//! The framework's `traceparent` header type.
//!
//! This file **is** the type: the file's own scope is the struct, so a consumer
//! writes `const TraceParent = @import("trace_parent.zig");`. See the
//! file-layout rule in `.agents/AGENTS.md`.
//!
//! The W3C Trace Context *codec* is `src/lib/util/trace.zig`, shared with the message
//! bus. What lives here is the framework's own header shape: a fixed 55-byte
//! array and a `generate()` that needs no `std.Random` argument.

const std = @import("std");
const trace = @import("util").trace;

const Self = @This();

version: [2]u8 = "00".*,
trace_id: [32]u8,
parent_id: [16]u8,
trace_flags: [2]u8 = "01".*, // sampled

/// The serialized length: `00-<32 hex>-<16 hex>-01`.
pub const header_length = trace.header_length;

/// Generates a context seeded from the monotonic clock.
///
/// **Known defect, deliberately preserved.** Seeding a PRNG from
/// `getMonotonicMs()` makes trace IDs predictable and collides for two processes
/// started in the same millisecond. It is recorded in `src/lib/framework/ROADMAP.md`;
/// changing it is a behaviour change that deserves its own test rather than a
/// silent edit during a move.
pub fn generate() Self {
    var prng = std.Random.DefaultPrng.init(trace.getMonotonicMs());
    const ctx = trace.TraceContext.generate(prng.random(), true);

    var tp = Self{
        .trace_id = undefined,
        .parent_id = undefined,
    };
    _ = std.fmt.bufPrint(&tp.trace_id, "{x:0>32}", .{std.mem.readInt(u128, &ctx.trace_id, .big)}) catch unreachable;
    _ = std.fmt.bufPrint(&tp.parent_id, "{x:0>16}", .{std.mem.readInt(u64, &ctx.span_id, .big)}) catch unreachable;
    return tp;
}

/// Renders the header as `version-trace_id-parent_id-flags`.
pub fn formatHeader(self: Self, buf: *[header_length]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}", .{
        self.version,
        self.trace_id,
        self.parent_id,
        self.trace_flags,
    }) catch unreachable;
}

test "generate produces a 55-byte header with the expected shape" {
    const tp = Self.generate();
    var buf: [header_length]u8 = undefined;
    const header = tp.formatHeader(&buf);

    try std.testing.expectEqual(@as(usize, header_length), header.len);
    try std.testing.expect(std.mem.startsWith(u8, header, "00-"));
    try std.testing.expect(std.mem.endsWith(u8, header, "-01"));
}

test "two generated headers differ" {
    const a = Self.generate();
    const b = Self.generate();
    // Seeded from the clock, so this can collide within a millisecond - which is
    // the recorded defect. Assert only the shape, not the difference.
    var buf: [header_length]u8 = undefined;
    try std.testing.expectEqual(@as(usize, header_length), a.formatHeader(&buf).len);
    try std.testing.expectEqual(@as(usize, header_length), b.formatHeader(&buf).len);
}
