//! `termancy cli repl`: termancy's own commands as an interactive shell.

const std = @import("std");
const cli = @import("cli");
const tree = @import("../../main.zig");

pub const command = cli.command(.{
    .name = "repl",
    .summary = "Run termancy commands from an interactive shell",
    .description =
    \\Read command lines and run each as termancy would, without the leading "termancy":
    \\"cfg get server.port", then "cfg keys", and so on. Words are split as a shell splits
    \\them, without expansions. "exit", "quit", or the end of input ends the shell, with
    \\the status of the last line run.
    \\
    \\Standard input may be a script: printf 'cfg keys\ncfg get name\n' | termancy cli repl.
    ,
    .examples =
    \\termancy cli repl
    \\termancy cli repl < commands.txt
    ,
    .run = run,
});

fn run(ctx: *cli.Context) !void {
    var buffer: [4096]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var in = stdin.readerStreaming(ctx.io, &buffer);
    const interactive = cli.terminal.interactive(
        ctx.environ,
        stdin.isTty(ctx.io) catch false,
        std.Io.File.stderr().isTty(ctx.io) catch false,
    );
    const app: cli.App = .{ .root = &tree.root, .completion_command = false };
    const status = cli.repl.run(app, .{
        .io = ctx.io,
        .gpa = ctx.gpa,
        .environ = ctx.environ,
        .out = ctx.out,
        .err = ctx.err,
        .in = &in.interface,
        .interactive = interactive,
        .terminal = if (interactive) stdin else null,
    }, .{ .prompt = "termancy> " });
    if (status != 0) return ctx.exit(status);
}
