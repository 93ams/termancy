//! `app/cfg/lib/cfg_ops` - configuration operations, framework-agnostic.
//!
//! ## Why this folder exists
//!
//! `app/cfg` used to expose exactly one thing: `Commands(comptime AppT: type)`,
//! whose `AppT` must be a `cli.App(...)`. `app/kvs` and `app/scp` have no `App` and
//! do not import `lib/cli`, so they could not reach *any* config management. The
//! shared config home was unreachable without adopting the whole CLI framework
//! first, which is why "make the apps use the shared libraries" had stalled.
//!
//! These operations fix that by depending on nothing but `std` and `lib/cfg`. They
//! are plain functions taking a writer and what they need - no `cli.Ctx`, no
//! `App`, no exit. A command, a server binary or a test can call them.
//!
//! ## The rule for this folder
//!
//! **No `@import("cli")`.** If an operation needs the framework to work, it is
//! either doing rendering that belongs in `cmd/`, or it is not an operation. That
//! rule is what keeps the folder callable from the server binaries, and it is worth
//! enforcing in review because the import is easy to add and hard to notice.
//!
//! ## What is here so far
//!
//! * `export` - map a config to environment variables, as `.env` or a systemd unit.
//! * `dry_run` - validate `key=value` overrides against a `ConfigT` without applying
//!   them.
//! * `inspect` - explain where a field's value came from (provenance / blame).
//!
//! Each was chosen because its library already existed and needed only wiring:
//! `util.systemd_exporter`, `cfg.config_dryrun` and `cfg.config_lineage`
//! respectively. See `app/cfg/PLAN.md` for what remains and in what order.

const std = @import("std");

/// The comptime field table shared by the operations below.
pub const fields = @import("fields.zig");

/// Export a resolved config as environment variables. (`exporter` - `export` is a Zig keyword.)
pub const exporter = @import("exporter.zig");
/// Validate configuration overrides without applying them.
pub const dry_run = @import("dry_run.zig");
/// Read a configuration value or list its keys.
pub const query = @import("query.zig");
/// Explain a configuration field's provenance.
pub const inspect = @import("inspect.zig");

test {
    // `refAllDecls` is shallow: it reaches the declarations of the namespaces it
    // is handed, and a `test` block is collected only when a declaration in that
    // namespace references it. Each namespace is named explicitly.
    // `app/cli/lib/ROADMAP.md` M-2 records the rule and the control experiment.
    std.testing.refAllDecls(exporter);
    std.testing.refAllDecls(dry_run);
    std.testing.refAllDecls(inspect);
    std.testing.refAllDecls(query);
}
