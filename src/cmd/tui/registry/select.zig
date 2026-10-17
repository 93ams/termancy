//! Choose one item from a list.
//!
//! ```zig
//! var select: Select = .{
//!     .header = "Pick a fruit",
//!     .list = .{ .items = &.{ "apple", "banana", "cherry" } },
//! };
//! if (try tui.run(gpa, io, &select, .{ .environ = environ }) != 0) return;
//! if (select.status == .submitted) use(select.selected().?);
//! ```
//!
//! Keys: everything `List` moves with (up/down, j/k, pgup/pgdown, home/end, g/G); enter
//! chooses the highlighted item; esc cancels. Enter on an empty list does nothing. In a
//! full-screen program with the mouse on, the wheel moves and a click chooses; `top` is
//! the screen row the select starts on.

const std = @import("std");
const tui = @import("tui");
const List = @import("list.zig").List;

pub const Status = enum { active, submitted, canceled };

pub const Select = struct {
    list: List,
    /// A line above the items; none when empty.
    header: []const u8 = "",
    status: Status = .active,
    /// The screen row the header (or the first item) is drawn on, for mouse clicks.
    top: usize = 0,
    styles: Styles = .{},

    pub const Styles = struct {
        header: tui.Style = .{ .fg = .{ .indexed = 99 }, .bold = true },
    };

    pub fn update(model: *Select, msg: tui.Msg) tui.Cmd {
        if (msg == .mouse) {
            const items_top = model.top + @intFromBool(model.header.len > 0);
            if (model.list.handleMouse(msg.mouse, items_top) != null) {
                model.status = .submitted;
                return .quit;
            }
            return .none;
        }
        if (msg == .key) {
            const key = msg.key;
            if (key.matches("enter") and model.list.items.len > 0) {
                model.status = .submitted;
                return .quit;
            }
            if (key.matches("esc")) {
                model.status = .canceled;
                return .quit;
            }
        }
        return model.list.update(msg);
    }

    /// The chosen (or, while active, highlighted) item; null when there are none.
    pub fn selected(model: *const Select) ?[]const u8 {
        return model.list.current();
    }

    /// Highlights the first item equal to `item`, if any.
    pub fn highlight(model: *Select, item: []const u8) void {
        for (model.list.items, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, item)) return model.list.moveTo(i);
        }
    }

    pub fn view(model: *const Select, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (model.header.len > 0) {
            try model.styles.header.paint(w, model.header);
            try w.writeByte('\n');
        }
        try model.list.view(w);
    }
};

const testing = std.testing;
const Driver = tui.testing.Driver(Select);

test "enter chooses the highlighted item" {
    var d: Driver = try .init(testing.allocator, .{
        .header = "Fruit?",
        .list = .{ .items = &.{ "apple", "banana", "cherry" } },
    }, .{});
    defer d.deinit();
    try d.expectFrame("Fruit?\n> apple\n  banana\n  cherry");
    try d.press("j");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqualStrings("banana", d.model().selected().?);
}

test "esc cancels; an empty list cannot be chosen from" {
    var d: Driver = try .init(testing.allocator, .{ .list = .{ .items = &.{} } }, .{});
    defer d.deinit();
    try d.press("enter");
    try testing.expect(!d.done());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "highlight starts on a given item" {
    var model: Select = .{ .list = .{ .items = &.{ "a", "b", "c" }, .height = 1 } };
    model.highlight("c");
    try testing.expectEqual(2, model.list.cursor);
    try testing.expectEqual(2, model.list.offset);
    model.highlight("missing");
    try testing.expectEqualStrings("c", model.selected().?);
}

test "the mouse: the wheel moves, a click chooses" {
    var d: Driver = try .init(testing.allocator, .{
        .header = "Fruit?",
        .list = .{ .items = &.{ "apple", "banana", "cherry" } },
    }, .{});
    defer d.deinit();
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .wheel_down, .action = .press } });
    try testing.expectEqualStrings("banana", d.model().selected().?);
    // The header is row 0, so the items start on row 1.
    try d.send(.{ .mouse = .{ .x = 3, .y = 3, .button = .left, .action = .press } });
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqualStrings("cherry", d.model().selected().?);
}
