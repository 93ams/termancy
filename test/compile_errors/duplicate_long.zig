//! Must not compile: two flags with one long name.

const cli = @import("cli");

const Flags = struct {
    port: u16 = 0,
    other: u16 = 0,
    pub const meta = .{ .other = .{ .name = "port" } };
};

const bad = cli.command(.{ .name = "app", .flags = Flags });

comptime {
    _ = bad;
}
