//! Target policy and small artifact helpers shared by every `build.zig` in the
//! repository.
//!
//! A build file can only import files inside its own package, and the root
//! `src/zig/build.zig` and `src/zig/app/scp/build.zig` need the same release
//! target policy and the same exec/library/test plumbing. Rather than keep two
//! copies in sync by hand — which is how the two build files drifted apart in
//! the first place — both import this file.
//!
//! **This file is the template; most packages carry their own copy of it.**
//! `[measured]` at P8 step 2 there are **14** copies under `build/targets.zig`,
//! and a build root cannot `@import` above itself (`AGENT.md` 2.4), so a copy is
//! the only mechanism available — `b.dependency` composition between packages is
//! not built out yet. Thirteen of the fourteen are **byte-identical** to this one.
//!
//! **One has diverged, and it predates the copies.** `[measured]`
//! `app/scp/build/targets.zig` is 3,166 bytes against this file's 7,175, and it is
//! missing two things: `addTestRoots` has no `direct_step` parameter (the
//! `?*std.Build.Step` this file's version uses for `test-bus-direct`-style
//! uncached runs) and takes only `[]const TestRoot` rather than any slice shape.
//! It also lacks `requestedTarget`, `addExecutable` and `Executable`. Scp builds
//! green, so this is latent rather than broken — but it is exactly the "two
//! copies drift apart" failure this header was written to prevent, and it is why
//! **a change to this file must be mirrored into every copy that has the function
//! being changed.** Do not assume a green `zig build` for `scp` means its copy is
//! current.

const std = @import("std");

/// The repository rule for non-Debug builds: assume the host CPU can do
/// AVX-512 on x86_64 and NEON on aarch64, so the crypto and transfer hot paths
/// get the widened primitives. Debug builds stay portable.
pub fn requestedTarget(b: *std.Build) std.Build.ResolvedTarget {
    return resolveTarget(b, b.standardOptimizeOption(.{}));
}

/// Same as `requestedTarget`, for a build file that already resolved its
/// optimize mode and therefore must not ask for it twice.
pub fn resolveTarget(b: *std.Build, optimize: std.builtin.OptimizeMode) std.Build.ResolvedTarget {
    const target = b.standardTargetOptions(.{});
    var query = target.query;

    if (optimize != .debug) {
        if (query.cpu_arch) |arch| {
            switch (arch) {
                .x86_64 => query.cpu_features_add.addFeature(@backingInt(std.Target.x86.Feature.avx512f)),
                .aarch64 => query.cpu_features_add.addFeature(@backingInt(std.Target.aarch64.Feature.neon)),
                else => {},
            }
        }
    }

    // Static musl on Linux, so shipped binaries have no runtime libc
    // dependency. `link_libc` is applied by each artifact separately.
    if (query.os_tag) |os| {
        if (os == .linux) query.abi = .musl;
    }

    return b.resolveTargetQuery(query);
}

/// `true` when the resolved target is Linux — the signal to strip symbols from
/// release binaries.
pub fn isLinux(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .linux;
}

/// An executable plus the install artifact step that places it in `zig-out/bin`.
pub const Executable = struct {
    artifact: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

/// Creates an executable from an already-built root module and wires install.
pub fn addExecutable(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
) Executable {
    const artifact = b.addExecutable(.{ .name = name, .root_module = root_module });
    return .{ .artifact = artifact, .install = b.addInstallArtifact(artifact, .{}) };
}

/// One unit-test root: a module whose `test { std.testing.refAllDecls(@This()); }`
/// reaches every test in the module graph reachable from it.
///
/// The app-local builds (`app/scp/build/targets.zig`) declare a structurally
/// identical type. They cannot import this file — a package cannot reach above
/// its own root — so `addTestRoots` accepts `anytype` and duck-types on the
/// fields instead of demanding nominal equality.
pub const TestRoot = struct {
    name: []const u8,
    module: *std.Build.Module,
    /// Carried per root because a module built only as a dependency has no
    /// target of its own, and `b.addTest` requires one.
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// Runs a test artifact as a direct child process instead of through the
/// `--listen=-` test-runner protocol, which emits spurious failures on
/// sandboxed Windows hosts. The step is named after the artifact, so a failure
/// names the binary that failed instead of "run ignored-placeholder".
pub fn addTestRun(b: *std.Build, root: *std.Build.Step, test_artifact: *std.Build.Step.Compile) void {
    const run = std.Build.Step.Run.create(b, b.fmt("run {s} tests", .{test_artifact.name}));
    run.addFileArg(test_artifact.getEmittedBin());
    run.step.dependOn(&test_artifact.step);
    root.dependOn(&run.step);
}

/// A module suitable as the root of a `Compile` step.
///
/// `b.addTest` panics unless the root module was created with a known target,
/// but a module built as a *dependency* (the bus's `config`, `shared`, `server`,
/// …) does not need one. Rather than force every dependency module to carry a
/// target just so it can be tested, wrap it: same source file, same import
/// table, plus the target and optimize mode the test artifact needs.
pub fn testableModule(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const imports = b.allocator.alloc(std.Build.Module.Import, module.import_table.count()) catch @panic("OOM");
    for (module.import_table.values(), module.import_table.keys(), 0..) |imported, name, i| {
        imports[i] = .{ .name = name, .module = imported };
    }

    return b.createModule(.{
        .root_source_file = module.root_source_file,
        .imports = imports,
        .target = target,
        .optimize = optimize,
        .link_libc = module.link_libc,
    });
}

/// Opens one test artifact, runs it through the test runner, and optionally
/// again as a direct child process (see `addTestRun`). Iterating index-by-index
/// rather than with `for (roots)` keeps `roots` usable as either a slice or an
/// array literal at the call site.
fn addOneTestRoot(
    b: *std.Build,
    test_step: *std.Build.Step,
    direct_step: ?*std.Build.Step,
    roots: anytype,
    comptime i: usize,
) void {
    const artifact = b.addTest(.{
        .name = roots[i].name,
        .root_module = testableModule(b, roots[i].module, roots[i].target, roots[i].optimize),
    });
    test_step.dependOn(&b.addRunArtifact(artifact).step);
    if (direct_step) |direct| addTestRun(b, direct, artifact);
}

/// Creates one test artifact per root and wires each into `test_step` (through
/// the test runner) and, when given, `direct_step` (as a child process).
///
/// This is the entire unit-test surface of an app: the build file names the
/// modules, not the individual test compilations, because each root module ends
/// its own file with `refAllDecls(@This())`. Each root carries the `target` and
/// `optimize` its test artifact needs (see `testableModule`).
pub fn addTestRoots(
    b: *std.Build,
    test_step: *std.Build.Step,
    direct_step: ?*std.Build.Step,
    roots: anytype,
) void {
    const T = @TypeOf(roots);

    if (comptime isSlice(T)) {
        for (roots) |root| {
            const artifact = b.addTest(.{
                .name = root.name,
                .root_module = testableModule(b, root.module, root.target, root.optimize),
            });
            test_step.dependOn(&b.addRunArtifact(artifact).step);
            if (direct_step) |direct| addTestRun(b, direct, artifact);
        }
    } else {
        inline for (roots, 0..) |_, i| addOneTestRoot(b, test_step, direct_step, roots, i);
    }
}

/// `true` for a slice, a pointer-to-array or an array — the shapes a caller may
/// reasonably hand to `addTestRoots`.
fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size != .one,
        .array => true,
        else => false,
    };
}
