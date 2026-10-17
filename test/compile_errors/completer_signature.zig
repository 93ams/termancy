//! Must not compile: a completer without the prefix parameter.

const cli = @import("cli");

const Flags = struct {
    color: []const u8 = "red",
    pub const meta = .{ .color = .{ .complete = completeColor } };
};

// The prefix parameter is missing.
fn completeColor(ctx: *cli.Context) ![]const cli.Candidate {
    _ = ctx;
    return &.{};
}

fn run(ctx: *cli.Context, flags: Flags) !void {
    _ = ctx;
    _ = flags;
}

pub const root = cli.command(.{ .name = "app", .flags = Flags, .run = run });

comptime {
    _ = root;
}
