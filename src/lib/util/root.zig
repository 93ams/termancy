//! Vendored subset of the upstream `snek` monorepo's `src/zig/lib/util`, carried
//! into this repository so that it has **no dependency on the monorepo it came
//! from**.
//!
//! ## Why this is a copy, and why it is small
//!
//! This repository was extracted from the upstream monorepo, which still
//! consumes this repository's `cfg` and `cli` modules from its own `app/kvs`,
//! `app/bus` and `app/git`. That makes the edge one-directional by construction:
//! the monorepo depends on this repository, so this repository may not depend on
//! the monorepo. The nine `@import("util")` sites inside the migrated apps
//! therefore cannot resolve to the monorepo's module, and the modules they touch
//! are copied here instead.
//!
//! (The two share a name, which is why this header says "the upstream monorepo"
//! and "this repository" rather than using it: the direction of the dependency,
//! not the name, is what the rule is about.)
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
//! directly, by `platform/*`, `render/progress.zig` and `app/cfg/lib/ops/exporter.zig`.

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

/// A virtual filesystem: one interface over memory, disk and embedded assets.
///
/// **This file has diverged from the copy it started as.** Everything else here is
/// byte-identical to the monorepo's `lib/util`; `vfs.zig` was a comptime asset
/// table with no interface, and now carries the `Vfs` vtable plus the in-memory
/// and disk backends. So "vendored" is accurate for the other thirteen modules and
/// no longer accurate for this one - recorded here rather than left for someone to
/// discover by diffing.
pub const vfs = @import("vfs.zig");

/// W3C Trace Context: the shared `traceparent` serializer.
pub const trace = @import("trace.zig");

test {
    std.testing.refAllDecls(@This());
}
