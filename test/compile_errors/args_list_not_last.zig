//! Must not compile: a list positional that is not the last.

const cli = @import("cli");

const Args = struct {
    files: []const []const u8,
    dest: []const u8,
};

fn run(_: *cli.Context, _: Args) !void {}

const bad = cli.command(.{ .name = "app", .args = Args, .run = run });

comptime {
    _ = bad;
}
