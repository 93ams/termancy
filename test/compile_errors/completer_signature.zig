//! Must not compile: a completer without the prefix parameter.

const cli = @import("cli");
const field = @import("field");

const Flags = struct { color: []const u8 = "red" };

// The prefix parameter is missing.
fn completeColor(ctx: *cli.Context) ![]const cli.Candidate {
    _ = ctx;
    return &.{};
}

fn run(ctx: *cli.Context, flags: Flags) !void {
    _ = ctx;
    _ = flags;
}

pub const root = cli.command(.{
    .name = "app",
    .flags = cli.flags(Flags, field.none, .{ .fields = .{
        .color = .{ .complete = .from(completeColor) },
    } }),
    .run = run,
});

comptime {
    _ = root;
}
