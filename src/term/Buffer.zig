//! A grid of cells: styled text laid out the way a terminal shows it, to draw into, put
//! blocks over one another, compare, and write out again. Under `Canvas` (layers) and
//! `Renderer` (writing only the cells that changed), as ultraviolet's buffers are under
//! Bubble Tea and Lip Gloss.
//!
//! ```zig
//! var buffer: term.Buffer = .init(gpa);
//! defer buffer.deinit();
//! try buffer.layout("\x1b[1mhello\x1b[0m world", .{ .width = 20 });
//! try buffer.writeRow(w, 0, .truecolor);
//! ```
//!
//! Text is read as a terminal reads it: grapheme clusters and wide characters (`width`),
//! SGR colors and attributes (`Pen`), OSC 8 hyperlinks, `\n` to start a row, and tabs to
//! the next multiple of 8. Other escape sequences take no cells and are dropped.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");
const capability = @import("capability.zig");
const display = @import("width.zig");
const Parser = @import("Parser.zig");
const Pen = @import("Pen.zig");
const vt = @import("vt.zig");

const Buffer = @This();

/// One cell: a cluster and its pen.
pub const Cell = vt.Cell;

gpa: Allocator,
width: usize = 0,
/// Rows in use.
rows: usize = 0,
cells: std.ArrayList(Cell) = .empty,
/// The URLs of hyperlinks, as cells number them (`Cell.link` minus one).
links: std.ArrayList([]u8) = .empty,

/// An empty buffer.
pub fn init(gpa: Allocator) Buffer {
    return .{ .gpa = gpa };
}

/// Frees the cells.
pub fn deinit(b: *Buffer) void {
    b.clearLinks();
    b.links.deinit(b.gpa);
    b.cells.deinit(b.gpa);
    b.* = undefined;
}

fn clearLinks(b: *Buffer) void {
    for (b.links.items) |url| b.gpa.free(url);
    b.links.clearRetainingCapacity();
}

/// Empties the buffer and makes it `width` columns by `rows` rows of blank cells.
pub fn reset(b: *Buffer, width: usize, rows: usize) Allocator.Error!void {
    b.clearLinks();
    b.width = width;
    b.rows = 0;
    b.cells.clearRetainingCapacity();
    try b.addRows(rows);
}

fn addRows(b: *Buffer, n: usize) Allocator.Error!void {
    try b.cells.appendNTimes(b.gpa, .{}, n * b.width);
    b.rows += n;
}

/// Keeps only the `count` rows from `first` (as many as there are).
pub fn window(b: *Buffer, first: usize, count: usize) void {
    const start = @min(first, b.rows);
    const kept = @min(count, b.rows - start);
    if (start > 0) {
        const cells = b.cells.items;
        const len = kept * b.width;
        std.mem.copyForwards(Cell, cells[0..len], cells[start * b.width ..][0..len]);
    }
    b.rows = kept;
    b.cells.shrinkRetainingCapacity(kept * b.width);
}

/// The cells of `row`.
pub fn row(b: *const Buffer, r: usize) []Cell {
    return b.cells.items[r * b.width ..][0..b.width];
}

/// The cell at `r`, `c`.
pub fn at(b: *const Buffer, r: usize, c: usize) *Cell {
    return &b.cells.items[r * b.width + c];
}

/// How `layout` places text.
pub const LayoutOptions = struct {
    /// Columns per row; text wider than this wraps onto the next row, as a terminal wraps
    /// it (a wide character that does not fit wraps whole).
    width: usize,
    /// Cut rows at `width` instead of wrapping.
    clip: bool = false,
};

/// Lays `text` out from the top left of an empty buffer, as many rows as it takes (one
/// for empty text).
pub fn layout(b: *Buffer, text: []const u8, options: LayoutOptions) Allocator.Error!void {
    assert(options.width > 0);
    try b.reset(options.width, 1);
    var writer: TextWriter = .{
        .buffer = b,
        .grow = true,
        .wrap = !options.clip,
        .left = 0,
        .right = options.width,
    };
    try writer.write(text);
}

/// Draws the block `text` (lines separated by `\n`) with its top left at `x`, `y`, over
/// what is there; what falls outside the buffer is cut. Lines are not wrapped. For
/// layers, overlays, and positioned blocks.
pub fn draw(b: *Buffer, x: usize, y: usize, text: []const u8) Allocator.Error!void {
    if (x >= b.width or y >= b.rows) return;
    var writer: TextWriter = .{
        .buffer = b,
        .grow = false,
        .wrap = false,
        .left = x,
        .right = b.width,
        .r = y,
        .c = x,
    };
    try writer.write(text);
}

/// Writes text into cells: the part of the `Buffer` both `layout` and `draw` share.
const TextWriter = struct {
    buffer: *Buffer,
    /// Add rows as text needs them (`layout`), or drop what falls below (`draw`).
    grow: bool,
    wrap: bool,
    /// The columns text goes in: a new line starts at `left`.
    left: usize,
    right: usize,
    r: usize = 0,
    c: usize = 0,
    pen: Pen = .{},
    link: u16 = 0,

    fn write(tw: *TextWriter, text: []const u8) Allocator.Error!void {
        var it: display.Iterator = .init(text);
        while (it.next()) |cluster| {
            if (cluster.escape) {
                try tw.escape(cluster.bytes);
            } else if (cluster.bytes[0] == '\n') {
                try tw.newline();
            } else if (cluster.bytes[0] == '\t') {
                const next_stop = (tw.c - tw.left) / 8 * 8 + 8 + tw.left;
                while (tw.c < next_stop and tw.c < tw.right) try tw.put(" ", 1);
            } else if (cluster.width > 0) {
                try tw.put(cluster.bytes, cluster.width);
            }
        }
    }

    fn newline(tw: *TextWriter) Allocator.Error!void {
        tw.r += 1;
        tw.c = tw.left;
        if (tw.grow and tw.r >= tw.buffer.rows) try tw.buffer.addRows(1);
    }

    fn put(tw: *TextWriter, bytes: []const u8, cluster_width: u2) Allocator.Error!void {
        if (tw.c + cluster_width > tw.right) {
            if (!tw.wrap) return;
            if (cluster_width > tw.right - tw.left) return;
            try tw.newline();
        }
        const b = tw.buffer;
        if (tw.r >= b.rows) return;
        clearHalves(b, tw.r, tw.c);
        if (cluster_width == 2) clearHalves(b, tw.r, tw.c + 1);
        const cell = b.at(tw.r, tw.c);
        cell.* = .{ .pen = tw.pen, .link = tw.link, .wide = cluster_width == 2 };
        const len = @min(bytes.len, Cell.max_cluster);
        @memcpy(cell.text[0..len], bytes[0..len]);
        cell.len = @intCast(len);
        if (cluster_width == 2) b.at(tw.r, tw.c + 1).* = .{
            .tail = true,
            .pen = tw.pen,
            .link = tw.link,
        };
        tw.c += cluster_width;
    }

    fn escape(tw: *TextWriter, bytes: []const u8) Allocator.Error!void {
        var parser: Parser = .{};
        var sink: Sink = .{ .tw = tw };
        parser.feed(bytes, &sink);
        if (sink.failed) return error.OutOfMemory;
    }

    const Sink = struct {
        tw: *TextWriter,
        failed: bool = false,

        pub fn csi(s: *Sink, seq: Parser.Csi) void {
            if (seq.final == 'm' and seq.private == 0 and seq.intermediates.len == 0) {
                s.tw.pen.apply(seq.params);
            }
        }

        pub fn osc(s: *Sink, data: []const u8) void {
            if (!std.mem.startsWith(u8, data, "8;")) return;
            const rest = data[2..];
            const semicolon = std.mem.indexOfScalar(u8, rest, ';') orelse return;
            const url = rest[semicolon + 1 ..];
            s.tw.link = if (url.len == 0) 0 else s.tw.buffer.linkId(url) catch {
                s.failed = true;
                return;
            };
        }
    };
};

/// Overwriting a cell takes the other half of a wide character there with it.
fn clearHalves(b: *Buffer, r: usize, c: usize) void {
    const cell = b.at(r, c);
    if (cell.tail and c > 0) b.at(r, c - 1).* = .{ .pen = .{ .bg = b.at(r, c - 1).pen.bg } };
    if (cell.wide and c + 1 < b.width) b.at(r, c + 1).* = .{ .pen = .{ .bg = cell.pen.bg } };
}

/// The number for `url`, added when new.
fn linkId(b: *Buffer, url: []const u8) Allocator.Error!u16 {
    for (b.links.items, 1..) |known, i| {
        if (std.mem.eql(u8, known, url)) return @intCast(i);
    }
    if (b.links.items.len == std.math.maxInt(u16)) return 0;
    const copy = try b.gpa.dupe(u8, url);
    errdefer b.gpa.free(copy);
    try b.links.append(b.gpa, copy);
    return @intCast(b.links.items.len);
}

/// The URL of `cell`'s hyperlink, or null.
pub fn linkOf(b: *const Buffer, cell: *const Cell) ?[]const u8 {
    if (cell.link == 0) return null;
    return b.links.items[cell.link - 1];
}

/// Whether two cells, each read in its own buffer, look the same.
pub fn sameCell(
    a_buffer: *const Buffer,
    a: *const Cell,
    b_buffer: *const Buffer,
    b: *const Cell,
) bool {
    if (a.len != b.len or a.tail != b.tail or a.wide != b.wide) return false;
    if (!a.pen.eql(b.pen)) return false;
    if (!std.mem.eql(u8, a.bytes(), b.bytes())) return false;
    const a_link = a_buffer.linkOf(a) orelse "";
    const b_link = b_buffer.linkOf(b) orelse "";
    return std.mem.eql(u8, a_link, b_link);
}

/// The column after the last cell of `r` that shows anything (text, or a background),
/// trailing blanks being what erasing leaves.
pub fn rowEnd(b: *const Buffer, r: usize) usize {
    const cells = b.row(r);
    var end = cells.len;
    while (end > 0 and isErased(&cells[end - 1])) end -= 1;
    return end;
}

/// A cell that erasing in the default colors leaves: no text, no colors, no attributes.
pub fn isErased(cell: *const Cell) bool {
    return cell.len == 0 and !cell.tail and cell.pen.eql(.{}) and cell.link == 0;
}

/// Tracks what the terminal has in effect while cells are written, so each cell writes
/// only the change.
pub const Output = struct {
    w: *Writer,
    level: capability.Color,
    pen: Pen = .{},
    link: ?[]const u8 = null,

    /// Writes `cell` (nothing for the right half of a wide character).
    pub fn cell(o: *Output, buffer: *const Buffer, c: *const Cell) Writer.Error!void {
        if (c.tail) return;
        try c.pen.writeFrom(o.pen, o.w, o.level);
        o.pen = c.pen;
        const url = buffer.linkOf(c);
        const same_link = if (url) |u|
            (if (o.link) |l| std.mem.eql(u8, u, l) else false)
        else
            o.link == null;
        if (!same_link) {
            try o.w.print(ansi.osc ++ "8;;{s}" ++ ansi.st, .{url orelse ""});
            o.link = url;
        }
        if (c.len == 0) try o.w.writeByte(' ') else try o.w.writeAll(c.bytes());
    }

    /// Back to the default pen, no hyperlink.
    pub fn finish(o: *Output) Writer.Error!void {
        if (o.link != null) try o.w.writeAll(ansi.osc ++ "8;;" ++ ansi.st);
        o.link = null;
        try (Pen{}).writeFrom(o.pen, o.w, o.level);
        o.pen = .{};
    }
};

/// Writes row `r` as styled text, its trailing erased cells left out, ending in the
/// default pen.
pub fn writeRow(b: *const Buffer, w: *Writer, r: usize, level: capability.Color) Writer.Error!void {
    var out: Output = .{ .w = w, .level = level };
    for (b.row(r)[0..b.rowEnd(r)]) |*c| try out.cell(b, c);
    try out.finish();
}

/// Writes every row as styled text, rows separated by `\n`. With `full`, every row is
/// written to the whole width (blocks for `layout` to place); otherwise trailing erased
/// cells are left out.
pub fn writeText(
    b: *const Buffer,
    w: *Writer,
    level: capability.Color,
    full: bool,
) Writer.Error!void {
    for (0..b.rows) |r| {
        if (r > 0) try w.writeByte('\n');
        var out: Output = .{ .w = w, .level = level };
        const end = if (full) b.width else b.rowEnd(r);
        for (b.row(r)[0..end]) |*c| try out.cell(b, c);
        try out.finish();
    }
}

const testing = std.testing;

fn expectRows(b: *const Buffer, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, b.rows);
    for (expected, 0..) |line, r| {
        var buffer: [256]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try b.writeRow(&w, r, .none);
        var plain: [256]u8 = undefined;
        var p: Writer = .fixed(&plain);
        try ansi.strip(&p, w.buffered());
        try testing.expectEqualStrings(line, p.buffered());
    }
}

test "layout wraps as a terminal does and expands tabs" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    try b.layout("hello world", .{ .width = 6 });
    try expectRows(&b, &.{ "hello ", "world" });
    try b.layout("\tx\nab\tc", .{ .width = 12 });
    try expectRows(&b, &.{ "        x", "ab      c" });
    try b.layout("12345中", .{ .width = 6 });
    try expectRows(&b, &.{ "12345", "中" });
    try b.layout("abcdefgh", .{ .width = 3, .clip = true });
    try expectRows(&b, &.{"abc"});
    try b.layout("", .{ .width = 3 });
    try expectRows(&b, &.{""});
}

test "layout keeps styles and links per cell" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    try b.layout("\x1b[1;31mab\x1b[0mc\x1b]8;;http://x\x1b\\d\x1b]8;;\x1b\\", .{ .width = 10 });
    try testing.expect(b.at(0, 1).pen.bold);
    try testing.expect(!b.at(0, 2).pen.bold);
    try testing.expectEqualStrings("http://x", b.linkOf(b.at(0, 3)).?);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try b.writeRow(&out.writer, 0, .truecolor);
    try testing.expectEqualStrings(
        "\x1b[1;31mab\x1b[0mc\x1b]8;;http://x\x1b\\d\x1b]8;;\x1b\\",
        out.written(),
    );
}

test "draw puts a block over what is there, cut at the edges" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    try b.layout("..........\n..........\n..........", .{ .width = 10 });
    try b.draw(7, 1, "ABCD\nEF\nGH");
    try expectRows(&b, &.{ "..........", ".......ABC", ".......EF." });
    // Over half of a wide character.
    try b.layout("中中中", .{ .width = 6 });
    try b.draw(1, 0, "x");
    try expectRows(&b, &.{" x中中"});
}

test window {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    try b.layout("1\n2\n3\n4", .{ .width = 2 });
    b.window(1, 2);
    try expectRows(&b, &.{ "2", "3" });
    b.window(1, 9);
    try expectRows(&b, &.{"3"});
}

test sameCell {
    var a: Buffer = .init(testing.allocator);
    defer a.deinit();
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    try a.layout("\x1b]8;;u\x1b\\x\x1b[1my", .{ .width = 4 });
    try b.layout("\x1b]8;;u\x1b\\x\x1b]8;;v\x1b\\y", .{ .width = 4 });
    try testing.expect(sameCell(&a, a.at(0, 0), &b, b.at(0, 0)));
    try testing.expect(!sameCell(&a, a.at(0, 1), &b, b.at(0, 1)));
}
