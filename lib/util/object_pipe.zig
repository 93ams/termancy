const std = @import("std");

const Self = @This();
pub fn pipeRecord(writer: anytype, record: anytype, is_tty: bool) !void {
    if (is_tty) {
        // Render styled human-readable representation
        const T = @TypeOf(record);
        if (@typeInfo(T) == .@"struct") {
            try writer.writeAll("{ ");
            inline for (std.meta.fields(T), 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                const val = @field(record, field.name);
                if (field.type == []const u8 or field.type == []u8) {
                    try writer.print(".{s} = \"{s}\"", .{ field.name, val });
                } else {
                    try writer.print(".{s} = {any}", .{ field.name, val });
                }
            }
            try writer.writeAll(" }\n");
        } else {
            try writer.print("{any}\n", .{record});
        }
    } else {
        // Streaming NDJSON format
        try std.json.fmt(record, .{}).format(writer);
        try writer.writeByte('\n');
    }
}
