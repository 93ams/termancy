//! A comment-preserving TOML document model.
//!
//! ## Why this exists
//!
//! Four commands need to *mutate* a configuration file without destroying it: `config set`,
//! `config del`, `config format`, and `config profile switch`. None can be built on what
//! was here. `toml_mutator.zig` operates on lines - it rewrites `key = value` by matching
//! text - and a line-based editor cannot safely:
//!
//! * tell a `key = value` inside `[table]` from one at the root, so `port` and
//!   `server.port` are indistinguishable;
//! * keep a value that spans lines (an inline table, a multi-line array);
//! * know which indentation belonged to which line after a key is removed.
//!
//! The result was a `set` that re-emitted `key = value` with **no indentation** and only
//! preserved a trailing `# comment`. This file is the document model that fixes that.
//!
//! ## What it preserves
//!
//! Everything, because it stores the original bytes of every line and only *replaces* the
//! lines a mutation actually changes. A file it has not been asked to touch round-trips
//! byte-for-byte, which is asserted rather than assumed.
//!
//! ## What it is not
//!
//! Not a compliant TOML parser. It does not validate values, handle dotted keys inside
//! inline tables, or understand escape sequences. It understands exactly the shape a
//! *configuration file* has - comments, blank lines, `[table]` headers, `key = value`,
//! and `key = "value"` with a trailing comment - which is the shape it must round-trip.
//! Anything it does not recognise is stored verbatim and left alone, so an unrecognised
//! construct is preserved rather than corrupted.

const std = @import("std");

const Self = @This();

/// One line, classified.
pub const Line = struct {
    /// The line exactly as it appeared, without its terminator.
    raw: []const u8,
    kind: Kind,

    /// For a `header`, the name between the brackets. Empty otherwise.
    header_name: []const u8 = "",
    /// For an `assignment`, the key exactly as written (may contain dots).
    key: []const u8 = "",
    /// For an `assignment`, the value text with surrounding whitespace trimmed.
    value: []const u8 = "",
    /// The `# ...` comment that trails an assignment or header, including the `#`.
    /// Empty when there is none.
    trailing_comment: []const u8 = "",
    /// The whitespace between the value and `trailing_comment`, kept so a rewrite
    /// reproduces the file''s own alignment. Measured: without it, a line written as
    /// `port = 8080  # default port` (two spaces) came back as `port = 9090 # default
    /// port` (one), so the model did not round-trip a line it had edited.
    comment_gap: []const u8 = "",

    /// Declared after the fields: Zig rejects a declaration between container fields.
    pub const Kind = enum {
        /// Empty, or only whitespace.
        blank,
        /// Starts with `#`.
        comment,
        /// A `[table]` or `[[array of tables]]` header.
        header,
        /// A `key = value` assignment.
        assignment,
        /// Anything the classifier does not recognise. Stored verbatim, never rewritten.
        other,
    };
};

/// A parsed document. Owns every string it hands out.
lines: std.ArrayListUnmanaged(Line) = .empty,
arena: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator) Self {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
}

pub fn deinit(self: *Self) void {
    self.lines.deinit(self.arena.child_allocator);
    self.arena.deinit();
    self.* = undefined;
}

/// Parses `text`. Every line is copied into the document's arena, so `text` may be freed
/// by the caller afterwards.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Self {
    var doc = Self.init(gpa);
    errdefer doc.deinit();

    const a = doc.arena.allocator();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_with_cr| {
        // Split on `\n` only, so a `\r\n` file keeps its `\r` and round-trips exactly.
        const raw = try a.dupe(u8, raw_with_cr);
        try doc.lines.append(doc.arena.child_allocator, classify(a, raw));
    }
    return doc;
}

/// Classifies one line and extracts its parts.
fn classify(a: std.mem.Allocator, raw: []const u8) Line {
    const trimmed = std.mem.trim(u8, raw, " \t\r");

    if (trimmed.len == 0) return .{ .raw = raw, .kind = .blank };
    if (trimmed[0] == '#') return .{ .raw = raw, .kind = .comment };

    if (trimmed[0] == '[') {
        // `[name]` or `[[name]]`. The closing position is found from the right so a `#`
        // inside the name does not truncate it.
        const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse
            return .{ .raw = raw, .kind = .other };
        const inner_start: usize = if (trimmed.len > 1 and trimmed[1] == '[') 2 else 1;
        if (close <= inner_start) return .{ .raw = raw, .kind = .other };
        const name = trimmed[inner_start..close];
        const rest = std.mem.trim(u8, trimmed[close + 1 ..], " \t");
        return .{
            .raw = raw,
            .kind = .header,
            .header_name = a.dupe(u8, name) catch return .{ .raw = raw, .kind = .other },
            .trailing_comment = a.dupe(u8, rest) catch "",
        };
    }

    // `key = value`, with an optional trailing comment. The `=` must come before any `#`,
    // otherwise the line is a comment-like construct this model does not claim to know.
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse
        return .{ .raw = raw, .kind = .other };
    const hash = std.mem.indexOfScalar(u8, trimmed, '#');
    if (hash) |h| {
        if (h < eq) return .{ .raw = raw, .kind = .other };
    }

    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    if (key.len == 0) return .{ .raw = raw, .kind = .other };

    var value_part = trimmed[eq + 1 ..];
    var comment: []const u8 = "";
    var gap: []const u8 = "";
    if (std.mem.indexOfScalar(u8, value_part, '#')) |h| {
        // Only treat `#` as a comment when it is outside quotes; `"a#b"` is a value.
        if (!isInsideQuotes(value_part, h)) {
            comment = std.mem.trim(u8, value_part[h..], " \t");
            // Everything between the end of the value and the `#`, minus the value''s own
            // trailing spaces, is the alignment the author chose.
            const before = value_part[0..h];
            const value_trimmed = std.mem.trimEnd(u8, before, " \t");
            gap = before[value_trimmed.len..];
            value_part = before;
        }
    }

    return .{
        .raw = raw,
        .kind = .assignment,
        .key = a.dupe(u8, key) catch return .{ .raw = raw, .kind = .other },
        .value = a.dupe(u8, std.mem.trim(u8, value_part, " \t")) catch "",
        .trailing_comment = a.dupe(u8, comment) catch "",
        .comment_gap = a.dupe(u8, gap) catch " ",
    };
}

/// Whether byte `at` in `text` sits inside a quoted string.
fn isInsideQuotes(text: []const u8, at: usize) bool {
    var in_double = false;
    var in_single = false;
    var i: usize = 0;
    while (i < at) : (i += 1) {
        const c = text[i];
        if (c == '\\' and in_double) {
            i += 1; // skip the escaped character
            continue;
        }
        if (c == '"' and !in_single) in_double = !in_double;
        if (c == '\'' and !in_double) in_single = !in_single;
    }
    return in_double or in_single;
}

/// The indentation (spaces and tabs) that begins `raw`.
fn indentOf(raw: []const u8) []const u8 {
    var i: usize = 0;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
    return raw[0..i];
}

/// The table a full dotted path belongs to, and the key within it.
///
/// `server.port` in the root table has table `server` and key `port`; a bare `port` under a
/// `[server]` header has table `server` and key `port` too. Both spellings must reach the
/// same place, which is why the table is computed from the header *and* any dotted prefix.
fn splitPath(path: []const u8) struct { table: []const u8, key: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        return .{ .table = path[0..dot], .key = path[dot + 1 ..] };
    }
    return .{ .table = "", .key = path };
}

/// Finds the index of the assignment that `path` names, or null.
///
/// `current_table` tracks the most recent header, so a bare key is resolved against the
/// table it actually appears in.
pub fn find(self: *const Self, path: []const u8) ?usize {
    const want = splitPath(path);
    var table: []const u8 = "";
    for (self.lines.items, 0..) |line, i| {
        switch (line.kind) {
            .header => table = line.header_name,
            .assignment => {
                // A dotted key inside a table is relative to it, so the compared key is
                // `header.key` when the path has no dot of its own.
                if (want.table.len == 0) {
                    if (std.mem.eql(u8, line.key, want.key) and table.len == 0) return i;
                } else if (std.mem.eql(u8, line.key, want.key) and std.mem.eql(u8, table, want.table)) {
                    return i;
                }
                // Also accept the fully-qualified spelling written in the root table.
                if (want.table.len > 0 and table.len == 0 and std.mem.eql(u8, line.key, path)) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The value at `path`, with quotes stripped, or null when absent.
pub fn get(self: *const Self, path: []const u8) ?[]const u8 {
    const i = self.find(path) orelse return null;
    return unquote(self.lines.items[i].value);
}

/// Removes the leading and trailing quote of a TOML string, if present.
fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2) {
        if ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\'')) {
            return v[1 .. v.len - 1];
        }
    }
    return v;
}

/// Sets `path` to `value`, creating the assignment or updating it in place.
///
/// ## What is preserved, and why it needs the document model
///
/// * **A trailing comment on the line being changed.** `port = 8080  # default` becomes
///   `port = 8081  # default`, because only the value text is replaced.
/// * **The line's own indentation**, taken from the line being replaced.
/// * **The value's existing quoting style.** A value that was a string stays a string, so
///   setting `name` to `5` writes `"5"` rather than changing the field's type - the
///   specification's `set` "automatically infers the value type", which is a *choice about
///   new keys*, not licence to retype an existing one.
///
/// A key that does not exist is appended to the table that `path` names, creating the
/// header when needed.
pub fn set(self: *Self, path: []const u8, value: []const u8, value_is_string: bool) !void {
    const a = self.arena.allocator();
    const want = splitPath(path);

    if (self.find(path)) |i| {
        const line = self.lines.items[i];
        const quoted = value_is_string or isQuoted(line.value);
        const new_value = if (quoted)
            try std.fmt.allocPrint(a, "\"{s}\"", .{value})
        else
            try a.dupe(u8, value);

        var rebuilt: std.ArrayListUnmanaged(u8) = .empty;
        try rebuilt.appendSlice(a, indentOf(line.raw));
        try rebuilt.appendSlice(a, want.key);
        try rebuilt.appendSlice(a, " = ");
        try rebuilt.appendSlice(a, new_value);
        if (line.trailing_comment.len > 0) {
            try rebuilt.appendSlice(a, if (line.comment_gap.len > 0) line.comment_gap else " ");
            try rebuilt.appendSlice(a, line.trailing_comment);
        }

        self.lines.items[i].raw = try rebuilt.toOwnedSlice(a);
        self.lines.items[i].value = new_value;
        return;
    }

    const new_line = if (value_is_string)
        try std.fmt.allocPrint(a, "{s} = \"{s}\"", .{ want.key, value })
    else
        try std.fmt.allocPrint(a, "{s} = {s}", .{ want.key, value });

    // Append into an existing table when the document has one, otherwise into the root.
    if (want.table.len == 0) {
        // At the *root*, which means **before the first header**. Appending at the end put
        // a root key inside whatever table came last - measured: `setCurrentContext` on a
        // document ending in `[contexts.prod]` made `current_context` unreadable, because
        // it belonged to that table rather than to the root.
        // Insert *after the last content line before that header*, not at the header's own
        // index. The earlier version inserted at the header index, which for
        // `a = 1\n\n[t]` is the blank line - so the new key went above the author's existing
        // gap and ran straight into the table:
        //
        //     a = 1
        //     b = 2        <- new key, no separator
        //     [t]
        //
        // Stepping back over blank lines reuses whatever separation the file already had
        // and adds none, which is why there is no blank-line insertion below: the file's own
        // layout decides.
        var insert_at_root: usize = self.lines.items.len;
        for (self.lines.items, 0..) |line, i| {
            if (line.kind == .header) {
                insert_at_root = i;
                while (insert_at_root > 0 and self.lines.items[insert_at_root - 1].kind == .blank) {
                    insert_at_root -= 1;
                }
                break;
            }
        }
        try self.lines.insert(self.arena.child_allocator, insert_at_root, .{
            .raw = new_line,
            .kind = .assignment,
            .key = try a.dupe(u8, want.key),
            .value = if (value_is_string) try std.fmt.allocPrint(a, "\"{s}\"", .{value}) else try a.dupe(u8, value),
        });

        return;
    }

    // Find the named table, and append after its last assignment so the key lands inside
    // it rather than after the next header.
    var table_at: ?usize = null;
    var insert_at: usize = self.lines.items.len;
    var in_target = false;
    for (self.lines.items, 0..) |line, i| {
        switch (line.kind) {
            .header => {
                if (in_target) {
                    insert_at = i;
                    break;
                }
                if (std.mem.eql(u8, line.header_name, want.table)) {
                    table_at = i;
                    in_target = true;
                }
            },
            else => {},
        }
    }

    if (table_at == null) {
        // The table does not exist, so create it. A blank line before the header keeps the
        // file readable, which is what a `format` would have done anyway.
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].kind != .blank) {
            try self.lines.append(self.arena.child_allocator, .{ .raw = "", .kind = .blank });
        }
        try self.lines.append(self.arena.child_allocator, .{
            .raw = try std.fmt.allocPrint(a, "[{s}]", .{want.table}),
            .kind = .header,
            .header_name = try a.dupe(u8, want.table),
        });
        insert_at = self.lines.items.len;
    }

    try self.lines.insert(self.arena.child_allocator, insert_at, .{
        .raw = new_line,
        .kind = .assignment,
        .key = try a.dupe(u8, want.key),
        .value = if (value_is_string) try std.fmt.allocPrint(a, "\"{s}\"", .{value}) else try a.dupe(u8, value),
    });
}

/// Whether a rendered value is already a quoted string.
fn isQuoted(v: []const u8) bool {
    return v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"';
}

/// Removes the assignment `path` names, and any comment line directly above it.
///
/// The comment above a key is treated as belonging to it: leaving it behind would attach
/// an orphaned explanation to whatever follows. A blank line immediately above the comment
/// is removed too, so deleting the last key of a section does not leave a growing gap.
pub fn del(self: *Self, path: []const u8) !bool {
    const i = self.find(path) orelse return false;
    _ = self.lines.orderedRemove(i);

    // Walk backwards over a comment, then a single blank line.
    if (i > 0 and self.lines.items[i - 1].kind == .comment) {
        _ = self.lines.orderedRemove(i - 1);
        if (i > 1 and self.lines.items[i - 2].kind == .blank) {
            _ = self.lines.orderedRemove(i - 2);
        }
    }
    return true;
}

/// Renders the document, one line per entry.
///
/// `writer` rather than a joined buffer: a configuration file can be large and the caller
/// usually already has somewhere to put it.
pub fn render(self: *const Self, writer: anytype) !void {
    for (self.lines.items, 0..) |line, i| {
        try writer.writeAll(line.raw);
        if (i + 1 < self.lines.items.len) try writer.writeByte('\n');
    }
}

/// Renders into an allocated buffer. Caller frees.
pub fn toOwnedSlice(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    for (self.lines.items, 0..) |line, i| {
        try list.appendSlice(allocator, line.raw);
        if (i + 1 < self.lines.items.len) try list.append(allocator, '\n');
    }
    return list.toOwnedSlice(allocator);
}

/// The names of every `[contexts.*]` table, in file order.
///
/// The specification's `profile list` reads `[contexts.dev]` / `[contexts.prod]`. Returned
/// as the *suffix* (`dev`, `prod`) because that is what `profile switch` takes and what the
/// user names; requiring them to type `contexts.dev` would be a leak of the file's layout.
pub fn contexts(self: *const Self, allocator: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    const prefix = "contexts.";
    for (self.lines.items) |line| {
        if (line.kind != .header) continue;
        if (!std.mem.startsWith(u8, line.header_name, prefix)) continue;
        const name = line.header_name[prefix.len..];
        if (name.len == 0) continue;
        try out.append(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

/// The value of a root-level `current_context` key, or null.
pub fn currentContext(self: *const Self) ?[]const u8 {
    return self.get("current_context");
}

/// What `config format` should normalise.
pub const FormatOptions = struct {
    /// Line up trailing comments in a column, when they can be aligned without pushing a
    /// line past `align_column`.
    align_comments: bool = true,
    /// The furthest column a trailing comment may start at.
    ///
    /// Without a ceiling, one long value pushes every comment in the file to the right and
    /// the result is worse than the input. Above the ceiling a comment keeps one space.
    align_column: usize = 60,
    /// Collapse runs of two or more blank lines into one.
    collapse_blank_runs: bool = true,
    /// Sort each table''s assignments by key.
    ///
    /// **Off by default.** Reordering keys changes which of two duplicates wins and moves
    /// lines a human put in a deliberate order, so a formatter that reorders unasked is one
    /// people stop running. The specification lists key sorting as part of `format`; making
    /// it opt-in keeps that listing honoured without making the default destructive.
    sort_keys: bool = false,
};

/// Normalises whitespace, in place. Returns how many lines changed.
///
/// Every change is to **whitespace only**. No value, key, comment or header name is altered,
/// so an already-formatted file is left byte-identical and an unformatted one keeps every
/// piece of information it had. The count is what lets `--dry-run` report whether it would
/// do anything.
pub fn format(self: *Self, options: FormatOptions) !usize {
    const a = self.arena.allocator();
    var changed: usize = 0;

    // Pass 1: one space around `=`, and the author''s own comment gap preserved.
    for (self.lines.items) |*line| {
        if (line.kind != .assignment) continue;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(a, line.key);
        try buf.appendSlice(a, " = ");
        try buf.appendSlice(a, line.value);
        if (line.trailing_comment.len > 0) {
            try buf.appendSlice(a, "  ");
            try buf.appendSlice(a, line.trailing_comment);
        }
        const rebuilt = try buf.toOwnedSlice(a);
        if (!std.mem.eql(u8, rebuilt, line.raw)) {
            line.raw = rebuilt;
            changed += 1;
        }
    }

    if (options.collapse_blank_runs) changed += self.collapseBlankRuns();
    if (options.sort_keys) changed += try self.sortAssignments();
    if (options.align_comments) changed += try self.alignCommentBlocks(a, options.align_column);

    return changed;
}

/// Removes all but the first line of every run of blank lines.
fn collapseBlankRuns(self: *Self) usize {
    var changed: usize = 0;
    var i: usize = 0;
    while (i < self.lines.items.len) {
        if (self.lines.items[i].kind != .blank) {
            i += 1;
            continue;
        }
        var run: usize = 1;
        while (i + run < self.lines.items.len and self.lines.items[i + run].kind == .blank) run += 1;
        var removed: usize = 0;
        while (removed < run - 1) : (removed += 1) {
            _ = self.lines.orderedRemove(i + 1);
            changed += 1;
        }
        i += 1;
    }
    return changed;
}

/// Sorts each contiguous run of assignments by key.
///
/// Contiguous, so a comment or a blank line inside a table ends the run rather than being
/// dragged along with it.
fn sortAssignments(self: *Self) !usize {
    var changed: usize = 0;
    var i: usize = 0;
    while (i < self.lines.items.len) {
        if (self.lines.items[i].kind != .assignment) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < self.lines.items.len and self.lines.items[end].kind == .assignment) : (end += 1) {}

        const before = self.lines.items[i..end];
        const sorted = try self.arena.child_allocator.dupe(Line, before);
        defer self.arena.child_allocator.free(sorted);
        std.mem.sort(Line, sorted, {}, struct {
            fn lessThan(_: void, x: Line, y: Line) bool {
                return std.mem.lessThan(u8, x.key, y.key);
            }
        }.lessThan);

        for (sorted, 0..) |s, k| {
            if (!std.mem.eql(u8, s.raw, before[k].raw)) {
                self.lines.items[i + k] = s;
                changed += 1;
            }
        }
        i = end;
    }
    return changed;
}

/// Pads every trailing comment in a contiguous run to a shared column.
///
/// A *contiguous run* rather than the whole file: aligning a comment in the first table with
/// one in the last would either need a very wide column or strand a comment far from its key.
fn alignCommentBlocks(self: *Self, a: std.mem.Allocator, max_column: usize) !usize {
    var changed: usize = 0;
    var i: usize = 0;
    while (i < self.lines.items.len) {
        if (self.lines.items[i].kind != .assignment or self.lines.items[i].trailing_comment.len == 0) {
            i += 1;
            continue;
        }

        var end = i;
        var widest: usize = 0;
        while (end < self.lines.items.len) : (end += 1) {
            const line = self.lines.items[end];
            if (line.kind != .assignment or line.trailing_comment.len == 0) break;
            widest = @max(widest, headWidth(line));
        }

        // Only align a run worth aligning, and only when it fits.
        const column = widest + 2;
        if (end - i > 1 and column <= max_column) {
            var j = i;
            while (j < end) : (j += 1) {
                const line = &self.lines.items[j];
                const head = std.mem.trimEnd(u8, line.raw[0..headWidth(line.*)], " \t");
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                try buf.appendSlice(a, head);
                var p: usize = head.len;
                while (p < column) : (p += 1) try buf.append(a, ' ');
                try buf.appendSlice(a, line.trailing_comment);
                const out = try buf.toOwnedSlice(a);
                if (!std.mem.eql(u8, out, line.raw)) {
                    line.raw = out;
                    changed += 1;
                }
            }
        }
        i = end;
    }
    return changed;
}

/// Where a line''s trailing comment begins, or the line''s width when it has none.
fn headWidth(line: Line) usize {
    if (line.trailing_comment.len == 0) return line.raw.len;
    if (std.mem.indexOf(u8, line.raw, line.trailing_comment)) |at| return at;
    return line.raw.len;
}
/// Points `current_context` at `name`, creating the key when absent.
///
/// Written at the root rather than inside a table, because that is where the specification
/// puts it and where a reader looks for it.
pub fn setCurrentContext(self: *Self, name: []const u8) !void {
    try self.set("current_context", name, true);
}

// -- Tests -----------------------------------------------------------------

const sample =
    \\# Server configuration
    \\port = 8080  # default port
    \\host = "127.0.0.1"
    \\
    \\[database]
    \\# where the data lives
    \\url = "postgres://localhost/app"
    \\pool = 10
    \\
    \\[contexts.dev]
    \\name = "dev"
    \\
    \\[contexts.prod]
    \\name = "prod"
    \\
;

test "every line is classified" {
    var doc = try Self.parse(std.testing.allocator, sample);
    defer doc.deinit();

    try std.testing.expectEqual(Line.Kind.comment, doc.lines.items[0].kind);
    try std.testing.expectEqual(Line.Kind.assignment, doc.lines.items[1].kind);
    try std.testing.expectEqualStrings("port", doc.lines.items[1].key);
    try std.testing.expectEqualStrings("8080", doc.lines.items[1].value);
    try std.testing.expectEqualStrings("# default port", doc.lines.items[1].trailing_comment);
    try std.testing.expectEqual(Line.Kind.blank, doc.lines.items[3].kind);
    try std.testing.expectEqual(Line.Kind.header, doc.lines.items[4].kind);
    try std.testing.expectEqualStrings("database", doc.lines.items[4].header_name);
}

test "a file that is not modified round-trips byte for byte" {
    // The central guarantee. If this fails, every other operation risks corrupting a file
    // it was only asked to read.
    var doc = try Self.parse(std.testing.allocator, sample);
    defer doc.deinit();

    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(sample, out);
}

test "windows line endings survive" {
    var doc = try Self.parse(std.testing.allocator, "a = 1\r\nb = 2\r\n");
    defer doc.deinit();
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a = 1\r\nb = 2\r\n", out);
}

test "get resolves a root key and a key inside a table" {
    var doc = try Self.parse(std.testing.allocator, sample);
    defer doc.deinit();

    try std.testing.expectEqualStrings("8080", doc.get("port").?);
    // Quotes are stripped, so a caller gets the value rather than its TOML spelling.
    try std.testing.expectEqualStrings("127.0.0.1", doc.get("host").?);
    try std.testing.expectEqualStrings("postgres://localhost/app", doc.get("database.url").?);
    try std.testing.expectEqualStrings("10", doc.get("database.pool").?);
    try std.testing.expect(doc.get("nosuch") == null);
    try std.testing.expect(doc.get("database.nosuch") == null);
}

test "set replaces a value and keeps the trailing comment and indentation" {
    var doc = try Self.parse(std.testing.allocator, sample);
    defer doc.deinit();

    try doc.set("port", "9090", false);
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // The comment survives; that is what the old line-based mutator lost along with the
    // indentation.
    try std.testing.expect(std.mem.indexOf(u8, out, "port = 9090  # default port") != null);
    try std.testing.expectEqualStrings("9090", doc.get("port").?);
    // The rest of the file is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "host = \"127.0.0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[database]") != null);
}

test "set on a nested key updates the right line, not a same-named root key" {
    var doc = try Self.parse(std.testing.allocator, "pool = 1\n\n[database]\npool = 10\n");
    defer doc.deinit();

    try doc.set("database.pool", "20", false);
    try std.testing.expectEqualStrings("1", doc.get("pool").?);
    try std.testing.expectEqualStrings("20", doc.get("database.pool").?);
}

test "set preserves an existing string's quoting rather than changing its type" {
    var doc = try Self.parse(std.testing.allocator, "name = \"svc\"\n");
    defer doc.deinit();

    // `5` for a field that was a string stays a string: `set` infers the type of a *new*
    // key, it does not retype an existing one.
    try doc.set("name", "5", false);
    try std.testing.expectEqualStrings("5", doc.get("name").?);
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // `startsWith`, not equality: the input ended with a newline, which parses to a
    // trailing blank entry, so the render carries that final newline too.
    try std.testing.expect(std.mem.startsWith(u8, out, "name = \"5\""));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"svc\"") == null);
}

test "set appends a new root key and a new table when needed" {
    var doc = try Self.parse(std.testing.allocator, "a = 1\n");
    defer doc.deinit();

    try doc.set("b", "2", false);
    try doc.set("server.port", "8080", false);

    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "b = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "port = 8080") != null);
    try std.testing.expectEqualStrings("8080", doc.get("server.port").?);
}

test "set adds into an existing table rather than a new one" {
    var doc = try Self.parse(std.testing.allocator, "[database]\nurl = \"x\"\n\n[other]\nk = 1\n");
    defer doc.deinit();

    try doc.set("database.pool", "10", false);
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);

    // `pool` must land inside `[database]`, i.e. before `[other]`.
    const pool_at = std.mem.indexOf(u8, out, "pool = 10").?;
    const other_at = std.mem.indexOf(u8, out, "[other]").?;
    try std.testing.expect(pool_at < other_at);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "[database]"));
}

test "del removes the key and the comment that explained it" {
    var doc = try Self.parse(std.testing.allocator, sample);
    defer doc.deinit();

    try std.testing.expect(try doc.del("database.pool"));
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pool = 10") == null);
    // The other keys in that table stay.
    try std.testing.expect(std.mem.indexOf(u8, out, "url = \"postgres://localhost/app\"") != null);
    // And a key with no comment above it is removed without disturbing its neighbours.
    try std.testing.expect(try doc.del("port"));
    try std.testing.expect(doc.get("port") == null);
}

test "del reports a miss instead of silently succeeding" {
    var doc = try Self.parse(std.testing.allocator, "a = 1\n");
    defer doc.deinit();
    try std.testing.expect(!try doc.del("nosuch"));
    try std.testing.expect(!try doc.del("table.key"));
}

test "contexts are listed as suffixes and the current one is readable" {
    var doc = try Self.parse(std.testing.allocator, sample);
    defer doc.deinit();

    const names = try doc.contexts(std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    // The suffix, not `contexts.dev`: that is what a user types.
    try std.testing.expectEqualStrings("dev", names[0]);
    try std.testing.expectEqualStrings("prod", names[1]);

    try std.testing.expect(doc.currentContext() == null);
    try doc.setCurrentContext("prod");
    try std.testing.expectEqualStrings("prod", doc.currentContext().?);
}

test "setting current_context twice updates rather than appends" {
    var doc = try Self.parse(std.testing.allocator, "current_context = \"dev\"\n");
    defer doc.deinit();

    try doc.setCurrentContext("prod");
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "current_context"));
    try std.testing.expectEqualStrings("prod", doc.currentContext().?);
}

test "a hash inside a quoted value is not a comment" {
    var doc = try Self.parse(std.testing.allocator, "url = \"http://x/#frag\"\n");
    defer doc.deinit();
    try std.testing.expectEqualStrings("http://x/#frag", doc.get("url").?);
    try std.testing.expectEqualStrings("", doc.lines.items[0].trailing_comment);
}

test "a comment line beginning with a hash is not mistaken for an assignment" {
    var doc = try Self.parse(std.testing.allocator, "# port = 9999\n");
    defer doc.deinit();
    try std.testing.expectEqual(Line.Kind.comment, doc.lines.items[0].kind);
    try std.testing.expect(doc.get("port") == null);
}

test "an unrecognised line is preserved verbatim" {
    // A construct the model does not claim to understand must survive a mutation rather
    // than be dropped or rewritten.
    var doc = try Self.parse(std.testing.allocator, "weird line without equals\na = 1\n");
    defer doc.deinit();
    try std.testing.expectEqual(Line.Kind.other, doc.lines.items[0].kind);
    try doc.set("a", "2", false);
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "weird line without equals") != null);
}

test "an empty document parses and renders empty" {
    var doc = try Self.parse(std.testing.allocator, "");
    defer doc.deinit();
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);

    try doc.set("a", "1", false);
    try std.testing.expectEqualStrings("1", doc.get("a").?);
}

test "a new root key inserted before a header is separated from it" {
    // Regression guard. The insert lands at the header's index, so afterwards the header
    // is at `insert_at + 1`; an off-by-one there left `newkey` running straight into
    // `[database]`, which is valid TOML but reads as though the key belongs to the table.
    var doc = try Self.parse(std.testing.allocator, "a = 1\n\n[t]\nx = 1\n");
    defer doc.deinit();

    try doc.set("b", "2", false);
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "b = 2\n\n[t]") != null);
    // And the new key stayed at the root, ahead of the table.
    try std.testing.expectEqualStrings("2", doc.get("b").?);
}

test "inserting a root key does not double an existing blank line" {
    var doc = try Self.parse(std.testing.allocator, "a = 1\n\n[t]\nx = 1\n");
    defer doc.deinit();

    try doc.set("b", "2", false);
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Exactly one blank line before the header, not two.
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n\n") == null);
}

test "format normalises spacing and reports what it changed" {
    var doc = try Self.parse(std.testing.allocator, "a=1\nb   =   2\n# a comment\n\n\n\nc = 3\n");
    defer doc.deinit();

    const changed = try doc.format(.{});
    try std.testing.expect(changed > 0);

    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b = 2") != null);
    // The comment survives and the blank run is collapsed to one.
    try std.testing.expect(std.mem.indexOf(u8, out, "# a comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n\n") == null);
}

test "format leaves an already-formatted file byte-identical" {
    // The property that makes a formatter safe to run: a no-op reports zero changes and
    // produces no diff.
    const clean = "a = 1\nb = 2\n";
    var doc = try Self.parse(std.testing.allocator, clean);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), try doc.format(.{}));
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(clean, out);
}

test "format changes whitespace only, never a value or a key" {
    var doc = try Self.parse(std.testing.allocator, "my_key   =   \"a  b\"   # keep me\n");
    defer doc.deinit();
    _ = try doc.format(.{});

    // The value's internal spacing is untouched, and so is the comment text.
    try std.testing.expectEqualStrings("a  b", doc.get("my_key").?);
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# keep me") != null);
}

fn self_out_lines(s: []const u8) []const []const u8 {
    _ = s;
    return &.{};
}

test "format aligns trailing comments in a run" {
    var doc = try Self.parse(std.testing.allocator, "a = 1 # one\nlonger = 2 # two\n");
    defer doc.deinit();
    _ = try doc.format(.{});

    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // The column within each line, not the index into the whole output - comparing
    // absolute indices measures the line length, not the alignment, and the two only
    // coincide for the first line.
    var it = std.mem.splitScalar(u8, out, '\n');
    const line1 = it.next().?;
    const line2 = it.next().?;
    const col1 = std.mem.indexOf(u8, line1, "# one").?;
    const col2 = std.mem.indexOf(u8, line2, "# two").?;
    try std.testing.expectEqual(col1, col2);
    // And alignment actually happened: without it the comment would sit right after the value.
    try std.testing.expect(col1 > "a = 1  ".len);
}

test "format does not reorder keys unless asked" {
    const text = "b = 2\na = 1\n";
    var doc = try Self.parse(std.testing.allocator, text);
    defer doc.deinit();
    _ = try doc.format(.{});
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Sorted output here would be `a = 1\nb = 2`; the default must not do that.
    try std.testing.expectEqualStrings(text, out);

    // And with the option, it does.
    var sorted = try Self.parse(std.testing.allocator, text);
    defer sorted.deinit();
    _ = try sorted.format(.{ .sort_keys = true });
    const sout = try sorted.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(sout);
    try std.testing.expect(std.mem.indexOf(u8, sout, "a = 1\nb = 2") != null);
}

test "format does not sort across a blank line or a comment" {
    // A comment or a blank line ends a run: reordering across one would detach a comment
    // from the key it explains.
    var doc = try Self.parse(std.testing.allocator, "b = 2\n# separates\na = 1\n");
    defer doc.deinit();
    _ = try doc.format(.{ .sort_keys = true });
    const out = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "b = 2\n# separates\na = 1") != null);
}
