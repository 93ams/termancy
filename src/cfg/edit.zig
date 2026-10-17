//! Editing a document in place: a change touches only the bytes it must, so comments,
//! blank lines, key order, and quoting elsewhere in the file survive.
//!
//! ```zig
//! const port: cfg.Value = .{ .int = 9090 };
//! const change: cfg.edit.Change = .{ .set = .{ .key = "server.port", .value = port } };
//! if (try cfg.edit.apply(arena, .toml, source, change)) |edited| {
//!     // Write `edited`.
//! } else {
//!     // Not possible in place: write the whole tree with `Format.write`, losing comments.
//! }
//! ```
//!
//! Every edit is checked before it is returned: the edited source must parse, and to the
//! tree the change describes, as the format reads it back. When either check fails, or the
//! edit is one the format's editor does not make (YAML is edited in block style only, INI
//! cannot hold tables in arrays), `apply` returns null rather than a wrong document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Format = @import("format.zig").Format;
const path = @import("path.zig");
const toml = @import("toml.zig");
const dotenv = @import("dotenv.zig");
const yaml = @import("yaml.zig");
const zon = @import("zon.zig");
const ini = @import("ini.zig");
const json = @import("json.zig");

/// One edit of a document.
pub const Change = union(enum) {
    /// Set the value at `key`, adding it when missing.
    set: struct { key: []const u8, value: Value },
    /// Remove the value or table at the key.
    unset: []const u8,
};

/// `source` with `change` applied in place, or null when that is not possible: the format
/// has no in-place editor, `source` does not parse, the key cannot be set or is not there
/// to unset, or the edited text would not read back as intended. All memory comes from
/// `arena`.
pub fn apply(
    arena: Allocator,
    format: Format,
    source: []const u8,
    change: Change,
) Allocator.Error!?[]const u8 {
    var expected = format.parse(arena, source, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return null,
    };
    switch (change) {
        .set => |set| expected.put(arena, set.key, set.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath, error.NotATable, error.IndexOutOfRange => return null,
        },
        .unset => |key| if (!expected.remove(key)) return null,
    }
    const edited = edit(arena, format, source, change) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return null,
    };
    const intended = try readBack(arena, format, expected) orelse return null;
    const actual = format.parse(arena, edited, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return null,
    };
    return if (same(actual, intended)) edited else null;
}

/// `source` with every change of `changes` applied in order, each as `apply` would; null
/// when any of them cannot be made in place.
pub fn applyAll(
    arena: Allocator,
    format: Format,
    source: []const u8,
    changes: []const Change,
) Allocator.Error!?[]const u8 {
    var text = source;
    for (changes) |change| text = try apply(arena, format, text, change) orelse return null;
    return text;
}

/// `Value.eql`, except that NaN equals NaN: an edit elsewhere in a file holding `nan`
/// leaves it as it was.
fn same(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .float => |x| x == b.float or (std.math.isNan(x) and std.math.isNan(b.float)),
        .array => |x| x.items.len == b.array.items.len and for (x.items, b.array.items) |l, r| {
            if (!same(l, r)) break false;
        } else true,
        .table => |x| x.count() == b.table.count() and blk: {
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.table.get(entry.key_ptr.*) orelse break :blk false;
                if (!same(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => a.eql(b),
    };
}

/// `value` as `format` reads it after writing it: dotenv, for one, keeps only strings.
fn readBack(arena: Allocator, format: Format, value: Value) Allocator.Error!?Value {
    var out: std.Io.Writer.Allocating = .init(arena);
    format.write(&out.writer, value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.Unrepresentable => return null,
    };
    return format.parse(arena, out.written(), null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => null,
    };
}

const EditError = error{Unsupported} || Allocator.Error;

fn edit(arena: Allocator, format: Format, source: []const u8, change: Change) EditError![]const u8 {
    return switch (format) {
        .toml => editToml(arena, source, change),
        .dotenv => editDotenv(arena, source, change),
        .yaml => editYaml(arena, source, change),
        .zon => editZon(arena, source, change),
        .ini => editIni(arena, source, change),
        .json => editJson(arena, source, change, false),
        .jsonc => editJson(arena, source, change, true),
    };
}

/// `source` in canonical form, as `Format.write` would write it, but keeping comments:
/// `zig fmt` for ZON; for TOML and dotenv, keys and values written canonically, comments
/// left beside what they annotate, and runs of blank lines collapsed. Null when that is
/// not possible (another format, a comment inside a multi-line value, or a result that
/// would read differently); the caller can rewrite the file, losing its comments.
pub fn reformat(arena: Allocator, format: Format, source: []const u8) Allocator.Error!?[]const u8 {
    const before = format.parse(arena, source, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return null,
    };
    const formatted = (switch (format) {
        .zon => reformatZon(arena, source),
        .toml => reformatToml(arena, source, before),
        .dotenv => reformatDotenv(arena, source),
        .yaml => reformatYaml(arena, source, before),
        .json, .jsonc, .ini => error.Unsupported,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return null,
    };
    const after = format.parse(arena, formatted, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return null,
    };
    return if (same(before, after)) formatted else null;
}

/// `source` with its keys sorted, as `Value.sortKeys` sorts a tree, and otherwise in
/// canonical form as `reformat` writes it, keeping comments: TOML only. Tables are sorted
/// by name. Keys are sorted within each run of key/value lines, a blank line or a comment
/// set apart by blank lines ending a run, so a file's grouping survives. A line, or a
/// table, moves with the comment lines directly above it. Null for another format, or
/// where `reformat` would give null.
pub fn sort(arena: Allocator, format: Format, source: []const u8) Allocator.Error!?[]const u8 {
    if (format != .toml) return null;
    var tree = format.parse(arena, source, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return null,
    };
    // Sorted first, so inline tables are written sorted.
    tree.sortKeys();
    const sorted = sortToml(arena, source, tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return null,
    };
    const after = format.parse(arena, sorted, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return null,
    };
    return if (same(tree, after)) sorted else null;
}

/// A header or key/value line of canonical TOML, with the comment lines directly above it.
const SortItem = struct {
    start: usize,
    end: usize,
    path: []const []const u8,
    header: bool,

    fn lessThan(_: void, a: SortItem, b: SortItem) bool {
        return pathLessThan(a.path, b.path);
    }
};

/// Orders key paths segment by segment, array indices as numbers, a prefix first.
fn pathLessThan(a: []const []const u8, b: []const []const u8) bool {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (std.mem.eql(u8, x, y)) continue;
        const x_index = std.fmt.parseUnsigned(usize, x, 10) catch null;
        const y_index = std.fmt.parseUnsigned(usize, y, 10) catch null;
        if (x_index != null and y_index != null) return x_index.? < y_index.?;
        return std.mem.lessThan(u8, x, y);
    }
    return a.len < b.len;
}

fn sortToml(arena: Allocator, source: []const u8, tree: Value) EditError![]const u8 {
    const text = try reformatToml(arena, source, tree);
    const all = toml.spans(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    const items = try arena.alloc(SortItem, all.len);
    var previous_end: usize = 0;
    for (all, items, 0..) |span, *item, i| {
        var start = span.start;
        // Canonical text: comments start their lines.
        while (start > previous_end) {
            const before = lineStartBefore(text, start);
            if (before < previous_end or text[before] != '#') break;
            start = before;
        }
        // Comments that open a run (after a blank line or a header) head the run rather
        // than describe its first key; a table keeps those above its header.
        const follows_entry = i > 0 and start == previous_end and all[i - 1].kind == .entry;
        if (span.kind == .entry and !follows_entry) start = span.start;
        item.* = .{
            .start = start,
            .end = span.end,
            .path = span.path,
            .header = span.kind == .header,
        };
        previous_end = span.end;
    }
    const first_header = for (items, 0..) |item, i| {
        if (item.header) break i;
    } else items.len;
    var out: std.ArrayList(u8) = .empty;
    const root_end = if (first_header < items.len) items[first_header].start else text.len;
    try appendSorted(arena, &out, text, 0, root_end, items[0..first_header]);

    // Each table: its header's index, and the end of its items.
    const Table = struct { header: usize, end: usize };
    var tables: std.ArrayList(Table) = .empty;
    for (items[first_header..], first_header..) |item, i| {
        if (!item.header) continue;
        if (tables.items.len > 0) tables.items[tables.items.len - 1].end = i;
        try tables.append(arena, .{ .header = i, .end = items.len });
    }
    std.mem.sort(Table, tables.items, items, struct {
        fn lessThan(all_items: []const SortItem, a: Table, b: Table) bool {
            return pathLessThan(all_items[a.header].path, all_items[b.header].path);
        }
    }.lessThan);
    for (tables.items) |table| {
        // One blank line between tables, as `reformat` writes them.
        while (std.mem.endsWith(u8, out.items, "\n\n")) out.items.len -= 1;
        if (out.items.len > 0) try out.append(arena, '\n');
        const start = items[table.header].start;
        const end = if (table.end < items.len) items[table.end].start else text.len;
        try appendSorted(arena, &out, text, start, end, items[table.header + 1 .. table.end]);
    }
    while (std.mem.endsWith(u8, out.items, "\n\n")) out.items.len -= 1;
    return out.items;
}

/// Appends `text[start..end]` with each run of `items` (those with nothing between them)
/// sorted by key.
fn appendSorted(
    arena: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    start: usize,
    end: usize,
    items: []const SortItem,
) Allocator.Error!void {
    var at = start;
    var i: usize = 0;
    while (i < items.len) {
        try out.appendSlice(arena, text[at..items[i].start]);
        var j = i + 1;
        while (j < items.len and items[j].start == items[j - 1].end) j += 1;
        const run = try arena.dupe(SortItem, items[i..j]);
        std.mem.sort(SortItem, run, {}, SortItem.lessThan);
        for (run) |item| try out.appendSlice(arena, text[item.start..item.end]);
        at = items[j - 1].end;
        i = j;
    }
    try out.appendSlice(arena, text[at..end]);
}

fn reformatZon(arena: Allocator, source: []const u8) EditError![]const u8 {
    const text = try arena.dupeSentinel(u8, source, 0);
    const tree = try std.zig.Ast.parse(arena, text, .{ .mode = .zon });
    if (tree.errors.len > 0) return error.Unsupported;
    return tree.renderAlloc(arena);
}

fn reformatToml(arena: Allocator, source: []const u8, tree: Value) EditError![]const u8 {
    const all = toml.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var formatter: LineFormatter = .{ .w = w };
    var section: []const []const u8 = &.{};
    var from: usize = 0;
    write: {
        for (all) |span| {
            const is_header = span.kind == .header;
            formatter.gap(source[from..span.start], is_header) catch break :write;
            from = span.end;
            const text = source[span.start..span.end];
            switch (span.kind) {
                .header => {
                    section = span.path;
                    const opening = std.mem.trimStart(u8, text, " \t");
                    const is_array = std.mem.startsWith(u8, opening, "[[");
                    // Before a section, one blank line, unless the file starts with it, or
                    // the comments directly above it are there.
                    if (formatter.written and !formatter.blank and !formatter.attached) {
                        w.writeByte('\n') catch break :write;
                    }
                    w.writeAll(if (is_array) "[[" else "[") catch break :write;
                    var first = true;
                    for (span.path, 0..) |segment, i| {
                        // An array of tables' index is not spelled in its header.
                        if (isIndexAfterArray(source, all, span.path[0 .. i + 1])) continue;
                        if (!first) w.writeByte('.') catch break :write;
                        first = false;
                        toml.writeKey(w, segment) catch return error.Unsupported;
                    }
                    w.writeAll(if (is_array) "]]" else "]") catch break :write;
                    try trailingComment(w, source[span.value_end..span.end]);
                },
                .entry => {
                    const value_text = source[span.value_start..span.value_end];
                    // A comment inside a multi-line value has nowhere to go.
                    const spans_lines = std.mem.indexOfScalar(u8, value_text, '\n') != null;
                    const has_hash = std.mem.indexOfScalar(u8, value_text, '#') != null;
                    if (spans_lines and has_hash) return error.Unsupported;
                    for (span.path[section.len..], 0..) |segment, i| {
                        if (i > 0) w.writeByte('.') catch break :write;
                        toml.writeKey(w, segment) catch return error.Unsupported;
                    }
                    w.writeAll(" = ") catch break :write;
                    const value = lookupSegments(tree, span.path) orelse return error.Unsupported;
                    toml.writeValue(w, value) catch |err| switch (err) {
                        error.WriteFailed => break :write,
                        error.Unrepresentable => return error.Unsupported,
                    };
                    try trailingComment(w, source[span.value_end..span.end]);
                },
            }
            formatter.written = true;
            formatter.blank = false;
        }
        formatter.gap(source[from..], false) catch break :write;
        return out.written();
    }
    return error.OutOfMemory;
}

/// Whether the last segment of `prefix` is the index TOML's parser added after an array of
/// tables, rather than a key: a header `[[a]]` has the path `a.0`.
fn isIndexAfterArray(source: []const u8, all: []const toml.Span, prefix: []const []const u8) bool {
    const last = prefix[prefix.len - 1];
    _ = std.fmt.parseUnsigned(usize, last, 10) catch return false;
    for (all) |span| {
        if (span.kind != .header or span.path.len < prefix.len) continue;
        if (!segmentsEql(span.path[0..prefix.len], prefix)) continue;
        const text = std.mem.trimStart(u8, source[span.start..span.end], " \t");
        if (std.mem.startsWith(u8, text, "[[")) return true;
    }
    return false;
}

fn lookupSegments(tree: Value, segments: []const []const u8) ?Value {
    var current = tree;
    for (segments) |segment| {
        current = switch (current) {
            .table => |t| t.get(segment) orelse return null,
            .array => |a| a.items[std.fmt.parseUnsigned(usize, segment, 10) catch return null],
            else => return null,
        };
    }
    return current;
}

/// Writes the `# comment` in `rest` (what follows a value on its line), then the line break.
fn trailingComment(w: *std.Io.Writer, rest: []const u8) EditError!void {
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
        const comment = std.mem.trimEnd(u8, rest[hash..], " \t\r\n");
        w.print(" {s}", .{comment}) catch return error.OutOfMemory;
    }
    w.writeByte('\n') catch return error.OutOfMemory;
}

/// Writes what lies between entries: comment lines without their indentation, and at most
/// one blank line in a row, none at the start.
const LineFormatter = struct {
    w: *std.Io.Writer,
    /// Something was written.
    written: bool = false,
    /// The last line written is blank.
    blank: bool = false,
    /// The last lines written are comments directly above a header, which keeps them.
    attached: bool = false,

    /// Writes `text`; `before_header` when a header follows it, so that the comment lines
    /// directly above the header stay so, set apart from what is before them instead.
    fn gap(f: *LineFormatter, text: []const u8, before_header: bool) std.Io.Writer.Error!void {
        const attached_at = if (before_header) attachedComments(text) else null;
        f.attached = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var pending_blank = false;
        var at: usize = 0;
        while (lines.next()) |raw| : (at += raw.len + 1) {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) {
                // The text after the last line break is not a line of its own.
                if (lines.peek() != null) pending_blank = true;
                continue;
            }
            if (attached_at == at) {
                pending_blank = true;
                f.attached = true;
            }
            if (pending_blank and f.written and !f.blank) {
                try f.w.writeByte('\n');
                f.blank = true;
            }
            pending_blank = false;
            try f.w.print("{s}\n", .{line});
            f.written = true;
            f.blank = false;
        }
        if (pending_blank and f.written and !f.blank) {
            try f.w.writeByte('\n');
            f.blank = true;
        }
    }

    /// Where the comment lines at the end of `text`, with no blank line after them, start.
    fn attachedComments(text: []const u8) ?usize {
        var start: ?usize = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var at: usize = 0;
        while (lines.next()) |raw| : (at += raw.len + 1) {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) {
                if (lines.peek() != null) start = null;
            } else if (start == null) {
                start = at;
            }
        }
        return start;
    }
};

fn reformatDotenv(arena: Allocator, source: []const u8) EditError![]const u8 {
    const all = dotenv.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var formatter: LineFormatter = .{ .w = w };
    var from: usize = 0;
    write: {
        for (all) |span| {
            formatter.gap(source[from..span.start], false) catch break :write;
            from = span.end;
            const line = std.mem.trimStart(u8, source[span.start..span.value_start], " \t");
            const exported = std.mem.startsWith(u8, line, "export ");
            const after_export = line[if (exported) "export ".len else 0..];
            const name_text = std.mem.trimStart(u8, after_export, " \t");
            const eq = std.mem.indexOfScalar(u8, name_text, '=') orelse return error.Unsupported;
            const name = std.mem.trimEnd(u8, name_text[0..eq], " \t");
            // Values keep their text: re-quoting could change what `${VAR}` expands.
            const value_text = std.mem.trimEnd(u8, source[span.value_start..span.value_end], " \t");
            if (std.mem.indexOfScalar(u8, value_text, '\n') != null) return error.Unsupported;
            const prefix = if (exported) "export " else "";
            w.print("{s}{s}={s}", .{ prefix, name, value_text }) catch break :write;
            try trailingComment(w, source[span.value_end..span.end]);
            formatter.written = true;
            formatter.blank = false;
        }
        formatter.gap(source[from..], false) catch break :write;
        return out.written();
    }
    return error.OutOfMemory;
}

/// A line of comments and blank lines that goes before a YAML entry, or at the end.
const YamlNote = union(enum) { blank, comment: []const u8 };

/// What a YAML entry carries besides its key and value.
const YamlComments = struct {
    before: []const YamlNote = &.{},
    trailing: ?[]const u8 = null,
};

/// YAML as `yaml.write` writes it, with each comment put back beside what it was beside:
/// the comment lines before an entry or a sequence item, and a comment after one on its
/// line. Entries are matched by their key path; sequence items holding one scalar, in
/// order. Documents with lines of any other kind (a flow collection over several lines, a
/// block scalar as a sequence item) are declined.
fn reformatYaml(arena: Allocator, source: []const u8, tree: Value) EditError![]const u8 {
    const all = try yamlSpansInOrder(arena, source) orelse return error.Unsupported;
    if (all.len == 0) return error.Unsupported;
    // Each entry's comments, by its path joined with NUL; each scalar item's, in order.
    var comments: std.StringHashMapUnmanaged(YamlComments) = .empty;
    var items: std.ArrayList(YamlComments) = .empty;
    var notes: std.ArrayList(YamlNote) = .empty;
    var marker = false;
    var next_span: usize = 0;
    // The end of a block scalar whose lines are being passed over.
    var content_end: usize = 0;
    var start: usize = 0;
    while (start < source.len) {
        const newline = std.mem.indexOfScalarPos(u8, source, start, '\n');
        const end = newline orelse source.len;
        const raw = std.mem.trimEnd(u8, source[start..end], "\r");
        const line = std.mem.trim(u8, raw, " \t");
        defer start = if (newline) |n| n + 1 else source.len;
        if (start < content_end) continue;
        if (next_span < all.len and all[next_span].start == start) {
            const span = all[next_span];
            next_span += 1;
            const after = if (span.value_end > 0) span.value_end else afterColon(raw) orelse
                return error.Unsupported;
            const absolute = if (span.value_end > 0) after else start + after;
            var rest = std.mem.trim(u8, source[absolute..@max(absolute, start + raw.len)], " \t");
            if (rest.len > 0 and (rest[0] == '|' or rest[0] == '>')) {
                // A block scalar: its lines are the value; a comment may follow its header.
                const header_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                rest = std.mem.trim(u8, rest[header_end..], " \t");
                content_end = span.end;
            }
            if (rest.len > 0 and rest[0] != '#') return error.Unsupported;
            try comments.put(arena, try std.mem.join(arena, "\x00", span.path), .{
                .before = try notes.toOwnedSlice(arena),
                .trailing = if (rest.len > 0) rest else null,
            });
            continue;
        }
        if (line.len == 0) {
            try notes.append(arena, .blank);
        } else if (line[0] == '#') {
            try notes.append(arena, .{ .comment = line });
        } else if (std.mem.eql(u8, line, "---") and next_span == 0 and !marker) {
            // The document marker at the top stays there, after the comments before it.
            if (notes.items.len > 0) return error.Unsupported;
            marker = true;
        } else if (isItem(line)) {
            try items.append(arena, .{
                .before = try notes.toOwnedSlice(arena),
                .trailing = itemComment(line) orelse return error.Unsupported,
            });
        } else return error.Unsupported;
    }
    // Two entries on one line, as in `- - a: 1`, are not reformatted.
    if (next_span != all.len) return error.Unsupported;
    var canonical: std.Io.Writer.Allocating = .init(arena);
    yaml.write(&canonical.writer, tree, .{}) catch return error.OutOfMemory;
    const text = canonical.written();
    const written = try yamlSpansInOrder(arena, text) orelse return error.Unsupported;
    if (written.len != all.len) return error.Unsupported;

    // Items are matched up only when they have comments to keep: a flow sequence in the
    // source becomes items in the output, with nothing to match.
    var match_items = false;
    for (items.items) |item| {
        if (item.trailing != null) match_items = true;
        for (item.before) |note| match_items = match_items or note == .comment;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var span_index: usize = 0;
    var item_index: usize = 0;
    write: {
        if (marker) w.writeAll("---\n") catch break :write;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var at: usize = 0;
        while (lines.next()) |line| : (at += line.len + 1) {
            if (line.len == 0 and lines.peek() == null) break;
            const found: ?YamlComments = if (span_index < written.len and
                written[span_index].start == at)
            found: {
                const span = written[span_index];
                span_index += 1;
                const key = try std.mem.join(arena, "\x00", span.path);
                break :found comments.get(key) orelse return error.Unsupported;
            } else if (match_items and isItem(std.mem.trimStart(u8, line, " "))) found: {
                if (item_index == items.items.len) return error.Unsupported;
                item_index += 1;
                break :found items.items[item_index - 1];
            } else null;
            if (found) |extra| {
                const indent = line[0 .. std.mem.indexOfNone(u8, line, " ") orelse 0];
                const first = out.written().len == @as(usize, if (marker) 4 else 0);
                writeYamlNotes(w, extra.before, indent, first) catch break :write;
                w.writeAll(line) catch break :write;
                if (extra.trailing) |comment| w.print(" {s}", .{comment}) catch break :write;
            } else w.writeAll(line) catch break :write;
            w.writeByte('\n') catch break :write;
        }
        // Items written differently (a flow sequence became items) cannot be matched up.
        if (match_items and item_index != items.items.len) return error.Unsupported;
        writeYamlNotes(w, notes.items, "", false) catch break :write;
        // Notes end with the line break of the last one; blank lines at the end are dropped.
        var result = out.written();
        while (std.mem.endsWith(u8, result, "\n\n")) result = result[0 .. result.len - 1];
        return result;
    }
    return error.OutOfMemory;
}

/// Whether `line`, without its indentation, is a sequence item that is not an entry.
fn isItem(line: []const u8) bool {
    return line.len > 0 and line[0] == '-' and (line.len == 1 or line[1] == ' ');
}

/// The comment after a sequence item holding one scalar (perhaps in a sequence in a
/// sequence: `- - a`): null when there is none, and when the item holds something else.
fn itemComment(line: []const u8) ??[]const u8 {
    var item = std.mem.trim(u8, line[1..], " \t");
    while (std.mem.startsWith(u8, item, "- ")) item = std.mem.trim(u8, item[1..], " \t");
    if (item.len == 0) return null;
    var value_end: usize = 0;
    switch (item[0]) {
        '"', '\'' => value_end = quotedEnd(item, 0) orelse return null,
        '[', '{' => {
            // Only an empty collection fits on the item's line as `yaml.write` writes it.
            if (item.len < 2 or item[1] != (if (item[0] == '[') @as(u8, ']') else '}')) {
                return null;
            }
            value_end = 2;
        },
        '|', '>', '&', '*', '!', '#', '%', '@', '`' => return null,
        // Indicators only before a blank: `-4` is a number.
        '-', '?', ':' => {
            if (item.len == 1 or item[1] == ' ') return null;
            value_end = plainEnd(item);
        },
        else => value_end = plainEnd(item),
    }
    const value = std.mem.trimEnd(u8, item[0..value_end], " \t");
    if (std.mem.indexOf(u8, value, ": ") != null or std.mem.endsWith(u8, value, ":")) {
        return null;
    }
    const rest = std.mem.trim(u8, item[value_end..], " \t");
    if (rest.len == 0) return @as(?[]const u8, null);
    if (rest[0] != '#') return null;
    return @as(?[]const u8, rest);
}

/// Where a plain scalar in `text` ends: before a ` #` comment, or at the end.
fn plainEnd(text: []const u8) usize {
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '#' and (text[i - 1] == ' ' or text[i - 1] == '\t')) return i;
    }
    return text.len;
}

/// Just past the quoted scalar that starts at `text[i]`: `\` escapes in double quotes,
/// `''` in single ones. Null when it does not close on this line.
fn quotedEnd(text: []const u8, start: usize) ?usize {
    const quote = text[start];
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (quote == '"' and text[i] == '\\') {
            i += 1;
        } else if (text[i] == quote) {
            if (quote == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
            } else return i + 1;
        }
    }
    return null;
}

/// `yaml.spans` in the order the entries' lines come (an entry with a block value is listed
/// after the entries in it); null when `source` does not parse.
fn yamlSpansInOrder(arena: Allocator, source: []const u8) Allocator.Error!?[]yaml.Span {
    const all = yaml.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return null,
    };
    const sorted = try arena.dupe(yaml.Span, all);
    std.mem.sort(yaml.Span, sorted, {}, struct {
        fn lessThan(_: void, a: yaml.Span, b: yaml.Span) bool {
            return a.start < b.start;
        }
    }.lessThan);
    return sorted;
}

/// Writes comment lines at `indent`, keeping one blank line where there were any, none at
/// the start of the document.
fn writeYamlNotes(
    w: *std.Io.Writer,
    notes: []const YamlNote,
    indent: []const u8,
    at_start: bool,
) std.Io.Writer.Error!void {
    var blank = false;
    var written = !at_start;
    for (notes) |note| switch (note) {
        .blank => blank = true,
        .comment => |comment| {
            if (blank and written) try w.writeByte('\n');
            try w.print("{s}{s}\n", .{ indent, comment });
            blank = false;
            written = true;
        },
    };
    if (blank and written) try w.writeByte('\n');
}

/// Where the value starts on a key's line `raw` whose value is a block below it: just past
/// the `:` that ends the key. Null when there is none.
fn afterColon(raw: []const u8) ?usize {
    var i = std.mem.indexOfNone(u8, raw, " \t") orelse return null;
    if (raw[i] == '-' and i + 1 < raw.len and raw[i + 1] == ' ') {
        i = std.mem.indexOfNonePos(u8, raw, i + 1, " \t") orelse return null;
    }
    if (raw[i] == '"' or raw[i] == '\'') i = quotedEnd(raw, i) orelse return null;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == ':' and (i + 1 == raw.len or raw[i + 1] == ' ' or raw[i + 1] == '\t')) {
            return i + 1;
        }
        if (raw[i] == '#') return null;
    }
    return null;
}

// -- TOML ------------------------------------------------------------------------------

/// A section: the root or a `[header]`, and where a new key/value line for it goes.
const Section = struct {
    path: []const []const u8,
    /// After the section's last key/value line, or after its header when it has none.
    insert_at: usize,
};

fn editToml(arena: Allocator, source: []const u8, change: Change) EditError![]const u8 {
    const all = toml.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    const key_text = switch (change) {
        .set => |set| set.key,
        .unset => |key| key,
    };
    const key = path.split(arena, key_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.Unsupported,
    };
    switch (change) {
        .set => |set| {
            var value: std.Io.Writer.Allocating = .init(arena);
            toml.writeValue(&value.writer, set.value) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.Unrepresentable => return error.Unsupported,
            };
            for (all) |span| {
                if (span.kind != .entry or !segmentsEql(span.path, key)) continue;
                const old = source[span.value_start..span.value_end];
                const text = try keepSingleQuotes(arena, old, set.value, .toml) orelse
                    value.written();
                return splice(arena, source, span.value_start, span.value_end, text);
            }
            return insertToml(arena, source, all, key, value.written());
        },
        .unset => return removeToml(arena, source, all, key, &.{"#"}),
    }
}

/// Adds `key = value` to the deepest section that holds a prefix of `key`. A nested key
/// nothing in the document starts yet gets a section of its own at the end: `[fetch]`
/// then `concurrency = 8`, rather than `fetch.concurrency = 8` among the top-level keys.
fn insertToml(
    arena: Allocator,
    source: []const u8,
    all: []const toml.Span,
    key: []const []const u8,
    value: []const u8,
) EditError![]const u8 {
    const sections = try sectionsOf(arena, source, all);
    var best = sections[0]; // The root, whose path is a prefix of every key.
    for (sections[1..]) |section| {
        if (section.path.len >= key.len or section.path.len <= best.path.len) continue;
        if (segmentsEql(section.path, key[0..section.path.len])) best = section;
    }
    const table = key[0 .. key.len - 1];
    const fresh = best.path.len == 0 and table.len > 0 and for (all) |span| {
        if (span.path.len >= 1 and std.mem.eql(u8, span.path[0], table[0])) break false;
    } else true;
    if (fresh) return appendTomlSection(arena, source, table, key[key.len - 1], value);
    var line: std.Io.Writer.Allocating = .init(arena);
    const w = &line.writer;
    const at = best.insert_at;
    const nl = lineBreak(source);
    write: {
        if (at > 0 and source[at - 1] != '\n') w.writeAll(nl) catch break :write;
        for (key[best.path.len..], 0..) |segment, i| {
            if (i > 0) w.writeByte('.') catch break :write;
            toml.writeKey(w, segment) catch |err| switch (err) {
                error.WriteFailed => break :write,
                error.Unrepresentable => return error.Unsupported,
            };
        }
        w.print(" = {s}{s}", .{ value, nl }) catch break :write;
        // A key added to the root just before the first header (or the comment above it):
        // keep a blank line.
        const before_header = best.path.len == 0 and at < source.len and
            (source[at] == '[' or source[at] == '#');
        if (before_header) w.writeAll(nl) catch break :write;
        return splice(arena, source, at, at, line.written());
    }
    return error.OutOfMemory;
}

/// `source` with `[table]` and `name = value` added at its end, after a blank line.
fn appendTomlSection(
    arena: Allocator,
    source: []const u8,
    table: []const []const u8,
    name: []const u8,
    value: []const u8,
) EditError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const nl = lineBreak(source);
    write: {
        const body = std.mem.trimEnd(u8, source, " \t\r\n");
        w.writeAll(body) catch break :write;
        if (body.len > 0) w.print("{s}{s}", .{ nl, nl }) catch break :write;
        w.writeByte('[') catch break :write;
        for (table, 0..) |segment, i| {
            if (i > 0) w.writeByte('.') catch break :write;
            toml.writeKey(w, segment) catch |err| switch (err) {
                error.WriteFailed => break :write,
                error.Unrepresentable => return error.Unsupported,
            };
        }
        w.print("]{s}", .{nl}) catch break :write;
        toml.writeKey(w, name) catch |err| switch (err) {
            error.WriteFailed => break :write,
            error.Unrepresentable => return error.Unsupported,
        };
        w.print(" = {s}{s}", .{ value, nl }) catch break :write;
        return out.written();
    }
    return error.OutOfMemory;
}

/// The root section first, then each header in order. `all` is TOML's or INI's spans.
fn sectionsOf(arena: Allocator, source: []const u8, all: anytype) Allocator.Error![]Section {
    var sections: std.ArrayList(Section) = .empty;
    // Without key/value lines, the root's new keys go before the first header.
    const first_header = for (all) |span| {
        if (span.kind == .header) break span.start;
    } else source.len;
    try sections.append(arena, .{ .path = &.{}, .insert_at = first_header });
    var root_has_entries = false;
    for (all) |span| switch (span.kind) {
        .header => try sections.append(arena, .{ .path = span.path, .insert_at = span.end }),
        .entry => {
            const current = &sections.items[sections.items.len - 1];
            current.insert_at = span.end;
            if (sections.items.len == 1) root_has_entries = true;
        },
    };
    if (!root_has_entries) {
        // Before the comment lines directly above the first header, which describe it.
        var at = first_header;
        while (at > 0 and first_header < source.len) {
            const previous = lineStartBefore(source, at);
            const text = std.mem.trim(u8, source[previous..at], " \t\r\n");
            if (text.len == 0 or (text[0] != '#' and text[0] != ';')) break;
            at = previous;
        }
        sections.items[0].insert_at = at;
    }
    return sections.items;
}

/// Removes every line under `key`: its key/value lines and its sections, in TOML or INI,
/// with the comments directly above them (see `tidyRemoval`). A section's trailing
/// comments and blank lines stay; they usually introduce what follows.
fn removeToml(
    arena: Allocator,
    source: []const u8,
    all: anytype,
    key: []const []const u8,
    markers: []const []const u8,
) EditError![]const u8 {
    var ranges: std.ArrayList([2]usize) = .empty;
    var section_end: ?*[2]usize = null;
    for (all) |span| {
        const under = span.path.len >= key.len and segmentsEql(span.path[0..key.len], key);
        switch (span.kind) {
            .header => {
                section_end = null;
                if (!under) continue;
                try ranges.append(arena, .{ span.start, span.end });
                section_end = &ranges.items[ranges.items.len - 1];
            },
            .entry => if (section_end) |range| {
                range[1] = span.end;
            } else if (under) {
                try ranges.append(arena, .{ span.start, span.end });
            },
        }
    }
    if (ranges.items.len == 0) return error.Unsupported;
    return cut(arena, source, try tidyRemoval(arena, source, ranges.items, markers, false));
}

// -- JSON ------------------------------------------------------------------------------

fn editJson(
    arena: Allocator,
    source: []const u8,
    change: Change,
    comments: bool,
) EditError![]const u8 {
    const all = json.spans(arena, source, comments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    const key_text = switch (change) {
        .set => |set| set.key,
        .unset => |key| key,
    };
    const key = path.split(arena, key_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.Unsupported,
    };
    switch (change) {
        .set => |set| {
            var value: std.Io.Writer.Allocating = .init(arena);
            json.writeInline(&value.writer, set.value) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.Unrepresentable => return error.Unsupported,
            };
            // A repeated key keeps its last value.
            var i = all.len;
            while (i > 0) {
                i -= 1;
                const span = all[i];
                if (span.kind != .field or !segmentsEql(span.path, key)) continue;
                return splice(arena, source, span.value_start, span.value_end, value.written());
            }
            return insertJson(arena, source, all, key, set.value, comments);
        },
        .unset => return removeJson(arena, source, all, key, comments),
    }
}

/// The fields directly inside `object`, in order.
fn fieldsOf(
    arena: Allocator,
    all: []const json.Span,
    object: json.Span,
) Allocator.Error![]const json.Span {
    var fields: std.ArrayList(json.Span) = .empty;
    for (all) |span| {
        if (span.kind == .field and span.path.len == object.path.len + 1 and
            span.start > object.start and span.end <= object.end)
        {
            try fields.append(arena, span);
        }
    }
    return fields.items;
}

/// Adds `"key": value` to the deepest object holding a prefix of `key`, keeping its style:
/// a field per line, or all on one.
fn insertJson(
    arena: Allocator,
    source: []const u8,
    all: []const json.Span,
    key: []const []const u8,
    value: Value,
    comments: bool,
) EditError![]const u8 {
    var best: ?json.Span = null;
    for (all) |span| {
        if (span.kind != .object or span.path.len >= key.len) continue;
        if (!segmentsEql(span.path, key[0..span.path.len])) continue;
        if (best == null or span.path.len > best.?.path.len) best = span;
    }
    const object = best orelse return error.Unsupported;
    // The rest of `key` below the object, as nested tables.
    var nested = value;
    var i = key.len;
    while (i > object.path.len + 1) {
        i -= 1;
        var table: Value = .empty_table;
        try table.table.put(arena, key[i], nested);
        nested = table;
    }
    var field: std.Io.Writer.Allocating = .init(arena);
    write: {
        json.writeString(&field.writer, key[object.path.len]) catch break :write;
        field.writer.writeAll(": ") catch break :write;
        json.writeInline(&field.writer, nested) catch |err| switch (err) {
            error.WriteFailed => break :write,
            error.Unrepresentable => return error.Unsupported,
        };
    }
    const text = field.written();
    const siblings = try fieldsOf(arena, all, object);
    if (siblings.len == 0) {
        // `{}` becomes `{"key": value}`.
        const inside = try std.fmt.allocPrint(arena, "{{{s}}}", .{text});
        return splice(arena, source, object.start, object.end + 1, inside);
    }
    const last = siblings[siblings.len - 1];
    const has_comma = last.end > last.value_end;
    if (!object.multiline) {
        if (has_comma) {
            const insertion = try std.fmt.allocPrint(arena, " {s},", .{text});
            return splice(arena, source, last.end, last.end, insertion);
        }
        const insertion = try std.fmt.allocPrint(arena, ", {s}", .{text});
        return splice(arena, source, last.value_end, last.value_end, insertion);
    }
    // A line of its own after the last field's line, indented like it; the last field gains
    // a comma when it has none.
    const line_start = (std.mem.lastIndexOfScalar(u8, source[0..last.start], '\n') orelse
        return error.Unsupported) + 1;
    const indent_end = std.mem.indexOfNonePos(u8, source, line_start, " \t") orelse line_start;
    const indent = source[line_start..indent_end];
    const line_end = std.mem.indexOfScalarPos(u8, source, last.end, '\n') orelse
        return error.Unsupported;
    const rest = std.mem.trim(u8, source[last.end..line_end], " \t\r");
    const comment = comments and (std.mem.startsWith(u8, rest, "//") or
        (std.mem.startsWith(u8, rest, "/*") and std.mem.endsWith(u8, rest, "*/")));
    if (rest.len > 0 and !comment) return error.Unsupported;
    const line = try std.fmt.allocPrint(arena, "\n{s}{s}{s}", .{
        indent, text, if (has_comma) "," else "",
    });
    const with_line = try splice(arena, source, line_end, line_end, line);
    if (has_comma) return with_line;
    return splice(arena, with_line, last.value_end, last.value_end, ",");
}

/// Removes every field at `key`, with its line when it has one to itself, and a `//`
/// comment after it. The field before a removed last field loses its comma, which JSON
/// would not accept before `}`.
fn removeJson(
    arena: Allocator,
    source: []const u8,
    all: []const json.Span,
    key: []const []const u8,
    comments: bool,
) EditError![]const u8 {
    var ranges: std.ArrayList([2]usize) = .empty;
    for (all) |found| {
        if (found.kind != .field or !segmentsEql(found.path, key)) continue;
        const has_comma = found.end > found.value_end;
        var span = found;
        if (comments) {
            const line_end = std.mem.indexOfScalarPos(u8, source, span.end, '\n') orelse source.len;
            const rest = std.mem.trimStart(u8, source[span.end..line_end], " \t");
            if (std.mem.startsWith(u8, rest, "//")) span.end = line_end;
        }
        if (has_comma) {
            try ranges.append(arena, wholeLines(source, span.start, span.end));
            continue;
        }
        // The last field: find the one before it in the same object.
        var before: ?json.Span = null;
        for (all) |other| {
            if (other.kind != .field or other.start >= span.start) continue;
            if (other.path.len != key.len) continue;
            if (!segmentsEql(other.path[0 .. key.len - 1], key[0 .. key.len - 1])) continue;
            if (std.mem.indexOfScalar(u8, source[other.end..span.start], '}') != null) continue;
            before = other;
        }
        if (before) |previous| {
            const between = source[previous.end..span.start];
            const same_line = std.mem.indexOfScalar(u8, between, '\n') == null;
            if (same_line) {
                try ranges.append(arena, .{ previous.value_end, span.end });
                continue;
            }
            try ranges.append(arena, .{ previous.value_end, previous.end });
        }
        try ranges.append(arena, wholeLines(source, span.start, span.end));
    }
    if (ranges.items.len == 0) return error.Unsupported;
    // Removing duplicate keys can make ranges touch or overlap.
    std.mem.sort([2]usize, ranges.items, {}, struct {
        fn lessThan(_: void, a: [2]usize, b: [2]usize) bool {
            return a[0] < b[0];
        }
    }.lessThan);
    var merged: std.ArrayList([2]usize) = .empty;
    for (ranges.items) |range| {
        if (merged.items.len > 0 and range[0] <= merged.items[merged.items.len - 1][1]) {
            const last = &merged.items[merged.items.len - 1];
            last[1] = @max(last[1], range[1]);
        } else try merged.append(arena, range);
    }
    const markers: []const []const u8 = if (comments) &.{"//"} else &.{};
    return cut(arena, source, try tidyRemoval(arena, source, merged.items, markers, false));
}

// -- INI -------------------------------------------------------------------------------

fn editIni(arena: Allocator, source: []const u8, change: Change) EditError![]const u8 {
    const all = ini.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    const key_text = switch (change) {
        .set => |set| set.key,
        .unset => |key| key,
    };
    const key = path.split(arena, key_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.Unsupported,
    };
    const set = switch (change) {
        .set => |set| set,
        .unset => return removeToml(arena, source, all, key, &.{ ";", "#" }),
    };
    var value: std.Io.Writer.Allocating = .init(arena);
    ini.writeScalar(&value.writer, set.value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.Unrepresentable => return error.Unsupported,
    };
    // A repeated key keeps its last value.
    var i = all.len;
    while (i > 0) {
        i -= 1;
        const span = all[i];
        if (span.kind != .entry or !segmentsEql(span.path, key)) continue;
        return splice(arena, source, span.value_start, span.value_end, value.written());
    }
    // A new key: INI has no dotted keys, so it goes into its own section, made if missing.
    const name = key[key.len - 1];
    if (!ini.isPlainKey(name)) return error.Unsupported;
    const section = key[0 .. key.len - 1];
    const sections = try sectionsOf(arena, source, all);
    var line: std.Io.Writer.Allocating = .init(arena);
    const w = &line.writer;
    var at = source.len;
    const nl = lineBreak(source);
    write: {
        for (sections) |candidate| {
            if (!segmentsEql(candidate.path, section)) continue;
            at = candidate.insert_at;
            if (at > 0 and source[at - 1] != '\n') w.writeAll(nl) catch break :write;
            w.print("{s} = {s}{s}", .{ name, value.written(), nl }) catch break :write;
            // A key added to the root just before the first header (or the comment above
            // it): keep a blank line.
            const before_header = section.len == 0 and at < source.len and
                (source[at] == '[' or source[at] == '#' or source[at] == ';');
            if (before_header) w.writeAll(nl) catch break :write;
            return splice(arena, source, at, at, line.written());
        }
        if (source.len > 0 and source[source.len - 1] != '\n') w.writeAll(nl) catch break :write;
        if (source.len > 0) w.writeAll(nl) catch break :write;
        w.writeByte('[') catch break :write;
        for (section, 0..) |segment, n| {
            if (n > 0) w.writeByte('.') catch break :write;
            path.writeSegment(w, segment) catch break :write;
        }
        w.print("]{s}{s} = {s}{s}", .{ nl, name, value.written(), nl }) catch break :write;
        return splice(arena, source, at, at, line.written());
    }
    return error.OutOfMemory;
}

// -- YAML ------------------------------------------------------------------------------

fn editYaml(arena: Allocator, source: []const u8, change: Change) EditError![]const u8 {
    const all = yaml.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    const key_text = switch (change) {
        .set => |set| set.key,
        .unset => |key| key,
    };
    const key = path.split(arena, key_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.Unsupported,
    };
    switch (change) {
        .set => |set| {
            var value: std.Io.Writer.Allocating = .init(arena);
            // YAML can write any value.
            yaml.writeValue(&value.writer, set.value) catch return error.OutOfMemory;
            for (all) |span| {
                if (!segmentsEql(span.path, key)) continue;
                // A block value (a nested mapping, a list, `|` text) is not one span.
                if (span.value_end == 0) return error.Unsupported;
                const old = source[span.value_start..span.value_end];
                const text = try keepSingleQuotes(arena, old, set.value, .yaml) orelse
                    value.written();
                return splice(arena, source, span.value_start, span.value_end, text);
            }
            return insertYaml(arena, source, all, key, value.written());
        },
        .unset => {
            for (all) |span| {
                if (!segmentsEql(span.path, key)) continue;
                const range = [_][2]usize{.{ span.start, span.end }};
                return cut(arena, source, try tidyRemoval(arena, source, &range, &.{"#"}, true));
            }
            return error.Unsupported;
        },
    }
}

/// Adds `key: value` under the deepest mapping holding a prefix of `key`, after its last
/// entry, nesting the rest of `key` two spaces at a time.
fn insertYaml(
    arena: Allocator,
    source: []const u8,
    all: []const yaml.Span,
    key: []const []const u8,
    value: []const u8,
) EditError![]const u8 {
    // The mapping at `parent` is the one whose entries' paths are `parent` and one key.
    var parent_len: ?usize = null;
    var indent: usize = 0;
    var at: usize = source.len;
    for (all) |span| {
        const depth = span.path.len - 1;
        if (depth >= key.len or !segmentsEql(span.path[0..depth], key[0..depth])) continue;
        if (parent_len == null or depth > parent_len.?) {
            parent_len = depth;
            indent = span.indent;
            at = span.end;
        } else if (depth == parent_len.?) {
            at = @max(at, span.end);
        }
    }
    const base = parent_len orelse blk: {
        // No entry at all: only an empty document can take a mapping at the root.
        if (std.mem.trim(u8, source, " \t\r\n").len > 0) return error.Unsupported;
        at = source.len;
        break :blk 0;
    };
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    const nl = lineBreak(source);
    write: {
        if (at > 0 and source[at - 1] != '\n') w.writeAll(nl) catch break :write;
        for (key[base..], 0..) |segment, i| {
            w.splatByteAll(' ', indent + 2 * i) catch break :write;
            yaml.writeString(w, segment) catch break :write;
            if (i + 1 < key.len - base) {
                w.print(":{s}", .{nl}) catch break :write;
            } else {
                w.print(": {s}{s}", .{ value, nl }) catch break :write;
            }
        }
        return splice(arena, source, at, at, text.written());
    }
    return error.OutOfMemory;
}

// -- ZON -------------------------------------------------------------------------------

fn editZon(arena: Allocator, source: []const u8, change: Change) EditError![]const u8 {
    const all = zon.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    const key_text = switch (change) {
        .set => |set| set.key,
        .unset => |key| key,
    };
    const key = path.split(arena, key_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.Unsupported,
    };
    switch (change) {
        .set => |set| {
            for (all) |span| {
                if (span.kind != .field or !segmentsEql(span.path, key)) continue;
                var value: std.Io.Writer.Allocating = .init(arena);
                zon.writeInline(&value.writer, set.value) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                    error.Unrepresentable => return error.Unsupported,
                };
                return splice(arena, source, span.value_start, span.value_end, value.written());
            }
            return insertZon(arena, source, all, key, set.value);
        },
        .unset => {
            for (all) |span| {
                if (span.kind != .field or !segmentsEql(span.path, key)) continue;
                const range = [_][2]usize{wholeLines(source, span.start, span.end)};
                return cut(arena, source, try tidyRemoval(arena, source, &range, &.{"//"}, false));
            }
            return error.Unsupported;
        },
    }
}

/// Adds `.key = value` to the deepest struct literal holding a prefix of `key`, keeping
/// its style: a field per line, or all on one.
fn insertZon(
    arena: Allocator,
    source: []const u8,
    all: []const zon.Span,
    key: []const []const u8,
    value: Value,
) EditError![]const u8 {
    var best: ?zon.Span = null;
    for (all) |span| {
        if (span.kind != .container or span.path.len >= key.len) continue;
        if (!segmentsEql(span.path, key[0..span.path.len])) continue;
        if (best == null or span.path.len > best.?.path.len) best = span;
    }
    const container = best orelse return error.Unsupported;
    // The rest of `key` below the container, as nested tables.
    var nested = value;
    var i = key.len;
    while (i > container.path.len + 1) {
        i -= 1;
        var table: Value = .empty_table;
        try table.table.put(arena, key[i], nested);
        nested = table;
    }
    var field: std.Io.Writer.Allocating = .init(arena);
    zon.writeFieldName(&field.writer, key[container.path.len]) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.Unrepresentable => return error.Unsupported,
    };
    field.writer.writeAll(" = ") catch return error.OutOfMemory;
    zon.writeInline(&field.writer, nested) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.Unrepresentable => return error.Unsupported,
    };
    const text = field.written();
    if (container.fields == 0) {
        // `.{}` becomes `.{ .key = value }`.
        const inside = try std.fmt.allocPrint(arena, "{{ {s} }}", .{text});
        return splice(arena, source, container.start, container.end + 1, inside);
    }
    // After the container's last field, with a comma between.
    var last: ?zon.Span = null;
    for (all) |span| {
        if (span.kind == .field and span.path.len == container.path.len + 1 and
            segmentsEql(span.path[0..container.path.len], container.path) and
            span.start > container.start and span.end <= container.end)
        {
            last = span;
        }
    }
    const after = last orelse return error.Unsupported;
    const has_comma = after.end > after.value_end;
    if (container.multiline) {
        // A line of its own, indented like the line of the last field.
        const line_start = (std.mem.lastIndexOfScalar(u8, source[0..after.start], '\n') orelse
            return error.Unsupported) + 1;
        const indent = source[line_start..after.start];
        if (std.mem.trim(u8, indent, " \t").len > 0) return error.Unsupported;
        const insertion = try std.fmt.allocPrint(arena, "{s}\n{s}{s},", .{
            if (has_comma) "" else ",", indent, text,
        });
        return splice(arena, source, after.end, after.end, insertion);
    }
    const separator = if (has_comma) "" else ",";
    const insertion = try std.fmt.allocPrint(arena, "{s} {s}", .{ separator, text });
    return splice(arena, source, after.end, after.end, insertion);
}

/// `[start, end)`, widened to whole lines when nothing else shares them, so that removing
/// a field on its own line removes the line.
fn wholeLines(source: []const u8, start: usize, end: usize) [2]usize {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |n| n + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, end, '\n') orelse source.len;
    const before_blank = std.mem.trim(u8, source[line_start..start], " \t").len == 0;
    const after_blank = std.mem.trim(u8, source[end..line_end], " \t\r").len == 0;
    if (before_blank and after_blank) return .{ line_start, @min(line_end + 1, source.len) };
    // Inline: also take the space after a removed `.a = 1,`.
    var stop = end;
    while (stop < line_end and source[stop] == ' ') stop += 1;
    return .{ start, stop };
}

// -- dotenv ----------------------------------------------------------------------------

fn editDotenv(arena: Allocator, source: []const u8, change: Change) EditError![]const u8 {
    const all = dotenv.spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.Unsupported,
    };
    const key_text = switch (change) {
        .set => |set| set.key,
        .unset => |key| key,
    };
    const key = path.split(arena, key_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.Unsupported,
    };
    // dotenv paths are segments joined with `.`; a segment holding one has no spelling.
    for (key) |segment| {
        if (std.mem.indexOfScalar(u8, segment, '.') != null) return error.Unsupported;
    }
    const joined = try std.mem.join(arena, ".", key);
    switch (change) {
        .set => |set| {
            var value: std.Io.Writer.Allocating = .init(arena);
            dotenv.writeValue(&value.writer, set.value) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.Unrepresentable => return error.Unsupported,
            };
            // The last definition of a name is the one that counts.
            var i = all.len;
            while (i > 0) {
                i -= 1;
                const span = all[i];
                if (!std.mem.eql(u8, span.path, joined)) continue;
                return splice(arena, source, span.value_start, span.value_end, value.written());
            }
            var line: std.Io.Writer.Allocating = .init(arena);
            const w = &line.writer;
            write: {
                const nl = lineBreak(source);
                if (source.len > 0 and source[source.len - 1] != '\n') {
                    w.writeAll(nl) catch break :write;
                }
                for (key, 0..) |segment, n| {
                    if (n > 0) w.writeAll("__") catch break :write;
                    dotenv.writeName(w, segment) catch break :write;
                }
                w.print("={s}{s}", .{ value.written(), nl }) catch break :write;
                return splice(arena, source, source.len, source.len, line.written());
            }
            return error.OutOfMemory;
        },
        .unset => {
            var ranges: std.ArrayList([2]usize) = .empty;
            for (all) |span| {
                const under = std.mem.startsWith(u8, span.path, joined) and
                    (span.path.len == joined.len or span.path[joined.len] == '.');
                if (under) try ranges.append(arena, .{ span.start, span.end });
            }
            if (ranges.items.len == 0) return error.Unsupported;
            return cut(arena, source, try tidyRemoval(arena, source, ranges.items, &.{"#"}, false));
        },
    }
}

// -- Text ------------------------------------------------------------------------------

fn segmentsEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// The line break `source` uses: CRLF when its first line ends with one, else LF.
fn lineBreak(source: []const u8) []const u8 {
    const newline = std.mem.indexOfScalar(u8, source, '\n') orelse return "\n";
    return if (newline > 0 and source[newline - 1] == '\r') "\r\n" else "\n";
}

/// `value` as a single-quoted string, when `old` (the text it replaces) is one and
/// `value` is a string that can be written that way; else null, for the format's own
/// spelling. TOML's literal strings and YAML's single-quoted ones have no escapes, so a
/// path such as `C:\dir` reads better kept in them.
fn keepSingleQuotes(
    arena: Allocator,
    old: []const u8,
    value: Value,
    format: Format,
) Allocator.Error!?[]const u8 {
    if (value != .string) return null;
    if (old.len < 2 or old[0] != '\'' or std.mem.startsWith(u8, old, "\'\'\'")) return null;
    for (value.string) |c| {
        // YAML doubles a quote inside; TOML's literal strings cannot hold one.
        if (c == '\'' and format == .toml) return null;
        if (c < 0x20 or c == 0x7f) return null;
    }
    if (format == .yaml) {
        const doubled = try std.mem.replaceOwned(u8, arena, value.string, "'", "''");
        return try std.mem.concat(arena, u8, &.{ "'", doubled, "'" });
    }
    return try std.mem.concat(arena, u8, &.{ "'", value.string, "'" });
}

/// `ranges` (in order, not overlapping) widened to what removing them would strand, where
/// a range is whole lines:
///
/// - the comment lines directly above it (a line starting with one of `markers`, with no
///   blank line between), which describe what is removed;
/// - the blank lines between two removed ranges, which become one;
/// - one blank line, when the removal would leave one on each side; at the start of the
///   file, every blank line after it; at the end, every one before and after it.
///
/// With `same_indent`, a comment line counts only at the indentation of the line below it
/// (YAML, where a `#` line indented further may be a block scalar's text).
fn tidyRemoval(
    arena: Allocator,
    source: []const u8,
    ranges: []const [2]usize,
    markers: []const []const u8,
    same_indent: bool,
) Allocator.Error![]const [2]usize {
    const widened = try arena.dupe([2]usize, ranges);
    for (widened) |*range| {
        if (!isWholeLines(source, range.*)) continue;
        const indent = indentOf(source[range[0]..]);
        while (range[0] > 0) {
            const previous = lineStartBefore(source, range[0]);
            const line = source[previous..range[0]];
            const text = std.mem.trim(u8, line, " \t\r\n");
            const comment = for (markers) |marker| {
                if (std.mem.startsWith(u8, text, marker)) break true;
            } else false;
            if (!comment) break;
            if (same_indent and !std.mem.eql(u8, indentOf(line), indent)) break;
            range[0] = previous;
        }
    }
    var merged: std.ArrayList([2]usize) = .empty;
    for (widened) |range| {
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            const between = source[@min(last[1], range[0])..range[0]];
            const touching = range[0] <= last[1] or (isWholeLines(source, last.*) and
                isWholeLines(source, range) and
                std.mem.trim(u8, between, " \t\r\n").len == 0);
            if (touching) {
                last[1] = @max(last[1], range[1]);
                continue;
            }
        }
        try merged.append(arena, range);
    }
    for (merged.items) |*range| {
        if (!isWholeLines(source, range.*)) continue;
        if (range[0] == 0) {
            // The file does not start with a blank line.
            while (blankLineAt(source, range[1])) |next| range[1] = next;
            continue;
        }
        if (std.mem.trim(u8, source[range[1]..], " \t\r\n").len == 0) {
            // What was last in the file takes the blank lines before and after it.
            range[1] = source.len;
            while (range[0] > 0) {
                const previous = lineStartBefore(source, range[0]);
                if (blankLineAt(source, previous) == null) break;
                range[0] = previous;
            }
            continue;
        }
        const previous = lineStartBefore(source, range[0]);
        if (blankLineAt(source, previous) == null) continue;
        if (blankLineAt(source, range[1])) |next| range[1] = next;
    }
    return merged.items;
}

/// Whether `range` starts at the start of a line and ends after a line break, or at the end.
fn isWholeLines(source: []const u8, range: [2]usize) bool {
    const starts = range[0] == 0 or source[range[0] - 1] == '\n';
    const ends = range[1] == source.len or (range[1] > 0 and source[range[1] - 1] == '\n');
    return range[0] < range[1] and starts and ends;
}

/// The start of the line before the one starting at `start`, which is not 0.
fn lineStartBefore(source: []const u8, start: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, source[0 .. start - 1], '\n')) |n| n + 1 else 0;
}

/// The end of the blank line (one with a line break) that starts at `start`; null when
/// that line is not blank.
fn blankLineAt(source: []const u8, start: usize) ?usize {
    const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return null;
    if (std.mem.trim(u8, source[start..newline], " \t\r").len > 0) return null;
    return newline + 1;
}

/// The spaces and tabs `line` starts with.
fn indentOf(line: []const u8) []const u8 {
    return line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];
}

/// `source` with `source[start..end]` replaced by `text`.
fn splice(
    arena: Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    text: []const u8,
) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ source[0..start], text, source[end..] });
}

/// `source` without `ranges`, which are in order and do not overlap.
fn cut(arena: Allocator, source: []const u8, ranges: []const [2]usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var from: usize = 0;
    for (ranges) |range| {
        try out.appendSlice(arena, source[from..range[0]]);
        from = range[1];
    }
    try out.appendSlice(arena, source[from..]);
    return out.items;
}

const testing = std.testing;

fn expectEdit(format: Format, source: []const u8, change: Change, expected: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const edited = try apply(arena.allocator(), format, source, change);
    if (expected) |text| {
        try testing.expectEqualStrings(text, edited orelse return error.TestExpectedEdit);
    } else {
        try testing.expectEqual(null, edited);
    }
}

fn setTo(key: []const u8, value: Value) Change {
    return .{ .set = .{ .key = key, .value = value } };
}

const toml_source =
    \\# Service configuration.
    \\name = "demo" # shown in logs
    \\
    \\[server]
    \\# Where to listen.
    \\host = 'localhost'
    \\port = 8080 # default
    \\
    \\# Upstreams, in order.
    \\[[upstream]]
    \\url = "http://a"
    \\
    \\[[upstream]]
    \\url = "http://b"
    \\
;

test "TOML: changing a value keeps everything else" {
    try expectEdit(.toml, toml_source, setTo("server.port", .{ .int = 9090 }),
        \\# Service configuration.
        \\name = "demo" # shown in logs
        \\
        \\[server]
        \\# Where to listen.
        \\host = 'localhost'
        \\port = 9090 # default
        \\
        \\# Upstreams, in order.
        \\[[upstream]]
        \\url = "http://a"
        \\
        \\[[upstream]]
        \\url = "http://b"
        \\
    );
}

test "TOML: a value in an array of tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const edited = (try apply(arena.allocator(), .toml, toml_source, setTo(
        "upstream.1.url",
        .{ .string = "http://c" },
    ))).?;
    try testing.expect(std.mem.indexOf(u8, edited, "url = \"http://a\"") != null);
    try testing.expect(std.mem.indexOf(u8, edited, "url = \"http://c\"") != null);
    try testing.expect(std.mem.indexOf(u8, edited, "# Upstreams, in order.") != null);
}

test "TOML: a new key goes into the deepest matching section" {
    try expectEdit(.toml, toml_source, setTo("server.tls.cert", .{ .string = "c.pem" }),
        \\# Service configuration.
        \\name = "demo" # shown in logs
        \\
        \\[server]
        \\# Where to listen.
        \\host = 'localhost'
        \\port = 8080 # default
        \\tls.cert = "c.pem"
        \\
        \\# Upstreams, in order.
        \\[[upstream]]
        \\url = "http://a"
        \\
        \\[[upstream]]
        \\url = "http://b"
        \\
    );
    try expectEdit(.toml, "# Only a comment.\n", setTo("debug", .{ .bool = true }),
        \\# Only a comment.
        \\debug = true
        \\
    );
    try expectEdit(.toml, "[a]\nx = 1\n", setTo("top", .{ .int = 1 }),
        \\top = 1
        \\
        \\[a]
        \\x = 1
        \\
    );
    try expectEdit(.toml, "a = 1", setTo("b", .{ .int = 2 }), "a = 1\nb = 2\n");
    try expectEdit(.toml, "", setTo("a.\"b.c\"", .{ .int = 2 }), "[a]\n\"b.c\" = 2\n");
}

test "TOML: a nested key nothing starts yet gets its own section, at the end" {
    try expectEdit(.toml, "# Mine.\nroots = [\"/src\"]\n\n", setTo("fetch.concurrency", .{
        .int = 8,
    }), "# Mine.\nroots = [\"/src\"]\n\n[fetch]\nconcurrency = 8\n");
    // Where the table is started already, by a dotted key, the key joins it there.
    const dotted = "fetch.timeout = 1\n";
    const joined = "fetch.timeout = 1\nfetch.concurrency = 8\n";
    try expectEdit(.toml, dotted, setTo("fetch.concurrency", .{ .int = 8 }), joined);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const changes = [_]Change{
        setTo("roots", .{ .string = "/src" }),
        setTo("fetch.concurrency", .{ .int = 8 }),
        setTo("depth", .{ .int = 2 }),
    };
    const written = (try applyAll(arena.allocator(), .toml, "", &changes)).?;
    try testing.expectEqualStrings(
        \\roots = "/src"
        \\depth = 2
        \\
        \\[fetch]
        \\concurrency = 8
        \\
    , written);
    const bad = [_]Change{ changes[0], .{ .unset = "missing" } };
    try testing.expectEqual(null, try applyAll(arena.allocator(), .toml, "", &bad));
}

test "TOML: removing a key, a table, and an array of tables" {
    try expectEdit(.toml, toml_source, .{ .unset = "server.port" },
        \\# Service configuration.
        \\name = "demo" # shown in logs
        \\
        \\[server]
        \\# Where to listen.
        \\host = 'localhost'
        \\
        \\# Upstreams, in order.
        \\[[upstream]]
        \\url = "http://a"
        \\
        \\[[upstream]]
        \\url = "http://b"
        \\
    );
    try expectEdit(.toml, toml_source, .{ .unset = "upstream" },
        \\# Service configuration.
        \\name = "demo" # shown in logs
        \\
        \\[server]
        \\# Where to listen.
        \\host = 'localhost'
        \\port = 8080 # default
        \\
    );
    try expectEdit(.toml, "a.b = 1\na.c = 2\nd = 3\n", .{ .unset = "a" }, "d = 3\n");
    // A first key and the blank line after it go together, so set then unset is a round trip.
    try expectEdit(.toml, "x = 1\n\n[t]\ny = 2\n", .{ .unset = "x" }, "[t]\ny = 2\n");
}

test "removing takes the comment directly above, and a blank line left over" {
    // The comment block right above a key or a table goes with it; one set apart by a
    // blank line stays.
    try expectEdit(.toml, "a = 1\n\n# About b.\n# More.\nb = 2\nc = 3\n", .{ .unset = "b" },
        \\a = 1
        \\
        \\c = 3
        \\
    );
    try expectEdit(.toml, "a = 1\n\n# Not about b.\n\nb = 2\n", .{ .unset = "b" },
        \\a = 1
        \\
        \\# Not about b.
        \\
    );
    try expectEdit(.toml, "a = 1\n\n# T.\n[t]\nx = 1\n\n[u]\ny = 2\n", .{ .unset = "t" },
        \\a = 1
        \\
        \\[u]
        \\y = 2
        \\
    );
    // A trailing comment is part of its line, not of the next key.
    try expectEdit(.toml, "a = 1 # one\nb = 2\n", .{ .unset = "b" }, "a = 1 # one\n");
    try expectEdit(.toml, "a = 1\r\n\r\n# B.\r\nb = 2\r\n", .{ .unset = "b" }, "a = 1\r\n");
    // The other formats do the same.
    try expectEdit(.yaml, "a: 1\n\n# About b.\nb:\n  c: 2\n\nd: 3\n", .{ .unset = "b" },
        \\a: 1
        \\
        \\d: 3
        \\
    );
    // In YAML, a `#` line indented under a block scalar is its text, not a comment.
    try expectEdit(.yaml, "t: |\n  # text\nb: 1\n", .{ .unset = "b" }, "t: |\n  # text\n");
    try expectEdit(.ini, "; About a.\na = 1\nb = 2\n", .{ .unset = "a" }, "b = 2\n");
    try expectEdit(.zon, ".{\n    // About a.\n    .a = 1,\n    .b = 2,\n}\n", .{ .unset = "a" },
        \\.{
        \\    .b = 2,
        \\}
        \\
    );
    try expectEdit(.jsonc, "{\n  // About a.\n  \"a\": 1,\n  \"b\": 2\n}\n", .{ .unset = "a" },
        \\{
        \\  "b": 2
        \\}
        \\
    );
}

test "TOML: edge cases" {
    // Line breaks stay CRLF, in place and in a line added.
    try expectEdit(.toml, "a = 1\r\nb = 2\r\n", setTo("a", .{ .int = 3 }), "a = 3\r\nb = 2\r\n");
    try expectEdit(.toml, "a = 1\r\n", setTo("b", .{ .int = 2 }), "a = 1\r\nb = 2\r\n");
    try expectEdit(
        .toml,
        "a = 1\r\n\r\n[t]\r\nx = 1\r\n",
        setTo("t.y", .{ .int = 2 }),
        "a = 1\r\n\r\n[t]\r\nx = 1\r\ny = 2\r\n",
    );
    // A literal string stays one when the new text can be.
    try expectEdit(.toml, "host = 'a'\n", setTo("host", .{ .string = "b\\c" }), "host = 'b\\c'\n");
    try expectEdit(
        .toml,
        "host = 'a'\n",
        setTo("host", .{ .string = "it's" }),
        "host = \"it's\"\n",
    );
    try expectEdit(.toml, "host = 'a'\n", setTo("host", .{ .int = 1 }), "host = 1\n");
    // Only the nested key changes, not the root one of the same name.
    try expectEdit(
        .toml,
        "port = 1\n\n[server]\nport = 2\n",
        setTo("server.port", .{ .int = 3 }),
        "port = 1\n\n[server]\nport = 3\n",
    );
    try expectEdit(
        .toml,
        "url = \"a#b\" # c\n",
        setTo("url", .{ .string = "x#y" }),
        "url = \"x#y\" # c\n",
    );
    // A commented-out key is not the key.
    try expectEdit(.toml, "# port = 1\n", setTo("port", .{ .int = 2 }), "# port = 1\nport = 2\n");
    // A root key added before a table does not double the blank line.
    try expectEdit(
        .toml,
        "a = 1\n\n[t]\nx = 1\n",
        setTo("b", .{ .int = 2 }),
        "a = 1\nb = 2\n\n[t]\nx = 1\n",
    );
    try expectEdit(
        .toml,
        "# Top.\n\n[t]\nx = 1\n",
        setTo("b", .{ .int = 2 }),
        "# Top.\n\nb = 2\n\n[t]\nx = 1\n",
    );
    // A comment right above the first table stays with it.
    try expectEdit(
        .toml,
        "# T.\n[t]\nx = 1\n",
        setTo("b", .{ .int = 2 }),
        "b = 2\n\n# T.\n[t]\nx = 1\n",
    );
}

test "YAML: single quotes stay, CRLF stays" {
    try expectEdit(.yaml, "a: 'x'\n", setTo("a", .{ .string = "y z" }), "a: 'y z'\n");
    try expectEdit(.yaml, "a: 1\r\n", setTo("b", .{ .int = 2 }), "a: 1\r\nb: 2\r\n");
}

test "TOML: what cannot be done in place returns null" {
    // A key inside an inline table or array.
    try expectEdit(.toml, "p = { x = 1 }\n", setTo("p.x", .{ .int = 2 }), null);
    try expectEdit(.toml, "t = [1, 2]\n", setTo("t.0", .{ .int = 5 }), null);
    // TOML has no null.
    try expectEdit(.toml, "a = 1\n", setTo("a", .null), null);
    // Not there to remove; not valid TOML to begin with.
    try expectEdit(.toml, "a = 1\n", .{ .unset = "b" }, null);
    try expectEdit(.toml, "a = \n", setTo("a", .{ .int = 1 }), null);
}

test "dotenv: set and unset in place" {
    const source =
        \\# Database.
        \\export DB__HOST=localhost # local only
        \\DB__PORT="5432"
        \\
        \\DEBUG=true
        \\
    ;
    try expectEdit(.dotenv, source, setTo("db.port", .{ .int = 6543 }),
        \\# Database.
        \\export DB__HOST=localhost # local only
        \\DB__PORT=6543
        \\
        \\DEBUG=true
        \\
    );
    try expectEdit(.dotenv, source, setTo("db.user", .{ .string = "ann lee" }),
        \\# Database.
        \\export DB__HOST=localhost # local only
        \\DB__PORT="5432"
        \\
        \\DEBUG=true
        \\DB__USER="ann lee"
        \\
    );
    // The comment above goes with them, and the blank line after, at the start.
    try expectEdit(.dotenv, source, .{ .unset = "db" }, "DEBUG=true\n");
    try expectEdit(.dotenv, "A=1\nA=2\n", setTo("a", .{ .int = 3 }), "A=1\nA=3\n");
    try expectEdit(.dotenv, "A=1", setTo("b", .{ .int = 2 }), "A=1\nB=2\n");
}

test "dotenv: what cannot be done in place returns null" {
    // A later value expands the one being changed.
    try expectEdit(.dotenv, "A=1\nB=${A}\n", setTo("a", .{ .int = 2 }), null);
    try expectEdit(.dotenv, "A=1\n", setTo("x.\"y.z\"", .{ .int = 2 }), null);
}

test "ZON: change, add, and remove, keeping comments and style" {
    const source =
        \\// Service.
        \\.{
        \\    .name = "demo", // shown in logs
        \\    .server = .{
        \\        .host = "localhost",
        \\        .port = 8080,
        \\    },
        \\    .tags = .{ "a", "b" },
        \\}
        \\
    ;
    try expectEdit(.zon, source, setTo("server.port", .{ .int = 9090 }),
        \\// Service.
        \\.{
        \\    .name = "demo", // shown in logs
        \\    .server = .{
        \\        .host = "localhost",
        \\        .port = 9090,
        \\    },
        \\    .tags = .{ "a", "b" },
        \\}
        \\
    );
    try expectEdit(.zon, source, setTo("server.tls.cert", .{ .string = "c.pem" }),
        \\// Service.
        \\.{
        \\    .name = "demo", // shown in logs
        \\    .server = .{
        \\        .host = "localhost",
        \\        .port = 8080,
        \\        .tls = .{ .cert = "c.pem" },
        \\    },
        \\    .tags = .{ "a", "b" },
        \\}
        \\
    );
    try expectEdit(.zon, source, .{ .unset = "server.host" },
        \\// Service.
        \\.{
        \\    .name = "demo", // shown in logs
        \\    .server = .{
        \\        .port = 8080,
        \\    },
        \\    .tags = .{ "a", "b" },
        \\}
        \\
    );
    const added = ".{ .a = 1, .b = true }\n";
    try expectEdit(.zon, ".{ .a = 1 }\n", setTo("b", .{ .bool = true }), added);
    try expectEdit(.zon, ".{ .a = 1, .b = 2 }\n", .{ .unset = "a" }, ".{ .b = 2 }\n");
    try expectEdit(.zon, ".{}\n", setTo("a", .{ .int = 1 }), ".{ .a = 1 }\n");
    try expectEdit(.zon, ".{ .@\"a b\" = 1 }", setTo("a b", .{ .int = 2 }), ".{ .@\"a b\" = 2 }");
}

test "JSON: change, add, and remove, keeping layout" {
    const source =
        \\{
        \\  "name": "demo",
        \\  "server": {"host": "a", "port": 1},
        \\  "tags": [{"x": 1}]
        \\}
        \\
    ;
    try expectEdit(.json, source, setTo("server.port", .{ .int = 2 }),
        \\{
        \\  "name": "demo",
        \\  "server": {"host": "a", "port": 2},
        \\  "tags": [{"x": 1}]
        \\}
        \\
    );
    try expectEdit(.json, source, setTo("debug", .{ .bool = true }),
        \\{
        \\  "name": "demo",
        \\  "server": {"host": "a", "port": 1},
        \\  "tags": [{"x": 1}],
        \\  "debug": true
        \\}
        \\
    );
    try expectEdit(.json, source, setTo("server.tls.on", .{ .bool = true }),
        \\{
        \\  "name": "demo",
        \\  "server": {"host": "a", "port": 1, "tls": {"on": true}},
        \\  "tags": [{"x": 1}]
        \\}
        \\
    );
    try expectEdit(.json, source, .{ .unset = "tags" },
        \\{
        \\  "name": "demo",
        \\  "server": {"host": "a", "port": 1}
        \\}
        \\
    );
    try expectEdit(.json, source, .{ .unset = "server.port" },
        \\{
        \\  "name": "demo",
        \\  "server": {"host": "a"},
        \\  "tags": [{"x": 1}]
        \\}
        \\
    );
    try expectEdit(.json, source, .{ .unset = "name" },
        \\{
        \\  "server": {"host": "a", "port": 1},
        \\  "tags": [{"x": 1}]
        \\}
        \\
    );
    try expectEdit(.json, "{}", setTo("a", .{ .int = 1 }), "{\"a\": 1}");
    try expectEdit(.json, "{\"a\": 1}", .{ .unset = "a" }, "{}");
    try expectEdit(
        .json,
        "{\"a\": 1, \"a\": 2}",
        setTo("a", .{ .int = 3 }),
        "{\"a\": 1, \"a\": 3}",
    );
    // Inside an array, or below a scalar, is not done in place.
    try expectEdit(.json, source, setTo("tags.0.x", .{ .int = 2 }), null);
    try expectEdit(.json, "[1]", setTo("a", .{ .int = 1 }), null);
}

test "JSON with comments: comments and trailing commas stay" {
    const source =
        \\// Settings.
        \\{
        \\  "a": 1, // one
        \\  /* two */ "b": 2,
        \\}
        \\
    ;
    try expectEdit(.jsonc, source, setTo("b", .{ .int = 3 }),
        \\// Settings.
        \\{
        \\  "a": 1, // one
        \\  /* two */ "b": 3,
        \\}
        \\
    );
    try expectEdit(.jsonc, source, setTo("c", .{ .string = "x" }),
        \\// Settings.
        \\{
        \\  "a": 1, // one
        \\  /* two */ "b": 2,
        \\  "c": "x",
        \\}
        \\
    );
    try expectEdit(.jsonc, source, .{ .unset = "a" },
        \\// Settings.
        \\{
        \\  /* two */ "b": 2,
        \\}
        \\
    );
    const no_trailing =
        \\{
        \\  "a": 1 // one
        \\}
        \\
    ;
    try expectEdit(.jsonc, "{\n  \"a\": 1,\n  \"b\": 2 // two\n}\n", .{ .unset = "b" },
        \\{
        \\  "a": 1
        \\}
        \\
    );
    try expectEdit(.jsonc, no_trailing, setTo("b", .{ .int = 2 }),
        \\{
        \\  "a": 1, // one
        \\  "b": 2
        \\}
        \\
    );
}

test "INI: change, add, and remove, keeping comments" {
    const source =
        \\; Service.
        \\name = demo
        \\
        \\[server]
        \\host = a   ; the host
        \\port: 1
        \\
        \\[server.tls]
        \\cert = c.pem
        \\
    ;
    try expectEdit(.ini, source, setTo("server.host", .{ .string = "b;c" }),
        \\; Service.
        \\name = demo
        \\
        \\[server]
        \\host = "b;c"   ; the host
        \\port: 1
        \\
        \\[server.tls]
        \\cert = c.pem
        \\
    );
    try expectEdit(.ini, source, setTo("server.workers", .{ .int = 4 }),
        \\; Service.
        \\name = demo
        \\
        \\[server]
        \\host = a   ; the host
        \\port: 1
        \\workers = 4
        \\
        \\[server.tls]
        \\cert = c.pem
        \\
    );
    try expectEdit(.ini, source, setTo("debug", .{ .bool = true }),
        \\; Service.
        \\name = demo
        \\debug = true
        \\
        \\[server]
        \\host = a   ; the host
        \\port: 1
        \\
        \\[server.tls]
        \\cert = c.pem
        \\
    );
    try expectEdit(.ini, source, setTo("log.level", .{ .string = "info" }), source ++
        \\
        \\[log]
        \\level = info
        \\
    );
    try expectEdit(.ini, source, .{ .unset = "server.tls" },
        \\; Service.
        \\name = demo
        \\
        \\[server]
        \\host = a   ; the host
        \\port: 1
        \\
    );
    try expectEdit(.ini, source, .{ .unset = "server.port" },
        \\; Service.
        \\name = demo
        \\
        \\[server]
        \\host = a   ; the host
        \\
        \\[server.tls]
        \\cert = c.pem
        \\
    );
    try expectEdit(.ini, "[a]\n", setTo("b", .{ .int = 1 }), "b = 1\n\n[a]\n");
    try expectEdit(.ini, "a = 1\n", setTo("b", .empty_table), null);
}

const yaml_source =
    \\# Service.
    \\name: demo # shown in logs
    \\
    \\server:
    \\  # Where to listen.
    \\  host: localhost
    \\  port: 8080
    \\
    \\# Upstreams.
    \\upstreams:
    \\  - url: http://a
    \\    weight: 1
    \\  - url: http://b
    \\
;

test "YAML: change, add, and remove, keeping comments" {
    try expectEdit(.yaml, yaml_source, setTo("server.port", .{ .int = 9090 }),
        \\# Service.
        \\name: demo # shown in logs
        \\
        \\server:
        \\  # Where to listen.
        \\  host: localhost
        \\  port: 9090
        \\
        \\# Upstreams.
        \\upstreams:
        \\  - url: http://a
        \\    weight: 1
        \\  - url: http://b
        \\
    );
    try expectEdit(.yaml, yaml_source, setTo("server.tls.cert", .{ .string = "c.pem" }),
        \\# Service.
        \\name: demo # shown in logs
        \\
        \\server:
        \\  # Where to listen.
        \\  host: localhost
        \\  port: 8080
        \\  tls:
        \\    cert: c.pem
        \\
        \\# Upstreams.
        \\upstreams:
        \\  - url: http://a
        \\    weight: 1
        \\  - url: http://b
        \\
    );
    try expectEdit(.yaml, yaml_source, setTo("upstreams.1.weight", .{ .int = 2 }),
        \\# Service.
        \\name: demo # shown in logs
        \\
        \\server:
        \\  # Where to listen.
        \\  host: localhost
        \\  port: 8080
        \\
        \\# Upstreams.
        \\upstreams:
        \\  - url: http://a
        \\    weight: 1
        \\  - url: http://b
        \\    weight: 2
        \\
    );
    try expectEdit(.yaml, yaml_source, .{ .unset = "server" },
        \\# Service.
        \\name: demo # shown in logs
        \\
        \\# Upstreams.
        \\upstreams:
        \\  - url: http://a
        \\    weight: 1
        \\  - url: http://b
        \\
    );
    try expectEdit(.yaml, "a: 1", setTo("b", .{ .string = "two words" }), "a: 1\nb: two words\n");
    try expectEdit(.yaml, "", setTo("a.b", .{ .bool = true }), "a:\n  b: true\n");
    // A block value cannot be replaced in place: the caller rewrites the file.
    try expectEdit(.yaml, "a:\n  b: 1\n", setTo("a", .{ .int = 2 }), null);
    try expectEdit(.yaml, "t: |\n  text\n", setTo("t", .{ .int = 2 }), null);
}

fn expectReformat(format: Format, source: []const u8, expected: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const formatted = try reformat(arena.allocator(), format, source);
    if (expected) |text| {
        try testing.expectEqualStrings(text, formatted orelse return error.TestExpectedFormat);
    } else {
        try testing.expectEqual(null, formatted);
    }
}

test "reformat TOML keeps comments" {
    try expectReformat(.toml,
        \\
        \\
        \\# Service.
        \\name='demo'   # shown in logs
        \\   port=0x1F
        \\
        \\
        \\
        \\[ server ]
        \\  # Where.
        \\  host   =   "h"
        \\tls . cert = "c"
        \\[[ upstream ]]
        \\url="a"
        \\[[upstream]]
        \\url="b"
        \\
    ,
        \\# Service.
        \\name = "demo" # shown in logs
        \\port = 31
        \\
        \\[server]
        \\# Where.
        \\host = "h"
        \\tls.cert = "c"
        \\
        \\[[upstream]]
        \\url = "a"
        \\
        \\[[upstream]]
        \\url = "b"
        \\
    );
    // A comment inside a multi-line array has nowhere to go.
    try expectReformat(.toml, "a = [\n  1, # one\n  2,\n]\n", null);
}

test "reformat TOML keeps a comment directly above a table there" {
    try expectReformat(.toml, "a = 1\n# The table.\n[t]\nx = 1\n# Apart.\n\n[u]\n",
        \\a = 1
        \\
        \\# The table.
        \\[t]
        \\x = 1
        \\# Apart.
        \\
        \\[u]
        \\
    );
}

fn expectSort(source: []const u8, expected: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sorted = try sort(arena.allocator(), .toml, source);
    if (expected) |text| {
        try testing.expectEqualStrings(text, sorted orelse return error.TestExpectedSort);
    } else {
        try testing.expectEqual(null, sorted);
    }
}

test "sort TOML keeps comments with their keys and tables" {
    try expectSort(
        \\# The file.
        \\
        \\zeta = 1 # last
        \\# About alpha.
        \\alpha = { y = 1, x = 2 }
        \\
        \\# A group of its own.
        \\b = 2
        \\a = 1
        \\
        \\# Upstreams.
        \\[[upstream]]
        \\url = "b"
        \\
        \\[[upstream]]
        \\url = "a"
        \\
        \\[server]
        \\port = 1
        \\# The host.
        \\host = "h"
        \\
    ,
        \\# The file.
        \\
        \\# About alpha.
        \\alpha = { x = 2, y = 1 }
        \\zeta = 1 # last
        \\
        \\# A group of its own.
        \\a = 1
        \\b = 2
        \\
        \\[server]
        \\# The host.
        \\host = "h"
        \\port = 1
        \\
        \\# Upstreams.
        \\[[upstream]]
        \\url = "b"
        \\
        \\[[upstream]]
        \\url = "a"
        \\
    );
    // Arrays of tables keep their order, ten after two.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..11) |i| try source.print(testing.allocator, "[[a]]\nn = {d}\n\n", .{i});
    source.items.len -= 1;
    try expectSort(source.items, source.items);
    try expectSort("b = 1\na = [\n  1, # one\n]\n", null);
}

test "reformat ZON is zig fmt" {
    try expectReformat(.zon, ".{ // note\n.a=1,\n    .b = .{1,2},}\n",
        \\.{ // note
        \\    .a = 1,
        \\    .b = .{ 1, 2 },
        \\}
        \\
    );
}

test "reformat YAML keeps comments beside their entries" {
    try expectReformat(.yaml,
        \\---
        \\# The service.
        \\name:   demo   # its name
        \\
        \\
        \\server:     # where it listens
        \\    # The host.
        \\    host: 'a'
        \\    port: 1
        \\tags:
        \\    - x
        \\    - "y"
        \\servers:
        \\  - name: one  # first
        \\    # Its port.
        \\    port: 2
        \\# The end.
        \\
    ,
        \\---
        \\# The service.
        \\name: demo # its name
        \\
        \\server: # where it listens
        \\  # The host.
        \\  host: a
        \\  port: 1
        \\tags:
        \\  - x
        \\  - y
        \\servers:
        \\  - name: one # first
        \\    # Its port.
        \\    port: 2
        \\# The end.
        \\
    );
    // A block scalar's lines are its value, even one that starts with `#`.
    try expectReformat(
        .yaml,
        "text: |  # kept\n  # not a comment\n  line\nnext: 1\n",
        "text: \"# not a comment\\nline\\n\" # kept\nnext: 1\n",
    );
    // Sequence items keep the comments before and after them.
    try expectReformat(
        .yaml,
        "list:\n  # first\n  - a   # one\n  - 'b c' # two\n  - - -4\n",
        "list:\n  # first\n  - a # one\n  - b c # two\n  - - -4\n",
    );
    // What cannot keep its comments in place is declined.
    try expectReformat(.yaml, "list: [a, b] # flow\nmore:\n  - x # item\n", null);
    try expectReformat(.yaml, "list:\n  - |\n    text\n", null);
    try expectReformat(.yaml, "flow: [a,\n  b]\n", null);
    try expectReformat(.yaml, "# only a comment\n", null);
    // Found by the fuzzer: a negative number in a sequence is a scalar, not an indicator.
    try expectReformat(.yaml, "counts: [3, -4]\n", "counts:\n  - 3\n  - -4\n");
    try expectReformat(.yaml, "\"a\\\"b\": # c\n  - 1\n", "a\"b: # c\n  - 1\n");
}

test "reformat dotenv keeps comments and values" {
    try expectReformat(.dotenv, "\n# db\n  DB__HOST = h # local\n\n\n\nexport  A=${DB__HOST}\n",
        \\# db
        \\DB__HOST=h # local
        \\
        \\export A=${DB__HOST}
        \\
    );
}
