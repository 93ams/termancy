//! `termancy tui list`: the registry's components, and their state in the project.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const catalog = @import("project/catalog.zig");
const manifest = @import("project/manifest.zig");
const status = @import("project/status.zig");
const Workspace = @import("project/workspace.zig");
const group = @import("init.zig").group;

const ListFlags = struct {
    project: []const u8 = ".",
};
const list_flags = cli.flags(ListFlags, field.Set(.{field.Spec(ListFlags){ .fields = .{
    .project = .{ .help = "The project directory" },
} }}), .{ .fields = .{
    .project = .{ .short = 'C', .value_name = "path" },
} });

pub const command = cli.command(.{
    .name = "list",
    .summary = "List the components and their state in the project",
    .description =
    \\List every component in the registry with its summary and, when the project has a
    \\tui.zon, its state: - (not installed), installed, modified (a file was edited or
    \\removed), outdated (the registry has a newer version), or modified,outdated.
    \\
    \\-o json prints one object, keys in this order:
    \\  {"version": 1, "manifest": bool,
    \\   "components": [{"name": string, "summary": string, "requires": [string],
    \\     "files": [string], "installed": bool, "modified": bool, "outdated": bool}]}
    \\"manifest" says whether tui.zon was found; without it, every component is not
    \\installed. "version" changes only when the shape does.
    ,
    .group = group,
    .flags = list_flags,
    .output = true,
    .examples =
    \\termancy tui list
    \\termancy tui list -o json -C demo
    ,
    .run = run,
});

/// The shape of `-o json`; field order is the output order.
const Listing = struct {
    version: u32 = 1,
    manifest: bool,
    components: []const Row,
};

const Row = struct {
    name: []const u8,
    summary: []const u8,
    requires: []const []const u8,
    files: []const []const u8,
    installed: bool,
    modified: bool,
    outdated: bool,
};

fn run(ctx: *cli.Context, flags: ListFlags) !void {
    var ws: Workspace = try .open(ctx, flags.project, false);
    defer ws.close(ctx.io);
    const m = try ws.loadManifest(ctx);
    const components = try Workspace.components(ctx);
    const rows = try ctx.arena.alloc(Row, components.len);
    for (components, rows) |*component, *row| {
        var state: status.Status = .{};
        if (m) |found| state = try componentStatus(ctx, &ws, found, component);
        row.* = .{
            .name = component.name,
            .summary = component.summary,
            .requires = component.requires,
            .files = component.files,
            .installed = state.installed,
            .modified = state.modified,
            .outdated = state.outdated,
        };
    }
    const listing: Listing = .{ .manifest = m != null, .components = rows };
    if (ctx.output != .text) return ctx.render(listing);
    try writeTable(ctx.out, rows);
}

/// The state of `component` in the project `m` describes.
pub fn componentStatus(
    ctx: *cli.Context,
    ws: *Workspace,
    m: manifest.Manifest,
    component: *const catalog.Component,
) !status.Status {
    if (m.components.get(component.name) == null) return .{};
    var state: status.Status = .{ .installed = true };
    for (component.files) |name| {
        const disk = try ws.read(ctx, try manifest.filePath(ctx.arena, m, name));
        const registry = try Workspace.source(ctx, name);
        status.addFile(&state, disk, m.recorded(component.name, name), registry);
    }
    return state;
}

fn writeTable(writer: *std.Io.Writer, rows: []const Row) std.Io.Writer.Error!void {
    var name_width: usize = "NAME".len;
    var state_width: usize = "STATUS".len;
    for (rows) |row| {
        name_width = @max(name_width, row.name.len);
        state_width = @max(state_width, label(row).len);
    }
    try writeRow(writer, .{ "NAME", "STATUS", "SUMMARY" }, name_width, state_width);
    for (rows) |row| {
        try writeRow(writer, .{ row.name, label(row), row.summary }, name_width, state_width);
    }
}

fn label(row: Row) []const u8 {
    const state: status.Status = .{
        .installed = row.installed,
        .modified = row.modified,
        .outdated = row.outdated,
    };
    return state.label();
}

fn writeRow(
    writer: *std.Io.Writer,
    cells: [3][]const u8,
    name_width: usize,
    state_width: usize,
) std.Io.Writer.Error!void {
    try writer.writeAll(cells[0]);
    try writer.splatByteAll(' ', name_width - cells[0].len + 2);
    try writer.writeAll(cells[1]);
    try writer.splatByteAll(' ', state_width - cells[1].len + 2);
    try writer.print("{s}\n", .{cells[2]});
}
