//! The app `docs/guide.md` builds, "Your first app in 10 minutes": a CLI that reads a
//! config file, asks for an order in a two-step flow, brews it under a live progress bar,
//! and picks a drink with the `select` component from the registry. Every Zig snippet of
//! the guide is in this file, which a test below checks, so the guide cannot drift from
//! code that compiles.
//!
//!     zig build examples
//!     zig-out/bin/first-app make                     # asks, at a terminal
//!     zig-out/bin/first-app make --drink latte --cups 2 -c examples/first-app/brew.toml
//!     zig-out/bin/first-app pick -c examples/first-app/brew.toml

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const tui = @import("tui");
// `termancy tui add select` copied select.zig, and list.zig which it requires, into src/ui.
const Select = @import("ui/select.zig").Select;

/// What brew.toml holds.
const Settings = struct {
    beans: []const u8 = "house blend",
    grams_per_cup: u8 = 15,
    menu: []const []const u8 = &.{ "espresso", "latte", "filter" },
};

/// The defaults, under the file at `path` when there is one.
fn loadSettings(ctx: *cli.Context, path: []const u8) !Settings {
    // On the run's arena: what `decode` returns lives as long as the config.
    var config: cfg.Config = .init(ctx.arena);
    try config.setDefaults(Settings{});
    var diag: cfg.Diagnostic = .{};
    config.loadFile(ctx.io, .cwd(), path, null, &diag) catch |err| switch (err) {
        error.FileNotFound => {},
        error.SyntaxError => return ctx.fail("{f}", .{diag}),
        else => return ctx.fail("{s}: {t}", .{ path, err }),
    };
    return config.decode(Settings, .{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => ctx.fail("{f}", .{diag}),
    };
}

/// The order: the flow's state, and the flags of `brew make`. A question whose flag was
/// given is not asked.
const Order = struct {
    drink: enum { espresso, latte, filter } = .espresso,
    cups: u8 = 1,
    config: []const u8 = "brew.toml",

    pub const meta = .{
        .drink = .{ .short = 'd', .help = "What to brew" },
        .cups = .{ .short = 'n', .help = "How many cups", .min = 1, .max = 12 },
        .config = .{ .short = 'c', .help = "The configuration file" },
    };
};

const Step = enum { order, brew };

const make_flow: cli.Flow(Order, Step) = .{ .start = .order, .steps = .{
    .order = .{
        .title = "Order",
        .form = &.{
            .{ .field = "drink", .label = "What would you like?" },
            .{ .field = "cups", .label = "How many cups?" },
        },
        .next = .brew,
    },
    .brew = .{ .title = "Brew", .run = brew },
} };

fn brew(ctx: *cli.Context, order: *Order) !void {
    const settings = try loadSettings(ctx, order.config);
    const grams = @as(u64, settings.grams_per_cup) * order.cups;
    // Redrawn in place at a terminal; a line per quarter in a log or a pipe.
    var grind: tui.term.live.Bar = .{ .label = "grinding", .total = grams, .show_eta = false };
    const items = [_]tui.term.live.Item{.{ .bar = &grind }};
    var display = ctx.live(&items);
    try display.draw(.now(ctx.io, .awake));
    for (0..grams) |_| {
        grind.add(1);
        try display.tick(.now(ctx.io, .awake));
    }
    grind.finish(.success);
    try display.finish(.now(ctx.io, .awake));
    try ctx.out.print("{d} {t}, from {d}g of {s}\n", .{
        order.cups, order.drink, grams, settings.beans,
    });
}

fn make(ctx: *cli.Context, flags: Order) !void {
    var order = flags;
    _ = try make_flow.run(ctx, &order);
}

const PickFlags = struct {
    config: []const u8 = "brew.toml",
    pub const meta = .{ .config = .{ .short = 'c', .help = "The configuration file" } };
};

/// Choose from the menu in brew.toml with the `select` component, full screen.
fn pick(ctx: *cli.Context, flags: PickFlags) !void {
    const settings = try loadSettings(ctx, flags.config);
    var menu: Select = .{ .header = "What would you like?", .list = .{ .items = settings.menu } };
    const status = tui.run(ctx.gpa, ctx.io, &menu, .{ .environ = ctx.environ }) catch |err|
        switch (err) {
            error.NotATerminal => return ctx.fail("pick needs a terminal", .{}),
            else => |e| return e,
        };
    if (status != 0) return ctx.exit(status);
    if (menu.status == .submitted) try ctx.out.print("{s}\n", .{menu.selected().?});
}

pub const root = cli.command(.{
    .name = "brew",
    .summary = "Brew coffee, as your first termancy app",
    .subcommands = .{
        cli.command(.{
            .name = "make",
            .summary = "Brew an order, asking for anything not given as a flag",
            .flags = Order,
            .run = make,
        }),
        cli.command(.{
            .name = "pick",
            .summary = "Pick a drink from the menu",
            .flags = PickFlags,
            .run = pick,
        }),
    },
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root, .version = "0.1.0" };
    return app.run(init);
}

const testing = std.testing;
const test_app: cli.App = .{ .root = &root };

test "flags answer the questions, and brew.toml names the beans" {
    const result = try cli.testing.run(test_app, &.{
        "make", "-d", "filter", "-n", "3", "-c", "examples/first-app/brew.toml",
    }, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expectEqualStrings("3 filter, from 54g of Ethiopia Yirgacheffe\n", result.out);
    // Without a terminal the bar logs lines, never a cursor movement.
    try testing.expect(std.mem.indexOf(u8, result.err, "✓ grinding") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "\x1b[") == null);
}

test "questions not given as flags are asked, and a missing file means the defaults" {
    // The drink (2 = latte), then the cups.
    const result = try cli.testing.run(test_app, &.{ "make", "-c", "nope.toml" }, .{
        .stdin = "2\n2\n",
    });
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expectEqualStrings("2 latte, from 30g of house blend\n", result.out);
}

test "the select component chooses from the menu" {
    var driver: tui.testing.Driver(Select) = try .init(testing.allocator, .{
        .header = "What would you like?",
        .list = .{ .items = (Settings{}).menu },
    }, .{});
    defer driver.deinit();
    try driver.expectFrameContains("What would you like?");
    try driver.press("down");
    try driver.press("enter");
    try testing.expect(driver.done());
    try testing.expectEqualStrings("latte", driver.model().selected().?);
}

test "every Zig snippet of docs/guide.md is in this file" {
    const guide = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "docs/guide.md",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(guide);
    const self = @embedFile("main.zig");
    var snippets: usize = 0;
    var rest = guide;
    while (std.mem.indexOf(u8, rest, "```zig\n")) |start| {
        const body = rest[start + "```zig\n".len ..];
        const end = std.mem.indexOf(u8, body, "```\n") orelse return error.UnclosedSnippet;
        if (std.mem.indexOf(u8, self, body[0..end]) == null) {
            std.debug.print("not in examples/first-app/main.zig:\n{s}\n", .{body[0..end]});
            return error.SnippetNotInExample;
        }
        snippets += 1;
        rest = body[end..];
    }
    try testing.expect(snippets >= 5);
}
