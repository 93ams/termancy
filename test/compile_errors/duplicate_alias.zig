//! Must not compile: an alias that another subcommand also has.

const cli = @import("cli");

const bad = cli.command(.{
    .name = "app",
    .subcommands = .{
        cli.command(.{ .name = "remove", .aliases = &.{"rm"} }),
        cli.command(.{ .name = "rmdir", .aliases = &.{"rm"} }),
    },
});

comptime {
    _ = bad;
}
