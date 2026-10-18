//! Must not compile: an `.args` field `cli.Command.Args` does not have.

const cli = @import("cli");

const bad = cli.command(.{ .name = "app", .args = .{ .maxx = 1 } });

comptime {
    _ = bad;
}
