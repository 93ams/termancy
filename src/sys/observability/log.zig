//! Leveled logging, as charm's log does it: human text (plain, or charm's colored
//! badges, restyled with `Styles`), JSON lines, or logfmt; structured fields, fields every
//! record carries (`with`), a prefix, the caller's file and line (`logAt`), time formats
//! (Go's named layouts among them), a fatal level, records with no level (`none`, as
//! charm's `Print`), redaction by key, and scrubbing of known secret values wherever they
//! appear.
//!
//! ```zig
//! var logger: log.Logger = .{ .writer = stderr, .level = try log.parseLevel("debug") };
//! logger.info("listening", .{ .port = 8080, .token = "abc" });
//! // 2026-10-12T10:00:00Z INFO listening port=8080 token=[REDACTED]
//! ```
//!
//! A `Logger` is a value, not a global: two can coexist (JSON to a file, text to the
//! terminal), and a test asserts exact bytes. Time comes from `Clock`, which is either an
//! `Io`, a fixed instant (for tests), or nothing. Colour is off unless the caller turns it on;
//! deciding whether the terminal supports it is the caller's job.
//!
//! `std.log` reaches a `Logger` through `stdLogFn`, installed in `std_options`. A `Logger`
//! does no locking; a logger shared between threads needs the caller's lock around it.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const timezone = @import("../system/timezone.zig");

/// Severity, least severe first, so filtering is one comparison.
pub const Level = enum(u3) {
    trace,
    debug,
    info,
    warn,
    err,
    /// Logged, then the process exits with status 1 (`Logger.fatal`).
    fatal,
    /// No level: the record carries none and is never filtered out, as charm's `Print`.
    none,

    /// The upper-case label used in text output: `INFO`, `ERROR`, ...
    pub fn label(level: Level) []const u8 {
        return switch (level) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
            .none => "",
        };
    }

    /// The four-letter label of charm's style: `INFO`, `WARN`, `ERRO`, `DEBU`, `FATA`.
    pub fn short(level: Level) []const u8 {
        return switch (level) {
            .trace => "TRAC",
            .debug => "DEBU",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERRO",
            .fatal => "FATA",
            .none => "",
        };
    }

    /// charm's color for the level, of the 256: debug purple, info teal, warn yellow,
    /// error pink, fatal magenta (and trace gray; `none` has no badge to color).
    pub fn charmColor(level: Level) u8 {
        return switch (level) {
            .trace => 245,
            .debug => 63,
            .info => 86,
            .warn => 192,
            .err => 204,
            .fatal => 134,
            .none => 0,
        };
    }

    /// The lower-case name used in JSON output: `info`, `error`, ...
    pub fn name(level: Level) []const u8 {
        return if (level == .err) "error" else @tagName(level);
    }

    /// The level `std.log` calls the same thing.
    pub fn fromStd(level: std.log.Level) Level {
        return switch (level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
    }

    /// The `parse` convention shared with `cli` and `cfg`; see `parseLevel`.
    pub fn parse(text: []const u8) ParseError!Level {
        return parseLevel(text);
    }
};

/// Returned by `parseLevel`.
pub const ParseError = error{InvalidLevel};

/// Reads a level name, ignoring case: `trace`, `debug`, `info`, `warn`/`warning`,
/// `err`/`error`.
pub fn parseLevel(text: []const u8) ParseError!Level {
    const names = [_]struct { []const u8, Level }{
        .{ "trace", .trace }, .{ "debug", .debug },  .{ "info", .info },
        .{ "warn", .warn },   .{ "warning", .warn }, .{ "err", .err },
        .{ "error", .err },   .{ "fatal", .fatal },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
    }
    return error.InvalidLevel;
}

/// How records are rendered.
pub const Format = enum {
    /// `2026-10-12T10:00:00Z INFO message key=value`
    text,
    /// `{"time":"2026-10-12T10:00:00Z","level":"info","msg":"message","key":"value"}`
    json,
    /// `time=2026-10-12T10:00:00Z level=info msg=message key=value`
    logfmt,
};

/// How text records look when `color` is on.
pub const Style = enum {
    /// Only the level label is colored.
    plain,
    /// charm's log: a four-letter level in its color, the prefix bold, keys faint.
    charm,
};

/// How timestamps are written in text records (JSON and logfmt always use RFC 3339), in
/// the logger's `zone`: these, and the rest of Go's named layouts as gum's log names them
/// (`goLayout`).
pub const TimeFormat = enum {
    /// `2026-10-12T10:00:00Z`
    rfc3339,
    /// `2026/10/12 10:00:00`
    date_time,
    /// `10:00:00`
    time,
    /// `10:00AM`
    kitchen,
    layout,
    ansic,
    unixdate,
    rubydate,
    rfc822,
    rfc822z,
    rfc850,
    rfc1123,
    rfc1123z,
    rfc3339nano,
    stamp,
    stampmilli,
    stampmicro,
    stampnano,
    datetime,
    dateonly,
    timeonly,

    /// The format as Go spells it, with its reference time `Mon Jan 2 15:04:05 MST 2006`:
    /// for the Go names, the `time` package's constant (`ansic` is `time.ANSIC`).
    pub fn goLayout(format: TimeFormat) []const u8 {
        return switch (format) {
            .rfc3339 => "2006-01-02T15:04:05Z07:00",
            .date_time => "2006/01/02 15:04:05",
            .time, .timeonly => "15:04:05",
            .kitchen => "3:04PM",
            .layout => "01/02 03:04:05PM '06 -0700",
            .ansic => "Mon Jan _2 15:04:05 2006",
            .unixdate => "Mon Jan _2 15:04:05 MST 2006",
            .rubydate => "Mon Jan 02 15:04:05 -0700 2006",
            .rfc822 => "02 Jan 06 15:04 MST",
            .rfc822z => "02 Jan 06 15:04 -0700",
            .rfc850 => "Monday, 02-Jan-06 15:04:05 MST",
            .rfc1123 => "Mon, 02 Jan 2006 15:04:05 MST",
            .rfc1123z => "Mon, 02 Jan 2006 15:04:05 -0700",
            .rfc3339nano => "2006-01-02T15:04:05.999999999Z07:00",
            .stamp => "Jan _2 15:04:05",
            .stampmilli => "Jan _2 15:04:05.000",
            .stampmicro => "Jan _2 15:04:05.000000",
            .stampnano => "Jan _2 15:04:05.000000000",
            .datetime => "2006-01-02 15:04:05",
            .dateonly => "2006-01-02",
        };
    }
};

/// How each part of a text record looks in charm's style (`style = .charm`, `color` on), as
/// charm's `Styles`: the SGR sequence starting it (`"\x1b[1m"`), empty for none. The
/// defaults are charm's look.
pub const Styles = struct {
    time: []const u8 = "\x1b[2m",
    /// Empty for the level's own color, bold (`Level.charmColor`).
    level: []const u8 = "",
    /// charm's four letters (`ERRO`); false writes the whole name (`ERROR`), as gum's log.
    short_levels: bool = true,
    prefix: []const u8 = "\x1b[1m",
    message: []const u8 = "",
    key: []const u8 = "\x1b[2m",
    separator: []const u8 = "\x1b[2m",
    value: []const u8 = "",

    /// No sequences at all, and whole level names: text without charm's style.
    const none: Styles = .{
        .time = "",
        .short_levels = false,
        .prefix = "",
        .key = "",
        .separator = "",
    };
};

/// A field every record of a logger carries (`Logger.with`).
pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        boolean: bool,
    };
};

/// Where timestamps come from.
pub const Clock = union(enum) {
    /// No timestamp is written.
    none,
    /// The real-time clock of this `Io`.
    io: Io,
    /// Always this instant; for tests.
    fixed: Io.Timestamp,

    /// The current time, or null for `.none`.
    pub fn now(clock: Clock) ?Io.Timestamp {
        return switch (clock) {
            .none => null,
            .io => |io| Io.Clock.real.now(io),
            .fixed => |instant| instant,
        };
    }
};

/// Keys redacted by default. Matching ignores case and looks for the word anywhere in the
/// key, so `db_password` and `X-Auth-Token` are covered.
pub const default_redact: []const []const u8 = &.{ "password", "token", "secret", "authorization" };

/// Written in place of a redacted value.
pub const redacted = "[REDACTED]";

/// Field names the record itself uses; a field with one of these names is a compile error.
const reserved_keys = [_][]const u8{ "time", "level", "msg", "scope", "caller", "prefix" };

/// A destination plus its rendering choices. Fill the fields directly.
pub const Logger = struct {
    writer: *Io.Writer,
    /// Records below this level are dropped.
    level: Level = .info,
    format: Format = .text,
    /// ANSI colour on the level label (text format only).
    color: bool = false,
    clock: Clock = .none,
    /// Fields whose key contains one of these words (ignoring case) are redacted.
    redact: []const []const u8 = default_redact,
    /// Secret values (an API key, a password read from the environment, ...) replaced by
    /// `redacted` wherever they occur in the message or in a string field value, whatever
    /// the key. Matching is exact and case-sensitive; empty values are ignored. The caller
    /// keeps the slice alive. Nothing is allocated: text is written around the matches.
    secrets: []const []const u8 = &.{},
    /// Written as a `scope` field when not empty.
    scope: []const u8 = "",
    /// Flush the writer after every record, so a crash loses nothing.
    flush: bool = true,
    /// Written before the message as `prefix: ` (text) or a `prefix` field.
    prefix: []const u8 = "",
    /// Written after the message, before each record's own fields.
    fields: []const Field = &.{},
    /// The look of text records with `color` on.
    style: Style = .plain,
    /// The look of each part under `style = .charm`.
    styles: Styles = .{},
    time_format: TimeFormat = .rfc3339,
    /// The zone times are written in: `timezone.local(...)` for the local time.
    zone: timezone.Zone = .utc,

    fn offsetAt(logger: *const Logger, instant: Io.Timestamp) timezone.Offset {
        return logger.zone.at(@intCast(@divFloor(instant.toNanoseconds(), std.time.ns_per_s)));
    }

    /// Whether a record at `level` would be written.
    pub fn enabled(logger: *const Logger, level: Level) bool {
        return @backingInt(level) >= @backingInt(logger.level);
    }

    /// A copy whose records also carry `fields` (which the caller keeps alive), as charm's
    /// `With`. They replace any the logger had.
    pub fn with(logger: Logger, fields: []const Field) Logger {
        var copy = logger;
        copy.fields = fields;
        return copy;
    }

    /// A copy writing with `prefix`.
    pub fn withPrefix(logger: Logger, prefix: []const u8) Logger {
        var copy = logger;
        copy.prefix = prefix;
        return copy;
    }

    /// A copy writing under a different scope.
    pub fn scoped(logger: Logger, scope: []const u8) Logger {
        var copy = logger;
        copy.scope = scope;
        return copy;
    }

    /// Writes one record. `fields` is a struct or tuple-like struct literal: `.{ .id = 7 }`.
    pub fn log(
        logger: *const Logger,
        level: Level,
        message: []const u8,
        fields: anytype,
    ) Io.Writer.Error!void {
        return logger.logAt(null, level, message, fields);
    }

    /// `log`, with the caller's place (`@src()`) as a `caller` field, as charm's
    /// `ReportCaller`.
    pub fn logAt(
        logger: *const Logger,
        src: ?std.builtin.SourceLocation,
        level: Level,
        message: []const u8,
        fields: anytype,
    ) Io.Writer.Error!void {
        comptime checkFields(@TypeOf(fields));
        if (!logger.enabled(level)) return;
        const time = logger.clock.now();
        var caller_buffer: [256]u8 = undefined;
        const caller: []const u8 = if (src) |at|
            std.fmt.bufPrint(&caller_buffer, "{s}:{d}", .{
                std.fs.path.basename(at.file),
                at.line,
            }) catch ""
        else
            "";
        switch (logger.format) {
            .text => try logger.writeText(level, time, caller, message, fields),
            .json => try logger.writeJson(level, time, caller, message, fields),
            .logfmt => try logger.writeLogfmt(level, time, caller, message, fields),
        }
        if (logger.flush) try logger.writer.flush();
    }

    /// Logs at `fatal`, then ends the process with status 1.
    pub fn fatal(logger: *const Logger, message: []const u8, fields: anytype) noreturn {
        logger.log(.fatal, message, fields) catch {};
        logger.writer.flush() catch {};
        std.process.exit(1);
    }

    /// Logs at `trace`. Write errors are dropped: logging must not fail the program.
    pub fn trace(logger: *const Logger, message: []const u8, fields: anytype) void {
        logger.log(.trace, message, fields) catch {};
    }

    /// Logs at `debug`, dropping write errors.
    pub fn debug(logger: *const Logger, message: []const u8, fields: anytype) void {
        logger.log(.debug, message, fields) catch {};
    }

    /// Logs at `info`, dropping write errors.
    pub fn info(logger: *const Logger, message: []const u8, fields: anytype) void {
        logger.log(.info, message, fields) catch {};
    }

    /// Logs at `warn`, dropping write errors.
    pub fn warn(logger: *const Logger, message: []const u8, fields: anytype) void {
        logger.log(.warn, message, fields) catch {};
    }

    /// Logs at `err`, dropping write errors.
    pub fn err(logger: *const Logger, message: []const u8, fields: anytype) void {
        logger.log(.err, message, fields) catch {};
    }

    /// Whether a field named `key` is hidden.
    pub fn isRedacted(logger: *const Logger, key: []const u8) bool {
        for (logger.redact) |word| {
            if (containsIgnoreCase(key, word)) return true;
        }
        return false;
    }

    fn writeText(
        logger: *const Logger,
        level: Level,
        time: ?Io.Timestamp,
        caller: []const u8,
        message: []const u8,
        fields: anytype,
    ) Io.Writer.Error!void {
        const w = logger.writer;
        const charm = logger.color and logger.style == .charm;
        const st: Styles = if (charm) logger.styles else .none;
        if (time) |instant| {
            try w.writeAll(st.time);
            try writeTimeAs(w, instant, logger.time_format, logger.offsetAt(instant));
            try endStyle(w, st.time);
            try w.writeByte(' ');
        }
        if (level != .none) {
            const label = if (st.short_levels) level.short() else level.label();
            if (st.level.len > 0) {
                try w.print("{s}{s}\x1b[0m ", .{ st.level, label });
            } else if (charm) {
                try w.print("\x1b[1;38;5;{d}m{s}\x1b[0m ", .{ level.charmColor(), label });
            } else if (logger.color) {
                try w.print("\x1b[{s}m{s}\x1b[0m ", .{ levelColor(level), label });
            } else {
                try w.print("{s} ", .{label});
            }
        }
        if (caller.len > 0) {
            if (charm) try w.writeAll("\x1b[2m");
            try w.print("<{s}> ", .{caller});
            if (charm) try w.writeAll("\x1b[0m");
        }
        if (logger.prefix.len > 0) {
            try w.writeAll(st.prefix);
            try writeTextEscaped(w, logger.prefix, &.{});
            try w.writeByte(':');
            try endStyle(w, st.prefix);
            try w.writeByte(' ');
        }
        try w.writeAll(st.message);
        try writeTextEscaped(w, message, logger.secrets);
        try endStyle(w, st.message);
        if (logger.scope.len > 0) {
            try writeKey(w, "scope", st);
            try w.writeAll(st.value);
            try writeTextString(w, logger.scope, &.{});
            try endStyle(w, st.value);
        }
        for (logger.fields) |field| {
            try writeKey(w, field.key, st);
            try w.writeAll(st.value);
            if (logger.isRedacted(field.key))
                try w.writeAll(redacted)
            else
                try writeFieldValue(w, field.value, logger.secrets);
            try endStyle(w, st.value);
        }
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |key| {
            try writeKey(w, key, st);
            try w.writeAll(st.value);
            if (logger.isRedacted(key)) {
                try w.writeAll(redacted);
            } else {
                try writeTextValue(w, @field(fields, key), logger.secrets);
            }
            try endStyle(w, st.value);
        }
        try w.writeByte('\n');
    }

    /// ` key=`, the key and the `=` each in their style (one span when the same).
    fn writeKey(w: *Io.Writer, key: []const u8, st: Styles) Io.Writer.Error!void {
        try w.print(" {s}{s}", .{ st.key, key });
        if (!std.mem.eql(u8, st.key, st.separator)) {
            try endStyle(w, st.key);
            try w.writeAll(st.separator);
        }
        try w.writeByte('=');
        try endStyle(w, st.separator);
    }

    fn writeLogfmt(
        logger: *const Logger,
        level: Level,
        time: ?Io.Timestamp,
        caller: []const u8,
        message: []const u8,
        fields: anytype,
    ) Io.Writer.Error!void {
        const w = logger.writer;
        if (time) |instant| {
            try w.writeAll("time=");
            try writeTimeAs(w, instant, .rfc3339, logger.offsetAt(instant));
            try w.writeByte(' ');
        }
        if (level != .none) try w.print("level={s} ", .{level.name()});
        if (caller.len > 0) {
            try w.writeAll("caller=");
            try writeTextString(w, caller, &.{});
            try w.writeByte(' ');
        }
        if (logger.prefix.len > 0) {
            try w.writeAll("prefix=");
            try writeTextString(w, logger.prefix, &.{});
            try w.writeByte(' ');
        }
        try w.writeAll("msg=");
        try writeTextString(w, message, logger.secrets);
        if (logger.scope.len > 0) {
            try w.writeAll(" scope=");
            try writeTextString(w, logger.scope, &.{});
        }
        for (logger.fields) |field| {
            try w.print(" {s}=", .{field.key});
            if (logger.isRedacted(field.key))
                try w.writeAll(redacted)
            else
                try writeFieldValue(w, field.value, logger.secrets);
        }
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |key| {
            try w.print(" {s}=", .{key});
            if (logger.isRedacted(key)) {
                try w.writeAll(redacted);
            } else {
                try writeTextValue(w, @field(fields, key), logger.secrets);
            }
        }
        try w.writeByte('\n');
    }

    fn writeJson(
        logger: *const Logger,
        level: Level,
        time: ?Io.Timestamp,
        caller: []const u8,
        message: []const u8,
        fields: anytype,
    ) Io.Writer.Error!void {
        var json: std.json.Stringify = .{ .writer = logger.writer };
        try json.beginObject();
        if (time) |instant| {
            try json.objectField("time");
            try json.beginWriteRaw();
            try json.writer.writeByte('"');
            try writeTimeAs(json.writer, instant, .rfc3339, logger.offsetAt(instant));
            try json.writer.writeByte('"');
            json.endWriteRaw();
        }
        if (level != .none) {
            try json.objectField("level");
            try json.write(level.name());
        }
        if (caller.len > 0) {
            try json.objectField("caller");
            try json.write(caller);
        }
        if (logger.prefix.len > 0) {
            try json.objectField("prefix");
            try json.write(logger.prefix);
        }
        try json.objectField("msg");
        try writeJsonString(&json, message, logger.secrets);
        if (logger.scope.len > 0) {
            try json.objectField("scope");
            try json.write(logger.scope);
        }
        for (logger.fields) |field| {
            try json.objectField(field.key);
            if (logger.isRedacted(field.key)) {
                try json.write(redacted);
            } else switch (field.value) {
                .string => |text| try writeJsonString(&json, text, logger.secrets),
                inline else => |v| try json.write(v),
            }
        }
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |key| {
            try json.objectField(key);
            if (logger.isRedacted(key)) {
                try json.write(redacted);
            } else {
                try writeJsonValue(&json, @field(fields, key), logger.secrets);
            }
        }
        try json.endObject();
        try logger.writer.writeByte('\n');
    }
};

/// Ends a part written in `sgr`, if it had a style.
fn endStyle(w: *Io.Writer, sgr: []const u8) Io.Writer.Error!void {
    if (sgr.len > 0) try w.writeAll("\x1b[0m");
}

fn checkFields(comptime Fields: type) void {
    if (@typeInfo(Fields) != .@"struct") {
        @compileError("log fields must be a struct literal such as .{ .id = 7 }");
    }
    for (@typeInfo(Fields).@"struct".field_names) |field_name| {
        for (reserved_keys) |key| {
            if (std.mem.eql(u8, field_name, key)) {
                @compileError("log field name '" ++ key ++ "' is reserved");
            }
        }
    }
}

fn levelColor(level: Level) []const u8 {
    return switch (level) {
        .trace => "2",
        .debug => "36",
        .info => "32",
        .warn => "33",
        .err => "31;1",
        .fatal => "35;1",
        .none => "",
    };
}

fn writeFieldValue(
    w: *Io.Writer,
    value: Field.Value,
    secrets: []const []const u8,
) Io.Writer.Error!void {
    switch (value) {
        .string => |text| try writeTextString(w, text, secrets),
        .int => |n| try w.print("{d}", .{n}),
        .float => |x| try w.print("{d}", .{x}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
    }
}

/// Writes `instant` in `format`, at `offset` from UTC (`timezone.Offset.utc` for UTC).
pub fn writeTimeAs(
    w: *Io.Writer,
    instant: Io.Timestamp,
    format: TimeFormat,
    offset: timezone.Offset,
) Io.Writer.Error!void {
    return writeLayout(w, instant, format.goLayout(), offset);
}

/// The parts of Go's reference time that `TimeFormat.goLayout` uses, longest first where
/// one starts another (`Monday`, `Mon`).
const LayoutPart = enum {
    weekday,
    weekday_short,
    month_short,
    year,
    zone_colon,
    zone,
    zone_name,
    nanos,
    micros,
    millis,
    fraction,
    pm,
    month,
    day,
    day_space,
    hour12_zero,
    minute,
    second,
    year_short,
    hour,
    hour12,
};

const layout_parts = [_]struct { []const u8, LayoutPart }{
    .{ "Monday", .weekday }, .{ "Mon", .weekday_short },   .{ "Jan", .month_short },
    .{ "2006", .year },      .{ "Z07:00", .zone_colon },   .{ "-0700", .zone },
    .{ "MST", .zone_name },  .{ ".000000000", .nanos },    .{ ".000000", .micros },
    .{ ".000", .millis },    .{ ".999999999", .fraction }, .{ "PM", .pm },
    .{ "01", .month },       .{ "02", .day },              .{ "_2", .day_space },
    .{ "03", .hour12_zero }, .{ "04", .minute },           .{ "05", .second },
    .{ "06", .year_short },  .{ "15", .hour },             .{ "3", .hour12 },
};

const months = "JanFebMarAprMayJunJulAugSepOctNovDec";

const weekdays = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};

/// Writes `instant` at `offset` from UTC as Go's `layout` spells it: each of
/// `layout_parts` stands for that part of the local time, and anything else is written as
/// it is.
fn writeLayout(
    w: *Io.Writer,
    instant: Io.Timestamp,
    layout: []const u8,
    offset: timezone.Offset,
) Io.Writer.Error!void {
    const local = instant.toNanoseconds() + @as(i96, offset.seconds) * std.time.ns_per_s;
    const ns: u64 = @intCast(@max(0, local));
    const minutes = @divTrunc(@abs(offset.seconds), 60);
    const sign: u8 = if (offset.seconds < 0) '-' else '+';
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = ns / std.time.ns_per_s };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    const hour = day.getHoursIntoDay();
    const hour12 = if (hour % 12 == 0) 12 else hour % 12;
    const month: usize = month_day.month.numeric();
    const nanos = ns % std.time.ns_per_s;
    var i: usize = 0;
    next: while (i < layout.len) {
        for (layout_parts) |part| if (std.mem.startsWith(u8, layout[i..], part[0])) {
            i += part[0].len;
            switch (part[1]) {
                // 1970-01-01 was a Thursday.
                .weekday => try w.writeAll(weekdays[(epoch_day.day + 4) % 7]),
                .weekday_short => try w.writeAll(weekdays[(epoch_day.day + 4) % 7][0..3]),
                .month_short => try w.writeAll(months[3 * (month - 1) ..][0..3]),
                .year => try w.print("{d:0>4}", .{year_day.year}),
                .zone_colon => if (offset.seconds == 0) try w.writeByte('Z') else {
                    try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, minutes / 60, minutes % 60 });
                },
                .zone => try w.print("{c}{d:0>2}{d:0>2}", .{ sign, minutes / 60, minutes % 60 }),
                .zone_name => try w.writeAll(offset.name.slice()),
                .nanos => try w.print(".{d:0>9}", .{nanos}),
                .micros => try w.print(".{d:0>6}", .{nanos / std.time.ns_per_us}),
                .millis => try w.print(".{d:0>3}", .{nanos / std.time.ns_per_ms}),
                .fraction => if (nanos > 0) {
                    var digits: [9]u8 = undefined;
                    _ = std.fmt.bufPrint(&digits, "{d:0>9}", .{nanos}) catch unreachable;
                    try w.print(".{s}", .{std.mem.trimEnd(u8, &digits, "0")});
                },
                .pm => try w.writeAll(if (hour < 12) "AM" else "PM"),
                .month => try w.print("{d:0>2}", .{month}),
                .day => try w.print("{d:0>2}", .{month_day.day_index + 1}),
                .day_space => try w.print("{d: >2}", .{month_day.day_index + 1}),
                .hour12_zero => try w.print("{d:0>2}", .{hour12}),
                .minute => try w.print("{d:0>2}", .{day.getMinutesIntoHour()}),
                .second => try w.print("{d:0>2}", .{day.getSecondsIntoMinute()}),
                .year_short => try w.print("{d:0>2}", .{year_day.year % 100}),
                .hour => try w.print("{d:0>2}", .{hour}),
                .hour12 => try w.print("{d}", .{hour12}),
            }
            continue :next;
        };
        try w.writeByte(layout[i]);
        i += 1;
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Writes `instant` as RFC 3339 UTC with second precision: `2026-10-12T10:00:00Z`.
/// Instants before 1970 are written as the epoch.
pub fn writeTimestamp(w: *Io.Writer, instant: Io.Timestamp) Io.Writer.Error!void {
    const seconds: u64 = @intCast(@max(0, instant.toSeconds()));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn writeTextValue(
    w: *Io.Writer,
    value: anytype,
    secrets: []const []const u8,
) Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime isString(T)) return writeTextString(w, value, secrets);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int, .float, .comptime_float => try w.print("{d}", .{value}),
        .@"enum", .enum_literal => try w.writeAll(@tagName(value)),
        .error_set => try w.writeAll(@errorName(value)),
        .null => try w.writeAll("null"),
        .optional => if (value) |inner| {
            try writeTextValue(w, inner, secrets);
        } else try w.writeAll("null"),
        else => {
            var buffer: [max_any_len]u8 = undefined;
            try w.writeAll(anyText(&buffer, value, secrets));
        },
    }
}

/// The longest rendering of a composite field value (a struct, a list) that is written.
const max_any_len = 256;

/// `value` rendered by `writeAny`, cut at `buffer`'s size.
fn anyText(buffer: []u8, value: anytype, secrets: []const []const u8) []const u8 {
    var fixed: Io.Writer = .fixed(buffer);
    writeAny(&fixed, value, secrets) catch {}; // Cut at the buffer's size.
    return fixed.buffered();
}

/// `value` as `{any}` writes it, except that strings inside it are text (quoted, with Zig
/// escapes, so a record stays one line) with every secret value replaced, where `{any}`
/// would list their bytes; a type with a `format` method is written with it.
fn writeAny(w: *Io.Writer, value: anytype, secrets: []const []const u8) Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime isString(T)) {
        try w.writeByte('"');
        var scrubber: Scrubber = .{ .secrets = secrets, .text = value };
        while (scrubber.next()) |piece| {
            try std.zig.stringEscape(piece.clear, w);
            if (piece.hit) try w.writeAll(redacted);
        }
        return w.writeByte('"');
    }
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) {
            try w.writeAll("{");
            for (value, 0..) |item, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                try writeAny(w, item, secrets);
            }
            return w.writeAll(if (value.len == 0) "}" else " }");
        },
        .array => |a| return if (a.child == u8)
            writeAny(w, @as([]const u8, &value), secrets)
        else
            writeAny(w, @as([]const a.child, &value), secrets),
        .@"struct" => |info| {
            if (comptime std.meta.hasMethod(T, "format")) return w.print("{f}", .{value});
            try w.writeAll(".{");
            inline for (info.field_names, 0..) |name, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                if (!info.is_tuple) try w.print(".{s} = ", .{name});
                try writeAny(w, @field(value, name), secrets);
            }
            return w.writeAll(if (info.field_names.len == 0) "}" else " }");
        },
        .optional => return if (value) |inner| writeAny(w, inner, secrets) else w.writeAll("null"),
        else => {},
    }
    try w.print("{any}", .{value});
}

/// Splits text into runs of clear text, each followed by a secret value or the end, so a
/// writer can escape the clear runs and write `redacted` in place of each secret without
/// copying the text. At one position the longest secret wins.
const Scrubber = struct {
    secrets: []const []const u8,
    text: []const u8,
    pos: usize = 0,

    const Piece = struct {
        clear: []const u8,
        /// Whether a secret followed `clear` (and was skipped).
        hit: bool,
    };

    /// The next piece, or null once the text is used up.
    fn next(scrubber: *Scrubber) ?Piece {
        if (scrubber.pos >= scrubber.text.len) return null;
        const rest = scrubber.text[scrubber.pos..];
        var best: ?usize = null;
        var best_len: usize = 0;
        for (scrubber.secrets) |secret| {
            if (secret.len == 0) continue;
            const at = std.mem.indexOf(u8, rest, secret) orelse continue;
            if (best == null or at < best.? or (at == best.? and secret.len > best_len)) {
                best = at;
                best_len = secret.len;
            }
        }
        const at = best orelse {
            scrubber.pos = scrubber.text.len;
            return .{ .clear = rest, .hit = false };
        };
        scrubber.pos += at + best_len;
        return .{ .clear = rest[0..at], .hit = true };
    }
};

fn containsSecret(text: []const u8, secrets: []const []const u8) bool {
    for (secrets) |secret| {
        if (secret.len > 0 and std.mem.indexOf(u8, text, secret) != null) return true;
    }
    return false;
}

/// Bare when the text is a plain word, otherwise quoted with Zig escapes, so a line stays
/// one record and `key=value` pairs stay unambiguous. Secret values become `redacted`.
fn writeTextString(
    w: *Io.Writer,
    text: []const u8,
    secrets: []const []const u8,
) Io.Writer.Error!void {
    var plain = text.len > 0;
    var scrubber: Scrubber = .{ .secrets = secrets, .text = text };
    while (scrubber.next()) |piece| for (piece.clear) |c| {
        if (c <= ' ' or c == '"' or c == '=' or c == '\\' or c >= 0x7f) plain = false;
    };
    scrubber.pos = 0;
    if (!plain) try w.writeByte('"');
    while (scrubber.next()) |piece| {
        if (plain) try w.writeAll(piece.clear) else try std.zig.stringEscape(piece.clear, w);
        if (piece.hit) try w.writeAll(redacted);
    }
    if (!plain) try w.writeByte('"');
}

/// The message is free text: written as is, except that control characters are escaped so
/// a message can never forge a second record, and secret values become `redacted`.
fn writeTextEscaped(
    w: *Io.Writer,
    text: []const u8,
    secrets: []const []const u8,
) Io.Writer.Error!void {
    var scrubber: Scrubber = .{ .secrets = secrets, .text = text };
    while (scrubber.next()) |piece| {
        for (piece.clear) |c| switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
            else => try w.writeByte(c),
        };
        if (piece.hit) try w.writeAll(redacted);
    }
}

/// A JSON string value with every secret value replaced by `redacted`.
fn writeJsonString(
    json: *std.json.Stringify,
    text: []const u8,
    secrets: []const []const u8,
) Io.Writer.Error!void {
    if (!containsSecret(text, secrets)) return json.write(text);
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    var scrubber: Scrubber = .{ .secrets = secrets, .text = text };
    while (scrubber.next()) |piece| {
        try std.json.Stringify.encodeJsonStringChars(piece.clear, json.options, json.writer);
        if (piece.hit) try json.writer.writeAll(redacted);
    }
    try json.writer.writeByte('"');
    json.endWriteRaw();
}

fn writeJsonValue(
    json: *std.json.Stringify,
    value: anytype,
    secrets: []const []const u8,
) Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime isString(T)) return writeJsonString(json, value, secrets);
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .null => try json.write(value),
        .@"enum", .enum_literal => try json.write(@tagName(value)),
        .error_set => try json.write(@errorName(value)),
        .optional => if (value) |inner| {
            try writeJsonValue(json, inner, secrets);
        } else try json.write(null),
        else => {
            // Anything else is rendered as text (`writeAny`), which is always valid JSON
            // once quoted, rather than trusting `Stringify` with an arbitrary type.
            var buffer: [max_any_len]u8 = undefined;
            try json.write(anyText(&buffer, value, secrets));
        },
    }
}

/// The signature `std_options.logFn` takes.
pub const StdLogFn = fn (
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void;

/// The longest `std.log` message kept; longer ones end in `...`.
pub const std_message_max = 1024;

/// A `std.log` function routing through the logger `get` returns, or to
/// `std.log.defaultLog` while it returns null:
///
/// ```zig
/// var app_logger: ?*const log.Logger = null;
/// fn getLogger() ?*const log.Logger { return app_logger; }
/// pub const std_options: std.Options = .{ .logFn = log.stdLogFn(getLogger) };
/// ```
///
/// The message is formatted into a fixed buffer; the scope becomes the `scope` field.
pub fn stdLogFn(comptime get: fn () ?*const Logger) StdLogFn {
    return struct {
        fn logFn(
            comptime level: std.log.Level,
            comptime scope: @EnumLiteral(),
            comptime format: []const u8,
            args: anytype,
        ) void {
            const logger = get() orelse return std.log.defaultLog(level, scope, format, args);
            if (!logger.enabled(.fromStd(level))) return;
            var buffer: [std_message_max]u8 = undefined;
            const message = formatMessage(&buffer, format, args);
            var target = logger.*;
            if (scope != .default) target.scope = @tagName(scope);
            target.log(.fromStd(level), message, .{}) catch {}; // Logging must not fail.
        }
    }.logFn;
}

fn formatMessage(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    assert(buffer.len >= 3);
    var w: Io.Writer = .fixed(buffer);
    w.print(format, args) catch {
        @memcpy(buffer[buffer.len - 3 ..], "...");
        return buffer;
    };
    return w.buffered();
}

const testing = std.testing;

/// 2026-10-12T10:00:00Z
const test_instant: Io.Timestamp = .fromNanoseconds(1_791_799_200 * std.time.ns_per_s);

fn testLogger(w: *Io.Writer, format: Format) Logger {
    return .{ .writer = w, .format = format, .level = .trace, .clock = .{ .fixed = test_instant } };
}

test "text records are byte-exact" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const logger = testLogger(&w, .text);
    try logger.log(.info, "listening", .{ .port = 8080, .host = "local host", .tls = false });
    const none: ?u8 = null;
    try logger.log(.err, "failed", .{ .cause = error.FileNotFound, .mode = .fast, .n = none });
    try logger.log(.warn, "two\nlines", .{ .empty = "", .ratio = 0.5 });
    try testing.expectEqualStrings(
        \\2026-10-12T10:00:00Z INFO listening port=8080 host="local host" tls=false
        \\2026-10-12T10:00:00Z ERROR failed cause=FileNotFound mode=fast n=null
        \\2026-10-12T10:00:00Z WARN two\nlines empty="" ratio=0.5
        \\
    , w.buffered());
}

test "json records are byte-exact" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    var logger = testLogger(&w, .json);
    logger.scope = "db";
    const three: ?u8 = 3;
    try logger.log(.info, "say \"hi\"", .{ .port = 8080, .host = "h", .ok = true, .opt = three });
    try logger.log(.err, "x", .{ .cause = error.Oops, .mode = .fast });
    try testing.expectEqualStrings(
        "{\"time\":\"2026-10-12T10:00:00Z\",\"level\":\"info\",\"msg\":\"say \\\"hi\\\"\"," ++
            "\"scope\":\"db\",\"port\":8080,\"host\":\"h\",\"ok\":true,\"opt\":3}\n" ++
            "{\"time\":\"2026-10-12T10:00:00Z\",\"level\":\"error\",\"msg\":\"x\"," ++
            "\"scope\":\"db\",\"cause\":\"Oops\",\"mode\":\"fast\"}\n",
        w.buffered(),
    );
}

test "no clock means no timestamp" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const logger: Logger = .{ .writer = &w };
    logger.info("hello", .{});
    var json: Logger = .{ .writer = &w, .format = .json };
    json.info("hello", .{});
    try testing.expectEqualStrings(
        "INFO hello\n{\"level\":\"info\",\"msg\":\"hello\"}\n",
        w.buffered(),
    );
}

test "colour wraps the label only" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const logger: Logger = .{ .writer = &w, .color = true };
    logger.warn("careful", .{ .n = 1 });
    try testing.expectEqualStrings("\x1b[33mWARN\x1b[0m careful n=1\n", w.buffered());
}

test "redaction by key, case-insensitive, in both formats" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    var logger: Logger = .{ .writer = &w };
    logger.info("login", .{ .user = "ann", .db_password = "hunter2", .Authorization = "Bearer x" });
    logger.format = .json;
    logger.info("login", .{ .api_TOKEN = "t", .client_secret = "s" });
    logger.format = .text;
    logger.redact = &.{"user"};
    logger.info("custom", .{ .user = "ann", .password = "visible" });
    try testing.expectEqualStrings(
        \\INFO login user=ann db_password=[REDACTED] Authorization=[REDACTED]
        \\{"level":"info","msg":"login","api_TOKEN":"[REDACTED]","client_secret":"[REDACTED]"}
        \\INFO custom user=[REDACTED] password=visible
        \\
    , w.buffered());
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "hunter2") == null);
}

test "level filtering" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const logger: Logger = .{ .writer = &w, .level = .warn };
    logger.trace("t", .{});
    logger.debug("d", .{});
    logger.info("i", .{});
    logger.warn("w", .{});
    logger.err("e", .{});
    try testing.expectEqualStrings("WARN w\nERROR e\n", w.buffered());
    try testing.expect(!logger.enabled(.info));
    try testing.expect(logger.enabled(.err));
}

test "parseLevel" {
    try testing.expectEqual(Level.trace, try parseLevel("trace"));
    try testing.expectEqual(Level.debug, try parseLevel("DEBUG"));
    try testing.expectEqual(Level.info, try parseLevel("Info"));
    try testing.expectEqual(Level.warn, try parseLevel("warn"));
    try testing.expectEqual(Level.warn, try parseLevel("WARNING"));
    try testing.expectEqual(Level.err, try parseLevel("err"));
    try testing.expectEqual(Level.err, try Level.parse("error"));
    try testing.expectEqual(Level.fatal, try parseLevel("FATAL"));
    for ([_][]const u8{ "", "inf", "warnings", " info" }) |text| {
        try testing.expectError(error.InvalidLevel, parseLevel(text));
    }
}

test "scoped copies" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const base: Logger = .{ .writer = &w };
    base.scoped("http").info("up", .{});
    try testing.expectEqualStrings("INFO up scope=http\n", w.buffered());
}

test "writeTimestamp" {
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeTimestamp(&w, .fromNanoseconds(0));
    try w.writeByte(' ');
    try writeTimestamp(&w, .fromNanoseconds(951_782_400 * std.time.ns_per_s + 1)); // Leap day.
    try w.writeByte(' ');
    try writeTimestamp(&w, .fromNanoseconds(-5));
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00Z 2000-02-29T00:00:00Z 1970-01-01T00:00:00Z",
        w.buffered(),
    );
}

var test_std_logger: ?*const Logger = null;

fn testGetLogger() ?*const Logger {
    return test_std_logger;
}

test "std.log adapter" {
    var buffer: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const logger: Logger = .{ .writer = &w, .level = .info };
    test_std_logger = &logger;
    defer test_std_logger = null;
    const logFn = stdLogFn(testGetLogger);
    logFn(.info, .default, "hello {s} #{d}", .{ "world", 7 });
    logFn(.debug, .default, "dropped", .{});
    logFn(.err, .net, "down", .{});
    try testing.expectEqualStrings("INFO hello world #7\nERROR down scope=net\n", w.buffered());

    w = .fixed(&buffer);
    var long: [std_message_max + 10]u8 = undefined;
    @memset(&long, 'a');
    logFn(.warn, .default, "{s}", .{&long});
    const line = w.buffered();
    try testing.expectEqual("WARN ".len + std_message_max + 1, line.len);
    try testing.expect(std.mem.endsWith(u8, line, "aaa...\n"));
}

test "formatMessage truncates with an ellipsis" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("abcde...", formatMessage(&buffer, "{s}", .{"abcdefghijk"}));
    try testing.expectEqualStrings("abc", formatMessage(&buffer, "{s}", .{"abc"}));
}

test "logfmt, charm's style, fields carried, prefixes, callers, and time formats" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    var logger = testLogger(&w, .logfmt);
    const carried = [_]Field{ .{ .key = "user", .value = .{ .string = "ada" } }, .{
        .key = "n",
        .value = .{ .int = 2 },
    } };
    const with_user = logger.with(&carried).withPrefix("bake");
    try with_user.log(.info, "two words", .{ .ok = true });
    try testing.expectEqualStrings("time=2026-10-12T10:00:00Z level=info prefix=bake " ++
        "msg=\"two words\" user=ada n=2 ok=true\n", w.buffered());

    w = .fixed(&buffer);
    logger.format = .text;
    logger.time_format = .kitchen;
    try logger.logAt(.{
        .file = "src/oven.zig",
        .fn_name = "",
        .line = 12,
        .column = 1,
        .module = "",
    }, .warn, "hot", .{});
    try testing.expectEqualStrings("10:00AM WARN <oven.zig:12> hot\n", w.buffered());

    w = .fixed(&buffer);
    logger.clock = .none;
    logger.color = true;
    logger.style = .charm;
    try logger.withPrefix("bake").log(.err, "burnt", .{ .temp = 300 });
    try testing.expectEqualStrings("\x1b[1;38;5;204mERRO\x1b[0m \x1b[1mbake:\x1b[0m burnt " ++
        "\x1b[2mtemp=\x1b[0m300\n", w.buffered());

    w = .fixed(&buffer);
    try writeTimeAs(&w, test_instant, .date_time, .utc);
    try testing.expectEqualStrings("2026/10/12 10:00:00", w.buffered());
}

test "records with no level, as charm's Print" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    var logger = testLogger(&w, .text);
    logger.level = .fatal;
    logger.prefix = "p";
    try logger.log(.none, "hi", .{ .n = 1 });
    logger.format = .logfmt;
    try logger.log(.none, "hi", .{});
    logger.format = .json;
    logger.clock = .none;
    try logger.log(.none, "hi", .{});
    try testing.expectEqualStrings("2026-10-12T10:00:00Z p: hi n=1\n" ++
        "time=2026-10-12T10:00:00Z prefix=p msg=hi\n" ++
        "{\"prefix\":\"p\",\"msg\":\"hi\"}\n", w.buffered());
}

test "Go's named time layouts" {
    // Monday 2026-10-12, 15:04:05.120 UTC.
    const instant: Io.Timestamp = .fromNanoseconds(test_instant.toNanoseconds() +
        (5 * std.time.s_per_hour + 4 * std.time.s_per_min + 5) * std.time.ns_per_s +
        120 * std.time.ns_per_ms);
    const expected = [_]struct { TimeFormat, []const u8 }{
        .{ .kitchen, "3:04PM" },
        .{ .layout, "10/12 03:04:05PM '26 +0000" },
        .{ .ansic, "Mon Oct 12 15:04:05 2026" },
        .{ .unixdate, "Mon Oct 12 15:04:05 UTC 2026" },
        .{ .rfc822z, "12 Oct 26 15:04 +0000" },
        .{ .rfc850, "Monday, 12-Oct-26 15:04:05 UTC" },
        .{ .rfc1123, "Mon, 12 Oct 2026 15:04:05 UTC" },
        .{ .rfc3339, "2026-10-12T15:04:05Z" },
        .{ .rfc3339nano, "2026-10-12T15:04:05.12Z" },
        .{ .stampmilli, "Oct 12 15:04:05.120" },
        .{ .stampmicro, "Oct 12 15:04:05.120000" },
        .{ .datetime, "2026-10-12 15:04:05" },
        .{ .dateonly, "2026-10-12" },
        .{ .timeonly, "15:04:05" },
    };
    var buffer: [128]u8 = undefined;
    for (expected) |e| {
        var w: Io.Writer = .fixed(&buffer);
        try writeTimeAs(&w, instant, e[0], .utc);
        try testing.expectEqualStrings(e[1], w.buffered());
    }
    // A day of one digit is padded with a space; midnight is 12AM.
    var w: Io.Writer = .fixed(&buffer);
    try writeTimeAs(&w, .fromNanoseconds(0), .stamp, .utc);
    try writeTimeAs(&w, .fromNanoseconds(0), .kitchen, .utc);
    try writeTimeAs(&w, .fromNanoseconds(0), .rfc3339nano, .utc);
    try testing.expectEqualStrings("Jan  1 00:00:0012:00AM1970-01-01T00:00:00Z", w.buffered());
    // In a zone: local fields, its offset, and its name.
    const india: timezone.Offset = .{ .seconds = 19800, .name = .init("IST") };
    w = .fixed(&buffer);
    try writeTimeAs(&w, instant, .rfc3339, india);
    try writeTimeAs(&w, instant, .rubydate, .{ .seconds = -14400, .name = .init("EDT") });
    try writeTimeAs(&w, instant, .unixdate, india);
    try testing.expectEqualStrings("2026-10-12T20:34:05+05:30Mon Oct 12 11:04:05 -0400 2026" ++
        "Mon Oct 12 20:34:05 IST 2026", w.buffered());
}

test "records in the logger's zone, in every format" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    var logger = testLogger(&w, .text);
    logger.zone = .{ .rule = try .parse("CET-1CEST,M3.5.0,M10.5.0/3") };
    logger.time_format = .unixdate;
    try logger.log(.info, "x", .{});
    logger.format = .logfmt;
    try logger.log(.info, "x", .{});
    logger.format = .json;
    try logger.log(.info, "x", .{});
    try testing.expectEqualStrings("Mon Oct 12 12:00:00 CEST 2026 INFO x\n" ++
        "time=2026-10-12T12:00:00+02:00 level=info msg=x\n" ++
        "{\"time\":\"2026-10-12T12:00:00+02:00\",\"level\":\"info\",\"msg\":\"x\"}\n", w.buffered());
}

test "charm's style, restyled" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const logger: Logger = .{
        .writer = &w,
        .color = true,
        .style = .charm,
        .styles = .{
            .time = "",
            .level = "\x1b[1;35m",
            .short_levels = false,
            .prefix = "\x1b[4m",
            .message = "\x1b[3m",
            .key = "",
            .separator = "\x1b[2m",
            .value = "\x1b[32m",
        },
        .prefix = "p",
    };
    try logger.log(.err, "m", .{ .k = "v" });
    try testing.expectEqualStrings("\x1b[1;35mERROR\x1b[0m \x1b[4mp:\x1b[0m \x1b[3mm\x1b[0m " ++
        "k\x1b[2m=\x1b[0m\x1b[32mv\x1b[0m\n", w.buffered());
}

test "secret values are scrubbed from messages and string fields in every format" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    var logger: Logger = .{ .writer = &w, .secrets = &.{ "", "hunter2", "hunt", "s3cr\"t" } };
    const carried = [_]Field{.{ .key = "note", .value = .{ .string = "pw hunter2" } }};
    logger = logger.with(&carried);
    logger.info("login hunter2\nok", .{ .arg = "hunter2", .q = "a s3cr\"t", .n = 2 });
    logger.format = .logfmt;
    logger.info("hunter2hunt", .{ .opt = @as(?[]const u8, "xhunter2x") });
    logger.format = .json;
    logger.info("say s3cr\"t\\", .{ .arg = "hunter2" });
    try testing.expectEqualStrings(
        \\INFO login [REDACTED]\nok note="pw [REDACTED]" arg=[REDACTED] q="a [REDACTED]" n=2
        \\level=info msg=[REDACTED][REDACTED] note="pw [REDACTED]" opt=x[REDACTED]x
        \\{"level":"info","msg":"say [REDACTED]\\","note":"pw [REDACTED]","arg":"[REDACTED]"}
        \\
    , w.buffered());
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "hunt") == null);
}

test "secret values are scrubbed from composite field values too" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    var logger: Logger = .{ .writer = &w, .secrets = &.{"hunter2"} };
    const argv: []const []const u8 = &.{ "--token", "hunter2" };
    logger.info("run", .{ .argv = argv });
    logger.format = .json;
    logger.info("run", .{ .argv = argv });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "hunter2") == null);
    try testing.expectEqual(2, std.mem.count(u8, w.buffered(), redacted));
}

test "composite values show their strings as text" {
    var buffer: [128]u8 = undefined;
    const S = struct { name: []const u8, n: u32, tags: [2][]const u8 };
    const text = anyText(&buffer, S{ .name = "a\nb", .n = 3, .tags = .{ "x", "pw" } }, &.{"pw"});
    try testing.expectEqualStrings(".{ .name = \"a\\nb\", .n = 3, .tags = { \"x\", \"[REDACTED]\" } }", text);
}

test "json message with a backslash and a newline is one line and round-trips" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const logger: Logger = .{ .writer = &w, .format = .json };
    const message = "C:\\temp\nnext \"line\"";
    logger.info(message, .{ .path = "a\\b\n" });
    const line = w.buffered();
    try testing.expectEqual(line.len - 1, std.mem.indexOfScalar(u8, line, '\n').?);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(message, parsed.value.object.get("msg").?.string);
    try testing.expectEqualStrings("a\\b\n", parsed.value.object.get("path").?.string);
}
