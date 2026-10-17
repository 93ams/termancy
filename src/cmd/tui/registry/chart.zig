//! Small charts drawn with block characters: a sparkline (`▁▃▅█`) for a series, and
//! horizontal bars for labelled amounts, with eighth-cell precision.
//!
//! ```zig
//! try chart.sparkline(w, &.{ 1, 5, 3, 8 }, .{});           // ▁▅▃█
//! try chart.bars(w, &.{ .{ .label = "zig", .value = 42 } }, .{ .width = 20 });
//! ```
//!
//! They are views, not programs: call them from a model's `view`.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;

const ticks = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
const eighths = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

pub const SparklineOptions = struct {
    /// The value drawn as the lowest tick; null for the series' minimum.
    min: ?f64 = null,
    /// The value drawn as the highest tick; null for the series' maximum.
    max: ?f64 = null,
    /// Draw only the last this many values.
    width: ?usize = null,
    style: tui.Style = .{ .fg = .{ .indexed = 212 } },
};

/// One character per value, its height in proportion between `min` and `max`.
pub fn sparkline(w: *Writer, values: []const f64, options: SparklineOptions) Writer.Error!void {
    const shown = if (options.width) |n| values[values.len -| n..] else values;
    if (shown.len == 0) return;
    var low = options.min orelse shown[0];
    var high = options.max orelse shown[0];
    if (options.min == null) for (shown) |v| {
        low = @min(low, v);
    };
    if (options.max == null) for (shown) |v| {
        high = @max(high, v);
    };
    try options.style.writeSgr(w);
    for (shown) |v| {
        const span = high - low;
        const level: usize = if (span <= 0)
            (ticks.len - 1) / 2
        else
            @intFromFloat(@round(std.math.clamp((v - low) / span, 0, 1) * (ticks.len - 1)));
        try w.writeAll(ticks[level]);
    }
    if (options.style.hasSgr()) try w.writeAll(tui.ansi.reset);
}

/// One bar of `bars`.
pub const Bar = struct {
    label: []const u8,
    value: f64,
};

pub const BarsOptions = struct {
    /// Columns of the longest bar.
    width: usize = 40,
    /// The value a full-width bar stands for; null for the largest value.
    max: ?f64 = null,
    /// Write each value after its bar.
    show_values: bool = true,
    label: tui.Style = .{},
    bar: tui.Style = .{ .fg = .{ .indexed = 212 } },
    value: tui.Style = .{ .fg = .{ .indexed = 245 } },
};

/// A row per bar: the label (padded to the longest), the bar, and the value.
pub fn bars(w: *Writer, items: []const Bar, options: BarsOptions) Writer.Error!void {
    var label_width: usize = 0;
    var largest: f64 = 0;
    for (items) |item| {
        label_width = @max(label_width, tui.width.of(item.label));
        largest = @max(largest, item.value);
    }
    const max = options.max orelse largest;
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte('\n');
        try options.label.paint(w, item.label);
        try w.splatByteAll(' ', label_width - tui.width.of(item.label) + 1);
        const part = if (max <= 0) 0 else std.math.clamp(item.value / max, 0, 1);
        const cells = part * @as(f64, @floatFromInt(options.width));
        const whole: usize = @intFromFloat(@floor(cells));
        const eighth: usize = @intFromFloat(@floor((cells - @floor(cells)) * 8));
        try options.bar.writeSgr(w);
        try w.splatBytesAll("█", whole);
        try w.writeAll(eighths[eighth]);
        if (options.bar.hasSgr()) try w.writeAll(tui.ansi.reset);
        if (options.show_values) {
            try w.writeByte(' ');
            var buffer: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{item.value}) catch "?";
            try options.value.paint(w, text);
        }
    }
}

const testing = std.testing;

fn expectChart(expected: []const u8, comptime f: anytype, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try @call(.auto, f, .{&w} ++ args);
    try testing.expectEqualStrings(expected, w.buffered());
}

test sparkline {
    try expectChart(
        "▁▅▃█",
        sparkline,
        .{ &[_]f64{ 1, 5, 3, 8 }, SparklineOptions{ .style = .{} } },
    );
    try expectChart("▄▄", sparkline, .{ &[_]f64{ 2, 2 }, SparklineOptions{ .style = .{} } });
    try expectChart("▃█", sparkline, .{ &[_]f64{ 1, 3, 10 }, SparklineOptions{
        .style = .{},
        .width = 2,
        .min = 0,
    } });
    try expectChart("", sparkline, .{ &[_]f64{}, SparklineOptions{} });
}

test bars {
    const plain: BarsOptions = .{ .width = 4, .bar = .{}, .value = .{} };
    try expectChart("zig  ████ 8\nc    ██ 4\nrust ▉ 1.75", bars, .{
        &[_]Bar{
            .{ .label = "zig", .value = 8 },
            .{ .label = "c", .value = 4 },
            .{ .label = "rust", .value = 1.75 },
        },
        plain,
    });
    var no_values = plain;
    no_values.show_values = false;
    no_values.max = 10;
    try expectChart("a ██▍", bars, .{ &[_]Bar{.{ .label = "a", .value = 6 }}, no_values });
}
