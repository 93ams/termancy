//! Differences between two trees, leaf by leaf.
//!
//! ```zig
//! for (try cfg.diff(arena, old, new)) |change| switch (change.kind()) {
//!     .added => ..., // change.new.?
//!     .removed => ..., // change.old.?
//!     .changed => ..., // both
//! };
//! ```
//!
//! Leaves are those of `Value.leafPaths`: scalars, arrays (compared whole), and empty
//! tables. A key that is a leaf on one side and a table on the other shows up as the leaf
//! removed (or added) and each leaf of the table added (or removed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

/// One leaf that differs between two trees.
pub const Change = struct {
    /// The leaf's path, as `Value.leafPaths` spells it.
    key: []const u8,
    /// The value in the old tree; null when the key was added.
    old: ?Value,
    /// The value in the new tree; null when the key was removed.
    new: ?Value,

    /// Whether the leaf was added, removed, or changed.
    pub const Kind = enum { added, removed, changed };

    /// Which kind of change this is.
    pub fn kind(change: Change) Kind {
        if (change.old == null) return .added;
        if (change.new == null) return .removed;
        return .changed;
    }
};

/// Every leaf that differs between `old` and `new`, sorted by key. The keys live in
/// `arena`; the values point into the trees.
pub fn diff(arena: Allocator, old: Value, new: Value) Allocator.Error![]const Change {
    var old_leaves: std.ArrayList([]const u8) = .empty;
    try old.leafPaths(arena, "", &old_leaves);
    var new_leaves: std.ArrayList([]const u8) = .empty;
    try new.leafPaths(arena, "", &new_leaves);

    var new_set: std.StringHashMapUnmanaged(void) = .empty;
    for (new_leaves.items) |key| try new_set.put(arena, key, {});

    var changes: std.ArrayList(Change) = .empty;
    var old_set: std.StringHashMapUnmanaged(void) = .empty;
    for (old_leaves.items) |key| {
        try old_set.put(arena, key, {});
        const before = old.lookup(key).?;
        if (!new_set.contains(key)) {
            try changes.append(arena, .{ .key = key, .old = before, .new = null });
            continue;
        }
        const after = new.lookup(key).?;
        if (before.eql(after)) continue;
        try changes.append(arena, .{ .key = key, .old = before, .new = after });
    }
    for (new_leaves.items) |key| {
        if (old_set.contains(key)) continue;
        try changes.append(arena, .{ .key = key, .old = null, .new = new.lookup(key).? });
    }
    std.mem.sort(Change, changes.items, {}, keyLessThan);
    return changes.items;
}

fn keyLessThan(_: void, a: Change, b: Change) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

const testing = std.testing;
const json = @import("json.zig");

fn parseJson(arena: Allocator, source: []const u8) !Value {
    return json.parse(arena, source, null);
}

test diff {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parseJson(a,
        \\{"server": {"host": "a", "port": 1}, "tags": [1, 2], "gone": true, "same": "x"}
    );
    const new = try parseJson(a,
        \\{"server": {"host": "b", "port": 1}, "tags": [1, 2, 3], "same": "x", "added": null}
    );
    const changes = try diff(a, old, new);
    try testing.expectEqual(4, changes.len);
    try testing.expectEqualStrings("added", changes[0].key);
    try testing.expectEqual(.added, changes[0].kind());
    try testing.expectEqualStrings("gone", changes[1].key);
    try testing.expectEqual(.removed, changes[1].kind());
    try testing.expectEqualStrings("server.host", changes[2].key);
    try testing.expectEqual(.changed, changes[2].kind());
    try testing.expectEqualStrings("b", changes[2].new.?.string);
    try testing.expectEqualStrings("tags", changes[3].key);
}

test "identical trees have no changes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try parseJson(a,
        \\{"a": {"b": [1, {"c": 2}]}, "e": {}}
    );
    try testing.expectEqual(0, (try diff(a, tree, tree)).len);
}

test "a leaf replaced by a table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parseJson(a,
        \\{"a": 1}
    );
    const new = try parseJson(a,
        \\{"a": {"b": 2}}
    );
    const changes = try diff(a, old, new);
    try testing.expectEqual(2, changes.len);
    try testing.expectEqualStrings("a", changes[0].key);
    try testing.expectEqual(.removed, changes[0].kind());
    try testing.expectEqualStrings("a.b", changes[1].key);
    try testing.expectEqual(.added, changes[1].kind());
}

test "keys that need quoting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parseJson(a,
        \\{"hosts": {"a.example": 1}}
    );
    const new = try parseJson(a,
        \\{"hosts": {"a.example": 2}}
    );
    const changes = try diff(a, old, new);
    try testing.expectEqual(1, changes.len);
    try testing.expectEqualStrings("hosts.\"a.example\"", changes[0].key);
    try testing.expectEqual(2, changes[0].new.?.int);
}
