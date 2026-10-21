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
    ordered: bool = false,
    select_if_one: bool = false,
    header: []const u8 = "Choose:",
    selected: []const []const u8 = &.{},
    height: usize = 10,
    cursor: []const u8 = "> ",
    cursor_prefix: []const u8 = "• ",
    selected_prefix: []const u8 = "✓ ",
    unselected_prefix: []const u8 = "• ",
    label_delimiter: []const u8 = "",
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
    .no_limit = .{ .help = "Choose any number of items; a chooses them all" },
    .ordered = .{ .help = "Sort the items, and print several in the order chosen" },
    .select_if_one = .{ .help = "Print the only item without asking (no terminal needed)" },
    .header = .{ .help = "Text above the items" },
    .selected = .{
        .help = "Items chosen at the start (with --limit 1, highlighted); * for all; repeatable",
    },
    .height = .{ .help = "Items shown at once" },
    .cursor = .{ .help = "Written before the highlighted item" },
    .cursor_prefix = .{ .help = "Mark of the highlighted item, when several can be chosen" },
    .selected_prefix = .{ .help = "Mark of a chosen item, when several can be chosen" },
    .unselected_prefix = .{ .help = "Mark of the other items, when several can be chosen" },
    .label_delimiter = .{
        .help = "Cuts each item into a label to show and a value to print (Red:#f00)",
    },
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
    \\and enter prints them all, in list order (with --ordered, in the order chosen),
    \\separated by --output-delimiter.
    \\
    \\--selected chooses items at the start (with --limit 1, it highlights the first);
    \\"*" chooses them all, up to the limit. When the items are arguments, piped standard
    \\input names the items selected. With --label-delimiter, each item is a label to show
    \\and a value to print: "Red:#f00". --ordered sorts the items by label.
    \\--select-if-one prints a lone item at once, with no terminal at all.
    \\
    \\Keys: up/down or j/k move (round past either end), left/right (h/l, pgup/pgdown) page,
    \\home/end jump, space (tab, x) chooses, ctrl+a (a) chooses them all (with --no-limit),
    \\enter (ctrl+q) prints, esc cancels (status 1), Ctrl-C
    \\interrupts (status 130). The list is drawn on the terminal even when standard output
    \\is not one. --timeout ends with status 124.
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
    \\termancy ui choose --label-delimiter : "Red:#f00" "Green:#0f0" "Blue:#00f"
    \\printf 'b\nc\n' | termancy ui choose --no-limit --ordered a b c d
    \\termancy ui choose --select-if-one $(git branch --format='%(refname:short)')
    \\termancy ui choose --timeout 10s --cursor.foreground 212 yes no
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (flags.limit == 0) return ctx.usageError("--limit must be at least 1", .{});
    const input: term.Input = .{
        .strip_ansi = flags.strip_ansi,
        .delimiter = flags.input_delimiter,
    };
    var selected = flags.selected;
    // As gum: with the items as arguments, piped standard input names those selected.
    if (ctx.args.len > 0 and selected.len == 0) {
        selected = try term.stdinItems(ctx, input) orelse &.{};
    }
    const options: Options = try .of(ctx, try term.items(ctx, input), flags);
    if (flags.select_if_one and options.labels.len == 1) {
        return term.writeJoined(ctx.out, options.values, flags.output_delimiter);
    }
    const several = flags.no_limit or flags.limit > 1;
    const limit = if (flags.no_limit) options.labels.len else flags.limit;
    const preset = try preselected(ctx.arena, options.labels, selected, limit);
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const chosen = try session.choose(flags.header, options.labels, limit, preset) orelse
            return error.CommandFailed;
        if (!flags.ordered) std.mem.sort(usize, chosen, {}, std.sort.asc(usize));
        return options.write(ctx, chosen, flags);
    }
    const look: Look = try .of(ctx.arena, flags, ctx.theme);
    const run_options = term.timed(term.suspend_options, flags.timeout);
    if (!several) {
        const inner = single(options.labels, preset, flags, look);
        var model = framed(ctx.gpa, inner, flags, &single_hints);
        const interrupted = try term.run(ctx, @TypeOf(model), &model, run_options);
        if (interrupted) return term.exitInterrupted(ctx);
        if (model.inner.status != .submitted) return error.CommandFailed;
        return options.write(ctx, &.{model.inner.list.cursor}, flags);
    }
    const inner = try multiple(ctx.gpa, options.labels, preset, flags, look);
    const hints: []const term.Hint = if (flags.no_limit) &all_hints else &multiple_hints;
    var model = framed(ctx.gpa, inner, flags, hints);
    defer model.deinit();
    if (try term.run(ctx, @TypeOf(model), &model, run_options)) return term.exitInterrupted(ctx);
    if (model.inner.status != .submitted) return error.CommandFailed;
    try options.write(ctx, try chosenOf(ctx.arena, &model.inner, flags.ordered), flags);
}

/// The items as shown (`labels`) and as printed (`values`): the same unless
/// `--label-delimiter` cuts each in two; sorted by label with `--ordered`.
pub const Options = struct {
    labels: []const []const u8,
    values: []const []const u8,

    const Pair = [2][]const u8;

    pub fn of(ctx: *cli.Context, items: []const []const u8, flags: Flags) !Options {
        const delimiter = try term.unescape(ctx.arena, flags.label_delimiter);
        const pairs = try ctx.arena.alloc(Pair, items.len);
        for (pairs, items) |*pair, item| {
            if (delimiter.len == 0) {
                pair.* = .{ item, item };
                continue;
            }
            const at = std.mem.indexOf(u8, item, delimiter) orelse return ctx.fail(
                "item \"{s}\" has no --label-delimiter \"{s}\"",
                .{ item, delimiter },
            );
            pair.* = .{ item[0..at], item[at + delimiter.len ..] };
        }
        if (flags.ordered) std.mem.sort(Pair, pairs, {}, byLabel);
        const labels = try ctx.arena.alloc([]const u8, items.len);
        const values = try ctx.arena.alloc([]const u8, items.len);
        for (pairs, labels, values) |pair, *label, *value| {
            label.* = pair[0];
            value.* = pair[1];
        }
        return .{ .labels = labels, .values = values };
    }

    fn byLabel(_: void, a: Pair, b: Pair) bool {
        return std.mem.lessThan(u8, a[0], b[0]);
    }

    /// Prints the values of items `indexes`, separated by `--output-delimiter`.
    fn write(options: Options, ctx: *cli.Context, indexes: []const usize, flags: Flags) !void {
        const values = try ctx.arena.alloc([]const u8, indexes.len);
        for (values, indexes) |*value, i| value.* = options.values[i];
        try term.writeJoined(ctx.out, values, flags.output_delimiter);
    }
};

/// The indexes of the items `selected` names (all of them for `*`), in list order, at
/// most `limit`.
pub fn preselected(
    arena: std.mem.Allocator,
    labels: []const []const u8,
    selected: []const []const u8,
    limit: usize,
) std.mem.Allocator.Error![]usize {
    const all = selected.len == 1 and std.mem.eql(u8, selected[0], "*");
    var found: std.ArrayList(usize) = .empty;
    for (labels, 0..) |label, i| {
        if (found.items.len == limit) break;
        const named = for (selected) |name| {
            if (std.mem.eql(u8, name, label)) break true;
        } else false;
        if (all or named) try found.append(arena, i);
    }
    return found.items;
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
};
const all_hints = multiple_hints ++ [_]term.Hint{
    .{ .keys = &.{"ctrl+a"}, .action = .hint, .help = "select all" },
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

/// The single-choice model: the first `preset` item highlighted.
pub fn single(
    labels: []const []const u8,
    preset: []const usize,
    flags: Flags,
    look: Look,
) Select {
    var model: Select = .{
        .header = look.header,
        .list = list(labels, flags, look),
        .styles = .{ .header = .{} },
    };
    if (preset.len > 0) model.list.moveTo(preset[0]);
    return model;
}

/// The multiple-choice model: the `preset` items chosen, in their order.
pub fn multiple(
    gpa: std.mem.Allocator,
    labels: []const []const u8,
    preset: []const usize,
    flags: Flags,
    look: Look,
) std.mem.Allocator.Error!MultiSelect {
    var model: MultiSelect = try .init(gpa, list(labels, flags, look));
    model.header = look.header;
    model.styles = .{ .header = .{}, .chosen = look.selected, .count = look.count };
    model.limit = if (flags.no_limit) null else flags.limit;
    // As gum, choosing them all is for --no-limit.
    model.toggle_all = flags.no_limit;
    model.cursor_mark = flags.cursor_prefix;
    model.chosen_mark = flags.selected_prefix;
    model.unchosen_mark = flags.unselected_prefix;
    for (preset) |i| model.toggle(i);
    return model;
}

fn list(labels: []const []const u8, flags: Flags, look: Look) List {
    return .{
        .items = labels,
        .height = @max(flags.height, 1),
        .cursor_prefix = flags.cursor,
        .item_prefix = spaces[0..@min(tui.width.of(flags.cursor), spaces.len)],
        .styles = .{ .cursor = look.cursor, .item = look.item },
        .wrap = true,
    };
}

const spaces: [16]u8 = @splat(' ');

/// The chosen items' indexes: in the order chosen when `ordered`, else in list order.
pub fn chosenOf(
    arena: std.mem.Allocator,
    model: *const MultiSelect,
    ordered: bool,
) std.mem.Allocator.Error![]const usize {
    if (ordered) return model.order.items;
    var chosen: std.ArrayList(usize) = .empty;
    for (model.chosen, 0..) |on, i| {
        if (on) try chosen.append(arena, i);
    }
    return chosen.items;
}

const testing = std.testing;
const colors = [_][]const u8{ "red", "green", "blue" };

fn lookOf(arena: *std.heap.ArenaAllocator, flags: Flags) !Look {
    return .of(arena.allocator(), flags, &cli.Theme.default);
}

test "one choice: the first --selected item starts highlighted, under gum's header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .selected = &.{ "blue", "green" }, .cursor = "→ " };
    const preset = try preselected(arena.allocator(), &colors, flags.selected, 1);
    const model = single(&colors, preset, flags, try lookOf(&arena, flags));
    var d: tui.testing.Driver(Select) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("Choose:\n  red\n→ green\n  blue");
    try d.press("down");
    try d.press("enter");
    try testing.expectEqualStrings("blue", d.model().selected().?);
}

test "preselected: in list order, up to the limit; * for all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blue_red = [_][]const u8{ "blue", "red" };
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, try preselected(a, &colors, &blue_red, 5));
    try testing.expectEqualSlices(usize, &.{0}, try preselected(a, &colors, &blue_red, 1));
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, try preselected(a, &colors, &.{"*"}, 2));
    // "*" among others is an item's name.
    try testing.expectEqualSlices(usize, &.{0}, try preselected(a, &colors, &.{ "*", "red" }, 3));
}

test "several choices, printed in list order or in the order chosen" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .limit = 2, .header = "", .selected = &.{ "blue", "red", "green" } };
    const preset = try preselected(arena.allocator(), &colors, flags.selected, 2);
    var d: tui.testing.Driver(MultiSelect) = try .init(
        testing.allocator,
        try multiple(testing.allocator, &colors, preset, flags, try lookOf(&arena, flags)),
        .{},
    );
    defer d.deinit();
    // red and green fit under the limit; blue does not.
    try d.expectFrame("> ✓ red\n  ✓ green\n  • blue\n2/2 chosen");
    try d.press("space"); // clears red
    try d.press("end");
    try d.press("space"); // blue
    try d.press("up");
    try d.press("space"); // clears green
    try d.press("space"); // green again, after blue
    try d.press("a"); // only with --no-limit
    try d.press("enter");
    const a = arena.allocator();
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, try chosenOf(a, d.model(), false));
    try testing.expectEqualSlices(usize, &.{ 2, 1 }, try chosenOf(a, d.model(), true));
}

test "the marks: highlighted, chosen, and the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{
        .no_limit = true,
        .header = "",
        .cursor_prefix = "[ ] ",
        .selected_prefix = "[x] ",
        .unselected_prefix = "    ",
    };
    var d: tui.testing.Driver(MultiSelect) = try .init(
        testing.allocator,
        try multiple(testing.allocator, &colors, &.{2}, flags, try lookOf(&arena, flags)),
        .{},
    );
    defer d.deinit();
    try d.expectFrame("> [ ] red\n      green\n  [x] blue");
    try d.press("a");
    try testing.expectEqualSlices(usize, &.{ 2, 0, 1 }, d.model().order.items);
}

test "--select-if-one prints the value, without a terminal; labels need the delimiter" {
    const app: cli.App = .{ .root = &command, .completion_command = false };
    const args = [_][]const u8{ "--select-if-one", "--selected", "x", "--label-delimiter", "\\t" };
    const one = try cli.testing.run(app, &(args ++ .{"One\t1"}), .{});
    defer one.deinit();
    try one.expect(0, "1\n", "");
    const bad = try cli.testing.run(app, &(args ++ .{ "a\t1", "b" }), .{});
    defer bad.deinit();
    try testing.expectEqual(1, bad.status);
    const message = "item \"b\" has no --label-delimiter \"\t\"\n";
    try testing.expect(std.mem.endsWith(u8, bad.err, message));
}

test "gum's keys: round past the ends, ctrl+a for all, ctrl+q to print" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .no_limit = true };
    const inner = try multiple(testing.allocator, &colors, &.{}, flags, try lookOf(&arena, flags));
    var d: tui.testing.Driver(MultiSelect) = try .init(testing.allocator, inner, .{});
    defer d.deinit();
    try d.press("up");
    try testing.expectEqual(2, d.model().list.cursor);
    try d.press("down");
    try testing.expectEqual(0, d.model().list.cursor);
    try d.press("ctrl+a");
    try d.press("ctrl+q");
    try testing.expect(d.done());
    try testing.expectEqual(3, d.model().count());
}

test "no limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .no_limit = true, .height = 0 };
    var model = try multiple(testing.allocator, &colors, &.{}, flags, try lookOf(&arena, flags));
    defer model.deinit();
    try testing.expectEqual(null, model.limit);
    try testing.expect(model.toggle_all);
    try testing.expectEqual(1, model.list.height);
}

test "the help line and --padding around the list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .header = "Color?", .padding = try .parse("1 2") };
    const look = try lookOf(&arena, flags);
    const inner = single(&colors, &.{}, flags, look);
    const model = framed(testing.allocator, inner, flags, &single_hints);
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
    const inner = try multiple(testing.allocator, &colors, &.{}, flags, look);
    const model = framed(testing.allocator, inner, flags, &all_hints);
    var d: tui.testing.Driver(@TypeOf(model)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("Choose:\n> • red\n  • green\n  • blue");
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
    const model = single(&colors, &.{}, flags, look);
    try testing.expectEqual(look.cursor, model.list.styles.cursor);
    try testing.expectEqual(look.item, model.list.styles.item);
}
