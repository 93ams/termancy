//! What `sys` gives a command-line program, as a `doctor` command that checks its
//! surroundings:
//!
//! - `dirs`: where an app keeps config, cache, data, state, and runtime files, on Linux,
//!   macOS, or Windows: pure functions of the environment, so `--os` shows any of them;
//! - `env`: the CI provider, `DO_NOT_TRACK`, the user and shell, elevated privileges;
//! - `newer`: semantic version precedence, as an update check needs it;
//! - `paths`: whether paths stay inside allowed roots (`..` and symbolic links included),
//!   as a generator writing files must check;
//! - `log`: leveled logs as text or JSON lines, with secrets redacted by key and by value
//!   (a `.secret` flag's value, wherever it shows up);
//! - `trace`: W3C trace context continued from `TRACEPARENT` and handed to a child;
//! - `--profile`: a middleware timing the command's phases with `sys.profiler`.
//!
//!     zig build examples
//!     zig-out/bin/doctor dirs --os macos
//!     CI=true GITHUB_ACTIONS=true zig-out/bin/doctor env
//!     zig-out/bin/doctor newer 1.9.0 v1.10.0-rc.1
//!     zig-out/bin/doctor paths src/a.zig src/../build.zig --root src
//!     zig-out/bin/doctor log --format json --profile

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const sys = @import("sys");

const dirs = sys.dirs;

const Global = struct {
    profile: bool = false,
};
const global_flags = cli.flags(Global, field.Set(.{field.Spec(Global){ .fields = .{
    .profile = .{ .help = "Print how long each phase took" },
} }}), .{});

const Profiler = sys.profiler.Profiler(true);

/// Marks the start of a phase, when `--profile` is timing the command.
fn phase(ctx: *cli.Context, name: []const u8) void {
    const p: *Profiler = @ptrCast(@alignCast(ctx.user_data orelse return));
    p.begin(name) catch {};
}

fn endPhase(ctx: *cli.Context, name: []const u8) void {
    const p: *Profiler = @ptrCast(@alignCast(ctx.user_data orelse return));
    p.end(name);
}

/// Times the command when `--profile` is given, and prints the phases afterwards.
fn profiled(ctx: *cli.Context, next: cli.Context.Next) anyerror!void {
    const global = try ctx.flags(Global);
    if (!global.profile) return next.run();
    var recording: Profiler = .init(ctx.gpa, .{ .io = ctx.io });
    defer recording.deinit();
    // Handed to the handler as its data, for `phase`.
    ctx.user_data = &recording;
    try recording.begin("command");
    try next.run();
    recording.end("command");
    try recording.writeText(ctx.err);
}

// -- dirs --------------------------------------------------------------------------------

const DirsFlags = struct {
    os: ?enum { linux, macos, windows, freebsd } = null,
};
const dirs_flags = cli.flags(DirsFlags, field.Set(.{field.Spec(DirsFlags){ .fields = .{
    .os = .{ .help = "Show another system's directories (default: this one)" },
} }}), .{});

fn showDirs(ctx: *cli.Context, flags: DirsFlags) !void {
    const os: dirs.Os = if (flags.os) |os| switch (os) {
        inline else => |tag| @field(dirs.Os, @tagName(tag)),
    } else dirs.native;
    inline for (@typeInfo(dirs.Kind).@"enum".field_names) |name| {
        const kind = @field(dirs.Kind, name);
        if (dirs.path(ctx.arena, ctx.environ, os, kind, "doctor")) |dir| {
            try ctx.out.print("{s:<8} {s}\n", .{ name, dir });
        } else |err| {
            try ctx.out.print("{s:<8} ({t})\n", .{ name, err });
        }
    }
}

// -- env ---------------------------------------------------------------------------------

fn showEnv(ctx: *cli.Context) !void {
    const env = sys.env;
    const ci = if (env.ci(ctx.environ)) |ci| @tagName(ci) else "no";
    try ctx.out.print("ci:            {s}\n", .{ci});
    try ctx.out.print("do not track:  {}\n", .{env.doNotTrack(ctx.environ)});
    try ctx.out.print("user:          {s}\n", .{env.username(ctx.environ, dirs.native) orelse "?"});
    try ctx.out.print("shell:         {s}\n", .{env.shell(ctx.environ, dirs.native) orelse "?"});
    try ctx.out.print("elevated:      {}\n", .{env.isElevated()});
}

// -- newer -------------------------------------------------------------------------------

const NewerArgs = struct { current: []const u8, latest: []const u8 };

fn newer(ctx: *cli.Context, args: NewerArgs) !void {
    const Version = sys.Version;
    const current = Version.parse(args.current) catch
        return ctx.usageError("\"{s}\" is not a version", .{args.current});
    const latest = Version.parse(args.latest) catch
        return ctx.usageError("\"{s}\" is not a version", .{args.latest});
    if (!latest.newerThan(current)) return ctx.out.print("{f} is up to date\n", .{current});
    const kind = if (latest.isPrerelease()) "a pre-release" else "an update";
    try ctx.out.print("{f} is {s} to {f}\n", .{ latest, kind, current });
}

// -- paths -------------------------------------------------------------------------------

const PathsFlags = struct {
    root: []const []const u8 = &.{"."},
};
const paths_flags = cli.flags(PathsFlags, field.Set(.{field.Spec(PathsFlags){ .fields = .{
    .root = .{ .help = "A directory paths may be in; repeat for more" },
} }}), .{});

const PathsArgs = struct {
    paths: []const []const u8,
};
const paths_args = cli.args(
    PathsArgs,
    field.none,
    .{ .fields = .{ .paths = .{ .name = "path" } } },
);

fn checkPaths(ctx: *cli.Context, flags: PathsFlags, args: PathsArgs) !void {
    const policy: sys.sandbox.Policy = .{ .roots = flags.root };
    var refused: usize = 0;
    for (args.paths) |path| {
        if (policy.check(ctx.io, .cwd(), path)) {
            try ctx.out.print("ok      {s}\n", .{path});
        } else |err| {
            refused += 1;
            try ctx.out.print("refused {s} ({t})\n", .{ path, err });
        }
    }
    if (refused > 0) return ctx.exit(1);
}

// -- log ---------------------------------------------------------------------------------

const LogFlags = struct {
    format: sys.log.Format = .text,
    level: []const u8 = "info",
    token: ?[]const u8 = null,
};
const log_flags = cli.flags(LogFlags, field.Set(.{field.Spec(LogFlags){ .fields = .{
    .format = .{ .help = "Text for people, JSON lines for collectors" },
    .token = .{ .secret = true, .help = "An API token to log in with" },
    .level = .{
        .help = "The least to show",
        .checks = &.{.oneOf(&.{ "trace", "debug", "info", "warn", "error" })},
    },
} }}), .{ .fields = .{
    .token = .{ .env = "DOCTOR_TOKEN" },
} });

fn showLog(ctx: *cli.Context, flags: LogFlags) !void {
    phase(ctx, "log");
    defer endPhase(ctx, "log");
    var logger: sys.log.Logger = .{
        .writer = ctx.out,
        .format = flags.format,
        .level = try sys.log.parseLevel(flags.level),
        .secrets = try ctx.secretValues(),
    };
    if (flags.token) |token| logger.info("logging in", .{ .url = try std.fmt.allocPrint(
        ctx.arena,
        "https://api.example.com/?token={s}",
        .{token},
    ) });
    logger.debug("reading the configuration", .{ .path = "app.toml" });
    logger.info("listening", .{ .port = 8080, .tls = true });
    logger.scoped("db").warn("slow query", .{ .ms = 412, .password = "hunter2" });
    logger.err("request failed", .{ .status = 502, .authorization = "Bearer abc" });
}

// -- trace -------------------------------------------------------------------------------

fn showTrace(ctx: *cli.Context) !void {
    const trace = sys.trace;
    const incoming = trace.Context.fromEnviron(ctx.environ);
    const span = if (incoming) |parent| parent.child(ctx.io) else trace.Context.root(ctx.io, true);
    const how = if (incoming != null) "continuing" else "new trace";
    try ctx.out.print("{s} {f}\n", .{ how, span.parent });
    // What a child process would see.
    var child: std.process.Environ.Map = .init(ctx.arena);
    try span.toEnviron(&child);
    try ctx.out.print("child TRACEPARENT={s}\n", .{child.get("TRACEPARENT").?});
}

pub const root = cli.command(.{
    .name = "doctor",
    .summary = "Check what a program sees of its system",
    .persistent_flags = global_flags,
    .subcommands = .{
        cli.command(.{
            .name = "dirs",
            .summary = "Where the app's files go",
            .flags = dirs_flags,
            .run = showDirs,
        }),
        cli.command(.{ .name = "env", .summary = "Facts about the environment", .run = showEnv }),
        cli.command(.{
            .name = "newer",
            .summary = "Whether a version is newer than another",
            .args = NewerArgs,
            .run = newer,
        }),
        cli.command(.{
            .name = "paths",
            .summary = "Whether paths stay inside allowed roots",
            .flags = paths_flags,
            .args = paths_args,
            .run = checkPaths,
        }),
        cli.command(.{
            .name = "log",
            .summary = "Write sample logs",
            .flags = log_flags,
            .run = showLog,
        }),
        cli.command(.{ .name = "trace", .summary = "Continue a trace", .run = showTrace }),
    },
});

const app: cli.App = .{ .root = &root, .middleware = &.{profiled} };

pub fn main(init: std.process.Init) u8 {
    return app.run(init);
}

const testing = std.testing;

fn expectRun(
    args: []const []const u8,
    env: []const [2][]const u8,
    status: u8,
    out: []const u8,
) !void {
    const result = try cli.testing.run(app, args, .{ .env = env });
    defer result.deinit();
    testing.expectEqual(status, result.status) catch |err| {
        std.debug.print("{s}", .{result.err});
        return err;
    };
    try testing.expectEqualStrings(out, result.out);
}

test "every system's directories, from the environment alone" {
    try expectRun(&.{ "dirs", "--os", "linux" }, &.{
        .{ "HOME", "/home/ada" },
        .{ "XDG_CACHE_HOME", "/var/cache/ada" },
    }, 0,
        \\config   /home/ada/.config/doctor
        \\cache    /var/cache/ada/doctor
        \\data     /home/ada/.local/share/doctor
        \\state    /home/ada/.local/state/doctor
        \\runtime  (RuntimeDirNotSet)
        \\
    );
    try expectRun(&.{ "dirs", "--os", "macos" }, &.{.{ "HOME", "/Users/ada" }}, 0,
        \\config   /Users/ada/Library/Application Support/doctor
        \\cache    /Users/ada/Library/Caches/doctor
        \\data     /Users/ada/Library/Application Support/doctor
        \\state    /Users/ada/Library/Application Support/doctor/state
        \\runtime  /tmp/doctor
        \\
    );
}

test "CI and do-not-track" {
    const result = try cli.testing.run(app, &.{"env"}, .{ .env = &.{
        .{ "GITHUB_ACTIONS", "true" },
        .{ "DO_NOT_TRACK", "1" },
    } });
    defer result.deinit();
    const facts = "ci:            github_actions\ndo not track:  true\n";
    try testing.expect(std.mem.startsWith(u8, result.out, facts));
}

test "version precedence" {
    try expectRun(&.{ "newer", "1.9.0", "v1.10.0" }, &.{}, 0, "1.10.0 is an update to 1.9.0\n");
    try expectRun(&.{ "newer", "1.10.0", "1.10.0-rc.1" }, &.{}, 0, "1.10.0 is up to date\n");
    const pre = "1.1.0-rc.1+build.5 is a pre-release to 1.0.0\n";
    try expectRun(&.{ "newer", "1.0.0", "1.1.0-rc.1+build.5" }, &.{}, 0, pre);
    try expectRun(&.{ "newer", "one", "two" }, &.{}, 2, "");
}

test "paths outside the roots are refused, before touching the disk" {
    const args: []const []const u8 = &.{
        "paths", "examples/doctor/main.zig", "examples/../build.zig", "--root", "examples",
    };
    try expectRun(args, &.{}, 1,
        \\ok      examples/doctor/main.zig
        \\refused examples/../build.zig (Traversal)
        \\
    );
}

test "logs redact secrets, in both formats" {
    try expectRun(&.{"log"}, &.{}, 0,
        \\INFO listening port=8080 tls=true
        \\WARN slow query scope=db ms=412 password=[REDACTED]
        \\ERROR request failed status=502 authorization=[REDACTED]
        \\
    );
    const json = try cli.testing.run(app, &.{ "log", "--format", "json", "--level", "error" }, .{});
    defer json.deinit();
    try testing.expectEqualStrings(
        \\{"level":"error","msg":"request failed","status":502,"authorization":"[REDACTED]"}
        \\
    , json.out);
}

test "logs redact a secret flag's value wherever it appears" {
    const env: []const [2][]const u8 = &.{.{ "DOCTOR_TOKEN", "s3cr3t" }};
    const result = try cli.testing.run(app, &.{"log"}, .{ .env = env });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.out, "token=[REDACTED]") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "s3cr3t") == null);
    try expectRun(&.{ "log", "--token", "s3cr3t" }, &.{}, 0,
        \\INFO logging in url="https://api.example.com/?token=[REDACTED]"
        \\INFO listening port=8080 tls=true
        \\WARN slow query scope=db ms=412 password=[REDACTED]
        \\ERROR request failed status=502 authorization=[REDACTED]
        \\
    );
}

test "a trace is continued, and handed on" {
    const parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const env: []const [2][]const u8 = &.{.{ "TRACEPARENT", parent }};
    const result = try cli.testing.run(app, &.{"trace"}, .{ .env = env });
    defer result.deinit();
    // The same trace id, a new span id.
    const same = "continuing 00-4bf92f3577b34da6a3ce929d0e0e4736-";
    try testing.expect(std.mem.startsWith(u8, result.out, same));
    try testing.expect(std.mem.indexOf(u8, result.out, "00f067aa0ba902b7") == null);
}

test "--profile times the phases" {
    const result = try cli.testing.run(app, &.{ "log", "--profile" }, .{});
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.err, "command") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "log") != null);
}
