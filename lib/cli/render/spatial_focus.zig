const std = @import("std");

pub const SpatialFocusGrid = struct {
    rows: usize,
    cols: usize,
    cur_row: usize = 0,
    cur_col: usize = 0,
    wrap: bool = true,

    pub fn init(rows: usize, cols: usize, wrap: bool) SpatialFocusGrid {
        return .{
            .rows = rows,
            .cols = cols,
            .wrap = wrap,
        };
    }

    pub fn getIndex(self: SpatialFocusGrid) usize {
        return self.cur_row * self.cols + self.cur_col;
    }

    pub fn moveRight(self: *SpatialFocusGrid) bool {
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

    pub fn moveLeft(self: *SpatialFocusGrid) bool {
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

    pub fn moveDown(self: *SpatialFocusGrid) bool {
        if (self.cur_row + 1 < self.rows) {
            self.cur_row += 1;
            return true;
        } else if (self.wrap) {
            self.cur_row = 0;
            return true;
        }
        return false;
    }

    pub fn moveUp(self: *SpatialFocusGrid) bool {
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
