const std = @import("std");

pub const ComptimeConfigRunner = struct {
    pub fn exists(io: std.Io, path: []const u8) bool {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
        f.close(io);
        return true;
    }

    /// Evaluates or extracts JSON configuration from a programmable Zig config file
    pub fn readScriptOrCachedJson(
        allocator: std.mem.Allocator,
        io: std.Io,
        config_path: []const u8,
        fallback_json: []const u8,
    ) ![]const u8 {
        if (!exists(io, config_path)) {
            return try allocator.dupe(u8, fallback_json);
        }

        // Read the config.zig file content
        const f = try std.Io.Dir.cwd().openFile(io, config_path, .{});
        defer f.close(io);

        var buf: [4096]u8 = undefined;
        const bufs = [_][]u8{&buf};
        const n = try f.readStreaming(io, &bufs);

        // If the file defines a json export directly or via comments/blocks
        if (std.mem.indexOf(u8, buf[0..n], "JSON_START")) |start_idx| {
            const after_start = buf[start_idx + "JSON_START".len .. n];
            if (std.mem.indexOf(u8, after_start, "JSON_END")) |end_idx| {
                const json_slice = std.mem.trim(u8, after_start[0..end_idx], " \r\n\t*//");
                return try allocator.dupe(u8, json_slice);
            }
        }

        return try allocator.dupe(u8, fallback_json);
    }
};
