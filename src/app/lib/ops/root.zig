//! `app/cfg/lib/ops` - configuration operations, framework-agnostic.
//!
//! ## Why this folder exists
//!
//! `app/cfg` used to expose exactly one thing: `Commands(comptime AppT: type)`,
//! whose `AppT` must be a `cli.App(...)`. `app/kvs` and `app/scp` have no `App` and
//! do not import `lib/cli`, so they could not reach *any* config management. The
//! shared config home was unreachable without adopting the whole CLI framework
//! first, which is why "make the apps use the shared libraries" had stalled.
//!
//! These operations fix that by depending on nothing but `std`, `lib/cfg` and
//! `lib/util`. They are plain functions taking a writer and what they need - no
//! `cli.Ctx`, no `App`, no exit. A command, a server binary or a test can call them.
//!
//! They are files of the `app_cfg` module, reached through `app/cfg/root.zig`'s
//! `ops` surface. They used to be a module of their own (`app_cfg_ops`); the folder
//! is what the split needs, and the second module only bought a second test root.
//!
//! ## The rule for this folder
//!
//! **No `@import("framework")`.** If an operation needs the framework to work, it is
//! either doing rendering that belongs in `cmd/`, or it is not an operation. That
//! rule is what keeps the folder callable from the server binaries, and it is worth
//! enforcing in review because the import is easy to add and hard to notice.
//!
//! It is *only* a review rule now: while `ops` was its own module, the module's
//! import table named `cfg` and `util` and not `cli`, so a `cli` import here failed
//! the build. `app_cfg`'s table does name `cli` (its `cmd/` wrappers are
//! `cli.App.Command`s), so the compiler no longer catches it.
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

test "no file in this folder imports the CLI" {
    // This is the invariant that the merge into `app_cfg` stopped enforcing. The ops
    // layer's reason to exist is being usable *without* `lib/cli` - its own header says
    // so, and that is what lets a non-CLI consumer manage configuration. Before the merge
    // the build graph guaranteed it: the deleted `app_cfg_ops` module named only `cfg` and
    // `util`, so `@import("framework")` did not resolve. `app_cfg` must name `cli` (its `cmd/`
    // wrappers are `cli.App.Commands`), so the compiler can no longer tell us; the source
    // can, and `@embedFile` reads it at compile time with no path or working-directory
    // assumption - which a runtime directory scan turned out to need.
    //
    // Add any new file in this folder to the list below; the count check keeps the list
    // honest about the ones it is told about.
    const sources = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "dry_run.zig", .text = @embedFile("dry_run.zig") },
        .{ .name = "exporter.zig", .text = @embedFile("exporter.zig") },
        .{ .name = "fields.zig", .text = @embedFile("fields.zig") },
        .{ .name = "inspect.zig", .text = @embedFile("inspect.zig") },
        .{ .name = "query.zig", .text = @embedFile("query.zig") },
        .{ .name = "root.zig", .text = @embedFile("root.zig") },
    };

    // Assembled from parts so this file can be scanned like any other: a whole literal
    // here would match itself.
    const needle = "@import(" ++ "\"cli\"" ++ ")";

    for (sources) |source| {
        // Comment lines are skipped, and that is not a loophole: this very header states
        // the rule as `**No `@import("framework")`.**`, so a scan that could not tell prose from
        // code would fail on the documentation of its own invariant. A real violation is a
        // line of code, and every line of code is still checked.
        var lines = std.mem.splitScalar(u8, source.text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "//")) continue;
            if (std.mem.indexOf(u8, line, needle) != null) {
                std.debug.print("{s} imports the CLI; this folder must stay framework-free\n", .{source.name});
                return error.OpsDependsOnCli;
            }
        }
    }

    // Guard the guard: a list that lost its entries would make the loop pass vacuously.
    try std.testing.expect(sources.len >= 6);
}
