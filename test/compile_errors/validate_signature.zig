//! Must not compile: a `validate` without the context parameter.

const cli = @import("cli");

const Flags = struct {
    low: u8 = 0,
    pub fn validate(flags: Flags) !void {
        _ = flags;
    }
};

fn run(_: *cli.Context, _: Flags) !void {}

const bad = cli.command(.{ .name = "app", .flags = Flags, .run = run });

comptime {
    _ = bad;
}
