//! A git-style tool: nested command groups, a persistent flag every command inherits,
//! typed positionals, aliases, enum and bounded flags, and a test of the whole tree.
//!
//!     zig build examples
//!     zig-out/bin/git-style remote add origin https://example.com/r.git -v
//!     zig-out/bin/git-style log --format full -n 2

const std = @import("std");
const cli = @import("cli");

/// Inherited by every command below the root.
const Global = struct {
    verbose: bool = false,
    pub const meta = .{ .verbose = .{ .short = 'v', .help = "Say what is happening" } };
};

const AddArgs = struct {
    name: []const u8,
    url: []const u8,
};

fn remoteAdd(ctx: *cli.Context, args: AddArgs) !void {
    const global = try ctx.flags(Global);
    if (global.verbose) try ctx.err.print("adding remote {s}\n", .{args.name});
    try ctx.out.print("{s}\t{s}\n", .{ args.name, args.url });
}

const RemoveArgs = struct { name: []const u8 };

fn remoteRemove(ctx: *cli.Context, args: RemoveArgs) !void {
    if (std.mem.eql(u8, args.name, "origin")) return ctx.fail("refusing to remove origin", .{});
    try ctx.out.print("removed {s}\n", .{args.name});
}

const LogFlags = struct {
    format: enum { oneline, full } = .oneline,
    max_count: u8 = 3,
    pub const meta = .{
        .format = .{ .help = "How much of each commit to show" },
        .max_count = .{ .short = 'n', .min = 1, .max = 50, .help = "How many commits" },
    };
};

const commits = [_][2][]const u8{
    .{ "a1b2c3d", "Add the parser" },
    .{ "e4f5a6b", "Fix the writer" },
    .{ "c7d8e9f", "First commit" },
};

fn log(ctx: *cli.Context, flags: LogFlags) !void {
    for (commits[0..@min(flags.max_count, commits.len)]) |commit| switch (flags.format) {
        .oneline => try ctx.out.print("{s} {s}\n", .{ commit[0], commit[1] }),
        .full => try ctx.out.print("commit {s}\n\n    {s}\n\n", .{ commit[0], commit[1] }),
    };
}

pub const root = cli.command(.{
    .name = "git-style",
    .summary = "A git-style command tree",
    .persistent_flags = Global,
    .subcommands = .{
        cli.command(.{
            .name = "remote",
            .summary = "Manage remotes",
            .subcommands = .{
                cli.command(.{
                    .name = "add",
                    .summary = "Add a remote",
                    .args = AddArgs,
                    .run = remoteAdd,
                }),
                cli.command(.{
                    .name = "remove",
                    .aliases = &.{"rm"},
                    .summary = "Remove a remote",
                    .args = RemoveArgs,
                    .run = remoteRemove,
                }),
            },
        }),
        cli.command(.{ .name = "log", .summary = "Show commits", .flags = LogFlags, .run = log }),
    },
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root, .version = "1.0.0" };
    return app.run(init);
}

test "the command tree, run in memory" {
    const app: cli.App = .{ .root = &root };
    const added = try cli.testing.run(app, &.{ "remote", "add", "origin", "https://x", "-v" }, .{});
    defer added.deinit();
    try added.expect(0, "origin\thttps://x\n", "adding remote origin\n");

    const removed = try cli.testing.run(app, &.{ "remote", "rm", "origin" }, .{});
    defer removed.deinit();
    try removed.expect(1, "", "git-style: refusing to remove origin\n");

    const bounded = try cli.testing.run(app, &.{ "log", "-n", "0" }, .{});
    defer bounded.deinit();
    try std.testing.expectEqual(2, bounded.status);
}
