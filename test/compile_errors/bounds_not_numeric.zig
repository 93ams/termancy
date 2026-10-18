//! Must not compile: `.min` on a field that is not a number.

const cli = @import("cli");

const Flags = struct {
    name: []const u8 = "x",
    pub const meta = .{ .name = .{ .min = 1 } };
};

fn run(_: *cli.Context, _: Flags) !void {}

const bad = cli.command(.{ .name = "app", .flags = Flags, .run = run });

comptime {
    _ = bad;
}
