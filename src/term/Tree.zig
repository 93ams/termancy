//! A tree drawn as text, as Lip Gloss's `tree`: a root, children that are text or trees
//! of their own, branches drawn with box glyphs, and styles for the root, the branches,
//! and the items.
//!
//! ```zig
//! const src: term.Tree = .{ .root = "src", .children = &.{.{ .text = "main.zig" }} };
//! const tree: term.Tree = .{
//!     .root = ".",
//!     .children = &.{ .{ .tree = &src }, .{ .text = "build.zig" } },
//! };
//! try tree.render(w);
//! ```
//!
//! ```text
//! .
//! ├── src
//! │   └── main.zig
//! └── build.zig
//! ```

const std = @import("std");
const Writer = std.Io.Writer;
const Style = @import("Style.zig");

const Tree = @This();

/// The label above the children; empty for none (the children start at the left).
root: []const u8 = "",
children: []const Node,
enumerator: Enumerator = .default,
root_style: Style = .{},
/// The branch glyphs' style.
enumerator_style: Style = .{},
item_style: Style = .{},

/// An entry: text, or a tree with a root of its own.
pub const Node = union(enum) {
    text: []const u8,
    tree: *const Tree,
};

/// The glyphs of the branches.
pub const Enumerator = struct {
    /// Before every child but the last.
    middle: []const u8,
    /// Before the last child.
    last: []const u8,
    /// Under a child that has more children below it, and before the lines that follow.
    pipe: []const u8,
    /// Under the last child.
    space: []const u8,

    /// `├──`, `└──`.
    pub const default: Enumerator = .{
        .middle = "├── ",
        .last = "└── ",
        .pipe = "│   ",
        .space = "    ",
    };
    /// `├──`, `╰──`.
    pub const rounded: Enumerator = .{
        .middle = "├── ",
        .last = "╰── ",
        .pipe = "│   ",
        .space = "    ",
    };
    /// `|--`, `` `-- ``, for ASCII-only output.
    pub const ascii: Enumerator = .{
        .middle = "|-- ",
        .last = "`-- ",
        .pipe = "|   ",
        .space = "    ",
    };
};

/// Writes the tree, lines separated by `\n`.
pub fn render(t: Tree, w: *Writer) Writer.Error!void {
    var first = true;
    if (t.root.len > 0) {
        try t.root_style.paint(w, t.root);
        first = false;
    }
    var prefix: [64][]const u8 = undefined;
    try t.renderChildren(w, &prefix, 0, &first);
}

fn renderChildren(
    t: Tree,
    w: *Writer,
    prefix: *[64][]const u8,
    depth: usize,
    first: *bool,
) Writer.Error!void {
    for (t.children, 0..) |child, i| {
        const last = i + 1 == t.children.len;
        const label = switch (child) {
            .text => |text| text,
            .tree => |sub| sub.root,
        };
        var lines = std.mem.splitScalar(u8, label, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line| : (line_number += 1) {
            if (!first.*) try w.writeByte('\n');
            first.* = false;
            for (prefix[0..depth]) |part| try t.enumerator_style.paint(w, part);
            const glyph = if (line_number > 0)
                (if (last) t.enumerator.space else t.enumerator.pipe)
            else if (last) t.enumerator.last else t.enumerator.middle;
            try t.enumerator_style.paint(w, glyph);
            const style = if (child == .tree) child.tree.root_style else t.item_style;
            try style.paint(w, line);
        }
        if (child == .tree and depth < prefix.len) {
            prefix[depth] = if (last) t.enumerator.space else t.enumerator.pipe;
            var sub = child.tree.*;
            // A subtree draws with its parent's glyphs unless it has its own style.
            if (!sub.enumerator_style.hasSgr()) sub.enumerator_style = t.enumerator_style;
            try sub.renderChildren(w, prefix, depth + 1, first);
        }
    }
}

/// `render` into memory the caller owns.
pub fn renderAlloc(t: Tree, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    t.render(&out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

test "a tree of trees" {
    const lib: Tree = .{ .root = "lib", .children = &.{.{ .text = "a.zig" }} };
    const src: Tree = .{
        .root = "src",
        .children = &.{ .{ .tree = &lib }, .{ .text = "main.zig" } },
    };
    const tree: Tree = .{
        .root = ".",
        .children = &.{ .{ .tree = &src }, .{ .text = "build.zig" } },
    };
    const text = try tree.renderAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\.
        \\├── src
        \\│   ├── lib
        \\│   │   └── a.zig
        \\│   └── main.zig
        \\└── build.zig
    , text);
}

test "rounded, rootless, and items of several lines" {
    const tree: Tree = .{
        .children = &.{ .{ .text = "one\nmore" }, .{ .text = "two" } },
        .enumerator = .rounded,
    };
    const text = try tree.renderAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("├── one\n│   more\n╰── two", text);
}
