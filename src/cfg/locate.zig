//! Where a key is written in a file's text, so a problem found while decoding (which knows
//! only the key) can point at the line: `config.toml:12:8: port: must be at most 65535`.
//!
//! Keys match as decoding matches them: ignoring ASCII case, with `-` and `_` alike. A key
//! the text does not have, such as a required one that is missing, is found at its nearest
//! enclosing table that the text has.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Format = @import("format.zig").Format;
const path = @import("path.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const json = @import("json.zig");
const zon = @import("zon.zig");
const ini = @import("ini.zig");
const dotenv = @import("dotenv.zig");

/// A place in the text.
pub const Position = struct {
    /// Byte offset.
    offset: usize,
    /// One-based line and column (in bytes).
    line: u32,
    column: u32,
    /// The key itself was found, rather than a table enclosing it.
    exact: bool,
};

/// One key in the text: its path, and where to point.
const Place = struct { segments: []const []const u8, offset: usize };

/// Where `key_path` is in `source`: its value when it has one on the key's line, otherwise
/// the key. Null when the text does not parse or has neither the key nor any table above
/// it.
pub fn locate(
    arena: Allocator,
    format: Format,
    source: []const u8,
    key_path: []const u8,
) Allocator.Error!?Position {
    const want = path.split(arena, key_path) catch return null;
    const places = placesOf(arena, format, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var best: ?Place = null;
    var best_len: usize = 0;
    // A key written only through what is below it, as an array of tables is through its
    // `[[header]]`s: the first of those.
    var inside: ?Place = null;
    for (places) |place| {
        if (place.segments.len > want.len) {
            if (inside == null and prefixMatches(want, place.segments[0..want.len])) {
                inside = place;
            }
            continue;
        }
        if (!prefixMatches(place.segments, want)) continue;
        // The deepest match wins; among equals, the first (a key written twice errs there).
        if (best == null or place.segments.len > best_len) {
            best = place;
            best_len = place.segments.len;
        }
    }
    if (best_len < want.len) if (inside) |place| return position(source, place.offset, true);
    const found = best orelse return null;
    return position(source, found.offset, best_len == want.len);
}

fn prefixMatches(have: []const []const u8, want: []const []const u8) bool {
    for (have, want[0..have.len]) |a, b| if (!namesMatch(a, b)) return false;
    return true;
}

fn namesMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '-') '_' else std.ascii.toLower(x);
        const ny = if (y == '-') '_' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

fn position(source: []const u8, offset: usize, exact: bool) Position {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..offset], 0..) |c, i| if (c == '\n') {
        line += 1;
        line_start = i + 1;
    };
    return .{
        .offset = offset,
        .line = line,
        .column = @intCast(offset - line_start + 1),
        .exact = exact,
    };
}

/// The value when there is one, else `start`.
fn pointAt(start: usize, value_start: usize, value_end: usize) usize {
    return if (value_end > value_start) value_start else start;
}

fn placesOf(arena: Allocator, format: Format, source: []const u8) ![]const Place {
    var out: std.ArrayList(Place) = .empty;
    switch (format) {
        .toml => for (try toml.spans(arena, source)) |s| {
            const at = switch (s.kind) {
                .header => s.value_start,
                .entry => pointAt(s.start, s.value_start, s.value_end),
            };
            try out.append(arena, .{ .segments = s.path, .offset = at });
        },
        .yaml => for (try yaml.spans(arena, source)) |s| {
            const at = pointAt(s.start + s.indent, s.value_start, s.value_end);
            try out.append(arena, .{ .segments = s.path, .offset = at });
        },
        .json, .jsonc => for (try json.spans(arena, source, format == .jsonc)) |s| {
            if (s.kind != .field) continue;
            const at = pointAt(s.start, s.value_start, s.value_end);
            try out.append(arena, .{ .segments = s.path, .offset = at });
        },
        .zon => for (try zon.spans(arena, source)) |s| {
            if (s.kind != .field) continue;
            const at = pointAt(s.start, s.value_start, s.value_end);
            try out.append(arena, .{ .segments = s.path, .offset = at });
        },
        .ini => for (try ini.spans(arena, source)) |s| {
            const at = switch (s.kind) {
                .header => s.start,
                .entry => pointAt(s.start, s.value_start, s.value_end),
            };
            try out.append(arena, .{ .segments = s.path, .offset = at });
        },
        .dotenv => for (try dotenv.spans(arena, source)) |s| {
            const segments = try path.split(arena, s.path);
            const at = pointAt(s.start, s.value_start, s.value_end);
            try out.append(arena, .{ .segments = segments, .offset = at });
        },
    }
    return out.items;
}

const testing = std.testing;

fn expectAt(format: Format, source: []const u8, key: []const u8, line: u32, column: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = (try locate(arena.allocator(), format, source, key)) orelse {
        std.debug.print("{t}: {s} not found\n", .{ format, key });
        return error.TestUnexpectedResult;
    };
    testing.expectEqual(line, found.line) catch |err| {
        std.debug.print("{t}: {s} at {d}:{d}\n", .{ format, key, found.line, found.column });
        return err;
    };
    try testing.expectEqual(column, found.column);
}

test "every format: a value, a nested value, and a missing key's table" {
    try expectAt(.toml, "a = 1\n[server]\nport = 70000\n", "server.port", 3, 8);
    try expectAt(.toml, "a = 1\n[server]\nport = 70000\n", "server.host", 2, 1);
    try expectAt(.toml, "[[servers]]\nport = 1\n[[servers]]\nport = 2\n", "servers.1.port", 4, 8);
    try expectAt(.toml, "a = 1\n[[servers]]\nport = 1\n", "servers", 2, 1);
    try expectAt(.yaml, "a: 1\nserver:\n  port: 70000\n", "server.port", 3, 9);
    try expectAt(.yaml, "a: 1\nserver:\n  port: 70000\n", "server.host", 2, 1);
    try expectAt(.yaml, "list:\n  - name: x\n  - name: y\n", "list.1.name", 3, 11);
    try expectAt(.json, "{\n  \"server\": {\"port\": 70000}\n}", "server.port", 2, 22);
    try expectAt(.jsonc, "{\n  // c\n  \"a\": 1,\n}", "a", 3, 8);
    try expectAt(.zon, ".{\n    .server = .{ .port = 70000 },\n}", "server.port", 2, 26);
    try expectAt(.ini, "[server]\nport = 70000\n", "server.port", 2, 8);
    try expectAt(.ini, "[server]\nport = 70000\n", "server.host", 1, 1);
    try expectAt(.dotenv, "A=1\nSERVER__PORT=70000\n", "server.port", 2, 14);
}

test "keys match as decoding matches them" {
    try expectAt(.toml, "tls-cert = \"x\"\n", "tls_cert", 1, 12);
    try expectAt(.yaml, "TLS_Cert: x\n", "tls_cert", 1, 11);
}

test "nothing to point at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try locate(a, .toml, "a = 1\n", "b.c"));
    try testing.expectEqual(null, try locate(a, .toml, "a = = 1\n", "a"));
    try testing.expect((try locate(a, .toml, "a = 1\n", "a")).?.exact);
    try testing.expect(!(try locate(a, .toml, "[t]\n", "t.x")).?.exact);
}
