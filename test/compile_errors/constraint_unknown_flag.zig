//! Must not compile: a flag group naming a field the struct does not have.

const cli = @import("cli");
const field = @import("field");

const Flags = struct { json: bool = false, yaml: bool = false };

const bad = cli.command(.{
    .name = "app",
    .flags = cli.flags(Flags, field.none, .{ .exclusive = &.{&.{ .json, .yml }} }),
});

comptime {
    _ = bad;
}
