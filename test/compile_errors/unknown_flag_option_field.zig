//! Must not compile: flag options for a field the struct does not have.

const cli = @import("cli");
const field = @import("field");

const Flags = struct {
    port: u16 = 0,
    host: []const u8 = "",
};

const bad = cli.command(.{
    .name = "app",
    .flags = cli.flags(Flags, field.none, .{ .fields = .{ .prot = .{ .short = 'p' } } }),
});

comptime {
    _ = bad;
}
