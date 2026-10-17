//! `snek tui init`: prepares a project for components: `tui.zon` at its root, the
//! component directory, and the `tui` module in `build.zig`.

const std = @import("std");
const cli = @import("cli");
const project = @import("../cli/project.zig");
const cli_init = @import("../cli/init.zig");
const manifest = @import("project/manifest.zig");
const Workspace = @import("project/workspace.zig").Workspace;

const InitFlags = struct {
    dir: []const u8 = manifest.default_dir,
    project: []const u8 = ".",
    wire: bool = false,
    dependency: ?[]const u8 = null,
    pub const meta = .{
        .dir = .{
            .help = "Where components go, relative to the project",
            .value_name = "path",
        },
        .project = .{ .short = 'C', .help = "The project directory", .value_name = "path" },
        .wire = .{ .help = "Add the tui module to a build.zig made by snek cli init" },
        .dependency = .{
            .help = "Add snek as a dependency (zig fetch --save=snek) and wire build.zig",
            .value_name = "url",
        },
    };
};

pub const command = cli.command(.{
    .name = "init",
    .summary = "Prepare a Zig project for components",
    .description =
    \\Write tui.zon at the project root (a directory holding build.zig and build.zig.zon)
    \\and create the component directory. tui.zon records where components go and the
    \\SHA-256 of every file snek tui add writes:
    \\
    \\  .{ .dir = "src/ui", .components = .{} }
    \\
    \\Components import the tui module of snek. When build.zig does not import it yet,
    \\init prints the line to add; for a build.zig made by snek cli init, --wire adds it.
    \\For any other project, --dependency <url> adds snek to build.zig.zon with zig fetch
    \\(a local path works too) and, for a build.zig shaped like zig init's, adds the
    \\dependency and the import before b.installArtifact(exe). Run again on an initialized
    \\project, init changes only what is missing.
    ,
    .group = group,
    .flags = InitFlags,
    .examples =
    \\snek tui init
    \\snek tui init --dir src/components -C demo --wire
    \\snek tui init --dependency git+https://github.com/93ams/snek
    ,
    .run = run,
});

pub const group = "Component Commands";

/// The import a `snek cli init` build.zig gets, inserted before its `cfg` import.
pub const wired_import = ".{ .name = \"tui\", .module = snek.module(\"tui\") },";
const cfg_import = ".{ .name = \"cfg\", .module = snek.module(\"cfg\") },";

fn run(ctx: *cli.Context, flags: InitFlags) !void {
    const dir = std.mem.trimEnd(u8, flags.dir, "/");
    if (!project.isSafeRelative(dir)) {
        return ctx.usageError("--dir must be a relative path inside the project, without . " ++
            "or .. parts: \"{s}\"", .{flags.dir});
    }
    var ws: Workspace = try .open(ctx, flags.project, true);
    defer ws.close(ctx.io);
    const component_dir = try planManifest(ctx, &ws, dir);
    if (flags.dependency) |url| {
        const zon = (try ws.read(ctx, "build.zig.zon")).?;
        if (std.mem.indexOf(u8, zon, ".snek = .{") == null) {
            try cli_init.fetch(ctx, flags.project, url);
        }
    }
    var build = (try ws.read(ctx, "build.zig")).?;
    if (flags.dependency != null and wiring(build) == .unknown) {
        build = wireGeneric(ctx.arena, build) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unrecognized => return ctx.fail("{s}build.zig: not shaped like zig init's " ++
                "(no b.installArtifact(exe)); add the module yourself:\n{s}", .{
                ws.prefix, generic_hint,
            }),
        };
        try ws.put("build.zig", build);
    }
    const state = wiring(build);
    if (flags.wire) switch (state) {
        .wired => {},
        .wirable => try ws.put("build.zig", try wire(ctx.arena, build)),
        .unknown => return ctx.fail("{s}build.zig: --wire needs a build.zig made by snek cli " ++
            "init (with the line {s}); add the module yourself:\n{s}", .{
            ws.prefix, cfg_import, generic_hint,
        }),
    };
    try ws.commit(ctx);
    for (ws.plan.files.items) |file| {
        if (!file.changed) continue;
        try ctx.out.print("{s} {s}{s}\n", .{ verb(file.existed), ws.prefix, file.path });
    }
    try makeDir(ctx, &ws, component_dir);
    if (flags.wire or flags.dependency != null) return;
    switch (state) {
        .wired => {},
        .wirable => try ctx.out.print("next: pass --wire, or add this import to the root " ++
            "module in {s}build.zig:\n    {s}\n", .{ ws.prefix, wired_import }),
        .unknown => try ctx.out.print("next: import the tui module in {s}build.zig:\n{s}\n", .{
            ws.prefix, generic_hint,
        }),
    }
}

const generic_hint =
    \\    root_module.addImport("tui", snek.module("tui"));
    \\where snek is b.dependency("snek", .{ .target = target, .optimize = optimize })
;

fn verb(existed: bool) []const u8 {
    return if (existed) "updated" else "created";
}

/// Plans `tui.zon` when it is missing, and returns the component directory it names.
fn planManifest(ctx: *cli.Context, ws: *Workspace, dir: []const u8) ![]const u8 {
    if (try ws.loadManifest(ctx)) |existing| {
        if (ctx.isSet("dir") and !std.mem.eql(u8, existing.dir, dir)) {
            return ctx.fail("{s}{s}: components already go to {s}; edit its .dir to move " ++
                "them", .{ ws.prefix, manifest.file_name, existing.dir });
        }
        return existing.dir;
    }
    try ws.put(manifest.file_name, try manifest.render(ctx.arena, .{ .dir = dir }));
    return dir;
}

/// Creates the component directory when it is missing.
fn makeDir(ctx: *cli.Context, ws: *Workspace, dir: []const u8) !void {
    project.checkInside(ctx.io, ws.dir, dir) catch {
        return ctx.fail("{s}{s}: outside the project", .{ ws.prefix, dir });
    };
    ws.dir.access(ctx.io, dir, .{}) catch {
        ws.dir.createDirPath(ctx.io, dir) catch |err| {
            return ctx.fail("{s}{s}: cannot create: {s}", .{ ws.prefix, dir, @errorName(err) });
        };
        try ctx.out.print("created {s}{s}/\n", .{ ws.prefix, dir });
    };
}

pub const Wiring = enum {
    /// `build.zig` already uses the `tui` module.
    wired,
    /// Made by `snek cli init`: `--wire` can add the import.
    wirable,
    /// Anything else: the user adds the import.
    unknown,
};

/// `build`, a `build.zig` made by `zig init`, with the `snek` dependency declared after the
/// optimize option and the `tui` import added before `b.installArtifact(exe);`.
pub fn wireGeneric(
    arena: std.mem.Allocator,
    build: []const u8,
) (std.mem.Allocator.Error || error{Unrecognized})![]const u8 {
    const install = "b.installArtifact(exe);";
    const optimize = "const optimize = b.standardOptimizeOption(.{});";
    const at_install = std.mem.indexOf(u8, build, install) orelse return error.Unrecognized;
    var out: std.ArrayList(u8) = .empty;
    const has_dependency = std.mem.indexOf(u8, build, "b.dependency(\"snek\"") != null;
    const at_optimize = std.mem.indexOf(u8, build, optimize);
    if (!has_dependency and at_optimize == null) return error.Unrecognized;
    const indent = lineIndent(build, at_install);
    if (!has_dependency) {
        const end = at_optimize.? + optimize.len;
        try out.appendSlice(arena, build[0..end]);
        try out.print(arena, "\n{s}const snek = b.dependency(\"snek\", " ++
            ".{{ .target = target, .optimize = optimize }});", .{lineIndent(build, at_optimize.?)});
        try out.appendSlice(arena, build[end..at_install]);
    } else {
        try out.appendSlice(arena, build[0..at_install]);
    }
    const import = "exe.root_module.addImport(\"tui\", snek.module(\"tui\"));";
    try out.print(arena, "{s}\n{s}", .{ import, indent });
    try out.appendSlice(arena, build[at_install..]);
    return out.items;
}

/// The spaces before `offset` on its line.
fn lineIndent(text: []const u8, offset: usize) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |n| n + 1 else 0;
    return text[start..offset];
}

pub fn wiring(build: []const u8) Wiring {
    if (std.mem.indexOf(u8, build, ".module(\"tui\")") != null) return .wired;
    var lines = std.mem.splitScalar(u8, build, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), cfg_import)) count += 1;
    }
    return if (count == 1) .wirable else .unknown;
}

/// `build` with the `tui` import inserted before the `cfg` one. `build` must be `.wirable`.
pub fn wire(arena: std.mem.Allocator, build: []const u8) std.mem.Allocator.Error![]const u8 {
    return project.insertAtMarker(arena, build, cfg_import, wired_import) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MarkerNotFound, error.MarkerRepeated, error.AlreadyPresent => unreachable,
    };
}

const testing = std.testing;
const templates = @import("../cli/templates.zig");

test "wiring a build.zig made by snek cli init" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const build = try templates.render(arena, templates.buildZig, .{"demo"});
    try testing.expectEqual(.wirable, wiring(build));
    const wired = try wire(arena, build);
    try testing.expectEqual(.wired, wiring(wired));
    try testing.expect(std.mem.indexOf(u8, wired,
        \\            .{ .name = "cli", .module = snek.module("cli") },
        \\            .{ .name = "tui", .module = snek.module("tui") },
        \\            .{ .name = "cfg", .module = snek.module("cfg") },
    ) != null);
    try testing.expectEqual(.unknown, wiring("const std = @import(\"std\");\n"));
}

test "wiring a build.zig made by zig init" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const build =
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const exe = b.addExecutable(.{ .name = "x", .root_module = b.createModule(.{}) });
        \\    b.installArtifact(exe);
        \\}
        \\
    ;
    try testing.expectEqual(.unknown, wiring(build));
    const wired = try wireGeneric(arena, build);
    try testing.expectEqualStrings(
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const snek = b.dependency("snek", .{ .target = target, .optimize = optimize });
        \\    const exe = b.addExecutable(.{ .name = "x", .root_module = b.createModule(.{}) });
        \\    exe.root_module.addImport("tui", snek.module("tui"));
        \\    b.installArtifact(exe);
        \\}
        \\
    , wired);
    try testing.expectEqual(.wired, wiring(wired));
    try testing.expectError(error.Unrecognized, wireGeneric(arena, "const x = 1;\n"));
}
