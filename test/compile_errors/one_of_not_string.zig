//! Must not compile: `.oneOf` on a field that is not a string.

const field = @import("field");

const Flags = struct { level: u8 = 1 };

const Specs = field.Set(.{field.Spec(Flags){ .fields = .{
    .level = .{ .checks = &.{.oneOf(&.{ "1", "2" })} },
} }});

comptime {
    _ = Specs;
}
