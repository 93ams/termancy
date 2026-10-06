const std = @import("std");

const Self = @This();
/// Sets the top and bottom scrolling margins (1-indexed)
pub fn setScrollRegion(writer: anytype, top: u16, bottom: u16) !void {
    try writer.print("\x1b[{d};{d}r", .{ top, bottom });
}

/// Resets the scrolling margins to full screen
pub fn resetScrollRegion(writer: anytype) !void {
    try writer.writeAll("\x1b[r");
}
