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

    /// Duplicates `key` and `value` and stores them, replacing both if `key` is
    /// already present.
    ///
    /// The store owns every key and value it holds, so a replacement frees the
    /// previous key and the previous value exactly once. `std.StringHashMap`
    /// offers no primitive that does this in one step:
    ///
    /// * `fetchPut` returns the *stored* key and still leaves it in the map
    ///   (`std/hash_map.zig:905-910` builds the result from `gop.key_ptr.*`, and
    ///   `:911` assigns only `value_ptr`), so freeing the returned key leaves the
    ///   map holding a freed pointer and leaks the freshly duped key.
    /// * `fetchRemove` + `put` frees safely but rehashes the key and can fail
    ///   out-of-memory *after* the old entry is gone, losing it.
    ///
    /// `getOrPut` is the primitive that works: it finds the slot for `key` and
    /// returns pointers to it, so when the key is already present the two old
    /// allocations are still live while the replacements are installed, and the
    /// assignments below cannot fail.
    ///
    /// Both duplications happen before any mutation, and each carries an
    /// `errdefer`, so if the second dupe or the map's own growth fails, nothing
    /// allocated here is leaked and the store is exactly as it was. `key` and
    /// `value` are borrowed: they are copied before being stored, and remain the
    /// caller's to free.
    ///
    /// Caller guarantees `key` is non-empty; an empty key is a caller bug.
    pub fn put(self: *WorkspaceStore, key: []const u8, value: []const u8) !void {
        std.debug.assert(key.len > 0);

        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);

        const gop = try self.map.getOrPut(k);
        if (gop.found_existing) {
            std.debug.assert(std.mem.eql(u8, gop.key_ptr.*, k));
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.*);
        }
        gop.key_ptr.* = k;
        gop.value_ptr.* = v;
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

// Every `put` on a key already in the map must return the value just stored.
// Exits non-zero on the defect: `put` frees the key the map still holds, so
// `get` hashes freed bytes and misses the entry.
test "WorkspaceStore.put on an existing key returns the new value and keeps one entry" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put("auth.token", "first");
    try store.put("auth.token", "second");

    try std.testing.expectEqual(@as(usize, 1), store.map.count());
    try std.testing.expectEqualStrings("second", store.get("auth.token").?);
}

// The regression test for the use-after-free: update, then read, then `deinit`.
// `std.testing.allocator` reports the leaked newly-duped key and the double free
// of the old key that `deinit` performs.
test "WorkspaceStore.put then get then deinit after an update leaks and double-frees nothing" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put("auth.token", "gho_first");
    try store.put("auth.token", "gho_second");
    try std.testing.expectEqualStrings("gho_second", store.get("auth.token").?);

    store.delete("auth.token");
    try std.testing.expect(store.get("auth.token") == null);
}

// An update whose value equals the stored one must still free exactly one old
// key and one old value: a fix that skips the free when the bytes are equal
// would leak both, and one that frees the new pair would double-free.
test "WorkspaceStore.put of an equal value on an existing key frees the old pair once" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put("env", "staging");
    try store.put("env", "staging");

    try std.testing.expectEqual(@as(usize, 1), store.map.count());
    try std.testing.expectEqualStrings("staging", store.get("env").?);
}

// `putScenario` is the scenario `checkAllAllocationFailures` drives; see below.
fn putScenario(allocator: std.mem.Allocator) !void {
    const Node = struct {
        store: WorkspaceStore,

        fn init(a: std.mem.Allocator) @This() {
            return .{ .store = WorkspaceStore.init(a) };
        }

        fn deinit(node: *@This()) void {
            node.store.deinit();
        }
    };

    var node = Node.init(allocator);
    defer node.deinit();

    try node.store.put("auth.token", "first");
    try std.testing.expectEqualStrings("first", node.store.get("auth.token").?);

    try node.store.put("auth.token", "second-and-longer");
    try std.testing.expectEqualStrings("second-and-longer", node.store.get("auth.token").?);

    node.store.delete("auth.token");
    try std.testing.expect(node.store.get("auth.token") == null);
}

// Fail every allocation point in the scenario, so a partial insert that leaks
// or corrupts the map fails the run.
test "WorkspaceStore.put and delete leak nothing when each allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, putScenario, .{});
}
