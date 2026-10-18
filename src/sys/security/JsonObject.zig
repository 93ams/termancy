//! A parsed JSON object with typed field access, shared by `oauth` and `webauthn`.
//!
//! Everything is allocated in the arena given to `parse`; strings are always copied, so
//! the input may be freed (or wiped) right after parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const base64url = std.base64.url_safe_no_pad;

const JsonObject = @This();

map: std.json.ObjectMap,

/// Why a document or a field was refused.
pub const Error = error{
    /// The text is not JSON, or its top level is not an object.
    InvalidJson,
    /// A required field is absent or `null`.
    MissingField,
    /// A field has the wrong type or an invalid value.
    InvalidField,
} || Allocator.Error;

/// Parses `text`, whose top level must be an object, into `arena`.
pub fn parse(arena: Allocator, text: []const u8) Error!JsonObject {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    return switch (value) {
        .object => |map| .{ .map = map },
        else => error.InvalidJson,
    };
}

/// The field, or `null` when it is absent or JSON `null`.
pub fn get(object: JsonObject, name: []const u8) ?std.json.Value {
    const value = object.map.get(name) orelse return null;
    return if (value == .null) null else value;
}

/// A string field, `null` when absent.
pub fn optionalString(object: JsonObject, name: []const u8) Error!?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidField,
    };
}

/// A string field that must be present.
pub fn string(object: JsonObject, name: []const u8) Error![]const u8 {
    return try object.optionalString(name) orelse error.MissingField;
}

/// A non-negative integer field, `null` when absent. A string of digits is accepted too,
/// since some servers send `"3600"`.
pub fn optionalUnsigned(object: JsonObject, name: []const u8) Error!?u32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| std.math.cast(u32, i) orelse error.InvalidField,
        .string, .number_string => |s| std.fmt.parseInt(u32, s, 10) catch error.InvalidField,
        else => error.InvalidField,
    };
}

/// A boolean field, `null` when absent.
pub fn optionalBool(object: JsonObject, name: []const u8) Error!?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidField,
    };
}

/// A nested object field, `null` when absent.
pub fn optionalObject(object: JsonObject, name: []const u8) Error!?JsonObject {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .object => |map| .{ .map = map },
        else => error.InvalidField,
    };
}

/// A base64url string field (padding tolerated), decoded into `arena`; `null` when absent.
pub fn optionalBytes(object: JsonObject, arena: Allocator, name: []const u8) Error!?[]u8 {
    const text = try object.optionalString(name) orelse return null;
    return decodeBase64Url(arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidEncoding => error.InvalidField,
    };
}

/// A base64url string field that must be present.
pub fn bytes(object: JsonObject, arena: Allocator, name: []const u8) Error![]u8 {
    return try object.optionalBytes(arena, name) orelse error.MissingField;
}

/// Decodes base64url text, with or without `=` padding.
pub fn decodeBase64Url(gpa: Allocator, text: []const u8) error{
    InvalidEncoding,
    OutOfMemory,
}![]u8 {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    const len = base64url.Decoder.calcSizeForSlice(trimmed) catch return error.InvalidEncoding;
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    base64url.Decoder.decode(out, trimmed) catch return error.InvalidEncoding;
    return out;
}

test "typed fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const object = try parse(a,
        \\{"s":"x","n":5,"ns":"7","b":true,"o":{},"z":null,"bytes":"AQID","neg":-1}
    );
    try std.testing.expectEqualStrings("x", try object.string("s"));
    try std.testing.expectEqual(null, try object.optionalString("missing"));
    try std.testing.expectEqual(null, try object.optionalString("z"));
    try std.testing.expectError(error.MissingField, object.string("z"));
    try std.testing.expectError(error.InvalidField, object.string("n"));
    try std.testing.expectEqual(5, try object.optionalUnsigned("n"));
    try std.testing.expectEqual(7, try object.optionalUnsigned("ns"));
    try std.testing.expectError(error.InvalidField, object.optionalUnsigned("neg"));
    try std.testing.expectEqual(true, try object.optionalBool("b"));
    try std.testing.expect(try object.optionalObject("o") != null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, try object.bytes(a, "bytes"));
    try std.testing.expectError(error.InvalidField, object.bytes(a, "s"));
}

test "parse refuses non-objects" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidJson, parse(arena.allocator(), "[1]"));
    try std.testing.expectError(error.InvalidJson, parse(arena.allocator(), "{"));
}

test decodeBase64Url {
    const gpa = std.testing.allocator;
    const padded = try decodeBase64Url(gpa, "_-8=");
    defer gpa.free(padded);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xef }, padded);
    try std.testing.expectError(error.InvalidEncoding, decodeBase64Url(gpa, "a+b/"));
}
