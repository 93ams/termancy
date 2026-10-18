//! End-to-end tests for the `snek tui` registry commands: `snek cli init` makes a project,
//! `snek tui init --wire`, `add`, `list`, and `diff` work on it, and then the project builds
//! with `zig build` and the copied components pass their tests, compiled against the `tui`
//! module the project now imports.

const std = @import("std");

/// A run of `snek`, or of `zig`, in the chain's directory.
const Step = struct {
    /// Run `zig` with these arguments instead of `snek` (see `zigRun`).
    zig: bool = false,
    /// The working directory, relative to the chain's directory.
    cwd: []const u8 = ".",
    args: []const []const u8,
    /// Appends `--module-path=<this checkout>`.
    module_path: bool = false,
    /// Null leaves the stream unchecked.
    stdout: ?[]const u8 = "",
    stderr: ?[]const u8 = "",
    status: u8 = 0,
};

const demo_created =
    \\created demo/build.zig
    \\created demo/build.zig.zon
    \\created demo/src/main.zig
    \\created demo/src/cmd/hello.zig
    \\created demo/src/settings.zig
    \\created demo/README.md
    \\created demo/.gitignore
    \\
++ "next: cd demo" ++ then ++ "zig build run -- --help\n";

/// How `snek cli init` joins the commands of its "next:" hint.
const then = if (@import("builtin").os.tag == .windows) "\n      " else " && ";

/// The files `select` brings, `list` (which it requires) first.
const select_files = [_][]const u8{ "demo/src/ui/list.zig", "demo/src/ui/select.zig" };

const steps = [_]Step{
    .{ .args = &.{ "cli", "init", "demo" }, .module_path = true, .stdout = demo_created },
    .{
        .args = &.{ "tui", "add", "-C", "demo", "select" },
        .stderr = "snek: demo/tui.zon: not found (run snek tui init first)\n",
        .status = 1,
    },
    .{
        // A subdirectory, as in a monorepo: tui.zon goes there, the wiring to the build.zig
        // above it.
        .args = &.{ "tui", "init", "-C", "demo/src", "--dir", "widgets" },
        .stdout = "created demo/src/tui.zon\ncreated demo/src/widgets/\n" ++
            "next: pass --wire, or add this import to the root module in demo/build.zig:\n" ++
            "    .{ .name = \"tui\", .module = snek.module(\"tui\") },\n",
    },
    .{
        .args = &.{ "tui", "init", "-C", "demo", "--wire" },
        .stdout = "updated demo/build.zig\ncreated demo/tui.zon\ncreated demo/src/ui/\n",
    },
    .{ .args = &.{ "tui", "init", "-C", "demo", "--wire" } },
    .{
        .args = &.{ "tui", "add", "-C", "demo", "select" },
        .stdout = "created " ++ select_files[0] ++ "\ncreated " ++ select_files[1] ++ "\n",
        // A step per component on standard error: `select` requires `list`.
        .stderr = "✓ list\n✓ select\n",
    },
    .{
        .args = &.{ "tui", "add", "-C", "demo", "select", "--dry-run", "-q" },
        .stdout = "unchanged " ++ select_files[0] ++ "\nunchanged " ++ select_files[1] ++ "\n",
    },
    .{ .args = &.{ "tui", "diff", "-C", "demo", "select" } },
    .{
        .args = &.{ "tui", "diff", "-C", "demo", "confirm" },
        .stderr = "snek: confirm: not installed (snek tui add confirm installs it)\n" ++
            "Run 'snek tui diff --help' for usage.\n",
        .status = 2,
    },
    .{
        .args = &.{ "tui", "add", "-C", "demo", "nope" },
        .stderr = "snek: unknown component \"nope\" (snek tui list lists them)\n" ++
            "Run 'snek tui add --help' for usage.\n",
        .status = 2,
    },
    .{
        // Without a terminal to choose at, no names is a usage error.
        .args = &.{ "tui", "add", "-C", "demo" },
        .stderr = "snek: \"snek tui add\" requires at least 1 argument, received 0\n" ++
            "Run 'snek tui add --help' for usage.\n",
        .status = 2,
    },
    .{
        // `add` needs only tui.zon: build.zig is further up.
        .args = &.{ "tui", "add", "-C", "demo/src", "select" },
        .stdout = "created demo/src/widgets/list.zig\ncreated demo/src/widgets/select.zig\n",
        .stderr = "✓ list\n✓ select\n",
    },
    // Wired now: no hint.
    .{ .args = &.{ "tui", "init", "-C", "demo/src" } },
    .{
        // One component: no step lines.
        .args = &.{ "tui", "add", "-C", "demo/src", "list" },
        .stdout = "unchanged demo/src/widgets/list.zig\n",
    },
    .{ .zig = true, .cwd = "demo", .args = &.{"build"}, .stderr = null },
};

/// `snek tui list -o json` after the steps, in part: the shape and the installed component.
const list_json = [_][]const u8{
    "{\n  \"version\": 1,\n  \"manifest\": true,\n  \"components\": [\n",
    \\    {
    \\      "name": "select",
    \\      "summary": "Choose one item from a list",
    \\      "requires": [
    \\        "list"
    \\      ],
    \\      "files": [
    \\        "select.zig"
    \\      ],
    \\      "installed": true,
    \\      "modified": false,
    \\      "outdated": false
    \\    }
    ,
};

pub fn addCases(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    // The chain's directory is the output directory of a `snek version` run. No step has
    // side effects, so the chain is cached and runs again, in a new directory, only when
    // snek or this file changes (the build system never empties a directory it reuses, so
    // a chain that failed part way must not get the same one back).
    const seed = b.addRunArtifact(exe);
    seed.setName("e2e: tui registry: directory");
    seed.clearEnvironment();
    seed.addArg("version");
    seed.addFileInput(b.path("test/e2e_tui_registry.zig"));
    const dir = seed.captureStdOut(.{ .basename = "tui-registry.txt" }).dirname();

    var previous = &seed.step;
    for (steps, 1..) |s, index| {
        const run = if (s.zig) zigRun(b, s.args) else snekRun(b, exe, s);
        run.setName(b.fmt("e2e: tui registry ({d})", .{index}));
        run.setCwd(dir.path(b, s.cwd));
        if (s.stdout) |bytes| run.expectStdOutEqual(bytes);
        if (s.stderr) |bytes| run.expectStdErrEqual(bytes);
        run.expectExitCode(s.status);
        run.step.dependOn(previous);
        previous = &run.step;
    }

    const list = snekRun(b, exe, .{ .args = &.{ "tui", "list", "-C", "demo", "-o", "json" } });
    list.setName("e2e: tui registry: list -o json");
    list.setCwd(dir);
    list.step.dependOn(previous);
    const listing = list.captureStdOut(.{ .basename = "list.json" });
    const check = b.addCheckFile(listing, .{ .expected_matches = &list_json });
    check.setName("e2e: tui registry: list -o json shape");
    step.dependOn(&check.step);

    // Each copied file passes its tests, compiled as the project would: against `tui` (and
    // the `term` under it).
    for (select_files) |file| {
        const tests = zigRun(b, &.{ "test", "--dep", "tui" });
        tests.setName(b.fmt("e2e: tui registry: zig test {s}", .{file}));
        tests.addPrefixedFileArg("-Mroot=", dir.path(b, file));
        tests.addArgs(&.{ "--dep", "term" });
        tests.addPrefixedFileArg("-Mtui=", b.path("src/tui/root.zig"));
        tests.addPrefixedFileArg("-Mterm=", b.path("src/term/root.zig"));
        tests.expectExitCode(0);
        // The test runner reports on standard error; only the status matters.
        _ = tests.captureStdErr(.{});
        tests.step.dependOn(previous);
        step.dependOn(&tests.step);
    }
    step.dependOn(previous);
}

fn snekRun(b: *std.Build, exe: *std.Build.Step.Compile, s: Step) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.clearEnvironment();
    run.addArgs(s.args);
    if (s.module_path) run.addPrefixedDirectoryArg("--module-path=", b.path("."));
    return run;
}

/// `zig <args[0]> --cache-dir <under the build's cache> <args[1..]>`. The cache stays off
/// the project's file system and is reused between builds. `zig` keeps the environment: it
/// finds its global cache through it.
fn zigRun(b: *std.Build, args: []const []const u8) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, "zig");
    run.addArg(b.graph.zig_exe);
    run.addArg(args[0]);
    run.addArg("--cache-dir");
    run.addDirectoryArg(.{ .relative = .{ .base = .local_cache, .sub_path = "e2e-tui-project" } });
    run.addArgs(args[1..]);
    return run;
}
