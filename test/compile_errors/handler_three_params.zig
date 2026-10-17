//! Must not compile: a handler with three parameters, the third not an `.args` struct.

const cli = @import("cli");

const Flags = struct { force: bool = false };

fn run(_: *cli.Context, _: Flags, _: u32) !void {}

const bad = cli.command(.{ .name = "app", .run = run });

comptime {
    _ = bad;
}
