//! The `tigershark` binary - the CLI framework's own entry point.
//!
//! `AGENT.md` 3.2: a file named `main.zig` holds `main` and nothing else. The command tree,
//! the flags struct, the `App` alias, the root command and its `run` are in `cmd/root.zig`,
//! which is the one file that names the whole command set.

const std = @import("std");
const cli = @import("cli");
const cmd = @import("cmd/root.zig");

/// The panic handler for this binary.
///
/// A panic prints a boxed banner naming the app, OS and architecture, dumps the stack
/// trace, and - because `install` arms the report writer below - writes a JSON report to
/// `.cache/tigershark-crash-<timestamp>.json` that a user can attach to an issue. The
/// report deliberately contains the message, app, OS, architecture, Zig version and
/// timestamp: no argv, no environment, no paths, because a panic is exactly the moment a
/// secret from the command line would otherwise be copied somewhere durable.
pub const panic = cli.crash.Panic(.{
    .app_name = "tigershark",
    .report_dir = ".cache",
});

pub fn main(init: std.process.Init) !void {
    // Arms the crash reporter. Without it the banner and stack still print and the JSON
    // report is skipped with a note, which is why this is the first statement in `main`
    // rather than something a later initialiser happens to do.
    cli.crash.install(init.io);

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
