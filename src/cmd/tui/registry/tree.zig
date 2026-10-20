//! A tree that expands and collapses, with a cursor: files, outlines, nested settings.
//!
//! ```zig
//! var nodes = [_]Tree.Node{
//!     .{ .label = "src", .children = &src_nodes, .expanded = true },
//!     .{ .label = "build.zig" },
//! };
//! var tree: Tree = .{ .roots = &nodes, .height = 10 };
//! _ = tree.update(msg); // up/down, j/k, right/l, left/h, enter/space, home/end
//! const node = tree.current(); // *Tree.Node
//! ```
//!
//! The nodes are the caller's, and `expanded` lives in them, so a tree can be built from
//! any data and its state survives being redrawn. Keys: up/down (j/k) move; right (l)
//! expands, or moves to the first child of an expanded node; left (h) collapses, or moves
//! to the parent; enter and space toggle. Like `list`, the tree never quits: the model
//! that embeds it decides what choosing means. Nesting deeper than `max_depth` is not
//! shown.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;

const Tree = @This();

roots: []Node,
/// The index of the highlighted row among the visible ones.
cursor: usize = 0,
/// The first visible row shown.
offset: usize = 0,
/// The most rows shown at once.
height: usize = 10,
/// The terminal's width, from the last resize; rows are cut to fit.
width: ?usize = null,
styles: Styles = .{},

pub const max_depth = 32;

pub const Node = struct {
    label: []const u8,
    children: []Node = &.{},
    expanded: bool = false,
    /// For the caller: what the node stands for.
    data: usize = 0,

    pub fn isLeaf(node: *const Node) bool {
        return node.children.len == 0;
    }
};

pub const Styles = struct {
    cursor: tui.Style = .{ .fg = .{ .indexed = 212 } },
    node: tui.Style = .{},
    /// The expand and collapse markers.
    marker: tui.Style = .{ .fg = .{ .indexed = 240 } },
};

/// A visible row: the node, its depth, and the row of its parent.
pub const Row = struct {
    node: *Node,
    depth: usize,
    parent: ?usize,
};

/// Moves and toggles on navigation keys; records the terminal width. Never quits.
pub fn update(tree: *Tree, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .key => |key| _ = tree.handleKey(key),
        .mouse => |mouse| switch (mouse.button) {
            .wheel_up => tree.moveBy(-1),
            .wheel_down => tree.moveBy(1),
            else => {},
        },
        .resize => |size| tree.width = size.width,
        else => {},
    }
    return .none;
}

/// Applies a navigation key; returns whether the key was one.
pub fn handleKey(tree: *Tree, key: tui.input.Key) bool {
    if (key.matches("up") or key.matches("k")) {
        tree.moveBy(-1);
    } else if (key.matches("down") or key.matches("j")) {
        tree.moveBy(1);
    } else if (key.matches("home") or key.matches("g")) {
        tree.moveTo(0);
    } else if (key.matches("end") or key.matches("G")) {
        tree.moveTo(tree.visibleCount() -| 1);
    } else if (key.matches("pgup")) {
        tree.moveBy(-@as(isize, @intCast(@max(tree.height, 1))));
    } else if (key.matches("pgdown")) {
        tree.moveBy(@intCast(@max(tree.height, 1)));
    } else if (key.matches("right") or key.matches("l")) {
        const row = tree.currentRow() orelse return true;
        if (row.node.isLeaf()) return true;
        if (row.node.expanded) tree.moveBy(1) else row.node.expanded = true;
    } else if (key.matches("left") or key.matches("h")) {
        const row = tree.currentRow() orelse return true;
        if (row.node.expanded and !row.node.isLeaf()) {
            row.node.expanded = false;
        } else if (row.parent) |parent| tree.moveTo(parent);
    } else if (key.matches("enter") or key.matches("space")) {
        const row = tree.currentRow() orelse return true;
        if (!row.node.isLeaf()) row.node.expanded = !row.node.expanded;
        tree.moveTo(tree.cursor);
    } else return false;
    return true;
}

/// Moves the cursor by `delta` rows, stopping at either end.
pub fn moveBy(tree: *Tree, delta: isize) void {
    const target = @as(isize, @intCast(tree.cursor)) + delta;
    tree.moveTo(@intCast(@max(0, target)));
}

/// Puts the cursor on visible row `index` (clamped) and scrolls it into view.
pub fn moveTo(tree: *Tree, index: usize) void {
    const count = tree.visibleCount();
    tree.cursor = @min(index, count -| 1);
    const height = @max(tree.height, 1);
    if (tree.cursor < tree.offset) tree.offset = tree.cursor;
    if (tree.cursor >= tree.offset + height) tree.offset = tree.cursor + 1 - height;
    tree.offset = @min(tree.offset, count -| height);
}

/// The highlighted node, or null when the tree is empty.
pub fn current(tree: *const Tree) ?*Node {
    const row = tree.currentRow() orelse return null;
    return row.node;
}

/// The highlighted row, or null when the tree is empty.
pub fn currentRow(tree: *const Tree) ?Row {
    var rows = tree.visible();
    var i: usize = 0;
    while (rows.next()) |row| : (i += 1) if (i == tree.cursor) return row;
    return null;
}

/// The number of visible rows: roots, and the children of expanded nodes.
pub fn visibleCount(tree: *const Tree) usize {
    var rows = tree.visible();
    var count: usize = 0;
    while (rows.next()) |_| count += 1;
    return count;
}

/// The visible rows, in order.
pub fn visible(tree: *const Tree) Rows {
    var rows: Rows = .{};
    rows.stack[0] = .{ .nodes = tree.roots, .parent = null };
    rows.depth = 1;
    return rows;
}

pub const Rows = struct {
    stack: [max_depth]Frame = undefined,
    depth: usize = 0,
    index: usize = 0,

    const Frame = struct { nodes: []Node, next: usize = 0, parent: ?usize };

    pub fn next(rows: *Rows) ?Row {
        while (rows.depth > 0) {
            const frame = &rows.stack[rows.depth - 1];
            if (frame.next == frame.nodes.len) {
                rows.depth -= 1;
                continue;
            }
            const node = &frame.nodes[frame.next];
            frame.next += 1;
            const row: Row = .{ .node = node, .depth = rows.depth - 1, .parent = frame.parent };
            const index = rows.index;
            rows.index += 1;
            if (node.expanded and !node.isLeaf() and rows.depth < max_depth) {
                rows.stack[rows.depth] = .{ .nodes = node.children, .parent = index };
                rows.depth += 1;
            }
            return row;
        }
        return null;
    }
};

/// One row per visible node on screen, indented two columns a level, with ▸ before a
/// collapsed node and ▾ before an expanded one.
pub fn view(tree: *const Tree, w: *Writer) Writer.Error!void {
    var rows = tree.visible();
    var i: usize = 0;
    const end = tree.offset + tree.height;
    while (rows.next()) |row| : (i += 1) {
        if (i < tree.offset) continue;
        if (i >= end) break;
        if (i > tree.offset) try w.writeByte('\n');
        const is_cursor = i == tree.cursor;
        const style = if (is_cursor) tree.styles.cursor else tree.styles.node;
        try style.paint(w, if (is_cursor) "> " else "  ");
        for (0..row.depth) |_| try w.writeAll("  ");
        const marker = if (row.node.isLeaf()) "  " else if (row.node.expanded) "▾ " else "▸ ";
        try tree.styles.marker.paint(w, marker);
        const used = 4 + 2 * row.depth;
        try style.writeSgr(w);
        if (tree.width) |width| {
            try tui.width.truncate(w, row.node.label, width -| used, "…");
        } else {
            try w.writeAll(row.node.label);
        }
        if (style.hasSgr()) try w.writeAll(tui.ansi.reset);
    }
}

const testing = std.testing;
const plain: Tree.Styles = .{ .cursor = .{}, .node = .{}, .marker = .{} };

fn sample() [3]Tree.Node {
    const S = struct {
        var lib = [_]Tree.Node{ .{ .label = "a.zig" }, .{ .label = "b.zig" } };
        var src = [_]Tree.Node{ .{ .label = "lib", .children = &lib }, .{ .label = "main.zig" } };
    };
    for (&S.lib) |*n| n.expanded = false;
    for (&S.src) |*n| n.expanded = false;
    return .{
        .{ .label = "src", .children = &S.src },
        .{ .label = "build.zig" },
        .{ .label = "empty", .children = &.{} },
    };
}

test "expanding, moving into children, collapsing, and back to the parent" {
    var nodes = sample();
    var d: tui.testing.Driver(Tree) = try .init(
        testing.allocator,
        .{ .roots = &nodes, .styles = plain },
        .{},
    );
    defer d.deinit();
    try d.expectFrame("> ▸ src\n    build.zig\n    empty");
    try d.press("right");
    try d.expectFrame("> ▾ src\n    ▸ lib\n      main.zig\n    build.zig\n    empty");
    try d.press("l"); // already expanded: into the first child
    try d.press("enter");
    try d.expectFrame("  ▾ src\n>   ▾ lib\n        a.zig\n        b.zig\n      main.zig\n" ++
        "    build.zig\n    empty");
    try d.press("down");
    try testing.expectEqualStrings("a.zig", d.model().current().?.label);
    try d.press("h"); // a leaf: to its parent
    try testing.expectEqualStrings("lib", d.model().current().?.label);
    try d.press("h"); // expanded: collapse
    try d.press("h"); // collapsed: to its parent
    try testing.expectEqualStrings("src", d.model().current().?.label);
    try d.expectFrame("> ▾ src\n    ▸ lib\n      main.zig\n    build.zig\n    empty");
    try d.press("space");
    try d.expectFrame("> ▸ src\n    build.zig\n    empty");
    try testing.expect(!d.done());
}

test "the window scrolls with the cursor, and collapsing keeps the cursor in range" {
    var nodes = sample();
    nodes[0].expanded = true;
    nodes[0].children[0].expanded = true;
    var tree: Tree = .{ .roots = &nodes, .height = 3, .styles = plain };
    try testing.expectEqual(7, tree.visibleCount());
    tree.moveTo(6);
    try testing.expectEqualStrings("empty", tree.current().?.label);
    try testing.expectEqual(4, tree.offset);
    tree.moveTo(1);
    try testing.expectEqual(1, tree.offset);
    _ = tree.handleKey(try .parse("enter")); // collapse lib
    try testing.expectEqual(5, tree.visibleCount());
    tree.moveTo(99);
    try testing.expectEqualStrings("empty", tree.current().?.label);
    try testing.expectEqual(2, tree.offset);
}

test "an empty tree draws nothing and ignores keys" {
    var d: tui.testing.Driver(Tree) = try .init(testing.allocator, .{ .roots = &.{} }, .{});
    defer d.deinit();
    try d.expectFrame("");
    try d.press("right");
    try d.press("down");
    try d.press("enter");
    try testing.expectEqual(null, d.model().current());
}

test "labels are cut to the width" {
    var nodes = [_]Tree.Node{.{ .label = "a rather long label" }};
    const tree: Tree = .{ .roots = &nodes, .styles = plain };
    var d: tui.testing.Driver(Tree) = try .init(testing.allocator, tree, .{
        .program = .{ .size = .{ .width = 12, .height = 5 } },
    });
    defer d.deinit();
    try d.expectFrame(">   a rathe…");
}
