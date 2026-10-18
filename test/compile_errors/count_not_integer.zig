//! Must not compile: `.count` on a field that is not an integer.

const cli = @import("cli");

const Flags = struct {
    verbose: bool = false,
    pub const meta = .{ .verbose = .{ .count = true } };
};

const bad = cli.command(.{ .name = "app", .flags = Flags });

comptime {
    _ = bad;
}
