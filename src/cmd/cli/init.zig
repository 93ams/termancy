//! `snek cli init <name>`: a new application on the `cli` and `cfg` modules, laid out as
//! snek itself is: `build.zig`, `build.zig.zon`, `src/main.zig` holding `main` and the
//! command tree, and an example command in `src/cmd/hello.zig`.

const std = @import("std");
const cli = @import("cli");
const term = @import("term");
const templates = @import("templates.zig");

const InitFlags = struct {
    dir: ?[]const u8 = null,
    module_path: ?[]const u8 = null,
    fetch: ?[]const u8 = null,
    force: bool = false,
    pub const meta = .{
        .dir = .{ .help = "Directory to create (default: the name)", .value_name = "path" },
        .module_path = .{
            .help = "Depend on a snek checkout at this path (for offline or local work)",
            .value_name = "path",
        },
        .fetch = .{
            .help = "Depend on snek at this URL, recorded by zig fetch --save=snek",
            .value_name = "url",
        },
        .force = .{ .help = "Write into a non-empty directory, replacing files" },
    };
};

pub const command = cli.command(.{
    .name = "init",
    .summary = "Create a new application on the cli and cfg modules",
    .description =
    \\Write build.zig, build.zig.zon, src/main.zig, an example command in src/cmd/hello.zig,
    \\README.md, and .gitignore for a new application called <name>. The snek dependency is
    \\a path with --module-path, or is fetched with --fetch (which runs zig fetch
    \\--save=snek <url>); with neither, add it yourself before building. Refuses to write
    \\into a non-empty directory without --force.
    ,
    .flags = InitFlags,
    .args = .{ .min = 1, .max = 1, .usage = "<name>" },
    .exclusive = &.{&.{ "module-path", "fetch" }},
    .examples =
    \\snek cli init demo --module-path ../snek
    \\snek cli init demo --fetch git+https://github.com/93ams/snek
    ,
    .run = run,
});

/// Package names longer than this are rejected by the Zig package manager.
const max_name_len = 32;

fn run(ctx: *cli.Context, flags: InitFlags) !void {
    const name = ctx.args[0];
    const package = try packageName(ctx, name);
    const dir_path = flags.dir orelse name;
    try checkEmpty(ctx, dir_path, flags.force);
    // Checked before anything is created, so a bad path leaves nothing behind.
    const module_real = if (flags.module_path) |path| try checkModule(ctx, path) else null;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(ctx.io, dir_path) catch |err| {
        return ctx.fail("{s}: cannot create: {s}", .{ dir_path, @errorName(err) });
    };
    var dir = cwd.openDir(ctx.io, dir_path, .{}) catch |err| {
        return ctx.fail("{s}: cannot open: {s}", .{ dir_path, @errorName(err) });
    };
    defer dir.close(ctx.io);

    const dependency: templates.Dependency = if (module_real) |real|
        .{ .path = try relativeTo(ctx, dir, real) }
    else
        .none;
    const random: std.Random.IoSource = .{ .io = ctx.io };
    const fingerprint = templates.fingerprint(random.interface(), package);
    const arena = ctx.arena;
    const files = [_]struct { []const u8, []const u8 }{
        .{ "build.zig", try templates.render(arena, templates.buildZig, .{name}) },
        .{
            "build.zig.zon",
            try templates.render(arena, templates.buildZon, .{ package, fingerprint, dependency }),
        },
        .{ "src/main.zig", try templates.render(arena, templates.mainZig, .{name}) },
        .{ "src/cmd/hello.zig", try templates.render(arena, templates.leaf, .{templates.hello}) },
        .{ "src/settings.zig", try templates.render(arena, templates.settingsZig, .{name}) },
        .{ "README.md", try templates.render(arena, templates.readme, .{name}) },
        .{ ".gitignore", templates.gitignore },
    };
    for (files) |file| try writeFile(ctx, dir, dir_path, file[0], file[1], flags.force);
    if (flags.fetch) |url| try fetch(ctx, dir_path, url);
    if (flags.module_path == null and flags.fetch == null) {
        try ctx.out.print("next: cd {s}" ++ then ++ "zig fetch --save=snek <url of snek>\n", .{dir_path});
    } else {
        try ctx.out.print("next: cd {s}" ++ then ++ "zig build run -- --help\n", .{dir_path});
    }
}

/// Between the two commands of the "next:" hint: `&&` where every shell takes it; on
/// Windows a second line, since Windows PowerShell 5.1 does not.
const then = if (@import("builtin").os.tag == .windows) "\n      " else " && ";

/// The package name for `build.zig.zon`: `name` with `-` as `_`, which must then be a
/// plain Zig identifier.
fn packageName(ctx: *cli.Context, name: []const u8) ![]const u8 {
    const package = try ctx.arena.dupe(u8, name);
    std.mem.replaceScalar(u8, package, '-', '_');
    const lower = for (name) |c| {
        if (std.ascii.isUpper(c)) break false;
    } else true;
    if (name.len > max_name_len or !lower or !std.zig.isValidId(package)) {
        return ctx.usageError("invalid name \"{s}\": use at most {d} lowercase letters, digits, " ++
            "_ and -, starting with a letter, and not a Zig keyword", .{ name, max_name_len });
    }
    return package;
}

/// Fails unless `path` is missing or an empty directory, or `force` is set.
fn checkEmpty(ctx: *cli.Context, path: []const u8, force: bool) !void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => {},
            error.NotDir => ctx.fail("{s}: not a directory", .{path}),
            else => ctx.fail("{s}: cannot open: {s}", .{ path, @errorName(err) }),
        };
    };
    defer dir.close(ctx.io);
    var it = dir.iterate();
    const entry = it.next(ctx.io) catch |err| {
        return ctx.fail("{s}: cannot list: {s}", .{ path, @errorName(err) });
    };
    if (entry != null and !force) {
        return ctx.fail("{s}: directory is not empty (use --force to write into it)", .{path});
    }
}

/// The real path of `module_path`, after checking that it is a snek checkout.
fn checkModule(ctx: *cli.Context, module_path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const real = cwd.realPathFileAlloc(ctx.io, module_path, ctx.arena) catch |err| {
        return ctx.fail("{s}: cannot resolve: {s}", .{ module_path, @errorName(err) });
    };
    var module = cwd.openDir(ctx.io, real, .{}) catch |err| {
        return ctx.fail("{s}: cannot open: {s}", .{ module_path, @errorName(err) });
    };
    defer module.close(ctx.io);
    module.access(ctx.io, "src/cli/root.zig", .{}) catch {
        return ctx.fail("{s}: not a snek checkout (no src/cli/root.zig)", .{module_path});
    };
    return real;
}

/// `target` (a real path) relative to the project directory.
fn relativeTo(ctx: *cli.Context, project: std.Io.Dir, target: []const u8) ![]const u8 {
    const project_real = project.realPathFileAlloc(ctx.io, ".", ctx.arena) catch |err| {
        return ctx.fail("cannot resolve the project directory: {s}", .{@errorName(err)});
    };
    const relative = try std.fs.path.relativeAlloc(
        ctx.arena,
        project_real,
        ctx.environ,
        project_real,
        target,
    );
    return if (relative.len == 0) "." else relative;
}

fn writeFile(
    ctx: *cli.Context,
    dir: std.Io.Dir,
    dir_path: []const u8,
    path: []const u8,
    content: []const u8,
    force: bool,
) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(ctx.io, parent) catch |err| {
            return ctx.fail("{s}/{s}: cannot create: {s}", .{ dir_path, parent, @errorName(err) });
        };
    }
    const file = dir.createFile(ctx.io, path, .{ .exclusive = !force }) catch |err| {
        return ctx.fail("{s}/{s}: cannot create: {s}", .{ dir_path, path, @errorName(err) });
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, content) catch |err| {
        return ctx.fail("{s}/{s}: cannot write: {s}", .{ dir_path, path, @errorName(err) });
    };
    try ctx.out.print("created {s}/{s}\n", .{ dir_path, path });
}

/// Runs `zig fetch --save=snek <url>` in the new project, which records the URL and the
/// package hash in `build.zig.zon`.
pub fn fetch(ctx: *cli.Context, dir_path: []const u8, url: []const u8) !void {
    const argv = [_][]const u8{ "zig", "fetch", "--save=snek", url };
    var spinner: term.live.Spinner = .{
        .title = try std.fmt.allocPrint(ctx.arena, "fetching snek from {s}", .{url}),
    };
    const items = [_]term.live.Item{.{ .spinner = &spinner }};
    var display = ctx.live(&items);
    display.start(ctx.io) catch {};
    const run_result = std.process.run(ctx.gpa, ctx.io, .{
        .argv = &argv,
        .cwd = .{ .path = dir_path },
    });
    try display.clear();
    const result = run_result catch |err|
        return ctx.fail("cannot run zig fetch: {s}", .{@errorName(err)});
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    if (!result.term.success()) {
        try ctx.err.writeAll(result.stderr);
        return ctx.fail("zig fetch --save=snek {s} failed", .{url});
    }
    try ctx.out.print("fetched snek from {s}\n", .{url});
}
