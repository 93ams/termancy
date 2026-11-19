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
//! type a regular expression (`term.Regex`; one that does not compile is searched for as
//! typed), enter goes to the first match from the top of the screen down, esc abandons
//! it. A pattern with no capital letter ignores case. n goes to the next match and N (or
//! p) to the previous one, round from either end. Every match on screen is highlighted,
//! the current one in its own style, and the screen scrolls only to bring a match into
//! view. q quits; esc quits as canceled.
//!
//! Colored text (`git diff --color`) keeps its colors: its SGR sequences are carried
//! across wrapped rows and lines, while every other escape sequence is dropped. Wrapping,
//! widths, and search see only the visible text. Lines are word-wrapped to the terminal
//! width (again on every resize); with `soft_wrap` off, each line is one row cut at the
//! width, and left/right (h/l) scroll sideways. With `line_numbers`, a gutter numbers the
//! lines, blank on the rows a line wraps onto and `~` past the end, as gum's pager draws
//! it. Tabs are not expanded: expand them first.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Pen = tui.term.Pen;
const Regex = tui.term.Regex;
const Input = @import("input.zig");

pub const Status = enum { active, submitted, canceled };

const Pager = @This();

gpa: Allocator,
/// The text shown, escape sequences and all; borrowed.
text: []const u8,
/// `text` without its escape sequences: what is wrapped, measured, and searched.
plain: []const u8 = "",
/// Holds `plain` when `text` has escape sequences.
plain_buffer: std.ArrayList(u8) = .empty,
/// The SGR sequences of `text`, by where they fall in `plain`.
escapes: std.ArrayList(Escape) = .empty,
/// `plain` wrapped to the width, one per screen row.
rows: std.ArrayList(Row) = .empty,
/// The first row on screen.
offset: usize = 0,
size: tui.Size = .{ .width = 80, .height = 24 },
/// The search being typed, or the last one.
search: Input,
/// Whether keys go to `search`.
searching: bool = false,
/// Where the last search matched in `plain`, in order.
matches: std.ArrayList(Match) = .empty,
/// The match n and N move on from: an index into `matches`.
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

/// An SGR sequence of the text: its parameters, before the character at `at` in `plain`.
pub const Escape = struct { at: usize, params: []const u8 };

/// One screen row.
pub const Row = struct {
    /// A slice of `plain`.
    bytes: []const u8,
    /// The line's number, from 1, on its first row; 0 on the rows it wraps onto.
    line: usize,
    /// The text's colors where the row starts.
    pen: Pen = .{},
};

/// Where a match is in `plain`.
pub const Match = Regex.Match;

pub const Styles = struct {
    /// Under everything, the text's own colors over it: kept through each change of
    /// style, as a border around the pager would paint it.
    text: tui.Style = .{},
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
    try pager.load();
    try pager.wrap();
    return pager;
}

/// Frees the rows, the matches, and the search.
pub fn deinit(pager: *Pager) void {
    pager.plain_buffer.deinit(pager.gpa);
    pager.escapes.deinit(pager.gpa);
    pager.rows.deinit(pager.gpa);
    pager.matches.deinit(pager.gpa);
    pager.search.deinit();
    pager.* = undefined;
}

/// Shows `text` (borrowed) instead, keeping the position and the search as far as they
/// allow.
pub fn setText(pager: *Pager, text: []const u8) Allocator.Error!void {
    pager.text = text;
    try pager.load();
    try pager.wrap();
    pager.findAll();
}

/// Splits `text` into `plain` and its SGR sequences.
fn load(pager: *Pager) Allocator.Error!void {
    pager.plain_buffer.clearRetainingCapacity();
    pager.escapes.clearRetainingCapacity();
    pager.matches.clearRetainingCapacity();
    pager.current = null;
    const text = pager.text;
    pager.plain = text;
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return;
    var at: usize = 0;
    while (at < text.len) {
        const len = tui.ansi.sequenceLen(text[at..]);
        if (len == 0) {
            const next = std.mem.indexOfScalarPos(u8, text, at, 0x1b) orelse text.len;
            try pager.plain_buffer.appendSlice(pager.gpa, text[at..next]);
            at = next;
            continue;
        }
        const sequence = text[at..][0..len];
        if (len >= 3 and sequence[1] == '[' and sequence[len - 1] == 'm') {
            try pager.escapes.append(pager.gpa, .{
                .at = pager.plain_buffer.items.len,
                .params = sequence[2 .. len - 1],
            });
        }
        at += len;
    }
    pager.plain = pager.plain_buffer.items;
}

/// Splits `plain` into rows at the current width, after the gutter.
fn wrap(pager: *Pager) Allocator.Error!void {
    pager.rows.clearRetainingCapacity();
    // The number, at least four columns as gum's, then " │ ".
    const lines_total = std.mem.count(u8, pager.plain, "\n") + 1;
    pager.gutter = if (pager.line_numbers) @max(4, digits(lines_total)) + 3 else 0;
    const limit = if (pager.soft_wrap) pager.textWidth() else std.math.maxInt(usize);
    const escapes = pager.escapes.items;
    var pen: Pen = .{};
    var next_escape: usize = 0;
    var lines = std.mem.splitScalar(u8, pager.plain, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        if (lines.index == null and raw.len == 0) break; // the text's final newline
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        var wrapper: tui.width.Wrapper = .init(line, limit);
        var first = true;
        while (wrapper.next()) |row| : (first = false) {
            const start = pager.startOf(row.bytes);
            while (next_escape < escapes.len and escapes[next_escape].at <= start) {
                pen.applyParams(escapes[next_escape].params);
                next_escape += 1;
            }
            try pager.rows.append(pager.gpa, .{
                .bytes = row.bytes,
                .line = if (first) number else 0,
                .pen = pen,
            });
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

/// Whether a search has been made, so n and N have something to go to.
pub fn searched(pager: *const Pager) bool {
    return !pager.searching and pager.search.value().len > 0;
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
        const widest = tui.width.of(pager.plain);
        pager.x_offset = @min(pager.x_offset + x_step, widest -| pager.textWidth());
    } else if (!pager.soft_wrap and (key.matches("left") or key.matches("h"))) {
        pager.x_offset -|= x_step;
    } else if (key.matches("/")) {
        pager.searching = true;
        pager.search.setValue("") catch {};
    } else if (key.matches("n")) {
        pager.step(.forward);
    } else if (key.matches("N") or key.matches("p")) {
        pager.step(.backward);
    }
    return .none;
}

fn searchKey(pager: *Pager, key: tui.input.Key) void {
    if (key.matches("enter")) {
        pager.searching = false;
        pager.findAll();
        pager.step(.forward);
    } else if (key.matches("esc")) {
        pager.searching = false;
        pager.search.setValue("") catch {};
        pager.findAll();
    } else {
        _ = pager.search.handleKey(key);
    }
}

/// Finds every match of the search in `plain`; says why in the status line when it
/// cannot.
fn findAll(pager: *Pager) void {
    pager.matches.clearRetainingCapacity();
    pager.current = null;
    const pattern = pager.search.value();
    if (pattern.len == 0) return;
    pager.collect(pattern) catch {
        pager.matches.clearRetainingCapacity();
        pager.message = "Out of memory";
    };
}

fn collect(pager: *Pager, pattern: []const u8) Allocator.Error!void {
    const gpa = pager.gpa;
    var re = Regex.compile(gpa, pattern) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern => literal: {
            pager.message = "Not a regular expression: searching for the text";
            const quoted = try quote(gpa, pattern);
            defer gpa.free(quoted);
            break :literal Regex.compile(gpa, quoted) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidPattern => unreachable, // every special byte is escaped
            };
        },
    };
    defer re.deinit(gpa);
    // Smart case: a pattern with no capital letter matches the text lowered.
    const lowered = if (hasCapital(pattern)) null else try std.ascii.allocLowerString(gpa, pager.plain);
    defer if (lowered) |text| gpa.free(text);
    const text = lowered orelse pager.plain;
    var from: usize = 0;
    while (from <= text.len) {
        const found = re.searchFrom(text, from) orelse break;
        if (found.end > found.start) {
            try pager.matches.append(gpa, found);
            from = found.end;
        } else from = found.start + 1;
    }
}

/// Whether `pattern` has a capital letter of its own, not one that names an escape
/// (`\D`).
fn hasCapital(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\') {
            i += 1;
        } else if (std.ascii.isUpper(pattern[i])) return true;
    }
    return false;
}

/// `pattern` as a regular expression matching it as typed: every ASCII byte but letters
/// and digits escaped.
fn quote(gpa: Allocator, pattern: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (pattern) |c| {
        if (c < 0x80 and !std.ascii.isAlphanumeric(c)) try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// Where the first row on screen starts in `plain`.
fn screenStart(pager: *const Pager) usize {
    const rows = pager.rows.items;
    return if (pager.offset < rows.len) pager.startOf(rows[pager.offset].bytes) else 0;
}

/// Where `part`, a slice of `plain`, starts in it.
fn startOf(pager: *const Pager, part: []const u8) usize {
    return @intFromPtr(part.ptr) - @intFromPtr(pager.plain.ptr);
}

const Direction = enum { forward, backward };

/// Makes the next (or previous) match current, round from the other end, and brings it
/// into view; with none current yet, the first from the top of the screen down (or the
/// last above it). Says so in the status line when nothing matches.
fn step(pager: *Pager, direction: Direction) void {
    if (pager.search.value().len == 0) return;
    const matches = pager.matches.items;
    if (matches.len == 0) {
        if (pager.message.len == 0) pager.message = "Pattern not found";
        return;
    }
    const index = if (pager.current) |at| switch (direction) {
        .forward => (at + 1) % matches.len,
        .backward => (at + matches.len - 1) % matches.len,
    } else first: {
        const top = pager.screenStart();
        const below = std.sort.partitionPoint(Match, matches, top, struct {
            fn before(at: usize, m: Match) bool {
                return m.start < at;
            }
        }.before);
        break :first switch (direction) {
            .forward => below % matches.len,
            .backward => (below + matches.len - 1) % matches.len,
        };
    };
    pager.current = index;
    pager.reveal(matches[index]);
}

/// Scrolls so `match` is on screen, if it is not.
fn reveal(pager: *Pager, match: Match) void {
    const row = pager.rowOf(match.start);
    if (row < pager.offset or row >= pager.offset + pager.bodyHeight()) pager.scrollTo(row);
    if (pager.soft_wrap) return;
    const plain = pager.plain;
    const width = tui.width.of(plain[match.start..match.end]);
    const column = tui.width.of(plain[pager.startOf(pager.rows.items[row].bytes)..match.start]);
    const room = pager.textWidth();
    if (column < pager.x_offset or column + width > pager.x_offset + room) {
        pager.x_offset = column -| @min(x_step, room -| width);
    }
}

/// The row holding byte `at` of `plain` (or, for a space dropped at a wrap, the row
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

/// Writes text a pen at a time, changing the terminal's pen only as needed.
const Ink = struct {
    w: *Writer,
    /// What the terminal draws with now.
    now: Pen = .{},

    fn write(ink: *Ink, pen: Pen, bytes: []const u8) Writer.Error!void {
        if (bytes.len == 0) return;
        try ink.set(pen);
        try ink.w.writeAll(bytes);
    }

    fn set(ink: *Ink, pen: Pen) Writer.Error!void {
        try pen.writeFrom(ink.now, ink.w, .truecolor);
        ink.now = pen;
    }
};

/// `top`'s colors and attributes over `base`'s.
fn over(base: Pen, top: Pen) Pen {
    var pen = base;
    if (top.fg != .default) pen.fg = top.fg;
    if (top.bg != .default) pen.bg = top.bg;
    if (top.underline != .none) {
        pen.underline = top.underline;
        pen.underline_color = top.underline_color;
    }
    inline for (.{ "bold", "dim", "italic", "blink", "reverse", "invisible", "strikethrough", "overline" }) |name| {
        if (@field(top, name)) @field(pen, name) = true;
    }
    return pen;
}

pub fn view(pager: *const Pager, w: *Writer) Writer.Error!void {
    const base: Pen = .fromStyle(pager.styles.text);
    // Every row ends in `base`, and a border's row opens it.
    var ink: Ink = .{ .w = w };
    const rows = pager.rows.items;
    for (0..pager.bodyHeight()) |i| {
        const index = pager.offset + i;
        const row: ?Row = if (index < rows.len) rows[index] else null;
        if (pager.line_numbers) try pager.writeGutter(&ink, base, row);
        if (row) |r| {
            const from = pager.x_offset;
            const shown = if (pager.soft_wrap)
                r.bytes
            else
                columns(r.bytes, from, from + pager.textWidth());
            try pager.writeSpan(&ink, base, r, shown);
        }
        try ink.set(base);
        try w.writeByte('\n');
    }
    try pager.writeStatus(&ink, base);
}

/// `   7 │ ` before a line's first row, blank before the rows it wraps onto, and `   ~ │ `
/// past the end.
fn writeGutter(pager: *const Pager, ink: *Ink, base: Pen, row: ?Row) Writer.Error!void {
    var number: [20]u8 = undefined;
    const label = if (row) |r|
        (if (r.line > 0) std.fmt.bufPrint(&number, "{d}", .{r.line}) catch unreachable else "")
    else
        "~";
    var buffer: [32]u8 = undefined;
    var gutter: Writer = .fixed(&buffer);
    gutter.splatByteAll(' ', (pager.gutter - 3) -| label.len) catch unreachable;
    gutter.print("{s} │ ", .{label}) catch unreachable;
    try ink.write(over(base, .fromStyle(pager.styles.line_number)), gutter.buffered());
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

/// Writes `part` of `row` (both slices of `plain`) in the text's colors, with every match
/// in it highlighted; a match the part cuts is highlighted as far as it shows.
fn writeSpan(pager: *const Pager, ink: *Ink, base: Pen, row: Row, part: []const u8) Writer.Error!void {
    const plain = pager.plain;
    const escapes = pager.escapes.items;
    const matches = pager.matches.items;
    const searching = pager.searching;
    const row_start = pager.startOf(row.bytes);
    var at = pager.startOf(part);
    const end = at + part.len;
    var pen = row.pen;
    var e = std.sort.partitionPoint(Escape, escapes, row_start, struct {
        fn by(start: usize, escape: Escape) bool {
            return escape.at <= start;
        }
    }.by);
    var m = std.sort.partitionPoint(Match, matches, at, struct {
        fn by(from: usize, match: Match) bool {
            return match.end <= from;
        }
    }.by);
    while (at < end) {
        while (e < escapes.len and escapes[e].at <= at) : (e += 1) pen.applyParams(escapes[e].params);
        const in_match = !searching and m < matches.len and matches[m].start <= at;
        var stop = end;
        if (e < escapes.len) stop = @min(stop, escapes[e].at);
        if (!searching and m < matches.len) stop = @min(stop, if (in_match) matches[m].end else matches[m].start);
        const style = if (pager.current == m) pager.styles.current_match else pager.styles.match;
        try ink.write(if (in_match) over(base, .fromStyle(style)) else over(base, pen), plain[at..stop]);
        at = stop;
        if (in_match and at == matches[m].end) m += 1;
    }
}

fn writeStatus(pager: *const Pager, ink: *Ink, base: Pen) Writer.Error!void {
    if (pager.searching) {
        try ink.set(.{});
        try pager.search.view(ink.w);
        ink.now = .{};
        return ink.set(base);
    }
    if (pager.message.len > 0) {
        try ink.write(over(base, .fromStyle(pager.styles.message)), pager.message);
        return ink.set(base);
    }
    const total = pager.rows.items.len;
    const last = @min(pager.offset + pager.bodyHeight(), total);
    const percent = if (total == 0) 100 else last * 100 / total;
    const first = @min(pager.offset + 1, total);
    var buffer: [80]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}-{d} of {d} ({d}%)", .{ first, last, total, percent }) catch unreachable;
    try ink.write(over(base, .fromStyle(pager.styles.status)), text);
    try ink.set(base);
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
        std.debug.print("not in the frame: {f}\nframe: {f}\n", .{
            std.ascii.hexEscape(bytes, .lower),
            std.ascii.hexEscape(d.frameBytes(), .lower),
        });
        return error.TestExpectedEqual;
    }
}

fn searchFor(d: *Driver, pattern: []const u8) !void {
    try d.press("/");
    try d.typeText(pattern);
    try d.press("enter");
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
    try searchFor(&d, "f");
    try d.expectFrame("abcdef\n\n1-2 of 2 (100%)");
    try expectBytes(&d, "abcde\x1b[7;38;5;212mf\x1b[0m");
}

test "search goes from match to match, round from either end, highlighting them" {
    var d: Driver = undefined;
    try startPager(&d, poem, .{ .width = 20, .height = 3 });
    defer finish(&d);
    try d.press("/");
    try d.typeText("f");
    try d.expectFrame("one\ntwo\n/f ");
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
    try testing.expectEqual(0, d.model().current);
    try d.press("N");
    try testing.expectEqual(1, d.model().current);
    try d.press("p");
    try testing.expectEqual(0, d.model().current);
    try d.press("g");
    try d.press("N");
    try d.expectFrame("five\nsix\n5-6 of 6 (100%)");
    try d.press("g");
    try searchFor(&d, "zzz");
    try d.expectFrame("one\ntwo\nPattern not found");
    try d.press("/");
    try d.typeText("x");
    try d.press("esc"); // abandons the search, not the pager
    try testing.expect(!d.done());
    try testing.expectEqualStrings("", d.model().search.value());
    try testing.expect(!d.model().searched());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "regular expressions, smart case, and a pattern that is none" {
    var d: Driver = undefined;
    try startPager(&d, "Error 42\nerror 7\nerr(or\n", .{ .width = 20, .height = 5 });
    defer finish(&d);
    // All lowercase ignores case.
    try searchFor(&d, "error \\d+");
    try testing.expectEqual(2, d.model().matches.items.len);
    try testing.expect(d.model().searched());
    // A capital letter makes it exact.
    try searchFor(&d, "Error");
    try testing.expectEqual(1, d.model().matches.items.len);
    try searchFor(&d, "^e");
    try testing.expectEqual(3, d.model().matches.items.len);
    // Not a regular expression: searched for as typed, and said so.
    try searchFor(&d, "r(o");
    try testing.expectEqual(1, d.model().matches.items.len);
    try d.expectFrameContains("Not a regular expression");
    try expectBytes(&d, "er\x1b[7;38;5;212mr(o\x1b[0mr");
}

test "a match a wrap breaks is highlighted on both rows" {
    var d: Driver = undefined;
    try startPager(&d, "abcdefgh", .{ .width = 4, .height = 4 });
    defer finish(&d);
    try d.expectFrame("abcd\nefgh\n\n1-2 of 2 (100%)");
    try searchFor(&d, "cdef");
    try expectBytes(&d, "ab\x1b[7;38;5;212mcd\x1b[0m");
    try expectBytes(&d, "\x1b[7;38;5;212mef\x1b[0mgh");
}

test "colored text keeps its colors across rows, and only the text is searched" {
    // Red from the middle of the first line to the end of the second; a cursor move,
    // which must not reach the screen; and "31" in the escapes only.
    const text = "ab \x1b[31mcd ef\nred\x1b[0m\x1b[2J plain 31";
    var d: Driver = undefined;
    try startPager(&d, text, .{ .width = 5, .height = 6 });
    defer finish(&d);
    try d.expectFrame("ab cd\nef\nred\nplain\n31\n1-5 of 5 (100%)");
    try expectBytes(&d, "ab \x1b[31mcd\x1b[0m\n\x1b[31mef\x1b[0m\n\x1b[31mred\x1b[0m\nplain");
    try searchFor(&d, "31");
    try testing.expectEqual(1, d.model().matches.items.len);
    try searchFor(&d, "d e");
    try testing.expectEqual(1, d.model().matches.items.len);
    // The highlight replaces the red, which comes back after it.
    try expectBytes(&d, "c\x1b[7;38;5;212md\x1b[0m\n\x1b[7;38;5;212me\x1b[0;31mf");
}

test "sideways, colors and widths count only the text" {
    var pager: Pager = try .init(testing.allocator, "\x1b[32mgreen and\x1b[0m more");
    pager.soft_wrap = false;
    var d: Driver = undefined;
    try startWith(&d, pager, .{ .width = 6, .height = 2 });
    defer finish(&d);
    try d.expectFrame("green \n1-1 of 1 (100%)");
    try d.press("right");
    // Still green, though the color began before the cut.
    try d.expectFrame("and mo\n1-1 of 1 (100%)");
    try expectBytes(&d, "\x1b[32mand\x1b[0m mo");
    try d.press("l"); // as far as "green and more" goes
    try d.expectFrame("d more\n1-1 of 1 (100%)");
}

test "the text's style survives every other style" {
    var pager: Pager = try .init(testing.allocator, "ab\x1b[0mc");
    pager.line_numbers = true;
    pager.styles = .{
        .text = .{ .fg = .blue },
        .line_number = .{ .dim = true },
        .current_match = .{ .reverse = true },
        .status = .{ .bold = true },
    };
    var d: Driver = undefined;
    try startWith(&d, pager, .{ .width = 20, .height = 2 });
    defer finish(&d);
    try searchFor(&d, "b");
    // Blue again after the gutter, the match, and the input's own reset.
    try expectBytes(&d, "\x1b[2;34m   1 │ \x1b[0;34ma\x1b[7mb\x1b[0;34mc");
    try expectBytes(&d, "\x1b[1m1-1 of 1 (100%)\x1b[0;34m");
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
