//! The dynamic configuration tree. Every format parses to a `Value` and writes from one.
//!
//! Ownership: a `Value` tree is owned by an arena. Functions here that allocate take that
//! arena and never free, so a whole tree is released by releasing its arena. Nothing in a
//! tree may point into memory the arena does not own or that outlives it (string literals
//! are fine).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const path = @import("path.zig");

/// A table keeps its keys in insertion order, which is the order formats write them in.
pub const Table = std.StringArrayHashMapUnmanaged(Value);
/// A tree's array.
pub const Array = std.ArrayList(Value);

/// A configuration tree: what every format parses to and writes from.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: Array,
    table: Table,

    /// Which kind of value.
    pub const Tag = std.meta.Tag(Value);
    /// A table with nothing in it.
    pub const empty_table: Value = .{ .table = .empty };

    /// A noun for messages: "a table", "an integer".
    pub fn describe(tag: Tag) []const u8 {
        return switch (tag) {
            .null => "null",
            .bool => "a boolean",
            .int => "an integer",
            .float => "a float",
            .string => "a string",
            .array => "an array",
            .table => "a table",
        };
    }

    /// Whether the value is a leaf (anything but a table).
    pub fn isLeaf(value: Value) bool {
        return value != .table;
    }

    /// A deep copy into `arena`. Strings are copied too, so the result shares nothing with
    /// `value`.
    pub fn clone(value: Value, arena: Allocator) Allocator.Error!Value {
        return switch (value) {
            .null, .bool, .int, .float => value,
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .array => |a| blk: {
                var copy: Array = try .initCapacity(arena, a.items.len);
                for (a.items) |item| copy.appendAssumeCapacity(try item.clone(arena));
                break :blk .{ .array = copy };
            },
            .table => |t| blk: {
                var copy: Table = .empty;
                try copy.ensureTotalCapacity(arena, t.count());
                var it = t.iterator();
                while (it.next()) |entry| {
                    const key = try arena.dupe(u8, entry.key_ptr.*);
                    copy.putAssumeCapacityNoClobber(key, try entry.value_ptr.clone(arena));
                }
                break :blk .{ .table = copy };
            },
        };
    }

    /// Structural equality. Tables compare as unordered maps; floats compare by value, so
    /// `nan` is never equal to itself.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .bool => |x| x == b.bool,
            .int => |x| x == b.int,
            .float => |x| x == b.float,
            .string => |x| std.mem.eql(u8, x, b.string),
            .array => |x| blk: {
                if (x.items.len != b.array.items.len) break :blk false;
                for (x.items, b.array.items) |l, r| {
                    if (!l.eql(r)) break :blk false;
                }
                break :blk true;
            },
            .table => |x| blk: {
                if (x.count() != b.table.count()) break :blk false;
                var it = x.iterator();
                while (it.next()) |entry| {
                    const other = b.table.get(entry.key_ptr.*) orelse break :blk false;
                    if (!entry.value_ptr.eql(other)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// The value at `key_path`, or null when any segment is missing or the path is
    /// malformed. A numeric segment indexes an array.
    pub fn lookup(value: Value, key_path: []const u8) ?Value {
        var current = value;
        var it = path.iterate(key_path);
        while (it.next() catch return null) |segment| {
            current = child(current, segment) orelse return null;
        }
        return current;
    }

    fn child(parent: Value, segment: path.Iterator.Segment) ?Value {
        switch (parent) {
            .table => |t| {
                if (!segment.quoted or std.mem.indexOfScalar(u8, segment.text, '\\') == null) {
                    return t.get(segment.text);
                }
                // A quoted segment with escapes is rare; compare unescaped bytes in place.
                var it = t.iterator();
                while (it.next()) |entry| {
                    if (escapedEql(segment.text, entry.key_ptr.*)) return entry.value_ptr.*;
                }
                return null;
            },
            .array => |a| {
                if (segment.quoted) return null;
                const index = std.fmt.parseUnsigned(usize, segment.text, 10) catch return null;
                if (index >= a.items.len) return null;
                return a.items[index];
            },
            else => return null,
        }
    }

    /// What `put` can fail with.
    pub const PutError = error{ InvalidPath, NotATable, IndexOutOfRange } || Allocator.Error;

    /// Stores `new` at `key_path`, creating intermediate tables. Replaces whatever was
    /// there. An array segment may index an existing element or append (index == len).
    /// Returns `error.NotATable` when a segment crosses a scalar, and
    /// `error.IndexOutOfRange` for an array index past the end.
    pub fn put(value: *Value, arena: Allocator, key_path: []const u8, new: Value) PutError!void {
        const segments = try path.split(arena, key_path);
        var current = value;
        for (segments, 0..) |segment, i| {
            const last = i + 1 == segments.len;
            current = try childPtrOrCreate(current, arena, segment);
            if (last) current.* = new;
        }
    }

    fn childPtrOrCreate(parent: *Value, arena: Allocator, key: []const u8) PutError!*Value {
        switch (parent.*) {
            .table => |*t| {
                const gop = try t.getOrPut(arena, key);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try arena.dupe(u8, key);
                    gop.value_ptr.* = empty_table;
                }
                return gop.value_ptr;
            },
            .array => |*a| {
                const index = std.fmt.parseUnsigned(usize, key, 10) catch return error.NotATable;
                if (index < a.items.len) return &a.items[index];
                if (index > a.items.len) return error.IndexOutOfRange;
                try a.append(arena, empty_table);
                return &a.items[index];
            },
            else => return error.NotATable,
        }
    }

    /// Removes the value at `key_path`. Returns whether something was removed. Tables keep
    /// the order of their remaining keys.
    pub fn remove(value: *Value, key_path: []const u8) bool {
        var it = path.iterate(key_path);
        var parent: *Value = value;
        var segment = (it.next() catch return false) orelse return false;
        while (it.next() catch return false) |next_segment| {
            parent = childPtr(parent, segment) orelse return false;
            segment = next_segment;
        }
        switch (parent.*) {
            .table => |*t| {
                const key = keyOf(t.*, segment) orelse return false;
                return t.orderedRemove(key);
            },
            .array => |*a| {
                if (segment.quoted) return false; // As in `lookup`: quotes name a table key.
                const index = std.fmt.parseUnsigned(usize, segment.text, 10) catch return false;
                if (index >= a.items.len) return false;
                _ = a.orderedRemove(index);
                return true;
            },
            else => return false,
        }
    }

    /// Sorts every table in `value` by key, recursively, tables inside arrays too.
    pub fn sortKeys(value: *Value) void {
        switch (value.*) {
            .table => |*table| {
                const Context = struct {
                    keys: []const []const u8,
                    pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                        return std.mem.lessThan(u8, c.keys[a], c.keys[b]);
                    }
                };
                table.sort(Context{ .keys = table.keys() });
                for (table.values()) |*entry| entry.sortKeys();
            },
            .array => |*array| for (array.items) |*item| item.sortKeys(),
            else => {},
        }
    }

    fn childPtr(parent: *Value, segment: path.Iterator.Segment) ?*Value {
        switch (parent.*) {
            .table => |*t| return t.getPtr(keyOf(t.*, segment) orelse return null),
            .array => |*a| {
                if (segment.quoted) return null;
                const index = std.fmt.parseUnsigned(usize, segment.text, 10) catch return null;
                if (index >= a.items.len) return null;
                return &a.items[index];
            },
            else => return null,
        }
    }

    fn keyOf(t: Table, segment: path.Iterator.Segment) ?[]const u8 {
        var it = t.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const matches = if (segment.quoted)
                escapedEql(segment.text, key)
            else
                std.mem.eql(u8, segment.text, key);
            if (matches) return key;
        }
        return null;
    }

    /// Merges `src` into `dst`: tables merge key by key, recursively; anything else in
    /// `src` replaces what is in `dst`. `src` is deep-copied into `arena`, so later changes
    /// to `dst` never reach `src`.
    pub fn merge(dst: *Value, arena: Allocator, src: Value) Allocator.Error!void {
        if (dst.* != .table or src != .table) {
            dst.* = try src.clone(arena);
            return;
        }
        var it = src.table.iterator();
        while (it.next()) |entry| {
            const gop = try dst.table.getOrPut(arena, entry.key_ptr.*);
            if (gop.found_existing) {
                try merge(gop.value_ptr, arena, entry.value_ptr.*);
            } else {
                gop.key_ptr.* = try arena.dupe(u8, entry.key_ptr.*);
                gop.value_ptr.* = try entry.value_ptr.clone(arena);
            }
        }
    }

    /// Appends the path of every leaf under `value` to `out`, depth first, in table order.
    /// Arrays are leaves. An empty table is reported as a leaf so that it is not lost.
    pub fn leafPaths(
        value: Value,
        arena: Allocator,
        prefix: []const u8,
        out: *std.ArrayList([]const u8),
    ) Allocator.Error!void {
        switch (value) {
            .table => |t| {
                if (t.count() == 0 and prefix.len > 0) {
                    try out.append(arena, prefix);
                    return;
                }
                var it = t.iterator();
                while (it.next()) |entry| {
                    const child_path = try path.join(arena, prefix, entry.key_ptr.*);
                    try leafPaths(entry.value_ptr.*, arena, child_path, out);
                }
            },
            else => if (prefix.len > 0) try out.append(arena, prefix),
        }
    }

    /// Writes the value as a compact, JSON-like single line. For messages and debugging; the
    /// codecs are the real writers.
    pub fn format(value: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (value) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writeFloat(writer, f),
            .string => |s| try writer.writeAll(s),
            .array => |a| {
                try writer.writeByte('[');
                for (a.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format(writer);
                }
                try writer.writeByte(']');
            },
            .table => |t| {
                try writer.writeByte('{');
                var it = t.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try writer.print("{s} = {f}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                try writer.writeByte('}');
            },
        }
    }
};

/// Writes a float so that it reads back as a float: always with a `.` or an exponent, and
/// `inf`/`-inf`/`nan` spelled out.
pub fn writeFloat(writer: *std.Io.Writer, f: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(f)) return writer.writeAll("nan");
    if (std.math.isInf(f)) return writer.writeAll(if (f > 0) "inf" else "-inf");
    // Decimal notation for everyday magnitudes, scientific outside them: `{d}` of `1e300`
    // would be 301 digits. Scientific output of an f64 fits in 32 bytes.
    const magnitude = @abs(f);
    const scientific = magnitude != 0 and (magnitude < 1e-6 or magnitude >= 1e21);
    var buffer: [64]u8 = undefined;
    const text = if (scientific)
        std.fmt.bufPrint(&buffer, "{e}", .{f}) catch unreachable // 64 bytes fit any `{e}` f64.
    else
        // Below 1e21 there are at most 21 integer digits, and the shortest round-trip
        // fraction of a value at or above 1e-6 is short, so this fits too.
        std.fmt.bufPrint(&buffer, "{d}", .{f}) catch unreachable;
    try writer.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try writer.writeAll(".0");
}

fn escapedEql(escaped: []const u8, plain: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < escaped.len) : (i += 1) {
        if (escaped[i] == '\\' and i + 1 < escaped.len) i += 1;
        if (j >= plain.len or plain[j] != escaped[i]) return false;
        j += 1;
    }
    return j == plain.len;
}

const testing = std.testing;

fn testTree(arena: Allocator) !Value {
    var root: Value = .empty_table;
    try root.put(arena, "server.host", .{ .string = "localhost" });
    try root.put(arena, "server.port", .{ .int = 8080 });
    try root.put(arena, "debug", .{ .bool = true });
    return root;
}

test "put and lookup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try testTree(arena.allocator());
    try testing.expectEqual(8080, root.lookup("server.port").?.int);
    try testing.expectEqualStrings("localhost", root.lookup("server.host").?.string);
    try testing.expectEqual(null, root.lookup("server.missing"));
    try testing.expectEqual(null, root.lookup("debug.x"));
    try testing.expectEqual(null, root.lookup("bad..path"));
}

test "put across a scalar fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var root = try testTree(arena.allocator());
    try testing.expectError(error.NotATable, root.put(arena.allocator(), "debug.x", .null));
}

test "arrays index and append" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "list", .{ .array = .empty });
    try root.put(a, "list.0", .{ .int = 1 });
    try root.put(a, "list.1", .{ .int = 2 });
    try root.put(a, "list.0", .{ .int = 3 });
    try testing.expectEqual(3, root.lookup("list.0").?.int);
    try testing.expectEqual(2, root.lookup("list.1").?.int);
    try testing.expectError(error.IndexOutOfRange, root.put(a, "list.5", .null));
    try testing.expect(root.remove("list.0"));
    try testing.expectEqual(2, root.lookup("list.0").?.int);
}

test "remove keeps order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var root = try testTree(arena.allocator());
    try testing.expect(root.remove("server.host"));
    try testing.expect(!root.remove("server.host"));
    try testing.expect(!root.remove("nope.nope"));
    try testing.expectEqual(null, root.lookup("server.host"));
    try testing.expectEqualStrings("server", root.table.keys()[0]);
}

test "quoted segments address dotted keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "hosts.\"a.example\"", .{ .int = 1 });
    try testing.expectEqual(1, root.lookup("hosts.\"a.example\"").?.int);
    try testing.expectEqual(1, root.table.get("hosts").?.table.count());
    var leaves: std.ArrayList([]const u8) = .empty;
    try root.leafPaths(a, "", &leaves);
    try testing.expectEqualStrings("hosts.\"a.example\"", leaves.items[0]);
}

test "merge is deep and copies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base = try testTree(a);
    var over: Value = .empty_table;
    try over.put(a, "server.port", .{ .int = 9090 });
    try over.put(a, "extra", .{ .string = "x" });
    try base.merge(a, over);
    try testing.expectEqual(9090, base.lookup("server.port").?.int);
    try testing.expectEqualStrings("localhost", base.lookup("server.host").?.string);
    try testing.expectEqualStrings("x", base.lookup("extra").?.string);
    try base.put(a, "server.port", .{ .int = 1 });
    try testing.expectEqual(9090, over.lookup("server.port").?.int);
}

test "eql and clone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tree = try testTree(arena.allocator());
    const copy = try tree.clone(arena.allocator());
    try testing.expect(tree.eql(copy));
    var other = copy;
    try other.put(arena.allocator(), "debug", .{ .bool = false });
    try testing.expect(!tree.eql(other));
}

test "leafPaths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try testTree(a);
    try tree.put(a, "empty", .empty_table);
    var leaves: std.ArrayList([]const u8) = .empty;
    try tree.leafPaths(a, "", &leaves);
    const expected = [_][]const u8{ "server.host", "server.port", "debug", "empty" };
    try testing.expectEqual(expected.len, leaves.items.len);
    for (expected, leaves.items) |e, got| try testing.expectEqualStrings(e, got);
}

test "format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tree = try testTree(arena.allocator());
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{tree});
    try testing.expectEqualStrings(
        "{server = {host = localhost, port = 8080}, debug = true}",
        writer.buffered(),
    );
}

test writeFloat {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeFloat(&writer, 1.0);
    try writer.writeByte(' ');
    try writeFloat(&writer, 2.5);
    try writer.writeByte(' ');
    try writeFloat(&writer, -std.math.inf(f64));
    try writer.writeByte(' ');
    try writeFloat(&writer, 1e300);
    try writer.writeByte(' ');
    try writeFloat(&writer, 5e-324);
    try testing.expectEqualStrings("1.0 2.5 -inf 1e300 5e-324", writer.buffered());
}

test "remove from arrays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "list", .{ .array = .empty });
    try root.put(a, "list.0.name", .{ .string = "x" });
    try root.put(a, "list.1", .{ .int = 2 });
    try root.put(a, "list.2", .{ .int = 3 });
    try testing.expect(!root.remove("list.3"));
    try testing.expect(!root.remove("list.x"));
    try testing.expect(!root.remove("list.-1"));
    try testing.expect(!root.remove("list.0.missing"));
    try testing.expect(!root.remove("list.1.deeper"));
    // A quoted segment names a table key, never an index: `lookup` agrees.
    try testing.expectEqual(null, root.lookup("list.\"0\""));
    try testing.expect(!root.remove("list.\"0\""));
    try testing.expect(!root.remove("list.\"0\".name"));
    try testing.expect(root.remove("list.0.name"));
    try testing.expectEqual(0, root.lookup("list.0").?.table.count());
    try testing.expect(root.remove("list.2"));
    try testing.expect(root.remove("list.0"));
    try testing.expectEqual(1, root.lookup("list").?.array.items.len);
    try testing.expectEqual(2, root.lookup("list.0").?.int);
}

test "remove rejects malformed paths and scalar roots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var root = try testTree(arena.allocator());
    try testing.expect(!root.remove(""));
    try testing.expect(!root.remove("server..host"));
    try testing.expect(!root.remove("server.host."));
    try testing.expect(!root.remove("\"server"));
    var scalar: Value = .{ .int = 1 };
    try testing.expect(!scalar.remove("a"));
    try testing.expectEqual(2, root.lookup("server").?.table.count());
}

test "keys with escaped quotes and backslashes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    const key_path = "t.\"say \\\"hi\\\" \\\\ ok\"";
    try root.put(a, key_path, .{ .int = 1 });
    const t = root.lookup("t").?.table;
    try testing.expectEqualStrings("say \"hi\" \\ ok", t.keys()[0]);
    try testing.expectEqual(1, root.lookup(key_path).?.int);
    var leaves: std.ArrayList([]const u8) = .empty;
    try root.leafPaths(a, "", &leaves);
    try testing.expectEqualStrings(key_path, leaves.items[0]);
    try testing.expect(root.remove(key_path));
    try testing.expectEqual(0, root.lookup("t").?.table.count());
    // The empty key is addressable too.
    try root.put(a, "t.\"\"", .{ .bool = true });
    try testing.expectEqual(true, root.lookup("t.\"\"").?.bool);
    try testing.expectEqual(true, root.lookup("t").?.table.get("").?.bool);
}

test "lookup through scalars, arrays, and bad indices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: Value = .empty_table;
    try root.put(a, "list", .{ .array = .empty });
    try root.put(a, "list.0", .{ .string = "x" });
    try testing.expectEqual(null, root.lookup("list.1"));
    try testing.expectEqual(null, root.lookup("list.x"));
    try testing.expectEqual(null, root.lookup("list.0.x"));
    try testing.expectEqual(null, root.lookup("list.99999999999999999999999"));
    try testing.expectEqualStrings(
        "x",
        (Value{ .array = root.lookup("list").?.array }).lookup("0").?.string,
    );
    try testing.expectError(error.NotATable, root.put(a, "list.x", .null));
    try testing.expectError(error.NotATable, root.put(a, "list.0.y", .null));
    try testing.expectError(error.InvalidPath, root.put(a, "list..y", .null));
}

test "merge replaces across kinds and keeps disjoint keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dst = try testTree(a);
    var src: Value = .empty_table;
    try src.put(a, "server", .{ .string = "flat" });
    try src.put(a, "debug.nested", .{ .int = 1 });
    try dst.merge(a, src);
    try testing.expectEqualStrings("flat", dst.lookup("server").?.string);
    try testing.expectEqual(1, dst.lookup("debug.nested").?.int);
    // A non-table source replaces the whole destination.
    try dst.merge(a, .{ .int = 7 });
    try testing.expectEqual(7, dst.int);
    // Arrays replace rather than concatenate.
    var x: Value = .empty_table;
    try x.put(a, "l", .{ .array = .empty });
    try x.put(a, "l.0", .{ .int = 1 });
    try x.put(a, "l.1", .{ .int = 2 });
    var y: Value = .empty_table;
    try y.put(a, "l", .{ .array = .empty });
    try y.put(a, "l.0", .{ .int = 3 });
    try x.merge(a, y);
    try testing.expectEqual(1, x.lookup("l").?.array.items.len);
}

test "eql compares tables as unordered maps and floats by value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x: Value = .empty_table;
    try x.put(a, "a", .{ .int = 1 });
    try x.put(a, "b", .{ .int = 2 });
    var y: Value = .empty_table;
    try y.put(a, "b", .{ .int = 2 });
    try y.put(a, "a", .{ .int = 1 });
    try testing.expect(x.eql(y));
    try y.put(a, "c", .null);
    try testing.expect(!x.eql(y));
    try testing.expect(!(Value{ .int = 1 }).eql(.{ .float = 1 }));
    try testing.expect((Value{ .float = 0.0 }).eql(.{ .float = -0.0 }));
    try testing.expect(!(Value{ .float = std.math.nan(f64) }).eql(.{ .float = std.math.nan(f64) }));
    try testing.expect((@as(Value, .null)).eql(.null));
}

test "clone shares no strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text = "abc".*;
    var tree: Value = .empty_table;
    try tree.put(a, "s", .{ .string = &text });
    try tree.put(a, "l", .{ .array = .empty });
    try tree.put(a, "l.0", .{ .string = &text });
    const copy = try tree.clone(a);
    text[0] = 'X';
    try testing.expectEqualStrings("abc", copy.lookup("s").?.string);
    try testing.expectEqualStrings("abc", copy.lookup("l.0").?.string);
}

test "describe and isLeaf" {
    try testing.expectEqualStrings("a table", Value.describe(.table));
    try testing.expectEqualStrings("an integer", Value.describe(.int));
    try testing.expect(!Value.empty_table.isLeaf());
    try testing.expect((Value{ .array = .empty }).isLeaf());
}

test "writeFloat switches notation at the documented bounds" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for ([_]f64{ 1e-6, 9.99e-7, 1e20, 1e21, -0.0, std.math.nan(f64), 123.0 }) |f| {
        try writeFloat(&writer, f);
        try writer.writeByte(' ');
    }
    try testing.expectEqualStrings(
        "0.000001 9.99e-7 100000000000000000000.0 1e21 -0.0 nan 123.0 ",
        writer.buffered(),
    );
}
