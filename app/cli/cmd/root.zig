//! `app/cli/cmd` - the shared `App` alias and one file per subcommand.
//!
//! This is both the folder root and the `App` home, which is deliberate: the
//! alias is what every command in this folder is built from, so it belongs beside
//! them rather than in a separate `app.zig`. A command file reads
//!
//! ```zig
//! const App = @import("root.zig").App;
//! pub const cmd = App.Command(MyFlags, .{}){ ... };
//! ```
//!
//! `main.zig` lists the commands in the root command's tuple. This file names
//! them, so a new subcommand is added in two places instead of being discoverable
//! only inside a tuple literal.
//!
//! The folder is `cmd/` to match `app/bus/cmd`, `app/kvs/cmd` and `app/scp/cmd`.
//! See repo-wide `ROADMAP.md` item O-3 for the naming convention.

const std = @import("std");
const cli = @import("cli");

/// Per-invocation state threaded through the command tree. Empty: this app keeps
/// no state between commands, which is why the commands are self-contained.
pub const State = struct {};

/// The app's `App`, specialised to `State` and the framework's default `Config`.
pub const App = cli.App(State, cli.Config{});

/// `tigershark add` - add a UI component from the registry.
pub const add = @import("add.zig");
/// `tigershark init` - scaffold a new project.
pub const init = @import("init.zig");

test {
    // Shallow by design: `refAllDecls` reaches the declarations of the namespace
    // it is handed, so each one is named. See `app/cli/lib/ROADMAP.md` M-2.
    std.testing.refAllDecls(@import("add.zig"));
    std.testing.refAllDecls(@import("init.zig"));
}

// -- The `tigershark` binary's root command ----------------------------------
//
// This file is the package root of `app/cli/cmd`, and `AGENT.md` 3.2 keeps a file named
// `main.zig` to `main` alone. The root command belongs here with the rest of the command
// tree rather than in the entry point: it is the same kind of declaration as `add` and
// `init` above, and putting it here means one file names the whole command set.

/// Flags for `tigershark` itself.
pub const RootFlags = struct {
    version: bool = false,

    pub const meta = .{
        .version = .{
            .short = 'v',
            .help = "Print the CLI version",
        },
    };
};

/// `tigershark repl` - the interactive shell. `is_repl` marks it for the framework.
const repl_cmd = App.Command(struct {}, .{}){
    .name = "repl",
    .description = "Start interactive Tigershark REPL",
    .is_repl = true,
};

/// The root command.
///
/// Configuration management lives in `app/cfg`, shared with the other binaries rather
/// than owned by this one. It is a function of `App` because a command is a type
/// specialised to the app's state - see `app/cfg/root.zig`.
pub const RootCmd = App.Command(RootFlags, .{
    repl_cmd,
    @import("app_cfg").Commands(App, @import("app_cfg").Config).config,
    add.cmd,
    init.cmd,
}){
    .name = "tigershark",
    .run = rootRun,
};

fn rootRun(ctx: App.Ctx, flags: App.Flags(RootFlags)) !void {
    if (flags.version) {
        try ctx.out.writeAll("tigershark v0.1.0\n");
        return;
    }
    // Print help if no subcommands match
    try ctx.out.writeAll("Tigershark CLI Framework - Project scaffolder and component manager" ++ "\n\nUse --help to see available commands.\n");
}
