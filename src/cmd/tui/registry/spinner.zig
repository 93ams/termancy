//! An animated spinner with a title, for work of unknown length.
//!
//! ```zig
//! var spinner: Spinner = .{ .title = "Fetching..." };
//! var program: tui.Program(Spinner) = .init(gpa, &spinner, out, .{});
//! ```
//!
//! `start` sets the first timer; each `.tick` carrying `tick_id` shows the next frame and
//! sets the next timer. The spinner never quits: whoever runs the work stops the program
//! (`Program.stop`) or quits from the model that embeds the spinner. A model embedding
//! several timers gives each a different `tick_id` and forwards the ticks.

const std = @import("std");
const tui = @import("tui");

/// Frame sets: `dots`, `line`, `arc`, `bouncing_bar`, and more (`term.live.frames`).
pub const frames = tui.term.live.frames;

pub const Spinner = struct {
    frames: []const []const u8 = &frames.dots,
    /// Time between frames.
    interval: std.Io.Duration = .fromMilliseconds(80),
    /// Written after the spinner; none when empty.
    title: []const u8 = "",
    /// The index of the frame shown.
    frame: usize = 0,
    /// The id of this spinner's timer.
    tick_id: u32 = 0x5350_494e, // "SPIN"
    styles: Styles = .{},

    pub const Styles = struct {
        spinner: tui.Style = .{ .fg = .{ .indexed = 212 } },
        title: tui.Style = .{},
    };

    /// Sets the first timer.
    pub fn start(spinner: *Spinner) tui.Cmd {
        return .tick(spinner.interval, spinner.tick_id);
    }

    /// Advances on this spinner's ticks; ignores everything else.
    pub fn update(spinner: *Spinner, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .tick => |id| if (id == spinner.tick_id) {
                spinner.frame = (spinner.frame + 1) % spinner.frames.len;
                return .tick(spinner.interval, spinner.tick_id);
            },
            else => {},
        }
        return .none;
    }

    pub fn view(spinner: *const Spinner, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try spinner.styles.spinner.paint(w, spinner.frames[spinner.frame]);
        if (spinner.title.len == 0) return;
        try w.writeByte(' ');
        try spinner.styles.title.paint(w, spinner.title);
    }
};

const testing = std.testing;
const Driver = tui.testing.Driver(Spinner);

test "one frame per interval" {
    var d: Driver = try .init(
        testing.allocator,
        .{ .frames = &frames.line, .title = "Working" },
        .{},
    );
    defer d.deinit();
    try d.expectFrame("- Working");
    try d.advance(.fromMilliseconds(79));
    try d.expectFrame("- Working");
    try d.advance(.fromMilliseconds(1));
    try d.expectFrame("\\ Working");
    try d.advance(.fromMilliseconds(240));
    try d.expectFrame("- Working"); // wrapped around
    try testing.expect(!d.done());
}

test "other timers and keys are ignored" {
    var spinner: Spinner = .{ .interval = .fromMilliseconds(10) };
    try testing.expectEqual(0, spinner.update(.{ .tick = 1 }).len);
    try testing.expectEqual(0, spinner.update(.{ .key = .{ .code = .enter } }).len);
    try testing.expectEqual(0, spinner.frame);
    const next = spinner.update(.{ .tick = spinner.tick_id });
    try testing.expectEqual(1, spinner.frame);
    try testing.expectEqual(spinner.tick_id, next.slice()[0].tick.id);
}

test "without a title, only the spinner" {
    var buffer: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const spinner: Spinner = .{
        .frames = &frames.points,
        .frame = 2,
        .styles = .{ .spinner = .{} },
    };
    try spinner.view(&w);
    try testing.expectEqualStrings("∙●∙", w.buffered());
}
