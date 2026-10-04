const std = @import("std");

pub const WalRecord = struct {
    op: enum(u8) { put = 1, delete = 2 },
    key: []const u8,
    value: []const u8 = "",
};

pub const WorkspaceStore = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorkspaceStore {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkspaceStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn put(self: *WorkspaceStore, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        if (self.map.fetchPut(k, v)) |old| {
            if (old) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        } else |_| {}
    }

    pub fn get(self: WorkspaceStore, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn delete(self: *WorkspaceStore, key: []const u8) void {
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }
};
