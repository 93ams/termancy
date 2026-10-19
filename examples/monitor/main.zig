//! A service monitor in the terminal: a `tui` program composed of registry components
//! (`tabs`, `table`, `chart`, `spinner`, `progress`; `termancy tui add` copies them into a
//! project), with:
//!
//! - one model forwarding messages to the components it embeds, the Elm way;
//! - key bindings declared once (`tui.Keymap`), matched in `update` and listed in `view`;
//! - timers (`Cmd.tick`) driving live traffic and a redeploy's progress;
//! - styles with borders and padding, laid out side by side (`tui.layout`);
//! - the mouse: clicking a tab switches to it;
//! - `tui.run`: the terminal, its colors, and exit status 130 after Ctrl-C in one call,
//!   which prints the first frame as text when there is no terminal (`--snapshot`);
//! - tests through `tui.testing.Driver`, a virtual terminal with a virtual clock.
//!
//!     zig build examples
//!     zig-out/bin/monitor              # ←/→ tabs, ↑/↓ services, r redeploys, q quits
//!     zig-out/bin/monitor --snapshot

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const components = @import("components");

const Tabs = components.tabs.Tabs;
const Table = components.table.Table;
const Spinner = components.spinner.Spinner;
const Progress = components.progress.Progress;
const chart = components.chart;

const services = [_][]const []const u8{
    &.{ "api", "healthy", "3", "1.4.0" },
    &.{ "web", "healthy", "2", "2.0.1" },
    &.{ "worker", "degraded", "1", "0.9.3" },
    &.{ "billing", "healthy", "2", "3.2.0" },
};

/// Requests per second, played back as if live.
const traffic = [_]f64{
    12, 14, 13, 18, 22, 25, 24, 30, 28, 26, 31, 35, 33, 29, 27, 24, 26, 30, 34, 38,
    41, 39, 36, 32, 30, 27, 25, 22, 20, 23, 26, 29, 33, 37, 40, 44, 42, 38, 35, 31,
};

const Action = enum { quit, up, down, redeploy };

const keys: tui.Keymap(Action) = .{ .bindings = &.{
    .{ .keys = &.{ "up", "k" }, .action = .up, .help = "service", .label = "↑/↓" },
    .{ .keys = &.{ "down", "j" }, .action = .down },
    .{ .keys = &.{"r"}, .action = .redeploy, .help = "redeploy" },
    .{ .keys = &.{ "q", "esc" }, .action = .quit, .help = "quit" },
} };

const traffic_tick = 1;
const deploy_tick = 2;
const shown = 24;

const Monitor = struct {
    tabs: Tabs = .{ .titles = &.{ "Services", "Traffic", "Help" } },
    table: Table = .{
        .columns = &.{
            .{ .title = "Service" },
            .{ .title = "Status" },
            .{ .title = "Replicas", .@"align" = .end },
            .{ .title = "Version" },
        },
        .rows = &services,
        .top = 3,
    },
    spinner: Spinner = .{ .tick_id = 3 },
    bar: Progress = .{ .total = 100, .width = 20, .show_eta = false },
    /// The service being redeployed, as a row of `services`.
    deploying: ?usize = null,
    /// How far `traffic` has played.
    played: usize = shown,

    const header: tui.Style = .{ .fg = .hex(0xff8700), .bold = true };
    const panel: tui.Style = .{ .border = .rounded, .padding = .symmetric(0, 1), .width = 28 };
    const muted: tui.Style = .{ .fg = .{ .indexed = 245 } };

    pub fn start(m: *Monitor) tui.Cmd {
        return .batch(&.{ m.spinner.start(), .tick(.fromMilliseconds(500), traffic_tick) });
    }

    pub fn update(m: *Monitor, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .key => |key| {
                if (keys.match(key)) |action| switch (action) {
                    .quit => return .quit,
                    .up => m.table.moveBy(-1),
                    .down => m.table.moveBy(1),
                    .redeploy => if (m.deploying == null) {
                        m.deploying = m.table.cursor;
                        m.bar.set(0, .zero);
                        return .tick(.fromMilliseconds(100), deploy_tick);
                    },
                } else _ = m.tabs.update(msg);
            },
            .mouse => _ = m.tabs.update(msg),
            .tick => |id| switch (id) {
                traffic_tick => {
                    m.played += 1;
                    return .tick(.fromMilliseconds(500), traffic_tick);
                },
                deploy_tick => {
                    m.bar.set(m.bar.current + 10, .zero);
                    if (m.bar.current < m.bar.total) {
                        return .tick(.fromMilliseconds(100), deploy_tick);
                    }
                    m.deploying = null;
                },
                else => return m.spinner.update(msg),
            },
            else => {},
        }
        return .none;
    }

    pub fn view(m: *const Monitor, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try header.paint(w, "◆ monitor");
        try muted.paint(w, "  4 services\n\n");
        try m.tabs.view(w);
        try w.writeAll("\n\n");
        switch (m.tabs.active) {
            0 => {
                // The table and a panel about the selected service, side by side: each is
                // drawn as a block of text first, then the blocks are joined.
                var buffers: [3][4096]u8 = undefined;
                var table: std.Io.Writer = .fixed(&buffers[0]);
                try m.table.view(&table);
                var detail: std.Io.Writer = .fixed(&buffers[1]);
                try m.viewDetail(&detail);
                var boxed: std.Io.Writer = .fixed(&buffers[2]);
                try panel.render(&boxed, detail.buffered());
                const blocks = [_][]const u8{ table.buffered(), "  ", boxed.buffered() };
                try tui.layout.joinHorizontal(w, .start, &blocks);
            },
            1 => {
                try w.writeAll("requests/s  ");
                const window = traffic[0 .. m.played % traffic.len];
                const values = if (window.len > 0) window else &traffic;
                try chart.sparkline(w, values, .{ .width = shown });
                try w.writeAll("\n\n");
                try chart.bars(w, &.{
                    .{ .label = "api", .value = 41 },
                    .{ .label = "web", .value = 27 },
                    .{ .label = "worker", .value = 9 },
                    .{ .label = "billing", .value = 5 },
                }, .{ .width = 30 });
            },
            else => try w.writeAll(
                \\This screen is a tui.Program: update receives each key, tick,
                \\and click; view draws the frame; the program redraws only the
                \\lines that changed.
            ),
        }
        try w.writeAll("\n\n");
        try keys.writeHelp(w, .{});
        try muted.paint(w, " • ←/→ tab");
    }

    fn viewDetail(m: *const Monitor, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const row = services[m.table.cursor];
        try w.print("{s}\nversion {s}\n\n", .{ row[0], row[3] });
        if (m.deploying) |at| if (at == m.table.cursor) {
            try m.spinner.view(w);
            try w.writeAll(" redeploying\n");
            return m.bar.view(w);
        };
        try muted.paint(w, "r to redeploy");
    }
};

const Flags = struct {
    snapshot: bool = false,
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .snapshot = .{ .help = "Print the first frame as text, and quit" },
} }}), .{});

fn run(ctx: *cli.Context, flags: Flags) !void {
    var monitor: Monitor = .{};
    const status = try tui.run(ctx.gpa, ctx.io, &monitor, .{
        .environ = ctx.environ,
        .program = .{ .alt_screen = true, .mouse = true },
        // No terminal: draw one frame on a virtual one and print it.
        .snapshot = flags.snapshot,
        .snapshot_out = ctx.out,
        .snapshot_size = .{ .width = 80, .height = 16 },
    });
    if (status != 0) return ctx.exit(status);
}

pub const root = cli.command(.{
    .name = "monitor",
    .summary = "Watch services in the terminal",
    .flags = flags_flags,
    .run = run,
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root };
    return app.run(init);
}

const testing = std.testing;
const Driver = tui.testing.Driver(Monitor);

fn startDriver() !Driver {
    const size: tui.Size = .{ .width = 80, .height = 16 };
    return .init(testing.allocator, .{}, .{ .program = .{ .size = size } });
}

test "keys move the selection, switch tabs, and quit" {
    var d = try startDriver();
    defer d.deinit();
    try d.expectFrameContains("│ api");
    try d.press("down");
    try d.press("j");
    try testing.expectEqual(2, d.model().table.cursor);
    try d.expectFrameContains("│ worker                     │");
    try d.press("right");
    try d.expectFrameContains("requests/s");
    try d.press("3");
    try d.expectFrameContains("This screen is a tui.Program");
    try d.press("q");
    try testing.expect(d.done());
}

test "a redeploy runs on the timer until it is done" {
    var d = try startDriver();
    defer d.deinit();
    try d.press("r");
    try d.expectFrameContains("redeploying");
    try d.advance(.fromMilliseconds(500));
    try testing.expectEqual(50, d.model().bar.current);
    try d.advance(.fromMilliseconds(600));
    try testing.expectEqual(null, d.model().deploying);
    try d.expectFrameContains("r to redeploy");
}

test "without a terminal, the first frame is printed" {
    const app: cli.App = .{ .root = &root };
    const result = try cli.testing.run(app, &.{"--snapshot"}, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expect(std.mem.startsWith(u8, result.out, "◆ monitor  4 services\n"));
    const help = "↑/↓ service • r redeploy • q/esc quit";
    try testing.expect(std.mem.indexOf(u8, result.out, help) != null);
}
