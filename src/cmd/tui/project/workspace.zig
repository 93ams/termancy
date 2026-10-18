//! A project as the `termancy tui` commands see it: a directory, the `tui.zon` at its root, and
//! the registry compiled into termancy. Every read and write goes through a `project.Plan`, so
//! no path leaves the project directory.

const std = @import("std");
const cli = @import("cli");
const sys = @import("sys");
const project = @import("../../cli/project.zig");
const catalog = @import("catalog.zig");
const manifest = @import("manifest.zig");
const registry = @import("../registry/root.zig");

/// The registry's files, as the catalog reads them.
pub const files: [registry.files.len]catalog.File = blk: {
    var result: [registry.files.len]catalog.File = undefined;
    for (registry.files, &result) |file, *out| {
        out.* = .{ .name = file.name, .source = file.source };
    }
    break :blk result;
};

/// The registry's components.
pub fn components(ctx: *cli.Context) ![]const catalog.Component {
    return catalog.parse(ctx.arena, registry.manifest) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError, error.InvalidCatalog => ctx.fail("the built-in registry.zon is " ++
            "invalid: {s}", .{@errorName(err)}),
    };
}

/// A registry file's source. Every file the catalog names is embedded; a test checks it.
pub fn source(ctx: *cli.Context, name: []const u8) ![]const u8 {
    return catalog.source(&files, name) orelse
        ctx.fail("the built-in registry has no file {s}", .{name});
}

pub const Workspace = struct {
    dir: std.Io.Dir,
    /// `-C` as given, for messages.
    path: []const u8,
    /// Printed before project paths: empty for `.`, else the path and the separator it
    /// uses (`sys.files.join`'s rule: `\` on Windows for a path written with it).
    prefix: []const u8,
    plan: project.Plan,
    /// The manifest as it was on disk before this command changed it, for `add` to find
    /// files a component has dropped.
    manifest_before: ?manifest.Manifest = null,

    /// Opens the project at `path`. With `zig_project`, it must hold `build.zig` and
    /// `build.zig.zon`.
    pub fn open(ctx: *cli.Context, path: []const u8, zig_project: bool) !Workspace {
        const dir = std.Io.Dir.cwd().openDir(ctx.io, path, .{}) catch |err| {
            return ctx.fail("{s}: cannot open: {s}", .{ path, @errorName(err) });
        };
        var ws: Workspace = .{
            .dir = dir,
            .path = path,
            .prefix = if (std.mem.eql(u8, path, "."))
                ""
            else
                try sys.files.join(ctx.arena, std.mem.trimEnd(u8, path, "/"), ""),
            .plan = .{ .io = ctx.io, .arena = ctx.arena, .root = dir },
        };
        if (!zig_project) return ws;
        for ([_][]const u8{ "build.zig", "build.zig.zon" }) |name| {
            if (try ws.read(ctx, name) == null) {
                ws.close(ctx.io);
                return ctx.fail("{s}: not a Zig project (no {s})", .{ path, name });
            }
        }
        return ws;
    }

    pub fn close(ws: *Workspace, io: std.Io) void {
        ws.dir.close(io);
    }

    /// `sub_path`, a path in the project written with `/`, as messages show it: after
    /// `prefix`, with its separator.
    pub fn show(ws: *const Workspace, arena: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
        if (ws.prefix.len == 0) return sub_path;
        return sys.files.join(arena, ws.prefix, sub_path);
    }

    /// The content of `sub_path`, or null when it does not exist.
    pub fn read(ws: *Workspace, ctx: *cli.Context, sub_path: []const u8) !?[]const u8 {
        const file = ws.plan.get(sub_path) catch |err| return switch (err) {
            error.FileNotFound => null,
            error.OutOfMemory => error.OutOfMemory,
            error.UnsafePath, error.OutsideProject => ctx.fail("{s}{s}: outside the project", .{
                ws.prefix, sub_path,
            }),
            error.ReadFailed => ctx.fail("{s}{s}: cannot read", .{ ws.prefix, sub_path }),
        };
        return file.content;
    }

    /// `tui.zon`, or null when the project has none.
    pub fn loadManifest(ws: *Workspace, ctx: *cli.Context) !?manifest.Manifest {
        const text = try ws.read(ctx, manifest.file_name) orelse return null;
        return manifest.parse(ctx.arena, text) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SyntaxError, error.InvalidManifest => ctx.fail("{s}{s}: invalid: {s}", .{
                ws.prefix, manifest.file_name, @errorName(err),
            }),
        };
    }

    /// Plans `content` for `sub_path`, which `read` has already looked for.
    pub fn put(ws: *Workspace, sub_path: []const u8, content: []const u8) !void {
        for (ws.plan.files.items) |*file| {
            if (!std.mem.eql(u8, file.path, sub_path)) continue;
            if (std.mem.eql(u8, file.content, content)) return;
            file.content = content;
            file.changed = true;
            return;
        }
        try ws.plan.create(sub_path, content);
    }

    /// Writes every planned change: new files exclusively, existing ones atomically.
    pub fn commit(ws: *Workspace, ctx: *cli.Context) !void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        ws.plan.commit(&discard.writer, "") catch |err| {
            return ctx.fail("{s}: cannot write the project: {s}", .{ ws.path, @errorName(err) });
        };
    }
};

const testing = std.testing;

test "the built-in registry names only embedded files and has no cycles" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = try catalog.parse(arena, registry.manifest);
    try testing.expect(all.len > 0);
    var culprit: []const u8 = "";
    for (all) |component| {
        for (component.files) |name| {
            errdefer std.debug.print("{s}: {s} is not embedded\n", .{ component.name, name });
            try testing.expect(catalog.source(&files, name) != null);
        }
        _ = try catalog.resolve(arena, all, &.{component.name}, &culprit);
    }
}
