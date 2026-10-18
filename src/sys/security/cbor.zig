//! The CBOR (RFC 8949) that WebAuthn and CTAP2 use: integers, byte and text strings,
//! arrays, maps, and booleans, with definite lengths. `Reader` decodes in place, without
//! allocating; the `write*` functions encode in the shortest form, which with map keys
//! written in order is the CTAP2 canonical encoding.

const std = @import("std");
const Io = std.Io;

/// What a malformed or unsupported encoding fails with.
pub const Error = error{InvalidCbor};

pub const Type = enum(u3) {
    unsigned = 0,
    negative = 1,
    bytes = 2,
    text = 3,
    array = 4,
    map = 5,
    tag = 6,
    simple = 7,
};

/// How deeply `Reader.skip` follows nested arrays and maps.
pub const max_depth = 16;

const simple_false = 20;
const simple_true = 21;

/// Decodes items from `bytes`, one after another.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    const Head = struct { type: Type, argument: u64 };

    /// Whether every byte has been read.
    pub fn atEnd(r: *const Reader) bool {
        return r.pos == r.bytes.len;
    }

    /// The type of the next item, without reading it.
    pub fn peek(r: *const Reader) Error!Type {
        if (r.pos >= r.bytes.len) return error.InvalidCbor;
        return @fromBackingInt(@intCast(r.bytes[r.pos] >> 5));
    }

    fn head(r: *Reader) Error!Head {
        if (r.pos >= r.bytes.len) return error.InvalidCbor;
        const initial = r.bytes[r.pos];
        r.pos += 1;
        const kind: Type = @fromBackingInt(@intCast(initial >> 5));
        const info: u5 = @truncate(initial);
        const size: usize = switch (info) {
            0...23 => return .{ .type = kind, .argument = info },
            24 => 1,
            25 => 2,
            26 => 4,
            27 => 8,
            // Indefinite lengths and reserved values.
            else => return error.InvalidCbor,
        };
        if (r.bytes.len - r.pos < size) return error.InvalidCbor;
        var argument: u64 = 0;
        for (r.bytes[r.pos..][0..size]) |byte| argument = argument << 8 | byte;
        r.pos += size;
        return .{ .type = kind, .argument = argument };
    }

    fn expect(r: *Reader, kind: Type) Error!u64 {
        const found = try r.head();
        if (found.type != kind) return error.InvalidCbor;
        return found.argument;
    }

    /// An unsigned or negative integer that fits in an `i64`.
    pub fn int(r: *Reader) Error!i64 {
        const found = try r.head();
        if (found.argument > std.math.maxInt(i64)) return error.InvalidCbor;
        const value: i64 = @intCast(found.argument);
        return switch (found.type) {
            .unsigned => value,
            .negative => -1 - value,
            else => error.InvalidCbor,
        };
    }

    /// A byte string, pointing into `bytes`.
    pub fn byteString(r: *Reader) Error![]const u8 {
        return r.take(try r.expect(.bytes));
    }

    /// A text string, pointing into `bytes`. Its UTF-8 is not checked.
    pub fn textString(r: *Reader) Error![]const u8 {
        return r.take(try r.expect(.text));
    }

    /// The head of an array: how many items follow.
    pub fn array(r: *Reader) Error!u64 {
        return r.expect(.array);
    }

    /// The head of a map: how many key and value pairs follow.
    pub fn map(r: *Reader) Error!u64 {
        return r.expect(.map);
    }

    pub fn boolean(r: *Reader) Error!bool {
        return switch (try r.expect(.simple)) {
            simple_false => false,
            simple_true => true,
            else => error.InvalidCbor,
        };
    }

    fn take(r: *Reader, len: u64) Error![]const u8 {
        if (len > r.bytes.len - r.pos) return error.InvalidCbor;
        const slice = r.bytes[r.pos..][0..@intCast(len)];
        r.pos += slice.len;
        return slice;
    }

    /// Reads past the next item, whatever it is, up to `max_depth` levels deep.
    pub fn skip(r: *Reader) Error!void {
        return r.skipDepth(0);
    }

    fn skipDepth(r: *Reader, depth: usize) Error!void {
        if (depth == max_depth) return error.InvalidCbor;
        const found = try r.head();
        switch (found.type) {
            .unsigned, .negative, .simple => {},
            .bytes, .text => _ = try r.take(found.argument),
            .array => for (0..found.argument) |_| try r.skipDepth(depth + 1),
            .map => for (0..found.argument) |_| {
                try r.skipDepth(depth + 1);
                try r.skipDepth(depth + 1);
            },
            .tag => try r.skipDepth(depth + 1),
        }
    }
};

fn writeHead(w: *Io.Writer, kind: Type, argument: u64) Io.Writer.Error!void {
    const major: u8 = @as(u8, @backingInt(kind)) << 5;
    if (argument < 24) return w.writeByte(major | @as(u8, @intCast(argument)));
    if (argument <= std.math.maxInt(u8)) {
        try w.writeByte(major | 24);
        return w.writeByte(@intCast(argument));
    }
    if (argument <= std.math.maxInt(u16)) {
        try w.writeByte(major | 25);
        return w.writeInt(u16, @intCast(argument), .big);
    }
    if (argument <= std.math.maxInt(u32)) {
        try w.writeByte(major | 26);
        return w.writeInt(u32, @intCast(argument), .big);
    }
    try w.writeByte(major | 27);
    return w.writeInt(u64, argument, .big);
}

pub fn writeInt(w: *Io.Writer, value: i64) Io.Writer.Error!void {
    if (value >= 0) return writeHead(w, .unsigned, @intCast(value));
    return writeHead(w, .negative, @intCast(-1 - value));
}

pub fn writeBytes(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    try writeHead(w, .bytes, bytes.len);
    try w.writeAll(bytes);
}

pub fn writeText(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try writeHead(w, .text, text.len);
    try w.writeAll(text);
}

/// The head of an array of `len` items, which the caller writes next.
pub fn writeArray(w: *Io.Writer, len: usize) Io.Writer.Error!void {
    return writeHead(w, .array, len);
}

/// The head of a map of `len` pairs, which the caller writes next, keys in canonical order.
pub fn writeMap(w: *Io.Writer, len: usize) Io.Writer.Error!void {
    return writeHead(w, .map, len);
}

pub fn writeBool(w: *Io.Writer, value: bool) Io.Writer.Error!void {
    return writeHead(w, .simple, if (value) simple_true else simple_false);
}

const testing = std.testing;

test "round trip, in the shortest form" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeMap(&w, 3);
    try writeInt(&w, 1);
    try writeInt(&w, -7);
    try writeInt(&w, 2);
    try writeArray(&w, 2);
    try writeBytes(&w, "ab");
    try writeBool(&w, true);
    try writeText(&w, "k");
    try writeInt(&w, 65536);
    try testing.expectEqualSlices(u8, &.{
        0xa3, 0x01, 0x26, 0x02, 0x82, 0x42, 'a', 'b', 0xf5, 0x61, 'k', 0x1a, 0x00, 0x01, 0x00, 0x00,
    }, w.buffered());

    var r: Reader = .{ .bytes = w.buffered() };
    try testing.expectEqual(3, try r.map());
    try testing.expectEqual(1, try r.int());
    try testing.expectEqual(-7, try r.int());
    try testing.expectEqual(2, try r.int());
    try testing.expectEqual(Type.array, try r.peek());
    try testing.expectEqual(2, try r.array());
    try testing.expectEqualStrings("ab", try r.byteString());
    try testing.expect(try r.boolean());
    try testing.expectEqualStrings("k", try r.textString());
    try testing.expectEqual(65536, try r.int());
    try testing.expect(r.atEnd());
}

test "skip passes nested items and refuses what it cannot read" {
    // {"a": [1, {2: h'00'}], "b": tag 1 (0)} then 7
    var r: Reader = .{ .bytes = &.{
        0xa2, 0x61, 'a', 0x82, 0x01, 0xa1, 0x02, 0x41, 0x00, 0x61, 'b', 0xc1, 0x00, 0x07,
    } };
    try r.skip();
    try testing.expectEqual(7, try r.int());

    const e = testing.expectError;
    var truncated: Reader = .{ .bytes = &.{ 0x42, 'a' } };
    try e(error.InvalidCbor, truncated.skip());
    var indefinite: Reader = .{ .bytes = &.{ 0x9f, 0xff } };
    try e(error.InvalidCbor, indefinite.skip());
    const nested = @as([max_depth + 1]u8, @splat(0x81)) ++ [_]u8{0x00};
    var deep: Reader = .{ .bytes = &nested };
    try e(error.InvalidCbor, deep.skip());
    var huge: Reader = .{ .bytes = &.{ 0x1b, 0xff, 0, 0, 0, 0, 0, 0, 0 } };
    try e(error.InvalidCbor, huge.int());
    var wrong: Reader = .{ .bytes = &.{0x01} };
    try e(error.InvalidCbor, wrong.textString());
    try e(error.InvalidCbor, (Reader{ .bytes = "" }).peek());
}
