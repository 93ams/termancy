//! Must not compile: two flags with one long name.

const cli = @import("cli");
const field = @import("field");

const Flags = struct {
    port: u16 = 0,
    other: u16 = 0,
};

const bad = cli.command(.{
    .name = "app",
    .flags = cli.flags(Flags, field.none, .{ .fields = .{ .other = .{ .name = "port" } } }),
});

comptime {
    _ = bad;
}
