//! Must not compile: `.flags` that is not a struct type.

const cli = @import("cli");

const bad = cli.command(.{ .name = "app", .flags = u8 });

comptime {
    _ = bad;
}
