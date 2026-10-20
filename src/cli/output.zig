//! `ctx.render(value)`: one value written as the user asked with `-o`/`--output` (a
//! command with `.output = true`), so a command prints for people and for programs
//! without two code paths.
//!
//! - `json`: the value as JSON, indented, then a newline (`std.json`'s rules: structs are
//!   objects, slices arrays, optionals null, enums their names).
//! - `jsonl`: a list as one compact JSON value per line, for `jq` and streaming readers;
//!   anything else as a single compact line.
//! - `yaml`: the same tree as JSON, in YAML's block style: structs are mappings, slices
//!   sequences, null `null`; strings are quoted when they would read as something else
//!   (`"true"`, `"8080"`, `""`, `"a: b"`). A type with a `format` method is its text.
//! - `text`: a type's own `format` method if it has one; a list of structs as a table with
//!   a header row; a struct as `field: value` lines; a list of other things one per line;
//!   anything else as `{any}` prints it, strings as they are. Columns line up by display
//!   width (`term.width`), so wide and combining characters do not shift them.
//!
//! A struct chooses its text columns, which JSON and YAML ignore, keeping every field:
//!
//! ```zig
//! pub const Repo = struct {
//!     name: []const u8,
//!     dirty: u32,
//!     path: []const u8,
//!     // Only these, in this order, under these headers; `path` is left out.
//!     pub const text_columns = .{ .name = "REPOSITORY", .dirty = "CHANGES" };
//! };
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const display = @import("term").width;
const isString = @import("field").isString;

/// What `-o`/`--output` chooses.
pub const Format = @import("spec.zig").Output;

/// What `write` can fail with.
pub const Error = Writer.Error || Allocator.Error;

/// Writes `value` in `format`. `arena` holds the cells of a table while it is laid out.
pub fn write(arena: Allocator, w: *Writer, format: Format, value: anytype) Error!void {
    switch (format) {
        .json => {
            std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, w) catch |err|
                return switch (err) {
                    error.WriteFailed => error.WriteFailed,
                };
            try w.writeByte('\n');
        },
        .jsonl => if (comptime isList(@TypeOf(value))) {
            for (value) |item| try jsonLine(w, item);
        } else try jsonLine(w, value),
        .yaml => try yaml(w, value, 0, .top),
        .text => try text(arena, w, value),
    }
}

fn jsonLine(w: *Writer, value: anytype) Writer.Error!void {
    std.json.Stringify.value(value, .{}, w) catch |err| return switch (err) {
        error.WriteFailed => error.WriteFailed,
    };
    try w.writeByte('\n');
}

/// A slice, or a pointer to an array, of anything but bytes.
fn isList(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child != u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child != u8,
            else => false,
        },
        else => false,
    };
}

/// Where a YAML node starts: alone at the top, after `key:`, or after `- `.
const Position = enum { top, key, item };

/// Writes `value` as a YAML node whose entries, when it is a collection, are indented by
/// `indent`. A scalar ends its line; so does every entry of a collection.
fn yaml(w: *Writer, value: anytype, indent: usize, at: Position) Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime hasFormat(T)) {
        var buffer: [256]u8 = undefined;
        var fixed: Writer = .fixed(&buffer);
        // Text too long for the buffer is written as a plain-quoted scalar from the start.
        if (value.format(&fixed)) |_| {
            return yamlScalar(w, at, fixed.buffered());
        } else |_| {
            try yamlLead(w, at);
            try w.writeByte('"');
            var escaping: EscapingWriter = .{ .out = w };
            try value.format(&escaping.writer);
            return w.writeAll("\"\n");
        }
    }
    if (comptime isString(T)) return yamlScalar(w, at, value);
    switch (@typeInfo(T)) {
        .optional => return if (value) |inner| yaml(w, inner, indent, at) else {
            return yamlPlain(w, at, "null");
        },
        .null, .void => return yamlPlain(w, at, "null"),
        .bool => return yamlPlain(w, at, if (value) "true" else "false"),
        .int, .comptime_int => {
            try yamlLead(w, at);
            return w.print("{d}\n", .{value});
        },
        .comptime_float => return yaml(w, @as(f64, value), indent, at),
        .float => {
            if (std.math.isNan(value)) return yamlPlain(w, at, ".nan");
            if (std.math.isInf(value)) return yamlPlain(w, at, if (value > 0) ".inf" else "-.inf");
            try yamlLead(w, at);
            return w.print("{d}\n", .{value});
        },
        .@"enum" => return yamlScalar(w, at, @tagName(value)),
        .enum_literal => return yamlScalar(w, at, @tagName(value)),
        .pointer => |p| switch (p.size) {
            .slice => return yamlSequence(w, value, indent, at),
            .one => return yaml(w, value.*, indent, at),
            else => @compileError("cli.output: cannot write " ++ @typeName(T) ++ " as YAML"),
        },
        .array => return yamlSequence(w, &value, indent, at),
        .@"struct" => |s| {
            if (s.field_names.len == 0) return yamlPlain(w, at, "{}");
            try yamlOpen(w, at);
            inline for (s.field_names, 0..) |name, i| {
                // After `- `, the first entry shares the dash's line.
                if (i > 0 or at != .item) try w.splatByteAll(' ', indent);
                try yamlKey(w, name);
                try yaml(w, @field(value, name), indent + 2, .key);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) {
                @compileError("cli.output: cannot write untagged " ++ @typeName(T) ++ " as YAML");
            }
            switch (value) {
                inline else => |payload, tag| {
                    if (@TypeOf(payload) == void) return yamlScalar(w, at, @tagName(tag));
                    try yamlOpen(w, at);
                    if (at != .item) try w.splatByteAll(' ', indent);
                    try yamlKey(w, @tagName(tag));
                    try yaml(w, payload, indent + 2, .key);
                },
            }
        },
        else => @compileError("cli.output: cannot write " ++ @typeName(T) ++ " as YAML"),
    }
}

fn yamlSequence(w: *Writer, items: anytype, indent: usize, at: Position) Writer.Error!void {
    if (comptime isString(@TypeOf(items))) return yamlScalar(w, at, items);
    if (items.len == 0) return yamlPlain(w, at, "[]");
    try yamlOpen(w, at);
    for (items, 0..) |item, i| {
        if (i > 0 or at != .item) try w.splatByteAll(' ', indent);
        try w.writeByte('-');
        try yaml(w, item, indent + 2, .item);
    }
}

/// Starts a collection: on its own lines after `key:`, on the dash's line after `-`.
fn yamlOpen(w: *Writer, at: Position) Writer.Error!void {
    switch (at) {
        .top => {},
        .key => try w.writeByte('\n'),
        .item => try w.writeByte(' '),
    }
}

/// What goes between `key:` or `-` and a scalar.
fn yamlLead(w: *Writer, at: Position) Writer.Error!void {
    if (at != .top) try w.writeByte(' ');
}

fn yamlPlain(w: *Writer, at: Position, plain: []const u8) Writer.Error!void {
    try yamlLead(w, at);
    try w.writeAll(plain);
    try w.writeByte('\n');
}

fn yamlKey(w: *Writer, key: []const u8) Writer.Error!void {
    try yamlString(w, key);
    try w.writeByte(':');
}

fn yamlScalar(w: *Writer, at: Position, string: []const u8) Writer.Error!void {
    try yamlLead(w, at);
    try yamlString(w, string);
    try w.writeByte('\n');
}

/// `string` plain when YAML would read it back as the same string, else double-quoted.
fn yamlString(w: *Writer, string: []const u8) Writer.Error!void {
    if (!needsQuotes(string)) return w.writeAll(string);
    try w.writeByte('"');
    try writeEscaped(w, string);
    try w.writeByte('"');
}

/// Whether `string` written plain would be read back as something else: nothing, a
/// boolean, null, a number, or the start of other syntax.
pub fn needsQuotes(string: []const u8) bool {
    if (string.len == 0) return true;
    if (string[0] == ' ' or string[string.len - 1] == ' ') return true;
    // Indicators that start other syntax: flow collections, anchors, tags, block scalars,
    // quotes, directives, comments, and `-`, `?`, `:` (sequence entries, keys).
    if (std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", string[0]) != null) return true;
    if (std.mem.indexOf(u8, string, ": ") != null or std.mem.indexOf(u8, string, " #") != null) {
        return true;
    }
    if (string[string.len - 1] == ':') return true;
    for (string) |c| if (c < 0x20 or c == 0x7f) return true;
    // YAML 1.1 readers still take these as booleans and null.
    const reserved = [_][]const u8{
        "true", "false", "yes", "no", "on", "off", "y", "n", "null", "~",
    };
    for (reserved) |word| if (std.ascii.eqlIgnoreCase(string, word)) return true;
    return looksNumeric(string);
}

/// Whether a YAML reader might take `string` as a number: decimal, `0x`, `0o`, `0b`,
/// with `_` separators or an exponent, `.inf`, `.nan`.
fn looksNumeric(string: []const u8) bool {
    if (std.fmt.parseFloat(f64, string)) |_| return true else |_| {}
    if (std.fmt.parseInt(i128, string, 0)) |_| return true else |_| {}
    const bare = if (string[0] == '+' or string[0] == '-') string[1..] else string;
    for ([_][]const u8{ ".inf", ".nan" }) |word| {
        if (std.ascii.eqlIgnoreCase(bare, word)) return true;
    }
    return false;
}

fn writeEscaped(w: *Writer, string: []const u8) Writer.Error!void {
    for (string) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
}

/// Escapes what a `format` method writes, for text longer than `yaml`'s buffer.
const EscapingWriter = struct {
    out: *Writer,
    writer: Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(io_w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *EscapingWriter = @fieldParentPtr("writer", io_w);
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try writeEscaped(self.out, bytes);
            written += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try writeEscaped(self.out, last);
        return written + last.len * splat;
    }
};

fn text(arena: Allocator, w: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (comptime hasFormat(T)) return w.print("{f}\n", .{value});
    if (comptime isString(T)) return w.print("{s}\n", .{value});
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) return list(arena, w, p.child, value) else {
            return text(arena, w, value.*);
        },
        .array => |a| return list(arena, w, a.child, &value),
        .@"struct" => {
            const columns = comptime columnsOf(T);
            var width: usize = 0;
            inline for (columns) |column| width = @max(width, display.of(column.title orelse
                column.field));
            inline for (columns) |column| {
                const title = column.title orelse column.field;
                try w.print("{s}:", .{title});
                try w.splatByteAll(' ', width - display.of(title) + 1);
                try w.print("{s}\n", .{try cell(arena, @field(value, column.field))});
            }
        },
        else => try w.print("{s}\n", .{try cell(arena, value)}),
    }
}

fn list(arena: Allocator, w: *Writer, comptime Item: type, items: []const Item) Error!void {
    if (@typeInfo(Item) != .@"struct" or comptime hasFormat(Item)) {
        for (items) |item| try w.print("{s}\n", .{try cell(arena, item)});
        return;
    }
    const columns = comptime columnsOf(Item);
    var titles: [columns.len][]const u8 = undefined;
    var widths: [columns.len]usize = undefined;
    const cells = try arena.alloc([columns.len][]const u8, items.len);
    inline for (columns, &titles, &widths) |column, *title, *width| {
        title.* = column.title orelse comptime upper(column.field);
        width.* = display.of(title.*);
    }
    for (items, cells) |item, *row| {
        inline for (columns, 0..) |column, i| {
            row[i] = try cell(arena, @field(item, column.field));
            widths[i] = @max(widths[i], display.of(row[i]));
        }
    }
    for (titles, 0..) |title, i| {
        try w.writeAll(title);
        try pad(w, display.of(title), widths[i], i + 1 == columns.len);
    }
    for (cells) |row| {
        for (row, 0..) |value, i| {
            try w.writeAll(value);
            try pad(w, display.of(value), widths[i], i + 1 == columns.len);
        }
    }
}

/// One text column: a field, and its header when `text_columns` names one.
const Column = struct { field: []const u8, title: ?[]const u8 = null };

/// The columns `T` shows as text: those of `T.text_columns`, in its order, else every
/// field.
fn columnsOf(comptime T: type) []const Column {
    var out: []const Column = &.{};
    if (!@hasDecl(T, "text_columns")) {
        for (@typeInfo(T).@"struct".field_names) |name| out = out ++ .{Column{ .field = name }};
        return out;
    }
    for (@typeInfo(@TypeOf(T.text_columns)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) {
            @compileError(@typeName(T) ++ ".text_columns names no field '" ++ name ++ "'");
        }
        const title: []const u8 = @field(T.text_columns, name);
        out = out ++ .{Column{ .field = name, .title = title }};
    }
    return out;
}

fn pad(w: *Writer, used: usize, width: usize, last: bool) Writer.Error!void {
    if (last) return w.writeByte('\n');
    try w.splatByteAll(' ', width - used + 2);
}

/// A field's default header: `last_commit` is `LAST COMMIT`.
fn upper(comptime name: []const u8) []const u8 {
    var out: [name.len]u8 = undefined;
    for (&out, name) |*o, c| o.* = if (c == '_') ' ' else std.ascii.toUpper(c);
    const final = out;
    return &final;
}

/// One value as text, for a table cell or a `field: value` line.
fn cell(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
    const T = @TypeOf(value);
    if (comptime hasFormat(T)) return std.fmt.allocPrint(arena, "{f}", .{value});
    if (comptime isString(T)) return value;
    return switch (@typeInfo(T)) {
        .optional => if (value) |inner| cell(arena, inner) else "",
        .@"enum" => @tagName(value),
        .bool,
        .int,
        .comptime_int,
        .float,
        .comptime_float,
        => std.fmt.allocPrint(arena, "{}", .{value}),
        .pointer => |p| if (p.size == .slice) slice: {
            var out: std.ArrayList(u8) = .empty;
            for (value, 0..) |item, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try cell(arena, item));
            }
            break :slice out.items;
        } else cell(arena, value.*),
        else => std.fmt.allocPrint(arena, "{any}", .{value}),
    };
}

fn hasFormat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => @hasDecl(T, "format"),
        else => false,
    };
}

const testing = std.testing;

const Server = struct { name: []const u8, port: u16, tags: []const []const u8 = &.{}, up: bool };

fn expectOutput(expected: []const u8, format: Format, value: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(arena.allocator(), &out.writer, format, value);
    try testing.expectEqualStrings(expected, out.written());
}

test "jsonl: a list as one compact object per line, anything else as one line" {
    const servers = [_]Server{
        .{ .name = "web", .port = 80, .tags = &.{"a"}, .up = true },
        .{ .name = "db", .port = 5432, .up = false },
    };
    try expectOutput(
        \\{"name":"web","port":80,"tags":["a"],"up":true}
        \\{"name":"db","port":5432,"tags":[],"up":false}
        \\
    , .jsonl, @as([]const Server, &servers));
    try expectOutput(
        "{\"name\":\"db\",\"port\":5432,\"tags\":[],\"up\":false}\n",
        .jsonl,
        servers[1],
    );
    try expectOutput("\"hello\"\n", .jsonl, "hello");
    try expectOutput("", .jsonl, @as([]const u32, &.{}));
    try expectOutput("1\n2\n", .jsonl, &[_]u32{ 1, 2 });
}

test "a list of structs is a table, or a JSON array" {
    const servers = [_]Server{
        .{ .name = "web", .port = 80, .tags = &.{ "a", "b" }, .up = true },
        .{ .name = "database", .port = 5432, .up = false },
    };
    try expectOutput(
        \\NAME      PORT  TAGS  UP
        \\web       80    a, b  true
        \\database  5432        false
        \\
    , .text, @as([]const Server, &servers));
    try expectOutput(
        \\[
        \\  {
        \\    "name": "web",
        \\    "port": 80,
        \\    "tags": [
        \\      "a",
        \\      "b"
        \\    ],
        \\    "up": true
        \\  },
        \\  {
        \\    "name": "database",
        \\    "port": 5432,
        \\    "tags": [],
        \\    "up": false
        \\  }
        \\]
        \\
    , .json, @as([]const Server, &servers));
}

test "a struct is field: value lines, scalars and strings as they are" {
    const one: Server = .{ .name = "web", .port = 80, .up = true };
    try expectOutput("name: web\nport: 80\ntags: \nup:   true\n", .text, one);
    try expectOutput("hello\n", .text, "hello");
    try expectOutput("42\n", .text, @as(u32, 42));
    try expectOutput("\"hello\"\n", .json, "hello");
    try expectOutput("a\nb\n", .text, @as([]const []const u8, &.{ "a", "b" }));
    const Mode = enum { fast, safe };
    try expectOutput("safe\n", .text, Mode.safe);
}

test "yaml: structs are mappings, slices sequences, a list of structs compact" {
    const servers = [_]Server{
        .{ .name = "web", .port = 80, .tags = &.{ "a", "b" }, .up = true },
        .{ .name = "database", .port = 5432, .up = false },
    };
    try expectOutput(
        \\- name: web
        \\  port: 80
        \\  tags:
        \\    - a
        \\    - b
        \\  up: true
        \\- name: database
        \\  port: 5432
        \\  tags: []
        \\  up: false
        \\
    , .yaml, @as([]const Server, &servers));
    try expectOutput("hello\n", .yaml, "hello");
    try expectOutput("42\n", .yaml, @as(u32, 42));
    try expectOutput("[]\n", .yaml, @as([]const u32, &.{}));
}

test "yaml: nesting, optionals, enums, unions, and empty collections" {
    const Inner = struct { level: ?u8 = null, mode: enum { fast, safe } = .safe };
    const Outer = struct {
        inner: Inner = .{},
        grid: []const []const u16 = &.{ &.{ 1, 2 }, &.{} },
        empty: struct {} = .{},
        choice: union(enum) { none, count: u32 } = .{ .count = 3 },
        bare: union(enum) { none, count: u32 } = .none,
        ratio: f64 = 0.5,
        far: f32 = std.math.inf(f32),
    };
    try expectOutput(
        \\inner:
        \\  level: null
        \\  mode: safe
        \\grid:
        \\  - - 1
        \\    - 2
        \\  - []
        \\empty: {}
        \\choice:
        \\  count: 3
        \\bare: none
        \\ratio: 0.5
        \\far: .inf
        \\
    , .yaml, Outer{});
    const level: ?Inner = .{ .level = 7 };
    try expectOutput("level: 7\nmode: safe\n", .yaml, level);
    try expectOutput("null\n", .yaml, @as(?Inner, null));
}

test "yaml: strings are quoted when they would read back as something else" {
    const plain = [_][]const u8{ "web", "hello world", "a:b", "a#b", "C:\\dir", "x-1", "ünï" };
    for (plain) |string| try testing.expect(!needsQuotes(string));
    const quoted = [_][]const u8{
        "",     " lead", "trail ", "a: b",        "a #b",  "end:", "true", "False", "yes",
        "NO",   "on",    "off",    "y",           "null",  "~",    "8080", "-1.5",  "1e3",
        "0x1F", "0o17",  ".inf",   "-.Inf",       ".NaN",  "[a]",  "{a}",  "*ref",  "&anchor",
        "!tag", "|",     ">",      "'q'",         "\"q\"", "%d",   "@x",   "`x`",   "#c",
        "?",    ",",     "-x",     "line\nbreak",
    };
    for (quoted) |string| try testing.expect(needsQuotes(string));
    const Pair = struct { key: []const u8, value: []const u8 };
    try expectOutput(
        \\key: "true"
        \\value: "say \"hi\"\n\ttab \\ \x01"
        \\
    , .yaml, Pair{ .key = "true", .value = "say \"hi\"\n\ttab \\ \x01" });
    try expectOutput("- \"\"\n- \"8080\"\n- plain\n", .yaml, @as([]const []const u8, &.{
        "",
        "8080",
        "plain",
    }));
}

test "yaml: a type's format method is its text, quoted when it needs to be" {
    const Version = struct {
        major: u8,
        pub fn format(v: @This(), w: *Writer) Writer.Error!void {
            try w.print("{d}", .{v.major});
        }
    };
    const Name = struct {
        pub fn format(_: @This(), w: *Writer) Writer.Error!void {
            try w.writeAll("v-next");
        }
    };
    const Long = struct {
        pub fn format(_: @This(), w: *Writer) Writer.Error!void {
            try w.splatByteAll('a', 300);
            try w.writeAll(": \"b\"");
        }
    };
    try expectOutput("\"2\"\n", .yaml, Version{ .major = 2 });
    try expectOutput("v-next\n", .yaml, Name{});
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.append(testing.allocator, '"');
    try expected.appendNTimes(testing.allocator, 'a', 300);
    try expected.appendSlice(testing.allocator, ": \\\"b\\\"\"\n");
    try expectOutput(expected.items, .yaml, Long{});
}

test "text_columns chooses, orders, and names the text columns; JSON keeps every field" {
    const Repo = struct {
        name: []const u8,
        path: []const u8,
        dirty: u32,
        pub const text_columns = .{ .dirty = "CHANGES", .name = "Repository" };
    };
    const repos = [_]Repo{
        .{ .name = "日本", .path = "/r/a", .dirty = 2 },
        .{ .name = "web", .path = "/r/b", .dirty = 0 },
    };
    try expectOutput(
        \\CHANGES  Repository
        \\2        日本
        \\0        web
        \\
    , .text, @as([]const Repo, &repos));
    try expectOutput("CHANGES:    0\nRepository: web\n", .text, repos[1]);
    try expectOutput(
        "{\"name\":\"web\",\"path\":\"/r/b\",\"dirty\":0}\n",
        .jsonl,
        repos[1],
    );
}

test "table columns line up by display width" {
    const Row = struct { name: []const u8, n: u8 };
    const rows = [_]Row{ .{ .name = "日本語", .n = 1 }, .{ .name = "e\u{301}", .n = 2 } };
    try expectOutput("NAME    N\n日本語  1\ne\u{301}       2\n", .text, @as([]const Row, &rows));
}
