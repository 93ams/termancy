//! Choose any number of items from a list, up to an optional limit.
//!
//! ```zig
//! var pick: MultiSelect = try .init(gpa, .{ .items = &.{ "a", "b", "c" } });
//! defer pick.deinit();
//! pick.limit = 2;
//! // ... run ...
//! for (pick.list.items, 0..) |item, i| if (pick.isChosen(i)) use(item);
//! for (pick.order.items) |i| use(pick.list.items[i]); // in the order chosen
//! ```
//!
//! Keys: everything `List` moves with; space (or tab, x, ctrl+space) toggles the
//! highlighted item; a (or ctrl+a) chooses every item (as many as the limit allows), or
//! clears them all when that is already done, unless `toggle_all` is off; enter submits,
//! choosing the highlighted item when nothing else is; esc cancels. With a limit, items
//! past it cannot be chosen until another is cleared.
//!
//! Each item shows a mark: `chosen_mark` when chosen, else `cursor_mark` on the highlighted
//! one and `unchosen_mark` on the rest. A chosen item, mark and text, is in `styles.chosen`.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const List = @import("list.zig");

pub const Status = enum { active, submitted, canceled };

const MultiSelect = @This();

gpa: Allocator,
list: List,
/// One flag per item.
chosen: []bool,
/// The indexes of the chosen items, in the order they were chosen.
order: std.ArrayList(usize),
/// The most items that may be chosen; null for no limit.
limit: ?usize = null,
/// Whether a (and ctrl+a) choose every item.
toggle_all: bool = true,
/// A line above the items; none when empty.
header: []const u8 = "",
chosen_mark: []const u8 = "✓ ",
cursor_mark: []const u8 = "• ",
unchosen_mark: []const u8 = "• ",
status: Status = .active,
styles: Styles = .{},

pub const Styles = struct {
    header: tui.Style = .{ .fg = .{ .indexed = 99 }, .bold = true },
    chosen: tui.Style = .{ .fg = .{ .indexed = 212 } },
    count: tui.Style = .{ .fg = .{ .indexed = 240 } },
};

/// A multi-select over `list`'s items, none chosen.
pub fn init(gpa: Allocator, list: List) Allocator.Error!MultiSelect {
    const chosen = try gpa.alloc(bool, list.items.len);
    errdefer gpa.free(chosen);
    @memset(chosen, false);
    const order: std.ArrayList(usize) = try .initCapacity(gpa, list.items.len);
    return .{ .gpa = gpa, .list = list, .chosen = chosen, .order = order };
}

/// Frees the flags and the order.
pub fn deinit(model: *MultiSelect) void {
    model.gpa.free(model.chosen);
    model.order.deinit(model.gpa);
    model.* = undefined;
}

/// Whether item `index` is chosen.
pub fn isChosen(model: *const MultiSelect, index: usize) bool {
    return model.chosen[index];
}

/// How many items are chosen.
pub fn count(model: *const MultiSelect) usize {
    return model.order.items.len;
}

/// Chooses or clears item `index`; choosing past the limit does nothing.
pub fn toggle(model: *MultiSelect, index: usize) void {
    if (model.chosen[index]) {
        model.chosen[index] = false;
        const at = std.mem.indexOfScalar(usize, model.order.items, index).?;
        _ = model.order.orderedRemove(at);
    } else if (!model.full()) {
        model.chosen[index] = true;
        model.order.appendAssumeCapacity(index);
    }
}

fn full(model: *const MultiSelect) bool {
    const limit = model.limit orelse return false;
    return model.count() >= limit;
}

/// Chooses every item in order until the limit, or clears all if no more fit.
pub fn toggleAll(model: *MultiSelect) void {
    const before = model.count();
    for (model.chosen, 0..) |flag, i| {
        if (!flag) model.toggle(i);
    }
    if (model.count() > before) return;
    @memset(model.chosen, false);
    model.order.clearRetainingCapacity();
}

pub fn update(model: *MultiSelect, msg: tui.Msg) tui.Cmd {
    if (msg == .mouse) {
        // A click toggles the item clicked; the wheel moves.
        const items_top = model.list.top + @intFromBool(model.header.len > 0);
        if (model.list.handleMouse(msg.mouse, items_top)) |index| model.toggle(index);
        return .none;
    }
    if (msg != .key) return model.list.update(msg);
    const key = msg.key;
    const items = model.list.items.len;
    const toggles = key.matches("space") or key.matches("tab") or key.matches("x") or
        key.matches("ctrl+space");
    if (toggles and items > 0) {
        model.toggle(model.list.cursor);
    } else if (model.toggle_all and (key.matches("a") or key.matches("ctrl+a"))) {
        model.toggleAll();
    } else if (key.matches("enter") and items > 0) {
        if (model.count() == 0) model.toggle(model.list.cursor);
        model.status = .submitted;
        return .quit;
    } else if (key.matches("esc")) {
        model.status = .canceled;
        return .quit;
    } else return model.list.update(msg);
    return .none;
}

/// Writes item `index` behind its mark, for `List.writeRow` to lay out.
fn writeItem(
    model: *const MultiSelect,
    w: *std.Io.Writer,
    index: usize,
) std.Io.Writer.Error!void {
    const item = model.list.items[index];
    if (!model.chosen[index]) {
        const mark = if (index == model.list.cursor) model.cursor_mark else model.unchosen_mark;
        return w.print("{s}{s}", .{ mark, item });
    }
    try model.styles.chosen.writeSgr(w);
    try w.print("{s}{s}", .{ model.chosen_mark, item });
    if (model.styles.chosen.hasSgr()) try w.writeAll(tui.ansi.reset);
}

pub fn view(model: *const MultiSelect, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (model.header.len > 0) {
        try model.styles.header.paint(w, model.header);
        try w.writeByte('\n');
    }
    const shown = model.list.window();
    var row: std.Io.Writer.Allocating = .init(model.gpa);
    defer row.deinit();
    for (shown.start..shown.end) |i| {
        if (i > shown.start) try w.writeByte('\n');
        row.clearRetainingCapacity();
        try model.writeItem(&row.writer, i);
        try model.list.writeRow(w, i, row.written());
    }
    if (model.limit) |limit| {
        try w.writeByte('\n');
        try model.styles.count.writeSgr(w);
        try w.print("{d}/{d} chosen", .{ model.count(), limit });
        if (model.styles.count.hasSgr()) try w.writeAll(tui.ansi.reset);
    }
}

const testing = std.testing;
const Driver = tui.testing.Driver(MultiSelect);
const letters = [_][]const u8{ "a", "b", "c", "d" };

fn startPick(d: *Driver, limit: ?usize) !void {
    var model: MultiSelect = try .init(testing.allocator, .{ .items = &letters });
    model.limit = limit;
    d.* = try .init(testing.allocator, model, .{});
}

fn finish(d: *Driver) void {
    d.deinit();
}

test "space toggles, enter submits the chosen items" {
    var d: Driver = undefined;
    try startPick(&d, null);
    defer finish(&d);
    try d.expectFrame("> • a\n  • b\n  • c\n  • d");
    try d.press("space");
    try d.press("down");
    try d.press("down");
    try d.press("x");
    try d.expectFrame("  ✓ a\n  • b\n> ✓ c\n  • d");
    try d.press("space");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqual(1, d.model().count());
    try testing.expect(d.model().isChosen(0));
}

test "enter with nothing chosen chooses the highlighted item" {
    var d: Driver = undefined;
    try startPick(&d, null);
    defer finish(&d);
    try d.press("end");
    try d.press("enter");
    try testing.expect(d.model().isChosen(3));
    try testing.expectEqual(1, d.model().count());
}

test "the limit caps choosing" {
    var d: Driver = undefined;
    try startPick(&d, 2);
    defer finish(&d);
    try d.expectFrameContains("0/2 chosen");
    for (0..4) |_| {
        try d.press("space");
        try d.press("down");
    }
    try testing.expectEqual(2, d.model().count());
    try testing.expect(!d.model().isChosen(2));
    try d.expectFrameContains("2/2 chosen");
    try d.press("home");
    try d.press("space"); // clear a
    try d.press("end");
    try d.press("space"); // now d fits
    try testing.expect(d.model().isChosen(3));
}

test "the order chosen, and the marks" {
    var model: MultiSelect = try .init(testing.allocator, .{ .items = &letters });
    model.cursor_mark = "> ";
    var d: Driver = try .init(testing.allocator, model, .{});
    defer finish(&d);
    try d.expectFrame("> > a\n  • b\n  • c\n  • d");
    try d.press("end");
    try d.press("tab");
    try d.press("home");
    try d.press("space");
    try d.press("down");
    try d.press("ctrl+space");
    try d.press("home");
    try d.press("x"); // clears a, which space chooses again, last
    try d.press("space");
    try d.expectFrame("> ✓ a\n  ✓ b\n  • c\n  ✓ d");
    try testing.expectEqualSlices(usize, &.{ 3, 1, 0 }, d.model().order.items);
}

test "toggle_all off: a is not a key" {
    var d: Driver = undefined;
    try startPick(&d, null);
    defer finish(&d);
    d.model().toggle_all = false;
    try d.press("a");
    try d.press("ctrl+a");
    try testing.expectEqual(0, d.model().count());
}

test "a chooses all that fit, then clears" {
    var d: Driver = undefined;
    try startPick(&d, 3);
    defer finish(&d);
    try d.press("end");
    try d.press("space");
    try d.press("a");
    try testing.expectEqual(3, d.model().count());
    try testing.expect(!d.model().isChosen(2));
    try testing.expectEqualSlices(usize, &.{ 3, 0, 1 }, d.model().order.items);
    try d.press("a");
    try testing.expectEqual(0, d.model().count());
    try testing.expectEqual(0, d.model().order.items.len);
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "the mouse: a click toggles the item clicked" {
    var d: Driver = undefined;
    try startPick(&d, null);
    defer finish(&d);
    try d.send(.{ .mouse = .{ .x = 2, .y = 2, .button = .left, .action = .press } });
    try testing.expect(d.model().isChosen(2));
    try d.send(.{ .mouse = .{ .x = 2, .y = 2, .button = .left, .action = .press } });
    try testing.expect(!d.model().isChosen(2));
    try testing.expect(!d.done());
}
