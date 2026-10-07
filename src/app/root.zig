//! `app` - the `snek` application: its `App` alias and its whole command set.
//!
//! `app/main.zig` holds the boot sequence and `src/root.zig` (the module root) holds
//! `pub fn main`; neither is imported here. What this file names is the app's surface - the
//! `App` alias and the command tree, both of which live in `cmd/`.
//!
//! The folder is `cmd/`, matching the naming convention in `AGENTS.md` 2.2 and repo-wide
//! `ROADMAP.md` item O-3.

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

test "`snek repl` reaches its body instead of falling back to help" {
    // The regression this pins: `repl` was registered with no `run`, so routing reached
    // a command with no body and *printed help* - an advertised subcommand that did
    // nothing. It now reaches `replRun`, which needs a terminal and says so.
    const testing = std.testing;

    var out_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [64]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    var state = State{};

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &state,
        .env_map = &env_map,
        .io = std.testing.io,
        .is_tty = false,
    };

    var chain = try App.ExecutionChain.init(testing.allocator, 4);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{"repl"};
    try testing.expectError(error.NotATerminal, App.execute(cmd.RootCmd, ctx, &args, &chain));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "needs a terminal") != null);
    // Nothing on stdout: the help that used to be printed instead is gone.
    try testing.expectEqualStrings("", out.buffered());
}
