//! A server's configuration in layers: defaults from a struct, a TOML file, `APP_*`
//! environment variables, and command-line flags, decoded into one typed struct, with
//! `explain` saying where each value came from.
//!
//!     zig build examples
//!     APP_PORT=9000 zig-out/bin/server-config -c examples/server-config/server.toml --workers 8

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");

const Settings = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    workers: u8 = 4,
    timeout: cfg.Duration = .{ .ns = 30 * std.time.ns_per_s },
    tls: struct {
        cert: ?[]const u8 = null,
        key: ?[]const u8 = null,
    } = .{},
};

/// The command's flags: the configuration file, and every setting, so `--workers 8` or
/// `--tls-cert c.pem` override the file and the environment.
const Flags = struct {
    config: ?[]const u8 = null,
    settings: Settings = .{},
};

/// What the values mean and must be, for the file, the environment, and the flags alike.
const Specs = field.Set(.{
    field.Spec(Settings){ .fields = .{
        .host = .{ .help = "The address to listen on" },
        .port = .{ .help = "The port to listen on", .checks = &.{.min(1)} },
        .workers = .{ .help = "Worker threads", .checks = &.{ .min(1), .max(64) } },
        .timeout = .{ .help = "How long a request may take" },
    } },
    field.Spec(Flags){ .fields = .{ .config = .{ .help = "The configuration file" } } },
});

const server = cfg.settings(Settings, Specs, .{});

const serve_flags = cli.flags(Flags, Specs, .{ .fields = .{
    .config = .{ .short = 'c' },
    .settings = .{ .name = "" },
} });

/// The layers, lowest first: the defaults, the file, `APP_*` variables, the flags. In the
/// run's arena, so what `decode` returns lives as long as the run.
fn open(ctx: *cli.Context) !*cfg.Config {
    const flags = try ctx.flags(Flags);
    const config = try ctx.arena.create(cfg.Config);
    config.* = .init(ctx.arena);
    // The struct's defaults, for `explain` in `serve`; `decode` would register them itself.
    try config.register(server);
    if (flags.config) |file| {
        var diag: cfg.Diagnostic = .{};
        config.loadFile(ctx.io, .cwd(), file, null, &diag) catch |err| switch (err) {
            error.SyntaxError => return ctx.configError("{f}", .{diag}),
            else => return ctx.fail("{s}: {t}", .{ file, err }),
        };
    }
    config.useEnv(ctx.environ);
    try config.automaticEnv("APP");
    try config.bindFlags(try ctx.changedFlags(), .{});
    // A missing setting's message names its flag; at a terminal, it is asked for.
    try config.nameFlags(try ctx.flagKeys(), .{});
    config.askWith(ctx.settingsAsker());
    return config;
}

/// The settings, from every layer, checked: the command's `.settings` loader.
fn load(ctx: *cli.Context) !Settings {
    const config = try open(ctx);
    var diag: cfg.Diagnostic = .{};
    return config.decode(server, .{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.configError("{f}", .{diag}),
    };
}

fn serve(ctx: *cli.Context, flags: Flags) !void {
    const settings = flags.settings;
    try ctx.out.print("listening on {s}:{d} with {d} workers, timeout {f}\n", .{
        settings.host, settings.port, settings.workers, settings.timeout,
    });
    try ctx.out.print("tls: {s}\n", .{if (settings.tls.cert != null) "on" else "off"});
    const config = try open(ctx);
    for ([_][]const u8{ "host", "port", "workers", "timeout" }) |key| {
        const origin = (try config.explain(key)).?;
        // The file's base name, so the output does not depend on where it runs.
        try ctx.out.print("  {s}: {t}", .{ key, origin.layer });
        if (origin.source.len > 0) {
            try ctx.out.print(" ({s})", .{std.fs.path.basename(origin.source)});
        }
        try ctx.out.writeByte('\n');
    }
}

pub const root = cli.command(.{
    .name = "server-config",
    .summary = "Print the settings a server would start with",
    .flags = serve_flags,
    .settings = .{
        .field = .settings,
        .load = load,
        // For help: `--port ... (also port in server.toml, $APP_PORT)`.
        .sources = cfg.sourcesOf(server, .{ .file = "server.toml", .env_prefix = "APP" }),
    },
    .run = serve,
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root };
    return app.run(init);
}

test "a value out of bounds is a configuration error, named by where it came from" {
    const app: cli.App = .{ .root = &root };
    const result = try cli.testing.run(app, &.{}, .{ .env = &.{.{ "APP_WORKERS", "100" }} });
    defer result.deinit();
    try std.testing.expectEqual(cli.App.exit_config, result.status);
    try std.testing.expectEqualStrings("server-config: workers: must be at most 64\n", result.err);
}

test "a flag's value is checked as it is given" {
    const app: cli.App = .{ .root = &root };
    const result = try cli.testing.run(app, &.{ "--workers", "100" }, .{});
    defer result.deinit();
    try std.testing.expectEqual(cli.App.exit_usage, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.err, "must be at most 64") != null);
}

test "help says where else each setting can be set" {
    const app: cli.App = .{ .root = &root };
    const result = try cli.testing.run(app, &.{"--help"}, .{});
    defer result.deinit();
    // Wrapped to the width, so in two pieces.
    try std.testing.expect(
        std.mem.indexOf(u8, result.out, "(also workers in server.toml,") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, result.out, "$APP_WORKERS)") != null);
}
