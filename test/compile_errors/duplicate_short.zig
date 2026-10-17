//! Must not compile: two flags with one short name, one local and one persistent.

const cli = @import("cli");

const bad = cli.command(.{
    .name = "app",
    .flags = struct {
        port: u16 = 0,
        pub const meta = .{ .port = .{ .short = 'p' } };
    },
    .persistent_flags = struct {
        profile: []const u8 = "",
        pub const meta = .{ .profile = .{ .short = 'p' } };
    },
});

comptime {
    _ = bad;
}
