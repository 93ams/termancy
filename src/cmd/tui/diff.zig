//! `snek tui diff <component>`: the project's copy of a component against the registry's,
//! as a unified diff.

const std = @import("std");
const cli = @import("cli");
const catalog = @import("project/catalog.zig");
const term = @import("tui").term;
const manifest = @import("project/manifest.zig");
const workspace = @import("project/workspace.zig");
const Workspace = workspace.Workspace;
const group = @import("init.zig").group;

const DiffFlags = struct {
    project: []const u8 = ".",
    pub const meta = .{
        .project = .{ .short = 'C', .help = "The project directory", .value_name = "path" },
    };
};

pub const command = cli.command(.{
    .name = "diff",
    .summary = "Compare the project's copy of a component with the registry's",
    .description =
    \\Print a unified diff from each file of the component in the project (--- side) to
    \\the registry's version (+++ side); a missing file compares as empty. As with diff(1),
    \\exits 0 when they are identical, 1 when they differ, and 2 when the component is
    \\unknown or not installed.
    ,
    .group = group,
    .flags = DiffFlags,
    .args = .{ .min = 1, .max = 1, .usage = "<component>" },
    .examples =
    \\snek tui diff select
    \\snek tui diff select -C demo | less
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: DiffFlags) !void {
    const name = ctx.args[0];
    var ws: Workspace = try .open(ctx, flags.project, false);
    defer ws.close(ctx.io);
    const m = try ws.loadManifest(ctx) orelse return ctx.usageError("{s}{s}: not found (run " ++
        "snek tui init first)", .{ ws.prefix, manifest.file_name });
    const component = catalog.find(try workspace.components(ctx), name) orelse
        return ctx.usageError("unknown component \"{s}\" (snek tui list lists them)", .{name});
    if (m.components.get(name) == null) {
        return ctx.usageError("{s}: not installed (snek tui add {s} installs it)", .{
            name, name,
        });
    }
    var different = false;
    for (component.files) |file| {
        const path = try manifest.filePath(ctx.arena, m, file);
        const ours = try ws.read(ctx, path) orelse "";
        const theirs = try workspace.source(ctx, file);
        const a_name = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ ws.prefix, path });
        const b_name = try std.fmt.allocPrint(ctx.arena, "registry/{s}", .{file});
        const options: term.diff.Options = .{ .color = ctx.color != .none };
        if (try term.diff.unified(ctx.arena, ctx.out, a_name, ours, b_name, theirs, options)) {
            different = true;
        }
    }
    // Like diff(1): status 1, with nothing more to say.
    if (different) return error.CommandFailed;
}
