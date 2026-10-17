//! W3C Trace Context (https://www.w3.org/TR/trace-context/): the `traceparent` header and
//! the `tracestate` passthrough, new and child spans, and propagation to subprocesses through
//! the `TRACEPARENT` and `TRACESTATE` environment variables.
//!
//! ```zig
//! const incoming = trace.Context.fromEnviron(environ);
//! const span = if (incoming) |ctx| ctx.child(io) else trace.Context.root(io, true);
//! try span.toEnviron(&child_environ); // the subprocess continues the trace
//! ```
//!
//! Parsing follows the spec: lower-case hex only, all-zero ids invalid, version `ff`
//! invalid, and a future version accepted when its first four fields parse. Output is always
//! version `00`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The HTTP header name.
pub const header = "traceparent";
/// The HTTP header carrying vendor state.
pub const state_header = "tracestate";
/// The environment variable a subprocess reads its parent span from.
pub const env_var = "TRACEPARENT";
/// The environment variable carrying `tracestate`.
pub const state_env_var = "TRACESTATE";

/// `tracestate` longer than this is dropped rather than propagated (the spec's limit).
pub const max_state_len = 512;
/// The most `tracestate` members the spec allows.
pub const max_state_members = 32;

/// 16 bytes identifying the whole trace.
pub const TraceId = [16]u8;
/// 8 bytes identifying one span.
pub const SpanId = [8]u8;

/// Returned by `TraceParent.parse`.
pub const ParseError = error{InvalidTraceParent};

/// A parsed `traceparent` value.
pub const TraceParent = struct {
    /// The version read; formatting always writes `00`.
    version: u8 = 0,
    trace_id: TraceId,
    parent_id: SpanId,
    flags: u8,

    /// The length of a version-00 `traceparent`.
    pub const len = 55;
    /// The `sampled` bit of `flags`.
    pub const flag_sampled: u8 = 0x01;

    /// Parses and validates a `traceparent` value.
    pub fn parse(text: []const u8) ParseError!TraceParent {
        if (text.len < len) return error.InvalidTraceParent;
        const version = try hexByte(text[0..2]);
        if (version == 0xff) return error.InvalidTraceParent;
        // Version 00 has exactly four fields; a later version may append more after a dash.
        if (version == 0 and text.len != len) return error.InvalidTraceParent;
        if (text.len > len and text[len] != '-') return error.InvalidTraceParent;
        if (text[2] != '-' or text[35] != '-' or text[52] != '-') return error.InvalidTraceParent;
        const result: TraceParent = .{
            .version = version,
            .trace_id = try hexArray(16, text[3..35]),
            .parent_id = try hexArray(8, text[36..52]),
            .flags = try hexByte(text[53..55]),
        };
        if (isZero(&result.trace_id) or isZero(&result.parent_id)) return error.InvalidTraceParent;
        return result;
    }

    /// Whether the caller upstream recorded this trace.
    pub fn sampled(tp: TraceParent) bool {
        return tp.flags & flag_sampled != 0;
    }

    /// The version-00 text: `00-<trace id>-<parent id>-<flags>`.
    pub fn toText(tp: TraceParent) [len]u8 {
        var out: [len]u8 = undefined;
        var w: Io.Writer = .fixed(&out);
        tp.format(&w) catch unreachable; // `out` is exactly `len` bytes.
        return out;
    }

    /// For `{f}`.
    pub fn format(tp: TraceParent, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("00-{x}-{x}-{x:0>2}", .{ &tp.trace_id, &tp.parent_id, tp.flags });
    }

    /// A new span in the same trace, with this one as its parent. Flags are kept.
    pub fn child(tp: TraceParent, io: Io) TraceParent {
        return .{ .trace_id = tp.trace_id, .parent_id = newSpanId(io), .flags = tp.flags };
    }

    /// A new trace with a new root span.
    pub fn root(io: Io, sample: bool) TraceParent {
        return .{
            .trace_id = newTraceId(io),
            .parent_id = newSpanId(io),
            .flags = if (sample) flag_sampled else 0,
        };
    }
};

/// A random trace id; never all zeros.
pub fn newTraceId(io: Io) TraceId {
    return randomNonZero(16, io);
}

/// A random span id; never all zeros.
pub fn newSpanId(io: Io) SpanId {
    return randomNonZero(8, io);
}

fn randomNonZero(comptime n: usize, io: Io) [n]u8 {
    var bytes: [n]u8 = undefined;
    while (true) {
        io.random(&bytes);
        if (!isZero(&bytes)) return bytes;
    }
}

fn isZero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

fn hexDigit(c: u8) ParseError!u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        else => error.InvalidTraceParent, // Upper case is invalid too.
    };
}

fn hexByte(pair: *const [2]u8) ParseError!u8 {
    return @as(u8, try hexDigit(pair[0])) << 4 | try hexDigit(pair[1]);
}

fn hexArray(comptime n: usize, digits: *const [2 * n]u8) ParseError![n]u8 {
    var out: [n]u8 = undefined;
    for (&out, 0..) |*byte, i| byte.* = try hexByte(digits[2 * i ..][0..2]);
    return out;
}

/// Whether `text` is a `tracestate` worth propagating: at most `max_state_len` bytes and
/// `max_state_members` comma-separated `key=value` members of printable ASCII. Keys and
/// values are opaque to this module; their vendor grammar is not checked.
pub fn validState(text: []const u8) bool {
    if (text.len > max_state_len) return false;
    var members: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const member = std.mem.trim(u8, raw, " \t");
        if (member.len == 0) continue; // Empty members are allowed and ignored.
        members += 1;
        if (members > max_state_members) return false;
        const eq = std.mem.indexOfScalar(u8, member, '=') orelse return false;
        if (eq == 0 or eq == member.len - 1) return false;
        for (member) |c| if (c < 0x20 or c > 0x7e) return false;
    }
    return true;
}

/// A span to continue: its `traceparent` and the opaque `tracestate` passed along with it.
pub const Context = struct {
    parent: TraceParent,
    /// Borrowed; empty when there is none.
    state: []const u8 = "",

    /// A new trace.
    pub fn root(io: Io, sample: bool) Context {
        return .{ .parent = .root(io, sample) };
    }

    /// A child span carrying the same state.
    pub fn child(ctx: Context, io: Io) Context {
        return .{ .parent = ctx.parent.child(io), .state = ctx.state };
    }

    /// Reads the headers' values. An invalid `traceparent` gives null (start a new trace);
    /// an invalid `tracestate` is dropped.
    pub fn fromHeaders(traceparent: ?[]const u8, tracestate: ?[]const u8) ?Context {
        const parent = TraceParent.parse(traceparent orelse return null) catch return null;
        const state = tracestate orelse "";
        return .{ .parent = parent, .state = if (validState(state)) state else "" };
    }

    /// Reads `TRACEPARENT` and `TRACESTATE`. The state borrows from `environ`.
    pub fn fromEnviron(environ: *const std.process.Environ.Map) ?Context {
        return fromHeaders(environ.get(env_var), environ.get(state_env_var));
    }

    /// Sets `TRACEPARENT`, and `TRACESTATE` when there is state (removing a stale one
    /// otherwise), for a subprocess.
    pub fn toEnviron(ctx: Context, environ: *std.process.Environ.Map) Allocator.Error!void {
        const value = ctx.parent.toText();
        try environ.put(env_var, &value);
        if (ctx.state.len > 0) {
            try environ.put(state_env_var, ctx.state);
        } else {
            _ = environ.swapRemove(state_env_var);
        }
    }
};

const testing = std.testing;

const spec_example = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

test "parse and format the spec example" {
    const tp = try TraceParent.parse(spec_example);
    try testing.expectEqual(0, tp.version);
    try testing.expectEqualSlices(u8, &.{ 0x4b, 0xf9, 0x2f, 0x35 }, tp.trace_id[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xf0, 0x67, 0xaa }, tp.parent_id[0..4]);
    try testing.expect(tp.sampled());
    try testing.expectEqualStrings(spec_example, &tp.toText());

    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{tp});
    try testing.expectEqualStrings(spec_example, w.buffered());

    const unsampled = try TraceParent.parse(spec_example[0 .. TraceParent.len - 1] ++ "0");
    try testing.expect(!unsampled.sampled());
    // Unknown flag bits are accepted and kept.
    const other = try TraceParent.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-09");
    try testing.expectEqual(0x09, other.flags);
}

test "invalid traceparent values" {
    const bad = [_][]const u8{
        "",
        "00",
        // All-zero trace id and parent id.
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
        // Version ff, non-hex version.
        "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "0g-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        // Upper case anywhere.
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00F067AA0BA902B7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0A",
        // Wrong lengths.
        "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e47366-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-011",
        // Version 00 with trailing data.
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra",
        // Wrong separators.
        "00_4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736_00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7_01",
        // Future version: more fields must follow a dash.
        "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x",
        " 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    };
    for (bad) |text| try testing.expectError(error.InvalidTraceParent, TraceParent.parse(text));
}

test "future versions parse and format as 00" {
    const tp = try TraceParent.parse("cc" ++ spec_example[2..] ++ "-what-the-future-holds");
    try testing.expectEqual(0xcc, tp.version);
    try testing.expectEqualStrings(spec_example, &tp.toText());
    const exact = try TraceParent.parse("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    try testing.expectEqual(1, exact.version);
}

test "root and child spans" {
    const io = testing.io;
    const root = TraceParent.root(io, true);
    try testing.expect(root.sampled());
    try testing.expect(!isZero(&root.trace_id) and !isZero(&root.parent_id));
    const reparsed = try TraceParent.parse(&root.toText());
    try testing.expectEqual(root, reparsed);

    const child = root.child(io);
    try testing.expectEqual(root.trace_id, child.trace_id);
    try testing.expectEqual(root.flags, child.flags);
    try testing.expect(!std.mem.eql(u8, &root.parent_id, &child.parent_id));
    try testing.expect(!TraceParent.root(io, false).sampled());
}

test "tracestate validation" {
    try testing.expect(validState(""));
    try testing.expect(validState("rojo=00f067aa0ba902b7,congo=t61rcWkgMzE"));
    try testing.expect(validState("a=1, ,b=2"));
    try testing.expect(!validState("novalue"));
    try testing.expect(!validState("=x"));
    try testing.expect(!validState("x="));
    try testing.expect(!validState("a=\x01"));
    var many: [33 * 4]u8 = undefined;
    for (0..33) |i| @memcpy(many[i * 4 ..][0..4], "k=v,");
    try testing.expect(!validState(&many));
    try testing.expect(validState(many[0 .. 32 * 4]));
    var long: [max_state_len + 1]u8 = undefined;
    @memset(&long, 'a');
    long[1] = '=';
    try testing.expect(!validState(&long));
}

test "propagation through an environ map" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectEqual(null, Context.fromEnviron(&environ));

    try environ.put(env_var, "garbage");
    try testing.expectEqual(null, Context.fromEnviron(&environ));

    try environ.put(env_var, spec_example);
    try environ.put(state_env_var, "rojo=00f067aa0ba902b7");
    const ctx = Context.fromEnviron(&environ).?;
    try testing.expectEqualStrings("rojo=00f067aa0ba902b7", ctx.state);

    const child = ctx.child(testing.io);
    var out: std.process.Environ.Map = .init(testing.allocator);
    defer out.deinit();
    try out.put(state_env_var, "stale=1");
    try child.toEnviron(&out);
    const back = Context.fromEnviron(&out).?;
    try testing.expectEqual(child.parent, back.parent);
    try testing.expectEqualStrings("rojo=00f067aa0ba902b7", back.state);

    try (Context{ .parent = child.parent }).toEnviron(&out);
    try testing.expectEqual(null, out.get(state_env_var));
}

test "fromHeaders drops an invalid tracestate" {
    const ctx = Context.fromHeaders(spec_example, "not valid").?;
    try testing.expectEqualStrings("", ctx.state);
    try testing.expectEqual(null, Context.fromHeaders(null, "a=b"));
}
