//! A table drawn as text, as Lip Gloss's `table`: a header, rows, a border with the
//! separators you choose, a style per cell, and a total width the columns shrink (and
//! wrap) to fit.
//!
//! ```zig
//! const table: term.Table = .{
//!     .headers = &.{ "Name", "Port" },
//!     .rows = &.{ &.{ "api", "8080" }, &.{ "web", "443" } },
//! };
//! try table.render(gpa, w);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const display = @import("width.zig");
const layout = @import("layout.zig");
const Style = @import("Style.zig");

const Table = @This();

headers: []const []const u8 = &.{},
rows: []const []const []const u8,
border: Style.Border = .rounded,
/// The border's colors.
border_style: Style = .{},
/// Which lines to draw.
lines: Lines = .{},
/// The style of a cell: its colors, attributes, padding, and alignment. `row` is null for
/// the header. Width, height, and border are the table's to set; they are ignored here.
style: ?*const fn (row: ?usize, column: usize) Style = null,
/// The table's whole width, border included; columns shrink to fit, widest first, and
/// their text wraps (or is cut, without `wrap`). Null: as wide as the content.
width: ?usize = null,
/// At most this wide, border included: like `width`, but only for a table wider than it.
max_width: ?usize = null,
wrap: bool = true,

/// Which lines a table draws.
pub const Lines = struct {
    top: bool = true,
    bottom: bool = true,
    left: bool = true,
    right: bool = true,
    /// Below the header.
    header: bool = true,
    /// Between columns.
    columns: bool = true,
    /// Between rows.
    rows: bool = false,

    /// No border at all: columns separated by space.
    pub const none: Lines = .{
        .top = false,
        .bottom = false,
        .left = false,
        .right = false,
        .header = false,
        .columns = false,
    };
};

/// The style cells have without `style`: one column of padding on each side.
pub const default_cell: Style = .{ .padding = .symmetric(0, 1) };

fn cellStyle(t: Table, row: ?usize, column: usize) Style {
    var style = if (t.style) |f| f(row, column) else default_cell;
    style.width = null;
    style.height = null;
    style.border = null;
    style.margin = .{};
    style.max_width = null;
    style.max_height = null;
    return style;
}

fn columnCount(t: Table) usize {
    var n = t.headers.len;
    for (t.rows) |cells| n = @max(n, cells.len);
    return n;
}

fn cellText(t: Table, row: ?usize, column: usize) []const u8 {
    const cells = if (row) |r| t.rows[r] else t.headers;
    return if (column < cells.len) cells[column] else "";
}

/// Writes the table; every line is as wide as the table.
pub fn render(t: Table, gpa: Allocator, w: *Writer) (Writer.Error || Allocator.Error)!void {
    const columns = t.columnCount();
    if (columns == 0) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each column's natural width: its widest cell, padding included.
    const widths = try arena.alloc(usize, columns);
    @memset(widths, 0);
    const has_header = t.headers.len > 0;
    const first_row: usize = if (has_header) 0 else 1;
    for (first_row..t.rows.len + 1) |r| {
        const row: ?usize = if (r == 0) null else r - 1;
        for (0..columns) |c| {
            const style = t.cellStyle(row, c);
            widths[c] = @max(widths[c], style.size(t.cellText(row, c)).width);
        }
    }
    if (t.width) |total| t.shrink(widths, total);
    if (t.max_width) |limit| if (t.totalWidth(widths) > limit) t.shrink(widths, limit);

    // The rows as blocks of cells, each cell rendered to its column's width.
    const lines_between: usize = @intFromBool(t.lines.columns);
    const rows_total = t.rows.len + @intFromBool(has_header);
    var rendered: std.ArrayList([]const []const u8) = .empty;
    var heights: std.ArrayList(usize) = .empty;
    for (first_row..t.rows.len + 1) |r| {
        const row: ?usize = if (r == 0) null else r - 1;
        const cells = try arena.alloc([]const u8, columns);
        var height: usize = 1;
        for (cells, 0..) |*cell, c| {
            var style = t.cellStyle(row, c);
            style.width = widths[c];
            if (!t.wrap) style.max_width = widths[c];
            var out: Writer.Allocating = .init(arena);
            const text = t.cellText(row, c);
            try style.render(&out.writer, if (t.wrap) text else firstLine(text));
            cell.* = out.written();
            height = @max(height, layout.size(cell.*).height);
        }
        try rendered.append(arena, cells);
        try heights.append(arena, height);
    }
    _ = rows_total;

    var first_line = true;
    if (t.lines.top) try t.rule(w, widths, .top, &first_line);
    for (rendered.items, heights.items, 0..) |cells, height, i| {
        for (0..height) |line| {
            try startLine(w, &first_line);
            if (t.lines.left) try t.border_style.paint(w, t.border.left);
            for (cells, 0..) |cell, c| {
                if (c > 0 and lines_between > 0) try t.border_style.paint(w, t.border.left);
                const text = lineOf(cell, line);
                try layout.writePadded(w, text, widths[c], .start);
            }
            if (t.lines.right) try t.border_style.paint(w, t.border.right);
        }
        const is_last = i + 1 == rendered.items.len;
        if (is_last) continue;
        if (i == 0 and has_header and t.lines.header) {
            try t.rule(w, widths, .middle, &first_line);
        } else if (t.lines.rows) {
            try t.rule(w, widths, .middle, &first_line);
        }
    }
    if (t.lines.bottom) try t.rule(w, widths, .bottom, &first_line);
}

/// `render` into memory the caller owns.
pub fn renderAlloc(t: Table, gpa: Allocator) (Writer.Error || Allocator.Error)![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try t.render(gpa, &out.writer);
    return out.toOwnedSlice();
}

fn startLine(w: *Writer, first: *bool) Writer.Error!void {
    if (!first.*) try w.writeByte('\n');
    first.* = false;
}

const RuleKind = enum { top, middle, bottom };

/// A horizontal line: `╭──┬──╮`, `├──┼──┤`, or `╰──┴──╯`.
fn rule(
    t: Table,
    w: *Writer,
    widths: []const usize,
    kind: RuleKind,
    first: *bool,
) Writer.Error!void {
    try startLine(w, first);
    const b = t.border;
    const glyphs: [4][]const u8 = switch (kind) {
        .top => .{ b.top_left, b.top, junction(b, .top), b.top_right },
        .middle => .{ junction(b, .left), b.top, junction(b, .cross), junction(b, .right) },
        .bottom => .{ b.bottom_left, b.bottom, junction(b, .bottom), b.bottom_right },
    };
    try t.border_style.writeSgr(w);
    if (t.lines.left) try w.writeAll(glyphs[0]);
    for (widths, 0..) |width, c| {
        if (c > 0 and t.lines.columns) try w.writeAll(glyphs[2]);
        try w.splatBytesAll(glyphs[1], width);
    }
    if (t.lines.right) try w.writeAll(glyphs[3]);
    if (t.border_style.hasSgr()) try w.writeAll(@import("ansi.zig").reset);
}

const Junction = enum { top, bottom, left, right, cross };

/// The glyph where lines meet, for the box-drawing borders this module knows.
fn junction(b: Style.Border, which: Junction) []const u8 {
    const sets = [_]struct { Style.Border, [5][]const u8 }{
        .{ Style.Border.normal, .{ "┬", "┴", "├", "┤", "┼" } },
        .{ Style.Border.rounded, .{ "┬", "┴", "├", "┤", "┼" } },
        .{ Style.Border.thick, .{ "┳", "┻", "┣", "┫", "╋" } },
        .{ Style.Border.double, .{ "╦", "╩", "╠", "╣", "╬" } },
    };
    for (sets) |set| {
        if (std.mem.eql(u8, set[0].top_left, b.top_left) and std.mem.eql(u8, set[0].top, b.top)) {
            return set[1][@backingInt(which)];
        }
    }
    // ASCII, markdown, hidden, blocks: their corner glyph serves.
    return switch (which) {
        .top, .left => b.top_left,
        .bottom, .right => b.bottom_right,
        .cross => b.top_left,
    };
}

/// The table's width with these column widths, border included.
fn totalWidth(t: Table, widths: []const usize) usize {
    var sum: usize = @as(usize, @intFromBool(t.lines.left)) + @intFromBool(t.lines.right);
    if (t.lines.columns) sum += widths.len - 1;
    for (widths) |w| sum += w;
    return sum;
}

/// Narrows `widths` until the table fits in `total`: one column at a time, the widest.
fn shrink(t: Table, widths: []usize, total: usize) void {
    const columns = widths.len;
    const borders = @as(usize, @intFromBool(t.lines.left)) + @intFromBool(t.lines.right) +
        if (t.lines.columns) columns - 1 else 0;
    const room = total -| borders;
    var sum: usize = 0;
    for (widths) |w| sum += w;
    while (sum > room) {
        var widest: usize = 0;
        for (widths, 0..) |w, i| if (w > widths[widest]) {
            widest = i;
        };
        if (widths[widest] <= 3) break;
        widths[widest] -= 1;
        sum -= 1;
    }
    // A wider table spreads the extra over the columns.
    var i: usize = 0;
    while (sum < room) : (i = (i + 1) % columns) {
        widths[i] += 1;
        sum += 1;
    }
}

fn lineOf(block: []const u8, index: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, block, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) if (i == index) return line;
    return "";
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

const testing = std.testing;

fn expectTable(expected: []const u8, table: Table) !void {
    const text = try table.renderAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "a header, rows, and a rounded border" {
    try expectTable(
        \\╭──────┬──────╮
        \\│ Name │ Port │
        \\├──────┼──────┤
        \\│ api  │ 8080 │
        \\│ web  │ 443  │
        \\╰──────┴──────╯
    , .{
        .headers = &.{ "Name", "Port" },
        .rows = &.{ &.{ "api", "8080" }, &.{ "web", "443" } },
    });
}

test "lines between rows, no outer border, a missing cell" {
    try expectTable(" a │ b \n───┼───\n c │   ", .{
        .rows = &.{ &.{ "a", "b" }, &.{"c"} },
        .lines = .{ .top = false, .bottom = false, .left = false, .right = false, .rows = true },
    });
}

test "a width the columns shrink to, wrapping" {
    try expectTable(
        \\┌────────┬───┐
        \\│ one    │ x │
        \\│ two    │   │
        \\│ three  │   │
        \\└────────┴───┘
    , .{
        .rows = &.{&.{ "one two three", "x" }},
        .border = .normal,
        .width = 14,
    });
}

fn rightAligned(row: ?usize, column: usize) Style {
    _ = row;
    return .{ .padding = .symmetric(0, 1), .@"align" = if (column == 1) .end else .start };
}

test "a cell style aligns a column" {
    try expectTable(
        \\╭─────┬─────╮
        \\│ a   │   1 │
        \\│ bbb │ 100 │
        \\╰─────┴─────╯
    , .{
        .rows = &.{ &.{ "a", "1" }, &.{ "bbb", "100" } },
        .style = rightAligned,
    });
}
