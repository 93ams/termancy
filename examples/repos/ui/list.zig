//! A scrollable list of items with a cursor: the building block of `select`, `multiselect`,
//! and `filter`.
//!
//! ```zig
//! var list: List = .{ .items = &.{ "apple", "banana", "cherry" }, .height = 5 };
//! _ = list.update(msg); // up/down, j/k, pgup/pgdown, home/end, g/G
//! const choice = list.current(); // "apple"
//! ```
//!
//! The list only moves: it never quits and has no notion of choosing. Embed it in a model
//! that decides what enter and esc mean, or use `select`. Models that type text (such as
//! `filter`) call `moveBy`, `page`, and `moveTo` instead of `update`, so letters stay theirs.
//!
//! At most `height` items are shown; the window scrolls to keep the cursor visible. Rows
//! wider than the terminal are cut with an ellipsis, so one item is always one row.
//!
//! The mouse (with `Options.mouse` in a full-screen program): the wheel moves the cursor,
//! and a click puts it on the item clicked. `top` is the screen row of the first item.

const std = @import("std");
const tui = @import("tui");

pub const List = struct {
    items: []const []const u8,
    /// The index of the highlighted item.
    cursor: usize = 0,
    /// The index of the first item shown.
    offset: usize = 0,
    /// The most items shown at once.
    height: usize = 10,
    /// The terminal's width, from the last resize; rows are cut to fit.
    width: ?usize = null,
    /// Written before the highlighted item.
    cursor_prefix: []const u8 = "> ",
    /// Written before every other item; as wide as `cursor_prefix`.
    item_prefix: []const u8 = "  ",
    /// The screen row the first item is drawn on, for mouse clicks.
    top: usize = 0,
    styles: Styles = .{},

    pub const Styles = struct {
        cursor: tui.Style = .{ .fg = .{ .indexed = 212 } },
        item: tui.Style = .{},
    };

    /// The first and one-past-the-last index of the items on screen.
    pub const Window = struct { start: usize, end: usize };

    /// Moves on navigation keys and records the terminal width. Never quits.
    pub fn update(list: *List, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .key => |key| _ = list.handleKey(key),
            .mouse => |mouse| _ = list.handleMouse(mouse, list.top),
            .resize => |size| list.width = size.width,
            else => {},
        }
        return .none;
    }

    /// Applies a navigation key; returns whether the key was one.
    pub fn handleKey(list: *List, key: tui.input.Key) bool {
        if (key.matches("up") or key.matches("k") or key.matches("ctrl+p")) {
            list.moveBy(-1);
        } else if (key.matches("down") or key.matches("j") or key.matches("ctrl+n")) {
            list.moveBy(1);
        } else if (key.matches("pgup") or key.matches("ctrl+b")) {
            list.page(-1);
        } else if (key.matches("pgdown") or key.matches("ctrl+f")) {
            list.page(1);
        } else if (key.matches("home") or key.matches("g")) {
            list.moveTo(0);
        } else if (key.matches("end") or key.matches("G")) {
            list.moveTo(list.items.len -| 1);
        } else return false;
        return true;
    }

    /// Applies a mouse event, the first item being on screen row `top`: the wheel moves the
    /// cursor; a left click puts it on the item clicked and returns that item's index.
    pub fn handleMouse(list: *List, mouse: tui.input.Mouse, top: usize) ?usize {
        switch (mouse.button) {
            .wheel_up => list.moveBy(-1),
            .wheel_down => list.moveBy(1),
            .left => if (mouse.action == .press and mouse.y >= top) {
                const index = list.window().start + (mouse.y - top);
                if (index < list.window().end) {
                    list.moveTo(index);
                    return index;
                }
            },
            else => {},
        }
        return null;
    }

    /// Moves the cursor by `delta` items, stopping at either end.
    pub fn moveBy(list: *List, delta: isize) void {
        const target = @as(isize, @intCast(list.cursor)) + delta;
        list.moveTo(@intCast(@max(0, target)));
    }

    /// Moves the cursor a screenful up (`direction` < 0) or down.
    pub fn page(list: *List, direction: isize) void {
        list.moveBy(direction * @as(isize, @intCast(@max(list.height, 1))));
    }

    /// Puts the cursor on `index` (clamped to the items) and scrolls it into view.
    pub fn moveTo(list: *List, index: usize) void {
        list.cursor = @min(index, list.items.len -| 1);
        list.scroll();
    }

    /// Replaces the items, keeping the cursor in range and on screen.
    pub fn setItems(list: *List, items: []const []const u8) void {
        list.items = items;
        list.moveTo(list.cursor);
    }

    /// Adjusts `offset` so the cursor is inside the window.
    fn scroll(list: *List) void {
        const height = @max(list.height, 1);
        if (list.cursor < list.offset) list.offset = list.cursor;
        if (list.cursor >= list.offset + height) list.offset = list.cursor + 1 - height;
        list.offset = @min(list.offset, list.items.len -| height);
    }

    /// The items on screen.
    pub fn window(list: *const List) Window {
        const start = @min(list.offset, list.items.len);
        return .{ .start = start, .end = @min(start + list.height, list.items.len) };
    }

    /// The highlighted item, or null when the list is empty.
    pub fn current(list: *const List) ?[]const u8 {
        if (list.items.len == 0) return null;
        return list.items[list.cursor];
    }

    /// One row per item on screen; nothing for an empty list.
    pub fn view(list: *const List, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const shown = list.window();
        for (shown.start..shown.end) |i| {
            if (i > shown.start) try w.writeByte('\n');
            try list.writeRow(w, i, list.items[i]);
        }
    }

    /// Writes item `index` as the list shows it, with `text` in place of the item, so
    /// models built on the list can decorate items (marks, highlights) and keep its look.
    pub fn writeRow(
        list: *const List,
        w: *std.Io.Writer,
        index: usize,
        text: []const u8,
    ) std.Io.Writer.Error!void {
        const is_cursor = index == list.cursor;
        const prefix = if (is_cursor) list.cursor_prefix else list.item_prefix;
        const style = if (is_cursor) list.styles.cursor else list.styles.item;
        try style.paint(w, prefix);
        try style.writeSgr(w);
        const room = if (list.width) |width| width -| tui.width.of(prefix) else null;
        if (room) |columns| {
            try tui.width.truncate(w, text, columns, "…");
        } else {
            try w.writeAll(text);
        }
        if (style.hasSgr()) try w.writeAll(tui.ansi.reset);
    }
};

const testing = std.testing;
const fruits = [_][]const u8{ "apple", "banana", "cherry", "damson", "elder", "fig", "grape" };

fn startList(driver: *tui.testing.Driver(List), list: List) !void {
    driver.* = try .init(testing.allocator, list, .{});
}

test "the cursor moves and stops at either end" {
    var d: tui.testing.Driver(List) = undefined;
    try startList(&d, .{ .items = fruits[0..3] });
    defer d.deinit();
    try d.expectFrame("> apple\n  banana\n  cherry");
    try d.press("down");
    try d.press("j");
    try d.expectFrame("  apple\n  banana\n> cherry");
    try d.press("down");
    try testing.expectEqual(2, d.model().cursor);
    try d.press("up");
    try d.press("k");
    try d.press("k");
    try d.expectFrame("> apple\n  banana\n  cherry");
    try testing.expect(!d.done());
}

test "a window of height items scrolls with the cursor" {
    var d: tui.testing.Driver(List) = undefined;
    try startList(&d, .{ .items = &fruits, .height = 3 });
    defer d.deinit();
    try d.expectFrame("> apple\n  banana\n  cherry");
    for (0..3) |_| try d.press("down");
    try d.expectFrame("  banana\n  cherry\n> damson");
    try d.press("end");
    try d.expectFrame("  elder\n  fig\n> grape");
    try d.press("up");
    try d.press("up");
    try d.press("up");
    try d.expectFrame("> damson\n  elder\n  fig");
    try d.press("home");
    try d.expectFrame("> apple\n  banana\n  cherry");
    try d.press("G");
    try testing.expectEqualStrings("grape", d.model().current().?);
    try d.press("g");
    try testing.expectEqual(0, d.model().offset);
}

test "page up and page down move a screenful" {
    var d: tui.testing.Driver(List) = undefined;
    try startList(&d, .{ .items = &fruits, .height = 3 });
    defer d.deinit();
    try d.press("pgdown");
    try testing.expectEqual(3, d.model().cursor);
    try d.press("pgdown");
    try d.press("pgdown");
    try testing.expectEqual(6, d.model().cursor);
    try d.press("pgup");
    try testing.expectEqual(3, d.model().cursor);
    try d.expectFrame("> damson\n  elder\n  fig");
}

test "rows are cut to the terminal width" {
    const list: List = .{ .items = &.{ "a long item name", "short" } };
    var d: tui.testing.Driver(List) = try .init(testing.allocator, list, .{
        .program = .{ .size = .{ .width = 8, .height = 5 } },
    });
    defer d.deinit();
    try d.expectFrame("> a lon…\n  short");
}

test "an empty list draws nothing and ignores keys" {
    var d: tui.testing.Driver(List) = undefined;
    try startList(&d, .{ .items = &.{} });
    defer d.deinit();
    try d.expectFrame("");
    try d.press("down");
    try d.press("end");
    try testing.expectEqual(null, d.model().current());
    try testing.expectEqual(0, d.model().cursor);
}

test "setItems keeps the cursor in range" {
    var list: List = .{ .items = &fruits, .height = 2 };
    list.moveTo(6);
    list.setItems(fruits[0..2]);
    try testing.expectEqual(1, list.cursor);
    try testing.expectEqual(0, list.offset);
    try testing.expectEqual(List.Window{ .start = 0, .end = 2 }, list.window());
}

test "the cursor row is styled" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const list: List = .{ .items = &.{ "a", "b" } };
    try list.view(&w);
    try testing.expectEqualStrings(
        "\x1b[38;5;212m> \x1b[0m\x1b[38;5;212ma\x1b[0m\n  b",
        w.buffered(),
    );
}
