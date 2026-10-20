//! A scrollable area of fixed height over text, to embed in a larger view: a log, help,
//! or a preview beside a list. (`pager` is the full-screen reader with search.)
//!
//! ```zig
//! var viewport: Viewport = .{ .content = log, .height = 10 };
//! _ = viewport.update(msg); // up/down, j/k, pgup/pgdown, ctrl+u/ctrl+d, g/G, the wheel
//! viewport.setContent(longer_log); // stays at the bottom if it was there
//! try viewport.view(w); // always `height` rows
//! ```
//!
//! Lines are word-wrapped to `width` (the terminal width from the last resize, unless set),
//! so scrolling is by screen row. With `wrap` off, each line is one row cut at the width,
//! and left/right (h/l) scroll sideways (`x_offset`). Nothing is allocated: rows are found
//! by walking the content, which suits text up to a few thousand lines.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;

const Viewport = @This();

/// The text shown; borrowed.
content: []const u8 = "",
/// Rows shown; `view` always writes this many.
height: usize = 10,
/// Columns rows are wrapped to; null takes the terminal width.
width: ?usize = null,
/// The terminal width from the last resize.
terminal_width: usize = 80,
/// The first row shown.
offset: usize = 0,
/// Whether the keys scroll; turn off when the keys belong to something else.
keys: bool = true,
/// Wrap long lines; off, they are cut at the width and scroll sideways.
wrap: bool = true,
/// The first column shown, when not wrapping.
x_offset: usize = 0,
/// Columns a sideways scroll moves.
x_step: usize = 4,

/// Scrolls on navigation keys and the wheel; records the terminal width. Never quits.
pub fn update(viewport: *Viewport, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .key => |key| if (viewport.keys) {
            _ = viewport.handleKey(key);
        },
        .mouse => |mouse| switch (mouse.button) {
            .wheel_up => viewport.scrollBy(-3),
            .wheel_down => viewport.scrollBy(3),
            else => {},
        },
        .resize => |size| {
            viewport.terminal_width = size.width;
            viewport.scrollBy(0);
        },
        else => {},
    }
    return .none;
}

/// Applies a navigation key; returns whether the key was one.
pub fn handleKey(viewport: *Viewport, key: tui.input.Key) bool {
    const page: isize = @intCast(@max(viewport.height, 1));
    if (key.matches("up") or key.matches("k")) {
        viewport.scrollBy(-1);
    } else if (key.matches("down") or key.matches("j")) {
        viewport.scrollBy(1);
    } else if (key.matches("pgup") or key.matches("ctrl+b")) {
        viewport.scrollBy(-page);
    } else if (key.matches("pgdown") or key.matches("ctrl+f") or key.matches("space")) {
        viewport.scrollBy(page);
    } else if (key.matches("ctrl+u")) {
        viewport.scrollBy(-@divFloor(page + 1, 2));
    } else if (key.matches("ctrl+d")) {
        viewport.scrollBy(@divFloor(page + 1, 2));
    } else if (key.matches("home") or key.matches("g")) {
        viewport.offset = 0;
    } else if (key.matches("end") or key.matches("G")) {
        viewport.gotoBottom();
    } else if (!viewport.wrap and (key.matches("right") or key.matches("l"))) {
        viewport.x_offset = @min(viewport.x_offset + viewport.x_step, viewport.maxXOffset());
    } else if (!viewport.wrap and (key.matches("left") or key.matches("h"))) {
        viewport.x_offset -|= viewport.x_step;
    } else return false;
    return true;
}

/// The farthest a sideways scroll goes: the widest line's end at the right edge.
fn maxXOffset(viewport: *const Viewport) usize {
    return tui.width.of(viewport.content) -| viewport.columns();
}

/// Replaces the content. A viewport at the bottom stays there, so a growing log
/// follows its tail; otherwise the offset is kept, within range.
pub fn setContent(viewport: *Viewport, content: []const u8) void {
    const following = viewport.atBottom();
    viewport.content = content;
    if (following) viewport.gotoBottom() else viewport.scrollBy(0);
}

/// Scrolls by `delta` rows, stopping at either end.
pub fn scrollBy(viewport: *Viewport, delta: isize) void {
    const target = @as(isize, @intCast(viewport.offset)) + delta;
    viewport.offset = @min(@as(usize, @intCast(@max(0, target))), viewport.maxOffset());
}

/// Scrolls so the last row is at the bottom.
pub fn gotoBottom(viewport: *Viewport) void {
    viewport.offset = viewport.maxOffset();
}

/// Whether the last row is on screen.
pub fn atBottom(viewport: *const Viewport) bool {
    return viewport.offset >= viewport.maxOffset();
}

/// How far down the view is, from 0 (top) to 100 (bottom, or everything fits).
pub fn percent(viewport: *const Viewport) u8 {
    const max = viewport.maxOffset();
    if (max == 0) return 100;
    return @intCast(@min(100, viewport.offset * 100 / max));
}

/// Rows the content wraps to.
pub fn rowCount(viewport: *const Viewport) usize {
    var it = viewport.rows();
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    return count;
}

fn maxOffset(viewport: *const Viewport) usize {
    return viewport.rowCount() -| viewport.height;
}

fn columns(viewport: *const Viewport) usize {
    return @max(1, viewport.width orelse viewport.terminal_width);
}

/// Exactly `height` rows: the content from `offset`, then blank rows.
pub fn view(viewport: *const Viewport, w: *Writer) Writer.Error!void {
    var it = viewport.rows();
    for (0..viewport.offset) |_| _ = it.next();
    for (0..viewport.height) |i| {
        if (i > 0) try w.writeByte('\n');
        const row = it.next() orelse continue;
        if (viewport.wrap) {
            try w.writeAll(row);
        } else {
            const from = viewport.x_offset;
            try tui.width.cut(w, row, from, from + viewport.columns());
        }
        if (std.mem.indexOfScalar(u8, row, 0x1b) != null) try w.writeAll(tui.ansi.reset);
    }
}

fn rows(viewport: *const Viewport) Rows {
    return .{
        .lines = std.mem.splitScalar(u8, viewport.content, '\n'),
        .limit = if (viewport.wrap) viewport.columns() else std.math.maxInt(usize),
        .empty = viewport.content.len == 0,
    };
}

/// The content's screen rows, in order.
const Rows = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    limit: usize,
    wrapper: ?tui.width.Wrapper = null,
    empty: bool,

    fn next(r: *Rows) ?[]const u8 {
        if (r.empty) return null;
        while (true) {
            if (r.wrapper) |*wrapper| {
                if (wrapper.next()) |row| return row.bytes;
                r.wrapper = null;
            }
            const line = r.lines.next() orelse return null;
            r.wrapper = .init(line, r.limit);
        }
    }
};

const testing = std.testing;
const ten = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10";

test "scrolls by row, page, and half page, and stops at either end" {
    var d: tui.testing.Driver(Viewport) = try .init(
        testing.allocator,
        .{ .content = ten, .height = 3 },
        .{},
    );
    defer d.deinit();
    try d.expectFrame("1\n2\n3");
    try d.press("down");
    try d.press("j");
    try d.expectFrame("3\n4\n5");
    try d.press("pgdown");
    try d.expectFrame("6\n7\n8");
    try d.press("pgdown");
    try d.expectFrame("8\n9\n10");
    try testing.expect(d.model().atBottom());
    try testing.expectEqual(100, d.model().percent());
    try d.press("ctrl+u");
    try d.expectFrame("6\n7\n8");
    try d.press("g");
    try d.press("up");
    try d.expectFrame("1\n2\n3");
    try testing.expectEqual(0, d.model().percent());
    try d.press("G");
    try d.expectFrame("8\n9\n10");
    try testing.expect(!d.done());
}

test "without wrapping, long lines scroll sideways" {
    var d: tui.testing.Driver(Viewport) = try .init(testing.allocator, .{
        .content = "0123456789abcdef\nxy",
        .height = 2,
        .width = 6,
        .wrap = false,
        .x_step = 4,
    }, .{});
    defer d.deinit();
    try d.expectFrame("012345\nxy");
    try d.press("right");
    try d.expectFrame("456789");
    try d.press("l");
    try d.press("l");
    try d.press("l");
    try d.expectFrame("abcdef");
    try d.press("left");
    try d.expectFrame("6789ab");
}

test "short content is padded to the height" {
    var d: tui.testing.Driver(Viewport) = try .init(
        testing.allocator,
        .{ .content = "only", .height = 3 },
        .{},
    );
    defer d.deinit();
    var buffer: [16]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try d.model().view(&w);
    try testing.expectEqualStrings("only\n\n", w.buffered());
    try d.press("down");
    try testing.expectEqual(0, d.model().offset);
    try testing.expectEqual(100, d.model().percent());
}

test "long lines wrap to the width, and a resize rewraps" {
    const viewport: Viewport = .{ .content = "one two three\nfour", .height = 2 };
    var d: tui.testing.Driver(Viewport) = try .init(testing.allocator, viewport, .{
        .program = .{ .size = .{ .width = 7, .height = 5 } },
    });
    defer d.deinit();
    try d.expectFrame("one two\nthree");
    try d.press("down");
    try d.expectFrame("three\nfour");
    try d.resize(.{ .width = 20, .height = 5 });
    // Two rows now fit everything; the offset is pulled back into range.
    try d.expectFrame("one two three\nfour");
}

test "setContent follows the tail only from the bottom" {
    var viewport: Viewport = .{ .content = "a\nb\nc", .height = 2 };
    viewport.gotoBottom();
    viewport.setContent("a\nb\nc\nd");
    try testing.expectEqual(2, viewport.offset);
    viewport.offset = 0;
    viewport.setContent("a\nb\nc\nd\ne");
    try testing.expectEqual(0, viewport.offset);
    viewport.offset = 3;
    viewport.setContent("a");
    try testing.expectEqual(0, viewport.offset);
}

test "the wheel scrolls, and keys can be left to the parent" {
    var viewport: Viewport = .{ .content = ten, .height = 3, .keys = false };
    _ = viewport.update(.{ .key = try .parse("down") });
    try testing.expectEqual(0, viewport.offset);
    _ = viewport.update(.{ .mouse = .{ .x = 0, .y = 0, .button = .wheel_down, .action = .press } });
    try testing.expectEqual(3, viewport.offset);
}

test "an empty viewport is blank rows" {
    var buffer: [16]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const viewport: Viewport = .{ .height = 2 };
    try viewport.view(&w);
    try testing.expectEqualStrings("\n", w.buffered());
    try testing.expectEqual(0, viewport.rowCount());
}
