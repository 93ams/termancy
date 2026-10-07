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

    // -- Library modules --
    //
    // One module per independently usable concern, declared in dependency order so each
    // module's import table can name the ones below it. The layering is `SPEC.md`
    // REQ-LAYOUT-008 and it points one way: nothing in `src/lib` imports `framework`, and
    // only `framework` imports everything.
    //
    // A module root may not import outside its own directory, which is why these are
    // modules rather than relative paths - see the probe recorded in `SPEC.md`.
    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/lib/util/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cfg_mod = b.addModule("cfg", .{
        .root_source_file = b.path("src/lib/cfg/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
        },
    });
    const render_mod = b.addModule("render", .{
        .root_source_file = b.path("src/lib/render/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
        },
    });
    const platform_mod = b.addModule("platform", .{
        .root_source_file = b.path("src/lib/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "render", .module = render_mod },
            .{ .name = "util", .module = util_mod },
        },
    });
    const secrets_mod = b.addModule("secrets", .{
        .root_source_file = b.path("src/lib/secrets/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cfg", .module = cfg_mod },
            .{ .name = "util", .module = util_mod },
        },
    });
    // `interact` is the module that reads stdin, so it needs the renderer to draw and the
    // platform layer for terminal state. `render` is here as well as on the two above
    // because a file inside this module resolves `@import("x")` against *this* table, and a
    // table that is a subset of what a deeper file needs fails against the deep file.
    const interact_mod = b.addModule("interact", .{
        .root_source_file = b.path("src/lib/interact/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "render", .module = render_mod },
            .{ .name = "platform", .module = platform_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // The framework's public surface is `root.zig`, not `cli.zig`; `root.zig` carries a
    // comptime guard asserting it re-exports every `pub` decl of `cli.zig`.
    const framework_mod = b.addModule("framework", .{
        .root_source_file = b.path("src/lib/framework/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cfg", .module = cfg_mod },
            .{ .name = "util", .module = util_mod },
            .{ .name = "render", .module = render_mod },
            .{ .name = "platform", .module = platform_mod },
            .{ .name = "secrets", .module = secrets_mod },
            .{ .name = "interact", .module = interact_mod },
        },
    });

    // -- The application module --
    //
    // The root is `src/root.zig` rather than `src/app/main.zig` because a module root may
    // only reach inside its own directory, and the app needs both `app/` and `lib/`. That
    // also means `pub fn main` lives in the root file and delegates to `app/main.zig`.
    //
    // The folder's own files (`cmd/`, `lib/ops/`) are reached by relative import, which is
    // what "the app imports its own lib files directly" means: they are files of this
    // module, not a module boundary of their own.
    const app_mod = b.addModule("app", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "framework", .module = framework_mod },
            .{ .name = "cfg", .module = cfg_mod },
            .{ .name = "util", .module = util_mod },
            .{ .name = "render", .module = render_mod },
            .{ .name = "platform", .module = platform_mod },
            .{ .name = "secrets", .module = secrets_mod },
            .{ .name = "interact", .module = interact_mod },
        },
    });

    // The cross-module behavioural suite. It exercises six modules, so it cannot live
    // inside any one of them; `ROADMAP.md` RISK-LAYOUT-2 records why.
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "framework", .module = framework_mod },
            .{ .name = "cfg", .module = cfg_mod },
            .{ .name = "util", .module = util_mod },
            .{ .name = "render", .module = render_mod },
            .{ .name = "platform", .module = platform_mod },
            .{ .name = "secrets", .module = secrets_mod },
            .{ .name = "interact", .module = interact_mod },
        },
    });

    // -- The binary --
    //
    // One executable (SPEC.md REQ-LAYOUT-004). Its module is the app's, so the entry point
    // is `src/root.zig`'s `pub fn main`.
    const snek_exe = b.addExecutable(.{
        .name = "snek",
        .root_module = app_mod,
    });
    b.installArtifact(snek_exe);

    // -- Source lint --
    //
    // Two checks, both about source text, which is why they are a build step rather than
    // unit tests: a test artifact cannot read its own tree portably (it runs elsewhere, and
    // `@embedFile` needs one literal path per file).
    //
    // 1. `@import` paths are always spelled with `/`. Zig reads `\c` as an invalid escape,
    //    so a backslash path is a compile error whose message points at the wrong thing; the
    //    repository has been bitten once by its own tooling. `MIGRATION.md` records it.
    //
    // 2. Every `.zig` file under a module directory is named by that module's collector.
    //    `refAllDecls` is shallow, so a file nobody references contributes no tests - the
    //    build stays green and the suite just gets smaller. That is how four `tea.Program`
    //    tests were lost during the migration; see `ROADMAP.md` M-2.
    const lint_exe = b.addExecutable(.{
        .name = "import-lint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/import_lint.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const lint_run = b.addRunArtifact(lint_exe);
    lint_run.setName("lint: import paths and module test collection");
    lint_run.addArg(b.pathFromRoot("src"));
    lint_run.addArg(b.pathFromRoot("build"));
    lint_run.addArg(b.fmt("--modules={s}", .{b.pathFromRoot("src/lib")}));
    const lint_step = b.step("lint", "Check import paths and module test collection");
    lint_step.dependOn(&lint_run.step);

    const test_step = b.step("test", "Run all snek unit tests");
    // Part of `test`, so a violation cannot reach a commit without failing the same command
    // a contributor already runs. `test-direct` deliberately does not depend on it: that
    // step exists to re-run the *same* test artifacts uncached, and this is a different
    // kind of check.
    test_step.dependOn(&lint_run.step);
    // `build/targets.zig` opens each artifact through the `--listen=-` test runner,
    // which emits spurious failures on sandboxed Windows hosts. Passing a
    // `direct_step` opens the *same* artifacts a second time as direct child
    // processes, so one declaration feeds both steps and the two cannot drift.
    const test_direct_step = b.step("test-direct", "Run all snek unit tests as direct child processes");
    targets.addTestRoots(b, test_step, test_direct_step, &.{
        .{ .name = "test-lib-util", .module = util_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-cfg", .module = cfg_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-render", .module = render_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-platform", .module = platform_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-secrets", .module = secrets_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-interact", .module = interact_mod, .target = target, .optimize = optimize },
        .{ .name = "test-lib-framework", .module = framework_mod, .target = target, .optimize = optimize },
        .{ .name = "test-app", .module = app_mod, .target = target, .optimize = optimize },
        .{ .name = "test-integration", .module = integration_test_mod, .target = target, .optimize = optimize },
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
        .{ .name = "linux-render", .module = render_mod },
        .{ .name = "linux-platform", .module = platform_mod },
        .{ .name = "linux-secrets", .module = secrets_mod },
        .{ .name = "linux-interact", .module = interact_mod },
        .{ .name = "linux-framework", .module = framework_mod },
        .{ .name = "linux-app", .module = app_mod },
        .{ .name = "linux-integration", .module = integration_test_mod },
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
