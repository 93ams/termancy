//! Must not compile: `.min` on a field that is neither a number nor ordered.

const field = @import("field");

const Flags = struct { name: []const u8 = "x" };

const Specs = field.Set(.{field.Spec(Flags){ .fields = .{
    .name = .{ .checks = &.{.min(1)} },
} }});

comptime {
    _ = Specs;
}
