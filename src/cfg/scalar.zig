//! Scalar types with a text grammar, and type inference for untyped text.
//!
//! `Duration`, `ByteSize`, and `DateTime` follow the `parse` convention shared with `cli`:
//! a type that declares `pub fn parse(text: []const u8) !T` can be decoded from
//! configuration and used as a flag type.

const std = @import("std");
const assert = std.debug.assert;
const Value = @import("value.zig").Value;

/// What the `parse` functions can fail with.
pub const ParseError = error{ InvalidCharacter, Overflow };

/// A span of time, in nanoseconds. Text form: one or more `<number><unit>` terms, such as
/// `500ms`, `1.5s`, `1h30m`, `2d`. Units: `ns`, `us`, `ms`, `s`, `m`, `h`, `d`, `w`. A bare
/// `0` is also accepted.
pub const Duration = struct {
    ns: u64,

    /// No time at all.
    pub const zero: Duration = .{ .ns = 0 };

    const units = [_]struct { []const u8, u64 }{
        .{ "ns", 1 },
        .{ "us", std.time.ns_per_us },
        .{ "ms", std.time.ns_per_ms },
        .{ "s", std.time.ns_per_s },
        .{ "m", std.time.ns_per_min },
        .{ "h", std.time.ns_per_hour },
        .{ "d", std.time.ns_per_day },
        .{ "w", std.time.ns_per_week },
    };

    /// Reads `90s`, `1h30m`, `1.5s`, `250ms`, or `0`.
    pub fn parse(text: []const u8) ParseError!Duration {
        if (std.mem.eql(u8, text, "0")) return zero;
        if (text.len == 0) return error.InvalidCharacter;
        var total: u64 = 0;
        var rest = text;
        while (rest.len > 0) {
            const number_len = numberPrefix(rest);
            if (number_len == 0) return error.InvalidCharacter;
            const unit_len = std.mem.indexOfAny(u8, rest[number_len..], "0123456789.") orelse
                rest.len - number_len;
            const unit = rest[number_len..][0..unit_len];
            const scale = for (units) |u| {
                if (std.mem.eql(u8, u[0], unit)) break u[1];
            } else return error.InvalidCharacter;
            const term = try scaleNumber(rest[0..number_len], scale);
            total = std.math.add(u64, total, term) catch return error.Overflow;
            rest = rest[number_len + unit_len ..];
        }
        return .{ .ns = total };
    }

    /// Writes the shortest exact compound form: `1h30m`, `1.5s` is written `1s500ms`.
    pub fn format(d: Duration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d.ns == 0) return writer.writeAll("0s");
        var rest = d.ns;
        var i: usize = units.len;
        while (i > 0) {
            i -= 1;
            // Weeks are accepted but not produced: `14d` reads better than `2w`.
            if (std.mem.eql(u8, units[i][0], "w")) continue;
            const scale = units[i][1];
            if (rest >= scale) {
                try writer.print("{d}{s}", .{ rest / scale, units[i][0] });
                rest %= scale;
            }
        }
        assert(rest == 0);
    }

    /// The same span as a `std.Io.Duration`, for timeouts and sleeps.
    pub fn toIo(d: Duration) std.Io.Duration {
        return .fromNanoseconds(d.ns);
    }

    /// A `std.Io.Duration` as a `Duration`; a negative one is zero.
    pub fn fromIo(d: std.Io.Duration) Duration {
        return .{ .ns = std.math.lossyCast(u64, d.toNanoseconds()) };
    }
};

/// A count of bytes. Text form: a number and an optional unit: `B`, decimal `KB` `MB` `GB`
/// `TB` `PB` (powers of 1000) or binary `KiB` `MiB` `GiB` `TiB` `PiB` (powers of 1024).
/// `K`, `M`, `G`, `T`, `P` alone are binary. Units are case-insensitive; a fraction is
/// allowed (`1.5GiB`) and is truncated to whole bytes.
pub const ByteSize = struct {
    bytes: u64,

    const units = [_]struct { []const u8, u64 }{
        .{ "", 1 },                      .{ "b", 1 },
        .{ "kb", 1000 },                 .{ "mb", 1000_000 },
        .{ "gb", 1000_000_000 },         .{ "tb", 1000_000_000_000 },
        .{ "pb", 1000_000_000_000_000 }, .{ "k", 1 << 10 },
        .{ "kib", 1 << 10 },             .{ "m", 1 << 20 },
        .{ "mib", 1 << 20 },             .{ "g", 1 << 30 },
        .{ "gib", 1 << 30 },             .{ "t", 1 << 40 },
        .{ "tib", 1 << 40 },             .{ "p", 1 << 50 },
        .{ "pib", 1 << 50 },
    };

    /// Reads `512`, `10MiB`, `1.5GB`, `4k`.
    pub fn parse(text: []const u8) ParseError!ByteSize {
        const number_len = numberPrefix(text);
        if (number_len == 0) return error.InvalidCharacter;
        const unit = std.mem.trim(u8, text[number_len..], " ");
        if (unit.len > 3) return error.InvalidCharacter;
        var lower: [3]u8 = undefined;
        const unit_lower = std.ascii.lowerString(&lower, unit);
        const scale = for (units) |u| {
            if (std.mem.eql(u8, u[0], unit_lower)) break u[1];
        } else return error.InvalidCharacter;
        return .{ .bytes = try scaleNumber(text[0..number_len], scale) };
    }

    /// Writes the largest unit that represents the size exactly, preferring binary units.
    pub fn format(size: ByteSize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const binary = [_][]const u8{ "PiB", "TiB", "GiB", "MiB", "KiB" };
        const decimal = [_][]const u8{ "PB", "TB", "GB", "MB", "KB" };
        if (size.bytes == 0) return writer.writeAll("0B");
        for (binary, 0..) |name, i| {
            const scale = @as(u64, 1) << @intCast(10 * (binary.len - i));
            if (size.bytes % scale == 0) {
                return writer.print("{d}{s}", .{ size.bytes / scale, name });
            }
        }
        for (decimal, 0..) |name, i| {
            const scale = std.math.pow(u64, 1000, decimal.len - i);
            if (size.bytes % scale == 0) {
                return writer.print("{d}{s}", .{ size.bytes / scale, name });
            }
        }
        try writer.print("{d}B", .{size.bytes});
    }
};

/// The length of the leading `digits[.digits]` run of `text`.
fn numberPrefix(text: []const u8) usize {
    var i: usize = 0;
    var seen_dot = false;
    while (i < text.len) : (i += 1) {
        if (std.ascii.isDigit(text[i])) continue;
        if (text[i] == '.' and !seen_dot) {
            seen_dot = true;
            continue;
        }
        break;
    }
    return i;
}

/// `number * scale`, where `number` is `digits[.digits]`, truncated to an integer.
fn scaleNumber(number: []const u8, scale: u64) ParseError!u64 {
    const dot = std.mem.indexOfScalar(u8, number, '.') orelse number.len;
    const whole_text = number[0..dot];
    if (whole_text.len == 0 and dot + 1 >= number.len) return error.InvalidCharacter;
    const whole = if (whole_text.len == 0) 0 else try std.fmt.parseUnsigned(u64, whole_text, 10);
    var total = std.math.mul(u64, whole, scale) catch return error.Overflow;
    if (dot < number.len) {
        const fraction = number[dot + 1 ..];
        if (fraction.len == 0) return error.InvalidCharacter;
        // Exact integer arithmetic: fraction * scale / 10^digits, truncated. Digits past the
        // 18th cannot change a u64 result by more than rounding, so they are ignored.
        const digits = fraction[0..@min(fraction.len, 18)];
        const numerator = try std.fmt.parseUnsigned(u64, digits, 10);
        const denominator = std.math.pow(u64, 10, digits.len);
        const part = @as(u128, numerator) * scale / denominator;
        for (fraction[digits.len..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidCharacter;
        total = std.math.add(u64, total, @intCast(part)) catch return error.Overflow;
    }
    return total;
}

/// The value untyped text most plausibly means: `true`/`false` are booleans, integers and
/// decimal floats are numbers, `null` is null, and anything else is the string itself. Used
/// for command-line `key=value` input, where the user wrote no type.
pub fn infer(text: []const u8) Value {
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, text, "null")) return .null;
    if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .int = i } else |_| {}
    if (looksLikeDecimal(text)) {
        if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
    }
    return .{ .string = text };
}

/// Digits with exactly one `.` or an exponent, and nothing else: rules out `inf`, `nan`,
/// `0x1p3`, and version strings like `1.2.3`.
fn looksLikeDecimal(text: []const u8) bool {
    var digits: usize = 0;
    var dots: usize = 0;
    var exponent = false;
    for (text, 0..) |c, i| {
        switch (c) {
            '0'...'9' => digits += 1,
            '.' => dots += 1,
            'e', 'E' => exponent = true,
            '+', '-' => if (i != 0 and text[i - 1] != 'e' and text[i - 1] != 'E') return false,
            else => return false,
        }
    }
    return digits > 0 and dots <= 1 and (dots == 1 or exponent);
}

/// A date, a time of day, or both, with an optional offset from UTC: the four kinds TOML
/// has, in RFC 3339 spelling. Text forms: `1979-05-27`, `07:32:00`, `07:32:00.999`,
/// `1979-05-27T07:32:00` (local), `1979-05-27T07:32:00Z`, `1979-05-27 07:32:00-07:00`.
///
/// Configuration keeps a date-time as its text (TOML writes it back unquoted), and a field
/// of this type decodes it.
pub const DateTime = struct {
    date: ?Date = null,
    time: ?Time = null,
    /// Minutes east of UTC; null for a local date-time, a date, or a time.
    offset: ?i16 = null,

    /// A calendar date.
    pub const Date = struct { year: u16, month: u8, day: u8 };
    /// A time of day.
    pub const Time = struct { hour: u8, minute: u8, second: u8, nanosecond: u32 = 0 };

    /// Reads any of the text forms above.
    pub fn parse(text: []const u8) ParseError!DateTime {
        var result: DateTime = .{};
        var rest = text;
        if (rest.len >= 10 and rest[4] == '-') {
            result.date = try parseDate(rest[0..10]);
            rest = rest[10..];
            if (rest.len == 0) return result;
            if (rest[0] != 'T' and rest[0] != 't' and rest[0] != ' ') return error.InvalidCharacter;
            rest = rest[1..];
        }
        const time_len = timeLength(rest) orelse return error.InvalidCharacter;
        result.time = try parseTime(rest[0..time_len]);
        rest = rest[time_len..];
        if (rest.len == 0) return result;
        if (result.date == null) return error.InvalidCharacter; // A time has no offset.
        if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {
            result.offset = 0;
            return result;
        }
        if (rest.len != 6 or (rest[0] != '+' and rest[0] != '-') or rest[3] != ':') {
            return error.InvalidCharacter;
        }
        const hours = try twoDigits(rest[1..3]);
        const minutes = try twoDigits(rest[4..6]);
        if (hours > 23 or minutes > 59) return error.Overflow;
        const magnitude: i16 = @as(i16, hours) * 60 + minutes;
        result.offset = if (rest[0] == '-') -magnitude else magnitude;
        return result;
    }

    fn parseDate(text: *const [10]u8) ParseError!Date {
        if (text[4] != '-' or text[7] != '-') return error.InvalidCharacter;
        const year = std.fmt.parseUnsigned(u16, text[0..4], 10) catch return error.InvalidCharacter;
        const month = try twoDigits(text[5..7]);
        const day = try twoDigits(text[8..10]);
        if (month < 1 or month > 12 or day < 1) return error.Overflow;
        const days: u8 = switch (month) {
            2 => if (std.time.epoch.isLeapYear(year)) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        };
        if (day > days) return error.Overflow;
        return .{ .year = year, .month = month, .day = day };
    }

    fn timeLength(text: []const u8) ?usize {
        if (text.len < 8 or text[2] != ':' or text[5] != ':') return null;
        if (text.len == 8 or text[8] != '.') return 8;
        var end: usize = 9;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        return if (end == 9) null else end;
    }

    fn parseTime(text: []const u8) ParseError!Time {
        const hour = try twoDigits(text[0..2]);
        const minute = try twoDigits(text[3..5]);
        const second = try twoDigits(text[6..8]);
        // A leap second may be 60.
        if (hour > 23 or minute > 59 or second > 60) return error.Overflow;
        var nanosecond: u32 = 0;
        if (text.len > 9) {
            // Digits past nanoseconds are dropped, as TOML allows.
            for (0..9) |i| {
                const digit: u32 = if (9 + i < text.len) text[9 + i] - '0' else 0;
                nanosecond = nanosecond * 10 + digit;
            }
        }
        return .{ .hour = hour, .minute = minute, .second = second, .nanosecond = nanosecond };
    }

    fn twoDigits(text: *const [2]u8) ParseError!u8 {
        if (!std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[1])) {
            return error.InvalidCharacter;
        }
        return (text[0] - '0') * 10 + (text[1] - '0');
    }

    /// Seconds since 1970-01-01T00:00:00Z, for a date and time with an offset; null for a
    /// local date-time, a date, or a time, which name no instant.
    pub fn unixSeconds(dt: DateTime) ?i64 {
        const date = dt.date orelse return null;
        const time = dt.time orelse return null;
        const offset = dt.offset orelse return null;
        // Days since the epoch, by the civil-from-days algorithm run backwards.
        const y: i64 = @as(i64, date.year) - @intFromBool(date.month <= 2);
        const era = @divFloor(y, 400);
        const year_of_era = y - era * 400;
        const m: i64 = date.month;
        const day_of_year = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + date.day - 1;
        const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
            @divFloor(year_of_era, 100) + day_of_year;
        const days = era * 146097 + day_of_era - 719468;
        const seconds = @as(i64, time.hour) * 3600 + @as(i64, time.minute) * 60 + time.second;
        return days * 86400 + seconds - @as(i64, offset) * 60;
    }

    /// Writes the RFC 3339 spelling of what is set.
    pub fn format(dt: DateTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (dt.date) |d| try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
        if (dt.date != null and dt.time != null) try writer.writeByte('T');
        if (dt.time) |t| {
            try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
            if (t.nanosecond != 0) {
                var digits: [9]u8 = undefined;
                _ = std.fmt.bufPrint(&digits, "{d:0>9}", .{t.nanosecond}) catch unreachable;
                try writer.print(".{s}", .{std.mem.trimEnd(u8, &digits, "0")});
            }
        }
        if (dt.offset) |offset| {
            if (offset == 0) return writer.writeByte('Z');
            const sign: u8 = if (offset < 0) '-' else '+';
            const magnitude = @abs(offset);
            try writer.print("{c}{d:0>2}:{d:0>2}", .{ sign, magnitude / 60, magnitude % 60 });
        }
    }
};

const testing = std.testing;

test "DateTime.parse and format" {
    const cases = [_][2][]const u8{
        .{ "1979-05-27", "1979-05-27" },
        .{ "07:32:00", "07:32:00" },
        .{ "00:32:00.999999", "00:32:00.999999" },
        .{ "1979-05-27T07:32:00", "1979-05-27T07:32:00" },
        .{ "1979-05-27 07:32:00Z", "1979-05-27T07:32:00Z" },
        .{ "1979-05-27T00:32:00.5-07:00", "1979-05-27T00:32:00.5-07:00" },
    };
    for (cases) |case| {
        const dt = try DateTime.parse(case[0]);
        var buffer: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try dt.format(&w);
        try testing.expectEqualStrings(case[1], w.buffered());
    }
    for ([_][]const u8{ "1979-13-01", "1979-02-30", "25:00:00", "07:32", "07:32:00Z", "x" }) |bad| {
        try testing.expect(std.meta.isError(DateTime.parse(bad)));
    }
    const instants = [_]struct { []const u8, ?i64 }{
        .{ "1979-05-27T07:32:00Z", 296638320 },
        .{ "1979-05-27T07:32:00-07:00", 296663520 },
        .{ "2000-02-29T00:00:00Z", 951782400 },
        .{ "1979-05-27", null },
    };
    for (instants) |case| {
        try testing.expectEqual(case[1], (try DateTime.parse(case[0])).unixSeconds());
    }
}

test "Duration.parse" {
    try testing.expectEqual(500 * std.time.ns_per_ms, (try Duration.parse("500ms")).ns);
    try testing.expectEqual(90 * std.time.ns_per_min, (try Duration.parse("1h30m")).ns);
    try testing.expectEqual(1500 * std.time.ns_per_ms, (try Duration.parse("1.5s")).ns);
    try testing.expectEqual(2 * std.time.ns_per_day, (try Duration.parse("2d")).ns);
    try testing.expectEqual(0, (try Duration.parse("0")).ns);
    const bad = [_][]const u8{ "", "5", "s", "5x", "1h-1m", ".s", "5.s", "1..5s" };
    for (bad) |text| try testing.expectError(error.InvalidCharacter, Duration.parse(text));
    try testing.expectError(error.Overflow, Duration.parse("99999999999999999w"));
}

test "Duration to and from std.Io.Duration" {
    const d: Duration = try .parse("1m30s");
    try std.testing.expectEqual(90 * std.time.ns_per_s, d.toIo().toNanoseconds());
    try std.testing.expectEqual(d, Duration.fromIo(d.toIo()));
    try std.testing.expectEqual(Duration.zero, Duration.fromIo(.fromNanoseconds(-5)));
}

test "Duration.format" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f} {f} {f}", .{
        try Duration.parse("90m"),
        try Duration.parse("1.5s"),
        Duration.zero,
    });
    try testing.expectEqualStrings("1h30m 1s500ms 0s", writer.buffered());
}

test "ByteSize.parse" {
    try testing.expectEqual(512, (try ByteSize.parse("512")).bytes);
    try testing.expectEqual(512, (try ByteSize.parse("512B")).bytes);
    try testing.expectEqual(10_000, (try ByteSize.parse("10KB")).bytes);
    try testing.expectEqual(10 * 1024, (try ByteSize.parse("10KiB")).bytes);
    try testing.expectEqual(10 * 1024, (try ByteSize.parse("10k")).bytes);
    try testing.expectEqual(3 << 29, (try ByteSize.parse("1.5GiB")).bytes);
    try testing.expectEqual(2 << 30, (try ByteSize.parse("2 gib")).bytes);
    const bad = [_][]const u8{ "", "KB", "10XB", "1.2.3", "10 kibs" };
    for (bad) |text| try testing.expectError(error.InvalidCharacter, ByteSize.parse(text));
}

test "ByteSize.format" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f} {f} {f} {f}", .{
        ByteSize{ .bytes = 2 << 30 },
        ByteSize{ .bytes = 10_000 },
        ByteSize{ .bytes = 1001 },
        ByteSize{ .bytes = 0 },
    });
    try testing.expectEqualStrings("2GiB 10KB 1001B 0B", writer.buffered());
}

test infer {
    try testing.expectEqual(Value{ .bool = true }, infer("true"));
    try testing.expectEqual(Value{ .int = -42 }, infer("-42"));
    try testing.expectEqual(Value{ .float = 2.5 }, infer("2.5"));
    try testing.expectEqual(Value{ .float = 1e3 }, infer("1e3"));
    try testing.expectEqual(Value.null, infer("null"));
    const strings = [_][]const u8{ "1.2.3", "inf", "nan", "0x10", "True", "", "8080/tcp" };
    for (strings) |text| try testing.expectEqualStrings(text, infer(text).string);
}

test "Duration.parse fractions, repeats, and overflow" {
    const ns_per_s = std.time.ns_per_s;
    try testing.expectEqual(90 * std.time.ns_per_min, (try Duration.parse("1.5h")).ns);
    try testing.expectEqual(ns_per_s / 2, (try Duration.parse(".5s")).ns);
    try testing.expectEqual(2 * std.time.ns_per_hour, (try Duration.parse("1h1h")).ns);
    try testing.expectEqual(1, (try Duration.parse("1ns")).ns);
    try testing.expectEqual(1500, (try Duration.parse("1.5us")).ns);
    try testing.expectEqual(1, (try Duration.parse("1.9ns")).ns); // Truncated.
    try testing.expectEqual(2 * std.time.ns_per_week, (try Duration.parse("2w")).ns);
    // More fraction digits than a u64 holds are read and ignored.
    try testing.expectEqual(ns_per_s, (try Duration.parse("1.0000000000000000000009s")).ns);
    // Each term fits, but their sum does not.
    try testing.expectError(error.Overflow, Duration.parse("15251w15251w"));
    try testing.expectEqual(
        15250 * 2 * std.time.ns_per_week,
        (try Duration.parse("15250w15250w")).ns,
    );
    try testing.expectError(error.Overflow, Duration.parse("99999999999999999999ns"));
    try testing.expectError(error.Overflow, Duration.parse("1ns18446744073709551615ns"));
    const bad = [_][]const u8{ "00", "1h 30m", " 1s", "1s ", "1S", "-1s", "1e3s", "1hh", "1sm" };
    for (bad) |text| try testing.expectError(error.InvalidCharacter, Duration.parse(text));
}

test "Duration.format round-trips through parse" {
    const values = [_]u64{ 1, 999, std.time.ns_per_day + 1, std.math.maxInt(u64) };
    for (values) |ns| {
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.print("{f}", .{Duration{ .ns = ns }});
        try testing.expectEqual(ns, (try Duration.parse(writer.buffered())).ns);
    }
}

test "ByteSize.parse decimal fractions and limits" {
    try testing.expectEqual(1500, (try ByteSize.parse("1.5KB")).bytes);
    try testing.expectEqual(1, (try ByteSize.parse("0.001kb")).bytes);
    try testing.expectEqual(1000, (try ByteSize.parse("1.0009KB")).bytes); // Truncated.
    try testing.expectEqual(512, (try ByteSize.parse(".5KiB")).bytes);
    try testing.expectEqual(1, (try ByteSize.parse("1.5")).bytes);
    try testing.expectEqual(2_500_000, (try ByteSize.parse("2.5MB")).bytes);
    try testing.expectEqual(1 << 50, (try ByteSize.parse("1p")).bytes);
    try testing.expectEqual(1_000_000_000_000_000, (try ByteSize.parse("1PB")).bytes);
    try testing.expectEqual(5, (try ByteSize.parse("5 b ")).bytes);
    const max = std.math.maxInt(u64);
    try testing.expectEqual(max, (try ByteSize.parse("18446744073709551615")).bytes);
    try testing.expectError(error.Overflow, ByteSize.parse("18446744073709551616"));
    try testing.expectError(error.Overflow, ByteSize.parse("16384PiB"));
    try testing.expectError(error.Overflow, ByteSize.parse("18446744073709551615.5KB"));
    const bad = [_][]const u8{ "1.", ".", "-1KB", "1KBB", "1 K B", "0x10", "1e3" };
    for (bad) |text| try testing.expectError(error.InvalidCharacter, ByteSize.parse(text));
}

test "ByteSize.format round-trips through parse" {
    const values = [_]u64{ 1, 1023, 1024, 1536, 1000, 1 << 50, std.math.maxInt(u64) };
    for (values) |bytes| {
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.print("{f}", .{ByteSize{ .bytes = bytes }});
        try testing.expectEqual(bytes, (try ByteSize.parse(writer.buffered())).bytes);
    }
}

test "infer edge cases" {
    try testing.expectEqual(Value{ .int = 5 }, infer("+5"));
    try testing.expectEqual(Value{ .int = 0 }, infer("-0"));
    try testing.expectEqual(Value{ .int = std.math.minInt(i64) }, infer("-9223372036854775808"));
    // Too big for an i64 and not written as a decimal: kept as text, losing nothing.
    try testing.expectEqualStrings("9223372036854775808", infer("9223372036854775808").string);
    try testing.expectEqual(Value{ .float = 0.5 }, infer(".5"));
    try testing.expectEqual(Value{ .float = -1e-3 }, infer("-1e-3"));
    try testing.expectEqual(Value{ .float = 1e3 }, infer("1E+3"));
    const strings = [_][]const u8{
        "-",   "+", ".", "1e", "e3", "1.2e", " 1", "1 ", "1-2", "TRUE", "Null", "0b1", "1.5.",
        "--1",
    };
    for (strings) |text| try testing.expectEqualStrings(text, infer(text).string);
}
