//! Upgrading configuration documents between versions of an application's schema.
//!
//! ```zig
//! const migrations = [_]cfg.migrate.Migration{
//!     .{ .to = 2, .steps = &.{.{ .rename = .{ .from = "port", .to = "server.port" } }} },
//!     .{ .to = 3, .steps = &.{
//!         .{ .remove = "legacy" },
//!         .{ .set = .{ .key = "mode", .value = .{ .string = "safe" } } },
//!     } },
//! };
//! const result = try cfg.migrate.run(arena, &tree, &migrations, .{});
//! // result.from == 1, result.to == 3; write `tree` back to upgrade the file.
//! ```
//!
//! A document records its version under `version_key` (`schema_version` by default); one
//! without it is version 1. `run` applies, in order, every migration newer than the
//! document and sets the version to the last one applied.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

/// One change a migration makes.
pub const Step = union(enum) {
    /// Moves the value at `from` to `to`, when there is one at `from`.
    rename: struct { from: []const u8, to: []const u8 },
    /// Removes the key, when it is there.
    remove: []const u8,
    /// Sets the key, when it is not set.
    set: struct { key: []const u8, value: Value },
    /// Anything else, such as splitting one value in two.
    custom: *const fn (arena: Allocator, tree: *Value) anyerror!void,
};

/// The steps that upgrade a document to one version.
pub const Migration = struct {
    /// The version this migration upgrades a document to.
    to: u32,
    steps: []const Step,
};

/// Where a document keeps its version.
pub const Options = struct {
    version_key: []const u8 = "schema_version",
};

/// What `run` did.
pub const Result = struct {
    /// The document's version before.
    from: u32,
    /// Its version after: `from` when nothing applied.
    to: u32,
};

/// What `run` can fail with.
pub const Error = error{ InvalidVersion, NotATable, MigrationFailed } || Allocator.Error;

/// Applies to `tree` every migration newer than its version, in order. `migrations` must
/// be sorted by `to`.
pub fn run(
    arena: Allocator,
    tree: *Value,
    migrations: []const Migration,
    options: Options,
) Error!Result {
    if (tree.* != .table) return error.NotATable;
    const from: u32 = if (tree.lookup(options.version_key)) |version| switch (version) {
        .int => |i| std.math.cast(u32, i) orelse return error.InvalidVersion,
        .string => |s| std.fmt.parseInt(u32, s, 10) catch return error.InvalidVersion,
        else => return error.InvalidVersion,
    } else 1;
    var current = from;
    for (migrations) |migration| {
        if (migration.to <= current) continue;
        for (migration.steps) |step| try apply(arena, tree, step);
        current = migration.to;
    }
    if (current != from) {
        tree.put(arena, options.version_key, .{ .int = current }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotATable,
        };
    }
    return .{ .from = from, .to = current };
}

fn apply(arena: Allocator, tree: *Value, step: Step) Error!void {
    switch (step) {
        .rename => |r| {
            const value = tree.lookup(r.from) orelse return;
            const moved = try value.clone(arena);
            _ = tree.remove(r.from);
            tree.put(arena, r.to, moved) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MigrationFailed,
            };
        },
        .remove => |key| _ = tree.remove(key),
        .set => |s| if (tree.lookup(s.key) == null) {
            tree.put(arena, s.key, try s.value.clone(arena)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MigrationFailed,
            };
        },
        .custom => |function| function(arena, tree) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.MigrationFailed;
        },
    }
}

const testing = std.testing;
const json = @import("json.zig");

fn splitAddress(arena: Allocator, tree: *Value) anyerror!void {
    const address = (tree.lookup("address") orelse return).string;
    const colon = std.mem.indexOfScalar(u8, address, ':') orelse return error.NoPort;
    try tree.put(arena, "host", .{ .string = address[0..colon] });
    try tree.put(arena, "port", .{ .string = address[colon + 1 ..] });
    _ = tree.remove("address");
}

const test_migrations = [_]Migration{
    .{ .to = 2, .steps = &.{.{ .rename = .{ .from = "name", .to = "app.name" } }} },
    .{ .to = 3, .steps = &.{
        .{ .remove = "legacy" },
        .{ .set = .{ .key = "mode", .value = .{ .string = "safe" } } },
        .{ .custom = splitAddress },
    } },
};

test run {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try json.parse(a, "{\"name\": \"x\", \"legacy\": 1, \"address\": \"h:80\"}", null);
    const result = try run(a, &tree, &test_migrations, .{});
    try testing.expectEqual(1, result.from);
    try testing.expectEqual(3, result.to);
    try testing.expectEqualStrings("x", tree.lookup("app.name").?.string);
    try testing.expectEqual(null, tree.lookup("legacy"));
    try testing.expectEqualStrings("safe", tree.lookup("mode").?.string);
    try testing.expectEqualStrings("80", tree.lookup("port").?.string);
    try testing.expectEqual(3, tree.lookup("schema_version").?.int);

    // Already current: nothing changes.
    const again = try run(a, &tree, &test_migrations, .{});
    try testing.expectEqual(3, again.from);
    try testing.expectEqual(3, again.to);

    const two = "{\"schema_version\": 2, \"name\": \"kept\", \"address\": \"h\"}";
    var from_two = try json.parse(a, two, null);
    try testing.expectError(error.MigrationFailed, run(a, &from_two, &test_migrations, .{}));
    var bad = try json.parse(a, "{\"schema_version\": \"two\"}", null);
    try testing.expectError(error.InvalidVersion, run(a, &bad, &test_migrations, .{}));
}
