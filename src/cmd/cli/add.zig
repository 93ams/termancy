//! `snek cli add <path...>`: writes a command into a project made by `snek cli init` and
//! lists it in its parent.
//!
//! For `add config get`: the leaf is `src/cmd/config/get.zig`; the group `config` is
//! `src/cmd/config/main.zig`, created when missing and listed in `src/main.zig`. Each
//! parent gets two lines, at its `// snek:subcommands` and `// snek:tests` markers. Nothing
//! is written unless every change can be made, and no file is ever overwritten.

const std = @import("std");
const cli = @import("cli");
const flagspec = @import("flagspec.zig");
const templates = @import("templates.zig");
const project = @import("project.zig");

const AddFlags = struct {
    flag: []const []const u8 = &.{},
    args: ?[]const u8 = null,
    summary: []const u8 = "",
    dir: []const u8 = ".",
    flow: bool = false,
    pub const meta = .{
        .flow = .{ .help = "Write a flow: the flags are questions, asked when not given" },
        .flag = .{
            .short = 'f',
            .help = "A flag: name:type[=default][,short=x][,required][,help=text]",
            .value_name = "spec",
        },
        .args = .{
            .help = "Positional arguments: N, N:M, or N: for no upper limit",
            .value_name = "min[:max]",
        },
        .summary = .{ .short = 's', .help = "One line for help", .value_name = "text" },
        .dir = .{ .short = 'C', .help = "The project directory", .value_name = "path" },
    };
};

pub const command = cli.command(.{
    .name = "add",
    .summary = "Add a command to an application made by snek cli init",
    .description =
    \\Write a command with a typed flags struct, a handler that prints what it receives,
    \\and a test, then list it in its parent. Every word of the path but the last is a
    \\group, created when missing.
    \\
    \\Flag types: bool, count, int, uint, i8...i64, u8...u64, float, f32, f64, string,
    \\enum(a|b|c), list(T). A scalar without a default is optional (?T) unless marked
    \\required.
    ,
    .flags = AddFlags,
    .args = .{ .min = 1, .max = null, .usage = "<command>..." },
    .examples =
    \\snek cli add hello --flag name:string=world --summary "Say hello"
    \\snek cli add config get --flag key:string,required --flag verbose:count,short=v
    \\snek cli add files copy --args 2: --flag mode:enum(fast|safe)=safe
    \\snek cli add deploy --flow --flag env:enum(staging|production) --flag version:string,required
    ,
    .run = run,
});

/// A path deeper than this is a mistake, not a design.
const max_path_len = 8;

const Args = struct { min: usize, max: ?usize };

fn run(ctx: *cli.Context, flags: AddFlags) !void {
    const path = ctx.args;
    if (path.len > max_path_len) return ctx.usageError("at most {d} words", .{max_path_len});
    for (path) |word| {
        if (!flagspec.isWord(word) or std.mem.eql(u8, word, "main")) {
            return ctx.usageError("invalid command name \"{s}\" (use lowercase words joined " ++
                "by -, not main)", .{word});
        }
    }
    for (flags.summary) |c| {
        if (!std.ascii.isPrint(c)) return ctx.usageError("--summary must be one line", .{});
    }
    var message: []const u8 = "";
    const specs = flagspec.parseAll(ctx.arena, flags.flag, &message) catch |err| switch (err) {
        error.InvalidFlagSpec => return ctx.usageError("{s}", .{message}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const args = parseArgs(flags.args orelse "0") orelse
        return ctx.usageError("invalid --args \"{s}\" (use N, N:M, or N:)", .{flags.args.?});
    if (flags.flow and args.max != 0) return ctx.usageError("a --flow takes no --args", .{});
    if (flags.flow and specs.len > templates.max_flow_flags) {
        return ctx.usageError("a --flow takes at most {d} flags", .{templates.max_flow_flags});
    }

    var dir = std.Io.Dir.cwd().openDir(ctx.io, flags.dir, .{}) catch |err| {
        return ctx.fail("{s}: cannot open: {s}", .{ flags.dir, @errorName(err) });
    };
    defer dir.close(ctx.io);
    var plan: project.Plan = .{ .io = ctx.io, .arena = ctx.arena, .root = dir };
    _ = plan.get("src/main.zig") catch |err| return planError(ctx, flags.dir, "src/main.zig", err);
    try planCommand(ctx, &plan, flags.dir, path, .{
        .path = path,
        .summary = flags.summary,
        .flags = specs,
        .args_min = args.min,
        .args_max = args.max,
    }, flags.flow);
    const prefix = if (std.mem.eql(u8, flags.dir, "."))
        ""
    else
        try std.fmt.allocPrint(ctx.arena, "{s}/", .{std.mem.trimEnd(u8, flags.dir, "/")});
    plan.commit(ctx.out, prefix) catch |err| {
        return ctx.fail("cannot write the project: {s}", .{@errorName(err)});
    };
}

/// `N`, `N:M` (M >= N), or `N:`.
fn parseArgs(text: []const u8) ?Args {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const min = std.fmt.parseInt(usize, text[0 .. colon orelse text.len], 10) catch return null;
    const after = if (colon) |at| text[at + 1 ..] else return .{ .min = min, .max = min };
    if (after.len == 0) return .{ .min = min, .max = null };
    const max = std.fmt.parseInt(usize, after, 10) catch return null;
    if (max < min) return null;
    return .{ .min = min, .max = max };
}

/// Plans the groups along `path` and the leaf at its end.
fn planCommand(
    ctx: *cli.Context,
    plan: *project.Plan,
    dir: []const u8,
    path: []const []const u8,
    leaf: templates.Leaf,
    flow: bool,
) !void {
    var parent: []const u8 = "src/main.zig";
    var import_prefix: []const u8 = "cmd/";
    var folder: []const u8 = "src/cmd/";
    for (path[0 .. path.len - 1], 1..) |word, depth| {
        const group_file = try std.fmt.allocPrint(ctx.arena, "{s}{s}/main.zig", .{ folder, word });
        const as_leaf = try std.fmt.allocPrint(ctx.arena, "{s}{s}.zig", .{ folder, word });
        if (!try exists(ctx, plan, dir, group_file)) {
            if (try exists(ctx, plan, dir, as_leaf)) {
                return ctx.fail("{s}: \"{s}\" is a command, not a group", .{ as_leaf, word });
            }
            const content = try templates.render(ctx.arena, templates.group, .{path[0..depth]});
            try plan.create(group_file, content);
            const import = try std.fmt.allocPrint(ctx.arena, "{s}{s}/main.zig", .{
                import_prefix, word,
            });
            try mount(ctx, plan, dir, parent, import);
        }
        parent = group_file;
        import_prefix = "";
        folder = try std.fmt.allocPrint(ctx.arena, "{s}{s}/", .{ folder, word });
    }
    const name = path[path.len - 1];
    const file = try std.fmt.allocPrint(ctx.arena, "{s}{s}.zig", .{ folder, name });
    const as_group = try std.fmt.allocPrint(ctx.arena, "{s}{s}/main.zig", .{ folder, name });
    for ([_][]const u8{ file, as_group }) |existing| {
        if (try exists(ctx, plan, dir, existing)) {
            return ctx.fail("{s}: the command already exists", .{existing});
        }
    }
    const content = if (flow)
        try templates.render(ctx.arena, templates.flowLeaf, .{leaf})
    else
        try templates.render(ctx.arena, templates.leaf, .{leaf});
    try plan.create(file, content);
    const import = try std.fmt.allocPrint(ctx.arena, "{s}{s}.zig", .{ import_prefix, name });
    try mount(ctx, plan, dir, parent, import);
}

fn exists(ctx: *cli.Context, plan: *project.Plan, dir: []const u8, path: []const u8) !bool {
    return plan.exists(path) catch |err| planError(ctx, dir, path, err);
}

/// Lists the file `import` (relative to `parent`) in `parent`'s subcommands and tests.
fn mount(
    ctx: *cli.Context,
    plan: *project.Plan,
    dir: []const u8,
    parent: []const u8,
    import: []const u8,
) !void {
    const file = plan.get(parent) catch |err| return planError(ctx, dir, parent, err);
    const entries = [_][2][]const u8{
        .{ templates.subcommands_marker, "@import(\"{s}\").command," },
        .{ templates.tests_marker, "_ = @import(\"{s}\");" },
    };
    inline for (entries) |entry| {
        const line = try std.fmt.allocPrint(ctx.arena, entry[1], .{import});
        file.content = project.insertAtMarker(ctx.arena, file.content, entry[0], line) catch |err| {
            return switch (err) {
                error.MarkerNotFound => ctx.fail("{s}: no \"{s}\" line to add the command at", .{
                    parent, entry[0],
                }),
                error.MarkerRepeated => ctx.fail("{s}: more than one \"{s}\" line", .{
                    parent, entry[0],
                }),
                error.AlreadyPresent => ctx.fail("{s}: already lists {s}", .{ parent, import }),
                error.OutOfMemory => error.OutOfMemory,
            };
        };
    }
    file.changed = true;
}

fn planError(
    ctx: *cli.Context,
    dir: []const u8,
    path: []const u8,
    err: project.Plan.ReadError,
) (cli.Context.Failure || std.mem.Allocator.Error) {
    return switch (err) {
        error.FileNotFound => ctx.fail("{s}/{s}: not found (is {s} a project made by snek cli " ++
            "init?)", .{ dir, path, dir }),
        error.UnsafePath, error.OutsideProject => ctx.fail("{s}/{s}: outside the project", .{
            dir, path,
        }),
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => ctx.fail("{s}/{s}: cannot read", .{ dir, path }),
    };
}

const testing = std.testing;

test parseArgs {
    try testing.expectEqual(Args{ .min = 2, .max = 2 }, parseArgs("2").?);
    try testing.expectEqual(Args{ .min = 1, .max = 3 }, parseArgs("1:3").?);
    try testing.expectEqual(Args{ .min = 1, .max = null }, parseArgs("1:").?);
    try testing.expectEqual(null, parseArgs("3:1"));
    try testing.expectEqual(null, parseArgs(":2"));
    try testing.expectEqual(null, parseArgs("x"));
}

/// Runs snek with `args`; the caller frees the result.
fn snek(args: []const []const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{});
}

test "init, then add twice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = ".zig-cache/tmp/" ++ tmp.sub_path;
    const project_dir = base ++ "/demo";

    const init = try snek(&.{ "cli", "init", "demo", "--dir", project_dir });
    defer init.deinit();
    try testing.expectEqualStrings("", init.err);
    try testing.expectEqual(0, init.status);

    const leaf = try snek(&.{ "cli", "add", "-C", project_dir, "config", "get", "-f", "raw:bool" });
    defer leaf.deinit();
    try testing.expectEqualStrings("", leaf.err);
    try testing.expectEqualStrings(
        "created " ++ project_dir ++ "/src/cmd/config/main.zig\n" ++
            "created " ++ project_dir ++ "/src/cmd/config/get.zig\n" ++
            "updated " ++ project_dir ++ "/src/main.zig\n",
        leaf.out,
    );
    const sibling = try snek(&.{ "cli", "add", "-C", project_dir, "config", "set", "--args", "2" });
    defer sibling.deinit();
    try testing.expectEqual(0, sibling.status);

    var buffer: [4096]u8 = undefined;
    const group_text = try tmp.dir.readFile(testing.io, "demo/src/cmd/config/main.zig", &buffer);
    try testing.expect(std.mem.indexOf(u8, group_text,
        \\    .subcommands = .{
        \\        @import("get.zig").command,
        \\        @import("set.zig").command,
        \\        // snek:subcommands
        \\    },
    ) != null);
    try testing.expect(std.mem.indexOf(u8, group_text,
        \\    _ = @import("get.zig");
        \\    _ = @import("set.zig");
        \\    // snek:tests
    ) != null);
    const main_text = try tmp.dir.readFile(testing.io, "demo/src/main.zig", &buffer);
    // Listed once in `.subcommands` and once in the tests, however many leaves it has.
    try testing.expectEqual(2, std.mem.count(u8, main_text, "@import(\"cmd/config/main.zig\")"));

    const again = try snek(&.{ "cli", "add", "-C", project_dir, "config", "get" });
    defer again.deinit();
    try testing.expectEqual(1, again.status);
    try testing.expectEqualStrings(
        "snek: src/cmd/config/get.zig: the command already exists\n",
        again.err,
    );
    const not_empty = try snek(&.{ "cli", "init", "demo", "--dir", project_dir });
    defer not_empty.deinit();
    try testing.expectEqual(1, not_empty.status);
}
