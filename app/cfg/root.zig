//! `app/cfg` - the configuration-management home for every binary.
//!
//! ## The two halves, and why they are split
//!
//! This module used to expose exactly one thing: `Commands(comptime AppT: type)`,
//! whose `AppT` must be a `cli.App(...)`. `app/kvs` and `app/scp` have no `App` and
//! do not import `lib/cli`, so they could not reach **any** config management. The
//! shared config home was unreachable without adopting the whole CLI framework
//! first, which is why "make the apps use the shared libraries" had stalled.
//!
//! So the module is split by **audience**:
//!
//! * **`lib/ops/`** - framework-agnostic operations. `std` + `lib/cfg` + `lib/util`
//!   only, no `cli.Ctx`. Callable from a command, a server binary, or a test.
//! * **`cmd/`** - thin `cli.App.Command` wrappers. Parse flags, call `ops`, render.
//!
//! Both are files of this one module; `ops/` is not a module of its own.
//!
//! `Commands(AppT, ConfigT)` is the assembly point that returns the command group.
//!
//! ## Using it
//!
//! From a binary that has a `cli.App`:
//!
//! ```zig
//! const cfg_cmds = @import("app_cfg").Commands(App, MyConfig);
//! // then use cfg_cmds.config in the root command tuple
//! ```
//!
//! From a server binary that does not (the case that was previously impossible):
//!
//! ```zig
//! const ops = @import("app_cfg").ops;
//! try ops.export.writeDotEnv(allocator, writer, collector.variables());
//! ```
//!
//! ## Status
//!
//! Implemented: `config export`, `config dry-run`, `config inspect` - the three
//! whose library operations already existed. See `PLAN.md` in this folder for the
//! remaining twelve features, the two binding owner constraints (no runtime
//! compilation, no background threads) and the risk-ordered plan.

const std = @import("std");

/// Configuration operations, callable without the CLI framework.
///
/// A folder of this module rather than a module of its own: the files are reached
/// by relative import, so `test { refAllDecls(ops); }` below collects their tests
/// into `test-app-cfg` instead of a second test root.
pub const ops = @import("lib/ops/root.zig");

/// The command group, and the demo config it defaults to.
pub const cmd = @import("cmd/root.zig");

/// Builds the `config` command group for `AppT` over `ConfigT`.
pub const Commands = cmd.Commands;

/// The placeholder configuration the prototype binary resolves.
pub const Config = cmd.Config;

test "the operations are part of this module, and reachable through it" {
    // `refAllDecls` is shallow: it reaches the declarations of the namespaces it is
    // handed, and a `test` block is collected only when a declaration in that
    // namespace references it. `app/cli/lib/ROADMAP.md` M-2 records the rule and the
    // control experiment.
    //
    // `ops` used to be a *separate module* (`app_cfg_ops`), and no amount of
    // referencing from here collected its tests - a `test` block is only collected
    // from the module being compiled - so they needed their own root,
    // `test-app-cfg-ops`. The operations are files of *this* module now, so naming
    // `ops` here is what collects their tests into `test-app-cfg`.
    std.testing.refAllDecls(cmd);
    std.testing.refAllDecls(ops);

    // The invariant the merge is for: a binary with no `cli.App` reaches every
    // operation through the app module's own surface (`@import("app_cfg").ops`),
    // with no module of its own in between - and the surface is checked rather than
    // assumed, because a folder that stops being re-exported still compiles.
    try std.testing.expect(@hasDecl(@This(), "ops"));
    try std.testing.expect(@hasDecl(ops, "exporter"));
    try std.testing.expect(@hasDecl(ops, "dry_run"));
    try std.testing.expect(@hasDecl(ops, "inspect"));
    try std.testing.expect(@hasDecl(ops, "query"));
    try std.testing.expect(@hasDecl(ops, "fields"));
    try std.testing.expect(@hasDecl(ops.exporter, "writeDotEnv"));
    try std.testing.expect(@hasDecl(ops.dry_run, "checkAll"));
    try std.testing.expect(@hasDecl(ops.inspect, "reportAll"));
    try std.testing.expect(@hasDecl(ops.query, "get"));
}
