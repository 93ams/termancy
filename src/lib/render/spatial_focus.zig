//! A 2-D focus grid for spatial navigation.
//!
//! The cursor is always a cell `(cur_row, cur_col)`. A grid with **zero rows or
//! zero columns is valid but empty**: it holds no cells, so `getIndex` reports
//! `0`, every movement is an inert no-op returning `false`, and the cursor stays
//! parked at `(0, 0)`. No dimension is ever subtracted from unguarded, so a
//! degenerate size cannot panic the process. See `init` for the contract.

const std = @import("std");

pub const SpatialFocusGrid = struct {
    rows: usize,
    cols: usize,
    cur_row: usize = 0,
    cur_col: usize = 0,
    wrap: bool = true,

    /// Builds a `rows` x `cols` grid with the cursor parked at `(0, 0)`.
    ///
    /// **Contract:** a zero dimension is *accepted* and yields an **empty**
    /// grid - not an error and not a panic. An empty grid holds no cells:
    /// `getIndex` returns `0` and all four `move*` functions are no-ops that
    /// return `false` and leave the cursor at `(0, 0)`.
    ///
    /// The alternative - rejecting `rows == 0 or cols == 0` by returning an
    /// error - was considered and declined. The grid is built from a terminal
    /// size, and a terminal legitimately reports zero rows or zero columns (a
    /// hidden window, a pty still starting up), so rejecting the size would
    /// force every caller to invent an error path for a state the type can
    /// simply represent. The only caller in this tree today is the literal
    /// `SpatialFocusGrid.init(3, 2, true)` in `src/lib/framework/test/cli_test.zig`, and
    /// staying infallible keeps it compiling unchanged. The guards in the
    /// movement functions below are what keep each `- 1` in range.
    pub fn init(rows: usize, cols: usize, wrap: bool) SpatialFocusGrid {
        return .{
            .rows = rows,
            .cols = cols,
            .wrap = wrap,
        };
    }

    /// `true` when the grid holds no cells, i.e. either dimension is zero.
    fn isEmpty(self: SpatialFocusGrid) bool {
        return self.rows == 0 or self.cols == 0;
    }

    /// Asserts that the cursor names a real cell, or that the grid is empty with
    /// the cursor parked at `(0, 0)`. Split per axis so a failure names the axis.
    fn assertCursorInBounds(self: SpatialFocusGrid) void {
        std.debug.assert(self.rows > 0 or self.cur_row == 0);
        std.debug.assert(self.cols > 0 or self.cur_col == 0);
        std.debug.assert(self.isEmpty() or self.cur_row < self.rows);
        std.debug.assert(self.isEmpty() or self.cur_col < self.cols);
    }

    /// Flat index of the cursor: `cur_row * cols + cur_col`.
    ///
    /// An empty grid reports `0`, which names no cell: callers must read an
    /// empty grid as "nothing is focused" rather than believing index `0`
    /// exists.
    pub fn getIndex(self: SpatialFocusGrid) usize {
        self.assertCursorInBounds();
        return self.cur_row * self.cols + self.cur_col;
    }

    /// Moves the cursor one cell right, crossing to the next row's first cell
    /// and finally wrapping to `(0, 0)`. Returns `false` when nothing moved: on
    /// an empty grid, or at the last cell with `wrap == false`.
    pub fn moveRight(self: *SpatialFocusGrid) bool {
        self.assertCursorInBounds();
        defer self.assertCursorInBounds(); // Postcondition: every path stays in bounds.
        // An empty grid has no cells, so "right" names no destination and
        // reporting a move would be a lie. The same rule holds for every
        // movement below.
        if (self.isEmpty()) return false;
        if (self.cur_col + 1 < self.cols) {
            self.cur_col += 1;
            return true;
        } else if (self.wrap and self.cur_row + 1 < self.rows) {
            self.cur_row += 1;
            self.cur_col = 0;
            return true;
        } else if (self.wrap) {
            self.cur_row = 0;
            self.cur_col = 0;
            return true;
        }
        return false;
    }

    /// Moves the cursor one cell left, crossing to the previous row's last cell
    /// and finally wrapping to the bottom-right cell. Returns `false` when
    /// nothing moved: on an empty grid, or at `(0, 0)` with `wrap == false`.
    pub fn moveLeft(self: *SpatialFocusGrid) bool {
        self.assertCursorInBounds();
        defer self.assertCursorInBounds(); // Postcondition: every path stays in bounds.
        if (self.isEmpty()) return false;
        // `cols > 0` and `rows > 0` past the guard above, so both `- 1` sites
        // below stay in range.
        if (self.cur_col > 0) {
            self.cur_col -= 1;
            return true;
        } else if (self.wrap and self.cur_row > 0) {
            self.cur_row -= 1;
            self.cur_col = self.cols - 1;
            return true;
        } else if (self.wrap) {
            self.cur_row = self.rows - 1;
            self.cur_col = self.cols - 1;
            return true;
        }
        return false;
    }

    /// Moves the cursor one row down, wrapping to the top row when it was on the
    /// last one. Returns `false` when nothing moved: on an empty grid, or on the
    /// last row with `wrap == false`.
    pub fn moveDown(self: *SpatialFocusGrid) bool {
        self.assertCursorInBounds();
        defer self.assertCursorInBounds(); // Postcondition: every path stays in bounds.
        if (self.isEmpty()) return false;
        if (self.cur_row + 1 < self.rows) {
            self.cur_row += 1;
            return true;
        } else if (self.wrap) {
            self.cur_row = 0;
            return true;
        }
        return false;
    }

    /// Moves the cursor one row up, wrapping to the bottom row when it was on
    /// the top one. Returns `false` when nothing moved: on an empty grid, or on
    /// the top row with `wrap == false`.
    pub fn moveUp(self: *SpatialFocusGrid) bool {
        self.assertCursorInBounds();
        defer self.assertCursorInBounds(); // Postcondition: every path stays in bounds.
        if (self.isEmpty()) return false;
        // `rows > 0` past the guard above, so the `rows - 1` wrap stays in range.
        if (self.cur_row > 0) {
            self.cur_row -= 1;
            return true;
        } else if (self.wrap) {
            self.cur_row = self.rows - 1;
            return true;
        }
        return false;
    }
};

const testing = std.testing;

test "SpatialFocusGrid: zero columns, moveLeft at the origin is inert" {
    var grid = SpatialFocusGrid.init(2, 0, true);
    try testing.expect(!grid.moveLeft());
    try testing.expectEqual(@as(usize, 0), grid.cur_row);
    try testing.expectEqual(@as(usize, 0), grid.cur_col);
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
}

test "SpatialFocusGrid: zero columns, moveLeft after moveDown is inert" {
    var grid = SpatialFocusGrid.init(2, 0, true);
    // The return value is deliberately discarded: before the fix this advanced
    // `cur_row` to 1, which armed the `cols - 1` underflow in the next call.
    // The cursor assertions below still pin it as inert.
    _ = grid.moveDown();
    try testing.expect(!grid.moveLeft());
    try testing.expectEqual(@as(usize, 0), grid.cur_row);
    try testing.expectEqual(@as(usize, 0), grid.cur_col);
}

test "SpatialFocusGrid: zero rows, moveLeft at the origin is inert" {
    var grid = SpatialFocusGrid.init(0, 2, true);
    try testing.expect(!grid.moveLeft());
    try testing.expectEqual(@as(usize, 0), grid.cur_row);
    try testing.expectEqual(@as(usize, 0), grid.cur_col);
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
}

test "SpatialFocusGrid: zero rows, moveUp at the origin is inert" {
    var grid = SpatialFocusGrid.init(0, 2, true);
    try testing.expect(!grid.moveUp());
    try testing.expectEqual(@as(usize, 0), grid.cur_row);
    try testing.expectEqual(@as(usize, 0), grid.cur_col);
}

test "SpatialFocusGrid: an empty grid is inert in every direction" {
    const empty_sizes = [_][2]usize{ .{ 0, 0 }, .{ 0, 2 }, .{ 2, 0 } };
    for (empty_sizes) |size| {
        var grid = SpatialFocusGrid.init(size[0], size[1], true);
        try testing.expect(!grid.moveRight());
        try testing.expect(!grid.moveLeft());
        try testing.expect(!grid.moveDown());
        try testing.expect(!grid.moveUp());
        try testing.expectEqual(@as(usize, 0), grid.cur_row);
        try testing.expectEqual(@as(usize, 0), grid.cur_col);
        try testing.expectEqual(@as(usize, 0), grid.getIndex());
    }
}

test "SpatialFocusGrid: wrapping movement crosses every boundary" {
    var grid = SpatialFocusGrid.init(3, 2, true);
    try testing.expectEqual(@as(usize, 0), grid.getIndex());

    // Left from the top-left corner wraps to the bottom-right cell.
    try testing.expect(grid.moveLeft());
    try testing.expectEqual(@as(usize, 5), grid.getIndex());

    // Right from the last cell wraps to the first one.
    try testing.expect(grid.moveRight());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());

    // Up from the top row wraps to the bottom row, same column.
    try testing.expect(grid.moveUp());
    try testing.expectEqual(@as(usize, 4), grid.getIndex());

    // Down from the bottom row wraps to the top row, same column.
    try testing.expect(grid.moveDown());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());

    // Inside a row, right steps then wraps into the next row's first cell.
    try testing.expect(grid.moveRight());
    try testing.expectEqual(@as(usize, 1), grid.getIndex());
    try testing.expect(grid.moveRight());
    try testing.expectEqual(@as(usize, 2), grid.getIndex());
    try testing.expect(grid.moveLeft());
    try testing.expectEqual(@as(usize, 1), grid.getIndex());
    try testing.expect(grid.moveLeft());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
}

test "SpatialFocusGrid: non-wrapping movement clamps at the edges" {
    var grid = SpatialFocusGrid.init(3, 2, false);

    // Already at the top-left corner: nothing to the left or above.
    try testing.expect(!grid.moveLeft());
    try testing.expect(!grid.moveUp());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());

    // Right to the last column, then clamped there.
    try testing.expect(grid.moveRight());
    try testing.expectEqual(@as(usize, 1), grid.getIndex());
    try testing.expect(!grid.moveRight());
    try testing.expectEqual(@as(usize, 1), grid.getIndex());
    try testing.expectEqual(@as(usize, 1), grid.cur_col);

    // Down to the last row, then clamped there.
    try testing.expect(grid.moveDown());
    try testing.expectEqual(@as(usize, 3), grid.getIndex());
    try testing.expect(grid.moveDown());
    try testing.expectEqual(@as(usize, 5), grid.getIndex());
    try testing.expect(!grid.moveDown());
    try testing.expectEqual(@as(usize, 5), grid.getIndex());
    try testing.expectEqual(@as(usize, 2), grid.cur_row);

    // And back up, one row at a time, until the top row clamps.
    try testing.expect(grid.moveUp());
    try testing.expectEqual(@as(usize, 3), grid.getIndex());
    try testing.expect(grid.moveUp());
    try testing.expectEqual(@as(usize, 1), grid.getIndex());
    try testing.expect(!grid.moveUp());
    try testing.expectEqual(@as(usize, 1), grid.getIndex());
}

test "SpatialFocusGrid: a single cell keeps the cursor parked" {
    var grid = SpatialFocusGrid.init(1, 1, true);
    // Pinned existing behaviour: wrapping still reports the move as handled.
    try testing.expect(grid.moveRight());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
    try testing.expect(grid.moveLeft());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
    try testing.expect(grid.moveDown());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
    try testing.expect(grid.moveUp());
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
}
