//! A scrollable viewport over long text, with search. Meant for the full screen
//! (`tui.Options.alt_screen`): it fills the terminal's height, the last row a status line.
//!
//! ```zig
//! var pager: Pager = try .init(gpa, text);
//! defer pager.deinit();
//! _ = try tui.run(gpa, io, &pager, .{ .environ = environ, .program = .{ .alt_screen = true } });
//! ```
//!
//! Keys: j/k, down/up, and enter scroll a row; space/f/pgdown and b/pgup a screen; d/u (or
//! ctrl+d/ctrl+u) half a screen; g/home and G/end jump to either end. / starts a search:
//! type, enter goes to the first match from the top of the screen down (ignoring ASCII
//! case), esc abandons it; n goes to the next match and N (or p) to the previous one, round
//! from either end. Every match on screen is highlighted, the current one in its own style,
//! and the screen scrolls only to bring a match into view. q quits; esc quits as canceled.
//!
//! Lines are word-wrapped to the terminal width (again on every resize), so each row is a
//! slice of the text. With `soft_wrap` off, each line is one row cut at the width, and
//! left/right (h/l) scroll sideways. With `line_numbers`, a gutter numbers the lines, blank
//! on the rows a line wraps onto and `~` past the end, as gum's pager draws it. Tabs are
//! not expanded: expand them first.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Input = @import("input.zig");

pub const Status = enum { active, submitted, canceled };

const Pager = @This();

gpa: Allocator,
/// The text shown; borrowed.
text: []const u8,
/// `text` wrapped to the width, one per screen row.
rows: std.ArrayList(Row) = .empty,
/// The first row on screen.
offset: usize = 0,
size: tui.Size = .{ .width = 80, .height = 24 },
/// The search being typed, or the last one.
search: Input,
/// Whether keys go to `search`.
searching: bool = false,
/// Where the current match starts in `text`: the one n and N move on from.
current: ?usize = null,
/// Number the lines in a gutter left of the text.
line_numbers: bool = false,
/// Wrap long lines at the width; off, each line is one row, scrolled sideways.
soft_wrap: bool = true,
/// The first column shown, when not wrapping.
x_offset: usize = 0,
/// Columns the gutter takes: none without `line_numbers`.
gutter: usize = 0,
/// Shown in the status line until the next key, such as "not found".
message: []const u8 = "",
status: Status = .active,
styles: Styles = .{},

/// One screen row.
pub const Row = struct {
    /// A slice of `text`.
    bytes: []const u8,
    /// The line's number, from 1, on its first row; 0 on the rows it wraps onto.
    line: usize,
};

pub const Styles = struct {
    match: tui.Style = .{ .fg = .{ .indexed = 212 }, .bold = true },
    /// The current match: reversed, so it shows under `NO_COLOR`.
    current_match: tui.Style = .{ .fg = .{ .indexed = 212 }, .reverse = true },
    line_number: tui.Style = .{ .fg = .{ .indexed = 240 } },
    status: tui.Style = .{ .fg = .{ .indexed = 240 } },
    message: tui.Style = .{ .fg = .{ .indexed = 203 } },
};

/// Columns a sideways scroll moves, as gum's.
const x_step = 6;

/// A pager over `text`, wrapped for an 80-column terminal until the first resize.
pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!Pager {
    var pager: Pager = .{
        .gpa = gpa,
        .text = text,
        .search = .{ .gpa = gpa, .prompt = "/" },
    };
    errdefer pager.deinit();
    try pager.wrap();
    return pager;
}

/// Frees the rows and the search.
pub fn deinit(pager: *Pager) void {
    pager.rows.deinit(pager.gpa);
    pager.search.deinit();
    pager.* = undefined;
}

/// Shows `text` (borrowed) instead, keeping the position as far as it allows.
pub fn setText(pager: *Pager, text: []const u8) Allocator.Error!void {
    pager.text = text;
    pager.current = null;
    try pager.wrap();
}

/// Splits the text into rows at the current width, after the gutter.
fn wrap(pager: *Pager) Allocator.Error!void {
    pager.rows.clearRetainingCapacity();
    // The number, at least four columns as gum's, then " │ ".
    const lines_total = std.mem.count(u8, pager.text, "\n") + 1;
    pager.gutter = if (pager.line_numbers) @max(4, digits(lines_total)) + 3 else 0;
    const limit = if (pager.soft_wrap) pager.textWidth() else std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, pager.text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        if (lines.index == null and raw.len == 0) break; // the text's final newline
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        var wrapper: tui.width.Wrapper = .init(line, limit);
        var first = true;
        while (wrapper.next()) |row| : (first = false) {
            try pager.rows.append(pager.gpa, .{ .bytes = row.bytes, .line = if (first) number else 0 });
        }
    }
    pager.scrollTo(pager.offset);
}

fn digits(n: usize) usize {
    var count: usize = 1;
    var rest = n / 10;
    while (rest > 0) : (rest /= 10) count += 1;
    return count;
}

/// Columns for the text: the width less the gutter, at least one.
fn textWidth(pager: *const Pager) usize {
    return @max(pager.size.width -| pager.gutter, 1);
}

/// Rows of text on screen: all but the status line.
pub fn bodyHeight(pager: *const Pager) usize {
    return @max(pager.size.height, 2) - 1;
}

/// Puts row `row` at the top, as far as the end of the text allows.
pub fn scrollTo(pager: *Pager, row: usize) void {
    pager.offset = @min(row, pager.rows.items.len -| pager.bodyHeight());
}

fn scrollBy(pager: *Pager, delta: isize) void {
    const target = @as(isize, @intCast(pager.offset)) + delta;
    pager.scrollTo(@intCast(@max(0, target)));
}

pub fn update(pager: *Pager, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .key => |key| {
            pager.message = "";
            if (pager.searching) {
                pager.searchKey(key);
                return .none;
            }
            return pager.viewKey(key);
        },
        .paste => |text| if (pager.searching) pager.search.insert(text) catch {},
        .resize => |size| {
            pager.size = size;
            pager.wrap() catch {};
        },
        .mouse => |mouse| switch (mouse.button) {
            .wheel_up => pager.scrollBy(-3),
            .wheel_down => pager.scrollBy(3),
            else => {},
        },
        else => {},
    }
    return .none;
}

fn viewKey(pager: *Pager, key: tui.input.Key) tui.Cmd {
    const page: isize = @intCast(pager.bodyHeight());
    if (key.matches("q")) {
        pager.status = .submitted;
        return .quit;
    } else if (key.matches("esc")) {
        pager.status = .canceled;
        return .quit;
    } else if (key.matches("j") or key.matches("down") or key.matches("enter")) {
        pager.scrollBy(1);
    } else if (key.matches("k") or key.matches("up")) {
        pager.scrollBy(-1);
    } else if (key.matches("space") or key.matches("f") or key.matches("pgdown")) {
        pager.scrollBy(page);
    } else if (key.matches("b") or key.matches("pgup")) {
        pager.scrollBy(-page);
    } else if (key.matches("d") or key.matches("ctrl+d")) {
        pager.scrollBy(@divTrunc(page + 1, 2));
    } else if (key.matches("u") or key.matches("ctrl+u")) {
        pager.scrollBy(-@divTrunc(page + 1, 2));
    } else if (key.matches("g") or key.matches("home")) {
        pager.scrollTo(0);
    } else if (key.matches("G") or key.matches("end")) {
        pager.scrollTo(pager.rows.items.len);
    } else if (!pager.soft_wrap and (key.matches("right") or key.matches("l"))) {
        const widest = tui.width.of(pager.text);
        pager.x_offset = @min(pager.x_offset + x_step, widest -| pager.textWidth());
    } else if (!pager.soft_wrap and (key.matches("left") or key.matches("h"))) {
        pager.x_offset -|= x_step;
    } else if (key.matches("/")) {
        pager.searching = true;
        pager.search.setValue("") catch {};
    } else if (key.matches("n")) {
        pager.find(if (pager.current) |at| at + 1 else pager.screenStart(), .forward);
    } else if (key.matches("N") or key.matches("p")) {
        pager.find(pager.current orelse pager.screenStart(), .backward);
    }
    return .none;
}

fn searchKey(pager: *Pager, key: tui.input.Key) void {
    if (key.matches("enter")) {
        pager.searching = false;
        pager.current = null;
        pager.find(pager.screenStart(), .forward);
    } else if (key.matches("esc")) {
        pager.searching = false;
        pager.current = null;
        pager.search.setValue("") catch {};
    } else {
        _ = pager.search.handleKey(key);
    }
}

/// Where the first row on screen starts in `text`.
fn screenStart(pager: *const Pager) usize {
    const rows = pager.rows.items;
    return if (pager.offset < rows.len) pager.startOf(rows[pager.offset].bytes) else 0;
}

/// Where `part`, a slice of `text`, starts in it.
fn startOf(pager: *const Pager, part: []const u8) usize {
    return @intFromPtr(part.ptr) - @intFromPtr(pager.text.ptr);
}

const Direction = enum { forward, backward };

/// Makes the first match at or after byte `from` (forward), or the last one before it
/// (backward), current, round from the other end, and brings it into view; says so in the
/// status line when there is none.
fn find(pager: *Pager, from: usize, direction: Direction) void {
    const pattern = pager.search.value();
    if (pattern.len == 0) return;
    const text = pager.text;
    const found = switch (direction) {
        .forward => std.ascii.findIgnoreCasePos(text, @min(from, text.len), pattern) orelse
            std.ascii.findIgnoreCase(text, pattern),
        .backward => lastBefore(text, from, pattern) orelse
            lastBefore(text, text.len, pattern),
    };
    pager.current = found;
    const at = found orelse {
        pager.message = "Pattern not found";
        return;
    };
    const row = pager.rowOf(at);
    if (row < pager.offset or row >= pager.offset + pager.bodyHeight()) pager.scrollTo(row);
    if (!pager.soft_wrap) {
        const width = tui.width.of(pattern);
        const column = tui.width.of(text[pager.startOf(pager.rows.items[row].bytes)..at]);
        const room = pager.textWidth();
        if (column < pager.x_offset or column + width > pager.x_offset + room) {
            pager.x_offset = column -| @min(x_step, room -| width);
        }
    }
}

/// The start of the last match of `pattern` that starts before `before`.
fn lastBefore(text: []const u8, before: usize, pattern: []const u8) ?usize {
    var last: ?usize = null;
    var at: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, at, pattern)) |found| : (at = found + 1) {
        if (found >= before) break;
        last = found;
    }
    return last;
}

/// The row holding byte `at` of the text (or, for a space dropped at a wrap, the row
/// before it).
fn rowOf(pager: *const Pager, at: usize) usize {
    const Context = struct { pager: *const Pager, at: usize };
    const context: Context = .{ .pager = pager, .at = at };
    const starts = std.sort.partitionPoint(Row, pager.rows.items, context, struct {
        fn startsBy(c: Context, row: Row) bool {
            return c.pager.startOf(row.bytes) <= c.at;
        }
    }.startsBy);
    return starts -| 1;
}

pub fn view(pager: *const Pager, w: *Writer) Writer.Error!void {
    const rows = pager.rows.items;
    for (0..pager.bodyHeight()) |i| {
        const index = pager.offset + i;
        const row: ?Row = if (index < rows.len) rows[index] else null;
        if (pager.line_numbers) try pager.writeGutter(w, row);
        if (row) |r| {
            const from = pager.x_offset;
            const shown = if (pager.soft_wrap)
                r.bytes
            else
                columns(r.bytes, from, from + pager.textWidth());
            try pager.writePart(w, shown);
        }
        try w.writeByte('\n');
    }
    try pager.writeStatus(w);
}

/// `   7 │ ` before a line's first row, blank before the rows it wraps onto, and `   ~ │ `
/// past the end.
fn writeGutter(pager: *const Pager, w: *Writer, row: ?Row) Writer.Error!void {
    var number: [20]u8 = undefined;
    const label = if (row) |r|
        (if (r.line > 0) std.fmt.bufPrint(&number, "{d}", .{r.line}) catch unreachable else "")
    else
        "~";
    var buffer: [32]u8 = undefined;
    var gutter: Writer = .fixed(&buffer);
    gutter.splatByteAll(' ', (pager.gutter - 3) -| label.len) catch unreachable;
    gutter.print("{s} │ ", .{label}) catch unreachable;
    try pager.styles.line_number.paint(w, gutter.buffered());
}

/// The part of `line` in columns `from` up to `to`, in whole clusters.
fn columns(line: []const u8, from: usize, to: usize) []const u8 {
    var it: tui.width.Iterator = .init(line);
    var column: usize = 0;
    var start: ?usize = null;
    var end: usize = line.len;
    while (it.next()) |cluster| {
        const at = it.index - cluster.bytes.len;
        if (start == null and column >= from) start = at;
        if (column + cluster.width > to) {
            end = at;
            break;
        }
        column += cluster.width;
    }
    const first = start orelse return line[line.len..];
    return line[first..@max(first, end)];
}

/// Writes `part`, a slice of the text, with every match of the search in it highlighted;
/// a match the slice cuts is highlighted as far as it shows.
fn writePart(pager: *const Pager, w: *Writer, part: []const u8) Writer.Error!void {
    const pattern = if (pager.searching) "" else pager.search.value();
    if (pattern.len == 0 or part.len == 0) return w.writeAll(part);
    const text = pager.text;
    const start = pager.startOf(part);
    const end = start + part.len;
    // Room for a match that starts in the part and ends after it.
    const haystack = text[0..@min(text.len, end + pattern.len - 1)];
    var at = start;
    var from = start -| (pattern.len - 1);
    while (std.ascii.findIgnoreCasePos(haystack, from, pattern)) |found| {
        if (found >= end) break;
        const shown_from = @max(found, at);
        const shown_to = @min(found + pattern.len, end);
        try w.writeAll(text[at..shown_from]);
        const style = if (pager.current == found) pager.styles.current_match else pager.styles.match;
        try style.paint(w, text[shown_from..shown_to]);
        at = shown_to;
        from = found + pattern.len;
    }
    try w.writeAll(text[at..end]);
}

fn writeStatus(pager: *const Pager, w: *Writer) Writer.Error!void {
    if (pager.searching) return pager.search.view(w);
    if (pager.message.len > 0) return pager.styles.message.paint(w, pager.message);
    const total = pager.rows.items.len;
    const last = @min(pager.offset + pager.bodyHeight(), total);
    const percent = if (total == 0) 100 else last * 100 / total;
    try pager.styles.status.writeSgr(w);
    const first = @min(pager.offset + 1, total);
    try w.print("{d}-{d} of {d} ({d}%)", .{ first, last, total, percent });
    if (pager.styles.status.hasSgr()) try w.writeAll(tui.ansi.reset);
}

const testing = std.testing;
const Driver = tui.testing.Driver(Pager);
const poem =
    \\one
    \\two
    \\three
    \\four
    \\five
    \\six
    \\
;

fn startPager(d: *Driver, text: []const u8, size: tui.Size) !void {
    try startWith(d, try .init(testing.allocator, text), size);
}

/// Starts `pager`, set up beforehand; the first resize wraps it.
fn startWith(d: *Driver, pager: Pager, size: tui.Size) !void {
    d.* = try .init(
        testing.allocator,
        pager,
        .{ .program = .{ .size = size, .alt_screen = true } },
    );
}

fn finish(d: *Driver) void {
    d.deinit();
}

fn expectBytes(d: *Driver, bytes: []const u8) !void {
    if (std.mem.indexOf(u8, d.frameBytes(), bytes) == null) {
        std.debug.print("not in the frame: {f}\n", .{std.ascii.hexEscape(bytes, .lower)});
        return error.TestExpectedEqual;
    }
}

test "scrolling by row, page, and to either end" {
    var d: Driver = undefined;
    try startPager(&d, poem, .{ .width = 20, .height = 4 });
    defer finish(&d);
    try d.expectFrame("one\ntwo\nthree\n1-3 of 6 (50%)");
    try d.press("j");
    try d.expectFrame("two\nthree\nfour\n2-4 of 6 (66%)");
    try d.press("space");
    try d.expectFrame("four\nfive\nsix\n4-6 of 6 (100%)");
    try d.press("j"); // already at the end
    try testing.expectEqual(3, d.model().offset);
    try d.press("b");
    try testing.expectEqual(0, d.model().offset);
    try d.press("G");
    try testing.expectEqual(3, d.model().offset);
    try d.press("u");
    try testing.expectEqual(1, d.model().offset);
    try d.press("g");
    try d.press("d");
    try testing.expectEqual(2, d.model().offset);
    try d.press("q");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
}

test "long lines wrap, and wrap again on resize" {
    var d: Driver = undefined;
    try startPager(&d, "alpha beta gamma\nx", .{ .width = 11, .height = 5 });
    defer finish(&d);
    try d.expectFrame("alpha beta\ngamma\nx\n\n1-3 of 3 (100%)");
    try d.resize(.{ .width = 6, .height = 5 });
    try d.expectFrame("alpha\nbeta\ngamma\nx\n1-4 of 4 (100%)");
}

test "line numbers: blank where a line wraps on, ~ past the end" {
    var pager: Pager = try .init(testing.allocator, "alpha beta gamma\nx");
    pager.line_numbers = true;
    var d: Driver = undefined;
    try startWith(&d, pager, .{ .width = 16, .height = 6 });
    defer finish(&d);
    // Seven columns of gutter leave nine for the text.
    try d.expectFrame("   1 │ alpha\n     │ beta\n     │ gamma\n   2 │ x\n   ~ │ \n" ++
        "1-4 of 4 (100%)");
    try expectBytes(&d, "\x1b[38;5;240m   1 │ \x1b[0malpha");
}

test "line numbers widen past 9999 lines" {
    var text: [20_000]u8 = undefined;
    for (0..10_000) |i| text[2 * i ..][0..2].* = "x\n".*;
    var pager: Pager = try .init(testing.allocator, &text);
    pager.line_numbers = true;
    var d: Driver = undefined;
    try startWith(&d, pager, .{ .width = 20, .height = 3 });
    defer finish(&d);
    try d.press("G");
    try d.expectFrame(" 9999 │ x\n10000 │ x\n9999-10000 of 10000 (100%)");
}

test "without soft wrap, long lines are cut and scroll sideways" {
    var pager: Pager = try .init(testing.allocator, "0123456789abcdef\nxy");
    pager.soft_wrap = false;
    var d: Driver = undefined;
    try startWith(&d, pager, .{ .width = 6, .height = 3 });
    defer finish(&d);
    try d.expectFrame("012345\nxy\n1-2 of 2 (100%)");
    try d.press("right");
    try d.expectFrame("6789ab\n\n1-2 of 2 (100%)");
    try d.press("l");
    try d.expectFrame("abcdef\n\n1-2 of 2 (100%)"); // as far as the widest line goes
    try d.press("left");
    try d.expectFrame("456789\n\n1-2 of 2 (100%)");
    try d.press("h");
    try d.press("h");
    try testing.expectEqual(0, d.model().x_offset);
    // A match off to the side scrolls into view.
    try d.press("/");
    try d.typeText("F");
    try d.press("enter");
    try d.expectFrame("abcdef\n\n1-2 of 2 (100%)");
    try expectBytes(&d, "abcde\x1b[7;38;5;212mf\x1b[0m");
}

test "search goes from match to match, round from either end, highlighting them" {
    var d: Driver = undefined;
    try startPager(&d, poem, .{ .width = 20, .height = 3 });
    defer finish(&d);
    try d.press("/");
    try d.typeText("F");
    try d.expectFrame("one\ntwo\n/F ");
    try d.press("enter");
    try d.expectFrame("four\nfive\n4-5 of 6 (83%)");
    // The current match reversed, the others bold.
    try expectBytes(&d, "\x1b[7;38;5;212mf\x1b[0mour");
    try expectBytes(&d, "\x1b[1;38;5;212mf\x1b[0mive");
    // The next match is on screen already: no scrolling.
    try d.press("n");
    try testing.expectEqual(3, d.model().offset);
    try expectBytes(&d, "\x1b[7;38;5;212mf\x1b[0mive");
    // Past the last match, round to the first; before the first, round to the last.
    try d.press("n");
    try testing.expectEqual(14, d.model().current);
    try d.press("N");
    try testing.expectEqual(19, d.model().current);
    try d.press("p");
    try testing.expectEqual(14, d.model().current);
    try d.press("g");
    try d.press("N");
    try d.expectFrame("five\nsix\n5-6 of 6 (100%)");
    try d.press("g");
    try d.press("/");
    try d.typeText("zzz");
    try d.press("enter");
    try d.expectFrame("one\ntwo\nPattern not found");
    try d.press("/");
    try d.typeText("x");
    try d.press("esc"); // abandons the search, not the pager
    try testing.expect(!d.done());
    try testing.expectEqualStrings("", d.model().search.value());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "a match a wrap breaks is highlighted on both rows" {
    var d: Driver = undefined;
    try startPager(&d, "abcdefgh", .{ .width = 4, .height = 4 });
    defer finish(&d);
    try d.expectFrame("abcd\nefgh\n\n1-2 of 2 (100%)");
    try d.press("/");
    try d.typeText("cdef");
    try d.press("enter");
    try expectBytes(&d, "ab\x1b[7;38;5;212mcd\x1b[0m");
    try expectBytes(&d, "\x1b[7;38;5;212mef\x1b[0mgh");
}

test "empty text" {
    var d: Driver = undefined;
    try startPager(&d, "", .{ .width = 10, .height = 2 });
    defer finish(&d);
    try d.expectFrame("\n0-0 of 0 (100%)");
}

test "the mouse wheel scrolls" {
    var d: Driver = undefined;
    try startPager(&d, poem, .{ .width = 20, .height = 4 });
    defer finish(&d);
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .wheel_down, .action = .press } });
    try testing.expectEqual(3, d.model().offset);
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .wheel_up, .action = .press } });
    try testing.expectEqual(0, d.model().offset);
}
