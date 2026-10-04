//! `app/cli` - the `tigershark` binary.
//!
//! `main.zig` is the executable entry point and is deliberately **not** imported
//! here: a module root must not depend on the entry point. What this file names is
//! the app's surface - the `App` alias and the command set, both of which live in
//! `cmd/`.
//!
//! The folder is `cmd/`, matching `app/bus/cmd`, `app/kvs/cmd` and
//! `app/scp/cmd`. See repo-wide `ROADMAP.md` item O-3.

const std = @import("std");

/// The `cmd/` folder root: the shared `App` alias plus every subcommand.
pub const cmd = @import("cmd/root.zig");

/// The `App` alias, specialised to this app's state and the default framework
/// config. Re-exported so callers can write `@import("root.zig").App`.
pub const App = cmd.App;
/// The per-invocation state type.
pub const State = cmd.State;

test {
    std.testing.refAllDecls(cmd);
}
