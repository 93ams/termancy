//! Which part of an interface has focus. `Ring` is tab order: tab and shift+tab move
//! through `count` parts. `Grid` is spatial: arrows (or h/j/k/l) move through parts laid out
//! in rows, as icons or cards are, the last row possibly short.
//!
//! ```zig
//! var fields: tui.focus.Ring = .{ .count = 3 };
//! // in update:
//! if (fields.handleKey(key)) return .none;
//! // in view:
//! const style = if (fields.is(1)) focused else plain;
//! ```

const std = @import("std");
const input = @import("term").input;

/// Tab order through `count` parts.
pub const Ring = struct {
    count: usize,
    index: usize = 0,
    /// Moving past either end comes back at the other.
    wrap: bool = true,

    /// Whether part `i` has focus.
    pub fn is(ring: Ring, i: usize) bool {
        return ring.index == i;
    }

    /// Focus moves to the next part.
    pub fn next(ring: *Ring) void {
        if (ring.count == 0) return;
        if (ring.index + 1 < ring.count) {
            ring.index += 1;
        } else if (ring.wrap) ring.index = 0;
    }

    /// Focus moves to the part before.
    pub fn prev(ring: *Ring) void {
        if (ring.count == 0) return;
        if (ring.index > 0) {
            ring.index -= 1;
        } else if (ring.wrap) ring.index = ring.count - 1;
    }

    /// Tab moves on, shift+tab back; returns whether the key was one of them.
    pub fn handleKey(ring: *Ring, key: input.Key) bool {
        if (key.matches("tab")) {
            ring.next();
        } else if (key.matches("shift+tab")) {
            ring.prev();
        } else return false;
        return true;
    }
};

/// A direction to move in a `Grid`.
pub const Direction = enum { up, down, left, right };

/// `count` parts in rows of `columns`, left to right, top to bottom.
pub const Grid = struct {
    count: usize,
    columns: usize,
    index: usize = 0,
    /// Moving past an edge comes back at the opposite one, in the same row or column.
    wrap: bool = false,

    /// Whether part `i` has focus.
    pub fn is(grid: Grid, i: usize) bool {
        return grid.index == i;
    }

    /// The row of the part with focus.
    pub fn row(grid: Grid) usize {
        return grid.index / @max(grid.columns, 1);
    }

    /// The column of the part with focus.
    pub fn column(grid: Grid) usize {
        return grid.index % @max(grid.columns, 1);
    }

    fn rows(grid: Grid) usize {
        const columns = @max(grid.columns, 1);
        return (grid.count + columns - 1) / columns;
    }

    /// The number of parts in row `r`.
    fn width(grid: Grid, r: usize) usize {
        const columns = @max(grid.columns, 1);
        return @min(columns, grid.count - r * columns);
    }

    /// Moves one step; a move into the short last row lands on its last part.
    pub fn move(grid: *Grid, direction: Direction) void {
        if (grid.count == 0) return;
        const columns = @max(grid.columns, 1);
        var r = grid.row();
        var c = grid.column();
        const last_row = grid.rows() - 1;
        switch (direction) {
            .left => {
                if (c > 0) {
                    c -= 1;
                } else if (grid.wrap) c = grid.width(r) - 1;
            },
            .right => {
                if (c + 1 < grid.width(r)) {
                    c += 1;
                } else if (grid.wrap) c = 0;
            },
            .up => {
                if (r > 0) {
                    r -= 1;
                } else if (grid.wrap) r = last_row;
            },
            .down => {
                if (r < last_row) {
                    r += 1;
                } else if (grid.wrap) r = 0;
            },
        }
        c = @min(c, grid.width(r) - 1);
        grid.index = r * columns + c;
    }

    /// Arrows and h/j/k/l move; returns whether the key was one of them.
    pub fn handleKey(grid: *Grid, key: input.Key) bool {
        const direction: Direction = if (key.matches("up") or key.matches("k"))
            .up
        else if (key.matches("down") or key.matches("j"))
            .down
        else if (key.matches("left") or key.matches("h"))
            .left
        else if (key.matches("right") or key.matches("l"))
            .right
        else
            return false;
        grid.move(direction);
        return true;
    }
};

const testing = std.testing;

test Ring {
    var ring: Ring = .{ .count = 3 };
    try testing.expect(ring.handleKey(try .parse("tab")));
    try testing.expect(ring.is(1));
    ring.next();
    ring.next();
    try testing.expectEqual(0, ring.index);
    try testing.expect(ring.handleKey(try .parse("shift+tab")));
    try testing.expectEqual(2, ring.index);
    try testing.expect(!ring.handleKey(try .parse("x")));
    var stuck: Ring = .{ .count = 2, .wrap = false };
    stuck.prev();
    try testing.expectEqual(0, stuck.index);
    var empty: Ring = .{ .count = 0 };
    empty.next();
    try testing.expectEqual(0, empty.index);
}

test Grid {
    // 0 1 2
    // 3 4 5
    // 6 7
    var grid: Grid = .{ .count = 8, .columns = 3, .index = 2 };
    grid.move(.down);
    grid.move(.down);
    try testing.expectEqual(7, grid.index); // the short row's last part
    grid.move(.right);
    try testing.expectEqual(7, grid.index);
    try testing.expect(grid.handleKey(try .parse("k")));
    try testing.expectEqual(4, grid.index);
    grid.move(.left);
    grid.move(.left);
    try testing.expectEqual(3, grid.index);
    var wrapping: Grid = .{ .count = 8, .columns = 3, .wrap = true };
    wrapping.move(.left);
    try testing.expectEqual(2, wrapping.index);
    wrapping.move(.up);
    try testing.expectEqual(7, wrapping.index);
    wrapping.move(.down);
    try testing.expectEqual(1, wrapping.index);
}
