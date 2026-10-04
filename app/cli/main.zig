//! The `tigershark` binary - the CLI framework's own entry point.
//!
//! `AGENT.md` 3.2: a file named `main.zig` holds `main` and nothing else. The command tree,
//! the flags struct, the `App` alias, the root command and its `run` are in `cmd/root.zig`,
//! which is the one file that names the whole command set.

const std = @import("std");
const cmd = @import("cmd/root.zig");

pub fn main(init: std.process.Init) !void {
    var state = cmd.State{};

    // `App.run` owns the bootstrap: argv filtering, buffered stdio sized from
    // `cli.Config`, the `Ctx` (including `env_map` and `io`), the execution
    // chain, and turning a failed command into a non-zero exit status.
    //
    // This used to hand-build all of that here, which is why `App.run`'s missing
    // `env_map`/`io` went unnoticed: the framework's own entry point was not
    // using the framework's entry point. Two things are deliberately not carried
    // over - a `std.debug.print("Debug print works!")` on every invocation, and
    // the best-effort `version.notifyIfUpdateAvailable` call at the end, whose
    // network check is disabled anyway (`cli.version.check`). Both are noted in
    // `app/cli/lib/ROADMAP.md` A-4.
    try cmd.App.run(&state, cmd.RootCmd, init);
}
