//! Typed flag values: which Zig types a flag may have, and how text becomes one.
//!
//! Supported element types: `bool`, integers (decimal, or `0x`/`0o`/`0b`), floats,
//! `[]const u8`, enums (by name; `-` matches `_`), a tagged union's variant names (the
//! variant takes its defaults: `--storage s3`), and any type following the `parse`
//! convention, `pub fn parse(text: []const u8) !T`. A field may also be `?T` (absent is
//! `null`) or `[]const T` (repeatable).

const std = @import("std");
const field = @import("field");
const Flag = @import("Flag.zig");

/// A word that is not a value of the type.
pub const Error = error{InvalidValue};

/// Parses one value of an element type.
pub fn parse(comptime T: type, text: []const u8) Error!T {
    if (comptime hasParse(T)) return T.parse(text) catch error.InvalidValue;
    return switch (@typeInfo(T)) {
        .bool => Flag.parseBool(text) orelse error.InvalidValue,
        .int => std.fmt.parseInt(T, text, 0) catch error.InvalidValue,
        .float => std.fmt.parseFloat(T, text) catch error.InvalidValue,
        .@"enum" => parseEnum(T, text),
        .@"union" => if (comptime field.isChoice(T)) parseChoice(
            T,
            text,
        ) else @compileError(unsupported(T)),
        .pointer => if (T == []const u8) text else @compileError(unsupported(T)),
        else => @compileError(unsupported(T)),
    };
}

fn parseEnum(comptime T: type, text: []const u8) Error!T {
    inline for (@typeInfo(T).@"enum".field_names, @typeInfo(T).@"enum".field_values) |name, value| {
        if (namesMatch(name, text)) return @fromBackingInt(@intCast(value));
    }
    return error.InvalidValue;
}

fn parseChoice(comptime T: type, text: []const u8) Error!T {
    inline for (comptime field.fieldNames(T)) |name| {
        if (namesMatch(name, text)) return field.initVariant(T, name);
    }
    return error.InvalidValue;
}

fn namesMatch(name: []const u8, text: []const u8) bool {
    if (name.len != text.len) return false;
    for (name, text) |n, t| {
        if (n != t and !(n == '_' and t == '-')) return false;
    }
    return true;
}

fn unsupported(comptime T: type) []const u8 {
    return "cli: " ++ @typeName(T) ++ " is not a supported flag type";
}

/// Whether `T` follows the `parse` convention; see `field.hasParse`.
pub const hasParse = field.hasParse;

/// `?T` -> `T`, `[]const T` -> `T` (except strings), otherwise `T` itself.
pub fn Element(comptime Field: type) type {
    const Base = switch (@typeInfo(Field)) {
        .optional => |o| o.child,
        else => Field,
    };
    if (isList(Base)) return @typeInfo(Base).pointer.child;
    return Base;
}

/// Whether a field type is a repeatable list (`[]const T` other than `[]const u8`).
pub fn isList(comptime Field: type) bool {
    return switch (@typeInfo(Field)) {
        .pointer => |p| p.size == .slice and Field != []const u8,
        else => false,
    };
}

/// A `Flag.check` function for an element type.
pub fn checker(comptime T: type) *const fn ([]const u8) bool {
    return &struct {
        fn check(text: []const u8) bool {
            _ = parse(T, text) catch return false;
            return true;
        }
    }.check;
}

/// The placeholder shown in help for an element type: `int`, `string`, `a|b`, `duration`.
pub fn label(comptime T: type) []const u8 {
    if (comptime hasParse(T)) {
        const name = @typeName(T);
        const start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| dot + 1 else 0;
        var lower: [name.len - start]u8 = undefined;
        _ = std.ascii.lowerString(&lower, name[start..]);
        const final = lower;
        return &final;
    }
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => "int",
        .float => "number",
        .@"enum", .@"union" => blk: {
            var out: []const u8 = "";
            for (choices(T), 0..) |name, i| out = out ++ (if (i == 0) "" else "|") ++ name;
            break :blk out;
        },
        else => "string",
    };
}

/// The documented type of an element type's values.
pub fn valueType(comptime T: type) Flag.ValueType {
    if (comptime hasParse(T)) return .custom;
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int => .int,
        .float => .float,
        .@"enum", .@"union" => .@"enum",
        else => .string,
    };
}

/// The names of an enum's values, or a choice's variants, as they are typed on the
/// command line.
pub fn choices(comptime T: type) []const []const u8 {
    if (hasParse(T)) return &.{};
    const names = switch (@typeInfo(T)) {
        .@"enum" => |e| e.field_names,
        .@"union" => if (field.isChoice(T)) field.fieldNames(T) else return &.{},
        else => return &.{},
    };
    var out: []const []const u8 = &.{};
    for (names) |name| out = out ++ .{kebabName(name)};
    return out;
}

fn kebabName(comptime name: []const u8) []const u8 {
    var out: [name.len]u8 = undefined;
    for (name, 0..) |c, i| out[i] = if (c == '_') '-' else c;
    const final = out;
    return &final;
}

/// Writes a value as it would be typed: enums by name, lists comma-separated.
pub fn write(comptime T: type, value: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (comptime hasParse(T) and std.meta.hasMethod(T, "format")) {
        return writer.print("{f}", .{value});
    }
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .int, .float => try writer.print("{d}", .{value}),
        .@"enum" => for (@tagName(value)) |c| try writer.writeByte(if (c == '_') '-' else c),
        .@"union" => for (@tagName(std.meta.activeTag(value))) |c| {
            try writer.writeByte(if (c == '_') '-' else c);
        },
        .optional => if (value) |v| try write(@TypeOf(v), v, writer),
        .pointer => if (T == []const u8)
            try writer.writeAll(value)
        else for (value, 0..) |item, i| {
            if (i > 0) try writer.writeByte(',');
            try write(@TypeOf(item), item, writer);
        },
        else => try writer.writeAll("?"),
    }
}

/// Whether a default is worth showing in help: not `null`, `false`, zero-length, or zero
/// for a counter.
pub fn isInteresting(comptime T: type, comptime value: T) bool {
    return switch (@typeInfo(T)) {
        .optional => value != null,
        .bool => value,
        .pointer => value.len > 0,
        else => true,
    };
}

const testing = std.testing;

test parse {
    const Mode = enum { dry_run, apply };
    try testing.expectEqual(0x50, try parse(u16, "0x50"));
    try testing.expectError(error.InvalidValue, parse(u8, "256"));
    try testing.expectEqual(Mode.dry_run, try parse(Mode, "dry-run"));
    try testing.expectEqual(Mode.dry_run, try parse(Mode, "dry_run"));
    try testing.expectEqual(true, try parse(bool, "on"));
    try testing.expectEqual(1.5, try parse(f32, "1.5"));
    try testing.expectEqualStrings("x", try parse([]const u8, "x"));
}

test valueType {
    const Duration = struct {
        ns: u64,
        pub fn parse(_: []const u8) !@This() {
            return .{ .ns = 0 };
        }
    };
    try testing.expectEqual(.int, valueType(u16));
    try testing.expectEqual(.float, valueType(f32));
    try testing.expectEqual(.@"enum", valueType(enum { a }));
    try testing.expectEqual(.string, valueType([]const u8));
    try testing.expectEqual(.custom, valueType(Duration));
    try testing.expectEqual(.bool, valueType(bool));
}

test "Element and isList" {
    try testing.expectEqual(u8, Element(?u8));
    try testing.expectEqual([]const u8, Element([]const []const u8));
    try testing.expectEqual([]const u8, Element([]const u8));
    try testing.expect(isList([]const u16));
    try testing.expect(!isList([]const u8));
}

test label {
    const Level = enum { debug, very_loud };
    const Duration = struct {
        ns: u64,
        pub fn parse(_: []const u8) !@This() {
            return .{ .ns = 0 };
        }
    };
    try testing.expectEqualStrings("debug|very-loud", comptime label(Level));
    try testing.expectEqualStrings("duration", comptime label(Duration));
    try testing.expectEqualStrings("int", comptime label(u16));
}

test write {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const Mode = enum { dry_run };
    try write([]const []const u8, &.{ "a", "b" }, &writer);
    try writer.writeByte(' ');
    try write(Mode, .dry_run, &writer);
    try testing.expectEqualStrings("a,b dry-run", writer.buffered());
}

const Celsius = struct {
    degrees: i32,
    pub fn parse(text: []const u8) error{Bad}!Celsius {
        if (!std.mem.endsWith(u8, text, "C")) return error.Bad;
        const n = std.fmt.parseInt(i32, text[0 .. text.len - 1], 10) catch return error.Bad;
        return .{ .degrees = n };
    }
    pub fn format(c: Celsius, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}C", .{c.degrees});
    }
};

/// Has a `parse` method, but not the convention's: it is a method on a value.
const Format = enum {
    json,
    pub fn parse(format: Format, text: []const u8) void {
        _ = format;
        _ = text;
    }
};

/// Returns `T` directly, without an error union.
const Always = struct {
    pub fn parse(_: []const u8) Always {
        return .{};
    }
};

test hasParse {
    try testing.expect(hasParse(Celsius));
    try testing.expect(hasParse(Always));
    try testing.expect(!hasParse(Format));
    try testing.expect(!hasParse(u8));
    try testing.expect(!hasParse(struct {
        const parse = 1;
    }));
    try testing.expect(!hasParse(struct {
        pub fn parse(_: []const u8) !u8 {
            return 0;
        }
    }));
}

test "parse: conventions, bases, and enums with explicit values" {
    try testing.expectEqual(-5, (try parse(Celsius, "-5C")).degrees);
    try testing.expectError(error.InvalidValue, parse(Celsius, "5F"));
    try testing.expectEqual(Format.json, try parse(Format, "json"));
    try testing.expectEqual(-12, try parse(i8, "-12"));
    try testing.expectEqual(8, try parse(u8, "0o10"));
    try testing.expectEqual(5, try parse(u8, "0b101"));
    try testing.expectError(error.InvalidValue, parse(u8, "-1"));
    try testing.expectError(error.InvalidValue, parse(u8, ""));
    try testing.expectError(error.InvalidValue, parse(f64, "1.5.2"));
    try testing.expectError(error.InvalidValue, parse(bool, "maybe"));
    const Sparse = enum(u8) { low = 5, high = 200 };
    try testing.expectEqual(Sparse.high, try parse(Sparse, "high"));
    try testing.expectError(error.InvalidValue, parse(Sparse, "hig"));
    try testing.expectError(error.InvalidValue, parse(Sparse, "200"));
}

test "checker, choices, and labels" {
    try testing.expect(checker(u8)("255"));
    try testing.expect(!checker(u8)("256"));
    try testing.expect(checker(Celsius)("1C"));
    const Mode = enum { dry_run, apply };
    const names = comptime choices(Mode);
    try testing.expectEqual(2, names.len);
    try testing.expectEqualStrings("dry-run", names[0]);
    try testing.expectEqual(0, comptime choices(u8).len);
    const Parsed = enum {
        a,
        pub fn parse(_: []const u8) !@This() {
            return .a;
        }
    };
    try testing.expectEqual(0, comptime choices(Parsed).len);
    try testing.expectEqualStrings("parsed", comptime label(Parsed));
    try testing.expectEqualStrings("bool", comptime label(bool));
    try testing.expectEqualStrings("number", comptime label(f32));
    try testing.expectEqualStrings("string", comptime label([]const u8));
}

test "write every kind of value" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(bool, false, &writer);
    try writer.writeByte(' ');
    try write(f32, 0.5, &writer);
    try writer.writeByte(' ');
    try write(?u8, 3, &writer);
    try write(?u8, null, &writer);
    try writer.writeByte(' ');
    try write(Celsius, .{ .degrees = 20 }, &writer);
    try writer.writeByte(' ');
    try write([]const u16, &.{ 1, 2 }, &writer);
    try writer.writeByte(' ');
    try write([]const u8, "s", &writer);
    try testing.expectEqualStrings("false 0.5 3 20C 1,2 s", writer.buffered());
}

test isInteresting {
    try testing.expect(!isInteresting(?u8, null));
    try testing.expect(isInteresting(?u8, 0));
    try testing.expect(!isInteresting(bool, false));
    try testing.expect(isInteresting(bool, true));
    try testing.expect(!isInteresting([]const u8, ""));
    try testing.expect(isInteresting([]const u8, "x"));
    try testing.expect(isInteresting(u8, 0));
}
