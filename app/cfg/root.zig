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
//! * **`ops/`** - framework-agnostic operations. `std` + `lib/cfg` only, no
//!   `cli.Ctx`. Callable from a command, a server binary, or a test.
//! * **`cmd/`** - thin `cli.App.Command` wrappers. Parse flags, call `ops`, render.
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
pub const ops = @import("app_cfg_ops");

/// The command group, and the demo config it defaults to.
pub const cmd = @import("cmd/root.zig");

/// Builds the `config` command group for `AppT` over `ConfigT`.
pub const Commands = cmd.Commands;

/// The placeholder configuration the prototype binary resolves.
pub const Config = cmd.Config;

test {

    // `refAllDecls` is shallow: it reaches the declarations of the namespaces it is
    // handed, and a `test` block is collected only when a declaration in that
    // namespace references it. `app/cli/lib/ROADMAP.md` M-2 records the rule and the
    // control experiment.
    //
    // `ops` is a *separate module* (`app_cfg_ops`), and no amount of referencing from
    // here collects its tests - a `test` block is only collected from the module
    // being compiled. Its tests therefore have their own root, `test-app-cfg-ops`,
    // registered in `build.zig`. Measured: naming `ops` here collected 0 of its tests
    // and this app's total silently fell from 34 to 15.
    std.testing.refAllDecls(cmd);
}
