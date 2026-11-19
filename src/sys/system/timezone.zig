//! The local time zone: its offset from UTC and its abbreviation at any instant, as the C
//! library's `localtime` finds them.
//!
//! ```zig
//! const zone = timezone.local(arena, io, environ.get("TZ"));
//! const here = zone.at(seconds_since_epoch); // here.seconds east of UTC, here.name.slice()
//! ```
//!
//! Where the zone comes from, as glibc and Go look: `TZ` when set (`""` is UTC) — a POSIX
//! rule (`CET-1CEST,M3.5.0,M10.5.0/3`) or a zone name (`Europe/Berlin`, `:Europe/Berlin`,
//! or an absolute path) read from the zoneinfo directory; else `/etc/localtime`; on
//! Windows, without `TZ`, the system's zone (`GetDynamicTimeZoneInformation`). A zoneinfo
//! file is TZif, versions 1 to 3, its footer rule covering times after its last
//! transition. Anything missing or malformed falls back to UTC: a clock is never worth
//! failing a program over.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// A zone abbreviation (`CET`, `EDT`, `+0530`), kept by value.
pub const Name = struct {
    bytes: [15]u8 = undefined,
    len: u8 = 0,

    pub fn init(text: []const u8) Name {
        var name: Name = .{};
        name.len = @intCast(@min(text.len, name.bytes.len));
        @memcpy(name.bytes[0..name.len], text[0..name.len]);
        return name;
    }

    pub fn slice(name: *const Name) []const u8 {
        return name.bytes[0..name.len];
    }

    /// The name tzdb gives a zone without an abbreviation: `+01`, `+0530`, `-03`.
    pub fn numeric(offset: i32) Name {
        var buffer: [8]u8 = undefined;
        const minutes = @divTrunc(@abs(offset), 60);
        const sign: u8 = if (offset < 0) '-' else '+';
        const text = if (minutes % 60 == 0)
            std.fmt.bufPrint(&buffer, "{c}{d:0>2}", .{ sign, minutes / 60 }) catch unreachable
        else
            std.fmt.bufPrint(&buffer, "{c}{d:0>2}{d:0>2}", .{ sign, minutes / 60, minutes % 60 }) catch
                unreachable;
        return .init(text);
    }
};

/// Local time at one instant.
pub const Offset = struct {
    /// Seconds east of UTC: 3600 for CET.
    seconds: i32 = 0,
    name: Name = .init("UTC"),
    dst: bool = false,

    pub const utc: Offset = .{};
};

/// The local time zone's rules.
pub const Zone = union(enum) {
    utc,
    rule: Rule,
    tzif: Tzif,
    /// The system's zone on Windows.
    windows: windows.DynamicInfo,

    /// The offset and abbreviation at `seconds` since the Unix epoch.
    pub fn at(zone: *const Zone, seconds: i64) Offset {
        return switch (zone.*) {
            .utc => .utc,
            .rule => |*rule| rule.at(seconds),
            .tzif => |*tzif| tzif.at(seconds),
            .windows => |*info| windows.at(info, seconds),
        };
    }
};

/// The local zone, by `tz` (the `TZ` variable, or null when unset); UTC when it cannot be
/// found or read. A zoneinfo file is read with `io`, and the zone's tables allocated in
/// `arena`, which owns them.
pub fn local(arena: std.mem.Allocator, io: Io, tz: ?[]const u8) Zone {
    if (tz) |value| {
        if (value.len == 0) return .utc;
        if (value[0] != ':') if (Rule.parse(value)) |rule| return .{ .rule = rule } else |_| {};
        const name = if (value[0] == ':') value[1..] else value;
        return loadNamed(arena, io, name) orelse .utc;
    }
    if (builtin.os.tag == .windows) return windows.system() orelse .utc;
    return load(arena, io, "/etc/localtime") orelse .utc;
}

const zoneinfo_dirs = [_][]const u8{ "/usr/share/zoneinfo/", "/usr/share/lib/zoneinfo/" };

fn loadNamed(arena: std.mem.Allocator, io: Io, name: []const u8) ?Zone {
    if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) return null;
    if (std.fs.path.isAbsolute(name)) return load(arena, io, name);
    for (zoneinfo_dirs) |dir| {
        const path = std.mem.concat(arena, u8, &.{ dir, name }) catch return null;
        if (load(arena, io, path)) |zone| return zone;
    }
    return null;
}

fn load(arena: std.mem.Allocator, io: Io, path: []const u8) ?Zone {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    return .{ .tzif = Tzif.parse(arena, bytes) catch return null };
}

// -- POSIX rules ----------------------------------------------------------------------

/// A POSIX `TZ` rule: `std offset [dst [offset] [,start[/time],end[/time]]]`, offsets
/// west of UTC as written (`EST5EDT`), with tzcode's extensions (`<+0330>` names, hours
/// up to 167 and negative in times).
pub const Rule = struct {
    /// Seconds east of UTC.
    std_offset: i32,
    std_name: Name,
    dst: ?Dst = null,

    pub const Dst = struct {
        /// Seconds east of UTC.
        offset: i32,
        name: Name,
        /// When daylight time starts, in local standard time.
        start: Date,
        start_time: i32 = 2 * 3600,
        /// When it ends, in local daylight time.
        end: Date,
        end_time: i32 = 2 * 3600,
    };

    pub const Date = union(enum) {
        /// `Jn`: day 1 to 365, February 29 never counted.
        julian: u16,
        /// `n`: day 0 to 365, counting February 29.
        day: u16,
        /// `Mm.w.d`: weekday `d` (0 Sunday) of week `w` (1 to 5, 5 the last) of month `m`.
        month: struct { month: u8, week: u8, weekday: u8 },
    };

    pub const ParseError = error{InvalidRule};

    pub fn parse(text: []const u8) ParseError!Rule {
        var p: Parser = .{ .text = text };
        var rule: Rule = .{ .std_name = try p.name(), .std_offset = -try p.time(25 * 3600) };
        if (p.done()) return rule;
        const dst_name = try p.name();
        const dst_offset = if (p.done() or p.peek() == ',') rule.std_offset + 3600 else -try p.time(25 * 3600);
        // Without dates, the US rule, as glibc and Go assume.
        var dst: Dst = .{
            .offset = dst_offset,
            .name = dst_name,
            .start = .{ .month = .{ .month = 3, .week = 2, .weekday = 0 } },
            .end = .{ .month = .{ .month = 11, .week = 1, .weekday = 0 } },
        };
        if (!p.done()) {
            try p.expect(',');
            dst.start = try p.date();
            if (p.peek() == '/') dst.start_time = try p.signedTime();
            try p.expect(',');
            dst.end = try p.date();
            if (p.peek() == '/') dst.end_time = try p.signedTime();
            if (!p.done()) return error.InvalidRule;
        }
        rule.dst = dst;
        return rule;
    }

    pub fn at(rule: *const Rule, seconds: i64) Offset {
        const standard: Offset = .{ .seconds = rule.std_offset, .name = rule.std_name };
        const dst = rule.dst orelse return standard;
        const daylight: Offset = .{ .seconds = dst.offset, .name = dst.name, .dst = true };
        const days = @divFloor(seconds, std.time.s_per_day);
        const year = civilYear(days);
        const into_year = seconds - daysFromCivil(year, 1, 1) * std.time.s_per_day;
        // Each transition in UTC seconds into the year, as Go's tzset computes them.
        const start = dayOfYear(year, dst.start) * std.time.s_per_day + dst.start_time - rule.std_offset;
        const end = dayOfYear(year, dst.end) * std.time.s_per_day + dst.end_time - dst.offset;
        // In the south, daylight time spans the new year: standard time is between.
        if (end < start) return if (into_year >= end and into_year < start) standard else daylight;
        return if (into_year >= start and into_year < end) daylight else standard;
    }
};

const Parser = struct {
    text: []const u8,
    i: usize = 0,

    fn done(p: *const Parser) bool {
        return p.i == p.text.len;
    }

    fn peek(p: *const Parser) u8 {
        return if (p.done()) 0 else p.text[p.i];
    }

    fn expect(p: *Parser, c: u8) Rule.ParseError!void {
        if (p.peek() != c) return error.InvalidRule;
        p.i += 1;
    }

    /// `CET`, or `<+0330>` quoted; three characters at least.
    fn name(p: *Parser) Rule.ParseError!Name {
        const start = p.i;
        if (p.peek() == '<') {
            const close = std.mem.indexOfScalarPos(u8, p.text, p.i, '>') orelse return error.InvalidRule;
            p.i = close + 1;
            if (close - start - 1 < 3) return error.InvalidRule;
            return .init(p.text[start + 1 .. close]);
        }
        while (std.ascii.isAlphabetic(p.peek())) p.i += 1;
        if (p.i - start < 3) return error.InvalidRule;
        return .init(p.text[start..p.i]);
    }

    fn number(p: *Parser, max: u32) Rule.ParseError!u32 {
        const start = p.i;
        while (std.ascii.isDigit(p.peek())) p.i += 1;
        const n = std.fmt.parseInt(u32, p.text[start..p.i], 10) catch return error.InvalidRule;
        if (n > max) return error.InvalidRule;
        return n;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds, hours at most `max_hours`.
    fn time(p: *Parser, comptime max: u32) Rule.ParseError!i32 {
        var sign: i32 = 1;
        if (p.peek() == '+' or p.peek() == '-') {
            if (p.peek() == '-') sign = -1;
            p.i += 1;
        }
        var seconds = try p.number(max / 3600) * 3600;
        if (p.peek() == ':') {
            p.i += 1;
            seconds += try p.number(59) * 60;
            if (p.peek() == ':') {
                p.i += 1;
                seconds += try p.number(59);
            }
        }
        return sign * @as(i32, @intCast(seconds));
    }

    /// `/time` after a date: hours from -167 to 167.
    fn signedTime(p: *Parser) Rule.ParseError!i32 {
        try p.expect('/');
        return p.time(167 * 3600);
    }

    fn date(p: *Parser) Rule.ParseError!Rule.Date {
        switch (p.peek()) {
            'J' => {
                p.i += 1;
                const n = try p.number(365);
                if (n == 0) return error.InvalidRule;
                return .{ .julian = @intCast(n) };
            },
            'M' => {
                p.i += 1;
                const month = try p.number(12);
                try p.expect('.');
                const week = try p.number(5);
                try p.expect('.');
                const weekday = try p.number(6);
                if (month == 0 or week == 0) return error.InvalidRule;
                return .{ .month = .{
                    .month = @intCast(month),
                    .week = @intCast(week),
                    .weekday = @intCast(weekday),
                } };
            },
            else => return .{ .day = @intCast(try p.number(365)) },
        }
    }
};

/// The day of `year` (0 for January 1) that `date` names.
fn dayOfYear(year: i64, date: Rule.Date) i64 {
    switch (date) {
        .julian => |n| return n - 1 + @intFromBool(isLeap(year) and n >= 60),
        .day => |n| return n,
        .month => |m| {
            const first = daysFromCivil(year, m.month, 1);
            const length = daysInMonth(year, m.month);
            var day = @mod(@as(i64, m.weekday) - @mod(first + 4, 7), 7); // 1970-01-01: Thursday
            var week: u8 = 1;
            while (week < m.week and day + 7 < length) : (week += 1) day += 7;
            return first - daysFromCivil(year, 1, 1) + day;
        },
    }
}

fn isLeap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) i64 {
    if (month == 12) return 31;
    return daysFromCivil(year, month + 1, 1) - daysFromCivil(year, month, 1);
}

/// Days from 1970-01-01 to the date (Howard Hinnant's `days_from_civil`).
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// The year of the day `days` after 1970-01-01 (Hinnant's `civil_from_days`).
fn civilYear(days: i64) i64 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    return yoe + era * 400 + @intFromBool(mp >= 10);
}

// -- TZif -------------------------------------------------------------------------------

/// A zoneinfo file (RFC 8536): its transitions, the local time types they switch to, and
/// the footer rule for times after the last.
pub const Tzif = struct {
    transitions: []const i64,
    /// For each transition, its index into `types`.
    indexes: []const u8,
    types: []const Type,
    footer: ?Rule,

    pub const Type = struct { offset: i32, dst: bool, name: Name };

    pub const ParseError = error{ InvalidTzif, OutOfMemory };

    pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ParseError!Tzif {
        var r: Reader = .{ .bytes = bytes };
        const v1 = try r.header();
        if (v1.version == 0) return r.data(arena, v1, 4, null);
        // Version 2 and later: skip the 32-bit data for the 64-bit copy and the footer.
        try r.skip(v1.size(4));
        const v2 = try r.header();
        try r.skip(v2.size(8));
        const footer_start = r.i;
        r.i = footer_start - v2.size(8);
        var footer: ?Rule = null;
        if (footer_start < bytes.len and bytes[footer_start] == '\n') {
            const end = std.mem.indexOfScalarPos(u8, bytes, footer_start + 1, '\n') orelse
                return error.InvalidTzif;
            footer = Rule.parse(bytes[footer_start + 1 .. end]) catch null;
        }
        return r.data(arena, v2, 8, footer);
    }

    pub fn at(tzif: *const Tzif, seconds: i64) Offset {
        const n = tzif.transitions.len;
        if (n == 0) {
            if (tzif.footer) |*rule| return rule.at(seconds);
            return tzif.offsetOf(0);
        }
        if (seconds < tzif.transitions[0]) return tzif.offsetOf(0);
        if (seconds >= tzif.transitions[n - 1]) {
            if (tzif.footer) |*rule| return rule.at(seconds);
        }
        // The last transition at or before `seconds`.
        var low: usize = 0;
        var high: usize = n;
        while (high - low > 1) {
            const mid = (low + high) / 2;
            if (tzif.transitions[mid] <= seconds) low = mid else high = mid;
        }
        return tzif.offsetOf(tzif.indexes[low]);
    }

    fn offsetOf(tzif: *const Tzif, index: usize) Offset {
        const t = tzif.types[index];
        return .{ .seconds = t.offset, .name = t.name, .dst = t.dst };
    }
};

const Counts = struct {
    version: u8,
    isut: u32,
    isstd: u32,
    leap: u32,
    time: u32,
    type: u32,
    char: u32,

    /// Bytes of the data after the header, with times of `time_size` bytes.
    fn size(c: Counts, time_size: usize) usize {
        return c.time * time_size + c.time + c.type * 6 + c.char + c.leap * (time_size + 4) +
            c.isstd + c.isut;
    }
};

const Reader = struct {
    bytes: []const u8,
    i: usize = 0,

    fn take(r: *Reader, n: usize) Tzif.ParseError![]const u8 {
        if (r.bytes.len - r.i < n) return error.InvalidTzif;
        defer r.i += n;
        return r.bytes[r.i..][0..n];
    }

    fn skip(r: *Reader, n: usize) Tzif.ParseError!void {
        _ = try r.take(n);
    }

    fn int(r: *Reader, comptime T: type) Tzif.ParseError!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn header(r: *Reader) Tzif.ParseError!Counts {
        if (!std.mem.eql(u8, try r.take(4), "TZif")) return error.InvalidTzif;
        const version = (try r.take(1))[0];
        if (version != 0 and (version < '2' or version > '9')) return error.InvalidTzif;
        try r.skip(15);
        const c: Counts = .{
            .version = version,
            .isut = try r.int(u32),
            .isstd = try r.int(u32),
            .leap = try r.int(u32),
            .time = try r.int(u32),
            .type = try r.int(u32),
            .char = try r.int(u32),
        };
        if (c.type == 0 or c.type > 256 or c.char == 0) return error.InvalidTzif;
        return c;
    }

    fn data(
        r: *Reader,
        arena: std.mem.Allocator,
        c: Counts,
        comptime time_size: usize,
        footer: ?Rule,
    ) Tzif.ParseError!Tzif {
        if (r.bytes.len - r.i < c.size(time_size)) return error.InvalidTzif;
        const transitions = try arena.alloc(i64, c.time);
        for (transitions) |*t| t.* = if (time_size == 4) try r.int(i32) else try r.int(i64);
        const indexes = try arena.dupe(u8, try r.take(c.time));
        for (indexes) |index| if (index >= c.type) return error.InvalidTzif;
        const raw_types = try r.take(c.type * 6);
        const chars = try r.take(c.char);
        const types = try arena.alloc(Tzif.Type, c.type);
        for (types, 0..) |*t, k| {
            const raw = raw_types[k * 6 ..][0..6];
            const at = raw[5];
            if (at >= chars.len) return error.InvalidTzif;
            const end = std.mem.indexOfScalarPos(u8, chars, at, 0) orelse chars.len;
            t.* = .{
                .offset = std.mem.readInt(i32, raw[0..4], .big),
                .dst = raw[4] != 0,
                .name = .init(chars[at..end]),
            };
        }
        return .{ .transitions = transitions, .indexes = indexes, .types = types, .footer = footer };
    }
};

// -- Windows ----------------------------------------------------------------------------

const windows = struct {
    const SystemTime = extern struct {
        year: u16,
        month: u16,
        day_of_week: u16,
        day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        milliseconds: u16,
    };

    /// `TIME_ZONE_INFORMATION`.
    const Info = extern struct {
        bias: i32,
        standard_name: [32]u16,
        standard_date: SystemTime,
        standard_bias: i32,
        daylight_name: [32]u16,
        daylight_date: SystemTime,
        daylight_bias: i32,
    };

    /// `DYNAMIC_TIME_ZONE_INFORMATION`.
    pub const DynamicInfo = extern struct {
        info: Info,
        key_name: [128]u16,
        dynamic_daylight_time_disabled: u8,
    };

    extern "kernel32" fn GetDynamicTimeZoneInformation(
        info: *DynamicInfo,
    ) callconv(.winapi) u32;
    extern "kernel32" fn GetTimeZoneInformationForYear(
        year: u16,
        dynamic: ?*const DynamicInfo,
        info: *Info,
    ) callconv(.winapi) i32;

    fn system() ?Zone {
        var info: DynamicInfo = undefined;
        if (GetDynamicTimeZoneInformation(&info) == 0xFFFF_FFFF) return null;
        return .{ .windows = info };
    }

    /// The year's rules for `dynamic`, as a POSIX rule, at `seconds`.
    fn at(dynamic: *const DynamicInfo, seconds: i64) Offset {
        const year = civilYear(@divFloor(seconds, std.time.s_per_day));
        var info: Info = dynamic.info;
        if (builtin.os.tag == .windows and year >= 1601 and year <= 30827) {
            _ = GetTimeZoneInformationForYear(@intCast(year), dynamic, &info);
        }
        return ruleOf(info).at(seconds);
    }

    /// Windows' rule as a POSIX one: biases are minutes west, and a date is a weekday of a
    /// week of a month (week 5 the last), or with a year, a day of that year.
    fn ruleOf(info: Info) Rule {
        const std_offset = -(info.bias + info.standard_bias) * 60;
        var rule: Rule = .{ .std_offset = std_offset, .std_name = .numeric(std_offset) };
        if (info.daylight_date.month == 0) return rule;
        const dst_offset = -(info.bias + info.daylight_bias) * 60;
        rule.dst = .{
            .offset = dst_offset,
            .name = .numeric(dst_offset),
            .start = dateOf(info.daylight_date),
            .start_time = timeOf(info.daylight_date),
            .end = dateOf(info.standard_date),
            .end_time = timeOf(info.standard_date),
        };
        return rule;
    }

    fn dateOf(t: SystemTime) Rule.Date {
        const month: u8 = @intCast(@min(t.month, 12));
        if (t.year == 0) return .{ .month = .{
            .month = month,
            .week = @intCast(@min(@max(t.day, 1), 5)),
            .weekday = @intCast(@min(t.day_of_week, 6)),
        } };
        const day = daysFromCivil(t.year, month, @intCast(@min(t.day, 31))) - daysFromCivil(t.year, 1, 1);
        return .{ .day = @intCast(day) };
    }

    fn timeOf(t: SystemTime) i32 {
        return @as(i32, t.hour) * 3600 + @as(i32, t.minute) * 60 + t.second;
    }
};

// -- Tests ------------------------------------------------------------------------------

const testing = std.testing;

/// Seconds since the epoch of a UTC date and time.
fn utc(year: i64, month: u8, day: u8, hour: i64, minute: i64) i64 {
    return daysFromCivil(year, month, day) * std.time.s_per_day + hour * 3600 + minute * 60;
}

fn expectAt(zone: Zone, seconds: i64, offset: i32, name: []const u8) !void {
    const got = zone.at(seconds);
    try testing.expectEqualStrings(name, got.name.slice());
    try testing.expectEqual(offset, got.seconds);
}

test "civil dates" {
    try testing.expectEqual(0, daysFromCivil(1970, 1, 1));
    try testing.expectEqual(-1, daysFromCivil(1969, 12, 31));
    try testing.expectEqual(20374, daysFromCivil(2025, 10, 13));
    try testing.expectEqual(2024, civilYear(daysFromCivil(2024, 12, 31)));
    try testing.expectEqual(2025, civilYear(daysFromCivil(2025, 1, 1)));
    try testing.expectEqual(1969, civilYear(-1));
    try testing.expectEqual(29, daysInMonth(2024, 2));
    try testing.expectEqual(31, daysInMonth(2025, 12));
}

test "POSIX rules: Europe, around both changes" {
    const berlin: Zone = .{ .rule = try .parse("CET-1CEST,M3.5.0,M10.5.0/3") };
    // 2025: the last Sunday of March is the 30th, of October the 26th; both at 01:00 UTC.
    try expectAt(berlin, utc(2025, 1, 15, 12, 0), 3600, "CET");
    try expectAt(berlin, utc(2025, 3, 30, 0, 59), 3600, "CET");
    try expectAt(berlin, utc(2025, 3, 30, 1, 0), 7200, "CEST");
    try expectAt(berlin, utc(2025, 10, 26, 0, 59), 7200, "CEST");
    try expectAt(berlin, utc(2025, 10, 26, 1, 0), 3600, "CET");
    try testing.expect(berlin.at(utc(2025, 7, 1, 0, 0)).dst);
}

test "POSIX rules: the US default, the south, Julian days, no daylight time" {
    // No dates: the second Sunday of March to the first of November, at 2:00 local.
    const new_york: Zone = .{ .rule = try .parse("EST5EDT") };
    try expectAt(new_york, utc(2025, 3, 9, 6, 59), -18000, "EST");
    try expectAt(new_york, utc(2025, 3, 9, 7, 0), -14400, "EDT");
    try expectAt(new_york, utc(2025, 11, 2, 5, 59), -14400, "EDT");
    try expectAt(new_york, utc(2025, 11, 2, 6, 0), -18000, "EST");
    // Sydney: daylight time from October to April, across the new year.
    const sydney: Zone = .{ .rule = try .parse("AEST-10AEDT,M10.1.0,M4.1.0/3") };
    try expectAt(sydney, utc(2025, 1, 1, 0, 0), 39600, "AEDT");
    try expectAt(sydney, utc(2025, 4, 5, 15, 59), 39600, "AEDT");
    try expectAt(sydney, utc(2025, 4, 5, 16, 0), 36000, "AEST");
    try expectAt(sydney, utc(2025, 10, 4, 15, 59), 36000, "AEST");
    try expectAt(sydney, utc(2025, 10, 4, 16, 0), 39600, "AEDT");
    // J60 is March 1 even in a leap year; 59 (zero-based) is February 29 there.
    const julian: Zone = .{ .rule = try .parse("AAA0BBB,J60/0,300/0") };
    try expectAt(julian, utc(2024, 2, 29, 23, 59), 0, "AAA");
    try expectAt(julian, utc(2024, 3, 1, 0, 0), 3600, "BBB");
    try expectAt(julian, utc(2024, 10, 26, 22, 59), 3600, "BBB");
    try expectAt(julian, utc(2024, 10, 26, 23, 0), 0, "AAA");
    const tehran: Zone = .{ .rule = try .parse("<+0330>-3:30") };
    try expectAt(tehran, utc(2025, 6, 1, 0, 0), 12600, "+0330");
    // Times past 24 hours and below zero (tzcode's extension).
    const late: Zone = .{ .rule = try .parse("XXX3YYY,M3.2.0/-1,M11.1.0/26") };
    try expectAt(late, utc(2025, 3, 9, 1, 59), -10800, "XXX");
    try expectAt(late, utc(2025, 3, 9, 2, 0), -7200, "YYY");
    for ([_][]const u8{ "", "CE", "CET", "CET-1CEST,M3.5", "CET-1CEST,M13.1.0,M1.1.0", "UTC0x" }) |bad| {
        try testing.expectError(error.InvalidRule, Rule.parse(bad));
    }
}

/// A TZif file of `version` (0 or '2'/'3'): the transitions, each to a type, the types, and
/// the footer rule.
fn tzifBytes(
    arena: std.mem.Allocator,
    version: u8,
    transitions: []const i64,
    indexes: []const u8,
    types: []const Tzif.Type,
    footer: []const u8,
) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var chars: Io.Writer.Allocating = .init(arena);
    for (types) |t| try chars.writer.print("{s}\x00", .{t.name.slice()});
    const blocks: []const usize = if (version == 0) &.{4} else &.{ 4, 8 };
    for (blocks) |size| {
        try w.writeAll("TZif");
        try w.writeByte(version);
        try w.splatByteAll(0, 15);
        for ([_]usize{ 0, 0, 0, transitions.len, types.len, chars.written().len }) |n| {
            try w.writeInt(u32, @intCast(n), .big);
        }
        for (transitions) |t| {
            if (size == 4) try w.writeInt(i32, @intCast(t), .big) else try w.writeInt(i64, t, .big);
        }
        try w.writeAll(indexes);
        var at: u8 = 0;
        for (types) |t| {
            try w.writeInt(i32, t.offset, .big);
            try w.writeByte(@intFromBool(t.dst));
            try w.writeByte(at);
            at += t.name.len + 1;
        }
        try w.writeAll(chars.written());
    }
    if (version != 0) try w.print("\n{s}\n", .{footer});
    return out.written();
}

const cet: Tzif.Type = .{ .offset = 3600, .dst = false, .name = .init("CET") };
const cest: Tzif.Type = .{ .offset = 7200, .dst = true, .name = .init("CEST") };
const lmt: Tzif.Type = .{ .offset = 3208, .dst = false, .name = .init("LMT") };

test "TZif: Europe/Berlin, transitions then the footer rule" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // From local mean time to CET (moved to 1938 to fit 32 bits), then 2020's changes.
    const bytes = try tzifBytes(a, '2', &.{
        -1_000_000_000, utc(2020, 3, 29, 1, 0), utc(2020, 10, 25, 1, 0),
    }, &.{ 1, 2, 1 }, &.{ lmt, cet, cest }, "CET-1CEST,M3.5.0,M10.5.0/3");
    const zone: Zone = .{ .tzif = try .parse(a, bytes) };
    try expectAt(zone, -1_000_000_001, 3208, "LMT");
    try expectAt(zone, utc(1950, 1, 1, 0, 0), 3600, "CET");
    try expectAt(zone, utc(2020, 7, 1, 0, 0), 7200, "CEST");
    try expectAt(zone, utc(2020, 12, 1, 0, 0), 3600, "CET");
    // Past the last transition, the footer: 2025's changes.
    try expectAt(zone, utc(2025, 3, 30, 0, 59), 3600, "CET");
    try expectAt(zone, utc(2025, 3, 30, 1, 0), 7200, "CEST");
    try expectAt(zone, utc(2025, 10, 26, 1, 0), 3600, "CET");
}

test "TZif: America/New_York in version 1 and 3, and malformed files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const est: Tzif.Type = .{ .offset = -18000, .dst = false, .name = .init("EST") };
    const edt: Tzif.Type = .{ .offset = -14400, .dst = true, .name = .init("EDT") };
    const transitions = [_]i64{ utc(2025, 3, 9, 7, 0), utc(2025, 11, 2, 6, 0) };
    const v1 = try tzifBytes(a, 0, &transitions, &.{ 1, 0 }, &.{ est, edt }, "");
    const zone1: Zone = .{ .tzif = try .parse(a, v1) };
    try expectAt(zone1, utc(2025, 3, 9, 6, 59), -18000, "EST");
    try expectAt(zone1, utc(2025, 3, 9, 7, 0), -14400, "EDT");
    try expectAt(zone1, utc(2026, 7, 1, 0, 0), -18000, "EST"); // no footer: the last type
    const v3 = try tzifBytes(a, '3', &transitions, &.{ 1, 0 }, &.{ est, edt }, "EST5EDT,M3.2.0,M11.1.0");
    const zone3: Zone = .{ .tzif = try .parse(a, v3) };
    try expectAt(zone3, utc(2026, 7, 1, 0, 0), -14400, "EDT");
    try expectAt(zone3, utc(2026, 3, 8, 7, 0), -14400, "EDT");
    try expectAt(zone3, utc(2026, 3, 8, 6, 59), -18000, "EST");
    try testing.expectError(error.InvalidTzif, Tzif.parse(a, v3[0 .. v3.len / 2]));
    try testing.expectError(error.InvalidTzif, Tzif.parse(a, "TZif"));
    try testing.expectError(error.InvalidTzif, Tzif.parse(a, "nope"));
    var bad_index = try a.dupe(u8, v1);
    bad_index[44 + 2 * 4] = 7; // the first transition's type
    try testing.expectError(error.InvalidTzif, Tzif.parse(a, bad_index));
}

test "local: TZ as a rule, empty, or a name not found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectAt(local(a, testing.io, "JST-9"), 0, 32400, "JST");
    try expectAt(local(a, testing.io, ""), 0, 0, "UTC");
    try expectAt(local(a, testing.io, ":Termancy/No_Such_Zone"), 0, 0, "UTC");
    try expectAt(local(a, testing.io, "../../etc/passwd"), 0, 0, "UTC");
}

test "Windows rules, as POSIX ones" {
    const none: windows.SystemTime = std.mem.zeroes(windows.SystemTime);
    var info: windows.Info = std.mem.zeroes(windows.Info);
    info.bias = -60;
    info.daylight_bias = -60;
    info.daylight_date = none;
    info.daylight_date.month = 3;
    info.daylight_date.day = 5;
    info.daylight_date.hour = 2;
    info.standard_date = none;
    info.standard_date.month = 10;
    info.standard_date.day = 5;
    info.standard_date.hour = 3;
    const zone: Zone = .{ .rule = windows.ruleOf(info) };
    try expectAt(zone, utc(2025, 3, 30, 0, 59), 3600, "+01");
    try expectAt(zone, utc(2025, 3, 30, 1, 0), 7200, "+02");
    try expectAt(zone, utc(2025, 10, 26, 1, 0), 3600, "+01");
    info.daylight_date.month = 0;
    info.bias = -330;
    try expectAt(.{ .rule = windows.ruleOf(info) }, 0, 19800, "+0530");
}
