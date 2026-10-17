//! Blocks of styled text placed at positions and stacked by depth, as Lip Gloss v2's
//! canvas and layers: dialogs over a screen, toasts in a corner, a popup by the cursor.
//! Each layer covers what is under it, cell by cell, where it has cells; the result is
//! one block of text, as wide and high as the canvas.
//!
//! ```zig
//! const canvas: term.Canvas = .{ .layers = &.{
//!     .{ .text = screen },
//!     .{ .text = dialog, .x = 20, .y = 5, .z = 1 },
//! } };
//! try canvas.render(gpa, w);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const layout = @import("layout.zig");
const capability = @import("capability.zig");
const Buffer = @import("Buffer.zig");

const Canvas = @This();

layers: []const Layer,
/// The canvas's size; null to fit the layers.
width: ?usize = null,
height: ?usize = null,

/// A block of text at a position.
pub const Layer = struct {
    text: []const u8,
    /// Columns from the left, rows from the top.
    x: usize = 0,
    y: usize = 0,
    /// Higher layers cover lower ones; layers of the same depth cover in order.
    z: i32 = 0,
};

/// The size that holds every layer, or the given size.
pub fn size(c: Canvas) layout.Size {
    var w: usize = 0;
    var h: usize = 1;
    for (c.layers) |layer| {
        const block = layout.size(layer.text);
        w = @max(w, layer.x + block.width);
        h = @max(h, layer.y + block.height);
    }
    return .{ .width = c.width orelse w, .height = c.height orelse h };
}

/// Writes the composed canvas: every row as wide as the canvas, `\n` between rows.
pub fn render(c: Canvas, gpa: Allocator, w: *Writer) (Writer.Error || Allocator.Error)!void {
    const area = c.size();
    if (area.width == 0) return w.splatBytesAll("\n", area.height - 1);
    var buffer: Buffer = .init(gpa);
    defer buffer.deinit();
    try buffer.reset(area.width, area.height);
    const order = try gpa.alloc(usize, c.layers.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.sort.insertion(usize, order, c.layers, struct {
        fn less(layers: []const Layer, a: usize, b: usize) bool {
            return layers[a].z < layers[b].z;
        }
    }.less);
    for (order) |i| {
        const layer = c.layers[i];
        try buffer.draw(layer.x, layer.y, layer.text);
    }
    try buffer.writeText(w, .truecolor, true);
}

/// `render` into memory the caller owns.
pub fn renderAlloc(c: Canvas, gpa: Allocator) (Writer.Error || Allocator.Error)![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try c.render(gpa, &out.writer);
    return out.toOwnedSlice();
}

const testing = std.testing;
const ansi = @import("ansi.zig");

test "layers cover what is under them, by depth" {
    const canvas: Canvas = .{ .layers = &.{
        .{ .text = "top", .x = 1, .y = 1, .z = 2 },
        .{ .text = "......\n......\n......" },
        .{ .text = "MID\nMID", .x = 2, .y = 0, .z = 1 },
    } };
    const text = try canvas.renderAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("..MID.\n.topD.\n......", text);
}

test "a canvas of a given size cuts and pads" {
    const canvas: Canvas = .{ .width = 4, .height = 2, .layers = &.{
        .{ .text = "\x1b[1mbold\x1b[0m text" },
        .{ .text = "x", .x = 9 },
    } };
    const text = try canvas.renderAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("\x1b[1mbold\x1b[0m\n    ", text);
}

test "a wide character under a layer's edge is cut cleanly" {
    const canvas: Canvas = .{ .layers = &.{
        .{ .text = "中中中" },
        .{ .text = "|", .x = 3 },
    } };
    const text = try canvas.renderAlloc(testing.allocator);
    defer testing.allocator.free(text);
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try ansi.strip(&plain.writer, text);
    try testing.expectEqualStrings("中 |中", plain.written());
}
