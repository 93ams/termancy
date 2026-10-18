//! Draws frames on a terminal cell by cell: after the first, only the cells that changed
//! go out, with the shortest cursor moves and attribute changes between them, as
//! ultraviolet's renderer does under Bubble Tea. Under `tui.Program`; usable alone by
//! anything that draws whole frames.
//!
//! ```zig
//! var renderer: term.Renderer = .init(gpa, .{ .mode = .inline_frame, .level = .truecolor });
//! defer renderer.deinit();
//! try frame.layout(view_text, .{ .width = terminal_width });
//! try renderer.draw(w, &frame, .{});
//! ```
//!
//! Inline frames sit below the cursor: the frame's last row is where the cursor rests
//! between frames, and a taller frame scrolls the screen to make room. Full-screen frames
//! start at the top left. The renderer only knows what it drew: output by others (or a
//! resize) between frames needs `erase` or a whole redraw.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");
const capability = @import("capability.zig");
const Buffer = @import("Buffer.zig");

const Renderer = @This();

gpa: Allocator,
options: Options,
/// What is on screen, as last drawn.
shown: Buffer,
/// Whether `shown` is on screen.
showing: bool = false,
/// The frame row the cursor is on.
cursor_row: usize = 0,
/// The column the cursor is on, while known.
cursor_column: ?usize = null,

/// Where frames go.
pub const Mode = enum {
    /// Below the cursor, in the scrolling screen (the frame's rows count from where it
    /// starts).
    inline_frame,
    /// From the top left of the screen, which the frame may fill.
    full_screen,
};

/// How a renderer draws.
pub const Options = struct {
    mode: Mode = .inline_frame,
    /// Colors are lowered to this.
    level: capability.Color = .truecolor,
};

/// A renderer that has drawn nothing yet. Free with `deinit`.
pub fn init(gpa: Allocator, options: Options) Renderer {
    return .{ .gpa = gpa, .options = options, .shown = .init(gpa) };
}

/// Frees the last frame.
pub fn deinit(r: *Renderer) void {
    r.shown.deinit();
    r.* = undefined;
}

/// How `draw` draws.
pub const DrawOptions = struct {
    /// Redraw every cell, whatever was there.
    whole: bool = false,
};

/// Puts `next` on screen: the cells that differ from what is shown, or all of it after
/// `forget`, a resize, or with `whole`. `next` must be as wide as the terminal; its rows
/// are those that fit. Ends with the cursor on the frame's last row and the default pen.
pub fn draw(
    r: *Renderer,
    w: *Writer,
    next: *const Buffer,
    options: DrawOptions,
) (Writer.Error || Allocator.Error)!void {
    const whole = options.whole or !r.showing or r.shown.width != next.width;
    if (whole) {
        try r.erase(w, next.width);
        var out: Buffer.Output = .{ .w = w, .level = r.options.level };
        for (0..next.rows) |row| {
            if (row > 0) {
                // The default pen first: a line feed that scrolls fills the new row with
                // the background in effect.
                try out.finish();
                try w.writeAll("\r\n");
            }
            for (next.row(row)[0..next.rowEnd(row)]) |*c| try out.cell(next, c);
        }
        try out.finish();
        r.cursor_row = next.rows -| 1;
        r.cursor_column = null;
    } else {
        try r.drawChanges(w, next);
    }
    try r.keep(next);
}

fn drawChanges(
    r: *Renderer,
    w: *Writer,
    next: *const Buffer,
) (Writer.Error || Allocator.Error)!void {
    const old = &r.shown;
    var out: Buffer.Output = .{ .w = w, .level = r.options.level };
    for (0..next.rows) |row| {
        if (row >= old.rows) {
            // A new row below the old frame: write it whole.
            try out.finish();
            try r.moveTo(w, row, 0, true);
            for (next.row(row)[0..next.rowEnd(row)]) |*c| try out.cell(next, c);
            r.cursor_column = null;
            continue;
        }
        const new_end = next.rowEnd(row);
        const old_end = old.rowEnd(row);
        var c: usize = 0;
        while (c < new_end) {
            if (Buffer.sameCell(old, old.at(row, c), next, next.at(row, c))) {
                c += 1;
                continue;
            }
            // A run of changed cells, taking in short runs of unchanged ones between,
            // which cost less to write than to move over.
            var start = c;
            var end = c + 1;
            var gap: usize = 0;
            var probe = end;
            while (probe < new_end) : (probe += 1) {
                if (Buffer.sameCell(old, old.at(row, probe), next, next.at(row, probe))) {
                    gap += 1;
                    if (gap > max_gap) break;
                } else {
                    gap = 0;
                    end = probe + 1;
                }
            }
            if (next.at(row, start).tail and start > 0) start -= 1;
            if (end < next.width and next.at(row, end).tail) end += 1;
            try r.moveTo(w, row, start, false);
            for (next.row(row)[start..end]) |*cell| try out.cell(next, cell);
            r.cursor_column = if (end >= next.width) null else end;
            c = end;
        }
        if (old_end > new_end) {
            try out.finish();
            try r.moveTo(w, row, new_end, false);
            try ansi.eraseLine(w, .to_end);
        }
    }
    try out.finish();
    if (next.rows < old.rows) {
        try r.moveTo(w, next.rows, 0, false);
        try ansi.eraseScreen(w, .to_end);
    }
    try r.moveTo(w, next.rows -| 1, 0, false);
}

/// Unchanged cells written over rather than moved past, at most, in a run of changes.
const max_gap = 4;

/// Moves the terminal's cursor to frame `row`, `column` (a row of the frame on screen), to
/// show it there; the next `draw` starts from where it is.
pub fn moveCursor(r: *Renderer, w: *Writer, row: usize, column: usize) Writer.Error!void {
    try r.moveTo(w, row, column, false);
}

/// Moves the cursor to frame `row`, `column`. Inline, rows past the frame's are made by
/// line feeds (`grow`), which scroll the screen at its bottom.
fn moveTo(r: *Renderer, w: *Writer, row: usize, column: usize, grow: bool) Writer.Error!void {
    if (r.options.mode == .full_screen) {
        if (row != r.cursor_row or r.cursor_column == null or r.cursor_column.? != column) {
            try ansi.cursorTo(w, row, column);
        }
        r.cursor_row = row;
        r.cursor_column = column;
        return;
    }
    if (row == r.cursor_row and r.cursor_column != null and column >= r.cursor_column.?) {
        try ansi.cursorForward(w, column - r.cursor_column.?);
        r.cursor_column = column;
        return;
    }
    if (row < r.cursor_row) {
        try w.writeByte('\r');
        try ansi.cursorUp(w, r.cursor_row - row);
    } else if (row > r.cursor_row) {
        if (grow) {
            for (r.cursor_row..row) |_| try w.writeAll("\r\n");
        } else {
            try w.writeByte('\r');
            try ansi.cursorDown(w, row - r.cursor_row);
        }
    } else {
        try w.writeByte('\r');
    }
    try ansi.cursorForward(w, column);
    r.cursor_row = row;
    r.cursor_column = column;
}

fn keep(r: *Renderer, next: *const Buffer) Allocator.Error!void {
    try r.shown.reset(next.width, next.rows);
    @memcpy(r.shown.cells.items, next.cells.items);
    for (next.links.items) |url| {
        const copy = try r.gpa.dupe(u8, url);
        r.shown.links.append(r.gpa, copy) catch |err| {
            r.gpa.free(copy);
            return err;
        };
    }
    r.showing = true;
}

/// Removes the frame from the screen: inline, moves to its first row (counting the rows
/// its lines reflowed into at `width`, after a resize) and erases from there down;
/// full-screen, clears the screen. The cursor ends where the next frame starts.
pub fn erase(r: *Renderer, w: *Writer, width: usize) Writer.Error!void {
    if (r.options.mode == .full_screen) {
        try ansi.cursorTo(w, 0, 0);
        try ansi.eraseScreen(w, .to_end);
        r.showing = false;
        r.cursor_row = 0;
        r.cursor_column = 0;
        return;
    }
    if (!r.showing) return;
    // Rows above the cursor's: the frame's rows before it, each as many terminal rows as
    // its cells take at `width` (more when the terminal narrowed and reflowed them).
    var above: usize = 0;
    for (0..r.cursor_row) |row| {
        const end = r.shown.rowEnd(row);
        above += if (end == 0 or width == 0) 1 else (end + width - 1) / width;
    }
    const own = r.shown.rowEnd(r.cursor_row);
    if (width > 0 and own > width) above += (own - 1) / width;
    try w.writeByte('\r');
    try ansi.cursorUp(w, above);
    try ansi.eraseScreen(w, .to_end);
    r.showing = false;
    r.cursor_row = 0;
    r.cursor_column = 0;
}

/// Forgets what is on screen: the next `draw` draws everything, from where the cursor is.
pub fn forget(r: *Renderer) void {
    r.showing = false;
    r.cursor_row = 0;
    r.cursor_column = 0;
}

/// Rows of the frame on screen.
pub fn rows(r: *const Renderer) usize {
    return if (r.showing) r.shown.rows else 0;
}

const testing = std.testing;
const vt = @import("vt.zig");

/// Draws `frames` one after another, through a renderer and onto a virtual screen, and
/// checks after each that the screen shows exactly what drawing it whole would.
fn expectFrames(mode: Mode, frames: []const []const u8) !void {
    const size: vt.Size = .{ .width = 12, .height = 6 };
    var screen: vt.Screen = try .init(testing.allocator, size);
    defer screen.deinit();
    var renderer: Renderer = .init(testing.allocator, .{ .mode = mode });
    defer renderer.deinit();
    var buffer: Buffer = .init(testing.allocator);
    defer buffer.deinit();
    for (frames) |frame| {
        try buffer.layout(frame, .{ .width = size.width });
        // As a program does: only the rows that fit.
        buffer.window(0, size.height);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try renderer.draw(&out.writer, &buffer, .{});
        screen.write(out.written());
        var whole: vt.Screen = try .init(testing.allocator, size);
        defer whole.deinit();
        var once: std.Io.Writer.Allocating = .init(testing.allocator);
        defer once.deinit();
        var fresh: Renderer = .init(testing.allocator, .{ .mode = mode });
        defer fresh.deinit();
        try fresh.draw(&once.writer, &buffer, .{});
        whole.write(once.written());
        for (0..size.height) |row| for (0..size.width) |column| {
            const a = screen.cell(row, column);
            const b = whole.cell(row, column);
            if (!std.mem.eql(u8, a.bytes(), b.bytes()) or !a.pen.eql(b.pen)) {
                std.debug.print("frame {s}: row {d} column {d} differs\n", .{ frame, row, column });
                return error.TestUnexpectedResult;
            }
        };
        try testing.expectEqual(whole.row, screen.row);
    }
}

test "drawing changes shows what drawing everything shows" {
    for ([_]Mode{ .inline_frame, .full_screen }) |mode| {
        try expectFrames(mode, &.{ "a\nb\nc", "a\nB\nc", "a\nbb", "a\nbb\nc\nd\ne", "x" });
        try expectFrames(mode, &.{ "\x1b[1mbold\x1b[0m plain", "\x1b[1mbald\x1b[0m plain", "" });
        try expectFrames(mode, &.{ "中文 here", "中x here", "abcdefghijklmnopq", "abc" });
        try expectFrames(mode, &.{ "\x1b[44m    \x1b[0m", "\x1b[44m  \x1b[0m", "  " });
    }
}

test "only the cells that changed go out" {
    var renderer: Renderer = .init(testing.allocator, .{});
    defer renderer.deinit();
    var buffer: Buffer = .init(testing.allocator);
    defer buffer.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try buffer.layout("count: 1\nok", .{ .width = 20 });
    try renderer.draw(&out.writer, &buffer, .{});
    try testing.expectEqualStrings("count: 1\r\nok", out.written());
    out.clearRetainingCapacity();
    try buffer.layout("count: 2\nok", .{ .width = 20 });
    try renderer.draw(&out.writer, &buffer, .{});
    try testing.expectEqualStrings("\r\x1b[1A\x1b[7C2\r\x1b[1B", out.written());
    out.clearRetainingCapacity();
    try renderer.draw(&out.writer, &buffer, .{});
    try testing.expectEqualStrings("", out.written());
}

test "random frames always draw what a whole redraw draws" {
    var prng: std.Random.DefaultPrng = .init(5);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",        "b",       " ",
        "中",
        "\n",       "\x1b[1m", "\x1b[0m",
        "\x1b[31m", "xyz",     "\x1b[42m",
    };
    for ([_]Mode{ .inline_frame, .full_screen }) |mode| {
        var frames: [12][]const u8 = undefined;
        var storage: [12][64]u8 = undefined;
        for (&frames, &storage) |*frame, *bytes| {
            var w: std.Io.Writer = .fixed(bytes);
            var lines: usize = 0;
            for (0..random.uintLessThan(usize, 16)) |_| {
                const piece = pieces[random.uintLessThan(usize, pieces.len)];
                if (piece[0] == '\n') {
                    if (lines == 4) continue;
                    lines += 1;
                }
                w.writeAll(piece) catch break;
            }
            frame.* = w.buffered();
        }
        try expectFrames(mode, &frames);
    }
}
