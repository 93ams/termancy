//! A countdown: time left until a timeout, which it says when it has passed. Started and
//! stopped by the model that embeds it (run alone, it starts at once, space stops and
//! starts it, and it quits at the timeout).
//!
//! ```zig
//! var timer: Timer = .{ .timeout = .fromSeconds(30) };
//! // in start: return timer.start();
//! // in update: return timer.update(msg);
//! if (timer.timedOut()) giveUp();
//! ```

const std = @import("std");
const tui = @import("tui");
const stopwatch = @import("stopwatch.zig");
const Writer = std.Io.Writer;
const Duration = std.Io.Duration;

const Timer = @This();

/// How long to count down from.
timeout: Duration,
/// The time left.
remaining: ?Duration = null,
running: bool = false,
interval: Duration = .fromSeconds(1),
tick_id: u32 = 0x5449_4d52, // "TIMR"
/// Run alone: space starts and stops, q quits, and it quits at the timeout.
keys: bool = true,
style: tui.Style = .{},

/// What is left: `remaining`, or all of `timeout` before the first tick.
pub fn left(t: *const Timer) Duration {
    return t.remaining orelse t.timeout;
}

pub fn timedOut(t: *const Timer) bool {
    return t.left().nanoseconds <= 0;
}

/// Starts counting down; returns the first tick.
pub fn start(t: *Timer) tui.Cmd {
    if (t.running or t.timedOut()) return .none;
    t.running = true;
    return .tick(t.interval, t.tick_id);
}

pub fn stop(t: *Timer) void {
    t.running = false;
}

pub fn toggle(t: *Timer) tui.Cmd {
    if (t.running) {
        t.stop();
        return .none;
    }
    return t.start();
}

pub fn update(t: *Timer, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .tick => |id| if (id == t.tick_id and t.running) {
            const after = t.left().nanoseconds - t.interval.nanoseconds;
            t.remaining = .fromNanoseconds(@max(after, 0));
            if (t.timedOut()) {
                t.running = false;
                return if (t.keys) .quit else .none;
            }
            return .tick(t.interval, t.tick_id);
        },
        .key => |key| if (t.keys) {
            if (key.matches("space")) return t.toggle();
            if (key.matches("q") or key.matches("esc")) return .quit;
        },
        else => {},
    }
    return .none;
}

pub fn view(t: *const Timer, w: *Writer) Writer.Error!void {
    var buffer: [32]u8 = undefined;
    var text: Writer = .fixed(&buffer);
    stopwatch.writeDuration(&text, t.left()) catch {};
    try t.style.paint(w, text.buffered());
}

const testing = std.testing;

test "it counts down and quits at the timeout" {
    var d: tui.testing.Driver(Timer) = try .init(
        testing.allocator,
        .{ .timeout = .fromSeconds(3) },
        .{},
    );
    defer d.deinit();
    try d.expectFrame("3s");
    try d.advance(.fromSeconds(1));
    try d.expectFrame("2s");
    try d.advance(.fromSeconds(2));
    try testing.expect(d.done());
    try testing.expect(d.model().timedOut());
}
