const std = @import("std");

pub const ContextManager = struct {
    pub fn getCurrentContext(toml_content: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, toml_content, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (std.mem.startsWith(u8, line, "current_context")) {
                const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const val = std.mem.trim(u8, line[eq_idx + 1 ..], " \r\t\"");
                return val;
            }
        }
        return null;
    }

    /// Atomically rewrite the current_context string in the given TOML content
    pub fn switchContextContent(allocator: std.mem.Allocator, toml_content: []const u8, new_context: []const u8) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(allocator);

        var it = std.mem.splitScalar(u8, toml_content, '\n');
        var replaced = false;

        while (it.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \r\t");
            if (!replaced and std.mem.startsWith(u8, trimmed, "current_context")) {
                const s = try std.fmt.allocPrint(allocator, "current_context = \"{s}\"\n", .{new_context});
                defer allocator.free(s);
                try list.appendSlice(allocator, s);
                replaced = true;
            } else {
                const s = try std.fmt.allocPrint(allocator, "{s}\n", .{raw_line});
                defer allocator.free(s);
                try list.appendSlice(allocator, s);
            }
        }

        if (!replaced) {
            // Prepend if not found
            var prepend = std.ArrayList(u8).empty;
            const s = try std.fmt.allocPrint(allocator, "current_context = \"{s}\"\n", .{new_context});
            defer allocator.free(s);
            try prepend.appendSlice(allocator, s);
            try prepend.appendSlice(allocator, list.items);
            list.deinit(allocator);
            return try prepend.toOwnedSlice(allocator);
        }

        return try list.toOwnedSlice(allocator);
    }
};
