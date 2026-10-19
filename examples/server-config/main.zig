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

/// What the settings must be, checked when they are decoded.
const server = cfg.settings(Settings, field.Set(.{field.Spec(Settings){ .fields = .{
    .port = .{ .checks = &.{.min(1)} },
    .workers = .{ .checks = &.{ .min(1), .max(64) } },
} }}), .{});

const Flags = struct {
    config: ?[]const u8 = null,
    workers: ?u8 = null,
    pub const meta = .{
        .config = .{ .short = 'c', .help = "The configuration file" },
        .workers = .{ .help = "Worker threads" },
    };
};

fn serve(ctx: *cli.Context, flags: Flags) !void {
    var config: cfg.Config = .init(ctx.gpa);
    defer config.deinit();
    try config.setDefaults(server, .{});
    if (flags.config) |file| {
        var diag: cfg.Diagnostic = .{};
        config.loadFile(ctx.io, .cwd(), file, null, &diag) catch |err| switch (err) {
            error.SyntaxError => return ctx.fail("{f}", .{diag}),
            else => return ctx.fail("{s}: {t}", .{ file, err }),
        };
    }
    config.useEnv(ctx.environ);
    try config.automaticEnv("APP");
    try config.bindFlags(try ctx.changedFlags(), .{});

    var diag: cfg.Diagnostic = .{};
    const settings = config.decode(server, .{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("{f}", .{diag}),
    };
    try ctx.out.print("listening on {s}:{d} with {d} workers, timeout {f}\n", .{
        settings.host, settings.port, settings.workers, settings.timeout,
    });
    try ctx.out.print("tls: {s}\n", .{if (settings.tls.cert != null) "on" else "off"});
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
    .flags = Flags,
    .run = serve,
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root };
    return app.run(init);
}

test "a value out of bounds is reported with its key" {
    const app: cli.App = .{ .root = &root };
    const result = try cli.testing.run(app, &.{}, .{ .env = &.{.{ "APP_WORKERS", "100" }} });
    defer result.deinit();
    try std.testing.expectEqual(1, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.err, "workers") != null);
}
