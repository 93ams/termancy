//! Flag specs for `snek cli add --flag`: `name:type[=default][,short=x][,required][,help=text]`.
//!
//! | type                      | Zig field                     | default            |
//! |---------------------------|-------------------------------|--------------------|
//! | `bool`                    | `bool`                        | `false`            |
//! | `count`                   | `u8` with `.count = true`     | `0`                |
//! | `int`, `uint`             | `i64`, `u64`                  | `null` (`?T`)      |
//! | `i8`...`i64`, `u8`...`u64`| that integer                  | `null` (`?T`)      |
//! | `float`, `f32`, `f64`     | `f64`, `f32`, `f64`           | `null` (`?T`)      |
//! | `string`                  | `[]const u8`                  | `null` (`?T`)      |
//! | `enum(a\|b\|c)`           | `enum { a, b, c }`            | `null` (`?T`)      |
//! | `list(T)`                 | `[]const T`, repeatable       | empty              |
//!
//! `=default` gives a scalar a default (printable ASCII without a comma); `required` makes a
//! scalar flag mandatory instead. `help=` takes the rest of the spec, commas included, so it
//! comes last. Names are lowercase words joined by `-`; the field is the name with `_`.
//! Custom types such as `cfg.Duration` are not offered: edit the generated struct.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Int = struct {
    signed: bool,
    bits: u16,
};

/// The type of one value.
pub const Base = union(enum) {
    bool,
    int: Int,
    /// 32 or 64.
    float: u16,
    string,
    /// The choices, as typed on the command line.
    @"enum": []const []const u8,
};

pub const Spec = struct {
    /// As typed on the command line: `dry-run`.
    name: []const u8,
    /// The struct field: `dry_run`.
    field: []const u8,
    base: Base,
    count: bool = false,
    list: bool = false,
    required: bool = false,
    /// The default as Zig source, normalized (`0x10` becomes `16`), or null.
    default: ?[]const u8 = null,
    short: ?u8 = null,
    help: []const u8 = "",

    /// Whether the field is `?T = null`: a scalar without a default that is not required.
    pub fn isOptional(s: Spec) bool {
        return !s.list and !s.count and s.base != .bool and !s.required and s.default == null;
    }
};

pub const Error = error{InvalidFlagSpec} || Allocator.Error;

/// Parses every spec and checks them against each other. On `error.InvalidFlagSpec`,
/// `message` says what is wrong.
pub fn parseAll(
    arena: Allocator,
    texts: []const []const u8,
    message: *[]const u8,
) Error![]const Spec {
    const specs = try arena.alloc(Spec, texts.len);
    for (texts, specs, 0..) |text, *s, i| {
        s.* = try parse(arena, text, message);
        for (specs[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.field, s.field)) {
                return fail(arena, message, "duplicate flag --{s}", .{s.name});
            }
            if (s.short != null and earlier.short == s.short) {
                return fail(arena, message, "duplicate short flag -{c}", .{s.short.?});
            }
        }
    }
    return specs;
}

/// Parses one spec.
pub fn parse(arena: Allocator, text: []const u8, message: *[]const u8) Error!Spec {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse
        return fail(arena, message, "flag spec \"{s}\" needs name:type", .{text});
    var s: Spec = .{ .name = text[0..colon], .field = "", .base = .bool };
    s.field = try fieldName(arena, s.name, message);
    var rest = text[colon + 1 ..];
    const head_end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    const head = rest[0..head_end];
    rest = rest[@min(head_end + 1, rest.len)..];
    const eq = std.mem.indexOfScalar(u8, head, '=');
    try parseType(arena, &s, head[0 .. eq orelse head.len], message);
    try parseOptions(arena, &s, rest, message);
    if (eq) |at| s.default = try parseDefault(arena, s, head[at + 1 ..], message);
    if (s.required and (s.default != null or s.list or s.count or s.base == .bool)) {
        return fail(arena, message, "--{s}: only a scalar without a default can be required", .{
            s.name,
        });
    }
    return s;
}

fn parseOptions(arena: Allocator, s: *Spec, options: []const u8, message: *[]const u8) Error!void {
    var rest = options;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "help=")) {
            s.help = rest["help=".len..];
            return;
        }
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const option = rest[0..end];
        rest = rest[@min(end + 1, rest.len)..];
        if (std.mem.eql(u8, option, "required")) {
            s.required = true;
        } else if (std.mem.startsWith(u8, option, "short=")) {
            const value = option["short=".len..];
            if (value.len != 1 or !std.ascii.isAlphanumeric(value[0]) or value[0] == 'h') {
                return fail(arena, message, "--{s}: short=\"{s}\" must be one letter or digit " ++
                    "other than h", .{ s.name, value });
            }
            s.short = value[0];
        } else {
            return fail(arena, message, "--{s}: unknown option \"{s}\"", .{ s.name, option });
        }
    }
}

/// `dry-run` -> `dry_run`, after checking the name.
fn fieldName(arena: Allocator, name: []const u8, message: *[]const u8) Error![]const u8 {
    if (!isWord(name) or std.mem.eql(u8, name, "help")) {
        return fail(arena, message, "invalid flag name \"{s}\" (use lowercase words joined " ++
            "by -, not help)", .{name});
    }
    const field = try arena.dupe(u8, name);
    std.mem.replaceScalar(u8, field, '-', '_');
    if (!std.zig.isValidId(field)) {
        return fail(arena, message, "flag name \"{s}\" is a Zig keyword", .{name});
    }
    return field;
}

/// A lowercase word, `-` separated: `dry-run`, `v2`.
pub fn isWord(text: []const u8) bool {
    if (text.len == 0 or text.len > 64 or !std.ascii.isLower(text[0])) return false;
    if (text[text.len - 1] == '-') return false;
    for (text, 0..) |c, i| switch (c) {
        'a'...'z', '0'...'9' => {},
        '-' => if (text[i - 1] == '-') return false,
        else => return false,
    };
    return true;
}

fn parseType(arena: Allocator, s: *Spec, text: []const u8, message: *[]const u8) Error!void {
    var inner = text;
    if (std.mem.startsWith(u8, text, "list(") and std.mem.endsWith(u8, text, ")")) {
        s.list = true;
        inner = text["list(".len .. text.len - 1];
    } else if (std.mem.eql(u8, text, "count")) {
        s.count = true;
        s.base = .{ .int = .{ .signed = false, .bits = 8 } };
        return;
    }
    s.base = try parseBase(arena, inner, message) orelse
        return fail(arena, message, "--{s}: unknown type \"{s}\"", .{ s.name, text });
}

fn parseBase(arena: Allocator, text: []const u8, message: *[]const u8) Error!?Base {
    const named = [_]struct { []const u8, Base }{
        .{ "bool", .bool },
        .{ "string", .string },
        .{ "int", .{ .int = .{ .signed = true, .bits = 64 } } },
        .{ "uint", .{ .int = .{ .signed = false, .bits = 64 } } },
        .{ "float", .{ .float = 64 } },
        .{ "f32", .{ .float = 32 } },
        .{ "f64", .{ .float = 64 } },
    };
    for (named) |entry| if (std.mem.eql(u8, text, entry[0])) return entry[1];
    if (text.len >= 2 and (text[0] == 'i' or text[0] == 'u')) {
        const bits = std.fmt.parseInt(u16, text[1..], 10) catch return null;
        return switch (bits) {
            8, 16, 32, 64 => .{ .int = .{ .signed = text[0] == 'i', .bits = bits } },
            else => null,
        };
    }
    if (std.mem.startsWith(u8, text, "enum(") and std.mem.endsWith(u8, text, ")")) {
        return .{ .@"enum" = try parseChoices(arena, text["enum(".len .. text.len - 1], message) };
    }
    return null;
}

fn parseChoices(arena: Allocator, text: []const u8, message: *[]const u8) Error![]const []const u8 {
    var choices: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '|');
    while (it.next()) |choice| {
        const field = try arena.dupe(u8, choice);
        std.mem.replaceScalar(u8, field, '-', '_');
        if (!isWord(choice) or !std.zig.isValidId(field)) {
            return fail(arena, message, "invalid enum choice \"{s}\"", .{choice});
        }
        for (choices.items) |earlier| {
            if (std.mem.eql(u8, earlier, choice)) {
                return fail(arena, message, "duplicate enum choice \"{s}\"", .{choice});
            }
        }
        try choices.append(arena, choice);
    }
    return choices.items;
}

/// Checks `text` against the flag's type and returns it as Zig source.
fn parseDefault(
    arena: Allocator,
    s: Spec,
    text: []const u8,
    message: *[]const u8,
) Error![]const u8 {
    if (s.list) return fail(arena, message, "--{s}: a list has no default", .{s.name});
    const bad = "--{s}: invalid default \"{s}\"";
    switch (s.base) {
        .bool => {
            if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return text;
            return fail(arena, message, bad, .{ s.name, text });
        },
        .int => |int| {
            const value = std.fmt.parseInt(i128, text, 0) catch
                return fail(arena, message, bad, .{ s.name, text });
            if (!fits(int, value)) return fail(arena, message, bad, .{ s.name, text });
            return std.fmt.allocPrint(arena, "{d}", .{value});
        },
        .float => |bits| return floatDefault(arena, bits, text) catch
            return fail(arena, message, bad, .{ s.name, text }),
        .string => {
            for (text) |c| if (!std.ascii.isPrint(c)) return fail(arena, message, bad, .{
                s.name, text,
            });
            return std.fmt.allocPrint(arena, "\"{f}\"", .{std.zig.fmtString(text)});
        },
        .@"enum" => |choices| for (choices) |choice| {
            if (!std.mem.eql(u8, choice, text)) continue;
            const field = try arena.dupe(u8, choice);
            std.mem.replaceScalar(u8, field, '-', '_');
            return std.fmt.allocPrint(arena, ".{s}", .{field});
        } else return fail(arena, message, bad, .{ s.name, text }),
    }
}

fn fits(int: Int, value: i128) bool {
    assert(int.bits <= 64);
    const max: i128 = if (int.signed)
        (@as(i128, 1) << @intCast(int.bits - 1)) - 1
    else
        (@as(i128, 1) << @intCast(int.bits)) - 1;
    const min: i128 = if (int.signed) -max - 1 else 0;
    return value >= min and value <= max;
}

/// The float as Zig prints it with `{d}` at its own width, which is also valid source.
fn floatDefault(arena: Allocator, bits: u16, text: []const u8) error{
    InvalidCharacter,
    NotFinite,
    OutOfMemory,
}![]const u8 {
    if (bits == 32) {
        const value = try std.fmt.parseFloat(f32, text);
        if (!std.math.isFinite(value)) return error.NotFinite;
        return std.fmt.allocPrint(arena, "{d}", .{value});
    }
    const value = try std.fmt.parseFloat(f64, text);
    if (!std.math.isFinite(value)) return error.NotFinite;
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

fn fail(
    arena: Allocator,
    message: *[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    message.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.InvalidFlagSpec;
}

const testing = std.testing;

fn parseOk(arena: Allocator, text: []const u8) !Spec {
    var message: []const u8 = "";
    return parse(arena, text, &message) catch |err| {
        std.debug.print("{s}: {s}\n", .{ text, message });
        return err;
    };
}

fn expectInvalid(text: []const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var message: []const u8 = "";
    try testing.expectError(error.InvalidFlagSpec, parse(arena_state.allocator(), text, &message));
    try testing.expectEqualStrings(expected, message);
}

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const port = try parseOk(arena, "port:u16=0x1f90,short=p,help=Port, to listen on");
    try testing.expectEqualStrings("port", port.field);
    try testing.expectEqual(Base{ .int = .{ .signed = false, .bits = 16 } }, port.base);
    try testing.expectEqualStrings("8080", port.default.?);
    try testing.expectEqual('p', port.short.?);
    try testing.expectEqualStrings("Port, to listen on", port.help);
    try testing.expect(!port.isOptional());

    const dry = try parseOk(arena, "dry-run:bool");
    try testing.expectEqualStrings("dry_run", dry.field);
    try testing.expect(!dry.isOptional());

    const mode = try parseOk(arena, "mode:enum(fast|very-slow)=very-slow");
    try testing.expectEqualStrings(".very_slow", mode.default.?);
    try testing.expectEqualStrings("very-slow", mode.base.@"enum"[1]);

    const tags = try parseOk(arena, "tag:list(string)");
    try testing.expect(tags.list and !tags.isOptional());

    const verbose = try parseOk(arena, "verbose:count,short=v");
    try testing.expect(verbose.count);

    const name = try parseOk(arena, "name:string,required");
    try testing.expect(name.required and !name.isOptional());

    const ratio = try parseOk(arena, "ratio:f32=0.10");
    try testing.expectEqualStrings("0.1", ratio.default.?);

    const text = try parseOk(arena, "greeting:string=say \"hi\"");
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", text.default.?);
    try testing.expect((try parseOk(arena, "limit:int")).isOptional());
}

test "parse: errors" {
    try expectInvalid("port", "flag spec \"port\" needs name:type");
    const advice = " (use lowercase words joined by -, not help)";
    try expectInvalid("Port:int", "invalid flag name \"Port\"" ++ advice);
    try expectInvalid("help:bool", "invalid flag name \"help\"" ++ advice);
    try expectInvalid("a--b:bool", "invalid flag name \"a--b\"" ++ advice);
    try expectInvalid("test:bool", "flag name \"test\" is a Zig keyword");
    try expectInvalid("port:u12", "--port: unknown type \"u12\"");
    try expectInvalid("port:u8=256", "--port: invalid default \"256\"");
    try expectInvalid("delta:i8=-129", "--delta: invalid default \"-129\"");
    try expectInvalid("ratio:float=inf", "--ratio: invalid default \"inf\"");
    try expectInvalid("on:bool=yes", "--on: invalid default \"yes\"");
    try expectInvalid("s:string=\xe2\x80\xa8", "--s: invalid default \"\xe2\x80\xa8\"");
    try expectInvalid("mode:enum(a|b)=c", "--mode: invalid default \"c\"");
    try expectInvalid("mode:enum(a|a)", "duplicate enum choice \"a\"");
    try expectInvalid("mode:enum(a|if)", "invalid enum choice \"if\"");
    try expectInvalid("tag:list(string)=x", "--tag: a list has no default");
    try expectInvalid("x:bool,short=h", "--x: short=\"h\" must be one letter or digit other " ++
        "than h");
    try expectInvalid("x:bool,shrt=y", "--x: unknown option \"shrt=y\"");
    try expectInvalid("x:int=1,required", "--x: only a scalar without a default can be required");
    try expectInvalid("x:list(count)", "--x: unknown type \"list(count)\"");
}

test parseAll {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var message: []const u8 = "";
    const specs = try parseAll(arena, &.{ "a:bool,short=a", "b:int" }, &message);
    try testing.expectEqual(2, specs.len);
    const twice: []const []const u8 = &.{ "a:bool", "a:int" };
    try testing.expectError(error.InvalidFlagSpec, parseAll(arena, twice, &message));
    try testing.expectEqualStrings("duplicate flag --a", message);
    const shorts: []const []const u8 = &.{ "a:bool,short=x", "b:bool,short=x" };
    try testing.expectError(error.InvalidFlagSpec, parseAll(arena, shorts, &message));
    try testing.expectEqualStrings("duplicate short flag -x", message);
}

test isWord {
    try testing.expect(isWord("dry-run"));
    try testing.expect(isWord("v2"));
    try testing.expect(!isWord("-x"));
    try testing.expect(!isWord("x-"));
    try testing.expect(!isWord("2x"));
    try testing.expect(!isWord(""));
}
