//! A multi-line text editor: each line behind a prompt, a cursor that moves across lines
//! keeping its column, an optional placeholder and length limit, and scrolling when the
//! text is taller than `height`.
//!
//! ```zig
//! var area: Textarea = .{ .gpa = gpa, .placeholder = "Tell us more", .height = 5 };
//! defer area.deinit();
//! // ... run it; ctrl+d submits ...
//! if (area.status == .submitted) use(area.value());
//! ```
//!
//! Keys: printable characters insert, enter starts a new line; left/right move by
//! character, alt+left/alt+right by word, up/down by line (keeping the column), home/end
//! (ctrl+a/ctrl+e) to the ends of the line; backspace and delete erase; ctrl+w erases the
//! word before the cursor, ctrl+u the line before it, ctrl+k the line after it. Ctrl+d
//! submits; esc cancels. A paste inserts its text with `\r\n` and `\r` as line breaks.
//!
//! Ctrl+z undoes the last edit and ctrl+y (or ctrl+shift+z) redoes it, cursor included.
//! Typing joins one undo step per word (a line break ends a word), and so does a run of
//! backspaces or deletes; a paste, a ctrl+w/ctrl+u/ctrl+k, `setValue`, and any edit after
//! the cursor moved are steps of their own. A new edit forgets what was undone.
//! `undo_limit` steps are kept, each a copy of the whole text; 0 turns undo off. A
//! `tui.Program` with `suspend_on_ctrl_z` on stops the process on ctrl+z instead.
//!
//! With `width`, a line longer than a row continues on the next (between characters),
//! and up and down move by rows. `max_lines` bounds the lines; `end_of_buffer` fills the
//! rows below the text up to `height`, as an editor marks them. `cursorPosition` is where a
//! real terminal cursor goes (`tui.Cursor`).
//!
//! The text grows with `gpa`; a keystroke that needs memory that is not there is dropped.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Status = enum { active, submitted, canceled };

const Textarea = @This();

gpa: Allocator,
text: std.ArrayList(u8) = .empty,
/// Byte offset of the cursor in `text`, always at a cluster boundary.
cursor: usize = 0,
/// Written before every line.
prompt: []const u8 = "┃ ",
/// Shown, dimmed, while the text is empty.
placeholder: []const u8 = "",
/// The most characters (grapheme clusters, line breaks included) the text may hold.
char_limit: ?usize = null,
/// The most lines (rows, with `width`) shown; null shows them all.
height: ?usize = null,
/// The most columns a row takes, prompt and line number included: longer lines wrap.
/// Null: lines are as long as they are. Call `scroll` after changing it.
width: ?usize = null,
/// The most lines the text may have: what is typed or pasted stops at a line break past
/// them.
max_lines: ?usize = null,
/// With `height`, the rows below the text are filled to it, each the prompt and this.
end_of_buffer: ?[]const u8 = null,
/// The first row shown.
offset: usize = 0,
/// The column up and down aim for: where the cursor was before it met a shorter line.
goal: ?usize = null,
/// Whether the cursor is drawn.
focused: bool = true,
/// Number the lines, after the prompt.
line_numbers: bool = false,
status: Status = .active,
/// The most edits ctrl+z can take back; 0 turns undo off.
// shortcut: each step copies the whole text, so memory is undo_limit times its size;
// store the edits instead if texts grow to megabytes.
undo_limit: usize = 100,
/// The text and cursor before each edit that can be undone, the oldest first.
undo_steps: std.ArrayList(Snapshot) = .empty,
/// The states undone, the latest undone last.
redo_steps: std.ArrayList(Snapshot) = .empty,
/// The last edit and where it left the cursor: another like it there joins its step.
last_edit: Edit = .none,
edit_end: usize = 0,
styles: Styles = .{},

pub const Snapshot = struct { text: std.ArrayList(u8), cursor: usize };

/// What an edit was, for joining edits into one undo step.
pub const Edit = enum { none, typing, erasing, other };

pub const Styles = struct {
    prompt: tui.Style = .{ .fg = .{ .indexed = 238 } },
    text: tui.Style = .{},
    placeholder: tui.Style = .{ .fg = .{ .indexed = 240 } },
    cursor: tui.Style = .{ .reverse = true },
    line_number: tui.Style = .{ .fg = .{ .indexed = 240 } },
    /// The line the cursor is on, instead of `text`; null: as the others.
    cursor_line: ?tui.Style = null,
    /// The number of the line the cursor is on; null: as the others.
    cursor_line_number: ?tui.Style = null,
    end_of_buffer: tui.Style = .{ .fg = .{ .indexed = 240 } },
};

/// Frees the text and the undo history.
pub fn deinit(area: *Textarea) void {
    area.text.deinit(area.gpa);
    for (area.undo_steps.items) |*step| step.text.deinit(area.gpa);
    for (area.redo_steps.items) |*step| step.text.deinit(area.gpa);
    area.undo_steps.deinit(area.gpa);
    area.redo_steps.deinit(area.gpa);
    area.* = undefined;
}

/// The text typed so far.
pub fn value(area: *const Textarea) []const u8 {
    return area.text.items;
}

/// Replaces the text (cut to `char_limit`) and puts the cursor at its end, as one
/// step ctrl+z takes back.
pub fn setValue(area: *Textarea, text: []const u8) Allocator.Error!void {
    area.remember(.other);
    area.text.clearRetainingCapacity();
    area.cursor = 0;
    area.offset = 0;
    try area.insertAs(text, .none);
}

/// Inserts `text` at the cursor, as much as `char_limit` allows. `\r\n` and `\r` become
/// line breaks, a tab four spaces; other control characters and escapes are dropped.
pub fn insert(area: *Textarea, text: []const u8) Allocator.Error!void {
    return area.insertAs(text, .other);
}

/// `insert`, recorded for undo as `kind` (`.none`: not recorded).
fn insertAs(area: *Textarea, text: []const u8, kind: Edit) Allocator.Error!void {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(area.gpa);
    var room = if (area.char_limit) |limit| limit -| clusterCount(area.value()) else null;
    const lines = std.mem.count(u8, area.value(), "\n") + 1;
    var breaks = if (area.max_lines) |limit| limit -| lines else null;
    var it: tui.width.Iterator = .init(text);
    while (it.next()) |cluster| {
        if (room) |left| {
            if (left == 0) break;
        }
        // The `\r` of a `\r\n`: the `\n` that follows is the line break.
        if (cluster.bytes[0] == '\r' and std.mem.startsWith(u8, text[it.index..], "\n")) {
            continue;
        }
        const bytes = sanitize(cluster) orelse continue;
        if (bytes[0] == '\n') if (breaks) |*left| {
            if (left.* == 0) break;
            left.* -= 1;
        };
        try clean.appendSlice(area.gpa, bytes);
        if (room) |*left| left.* -= 1;
    }
    if (clean.items.len > 0) {
        area.remember(kind);
        try area.text.insertSlice(area.gpa, area.cursor, clean.items);
        area.cursor += clean.items.len;
        area.edit_end = area.cursor;
    }
    area.goal = null;
    area.scroll();
}

/// Records the text before an edit of `kind`, unless it continues the last edit (the
/// same kind of typing or erasing, where that one left the cursor). A new step
/// forgets what was undone. Without memory for it, the edit goes unrecorded.
fn remember(area: *Textarea, kind: Edit) void {
    if (kind == .none or area.undo_limit == 0) return;
    const joins = kind != .other and kind == area.last_edit and
        area.cursor == area.edit_end;
    area.last_edit = kind;
    if (joins) return;
    for (area.redo_steps.items) |*step| step.text.deinit(area.gpa);
    area.redo_steps.clearRetainingCapacity();
    area.undo_steps.ensureUnusedCapacity(area.gpa, 1) catch return;
    const copy = area.gpa.dupe(u8, area.value()) catch return;
    if (area.undo_steps.items.len >= area.undo_limit) {
        var oldest = area.undo_steps.orderedRemove(0);
        oldest.text.deinit(area.gpa);
    }
    const step: Snapshot = .{ .text = .fromOwnedSlice(copy), .cursor = area.cursor };
    area.undo_steps.appendAssumeCapacity(step);
}

/// Takes back the last edit step; returns whether there was one.
pub fn undo(area: *Textarea) bool {
    return area.swapStep(&area.undo_steps, &area.redo_steps);
}

/// Makes again the last step undone; returns whether there was one.
pub fn redo(area: *Textarea) bool {
    return area.swapStep(&area.redo_steps, &area.undo_steps);
}

/// Restores the last state in `from`, keeping the current one in `to`.
fn swapStep(
    area: *Textarea,
    from: *std.ArrayList(Snapshot),
    to: *std.ArrayList(Snapshot),
) bool {
    if (from.items.len == 0) return false;
    to.ensureUnusedCapacity(area.gpa, 1) catch return false;
    const step = from.pop().?;
    to.appendAssumeCapacity(.{ .text = area.text, .cursor = area.cursor });
    area.text = step.text;
    area.cursor = step.cursor;
    area.last_edit = .none;
    area.goal = null;
    area.scroll();
    return true;
}

fn sanitize(cluster: tui.width.Cluster) ?[]const u8 {
    if (cluster.escape) return null;
    return switch (cluster.bytes[0]) {
        '\n', '\r' => "\n",
        '\t' => "    ",
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => null,
        else => cluster.bytes,
    };
}

pub fn update(area: *Textarea, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .key => |key| {
            if (key.matches("ctrl+d")) {
                area.status = .submitted;
                return .quit;
            }
            if (key.matches("esc")) {
                area.status = .canceled;
                return .quit;
            }
            _ = area.handleKey(key);
        },
        .paste => |text| area.insert(text) catch {},
        else => {},
    }
    return .none;
}

/// Applies an editing or movement key; returns whether the key was one. Ctrl+d and esc
/// are not: the caller decides what they mean.
pub fn handleKey(area: *Textarea, key: tui.input.Key) bool {
    if (key.matches("up")) {
        area.moveLine(.up);
    } else if (key.matches("down")) {
        area.moveLine(.down);
    } else if (area.edit(key)) {
        area.goal = null;
    } else return false;
    area.scroll();
    return true;
}

/// Every key but up and down: they forget the goal column.
fn edit(area: *Textarea, key: tui.input.Key) bool {
    const text = area.value();
    const line = lineOf(text, area.cursor);
    if (key.printable()) |c| {
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &buffer) catch return true;
        // A word typed after a space or a line break is a new undo step.
        if (c != ' ' and area.cursor > 0 and isSpace(text[area.cursor - 1])) {
            area.last_edit = .none;
        }
        area.insertAs(buffer[0..len], .typing) catch {};
    } else if (key.matches("enter")) {
        area.insertAs("\n", .typing) catch {};
    } else if (key.matches("ctrl+z")) {
        _ = area.undo();
    } else if (key.matches("ctrl+y") or key.matches("ctrl+Z")) {
        // The decoder reports ctrl+shift+z as ctrl+Z.
        _ = area.redo();
    } else if (key.matches("left") or key.matches("ctrl+b")) {
        area.cursor = previousBoundary(text, area.cursor);
    } else if (key.matches("right") or key.matches("ctrl+f")) {
        area.cursor = nextBoundary(text, area.cursor);
    } else if (key.matches("alt+left") or key.matches("alt+b")) {
        area.cursor = wordStart(text, area.cursor);
    } else if (key.matches("alt+right") or key.matches("alt+f")) {
        area.cursor = wordEnd(text, area.cursor);
    } else if (key.matches("home") or key.matches("ctrl+a")) {
        area.cursor = line.start;
    } else if (key.matches("end") or key.matches("ctrl+e")) {
        area.cursor = line.end;
    } else if (key.matches("backspace")) {
        area.erase(previousBoundary(text, area.cursor), area.cursor, .erasing);
    } else if (key.matches("delete")) {
        area.erase(area.cursor, nextBoundary(text, area.cursor), .erasing);
    } else if (key.matches("ctrl+w") or key.matches("alt+backspace")) {
        area.erase(wordStart(text, area.cursor), area.cursor, .other);
    } else if (key.matches("ctrl+u")) {
        area.erase(line.start, area.cursor, .other);
    } else if (key.matches("ctrl+k")) {
        area.erase(area.cursor, line.end, .other);
    } else return false;
    return true;
}

fn erase(area: *Textarea, from: usize, to: usize, kind: Edit) void {
    if (from == to) return;
    area.remember(kind);
    area.text.replaceRangeAssumeCapacity(from, to - from, &.{});
    area.cursor = from;
    area.edit_end = from;
}

const Direction = enum { up, down };

/// Moves to the row above or below, as near the goal column as that row allows. On the
/// first (last) row, up (down) goes to the start (end) of the text.
fn moveLine(area: *Textarea, direction: Direction) void {
    const text = area.value();
    var it = area.viewRows();
    var above: ?Row = null;
    const here = while (it.next()) |row| {
        if (row.has(area.cursor)) break row;
        above = row;
    } else return;
    const column = area.goal orelse tui.width.of(text[here.start..area.cursor]);
    area.goal = column;
    const target = switch (direction) {
        .up => above orelse {
            area.cursor = 0;
            return;
        },
        .down => it.next() orelse {
            area.cursor = text.len;
            return;
        },
    };
    var at = target.start + offsetAtColumn(text[target.start..target.end], column);
    // The end of a row that wraps is the start of the next: stay on this one.
    if (!target.last and at == target.end and at > target.start) {
        at = previousBoundary(text, at);
    }
    area.cursor = at;
}

/// Scrolls so the cursor's row is shown.
pub fn scroll(area: *Textarea) void {
    const height = area.height orelse return;
    const row = area.cursorRow();
    if (row < area.offset) area.offset = row;
    if (row >= area.offset + height) area.offset = row + 1 - @max(height, 1);
}

/// One row of the view: a line, or with `width` the part of one that fits.
pub const Row = struct {
    start: usize,
    end: usize,
    /// It starts a line, so it shows the line's number.
    first: bool,
    /// It ends a line, so the cursor at its end is on it.
    last: bool,

    /// Whether the cursor at `index` is on this row.
    pub fn has(row: Row, index: usize) bool {
        return row.start <= index and (index < row.end or (index == row.end and row.last));
    }
};

/// The rows of the text, in order.
pub const Rows = struct {
    text: []const u8,
    columns: usize,
    index: usize = 0,
    done: bool = false,

    pub fn next(it: *Rows) ?Row {
        if (it.done) return null;
        const text = it.text;
        const start = it.index;
        const line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const end = rowEnd(text[0..line_end], start, it.columns);
        const row: Row = .{
            .start = start,
            .end = end,
            .first = start == 0 or text[start - 1] == '\n',
            .last = end == line_end,
        };
        it.done = row.last and line_end == text.len;
        it.index = if (row.last) line_end + 1 else end;
        return row;
    }
};

/// The end of a row from `start`: as many characters as fit in `columns`, at least one.
fn rowEnd(line: []const u8, start: usize, columns: usize) usize {
    var it: tui.width.Iterator = .{ .bytes = line, .index = start };
    var used: usize = 0;
    var end = start;
    while (it.next()) |cluster| {
        if (used + cluster.width > columns and end > start) break;
        used += cluster.width;
        end = it.index;
    }
    return end;
}

/// The rows of the text as the view shows them.
pub fn viewRows(area: *const Textarea) Rows {
    return .{ .text = area.value(), .columns = area.textColumns() };
}

/// The columns a row has for text: `width` less the prompt, the line number, and a column
/// for the cursor at the end of a full row.
fn textColumns(area: *const Textarea) usize {
    const width = area.width orelse return std.math.maxInt(usize);
    return @max(width -| tui.width.of(area.prompt) -| area.gutter() -| 1, 1);
}

/// The columns the line numbers take, a space after them included.
fn gutter(area: *const Textarea) usize {
    if (!area.line_numbers) return 0;
    var digits: usize = 1;
    var n = std.mem.count(u8, area.value(), "\n") + 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits + 1;
}

/// The row the cursor is on, from the first.
fn cursorRow(area: *const Textarea) usize {
    var it = area.viewRows();
    var index: usize = 0;
    while (it.next()) |row| : (index += 1) {
        if (row.has(area.cursor)) return index;
    }
    return index -| 1;
}

/// A place in the view: a row from the first shown, and a column.
pub const Position = struct { row: usize, column: usize };

/// Where the cursor is in the view, the prompt and line number counted.
pub fn cursorPosition(area: *const Textarea) Position {
    const text = area.value();
    var it = area.viewRows();
    var index: usize = 0;
    const start = while (it.next()) |row| : (index += 1) {
        if (row.has(area.cursor)) break row.start;
    } else 0;
    const before = tui.width.of(text[start..area.cursor]);
    return .{
        .row = index -| area.offset,
        .column = tui.width.of(area.prompt) + area.gutter() + before,
    };
}

pub fn view(area: *const Textarea, w: *Writer) Writer.Error!void {
    const text = area.value();
    const last = if (area.height) |height| area.offset + height else std.math.maxInt(usize);
    const line = lineOf(text, area.cursor);
    var it = area.viewRows();
    var index: usize = 0;
    var number: usize = 0;
    var shown: usize = 0;
    while (it.next()) |row| : (index += 1) {
        if (row.first) number += 1;
        if (index >= last) break;
        if (index < area.offset) continue;
        if (shown > 0) try w.writeByte('\n');
        shown += 1;
        const on_line = area.focused and row.start >= line.start and row.end <= line.end;
        try area.styles.prompt.paint(w, area.prompt);
        try area.writeNumber(w, if (row.first) number else null, on_line);
        if (text.len == 0) {
            try area.writePlaceholder(w);
        } else {
            try area.writeRow(w, row, on_line);
        }
    }
    const filler = area.end_of_buffer orelse return;
    const height = area.height orelse return;
    while (shown < height) : (shown += 1) {
        try w.writeByte('\n');
        try area.styles.prompt.paint(w, area.prompt);
        try area.writeNumber(w, null, false);
        try area.styles.end_of_buffer.paint(w, filler);
    }
}

/// Line `number` (from 1), right-aligned to the widest, when `line_numbers` is on;
/// blank for a row that continues a line (null).
fn writeNumber(
    area: *const Textarea,
    w: *Writer,
    number: ?usize,
    on_line: bool,
) Writer.Error!void {
    const columns = area.gutter();
    if (columns == 0) return;
    var buffer: [24]u8 = @splat(' ');
    const text = if (number) |n|
        std.fmt.bufPrint(&buffer, "{d: >[1]} ", .{ n, columns - 1 }) catch ""
    else
        buffer[0..@min(columns, buffer.len)];
    const style = (if (on_line) area.styles.cursor_line_number else null) orelse
        area.styles.line_number;
    try style.paint(w, text);
}

fn writePlaceholder(area: *const Textarea, w: *Writer) Writer.Error!void {
    const placeholder = area.placeholder[0..rowEnd(area.placeholder, 0, area.textColumns())];
    if (!area.focused) return area.styles.placeholder.paint(w, placeholder);
    const first = nextBoundary(placeholder, 0);
    try area.styles.cursor.paint(w, if (first == 0) " " else placeholder[0..first]);
    try area.styles.placeholder.paint(w, placeholder[first..]);
}

/// Writes `row`, with the cursor if it is on it; on the cursor's line, in
/// `cursor_line`'s style, to the full width when there is one.
fn writeRow(area: *const Textarea, w: *Writer, row: Row, on_line: bool) Writer.Error!void {
    const text = area.value();
    const line_style = if (on_line) area.styles.cursor_line else null;
    const base = line_style orelse area.styles.text;
    var it: tui.width.Iterator = .{ .bytes = text[0..row.end], .index = row.start };
    var at = row.start;
    var used: usize = 0;
    while (it.next()) |cluster| : (at = it.index) {
        const on_cursor = area.focused and at == area.cursor;
        try (if (on_cursor) area.styles.cursor else base).paint(w, cluster.bytes);
        used += cluster.width;
    }
    if (area.focused and row.last and area.cursor == row.end) {
        try area.styles.cursor.paint(w, " ");
        used += 1;
    }
    if (line_style == null or area.width == null) return;
    const spaces: [64]u8 = @splat(' ');
    var left = (area.textColumns() + 1) -| used;
    while (left > 0) {
        const n = @min(left, spaces.len);
        try base.paint(w, spaces[0..n]);
        left -= n;
    }
}

/// The bounds of the line holding `index`: its first byte and its `\n` (or the end).
pub const Line = struct { start: usize, end: usize };

/// The line `index` is on.
pub fn lineOf(text: []const u8, index: usize) Line {
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..index], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, index, '\n') orelse text.len;
    return .{ .start = start, .end = end };
}

/// The byte offset in `line` of the last cluster boundary at or before display `column`.
pub fn offsetAtColumn(line: []const u8, column: usize) usize {
    var it: tui.width.Iterator = .init(line);
    var used: usize = 0;
    var offset: usize = 0;
    while (it.next()) |cluster| {
        if (used + cluster.width > column) break;
        used += cluster.width;
        offset = it.index;
    }
    return offset;
}

/// The number of grapheme clusters in `text`.
pub fn clusterCount(text: []const u8) usize {
    var count: usize = 0;
    var it: tui.width.Iterator = .init(text);
    while (it.next()) |_| count += 1;
    return count;
}

/// The cluster boundary before `index`, or 0.
pub fn previousBoundary(text: []const u8, index: usize) usize {
    var it: tui.width.Iterator = .init(text);
    var last: usize = 0;
    while (it.index < index) {
        last = it.index;
        _ = it.next() orelse break;
    }
    return last;
}

/// The cluster boundary after `index`, or the end of `text`.
pub fn nextBoundary(text: []const u8, index: usize) usize {
    var it: tui.width.Iterator = .{ .bytes = text, .index = index };
    _ = it.next();
    return it.index;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n';
}

/// The start of the word before `index`: back over spaces, then over the word.
pub fn wordStart(text: []const u8, index: usize) usize {
    var i = index;
    while (i > 0 and isSpace(text[i - 1])) i -= 1;
    while (i > 0 and !isSpace(text[i - 1])) i -= 1;
    return i;
}

/// The end of the word after `index`: forward over spaces, then over the word.
pub fn wordEnd(text: []const u8, index: usize) usize {
    var i = index;
    while (i < text.len and isSpace(text[i])) i += 1;
    while (i < text.len and !isSpace(text[i])) i += 1;
    return i;
}

const testing = std.testing;
const Driver = tui.testing.Driver(Textarea);

fn startArea(d: *Driver, area: Textarea) !void {
    d.* = try .init(testing.allocator, area, .{});
}

fn finish(d: *Driver) void {
    d.deinit();
}

test "typing lines and submitting with ctrl+d" {
    var d: Driver = undefined;
    try startArea(&d, .{ .gpa = testing.allocator, .prompt = "| " });
    defer finish(&d);
    try d.typeText("one");
    try d.press("enter");
    try d.typeText("two");
    try d.expectFrame("| one\n| two ");
    try d.press("ctrl+d");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqualStrings("one\ntwo", d.model().value());
}

test "up and down keep the column" {
    var d: Driver = undefined;
    try startArea(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.typeText("long line\nab\nanother");
    try d.press("left"); // column 6 of "another"
    try d.press("up");
    try testing.expectEqual(12, d.model().cursor); // the end of "ab"
    try d.press("up");
    try testing.expectEqual(6, d.model().cursor); // column 6 again
    try d.press("up");
    try testing.expectEqual(0, d.model().cursor);
    try d.press("down");
    try d.press("down");
    try d.press("down");
    try testing.expectEqual(d.model().value().len, d.model().cursor);
}

test "home, end, and erasing within a line" {
    var d: Driver = undefined;
    try startArea(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.typeText("first\nsecond line");
    try d.press("home");
    try testing.expectEqual(6, d.model().cursor);
    try d.press("backspace"); // joins the lines
    try testing.expectEqualStrings("firstsecond line", d.model().value());
    try d.press("ctrl+k");
    try testing.expectEqualStrings("first", d.model().value());
    try d.press("ctrl+w");
    try testing.expectEqualStrings("", d.model().value());
}

test "a paste keeps line breaks and normalizes them" {
    var d: Driver = undefined;
    try startArea(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.paste("a\r\nb\rc\td");
    try testing.expectEqualStrings("a\nb\nc    d", d.model().value());
}

test "height scrolls to the cursor's line" {
    var d: Driver = undefined;
    try startArea(&d, .{ .gpa = testing.allocator, .prompt = "", .height = 2 });
    defer finish(&d);
    try d.typeText("1\n2\n3");
    try d.expectFrame("2\n3 ");
    try d.press("up");
    try d.press("up");
    try d.expectFrame("1 \n2");
    try d.press("down");
    try d.press("down");
    try d.expectFrame("2\n3 ");
}

test "placeholder, char_limit, and esc" {
    var d: Driver = undefined;
    try startArea(&d, .{
        .gpa = testing.allocator,
        .prompt = "",
        .placeholder = "Write",
        .char_limit = 4,
    });
    defer finish(&d);
    try d.expectFrame("Write");
    try d.typeText("ab");
    try d.press("enter");
    try d.typeText("cd");
    try testing.expectEqualStrings("ab\nc", d.model().value());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "the cursor at the end of a line is a reversed space" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    var area: Textarea = .{ .gpa = testing.allocator, .styles = .{ .prompt = .{} } };
    defer area.deinit();
    try area.setValue("x\ny");
    area.cursor = 1;
    try area.view(&w);
    try testing.expectEqualStrings("┃ x\x1b[7m \x1b[0m\n┃ y", w.buffered());
}

test lineOf {
    try testing.expectEqual(Line{ .start = 0, .end = 2 }, lineOf("ab\ncd", 1));
    try testing.expectEqual(Line{ .start = 3, .end = 5 }, lineOf("ab\ncd", 3));
    try testing.expectEqual(Line{ .start = 3, .end = 3 }, lineOf("ab\n", 3));
}

test offsetAtColumn {
    try testing.expectEqual(2, offsetAtColumn("abc", 2));
    try testing.expectEqual(3, offsetAtColumn("abc", 9));
    try testing.expectEqual(1, offsetAtColumn("a中b", 2)); // the wide char does not fit
    try testing.expectEqual(4, offsetAtColumn("a中b", 3));
}

test "line numbers line up" {
    var area: Textarea = .{
        .gpa = testing.allocator,
        .prompt = "",
        .line_numbers = true,
        .focused = false,
        .styles = .{ .line_number = .{}, .prompt = .{} },
    };
    defer area.deinit();
    try area.insert("a\nb\nc\nd\ne\nf\ng\nh\ni\nj");
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try area.view(&out.writer);
    try testing.expect(std.mem.startsWith(u8, out.written(), " 1 a\n 2 b"));
    try testing.expect(std.mem.endsWith(u8, out.written(), "10 j"));
}

test "width wraps long lines; up and down move by rows" {
    var d: Driver = try .init(testing.allocator, .{
        .gpa = testing.allocator,
        .prompt = "> ",
        .width = 6,
        .styles = .{ .cursor = .{}, .prompt = .{} },
    }, .{});
    defer finish(&d);
    // Six columns: the prompt, three characters, and one for the cursor.
    try d.typeText("abcdefg");
    try d.press("enter");
    try d.typeText("hi");
    try d.expectFrame("> abc\n> def\n> g\n> hi ");
    try testing.expectEqual(Position{ .row = 3, .column = 4 }, d.model().cursorPosition());
    try d.press("up");
    try testing.expectEqual(Position{ .row = 2, .column = 3 }, d.model().cursorPosition());
    try d.press("up");
    try d.press("left");
    try testing.expectEqual(4, d.model().cursor);
    try d.press("down");
    try testing.expectEqual(7, d.model().cursor);
}

test "max_lines stops the text at a line break past it" {
    var d: Driver = try .init(testing.allocator, .{
        .gpa = testing.allocator,
        .max_lines = 2,
    }, .{});
    defer finish(&d);
    try d.paste("a\nb\nc");
    try testing.expectEqualStrings("a\nb", d.model().value());
    try d.press("enter");
    try d.typeText("x");
    try testing.expectEqualStrings("a\nbx", d.model().value());
}

test "end_of_buffer fills the rows to height; the cursor's line has its own styles" {
    var area: Textarea = .{
        .gpa = testing.allocator,
        .prompt = "|",
        .height = 3,
        .line_numbers = true,
        .end_of_buffer = "~",
        .styles = .{
            .prompt = .{},
            .cursor = .{},
            .line_number = .{},
            .end_of_buffer = .{},
            .cursor_line = .{ .bold = true },
            .cursor_line_number = .{ .italic = true },
        },
    };
    defer area.deinit();
    try area.setValue("a\nb");
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try area.view(&out.writer);
    try testing.expectEqualStrings(
        "|1 a\n|\x1b[3m2 \x1b[0m\x1b[1mb\x1b[0m \n|  ~",
        out.written(),
    );
}

test "undo and redo across lines, a word at a time, cursor included" {
    var d: Driver = try .init(testing.allocator, .{ .gpa = testing.allocator }, .{});
    defer finish(&d);
    try d.typeText("one two");
    try d.press("enter");
    try d.typeText("three");
    try d.press("ctrl+z");
    try testing.expectEqualStrings("one two\n", d.model().value());
    try testing.expectEqual(8, d.model().cursor);
    try d.press("ctrl+z");
    try testing.expectEqualStrings("one ", d.model().value());
    try d.press("ctrl+y");
    try d.press("ctrl+Z"); // ctrl+shift+z
    try testing.expectEqualStrings("one two\nthree", d.model().value());
    try testing.expectEqual(13, d.model().cursor);
    try testing.expect(!d.model().redo());
}

test "a multi-line paste, a ctrl+u, and a run of backspaces are one step each" {
    var d: Driver = try .init(testing.allocator, .{ .gpa = testing.allocator }, .{});
    defer finish(&d);
    try d.paste("first\nsecond line");
    try d.press("ctrl+u");
    try testing.expectEqualStrings("first\n", d.model().value());
    try d.press("backspace");
    try d.press("backspace");
    try testing.expectEqualStrings("firs", d.model().value());
    try d.press("ctrl+z");
    try testing.expectEqualStrings("first\n", d.model().value());
    try d.press("ctrl+z");
    try testing.expectEqualStrings("first\nsecond line", d.model().value());
    try testing.expectEqual(17, d.model().cursor);
    try d.press("ctrl+z");
    try testing.expectEqualStrings("", d.model().value());
    try d.typeText("x");
    try testing.expect(!d.model().redo());
}

test "undo_limit bounds the textarea's history" {
    var area: Textarea = .{ .gpa = testing.allocator, .undo_limit = 1 };
    defer area.deinit();
    try area.setValue("a\nb");
    try area.setValue("c");
    try testing.expect(area.undo());
    try testing.expect(!area.undo());
    try testing.expectEqualStrings("a\nb", area.value());
}
