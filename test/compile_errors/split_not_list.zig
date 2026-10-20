//! Must not compile: `.split` on a field that is not a list.

const cli = @import("cli");
const field = @import("field");

const Flags = struct { tag: []const u8 = "" };

const bad = cli.command(.{
    .name = "app",
    .flags = cli.flags(Flags, field.none, .{ .fields = .{ .tag = .{ .split = ',' } } }),
});

comptime {
    _ = bad;
}
