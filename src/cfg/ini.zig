//! INI <-> `Value`.
//!
//! Reading: `key = value` or `key: value` lines, under `[section]` headers whose names are
//! key paths (`[server.tls]` is the table `tls` in `server`; `["a.b"]` is one key), `;` and
//! `#` comments on their own lines or after a value (following a space), and values either
//! bare (trimmed) or double-quoted with `\"`, `\\`, `\n`, `\t` escapes. Keys before the
//! first header belong to the root. A repeated key keeps its last value. All values are
//! strings, as INI has no types; decoding coerces them.
//!
//! Writing: a table's plain keys, then each sub-table as a section, so the output reads
//! back to the same strings. Arrays of scalars join with `,`, as in dotenv; null leaves are
//! left out. Arrays holding tables or arrays, and keys INI cannot spell, are
//! `error.Unrepresentable`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Diagnostic = @import("Diagnostic.zig");
const path = @import("path.zig");

/// What parsing can fail with; the diagnostic says where.
pub const Error = error{SyntaxError} || Allocator.Error;

/// Parses one INI document into a `.table`. All memory comes from `arena`.
pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diagnostic) Error!Value {
    return parseInto(arena, source, diag, null);
}

/// A section header or a key/value line, for editing in place.
pub const Span = struct {
    kind: Kind,
    /// The section's path; for a key/value line, then its key.
    path: []const []const u8,
    /// The start of the line.
    start: usize,
    /// The next line's start.
    end: usize,
    /// A key/value line's value, quotes included, without a trailing comment.
    value_start: usize = 0,
    value_end: usize = 0,

    /// A section header, or a key/value line.
    pub const Kind = enum { header, entry };
};

/// Parses `source` and returns every header and key/value line in order. Fails as `parse`
/// does.
pub fn spans(arena: Allocator, source: []const u8) Error![]const Span {
    var list: std.ArrayList(Span) = .empty;
    _ = try parseInto(arena, source, null, &list);
    return list.items;
}

fn parseInto(
    arena: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
    list: ?*std.ArrayList(Span),
) Error!Value {
    var root: Value = .empty_table;
    var section: []const []const u8 = &.{};
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| : (offset += raw_line.len + 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        const at = offset + (std.mem.indexOfNone(u8, raw_line, " \t") orelse 0);
        if (line[0] == '[') {
            const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse
                return fail(diag, source, at, "expected ']' after a section name");
            if (std.mem.trim(u8, line[close + 1 ..], " \t").len > 0 and
                !isComment(std.mem.trim(u8, line[close + 1 ..], " \t")))
            {
                return fail(diag, source, at, "unexpected text after a section header");
            }
            const name = std.mem.trim(u8, line[1..close], " \t");
            if (name.len == 0) return fail(diag, source, at, "empty section name");
            section = path.split(arena, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidPath => return fail(diag, source, at, "invalid section name"),
            };
            put(arena, &root, section, null, .empty_table, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotATable => return fail(diag, source, at, "section crosses a value"),
            };
            if (list) |l| try l.append(arena, .{
                .kind = .header,
                .path = section,
                .start = offset,
                .end = @min(offset + raw_line.len + 1, source.len),
            });
            continue;
        }
        const separator = std.mem.indexOfAny(u8, line, "=:") orelse
            return fail(diag, source, at, "expected '=' after a key");
        const key = std.mem.trim(u8, line[0..separator], " \t");
        if (key.len == 0) return fail(diag, source, at, "expected a key");
        const written = std.mem.trim(u8, line[separator + 1 ..], " \t");
        const text = try value(arena, written) orelse
            return fail(diag, source, at, "unterminated or invalid quoted value");
        put(arena, &root, section, key, .{ .string = text }, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotATable => return fail(diag, source, at, "key is also a section"),
        };
        if (list) |l| {
            // `line` and `written` are slices of `source`.
            const value_start = @intFromPtr(written.ptr) - @intFromPtr(source.ptr);
            try l.append(arena, .{
                .kind = .entry,
                .path = try std.mem.concat(arena, []const u8, &.{ section, &.{key} }),
                .start = offset,
                .end = @min(offset + raw_line.len + 1, source.len),
                .value_start = value_start,
                .value_end = value_start + valueLen(written),
            });
        }
    }
    return root;
}

fn fail(diag: ?*Diagnostic, source: []const u8, offset: usize, message: []const u8) Error {
    Diagnostic.report(diag, source, offset, message);
    return error.SyntaxError;
}

fn isComment(text: []const u8) bool {
    return text.len > 0 and (text[0] == ';' or text[0] == '#');
}

/// How much of `text`, which `value` accepts, is the value: a quoted string with its
/// quotes, or bare text up to a comment.
fn valueLen(text: []const u8) usize {
    if (text.len > 0 and text[0] == '"') {
        var i: usize = 1;
        while (i < text.len) : (i += 1) switch (text[i]) {
            '\\' => i += 1,
            '"' => return i + 1,
            else => {},
        };
        return text.len;
    }
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const after_space = text[i - 1] == ' ' or text[i - 1] == '\t';
        if ((text[i] == ';' or text[i] == '#') and after_space) break;
    }
    return std.mem.trimEnd(u8, text[0..@min(i, text.len)], " \t").len;
}

/// The value written after the separator: a quoted string, or bare text up to a comment.
/// Null for a quoted value that is not closed or is followed by more than a comment.
fn value(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    if (text.len == 0 or text[0] != '"') {
        var end = text.len;
        var i: usize = 1;
        while (i < text.len) : (i += 1) {
            const after_space = text[i - 1] == ' ' or text[i - 1] == '\t';
            if ((text[i] == ';' or text[i] == '#') and after_space) {
                end = i;
                break;
            }
        }
        return try arena.dupe(u8, std.mem.trimEnd(u8, text[0..end], " \t"));
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => {
                const rest = std.mem.trim(u8, text[i + 1 ..], " \t");
                if (rest.len > 0 and !isComment(rest)) return null;
                return out.items;
            },
            '\\' => {
                i += 1;
                if (i >= text.len) return null;
                try out.append(arena, switch (text[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '"', '\\' => text[i],
                    else => return null,
                });
            },
            else => |c| try out.append(arena, c),
        }
    }
    return null;
}

/// Stores `new` at `section` + `key` (or at `section` itself when `key` is null and
/// `merge_table` is set, keeping a table already there).
fn put(
    arena: Allocator,
    root: *Value,
    section: []const []const u8,
    key: ?[]const u8,
    new: Value,
    merge_table: bool,
) (Allocator.Error || error{NotATable})!void {
    var current = root;
    for (section) |segment| {
        if (current.* != .table) return error.NotATable;
        const entry = try current.table.getOrPut(arena, segment);
        if (!entry.found_existing) entry.value_ptr.* = .empty_table;
        current = entry.value_ptr;
    }
    if (current.* != .table) return error.NotATable;
    const name = key orelse {
        std.debug.assert(merge_table);
        return;
    };
    const entry = try current.table.getOrPut(arena, try arena.dupe(u8, name));
    if (entry.found_existing and entry.value_ptr.* == .table) return error.NotATable;
    entry.value_ptr.* = new;
}

/// What writing can fail with: the writer, or a value INI cannot hold.
pub const WriteError = std.Io.Writer.Error || error{Unrepresentable};

/// Writes `value`, which must be a table, as an INI document.
pub fn write(writer: *std.Io.Writer, value_to_write: Value) WriteError!void {
    if (value_to_write != .table) return error.Unrepresentable;
    var section: std.ArrayList(u8) = .empty;
    var buffer: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    defer section.deinit(fixed.allocator());
    var started = false;
    try writeTable(writer, value_to_write.table, fixed.allocator(), &section, &started, true);
}

fn writeTable(
    writer: *std.Io.Writer,
    table: Table,
    scratch: Allocator,
    section: *std.ArrayList(u8),
    started: *bool,
    is_root: bool,
) WriteError!void {
    var has_plain = false;
    for (table.values()) |child| has_plain = has_plain or (child != .table and child != .null);
    const header = !is_root and (has_plain or table.count() == 0);
    if (header) {
        if (started.*) try writer.writeByte('\n');
        try writer.print("[{s}]\n", .{section.items});
        started.* = true;
    }
    var it = table.iterator();
    while (it.next()) |entry| {
        const child = entry.value_ptr.*;
        if (child == .table or child == .null) continue;
        if (!isPlainKey(entry.key_ptr.*)) return error.Unrepresentable;
        try writer.print("{s} = ", .{entry.key_ptr.*});
        try writeScalar(writer, child);
        try writer.writeByte('\n');
        started.* = true;
    }
    it = table.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) continue;
        const mark = section.items.len;
        defer section.shrinkRetainingCapacity(mark);
        var segment: std.Io.Writer.Allocating = .init(scratch);
        defer segment.deinit();
        path.writeSegment(&segment.writer, entry.key_ptr.*) catch return error.Unrepresentable;
        if (mark > 0) section.append(scratch, '.') catch return error.Unrepresentable;
        section.appendSlice(scratch, segment.written()) catch return error.Unrepresentable;
        try writeTable(writer, entry.value_ptr.table, scratch, section, started, false);
    }
}

/// A key INI can spell: not empty, no separator or comment characters, no surrounding
/// space.
pub fn isPlainKey(key: []const u8) bool {
    if (key.len == 0 or key[0] == '[' or key[0] == ' ' or key[key.len - 1] == ' ') return false;
    return std.mem.indexOfAny(u8, key, "=:;#\n\r\t") == null;
}

/// Writes a value of a key/value line: a scalar, or an array of scalars joined with `,`.
pub fn writeScalar(writer: *std.Io.Writer, leaf: Value) WriteError!void {
    var buffer: [4096]u8 = undefined;
    var text: std.Io.Writer = .fixed(&buffer);
    switch (leaf) {
        .string => |s| return writeText(writer, s),
        .array => |a| for (a.items, 0..) |item, i| {
            if (item == .array or item == .table) return error.Unrepresentable;
            if (i > 0) text.writeByte(',') catch return error.Unrepresentable;
            item.format(&text) catch return error.Unrepresentable;
        },
        .table, .null => return error.Unrepresentable, // writeTable handles them.
        else => leaf.format(&text) catch return error.Unrepresentable,
    }
    try writeText(writer, text.buffered());
}

/// Writes `s` bare when that reads back unchanged, otherwise quoted.
fn writeText(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const bare = s.len == 0 or (s[0] != ' ' and s[0] != '"' and s[s.len - 1] != ' ' and
        std.mem.indexOfAny(u8, s, ";#\"\\\n\r\t") == null);
    if (bare) return writer.writeAll(s);
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"', '\\' => {
            try writer.writeByte('\\');
            try writer.writeByte(c);
        },
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        '\r' => try writer.writeAll("\\r"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

const testing = std.testing;

test parse {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try parse(a,
        \\; A comment.
        \\name = demo
        \\
        \\[server]
        \\host: example.com   ; inline comment
        \\port = 8080
        \\motto = "semi;colon # and \"quotes\""
        \\url = http://x/#anchor
        \\
        \\[server.tls]
        \\cert = c.pem
        \\["a.b"]
        \\k = v
        \\[empty]
    , null);
    try testing.expectEqualStrings("demo", tree.lookup("name").?.string);
    try testing.expectEqualStrings("example.com", tree.lookup("server.host").?.string);
    try testing.expectEqualStrings("8080", tree.lookup("server.port").?.string);
    const motto = tree.lookup("server.motto").?.string;
    try testing.expectEqualStrings("semi;colon # and \"quotes\"", motto);
    try testing.expectEqualStrings("http://x/#anchor", tree.lookup("server.url").?.string);
    try testing.expectEqualStrings("c.pem", tree.lookup("server.tls.cert").?.string);
    try testing.expectEqualStrings("v", tree.lookup("\"a.b\".k").?.string);
    try testing.expectEqual(0, tree.lookup("empty").?.table.count());
}

test "parse errors have a line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { []const u8, []const u8, u32 }{
        .{ "a = 1\n[open", "expected ']' after a section name", 2 },
        .{ "\njust words", "expected '=' after a key", 2 },
        .{ "a = \"open", "unterminated or invalid quoted value", 1 },
        .{ "a = 1\n[a]", "section crosses a value", 2 },
        .{ "[]", "empty section name", 1 },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try testing.expectError(error.SyntaxError, parse(arena.allocator(), case[0], &diag));
        try testing.expectEqualStrings(case[1], diag.message);
        try testing.expectEqual(case[2], diag.line);
    }
}

test "write reads back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "name", .{ .string = " padded " });
    try root.put(a, "port", .{ .int = 8080 });
    try root.put(a, "server.host", .{ .string = "a;b" });
    try root.put(a, "server.tls.on", .{ .bool = true });
    try root.put(a, "\"a.b\".k", .{ .string = "v" });
    try root.put(a, "skip", .null);
    var tags: @import("value.zig").Array = .empty;
    try tags.append(a, .{ .string = "x" });
    try tags.append(a, .{ .int = 2 });
    try root.put(a, "tags", .{ .array = tags });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, root);
    try testing.expectEqualStrings(
        \\name = " padded "
        \\port = 8080
        \\tags = x,2
        \\
        \\[server]
        \\host = "a;b"
        \\
        \\[server.tls]
        \\on = true
        \\
        \\["a.b"]
        \\k = v
        \\
    , out.written());
    const back = try parse(a, out.written(), null);
    try testing.expectEqualStrings(" padded ", back.lookup("name").?.string);
    try testing.expectEqualStrings("a;b", back.lookup("server.host").?.string);
    try testing.expectEqualStrings("true", back.lookup("server.tls.on").?.string);
}

test "what INI cannot write" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.Unrepresentable, write(&out.writer, .{ .int = 1 }));
    var root: Value = .empty_table;
    try root.put(a, "a=b", .{ .int = 1 });
    try testing.expectError(error.Unrepresentable, write(&out.writer, root));
}
