//! `snek tui`: terminal user interfaces, built on the `tui` library: gum-style widgets for
//! shell scripts, and a shadcn-style registry of components that are copied into your
//! project as source you own (`init`, `add`, `list`, `diff`).

const std = @import("std");
const cli = @import("cli");
const gum = @import("gum.zig");
const init = @import("init.zig");
const add = @import("add.zig");
const list = @import("list.zig");
const diff = @import("diff.zig");
const demo = @import("demo.zig");
const md = @import("md.zig");
const image = @import("image.zig");
const serve = @import("serve.zig");

pub const command = cli.command(.{
    .name = "tui",
    .summary = "Terminal widgets for scripts, and components to copy into your project",
    .subcommands = gum.commands ++ .{
        init.command,  add.command,   list.command, diff.command, demo.command, md.command,
        image.command, serve.command,
    },
});

test {
    std.testing.refAllDecls(gum);
    std.testing.refAllDecls(init);
    std.testing.refAllDecls(add);
    std.testing.refAllDecls(list);
    std.testing.refAllDecls(diff);
    std.testing.refAllDecls(demo);
    std.testing.refAllDecls(md);
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(serve);
    std.testing.refAllDecls(@import("project/catalog.zig"));
    std.testing.refAllDecls(@import("project/manifest.zig"));
    std.testing.refAllDecls(@import("project/status.zig"));
    std.testing.refAllDecls(@import("project/workspace.zig"));
}

const testing = std.testing;

/// Runs snek with `args`; the caller frees the result.
fn snek(args: []const []const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{});
}

fn expectRun(args: []const []const u8, status: u8, out: []const u8, err: []const u8) !void {
    const r = try snek(args);
    defer r.deinit();
    try r.expect(status, out, err);
}

test "init, add, edit, add again, force, diff" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = ".zig-cache/tmp/" ++ tmp.sub_path;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig.zon", .data = ".{}\n" });

    try expectRun(&.{ "tui", "add", "-C", dir, "select" }, 1, "", "snek: " ++ dir ++
        "/tui.zon: not found (run snek tui init first)\n");
    try expectRun(&.{ "tui", "init", "-C", dir }, 0, "created " ++ dir ++ "/tui.zon\n" ++
        "created " ++ dir ++ "/src/ui/\n" ++
        "next: import the tui module in " ++ dir ++ "/build.zig:\n" ++
        "    root_module.addImport(\"tui\", snek.module(\"tui\"));\n" ++
        "where snek is b.dependency(\"snek\", .{ .target = target, .optimize = optimize })\n", "");
    try expectRun(&.{ "tui", "diff", "-C", dir, "select" }, 2, "", "snek: select: not " ++
        "installed (snek tui add select installs it)\nRun 'snek tui diff --help' for usage.\n");

    // `select` requires `list`, which comes first.
    const added = try snek(&.{ "tui", "add", "-C", dir, "select" });
    defer added.deinit();
    try testing.expectEqualStrings("✓ list\n✓ select\n", added.err);
    try testing.expectEqual(0, added.status);
    const list_line = "created " ++ dir ++ "/src/ui/list.zig\n";
    const select_line = "created " ++ dir ++ "/src/ui/select.zig\n";
    const list_at = std.mem.indexOf(u8, added.out, list_line).?;
    try testing.expect(list_at < std.mem.indexOf(u8, added.out, select_line).?);

    var buffer: [1 << 16]u8 = undefined;
    const manifest_text = try tmp.dir.readFile(testing.io, "tui.zon", &buffer);
    try testing.expect(std.mem.indexOf(u8, manifest_text, ".select = .{") != null);
    try testing.expect(std.mem.indexOf(u8, manifest_text, ".list = .{") != null);
    try expectRun(&.{ "tui", "diff", "-C", dir, "select" }, 0, "", "");

    // An edit: kept by add, shown by diff, replaced with --force.
    const original = try testing.allocator.dupe(u8, try tmp.dir.readFile(
        testing.io,
        "src/ui/select.zig",
        &buffer,
    ));
    defer testing.allocator.free(original);
    const edited = try std.mem.concat(testing.allocator, u8, &.{ "// mine\n", original });
    defer testing.allocator.free(edited);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/ui/select.zig", .data = edited });

    const again = try snek(&.{ "tui", "add", "-C", dir, "select" });
    defer again.deinit();
    try testing.expectEqual(1, again.status);
    try testing.expect(std.mem.indexOf(u8, again.out, "unchanged " ++ dir ++
        "/src/ui/list.zig\n") != null);
    try testing.expect(std.mem.indexOf(u8, again.out, "skipped (modified; use --force) " ++ dir ++
        "/src/ui/select.zig\n") != null);
    try testing.expectEqualStrings(edited, try tmp.dir.readFile(
        testing.io,
        "src/ui/select.zig",
        &buffer,
    ));

    const changed = try snek(&.{ "tui", "diff", "-C", dir, "select" });
    defer changed.deinit();
    try testing.expectEqual(1, changed.status);
    try testing.expect(std.mem.startsWith(u8, changed.out, "--- " ++ dir ++
        "/src/ui/select.zig\n+++ registry/select.zig\n@@ -1,4 +1,3 @@\n-// mine\n"));

    const listed = try snek(&.{ "tui", "list", "-C", dir, "-o", "json" });
    defer listed.deinit();
    try testing.expectEqual(0, listed.status);
    try testing.expect(std.mem.indexOf(u8, listed.out, "\"manifest\": true") != null);

    const dry = try snek(&.{ "tui", "add", "-C", dir, "select", "--force", "--dry-run" });
    defer dry.deinit();
    try testing.expectEqual(0, dry.status);
    try testing.expect(std.mem.indexOf(u8, dry.out, "updated " ++ dir ++
        "/src/ui/select.zig\n") != null);
    try expectRun(&.{ "tui", "diff", "-C", dir, "select" }, 1, changed.out, "");

    const forced = try snek(&.{ "tui", "add", "-C", dir, "select", "--force" });
    defer forced.deinit();
    try testing.expectEqual(0, forced.status);
    try expectRun(&.{ "tui", "diff", "-C", dir, "select" }, 0, "", "");
    try testing.expectEqualStrings(original, try tmp.dir.readFile(
        testing.io,
        "src/ui/select.zig",
        &buffer,
    ));
    try expectRun(&.{ "tui", "add", "-C", dir, "nope" }, 2, "", "snek: unknown component " ++
        "\"nope\" (snek tui list lists them)\nRun 'snek tui add --help' for usage.\n");
}

test "the tui.zon directory cannot lead out of the project" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = ".zig-cache/tmp/" ++ tmp.sub_path;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig.zon", .data = ".{}\n" });
    try expectRun(&.{ "tui", "init", "-C", dir, "--dir", "../out" }, 2, "", "snek: --dir must " ++
        "be a relative path inside the project, without . or .. parts: \"../out\"\n" ++
        "Run 'snek tui init --help' for usage.\n");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "tui.zon",
        .data = ".{ .dir = \"../out\", .components = .{} }\n",
    });
    try expectRun(&.{ "tui", "add", "-C", dir, "select" }, 1, "", "snek: " ++ dir ++
        "/tui.zon: invalid: InvalidManifest\n");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "tui.zon",
        .data = ".{ .dir = \"escape\", .components = .{} }\n",
    });
    tmp.dir.symLink(testing.io, "/tmp", "escape", .{ .is_directory = true }) catch return;
    try expectRun(&.{ "tui", "add", "-C", dir, "select" }, 1, "", "snek: " ++ dir ++
        "/escape/list.zig: outside the project\n");
}

test "files a component no longer has are reported, and pruned when untouched" {
    const manifest = @import("project/manifest.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = ".zig-cache/tmp/" ++ tmp.sub_path;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig.zon", .data = ".{}\n" });
    const inited = try snek(&.{ "tui", "init", "-C", dir });
    defer inited.deinit();
    const added = try snek(&.{ "tui", "add", "-C", dir, "select" });
    defer added.deinit();
    try testing.expectEqual(0, added.status);

    // As if an earlier `select` had a file `old.zig` that the registry has since dropped.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [1 << 16]u8 = undefined;
    var m = try manifest.parse(arena, try tmp.dir.readFile(testing.io, "tui.zon", &buffer));
    const old = "pub const old = 1;\n";
    try m.components.getPtr("select").?.put(arena, "old.zig", manifest.hash(old));
    const rendered = try manifest.render(arena, m);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tui.zon", .data = rendered });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/ui/old.zig", .data = old });

    const reported = try snek(&.{ "tui", "add", "-C", dir, "select" });
    defer reported.deinit();
    try testing.expectEqual(0, reported.status);
    try testing.expect(std.mem.indexOf(u8, reported.out, "retired (no longer part of select; " ++
        "use --prune) " ++ dir ++ "/src/ui/old.zig\n") != null);
    // Still recorded, so a later --prune finds it.
    const kept = try tmp.dir.readFile(testing.io, "tui.zon", &buffer);
    try testing.expect(std.mem.indexOf(u8, kept, "old.zig") != null);

    const pruned = try snek(&.{ "tui", "add", "-C", dir, "select", "--prune" });
    defer pruned.deinit();
    const removed = "removed " ++ dir ++ "/src/ui/old.zig\n";
    try testing.expect(std.mem.indexOf(u8, pruned.out, removed) != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "src/ui/old.zig", .{}));
    const forgotten = try tmp.dir.readFile(testing.io, "tui.zon", &buffer);
    try testing.expect(std.mem.indexOf(u8, forgotten, "old.zig") == null);
}
