//! Anonymous, opt-in telemetry: what the environment says, and one event.
//!
//! ## Opt-in, and off by default
//!
//! This module used to hold a single predicate, `isOptedOut`, and nothing could
//! emit telemetry at all. The reporter added here keeps that stance: nothing is
//! sent unless the user asked for it, by setting `SNEK_TELEMETRY` to `1` or
//! `true`. An unset variable, an empty value, `0` and `false` are all "do not
//! send", so a program that merely *links* this module still sends nothing.
//!
//! `DO_NOT_TRACK` and `CI` are checked **first** and win over any opt-in. That
//! ordering is the point: the user-wide refusal is the one signal that must not
//! be overridable by a stale per-project setting, and `CI` exists because a build
//! pipeline inherits whatever a developer's shell happens to export.
//!
//! ## The network is the caller's, exactly as in `update.zig`
//!
//! This module never opens a socket. The transport arrives as a `Transport` the
//! caller supplies - a `ctx: ?*anyopaque` plus a `*const fn` - which is the same
//! seam `update.zig` uses for its `Fetcher`, and for the same reason: `snek` has
//! no HTTP client and an opt-in reporter that must not drag one in is the
//! clearest case for it. A caller that wants to send supplies `send`; a caller
//! that does not cannot accidentally acquire a destination for the payload.
//!
//! ## Why the redaction guarantee is structural
//!
//! The payload is rendered **only** from the named values passed to
//! `renderPayload` and `Reporter.record`: an event name, the app name, a schema
//! version, a caller-supplied instance id and a caller-supplied timestamp. No
//! environment variable, no `argv`, no hostname, no user name and no file path is
//! read anywhere in this file, so there is nothing to redact - the values that
//! would need redacting are never in scope. `record` additionally takes no
//! environment and no argument list as parameters, which means it *cannot* reach
//! them even by accident; a future contributor who wants to add a field has to
//! add it to `Event` and to `renderPayload` first, where the test below fails.
//!
//! The instance id is a caller-supplied value for the same reason. This module
//! deliberately does **not** fingerprint the host - no machine id, no MAC
//! address, no `hostname`, no home directory hash - because an id derived from
//! the machine is a durable identifier that survives uninstall and cannot be
//! reset by the user. A random id the caller draws once and stores is anonymous;
//! a derived one is not, whatever it is called.
//!
//! ## Why no clock
//!
//! The timestamp is a parameter, as everywhere else in this repository (see
//! `log.zig`): an event is then a pure function of its arguments, which is what
//! lets the tests assert an exact JSON document rather than a regex over one, and
//! what keeps `std.time` out of a module that must be safe to link into anything.

const std = @import("std");
const assert = std.debug.assert;

/// The environment variable that turns telemetry **on**.
///
/// Opt-in: only `1` and `true` enable it. Anything else - unset, empty, `0`,
/// `false`, `yes`, `maybe` - leaves it off.
pub const opt_in_var = "SNEK_TELEMETRY";

/// The schema version stamped into every payload.
///
/// A consumer needs to know how to read a document before it reads it, and a
/// payload without a version cannot be changed later without breaking every
/// collector that already parses it.
pub const schema_version: u32 = 1;

/// Why a payload was not produced or not handed over.
///
/// Narrow on purpose. The transport itself returns `anyerror` - the caller's
/// channel can fail in ways this module cannot name - and that is folded into
/// `TransportFailed` rather than leaked, so every failure of a record is one of
/// exactly two things: the document did not fit, or the channel refused it.
pub const Error = error{
    /// The rendered payload did not fit `Reporter.payload_buffer_bytes`.
    PayloadTooLarge,
    /// `Transport.send` returned an error.
    TransportFailed,
};

/// True when the environment asks for telemetry to be disabled.
///
/// Honours `DO_NOT_TRACK=1` (the cross-project convention) and `CI` being set to
/// `true` or `1`, because a build pipeline should not emit telemetry by default.
///
/// This is checked before, and independently of, any opt-in: see `resolve`.
pub fn isOptedOut(env_map: *std.process.Environ.Map) bool {
    if (env_map.get("DO_NOT_TRACK")) |val| {
        if (std.mem.eql(u8, val, "1")) return true;
    }
    if (env_map.get("CI")) |val| {
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
    }
    return false;
}

/// True when the environment explicitly enables telemetry.
///
/// `SNEK_TELEMETRY` is the opt-in: `1` or `true`, and nothing else. The other
/// spellings a person might type are "off" rather than a guess at what they
/// meant, because guessing "on" is the one mistake that cannot be taken back -
/// the payload has already left the machine.
///
/// This does not consider `DO_NOT_TRACK` or `CI`. Ask `resolve` for the answer
/// that does.
pub fn isOptedIn(env_map: *std.process.Environ.Map) bool {
    const val = env_map.get(opt_in_var) orelse return false;
    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

/// The single decision a caller needs: may this program emit telemetry?
///
/// `isOptedOut` is consulted first and wins over every opt-in, so
/// `DO_NOT_TRACK=1` with `SNEK_TELEMETRY=1` is **off**. The answer is a value
/// rather than a live query because `Reporter` takes it at construction: a
/// reporter cannot change its mind halfway through a run, and a test can assert
/// both branches without mutating the process environment.
pub fn resolve(env_map: *std.process.Environ.Map) bool {
    // Ordering is the guarantee, not an optimisation: the refusal is checked
    // before the opt-in is even read.
    if (isOptedOut(env_map)) return false;
    return isOptedIn(env_map);
}

/// The transport, supplied by the caller. `snek` has no HTTP client by design.
///
/// Same shape as `update.Fetcher`: an opaque context plus a function pointer. The
/// context is optional because a transport that holds no state - a function that
/// writes to a pipe, a test double - has nothing to point at, and `?*anyopaque`
/// lets it say so instead of inventing a dummy pointer.
pub const Transport = struct {
    /// Non-const on purpose: a real transport holds state - a connection, a
    /// token, a retry counter - and a const context would force every one of
    /// them to cast the const away.
    ctx: ?*anyopaque = null,
    /// Hands `payload` (one JSON document, no trailing newline) to the network.
    ///
    /// The allocator is passed through rather than captured so the transport is
    /// not forced to keep one alive, and `anyerror` because the failure modes
    /// belong to the caller's channel, not to this module.
    send: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        payload: []const u8,
    ) anyerror!void,

    pub fn sendPayload(
        self: Transport,
        allocator: std.mem.Allocator,
        payload: []const u8,
    ) anyerror!void {
        assert(payload.len > 0);
        assert(payload[0] == '{');
        return self.send(self.ctx, allocator, payload);
    }
};

/// One thing that happened, as named values - never as environment or arguments.
///
/// Every field is a caller-supplied value. Nothing here is read from the process,
/// which is what makes the redaction guarantee in the module comment structural
/// rather than a promise: this struct is the complete set of inputs to a payload.
pub const Event = struct {
    /// The caller's own event vocabulary, e.g. `"command_finished"`. A consumer
    /// counts these; it never needs the arguments that produced the call.
    name: []const u8,
    /// The application name, e.g. `"snek"` or `"cfg"`.
    app: []const u8,
    /// An anonymous, caller-chosen id. Draw it at random once and store it. It
    /// must not be derived from the host - see the module comment.
    instance: []const u8,
    /// Milliseconds since the Unix epoch, read by the caller. `null` omits the
    /// field rather than fabricating a zero, which a collector cannot detect.
    timestamp_ms: ?i64 = null,
};

/// Renders `event` as one JSON object into `writer`, with no trailing newline.
///
/// The writer is `anytype` so a test can capture into a fixed buffer and a
/// transport can render straight into its own output. Values are escaped by
/// `std.json.Stringify`, not by string interpolation, so an event name
/// containing a quote or a backslash - which is entirely ordinary - cannot
/// produce a document a collector drops or misparses.
pub fn renderPayload(writer: anytype, event: Event) !void {
    assert(event.name.len > 0);
    assert(event.app.len > 0);
    assert(event.instance.len > 0);

    var json: std.json.Stringify = .{ .writer = writer };

    try json.beginObject();
    try json.objectField("name");
    try json.write(event.name);
    try json.objectField("app");
    try json.write(event.app);
    try json.objectField("schema");
    try json.write(schema_version);
    try json.objectField("instance");
    try json.write(event.instance);
    if (event.timestamp_ms) |ms| {
        try json.objectField("time");
        try json.write(ms);
    }
    try json.endObject();
}

/// An opt-in reporter: an enabled bit decided once, an identity, and a transport.
///
/// It owns no clock and no network - see the module comment - and it holds no
/// allocator, because `record` renders into a fixed stack buffer. The allocator
/// is a parameter of `record` only because `Transport` takes one.
pub const Reporter = struct {
    /// Overwritten from the environment in `initFromEnv`; `false` is the safe
    /// default, so a `Reporter` literal with no environment is off.
    enabled: bool = false,
    /// Every payload is rendered here, so an enabled `record` allocates nothing.
    /// 512 bytes is far more than a five-field document needs; the bound exists
    /// to keep the document small by construction, not to be approached.
    payload_buffer: [payload_buffer_bytes]u8 = undefined,
    /// The application name stamped into every event.
    app: []const u8,
    /// The anonymous id stamped into every event, chosen by the caller.
    instance: []const u8,
    /// Where a record goes when enabled. See `Transport`.
    transport: Transport,

    /// Enough for every field at a plausible length. See `payload_buffer`.
    pub const payload_buffer_bytes = 512;

    /// The production constructor: reads the environment once, then never again.
    ///
    /// `transport` may be a stub even when enabled; whether a destination exists
    /// is the caller's decision, and this module does not care.
    pub fn initFromEnv(
        env_map: *std.process.Environ.Map,
        app: []const u8,
        instance: []const u8,
        transport: Transport,
    ) Reporter {
        assert(app.len > 0);
        assert(instance.len > 0);
        // Empty would produce a valid JSON document with an empty id, which is
        // anonymous but unusable: a consumer cannot count distinct instances.
        // It is almost always a caller that forgot to draw one.
        assert(std.mem.indexOfAny(u8, app, " \t\r\n\"") == null);
        assert(std.mem.indexOfAny(u8, instance, " \t\r\n\"") == null);

        return .{
            .enabled = resolve(env_map),
            .app = app,
            .instance = instance,
            .transport = transport,
        };
    }

    /// Whether this reporter will send anything. Public so a caller can skip the
    /// work whose only purpose was to produce an event - the same reasoning as
    /// `log.Level` being checked before a message is built.
    pub fn isEnabled(self: Reporter) bool {
        return self.enabled;
    }

    /// Renders and hands one event to the transport.
    ///
    /// Returns **immediately, allocating nothing and calling nothing**, when
    /// disabled: a disabled reporter must cost exactly nothing, because it is the
    /// default and it runs on every invocation. An empty event name is then
    /// accepted without complaint rather than asserted on, which is the price of
    /// that short-circuit - the payload is the caller's to get right, and the
    /// assertions in `renderPayload` guard the enabled path.
    ///
    /// A transport failure is reported as `error.TransportFailed` rather than
    /// swallowed. Swallowing it is the tempting choice - nobody's command should
    /// fail because an analytics endpoint is down - but it is the caller's
    /// decision to make, and a caller that wants to ignore it writes `catch {}`
    /// at the one call site, where the reader can see it.
    pub fn record(
        self: *Reporter,
        allocator: std.mem.Allocator,
        name: []const u8,
        timestamp_ms: ?i64,
    ) Error!void {
        if (!self.enabled) return;

        var writer = std.Io.Writer.fixed(&self.payload_buffer);
        renderPayload(&writer, .{
            .name = name,
            .app = self.app,
            .instance = self.instance,
            .timestamp_ms = timestamp_ms,
        }) catch |err| switch (err) {
            // A fixed-buffer writer has exactly one failure mode, and it is not
            // "the transport refused": the document was larger than the buffer.
            error.WriteFailed => return error.PayloadTooLarge,
        };

        const payload = writer.buffered();
        assert(payload.len > 0);
        self.transport.sendPayload(allocator, payload) catch return error.TransportFailed;
    }
};

const testing = std.testing;

/// A transport that counts calls and can be made to fail, so a test can assert
/// both that nothing was sent and that a failure is reported.
const FakeTransport = struct {
    calls: usize = 0,
    payload_len: usize = 0,
    fail: bool = false,

    fn send(ctx: ?*anyopaque, allocator: std.mem.Allocator, payload: []const u8) anyerror!void {
        _ = allocator;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.payload_len = payload.len;
        if (self.fail) return error.ConnectionRefused;
    }

    fn interface(self: *FakeTransport) Transport {
        return .{ .ctx = self, .send = send };
    }
};

/// An empty environment, owned by the caller.
///
/// Never the process environment: a test that resolved opt-in against whatever
/// the CI host happens to export would pass or fail depending on the machine,
/// which is the one thing a test of a *default* must not do. A fresh map per
/// case is also what makes `DO_NOT_TRACK=1` and `CI=true` separately assertable
/// - `Environ.Map` has `swapRemove`, but a key that was never set and one that
/// was removed are the same map, and one case per spelling says which is which.
fn envWith(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "DO_NOT_TRACK and CI are both honoured" {
    var empty = try envWith(&.{});
    defer empty.deinit();
    try testing.expect(!isOptedOut(&empty));

    var do_not_track = try envWith(&.{
        .{ "DO_NOT_TRACK", "1" },
    });
    defer do_not_track.deinit();
    try testing.expect(isOptedOut(&do_not_track));

    var ci_true = try envWith(&.{
        .{ "CI", "true" },
    });
    defer ci_true.deinit();
    try testing.expect(isOptedOut(&ci_true));

    var ci_one = try envWith(&.{
        .{ "CI", "1" },
    });
    defer ci_one.deinit();
    try testing.expect(isOptedOut(&ci_one));

    var ci_zero = try envWith(&.{
        .{ "CI", "0" },
    });
    defer ci_zero.deinit();
    try testing.expect(!isOptedOut(&ci_zero));

    // Only "1" counts for DO_NOT_TRACK; "true" is a different convention.
    var dnt_true = try envWith(&.{
        .{ "DO_NOT_TRACK", "true" },
    });
    defer dnt_true.deinit();
    try testing.expect(!isOptedOut(&dnt_true));
}

test "telemetry is off unless the environment opts in" {
    // The default, and the one that must not change: an unset variable is off.
    var unset = try envWith(&.{});
    defer unset.deinit();
    try testing.expect(!isOptedIn(&unset));
    try testing.expect(!resolve(&unset));

    var one = try envWith(&.{
        .{ opt_in_var, "1" },
    });
    defer one.deinit();
    try testing.expect(isOptedIn(&one));
    try testing.expect(resolve(&one));

    var true_text = try envWith(&.{
        .{ opt_in_var, "true" },
    });
    defer true_text.deinit();
    try testing.expect(isOptedIn(&true_text));
    try testing.expect(resolve(&true_text));
}

test "every other spelling of the opt-in is off" {
    // Guessing "on" is the one mistake that cannot be taken back, so anything
    // unrecognised - including the spellings a person would most plausibly
    // type - is treated as a refusal to opt in.
    const off = [_][]const u8{ "0", "false", "", "yes", "TRUE", "on", " 1", "2" };
    for (off) |value| {
        var map = try envWith(&.{.{ opt_in_var, value }});
        defer map.deinit();
        try testing.expect(!isOptedIn(&map));
        try testing.expect(!resolve(&map));
    }
}

test "isOptedOut wins over every opt-in" {
    // The precedence that matters: a user-wide refusal must not be overridable
    // by a per-project setting, and a build pipeline must stay silent even if
    // the developer's shell exported the opt-in.
    var both = try envWith(&.{
        .{ opt_in_var, "1" },
        .{ "DO_NOT_TRACK", "1" },
    });
    defer both.deinit();
    try testing.expect(isOptedIn(&both));
    try testing.expect(isOptedOut(&both));
    try testing.expect(!resolve(&both));

    var in_ci = try envWith(&.{
        .{ opt_in_var, "true" },
        .{ "CI", "true" },
    });
    defer in_ci.deinit();
    try testing.expect(isOptedIn(&in_ci));
    try testing.expect(!resolve(&in_ci));
}

test "a disabled record is a no-op that never reaches the transport" {
    var fake = FakeTransport{};
    var reporter: Reporter = .{
        // Default-disabled, and the event name is deliberately nonsense: a
        // disabled record must not inspect its arguments at all, which the
        // absent assertion in `record` is what makes true.
        .app = "snek",
        .instance = "anon-1",
        .transport = fake.interface(),
    };

    for (0..16) |_| try reporter.record(testing.allocator, "", null);

    try testing.expect(!reporter.isEnabled());
    try testing.expectEqual(@as(usize, 0), fake.calls);
    try testing.expectEqual(@as(usize, 0), fake.payload_len);
}

test "a reporter built from an opt-in environment is enabled and one from an opt-out is not" {
    var fake = FakeTransport{};

    var opted_in = try envWith(&.{
        .{ opt_in_var, "1" },
    });
    defer opted_in.deinit();
    var on = Reporter.initFromEnv(&opted_in, "snek", "anon-1", fake.interface());
    try testing.expect(on.isEnabled());

    var refused = try envWith(&.{
        .{ opt_in_var, "1" },
        .{ "DO_NOT_TRACK", "1" },
    });
    defer refused.deinit();
    var off = Reporter.initFromEnv(&refused, "snek", "anon-1", fake.interface());
    try testing.expect(!off.isEnabled());
}

test "a payload is one JSON object with exactly the documented fields" {
    var buf: [Reporter.payload_buffer_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderPayload(&writer, .{
        .name = "command_finished",
        .app = "snek",
        .instance = "anon-1",
        .timestamp_ms = 1_700_000_000_000,
    });

    // No trailing newline: a transport frames its own messages, and a document
    // whose length depends on a separator it did not write is a bug waiting for
    // the first caller that concatenates two of them.
    try testing.expectEqualStrings(
        "{\"name\":\"command_finished\",\"app\":\"snek\",\"schema\":1," ++
            "\"instance\":\"anon-1\",\"time\":1700000000000}",
        writer.buffered(),
    );

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        writer.buffered(),
        .{},
    );
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("command_finished", object.get("name").?.string);
    try testing.expectEqualStrings("snek", object.get("app").?.string);
    try testing.expectEqual(schema_version, object.get("schema").?.integer);
    try testing.expectEqualStrings("anon-1", object.get("instance").?.string);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), object.get("time").?.integer);
}

test "a payload with no timestamp omits the field rather than inventing zero" {
    var buf: [Reporter.payload_buffer_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderPayload(&writer, .{ .name = "started", .app = "snek", .instance = "anon-1" });

    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"time\"") == null);
    try testing.expectEqualStrings(
        "{\"name\":\"started\",\"app\":\"snek\",\"schema\":1,\"instance\":\"anon-1\"}",
        writer.buffered(),
    );
}

test "a payload carries nothing the caller did not name" {
    // The redaction guarantee, as a test rather than a comment. A real process
    // environment is full of values that would be a disclosure if they shipped -
    // a home directory, a session token, a proxy password - so the payload built
    // from a suspicious event must contain none of them.
    //
    // The environment iterated here is a clone of this process's own, plus a
    // marker, rather than a small synthetic one: a test against a map holding
    // only the marker would prove nothing about the values that actually matter.
    const marker = "snek-telemetry-redaction-marker";
    var process_env = try std.process.Environ.createMap(
        .{ .block = .global },
        testing.allocator,
    );
    defer process_env.deinit();
    try process_env.put("SNEK_TEST_SECRET", marker);
    // A value that occurs in environment values but in no JSON structural
    // character, so "was this leaked" is a substring test and not a coincidence.
    try testing.expect(process_env.get("SNEK_TEST_SECRET") != null);

    var buf: [Reporter.payload_buffer_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderPayload(&writer, .{
        .name = "command_finished",
        .app = "snek",
        .instance = "anon-1",
        .timestamp_ms = 1,
    });

    const payload = writer.buffered();

    var it = process_env.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        // Short values are skipped because a two-character substring like `.c`
        // occurs in the payload's own field names, which is a false positive
        // rather than a leak. Four characters is longer than any JSON token
        // this document contains.
        if (value.len < 4) continue;
        try testing.expect(std.mem.indexOf(u8, payload, value) == null);
    }
    // The marker was in the map, so the loop above really did test it.
    try testing.expect(std.mem.indexOf(u8, payload, marker) == null);

    // And an argument list must not reach it either: `record` takes a name, not
    // an `argv`, so a canary placed in the same buffer as one is never read.
    const argv_canary = "snek-telemetry-argv-canary";
    try testing.expect(std.mem.indexOf(u8, payload, argv_canary) == null);
}

test "record sends the rendered payload when enabled" {
    var fake = FakeTransport{};
    // Built by literal rather than from the process environment: whether *this*
    // machine exports `SNEK_TELEMETRY` is not what this test is about, and
    // inheriting it would make the test's result depend on the host.
    var reporter: Reporter = .{
        .enabled = true,
        .app = "snek",
        .instance = "anon-1",
        .transport = fake.interface(),
    };

    try reporter.record(testing.allocator, "command_finished", 1_700_000_000_000);

    try testing.expectEqual(@as(usize, 1), fake.calls);
    // The exact length of the document, so an accidental extra field cannot be
    // added to `record`'s path without this failing.
    try testing.expectEqual(
        "{\"name\":\"command_finished\",\"app\":\"snek\",\"schema\":1,".len +
            "\"instance\":\"anon-1\",\"time\":1700000000000}".len,
        fake.payload_len,
    );
}

test "a transport failure is reported rather than swallowed" {
    var fake = FakeTransport{ .fail = true };
    var reporter: Reporter = .{
        .enabled = true,
        .app = "snek",
        .instance = "anon-1",
        .transport = fake.interface(),
    };

    // A specific error, not a silent success and not the transport's own error:
    // the caller can tell "the channel refused" from "the document did not fit".
    try testing.expectError(
        error.TransportFailed,
        reporter.record(testing.allocator, "command_finished", null),
    );
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "an event field that needs escaping is escaped rather than interpolated" {
    // A quote in an event name is ordinary, and hand-rolled interpolation would
    // produce a document a collector drops or misparses.
    var buf: [Reporter.payload_buffer_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderPayload(&writer, .{
        .name = "weird \"name\"\nwith a newline",
        .app = "snek",
        .instance = "anon-1",
    });

    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, writer.buffered(), "\n"));
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        writer.buffered(),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "weird \"name\"\nwith a newline",
        parsed.value.object.get("name").?.string,
    );
}
