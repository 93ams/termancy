//! Must not compile: a required positional after an optional one.

const cli = @import("cli");

const Args = struct {
    first: ?[]const u8 = null,
    second: []const u8,
};

fn run(_: *cli.Context, _: Args) !void {}

const bad = cli.command(.{ .name = "app", .args = Args, .run = run });

comptime {
    _ = bad;
}
