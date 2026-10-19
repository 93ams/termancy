# Your first app in 10 minutes

This guide builds `brew`, a small coffee app with everything a real command-line program
needs: a config file, a two-step flow that asks for what was not given as a flag, a live
progress bar, and a full-screen picker taken from the component registry.

Every Zig snippet below is part of `examples/first-app/main.zig`
([on GitHub](https://github.com/93ams/termancy/blob/master/examples/first-app/main.zig)),
and a test there fails when a snippet here is not in that file, so what you read compiles.
`zig build examples` builds and tests it.

## 1. Make the project

You need Zig 0.17 and `termancy` on your PATH (`zig build` in a termancy checkout puts it in
`zig-out/bin`).

```sh
termancy cli init brew --module-path /path/to/termancy   # or --fetch <url>
cd brew
termancy tui init --wire
termancy tui add select
```

`termancy cli init` writes `build.zig`, `build.zig.zon`, and `src/main.zig` wired to the `cli`
and `cfg` modules, with an example command in `src/cmd/hello.zig` (`zig build run -- hello`)
and its test. `termancy tui init --wire` adds the `tui` module, and `termancy tui add select`
copies the `select` component, and `list` which it requires, into `src/ui/`. They are your
files now: change them as you like, and `termancy tui diff select` shows what changed upstream.

Replace `src/main.zig` with the snippets below, in order (brew does without `hello`, so
delete `src/cmd/hello.zig` or keep it to crib from). It starts with the imports:

```zig
const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const tui = @import("tui");
// `termancy tui add select` copied select.zig, and list.zig which it requires, into src/ui.
const Select = @import("ui/select.zig").Select;
```

## 2. A config file

The settings are a struct whose defaults are the defaults. `cfg` reads TOML, YAML, JSON,
ZON, INI, and dotenv files over them and decodes the result back into the struct, with a
diagnostic that names the file and line when something does not fit.

```zig
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
    try config.setDefaults(Settings, .{});
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
```

Write `brew.toml` next to `build.zig`:

```toml
beans = "Ethiopia Yirgacheffe"
grams_per_cup = 18
menu = ["espresso", "latte", "filter", "cold brew"]
```

## 3. A two-step flow

`brew make` takes an order. Its flags are a struct too, and the same struct is the state
of a `cli.Flow`: the first step asks for the drink and the cups on one form (at a terminal;
one line each otherwise), skipping what a flag already answered, and the second brews.

```zig
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
```

## 4. A live progress bar

The brew step reads the settings and grinds under a progress bar. `ctx.live` redraws it in
place at a terminal and writes a plain line now and then when the output is a log or a pipe,
so the same code is right in both.

```zig
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
```

## 5. A component from the registry

`brew pick` shows the menu from `brew.toml` with the `select` component you added. A
component is a model (`update` and `view`); `tui.run` runs it on the terminal, updating
it in place, and returns the exit status (130 after Ctrl-C).

```zig
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
```

## 6. The command tree

Last, the tree of commands and `main`. Help, `--version`, shell completion, typo
suggestions, and errors in the right exit status come with `cli.App`.

```zig
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
```

## 7. Run it

```sh
zig build run -- --help
zig build run -- make                      # asks for the drink and the cups
zig build run -- make -d latte -n 2        # asks nothing
zig build run -- make -d filter 2>&1 | cat   # the bar becomes plain lines
zig build run -- pick
```

## 8. Test it

`cli.testing.run` runs a command in memory, with standard input to answer the questions,
and `tui.testing.Driver` runs a component on a virtual screen. The tests at the end of
`examples/first-app/main.zig` do both; copy them into your `src/main.zig` and run
`zig build test`.

## Next

- [The components](components/index.html): each one recorded, with its source.
- [The command reference](commands.html): everything `termancy` does.
- The libraries: [cli](lib/cli.html), [cfg](lib/cfg.html), [tui](lib/tui.html),
  [term](lib/term.html), [sys](lib/sys.html).
