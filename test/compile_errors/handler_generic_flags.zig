//! Must not compile: a handler whose flags parameter is `anytype`.

const cli = @import("cli");

fn run(_: *cli.Context, _: anytype) !void {}

const bad = cli.command(.{ .name = "app", .run = run });

comptime {
    _ = bad;
}
