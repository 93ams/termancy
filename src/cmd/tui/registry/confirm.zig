//! A yes/no question with two buttons.
//!
//! ```zig
//! var confirm: Confirm = .{ .prompt = "Delete it?" };
//! if (try tui.run(gpa, io, &confirm, .{ .environ = environ }) != 0) return;
//! if (confirm.status == .submitted and confirm.value) deleteIt();
//! ```
//!
//! Keys: left/right, h/l, tab, and ctrl+n/ctrl+p move between the buttons; enter answers
//! with the one highlighted; y answers yes and n (or q) no directly; esc cancels. The
//! answer is `value` once `status` is `.submitted`. An empty `negative` hides its button:
//! the question then has one answer, or none but esc.

const std = @import("std");
const tui = @import("tui");

pub const Status = enum { active, submitted, canceled };

const Confirm = @This();

prompt: []const u8 = "Are you sure?",
affirmative: []const u8 = "Yes",
negative: []const u8 = "No",
/// The highlighted button: true for `affirmative`. Its starting value is the default.
value: bool = true,
/// Between the buttons; gum's command leaves it empty, spacing them with margins.
gap: []const u8 = "  ",
/// The screen row this is drawn from, for mouse clicks.
top: usize = 0,
status: Status = .active,
styles: Styles = .{},

pub const Styles = struct {
    prompt: tui.Style = .{ .bold = true },
    /// Bold and underlined as well as colored, so it stands out under `NO_COLOR`.
    selected: tui.Style = .{
        .fg = .{ .indexed = 230 },
        .bg = .{ .indexed = 212 },
        .bold = true,
        .underline = true,
        .padding = .symmetric(0, 3),
    },
    unselected: tui.Style = .{
        .fg = .{ .indexed = 254 },
        .bg = .{ .indexed = 235 },
        .padding = .symmetric(0, 3),
    },
};

pub fn update(model: *Confirm, msg: tui.Msg) tui.Cmd {
    const key = switch (msg) {
        .key => |key| key,
        .mouse => |mouse| return model.click(mouse),
        else => return .none,
    };
    if (key.matches("left") or key.matches("right") or key.matches("tab") or
        key.matches("shift+tab") or key.matches("h") or key.matches("l") or
        key.matches("ctrl+n") or key.matches("ctrl+p"))
    {
        if (model.negative.len > 0) model.value = !model.value;
    } else if (key.matches("y") or key.matches("Y")) {
        return model.answer(true);
    } else if (key.matches("n") or key.matches("N") or key.matches("q")) {
        return model.answer(false);
    } else if (key.matches("enter")) {
        return model.answer(model.value);
    } else if (key.matches("esc")) {
        model.status = .canceled;
        return .quit;
    }
    return .none;
}

/// A left click on a button answers with it. The buttons are two rows below the prompt,
/// which starts on screen row `top`.
fn click(model: *Confirm, mouse: tui.input.Mouse) tui.Cmd {
    if (mouse.button != .left or mouse.action != .press) return .none;
    if (mouse.y != model.top + 2) return .none;
    const first = buttonWidth(model, model.affirmative, model.value);
    if (mouse.x < first) return model.answer(true);
    if (model.negative.len == 0) return .none;
    const second = buttonWidth(model, model.negative, !model.value);
    const gap = tui.width.of(model.gap);
    if (mouse.x >= first + gap and mouse.x < first + gap + second) return model.answer(false);
    return .none;
}

fn buttonWidth(model: *const Confirm, label: []const u8, selected: bool) usize {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    model.button(&w, label, selected) catch return label.len;
    var plain: [256]u8 = undefined;
    var stripped: std.Io.Writer = .fixed(&plain);
    tui.ansi.strip(&stripped, w.buffered()) catch return label.len;
    return tui.width.of(stripped.buffered());
}

fn answer(model: *Confirm, value: bool) tui.Cmd {
    model.value = value;
    model.status = .submitted;
    return .quit;
}

pub fn view(model: *const Confirm, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try model.styles.prompt.render(w, model.prompt);
    try w.writeAll("\n\n");
    try model.button(w, model.affirmative, model.value);
    if (model.negative.len == 0) return;
    try w.writeAll(model.gap);
    try model.button(w, model.negative, !model.value);
}

fn button(
    model: *const Confirm,
    w: *std.Io.Writer,
    label: []const u8,
    selected: bool,
) std.Io.Writer.Error!void {
    const style = if (selected) model.styles.selected else model.styles.unselected;
    try style.render(w, label);
}

const testing = std.testing;
const Driver = tui.testing.Driver(Confirm);

test "enter answers with the highlighted button" {
    var d: Driver = try .init(testing.allocator, .{ .prompt = "Continue?" }, .{});
    defer d.deinit();
    try d.expectFrame("Continue?\n\n   Yes        No   ");
    try d.press("right");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expect(!d.model().value);
}

test "y and n answer at once" {
    var d: Driver = try .init(testing.allocator, .{ .value = false }, .{});
    defer d.deinit();
    try d.press("y");
    try testing.expect(d.done() and d.model().value);

    var n: Driver = try .init(testing.allocator, .{}, .{});
    defer n.deinit();
    try n.press("N");
    try testing.expect(n.done() and !n.model().value);
}

test "the arrows toggle, esc cancels" {
    var d: Driver = try .init(
        testing.allocator,
        .{ .affirmative = "Do it", .negative = "Stop" },
        .{},
    );
    defer d.deinit();
    try d.press("tab");
    try testing.expect(!d.model().value);
    try d.press("h");
    try testing.expect(d.model().value);
    try d.press("esc");
    try testing.expect(d.done());
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "q answers no; an empty negative hides its button and cannot be toggled to" {
    var d: Driver = try .init(testing.allocator, .{}, .{});
    defer d.deinit();
    try d.press("ctrl+n");
    try testing.expect(!d.model().value);
    try d.press("q");
    try testing.expect(d.done() and !d.model().value);

    var one: Driver = try .init(testing.allocator, .{ .prompt = "OK?", .negative = "" }, .{});
    defer one.deinit();
    try one.expectFrame("OK?\n\n   Yes   ");
    try one.press("right");
    try testing.expect(one.model().value);
    try one.send(.{ .mouse = .{ .x = 20, .y = 2, .button = .left, .action = .press } });
    try testing.expect(!one.done());
}

test "the highlighted button is styled" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const model: Confirm = .{ .styles = .{
        .prompt = .{},
        .selected = .{ .reverse = true },
        .unselected = .{},
    } };
    try model.view(&w);
    try testing.expectEqualStrings("Are you sure?\n\n\x1b[7mYes\x1b[0m  No", w.buffered());
}

test "the mouse: a click on a button answers" {
    var d: Driver = try .init(testing.allocator, .{ .prompt = "Sure?" }, .{});
    defer d.deinit();
    // Not on the buttons' row: nothing.
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .left, .action = .press } });
    try testing.expect(!d.done());
    try d.send(.{ .mouse = .{ .x = 0, .y = 2, .button = .left, .action = .press } });
    try testing.expect(d.done());
    try testing.expect(d.model().value);

    var e: Driver = try .init(testing.allocator, .{ .prompt = "Sure?", .value = true }, .{});
    defer e.deinit();
    const first = e.model().buttonWidth(e.model().affirmative, true);
    try e.send(.{ .mouse = .{
        .x = @intCast(first + 2),
        .y = 2,
        .button = .left,
        .action = .press,
    } });
    try testing.expect(e.done());
    try testing.expect(!e.model().value);
}
