//! Must not compile: a list of structs as flags, without `.internal`.

const cli = @import("cli");

const Mirror = struct { host: []const u8 = "" };
const Flags = struct { mirrors: []const Mirror = &.{} };

const bad = cli.command(.{ .name = "app", .flags = Flags });

comptime {
    _ = bad;
}
