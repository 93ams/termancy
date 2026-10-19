//! `termancy tui add <component>...`: copies components, and every component they require,
//! from the registry into the project, and records what it wrote in `tui.zon`. With no
//! names at a terminal, asks which, with the multi-select `termancy ui choose` uses.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const live = @import("term").live;
const term = @import("../ui/term.zig");
const plain = @import("../ui/plain.zig");
const List = @import("registry/list.zig").List;
const MultiSelect = @import("registry/multiselect.zig").MultiSelect;
const catalog = @import("project/catalog.zig");
const manifest = @import("project/manifest.zig");
const status = @import("project/status.zig");
const workspace = @import("project/workspace.zig");
const Workspace = workspace.Workspace;
const group = @import("init.zig").group;

const AddFlags = struct {
    force: bool = false,
    prune: bool = false,
    project: []const u8 = ".",
};
const add_flags = cli.flags(AddFlags, field.Set(.{field.Spec(AddFlags){ .fields = .{
    .force = .{ .help = "Replace files modified since termancy tui add wrote them" },
    .prune = .{ .help = "Remove files a component no longer has, unless edited" },
    .project = .{ .help = "The project directory" },
} }}), .{ .fields = .{
    .project = .{ .short = 'C', .value_name = "path" },
} });

pub const command = cli.command(.{
    .name = "add",
    .summary = "Copy components into the project",
    .description =
    \\Copy each component, and every component it requires, into the directory tui.zon
    \\names, and record each file's SHA-256 in tui.zon. One line per file:
    \\
    \\  created    the file was missing
    \\  updated    the file was as termancy tui add last wrote it, and the registry has changed
    \\  unchanged  the file is already the registry's version
    \\  skipped (modified; use --force)
    \\             the file was edited; termancy tui diff <component> shows how
    \\  retired (no longer part of <component>; use --prune)
    \\             a file an earlier version had; --prune removes it
    \\  removed    with --prune, a retired file as termancy tui add wrote it
    \\  kept (retired, modified)
    \\             with --prune, a retired file that was edited, left alone
    \\
    \\Exits 1 when a file was skipped. --force replaces edited files too.
    \\
    \\With no components named, at a terminal, choose them from a list: space chooses,
    \\enter adds, esc cancels. Elsewhere, name at least one.
    ,
    .group = group,
    .flags = add_flags,
    .dry_run = true,
    .args = .{ .max = null, .usage = "<component>..." },
    .examples =
    \\termancy tui add
    \\termancy tui add select
    \\termancy tui add form tabs --dry-run
    \\termancy tui add select --force -C demo
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: AddFlags) !void {
    // `tui.zon` marks the project, as for `diff` and `list`: build.zig may be further up.
    var ws: Workspace = try .open(ctx, flags.project, false);
    defer ws.close(ctx.io);
    var m = try ws.loadManifest(ctx) orelse return ctx.fail("{s}{s}: not found (run termancy " ++
        "tui init first)", .{ ws.prefix, manifest.file_name });
    ws.manifest_before = try ws.loadManifest(ctx);
    const components = try workspace.components(ctx);
    const wanted = if (ctx.args.len > 0) ctx.args else try ask(ctx, components);
    const order = try resolve(ctx, components, wanted);

    var report: std.Io.Writer.Allocating = .init(ctx.arena);
    var skipped: std.ArrayList([]const u8) = .empty;
    var removals: std.ArrayList([]const u8) = .empty;
    {
        // A line per component when there are several. Planning one takes no time worth
        // animating, and a failure's message must not land on a line redrawn in place.
        const list = try ctx.arena.alloc(live.Steps.Step, if (order.len > 1) order.len else 0);
        for (list, order[0..list.len]) |*step, component| step.* = .{ .name = component.name };
        var steps: live.Steps = .{ .items = list };
        const items = [_]live.Item{.{ .steps = &steps }};
        var display = ctx.live(&items);
        display.animate = false;
        for (order, 0..) |component, i| {
            const edited = try addComponent(ctx, &ws, &m, component, flags.force, &report.writer);
            if (edited) try skipped.append(ctx.arena, component.name);
            try retire(ctx, &ws, &m, component, flags.prune, &removals, &report.writer);
            if (list.len == 0) continue;
            list[i].state = if (edited) .failed else .done;
            try display.draw(.now(ctx.io, .awake));
        }
    }
    try ws.put(manifest.file_name, try manifest.render(ctx.arena, m));
    if (!ctx.dry_run) {
        try ws.commit(ctx);
        for (removals.items) |path| ws.dir.deleteFile(ctx.io, path) catch |err| {
            return ctx.fail("{s}: cannot remove: {s}", .{ try ws.show(ctx.arena, path), @errorName(err) });
        };
    }
    try ctx.out.writeAll(report.written());
    if (ctx.dry_run and !ctx.quiet) try ctx.err.writeAll("termancy: dry run: nothing was written\n");
    if (skipped.items.len > 0) {
        const names = try std.mem.join(ctx.arena, ", ", skipped.items);
        return ctx.fail("edited files were left alone ({s}); review them with termancy tui diff " ++
            "<component>, then pass --force to replace them", .{names});
    }
}

/// The names of the components chosen at the terminal. Without one to ask at, the usage
/// error a missing argument gets; esc cancels with status 1 and Ctrl-C with 130, as
/// `termancy ui choose` does.
fn ask(ctx: *cli.Context, components: []const catalog.Component) ![]const []const u8 {
    if (!ctx.interactive) {
        var words: std.ArrayList([]const u8) = .empty;
        for (ctx.path) |c| try words.append(ctx.arena, c.name);
        return ctx.usageError("\"{s}\" requires at least 1 argument, received 0", .{
            try std.mem.join(ctx.arena, " ", words.items),
        });
    }
    const items = try ctx.arena.alloc([]const u8, components.len);
    for (components, items) |component, *item| {
        item.* = try std.fmt.allocPrint(ctx.arena, "{s}  {s}", .{
            component.name, component.summary,
        });
    }
    var chosen: std.ArrayList([]const u8) = .empty;
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const indexes = try session.choose(header, items, items.len) orelse
            return error.CommandFailed;
        for (indexes) |i| try chosen.append(ctx.arena, components[i].name);
    } else {
        var model = try picker(ctx.gpa, items);
        defer model.deinit();
        const interrupted = try term.run(ctx, MultiSelect, &model, term.inline_options);
        if (interrupted) return term.exitInterrupted(ctx);
        if (model.status != .submitted) return error.CommandFailed;
        for (components, 0..) |component, i| {
            if (model.isChosen(i)) try chosen.append(ctx.arena, component.name);
        }
    }
    return chosen.items;
}

const header = "Components to add";

/// The multi-select `ask` shows: every component, none chosen.
fn picker(gpa: std.mem.Allocator, items: []const []const u8) !MultiSelect {
    var model: MultiSelect = try .init(gpa, .{ .items = items, .height = 12 });
    model.header = header;
    return model;
}

/// The components named on the command line and everything they require.
fn resolve(
    ctx: *cli.Context,
    components: []const catalog.Component,
    names: []const []const u8,
) ![]const *const catalog.Component {
    var culprit: []const u8 = "";
    return catalog.resolve(ctx.arena, components, names, &culprit) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownComponent => ctx.usageError("unknown component \"{s}\" (termancy tui list " ++
            "lists them)", .{culprit}),
        error.DependencyCycle => ctx.fail("the built-in registry is invalid: {s} requires " ++
            "itself", .{culprit}),
    };
}

/// Reports the files `m` records for `component` that its registry version no longer has,
/// and with `prune`, plans removing those not edited since they were written. A retired
/// file that is gone, or removed, leaves the record; the others stay recorded.
fn retire(
    ctx: *cli.Context,
    ws: *Workspace,
    m: *manifest.Manifest,
    component: *const catalog.Component,
    prune: bool,
    removals: *std.ArrayList([]const u8),
    report: *std.Io.Writer,
) !void {
    const old = (ws.manifest_before orelse return).components.get(component.name) orelse return;
    var record = m.components.get(component.name).?;
    var it = old.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const current = for (component.files) |file| {
            if (std.mem.eql(u8, file, name)) break true;
        } else false;
        if (current) continue;
        const path = try manifest.filePath(ctx.arena, m.*, name);
        const disk = try ws.read(ctx, path) orelse continue; // Gone already: forget it.
        const untouched = std.mem.eql(u8, &manifest.hash(disk), entry.value_ptr);
        if (prune and untouched) {
            try removals.append(ctx.arena, path);
            try report.print("removed {s}\n", .{try ws.show(ctx.arena, path)});
            continue;
        }
        try record.put(ctx.arena, name, entry.value_ptr.*);
        if (prune) {
            try report.print("kept (retired, modified) {s}\n", .{try ws.show(ctx.arena, path)});
        } else {
            try report.print("retired (no longer part of {s}; use --prune) {s}\n", .{
                component.name, try ws.show(ctx.arena, path),
            });
        }
    }
    try m.components.put(ctx.arena, component.name, record);
}

/// Plans one component's files and its record in `m`, and reports each file. Returns
/// whether a file was skipped.
fn addComponent(
    ctx: *cli.Context,
    ws: *Workspace,
    m: *manifest.Manifest,
    component: *const catalog.Component,
    force: bool,
    report: *std.Io.Writer,
) !bool {
    var record: manifest.Files = .empty;
    var any_skipped = false;
    for (component.files) |name| {
        const registry = try workspace.source(ctx, name);
        const path = try manifest.filePath(ctx.arena, m.*, name);
        const recorded = m.recorded(component.name, name);
        const action = status.decide(try ws.read(ctx, path), recorded, registry, force);
        switch (action) {
            .create, .update => try ws.put(path, registry),
            .unchanged => {},
            .skip => any_skipped = true,
        }
        if (action != .skip) {
            try record.put(ctx.arena, name, manifest.hash(registry));
        } else if (recorded) |hash| {
            try record.put(ctx.arena, name, hash);
        }
        try report.print("{s} {s}\n", .{ action.verb(), try ws.show(ctx.arena, path) });
    }
    try m.components.put(ctx.arena, component.name, record);
    return any_skipped;
}

const testing = std.testing;

test "the picker offers every component and returns those chosen" {
    const items = [_][]const u8{ "select  One of a list", "tabs  Tabs", "form  Fields" };
    var d: tui.testing.Driver(MultiSelect) = try .init(
        testing.allocator,
        try picker(testing.allocator, &items),
        .{},
    );
    defer d.deinit();
    try d.press("space");
    try d.press("down");
    try d.press("down");
    try d.press("space");
    try d.press("enter");
    try testing.expect(d.model().status == .submitted);
    try testing.expect(d.model().isChosen(0));
    try testing.expect(!d.model().isChosen(1));
    try testing.expect(d.model().isChosen(2));
}
