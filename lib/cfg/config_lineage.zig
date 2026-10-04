//! Configuration provenance: which layer last set a field, and where it came from.
//!
//! This file **is** the type: the file's own scope is `ConfigLineage`, so a
//! consumer writes `const ConfigLineage = @import("config_lineage.zig");`. See
//! the file-layout rule in `.agents/AGENTS.md`.
//!
//! `ConfigSource` and `FieldProvenance` stay declarations inside, because a
//! lineage record is made of them - one subject, not three.
//!
//! **Known defect, recorded not fixed:** `deinit` decides whether to free an
//! origin by checking `origin.len > 0`, but `record` stores the literal `""` when
//! no origin is given. Re-recording a key can therefore free a string literal.
//! See `app/cli/lib/ROADMAP.md` section 5.3.

const std = @import("std");

const Self = @This();

/// Where a value came from, in increasing order of precedence.
pub const ConfigSource = enum {
    default,
    file,
    remote,
    env,
    flag,

    pub fn toLabel(self: ConfigSource) []const u8 {
        return switch (self) {
            .default => "DEFAULT",
            .file => "FILE",
            .remote => "REMOTE",
            .env => "ENV",
            .flag => "FLAG",
        };
    }
};

/// One field's recorded provenance.
pub const FieldProvenance = struct {
    source: ConfigSource,
    origin: []const u8,
};

records: std.StringHashMap(FieldProvenance),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .records = std.StringHashMap(FieldProvenance).init(allocator),
        .allocator = allocator,
    };
}

/// Frees every recorded key and origin.
///
/// See the module header: the `origin.len > 0` guard is the recorded defect.
pub fn deinit(self: *Self) void {
    var it = self.records.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.origin.len > 0) {
            self.allocator.free(entry.value_ptr.origin);
        }
    }
    self.records.deinit();
}

/// Records where `path` was last set, replacing any previous record.
///
/// ## The defect this replaces
///
/// The obvious implementation is `fetchPut` and then free whatever it handed back:
///
/// ```zig
/// const k = try self.allocator.dupe(u8, path);
/// if (self.records.fetchPut(k, new_value)) |old| {
///     self.allocator.free(old.?.key);   // <- the map still holds this pointer
/// }
/// ```
///
/// `fetchPut` returns the **previous** key, and `std.StringHashMap` stores the key
/// *inside itself* rather than pointing at the caller's slice - so the pointer
/// returned is the map's own, still live. Freeing it leaves the map holding a dangling
/// key: a later lookup reads freed memory, and `deinit` frees it a second time.
///
/// Measured on Zig 0.16 with `std.testing.allocator`, recording `"a.b"` twice:
/// `getProvenance("a.b")` returned **null** (the lookup compared against freed bytes),
/// then `deinit` reported `Double free detected` - first free here, second in `deinit` -
/// plus a leak of the newly duped key, which nothing kept.
///
/// The documented hazard in this file used to be "it can free the `""` literal"; that
/// was wrong in both directions. Nothing ever frees the literal, and the real problem
/// is the map's own key.
///
/// ## The fix
///
/// Take the update path explicitly. That reuses the stored key, so no key is allocated
/// or freed on a replacement and the dangling pointer cannot arise. The freshly duped
/// key is freed only when it was not adopted.
pub fn record(self: *Self, path: []const u8, source: ConfigSource, origin: []const u8) !void {
    const orig = if (origin.len > 0) try self.allocator.dupe(u8, origin) else "";
    errdefer if (origin.len > 0) self.allocator.free(orig);

    if (self.records.getEntry(path)) |entry| {
        // Key already stored: keep it, swap the value, and release the previous value's
        // origin. Nothing here touches `entry.key_ptr`.
        const previous = entry.value_ptr.*;
        entry.value_ptr.* = .{ .source = source, .origin = orig };
        if (previous.origin.len > 0) self.allocator.free(previous.origin);
        return;
    }

    const k = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(k);
    try self.records.put(k, .{ .source = source, .origin = orig });
}

/// The recorded provenance for `path`, or null if never recorded.
pub fn getProvenance(self: Self, path: []const u8) ?FieldProvenance {
    return self.records.get(path);
}

/// Writes one line describing a value and where it came from, falling back to
/// "built-in default" when nothing was recorded.
pub fn inspect(
    self: Self,
    writer: anytype,
    path: []const u8,
    value_repr: []const u8,
    type_name: []const u8,
) !void {
    const prov = self.getProvenance(path) orelse FieldProvenance{
        .source = .default,
        .origin = "built-in default",
    };

    try writer.print("Value: {s} | Type: {s} | Source: {s}", .{
        value_repr,
        type_name,
        prov.source.toLabel(),
    });

    if (prov.origin.len > 0) {
        try writer.print(" ({s})", .{prov.origin});
    }
    try writer.writeByte('\n');
}

test "record and getProvenance round-trip, and inspect renders the source" {
    var lineage = Self.init(std.testing.allocator);
    defer lineage.deinit();

    try lineage.record("a.b", .env, "A_B");
    try lineage.record("c.d", .file, "config.toml");

    const a = lineage.getProvenance("a.b").?;
    try std.testing.expectEqual(ConfigSource.env, a.source);
    try std.testing.expectEqualStrings("A_B", a.origin);

    try std.testing.expect(lineage.getProvenance("missing") == null);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try lineage.inspect(&w, "a.b", "8080", "u16");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "ENV") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "A_B") != null);
}

test "inspect falls back to default when nothing was recorded" {
    var lineage = Self.init(std.testing.allocator);
    defer lineage.deinit();

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try lineage.inspect(&w, "x", "1", "u16");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "DEFAULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "built-in default") != null);
}

test "re-recording the same path replaces cleanly and stays findable" {
    // The regression guard for the double-free. Before the fix, `fetchPut` returned the
    // map's own key and `record` freed it, so this sequence produced a null lookup, a
    // double free at `deinit`, and a leaked key. `std.testing.allocator` reports both.
    var led = Self.init(std.testing.allocator);
    defer led.deinit();

    try led.record("a.b", .default, "built-in default");
    try led.record("a.b", .env, "APP_A_B");

    // The lookup must still work: with a dangling key it compared against freed bytes
    // and returned null.
    const prov = led.getProvenance("a.b").?;
    try std.testing.expectEqual(ConfigSource.env, prov.source);
    try std.testing.expectEqualStrings("APP_A_B", prov.origin);

    // Re-recording again must also be clean, and must not accumulate records.
    try led.record("a.b", .flag, "--a-b");
    try std.testing.expectEqual(ConfigSource.flag, led.getProvenance("a.b").?.source);
    try std.testing.expectEqual(@as(usize, 1), led.records.count());
}

test "re-recording an empty origin does not free the empty literal" {
    var led = Self.init(std.testing.allocator);
    defer led.deinit();

    // `""` is not owned, so neither path may free it. Both calls pass an empty origin,
    // which is the case the old comment worried about.
    try led.record("x", .default, "");
    try led.record("x", .env, "");
    try std.testing.expectEqualStrings("", led.getProvenance("x").?.origin);
}

test "recording several paths frees each key exactly once" {
    var led = Self.init(std.testing.allocator);
    defer led.deinit();

    try led.record("one", .default, "a");
    try led.record("two", .env, "b");
    try led.record("three", .file, "c");
    try led.record("two", .flag, "d");

    try std.testing.expectEqual(@as(usize, 3), led.records.count());
    try std.testing.expectEqualStrings("d", led.getProvenance("two").?.origin);
    try std.testing.expectEqualStrings("a", led.getProvenance("one").?.origin);
}
