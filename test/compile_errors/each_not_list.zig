//! Must not compile: `.each` on a field that is not a list.

const field = @import("field");

const Flags = struct { port: u16 = 0 };

const Specs = field.Set(.{field.Spec(Flags){ .fields = .{
    .port = .{ .each = &.{.min(1)} },
} }});

comptime {
    _ = Specs.of(Flags);
}
