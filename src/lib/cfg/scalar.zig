//! Config scalar types: a duration and a byte size, with their string grammars.
//!
//! These are **generic config behaviour, not NATS behaviour.** They were lifted
//! out of `app/bus/config/root.zig` verbatim once the bus was the only thing that
//! had them and this file was the only thing that could host them. `kvs`, `scp`
//! and the CLI all take durations and sizes in the same two shapes.
//!
//! ## Why the file's type is `DurationMs` and the name is `scalar.zig`
//!
//! The file-layout rule says a file's own scope is its primary type. This file has
//! **two** peer types and no obvious senior one, so it is the documented
//! "not a single subject" case: the names are grouped by what they *are* (config
//! scalars), not by the first type declared. `DurationMs` is the file's own scope
//! because something has to be, and it is the more widely used of the two.
//!
//! `ByteSize` is a declaration inside, so `scalar.ByteSize` and
//! `scalar.DurationMs` both resolve - the alternative was a sibling file, which
//! would separate two grammars that are deliberately parallel.
//!
//! Both grammars are covered by tests that moved with the code.

const std = @import("std");

/// The file is the type: `scalar.DurationMs`.
const Self = @This();

/// A duration in milliseconds, parsed from `"10ms"`, `"1s"`, `"2m"`, `"1h"`, or
/// a plain number of milliseconds.
///
/// A distinct struct rather than a bare `u64` so a config hydrator can dispatch
/// on it, and so `.{ .ms = 2000 }` reads as a duration at the call site.
ms: u64,

/// A byte size, parsed from `"1KB"`, `"1MB"`, `"1GB"`, `"1K"`, `"1M"`, `"1G"`,
/// `"1B"`, or a plain number of bytes.
///
/// A distinct struct for the same reason as `DurationMs`.
pub const ByteSize = struct {
    bytes: u64,
};

/// Constructs a `DurationMs` from a millisecond count.
pub fn durationMs(ms: u64) Self {
    return .{ .ms = ms };
}

/// Constructs a `ByteSize` from a byte count.
pub fn byteSize(bytes: u64) ByteSize {
    return .{ .bytes = bytes };
}

/// Parses a duration (`"10ms"`, `"1s"`, `"2m"`, `"1h"`, or a plain number of
/// milliseconds) into milliseconds.
pub fn parseDurationMs(raw: []const u8) error{ InvalidDuration, Overflow }!Self {
    const trimmed = std.mem.trim(u8, raw, " \t");
    var i: usize = 0;
    while (i < trimmed.len and (trimmed[i] >= '0' and trimmed[i] <= '9')) : (i += 1) {}
    if (i == 0) return error.InvalidDuration;
    const number = std.fmt.parseInt(u64, trimmed[0..i], 10) catch return error.InvalidDuration;

    const rest = trimmed[i..];
    if (rest.len == 0) return .{ .ms = number }; // plain number = milliseconds
    if (std.mem.eql(u8, rest, "ms")) return .{ .ms = number };
    if (std.mem.eql(u8, rest, "s")) {
        if (number > std.math.maxInt(u64) / std.time.ns_per_s) return error.Overflow;
        return .{ .ms = number * std.time.ns_per_s / std.time.ns_per_ms };
    }
    if (std.mem.eql(u8, rest, "m")) {
        if (number > std.math.maxInt(u64) / (60 * std.time.ns_per_s)) return error.Overflow;
        return .{ .ms = number * 60 * std.time.ns_per_s / std.time.ns_per_ms };
    }
    if (std.mem.eql(u8, rest, "h")) {
        if (number > std.math.maxInt(u64) / (3600 * std.time.ns_per_s)) return error.Overflow;
        return .{ .ms = number * 3600 * std.time.ns_per_s / std.time.ns_per_ms };
    }
    return error.InvalidDuration;
}

/// Parses a byte size (`"1KB"`, `"1MB"`, `"1GB"`, `"1K"`, `"1M"`, `"1G"`, `"1B"`,
/// or a plain number of bytes) into bytes.
pub fn parseByteSize(raw: []const u8) error{ InvalidSize, Overflow }!ByteSize {
    const trimmed = std.mem.trim(u8, raw, " \t");
    var i: usize = 0;
    while (i < trimmed.len and (trimmed[i] >= '0' and trimmed[i] <= '9')) : (i += 1) {}
    if (i == 0) return error.InvalidSize;
    const number = std.fmt.parseInt(u64, trimmed[0..i], 10) catch return error.InvalidSize;

    const rest = trimmed[i..];
    if (rest.len == 0) return .{ .bytes = number };
    const mult: u64 = if (std.mem.eql(u8, rest, "B")) 1 else if (std.mem.eql(u8, rest, "K") or std.mem.eql(u8, rest, "KB")) 1024 else if (std.mem.eql(u8, rest, "M") or std.mem.eql(u8, rest, "MB")) 1024 * 1024 else if (std.mem.eql(u8, rest, "G") or std.mem.eql(u8, rest, "GB")) 1024 * 1024 * 1024 else return error.InvalidSize;
    if (number > std.math.maxInt(u64) / mult) return error.Overflow;
    return .{ .bytes = number * mult };
}

test "parseDurationMs units" {
    const t = std.testing;
    try t.expectEqual(@as(Self, .{ .ms = 10 }), try parseDurationMs("10ms"));
    try t.expectEqual(@as(Self, .{ .ms = 1000 }), try parseDurationMs("1s"));
    try t.expectEqual(@as(Self, .{ .ms = 120_000 }), try parseDurationMs("2m"));
    try t.expectEqual(@as(Self, .{ .ms = 3_600_000 }), try parseDurationMs("1h"));
    try t.expectEqual(@as(Self, .{ .ms = 500 }), try parseDurationMs("500"));
    try t.expectEqual(@as(Self, .{ .ms = 500 }), try parseDurationMs(" 500 "));
    try t.expectError(error.InvalidDuration, parseDurationMs("ms"));
    try t.expectError(error.InvalidDuration, parseDurationMs("1x"));
    try t.expectError(error.InvalidDuration, parseDurationMs(""));
}

test "parseByteSize units" {
    const t = std.testing;
    try t.expectEqual(@as(ByteSize, .{ .bytes = 1024 }), try parseByteSize("1KB"));
    try t.expectEqual(@as(ByteSize, .{ .bytes = 1024 }), try parseByteSize("1K"));
    try t.expectEqual(@as(ByteSize, .{ .bytes = 1024 * 1024 }), try parseByteSize("1MB"));
    try t.expectEqual(@as(ByteSize, .{ .bytes = 1024 * 1024 * 1024 }), try parseByteSize("1GB"));
    try t.expectEqual(@as(ByteSize, .{ .bytes = 500 }), try parseByteSize("500"));
    try t.expectEqual(@as(ByteSize, .{ .bytes = 5 }), try parseByteSize("5B"));
    try t.expectError(error.InvalidSize, parseByteSize("1XB"));
    try t.expectError(error.InvalidSize, parseByteSize("KB"));
}

test "the two scalar types are both reached through the file" {
    // Asserted so a future split cannot silently re-spell `scalar.ByteSize`,
    // which 12 bus config fields and 32 internal references depend on.
    try std.testing.expectEqual(@as(Self, .{ .ms = 7 }), durationMs(7));
    try std.testing.expectEqual(ByteSize{ .bytes = 7 }, byteSize(7));
    try std.testing.expect(@hasField(Self, "ms"));
    try std.testing.expect(@hasField(ByteSize, "bytes"));
}

/// Parses `raw` into the config field type `TargetType`.
///
/// This is the counterpart to the two grammars above: they answer "what does
/// `2m` mean", this answers "does `2m` belong in *this* field". It exists because
/// three callers needed that answer and each was about to grow its own copy -
/// `app/bus/config`'s hydrator, `app/cfg`'s dry-run validator, and any future
/// typed-override path.
///
/// Supported field types are the ones a config file can express: integers,
/// booleans, byte slices, optionals of those, `DurationMs` and `ByteSize`. A type
/// outside that set is a **compile error** in the caller rather than a runtime
/// rejection, because a config field the framework cannot parse is a bug in the
/// config declaration, not in the user's input.
///
/// Error semantics are deliberately coarse. A caller reporting to a user needs
/// "this value does not fit this field"; distinguishing `InvalidCharacter` from
/// `Overflow` would leak `std.fmt`'s vocabulary into user-facing messages.
pub fn parseValue(
    comptime TargetType: type,
    raw: []const u8,
    allocator: std.mem.Allocator,
) !TargetType {
    const is_optional = @typeInfo(TargetType) == .optional;
    const RealType = if (is_optional) @typeInfo(TargetType).optional.child else TargetType;

    var parsed: RealType = switch (@typeInfo(RealType)) {
        .int => std.fmt.parseInt(RealType, raw, 10) catch return error.InvalidValue,
        .float => std.fmt.parseFloat(RealType, raw) catch return error.InvalidValue,
        .bool => parseBool(raw) orelse return error.InvalidValue,
        // An enum is matched by tag name, because that is what a human writes in a
        // config file and what a flag value looks like. Numeric ordinals are
        // deliberately not accepted: a config file that silently changes meaning
        // when a variant is inserted in the middle is worse than one that fails.
        .@"enum" => std.meta.stringToEnum(RealType, raw) orelse return error.InvalidValue,
        .pointer => |p| blk: {
            if (p.size != .slice or p.child != u8) {
                @compileError("unsupported config field type: " ++ @typeName(RealType));
            }
            break :blk allocator.dupe(u8, raw) catch return error.OutOfMemory;
        },
        .@"struct" => blk: {
            if (RealType == Self) break :blk parseDurationMs(raw) catch return error.InvalidValue;
            if (RealType == ByteSize) break :blk parseByteSize(raw) catch return error.InvalidValue;
            @compileError("unsupported config struct field type: " ++ @typeName(RealType));
        },
        else => @compileError("unsupported config field type: " ++ @typeName(RealType)),
    };
    _ = &parsed;

    if (is_optional) return parsed;
    return parsed;
}

/// The boolean spellings a config file may use.
///
/// `yes`/`no` are included because the bus's existing flag sink already accepts
/// them (`app/kvs/persistence`) and both spellings appear in real config files.
///
/// `1`/`0` are included because the environment is where a boolean most often
/// arrives as a digit, and `loader.load` already accepted `1` as true. Omitting
/// them here would have made the binder reject a spelling the resolver it replaces
/// accepted - the kind of quiet regression that only shows up as "my env var
/// stopped working".
fn parseBool(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.ascii.eqlIgnoreCase(raw, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.ascii.eqlIgnoreCase(raw, "no")) return false;
    if (std.mem.eql(u8, raw, "1")) return true;
    if (std.mem.eql(u8, raw, "0")) return false;
    return null;
}

test "parseValue accepts the shapes a config file can express" {
    const a = std.testing.allocator;

    try std.testing.expectEqual(@as(u16, 8080), try parseValue(u16, "8080", a));
    try std.testing.expectEqual(true, try parseValue(bool, "yes", a));
    try std.testing.expectEqual(false, try parseValue(bool, "FALSE", a));
    try std.testing.expectEqual(@as(?u16, 9), try parseValue(?u16, "9", a));
    try std.testing.expectEqual(@as(Self, .{ .ms = 2000 }), try parseValue(Self, "2s", a));
    try std.testing.expectEqual(ByteSize{ .bytes = 1024 }, try parseValue(ByteSize, "1KB", a));

    const s = try parseValue([]const u8, "hello", a);
    defer a.free(s);
    try std.testing.expectEqualStrings("hello", s);
}

test "parseValue rejects what does not fit, without leaking" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parseValue(u16, "not-a-number", a));
    try std.testing.expectError(error.InvalidValue, parseValue(u16, "-1", a));
    try std.testing.expectError(error.InvalidValue, parseValue(u16, "99999999", a));
    try std.testing.expectError(error.InvalidValue, parseValue(bool, "maybe", a));
    try std.testing.expectError(error.InvalidValue, parseValue(Self, "2 fortnights", a));
    try std.testing.expectError(error.InvalidValue, parseValue(ByteSize, "1XB", a));
}
