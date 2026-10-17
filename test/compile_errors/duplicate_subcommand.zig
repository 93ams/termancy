//! Must not compile: two subcommands with one name.

const cli = @import("cli");

const bad = cli.command(.{
    .name = "app",
    .subcommands = .{
        cli.command(.{ .name = "get" }),
        cli.command(.{ .name = "get" }),
    },
});

comptime {
    _ = bad;
}
