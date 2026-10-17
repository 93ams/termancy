//! `snek tui filter`: fuzzy-find items by typing.

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const term = @import("term.zig");
const Filter = @import("../registry/filter.zig").Filter;

pub const Flags = struct {
    limit: usize = 1,
    no_limit: bool = false,
    placeholder: []const u8 = "Filter...",
    header: []const u8 = "",
    prompt: []const u8 = "> ",
    value: []const u8 = "",
    height: usize = 10,

    pub const meta = .{
        .limit = .{ .help = "The most items to choose; above 1, tab chooses each" },
        .no_limit = .{ .help = "Choose any number of items" },
        .placeholder = .{ .help = "Shown while the query is empty" },
        .header = .{ .help = "Text above the query" },
        .prompt = .{ .help = "Written before the query" },
        .value = .{ .help = "The query to start with" },
        .height = .{ .help = "Items shown at once" },
    };
};

pub const command = cli.command(.{
    .name = "filter",
    .summary = "Fuzzy-find items by typing",
    .description =
    \\Show the items (the lines of standard input, or the arguments) and narrow them as
    \\you type: an item matches when it contains the query's characters in order, best
    \\matches first, matched characters highlighted. Case is ignored unless the query has
    \\an uppercase letter. Prints the chosen item; with --limit above 1 or --no-limit, tab
    \\chooses each and enter prints them all, one per line, in their original order.
    \\
    \\Keys: typing edits the query, up/down (ctrl+p/ctrl+n) move, enter chooses, esc
    \\cancels (status 1), Ctrl-C interrupts (status 130).
    ,
    .flags = Flags,
    .args = .{ .max = null, .usage = "[item...]" },
    .examples =
    \\vim "$(find . -type f | snek tui filter)"
    \\git log --oneline | snek tui filter --no-limit | cut -d' ' -f1
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (flags.limit == 0) return ctx.usageError("--limit must be at least 1", .{});
    var model = try build(ctx.gpa, try term.items(ctx), flags);
    defer model.deinit();
    if (try term.run(ctx, Filter, &model, term.inline_options)) return term.exitInterrupted(ctx);
    if (model.status != .submitted) return error.CommandFailed;
    try writeChosen(ctx.out, &model);
}

/// The model for `items` and the flags.
pub fn build(
    gpa: std.mem.Allocator,
    items: []const []const u8,
    flags: Flags,
) std.mem.Allocator.Error!Filter {
    var model: Filter = try .init(gpa, items);
    errdefer model.deinit();
    model.header = flags.header;
    model.limit = if (flags.no_limit) null else flags.limit;
    model.list.height = @max(flags.height, 1);
    model.query.prompt = flags.prompt;
    model.query.placeholder = flags.placeholder;
    try model.query.setValue(flags.value);
    try model.refilter();
    return model;
}

/// Writes the chosen items, one per line, in their original order.
pub fn writeChosen(w: *std.Io.Writer, model: *const Filter) std.Io.Writer.Error!void {
    for (model.items, 0..) |item, i| {
        if (model.isChosen(i)) try w.print("{s}\n", .{item});
    }
}

const testing = std.testing;
const Driver = tui.testing.Driver(Filter);
const words = [_][]const u8{ "alpha", "beta", "gamma", "delta" };

fn finish(d: *Driver) void {
    d.deinit();
}

fn chosen(d: *Driver) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeChosen(&out.writer, d.model());
    return out.toOwnedSlice();
}

test "a starting query and one choice" {
    var d: Driver = try .init(
        testing.allocator,
        try build(testing.allocator, &words, .{ .value = "ta" }),
        .{},
    );
    defer finish(&d);
    try d.expectFrame("> ta \n> beta\n  delta\n2/4");
    try d.press("down");
    try d.press("enter");
    const out = try chosen(&d);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("delta\n", out);
}

test "no limit: tab chooses several" {
    var d: Driver = undefined;
    const flags: Flags = .{ .no_limit = true, .placeholder = "", .header = "Pick" };
    d = try .init(testing.allocator, try build(testing.allocator, &words, flags), .{});
    defer finish(&d);
    try d.expectFrameContains("Pick\n>  \n");
    try d.press("tab");
    try d.press("tab");
    try d.press("tab");
    try d.press("enter");
    const out = try chosen(&d);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\n", out);
}
