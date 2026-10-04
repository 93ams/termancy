const std = @import("std");

pub const EmbeddedAsset = struct {
    path: []const u8,
    content: []const u8,
    mime: []const u8 = "application/octet-stream",
};

pub const VirtualFileSystem = struct {
    assets: []const EmbeddedAsset,

    pub fn init(comptime assets: []const EmbeddedAsset) VirtualFileSystem {
        return .{ .assets = assets };
    }

    pub fn get(self: VirtualFileSystem, path: []const u8) ?[]const u8 {
        for (self.assets) |asset| {
            if (std.mem.eql(u8, asset.path, path)) {
                return asset.content;
            }
        }
        return null;
    }

    pub fn getAsset(self: VirtualFileSystem, path: []const u8) ?EmbeddedAsset {
        for (self.assets) |asset| {
            if (std.mem.eql(u8, asset.path, path)) {
                return asset;
            }
        }
        return null;
    }

    pub fn extractAll(self: VirtualFileSystem, io: std.Io, target_dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, target_dir);

        for (self.assets) |asset| {
            var full_path_buf: [512]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ target_dir, asset.path });
            if (std.fs.path.dirname(full_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }
            const file = try std.Io.Dir.cwd().createFile(io, full_path, .{ .truncate = true });
            defer file.close(io);
            try file.writePositionalAll(io, asset.content, 0);
        }
    }
};
