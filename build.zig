//! Repository build entry point for `snek`.
//!
//! ## What this repository is
//!
//! `snek` is the standalone home of two subsystems that were extracted from the
//! `snek` monorepo (`src/zig/app/cli` and `src/zig/app/cfg`):
//!
//! * `lib/cli`  - the command framework: routing, flag parsing, render, interact.
//! * `lib/cfg`  - the configuration framework: loader, TOML document model,
//!   encrypted config, scalar grammars.
//! * `lib/util` - a vendored subset of the monorepo's `lib/util`, so that this
//!   repository depends on nothing outside itself. See its `root.zig` for why the
//!   copy exists and why it is the closure actually used rather than the whole
//!   library.
//!
//! `app/cfg/lib/ops` is the configuration operations: they import `cfg` and `util`
//! and never `cli`, so a server binary with no `App` still uses config management.
//! They are a folder inside the `app_cfg` module, not a module of their own - a
//! second module would need a second test root and would buy nothing, since the
//! files are only ever reached through `app/cfg/root.zig`'s `ops` surface.
//!
//! The two binaries are `app/cli/main.zig` (installed as `snek`) and
//! `app/cfg/main.zig` (installed as `cfg`).
//!
//! ## One build root, and why that removes a whole class of duplication
//!
//! In the monorepo, `app/cli` and `app/cfg` were separate packages with separate
//! `build.zig` files, and each carried its own copy of `build/targets.zig`. That
//! was forced, not chosen: a build root's module path begins at the directory
//! holding its `build.zig.zon`, and a relative import may not escape it in *any*
//! direction, so `app/cli` could not reach `app/cfg`'s wiring and both had to
//! redeclare the other's modules. `[measured]` in the monorepo the rule produced
//! 17 copies of `targets.zig`.
//!
//! Here both apps sit below **one** build root, so the rule does not apply: there
//! is one `build/targets.zig`, one `build.zig`, and no app declares another app's
//! modules.
//!
//! ## Conventions kept from the monorepo
//!
//! * **`.imports` at construction.** A module is created with its full import
//!   table, so there is no `addImport` tail to keep in sync.
//! * **No per-file test entries.** A test root is a module whose own
//!   `test { std.testing.refAllDecls(@This()); }` reaches every test in its graph,
//!   so adding a test never means editing this file.

const std = @import("std");
const targets = @import("build/targets.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = targets.resolveTarget(b, optimize);

    // -- Shared libraries --
    //
    // Declared in dependency order: `cfg` and `util` first because `cli` imports
    // them.
    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("lib/util/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cfg_mod = b.addModule("cfg", .{
        .root_source_file = b.path("lib/cfg/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The framework's public surface is `root.zig`, not `cli.zig`; `root.zig` is
    // the only module root that reaches `test/cli_test.zig`, and it carries a
    // comptime guard asserting it re-exports every `pub` decl of `cli.zig`.
    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("lib/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cfg", .module = cfg_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // -- App command groups --
    //
    // `app_cfg` imports `cli`: the command group is `Commands(App, Config)`-shaped
    // and its wrappers are `cli.App.Command`s. `util` and `cfg` are named on the
    // import table as well as on `cli` because a file inside a module resolves
    // `@import("x")` against the *importing* module's table, and a table that is a
    // subset of what a deeper file needs fails against the deep file rather than
    // at its declaration. That covers `app/cfg/lib/ops/*.zig` too: they are files
    // of this module, reached by relative import, and they import `cfg` and `util`
    // by name.
    const app_cfg_mod = b.addModule("app_cfg", .{
        .root_source_file = b.path("app/cfg/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "cfg", .module = cfg_mod },
            .{ .name = "util", .module = util_mod },
        },
    });
    const app_cli_mod = b.addModule("app_cli", .{
        .root_source_file = b.path("app/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "app_cfg", .module = app_cfg_mod },
            .{ .name = "util", .module = util_mod },
            .{ .name = "cfg", .module = cfg_mod },
        },
    });

    // -- Binaries --
    //
    // `cfg` names its whole graph because the executable's module compiles
    // `app/cfg/cmd/*.zig` directly when it names their declarations, so it needs
    // the same table rather than a subset.
    const cfg_exe = b.addExecutable(.{
        .name = "cfg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/cfg/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "app_cfg", .module = app_cfg_mod },
                .{ .name = "cfg", .module = cfg_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });
    const cli_exe = b.addExecutable(.{
        .name = "snek",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "app_cfg", .module = app_cfg_mod },
            },
        }),
    });

    const install_cfg = b.addInstallArtifact(cfg_exe, .{});
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    b.getInstallStep().dependOn(&install_cfg.step);
    b.getInstallStep().dependOn(&install_cli.step);

    // -- Tests --
    //
    // Building a binary never collects its `test` blocks: a `test` block is
    // collected only from the module compiled *as a test*. `app/cfg`'s entry point
    // is therefore declared a second time here, with the executable's import
    // table, purely so its tests run.
    const cfg_bin_test_mod = b.createModule(.{
        .root_source_file = b.path("app/cfg/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "app_cfg", .module = app_cfg_mod },
            .{ .name = "cfg", .module = cfg_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    const test_step = b.step("test", "Run all snek unit tests");
    // `build/targets.zig` opens each artifact through the `--listen=-` test runner,
    // which emits spurious failures on sandboxed Windows hosts. Passing a
    // `direct_step` opens the *same* artifacts a second time as direct child
    // processes, so one declaration feeds both steps and the two cannot drift.
    const test_direct_step = b.step("test-direct", "Run all snek unit tests as direct child processes");
    targets.addTestRoots(b, test_step, test_direct_step, &.{
        .{ .name = "test-lib-util", .module = util_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-cfg", .module = cfg_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-cli", .module = cli_mod, .target = target, .optimize = optimize },
        .{ .name = "test-app-cfg", .module = app_cfg_mod, .target = target, .optimize = optimize },
        .{ .name = "test-app-cfg-bin", .module = cfg_bin_test_mod, .target = target, .optimize = optimize },
        .{ .name = "test-app-cli", .module = app_cli_mod, .target = target, .optimize = optimize },
    });

    // -- Linux compile gate --
    //
    // `test` runs the artifacts for the *host* target, so a branch guarded by
    // `builtin.os.tag` is analysed only for this OS. A file can therefore pass
    // every local gate while its Linux half references APIs that no longer
    // exist - which is exactly how `lib/util/mmap.zig` rotted: the Windows
    // branch was analysed, the POSIX one never was, and nothing called
    // `MmapFile.open` to change that.
    //
    // This step compiles each test root for the shipping target - Linux, which
    // `build/targets.zig` resolves to static musl - and asserts each step
    // **succeeded without being run**. Compiling is the assertion: the suite
    // cannot execute here, and a compile of every root is enough to catch an
    // API that has been removed. It is deliberately excluded from `test`, so a
    // developer without a cross-toolchain is not blocked; run it before
    // releasing, or whenever a per-OS branch changes.
    const linux_step = b.step("test-linux-compile", "Compile every test root for x86_64-linux-musl without running it");
    const linux_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl });
    const linux_roots = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "linux-util", .module = util_mod },
        .{ .name = "linux-cfg", .module = cfg_mod },
        .{ .name = "linux-cli", .module = cli_mod },
        .{ .name = "linux-app-cfg", .module = app_cfg_mod },
        .{ .name = "linux-app-cli", .module = app_cli_mod },
    };
    for (linux_roots) |root| {
        const module = targets.testableModule(b, root.module, linux_target, optimize);
        // `link_libc` matches the shipped configuration: the release builds are
        // static musl, and a module that reaches `std.c` (as one POSIX branch
        // does) does not compile without saying so.
        module.link_libc = true;
        const compiled = b.addTest(.{ .name = root.name, .root_module = module });
        // Depending on the compile step itself is the assertion: `addTest`
        // builds a test binary and only `run` would execute it, so depending on
        // `.step` compiles every root for Linux and stops there.
        linux_step.dependOn(&compiled.step);
    }
}
