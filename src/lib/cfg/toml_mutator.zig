const std = @import("std");

const Self = @This();
/// Mutates or inserts a key value in TOML content while preserving user comments and formatting
pub fn setValue(
    allocator: std.mem.Allocator,
    toml_content: []const u8,
    key: []const u8,
    new_val: []const u8,
) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    var it = std.mem.splitScalar(u8, toml_content, '\n');
    var replaced = false;

    while (it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \r\t");
        if (!replaced and !std.mem.startsWith(u8, trimmed, "#")) {
            if (std.mem.startsWith(u8, trimmed, key)) {
                const after_key = trimmed[key.len..];
                if (after_key.len == 0 or after_key[0] == ' ' or after_key[0] == '=') {
                    // Preserve trailing comments if present
                    var comment: []const u8 = "";
                    if (std.mem.indexOfScalar(u8, raw_line, '#')) |c_idx| {
                        comment = raw_line[c_idx..];
                    }

                    if (comment.len > 0) {
                        const s = try std.fmt.allocPrint(allocator, "{s} = {s}  {s}\n", .{ key, new_val, comment });
                        defer allocator.free(s);
                        try list.appendSlice(allocator, s);
                    } else {
                        const s = try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ key, new_val });
                        defer allocator.free(s);
                        try list.appendSlice(allocator, s);
                    }
                    replaced = true;
                    continue;
                }
            }
        }
        const s = try std.fmt.allocPrint(allocator, "{s}\n", .{raw_line});
        defer allocator.free(s);
        try list.appendSlice(allocator, s);
    }

    if (!replaced) {
        // Append to bottom
        const s = try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ key, new_val });
        defer allocator.free(s);
        try list.appendSlice(allocator, s);
    }

    return try list.toOwnedSlice(allocator);
}
