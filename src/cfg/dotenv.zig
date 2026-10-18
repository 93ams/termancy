//! dotenv <-> `Value`.
//!
//! Reading: `KEY=value` lines, an optional `export ` prefix, `#` comments, single-quoted
//! (literal) and double-quoted (escaped, may span lines) values, and `${VAR}`,
//! `${VAR:-default}`, `$VAR` expansion in unquoted and double-quoted values. Expansion sees
//! keys defined earlier in the same file, then the environment passed in `ParseOptions`.
//! Because only earlier keys are visible, expansion cannot cycle; nested defaults are
//! bounded by `max_depth`.
//!
//! Keys map to paths: `SERVER__PORT` becomes `server.port` (lower-cased, `__` nests). All
//! values are strings; decoding coerces them.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Diagnostic = @import("Diagnostic.zig");
const path = @import("path.zig");

/// What parsing can fail with; the diagnostic says where.
pub const Error = error{SyntaxError} || Allocator.Error;

/// The deepest `${A:-${B:-...}}` nesting accepted.
pub const max_depth = 16;

/// How `parse` reads names and expands variables.
pub const ParseOptions = struct {
    /// Consulted for `${VAR}` after the file's own earlier keys.
    environ: ?*const std.process.Environ.Map = null,
    /// When true, keys become nested lower-case paths; when false the result is a flat
    /// table keyed by the exact names in the file.
    nest: bool = true,
};

/// Parses with the default options: nested keys, no outside environment.
pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diagnostic) Error!Value {
    return parseWith(arena, source, diag, .{});
}

/// Parses with explicit options: an environment for `${VAR}`, and nesting on or off.
pub fn parseWith(
    arena: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
    options: ParseOptions,
) Error!Value {
    var parser: Parser = .{ .arena = arena, .source = source, .diag = diag, .options = options };
    try parser.run();
    if (!options.nest) return .{ .table = parser.flat };
    var root: Value = .empty_table;
    var it = parser.flat.iterator();
    while (it.next()) |entry| {
        const key_path = try nestedPath(arena, entry.key_ptr.*);
        // `A=1` then `A__B=2`, or `A__B=2` then `A=1`: a key cannot be both a value and a
        // table, in either order.
        const section = if (root.lookup(key_path)) |existing| existing == .table else false;
        const stored = if (section)
            error.NotATable
        else
            root.put(arena, key_path, .{ .string = entry.value_ptr.string });
        stored catch |err| {
            Diagnostic.report(diag, "", 0, switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotATable => "a key is used both as a value and as a section",
                error.InvalidPath => "a key has an empty segment",
                // Only tables are created on the way, never arrays.
                error.IndexOutOfRange => unreachable,
            });
            return error.SyntaxError;
        };
    }
    return root;
}

/// Where a `NAME=value` line sits in the source, for editing it in place.
pub const Span = struct {
    /// The key the name maps to, as `parse` nests it.
    path: []const u8,
    /// The start of the line.
    start: usize,
    /// The next line's start.
    end: usize,
    value_start: usize,
    value_end: usize,
};

/// Parses `source` and returns every `NAME=value` line in order. Fails as `parse` does.
pub fn spans(arena: Allocator, source: []const u8) Error![]const Span {
    var list: std.ArrayList(Span) = .empty;
    var parser: Parser = .{
        .arena = arena,
        .source = source,
        .diag = null,
        .options = .{},
        .spans = &list,
    };
    try parser.run();
    return list.items;
}

/// `SERVER__TLS_CERT` -> `server.tls_cert`. A `__` nests only between two non-empty
/// segments; at either end of the name, or right after another separator, it is literal, so
/// `__PRIVATE`, `A__`, and `A____B` (`a.__b`) are valid keys.
fn nestedPath(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, key.len);
    var i: usize = 0;
    while (i < key.len) : (i += 1) {
        const separator = key[i] == '_' and i + 2 < key.len and key[i + 1] == '_' and
            out.items.len > 0 and out.items[out.items.len - 1] != '.';
        if (separator) {
            out.appendAssumeCapacity('.');
            i += 1;
        } else {
            out.appendAssumeCapacity(std.ascii.toLower(key[i]));
        }
    }
    return out.items;
}

const Parser = struct {
    arena: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
    options: ParseOptions,
    index: usize = 0,
    flat: Table = .empty,
    /// When set, every entry is recorded here (see `spans`).
    spans: ?*std.ArrayList(Span) = null,

    fn run(p: *Parser) Error!void {
        while (p.index < p.source.len) {
            const line_start = p.index;
            p.skipBlank();
            if (p.index >= p.source.len) break;
            const crlf = std.mem.startsWith(u8, p.source[p.index..], "\r\n");
            if (p.peek() == '#' or p.peek() == '\n' or crlf) {
                p.skipLine();
                continue;
            }
            try p.entry(line_start);
        }
    }

    fn entry(p: *Parser, line_start: usize) Error!void {
        if (std.mem.startsWith(u8, p.source[p.index..], "export ")) {
            p.index += "export ".len;
            p.skipBlank();
        }
        const key_start = p.index;
        while (p.index < p.source.len and isKeyByte(p.source[p.index])) p.index += 1;
        if (p.index == key_start) return p.fail("expected a variable name");
        // As in POSIX: `1BAD=x` would be a command to a shell, not an assignment.
        if (std.ascii.isDigit(p.source[key_start])) {
            return p.failAt(key_start, "a variable name cannot start with a digit");
        }
        const key = p.source[key_start..p.index];
        p.skipBlank();
        if (p.peek() != '=') return p.fail("expected '=' after the variable name");
        p.index += 1;
        p.skipBlank();
        const value_start = p.index;
        const text = try p.value();
        const value_end = p.index;
        p.skipBlank();
        if (p.peek() == '#') {
            p.skipLine();
        } else if (p.index < p.source.len and p.peek() != '\n' and p.peek() != '\r') {
            return p.fail("unexpected text after the value");
        } else {
            p.skipLine();
        }
        try p.flat.put(p.arena, key, .{ .string = text });
        if (p.spans) |list| try list.append(p.arena, .{
            .path = try nestedPath(p.arena, key),
            .start = line_start,
            .end = p.index,
            .value_start = value_start,
            .value_end = value_end,
        });
    }

    fn value(p: *Parser) Error![]const u8 {
        return switch (p.peek()) {
            '\'' => p.singleQuoted(),
            '"' => p.doubleQuoted(),
            else => p.unquoted(),
        };
    }

    fn singleQuoted(p: *Parser) Error![]const u8 {
        assert(p.peek() == '\'');
        const start = p.index + 1;
        const end = std.mem.indexOfScalarPos(u8, p.source, start, '\'') orelse
            return p.fail("unterminated single-quoted value");
        p.index = end + 1;
        return p.source[start..end];
    }

    fn doubleQuoted(p: *Parser) Error![]const u8 {
        assert(p.peek() == '"');
        const open = p.index;
        p.index += 1;
        var out: std.ArrayList(u8) = .empty;
        while (p.index < p.source.len) {
            const c = p.source[p.index];
            switch (c) {
                '"' => {
                    p.index += 1;
                    return out.items;
                },
                '\\' => {
                    if (p.index + 1 >= p.source.len) break;
                    try out.append(p.arena, switch (p.source[p.index + 1]) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '"', '\\', '$', '\'', '`' => |e| e,
                        else => return p.fail("invalid escape in a double-quoted value"),
                    });
                    p.index += 2;
                },
                '$' => try p.expand(&out),
                else => {
                    try out.append(p.arena, c);
                    p.index += 1;
                },
            }
        }
        p.index = open;
        return p.fail("unterminated double-quoted value");
    }

    fn unquoted(p: *Parser) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (p.index < p.source.len) {
            const c = p.source[p.index];
            if (c == '\n' or c == '\r') break;
            if (c == '#' and out.items.len > 0 and isBlank(out.items[out.items.len - 1])) break;
            if (c == '$') {
                try p.expand(&out);
                continue;
            }
            try out.append(p.arena, c);
            p.index += 1;
        }
        return std.mem.trimEnd(u8, out.items, " \t");
    }

    /// Expands the reference at `p.index` (which is `$`) into `out`.
    fn expand(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        assert(p.peek() == '$');
        const text = p.source[p.index + 1 ..];
        if (text.len > 0 and text[0] == '{') {
            const consumed = try p.braced(out, p.index + 2, 0);
            p.index = consumed;
            return;
        }
        var len: usize = 0;
        if (text.len > 0 and (std.ascii.isAlphabetic(text[0]) or text[0] == '_')) {
            while (len < text.len and isNameByte(text[len])) len += 1;
        }
        if (len == 0) {
            // A `$` that does not start a name is literal.
            try out.append(p.arena, '$');
            p.index += 1;
            return;
        }
        try out.appendSlice(p.arena, p.lookup(text[0..len]) orelse "");
        p.index += 1 + len;
    }

    /// Expands `NAME}` or `NAME:-default}` starting at `start`; returns the index after the
    /// closing brace.
    fn braced(p: *Parser, out: *std.ArrayList(u8), start: usize, depth: usize) Error!usize {
        if (depth >= max_depth) return p.failAt(start, "variable defaults are nested too deeply");
        var i = start;
        while (i < p.source.len and isNameByte(p.source[i])) i += 1;
        if (i == start) return p.failAt(start, "expected a variable name after '${'");
        const name = p.source[start..i];
        const found = p.lookup(name);
        if (std.mem.startsWith(u8, p.source[i..], ":-")) {
            i += 2;
            var default: std.ArrayList(u8) = .empty;
            while (i < p.source.len and p.source[i] != '}') {
                if (std.mem.startsWith(u8, p.source[i..], "${")) {
                    i = try p.braced(&default, i + 2, depth + 1);
                } else {
                    if (p.source[i] == '\n') break;
                    try default.append(p.arena, p.source[i]);
                    i += 1;
                }
            }
            const use_default = found == null or found.?.len == 0;
            try out.appendSlice(p.arena, if (use_default) default.items else found.?);
        } else {
            try out.appendSlice(p.arena, found orelse "");
        }
        if (i >= p.source.len or p.source[i] != '}') return p.failAt(start, "unterminated '${'");
        return i + 1;
    }

    fn lookup(p: *Parser, name: []const u8) ?[]const u8 {
        if (p.flat.get(name)) |v| return v.string;
        const environ = p.options.environ orelse return null;
        return environ.get(name);
    }

    fn peek(p: *Parser) u8 {
        return if (p.index < p.source.len) p.source[p.index] else 0;
    }

    fn skipBlank(p: *Parser) void {
        while (p.index < p.source.len and isBlank(p.source[p.index])) p.index += 1;
    }

    fn skipLine(p: *Parser) void {
        const end = std.mem.indexOfScalarPos(u8, p.source, p.index, '\n') orelse p.source.len;
        p.index = @min(end + 1, p.source.len);
    }

    fn fail(p: *Parser, message: []const u8) error{SyntaxError} {
        return p.failAt(p.index, message);
    }

    fn failAt(p: *Parser, offset: usize, message: []const u8) error{SyntaxError} {
        Diagnostic.report(p.diag, p.source, offset, message);
        return error.SyntaxError;
    }
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isKeyByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
}

fn isNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// How `write` names the variables.
pub const WriteOptions = struct {
    /// Prepended to every name, with `_`: prefix `APP` gives `APP_SERVER__PORT`.
    prefix: []const u8 = "",
    /// Write `export NAME=value`, for sourcing from a shell.
    @"export": bool = false,
};

/// What writing can fail with: the writer, or a value dotenv cannot hold.
pub const WriteError = std.Io.Writer.Error || error{Unrepresentable};

/// Writes every leaf as `NAME=value`. Nested keys join with `__`; arrays of scalars join
/// with `,`. Null leaves are left out, since `NAME=` would read back as an empty string. An
/// array containing a table or an array, a root that is not a table, and a key whose name
/// would read back as another path (a section key ending in `_`, so `__` cannot follow it
/// unambiguously) are `error.Unrepresentable`.
pub fn write(writer: *std.Io.Writer, value: Value, options: WriteOptions) WriteError!void {
    if (value != .table) return error.Unrepresentable;
    var name_buffer: [512]u8 = undefined;
    var name: std.Io.Writer = .fixed(&name_buffer);
    var key_path_buffer: [512]u8 = undefined;
    var key_path: std.Io.Writer = .fixed(&key_path_buffer);
    if (options.prefix.len > 0) {
        writeName(&name, options.prefix) catch return error.Unrepresentable;
        name.writeByte('_') catch return error.Unrepresentable;
        key_path.writeAll(name.buffered()) catch return error.Unrepresentable;
    }
    try writeTable(writer, value.table, &name, &key_path, false, options);
}

fn writeTable(
    writer: *std.Io.Writer,
    table: Table,
    name: *std.Io.Writer,
    /// The path the names must read back as.
    key_path: *std.Io.Writer,
    nested: bool,
    options: WriteOptions,
) WriteError!void {
    const mark = name.end;
    const key_path_mark = key_path.end;
    defer name.end = mark;
    defer key_path.end = key_path_mark;
    var it = table.iterator();
    while (it.next()) |entry| {
        name.end = mark;
        key_path.end = key_path_mark;
        // An empty key would leave no name, or an empty segment, to read back.
        if (entry.key_ptr.len == 0) return error.Unrepresentable;
        if (mark > 0 and name.buffered()[mark - 1] != '_') {
            name.writeAll("__") catch return error.Unrepresentable;
        }
        if (nested) key_path.writeByte('.') catch return error.Unrepresentable;
        writeName(name, entry.key_ptr.*) catch return error.Unrepresentable;
        writeName(key_path, entry.key_ptr.*) catch return error.Unrepresentable;
        switch (entry.value_ptr.*) {
            .table => |t| try writeTable(writer, t, name, key_path, true, options),
            // `NAME=` would read back as an empty string; an absent variable is the
            // nearest thing to null.
            .null => {},
            else => |leaf| {
                if (!readsBackAs(name.buffered(), key_path.buffered())) {
                    return error.Unrepresentable;
                }
                if (std.ascii.isDigit(name.buffered()[0])) return error.Unrepresentable;
                if (options.@"export") try writer.writeAll("export ");
                try writer.writeAll(name.buffered());
                try writer.writeByte('=');
                try writeLeaf(writer, leaf);
                try writer.writeByte('\n');
            },
        }
    }
}

/// Whether the variable `name` reads back as `key_path` (both upper-cased, segments joined by
/// `.`), as `nestedPath` splits names.
fn readsBackAs(name: []const u8, key_path: []const u8) bool {
    var buffer: [512]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const read = nestedPath(fixed.allocator(), name) catch return false;
    return std.ascii.eqlIgnoreCase(read, key_path);
}

/// Writes the variable name for one key segment: upper-cased, other bytes as `_`.
pub fn writeName(name: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    for (key) |c| try name.writeByte(if (isNameByte(c)) std.ascii.toUpper(c) else '_');
}

/// Writes `value` as it appears after `NAME=`. A table or null is `error.Unrepresentable`.
pub fn writeValue(writer: *std.Io.Writer, value: Value) WriteError!void {
    if (value == .table or value == .null) return error.Unrepresentable;
    return writeLeaf(writer, value);
}

fn writeLeaf(writer: *std.Io.Writer, value: Value) WriteError!void {
    // A string is written as is, so its length is not bounded by the buffer below.
    if (value == .string) return writeQuoted(writer, value.string);
    var buffer: [4096]u8 = undefined;
    var text: std.Io.Writer = .fixed(&buffer);
    switch (value) {
        .table => unreachable, // writeTable recurses into tables before calling here.
        .array => |a| for (a.items, 0..) |item, i| {
            if (item == .array or item == .table) return error.Unrepresentable;
            if (i > 0) text.writeByte(',') catch return error.Unrepresentable;
            item.format(&text) catch return error.Unrepresentable;
        },
        .null => unreachable, // writeTable leaves null leaves out.
        else => value.format(&text) catch return error.Unrepresentable,
    }
    try writeQuoted(writer, text.buffered());
}

/// Writes `s` bare when that reads back unchanged, otherwise double-quoted.
fn writeQuoted(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const bare = for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_-.,:/@+=", c) != null)) {
            break false;
        }
    } else true;
    if (bare) return writer.writeAll(s);
    try writer.writeByte('"');
    // `$` and the backquote are escaped too, so `export` output is safe to source: inside
    // double quotes a shell would expand them.
    for (s) |c| switch (c) {
        '"', '\\', '$', '`' => {
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

fn parseFlat(arena: Allocator, source: []const u8) !Table {
    const v = try parseWith(arena, source, null, .{ .nest = false });
    return v.table;
}

test "plain, quoted, export, comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try parseFlat(arena.allocator(),
        \\# a comment
        \\A=1
        \\export B = two words # trailing
        \\C='literal $A \n'
        \\D="esc\t\"q\" $A"
        \\E=
        \\F=a#b
    );
    try testing.expectEqualStrings("1", t.get("A").?.string);
    try testing.expectEqualStrings("two words", t.get("B").?.string);
    try testing.expectEqualStrings("literal $A \\n", t.get("C").?.string);
    try testing.expectEqualStrings("esc\t\"q\" 1", t.get("D").?.string);
    try testing.expectEqualStrings("", t.get("E").?.string);
    try testing.expectEqualStrings("a#b", t.get("F").?.string);
}

test "edge cases, pinned" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try parseFlat(arena.allocator(),
        \\A=1
        \\MONEY=$$A
        \\export  OTHER=def
        \\PORT=8080   # c
        \\WIN='C:\Users\ada'
    );
    // `$$` is not an escape (as it is in Compose files): a lone `$`, then `$A` expanded.
    try testing.expectEqualStrings("$1", t.get("MONEY").?.string);
    try testing.expectEqualStrings("def", t.get("OTHER").?.string);
    try testing.expectEqualStrings("8080", t.get("PORT").?.string);
    try testing.expectEqualStrings("C:\\Users\\ada", t.get("WIN").?.string);
    // A key starting with a digit cannot be written either.
    var tree: Value = .empty_table;
    try tree.put(arena.allocator(), "1bad", .{ .string = "x" });
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try testing.expectError(error.Unrepresentable, write(&out.writer, tree, .{}));
    try write(&out.writer, tree, .{ .prefix = "APP" });
    try testing.expectEqualStrings("APP_1BAD=x\n", out.written());
}

test "multi-line double-quoted values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try parseFlat(arena.allocator(), "K=\"line1\nline2\"\nN=2\n");
    try testing.expectEqualStrings("line1\nline2", t.get("K").?.string);
    try testing.expectEqualStrings("2", t.get("N").?.string);
}

test "expansion from the file, the environment, and defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/u");
    const v = try parseWith(arena.allocator(),
        \\BASE=${HOME}/app
        \\LOG=$BASE/log
        \\PORT=${PORT:-8080}
        \\HOST=${UNSET:-${ALSO_UNSET:-localhost}}
        \\DOLLAR=cost $5
    , null, .{ .environ = &environ, .nest = false });
    try testing.expectEqualStrings("/home/u/app", v.table.get("BASE").?.string);
    try testing.expectEqualStrings("/home/u/app/log", v.table.get("LOG").?.string);
    try testing.expectEqualStrings("8080", v.table.get("PORT").?.string);
    try testing.expectEqualStrings("localhost", v.table.get("HOST").?.string);
    try testing.expectEqualStrings("cost $5", v.table.get("DOLLAR").?.string);
}

test "later keys are not visible to earlier ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try parseFlat(arena.allocator(), "A=$B\nB=x\n");
    try testing.expectEqualStrings("", t.get("A").?.string);
}

test "keys nest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "SERVER__PORT=80\nSERVER__TLS_CERT=c\nDEBUG=1\n", null);
    try testing.expectEqualStrings("80", v.lookup("server.port").?.string);
    try testing.expectEqualStrings("c", v.lookup("server.tls_cert").?.string);
    try testing.expectEqualStrings("1", v.lookup("debug").?.string);
}

test "errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8, u32 }{
        .{ "A=1\n=2\n", "expected a variable name", 2 },
        .{ "A 1\n", "expected '=' after the variable name", 1 },
        .{ "A='x\n", "unterminated single-quoted value", 1 },
        .{ "\nA=\"x\n", "unterminated double-quoted value", 2 },
        .{ "A=\"\\q\"", "invalid escape in a double-quoted value", 1 },
        .{ "A=${B", "unterminated '${'", 1 },
        .{ "A=${}", "expected a variable name after '${'", 1 },
        .{ "A='x' y", "unexpected text after the value", 1 },
        .{ "A=1\n1BAD=x\n", "a variable name cannot start with a digit", 2 },
        // Backslashes in double quotes are escapes, and `\U` is none: single-quote paths.
        .{ "PATH=\"C:\\Users\\ada\"", "invalid escape in a double-quoted value", 1 },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try testing.expectError(error.SyntaxError, parse(a, case[0], &diag));
        try testing.expectEqualStrings(case[1], diag.message);
        try testing.expectEqual(case[2], diag.line);
    }
}

test "a double underscore at the ends of a name is literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `__R4` was read as the path `.r4`, which is invalid, so the file failed to parse.
    const v = try parse(a, "__R4=1\nA__=2\nB____C=3\nD___E=4\n", null);
    try testing.expectEqualStrings("1", v.lookup("__r4").?.string);
    try testing.expectEqualStrings("2", v.lookup("a__").?.string);
    try testing.expectEqualStrings("3", v.lookup("b.__c").?.string);
    try testing.expectEqualStrings("4", v.lookup("d._e").?.string);
    // What the writer makes of such keys reads back.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, v, .{});
    try testing.expectEqualStrings("__R4=1\nA__=2\nB____C=3\nD___E=4\n", out.written());
    try testing.expect(v.eql(try parse(a, out.written(), null)));
}

test "a key that is both a value and a section" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "A=1\nA__B=2\n", null));
}

test "write" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "server.port", .{ .int = 8080 });
    try root.put(a, "server.name", .{ .string = "my app" });
    try root.put(a, "debug", .{ .bool = true });
    var tags: @import("value.zig").Array = .empty;
    try tags.append(a, .{ .string = "a" });
    try tags.append(a, .{ .string = "b" });
    try root.put(a, "tags", .{ .array = tags });
    try root.put(a, "secret", .{ .string = "$x\"" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, root, .{ .prefix = "app", .@"export" = true });
    try testing.expectEqualStrings(
        \\export APP_SERVER__PORT=8080
        \\export APP_SERVER__NAME="my app"
        \\export APP_DEBUG=true
        \\export APP_TAGS=a,b
        \\export APP_SECRET="\$x\""
        \\
    , out.written());
}

test "a backquote is escaped, so sourcing export output runs nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "cmd", .{ .string = "`touch x` $(id)" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, root, .{ .@"export" = true });
    try testing.expectEqualStrings("export CMD=\"\\`touch x\\` \\$(id)\"\n", out.written());
    const back = try parse(a, out.written()["export ".len..], null);
    try testing.expectEqualStrings("`touch x` $(id)", back.lookup("cmd").?.string);
}

test "write round-trips through parse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "SERVER__HOST=\"a b\"\nSERVER__PORT=1\nNOTE=\"multi\\nline \\$HOME\"\n";
    const first = try parse(a, source, null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, first, .{});
    const second = try parse(a, out.written(), null);
    try testing.expect(first.eql(second));
    try testing.expectEqualStrings("multi\nline $HOME", second.lookup("note").?.string);
}

test "unrepresentable values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nested: @import("value.zig").Array = .empty;
    try nested.append(a, .empty_table);
    var root: Value = .empty_table;
    try root.put(a, "x", .{ .array = nested });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.Unrepresentable, write(&out.writer, root, .{}));
    try testing.expectError(error.Unrepresentable, write(&out.writer, .{ .int = 1 }, .{}));
}

test "CRLF line endings, blank lines included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try parseFlat(arena.allocator(), "A=1\r\n\r\n# c\r\nB=\"x\"\r\n  \r\nC='y' # z\r\n");
    try testing.expectEqualStrings("1", t.get("A").?.string);
    try testing.expectEqualStrings("x", t.get("B").?.string);
    try testing.expectEqualStrings("y", t.get("C").?.string);
}

test "long values write" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, 10_000);
    @memset(long, 'x');
    long[0] = ' ';
    var root: Value = .empty_table;
    try root.put(a, "cert", .{ .string = long });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, root, .{});
    try testing.expectEqualStrings(
        long,
        (try parse(a, out.written(), null)).lookup("cert").?.string,
    );
}

test "an empty key cannot be written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "\"\"", .{ .string = "v" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.Unrepresentable, write(&out.writer, root, .{}));
}

test "expansion edge cases" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("EMPTY", "");
    try environ.put("FROM_ENV", "env");
    const v = try parseWith(a,
        \\A=$
        \\B=$1x
        \\C=${EMPTY:-fallback}
        \\D=${UNSET:-}
        \\E=${FROM_ENV}${FROM_ENV:-no}
        \\FROM_ENV=file
        \\F=$FROM_ENV
        \\G="\$FROM_ENV \'"
        \\H='${FROM_ENV}'
        \\I=a$FROM_ENV-b
        \\J=${A:-x}y
    , null, .{ .environ = &environ, .nest = false });
    const expected = [_]struct { []const u8, []const u8 }{
        .{ "A", "$" },           .{ "B", "$1x" },         .{ "C", "fallback" },
        .{ "D", "" },            .{ "E", "envenv" },      .{ "F", "file" },
        .{ "G", "$FROM_ENV '" }, .{ "H", "${FROM_ENV}" }, .{ "I", "afile-b" },
        .{ "J", "$y" },
    };
    for (expected) |e| try testing.expectEqualStrings(e[1], v.table.get(e[0]).?.string);

    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(a, "X=");
    for (0..max_depth + 1) |_| try deep.appendSlice(a, "${U:-");
    for (0..max_depth + 1) |_| try deep.append(a, '}');
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(a, deep.items, &diag));
    try testing.expectEqualStrings("variable defaults are nested too deeply", diag.message);
    try testing.expectError(error.SyntaxError, parse(a, "X=${U:-a\n}", &diag));
    try testing.expectEqualStrings("unterminated '${'", diag.message);
}

test "keys with dots nest, and conflicting keys are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, "A.B=1\nA__C=2\nx-y=3\n", null);
    try testing.expectEqualStrings("1", v.lookup("a.b").?.string);
    try testing.expectEqualStrings("2", v.lookup("a.c").?.string);
    try testing.expectEqualStrings("3", v.lookup("x-y").?.string);
    // `A` and `a` are one key once lower-cased; the later one wins.
    const same = try parse(a, "A=1\na=2\n", null);
    try testing.expectEqualStrings("2", same.lookup("a").?.string);
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(a, "A..B=1\n", &diag));
    try testing.expectEqualStrings("a key has an empty segment", diag.message);
    // Was accepted, silently dropping `A__B`, while the reverse order was an error.
    try testing.expectError(error.SyntaxError, parse(a, "A__B=1\nA=2\n", &diag));
    try testing.expectEqualStrings("a key is used both as a value and as a section", diag.message);
}

test "write scalars, nulls, and empty tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "none", .null);
    try root.put(a, "f", .{ .float = 1.5 });
    try root.put(a, "neg", .{ .int = -3 });
    try root.put(a, "empty", .empty_table);
    try root.put(a, "blank", .{ .string = "" });
    try root.put(a, "odd key", .{ .string = "a b" });
    try root.put(a, "mixed", .{ .array = .empty });
    try root.put(a, "mixed.0", .{ .int = 1 });
    try root.put(a, "mixed.1", .{ .string = "x y" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, root, .{});
    try testing.expectEqualStrings(
        \\F=1.5
        \\NEG=-3
        \\BLANK=
        \\ODD_KEY="a b"
        \\MIXED="1,x y"
        \\
    , out.written());
    // A name longer than the name buffer is unrepresentable rather than truncated.
    const long_key = try a.alloc(u8, 600);
    @memset(long_key, 'k');
    var long: Value = .empty_table;
    try long.table.put(a, long_key, .{ .int = 1 });
    try testing.expectError(error.Unrepresentable, write(&out.writer, long, .{}));
}

test "a name that would read back as another path is unrepresentable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    // Found by the fuzzer: `__.__` nests under `__`, whose name would be `____`, which
    // reads back as `_._` and clashes with the `_` beside it.
    const found = try parse(a, "_=\n__.__=\n_=\n", null);
    try testing.expectError(error.Unrepresentable, write(&out.writer, found, .{}));
    // `a_` holding `b`: `A_B` would read back as `a_b`, `A___B` as `a._b`.
    const trailing = try parse(a, "A_.B=1\n", null);
    try testing.expectError(error.Unrepresentable, write(&out.writer, trailing, .{}));
    // Literal `__` at the edges still writes and reads back.
    out.clearRetainingCapacity();
    const edges = try parse(a, "__R4=1\nA__=2\nB____C=3\n", null);
    try write(&out.writer, edges, .{});
    try testing.expectEqualStrings("__R4=1\nA__=2\nB____C=3\n", out.written());
}
