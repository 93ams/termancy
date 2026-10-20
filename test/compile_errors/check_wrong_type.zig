//! Must not compile: a check of one type on a field of another.

const std = @import("std");
const field = @import("field");

const Flags = struct { port: u16 = 0 };

fn local(host: []const u8, w: *std.Io.Writer) !void {
    if (host.len == 0) return field.fail(w, "is empty", .{});
}

const Specs = field.Set(.{field.Spec(Flags){ .fields = .{
    .port = .{ .checks = &.{.from(local)} },
} }});

comptime {
    _ = Specs;
}
