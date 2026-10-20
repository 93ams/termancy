//! Must not compile: two flags with one short name, one local and one persistent.

const cli = @import("cli");
const field = @import("field");

const bad = cli.command(.{
    .name = "app",
    .flags = cli.flags(struct { port: u16 = 0 }, field.none, .{ .fields = .{
        .port = .{ .short = 'p' },
    } }),
    .persistent_flags = cli.flags(struct { profile: []const u8 = "" }, field.none, .{ .fields = .{
        .profile = .{ .short = 'p' },
    } }),
});

comptime {
    _ = bad;
}
