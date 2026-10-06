//! A width/height cell grid with an SVG exporter.
//!
//! This file **is** the type: the file's own scope is `VirtualTerminal`, so a
//! consumer writes `const VirtualTerminal = @import("virtual_terminal.zig");`.
//! See the file-layout rule in `.agents/AGENTS.md`.
//!
//! `Cell` stays a declaration inside, because the grid is an array of them - one
//! subject, not two.
//!
//! **Not a terminal emulator.** There is no scrollback, no cursor, no escape
//! parsing and no attributes; `Cell.char` is a single byte, so non-ASCII text
//! cannot be stored. Recorded in `app/cli/lib/ROADMAP.md` section 5.4.

const std = @import("std");

const Self = @This();

/// One grid position. `char` is a byte, not a codepoint.
pub const Cell = struct {
    char: u8 = ' ',
    fg: u8 = 7,
    bg: u8 = 0,
};

width: usize,
height: usize,
cells: []Cell,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Self {
    const cells = try allocator.alloc(Cell, width * height);
    @memset(cells, Cell{});
    return .{
        .width = width,
        .height = height,
        .cells = cells,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.cells);
}

/// Sets one cell, ignoring out-of-bounds coordinates.
pub fn setChar(self: *Self, x: usize, y: usize, ch: u8) void {
    if (x < self.width and y < self.height) {
        self.cells[y * self.width + x].char = ch;
    }
}

/// Writes `str` starting at `x`, clipping at the right edge.
pub fn writeString(self: *Self, x: usize, y: usize, str: []const u8) void {
    for (str, 0..) |ch, i| {
        if (x + i >= self.width) break;
        self.setChar(x + i, y, ch);
    }
}

/// Copies row `y` into `buf` and returns the written prefix.
///
/// Truncates to `buf.len`; a short buffer yields a short line, silently.
pub fn getLine(self: Self, y: usize, buf: []u8) []const u8 {
    if (y >= self.height) return "";
    const max_len = @min(buf.len, self.width);
    for (0..max_len) |x| {
        buf[x] = self.cells[y * self.width + x].char;
    }
    return buf[0..max_len];
}

/// Renders the grid as SVG. Escapes `&`, `<` and `>`; note that `"` and control
/// bytes are written raw, which is the recorded defect in ROADMAP 5.4.
pub fn exportSvg(self: Self, writer: anytype) !void {
    try writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" style="background-color: #1e1e1e; font-family: monospace; font-size: 14px;">
        \\
    , .{ self.width * 9, self.height * 18 });

    for (0..self.height) |y| {
        try writer.print("<text x=\"0\" y=\"{d}\" fill=\"#d4d4d4\">", .{(y + 1) * 16});
        for (0..self.width) |x| {
            const ch = self.cells[y * self.width + x].char;
            switch (ch) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                else => try writer.writeByte(ch),
            }
        }
        try writer.writeAll("</text>\n");
    }

    try writer.writeAll("</svg>\n");
}

test "setChar and getLine round-trip, with bounds respected" {
    var vt = try Self.init(std.testing.allocator, 10, 3);
    defer vt.deinit();

    vt.writeString(0, 0, "hello");
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("hello     ", vt.getLine(0, &buf));

    // Out of bounds must be ignored, not corrupt an adjacent row.
    vt.setChar(99, 99, 'X');
    try std.testing.expectEqualStrings("          ", vt.getLine(1, &buf));

    // Writing past the right edge clips.
    vt.writeString(8, 2, "abcdef");
    try std.testing.expectEqualStrings("        ab", vt.getLine(2, &buf));
}

test "exportSvg escapes markup characters" {
    var vt = try Self.init(std.testing.allocator, 4, 1);
    defer vt.deinit();
    vt.writeString(0, 0, "<&>x");

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try vt.exportSvg(&w);

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "&lt;&amp;&gt;x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</svg>") != null);
}
