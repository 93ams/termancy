//! `termancy ui choose`: pick one item (or several) from a list.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const plain = @import("plain.zig");
const List = @import("../tui/registry/list.zig").List;
const Select = @import("../tui/registry/select.zig").Select;
const MultiSelect = @import("../tui/registry/multiselect.zig").MultiSelect;

pub const Flags = struct {
    limit: usize = 1,
    no_limit: bool = false,
    header: []const u8 = "",
    selected: []const []const u8 = &.{},
    height: usize = 10,
    cursor: []const u8 = "> ",
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .limit = .{ .help = "The most items to choose; above 1, space chooses each" },
    .no_limit = .{ .help = "Choose any number of items" },
    .header = .{ .help = "Text above the items" },
    .selected = .{
        .help = "An item highlighted (or, with a limit, chosen) at the start; repeatable",
    },
    .height = .{ .help = "Items shown at once" },
    .cursor = .{ .help = "Written before the highlighted item" },
} }}), .{ .fields = .{
    .selected = .{ .value_name = "item", .split = ',' },
} });

pub const command = cli.command(.{
    .name = "choose",
    .summary = "Choose items from a list",
    .description =
    \\Show the items (the arguments, or the lines of standard input) and print the one
    \\chosen. With --limit above 1 or --no-limit, space chooses each item and enter
    \\prints them all, one per line, in their original order.
    \\
    \\Keys: up/down or j/k move, pgup/pgdown and home/end jump, enter chooses, esc
    \\cancels (status 1), Ctrl-C interrupts (status 130). The list is drawn on the
    \\terminal even when standard output is not one.
    ,
    .flags = flags_flags,
    .args = .{ .max = null, .usage = "[item...]" },
    .examples =
    \\termancy ui choose red green blue
    \\git branch --format='%(refname:short)' | termancy ui choose --header "Branch?"
    \\termancy ui choose --limit 2 a b c d
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (flags.limit == 0) return ctx.usageError("--limit must be at least 1", .{});
    const items = try term.items(ctx);
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const limit = if (flags.no_limit) items.len else flags.limit;
        const chosen = try session.choose(flags.header, items, limit) orelse
            return error.CommandFailed;
        for (chosen) |i| try ctx.out.print("{s}\n", .{items[i]});
        return;
    }
    if (flags.limit == 1 and !flags.no_limit) {
        var model = single(items, flags);
        const interrupted = try term.run(ctx, Select, &model, term.suspend_options);
        if (interrupted) return term.exitInterrupted(ctx);
        if (model.status != .submitted) return error.CommandFailed;
        try ctx.out.print("{s}\n", .{model.selected().?});
        return;
    }
    var model = try multiple(ctx.gpa, items, flags);
    defer model.deinit();
    const interrupted = try term.run(ctx, MultiSelect, &model, term.suspend_options);
    if (interrupted) return term.exitInterrupted(ctx);
    if (model.status != .submitted) return error.CommandFailed;
    try writeChosen(ctx.out, &model);
}

/// The single-choice model: the first `--selected` item highlighted.
pub fn single(items: []const []const u8, flags: Flags) Select {
    var model: Select = .{ .header = flags.header, .list = list(items, flags) };
    if (flags.selected.len > 0) model.highlight(flags.selected[0]);
    return model;
}

/// The multiple-choice model: `--selected` items chosen, as many as the limit allows.
pub fn multiple(
    gpa: std.mem.Allocator,
    items: []const []const u8,
    flags: Flags,
) std.mem.Allocator.Error!MultiSelect {
    var model: MultiSelect = try .init(gpa, list(items, flags));
    model.header = flags.header;
    model.limit = if (flags.no_limit) null else flags.limit;
    for (flags.selected) |wanted| {
        for (items, 0..) |item, i| {
            if (std.mem.eql(u8, item, wanted) and !model.isChosen(i)) model.toggle(i);
        }
    }
    return model;
}

fn list(items: []const []const u8, flags: Flags) List {
    return .{
        .items = items,
        .height = @max(flags.height, 1),
        .cursor_prefix = flags.cursor,
        .item_prefix = spaces[0..@min(tui.width.of(flags.cursor), spaces.len)],
    };
}

const spaces: [16]u8 = @splat(' ');

/// Writes the chosen items, one per line, in their original order.
pub fn writeChosen(w: *std.Io.Writer, model: *const MultiSelect) std.Io.Writer.Error!void {
    for (model.list.items, 0..) |item, i| {
        if (model.isChosen(i)) try w.print("{s}\n", .{item});
    }
}

const testing = std.testing;
const colors = [_][]const u8{ "red", "green", "blue" };

test "one choice: the --selected item starts highlighted" {
    var d: tui.testing.Driver(Select) = undefined;
    const flags: Flags = .{ .selected = &.{"green"}, .cursor = "→ " };
    d = try .init(testing.allocator, single(&colors, flags), .{});
    defer d.deinit();
    try d.expectFrame("  red\n→ green\n  blue");
    try d.press("down");
    try d.press("enter");
    try testing.expectEqualStrings("blue", d.model().selected().?);
}

test "several choices, printed in order" {
    const flags: Flags = .{ .limit = 2, .selected = &.{ "blue", "red", "green" } };
    var d: tui.testing.Driver(MultiSelect) = try .init(
        testing.allocator,
        try multiple(testing.allocator, &colors, flags),
        .{},
    );
    defer d.deinit();
    // red and blue fit under the limit; green does not.
    try d.expectFrame("> ✓ red\n  • green\n  ✓ blue\n2/2 chosen");
    try d.press("space");
    try d.press("down");
    try d.press("space");
    try d.press("enter");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeChosen(&out.writer, d.model());
    try testing.expectEqualStrings("green\nblue\n", out.written());
}

test "no limit" {
    var model = try multiple(testing.allocator, &colors, .{ .no_limit = true, .height = 0 });
    defer model.deinit();
    try testing.expectEqual(null, model.limit);
    try testing.expectEqual(1, model.list.height);
}
