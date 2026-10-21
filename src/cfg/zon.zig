//! ZON (Zig Object Notation) <-> `Value`. Reading uses the compiler's own front end,
//! `std.zig.Ast` and `std.zig.ZonGen`, so what reads here is exactly what `@import` of a
//! `.zon` file accepts, and errors carry the compiler's messages.
//!
//! | ZON                                    | `Value`                                     |
//! |----------------------------------------|---------------------------------------------|
//! | `.{ .a = 1, .@"b c" = 2 }`             | `.table`                                    |
//! | `.{ 1, 2 }`                            | `.array`                                    |
//! | `.{}`                                  | an empty `.table` (see below)               |
//! | `"text"`, `\\multi-line`               | `.string`                                   |
//! | `.enum_literal`                        | `.string` (`"enum_literal"`)                |
//! | `'c'`                                  | `.int` (the code point)                     |
//! | `42`, `0x2A`, `1_000`                  | `.int`; past `i64`, `.float` as JSON does   |
//! | `1.5`, `0x1p4`, `inf`, `-inf`, `nan`   | `.float`                                    |
//! | `true`, `false`, `null`                | `.bool`, `.null`                            |
//!
//! `.{}` is both the empty struct and the empty tuple; it reads as an empty table, so an
//! empty array writes as `.{}` and reads back as an empty table. `decode` accepts an
//! empty table for a slice, so typed configuration is unaffected. An enum literal and a
//! string are indistinguishable after reading. Table keys must be non-empty and must not
//! contain a zero byte: the compiler rejects both, so the writer does too.
//!
//! Diagnostics: `message` is the compiler's text, allocated in the arena given to `parse`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const writeFloat = @import("value.zig").writeFloat;
const Diagnostic = @import("Diagnostic.zig");

/// What parsing can fail with; the diagnostic says where.
pub const Error = error{SyntaxError} || Allocator.Error;

/// Nesting deeper than this is rejected, which bounds the parser's and the writer's
/// recursion. Every `.{` counts as one level, the outermost included.
pub const max_depth = 256;

/// Parses one ZON document. All memory comes from `arena`; the result shares nothing with
/// `source`.
pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diagnostic) Error!Value {
    const text = try arena.dupeSentinel(u8, source, 0);
    if (tooDeep(text)) |offset| {
        Diagnostic.report(diag, source, offset, "nesting is too deep");
        return error.SyntaxError;
    }
    const tree = try Ast.parse(arena, text, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(arena, tree, .{});
    if (zoir.hasCompileErrors()) {
        const err = zoir.compile_errors[0];
        const offset = if (err.token.unwrap()) |token|
            tree.tokenStart(token) + err.node_or_offset
        else
            tree.tokenStart(tree.firstToken(@fromBackingInt(err.node_or_offset)));
        Diagnostic.report(diag, source, offset, err.msg.get(&zoir));
        return error.SyntaxError;
    }
    const reader: Reader = .{ .arena = arena, .tree = &tree, .zoir = &zoir };
    return reader.value(.root);
}

/// A field (`.name = value`) or a struct literal (`.{ ... }`) as it sits in the source, for
/// editing in place.
pub const Span = struct {
    kind: Kind,
    /// A field's key path; a container's path.
    path: []const []const u8,
    /// A field: the start of its `.name`. A container: the start of its `{`.
    start: usize,
    /// A field: after its value, and after the comma that follows it, if any. A container:
    /// the start of its `}`.
    end: usize,
    /// A field's value.
    value_start: usize = 0,
    value_end: usize = 0,
    /// A container: its fields are one to a line.
    multiline: bool = false,
    /// A container: how many fields it has.
    fields: usize = 0,

    /// A container's field, or a container.
    pub const Kind = enum { field, container };
};

/// Parses `source` and returns its fields and struct literals, in order. Fails as `parse`
/// does.
pub fn spans(arena: Allocator, source: []const u8) Error![]const Span {
    const text = try arena.dupeSentinel(u8, source, 0);
    if (tooDeep(text) != null) return error.SyntaxError;
    const tree = try Ast.parse(arena, text, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(arena, tree, .{});
    if (zoir.hasCompileErrors()) return error.SyntaxError;
    var list: std.ArrayList(Span) = .empty;
    var walker: SpanWalker = .{ .arena = arena, .tree = &tree, .zoir = &zoir, .list = &list };
    try walker.walk(.root, &.{});
    return list.items;
}

const SpanWalker = struct {
    arena: Allocator,
    tree: *const Ast,
    zoir: *const Zoir,
    list: *std.ArrayList(Span),

    fn tokenEnd(w: SpanWalker, token: Ast.TokenIndex) usize {
        return w.tree.tokenStart(token) + w.tree.tokenSlice(token).len;
    }

    fn walk(w: SpanWalker, index: Zoir.Node.Index, at: []const []const u8) Allocator.Error!void {
        const tree = w.tree;
        switch (index.get(w.zoir)) {
            .empty_literal => {
                const node = index.getAstNode(w.zoir);
                const close = tree.lastToken(node);
                try w.list.append(w.arena, .{
                    .kind = .container,
                    .path = at,
                    .start = tree.tokenStart(close - 1),
                    .end = tree.tokenStart(close),
                });
            },
            .struct_literal => |fields| {
                const node = index.getAstNode(w.zoir);
                const close = tree.lastToken(node);
                const open = tree.firstToken(node) + 1;
                const inside = tree.source[tree.tokenStart(open)..tree.tokenStart(close)];
                try w.list.append(w.arena, .{
                    .kind = .container,
                    .path = at,
                    .start = tree.tokenStart(open),
                    .end = tree.tokenStart(close),
                    .multiline = std.mem.indexOfScalar(u8, inside, '\n') != null,
                    .fields = fields.names.len,
                });
                for (fields.names, 0..) |name, i| {
                    const value_index = fields.vals.at(@intCast(i));
                    const value_node = value_index.getAstNode(w.zoir);
                    const first = tree.firstToken(value_node);
                    const last = tree.lastToken(value_node);
                    // `.name = value`: the `.` is three tokens before the value.
                    const comma = last + 1 < tree.tokens.len and tree.tokenTag(last + 1) == .comma;
                    const path = try w.arena.alloc([]const u8, at.len + 1);
                    @memcpy(path[0..at.len], at);
                    path[at.len] = name.get(w.zoir);
                    try w.list.append(w.arena, .{
                        .kind = .field,
                        .path = path,
                        .start = tree.tokenStart(first - 3),
                        .end = if (comma) w.tokenEnd(last + 1) else w.tokenEnd(last),
                        .value_start = tree.tokenStart(first),
                        .value_end = w.tokenEnd(last),
                    });
                    try w.walk(value_index, path);
                }
            },
            .array_literal => |range| for (0..range.len) |i| {
                const path = try w.arena.alloc([]const u8, at.len + 1);
                @memcpy(path[0..at.len], at);
                path[at.len] = try std.fmt.allocPrint(w.arena, "{d}", .{i});
                try w.walk(range.at(@intCast(i)), path);
            },
            else => {},
        }
    }
};

/// Writes `value` on one line, as it appears after `.name = `.
pub fn writeInline(writer: *std.Io.Writer, value: Value) WriteError!void {
    return writeValue(writer, value, .{ .indent = 0 }, 0);
}

/// Writes `.key`, or `.@"key"` when the key is not a plain identifier.
pub fn writeFieldName(writer: *std.Io.Writer, key: []const u8) WriteError!void {
    return writeKey(writer, key);
}

/// The offset of the token at which the source nests deeper than `max_depth`, or null.
///
/// The compiler's parser is recursive and has no depth limit of its own, so this bounds
/// what reaches it: brackets, runs of prefix tokens (`- - -x`, `.`), and keywords (none of
/// which ZON allows, but each can open a nested expression) are each limited.
fn tooDeep(source: [:0]const u8) ?usize {
    var tokenizer: std.zig.Tokenizer = .init(source);
    var depth: usize = 0;
    var run: usize = 0;
    var keywords: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return null,
            .l_brace, .l_paren, .l_bracket => {
                depth += 1;
                run = 0;
            },
            .r_brace, .r_paren, .r_bracket => {
                depth -|= 1;
                run = 0;
            },
            .identifier,
            .number_literal,
            .char_literal,
            .string_literal,
            .multiline_string_literal_line,
            .comma,
            .equal,
            => run = 0,
            else => {
                run += 1;
                if (std.mem.startsWith(u8, @tagName(token.tag), "keyword_")) keywords += 1;
            },
        }
        if (depth > max_depth or run > max_depth or keywords > max_depth) {
            return token.loc.start;
        }
    }
}

/// Converts a `Zoir` without errors to a `Value`. Recursion is bounded by `tooDeep`.
const Reader = struct {
    arena: Allocator,
    tree: *const Ast,
    zoir: *const Zoir,

    fn value(r: Reader, index: Zoir.Node.Index) Allocator.Error!Value {
        return switch (index.get(r.zoir)) {
            .true => .{ .bool = true },
            .false => .{ .bool = false },
            .null => .null,
            .pos_inf => .{ .float = std.math.inf(f64) },
            .neg_inf => .{ .float = -std.math.inf(f64) },
            .nan => .{ .float = std.math.nan(f64) },
            .int_literal => |int| switch (int) {
                .small => |i| .{ .int = i },
                .big => |big| if (big.toInt(i64)) |i|
                    .{ .int = i }
                else |_|
                    .{ .float = big.toFloat(f64, .nearest_even)[0] },
            },
            .float_literal => .{ .float = r.float(index) },
            .char_literal => |c| .{ .int = c },
            .enum_literal => |name| .{ .string = name.get(r.zoir) },
            .string_literal => |s| .{ .string = s },
            .empty_literal => .empty_table,
            .array_literal => |range| blk: {
                var array: Array = try .initCapacity(r.arena, range.len);
                for (0..range.len) |i| {
                    array.appendAssumeCapacity(try r.value(range.at(@intCast(i))));
                }
                break :blk .{ .array = array };
            },
            .struct_literal => |fields| blk: {
                var table: Table = .empty;
                try table.ensureTotalCapacity(r.arena, fields.names.len);
                for (fields.names, 0..) |name, i| {
                    const item = try r.value(fields.vals.at(@intCast(i)));
                    // ZonGen rejects duplicate names.
                    table.putAssumeCapacityNoClobber(name.get(r.zoir), item);
                }
                break :blk .{ .table = table };
            },
        };
    }

    /// Reads a float literal from its token as an `f64`. `Zoir` holds an `f128`, and
    /// narrowing that could round twice.
    fn float(r: Reader, index: Zoir.Node.Index) f64 {
        const tree = r.tree;
        const node = index.getAstNode(r.zoir);
        const negative = tree.nodeTag(node) == .negation;
        const literal = if (negative) tree.nodeData(node).node else node;
        const text = tree.tokenSlice(tree.nodeMainToken(literal));
        const f = std.fmt.parseFloat(f64, text) catch unreachable; // ZonGen has validated it.
        return if (negative) -f else f;
    }
};

/// How `write` lays the ZON out.
pub const WriteOptions = struct {
    /// Spaces per level; zero writes one line.
    indent: u8 = 4,
};

/// What writing can fail with: the writer, or a value ZON cannot hold.
pub const WriteError = std.Io.Writer.Error || error{Unrepresentable};

/// Writes `value` as ZON in `zig fmt` style, followed by a newline. A non-empty table is
/// one field per line; an array is one line when no item is a non-empty container. A key
/// that is empty or contains a zero byte, and nesting deeper than `max_depth`, are
/// `error.Unrepresentable`.
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
        .float => |f| try writeFloat(writer, f),
        .string, .datetime => |s| try writeString(writer, s),
        .array => |a| {
            if (level == max_depth) return error.Unrepresentable;
            if (a.items.len == 0) return writer.writeAll(".{}");
            const one_line = options.indent == 0 or for (a.items) |item| {
                if (!isFlat(item)) break false;
            } else true;
            // `zig fmt` writes a one-item tuple without the inner spaces.
            const pad = one_line and a.items.len > 1;
            try writer.writeAll(if (pad) ".{ " else ".{");
            for (a.items, 0..) |item, i| {
                if (one_line and i > 0) try writer.writeAll(", ");
                if (!one_line) try newline(writer, options, level + 1);
                try writeValue(writer, item, options, level + 1);
                if (!one_line) try writer.writeByte(',');
            }
            if (!one_line) try newline(writer, options, level);
            try writer.writeAll(if (pad) " }" else "}");
        },
        .table => |t| {
            if (level == max_depth) return error.Unrepresentable;
            if (t.count() == 0) return writer.writeAll(".{}");
            const one_line = options.indent == 0;
            try writer.writeAll(if (one_line) ".{ " else ".{");
            var it = t.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (one_line and !first) try writer.writeAll(", ");
                first = false;
                if (!one_line) try newline(writer, options, level + 1);
                try writeKey(writer, entry.key_ptr.*);
                try writer.writeAll(" = ");
                try writeValue(writer, entry.value_ptr.*, options, level + 1);
                if (!one_line) try writer.writeByte(',');
            }
            if (!one_line) try newline(writer, options, level);
            try writer.writeAll(if (one_line) " }" else "}");
        },
    }
}

/// Whether `value` fits on one line inside an array: a scalar or an empty container.
fn isFlat(value: Value) bool {
    return switch (value) {
        .array => |a| a.items.len == 0,
        .table => |t| t.count() == 0,
        else => true,
    };
}

fn newline(writer: *std.Io.Writer, options: WriteOptions, level: usize) std.Io.Writer.Error!void {
    try writer.writeByte('\n');
    try writer.splatByteAll(' ', level * options.indent);
}

/// Writes `.key`, or `.@"key"` when the key is not a plain identifier.
fn writeKey(writer: *std.Io.Writer, key: []const u8) WriteError!void {
    if (key.len == 0 or std.mem.indexOfScalar(u8, key, 0) != null) return error.Unrepresentable;
    try writer.print(".{f}", .{std.zig.fmtIdPU(key)});
}

/// Writes `s` as a Zig string literal. Valid UTF-8 is kept; control characters, invalid
/// UTF-8, and Unicode line breaks are escaped.
pub fn writeString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writer.print("\"{f}\"", .{std.zig.fmtString(s)});
}

const testing = std.testing;

fn expectParseError(source: []const u8, message: []const u8, line: u32, column: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), source, &diag));
    try testing.expectEqualStrings(message, diag.message);
    try testing.expectEqual(line, diag.line);
    try testing.expectEqual(column, diag.column);
}

/// Writes `value` with `options` and checks the exact text, that it reads back equal, and
/// that `zig fmt` would leave it unchanged.
fn expectWrite(value: Value, options: WriteOptions, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try write(&out.writer, value, options);
    try testing.expectEqualStrings(expected, out.written());
    try testing.expect(value.eql(try parse(a, out.written(), null)));
    if (options.indent == 4) {
        const tree = try Ast.parse(a, try a.dupeSentinel(u8, out.written(), 0), .{ .mode = .zon });
        try testing.expectEqual(0, tree.errors.len);
        try testing.expectEqualStrings(expected, try tree.renderAlloc(a));
    }
}

test "structs, tuples, and the empty literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\// A comment.
        \\.{
        \\    .name = "termancy",
        \\    .@"quoted key" = 1,
        \\    .@"while" = .{ 1, .{ 2, 3 }, .{} },
        \\    .nested = .{ .deeper = .{ .x = true } },
        \\    .empty = .{},
        \\    .@"\x41\u{e9}" = null,
        \\}
    , null);
    try testing.expectEqualStrings("termancy", v.lookup("name").?.string);
    try testing.expectEqual(1, v.table.get("quoted key").?.int);
    const tuple = v.table.get("while").?.array.items;
    try testing.expectEqual(3, tuple.len);
    try testing.expectEqual(1, tuple[0].int);
    try testing.expectEqual(3, tuple[1].array.items[1].int);
    try testing.expectEqual(0, tuple[2].table.count());
    try testing.expectEqual(true, v.lookup("nested.deeper.x").?.bool);
    try testing.expectEqual(0, v.lookup("empty").?.table.count());
    try testing.expectEqual(Value.null, v.table.get("A\u{e9}").?);
    const keys = v.table.keys();
    try testing.expectEqualStrings("name", keys[0]);
    try testing.expectEqualStrings("A\u{e9}", keys[keys.len - 1]);
}

test "trailing commas and a top-level scalar" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, ".{ .a = .{ 1, 2, }, }", null);
    try testing.expectEqual(2, v.lookup("a.1").?.int);
    try testing.expectEqual(7, (try parse(a, "  7 // seven\n", null)).int);
    try testing.expectEqual(Value.null, try parse(a, "null", null));
    try testing.expectEqual(0, (try parse(a, ".{}", null)).table.count());
}

test "strings and escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a,
        \\.{
        \\    "\n\r\t\\\'\"\x00\x7f\u{1F40D}\u{e9}",
        \\    "raw \u{e9} é '",
        \\    \\first "line" \n
        \\    \\
        \\    \\third\\
        \\    ,
        \\    \\only
        \\    ,
        \\    "",
        \\}
    , null);
    const items = v.array.items;
    try testing.expectEqualStrings("\n\r\t\\'\"\x00\x7f\u{1F40D}\u{e9}", items[0].string);
    try testing.expectEqualStrings("raw \u{e9} é '", items[1].string);
    try testing.expectEqualStrings("first \"line\" \\n\n\nthird\\\\", items[2].string);
    try testing.expectEqualStrings("only", items[3].string);
    try testing.expectEqualStrings("", items[4].string);
    const crlf = try parse(a, ".{ .s = \r\n\\\\a\r\n\\\\b\r\n}", null);
    try testing.expectEqualStrings("a\nb", crlf.lookup("s").?.string);
}

test "character literals are integers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = ".{ 'a', '\\n', '\\x7f', '\\u{1F40D}', 'é', '\\'' }";
    const v = try parse(arena.allocator(), source, null);
    const expected = [_]i64{ 'a', '\n', 0x7f, 0x1F40D, 0xe9, '\'' };
    for (expected, v.array.items) |e, item| try testing.expectEqual(e, item.int);
}

test "integers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\.{
        \\    0,                    42,                   -17,
        \\    1_000_000,            0x2A,                 0xdead_BEEF,
        \\    0o755,                0b1010_1010,          -0x10,
        \\    2147483648,           -2147483649,
        \\    9223372036854775807,  -9223372036854775808,
        \\    9223372036854775808,  18446744073709551616, -0x8000_0000_0000_0001,
        \\}
    , null);
    const ints = [_]i64{
        0,                    42,          -17,
        1_000_000,            0x2A,        0xdeadbeef,
        0o755,                0b10101010,  -16,
        2147483648,           -2147483649, std.math.maxInt(i64),
        std.math.minInt(i64),
    };
    const items = v.array.items;
    for (ints, items[0..ints.len]) |e, item| try testing.expectEqual(e, item.int);
    // Past `i64`, the nearest float, as JSON reads them.
    try testing.expectEqual(9223372036854775808.0, items[13].float);
    try testing.expectEqual(18446744073709551616.0, items[14].float);
    try testing.expectEqual(-9223372036854775809.0, items[15].float);
}

test "floats" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\.{ 1.5, -0.0, 1e3, 1.5E-3, 1_0.2_5, 0x1p4, 0x1.8P-1, -2.5, inf, -inf, nan, 1e400,
        \\   0.1, 2.2250738585072014e-308, 5e-324, 1.7976931348623157e308 }
    , null);
    const items = v.array.items;
    const floats = [_]f64{ 1.5, -0.0, 1e3, 1.5e-3, 10.25, 16.0, 0.75, -2.5 };
    for (floats, items[0..floats.len]) |e, item| try testing.expectEqual(e, item.float);
    try testing.expect(std.math.signbit(items[1].float));
    try testing.expectEqual(std.math.inf(f64), items[8].float);
    try testing.expectEqual(-std.math.inf(f64), items[9].float);
    try testing.expect(std.math.isNan(items[10].float));
    try testing.expectEqual(std.math.inf(f64), items[11].float);
    // Read straight to `f64`, not through the compiler's `f128`.
    try testing.expectEqual(0.1, items[12].float);
    try testing.expectEqual(2.2250738585072014e-308, items[13].float);
    try testing.expectEqual(5e-324, items[14].float);
    try testing.expectEqual(std.math.floatMax(f64), items[15].float);
}

test "booleans, null, and enum literals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), ".{ true, false, null, .debug, .@\"two words\" }", null);
    const items = v.array.items;
    try testing.expectEqual(true, items[0].bool);
    try testing.expectEqual(false, items[1].bool);
    try testing.expectEqual(Value.null, items[2]);
    try testing.expectEqualStrings("debug", items[3].string);
    try testing.expectEqualStrings("two words", items[4].string);
}

test "syntax errors" {
    try expectParseError("", "expected expression, found 'EOF'", 1, 1);
    try expectParseError(".{\n    .a = ,\n}", "expected expression, found ','", 2, 10);
    try expectParseError(".{ .a = 1 .b = 2 }", "expected ',' after initializer", 1, 14);
    try expectParseError(".{ .a = 1, 2 }", "expected field initializer", 1, 12);
    try expectParseError(".{ 1, 2", "expected ',' after initializer", 1, 8);
    try expectParseError("1 2", "expected 'EOF', found 'a number literal'", 1, 3);
    try expectParseError("\"abc\n\"", "expected expression, found 'invalid token'", 1, 1);
    try expectParseError("\"\x01\"", "expected expression, found 'invalid token'", 1, 1);
}

test "what ZON does not allow" {
    try expectParseError("\n.{ .a = 1, .a = 2 }", "duplicate struct field name", 2, 5);
    try expectParseError(".{ .a = 1, .@\"a\" = 2 }", "duplicate struct field name", 1, 5);
    try expectParseError(".{ .a = x }", "invalid expression", 1, 9);
    try expectParseError("-0", "integer literal '-0' is ambiguous", 1, 2);
    try expectParseError("-nan", "expected number or 'inf' after '-'", 1, 1);
    try expectParseError("(1)", "expression grouping is not allowed in ZON", 1, 1);
    try expectParseError("1 + 2", "operator '+' is not allowed in ZON", 1, 3);
    try expectParseError("@as(u8, 1)", "builtin function calls are not allowed in ZON", 1, 1);
    try expectParseError("struct {}", "types are not available in ZON", 1, 1);
    try expectParseError("if (true) 1 else 2", "control flow is not allowed in ZON", 1, 1);
    try expectParseError("Foo{ .a = 1 }", "types are not available in ZON", 1, 1);
    try expectParseError(".{ .@\"\" = 1 }", "identifier cannot be empty", 1, 5);
    try expectParseError(".{ .@\"a\\x00\" = 1 }", "identifier cannot contain null bytes", 1, 5);
    try expectParseError(".{ .@\"\\q\" = 1 }", "invalid escape character: 'q'", 1, 8);
}

test "number and string errors point into the literal" {
    try expectParseError("\n  0x1G", "invalid digit 'G' for hex base", 2, 6);
    try expectParseError("1__0", "repeated digit separator", 1, 3);
    try expectParseError("1_", "trailing digit separator", 1, 2);
    try expectParseError("0X1", "base prefix must be lowercase", 1, 2);
    try expectParseError("012", "number '012' has leading zero", 1, 1);
    try expectParseError("\"a\\qb\"", "invalid escape character: 'q'", 1, 4);
    try expectParseError(
        "\"\\u{110000}\"",
        "unicode escape does not correspond to a valid unicode scalar value",
        1,
        10,
    );
    try expectParseError("'ab'", "expected single quote ('), found 'b'", 1, 3);
}

test "nesting is bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var deep: [3 * (max_depth + 1)]u8 = undefined;
    for (0..max_depth + 1) |i| @memcpy(deep[2 * i ..][0..2], ".{");
    @memset(deep[2 * (max_depth + 1) ..], '}');
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(a, &deep, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);
    try testing.expectEqual(2 * max_depth + 2, diag.column);
    // `max_depth` levels parse.
    var balanced: [3 * max_depth]u8 = undefined;
    for (0..max_depth) |i| @memcpy(balanced[2 * i ..][0..2], ".{");
    @memset(balanced[2 * max_depth ..], '}');
    _ = try parse(a, &balanced, null);
    // Long prefix runs and keyword chains, which the compiler's parser recurses on.
    var minus: [max_depth + 2]u8 = undefined;
    @memset(minus[0 .. max_depth + 1], '-');
    minus[max_depth + 1] = '1';
    try testing.expectError(error.SyntaxError, parse(a, &minus, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);
    var chain: std.ArrayList(u8) = .empty;
    for (0..max_depth + 1) |_| try chain.appendSlice(a, "if (x) ");
    try chain.append(a, '1');
    try testing.expectError(error.SyntaxError, parse(a, chain.items, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);
    // A few keywords reach the compiler, which explains what ZON does not allow.
    try expectParseError("if (x) if (y) 1", "control flow is not allowed in ZON", 1, 1);
}

test "write a representative document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try parse(arena.allocator(),
        \\.{ .name = "termancy \"v1\"", .ports = .{ 8000, 8001 }, .ratio = 0.5,
        \\  .server = .{ .host = "localhost", .tls = .{ .enabled = true } },
        \\  .users = .{ .{ .name = "a" }, .{} }, .mixed = .{ 1, .{ 2 } },
        \\  .empty = .{}, .@"not an id" = null, .@"if" = -inf, .u8 = 'x', ._ = .flag }
    , null);
    try expectWrite(value, .{},
        \\.{
        \\    .name = "termancy \"v1\"",
        \\    .ports = .{ 8000, 8001 },
        \\    .ratio = 0.5,
        \\    .server = .{
        \\        .host = "localhost",
        \\        .tls = .{
        \\            .enabled = true,
        \\        },
        \\    },
        \\    .users = .{
        \\        .{
        \\            .name = "a",
        \\        },
        \\        .{},
        \\    },
        \\    .mixed = .{
        \\        1,
        \\        .{2},
        \\    },
        \\    .empty = .{},
        \\    .@"not an id" = null,
        \\    .@"if" = -inf,
        \\    .u8 = 120,
        \\    ._ = "flag",
        \\}
        \\
    );
    var small: Value = .empty_table;
    const a = arena.allocator();
    try small.table.put(a, "tls", value.lookup("server.tls").?);
    try small.table.put(a, "users", value.table.get("users").?);
    try small.table.put(a, "one", value.table.get("mixed").?.array.items[1]);
    try expectWrite(small, .{ .indent = 0 },
        \\.{ .tls = .{ .enabled = true }, .users = .{ .{ .name = "a" }, .{} }, .one = .{2} }
        \\
    );
}

test "write scalars" {
    try expectWrite(.null, .{}, "null\n");
    try expectWrite(.{ .bool = false }, .{}, "false\n");
    try expectWrite(.{ .int = std.math.minInt(i64) }, .{}, "-9223372036854775808\n");
    try expectWrite(.{ .float = 2.0 }, .{}, "2.0\n");
    try expectWrite(.{ .float = -0.0 }, .{}, "-0.0\n");
    try expectWrite(.{ .float = 1e300 }, .{}, "1e300\n");
    try expectWrite(.{ .float = -5e-324 }, .{}, "-5e-324\n");
    try expectWrite(.{ .float = std.math.inf(f64) }, .{}, "inf\n");
    try expectWrite(.empty_table, .{}, ".{}\n");
    try expectWrite(.{ .string = "" }, .{}, "\"\"\n");
}

test "write escapes strings and quotes keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value: Value = .empty_table;
    try value.table.put(a, "s", .{ .string = "\x00\t\n\r\x1f\x7f\\\"'é\u{1F40D}\xff\u{2028}" });
    try value.table.put(a, "a b", .{ .int = 1 });
    try value.table.put(a, "1st", .{ .int = 2 });
    try value.table.put(a, "\xff", .{ .int = 3 });
    try value.table.put(a, "é", .{ .int = 4 });
    try value.table.put(a, "true", .{ .int = 5 });
    try expectWrite(value, .{},
        \\.{
        \\    .s = "\x00\t\n\r\x1f\x7f\\\"'é🐍\xff\xe2\x80\xa8",
        \\    .@"a b" = 1,
        \\    .@"1st" = 2,
        \\    .@"\xff" = 3,
        \\    .@"é" = 4,
        \\    .true = 5,
        \\}
        \\
    );
}

test "nan writes and reads back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .float = -std.math.nan(f64) }, .{});
    try testing.expectEqualStrings("nan\n", out.written());
    try testing.expect(std.math.isNan((try parse(arena.allocator(), out.written(), null)).float));
}

test "an empty array writes as .{} and reads back as an empty table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .array = .empty }, .{});
    try testing.expectEqualStrings(".{}\n", out.written());
    try testing.expect((try parse(arena.allocator(), out.written(), null)).eql(.empty_table));
}

test "write rejects what ZON cannot express" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var empty_key: Value = .empty_table;
    try empty_key.table.put(a, "", .{ .int = 1 });
    try testing.expectError(error.Unrepresentable, write(&out.writer, empty_key, .{}));
    var nul_key: Value = .empty_table;
    try nul_key.table.put(a, "a\x00", .{ .int = 1 });
    try testing.expectError(error.Unrepresentable, write(&out.writer, nul_key, .{}));

    // `max_depth` nested arrays write; one more does not.
    var deep: Value = .{ .int = 1 };
    for (0..max_depth) |_| {
        var array: Array = .empty;
        try array.append(a, deep);
        deep = .{ .array = array };
    }
    out.clearRetainingCapacity();
    try write(&out.writer, deep, .{ .indent = 0 });
    try testing.expect(deep.eql(try parse(a, out.written(), null)));
    var array: Array = .empty;
    try array.append(a, deep);
    try testing.expectError(error.Unrepresentable, write(&out.writer, .{ .array = array }, .{}));
}

test "round trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_][]const u8{
        ".{}",
        ".{ .a = 1, .b = -2.5e10, .c = \"x\" }",
        ".{ .d = .{ .{ 1 }, .{ .e = .{} }, .{ 1, \"two\", 3.0 } } }",
        ".{ .max = 9223372036854775807, .min = -9223372036854775808, .f = .{ 0.1, 1e300 } }",
        "\"top\"",
        ".{ .@\"weird \\\"key\\\"\" = \"\\x01\", .s = \\\\multi\n\\\\line\n}",
    };
    for (sources) |source| {
        const value = try parse(a, source, null);
        var out: std.Io.Writer.Allocating = .init(a);
        try write(&out.writer, value, .{});
        try testing.expect(value.eql(try parse(a, out.written(), null)));
    }
}

test "a parsed tree shares nothing with the source" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var source = ".{ .plain = \"abc\", .e = .lit }".*;
    const v = try parse(arena.allocator(), &source, null);
    @memset(&source, 'x');
    try testing.expectEqualStrings("abc", v.lookup("plain").?.string);
    try testing.expectEqualStrings("lit", v.lookup("e").?.string);
    try testing.expectEqualStrings("plain", v.table.keys()[0]);
}
