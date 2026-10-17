//! Arranging rendered blocks of text: joining them side by side or stacked, and placing
//! one in a larger box. A block is a string whose lines are separated by `\n`; widths are
//! display widths, so styled (escaped) and wide text lines up. Output is rectangular: every
//! line is padded with spaces to the full width.

const std = @import("std");
const Writer = std.Io.Writer;
const width = @import("width.zig");

/// Where a smaller block sits along an axis.
pub const Position = enum {
    /// Left, or top.
    start,
    center,
    /// Right, or bottom.
    end,

    /// The space before a block of `extent` in `room`; the rest goes after.
    pub fn offset(position: Position, extent: usize, room: usize) usize {
        const free = room -| extent;
        return switch (position) {
            .start => 0,
            .center => free / 2,
            .end => free,
        };
    }
};

/// The width and height of a block.
pub const Size = struct {
    width: usize,
    height: usize,
};

/// The size of `block`. Every block has at least one line, so "" is 0 wide and 1 high.
pub fn size(block: []const u8) Size {
    return .{ .width = width.of(block), .height = std.mem.count(u8, block, "\n") + 1 };
}

/// How much of a row or column one part of a `split` takes.
pub const Constraint = union(enum) {
    /// Exactly this many cells, as far as there are.
    length: usize,
    /// This percentage of the whole.
    percent: u8,
    /// A share of what the fixed parts leave, by weight: `.fill = 1` twice halves it.
    fill: u16,
    /// At least this many cells, and a share of what is left like `.fill = 1`.
    min: usize,
    /// At most this many cells, and a share of what is left like `.fill = 1`.
    max: usize,
};

/// Divides `total` cells among `constraints`, into `out` (as long as `constraints`):
/// lengths and percentages first, then the rest shared by weight among fills, mins, and
/// maxes, `gap` cells between parts. When the fixed parts do not fit, the later ones
/// shrink. The sizes always add up to `total` minus the gaps, unless no part can grow.
///
/// ```zig
/// var columns: [3]usize = undefined;
/// layout.split(80, &.{ .{ .length = 20 }, .{ .fill = 1 }, .{ .percent = 25 } }, 1, &columns);
/// // 20, 38, 20
/// ```
pub fn split(total: usize, constraints: []const Constraint, gap: usize, out: []usize) void {
    std.debug.assert(out.len == constraints.len);
    if (constraints.len == 0) return;
    const room = total -| gap * (constraints.len - 1);
    var left = room;
    // Fixed parts, in order, as far as they fit.
    for (constraints, out) |constraint, *size_out| {
        const want: usize = switch (constraint) {
            .length => |n| n,
            .percent => |p| room * @min(p, 100) / 100,
            .min => |n| n,
            .fill, .max => 0,
        };
        size_out.* = @min(want, left);
        left -= size_out.*;
    }
    // What is left, shared by weight; a part at its `max` stops and passes the rest on.
    while (left > 0) {
        var weights: usize = 0;
        for (constraints, out) |constraint, size_out| weights += weightOf(constraint, size_out);
        if (weights == 0) break;
        const share = left;
        var given: usize = 0;
        for (constraints, out) |constraint, *size_out| {
            const weight = weightOf(constraint, size_out.*);
            if (weight == 0) continue;
            var add = share * weight / weights;
            if (constraint == .max) add = @min(add, constraint.max - size_out.*);
            size_out.* += add;
            given += add;
        }
        left -= given;
        if (given == 0) {
            // Rounding left a few cells: one each to the first parts that can grow.
            for (constraints, out) |constraint, *size_out| {
                if (left == 0) break;
                if (weightOf(constraint, size_out.*) == 0) continue;
                size_out.* += 1;
                left -= 1;
            }
            break;
        }
    }
}

fn weightOf(constraint: Constraint, current: usize) usize {
    return switch (constraint) {
        .fill => |w| w,
        .min => 1,
        .max => |n| @intFromBool(current < n),
        .length, .percent => 0,
    };
}

/// Writes `blocks` side by side, each `position` along the vertical axis within the tallest.
pub fn joinHorizontal(
    w: *Writer,
    position: Position,
    blocks: []const []const u8,
) Writer.Error!void {
    var height: usize = 0;
    for (blocks) |block| height = @max(height, size(block).height);
    for (0..height) |row| {
        if (row > 0) try w.writeByte('\n');
        for (blocks) |block| {
            const block_size = size(block);
            const top = position.offset(block_size.height, height);
            const line = if (row >= top) lineAt(block, row - top) else null;
            try writePadded(w, line orelse "", block_size.width, .start);
        }
    }
}

/// Writes `blocks` one above the other, each line `position`ed within the widest.
pub fn joinVertical(w: *Writer, position: Position, blocks: []const []const u8) Writer.Error!void {
    var total: usize = 0;
    for (blocks) |block| total = @max(total, width.of(block));
    for (blocks, 0..) |block, i| {
        if (i > 0) try w.writeByte('\n');
        try writeLines(w, block, total, position);
    }
}

/// Writes `block` inside a box of `box_width` by `box_height`, positioned on each axis. A
/// block larger than the box is not cut; the box grows to fit it.
pub fn place(
    w: *Writer,
    box_width: usize,
    box_height: usize,
    horizontal: Position,
    vertical: Position,
    block: []const u8,
) Writer.Error!void {
    const block_size = size(block);
    const full_width = @max(box_width, block_size.width);
    const full_height = @max(box_height, block_size.height);
    const top = vertical.offset(block_size.height, full_height);
    for (0..full_height) |row| {
        if (row > 0) try w.writeByte('\n');
        const line = if (row >= top) lineAt(block, row - top) else null;
        if (line) |text| {
            try writePadded(w, text, full_width, horizontal);
        } else {
            try w.splatByteAll(' ', full_width);
        }
    }
}

/// Writes each line of `block` padded to `total` columns.
fn writeLines(w: *Writer, block: []const u8, total: usize, position: Position) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, block, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try w.writeByte('\n');
        first = false;
        try writePadded(w, line, total, position);
    }
}

/// Writes `line` with spaces around it to fill `total` columns.
pub fn writePadded(
    w: *Writer,
    line: []const u8,
    total: usize,
    position: Position,
) Writer.Error!void {
    const line_width = width.of(line);
    const before = position.offset(line_width, total);
    try w.splatByteAll(' ', before);
    try w.writeAll(line);
    try w.splatByteAll(' ', total -| (before + line_width));
}

/// Line `index` of `block`, or null past the end.
fn lineAt(block: []const u8, index: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, block, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        if (i == index) return line;
    }
    return null;
}

const testing = std.testing;

fn expectJoin(
    expected: []const u8,
    comptime join: anytype,
    position: Position,
    blocks: []const []const u8,
) !void {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try join(&w, position, blocks);
    try testing.expectEqualStrings(expected, w.buffered());
}

test size {
    try testing.expectEqual(Size{ .width = 0, .height = 1 }, size(""));
    try testing.expectEqual(Size{ .width = 3, .height = 2 }, size("abc\nd"));
    try testing.expectEqual(Size{ .width = 4, .height = 1 }, size("\x1b[1m中文\x1b[0m"));
    try testing.expectEqual(Size{ .width = 1, .height = 2 }, size("a\n"));
}

test "Position.offset" {
    try testing.expectEqual(0, Position.start.offset(3, 10));
    try testing.expectEqual(3, Position.center.offset(3, 10));
    try testing.expectEqual(7, Position.end.offset(3, 10));
    try testing.expectEqual(0, Position.end.offset(12, 10));
}

test joinHorizontal {
    try expectJoin("ab12\ncd34", joinHorizontal, .start, &.{ "ab\ncd", "12\n34" });
    try expectJoin("ab1\ncd \nef ", joinHorizontal, .start, &.{ "ab\ncd\nef", "1" });
    try expectJoin("ab \ncd1\nef ", joinHorizontal, .center, &.{ "ab\ncd\nef", "1" });
    try expectJoin("ab \ncd \nef1", joinHorizontal, .end, &.{ "ab\ncd\nef", "1" });
    // Ragged blocks are squared off, and escapes take no room.
    try expectJoin("a  |x\nbbb|y", joinHorizontal, .start, &.{ "a\nbbb", "|x\n|y" });
    try expectJoin("\x1b[1mA\x1b[0m  中\nbb 文", joinHorizontal, .start, &.{
        "\x1b[1mA\x1b[0m\nbb",
        " 中\n 文",
    });
    try expectJoin("", joinHorizontal, .start, &.{});
    try expectJoin("ab", joinHorizontal, .start, &.{"ab"});
}

test joinVertical {
    try expectJoin("abc\nd  ", joinVertical, .start, &.{ "abc", "d" });
    try expectJoin("abc\n d \nxyz", joinVertical, .center, &.{ "abc", "d", "xyz" });
    try expectJoin("abcd\n  ef", joinVertical, .end, &.{ "abcd", "ef" });
    try expectJoin("中文\n    ", joinVertical, .start, &.{ "中文", "" });
    try expectJoin("", joinVertical, .start, &.{});
}

fn expectPlace(
    expected: []const u8,
    box: [2]usize,
    horizontal: Position,
    vertical: Position,
    block: []const u8,
) !void {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try place(&w, box[0], box[1], horizontal, vertical, block);
    try testing.expectEqualStrings(expected, w.buffered());
}

test place {
    try expectPlace("     \n  x  \n     ", .{ 5, 3 }, .center, .center, "x");
    try expectPlace("x    \n     ", .{ 5, 2 }, .start, .start, "x");
    try expectPlace("     \n    x", .{ 5, 2 }, .end, .end, "x");
    try expectPlace(" ab \n cd ", .{ 4, 2 }, .center, .center, "ab\ncd");
    // Too big for the box: the box grows.
    try expectPlace("abcdef\nxy    ", .{ 3, 1 }, .start, .start, "abcdef\nxy");
}

test split {
    var three: [3]usize = undefined;
    split(80, &.{ .{ .length = 20 }, .{ .fill = 1 }, .{ .percent = 25 } }, 1, &three);
    try std.testing.expectEqualSlices(usize, &.{ 20, 39, 19 }, &three);
    var weighted: [2]usize = undefined;
    split(9, &.{ .{ .fill = 1 }, .{ .fill = 2 } }, 0, &weighted);
    try std.testing.expectEqualSlices(usize, &.{ 3, 6 }, &weighted);
    // Too little room: later fixed parts shrink.
    split(10, &.{ .{ .length = 8 }, .{ .length = 8 } }, 0, &weighted);
    try std.testing.expectEqualSlices(usize, &.{ 8, 2 }, &weighted);
    // A max stops growing and passes the rest on.
    split(30, &.{ .{ .max = 5 }, .{ .fill = 1 } }, 0, &weighted);
    try std.testing.expectEqualSlices(usize, &.{ 5, 25 }, &weighted);
    split(30, &.{ .{ .min = 20 }, .{ .fill = 1 } }, 0, &weighted);
    try std.testing.expectEqualSlices(usize, &.{ 25, 5 }, &weighted);
    // Rounding: the sizes still add up.
    split(10, &.{ .{ .fill = 1 }, .{ .fill = 1 }, .{ .fill = 1 } }, 0, &three);
    try std.testing.expectEqual(10, three[0] + three[1] + three[2]);
}

test "split adds up for any constraints that can grow" {
    var prng: std.Random.DefaultPrng = .init(5);
    const random = prng.random();
    for (0..2000) |_| {
        var constraints: [5]Constraint = undefined;
        var out: [5]usize = undefined;
        const n = random.intRangeAtMost(usize, 1, 5);
        var grows = false;
        for (constraints[0..n]) |*c| c.* = switch (random.uintLessThan(u8, 5)) {
            0 => .{ .length = random.uintLessThan(usize, 50) },
            1 => .{ .percent = random.uintAtMost(u8, 100) },
            2 => blk: {
                grows = true;
                break :blk .{ .fill = random.intRangeAtMost(u16, 1, 4) };
            },
            3 => blk: {
                grows = true;
                break :blk .{ .min = random.uintLessThan(usize, 40) };
            },
            else => .{ .max = random.uintLessThan(usize, 40) },
        };
        const total = random.uintLessThan(usize, 200);
        const gap = random.uintLessThan(usize, 3);
        split(total, constraints[0..n], gap, out[0..n]);
        var sum: usize = 0;
        for (out[0..n]) |size_n| sum += size_n;
        const room = total -| gap * (n - 1);
        try std.testing.expect(sum <= room);
        if (grows) try std.testing.expectEqual(room, sum);
    }
}
