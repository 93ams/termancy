//! JSON <-> `Value`. Reading uses `std.json.Scanner`; integers that fit an `i64` become
//! `.int`, every other number `.float`. Every string is copied into the arena, so the tree
//! never points into the source.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const writeFloat = @import("value.zig").writeFloat;
const Diagnostic = @import("Diagnostic.zig");
const bomLength = @import("format.zig").bomLength;

/// What parsing can fail with; the diagnostic says where.
pub const Error = error{SyntaxError} || Allocator.Error;

/// Nesting deeper than this is rejected, which bounds the parser's recursion.
pub const max_depth = 256;

/// Parses one JSON document. All memory comes from `arena`.
pub fn parse(arena: Allocator, source_with_bom: []const u8, diag: ?*Diagnostic) Error!Value {
    const source = source_with_bom[bomLength(source_with_bom)..];
    var scanner: std.json.Scanner = .initCompleteInput(arena, source);
    const value = parseValue(arena, &scanner, 0) catch |err| {
        return fail(&scanner, source, diag, err);
    };
    const end = scanner.next() catch |err| return fail(&scanner, source, diag, err);
    if (end != .end_of_document) {
        Diagnostic.report(diag, source, scanner.cursor, "trailing content after the document");
        return error.SyntaxError;
    }
    return value;
}

/// Parses JSON with comments (`//` to the end of the line, `/* ... */`) and trailing commas
/// before `]` and `}`, as `.jsonc` files and many editors' settings use. They are blanked
/// out first, keeping every line and column where it was, so errors point at the source.
pub fn parseWithComments(arena: Allocator, source: []const u8, diag: ?*Diagnostic) Error!Value {
    const plain = try arena.dupe(u8, source);
    if (!blankComments(plain)) {
        Diagnostic.report(diag, source, source.len, "unterminated comment");
        return error.SyntaxError;
    }
    return parse(arena, plain, diag);
}

/// Replaces comments and trailing commas in `text` with spaces, leaving line breaks.
/// Returns false for a `/*` without its `*/`.
fn blankComments(text: []u8) bool {
    var i: usize = 0;
    var in_string = false;
    // The last comma outside a string whose following text, so far, is blank.
    var pending_comma: ?usize = null;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => {
                in_string = true;
                pending_comma = null;
            },
            ',' => pending_comma = i,
            ']', '}' => {
                if (pending_comma) |comma| text[comma] = ' ';
                pending_comma = null;
            },
            '/' => if (i + 1 < text.len and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') : (i += 1) text[i] = ' ';
            } else if (i + 1 < text.len and text[i + 1] == '*') {
                const start = i;
                const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return false;
                for (text[start .. end + 2]) |*b| {
                    if (b.* != '\n') b.* = ' ';
                }
                i = end + 1;
            } else {
                pending_comma = null;
            },
            ' ', '\t', '\r', '\n' => {},
            else => pending_comma = null,
        }
    }
    return true;
}

/// An object's field or an object, for editing in place. Objects inside arrays are not
/// listed.
pub const Span = struct {
    kind: Kind,
    /// A field's key path; an object's path.
    path: []const []const u8,
    /// A field: the start of its key's `"`. An object: its `{`.
    start: usize,
    /// A field: after its value, and after the comma that follows it, if any. An object:
    /// its `}`.
    end: usize,
    /// A field's value.
    value_start: usize = 0,
    value_end: usize = 0,
    /// An object: its first field starts a line of its own.
    multiline: bool = false,
    /// An object: how many fields it has.
    fields: usize = 0,

    /// An object's field, or an object.
    pub const Kind = enum { field, object };
};

/// Parses `source` and returns its objects and their fields, in order. With `comments`,
/// `source` is JSON with comments, and comments count as space. Fails as `parse` does.
pub fn spans(arena: Allocator, source: []const u8, comments: bool) Error![]const Span {
    // Validated first, so the walker can rely on the syntax.
    _ = if (comments)
        try parseWithComments(arena, source, null)
    else
        try parse(arena, source, null);
    var list: std.ArrayList(Span) = .empty;
    var walker: SpanWalker = .{
        .arena = arena,
        .source = source,
        .comments = comments,
        .list = &list,
        .i = bomLength(source),
    };
    walker.skip();
    try walker.value(&.{});
    return list.items;
}

const SpanWalker = struct {
    arena: Allocator,
    source: []const u8,
    comments: bool,
    list: *std.ArrayList(Span),
    i: usize = 0,

    /// Past white space, and comments when they are allowed.
    fn skip(w: *SpanWalker) void {
        const s = w.source;
        while (w.i < s.len) {
            switch (s[w.i]) {
                ' ', '\t', '\r', '\n' => w.i += 1,
                '/' => {
                    if (!w.comments or w.i + 1 >= s.len) return;
                    if (s[w.i + 1] == '/') {
                        w.i = std.mem.indexOfScalarPos(u8, s, w.i, '\n') orelse s.len;
                    } else if (s[w.i + 1] == '*') {
                        const close = std.mem.indexOfPos(u8, s, w.i + 2, "*/") orelse s.len;
                        w.i = @min(close + 2, s.len);
                    } else return;
                },
                else => return,
            }
        }
    }

    /// Past a string, from its opening quote.
    fn string(w: *SpanWalker) void {
        w.i += 1;
        while (w.i < w.source.len) : (w.i += 1) switch (w.source[w.i]) {
            '\\' => w.i += 1,
            '"' => {
                w.i += 1;
                return;
            },
            else => {},
        };
    }

    /// Past one value, listing the objects in it; `at` is null inside an array.
    fn value(w: *SpanWalker, at: ?[]const []const u8) Error!void {
        const s = w.source;
        if (w.i >= s.len) return error.SyntaxError;
        switch (s[w.i]) {
            '{' => try w.object(at),
            '[' => {
                w.i += 1;
                w.skip();
                while (w.i < s.len and s[w.i] != ']') {
                    try w.value(null);
                    w.skip();
                    if (w.i < s.len and s[w.i] == ',') w.i += 1;
                    w.skip();
                }
                w.i += 1;
            },
            '"' => w.string(),
            else => while (w.i < s.len) : (w.i += 1) switch (s[w.i]) {
                ',', ']', '}', ' ', '\t', '\r', '\n', '/' => break,
                else => {},
            },
        }
    }

    fn object(w: *SpanWalker, at: ?[]const []const u8) Error!void {
        const s = w.source;
        const index = w.list.items.len;
        const open = w.i;
        if (at) |p| try w.list.append(w.arena, .{
            .kind = .object,
            .path = p,
            .start = open,
            .end = 0,
        });
        w.i += 1;
        w.skip();
        const multiline = std.mem.indexOfScalar(u8, s[open..w.i], '\n') != null;
        var fields: usize = 0;
        while (w.i < s.len and s[w.i] != '}') : (fields += 1) {
            const key_start = w.i;
            w.string();
            const raw = s[key_start..w.i];
            w.skip();
            w.i += 1; // The validated `:`.
            w.skip();
            const value_start = w.i;
            const child: ?[]const []const u8 = if (at) |p| blk: {
                const key = if (std.mem.indexOfScalar(u8, raw, '\\') == null)
                    raw[1 .. raw.len - 1]
                else
                    std.json.parseFromSliceLeaky([]const u8, w.arena, raw, .{}) catch
                        return error.SyntaxError;
                break :blk try std.mem.concat(w.arena, []const u8, &.{ p, &.{key} });
            } else null;
            try w.value(child);
            const value_end = w.i;
            w.skip();
            var end = value_end;
            if (w.i < s.len and s[w.i] == ',') {
                w.i += 1;
                end = w.i;
            }
            if (child) |p| try w.list.append(w.arena, .{
                .kind = .field,
                .path = p,
                .start = key_start,
                .end = end,
                .value_start = value_start,
                .value_end = value_end,
            });
            w.skip();
        }
        if (at != null) {
            const span = &w.list.items[index];
            span.end = w.i;
            span.multiline = multiline;
            span.fields = fields;
        }
        w.i += 1;
    }
};

const ScanError = std.json.Scanner.AllocError || std.json.Scanner.PeekError || error{TooDeep};

fn fail(scanner: *std.json.Scanner, source: []const u8, diag: ?*Diagnostic, err: ScanError) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const message = switch (err) {
        error.TooDeep => "nesting is too deep",
        error.UnexpectedEndOfInput => "unexpected end of input",
        else => "invalid JSON",
    };
    Diagnostic.report(diag, source, scanner.cursor, message);
    return error.SyntaxError;
}

fn parseValue(arena: Allocator, scanner: *std.json.Scanner, depth: usize) ScanError!Value {
    return Walker(std.json.Scanner, ScanError).value(arena, scanner, depth);
}

/// The tree builder, for a whole-input `std.json.Scanner` or a streaming `std.json.Reader`;
/// both have `nextAlloc`, `peekNextTokenType`, and `next`.
fn Walker(comptime Source: type, comptime WalkError: type) type {
    return struct {
        fn value(arena: Allocator, scanner: *Source, depth: usize) WalkError!Value {
            if (depth > max_depth) return error.TooDeep;
            const token = try scanner.nextAlloc(arena, .alloc_always);
            return switch (token) {
                .null => .null,
                .true => .{ .bool = true },
                .false => .{ .bool = false },
                .allocated_number => |text| number(text),
                .allocated_string => |text| .{ .string = text },
                .array_begin => blk: {
                    var array: Array = .empty;
                    while (try scanner.peekNextTokenType() != .array_end) {
                        try array.append(arena, try value(arena, scanner, depth + 1));
                    }
                    _ = try scanner.next();
                    break :blk .{ .array = array };
                },
                .object_begin => blk: {
                    var table: Table = .empty;
                    while (true) {
                        const key_token = try scanner.nextAlloc(arena, .alloc_always);
                        const key = switch (key_token) {
                            .allocated_string => |k| k,
                            .object_end => break,
                            else => return error.SyntaxError,
                        };
                        const item = try value(arena, scanner, depth + 1);
                        // A duplicate key keeps the last value, as most JSON readers do.
                        try table.put(arena, key, item);
                    }
                    break :blk .{ .table = table };
                },
                else => error.SyntaxError,
            };
        }
    };
}

const StreamError = std.json.Reader.AllocError || std.json.Reader.PeekError || error{TooDeep};

/// Parses one JSON document read from `reader`, without holding the whole text: memory
/// grows with the tree, not the file. Errors carry the line and column.
pub fn parseReader(
    arena: Allocator,
    reader: *std.Io.Reader,
    diag: ?*Diagnostic,
) (Error || error{ReadFailed})!Value {
    if (reader.peek(3)) |head| {
        if (bomLength(head) > 0) reader.toss(3);
    } else |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => {},
    }
    var scanner: std.json.Reader = .init(arena, reader);
    var position: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);
    const result = Walker(std.json.Reader, StreamError).value(arena, &scanner, 0);
    const value = result catch |err| return failStream(&position, diag, err);
    const end = scanner.next() catch |err| return failStream(&position, diag, err);
    if (end != .end_of_document) {
        return failStream(&position, diag, error.SyntaxError);
    }
    return value;
}

fn failStream(
    position: *const std.json.Diagnostics,
    diag: ?*Diagnostic,
    err: StreamError,
) (Error || error{ReadFailed}) {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
        else => {},
    }
    if (diag) |d| d.* = .{
        .line = @intCast(position.getLine()),
        .column = @intCast(position.getColumn()),
        .message = switch (err) {
            error.TooDeep => "nesting is too deep",
            error.UnexpectedEndOfInput => "unexpected end of input",
            else => "invalid JSON",
        },
    };
    return error.SyntaxError;
}

fn number(text: []const u8) Value {
    if (std.json.isNumberFormattedLikeAnInteger(text)) {
        if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .int = i } else |_| {}
    }
    // The scanner has validated the syntax, so this can only fail on a syntax error.
    return .{ .float = std.fmt.parseFloat(f64, text) catch unreachable };
}

/// How `write` lays the JSON out.
pub const WriteOptions = struct {
    /// Spaces per level; zero writes one line.
    indent: u8 = 2,
};

/// What writing can fail with: the writer, or a value JSON cannot hold.
pub const WriteError = std.Io.Writer.Error || error{Unrepresentable};

/// Writes `value` as JSON followed by a newline. `inf` and `nan` have no JSON spelling and
/// are `error.Unrepresentable`.
pub fn write(writer: *std.Io.Writer, value: Value, options: WriteOptions) WriteError!void {
    try writeValue(writer, value, options, 0);
    try writer.writeByte('\n');
}

fn writeValue(
    writer: *std.Io.Writer,
    value: Value,
    options: WriteOptions,
    level: usize,
) WriteError!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) return error.Unrepresentable;
            try writeFloat(writer, f);
        },
        .string => |s| try writeString(writer, s),
        .array => |a| {
            if (a.items.len == 0) return writer.writeAll("[]");
            try writer.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try newline(writer, options, level + 1);
                try writeValue(writer, item, options, level + 1);
            }
            try newline(writer, options, level);
            try writer.writeByte(']');
        },
        .table => |t| {
            if (t.count() == 0) return writer.writeAll("{}");
            try writer.writeByte('{');
            var it = t.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try newline(writer, options, level + 1);
                try writeString(writer, entry.key_ptr.*);
                try writer.writeAll(if (options.indent == 0) ":" else ": ");
                try writeValue(writer, entry.value_ptr.*, options, level + 1);
            }
            try newline(writer, options, level);
            try writer.writeByte('}');
        },
    }
}

/// Writes `value` on one line, spaced as people write it (`{"a": [1, 2]}`), without a
/// trailing newline.
pub fn writeInline(writer: *std.Io.Writer, value: Value) WriteError!void {
    switch (value) {
        .array => |a| {
            try writer.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeInline(writer, item);
            }
            try writer.writeByte(']');
        },
        .table => |t| {
            try writer.writeByte('{');
            var it = t.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writeString(writer, entry.key_ptr.*);
                try writer.writeAll(": ");
                try writeInline(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        else => try writeValue(writer, value, .{ .indent = 0 }, 0),
    }
}

fn newline(writer: *std.Io.Writer, options: WriteOptions, level: usize) std.Io.Writer.Error!void {
    if (options.indent == 0) return;
    try writer.writeByte('\n');
    try writer.splatByteAll(' ', level * options.indent);
}

/// Writes `s` as a JSON string literal.
pub fn writeString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

const testing = std.testing;

fn roundTrip(source: []const u8, options: WriteOptions, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try parse(arena.allocator(), source, null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, options);
    try testing.expectEqualStrings(expected, out.written());
}

test "parse scalars and containers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\{"a": 1, "b": [true, null, 2.5, "x\n"], "c": {"d": -9223372036854775808}, "e": 1e400}
    , null);
    try testing.expectEqual(1, v.lookup("a").?.int);
    try testing.expectEqual(true, v.lookup("b.0").?.bool);
    try testing.expectEqual(Value.null, v.lookup("b.1").?);
    try testing.expectEqual(2.5, v.lookup("b.2").?.float);
    try testing.expectEqualStrings("x\n", v.lookup("b.3").?.string);
    try testing.expectEqual(std.math.minInt(i64), v.lookup("c.d").?.int);
    try testing.expect(std.math.isInf(v.lookup("e").?.float));
}

test "big integers become floats" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "18446744073709551616", null);
    try testing.expectEqual(18446744073709551616.0, v.float);
}

test "syntax errors carry a position" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.SyntaxError,
        parse(arena.allocator(), "{\n  \"a\": tru\n}", &diag),
    );
    try testing.expectEqual(2, diag.line);
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "1 2", &diag));
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "[1,", &diag));
    try testing.expectEqualStrings("unexpected end of input", diag.message);
}

test "nesting is bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var deep: [2 * (max_depth + 2)]u8 = undefined;
    @memset(deep[0 .. max_depth + 2], '[');
    @memset(deep[max_depth + 2 ..], ']');
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), &deep, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);
}

test "write pretty and compact" {
    try roundTrip(
        \\{"a":1,"b":[true,"q\"\u0001"],"c":{},"d":[],"e":1.0}
    , .{},
        \\{
        \\  "a": 1,
        \\  "b": [
        \\    true,
        \\    "q\"\u0001"
        \\  ],
        \\  "c": {},
        \\  "d": [],
        \\  "e": 1.0
        \\}
        \\
    );
    try roundTrip("{\"a\": [1, 2]}", .{ .indent = 0 }, "{\"a\":[1,2]}\n");
}

test "non-finite floats are unrepresentable" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(
        error.Unrepresentable,
        write(&out.writer, .{ .float = std.math.nan(f64) }, .{}),
    );
}

test parseWithComments {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try parseWithComments(a,
        \\{
        \\  // The port.
        \\  "port": 8080, /* or 80 */
        \\  "url": "http://x//y/*z*/",
        \\  "tags": ["a", "b",],
        \\  "nested": {"k": "\"//\"",},
        \\}
    , null);
    try testing.expectEqual(8080, value.lookup("port").?.int);
    try testing.expectEqualStrings("http://x//y/*z*/", value.lookup("url").?.string);
    try testing.expectEqual(2, value.lookup("tags").?.array.items.len);
    try testing.expectEqualStrings("\"//\"", value.lookup("nested.k").?.string);

    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parseWithComments(a, "{\n/* open", &diag));
    // A comment before the error does not move it.
    const source = "{ /* x\n */\n\"a\" 1}";
    try testing.expectError(error.SyntaxError, parseWithComments(a, source, &diag));
    try testing.expectEqual(3, diag.line);
}

test parseReader {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The document arrives in small pieces, through a small buffer.
    const source =
        \\{"servers": [{"host": "a", "port": 1}, {"host": "b"}], "n": 1.5}
    ;
    var buffer: [8]u8 = undefined;
    var chunked: std.testing.Reader = .init(&buffer, &.{
        .{ .buffer = source[0..10] },
        .{ .buffer = source[10..27] },
        .{ .buffer = source[27..] },
    });
    chunked.artificial_limit = .limited(3);
    const value = try parseReader(a, &chunked.interface, null);
    try testing.expect(value.eql(try parse(a, source, null)));

    var diag: Diagnostic = .{};
    var broken: std.Io.Reader = .fixed("{\n  \"a\": [1,\n  }");
    try testing.expectError(error.SyntaxError, parseReader(a, &broken, &diag));
    try testing.expectEqual(3, diag.line);
}
