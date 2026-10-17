//! `tui.zon`, at a project's root: where its components live and, for each installed
//! component, the SHA-256 of every file as the registry last wrote it.
//!
//! ```zig
//! .{
//!     .dir = "src/ui",
//!     .components = .{
//!         .select = .{
//!             .files = .{
//!                 .@"select.zig" = "<SHA-256 of the file, 64 lowercase hex digits>",
//!             },
//!         },
//!     },
//! }
//! ```
//!
//! A file whose hash still matches is the registry's, and `snek tui add` may replace it; a
//! file whose hash differs was edited, and is left alone without `--force`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const cfg = @import("cfg");
const project = @import("../../cli/project.zig");

pub const file_name = "tui.zon";
pub const default_dir = "src/ui";

/// A SHA-256 digest in lowercase hexadecimal.
pub const Hash = [Sha256.digest_length * 2]u8;

pub fn hash(content: []const u8) Hash {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// File path (relative to `dir`) to its hash.
pub const Files = std.StringArrayHashMapUnmanaged(Hash);

pub const Manifest = struct {
    /// The component directory, relative to the project root.
    dir: []const u8,
    /// Component name to its files.
    components: std.StringArrayHashMapUnmanaged(Files) = .empty,

    /// The hash recorded for `path` of `component`.
    pub fn recorded(m: Manifest, component: []const u8, path: []const u8) ?Hash {
        const files = m.components.get(component) orelse return null;
        return files.get(path);
    }
};

pub const ParseError = error{
    SyntaxError,
    /// Valid ZON, but not the shape above, or a path that is not a plain relative path.
    InvalidManifest,
} || Allocator.Error;

/// Reads `tui.zon`. All memory comes from `arena`.
pub fn parse(arena: Allocator, text: []const u8) ParseError!Manifest {
    const root = try cfg.Format.zon.parse(arena, text, null);
    if (root != .table) return error.InvalidManifest;
    const dir = root.table.get("dir") orelse return error.InvalidManifest;
    if (dir != .string or !project.isSafeRelative(dir.string)) return error.InvalidManifest;
    var m: Manifest = .{ .dir = dir.string };
    const components = root.table.get("components") orelse cfg.Value.empty_table;
    if (components != .table) return error.InvalidManifest;
    var it = components.table.iterator();
    while (it.next()) |entry| {
        try m.components.put(arena, entry.key_ptr.*, try parseFiles(arena, entry.value_ptr.*));
    }
    return m;
}

fn parseFiles(arena: Allocator, value: cfg.Value) ParseError!Files {
    if (value != .table) return error.InvalidManifest;
    const table = value.table.get("files") orelse cfg.Value.empty_table;
    if (table != .table) return error.InvalidManifest;
    var files: Files = .empty;
    var it = table.table.iterator();
    while (it.next()) |entry| {
        const text = entry.value_ptr.*;
        if (!project.isSafeRelative(entry.key_ptr.*)) return error.InvalidManifest;
        if (text != .string or !isHash(text.string)) return error.InvalidManifest;
        try files.put(arena, entry.key_ptr.*, text.string[0..@sizeOf(Hash)].*);
    }
    return files;
}

fn isHash(text: []const u8) bool {
    if (text.len != @sizeOf(Hash)) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// `m` as ZON, components sorted by name, as `zig fmt` would leave it.
pub fn render(arena: Allocator, m: Manifest) Allocator.Error![]const u8 {
    var components: cfg.Value = .empty_table;
    const names = try arena.dupe([]const u8, m.components.keys());
    std.mem.sort([]const u8, names, {}, lessThan);
    for (names) |name| {
        var files: cfg.Value = .empty_table;
        var it = m.components.get(name).?.iterator();
        while (it.next()) |entry| {
            const text = try arena.dupe(u8, entry.value_ptr);
            try files.table.put(arena, entry.key_ptr.*, .{ .string = text });
        }
        var entry: cfg.Value = .empty_table;
        try entry.table.put(arena, "files", files);
        try components.table.put(arena, name, entry);
    }
    var root: cfg.Value = .empty_table;
    try root.table.put(arena, "dir", .{ .string = m.dir });
    try root.table.put(arena, "components", components);
    var out: std.Io.Writer.Allocating = .init(arena);
    // Keys are non-empty and nesting is shallow, so only allocation can fail.
    cfg.zon.write(&out.writer, root, .{}) catch return error.OutOfMemory;
    return out.written();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The project path of component file `path`, `/`-separated on every system.
pub fn filePath(arena: Allocator, m: Manifest, path: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ m.dir, "/", path });
}

const testing = std.testing;

const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

test hash {
    try testing.expectEqualStrings(empty_hash, &hash(""));
}

test "render and parse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: Manifest = .{ .dir = "src/ui" };
    try testing.expectEqualStrings(
        \\.{
        \\    .dir = "src/ui",
        \\    .components = .{},
        \\}
        \\
    , try render(arena, empty));

    var m = try parse(arena, try render(arena, empty));
    try testing.expectEqualStrings("src/ui", m.dir);
    var files: Files = .empty;
    try files.put(arena, "select.zig", hash(""));
    try m.components.put(arena, "select", files);
    try m.components.put(arena, "list", .empty);
    const text = try render(arena, m);
    try testing.expectEqualStrings(
        \\.{
        \\    .dir = "src/ui",
        \\    .components = .{
        \\        .list = .{
        \\            .files = .{},
        \\        },
        \\        .select = .{
        \\            .files = .{
        \\
    ++ "                .@\"select.zig\" = \"" ++ empty_hash ++ "\",\n" ++
        \\            },
        \\        },
        \\    },
        \\}
        \\
    , text);
    const again = try parse(arena, text);
    try testing.expectEqualSlices(u8, &hash(""), &again.recorded("select", "select.zig").?);
    try testing.expectEqual(null, again.recorded("select", "other.zig"));
    try testing.expectEqual(null, again.recorded("list", "list.zig"));
}

test "parse rejects what it cannot trust" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.SyntaxError, parse(arena, ".{ .dir = }"));
    try testing.expectError(error.InvalidManifest, parse(arena, ".{ .components = .{} }"));
    try testing.expectError(error.InvalidManifest, parse(arena, ".{ .dir = \"../out\" }"));
    try testing.expectError(error.InvalidManifest, parse(arena, ".{ .dir = \"/etc\" }"));
    try testing.expectError(
        error.InvalidManifest,
        parse(arena, ".{ .dir = \"ui\", .components = .{ .a = .{ .files = .{ .x = \"1\" } } } }"),
    );
    try testing.expectError(
        error.InvalidManifest,
        parse(arena, ".{ .dir = \"ui\", .components = .{ .a = .{ .files = .{ .@\"../x\" = \"" ++
            empty_hash ++ "\" } } } }"),
    );
}
