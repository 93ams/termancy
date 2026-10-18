//! Must not compile: a handler whose first parameter is not `*cli.Context`.

const cli = @import("cli");

fn run(_: u32) !void {}

const bad = cli.command(.{ .name = "app", .run = run });

comptime {
    _ = bad;
}
