//! TOML <-> `Value`. Reads TOML 1.0. Date and time values are validated and kept as
//! `.string` with their exact text, since `Value` has no date type. Writing puts a table's
//! plain keys first, then its sub-tables as `[header]` sections and its arrays of tables as
//! `[[header]]` sections, so the output reads back to an equal tree.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const writeFloat = @import("value.zig").writeFloat;
const Diagnostic = @import("Diagnostic.zig");
const path = @import("path.zig");

/// What parsing can fail with; the diagnostic says where.
pub const Error = error{SyntaxError} || Allocator.Error;

/// Nesting deeper than this is rejected, which bounds the parser's and the writer's
/// recursion. Every table, array, and dotted-key segment counts as one level.
pub const max_depth = 256;

/// Parses one TOML document into a `.table`. All memory comes from `arena`; the result
/// shares nothing with `source`.
pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diagnostic) Error!Value {
    var parser: Parser = .{ .arena = arena, .source = source, .diag = diag };
    if (invalidUtf8(source)) |offset| return parser.fail(offset, "invalid UTF-8");
    const root = try parser.newTable(.header, 0);
    try parser.document(root);
    return .{ .table = try toTable(arena, root) };
}

/// Where a table header or a key/value line sits in the source, for editing it in place.
pub const Span = struct {
    kind: Kind,
    /// The full key: the section's path, with array-of-tables indices (`servers.0`), then
    /// a key/value line's own dotted key.
    path: []const []const u8,
    /// The start of the line.
    start: usize,
    /// After the line's newline (or comment): the next line's start.
    end: usize = 0,
    /// A key/value line's value; for a header, the header itself, `[` to `]`.
    value_start: usize = 0,
    value_end: usize = 0,

    /// A table header, or a key/value line.
    pub const Kind = enum { header, entry };
};

/// Parses `source` and returns every header and key/value line in order. Fails as `parse`
/// does.
pub fn spans(arena: Allocator, source: []const u8) Error![]const Span {
    var list: std.ArrayList(Span) = .empty;
    var parser: Parser = .{ .arena = arena, .source = source, .diag = null, .spans = &list };
    if (invalidUtf8(source)) |offset| return parser.fail(offset, "invalid UTF-8");
    const root = try parser.newTable(.header, 0);
    try parser.document(root);
    return list.items;
}

/// A table under construction. TOML's redefinition rules depend on how a table came to
/// exist, which a `Value` does not record, so the parser builds these and converts at the
/// end. Nodes are heap-allocated so pointers to them stay valid while their parents grow.
const TableNode = struct {
    kind: Kind,
    depth: u32,
    entries: std.StringArrayHashMapUnmanaged(Node) = .empty,

    const Kind = enum {
        /// Created as a parent by a header such as `[a.b]`; a later `[a]` may define it.
        implicit,
        /// Defined by its own `[header]` or `[[header]]`, or the root.
        header,
        /// Created by a dotted key; only more dotted keys in the same table extend it.
        dotted,
    };
};

const Node = union(enum) {
    /// Closed to later additions: a scalar, an array literal, or an inline table.
    value: Value,
    table: *TableNode,
    /// Built by `[[header]]` sections; never empty.
    array_of_tables: std.ArrayList(*TableNode),
};

/// One part of a dotted key, with where it starts for error messages.
const Segment = struct {
    name: []const u8,
    offset: usize,
};

const Parser = struct {
    arena: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
    pos: usize = 0,
    /// When set, every header and key/value line is recorded here (see `spans`).
    spans: ?*std.ArrayList(Span) = null,
    /// While recording: the current section's path.
    section: []const []const u8 = &.{},

    fn fail(p: *const Parser, offset: usize, message: []const u8) error{SyntaxError} {
        Diagnostic.report(p.diag, p.source, offset, message);
        return error.SyntaxError;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.source.len) p.source[p.pos] else null;
    }

    fn startsWith(p: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, p.source[p.pos..], prefix);
    }

    /// Consumes `c` if it is next.
    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() != c) return false;
        p.pos += 1;
        return true;
    }

    /// Consumes a `\n` or `\r\n` if one is next.
    fn eatNewline(p: *Parser) bool {
        if (p.eat('\n')) return true;
        if (!p.startsWith("\r\n")) return false;
        p.pos += 2;
        return true;
    }

    fn atNewline(p: *const Parser) bool {
        return p.peek() == '\n' or p.startsWith("\r\n");
    }

    fn skipSpace(p: *Parser) void {
        while (p.peek()) |c| : (p.pos += 1) {
            if (c != ' ' and c != '\t') return;
        }
    }

    fn skipComment(p: *Parser) Error!void {
        if (!p.eat('#')) return;
        while (p.peek()) |c| : (p.pos += 1) {
            if (p.atNewline()) return;
            if (isControl(c)) return p.fail(p.pos, "invalid character in comment");
        }
    }

    /// Skips whitespace, comments, and newlines, as allowed between array items.
    fn skipBlank(p: *Parser) Error!void {
        while (true) {
            p.skipSpace();
            try p.skipComment();
            if (!p.eatNewline()) return;
        }
    }

    /// Requires the rest of the line to be blank or a comment, and consumes its newline.
    fn endLine(p: *Parser, message: []const u8) Error!void {
        p.skipSpace();
        try p.skipComment();
        if (p.pos == p.source.len or p.eatNewline()) return;
        return p.fail(p.pos, message);
    }

    fn newTable(p: *Parser, kind: TableNode.Kind, depth: usize) Error!*TableNode {
        if (depth > max_depth) return p.fail(p.pos, "nesting is too deep");
        const table = try p.arena.create(TableNode);
        table.* = .{ .kind = kind, .depth = @intCast(depth) };
        return table;
    }

    fn document(p: *Parser, root: *TableNode) Error!void {
        var current = root;
        while (true) {
            const line_start = p.pos;
            p.skipSpace();
            const c = p.peek() orelse return;
            switch (c) {
                '#', '\n', '\r' => try p.endLine("expected a newline"),
                '[' => {
                    const header_start = p.pos;
                    current = try p.header(root);
                    const header_end = p.pos;
                    try p.endLine("expected a newline after a table header");
                    try p.record(.{
                        .kind = .header,
                        .path = p.section,
                        .start = line_start,
                        .value_start = header_start,
                        .value_end = header_end,
                    });
                },
                else => {
                    const entry = try p.keyValue(current);
                    try p.endLine("expected a newline after a key/value pair");
                    if (p.spans == null) continue;
                    const names = try p.arena.alloc([]const u8, p.section.len + entry.key.len);
                    @memcpy(names[0..p.section.len], p.section);
                    for (names[p.section.len..], entry.key) |*name, segment| name.* = segment.name;
                    try p.record(.{
                        .kind = .entry,
                        .path = names,
                        .start = line_start,
                        .value_start = entry.value_start,
                        .value_end = entry.value_end,
                    });
                },
            }
        }
    }

    /// Records `span`, ending at the current position, when recording.
    fn record(p: *Parser, span: Span) Allocator.Error!void {
        const list = p.spans orelse return;
        var complete = span;
        complete.end = p.pos;
        try list.append(p.arena, complete);
    }

    // Keys and tables.

    const KeyValue = struct {
        key: []const Segment,
        value_start: usize,
        value_end: usize,
    };

    fn keyValue(p: *Parser, table: *TableNode) Error!KeyValue {
        const key = try p.parseKey();
        if (!p.eat('=')) return p.fail(p.pos, "expected '=' after a key");
        p.skipSpace();
        const value_start = p.pos;
        const value = try p.parseValue(table.depth + key.len);
        try p.assign(table, key, value);
        return .{ .key = key, .value_start = value_start, .value_end = p.pos };
    }

    /// Parses a possibly dotted key and the whitespace after it.
    fn parseKey(p: *Parser) Error![]const Segment {
        var segments: std.ArrayList(Segment) = .empty;
        while (true) {
            const offset = p.pos;
            const name = try p.keySegment();
            try segments.append(p.arena, .{ .name = name, .offset = offset });
            p.skipSpace();
            if (!p.eat('.')) return segments.items;
            p.skipSpace();
        }
    }

    fn keySegment(p: *Parser) Error![]const u8 {
        const start = p.pos;
        switch (p.peek() orelse 0) {
            '"', '\'' => {
                if (p.startsWith("\"\"\"") or p.startsWith("'''")) {
                    return p.fail(start, "a key cannot be a multi-line string");
                }
                return if (p.source[start] == '"') p.string('"') else p.string('\'');
            },
            else => {
                while (p.peek()) |c| : (p.pos += 1) {
                    if (!isBareKeyChar(c)) break;
                }
                if (p.pos == start) return p.fail(start, "expected a key");
                return p.arena.dupe(u8, p.source[start..p.pos]);
            },
        }
    }

    /// Stores `value` under the dotted `key` of `table`, creating dotted parent tables.
    fn assign(p: *Parser, table: *TableNode, key: []const Segment, value: Value) Error!void {
        assert(key.len > 0);
        var parent = table;
        for (key[0 .. key.len - 1]) |segment| parent = try p.dottedChild(parent, segment);
        const last = key[key.len - 1];
        const gop = try parent.entries.getOrPut(p.arena, last.name);
        if (gop.found_existing) return p.fail(last.offset, "duplicate key");
        gop.value_ptr.* = .{ .value = value };
    }

    fn dottedChild(p: *Parser, parent: *TableNode, segment: Segment) Error!*TableNode {
        if (parent.entries.get(segment.name)) |existing| return switch (existing) {
            .table => |child| if (child.kind == .dotted) child else p.fail(
                segment.offset,
                "cannot add dotted keys to a table defined by a header",
            ),
            .value => |v| p.fail(segment.offset, notATable(v)),
            .array_of_tables => p.fail(segment.offset, "cannot add keys to an array of tables"),
        };
        const child = try p.newTable(.dotted, parent.depth + 1);
        try parent.entries.putNoClobber(p.arena, segment.name, .{ .table = child });
        return child;
    }

    /// Parses `[key]` or `[[key]]` and returns the table that following keys go into.
    fn header(p: *Parser, root: *TableNode) Error!*TableNode {
        assert(p.peek() == '[');
        p.pos += 1;
        const is_array = p.eat('[');
        p.skipSpace();
        const key = try p.parseKey();
        if (!p.eat(']')) return p.fail(p.pos, "expected ']' after a table header");
        if (is_array and !p.eat(']')) return p.fail(p.pos, "expected ']]' after an array header");
        var parent = root;
        for (key[0 .. key.len - 1]) |segment| parent = try p.headerChild(parent, segment);
        const last = key[key.len - 1];
        const table = if (is_array)
            try p.appendTable(parent, last)
        else
            try p.defineTable(parent, last);
        if (p.spans != null) p.section = try p.sectionPath(root, key);
        return table;
    }

    /// The path a header's key leads to, with the index of the last table of each array
    /// of tables it passes through (the one the header extends or just appended).
    fn sectionPath(
        p: *Parser,
        root: *TableNode,
        key: []const Segment,
    ) Allocator.Error![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var node = root;
        for (key) |segment| {
            try names.append(p.arena, segment.name);
            switch (node.entries.get(segment.name).?) {
                .table => |child| node = child,
                .array_of_tables => |list| {
                    const index = list.items.len - 1;
                    try names.append(p.arena, try std.fmt.allocPrint(p.arena, "{d}", .{index}));
                    node = list.items[index];
                },
                .value => unreachable, // The header was accepted, so it names tables.
            }
        }
        return names.items;
    }

    /// The table a header path passes through: created implicitly when missing, or the
    /// last element of an array of tables.
    fn headerChild(p: *Parser, parent: *TableNode, segment: Segment) Error!*TableNode {
        if (parent.entries.get(segment.name)) |existing| return switch (existing) {
            .table => |child| child,
            .array_of_tables => |list| list.items[list.items.len - 1],
            .value => |v| p.fail(segment.offset, notATable(v)),
        };
        const child = try p.newTable(.implicit, parent.depth + 1);
        try parent.entries.putNoClobber(p.arena, segment.name, .{ .table = child });
        return child;
    }

    fn defineTable(p: *Parser, parent: *TableNode, segment: Segment) Error!*TableNode {
        if (parent.entries.get(segment.name)) |existing| switch (existing) {
            .table => |child| {
                if (child.kind != .implicit) {
                    return p.fail(segment.offset, "table is already defined");
                }
                child.kind = .header;
                return child;
            },
            .array_of_tables => return p.fail(segment.offset, "key is already an array of tables"),
            .value => return p.fail(segment.offset, "duplicate key"),
        };
        const child = try p.newTable(.header, parent.depth + 1);
        try parent.entries.putNoClobber(p.arena, segment.name, .{ .table = child });
        return child;
    }

    fn appendTable(p: *Parser, parent: *TableNode, segment: Segment) Error!*TableNode {
        // An array of tables is one level and each of its tables another.
        const child = try p.newTable(.header, parent.depth + 2);
        const gop = try parent.entries.getOrPut(p.arena, segment.name);
        if (!gop.found_existing) gop.value_ptr.* = .{ .array_of_tables = .empty };
        switch (gop.value_ptr.*) {
            .array_of_tables => |*list| try list.append(p.arena, child),
            .value => |v| return p.fail(segment.offset, if (v == .array)
                "cannot append to a static array"
            else
                "key is not an array of tables"),
            .table => return p.fail(segment.offset, "key is not an array of tables"),
        }
        return child;
    }

    // Values.

    fn parseValue(p: *Parser, depth: usize) Error!Value {
        if (depth > max_depth) return p.fail(p.pos, "nesting is too deep");
        const c = p.peek() orelse return p.fail(p.pos, "expected a value");
        return switch (c) {
            '"' => .{ .string = try if (p.startsWith("\"\"\""))
                p.multiLineString('"')
            else
                p.string('"') },
            '\'' => .{ .string = try if (p.startsWith("'''"))
                p.multiLineString('\'')
            else
                p.string('\'') },
            '[' => p.array(depth),
            '{' => p.inlineTable(depth),
            else => p.scalar(),
        };
    }

    fn array(p: *Parser, depth: usize) Error!Value {
        assert(p.peek() == '[');
        const start = p.pos;
        p.pos += 1;
        var items: Array = .empty;
        while (true) {
            try p.skipBlank();
            if (p.eat(']')) return .{ .array = items };
            if (p.peek() == null) return p.fail(start, "unterminated array");
            try items.append(p.arena, try p.parseValue(depth + 1));
            try p.skipBlank();
            if (p.eat(']')) return .{ .array = items };
            if (p.eat(',')) continue;
            if (p.peek() == null) return p.fail(start, "unterminated array");
            return p.fail(p.pos, "expected ',' or ']' in an array");
        }
    }

    fn inlineTable(p: *Parser, depth: usize) Error!Value {
        assert(p.peek() == '{');
        const start = p.pos;
        p.pos += 1;
        // Dotted keys inside may extend each other, as in a section; once the closing brace
        // is read the table becomes a plain value, which nothing can extend.
        const table = try p.newTable(.dotted, depth);
        p.skipSpace();
        if (p.eat('}')) return .{ .table = .empty };
        while (true) {
            p.skipSpace();
            if (p.peek() == '}') return p.fail(p.pos, "trailing comma in an inline table");
            if (p.atNewline()) return p.fail(p.pos, "an inline table must be on one line");
            _ = try p.keyValue(table);
            p.skipSpace();
            if (p.eat('}')) return .{ .table = try toTable(p.arena, table) };
            if (p.eat(',')) continue;
            if (p.peek() == null) return p.fail(start, "unterminated inline table");
            if (p.atNewline()) return p.fail(p.pos, "an inline table must be on one line");
            return p.fail(p.pos, "expected ',' or '}' in an inline table");
        }
    }

    /// A single-line basic (`"`) or literal (`'`) string.
    fn string(p: *Parser, comptime quote: u8) Error![]const u8 {
        assert(p.peek() == quote);
        const start = p.pos;
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |c| {
            if (c == quote) {
                p.pos += 1;
                return out.items;
            }
            if (c == '\n' or c == '\r') break;
            if (quote == '"' and c == '\\') {
                try p.escape(&out);
                continue;
            }
            if (isControl(c)) return p.fail(p.pos, "invalid character in string");
            try out.append(p.arena, c);
            p.pos += 1;
        }
        return p.fail(start, "unterminated string");
    }

    /// A multi-line basic (`"""`) or literal (`'''`) string. A newline right after the
    /// opening delimiter is dropped, and `\r\n` becomes `\n`.
    fn multiLineString(p: *Parser, comptime quote: u8) Error![]const u8 {
        const start = p.pos;
        p.pos += 3;
        _ = p.eatNewline();
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |c| {
            if (c == quote) {
                if (try p.closingQuotes(&out, quote)) return out.items;
            } else if (p.eatNewline()) {
                try out.append(p.arena, '\n');
            } else if (quote == '"' and c == '\\') {
                if (!p.skipLineEndingBackslash()) try p.escape(&out);
            } else if (isControl(c)) {
                return p.fail(p.pos, "invalid character in string");
            } else {
                try out.append(p.arena, c);
                p.pos += 1;
            }
        }
        return p.fail(start, "unterminated string");
    }

    /// Consumes a run of quotes in a multi-line string. Up to two quotes may sit right
    /// before the closing three; they belong to the content. Returns whether the run closed
    /// the string.
    fn closingQuotes(p: *Parser, out: *std.ArrayList(u8), comptime quote: u8) Error!bool {
        const start = p.pos;
        while (p.peek() == quote) p.pos += 1;
        const count = p.pos - start;
        assert(count > 0);
        if (count > 5) return p.fail(start, "too many quotes in a multi-line string");
        const content = if (count >= 3) count - 3 else count;
        assert(content <= 2);
        const pair: [2]u8 = @splat(quote);
        try out.appendSlice(p.arena, pair[0..content]);
        return count >= 3;
    }

    /// In a multi-line basic string, a `\` that ends a line removes it and all whitespace
    /// up to the next non-whitespace character.
    fn skipLineEndingBackslash(p: *Parser) bool {
        assert(p.peek() == '\\');
        const backslash = p.pos;
        p.pos += 1;
        p.skipSpace();
        if (!p.eatNewline()) {
            p.pos = backslash;
            return false;
        }
        while (true) {
            p.skipSpace();
            if (!p.eatNewline()) return true;
        }
    }

    fn escape(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        assert(p.peek() == '\\');
        const start = p.pos;
        p.pos += 1;
        const c = p.peek() orelse return p.fail(start, "invalid escape");
        p.pos += 1;
        const byte: u8 = switch (c) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            'u' => return p.unicodeEscape(out, start, 4),
            'U' => return p.unicodeEscape(out, start, 8),
            else => return p.fail(start, "invalid escape"),
        };
        try out.append(p.arena, byte);
    }

    /// Reads `digits` hex digits after `\u` or `\U` and appends the code point as UTF-8.
    fn unicodeEscape(p: *Parser, out: *std.ArrayList(u8), start: usize, digits: usize) Error!void {
        if (p.source.len - p.pos < digits) return p.fail(start, "invalid unicode escape");
        const hex = p.source[p.pos..][0..digits];
        for (hex) |c| if (!std.ascii.isHex(c)) return p.fail(start, "invalid unicode escape");
        p.pos += digits;
        // At most eight hex digits, which always fit a u32.
        const code = std.fmt.parseUnsigned(u32, hex, 16) catch unreachable;
        if (code > 0x10ffff) return p.fail(start, "invalid unicode escape");
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(code), &buffer) catch
            return p.fail(start, "invalid unicode escape");
        try out.appendSlice(p.arena, buffer[0..len]);
    }

    /// A number, boolean, special float, or date-time: everything not quoted or bracketed.
    fn scalar(p: *Parser) Error!Value {
        const start = p.pos;
        p.pos = tokenEnd(p.source, start);
        if (p.pos == start) return p.fail(start, "expected a value");
        // A date and a time may be separated by a space instead of a `T`.
        const text = p.source[start..p.pos];
        if (text.len == 10 and isDate(text[0..10]) and p.startsWith(" ") and
            p.pos + 1 < p.source.len and std.ascii.isDigit(p.source[p.pos + 1]))
        {
            p.pos = tokenEnd(p.source, p.pos + 1);
        }
        return scalarValue(p.arena, p.source[start..p.pos]) catch |err| p.fail(start, switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidValue => "invalid value",
            error.InvalidNumber => "invalid number",
            error.LeadingZero => "leading zeros are not allowed",
            error.OutOfRange => "integer out of range",
            error.InvalidDateTime => "invalid date or time",
        });
    }
};

fn notATable(value: Value) []const u8 {
    return if (value == .table) "cannot extend an inline table" else "key is not a table";
}

fn toTable(arena: Allocator, node: *const TableNode) Allocator.Error!Table {
    var table: Table = .empty;
    try table.ensureTotalCapacity(arena, node.entries.count());
    var it = node.entries.iterator();
    while (it.next()) |entry| {
        const value: Value = switch (entry.value_ptr.*) {
            .value => |v| v,
            .table => |child| .{ .table = try toTable(arena, child) },
            .array_of_tables => |list| blk: {
                assert(list.items.len > 0);
                var array: Array = try .initCapacity(arena, list.items.len);
                for (list.items) |child| {
                    array.appendAssumeCapacity(.{ .table = try toTable(arena, child) });
                }
                break :blk .{ .array = array };
            },
        };
        table.putAssumeCapacityNoClobber(entry.key_ptr.*, value);
    }
    return table;
}

/// The offset of the first byte that is not valid UTF-8, or null.
fn invalidUtf8(source: []const u8) ?usize {
    if (std.unicode.utf8ValidateSlice(source)) return null;
    var i: usize = 0;
    while (i < source.len) {
        const len = std.unicode.utf8ByteSequenceLength(source[i]) catch return i;
        if (source.len - i < len) return i;
        _ = std.unicode.utf8Decode(source[i..][0..len]) catch return i;
        i += len;
    }
    // utf8ValidateSlice disagreed with a per-sequence decode; report the end.
    return source.len;
}

/// Control characters other than tab, which TOML forbids in strings and comments.
fn isControl(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7f;
}

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// The end of a run of characters that may make up an unquoted scalar.
fn tokenEnd(source: []const u8, start: usize) usize {
    var end = start;
    while (end < source.len) : (end += 1) {
        const c = source[end];
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            '_', '+', '-', '.', ':' => true,
            else => false,
        };
        if (!ok) break;
    }
    return end;
}

const ScalarError = error{
    InvalidValue,
    InvalidNumber,
    LeadingZero,
    OutOfRange,
    InvalidDateTime,
} || Allocator.Error;

fn scalarValue(arena: Allocator, text: []const u8) ScalarError!Value {
    assert(text.len > 0);
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
    const unsigned = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    if (std.mem.eql(u8, unsigned, "inf")) {
        return .{ .float = if (text[0] == '-') -std.math.inf(f64) else std.math.inf(f64) };
    }
    if (std.mem.eql(u8, unsigned, "nan")) return .{ .float = std.math.nan(f64) };
    if (looksLikeDateTime(text)) {
        if (!isDateTime(text)) return error.InvalidDateTime;
        return .{ .string = try arena.dupe(u8, text) };
    }
    if (unsigned.len == 0 or !std.ascii.isDigit(unsigned[0])) return error.InvalidValue;
    if (text.len > 2 and text[0] == '0') switch (text[1]) {
        'x' => return prefixedInt(text[2..], 16),
        'o' => return prefixedInt(text[2..], 8),
        'b' => return prefixedInt(text[2..], 2),
        else => {},
    };
    if (std.mem.indexOfAny(u8, text, ".eE") != null) return float(text);
    try checkDecimal(unsigned);
    return .{ .int = std.fmt.parseInt(i64, text, 10) catch |err| switch (err) {
        error.Overflow => return error.OutOfRange,
        error.InvalidCharacter => return error.InvalidNumber,
    } };
}

fn prefixedInt(digits: []const u8, comptime base: u8) ScalarError!Value {
    if (!validDigits(digits, base)) return error.InvalidNumber;
    // `parseInt` accepts the `_` separators that `validDigits` has checked.
    return .{ .int = std.fmt.parseInt(i64, digits, base) catch |err| switch (err) {
        error.Overflow => return error.OutOfRange,
        error.InvalidCharacter => return error.InvalidNumber,
    } };
}

/// The integer part of a decimal number: digits with separators and no leading zero.
fn checkDecimal(digits: []const u8) ScalarError!void {
    if (!validDigits(digits, 10)) return error.InvalidNumber;
    if (digits.len > 1 and digits[0] == '0') return error.LeadingZero;
}

fn float(text: []const u8) ScalarError!Value {
    var rest = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    const int_end = std.mem.indexOfAny(u8, rest, ".eE") orelse rest.len;
    try checkDecimal(rest[0..int_end]);
    rest = rest[int_end..];
    if (rest.len > 0 and rest[0] == '.') {
        const fraction_end = std.mem.indexOfAny(u8, rest, "eE") orelse rest.len;
        if (!validDigits(rest[1..fraction_end], 10)) return error.InvalidNumber;
        rest = rest[fraction_end..];
    }
    if (rest.len > 0) {
        assert(rest[0] == 'e' or rest[0] == 'E');
        var exponent = rest[1..];
        if (exponent.len > 0 and (exponent[0] == '+' or exponent[0] == '-')) {
            exponent = exponent[1..];
        }
        if (!validDigits(exponent, 10)) return error.InvalidNumber;
    }
    // The syntax is checked above, and `parseFloat` accepts the `_` separators.
    return .{ .float = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber };
}

/// Whether `s` is one or more digits of `base`, with each `_` between two digits.
fn validDigits(s: []const u8, comptime base: u8) bool {
    var previous_digit = false;
    for (s) |c| {
        if (c == '_') {
            if (!previous_digit) return false;
            previous_digit = false;
        } else {
            _ = std.fmt.charToDigit(c, base) catch return false;
            previous_digit = true;
        }
    }
    return previous_digit;
}

/// Whether `text` starts like a date (`1979-`) or a time (`07:`).
fn looksLikeDateTime(text: []const u8) bool {
    if (text.len >= 5 and text[4] == '-') return allDigits(text[0..4]);
    return text.len >= 3 and text[2] == ':' and allDigits(text[0..2]);
}

/// Validates an offset date-time, local date-time, local date, or local time.
pub fn isDateTime(text: []const u8) bool {
    if (text.len >= 10 and text[4] == '-') {
        if (!isDate(text[0..10])) return false;
        const rest = text[10..];
        if (rest.len == 0) return true;
        if (rest[0] != 'T' and rest[0] != 't' and rest[0] != ' ') return false;
        const time_len = timeLength(rest[1..]) orelse return false;
        return isOffset(rest[1 + time_len ..]);
    }
    const time_len = timeLength(text) orelse return false;
    return time_len == text.len;
}

fn isDate(text: *const [10]u8) bool {
    if (text[4] != '-' or text[7] != '-' or !allDigits(text[0..4])) return false;
    const year = std.fmt.parseUnsigned(u16, text[0..4], 10) catch return false;
    const month = twoDigits(text[5..7]) orelse return false;
    const day = twoDigits(text[8..10]) orelse return false;
    if (month < 1 or month > 12 or day < 1) return false;
    const days: u8 = switch (month) {
        2 => if (std.time.epoch.isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    return day <= days;
}

/// The length of the `HH:MM:SS[.fraction]` at the start of `text`, or null.
fn timeLength(text: []const u8) ?usize {
    if (text.len < 8 or text[2] != ':' or text[5] != ':') return null;
    const hour = twoDigits(text[0..2]) orelse return null;
    const minute = twoDigits(text[3..5]) orelse return null;
    const second = twoDigits(text[6..8]) orelse return null;
    // A leap second may be 60.
    if (hour > 23 or minute > 59 or second > 60) return null;
    if (text.len == 8 or text[8] != '.') return 8;
    var end: usize = 9;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return if (end == 9) null else end;
}

/// Whether `text` is empty (a local date-time), `Z`, or `+HH:MM` / `-HH:MM`.
fn isOffset(text: []const u8) bool {
    if (text.len == 0) return true;
    if (text.len == 1) return text[0] == 'Z' or text[0] == 'z';
    if (text.len != 6 or (text[0] != '+' and text[0] != '-') or text[3] != ':') return false;
    const hour = twoDigits(text[1..3]) orelse return false;
    const minute = twoDigits(text[4..6]) orelse return false;
    return hour <= 23 and minute <= 59;
}

fn twoDigits(text: *const [2]u8) ?u8 {
    if (!allDigits(text)) return null;
    return (text[0] - '0') * 10 + (text[1] - '0');
}

fn allDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// How `write` lays the TOML out.
pub const WriteOptions = struct {
    /// Write a non-empty array whose items are all tables as `[[header]]` sections. When
    /// false, it is written inline like any other array.
    array_sections: bool = true,
    /// Key paths (as `Value.leafPaths` spells them) of tables to write inline,
    /// `point = { x = 1 }`, instead of as sections: `inlineTables` lists those of a source,
    /// so that rewriting it keeps its style.
    inline_tables: []const []const u8 = &.{},
};

/// The key paths of the tables `source` writes inline (`point = { x = 1 }`), for
/// `WriteOptions.inline_tables`. Empty when `source` does not parse.
pub fn inlineTables(arena: Allocator, source: []const u8) Allocator.Error![]const []const u8 {
    const all = spans(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |span| {
        if (span.kind != .entry or source[span.value_start] != '{') continue;
        var key: []const u8 = "";
        for (span.path) |segment| key = try path.join(arena, key, segment);
        try out.append(arena, key);
    }
    return out.items;
}

/// What writing can fail with: the writer, or a value TOML cannot hold.
pub const WriteError = std.Io.Writer.Error || error{Unrepresentable};

/// Writes `value`, which must be a table, as a TOML document. `null` has no TOML spelling,
/// and strings must be valid UTF-8; anything else is `error.Unrepresentable`.
pub fn write(writer: *std.Io.Writer, value: Value, options: WriteOptions) WriteError!void {
    if (value != .table) return error.Unrepresentable;
    var sections: SectionWriter = .{ .writer = writer, .options = options };
    try sections.keyValues(value.table);
    try sections.subSections(value.table);
}

const SectionWriter = struct {
    writer: *std.Io.Writer,
    options: WriteOptions,
    /// The keys leading to the table being written; headers spell them out.
    path: [max_depth][]const u8 = undefined,
    depth: usize = 0,
    /// Whether anything was written yet, so that sections are separated by a blank line.
    started: bool = false,

    /// Whether `value`, at `key` in the table being written, is written as a section rather
    /// than as `key = value`.
    fn isSection(w: *const SectionWriter, key: []const u8, value: Value) bool {
        return switch (value) {
            .table => !w.isInline(key),
            .array => |a| w.options.array_sections and a.items.len > 0 and for (a.items) |item| {
                if (item != .table) break false;
            } else true,
            else => false,
        };
    }

    /// Whether the table at `key`, below the path being written, is one to write inline.
    fn isInline(w: *const SectionWriter, key: []const u8) bool {
        if (w.options.inline_tables.len == 0) return false;
        var buffer: [1024]u8 = undefined;
        var full: std.Io.Writer = .fixed(&buffer);
        for (w.path[0..w.depth]) |segment| {
            path.writeSegment(&full, segment) catch return false;
            full.writeByte('.') catch return false;
        }
        path.writeSegment(&full, key) catch return false;
        for (w.options.inline_tables) |candidate| {
            if (std.mem.eql(u8, candidate, full.buffered())) return true;
        }
        return false;
    }

    fn keyValues(w: *SectionWriter, table: Table) WriteError!void {
        var it = table.iterator();
        while (it.next()) |entry| {
            if (w.isSection(entry.key_ptr.*, entry.value_ptr.*)) continue;
            try writeKey(w.writer, entry.key_ptr.*);
            try w.writer.writeAll(" = ");
            try writeInline(w.writer, entry.value_ptr.*, w.depth + 1);
            try w.writer.writeByte('\n');
            w.started = true;
        }
    }

    fn subSections(w: *SectionWriter, table: Table) WriteError!void {
        var it = table.iterator();
        while (it.next()) |entry| {
            const value = entry.value_ptr.*;
            if (!w.isSection(entry.key_ptr.*, value)) continue;
            if (w.depth == max_depth) return error.Unrepresentable;
            w.path[w.depth] = entry.key_ptr.*;
            w.depth += 1;
            defer w.depth -= 1;
            switch (value) {
                .table => |t| {
                    // A table holding only sections needs no header: theirs create it.
                    var plain = t.count() == 0;
                    for (t.keys(), t.values()) |k, child| plain = plain or !w.isSection(k, child);
                    if (plain) try w.header(false);
                    try w.keyValues(t);
                    try w.subSections(t);
                },
                .array => |a| for (a.items) |item| {
                    try w.header(true);
                    try w.keyValues(item.table);
                    try w.subSections(item.table);
                },
                else => unreachable, // isSection admits only tables and arrays.
            }
        }
    }

    fn header(w: *SectionWriter, is_array: bool) WriteError!void {
        assert(w.depth > 0);
        if (w.started) try w.writer.writeByte('\n');
        w.started = true;
        try w.writer.writeAll(if (is_array) "[[" else "[");
        for (w.path[0..w.depth], 0..) |key, i| {
            if (i > 0) try w.writer.writeByte('.');
            try writeKey(w.writer, key);
        }
        try w.writer.writeAll(if (is_array) "]]\n" else "]\n");
    }
};

/// Writes `value` as it appears after `key = `: inline, on one line.
pub fn writeValue(writer: *std.Io.Writer, value: Value) WriteError!void {
    return writeInline(writer, value, 0);
}

fn writeInline(writer: *std.Io.Writer, value: Value, depth: usize) WriteError!void {
    if (depth > max_depth) return error.Unrepresentable;
    switch (value) {
        .null => return error.Unrepresentable,
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writeTomlFloat(writer, f),
        // A date-time reads back as its text; writing it bare keeps it a date-time.
        .string => |s| if (looksLikeDateTime(s) and isDateTime(s))
            try writer.writeAll(s)
        else
            try writeString(writer, s),
        .array => |a| {
            try writer.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeInline(writer, item, depth + 1);
            }
            try writer.writeByte(']');
        },
        .table => |t| {
            if (t.count() == 0) return writer.writeAll("{}");
            try writer.writeAll("{ ");
            var it = t.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writeKey(writer, entry.key_ptr.*);
                try writer.writeAll(" = ");
                try writeInline(writer, entry.value_ptr.*, depth + 1);
            }
            try writer.writeAll(" }");
        },
    }
}

/// Writes a float with `writeFloat`, except that very large and very small magnitudes use
/// exponent notation: their positional spelling overflows `writeFloat`'s buffer.
fn writeTomlFloat(writer: *std.Io.Writer, f: f64) std.Io.Writer.Error!void {
    const magnitude = @abs(f);
    const positional = magnitude == 0 or std.math.isNan(f) or std.math.isInf(f) or
        (magnitude >= 1e-30 and magnitude < 1e30);
    if (positional) return writeFloat(writer, f);
    try writer.print("{e}", .{f});
}

/// Writes `key` bare when it can be, and as a basic string otherwise.
pub fn writeKey(writer: *std.Io.Writer, key: []const u8) WriteError!void {
    for (key) |c| {
        if (!isBareKeyChar(c)) break;
    } else if (key.len > 0) return writer.writeAll(key);
    try writeString(writer, key);
}

/// Writes `s` as a TOML basic string. Invalid UTF-8 is `error.Unrepresentable`.
pub fn writeString(writer: *std.Io.Writer, s: []const u8) WriteError!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.Unrepresentable;
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        0x08 => try writer.writeAll("\\b"),
        '\t' => try writer.writeAll("\\t"),
        '\n' => try writer.writeAll("\\n"),
        0x0c => try writer.writeAll("\\f"),
        '\r' => try writer.writeAll("\\r"),
        0...7, 11, 14...0x1f, 0x7f => try writer.print("\\u{X:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

const testing = std.testing;

fn expectParseError(source: []const u8, message: []const u8, line: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), source, &diag));
    try testing.expectEqualStrings(message, diag.message);
    try testing.expectEqual(line, diag.line);
}

/// Writes `value`, parses the output, and checks that it reads back equal.
fn expectRoundTrip(arena: Allocator, value: Value) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, .{});
    const again = try parse(arena, out.written(), null);
    try testing.expect(value.eql(again));
}

test "comments and blank lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "# top\r\n\n  a = 1 # trailing\r\n\t# indented\n", null);
    try testing.expectEqual(1, v.table.count());
    try testing.expectEqual(1, v.lookup("a").?.int);
    const empty = try parse(arena.allocator(), "", null);
    try testing.expectEqual(0, empty.table.count());
}

test "bare, quoted, and dotted keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\bare_key-1 = 1
        \\"quoted key" = 2
        \\'literal.key' = 3
        \\a . "b.c" . d = 4
        \\a.e = 5
        \\"" = 6
        \\1234 = 7
    , null);
    try testing.expectEqual(1, v.lookup("bare_key-1").?.int);
    try testing.expectEqual(2, v.table.get("quoted key").?.int);
    try testing.expectEqual(3, v.table.get("literal.key").?.int);
    try testing.expectEqual(4, v.lookup("a.\"b.c\".d").?.int);
    try testing.expectEqual(5, v.lookup("a.e").?.int);
    try testing.expectEqual(6, v.table.get("").?.int);
    try testing.expectEqual(7, v.table.get("1234").?.int);
}

test "tables and sub-tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\top = true
        \\[server]
        \\host = "h"
        \\[server.tls]
        \\on = false
        \\[ a . "b" ]
        \\x = 1
        \\[a]
        \\y = 2
    , null);
    try testing.expectEqual(true, v.lookup("top").?.bool);
    try testing.expectEqualStrings("h", v.lookup("server.host").?.string);
    try testing.expectEqual(false, v.lookup("server.tls.on").?.bool);
    try testing.expectEqual(1, v.lookup("a.b.x").?.int);
    try testing.expectEqual(2, v.lookup("a.y").?.int);
    try testing.expectEqualStrings("b", v.lookup("a").?.table.keys()[0]);
}

test "arrays of tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\[[fruit]]
        \\name = "apple"
        \\[fruit.physical]
        \\color = "red"
        \\[[fruit.variety]]
        \\name = "fuji"
        \\[[fruit]]
        \\name = "banana"
        \\[[fruit.variety]]
        \\name = "plantain"
    , null);
    try testing.expectEqual(2, v.lookup("fruit").?.array.items.len);
    try testing.expectEqualStrings("apple", v.lookup("fruit.0.name").?.string);
    try testing.expectEqualStrings("red", v.lookup("fruit.0.physical.color").?.string);
    try testing.expectEqualStrings("fuji", v.lookup("fruit.0.variety.0.name").?.string);
    try testing.expectEqualStrings("plantain", v.lookup("fruit.1.variety.0.name").?.string);
    try testing.expectEqual(null, v.lookup("fruit.1.physical"));
}

test "basic string escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\s = "\b\t\n\f\r\"\\ \u00e9 \U0001F40D tab:
    ++ "\t\"\n";
    const v = try parse(arena.allocator(), source, null);
    const expected = "\x08\t\n\x0c\r\"\\ \u{e9} \u{1F40D} tab:\t";
    try testing.expectEqualStrings(expected, v.lookup("s").?.string);
}

test "literal strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\path = 'C:\Users\nodejs'
        \\quoted = 'Tom "Dubs" Preston'
    , null);
    try testing.expectEqualStrings("C:\\Users\\nodejs", v.lookup("path").?.string);
    try testing.expectEqualStrings("Tom \"Dubs\" Preston", v.lookup("quoted").?.string);
}

test "multi-line basic strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "a = \"\"\"\nRoses\r\nViolets\"\"\"\n" ++
        "b = \"\"\"\\\n    The quick \\   \n\n    fox.\\\n    \"\"\"\n" ++
        "c = \"\"\"\"quoted\"\"\"\"\"\n" ++
        "d = \"\"\"esc: \\t\\u0041\"\"\"\n", null);
    try testing.expectEqualStrings("Roses\nViolets", v.lookup("a").?.string);
    try testing.expectEqualStrings("The quick fox.", v.lookup("b").?.string);
    try testing.expectEqualStrings("\"quoted\"\"", v.lookup("c").?.string);
    try testing.expectEqualStrings("esc: \tA", v.lookup("d").?.string);
}

test "multi-line literal strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "re = '''\nI [dw]on't need \\d{2}\n  apples'''\n" ++
        "q = ''''That's it'''''\n", null);
    try testing.expectEqualStrings("I [dw]on't need \\d{2}\n  apples", v.lookup("re").?.string);
    try testing.expectEqualStrings("'That's it''", v.lookup("q").?.string);
}

test "integers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\a = +99
        \\b = -17
        \\c = 0
        \\d = 1_000_000
        \\e = 0xDEAD_beef
        \\f = 0o755
        \\g = 0b1101_0110
        \\h = -9223372036854775808
        \\i = -0
    , null);
    try testing.expectEqual(99, v.lookup("a").?.int);
    try testing.expectEqual(-17, v.lookup("b").?.int);
    try testing.expectEqual(0, v.lookup("c").?.int);
    try testing.expectEqual(1_000_000, v.lookup("d").?.int);
    try testing.expectEqual(0xdeadbeef, v.lookup("e").?.int);
    try testing.expectEqual(0o755, v.lookup("f").?.int);
    try testing.expectEqual(0b11010110, v.lookup("g").?.int);
    try testing.expectEqual(std.math.minInt(i64), v.lookup("h").?.int);
    try testing.expectEqual(0, v.lookup("i").?.int);
}

test "floats" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\a = +1.0
        \\b = -0.01
        \\c = 5e+22
        \\d = 1e06
        \\e = -2E-2
        \\f = 6.626e-34
        \\g = 224_617.445_991
        \\h = inf
        \\i = -inf
        \\j = +nan
        \\k = 0.5
    , null);
    try testing.expectEqual(1.0, v.lookup("a").?.float);
    try testing.expectEqual(-0.01, v.lookup("b").?.float);
    try testing.expectEqual(5e22, v.lookup("c").?.float);
    try testing.expectEqual(1e6, v.lookup("d").?.float);
    try testing.expectEqual(-2e-2, v.lookup("e").?.float);
    try testing.expectEqual(6.626e-34, v.lookup("f").?.float);
    try testing.expectEqual(224617.445991, v.lookup("g").?.float);
    try testing.expect(std.math.isPositiveInf(v.lookup("h").?.float));
    try testing.expect(std.math.isNegativeInf(v.lookup("i").?.float));
    try testing.expect(std.math.isNan(v.lookup("j").?.float));
    try testing.expectEqual(0.5, v.lookup("k").?.float);
}

test "booleans" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "t = true\nf = false\n", null);
    try testing.expectEqual(true, v.lookup("t").?.bool);
    try testing.expectEqual(false, v.lookup("f").?.bool);
}

test "dates and times are kept as text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\odt1 = 1979-05-27T07:32:00Z
        \\odt2 = 1979-05-27T00:32:00.999999-07:00
        \\odt3 = 1979-05-27 07:32:00+01:30
        \\ldt = 1979-05-27t07:32:00
        \\ld = 2024-02-29
        \\lt = 00:32:00.5
        \\list = [1979-05-27, 07:32:00]
    , null);
    try testing.expectEqualStrings("1979-05-27T07:32:00Z", v.lookup("odt1").?.string);
    try testing.expectEqualStrings("1979-05-27T00:32:00.999999-07:00", v.lookup("odt2").?.string);
    try testing.expectEqualStrings("1979-05-27 07:32:00+01:30", v.lookup("odt3").?.string);
    try testing.expectEqualStrings("1979-05-27t07:32:00", v.lookup("ldt").?.string);
    try testing.expectEqualStrings("2024-02-29", v.lookup("ld").?.string);
    try testing.expectEqualStrings("00:32:00.5", v.lookup("lt").?.string);
    try testing.expectEqualStrings("07:32:00", v.lookup("list.1").?.string);
}

test "arrays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\empty = [ ]
        \\nested = [[1, 2], ["a"]]
        \\mixed = [
        \\  1, # one
        \\  "two",
        \\  # a comment line
        \\  { three = 3 },
        \\]
    , null);
    try testing.expectEqual(0, v.lookup("empty").?.array.items.len);
    try testing.expectEqual(2, v.lookup("nested.0.1").?.int);
    try testing.expectEqualStrings("a", v.lookup("nested.1.0").?.string);
    try testing.expectEqual(3, v.lookup("mixed").?.array.items.len);
    try testing.expectEqualStrings("two", v.lookup("mixed.1").?.string);
    try testing.expectEqual(3, v.lookup("mixed.2.three").?.int);
}

test "inline tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\name = { first = "Tom", last = "Preston-Werner" }
        \\point = {x=1,y=2}
        \\dotted = { type.name = "pug", type.age = 3, other = {} }
        \\empty = {}
    , null);
    try testing.expectEqualStrings("Tom", v.lookup("name.first").?.string);
    try testing.expectEqual(2, v.lookup("point.y").?.int);
    try testing.expectEqualStrings("pug", v.lookup("dotted.type.name").?.string);
    try testing.expectEqual(3, v.lookup("dotted.type.age").?.int);
    try testing.expectEqual(0, v.lookup("dotted.other").?.table.count());
    try testing.expectEqual(0, v.lookup("empty").?.table.count());
}

test "dotted keys may extend dotted tables and headers may add sub-tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\[fruit]
        \\apple.color = "red"
        \\apple.taste.sweet = true
        \\[fruit.apple.texture]
        \\smooth = true
    , null);
    try testing.expectEqual(true, v.lookup("fruit.apple.taste.sweet").?.bool);
    try testing.expectEqual(true, v.lookup("fruit.apple.texture.smooth").?.bool);
}

test "duplicate keys and tables" {
    try expectParseError("a = 1\na = 2\n", "duplicate key", 2);
    try expectParseError("a.b = 1\na.b = 2\n", "duplicate key", 2);
    try expectParseError("[a]\nb = 1\n[a]\n", "table is already defined", 3);
    try expectParseError("[a.b]\n[a]\n[a]\n", "table is already defined", 3);
    try expectParseError("[a]\nb.c = 1\n[a.b]\n", "table is already defined", 3);
    try expectParseError("a = 1\n[a]\n", "duplicate key", 2);
    try expectParseError("[a.b]\n[a]\nb = 1\n", "duplicate key", 3);
    try expectParseError("[[a]]\n[a]\n", "key is already an array of tables", 2);
    try expectParseError("[a]\n[[a]]\n", "key is not an array of tables", 2);
    try expectParseError("a = { b = 1, b = 2 }\n", "duplicate key", 1);
}

test "dotted keys cannot reach into a table defined by a header" {
    try expectParseError(
        "[a.b.c]\nz = 9\n[a]\nb.c.t = 1\n",
        "cannot add dotted keys to a table defined by a header",
        4,
    );
}

test "inline tables and static arrays are closed" {
    try expectParseError("a = { b = 1 }\n[a]\n", "duplicate key", 2);
    try expectParseError("a = { b = 1 }\n[a.c]\n", "cannot extend an inline table", 2);
    try expectParseError("a = { b = 1 }\na.c = 2\n", "cannot extend an inline table", 2);
    try expectParseError("a = { b = {}, b.c = 1 }\n", "cannot extend an inline table", 1);
    try expectParseError("a = []\n[[a]]\n", "cannot append to a static array", 2);
}

test "assigning into a non-table" {
    try expectParseError("a = 1\na.b = 2\n", "key is not a table", 2);
    try expectParseError("a = 1\n[a.b]\n", "key is not a table", 2);
    try expectParseError("[[a]]\na.b = 1\n[a]\n", "key is already an array of tables", 3);
    try expectParseError("[[a.b]]\n[a]\nb.x = 1\n", "cannot add keys to an array of tables", 3);
}

test "number errors" {
    try expectParseError("a = 01\n", "leading zeros are not allowed", 1);
    try expectParseError("a = 00.5\n", "leading zeros are not allowed", 1);
    try expectParseError("\na = 1__0\n", "invalid number", 2);
    try expectParseError("a = _1\n", "invalid value", 1);
    try expectParseError("a = 1_\n", "invalid number", 1);
    try expectParseError("a = 1.\n", "invalid number", 1);
    try expectParseError("a = 1e\n", "invalid number", 1);
    try expectParseError("a = 0x\n", "invalid number", 1);
    try expectParseError("a = +0x1\n", "invalid number", 1);
    try expectParseError("a = 0xG\n", "invalid number", 1);
    try expectParseError("a = 9223372036854775808\n", "integer out of range", 1);
    try expectParseError("a = 0x8000000000000000\n", "integer out of range", 1);
    try expectParseError("a = yes\n", "invalid value", 1);
}

test "date errors" {
    try expectParseError("a = 2023-02-29\n", "invalid date or time", 1);
    try expectParseError("a = 1979-13-01\n", "invalid date or time", 1);
    try expectParseError("a = 24:00:00\n", "invalid date or time", 1);
    try expectParseError("a = 07:32\n", "invalid date or time", 1);
    try expectParseError("a = 1979-05-27T07:32:00+1:00\n", "invalid date or time", 1);
}

test "string errors" {
    try expectParseError("a = \"abc\n", "unterminated string", 1);
    try expectParseError("a = 'abc", "unterminated string", 1);
    try expectParseError("a = \"\"\"abc\n\n", "unterminated string", 1);
    try expectParseError("\na = \"\\x\"\n", "invalid escape", 2);
    try expectParseError("a = \"\\uD800\"\n", "invalid unicode escape", 1);
    try expectParseError("a = \"\\U00110000\"\n", "invalid unicode escape", 1);
    try expectParseError("a = \"\\u12\"\n", "invalid unicode escape", 1);
    try expectParseError("a = \"\x01\"\n", "invalid character in string", 1);
    try expectParseError("a = \"\"\"x\"\"\"\"\"\"\n", "too many quotes in a multi-line string", 1);
    try expectParseError("\"\"\"k\"\"\" = 1\n", "a key cannot be a multi-line string", 1);
    try expectParseError("a = \"\xff\"\n", "invalid UTF-8", 1);
}

test "structural errors" {
    try expectParseError("a = 1 b = 2\n", "expected a newline after a key/value pair", 1);
    try expectParseError("[a] x = 1\n", "expected a newline after a table header", 1);
    try expectParseError("a 1\n", "expected '=' after a key", 1);
    try expectParseError("a =\n", "expected a value", 1);
    try expectParseError("= 1\n", "expected a key", 1);
    try expectParseError("[a\n", "expected ']' after a table header", 1);
    try expectParseError("[[a]\n", "expected ']]' after an array header", 1);
    try expectParseError("a = [1 2]\n", "expected ',' or ']' in an array", 1);
    try expectParseError("a = [1,\n", "unterminated array", 1);
    try expectParseError("a = { b = 1, }\n", "trailing comma in an inline table", 1);
    try expectParseError("a = { b = 1\n}\n", "an inline table must be on one line", 1);
    try expectParseError("a = { b = 1", "unterminated inline table", 1);
    try expectParseError("a = 1 # \x01\n", "invalid character in comment", 1);
    try expectParseError("a = 1\r", "expected a newline after a key/value pair", 1);
}

test "error columns point at the offending byte" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const source = "x = 1\n[t]\nk = \"a\\qb\"\n";
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), source, &diag));
    try testing.expectEqual(3, diag.line);
    try testing.expectEqual(7, diag.column);
    try testing.expectEqualStrings("invalid escape", diag.message);
    const duplicate = "a.b = 1\na . b = 2";
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), duplicate, &diag));
    try testing.expectEqual(2, diag.line);
    try testing.expectEqual(5, diag.column);
}

test "nesting is bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var deep: [4 + 2 * (max_depth + 2)]u8 = undefined;
    @memcpy(deep[0..4], "a = ");
    @memset(deep[4..][0 .. max_depth + 2], '[');
    @memset(deep[4 + max_depth + 2 ..], ']');
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), &deep, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);

    var dotted: [2 * (max_depth + 1) + 4]u8 = undefined;
    for (0..max_depth + 1) |i| @memcpy(dotted[2 * i ..][0..2], "a.");
    @memcpy(dotted[2 * (max_depth + 1) ..], "b=1\n");
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), &dotted, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);
}

test "write a representative document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\title = "snek \"v1\""
        \\ports = [8000, 8001]
        \\ratio = 5e-1
        \\point = {x=1, y = {}}
        \\mixed = [1, {a = 1}]
        \\
        \\[server]
        \\host = "localhost"
        \\[server."tls.v2"]
        \\enabled = true
        \\[only.nested]
        \\x = 1
        \\[[users]]
        \\name = "a"
        \\[users.meta]
        \\[[users]]
        \\name = "b"
        \\[empty]
    ;
    const value = try parse(a, source, null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, .{});
    try testing.expectEqualStrings(
        \\title = "snek \"v1\""
        \\ports = [8000, 8001]
        \\ratio = 0.5
        \\mixed = [1, { a = 1 }]
        \\
        \\[point]
        \\x = 1
        \\
        \\[point.y]
        \\
        \\[server]
        \\host = "localhost"
        \\
        \\[server."tls.v2"]
        \\enabled = true
        \\
        \\[only.nested]
        \\x = 1
        \\
        \\[[users]]
        \\name = "a"
        \\
        \\[users.meta]
        \\
        \\[[users]]
        \\name = "b"
        \\
        \\[empty]
        \\
    , out.written());
    try testing.expect(value.eql(try parse(a, out.written(), null)));
}

test "write arrays of tables inline when asked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try parse(arena.allocator(), "[[a]]\nx = 1\n[[a]]\n", null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, .{ .array_sections = false });
    try testing.expectEqualStrings("a = [{ x = 1 }, {}]\n", out.written());
}

test "write quotes keys and escapes strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value: Value = .empty_table;
    try value.table.put(a, "", .{ .string = "\x00\x08\t\n\x0c\r\x1f\x7f\\é" });
    try value.table.put(a, "a b", .{ .float = -std.math.inf(f64) });
    try value.table.put(a, "ok_-9", .{ .float = 2.0 });
    try value.table.put(a, "tiny", .{ .float = -5e-324 });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, .{});
    try testing.expectEqualStrings(
        \\"" = "\u0000\b\t\n\f\r\u001F\u007F\\é"
        \\"a b" = -inf
        \\ok_-9 = 2.0
        \\tiny = -5e-324
        \\
    , out.written());
    try expectRoundTrip(a, value);
}

test "write rejects what TOML cannot express" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.Unrepresentable, write(&out.writer, .{ .int = 1 }, .{}));
    var with_null: Value = .empty_table;
    try with_null.put(a, "a.b", .null);
    try testing.expectError(error.Unrepresentable, write(&out.writer, with_null, .{}));
    var bad_utf8: Value = .empty_table;
    try bad_utf8.put(a, "s", .{ .string = "\xff" });
    try testing.expectError(error.Unrepresentable, write(&out.writer, bad_utf8, .{}));
}

test "round trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_][]const u8{
        "",
        "a = 1\nb = -2.5e10\nc = 'x'\nd = [[], [{}], [1, 'two', 3.0]]\n",
        "[a.b.c]\n[a.b.d]\nx = 1979-05-27T07:32:00Z\n",
        "[[a]]\n[[a.b]]\n[[a.b]]\nc = { d.e = 1 }\n[[a]]\n",
        "\"weird key\".\"\" = \"\\u0001\"\nmax = 9223372036854775807\nmin = -9223372036854775808\n",
        "f = [0.1, -0.0, 1e300, -5e-324, 1.5e29, 2e-30, inf]\ns = \"\"\"\nline\n\tnext\"\"\"\n",
    };
    for (sources) |source| try expectRoundTrip(a, try parse(a, source, null));
}

test "a parsed tree shares nothing with the source" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var source = "plain = 'abc'\n".*;
    const v = try parse(arena.allocator(), &source, null);
    @memset(&source, 'x');
    try testing.expectEqualStrings("abc", v.lookup("plain").?.string);
    try testing.expectEqualStrings("plain", v.table.keys()[0]);
}

test "inline tables are kept when the writer is told which" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\name = "x"
        \\point = { x = 1, y = 2 }
        \\
        \\[server]
        \\tls = { cert = "c.pem" }
        \\port = 80
        \\
    ;
    const tree = try parse(a, source, null);
    const inline_tables = try inlineTables(a, source);
    try testing.expectEqual(2, inline_tables.len);
    try testing.expectEqualStrings("server.tls", inline_tables[1]);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, tree, .{ .inline_tables = inline_tables });
    try testing.expectEqualStrings(
        \\name = "x"
        \\point = { x = 1, y = 2 }
        \\
        \\[server]
        \\tls = { cert = "c.pem" }
        \\port = 80
        \\
    , out.written());
}
