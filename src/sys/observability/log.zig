//! Leveled logging, as charm's log does it: human text (plain, or charm's colored
//! badges), JSON lines, or logfmt; structured fields, fields every record carries
//! (`with`), a prefix, the caller's file and line (`logAt`), time formats, a fatal level,
//! redaction by key, and scrubbing of known secret values wherever they appear.
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

/// Severity, least severe first, so filtering is one comparison.
pub const Level = enum(u3) {
    trace,
    debug,
    info,
    warn,
    err,
    /// Logged, then the process exits with status 1 (`Logger.fatal`).
    fatal,

    /// The upper-case label used in text output: `INFO`, `ERROR`, ...
    pub fn label(level: Level) []const u8 {
        return switch (level) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
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

/// How timestamps are written in text records (JSON and logfmt always use RFC 3339).
pub const TimeFormat = enum {
    /// `2026-10-12T10:00:00Z`
    rfc3339,
    /// `2026/10/12 10:00:00`
    date_time,
    /// `10:00:00`
    time,
    /// `10:00AM`
    kitchen,
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
    time_format: TimeFormat = .rfc3339,

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
        if (time) |instant| {
            if (charm) try w.writeAll("\x1b[2m");
            try writeTimeAs(w, instant, logger.time_format);
            if (charm) try w.writeAll("\x1b[0m");
            try w.writeByte(' ');
        }
        if (charm) {
            try w.print("\x1b[{s}m{s}\x1b[0m ", .{ charmColor(level), level.short() });
        } else if (logger.color) {
            try w.print("\x1b[{s}m{s}\x1b[0m ", .{ levelColor(level), level.label() });
        } else {
            try w.print("{s} ", .{level.label()});
        }
        if (caller.len > 0) {
            if (charm) try w.writeAll("\x1b[2m");
            try w.print("<{s}> ", .{caller});
            if (charm) try w.writeAll("\x1b[0m");
        }
        if (logger.prefix.len > 0) {
            if (charm) try w.writeAll("\x1b[1m");
            try writeTextEscaped(w, logger.prefix, &.{});
            try w.writeByte(':');
            if (charm) try w.writeAll("\x1b[0m");
            try w.writeByte(' ');
        }
        try writeTextEscaped(w, message, logger.secrets);
        if (logger.scope.len > 0) {
            try logger.writeKey(w, "scope", charm);
            try writeTextString(w, logger.scope, &.{});
        }
        for (logger.fields) |field| {
            try logger.writeKey(w, field.key, charm);
            if (logger.isRedacted(field.key))
                try w.writeAll(redacted)
            else
                try writeFieldValue(w, field.value, logger.secrets);
        }
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |key| {
            try logger.writeKey(w, key, charm);
            if (logger.isRedacted(key)) {
                try w.writeAll(redacted);
            } else {
                try writeTextValue(w, @field(fields, key), logger.secrets);
            }
        }
        try w.writeByte('\n');
    }

    fn writeKey(
        logger: *const Logger,
        w: *Io.Writer,
        key: []const u8,
        charm: bool,
    ) Io.Writer.Error!void {
        _ = logger;
        if (charm) return w.print(" \x1b[2m{s}=\x1b[0m", .{key});
        try w.print(" {s}=", .{key});
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
            try writeTimestamp(w, instant);
            try w.writeByte(' ');
        }
        try w.print("level={s}", .{level.name()});
        if (caller.len > 0) {
            try w.writeAll(" caller=");
            try writeTextString(w, caller, &.{});
        }
        if (logger.prefix.len > 0) {
            try w.writeAll(" prefix=");
            try writeTextString(w, logger.prefix, &.{});
        }
        try w.writeAll(" msg=");
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
            try writeTimestamp(json.writer, instant);
            try json.writer.writeByte('"');
            json.endWriteRaw();
        }
        try json.objectField("level");
        try json.write(level.name());
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
    };
}

/// charm's log colors: debug purple, info teal, warn yellow, error pink, fatal magenta.
fn charmColor(level: Level) []const u8 {
    return switch (level) {
        .trace => "1;38;5;245",
        .debug => "1;38;5;63",
        .info => "1;38;5;86",
        .warn => "1;38;5;192",
        .err => "1;38;5;204",
        .fatal => "1;38;5;134",
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

/// Writes `instant` (UTC) in `format`.
pub fn writeTimeAs(w: *Io.Writer, instant: Io.Timestamp, format: TimeFormat) Io.Writer.Error!void {
    if (format == .rfc3339) return writeTimestamp(w, instant);
    const seconds: u64 = @intCast(@max(0, instant.toSeconds()));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getDaySeconds();
    const hours = day.getHoursIntoDay();
    const minutes = day.getMinutesIntoHour();
    switch (format) {
        .rfc3339 => unreachable,
        .time => try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{
            hours,
            minutes,
            day.getSecondsIntoMinute(),
        }),
        .kitchen => {
            const twelve = if (hours % 12 == 0) 12 else hours % 12;
            try w.print("{d}:{d:0>2}{s}", .{ twelve, minutes, if (hours < 12) "AM" else "PM" });
        },
        .date_time => {
            const year_day = epoch.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            try w.print("{d:0>4}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                hours,
                minutes,
                day.getSecondsIntoMinute(),
            });
        },
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
        else => try w.print("{any}", .{value}),
    }
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
            // Anything else is rendered as its `{any}` text, which is always valid JSON once
            // quoted, rather than trusting `Stringify` with an arbitrary type.
            var buffer: [256]u8 = undefined;
            var fixed: Io.Writer = .fixed(&buffer);
            fixed.print("{any}", .{value}) catch {}; // Truncated at the buffer's size.
            try json.write(fixed.buffered());
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
    try writeTimeAs(&w, test_instant, .date_time);
    try testing.expectEqualStrings("2026/10/12 10:00:00", w.buffered());
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
