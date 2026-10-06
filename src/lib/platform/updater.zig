const std = @import("std");
const builtin = @import("builtin");

pub const SelfUpdater = struct {
    pub fn updateBinary(io: std.Io, exe_path: []const u8, new_binary_bytes: []const u8) !void {
        var old_path_buf: [512]u8 = undefined;
        const old_path = try std.fmt.bufPrint(&old_path_buf, "{s}.old", .{exe_path});

        // 1. Move current binary to .old
        std.Io.Dir.cwd().deleteFile(io, old_path) catch {};
        try std.Io.Dir.cwd().rename(exe_path, std.Io.Dir.cwd(), old_path, io);

        // 2. Write new binary to the original path
        const new_file = try std.Io.Dir.cwd().createFile(io, exe_path, .{ .truncate = true });
        defer new_file.close(io);
        try new_file.writePositionalAll(io, new_binary_bytes, 0);
    }
};
