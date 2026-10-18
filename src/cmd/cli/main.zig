//! `termancy cli`: commands about command-line applications built on the `cli` library:
//! termancy's own documentation, completion, and shell, and the `init` and `add` generators.

const std = @import("std");
const cli = @import("cli");
const docs = @import("docs.zig");
const init = @import("init.zig");
const add = @import("add.zig");
const repl = @import("repl.zig");

pub const command = cli.command(.{
    .name = "cli",
    .summary = "Generate cli applications; documentation and completion for termancy",
    .subcommands = .{
        init.command,
        add.command,
        docs.command,
        repl.command,
        cli.complete.command,
    },
});

test {
    std.testing.refAllDecls(docs);
    std.testing.refAllDecls(init);
    std.testing.refAllDecls(add);
    std.testing.refAllDecls(repl);
    std.testing.refAllDecls(@import("flagspec.zig"));
    std.testing.refAllDecls(@import("templates.zig"));
    std.testing.refAllDecls(@import("project.zig"));
}
