//! `termancy ui choose`: pick one item (or several) from a list.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const plain = @import("plain.zig");
const styles = @import("styles.zig");
const List = @import("../tui/registry/list.zig");
const Select = @import("../tui/registry/select.zig");
const MultiSelect = @import("../tui/registry/multiselect.zig");

pub const Flags = struct {
    limit: usize = 1,
    no_limit: bool = false,
    header: []const u8 = "",
    selected: []const []const u8 = &.{},
    height: usize = 10,
    cursor: []const u8 = "> ",
    timeout: cfg.Duration = .zero,
    show_help: bool = true,
    padding: styles.Spacing = .{},
    strip_ansi: bool = true,
    input_delimiter: []const u8 = "\\n",
    output_delimiter: []const u8 = "\\n",
    cursor_style: styles.Styles = .{},
    header_style: styles.Styles = .{},
    item_style: styles.Styles = .{},
    selected_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field.Set(.{ field.Spec(Flags){ .fields = .{
    .limit = .{ .help = "The most items to choose; above 1, space chooses each" },
    .no_limit = .{ .help = "Choose any number of items" },
    .header = .{ .help = "Text above the items" },
    .selected = .{
        .help = "An item highlighted (or, with a limit, chosen) at the start; repeatable",
    },
    .height = .{ .help = "Items shown at once" },
    .cursor = .{ .help = "Written before the highlighted item" },
    .timeout = .{ .help = term.help.timeout },
    .show_help = .{ .help = term.help.show_help },
    .padding = .{ .help = term.help.padding },
    .strip_ansi = .{ .help = term.help.strip_ansi },
    .input_delimiter = .{ .help = term.help.input_delimiter },
    .output_delimiter = .{ .help = term.help.output_delimiter },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_CHOOSE_", .fields = .{
    .selected = .{ .value_name = "item", .split = ',' },
    .cursor_style = styles.group("cursor"),
    .header_style = styles.group("header"),
    .item_style = styles.hiddenGroup("item"),
    .selected_style = styles.group("selected"),
} });

pub const command = cli.command(.{
    .name = "choose",
    .summary = "Choose items from a list",
    .description =
    \\Show the items (the arguments, or standard input split at --input-delimiter) and
    \\print the one chosen. With --limit above 1 or --no-limit, space chooses each item
    \\and enter prints them all, in their original order, separated by
    \\--output-delimiter.
    \\
    \\Keys: up/down or j/k move, pgup/pgdown and home/end jump, enter chooses, esc
    \\cancels (status 1), Ctrl-C interrupts (status 130). The list is drawn on the
    \\terminal even when standard output is not one. --timeout ends with status 124.
    \\
    \\Style a part with --cursor.*, --header.*, --item.*, and --selected.* (foreground,
    \\background, bold, and the rest of `ui style`'s flags). Every flag can also come
    \\from a variable: TERMANCY_CHOOSE_HEIGHT, TERMANCY_CHOOSE_CURSOR_FOREGROUND.
    ,
    .flags = flags_flags,
    .args = .{ .max = null, .usage = "[item...]" },
    .examples =
    \\termancy ui choose red green blue
    \\git branch --format='%(refname:short)' | termancy ui choose --header "Branch?"
    \\termancy ui choose --limit 2 --output-delimiter , a b c d
    \\termancy ui choose --timeout 10s --cursor.foreground 212 yes no
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (flags.limit == 0) return ctx.usageError("--limit must be at least 1", .{});
    const items = try term.items(ctx, .{
        .strip_ansi = flags.strip_ansi,
        .delimiter = flags.input_delimiter,
    });
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const limit = if (flags.no_limit) items.len else flags.limit;
        const indexes = try session.choose(flags.header, items, limit) orelse
            return error.CommandFailed;
        const chosen = try ctx.arena.alloc([]const u8, indexes.len);
        for (chosen, indexes) |*item, i| item.* = items[i];
        return term.writeJoined(ctx.out, chosen, flags.output_delimiter);
    }
    const look: Look = try .of(ctx.arena, flags, ctx.theme);
    const options = term.timed(term.suspend_options, flags.timeout);
    if (flags.limit == 1 and !flags.no_limit) {
        var model = framed(ctx.gpa, single(items, flags, look), flags, &single_hints);
        if (try term.run(ctx, @TypeOf(model), &model, options)) return term.exitInterrupted(ctx);
        if (model.inner.status != .submitted) return error.CommandFailed;
        return term.writeJoined(ctx.out, &.{model.inner.selected().?}, flags.output_delimiter);
    }
    const inner = try multiple(ctx.gpa, items, flags, look);
    var model = framed(ctx.gpa, inner, flags, &multiple_hints);
    defer model.deinit();
    if (try term.run(ctx, @TypeOf(model), &model, options)) return term.exitInterrupted(ctx);
    if (model.inner.status != .submitted) return error.CommandFailed;
    try term.writeJoined(ctx.out, try chosenOf(ctx.arena, &model.inner), flags.output_delimiter);
}

/// How the parts look: the theme's, with the style flags over it.
pub const Look = struct {
    /// `--header` laid out in its style (a border or padding needs more than a span).
    header: []const u8,
    cursor: tui.Style,
    item: tui.Style,
    selected: tui.Style,
    /// The `chosen` count under a limit.
    count: tui.Style,

    pub fn of(arena: std.mem.Allocator, flags: Flags, theme: *const cli.Theme) !Look {
        const header = flags.header_style.over(theme.heading);
        return .{
            .header = try styles.render(arena, header, flags.header),
            .cursor = flags.cursor_style.over(theme.accent),
            .item = flags.item_style.over(.{}),
            .selected = flags.selected_style.over(theme.accent),
            .count = theme.note,
        };
    }
};

const navigate: term.Hint = .{ .keys = &.{ "up", "down" }, .action = .hint, .help = "navigate" };
const submit: term.Hint = .{ .keys = &.{"enter"}, .action = .hint, .help = "submit" };
const single_hints = [_]term.Hint{ navigate, submit };
const multiple_hints = [_]term.Hint{
    .{ .keys = &.{"space"}, .action = .hint, .help = "toggle" },
    navigate,
    submit,
    .{ .keys = &.{"a"}, .action = .hint, .help = "all" },
};

/// `inner` with the help line (unless `--no-show-help`) and `--padding`.
pub fn framed(
    gpa: std.mem.Allocator,
    inner: anytype,
    flags: Flags,
    hints: []const term.Hint,
) term.Framed(@TypeOf(inner)) {
    return .{
        .inner = inner,
        .gpa = gpa,
        .padding = flags.padding.sides,
        .hints = if (flags.show_help) hints else &.{},
    };
}

/// The single-choice model: the first `--selected` item highlighted.
pub fn single(items: []const []const u8, flags: Flags, look: Look) Select {
    var model: Select = .{
        .header = look.header,
        .list = list(items, flags, look),
        .styles = .{ .header = .{} },
    };
    if (flags.selected.len > 0) model.highlight(flags.selected[0]);
    return model;
}

/// The multiple-choice model: `--selected` items chosen, as many as the limit allows.
pub fn multiple(
    gpa: std.mem.Allocator,
    items: []const []const u8,
    flags: Flags,
    look: Look,
) std.mem.Allocator.Error!MultiSelect {
    var model: MultiSelect = try .init(gpa, list(items, flags, look));
    model.header = look.header;
    model.styles = .{ .header = .{}, .chosen = look.selected, .count = look.count };
    model.limit = if (flags.no_limit) null else flags.limit;
    for (flags.selected) |wanted| {
        for (items, 0..) |item, i| {
            if (std.mem.eql(u8, item, wanted) and !model.isChosen(i)) model.toggle(i);
        }
    }
    return model;
}

fn list(items: []const []const u8, flags: Flags, look: Look) List {
    return .{
        .items = items,
        .height = @max(flags.height, 1),
        .cursor_prefix = flags.cursor,
        .item_prefix = spaces[0..@min(tui.width.of(flags.cursor), spaces.len)],
        .styles = .{ .cursor = look.cursor, .item = look.item },
    };
}

const spaces: [16]u8 = @splat(' ');

/// The chosen items, in their original order.
pub fn chosenOf(
    arena: std.mem.Allocator,
    model: *const MultiSelect,
) std.mem.Allocator.Error![]const []const u8 {
    var chosen: std.ArrayList([]const u8) = .empty;
    for (model.list.items, 0..) |item, i| {
        if (model.isChosen(i)) try chosen.append(arena, item);
    }
    return chosen.items;
}

const testing = std.testing;
const colors = [_][]const u8{ "red", "green", "blue" };

fn lookOf(arena: *std.heap.ArenaAllocator, flags: Flags) !Look {
    return .of(arena.allocator(), flags, &cli.Theme.default);
}

test "one choice: the --selected item starts highlighted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: tui.testing.Driver(Select) = undefined;
    const flags: Flags = .{ .selected = &.{"green"}, .cursor = "→ " };
    d = try .init(testing.allocator, single(&colors, flags, try lookOf(&arena, flags)), .{});
    defer d.deinit();
    try d.expectFrame("  red\n→ green\n  blue");
    try d.press("down");
    try d.press("enter");
    try testing.expectEqualStrings("blue", d.model().selected().?);
}

test "several choices, printed in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .limit = 2, .selected = &.{ "blue", "red", "green" } };
    var d: tui.testing.Driver(MultiSelect) = try .init(
        testing.allocator,
        try multiple(testing.allocator, &colors, flags, try lookOf(&arena, flags)),
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
    try term.writeJoined(&out.writer, try chosenOf(arena.allocator(), d.model()), ", ");
    try testing.expectEqualStrings("green, blue\n", out.written());
}

test "no limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .no_limit = true, .height = 0 };
    var model = try multiple(testing.allocator, &colors, flags, try lookOf(&arena, flags));
    defer model.deinit();
    try testing.expectEqual(null, model.limit);
    try testing.expectEqual(1, model.list.height);
}

test "the help line and --padding around the list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .header = "Color?", .padding = try .parse("1 2") };
    const look = try lookOf(&arena, flags);
    const model = framed(testing.allocator, single(&colors, flags, look), flags, &single_hints);
    var d: tui.testing.Driver(@TypeOf(model)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    const blank: [31]u8 = @splat(' ');
    try d.expectFrame(blank ++ "\n" ++
        "  Color?                       \n" ++
        "  > red                        \n" ++
        "    green                      \n" ++
        "    blue                       \n" ++
        blank ++ "\n" ++
        "  ↑/↓ navigate • enter submit  \n" ++
        blank);
    // The list fits inside the padding.
    try testing.expectEqual(76, d.model().inner.list.width);
    try d.press("down");
    try d.press("enter");
    try testing.expectEqualStrings("green", d.model().inner.selected().?);
}

test "--no-show-help, and several choices framed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .no_limit = true, .show_help = false };
    const look = try lookOf(&arena, flags);
    const inner = try multiple(testing.allocator, &colors, flags, look);
    const model = framed(testing.allocator, inner, flags, &multiple_hints);
    var d: tui.testing.Driver(@TypeOf(model)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("> • red\n  • green\n  • blue");
}

test "the style flags reach the parts, over the theme" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{
        .header = "Pick",
        .cursor_style = .{ .foreground = .{ .indexed = 212 } },
        .header_style = .{ .bold = false, .border = .ascii },
        .item_style = .{ .italic = true },
    };
    const look = try lookOf(&arena, flags);
    try testing.expectEqual(tui.Color{ .indexed = 212 }, look.cursor.fg);
    try testing.expectEqual(cli.Theme.default.accent, look.selected);
    try testing.expect(look.item.italic);
    // The theme's heading color, not bold, in a border.
    try testing.expectEqualStrings("+----+\n|\x1b[35mPick\x1b[0m|\n+----+", look.header);
    const model = single(&colors, flags, look);
    try testing.expectEqual(look.cursor, model.list.styles.cursor);
    try testing.expectEqual(look.item, model.list.styles.item);
}
