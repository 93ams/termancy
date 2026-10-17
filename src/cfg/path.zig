//! Dotted key paths: `server.tls.cert`, `servers.0.host`, `a."dotted.key".b`.
//!
//! A segment is a run of bytes up to the next `.`, or a double-quoted string, which is how a
//! key that itself contains a dot is addressed. Inside quotes, `\"` and `\\` escape.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// A path that is empty, has an empty segment, or an unclosed quote.
pub const Error = error{InvalidPath};

/// Iterates the segments of a path. Quoted segments are returned with escapes still in
/// place; `unescape` removes them.
pub const Iterator = struct {
    path: []const u8,
    index: usize = 0,

    /// One segment, as written.
    pub const Segment = struct {
        text: []const u8,
        quoted: bool,
    };

    /// The next segment, or null after the last.
    pub fn next(it: *Iterator) Error!?Segment {
        if (it.index > it.path.len) return null;
        if (it.path.len == 0) return error.InvalidPath;
        const rest = it.path[it.index..];
        if (rest.len > 0 and rest[0] == '"') {
            var i: usize = 1;
            while (i < rest.len) : (i += 1) {
                if (rest[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (rest[i] == '"') break;
            }
            if (i >= rest.len) return error.InvalidPath;
            const segment: Segment = .{ .text = rest[1..i], .quoted = true };
            const after = i + 1;
            if (after < rest.len and rest[after] != '.') return error.InvalidPath;
            it.index += after + 1;
            if (after + 1 == rest.len) return error.InvalidPath; // trailing dot
            return segment;
        }
        const end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        if (end == 0) return error.InvalidPath;
        if (end + 1 == rest.len) return error.InvalidPath; // trailing dot
        it.index += end + 1;
        return .{ .text = rest[0..end], .quoted = false };
    }
};

/// Iterates the segments of `path`. Malformed paths fail on `next`.
pub fn iterate(path: []const u8) Iterator {
    return .{ .path = path };
}

/// Returns the segment's key text. Unquoted segments are returned as is; quoted segments
/// without escapes are returned as is; otherwise the escapes are removed into `arena`.
pub fn unescape(arena: Allocator, segment: Iterator.Segment) Allocator.Error![]const u8 {
    if (!segment.quoted) return segment.text;
    if (std.mem.indexOfScalar(u8, segment.text, '\\') == null) return segment.text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < segment.text.len) : (i += 1) {
        const c = segment.text[i];
        if (c == '\\' and i + 1 < segment.text.len) {
            i += 1;
            try out.append(arena, segment.text[i]);
        } else {
            try out.append(arena, c);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Splits a path into unescaped key segments, allocated in `arena`.
pub fn split(arena: Allocator, path: []const u8) (Error || Allocator.Error)![]const []const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var it = iterate(path);
    while (try it.next()) |segment| {
        try segments.append(arena, try unescape(arena, segment));
    }
    assert(segments.items.len > 0);
    return segments.toOwnedSlice(arena);
}

/// Whether `key` can be written as a bare path segment.
pub fn isBare(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if (c == '.' or c == '"' or c == '\\') return false;
    }
    return true;
}

/// Writes one path segment, quoting it when it is not bare.
pub fn writeSegment(writer: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    if (isBare(key)) return writer.writeAll(key);
    try writer.writeByte('"');
    for (key) |c| {
        if (c == '"' or c == '\\') try writer.writeByte('\\');
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

/// Joins `parent` and `key` into a new path in `arena`.
pub fn join(arena: Allocator, parent: []const u8, key: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    if (parent.len > 0) {
        out.writer.writeAll(parent) catch return error.OutOfMemory;
        out.writer.writeByte('.') catch return error.OutOfMemory;
    }
    writeSegment(&out.writer, key) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Maps a path to an environment variable name: `server.tls-cert` with prefix `APP`
/// becomes `APP_SERVER_TLS_CERT`. Non-alphanumeric bytes become `_`.
pub fn toEnvName(
    arena: Allocator,
    prefix: []const u8,
    key_path: []const u8,
) Allocator.Error![]const u8 {
    const len = prefix.len + @intFromBool(prefix.len > 0) + key_path.len;
    const out = try arena.alloc(u8, len);
    var i: usize = 0;
    for (prefix) |c| {
        out[i] = envByte(c);
        i += 1;
    }
    if (prefix.len > 0) {
        out[i] = '_';
        i += 1;
    }
    for (key_path) |c| {
        out[i] = if (c == '"') '_' else envByte(c);
        i += 1;
    }
    assert(i == len);
    return out;
}

fn envByte(c: u8) u8 {
    if (std.ascii.isAlphanumeric(c)) return std.ascii.toUpper(c);
    return '_';
}

test "iterate bare and quoted segments" {
    var it = iterate("a.\"b.c\".0");
    const first = (try it.next()).?;
    try std.testing.expectEqualStrings("a", first.text);
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("b.c", second.text);
    try std.testing.expect(second.quoted);
    const third = (try it.next()).?;
    try std.testing.expectEqualStrings("0", third.text);
    try std.testing.expectEqual(null, try it.next());
}

test "invalid paths" {
    const bad = [_][]const u8{ "", ".", "a.", ".a", "a..b", "\"a", "\"a\"b" };
    for (bad) |path| {
        var it = iterate(path);
        const result = while (true) {
            const segment = it.next() catch |err| break err;
            if (segment == null) break error.Valid;
        };
        try std.testing.expectEqual(error.InvalidPath, result);
    }
}

test "split unescapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const segments = try split(arena.allocator(), "x.\"q\\\"t\"");
    try std.testing.expectEqual(2, segments.len);
    try std.testing.expectEqualStrings("q\"t", segments[1]);
}

test "join quotes when needed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a.b", try join(arena.allocator(), "a", "b"));
    try std.testing.expectEqualStrings("a.\"b.c\"", try join(arena.allocator(), "a", "b.c"));
    try std.testing.expectEqualStrings("k", try join(arena.allocator(), "", "k"));
}

test "toEnvName" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const name = try toEnvName(arena.allocator(), "app", "server.tls-cert");
    try std.testing.expectEqualStrings("APP_SERVER_TLS_CERT", name);
    try std.testing.expectEqualStrings("PORT", try toEnvName(arena.allocator(), "", "port"));
}

test "quoted segments with escaped quotes and backslashes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var it = iterate("\"a\\\"b\".\"c\\\\\".\"\"");
    const first = (try it.next()).?;
    try std.testing.expectEqualStrings("a\\\"b", first.text);
    try std.testing.expect(first.quoted);
    try std.testing.expectEqualStrings("a\"b", try unescape(a, first));
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("c\\", try unescape(a, second));
    const third = (try it.next()).?;
    try std.testing.expectEqualStrings("", third.text);
    try std.testing.expect(third.quoted);
    try std.testing.expectEqual(null, try it.next());
    // An escaped closing quote leaves the segment unterminated.
    var open = iterate("\"a\\\"");
    try std.testing.expectError(error.InvalidPath, open.next());
    // A quoted segment followed by a dot and nothing else.
    var trailing = iterate("\"a\".");
    try std.testing.expectError(error.InvalidPath, trailing.next());
    // Unquoted segments keep their bytes, quotes in the middle included.
    const bare = try split(a, "a\"b.c\\d");
    try std.testing.expectEqualStrings("a\"b", bare[0]);
    try std.testing.expectEqualStrings("c\\d", bare[1]);
}

test "writeSegment and split are inverses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = [_][]const u8{ "plain", "", "a.b", "q\"t", "back\\slash", "\\\"", "x y", "0" };
    for (keys) |key| {
        const joined = try join(a, "root", key);
        const segments = try split(a, joined);
        try std.testing.expectEqual(2, segments.len);
        try std.testing.expectEqualStrings(key, segments[1]);
        try std.testing.expectEqual(
            key.len > 0 and std.mem.indexOfAny(u8, key, ".\"\\") == null,
            isBare(key),
        );
    }
}

test "toEnvName maps every non-alphanumeric byte" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("MY_APP_A__B_C_", try toEnvName(a, "my-app", "a.\"b.c\""));
    try std.testing.expectEqualStrings("X_0_Y", try toEnvName(a, "x", "0.y"));
    try std.testing.expectEqualStrings("_", try toEnvName(a, "", "\u{e9}"[0..1]));
}
