//! SSH's data types (RFC 4251, section 5): bytes, booleans, 32-bit integers, strings
//! (length-prefixed), name lists, and multiple-precision integers, read from a message and
//! written into one.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{Malformed};

/// Reads values from the front of a message.
pub const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn byte(r: *Reader) Error!u8 {
        if (r.index >= r.bytes.len) return error.Malformed;
        r.index += 1;
        return r.bytes[r.index - 1];
    }

    pub fn boolean(r: *Reader) Error!bool {
        return try r.byte() != 0;
    }

    pub fn int(r: *Reader) Error!u32 {
        const b = try r.take(4);
        return std.mem.readInt(u32, b[0..4], .big);
    }

    pub fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.bytes.len - r.index < n) return error.Malformed;
        r.index += n;
        return r.bytes[r.index - n .. r.index];
    }

    pub fn string(r: *Reader) Error![]const u8 {
        return r.take(try r.int());
    }

    /// A multiple-precision integer's magnitude, leading zeros dropped; negative ones are
    /// malformed (SSH never sends them where this is used).
    pub fn mpint(r: *Reader) Error![]const u8 {
        const s = try r.string();
        if (s.len > 0 and s[0] & 0x80 != 0) return error.Malformed;
        var i: usize = 0;
        while (i < s.len and s[i] == 0) i += 1;
        return s[i..];
    }

    pub fn rest(r: *Reader) []const u8 {
        defer r.index = r.bytes.len;
        return r.bytes[r.index..];
    }

    pub fn done(r: *const Reader) bool {
        return r.index == r.bytes.len;
    }
};

/// Whether the comma-separated `list` names `name`.
pub fn listHas(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// The first of the client's names (`client`, in its order of preference) the server also
/// has, as RFC 4253 section 7.1 chooses.
pub fn negotiate(client: []const u8, server: []const []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, client, ',');
    while (it.next()) |name| for (server) |s| if (std.mem.eql(u8, s, name)) return s;
    return null;
}

/// Builds a message.
pub const Builder = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.list.deinit(b.gpa);
    }

    pub fn bytes(b: *const Builder) []const u8 {
        return b.list.items;
    }

    pub fn byte(b: *Builder, v: u8) Allocator.Error!void {
        try b.list.append(b.gpa, v);
    }

    pub fn boolean(b: *Builder, v: bool) Allocator.Error!void {
        try b.byte(@intFromBool(v));
    }

    pub fn int(b: *Builder, v: u32) Allocator.Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .big);
        try b.list.appendSlice(b.gpa, &buf);
    }

    pub fn raw(b: *Builder, v: []const u8) Allocator.Error!void {
        try b.list.appendSlice(b.gpa, v);
    }

    pub fn string(b: *Builder, v: []const u8) Allocator.Error!void {
        try b.int(@intCast(v.len));
        try b.raw(v);
    }

    /// A name list from names.
    pub fn names(b: *Builder, list: []const []const u8) Allocator.Error!void {
        var len: usize = 0;
        for (list, 0..) |n, i| len += n.len + @intFromBool(i > 0);
        try b.int(@intCast(len));
        for (list, 0..) |n, i| {
            if (i > 0) try b.byte(',');
            try b.raw(n);
        }
    }

    /// An unsigned big-endian magnitude as an mpint: leading zeros dropped, a zero byte
    /// added when the top bit is set.
    pub fn mpint(b: *Builder, magnitude: []const u8) Allocator.Error!void {
        var m = magnitude;
        while (m.len > 0 and m[0] == 0) m = m[1..];
        const pad = m.len > 0 and m[0] & 0x80 != 0;
        try b.int(@intCast(m.len + @intFromBool(pad)));
        if (pad) try b.byte(0);
        try b.raw(m);
    }
};

const testing = std.testing;

test "round trip" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.byte(5);
    try b.boolean(true);
    try b.int(0xdeadbeef);
    try b.string("ssh-userauth");
    try b.names(&.{ "a", "bc" });
    try b.mpint(&.{ 0, 0, 0x80, 1 });
    try b.mpint(&.{ 0, 0x7f });
    var r: Reader = .init(b.bytes());
    try testing.expectEqual(5, try r.byte());
    try testing.expect(try r.boolean());
    try testing.expectEqual(0xdeadbeef, try r.int());
    try testing.expectEqualStrings("ssh-userauth", try r.string());
    try testing.expectEqualStrings("a,bc", try r.string());
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 3, 0, 0x80, 1 }, r.bytes[r.index..][0..7]);
    try testing.expectEqualSlices(u8, &.{ 0x80, 1 }, try r.mpint());
    try testing.expectEqualSlices(u8, &.{0x7f}, try r.mpint());
    try testing.expect(r.done());
    try testing.expectError(error.Malformed, r.byte());
}

test negotiate {
    try testing.expectEqualStrings("b", negotiate("x,b,a", &.{ "a", "b" }).?);
    try testing.expectEqual(null, negotiate("x,y", &.{ "a", "b" }));
    try testing.expect(listHas("a,kex-strict-c-v00@openssh.com", "kex-strict-c-v00@openssh.com"));
}
