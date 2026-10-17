//! `snek cli`: commands about command-line applications built on the `cli` library:
//! snek's own documentation, completion, and shell, and the `init` and `add` generators.

const std = @import("std");
const cli = @import("cli");
const docs = @import("docs.zig");
const init = @import("init.zig");
const add = @import("add.zig");
const repl = @import("repl.zig");
const explain = @import("explain.zig");
const freeze = @import("freeze.zig");
const record = @import("record.zig");

pub const command = cli.command(.{
    .name = "cli",
    .summary = "Generate cli applications; documentation and completion for snek",
    .subcommands = .{
        init.command,
        add.command,
        docs.command,
        repl.command,
        explain.command,
        freeze.command,
        record.command,
        cli.complete.command,
    },
});

test {
    std.testing.refAllDecls(docs);
    std.testing.refAllDecls(init);
    std.testing.refAllDecls(add);
    std.testing.refAllDecls(repl);
    std.testing.refAllDecls(explain);
    std.testing.refAllDecls(freeze);
    std.testing.refAllDecls(record);
    std.testing.refAllDecls(@import("flagspec.zig"));
    std.testing.refAllDecls(@import("templates.zig"));
    std.testing.refAllDecls(@import("project.zig"));
}
