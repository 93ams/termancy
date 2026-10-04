//! Vendored subset of `tigershark`'s `src/zig/lib/util`, carried into `snek` so
//! that this repository has **no dependency on the monorepo it came from**.
//!
//! ## Why this is a copy, and why it is small
//!
//! `snek` was extracted from `tigershark`, which still consumes `snek`'s `cfg`
//! and `cli` modules from `app/kvs`, `app/bus` and `app/git`. That makes the
//! edge one-directional by construction: `tigershark` depends on `snek`, so
//! `snek` may not depend on `tigershark`. The nine `@import("util")` sites inside
//! the migrated apps therefore cannot resolve to the monorepo's module, and the
//! modules they touch are copied here instead.
//!
//! The copy is deliberately the **closure actually used**, not the whole
//! library. `lib/io`, `lib/net` and `lib/crypto` are not represented at all:
//! `[measured]` zero files under the migrated apps import them.
//!
//! ## Why eleven of these look unused
//!
//! `lib/cli/cli.zig` re-exports eleven of these modules under their historical
//! `cli.X` names (`vfs`, `tasks`, `cancellation`, `mmap`, `linter`, `dag`, `cas`,
//! `btree_store`, `object_pipe`, `footprint`, `dry_run`), and
//! `lib/cli/root.zig` carries a comptime guard asserting that every `pub` decl of
//! `cli.zig` is re-exported from `root.zig`. Both halves have to compile, so all
//! eleven modules must exist here even though nothing calls them directly.
//!
//! `trace`, `systemd_exporter` and `spin_lock` are the three that are named
//! directly, by `platform/*`, `render/progress.zig` and `cfg_ops/exporter.zig`.

const std = @import("std");

/// A spin lock, used by the progress renderer.
pub const spin_lock = @import("spin_lock.zig");

/// `.env` / systemd-unit export. Takes a writer and key/value pairs and mentions
/// neither a terminal nor a command, which is why it does not live in `cli`.
pub const systemd_exporter = @import("systemd_exporter.zig");

/// A cooperative cancellation flag shared across a task graph.
pub const cancellation = @import("cancellation.zig");

/// Content-addressable key derivation for caching command results.
pub const cas = @import("cas.zig");

/// A string-keyed workspace store. Carries a known defect in the update path,
/// recorded in `lib/cli/ROADMAP.md` B-2.
pub const btree_store = @import("btree_store.zig");

/// Task dependency graphs and stage layering.
pub const dag = @import("dag.zig");

/// A record of intended mutations for a dry run, and its diff renderer.
pub const dry_run = @import("dry_run.zig");

/// Compiled struct-layout metrics.
pub const footprint = @import("footprint.zig");

/// Comptime validation of flag-struct declarations.
pub const linter = @import("linter.zig");

/// Read-only memory-mapped files, Windows and POSIX.
pub const mmap = @import("mmap.zig");

/// Structured (JSON / NDJSON) record piping.
pub const object_pipe = @import("object_pipe.zig");

/// Named tasks with dependencies and cycle detection.
pub const tasks = @import("tasks.zig");

/// An embedded-asset virtual filesystem.
pub const vfs = @import("vfs.zig");

/// W3C Trace Context: the shared `traceparent` serializer.
pub const trace = @import("trace.zig");

test {
    std.testing.refAllDecls(@This());
}
