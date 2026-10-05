//! `cfg` - the configuration-management binary.
//!
//! ## Why this is a separate binary
//!
//! The specification describes two tools: `cli` for workspace and framework work, and
//! `cfg` for configuration. Both existed only as subcommands of one binary, so a user who
//! wanted `cfg get` had to invoke `tigershark config get`, and a machine that needed only
//! configuration tooling had to install the component registry, the scaffolder and the
//! REPL with it.
//!
//! ## What this binary deliberately does not have
//!
//! No `repl`, no `add`, no `init`. Those are workspace tools, and their absence is the
//! reason to have a separate binary at all. The root command's test asserts it.
//!
//! ## Only `main` lives here
//!
//! `AGENT.md` 3.2: a file named `main.zig` holds `main` and nothing else. The command
//! tree, the flags struct, the `App` alias and the root `run` are in `cmd/cfg.zig`; this
//! file exists to root the artifact and nothing more.

const std = @import("std");
const cli = @import("cli");
const cfg_cmd = @import("cmd/root.zig");

/// The panic handler for this binary. See `app/cli/main.zig` for what it prints and
/// why the JSON report carries no argv or environment.
pub const panic = cli.crash.Panic(.{
    .app_name = "cfg",
    .report_dir = ".cache",
});

pub fn main(init: std.process.Init) !void {
    // Arms the crash reporter before anything else can panic.
    cli.crash.install(init.io);

    var state = cfg_cmd.State{};
    try cfg_cmd.CfgApp.run(&state, cfg_cmd.RootCmd, init);
}
