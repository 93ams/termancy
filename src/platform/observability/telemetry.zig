//! Opt-in usage telemetry: the decision, the event, and (separately, explicitly) the sending.
//!
//! ```zig
//! const decision = (telemetry.Policy{
//!     .consent = if (settings.telemetry) .granted else .unknown,
//!     .opt_out_var = "SNEK_NO_TELEMETRY",
//! }).decide(environ);
//! if (decision == .enabled) {
//!     var body: std.Io.Writer.Allocating = .init(gpa);
//!     defer body.deinit();
//!     try telemetry.writeEvent(&body.writer, app, &.{ "command", "ok" }, .{
//!         .name = "command_run",
//!         .properties = &.{ .{ .key = "command", .value = .{ .string = "cfg get" } } },
//!     }, std.Io.Clock.real.now(io));
//!     try telemetry.send(&client, decision, "https://telemetry.example/v1", body.written());
//! }
//! ```
//!
//! Telemetry is off unless consent was recorded, and off whenever `DO_NOT_TRACK`, `CI`, or
//! the application's own opt-out variable is set, whatever the consent says.
//!
//! Privacy: an event carries the event name, an anonymous id, the app's name and version,
//! OS, architecture, time, and only properties whose keys the caller allow-listed. String
//! values that look like paths or addresses are refused. The anonymous id is a hash of a
//! random install id the caller generates once (`newInstallId`) and persists, salted with the
//! app name, so the stored id never leaves the machine and two apps cannot correlate it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = @import("log.zig");

/// Whether the user agreed, as the application recorded it.
pub const Consent = enum { unknown, granted, denied };

/// The outcome of `Policy.decide`: `enabled`, or the reason it is not.
pub const Decision = enum {
    enabled,
    /// No consent was recorded; the default.
    no_consent,
    consent_denied,
    do_not_track,
    ci,
    /// The application's opt-out variable is set.
    opt_out,
};

/// The inputs to the decision besides the environment.
pub const Policy = struct {
    consent: Consent = .unknown,
    /// An application-specific variable that disables telemetry when set, such as
    /// `SNEK_NO_TELEMETRY`.
    opt_out_var: ?[]const u8 = null,

    /// Decides. The environment's refusals win over consent; without consent it is off.
    pub fn decide(policy: Policy, environ: *const std.process.Environ.Map) Decision {
        if (isSet(environ, "DO_NOT_TRACK")) return .do_not_track;
        if (policy.opt_out_var) |name| if (isSet(environ, name)) return .opt_out;
        if (isSet(environ, "CI")) return .ci;
        return switch (policy.consent) {
            .granted => .enabled,
            .denied => .consent_denied,
            .unknown => .no_consent,
        };
    }
};

/// Set to anything but empty, `0`, `false`, `no`, or `off` (ignoring case).
fn isSet(environ: *const std.process.Environ.Map, name: []const u8) bool {
    const value = std.mem.trim(u8, environ.get(name) orelse return false, " \t");
    for ([_][]const u8{ "", "0", "false", "no", "off" }) |off| {
        if (std.ascii.eqlIgnoreCase(value, off)) return false;
    }
    return true;
}

/// A property value.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
};

/// One event property; its key must be allow-listed.
pub const Property = struct {
    key: []const u8,
    value: Value,
};

/// What happened.
pub const Event = struct {
    /// Lower-case letters, digits, `_` and `.`; at most `max_name_len` bytes.
    name: []const u8,
    properties: []const Property = &.{},
};

/// The application sending events.
pub const App = struct {
    name: []const u8,
    version: []const u8,
    /// From `newInstallId`, persisted by the caller.
    install_id: []const u8,
};

/// The longest event name or property key.
pub const max_name_len = 64;
/// The longest string property value.
pub const max_value_len = 128;
/// The length of an install id: 16 random bytes in lower-case hex.
pub const install_id_len = 32;

/// A new random install id. Generate once, store with the app's state, reuse.
pub fn newInstallId(io: Io) [install_id_len]u8 {
    var bytes: [install_id_len / 2]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// The id events carry: a salted hash of the install id, never the install id itself.
pub fn anonymousId(app_name: []const u8, install_id: []const u8) [32]u8 {
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    hash.update("snek-telemetry-v1\x00");
    hash.update(app_name);
    hash.update("\x00");
    hash.update(install_id);
    const digest = hash.finalResult();
    return std.fmt.bytesToHex(digest[0..16].*, .lower);
}

/// Why `writeEvent` refused an event.
pub const EventError = error{
    /// The event name or a property key is not `[a-z0-9_.]{1,64}`.
    InvalidName,
    /// A property key is not in the allow-list.
    PropertyNotAllowed,
    /// A string value is too long or looks like a path, address, or user name.
    ValueNotAllowed,
    /// The install id is not 32 lower-case hex digits.
    InvalidInstallId,
};

/// Checks an event against the allow-list and the privacy rules without writing anything.
pub fn validate(app: App, allowed: []const []const u8, event: Event) EventError!void {
    if (!validInstallId(app.install_id)) return error.InvalidInstallId;
    if (!validName(event.name)) return error.InvalidName;
    for (event.properties) |property| {
        if (!validName(property.key)) return error.InvalidName;
        if (!isAllowed(allowed, property.key)) return error.PropertyNotAllowed;
        switch (property.value) {
            .string => |text| if (!safeValue(text)) return error.ValueNotAllowed,
            .int, .bool => {},
        }
    }
}

/// Writes `event` as one JSON line, after `validate`. `time` is omitted when null.
pub fn writeEvent(
    w: *Io.Writer,
    app: App,
    allowed: []const []const u8,
    event: Event,
    time: ?Io.Timestamp,
) (EventError || Io.Writer.Error)!void {
    try validate(app, allowed, event);
    var json: std.json.Stringify = .{ .writer = w };
    try json.beginObject();
    try json.objectField("event");
    try json.write(event.name);
    try json.objectField("anonymous_id");
    try json.write(&anonymousId(app.name, app.install_id));
    inline for (.{
        .{ "app", app.name },
        .{ "version", app.version },
        .{ "os", @tagName(builtin.os.tag) },
        .{ "arch", @tagName(builtin.cpu.arch) },
    }) |field| {
        try json.objectField(field[0]);
        try json.write(field[1]);
    }
    if (time) |instant| {
        try json.objectField("time");
        try json.beginWriteRaw();
        try w.writeByte('"');
        try log.writeTimestamp(w, instant);
        try w.writeByte('"');
        json.endWriteRaw();
    }
    try json.objectField("properties");
    try json.beginObject();
    for (event.properties) |property| {
        try json.objectField(property.key);
        switch (property.value) {
            inline else => |value| try json.write(value),
        }
    }
    try json.endObject();
    try json.endObject();
    try w.writeByte('\n');
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '.' => {},
        else => return false,
    };
    return true;
}

fn validInstallId(id: []const u8) bool {
    if (id.len != install_id_len) return false;
    for (id) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn isAllowed(allowed: []const []const u8, key: []const u8) bool {
    for (allowed) |entry| {
        if (std.mem.eql(u8, entry, key)) return true;
    }
    return false;
}

/// A heuristic net under the allow-list: refuses paths (`/`, `\`, `~`), e-mail addresses
/// and `user@host` (`@`), control characters, and long text.
fn safeValue(text: []const u8) bool {
    if (text.len > max_value_len) return false;
    for (text) |c| switch (c) {
        '/', '\\', '~', '@', 0...0x1f, 0x7f => return false,
        else => {},
    };
    return true;
}

/// Why `send` failed.
pub const SendError = error{ TelemetryDisabled, UnexpectedStatus } || std.http.Client.FetchError;

/// Posts `body` (from `writeEvent`) to `url` as JSON. This is the only function in the
/// module that touches the network, and it refuses unless `decision` is `enabled`. Tests
/// never call it.
pub fn send(
    client: *std.http.Client,
    decision: Decision,
    url: []const u8,
    body: []const u8,
) SendError!void {
    if (decision != .enabled) return error.TelemetryDisabled;
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    if (result.status.class() != .success) return error.UnexpectedStatus;
}

const testing = std.testing;

fn testEnviron(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    errdefer environ.deinit();
    for (pairs) |pair| try environ.put(pair[0], pair[1]);
    return environ;
}

test "policy matrix" {
    const Case = struct { []const [2][]const u8, Consent, Decision };
    const cases = [_]Case{
        .{ &.{}, .unknown, .no_consent },
        .{ &.{}, .denied, .consent_denied },
        .{ &.{}, .granted, .enabled },
        .{ &.{.{ "DO_NOT_TRACK", "1" }}, .granted, .do_not_track },
        .{ &.{.{ "DO_NOT_TRACK", "true" }}, .unknown, .do_not_track },
        .{ &.{.{ "DO_NOT_TRACK", "0" }}, .granted, .enabled },
        .{ &.{.{ "DO_NOT_TRACK", "" }}, .granted, .enabled },
        .{ &.{.{ "DO_NOT_TRACK", "False" }}, .granted, .enabled },
        .{ &.{.{ "CI", "true" }}, .granted, .ci },
        .{ &.{.{ "CI", "1" }}, .unknown, .ci },
        .{ &.{.{ "CI", "false" }}, .granted, .enabled },
        .{ &.{.{ "SNEK_NO_TELEMETRY", "yes" }}, .granted, .opt_out },
        .{ &.{.{ "SNEK_NO_TELEMETRY", "off" }}, .granted, .enabled },
        .{ &.{ .{ "CI", "1" }, .{ "DO_NOT_TRACK", "1" } }, .granted, .do_not_track },
        .{ &.{ .{ "CI", "1" }, .{ "SNEK_NO_TELEMETRY", "1" } }, .granted, .opt_out },
    };
    for (cases) |case| {
        var environ = try testEnviron(case[0]);
        defer environ.deinit();
        const policy: Policy = .{ .consent = case[1], .opt_out_var = "SNEK_NO_TELEMETRY" };
        try testing.expectEqual(case[2], policy.decide(&environ));
    }
    var environ = try testEnviron(&.{.{ "SNEK_NO_TELEMETRY", "1" }});
    defer environ.deinit();
    // Without an opt-out variable configured, it is not consulted.
    try testing.expectEqual(Decision.enabled, (Policy{ .consent = .granted }).decide(&environ));
}

const test_app: App = .{
    .name = "snek",
    .version = "0.2.0",
    .install_id = "0123456789abcdef0123456789abcdef",
};

test "event JSON" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeEvent(&w, test_app, &.{ "command", "ok", "count" }, .{
        .name = "command_run",
        .properties = &.{
            .{ .key = "command", .value = .{ .string = "cfg get" } },
            .{ .key = "ok", .value = .{ .bool = true } },
            .{ .key = "count", .value = .{ .int = -3 } },
        },
    }, .fromNanoseconds(1_791_799_200 * std.time.ns_per_s));
    var expected_buffer: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buffer,
        "{{\"event\":\"command_run\",\"anonymous_id\":\"{s}\",\"app\":\"snek\"," ++
            "\"version\":\"0.2.0\",\"os\":\"{t}\",\"arch\":\"{t}\"," ++
            "\"time\":\"2026-10-12T10:00:00Z\"," ++
            "\"properties\":{{\"command\":\"cfg get\",\"ok\":true,\"count\":-3}}}}\n",
        .{ &anonymousId("snek", test_app.install_id), builtin.os.tag, builtin.cpu.arch },
    );
    try testing.expectEqualStrings(expected, w.buffered());
    try testing.expect(std.mem.indexOf(u8, w.buffered(), test_app.install_id) == null);
}

fn oneProperty(key: []const u8, value: Value) [1]Property {
    return .{.{ .key = key, .value = value }};
}

test "allow-list and privacy rules" {
    const allowed: []const []const u8 = &.{ "command", "shell" };
    const cwd = oneProperty("cwd", .{ .int = 1 });
    const cwd_event: Event = .{ .name = "x", .properties = &cwd };
    try testing.expectError(error.PropertyNotAllowed, validate(test_app, allowed, cwd_event));
    const unsafe = [_][]const u8{ "/home/ann", "C:\\Users", "ann@host", "~ann", "a\nb" };
    for (unsafe) |text| {
        const properties = oneProperty("command", .{ .string = text });
        const event: Event = .{ .name = "x", .properties = &properties };
        try testing.expectError(error.ValueNotAllowed, validate(test_app, allowed, event));
    }
    for ([_][]const u8{ "Bad Name", "", "dash-ed" }) |name| {
        try testing.expectError(error.InvalidName, validate(test_app, allowed, .{ .name = name }));
    }
    const upper = oneProperty("Command", .{ .int = 1 });
    const upper_event: Event = .{ .name = "x", .properties = &upper };
    try testing.expectError(error.InvalidName, validate(test_app, allowed, upper_event));

    var long: [max_value_len + 1]u8 = undefined;
    @memset(&long, 'a');
    const too_long = oneProperty("shell", .{ .string = &long });
    const longest = oneProperty("shell", .{ .string = long[1..] });
    try testing.expectError(error.ValueNotAllowed, validate(test_app, allowed, .{
        .name = "x",
        .properties = &too_long,
    }));
    try validate(test_app, allowed, .{ .name = "x", .properties = &longest });

    var bad_app = test_app;
    bad_app.install_id = "0123456789ABCDEF0123456789ABCDEF";
    try testing.expectError(error.InvalidInstallId, validate(bad_app, allowed, .{ .name = "x" }));

    // A refused event writes nothing.
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const refused: Event = .{ .name = "x", .properties = &longest };
    const result = writeEvent(&w, test_app, &.{}, refused, null);
    try testing.expectError(error.PropertyNotAllowed, result);
    try testing.expectEqual(0, w.buffered().len);
}

test "install ids and anonymous ids" {
    const id = newInstallId(testing.io);
    try testing.expect(validInstallId(&id));
    try testing.expect(!std.mem.eql(u8, &id, &newInstallId(testing.io)));
    const anon = anonymousId("snek", &id);
    try testing.expect(validInstallId(&anon));
    try testing.expectEqualSlices(u8, &anon, &anonymousId("snek", &id));
    try testing.expect(!std.mem.eql(u8, &anon, &anonymousId("other", &id)));
}

test "send refuses without an enabled decision" {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    const result = send(&client, .no_consent, "http://127.0.0.1:9/", "{}");
    try testing.expectError(error.TelemetryDisabled, result);
}
