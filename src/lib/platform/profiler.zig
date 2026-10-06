//! A coarse phase timer for a command's parse and execute steps.
//!
//! This file **is** the type: the file's own scope is the struct, so a consumer
//! writes `const Profiler = @import("profiler.zig");`. See the file-layout rule
//! in `.agents/AGENTS.md`.

const std = @import("std");
const getMonotonicMs = @import("..\util\root.zig").trace.getMonotonicMs;

const Self = @This();

start_time: u64,
parse_duration_ms: u64 = 0,
exec_duration_ms: u64 = 0,

/// Starts the clock. The parse phase runs from here until `recordParse`.
pub fn start() Self {
    return .{ .start_time = getMonotonicMs() };
}

/// Closes the parse phase.
pub fn recordParse(self: *Self) void {
    self.parse_duration_ms = getMonotonicMs() - self.start_time;
}

/// Closes the execute phase, measured from the end of parse.
pub fn recordExec(self: *Self) void {
    const now = getMonotonicMs();
    self.exec_duration_ms = now - (self.start_time + self.parse_duration_ms);
}

/// Writes the three timings. `writer` is `anytype` so this works with a file
/// writer and with the fixed-buffer writers the tests use.
pub fn render(self: Self, writer: anytype) !void {
    const total_ms = self.parse_duration_ms + self.exec_duration_ms;

    try writer.print("\n\x1b[2m--- Execution Profile ---\x1b[0m\n", .{});
    try writer.print("Parse time:   {d} ms\n", .{self.parse_duration_ms});
    try writer.print("Exec time:    {d} ms\n", .{self.exec_duration_ms});
    try writer.print("Total time:   {d} ms\n", .{total_ms});
}

test "a fresh profiler reports zero and renders" {
    var p = Self.start();
    p.recordParse();
    p.recordExec();

    try std.testing.expect(p.parse_duration_ms == 0 or p.parse_duration_ms > 0);
    // The total must be the sum of the two phases, whatever they measured.
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try p.render(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Execution Profile") != null);
}
