//! A stopwatch: time counting up while it runs, started, stopped, and reset by the model
//! that embeds it (run alone, it starts at once; space stops and starts it, r resets it).
//!
//! ```zig
//! var watch: Stopwatch = .{};
//! // in start: return watch.start();
//! // in update: return watch.update(msg);
//! try watch.view(w); // 1m02s
//! ```
//!
//! Time is counted from its own ticks, so a test drives it with a virtual clock.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;
const Duration = std.Io.Duration;

pub const Stopwatch = struct {
    /// The time counted so far.
    elapsed: Duration = .zero,
    running: bool = false,
    /// How often it ticks, and so how fine its count is.
    interval: Duration = .fromSeconds(1),
    tick_id: u32 = 0x5357_4154, // "SWAT"
    /// Run alone: space starts and stops, r resets, q quits.
    keys: bool = true,
    style: tui.Style = .{},

    /// Starts counting; returns the first tick.
    pub fn start(s: *Stopwatch) tui.Cmd {
        if (s.running) return .none;
        s.running = true;
        return .tick(s.interval, s.tick_id);
    }

    /// Stops counting; the count stays.
    pub fn stop(s: *Stopwatch) void {
        s.running = false;
    }

    /// Starts or stops.
    pub fn toggle(s: *Stopwatch) tui.Cmd {
        if (s.running) {
            s.stop();
            return .none;
        }
        return s.start();
    }

    /// Back to zero, running or not.
    pub fn reset(s: *Stopwatch) void {
        s.elapsed = .zero;
    }

    pub fn update(s: *Stopwatch, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .tick => |id| if (id == s.tick_id and s.running) {
                s.elapsed = .fromNanoseconds(s.elapsed.nanoseconds + s.interval.nanoseconds);
                return .tick(s.interval, s.tick_id);
            },
            .key => |key| if (s.keys) {
                if (key.matches("space")) return s.toggle();
                if (key.matches("r")) s.reset();
                if (key.matches("q") or key.matches("esc")) return .quit;
            },
            else => {},
        }
        return .none;
    }

    pub fn view(s: *const Stopwatch, w: *Writer) Writer.Error!void {
        var buffer: [32]u8 = undefined;
        var text: Writer = .fixed(&buffer);
        writeDuration(&text, s.elapsed) catch {};
        try s.style.paint(w, text.buffered());
    }
};

/// Writes `duration` as people read it: `1h02m03s`, `2m05s`, `7s`, `0.25s`.
pub const writeDuration = tui.term.live.writeElapsed;

const testing = std.testing;

test "it counts while running, from its own ticks" {
    var d: tui.testing.Driver(Stopwatch) = try .init(testing.allocator, .{}, .{});
    defer d.deinit();
    try d.expectFrame("0s");
    try d.advance(.fromSeconds(65));
    try d.expectFrame("1m05s");
    try d.press("space");
    try d.advance(.fromSeconds(10));
    try d.expectFrame("1m05s");
    try d.press("r");
    try d.expectFrame("0s");
}

test writeDuration {
    var buffer: [32]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    for ([_]i64{ 3_723_000, 125_000, 7_000, 250 }, 0..) |ms, i| {
        if (i > 0) try w.writeByte(' ');
        try writeDuration(&w, .fromMilliseconds(ms));
    }
    try testing.expectEqualStrings("1h02m03s 2m05s 7s 0.25s", w.buffered());
}
