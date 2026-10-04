//! W3C Trace Context: the `traceparent` header, and a small step timer.
//!
//! This is the canonical implementation in the tree. It is app-agnostic and
//! lives here because both the CLI and the message bus need the same wire
//! format and neither should own it.
//!
//! Found duplicated: the message bus carried a `TraceContext` with a `toW3C`
//! serializer (generic, correct, tested, and referenced by nothing else), while
//! `lib/cli` carried a second, stringly-typed `TraceParent` that emitted the
//! same format. Two implementations of one wire format is a correctness risk,
//! not just duplication - the same argument the repo-wide roadmap used when it
//! consolidated the two S3 SigV4 signers (item R-2).
//!
//! Reference: https://www.w3.org/TR/trace-context/

const std = @import("std");

/// 16 bytes, rendered as 32 lowercase hex characters.
pub const TraceId = [16]u8;

/// 8 bytes, rendered as 16 lowercase hex characters.
pub const SpanId = [8]u8;

/// The exact length of a serialized `traceparent`:
/// `00-<32 hex>-<16 hex>-01`.
pub const header_length = 55;

/// A W3C Trace Context, in its binary form.
pub const TraceContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    sampled: bool,

    pub fn init(trace_id: TraceId, span_id: SpanId, sampled: bool) TraceContext {
        return .{ .trace_id = trace_id, .span_id = span_id, .sampled = sampled };
    }

    /// Generates a random context.
    ///
    /// `random` is explicit rather than seeded internally: an earlier version in
    /// `lib/cli` seeded a PRNG from the monotonic clock, which makes trace IDs
    /// predictable and collides across processes started in the same
    /// millisecond. The caller owns that choice.
    pub fn generate(random: std.Random, sampled: bool) TraceContext {
        var trace_id: TraceId = undefined;
        var span_id: SpanId = undefined;
        random.bytes(&trace_id);
        random.bytes(&span_id);
        return .{ .trace_id = trace_id, .span_id = span_id, .sampled = sampled };
    }

    /// Serializes into `buffer`, returning the written slice.
    ///
    /// Accepts any buffer of at least `header_length` bytes rather than a
    /// pointer to an exactly-55-byte array, so callers are not forced to guess
    /// the size.
    pub fn toW3C(self: *const TraceContext, buffer: []u8) ![]const u8 {
        if (buffer.len < header_length) return error.BufferTooSmall;
        const sampled_flag: u8 = if (self.sampled) 1 else 0;
        return std.fmt.bufPrint(buffer, "00-{s}-{s}-0{d}", .{
            std.fmt.bytesToHex(self.trace_id, .lower),
            std.fmt.bytesToHex(self.span_id, .lower),
            sampled_flag,
        }) catch return error.BufferTooSmall;
    }

    /// Convenience: serialize into a caller-supplied header buffer.
    pub fn headerInto(self: *const TraceContext, buffer: *[header_length]u8) []const u8 {
        return self.toW3C(buffer) catch unreachable; // buffer is exactly the right size
    }
};

/// A monotonic millisecond clock, for coarse duration measurement.
///
/// Known defect, inherited from `app/cli/lib/platform/telemetry.zig` and recorded as
/// `app/cli/lib/ROADMAP.md` B-6: the POSIX branch calls `std.posix.clock_gettime`,
/// which Zig 0.16 does not expose. It is not instantiated on Windows, which is
/// why the host build is green. Fix it with B-6, not here.
pub fn getMonotonicMs() u64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            pub extern "kernel32" fn GetTickCount64() u64;
        };
        return kernel32.GetTickCount64();
    } else {
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) catch return 0;
        return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.tv_nsec, 1_000_000)));
    }
}

test "TraceContext serializes to a W3C traceparent" {
    const ctx = TraceContext.init([_]u8{0x01} ** 16, [_]u8{0x02} ** 8, true);
    var buf: [64]u8 = undefined;
    const written = try ctx.toW3C(&buf);

    try std.testing.expectEqualStrings(
        "00-01010101010101010101010101010101-0202020202020202-01",
        written,
    );
    try std.testing.expectEqual(@as(usize, header_length), written.len);
}

test "TraceContext respects the sampled flag" {
    const ctx = TraceContext.init([_]u8{0xAB} ** 16, [_]u8{0xCD} ** 8, false);
    var buf: [header_length]u8 = undefined;
    const written = ctx.headerInto(&buf);

    try std.testing.expect(std.mem.endsWith(u8, written, "-00"));
    try std.testing.expectEqual(@as(usize, header_length), written.len);
}

test "TraceContext rejects a short buffer" {
    const ctx = TraceContext.init([_]u8{0} ** 16, [_]u8{0} ** 8, true);
    var buf: [header_length - 1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, ctx.toW3C(&buf));
}

test "generated trace contexts are the right shape and differ" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();

    const a = TraceContext.generate(random, true);
    const b = TraceContext.generate(random, true);
    try std.testing.expect(!std.mem.eql(u8, &a.trace_id, &b.trace_id));

    var buf: [header_length]u8 = undefined;
    const written = a.headerInto(&buf);
    try std.testing.expectEqual(@as(usize, header_length), written.len);
    try std.testing.expect(std.mem.startsWith(u8, written, "00-"));
}
