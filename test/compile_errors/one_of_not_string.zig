//! Must not compile: `.one_of` on a field that is not a string.

const cli = @import("cli");

const Flags = struct {
    level: u8 = 1,
    pub const meta = .{ .level = .{ .one_of = &[_][]const u8{ "1", "2" } } };
};

fn run(_: *cli.Context, _: Flags) !void {}

const bad = cli.command(.{ .name = "app", .flags = Flags, .run = run });

comptime {
    _ = bad;
}
