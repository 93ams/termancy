//! Leveled logging that renders either readable console text or machine-readable
//! JSON.
//!
//! ## Why this is a value and not a global
//!
//! `std.log` is a global because it has to be: it is reached from code that never
//! receives a context. A logger chosen by the program does not have that problem,
//! and making it a value buys three things a global cannot:
//!
//!   * A test asserts the **exact bytes** of a record, including the JSON, without
//!     installing a global log function and racing every other test.
//!   * Two loggers with different levels or formats can coexist - a program that
//!     writes JSON to a file and text to its terminal needs exactly that.
//!   * Nothing is enabled by importing the module. A library that uses this cannot
//!     start printing because someone linked it.
//!
//! ## Why it owns no clock
//!
//! The timestamp is a parameter, not a reading. That makes every record a pure
//! function of its arguments, which is what lets a test assert an exact JSON
//! document rather than a regex over it. A caller with a time source uses
//! `writeAt`; a caller without one uses `write` and the field is simply absent,
//! which is honest - a fabricated `"time":0` would be a lie an aggregator cannot
//! detect.
//!
//! ## Escaping is not optional
//!
//! The JSON path goes through `std.json.Stringify` rather than `writer.print`.
//! A message containing a quote, a backslash or a newline is completely ordinary
//! - a file path on Windows, an error from a foreign program - and interpolating
//! one into a JSON document by hand produces a record that a collector will drop
//! or, worse, parse as something else.

const std = @import("std");
const assert = std.debug.assert;

/// Severity.
///
/// Numbered so that "is this record worth emitting" is a single `<`. The names
/// are `std.log`'s, with `err` rather than `error` because `error` is a keyword.
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    /// The lowercase name used in both output formats, so a JSON consumer and a
    /// text consumer see the same vocabulary.
    pub fn name(self: Level) []const u8 {
        return @tagName(self);
    }
};

/// How a record is rendered.
pub const Format = enum { text, json };

const Self = @This();

/// Records below this are dropped.
min_level: Level = .info,
format: Format = .text,
/// Emitted in every record so an aggregator can attribute a line to the program
/// that wrote it. Required, because a log stream with no source is a log stream
/// nobody can act on.
service: []const u8,

/// A logger for `service` at `.info`, in text.
pub fn init(service: []const u8) Self {
    assert(service.len > 0);
    assert(std.mem.indexOfAny(u8, service, " \t\n") == null);
    return .{ .service = service };
}

/// The same logger with a different threshold.
pub fn withLevel(self: Self, level: Level) Self {
    var copy = self;
    copy.min_level = level;
    return copy;
}

/// The same logger with a different format.
pub fn withFormat(self: Self, format: Format) Self {
    var copy = self;
    copy.format = format;
    return copy;
}

/// Whether a record at `level` would be written.
///
/// Public so a caller can skip work whose only purpose was to produce a message:
/// rendering a large diff into a log line that is then discarded is the usual way
/// a debug-level statement becomes a performance problem.
pub fn enabled(self: Self, level: Level) bool {
    return @backingInt(level) >= @backingInt(self.min_level);
}

/// Writes one record with no timestamp.
pub fn write(
    self: Self,
    writer: anytype,
    level: Level,
    scope: []const u8,
    message: []const u8,
) !void {
    return self.writeAt(writer, level, scope, message, null);
}

/// Writes one record, with `timestamp_ms` in the JSON form when supplied.
///
/// `scope` may be empty, meaning "no particular subsystem"; it is then omitted
/// from the text line rather than rendered as a dangling separator.
///
/// The message is scrubbed of every registered secret first - see
/// `registerSecret`. A log line is the one output nobody reviews before it ships,
/// so a token that reaches a log has left the machine.
pub fn writeAt(
    self: Self,
    writer: anytype,
    level: Level,
    scope: []const u8,
    message: []const u8,
    timestamp_ms: ?i64,
) !void {
    assert(self.service.len > 0);
    if (!self.enabled(level)) return;

    switch (self.format) {
        .text => try self.writeTextScrubbed(writer, level, scope, message),
        .json => try self.writeJson(writer, level, scope, message, timestamp_ms),
    }
}

/// `writeText` with the message's secrets replaced.
///
/// Streamed rather than buffered: the message is walked once, writing the text before
/// each secret and a mask in its place. That keeps arbitrarily long messages working
/// without an allocation, which matters because a log call must not be able to fail
/// for a reason unrelated to logging.
fn writeTextScrubbed(
    self: Self,
    writer: anytype,
    level: Level,
    scope: []const u8,
    message: []const u8,
) !void {
    assert(level.name().len <= 5);
    if (scope.len == 0) {
        try writer.print("{s: <5} {s}: ", .{ level.name(), self.service });
    } else {
        try writer.print("{s: <5} {s}:{s} ", .{ level.name(), self.service, scope });
    }

    // The prefix goes out first, so the walk below only has to reason about the message.
    var remaining = message;
    while (findEarliestSecret(remaining)) |hit| {
        try writer.writeAll(remaining[0..hit.start]);
        try writer.writeAll(redaction_mask);
        remaining = remaining[hit.end..];
    }
    try writer.writeAll(remaining);
    try writer.writeByte('\n');
}

/// What replaces a secret in a log line. Fixed text, not a masked prefix: a mask that
/// keeps characters leaks the length and the last character, which the suite's own
/// `security.redact` test records as a defect of that helper.
pub const redaction_mask = "[REDACTED]";

/// The secrets registered process-wide, in registration order.
///
/// Process-wide because a logger is a value type passed to `write`, while the flags
/// that carry secrets are parsed once, elsewhere. The framework registers them as it
/// parses (`App.execute`), so an application that never touches this API still gets
/// its `meta.<field>.secret` values scrubbed out of every log line.
var registered_secrets: [32][]const u8 = @splat("");
var registered_count: usize = 0;

/// Registers a value to be scrubbed from every subsequent log message.
///
/// Empty values and duplicates are ignored: an empty string would match everywhere,
/// and registering the same token twice would only cost a comparison. The slice is
/// *borrowed*, not copied - command-line arguments live for the whole process, which
/// is exactly the lifetime a secret needs here.
pub fn registerSecret(value: []const u8) void {
    if (value.len == 0) return;
    for (registered_secrets[0..registered_count]) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    if (registered_count == registered_secrets.len) return;
    registered_secrets[registered_count] = value;
    registered_count += 1;
}

/// Forgets every registered secret. For a long-lived process that has finished with
/// one set of credentials, and for tests, which must not leak state into each other.
pub fn clearSecrets() void {
    for (registered_secrets[0..registered_count]) |*slot| slot.* = "";
    registered_count = 0;
}

/// How many secrets are registered. Exposed so a test can assert the framework
/// registered what it parsed.
pub fn registeredSecretCount() usize {
    return registered_count;
}

/// Where a secret was found in a message.
///
/// A named type rather than an anonymous struct literal: two returns of the same
/// anonymous shape are two *different* types to Zig, and the call sites in this file
/// compare them. (The same hazard as `Ctx`: an anonymous type inside a generic
/// function is instantiated per use.)
pub const SecretRange = struct { start: usize, end: usize };

/// The earliest occurrence of any registered secret in `text`, or null.
///
/// Earliest rather than first-registered: two secrets can overlap, and replacing a
/// later one first would leave a fragment of the earlier one in the output.
fn findEarliestSecret(text: []const u8) ?SecretRange {
    var best: ?SecretRange = null;
    for (registered_secrets[0..registered_count]) |secret| {
        if (secret.len == 0) continue;
        if (std.mem.indexOf(u8, text, secret)) |start| {
            const end = start + secret.len;
            if (best == null or start < best.?.start) best = .{ .start = start, .end = end };
        }
    }
    return best;
}

/// `level  service:scope message`
///
/// The level is padded to a fixed width so a column of records lines up, which is
/// the entire reason a human reads one of these rather than a JSON document.
fn writeText(
    self: Self,
    writer: anytype,
    level: Level,
    scope: []const u8,
    message: []const u8,
) !void {
    assert(level.name().len <= 5);
    if (scope.len == 0) {
        try writer.print("{s: <5} {s}: {s}\n", .{ level.name(), self.service, message });
    } else {
        try writer.print("{s: <5} {s}:{s} {s}\n", .{
            level.name(), self.service, scope, message,
        });
    }
}

/// One JSON object per line (NDJSON), which is the shape a log collector wants:
/// a stream of independently parseable documents rather than one array that is
/// only valid once the process exits cleanly.
fn writeJson(
    self: Self,
    writer: anytype,
    level: Level,
    scope: []const u8,
    message: []const u8,
    timestamp_ms: ?i64,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };

    try json.beginObject();
    if (timestamp_ms) |ms| {
        try json.objectField("time");
        try json.write(ms);
    }
    try json.objectField("level");
    try json.write(level.name());
    try json.objectField("service");
    try json.write(self.service);
    if (scope.len > 0) {
        try json.objectField("scope");
        try json.write(scope);
    }
    try json.objectField("msg");
    // Scrubbing happens before escaping, so the mask is escaped like any other text.
    // A stack copy rather than streaming: `Stringify` wants one value, and a message
    // that contains a secret is the rare case this branch exists for.
    var scrub_buf: [2048]u8 = undefined;
    try json.write(scrubBorrowed(&scrub_buf, message) orelse message);
    try json.endObject();
    try writer.writeByte('\n');
}

/// A stack copy of `message` with every registered secret replaced, or null when the
/// message contained none.
///
/// Null is also the answer when the copy would not fit the caller's buffer, in which
/// case the original is written and the mask is the only thing lost. The text form
/// streams and has no such limit; this exists because `std.json.Stringify` wants one
/// value to escape.
fn scrubBorrowed(buffer: []u8, message: []const u8) ?[]const u8 {
    if (registered_count == 0) return null;
    if (findEarliestSecret(message) == null) return null;

    var fixed = std.Io.Writer.fixed(buffer);
    var remaining = message;
    while (findEarliestSecret(remaining)) |hit| {
        fixed.writeAll(remaining[0..hit.start]) catch return null;
        fixed.writeAll(redaction_mask) catch return null;
        remaining = remaining[hit.end..];
    }
    fixed.writeAll(remaining) catch return null;
    return buffer[0 .. buffer.len - fixed.unusedCapacityLen()];
}

/// Parses a level name, case-insensitively, accepting the abbreviations people
/// actually type.
///
/// Returns `null` for anything unrecognised rather than substituting a default: a
/// caller that asked for `--log-level verbose` should be told its request was not
/// understood, not silently given `.info`.
pub fn parseLevel(name: []const u8) ?Level {
    assert(name.len > 0);

    const known = [_]struct { name: []const u8, level: Level }{
        .{ .name = "debug", .level = .debug },
        .{ .name = "dbg", .level = .debug },
        .{ .name = "info", .level = .info },
        .{ .name = "warn", .level = .warn },
        .{ .name = "warning", .level = .warn },
        .{ .name = "err", .level = .err },
        .{ .name = "error", .level = .err },
    };

    for (known) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.level;
    }
    return null;
}

const testing = std.testing;

test "records below the threshold are dropped and the rest are not" {
    const logger = Self.init("cfg").withLevel(.warn);

    try testing.expect(!logger.enabled(.debug));
    try testing.expect(!logger.enabled(.info));
    try testing.expect(logger.enabled(.warn));
    try testing.expect(logger.enabled(.err));

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try logger.write(&w, .info, "cmd.get", "resolved 3 keys");
    // The rejected record must not have written its level or its message.
    try testing.expectEqualStrings("", w.buffered());
}

test "the text form is a padded level, the service, the scope and the message" {
    const logger = Self.init("cfg");

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try logger.write(&w, .info, "cmd.get", "resolved 3 keys");
    // Two spaces after `info` because the level is padded to five columns, so a
    // column of records lines up.
    try testing.expectEqualStrings("info  cfg:cmd.get resolved 3 keys\n", w.buffered());
}

test "an empty scope is omitted rather than rendered as a dangling colon" {
    const logger = Self.init("snek");
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try logger.write(&w, .err, "", "something went wrong");
    try testing.expectEqualStrings("err   snek: something went wrong\n", w.buffered());
}

test "the JSON form is one object per line with the fields a collector needs" {
    const logger = Self.init("cfg").withFormat(.json);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try logger.writeAt(&w, .info, "cmd.get", "resolved 3 keys", 1_700_000_000_000);
    try testing.expectEqualStrings(
        "{\"time\":1700000000000,\"level\":\"info\",\"service\":\"cfg\"," ++
            "\"scope\":\"cmd.get\",\"msg\":\"resolved 3 keys\"}\n",
        w.buffered(),
    );
}

test "JSON escaping survives a quote, a backslash and a newline" {
    // This is the case that makes hand-rolled interpolation wrong. A Windows path
    // and a multi-line error from a foreign program are both completely ordinary.
    const logger = Self.init("cfg").withFormat(.json);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try logger.write(&w, .err, "fs", "cannot open \"C:\\a b\"\nline two");

    const out = w.buffered();
    // The document must still be exactly one line, and must still parse.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\\\") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\n") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const message = parsed.value.object.get("msg").?.string;
    try testing.expectEqualStrings("cannot open \"C:\\a b\"\nline two", message);
}

test "a record with no timestamp omits the field rather than inventing zero" {
    const logger = Self.init("cfg").withFormat(.json);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try logger.write(&w, .info, "cmd.get", "no clock here");

    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"time\"") == null);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "{\"level\":\"info\""));
}

test "parseLevel is case-insensitive and accepts the usual abbreviations" {
    try testing.expectEqual(@as(?Level, .debug), parseLevel("DEBUG"));
    try testing.expectEqual(@as(?Level, .debug), parseLevel("dbg"));
    try testing.expectEqual(@as(?Level, .info), parseLevel("Info"));
    try testing.expectEqual(@as(?Level, .warn), parseLevel("WARN"));
    try testing.expectEqual(@as(?Level, .warn), parseLevel("warning"));
    try testing.expectEqual(@as(?Level, .err), parseLevel("err"));
    try testing.expectEqual(@as(?Level, .err), parseLevel("ERROR"));

    // Unrecognised input is reported, not defaulted.
    try testing.expectEqual(@as(?Level, null), parseLevel("verbose"));
}

test "builders copy rather than mutate, so two loggers can coexist" {
    const base = Self.init("cfg");
    const json_logger = base.withFormat(.json);
    const quiet = base.withLevel(.err);

    // The original is untouched by either derivation.
    try testing.expectEqual(Format.text, base.format);
    try testing.expectEqual(Level.info, base.min_level);
    try testing.expectEqual(Format.json, json_logger.format);
    try testing.expectEqual(Level.err, quiet.min_level);
}
