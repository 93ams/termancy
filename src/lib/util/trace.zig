//! W3C Trace Context: the `traceparent` header, and a small step timer.
//!
//! This is the canonical implementation in the tree. It is app-agnostic and
//! lives here because both the CLI and the message bus need the same wire
//! format and neither should own it.
//!
//! Found duplicated: the message bus carried a `TraceContext` with a `toW3C`
//! serializer (generic, correct, tested, and referenced by nothing else), while
//! `src/lib/framework` carried a second, stringly-typed `TraceParent` that emitted the
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
    /// `src/lib/framework` seeded a PRNG from the monotonic clock, which makes trace IDs
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
/// The POSIX half used to call `std.posix.clock_gettime`, which Zig 0.16 does
/// not expose - the same class of rot as the rest of ROADMAP B-6, and it was
/// found the same way: not by reading the file, but by compiling it for Linux.
/// It also read `.tv_sec`/`.tv_nsec`, which is the *POSIX* spelling: on Linux
/// both `std.c.timespec` and `std.os.linux.timespec` name the fields `sec` and
/// `nsec`, so that line could never have compiled. A comment claiming a defect
/// is not a working branch, which is exactly why B-6 was open for so long.
///
/// `std.c` is used only where a libc is actually linked, because naming `std.c`
/// at all is a build error without `-lc`. This repository's artifacts do not
/// declare `link_libc` (they are static musl), so the Linux path is the syscall
/// layer - which needs no libc and is what `std.posix.system` resolves to there
/// anyway.
///
/// A clock that cannot be read yields 0 rather than an error: this is a coarse
/// duration for telemetry, and a caller that cannot measure must still record
/// the event.
pub fn getMonotonicMs() u64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            pub extern "kernel32" fn GetTickCount64() u64;
        };
        return kernel32.GetTickCount64();
    } else if (builtin.os.tag == .linux) {
        // No libc needed, so this branch is correct for both static musl and a
        // libc-linked build; the field names below are the Linux ones.
        comptime std.debug.assert(@hasField(std.os.linux.timespec, "sec"));
        comptime std.debug.assert(@hasField(std.os.linux.timespec, "nsec"));

        var ts: std.os.linux.timespec = undefined;
        if (std.posix.errno(std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
        std.debug.assert(ts.sec >= 0);
        std.debug.assert(ts.nsec >= 0);
        const ms = @as(u64, @intCast(ts.sec)) * 1000 +
            @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
        return ms;
    } else if (builtin.link_libc) {
        var ts: std.c.timespec = undefined;
        if (std.posix.errno(std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
        std.debug.assert(ts.sec >= 0);
        std.debug.assert(ts.nsec >= 0);
        const ms = @as(u64, @intCast(ts.sec)) * 1000 +
            @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
        return ms;
    } else {
        // A POSIX target with no syscall wrapper and no libc. Reported by
        // returning 0 rather than by failing to compile, because a build error
        // here would take out every caller of a coarse telemetry clock.
        return 0;
    }
}

test "TraceContext serializes to a W3C traceparent" {
    const ctx = TraceContext.init(@as([16]u8, @splat(0x01)), @as([8]u8, @splat(0x02)), true);
    var buf: [64]u8 = undefined;
    const written = try ctx.toW3C(&buf);

    try std.testing.expectEqualStrings(
        "00-01010101010101010101010101010101-0202020202020202-01",
        written,
    );
    try std.testing.expectEqual(@as(usize, header_length), written.len);
}

test "TraceContext respects the sampled flag" {
    const ctx = TraceContext.init(@as([16]u8, @splat(0xAB)), @as([8]u8, @splat(0xCD)), false);
    var buf: [header_length]u8 = undefined;
    const written = ctx.headerInto(&buf);

    try std.testing.expect(std.mem.endsWith(u8, written, "-00"));
    try std.testing.expectEqual(@as(usize, header_length), written.len);
}

test "TraceContext rejects a short buffer" {
    const ctx = TraceContext.init(@as([16]u8, @splat(0)), @as([8]u8, @splat(0)), true);
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

test "the monotonic clock advances, and never comes back as a negative" {
    // This test exists because `getMonotonicMs` had none, and that is why its
    // POSIX branch sat on two removed APIs without anyone noticing. It is called
    // for real - `profiler.zig` times with it and `trace_parent.zig` seeds its
    // PRNG from it - so a missing test was the whole of the gap.
    //
    // Both branches return milliseconds since some epoch (boot, on Windows and
    // for `CLOCK_MONOTONIC`), so the assertions are the shape of the value
    // rather than a particular magnitude: the negative reading is what a sign
    // error produces, and the upper bound rejects a nanosecond value or a
    // wrapping somewhere in the conversion.
    const first = getMonotonicMs();
    const second = getMonotonicMs();

    try std.testing.expect(first <= second);
    try std.testing.expect(second < 1_000_000_000_000_000);
}
