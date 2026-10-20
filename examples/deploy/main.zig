//! A deploy command that is a graph, not a script: `cli.Flow` asks what it needs, looks
//! before it acts, branches on what it found and what was answered, and undoes what it did
//! when a later step fails.
//!
//! - one **form** for the target (service, environment, version), on one screen at a
//!   terminal through the `prompts` component, as plain lines otherwise;
//! - a **probe** (`check`) that runs even under `--dry-run`, whose finding decides the path;
//! - **decisions**: migrations are offered only when some are pending, a canary only for
//!   production;
//! - **undo**: when the release fails, the canary and the migrations are rolled back,
//!   latest first;
//! - every question is also a flag, so the same flow runs from a script;
//! - `-o json` reports each step as a JSON line, `-v` logs what the steps do, and
//!   `deploy graph` draws the flow as a Mermaid chart.
//!
//!     zig build examples
//!     zig-out/bin/deploy run                          # asks, at a terminal
//!     zig-out/bin/deploy run --service api --env production --version 1.4.0 --migrate -v
//!     zig-out/bin/deploy run --service api --env production --dry-run -o json
//!     zig-out/bin/deploy run --service api --env production --break-release  # rolls back
//!     zig-out/bin/deploy graph

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const term = @import("term");
const components = @import("components");

/// The flow's state, and the flags of `deploy run`: a question whose flag was given is
/// not asked.
const Deploy = struct {
    service: []const u8 = "",
    env: enum { staging, production } = .staging,
    version: []const u8 = "latest",
    migrate: bool = false,
    canary: bool = true,
    /// Makes the release fail, to show the undos.
    break_release: bool = false,
    /// What `check` found: state, not a flag.
    pending: u32 = 0,
};
const deploy_flags = cli.flags(Deploy, field.Set(.{field.Spec(Deploy){ .fields = .{
    .service = .{ .help = "The service to deploy", .checks = &.{.minLen(1)} },
    .env = .{ .help = "Where to deploy" },
    .version = .{ .help = "The version to release" },
    .migrate = .{ .help = "Run the pending database migrations" },
    .canary = .{ .help = "Release to one replica first (production only)" },
} }}), .{ .fields = .{
    .service = .{ .short = 's' },
    .env = .{ .short = 'e' },
    .break_release = .{ .hidden = true },
    .pending = .{ .internal = true },
} });

const Step = enum { target, check, ask_migrate, build, migrate, ask_canary, canary, release };

const deploy: cli.Flow(Deploy, Step) = .{ .start = .target, .steps = .{
    .target = .{
        .title = "Deploy",
        .form = &.{
            .{ .field = "service", .label = "Which service?", .required = true },
            .{ .field = "env", .label = "Where to?" },
            .{ .field = "version", .label = "Which version?" },
        },
        .next = .check,
    },
    .check = .{ .title = "Check the database", .run = check, .probe = true, .decide = .{
        .to = &.{ .ask_migrate, .build },
        .by = afterCheck,
    } },
    .ask_migrate = .{
        .ask = .{ .field = "migrate", .label = "Run the pending migrations?" },
        .next = .build,
    },
    .build = .{ .title = "Build the image", .run = build, .next = .migrate },
    .migrate = .{
        .title = "Migrate",
        .run = migrate,
        .undo = rollBackMigrations,
        .when = wantsMigrations,
        .decide = .{ .to = &.{ .ask_canary, .release }, .by = afterMigrate },
    },
    .ask_canary = .{
        .ask = .{ .field = "canary", .label = "Release to one replica first?" },
        .decide = .{ .to = &.{ .canary, .release }, .by = afterAskCanary },
    },
    .canary = .{ .title = "Canary", .run = canary, .undo = withdrawCanary, .next = .release },
    .release = .{ .title = "Release", .run = release },
} };

fn afterCheck(state: *const Deploy) ?Step {
    return if (state.pending > 0) .ask_migrate else .build;
}

fn wantsMigrations(state: *const Deploy) bool {
    return state.migrate and state.pending > 0;
}

fn afterMigrate(state: *const Deploy) ?Step {
    return if (state.env == .production) .ask_canary else .release;
}

fn afterAskCanary(state: *const Deploy) ?Step {
    return if (state.canary) .canary else .release;
}

/// Looks only, so it runs under `--dry-run` too and the dry run takes the real path.
fn check(ctx: *cli.Context, state: *Deploy) !void {
    state.pending = if (state.env == .production) 2 else 0;
    ctx.log(.info, "{d} migrations pending on {t}", .{ state.pending, state.env });
}

fn build(ctx: *cli.Context, state: *Deploy) !void {
    ctx.log(.debug, "building {s}:{s}", .{ state.service, state.version });
    // The image's layers go up under a progress bar: redrawn in place at a terminal, a line
    // per quarter in a log.
    const layer = 12 * 1024 * 1024;
    var push: term.live.Bar = .{
        .label = "push",
        .total = 8 * layer,
        .units = .bytes,
        .show_count = true,
        .show_eta = false,
    };
    const items = [_]term.live.Item{.{ .bar = &push }};
    var display = ctx.live(&items);
    try display.draw(.now(ctx.io, .awake));
    for (0..8) |_| {
        push.add(layer);
        try display.tick(.now(ctx.io, .awake));
    }
    push.finish(.success);
    try display.finish(.now(ctx.io, .awake));
}

fn migrate(ctx: *cli.Context, state: *Deploy) !void {
    ctx.log(.info, "applying {d} migrations", .{state.pending});
}

fn rollBackMigrations(ctx: *cli.Context, state: *Deploy) !void {
    ctx.log(.info, "reverting {d} migrations", .{state.pending});
}

fn canary(ctx: *cli.Context, state: *Deploy) !void {
    ctx.log(.info, "{s} {s} on one replica", .{ state.service, state.version });
}

fn withdrawCanary(ctx: *cli.Context, state: *Deploy) !void {
    ctx.log(.info, "withdrawing the canary of {s}", .{state.service});
}

fn release(ctx: *cli.Context, state: *Deploy) !void {
    if (state.break_release) return error.HealthCheckFailed;
    if (ctx.output == .text) {
        try ctx.out.print("{s} {s} is live on {t}\n", .{ state.service, state.version, state.env });
    }
}

fn runDeploy(ctx: *cli.Context, flags: Deploy) !void {
    var state = flags;
    _ = try deploy.run(ctx, &state);
}

fn graph(ctx: *cli.Context) !void {
    try cli.flow.writeMermaid(deploy, ctx.out);
}

pub const root = cli.command(.{
    .name = "deploy",
    .summary = "Deploy a service, asking what it needs",
    .logging = true,
    .subcommands = .{
        cli.command(.{
            .name = "run",
            .summary = "Deploy, asking for anything not given as a flag",
            .flags = deploy_flags,
            .dry_run = true,
            .output = true,
            .examples =
            \\deploy run
            \\deploy run -s api -e production --version 1.4.0 --migrate --no-canary
            \\deploy run -s api -e production --dry-run -o json
            ,
            .run = runDeploy,
        }),
        cli.command(.{
            .name = "graph",
            .summary = "Draw the deploy flow as a Mermaid chart",
            .run = graph,
        }),
    },
});

/// A failed release, rolled back, exits 3, so a script can tell it from a usage error (2).
fn exitStatus(err: anyerror) ?u8 {
    return if (err == error.HealthCheckFailed) 3 else null;
}

pub fn main(init: std.process.Init) u8 {
    // At a terminal, the questions are drawn by the `prompts` component (copied into a
    // project with `termancy tui add prompts`); elsewhere they are never asked.
    var prompts: components.Prompts = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
    };
    defer prompts.deinit();
    const app: cli.App = .{
        .root = &root,
        .asker = prompts.asker(cli.flow.Asker),
        .exit_status = exitStatus,
    };
    return app.run(init);
}

const testing = std.testing;
/// Tests answer with lines on standard input, the asker every app has by default.
const test_app: cli.App = .{ .root = &root, .exit_status = exitStatus };

test "flags answer every question, and production takes the long path" {
    const result = try cli.testing.run(test_app, &.{
        "run", "-s", "api", "-e", "production", "--version", "1.4.0", "--migrate", "--canary",
    }, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expectEqualStrings("api 1.4.0 is live on production\n", result.out);
    for ([_][]const u8{ "✓ Check the database", "✓ Migrate", "✓ Canary", "✓ Release" }) |line| {
        try testing.expect(std.mem.indexOf(u8, result.err, line) != null);
    }
    // Without a terminal the push bar logs lines, never a cursor movement.
    try testing.expect(std.mem.indexOf(u8, result.err, "✓ push ") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "100% 96.0MiB/96.0MiB") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "\x1b[") == null);
}

test "staging has no migrations, so neither question is asked" {
    const result = try cli.testing.run(test_app, &.{ "run", "-s", "web" }, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expectEqualStrings("web latest is live on staging\n", result.out);
    try testing.expect(std.mem.indexOf(u8, result.err, "- Migrate: skipped") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "pending migrations?") == null);
}

test "questions not given as flags are asked, one line each" {
    // Service, environment (2 = production), version (empty keeps the default), then the
    // migrations and the canary.
    const result = try cli.testing.run(test_app, &.{"run"}, .{ .stdin = "api\n2\n\ny\nn\n" });
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expectEqualStrings("api latest is live on production\n", result.out);
    try testing.expect(std.mem.indexOf(u8, result.err, "Run the pending migrations?") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "Canary") == null);
}

test "a failed release undoes the canary and the migrations, latest first" {
    const result = try cli.testing.run(test_app, &.{
        "run", "-s", "api", "-e", "production", "--migrate", "--break-release",
    }, .{});
    defer result.deinit();
    try testing.expectEqual(3, result.status);
    const canary_undone = std.mem.indexOf(u8, result.err, "↩ Canary: undone").?;
    const migrate_undone = std.mem.indexOf(u8, result.err, "↩ Migrate: undone").?;
    try testing.expect(canary_undone < migrate_undone);
}

test "a dry run probes and decides, but changes nothing" {
    const result = try cli.testing.run(test_app, &.{
        "run", "-s", "api", "-e", "production", "--migrate", "--dry-run", "-o", "json",
    }, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expect(std.mem.indexOf(u8, result.out,
        \\{"step":"check","title":"Check the database","outcome":"done"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, result.out,
        \\{"step":"release","title":"Release","outcome":"dry_run"}
    ) != null);
}

test "without a terminal, a required question names its flag" {
    const result = try cli.testing.run(test_app, &.{"run"}, .{});
    defer result.deinit();
    try testing.expectEqual(2, result.status);
    try testing.expect(std.mem.indexOf(u8, result.err, "--service") != null);
}

test "-v logs what the steps do" {
    const result = try cli.testing.run(test_app, &.{ "run", "-s", "api", "-vv" }, .{});
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.err, "deploy: debug: building api") != null);
}
