//! `termancy ui filter`: fuzzy-find items by typing.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const styles = @import("styles.zig");
const choose = @import("choose.zig");
const plain = @import("plain.zig");
const Filter = @import("../tui/registry/filter.zig");

pub const Flags = struct {
    indicator: []const u8 = "•",
    limit: usize = 1,
    no_limit: bool = false,
    select_if_one: bool = false,
    selected: []const []const u8 = &.{},
    strict: bool = true,
    selected_prefix: []const u8 = " ◉ ",
    unselected_prefix: []const u8 = " ○ ",
    header: []const u8 = "",
    placeholder: []const u8 = "Filter...",
    prompt: []const u8 = "> ",
    width: usize = 0,
    height: usize = 0,
    value: []const u8 = "",
    reverse: bool = false,
    fuzzy: bool = true,
    fuzzy_sort: bool = true,
    timeout: cfg.Duration = .zero,
    show_help: bool = true,
    padding: styles.Spacing = .{},
    strip_ansi: bool = true,
    input_delimiter: []const u8 = "\\n",
    output_delimiter: []const u8 = "\\n",
    indicator_style: styles.Styles = .{},
    selected_indicator_style: styles.Styles = .{},
    unselected_prefix_style: styles.Styles = .{},
    header_style: styles.Styles = .{},
    text_style: styles.Styles = .{},
    cursor_text_style: styles.Styles = .{},
    match_style: styles.Styles = .{},
    prompt_style: styles.Styles = .{},
    placeholder_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field.Set(.{ field.Spec(Flags){ .fields = .{
    .indicator = .{ .help = "Written before the highlighted item" },
    .limit = .{ .help = "The most items to choose; above 1, tab chooses each" },
    .no_limit = .{ .help = "Choose any number of items" },
    .select_if_one = .{ .help = "Print the only match without asking (no terminal needed)" },
    .selected = .{
        .help = "Items chosen at the start (with --limit 1, highlighted); * for all; repeatable",
    },
    .strict = .{ .help = "Print only a match; --no-strict can print the typed text" },
    .selected_prefix = .{ .help = "Mark of a chosen item, when several can be chosen" },
    .unselected_prefix = .{ .help = "Mark of the other items, when several can be chosen" },
    .header = .{ .help = "Text above the query" },
    .placeholder = .{ .help = "Shown while the query is empty" },
    .prompt = .{ .help = "Written before the query" },
    .width = .{ .help = "The most columns to use (0 for the terminal's width)" },
    .height = .{ .help = "Items shown at once (0 fills the terminal)" },
    .value = .{ .help = "The query to start with" },
    .reverse = .{ .help = "Draw from the bottom up, the query last" },
    .fuzzy = .{ .help = "Match characters in order; --no-fuzzy matches the query as typed" },
    .fuzzy_sort = .{ .help = "Sort fuzzy matches best first" },
    .timeout = .{ .help = term.help.timeout },
    .show_help = .{ .help = term.help.show_help },
    .padding = .{ .help = term.help.padding },
    .strip_ansi = .{ .help = term.help.strip_ansi },
    .input_delimiter = .{ .help = term.help.input_delimiter },
    .output_delimiter = .{ .help = term.help.output_delimiter },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_FILTER_", .fields = .{
    .selected = .{ .value_name = "item", .split = ',' },
    .indicator_style = styles.group("indicator"),
    .selected_indicator_style = styles.group("selected-indicator"),
    .unselected_prefix_style = styles.group("unselected-prefix"),
    .header_style = styles.group("header"),
    .text_style = styles.group("text"),
    .cursor_text_style = styles.group("cursor-text"),
    .match_style = styles.group("match"),
    .prompt_style = styles.group("prompt"),
    .placeholder_style = styles.group("placeholder"),
} });

pub const command = cli.command(.{
    .name = "filter",
    .summary = "Fuzzy-find items by typing",
    .description =
    \\Show the items (the arguments, or standard input split at --input-delimiter) and
    \\narrow them as you type: an item matches when it contains the query's characters in
    \\order, best matches first (--no-fuzzy-sort keeps their order), matched characters
    \\highlighted. Case is ignored unless the query has an uppercase letter. --no-fuzzy
    \\matches the query as typed, anywhere in an item, ignoring case. Prints the chosen
    \\item; with --limit above 1 or --no-limit, tab chooses each and enter prints them all,
    \\in their original order, separated by --output-delimiter.
    \\
    \\Enter prints only a match (--strict); with --no-strict, the typed text is offered
    \\first, to print as it is. --selected chooses items at the start (with --limit 1, it
    \\highlights the first); "*" chooses them all, up to the limit. --select-if-one prints
    \\the only match of --value at once, with no terminal at all. --height 0, the default,
    \\fills the terminal (on the alternate screen); --reverse puts the query at the bottom.
    \\
    \\Keys: typing edits the query, up/down (ctrl+p/ctrl+n) move, round past either end,
    \\tab and shift+tab choose, ctrl+a chooses all, enter (ctrl+q) prints, esc cancels
    \\(status 1), Ctrl-C interrupts (status 130). --timeout ends with status 124.
    \\
    \\With ACCESSIBLE=1, the query is a typed line and its matches are numbered, to choose
    \\by number as `ui choose` asks.
    \\
    \\Style a part with --indicator.*, --selected-indicator.*, --unselected-prefix.*,
    \\--header.*, --text.*, --cursor-text.*, --match.*, --prompt.*, and --placeholder.*.
    \\Every flag can also come from a variable: TERMANCY_FILTER_HEIGHT,
    \\TERMANCY_FILTER_MATCH_FOREGROUND.
    ,
    .flags = flags_flags,
    .args = .{ .max = null, .usage = "[item...]" },
    .examples =
    \\vim "$(find . -type f | termancy ui filter)"
    \\git log --oneline | termancy ui filter --no-limit | cut -d' ' -f1
    \\git branch --format='%(refname:short)' | termancy ui filter --no-strict --height 10
    \\ls | termancy ui filter --select-if-one --value "$1" --reverse
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (flags.limit == 0) return ctx.usageError("--limit must be at least 1", .{});
    const items = try term.items(ctx, .{
        .strip_ansi = flags.strip_ansi,
        .delimiter = flags.input_delimiter,
    });
    var model = try framed(ctx.gpa, ctx.arena, items, flags, ctx.theme);
    defer model.deinit();
    const matches = model.inner.matches.items;
    if (flags.select_if_one and matches.len == 1) {
        return term.writeJoined(ctx.out, &.{items[matches[0].index]}, flags.output_delimiter);
    }
    if (plain.wanted(ctx)) return askPlainly(ctx, items, flags);
    // gum's: unless a height is given, the whole screen.
    const full: tui.Options = .{ .alt_screen = true };
    const options = term.timed(if (flags.height == 0) full else term.inline_options, flags.timeout);
    if (try term.run(ctx, @TypeOf(model), &model, options)) return term.exitInterrupted(ctx);
    if (model.inner.status != .submitted) return error.CommandFailed;
    try term.writeJoined(ctx.out, try answerOf(ctx.arena, &model.inner), flags.output_delimiter);
}

const navigate: term.Hint = .{ .keys = &.{ "up", "down" }, .action = .hint, .help = "navigate" };
const submit: term.Hint = .{ .keys = &.{"enter"}, .action = .hint, .help = "submit" };
const single_hints = [_]term.Hint{ navigate, submit };
const multiple_hints = [_]term.Hint{
    navigate,
    .{ .keys = &.{"tab"}, .action = .hint, .help = "toggle" },
    .{ .keys = &.{"ctrl+a"}, .action = .hint, .help = "select all" },
    submit,
};

/// The model for `items` and the flags, with the help line, `--padding`, and `--width`.
pub fn framed(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    items: []const []const u8,
    flags: Flags,
    theme: *const cli.Theme,
) !term.Framed(Filter) {
    const hints: []const term.Hint = if (flags.limit > 1 or flags.no_limit)
        &multiple_hints
    else
        &single_hints;
    return .{
        .inner = try build(gpa, arena, items, flags, theme),
        .gpa = gpa,
        .padding = flags.padding.sides,
        .hints = if (flags.show_help) hints else &.{},
        .max_width = if (flags.width > 0) flags.width else null,
    };
}

/// The filter for `items` and the flags, in the theme's look under the style flags.
pub fn build(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    items: []const []const u8,
    flags: Flags,
    theme: *const cli.Theme,
) !Filter {
    var model: Filter = try .init(gpa, items);
    errdefer model.deinit();
    model.header = try styles.render(arena, flags.header_style.over(theme.heading), flags.header);
    model.limit = if (flags.no_limit) null else flags.limit;
    model.strict = flags.strict;
    model.fuzzy = flags.fuzzy;
    model.sort = flags.fuzzy_sort;
    model.reverse = flags.reverse;
    model.fill = flags.height == 0;
    model.list.height = @max(flags.height, 1);
    model.list.wrap = true;
    // As gum: the indicator, then a space with a limit of one, or else the marks.
    const one = model.limit == 1;
    model.list.cursor_prefix = if (one)
        try std.mem.concat(arena, u8, &.{ flags.indicator, " " })
    else
        flags.indicator;
    const blank = try arena.alloc(u8, tui.width.of(model.list.cursor_prefix));
    @memset(blank, ' ');
    model.list.item_prefix = blank;
    model.chosen_mark = flags.selected_prefix;
    model.unchosen_mark = flags.unselected_prefix;
    model.list.styles = .{
        .cursor = flags.indicator_style.over(theme.accent),
        .cursor_text = flags.cursor_text_style.over(.{}),
        .item = flags.text_style.over(.{}),
    };
    var match = theme.accent;
    match.underline = true; // so matches show without color too
    model.styles = .{
        .header = .{},
        .match = flags.match_style.over(match),
        .chosen = flags.selected_indicator_style.over(theme.accent),
        .unchosen = flags.unselected_prefix_style.over(theme.note),
        .count = theme.note,
    };
    model.query.prompt = flags.prompt;
    model.query.placeholder = flags.placeholder;
    model.query.styles.prompt = flags.prompt_style.over(theme.note);
    model.query.styles.placeholder = flags.placeholder_style.over(theme.note);
    try model.query.setValue(flags.value);
    try model.refilter();
    // --selected, among the matches of --value.
    const first = @intFromBool(model.offers_query);
    const limit = model.limit orelse items.len;
    const rows = try choose.preselected(arena, model.shown.items[first..], flags.selected, limit);
    for (rows) |row| {
        if (one) model.list.moveTo(first + row) else model.toggle(model.matches.items[row].index);
    }
    return model;
}

/// ACCESSIBLE: a typed query (`--value` when empty), then its matches numbered, as
/// `choose` asks; strictly, a query that matches nothing is asked again.
fn askPlainly(ctx: *cli.Context, items: []const []const u8, flags: Flags) !void {
    var session: plain.Session = undefined;
    try session.open(ctx);
    defer session.close();
    const label = if (flags.value.len == 0)
        "Filter"
    else
        try std.fmt.allocPrint(ctx.arena, "Filter (enter for {s})", .{flags.value});
    while (true) {
        var with = flags;
        with.value = try session.input(label, flags.value, false) orelse return error.CommandFailed;
        var model = try build(ctx.gpa, ctx.arena, items, with, ctx.theme);
        defer model.deinit();
        const rows = model.list.items;
        if (rows.len == 0) {
            try session.terminal.writer().writeAll("No match.\n");
            continue;
        }
        const first = @intFromBool(model.offers_query);
        const limit = model.limit orelse rows.len;
        const named = try choose.preselected(ctx.arena, rows[first..], flags.selected, limit);
        for (named) |*row| row.* += first;
        const chosen = try session.choose(flags.header, rows, limit, named) orelse
            return error.CommandFailed;
        // In the items' order, the query (its own row) first.
        const order = struct {
            fn key(m: *const Filter, row: usize) usize {
                if (row < @intFromBool(m.offers_query)) return 0;
                return m.matches.items[row - @intFromBool(m.offers_query)].index + 1;
            }
            fn less(m: *const Filter, a: usize, b: usize) bool {
                return key(m, a) < key(m, b);
            }
        };
        std.mem.sort(usize, chosen, @as(*const Filter, &model), order.less);
        const texts = try ctx.arena.alloc([]const u8, chosen.len);
        for (texts, chosen) |*text, row| text.* = rows[row];
        return term.writeJoined(ctx.out, texts, flags.output_delimiter);
    }
}

/// What the filter answers: the chosen items, in their original order, or else the query
/// (`--no-strict`).
pub fn answerOf(
    arena: std.mem.Allocator,
    model: *const Filter,
) std.mem.Allocator.Error![]const []const u8 {
    var chosen: std.ArrayList([]const u8) = .empty;
    for (model.items, model.chosen) |item, on| {
        if (on) try chosen.append(arena, item);
    }
    if (chosen.items.len == 0) try chosen.append(arena, model.query.value());
    return chosen.items;
}

const testing = std.testing;
const words = [_][]const u8{ "alpha", "beta", "gamma", "delta" };

const Driver = tui.testing.Driver;

fn answer(arena: *std.heap.ArenaAllocator, model: *const Filter) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try term.writeJoined(&out.writer, try answerOf(arena.allocator(), model), ",");
    return out.written();
}

fn start(arena: *std.heap.ArenaAllocator, flags: Flags) !Driver(Filter) {
    const theme = &cli.Theme.default;
    const model = try build(testing.allocator, arena.allocator(), &words, flags, theme);
    return .init(testing.allocator, model, .{});
}

test "a starting query and one choice, in gum's look" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d = try start(&arena, .{ .value = "ta" });
    defer d.deinit();
    try d.expectFrame("> ta \n• beta\n  delta\n2/4");
    try d.press("down");
    try d.press("enter");
    try testing.expectEqualStrings("delta\n", try answer(&arena, d.model()));
}

test "no limit: tab chooses several, the marks gum's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d = try start(&arena, .{ .no_limit = true, .placeholder = "", .header = "Pick" });
    defer d.deinit();
    try d.expectFrameContains("Pick\n>  \n• ○ alpha\n  ○ beta\n");
    try d.press("tab");
    try d.press("tab");
    try d.press("tab");
    try d.expectFrameContains("  ◉ gamma\n• ○ delta");
    try d.press("enter");
    try testing.expectEqualStrings("alpha,beta,gamma\n", try answer(&arena, d.model()));
}

test "round past the ends; ctrl+q prints" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d = try start(&arena, .{});
    defer d.deinit();
    try d.press("up");
    try d.press("ctrl+q");
    try testing.expectEqualStrings("delta\n", try answer(&arena, d.model()));
}

test "--selected: highlighted with a limit of one, chosen above it; * for all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var one = try start(&arena, .{ .selected = &.{ "gamma", "beta" } });
    defer one.deinit();
    try testing.expectEqual(1, one.model().current().?);
    try testing.expectEqual(0, one.model().count());
    var two = try start(&arena, .{ .limit = 2, .selected = &.{"*"}, .value = "a" });
    defer two.deinit();
    try testing.expect(two.model().isChosen(0) and two.model().isChosen(1));
    try testing.expectEqual(2, two.model().count());
}

test "--no-strict: the typed text is the answer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d = try start(&arena, .{ .strict = false, .selected = &.{"beta"}, .value = "bet" });
    defer d.deinit();
    // The query's row first, then the match --selected highlights.
    try d.expectFrame("> bet \n  bet\n• beta\n1/4");
    try d.press("up");
    try d.press("enter");
    try testing.expectEqualStrings("bet\n", try answer(&arena, d.model()));
}

test "--height 0 fills what --padding and the help line leave; --width caps the rows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .header = "H", .width = 8, .padding = try .parse("1 0") };
    const theme = &cli.Theme.default;
    const model = try framed(testing.allocator, arena.allocator(), &words, flags, theme);
    var d: Driver(term.Framed(Filter)) = try .init(testing.allocator, model, .{
        .program = .{ .size = .{ .width = 40, .height = 10 } },
    });
    defer d.deinit();
    // 10 rows: 2 of padding, 2 of help, the header, the query, and the count leave 3.
    try testing.expectEqual(3, d.model().inner.list.height);
    try testing.expectEqual(8, d.model().inner.list.width);
}

test "the style flags reach the parts, over the theme" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{
        .indicator_style = .{ .foreground = .{ .indexed = 1 } },
        .cursor_text_style = .{ .bold = true },
        .match_style = .{ .underline = false },
        .unselected_prefix_style = .{ .italic = true },
        .prompt_style = .{ .foreground = .{ .indexed = 2 } },
    };
    var model = try build(testing.allocator, arena.allocator(), &words, flags, &cli.Theme.default);
    defer model.deinit();
    const theme = cli.Theme.default;
    try testing.expectEqual(tui.Color{ .indexed = 1 }, model.list.styles.cursor.fg);
    try testing.expect(model.list.styles.cursor_text.?.bold);
    try testing.expectEqual(theme.accent, model.styles.match);
    try testing.expectEqual(theme.accent, model.styles.chosen);
    try testing.expect(model.styles.unchosen.italic and model.styles.unchosen.dim);
    try testing.expectEqual(tui.Color{ .indexed = 2 }, model.query.styles.prompt.fg);
    try testing.expectEqual(theme.note, model.query.styles.placeholder);
}
