//! A determinate progress bar with a percentage and an estimate of the time left.
//!
//! ```zig
//! var bar: Progress = .{ .total = files.len };
//! for (files, 1..) |file, done| {
//!     copy(file);
//!     bar.set(done, .now(io, .awake));
//!     // ... redraw ...
//! }
//! ```
//!
//! The bar can fill with a gradient (`gradient`, across the whole bar or `scale_gradient`
//! across the part filled), in eighths of a cell (`smooth`), and move toward each new value
//! on a spring (`animate`) instead of jumping, as Bubbles' bar does.
//!
//! The clock is injected: the component never reads one. Each `set` (or `.app` message
//! of type `Sample`, when the bar runs as a program) carries the time it was taken, and the
//! estimate is the time since the first sample scaled by the work left over the work done
//! since then. Tests pass whatever times they like.

const std = @import("std");
const tui = @import("tui");
const Io = std.Io;
const Writer = Io.Writer;

/// Progress at a moment.
pub const Sample = struct {
    current: u64,
    at: Io.Timestamp,
};

const Progress = @This();

/// The amount of work in all; at least 1 for a meaningful bar.
total: u64,
/// The amount done.
current: u64 = 0,
/// Columns of the bar itself.
width: usize = 40,
full: []const u8 = "█",
empty: []const u8 = "░",
show_percent: bool = true,
show_eta: bool = true,
/// Quit when `current` reaches `total`, for a bar run as a program on its own.
quit_when_done: bool = false,
/// The first sample, which the estimate measures from.
first: ?Sample = null,
/// The latest sample.
latest: ?Sample = null,
/// Colors the filled cells blend through (two or more), in place of `styles.full`'s.
gradient: []const tui.Color = &.{},
/// Spread `gradient` over the filled part rather than the whole bar.
scale_gradient: bool = false,
/// Fill in eighths of a cell with the partial blocks (`▏` to `▉`).
smooth: bool = false,
/// Move toward each new value on a spring, a frame every `frame_interval`.
animate: bool = false,
spring: tui.motion.Spring = .init(60, 18, 1),
frame_interval: Io.Duration = .fromMilliseconds(16),
frame_id: u32 = 0x5052_4f47, // "PROG"
/// The fraction drawn, while animating.
shown: f64 = 0,
velocity: f64 = 0,
/// A frame is due (an animation is under way).
moving: bool = false,
styles: Styles = .{},

pub const Styles = struct {
    full: tui.Style = .{ .fg = .{ .indexed = 212 } },
    empty: tui.Style = .{ .fg = .{ .indexed = 238 } },
    text: tui.Style = .{},
};

/// The application messages a bar run as a program receives.
pub const Message = Sample;

/// Records that `current` units are done at time `at`; `current` is capped at `total`.
pub fn set(bar: *Progress, current: u64, at: Io.Timestamp) void {
    bar.current = @min(current, bar.total);
    const sample: Sample = .{ .current = bar.current, .at = at };
    if (bar.first == null) bar.first = sample;
    bar.latest = sample;
}

/// The part done, from 0 to 1.
pub fn fraction(bar: *const Progress) f64 {
    if (bar.total == 0) return 1;
    return @as(f64, @floatFromInt(bar.current)) / @as(f64, @floatFromInt(bar.total));
}

/// The time left at the rate since the first sample, or null before any progress.
pub fn eta(bar: *const Progress) ?Io.Duration {
    const first = bar.first orelse return null;
    const latest = bar.latest orelse return null;
    if (latest.current <= first.current) return null;
    const elapsed = first.at.durationTo(latest.at).toNanoseconds();
    if (elapsed <= 0) return null;
    const done: i96 = @intCast(latest.current - first.current);
    const left: i96 = @intCast(bar.total - latest.current);
    return .fromNanoseconds(@divTrunc(elapsed * left, done));
}

/// `set`, for an animated bar: returns the frame that starts it moving (nothing when
/// one is under way, or the bar does not animate).
pub fn setAnimated(bar: *Progress, current: u64, at: Io.Timestamp) tui.Cmd {
    bar.set(current, at);
    if (!bar.animate or bar.moving) return .none;
    bar.moving = true;
    return .tick(bar.frame_interval, bar.frame_id);
}

/// The fraction the bar draws: where the spring is, or where the work is.
pub fn drawn(bar: *const Progress) f64 {
    return if (bar.animate) std.math.clamp(bar.shown, 0, 1) else bar.fraction();
}

pub fn update(bar: *Progress, msg: tui.Message(Sample)) tui.Cmd {
    switch (msg) {
        .app => |sample| {
            const frame = bar.setAnimated(sample.current, sample.at);
            if (bar.quit_when_done and bar.current >= bar.total and !bar.animate) return .quit;
            return frame;
        },
        .tick => |id| if (id == bar.frame_id) return bar.step(),
        else => {},
    }
    return .none;
}

/// One animation frame: the spring moves toward the work done.
pub fn step(bar: *Progress) tui.Cmd {
    const target = bar.fraction();
    bar.spring.update(&bar.shown, &bar.velocity, target);
    const settled = @abs(bar.shown - target) < 0.001 and @abs(bar.velocity) < 0.01;
    if (settled) {
        bar.shown = target;
        bar.velocity = 0;
        bar.moving = false;
        if (bar.quit_when_done and bar.current >= bar.total) return .quit;
        return .none;
    }
    return .tick(bar.frame_interval, bar.frame_id);
}

pub fn view(bar: *const Progress, w: *Writer) Writer.Error!void {
    const cells: tui.term.live.Cells = .{
        .full = bar.full,
        .empty = bar.empty,
        .partial = if (bar.smooth) tui.term.live.Cells.blocks.partial else &.{},
    };
    try tui.term.live.writeCells(w, bar.drawn(), bar.width, cells, .{
        .full = bar.styles.full,
        .empty = bar.styles.empty,
        .gradient = bar.gradient,
        .scale_gradient = bar.scale_gradient,
    });
    try bar.styles.text.writeSgr(w);
    if (bar.show_percent) {
        try w.print(" {d:>3}%", .{@as(u8, @intFromFloat(@floor(bar.fraction() * 100)))});
    }
    if (bar.show_eta) {
        if (bar.eta()) |left| {
            try w.writeAll(" ETA ");
            try writeDuration(w, left);
        }
    }
    if (bar.styles.text.hasSgr()) try w.writeAll(tui.ansi.reset);
}

/// Writes a duration as `1h02m`, `3m05s`, or `12s`, rounded up to the second.
pub const writeDuration = tui.term.live.writeEta;

const testing = std.testing;

fn second(n: i64) Io.Timestamp {
    return Io.Timestamp.zero.addDuration(.fromSeconds(n));
}

test "the bar fills in proportion" {
    var d: tui.testing.Driver(Progress) = try .init(
        testing.allocator,
        .{ .total = 4, .width = 8, .full = "#", .empty = "." },
        .{},
    );
    defer d.deinit();
    try d.expectFrame("........   0%");
    try d.send(.{ .app = .{ .current = 1, .at = second(0) } });
    try d.expectFrame("##......  25%");
    try d.send(.{ .app = .{ .current = 2, .at = second(10) } });
    try d.expectFrame("####....  50% ETA 20s");
    try d.send(.{ .app = .{ .current = 9, .at = second(30) } });
    try d.expectFrame("######## 100% ETA 0s");
    try testing.expect(!d.done());
}

test "quit_when_done ends a bar run on its own" {
    var d: tui.testing.Driver(Progress) = try .init(
        testing.allocator,
        .{ .total = 2, .quit_when_done = true },
        .{},
    );
    defer d.deinit();
    try d.send(.{ .app = .{ .current = 2, .at = second(1) } });
    try testing.expect(d.done());
}

test "eta needs progress over time" {
    var bar: Progress = .{ .total = 100 };
    try testing.expectEqual(null, bar.eta());
    bar.set(10, second(5));
    try testing.expectEqual(null, bar.eta());
    bar.set(10, second(6));
    try testing.expectEqual(null, bar.eta());
    bar.set(55, second(50));
    // 45 units in 45 s since the first sample; 45 left.
    try testing.expectEqual(45, bar.eta().?.toSeconds());
}

test writeDuration {
    var buffer: [32]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeDuration(&w, .fromMilliseconds(11_200));
    try w.writeByte(' ');
    try writeDuration(&w, .fromSeconds(185));
    try w.writeByte(' ');
    try writeDuration(&w, .fromSeconds(3720));
    try testing.expectEqualStrings("12s 3m05s 1h02m", w.buffered());
}

test "gradients, smooth fills, and a spring" {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    var bar: Progress = .{
        .total = 16,
        .current = 5,
        .width = 4,
        .smooth = true,
        .show_percent = false,
        .styles = .{ .full = .{}, .empty = .{} },
    };
    try bar.view(&w);
    // 5/16 of 4 columns: one cell and a quarter.
    try testing.expectEqualStrings("█▎░░", w.buffered());
    bar.gradient = &.{ .hex(0xff0000), .hex(0x0000ff) };
    bar.current = 16;
    w = .fixed(&buffer);
    try bar.view(&w);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "\x1b[38;2;255;0;0m█"));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[38;2;0;0;255m█") != null);

    var d: tui.testing.Driver(Progress) = try .init(testing.allocator, .{
        .total = 10,
        .width = 10,
        .full = "#",
        .empty = ".",
        .animate = true,
        .show_percent = false,
        .show_eta = false,
    }, .{});
    defer d.deinit();
    try d.send(.{ .app = .{ .current = 10, .at = second(0) } });
    // Not there at once: the spring takes it over a few frames.
    try d.expectFrame("..........");
    try d.advance(.fromMilliseconds(64));
    const halfway = try d.frameText(testing.allocator);
    defer testing.allocator.free(halfway);
    try testing.expect(std.mem.indexOfScalar(u8, halfway, '#') != null);
    try testing.expect(std.mem.indexOfScalar(u8, halfway, '.') != null);
    try d.advance(.fromSeconds(2));
    try d.expectFrame("##########");
    try testing.expect(!d.model().moving);
}

test "a total of zero is complete" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const bar: Progress = .{ .total = 0, .width = 2, .styles = .{ .full = .{}, .empty = .{} } };
    try bar.view(&w);
    try testing.expectEqualStrings("██ 100%", w.buffered());
}
