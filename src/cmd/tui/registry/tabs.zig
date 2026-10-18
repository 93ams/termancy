//! A row of tabs, one active, with the active tab's content below.
//!
//! ```zig
//! var tabs: Tabs = .{
//!     .titles = &.{ "Overview", "Details" },
//!     .contents = &.{ "Everything is fine.", "Really." },
//! };
//! _ = tabs.update(msg);
//! if (tabs.active == 1) showDetails();
//! ```
//!
//! Keys: right, l, or tab activates the next tab and left, h, or shift+tab the previous
//! one, wrapping around; 1-9 activate a tab by position. Tabs never quit: embed them in a
//! model that decides when it is done. Without `contents`, only the row of titles is drawn,
//! so a model can draw the content itself.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;

pub const Tabs = struct {
    titles: []const []const u8,
    /// One text per tab, drawn below the titles; may be empty.
    contents: []const []const u8 = &.{},
    /// The index of the active tab.
    active: usize = 0,
    /// Written between titles.
    separator: []const u8 = " │ ",
    /// The screen row this is drawn from, for mouse clicks.
    top: usize = 0,
    styles: Styles = .{},

    pub const Styles = struct {
        /// The active title: underlined as well as colored, so it shows under `NO_COLOR`.
        active: tui.Style = .{ .fg = .{ .indexed = 212 }, .bold = true, .underline = true },
        inactive: tui.Style = .{ .fg = .{ .indexed = 245 } },
        separator: tui.Style = .{ .fg = .{ .indexed = 238 } },
        content: tui.Style = .{
            .border = .rounded,
            .border_fg = .{ .indexed = 238 },
            .padding = .symmetric(0, 1),
        },
    };

    pub fn update(tabs: *Tabs, msg: tui.Msg) tui.Cmd {
        const key = switch (msg) {
            .key => |key| key,
            .mouse => |mouse| {
                tabs.click(mouse);
                return .none;
            },
            else => return .none,
        };
        const count = tabs.titles.len;
        if (count == 0) return .none;
        if (key.matches("right") or key.matches("l") or key.matches("tab")) {
            tabs.active = (tabs.active + 1) % count;
        } else if (key.matches("left") or key.matches("h") or key.matches("shift+tab")) {
            tabs.active = (tabs.active + count - 1) % count;
        } else if (key.printable()) |c| {
            if (c >= '1' and c <= '9' and c - '1' < count) tabs.active = c - '1';
        }
        return .none;
    }

    /// A left click on a title, on screen row `top`, makes its tab active.
    fn click(tabs: *Tabs, mouse: tui.input.Mouse) void {
        if (mouse.button != .left or mouse.action != .press or mouse.y != tabs.top) return;
        var x: usize = 0;
        for (tabs.titles, 0..) |title, i| {
            if (i > 0) x += tui.width.of(tabs.separator);
            const width = tui.width.of(title);
            if (mouse.x >= x and mouse.x < x + width) {
                tabs.active = i;
                return;
            }
            x += width;
        }
    }

    pub fn view(tabs: *const Tabs, w: *Writer) Writer.Error!void {
        for (tabs.titles, 0..) |title, i| {
            if (i > 0) try tabs.styles.separator.paint(w, tabs.separator);
            const style = if (i == tabs.active) tabs.styles.active else tabs.styles.inactive;
            try style.paint(w, title);
        }
        if (tabs.active < tabs.contents.len) {
            try w.writeByte('\n');
            try tabs.styles.content.render(w, tabs.contents[tabs.active]);
        }
    }
};

const testing = std.testing;
const Driver = tui.testing.Driver(Tabs);

test "switching tabs shows their content" {
    var d: Driver = try .init(testing.allocator, .{
        .titles = &.{ "One", "Two", "Three" },
        .contents = &.{ "first", "second", "third" },
    }, .{});
    defer d.deinit();
    try d.expectFrame("One │ Two │ Three\n╭───────╮\n│ first │\n╰───────╯");
    try d.press("right");
    try d.expectFrameContains("│ second │");
    try d.press("tab");
    try d.press("l");
    try testing.expectEqual(0, d.model().active); // wrapped around
    try d.press("left");
    try testing.expectEqual(2, d.model().active);
    try d.press("shift+tab");
    try d.press("h");
    try testing.expectEqual(0, d.model().active);
    try d.press("3");
    try testing.expectEqual(2, d.model().active);
    try d.press("9"); // no ninth tab
    try testing.expectEqual(2, d.model().active);
    try testing.expect(!d.done());
}

test "titles only, and the active one styled" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const tabs: Tabs = .{
        .titles = &.{ "a", "b" },
        .active = 1,
        .separator = "|",
        .styles = .{ .active = .{ .reverse = true }, .inactive = .{}, .separator = .{} },
    };
    try tabs.view(&w);
    try testing.expectEqualStrings("a|\x1b[7mb\x1b[0m", w.buffered());
}

test "no tabs" {
    var tabs: Tabs = .{ .titles = &.{} };
    try testing.expectEqual(0, tabs.update(.{ .key = .{ .code = .right } }).len);
}

test "the mouse: a click on a title switches to its tab" {
    var d: Driver = try .init(testing.allocator, .{
        .titles = &.{ "One", "Two", "Three" },
        .contents = &.{ "first", "second", "third" },
    }, .{});
    defer d.deinit();
    const second = tui.width.of("One") + tui.width.of(d.model().separator);
    try d.send(.{ .mouse = .{ .x = @intCast(second), .y = 0, .button = .left, .action = .press } });
    try testing.expectEqual(1, d.model().active);
    try d.send(.{ .mouse = .{ .x = 0, .y = 1, .button = .left, .action = .press } });
    try testing.expectEqual(1, d.model().active);
}
