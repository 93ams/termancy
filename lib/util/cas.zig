const std = @import("std");

pub const CasStore = struct {
    cache_dir: []const u8,

    pub fn init(cache_dir: []const u8) CasStore {
        return .{ .cache_dir = cache_dir };
    }

    pub fn computeKey(cmd_name: []const u8, args_repr: []const u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(cmd_name);
        hasher.update("::");
        hasher.update(args_repr);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }

    pub fn formatKeyHex(key: [32]u8, buf: *[64]u8) []const u8 {
        buf.* = std.fmt.bytesToHex(key, .lower);
        return buf;
    }
};
