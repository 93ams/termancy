//! Must not compile: a `meta` entry naming no field.

const cli = @import("cli");

const Flags = struct {
    port: u16 = 0,
    pub const meta = .{ .prot = .{ .short = 'p' } };
};

const bad = cli.command(.{ .name = "app", .flags = Flags });

comptime {
    _ = bad;
}
