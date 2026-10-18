//! Semantic versions, per Semantic Versioning 2.0.0 (https://semver.org).
//!
//! `parse` accepts `MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]` with an optional leading `v`
//! (`v1.2.3`, the form release tags take). Parsing does not allocate: the pre-release and
//! build slices point into the text, so a `Version` lives as long as the text it came from.
//!
//! `order` implements the precedence rules of section 11: core numbers numerically, a
//! pre-release below its release, pre-release identifiers left to right (numeric ones
//! numerically and below alphanumeric ones, alphanumeric ones in ASCII order, a shorter
//! list below a longer one it prefixes). Build metadata never takes part in precedence.

const std = @import("std");
const assert = std.debug.assert;

/// The text is not a semantic version.
pub const ParseError = error{InvalidVersion};

/// A parsed version. `pre` and `build` are empty when absent; they hold the text after `-`
/// and `+` respectively, dot-separated identifiers included.
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    pre: []const u8 = "",
    build: []const u8 = "",

    /// Parses `text`, which may start with a `v`.
    pub fn parse(text: []const u8) ParseError!Version {
        return parseVersion(text);
    }

    /// Precedence of `a` relative to `b`; build metadata is ignored.
    pub fn order(a: Version, b: Version) std.math.Order {
        return orderVersions(a, b);
    }

    /// Whether `a` has strictly higher precedence than `b`.
    pub fn newerThan(a: Version, b: Version) bool {
        return order(a, b) == .gt;
    }

    /// Whether this is a pre-release (`1.0.0-rc.1`).
    pub fn isPrerelease(v: Version) bool {
        return v.pre.len > 0;
    }

    /// Writes the canonical form, without a leading `v`: `1.2.3-rc.1+build.5`.
    pub fn format(v: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        if (v.pre.len > 0) try writer.print("-{s}", .{v.pre});
        if (v.build.len > 0) try writer.print("+{s}", .{v.build});
    }
};

/// Parses `text`, which may start with a `v`. Shorthand for `Version.parse`.
pub fn parse(text: []const u8) ParseError!Version {
    return parseVersion(text);
}

fn parseVersion(text: []const u8) ParseError!Version {
    var rest = text;
    if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];
    var build: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        build = rest[plus + 1 ..];
        rest = rest[0..plus];
        try checkIdentifiers(build, .build);
    }
    var pre: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        pre = rest[dash + 1 ..];
        rest = rest[0..dash];
        try checkIdentifiers(pre, .pre);
    }
    var parts = std.mem.splitScalar(u8, rest, '.');
    const major = try parseNumber(parts.next() orelse return error.InvalidVersion);
    const minor = try parseNumber(parts.next() orelse return error.InvalidVersion);
    const patch = try parseNumber(parts.next() orelse return error.InvalidVersion);
    if (parts.next() != null) return error.InvalidVersion;
    return .{ .major = major, .minor = minor, .patch = patch, .pre = pre, .build = build };
}

/// A core number: digits only, no leading zero, fits in `u64`.
fn parseNumber(text: []const u8) ParseError!u64 {
    if (!isNumeric(text)) return error.InvalidVersion;
    if (text.len > 1 and text[0] == '0') return error.InvalidVersion;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidVersion;
}

const Part = enum { pre, build };

/// Dot-separated, non-empty `[0-9A-Za-z-]` identifiers; numeric pre-release identifiers
/// may not have leading zeros (build identifiers may).
fn checkIdentifiers(text: []const u8, part: Part) ParseError!void {
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |identifier| {
        if (identifier.len == 0) return error.InvalidVersion;
        for (identifier) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidVersion;
        }
        const leading_zero = identifier.len > 1 and identifier[0] == '0';
        if (part == .pre and leading_zero and isNumeric(identifier)) {
            return error.InvalidVersion;
        }
    }
}

fn isNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn orderVersions(a: Version, b: Version) std.math.Order {
    const core = std.math.order(a.major, b.major)
        .differ() orelse std.math.order(a.minor, b.minor)
        .differ() orelse std.math.order(a.patch, b.patch);
    if (core != .eq) return core;
    // A release outranks any of its pre-releases.
    if (a.pre.len == 0 or b.pre.len == 0) {
        return std.math.order(@intFromBool(a.pre.len == 0), @intFromBool(b.pre.len == 0));
    }
    return orderPrerelease(a.pre, b.pre);
}

fn orderPrerelease(a: []const u8, b: []const u8) std.math.Order {
    var left = std.mem.splitScalar(u8, a, '.');
    var right = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = left.next() orelse return if (right.next() == null) .eq else .lt;
        const y = right.next() orelse return .gt;
        const result = orderIdentifier(x, y);
        if (result != .eq) return result;
    }
}

fn orderIdentifier(x: []const u8, y: []const u8) std.math.Order {
    const x_numeric = isNumeric(x);
    const y_numeric = isNumeric(y);
    if (x_numeric and y_numeric) {
        // Parsing guarantees no leading zeros, so the longer number is the larger one and
        // equal lengths compare as text; this never overflows, however long the digits.
        assert(x.len == 1 or x[0] != '0');
        assert(y.len == 1 or y[0] != '0');
        if (x.len != y.len) return std.math.order(x.len, y.len);
        return std.mem.order(u8, x, y);
    }
    if (x_numeric) return .lt;
    if (y_numeric) return .gt;
    return std.mem.order(u8, x, y);
}

const testing = std.testing;

test "parse: core, pre-release, build, leading v" {
    const v = try parse("v1.20.3-rc.1+build.7");
    try testing.expectEqual(@as(u64, 1), v.major);
    try testing.expectEqual(@as(u64, 20), v.minor);
    try testing.expectEqual(@as(u64, 3), v.patch);
    try testing.expectEqualStrings("rc.1", v.pre);
    try testing.expectEqualStrings("build.7", v.build);
    try testing.expect(v.isPrerelease());

    const plain = try Version.parse("0.0.0");
    try testing.expectEqualStrings("", plain.pre);
    try testing.expect(!plain.isPrerelease());

    const hyphens = try parse("1.0.0-x-y-z.--+a-b");
    try testing.expectEqualStrings("x-y-z.--", hyphens.pre);
    try testing.expectEqualStrings("a-b", hyphens.build);
}

test "parse: rejects what the grammar does not allow" {
    const bad = [_][]const u8{
        "",                         "v",         "1",      "1.2",    "1.2.3.4",    "01.2.3",
        "1.02.3",                   "1.2.03",    "1.2.3-", "1.2.3+", "1.2.3-a..b", "1.2.3-01",
        "1.2.3-a_b",                "1.2.3+a b", "V1.2.3", "-1.2.3", "1.2.x",
        "1.2.3-é",
        "99999999999999999999.0.0",
    };
    for (bad) |text| {
        try testing.expectError(error.InvalidVersion, parse(text));
    }
    // Build identifiers may have leading zeros; pre-release alphanumerics may too.
    _ = try parse("1.2.3+001");
    _ = try parse("1.2.3-0a");
}

test "format: canonical text without the v" {
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{try parse("v1.2.3-beta.2+sha.5114f85")});
    try testing.expectEqualStrings("1.2.3-beta.2+sha.5114f85", text);
    const core = try std.fmt.bufPrint(&buffer, "{f}", .{try parse("10.0.1")});
    try testing.expectEqualStrings("10.0.1", core);
}

test "order: the precedence examples of the specification" {
    const ascending = [_][]const u8{
        "1.0.0-alpha",  "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
        "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1",       "1.0.0",
        "2.0.0",        "2.1.0",         "2.1.1",
    };
    for (ascending, 0..) |lower_text, i| {
        const lower = try parse(lower_text);
        try testing.expectEqual(std.math.Order.eq, lower.order(lower));
        for (ascending[i + 1 ..]) |higher_text| {
            const higher = try parse(higher_text);
            try testing.expectEqual(std.math.Order.lt, lower.order(higher));
            try testing.expectEqual(std.math.Order.gt, higher.order(lower));
            try testing.expect(higher.newerThan(lower));
            try testing.expect(!lower.newerThan(higher));
        }
    }
}

test "order: build metadata is ignored, huge numeric identifiers compare numerically" {
    const a = try parse("1.0.0+20130313144700");
    const b = try parse("v1.0.0+exp.sha.5114f85");
    try testing.expectEqual(std.math.Order.eq, a.order(b));
    try testing.expect(!a.newerThan(b));

    const small = try parse("1.0.0-99999999999999999999999");
    const large = try parse("1.0.0-100000000000000000000000");
    try testing.expectEqual(std.math.Order.lt, small.order(large));
    // Numeric identifiers rank below alphanumeric ones.
    try testing.expectEqual(std.math.Order.lt, (try parse("1.0.0-9")).order(try parse("1.0.0-a")));
}
