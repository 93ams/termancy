//! Must not compile: a flag whose type is a pointer to a struct.

const cli = @import("cli");

const Point = struct { x: i32 = 0, y: i32 = 0 };

const bad = cli.command(.{
    .name = "app",
    .flags = struct { origin: *const Point = &.{} },
});

comptime {
    _ = bad;
}
