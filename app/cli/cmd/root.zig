//! `app/cli/cmd` - the shared `App` alias and one file per subcommand.
//!
//! This is both the folder root and the `App` home, which is deliberate: the
//! alias is what every command in this folder is built from, so it belongs beside
//! them rather than in a separate `app.zig`. A command file reads
//!
//! ```zig
//! const App = @import("root.zig").App;
//!
//! const meta = .{ .name = "add", .flags = AddFlags, .args = AddArgs };
//! pub const cmd = App.command(meta, addRun);
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

/// The app's `App`, specialised to `State` and this app's framework configuration.
///
/// `version` is what the framework's built-in `--version` / `-V` prints, with the
/// command's own name in front. The root command below keeps its `-v` flag as well,
/// so all three spellings work and none of them is lost.
pub const App = cli.App(State, cli.Config{ .version = "v0.1.0" });

/// `snek add` - add a UI component from the registry.
pub const add = @import("add.zig");
/// `snek init` - scaffold a new project.
pub const init = @import("init.zig");

test {
    // Shallow by design: `refAllDecls` reaches the declarations of the namespace
    // it is handed, so each one is named. See `lib/cli/ROADMAP.md` M-2.
    std.testing.refAllDecls(@import("add.zig"));
    std.testing.refAllDecls(@import("init.zig"));
}

// -- The `snek` binary's root command ----------------------------------
//
// This file is the package root of `app/cli/cmd`, and `AGENTS.md` 3.2 keeps a file named
// `main.zig` to `main` alone. The root command belongs here with the rest of the command
// tree rather than in the entry point: it is the same kind of declaration as `add` and
// `init` above, and putting it here means one file names the whole command set.

/// Flags for `snek` itself.
pub const RootFlags = struct {
    version: bool = false,

    pub const meta = .{
        .version = .{
            .short = 'v',
            .help = "Print the CLI version",
        },
    };
};

/// `snek repl` - the interactive shell.
///
/// `is_repl` marks it for the framework's own interactive path, and the body below
/// enters the shell. Without the body this command was *advertised and did nothing*:
/// routing reached a command with no `run`, which printed help instead of starting the
/// shell - so `snek repl` and `snek --interactive` disagreed about what the
/// subcommand was for.
const repl_meta = .{
    .name = "repl",
    .description = "Start interactive Snek REPL",
    .is_repl = true,
};

const repl_cmd = App.command(repl_meta, replRun);

/// Starts the REPL over the root command.
///
/// `RootCmd` is declared below; that is not a cycle, because a function body is
/// analysed when it is called and the command's *type* does not depend on it.
fn replRun(ctx: App.Ctx) !void {
    if (!ctx.is_tty) {
        // Raw mode needs a terminal. Saying so beats the OS error that setting raw
        // mode on a pipe produces.
        try ctx.err.writeAll("'repl' needs a terminal; run it directly rather than through a pipe.\n");
        return error.NotATerminal;
    }
    try App.runShell(RootCmd, ctx);
}

/// The built-in `update` command, wired to this application's release registry.
///
/// `resolve_target` is what makes it usable rather than merely present: the framework
/// cannot discover the running binary's path (`std.process.Init` does not carry one), so
/// the app supplies `cli.self_exe`'s resolver, which reads the loader's record on Windows
/// and `/proc/self/exe` on Linux.
///
/// No `public_key` yet: signatures are supported and enforced when a key is configured,
/// and setting one before the project publishes signed releases would make `update`
/// refuse to install its own releases. The field is the policy switch, so this is a
/// deliberate omission with a one-line fix rather than an unimplemented feature.
const update_cmd = App.updateCommand(.{
    .owner = "93ams",
    .repo = "snek",
    .asset = if (@import("builtin").os.tag == .windows)
        "snek-windows-x86_64.exe"
    else
        "snek-linux-x86_64",
    .current_version = "0.1.0",
    .resolve_target = cli.self_exe.resolveTarget,
});

/// The root command's metadata.
///
/// Configuration management lives in `app/cfg`, shared with the other binaries rather
/// than owned by this one. It is a function of `App` because a command is a type
/// specialised to the app's state - see `app/cfg/root.zig`.
const root_meta = .{
    .name = "snek",
    .description = "Snek CLI Framework - project scaffolder and component manager",
    .flags = RootFlags,
    .subcommands = .{
        repl_cmd,
        update_cmd,
        @import("app_cfg").Commands(App, @import("app_cfg").Config).config,
        add.cmd,
        init.cmd,
    },
};

pub const RootCmd = App.command(root_meta, rootRun);

/// The root body: `--version`'s short form, or usage.
///
/// `--version` and `-V` never reach here: the framework answers them from
/// `Config.version` before the body runs.
fn rootRun(ctx: App.Ctx, flags: App.Flags(RootFlags)) !void {
    if (flags.version) {
        try ctx.out.writeAll("snek v0.1.0\n");
        return;
    }
    // Print help if no subcommands match
    try ctx.out.writeAll("Snek CLI Framework - Project scaffolder and component manager" ++ "\n\nUse --help to see available commands.\n");
}
