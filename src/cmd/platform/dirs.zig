//! `snek platform dirs [app]`: where this operating system keeps an application's
//! configuration, cache, data, state, and runtime files.

const std = @import("std");
const cli = @import("cli");
const platform = @import("platform");
const group = @import("main.zig");

const Kind = platform.dirs.Kind;

const DirsFlags = struct {
    search: bool = false,
    null: bool = false,
    pub const meta = .{
        .search = .{ .help = "Print the configuration search path instead" },
        .null = .{ .short = '0', .help = "End lines with NUL, not newline (for xargs -0)" },
    };
};

pub const command = cli.command(.{
    .name = "dirs",
    .summary = "Print where an application's files go on this system",
    .description =
    \\Print the config, cache, data, state, and runtime directories of [app] (default:
    \\snek): XDG on Linux and the BSDs, ~/Library on macOS, known folders on Windows.
    \\Nothing is created. A directory the system does not define prints as - (null in
    \\JSON); today that is only runtime, without $XDG_RUNTIME_DIR.
    \\
    \\With --search, print the directories a configuration loader should search, most
    \\specific first, one per line.
    \\
    \\-o json prints one object, keys in this order:
    \\  {"app": string, "os": string, "config": string, "cache": string, "data": string,
    \\   "state": string, "runtime": string or null}
    \\or, with --search:
    \\  {"app": string, "os": string, "search": [string, ...]}
    ,
    .flags = DirsFlags,
    .output = true,
    .args = .{ .max = 1, .usage = "[app]" },
    .examples =
    \\snek platform dirs
    \\snek platform dirs myapp -o json
    \\snek platform dirs --search
    ,
    .run = run,
});

/// The shape of `-o json`; field order is the output order.
const Dirs = struct {
    app: []const u8,
    os: []const u8,
    config: []const u8,
    cache: []const u8,
    data: []const u8,
    state: []const u8,
    runtime: ?[]const u8,
};

/// The shape of `--search -o json`.
const Search = struct {
    app: []const u8,
    os: []const u8,
    search: []const []const u8,
};

fn run(ctx: *cli.Context, flags: DirsFlags) !void {
    const app = if (ctx.args.len > 0) ctx.args[0] else "snek";
    if (!isAppName(app)) {
        return ctx.usageError("invalid app name \"{s}\": it names a directory, so it cannot " ++
            "be empty, . or .., or hold / or \\", .{app});
    }
    if (flags.null and (!flags.search or ctx.output != .text)) {
        return ctx.usageError("--null applies to --search with text output", .{});
    }
    if (flags.search) return runSearch(ctx, app, flags.null);
    // Only the runtime directory can be undefined; the others fall back to the home.
    const found: Dirs = .{
        .app = app,
        .os = @tagName(platform.dirs.native),
        .config = (try locate(ctx, .config, app)).?,
        .cache = (try locate(ctx, .cache, app)).?,
        .data = (try locate(ctx, .data, app)).?,
        .state = (try locate(ctx, .state, app)).?,
        .runtime = try locate(ctx, .runtime, app),
    };
    if (ctx.output != .text) return ctx.render(found);
    try group.writeRows(ctx.out, &.{
        .{ "config", found.config },
        .{ "cache", found.cache },
        .{ "data", found.data },
        .{ "state", found.state },
        .{ "runtime", found.runtime orelse "-" },
    });
}

fn runSearch(ctx: *cli.Context, app: []const u8, nul: bool) !void {
    const os = platform.dirs.native;
    const search = platform.dirs.configSearchPath(ctx.arena, ctx.environ, os, app) catch |err| {
        return switch (err) {
            error.HomeNotFound => noHome(ctx),
            error.RuntimeDirNotSet => unreachable, // Only the runtime directory needs it.
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    if (ctx.output != .text) {
        return ctx.render(Search{ .app = app, .os = @tagName(os), .search = search.dirs });
    }
    for (search.dirs) |dir| try ctx.out.print("{s}{c}", .{ dir, @as(u8, if (nul) 0 else '\n') });
}

/// The directory of `kind`, or null when the system defines none.
fn locate(ctx: *cli.Context, kind: Kind, app: []const u8) !?[]const u8 {
    return platform.dirs.nativePath(ctx.arena, ctx.environ, kind, app) catch |err| switch (err) {
        error.HomeNotFound => noHome(ctx),
        error.RuntimeDirNotSet => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn noHome(ctx: *cli.Context) cli.Context.Failure {
    const variable = if (platform.dirs.native == .windows) "USERPROFILE" else "HOME";
    return ctx.fail("no home directory: set {s} to an absolute path", .{variable});
}

/// A single, real path component: what `platform.dirs` appends to a base directory.
fn isAppName(app: []const u8) bool {
    if (app.len == 0 or std.mem.eql(u8, app, ".") or std.mem.eql(u8, app, "..")) return false;
    return std.mem.indexOfAny(u8, app, "/\\\x00") == null;
}

const testing = std.testing;

test isAppName {
    try testing.expect(isAppName("snek"));
    try testing.expect(isAppName("my app"));
    try testing.expect(!isAppName(""));
    try testing.expect(!isAppName(".."));
    try testing.expect(!isAppName("a/b"));
    try testing.expect(!isAppName("a\\b"));
}

/// Runs snek with `args` and `environ`; the caller frees the result.
fn snek(args: []const []const u8, env: []const [2][]const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{ .env = env });
}

test "dirs without a home directory" {
    const result = try snek(&.{ "platform", "dirs" }, &.{});
    defer result.deinit();
    try testing.expectEqual(1, result.status);
    try testing.expect(std.mem.startsWith(u8, result.err, "snek: no home directory: set "));
}

test "dirs rejects an app name that is a path" {
    const result = try snek(&.{ "platform", "dirs", "../x" }, &.{.{ "HOME", "/h" }});
    defer result.deinit();
    try testing.expectEqual(2, result.status);
}

test "dirs on Linux, text and JSON" {
    if (platform.dirs.native != .linux) return error.SkipZigTest;
    const environ = [_][2][]const u8{ .{ "HOME", "/h" }, .{ "XDG_CACHE_HOME", "/c" } };
    const text = try snek(&.{ "platform", "dirs", "app" }, &environ);
    defer text.deinit();
    try testing.expectEqualStrings(
        \\config   /h/.config/app
        \\cache    /c/app
        \\data     /h/.local/share/app
        \\state    /h/.local/state/app
        \\runtime  -
        \\
    , text.out);
    const json = try snek(&.{ "platform", "dirs", "app", "-o", "json", "--search" }, &environ);
    defer json.deinit();
    try testing.expectEqualStrings(
        \\{
        \\  "app": "app",
        \\  "os": "linux",
        \\  "search": [
        \\    "/h/.config/app",
        \\    "/etc/xdg/app"
        \\  ]
        \\}
        \\
    , json.out);
}
