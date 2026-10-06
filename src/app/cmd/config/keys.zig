//! `config keys [path]` - list the configuration's dotted key paths, one per line.
//!
//! The specification describes this as data-structure traversal for dynamic shell
//! scripts: `cfg keys database` returns `host`, `port`, `user`, ... so a bash
//! completion function can suggest real keys from the real file rather than a
//! hardcoded list.
//!
//! Two deliberate choices, both about being usable from a shell:
//!
//! * **One path per line, nothing else.** No type, no value, no bullets - a caller is
//!   going to `for k in $(config keys); do`, and any decoration becomes a word in that
//!   loop.
//! * **Prefixes match on a dot boundary.** `config keys net` does *not* list
//!   `network.port`, because a completion script descends one segment at a time and
//!   would otherwise offer keys from a subtree the user has not entered.

const std = @import("std");
const cfg = @import("cfg");
const ops = @import("../../lib/ops/root.zig");

/// Flags for `config keys`.
pub const KeysFlags = struct {
    /// Optional dotted prefix to filter by.
    positionals: struct {
        prefix: []const u8 = "",
    } = .{},

    pub const meta = .{
        .positionals = .{ .description = "Dotted prefix to filter by, e.g. network" },
    };
};

/// Writes one dotted path per line.
pub fn run(
    allocator: std.mem.Allocator,
    writer: anytype,
    comptime ConfigT: type,
    prefix: []const u8,
) !void {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(allocator);

    _ = try ops.query.keys(allocator, ConfigT, &list, prefix);
    for (list.items) |path| {
        try writer.print("{s}\n", .{path});
    }
}

// -- Tests -----------------------------------------------------------------

const Network = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
};

const Fixture = struct {
    name: []const u8 = "svc",
    verbose: bool = false,
    network: Network = .{},

    pub const meta = .{};
};

test "every key is printed on its own line, undecorated" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, Fixture, "");

    // Exactly the paths, one per line - no values, no types.
    try std.testing.expectEqualStrings("name\nverbose\nnetwork.port\nnetwork.host\n", w.buffered());
}

test "a prefix filters to one subtree without matching partial segments" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, Fixture, "network");
    try std.testing.expectEqualStrings("network.port\nnetwork.host\n", w.buffered());

    // `net` is not a segment prefix of `network`, so it lists nothing.
    var buf2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try run(std.testing.allocator, &w2, Fixture, "net");
    try std.testing.expectEqual(@as(usize, 0), w2.buffered().len);
}

test "an unknown prefix lists nothing rather than failing" {
    // Listing nothing is the honest answer to "what is under this key" when there is
    // nothing under it; a completion script should get an empty list, not an error.
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, Fixture, "nosuch");
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "the positional is declared where the framework looks for it" {
    try std.testing.expect(@hasField(KeysFlags, "positionals"));
    try std.testing.expect(@hasField(@FieldType(KeysFlags, "positionals"), "prefix"));
}
