//! The registry's catalog: `registry.zon` read into components, and the order in which a
//! set of components and everything they require is installed.
//!
//! ```zig
//! .{ .components = .{
//!     .select = .{ .summary = "Pick one item", .files = .{"select.zig"}, .requires = .{"list"} },
//! } }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const cfg = @import("cfg");
const project = @import("../../cli/project.zig");

pub const Component = struct {
    name: []const u8,
    summary: []const u8,
    /// Paths relative to the registry, and to the project's component directory.
    files: []const []const u8,
    /// Names of other components.
    requires: []const []const u8,
};

/// A component source file, as the registry embeds it.
pub const File = struct { name: []const u8, source: []const u8 };

pub const ParseError = error{
    SyntaxError,
    /// Valid ZON, but not the shape above, or a file path that is not a plain relative path.
    InvalidCatalog,
} || Allocator.Error;

/// Reads `registry.zon`. All memory comes from `arena`.
pub fn parse(arena: Allocator, text: []const u8) ParseError![]const Component {
    const root = try cfg.Format.zon.parse(arena, text, null);
    if (root != .table) return error.InvalidCatalog;
    const table = root.table.get("components") orelse return error.InvalidCatalog;
    if (table != .table) return error.InvalidCatalog;
    var components: std.ArrayList(Component) = .empty;
    var it = table.table.iterator();
    while (it.next()) |entry| {
        try components.append(arena, try component(arena, entry.key_ptr.*, entry.value_ptr.*));
    }
    return components.items;
}

fn component(arena: Allocator, name: []const u8, value: cfg.Value) ParseError!Component {
    if (value != .table) return error.InvalidCatalog;
    const summary = value.table.get("summary") orelse cfg.Value{ .string = "" };
    if (summary != .string) return error.InvalidCatalog;
    const files = try strings(arena, value.table.get("files") orelse return error.InvalidCatalog);
    for (files) |file| {
        if (!project.isSafeRelative(file)) return error.InvalidCatalog;
    }
    const requires = value.table.get("requires") orelse cfg.Value.empty_table;
    return .{
        .name = name,
        .summary = summary.string,
        .files = files,
        .requires = try strings(arena, requires),
    };
}

/// A tuple of strings. `.{}` reads as an empty table, so that is an empty list too.
fn strings(arena: Allocator, value: cfg.Value) ParseError![]const []const u8 {
    switch (value) {
        .table => |t| return if (t.count() == 0) &.{} else error.InvalidCatalog,
        .array => |a| {
            const list = try arena.alloc([]const u8, a.items.len);
            for (a.items, list) |item, *out| {
                if (item != .string) return error.InvalidCatalog;
                out.* = item.string;
            }
            return list;
        },
        else => return error.InvalidCatalog,
    }
}

/// The component called `name`.
pub fn find(components: []const Component, name: []const u8) ?*const Component {
    for (components) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// The source of the registry file `name`.
pub fn source(files: []const File, name: []const u8) ?[]const u8 {
    for (files) |file| {
        if (std.mem.eql(u8, file.name, name)) return file.source;
    }
    return null;
}

pub const ResolveError = error{
    /// A name, given or required, is not in the catalog.
    UnknownComponent,
    /// A component requires itself, directly or not.
    DependencyCycle,
} || Allocator.Error;

/// `names` and everything they require, transitively, each once, every component after
/// the components it requires. On an error, `culprit` is the unknown name, or a component
/// on the cycle.
pub fn resolve(
    arena: Allocator,
    components: []const Component,
    names: []const []const u8,
    culprit: *[]const u8,
) ResolveError![]const *const Component {
    const marks = try arena.alloc(Mark, components.len);
    @memset(marks, .unseen);
    var order: std.ArrayList(*const Component) = .empty;
    var walk: Walk = .{
        .arena = arena,
        .components = components,
        .marks = marks,
        .order = &order,
        .culprit = culprit,
    };
    for (names) |name| try walk.visit(name);
    return order.items;
}

const Mark = enum { unseen, visiting, done };

/// A depth-first walk; a component met again while it is being visited closes a cycle.
const Walk = struct {
    arena: Allocator,
    components: []const Component,
    marks: []Mark,
    order: *std.ArrayList(*const Component),
    culprit: *[]const u8,

    fn visit(walk: *Walk, name: []const u8) ResolveError!void {
        const c = find(walk.components, name) orelse {
            walk.culprit.* = name;
            return error.UnknownComponent;
        };
        const index = c - walk.components.ptr;
        switch (walk.marks[index]) {
            .done => return,
            .visiting => {
                walk.culprit.* = name;
                return error.DependencyCycle;
            },
            .unseen => {},
        }
        walk.marks[index] = .visiting;
        for (c.requires) |required| try walk.visit(required);
        walk.marks[index] = .done;
        try walk.order.append(walk.arena, c);
    }
};

const testing = std.testing;

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const components = try parse(arena,
        \\.{ .components = .{
        \\    .list = .{ .summary = "A list", .files = .{"list.zig"} },
        \\    .select = .{
        \\        .summary = "Pick one",
        \\        .files = .{ "select.zig", "select/keys.zig" },
        \\        .requires = .{"list"},
        \\    },
        \\    .bare = .{ .files = .{}, .requires = .{} },
        \\} }
    );
    try testing.expectEqual(3, components.len);
    const select = find(components, "select").?;
    try testing.expectEqualStrings("Pick one", select.summary);
    try testing.expectEqualStrings("select/keys.zig", select.files[1]);
    try testing.expectEqualStrings("list", select.requires[0]);
    try testing.expectEqual(0, find(components, "list").?.requires.len);
    try testing.expectEqual(0, find(components, "bare").?.files.len);
    try testing.expectEqual(null, find(components, "nope"));

    try testing.expectError(error.SyntaxError, parse(arena, ".{"));
    try testing.expectError(error.InvalidCatalog, parse(arena, ".{ .x = 1 }"));
    try testing.expectError(error.InvalidCatalog, parse(arena, ".{ .components = .{ .a = 1 } }"));
    try testing.expectError(error.InvalidCatalog, parse(arena, ".{ .components = .{ .a = .{} } }"));
    try testing.expectError(
        error.InvalidCatalog,
        parse(arena, ".{ .components = .{ .a = .{ .files = .{\"../x.zig\"} } } }"),
    );
    try testing.expectError(
        error.InvalidCatalog,
        parse(arena, ".{ .components = .{ .a = .{ .files = .{ 1, 2 } } } }"),
    );
}

fn joinNames(order: []const *const Component) ![]const u8 {
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    for (order) |c| try w.print("{s} ", .{c.name});
    return testing.allocator.dupe(u8, w.buffered());
}

test resolve {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const components = [_]Component{
        .{ .name = "form", .summary = "", .files = &.{}, .requires = &.{ "input", "select" } },
        .{ .name = "select", .summary = "", .files = &.{}, .requires = &.{"list"} },
        .{ .name = "input", .summary = "", .files = &.{}, .requires = &.{} },
        .{ .name = "list", .summary = "", .files = &.{}, .requires = &.{} },
        .{ .name = "a", .summary = "", .files = &.{}, .requires = &.{"b"} },
        .{ .name = "b", .summary = "", .files = &.{}, .requires = &.{"a"} },
        .{ .name = "broken", .summary = "", .files = &.{}, .requires = &.{"gone"} },
    };
    var culprit: []const u8 = "";
    const order = try resolve(arena, &components, &.{ "select", "form", "list" }, &culprit);
    const text = try joinNames(order);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("list select input form ", text);

    try testing.expectError(error.UnknownComponent, resolve(arena, &components, &.{"x"}, &culprit));
    try testing.expectEqualStrings("x", culprit);
    try testing.expectError(
        error.UnknownComponent,
        resolve(arena, &components, &.{"broken"}, &culprit),
    );
    try testing.expectEqualStrings("gone", culprit);
    try testing.expectError(error.DependencyCycle, resolve(arena, &components, &.{"a"}, &culprit));
    try testing.expectEqualStrings("a", culprit);
}

test source {
    const files = [_]File{.{ .name = "list.zig", .source = "x" }};
    try testing.expectEqualStrings("x", source(&files, "list.zig").?);
    try testing.expectEqual(null, source(&files, "select.zig"));
}
