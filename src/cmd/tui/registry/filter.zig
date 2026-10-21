//! Type to narrow a list by fuzzy matching, then choose one item (or several, with a
//! limit above one). Matched characters are highlighted.
//!
//! ```zig
//! var filter: Filter = try .init(gpa, &.{ "build.zig", "src/main.zig", "README.md" });
//! defer filter.deinit();
//! // ... run ...
//! if (filter.status == .submitted) use(filter.items[filter.current().?]);
//! ```
//!
//! Keys: printable characters and the `input` editing keys edit the query; up/down
//! (ctrl+p/ctrl+n) and pgup/pgdown move; when `limit` allows more than one, tab chooses or
//! clears the highlighted item and moves down (shift+tab, up; ctrl+space, nowhere) and
//! ctrl+a chooses every match (as many as the limit allows), or clears them all when that is
//! already done; enter (or ctrl+q) submits (choosing the highlighted item when nothing else
//! is chosen); esc cancels. Enter does nothing when no row is shown.
//!
//! With `strict` off, a query that is not an item is offered as the first row, so enter
//! there submits the typed text itself: the filter ends submitted with nothing chosen, and
//! the query is the answer. `reverse` draws from the bottom up: the query last, the best
//! match just above it. `fill` makes the list as tall as the terminal leaves room for.
//!
//! Scoring (`score`): the query matches when its characters appear in the item in order,
//! not necessarily together. Matching ignores ASCII case unless the query has an uppercase
//! letter ("smart case"). Every matched character scores 16, plus 8 when it starts a word
//! (the item's first character, one after a space or one of `-_./\:`, or an uppercase
//! letter after a lowercase one) and 8 when it directly follows the previous match; every
//! unmatched character between the first and last match costs 1. Each place the first
//! character occurs is tried as a start, matching the rest as early as possible after it,
//! and the best total wins. Items are shown best first; equal scores keep the shorter item
//! first, then the original order (or only the original order, with `sort` off). An empty
//! query matches everything, in order. With `fuzzy` off, an item matches when it contains
//! the query as it is, ignoring ASCII case, and items keep their order.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Input = @import("input.zig");
const List = @import("list.zig");

pub const Status = enum { active, submitted, canceled };

const Filter = @This();

gpa: Allocator,
items: []const []const u8,
/// The query being typed.
query: Input,
/// The matching items, best first; `list.items` is `shown.items`.
list: List,
matches: std.ArrayList(Match) = .empty,
shown: std.ArrayList([]const u8) = .empty,
/// One flag per item of `items`.
chosen: []bool,
/// The most items that may be chosen; null for no limit. Tab chooses when above 1.
limit: ?usize = 1,
/// A line above the query; none when empty.
header: []const u8 = "",
chosen_mark: []const u8 = "✓ ",
unchosen_mark: []const u8 = "• ",
/// Off: a query that is not an item can be submitted as it is (see the file header).
strict: bool = true,
/// Off: items match by containing the query.
fuzzy: bool = true,
/// Off: matches keep the items' order.
sort: bool = true,
/// Draw from the bottom up, the query last.
reverse: bool = false,
/// Size the list to the terminal's height, less the header, query, and count rows.
fill: bool = false,
/// Whether the first row is the query itself (`strict` off).
offers_query: bool = false,
status: Status = .active,
styles: Styles = .{},

pub const Styles = struct {
    header: tui.Style = .{ .fg = .{ .indexed = 99 }, .bold = true },
    /// Matched characters: colored, and underlined so they show under `NO_COLOR`.
    match: tui.Style = .{ .fg = .{ .indexed = 212 }, .underline = true },
    chosen: tui.Style = .{ .fg = .{ .indexed = 212 } },
    unchosen: tui.Style = .{},
    count: tui.Style = .{ .fg = .{ .indexed = 240 } },
};

/// An item that matches the query.
pub const Match = struct {
    /// Index into `items`.
    index: usize,
    score: i32,
};

/// A filter over `items` (borrowed), with an empty query.
pub fn init(gpa: Allocator, items: []const []const u8) Allocator.Error!Filter {
    const chosen = try gpa.alloc(bool, items.len);
    @memset(chosen, false);
    var filter: Filter = .{
        .gpa = gpa,
        .items = items,
        .query = .{ .gpa = gpa, .placeholder = "Filter..." },
        .list = .{ .items = &.{} },
        .chosen = chosen,
    };
    errdefer filter.deinit();
    try filter.refilter();
    return filter;
}

/// Frees the query, the matches, and the flags.
pub fn deinit(filter: *Filter) void {
    filter.query.deinit();
    filter.matches.deinit(filter.gpa);
    filter.shown.deinit(filter.gpa);
    filter.gpa.free(filter.chosen);
    filter.* = undefined;
}

/// Matches every item against the query again and sorts the matches.
pub fn refilter(filter: *Filter) Allocator.Error!void {
    const pattern = filter.query.value();
    filter.offers_query = !filter.strict and pattern.len > 0;
    filter.matches.clearRetainingCapacity();
    for (filter.items, 0..) |item, i| {
        if (std.mem.eql(u8, item, pattern)) filter.offers_query = false;
        const points = filter.scoreOf(pattern, item) orelse continue;
        try filter.matches.append(filter.gpa, .{ .index = i, .score = points });
    }
    if (filter.fuzzy and filter.sort and pattern.len > 0) {
        std.mem.sort(Match, filter.matches.items, filter.items, better);
    }
    filter.shown.clearRetainingCapacity();
    if (filter.offers_query) try filter.shown.append(filter.gpa, pattern);
    for (filter.matches.items) |match| {
        try filter.shown.append(filter.gpa, filter.items[match.index]);
    }
    filter.list.setItems(filter.shown.items);
}

fn better(items: []const []const u8, a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    const a_len = items[a.index].len;
    const b_len = items[b.index].len;
    if (a_len != b_len) return a_len < b_len;
    return a.index < b.index;
}

/// How `pattern` matches `text` the way this filter matches (`fuzzy` or not).
fn scoreOf(filter: *const Filter, pattern: []const u8, text: []const u8) ?i32 {
    if (filter.fuzzy) return score(pattern, text, null);
    var position: [1]usize = undefined;
    return if (substring(pattern, text, &position) == null) null else 0;
}

/// The byte offsets in `text` of the characters the query matches.
fn positionsOf(filter: *const Filter, text: []const u8, buffer: []usize) []usize {
    const pattern = filter.query.value();
    if (filter.fuzzy) return matchPositions(pattern, text, buffer);
    return substring(pattern, text, buffer) orelse buffer[0..0];
}

/// The index in `items` of the highlighted match; null when no row is shown or the
/// highlighted row is the query itself.
pub fn current(filter: *const Filter) ?usize {
    if (filter.list.items.len == 0) return null;
    return filter.itemAt(filter.list.cursor);
}

/// The index in `items` shown on list row `row`, or null for the query's own row.
fn itemAt(filter: *const Filter, row: usize) ?usize {
    if (!filter.offers_query) return filter.matches.items[row].index;
    return if (row == 0) null else filter.matches.items[row - 1].index;
}

/// Whether item `index` (of `items`) is chosen.
pub fn isChosen(filter: *const Filter, index: usize) bool {
    return filter.chosen[index];
}

/// How many items are chosen.
pub fn count(filter: *const Filter) usize {
    return std.mem.count(bool, filter.chosen, &.{true});
}

fn multiple(filter: *const Filter) bool {
    const limit = filter.limit orelse return true;
    return limit > 1;
}

/// Chooses or clears item `index`; choosing past the limit does nothing.
pub fn toggle(filter: *Filter, index: usize) void {
    if (!filter.chosen[index]) {
        if (filter.limit) |limit| {
            if (filter.count() >= limit) return;
        }
    }
    filter.chosen[index] = !filter.chosen[index];
}

/// Chooses every match in order until the limit, or clears every item if no more fit.
pub fn toggleAll(filter: *Filter) void {
    const before = filter.count();
    for (filter.matches.items) |match| {
        if (!filter.chosen[match.index]) filter.toggle(match.index);
    }
    if (filter.count() == before) @memset(filter.chosen, false);
}

/// Moves the cursor a row down the screen (`rows` 1) or up (-1): up the list when
/// `reverse`. Round to the other end with `list.wrap`.
fn move(filter: *Filter, rows: isize) void {
    filter.list.step(if (filter.reverse) -rows else rows);
}

fn headerRows(filter: *const Filter) usize {
    if (filter.header.len == 0) return 0;
    return std.mem.count(u8, filter.header, "\n") + 1;
}

pub fn update(filter: *Filter, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .key => |key| return filter.handleKey(key),
        .paste => |text| {
            filter.query.insert(text) catch {};
            filter.refilter() catch {};
        },
        .resize => |size| {
            _ = filter.list.update(msg);
            if (filter.fill) {
                filter.list.height = @max(size.height -| (filter.headerRows() + 2), 1);
                filter.list.moveTo(filter.list.cursor);
            }
        },
        .mouse => |mouse| {
            // shortcut: the mouse does nothing in reverse; map the reversed rows to items
            // when a reversed filter needs the mouse.
            if (filter.reverse) return .none;
            // The items start below the header and the query line.
            const items_top = filter.list.top + filter.headerRows() + 1;
            _ = filter.list.handleMouse(mouse, items_top);
        },
        else => {},
    }
    return .none;
}

fn handleKey(filter: *Filter, key: tui.input.Key) tui.Cmd {
    if (key.matches("enter") or key.matches("ctrl+q")) {
        if (filter.list.items.len == 0) return .none;
        if (filter.count() == 0) {
            if (filter.current()) |index| filter.chosen[index] = true;
        }
        filter.status = .submitted;
        return .quit;
    }
    if (key.matches("esc")) {
        filter.status = .canceled;
        return .quit;
    }
    const several = filter.multiple();
    const toggles = key.matches("tab") or key.matches("shift+tab") or key.matches("ctrl+space");
    if (several and toggles) {
        if (filter.current()) |index| filter.toggle(index);
        if (key.matches("tab")) filter.move(1) else if (key.matches("shift+tab")) filter.move(-1);
    } else if (several and key.matches("ctrl+a")) {
        filter.toggleAll();
    } else if (key.matches("up") or key.matches("ctrl+p")) {
        filter.move(-1);
    } else if (key.matches("down") or key.matches("ctrl+n")) {
        filter.move(1);
    } else if (key.matches("pgup")) {
        filter.list.page(if (filter.reverse) 1 else -1);
    } else if (key.matches("pgdown")) {
        filter.list.page(if (filter.reverse) -1 else 1);
    } else {
        const before = filter.query.text.items.len;
        const was = filter.query.cursor;
        if (!filter.query.handleKey(key)) return .none;
        // Moving the cursor needs no new matches; anything else might.
        if (filter.query.text.items.len != before or filter.query.cursor == was) {
            filter.refilter() catch {};
        }
    }
    return .none;
}

pub fn view(filter: *const Filter, w: *Writer) Writer.Error!void {
    var row: Writer.Allocating = .init(filter.gpa);
    defer row.deinit();
    const shown = filter.list.window();
    if (filter.reverse) {
        // Blank rows first keep the query on the same row as the matches change.
        for (shown.end - shown.start..@max(filter.list.height, 1)) |_| try w.writeByte('\n');
        var i = shown.end;
        while (i > shown.start) {
            i -= 1;
            try filter.writeRow(w, &row, i);
            try w.writeByte('\n');
        }
        try filter.writeCount(w);
        try w.writeByte('\n');
        try filter.writeHeader(w);
        return filter.query.view(w);
    }
    try filter.writeHeader(w);
    try filter.query.view(w);
    for (shown.start..shown.end) |i| {
        try w.writeByte('\n');
        try filter.writeRow(w, &row, i);
    }
    try w.writeByte('\n');
    try filter.writeCount(w);
}

fn writeHeader(filter: *const Filter, w: *Writer) Writer.Error!void {
    if (filter.header.len == 0) return;
    try filter.styles.header.paint(w, filter.header);
    try w.writeByte('\n');
}

fn writeCount(filter: *const Filter, w: *Writer) Writer.Error!void {
    try filter.styles.count.writeSgr(w);
    try w.print("{d}/{d}", .{ filter.matches.items.len, filter.items.len });
    if (filter.limit != 1) try w.print(", {d} chosen", .{filter.count()});
    if (filter.styles.count.hasSgr()) try w.writeAll(tui.ansi.reset);
}

/// Writes list row `row` as the list lays it out, `buffer` holding its text meanwhile.
fn writeRow(
    filter: *const Filter,
    w: *Writer,
    buffer: *Writer.Allocating,
    row: usize,
) Writer.Error!void {
    buffer.clearRetainingCapacity();
    try filter.writeItem(&buffer.writer, row);
    try filter.list.writeRow(w, row, buffer.written());
}

/// Writes list row `row`: its mark when several may be chosen, then the item (or the
/// query, on its own row) with the matched characters highlighted.
fn writeItem(filter: *const Filter, w: *Writer, row: usize) Writer.Error!void {
    const index = filter.itemAt(row);
    // A highlight's reset ends the row's own style; this starts it again.
    const restyle = filter.list.textStyle(row);
    if (filter.multiple()) {
        const chosen = if (index) |i| filter.chosen[i] else false;
        const style = if (chosen) filter.styles.chosen else filter.styles.unchosen;
        try style.paint(w, if (chosen) filter.chosen_mark else filter.unchosen_mark);
        if (style.hasSgr()) try restyle.writeSgr(w);
    }
    const text = if (index) |i| filter.items[i] else filter.query.value();
    var positions: [max_positions]usize = undefined;
    const matched = filter.positionsOf(text, &positions);
    var it: tui.width.Iterator = .init(text);
    var start: usize = 0;
    var next: usize = 0;
    while (it.next()) |cluster| : (start = it.index) {
        if (next < matched.len and matched[next] == start) {
            next += 1;
            try filter.styles.match.paint(w, cluster.bytes);
            try restyle.writeSgr(w);
        } else {
            try w.writeAll(cluster.bytes);
        }
    }
}

/// The most matched characters `matchPositions` reports; the rest are matched but not
/// highlighted.
pub const max_positions = 64;

const score_match = 16;
const bonus_word_start = 8;
const bonus_consecutive = 8;
const penalty_gap = 1;

/// How well `pattern` matches `text` (higher is better), or null when it does not match.
/// See the file header for the rules. When `positions` is given, the byte offsets in
/// `text` of the best alignment's matched characters are written to it, as many as fit.
pub fn score(pattern: []const u8, text: []const u8, positions: ?[]usize) ?i32 {
    if (pattern.len == 0) return 0;
    const exact = hasUpper(pattern);
    const first = decode(pattern, 0);
    var best: ?i32 = null;
    var candidate: [max_positions]usize = undefined;
    var start: usize = 0;
    while (start < text.len) : (start += decode(text, start).len) {
        if (!same(decode(text, start).cp, first.cp, exact)) continue;
        const points = alignFrom(pattern, text, start, exact, &candidate) orelse break;
        if (best == null or points > best.?) {
            best = points;
            if (positions) |out| {
                const n = @min(out.len, candidate.len, codepointCount(pattern));
                @memcpy(out[0..n], candidate[0..n]);
            }
        }
    }
    return best;
}

/// The byte offsets of the characters `pattern` matches in `text` (empty when it does not
/// match), in order, at most `buffer.len` of them.
pub fn matchPositions(pattern: []const u8, text: []const u8, buffer: []usize) []usize {
    if (pattern.len == 0) return buffer[0..0];
    _ = score(pattern, text, buffer) orelse return buffer[0..0];
    return buffer[0..@min(buffer.len, codepointCount(pattern))];
}

/// Where `pattern` first occurs in `text`, ignoring ASCII case (`fuzzy` off): the byte
/// offsets of its characters, at most `buffer.len` of them; null when it does not occur.
pub fn substring(pattern: []const u8, text: []const u8, buffer: []usize) ?[]usize {
    const at = std.ascii.findIgnoreCase(text, pattern) orelse return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < pattern.len and n < buffer.len) : (i += decode(pattern, i).len) {
        buffer[n] = at + i;
        n += 1;
    }
    return buffer[0..n];
}

/// Matches `pattern` in `text` from `start`, each character as early as possible. Null
/// when the rest of the pattern does not fit, which no later start can fix.
fn alignFrom(
    pattern: []const u8,
    text: []const u8,
    start: usize,
    exact: bool,
    positions: *[max_positions]usize,
) ?i32 {
    var total: i32 = 0;
    var at = start;
    var previous: ?usize = null; // the offset just past the previous match
    var p: usize = 0;
    var n: usize = 0;
    while (p < pattern.len) : (n += 1) {
        const want = decode(pattern, p);
        while (at < text.len and !same(decode(text, at).cp, want.cp, exact)) {
            if (previous != null) total -= penalty_gap;
            at += decode(text, at).len;
        }
        if (at >= text.len) return null;
        total += score_match;
        if (isWordStart(text, at)) total += bonus_word_start;
        if (previous == at) total += bonus_consecutive;
        if (n < max_positions) positions[n] = at;
        at += decode(text, at).len;
        previous = at;
        p += want.len;
    }
    return total;
}

const Decoded = struct { cp: u21, len: u3 };

/// The codepoint at `bytes[i]`; a byte that does not start valid UTF-8 stands for itself.
fn decode(bytes: []const u8, i: usize) Decoded {
    const byte: Decoded = .{ .cp = bytes[i], .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return byte;
    if (i + len > bytes.len) return byte;
    const cp = std.unicode.utf8Decode(bytes[i..][0..len]) catch return byte;
    return .{ .cp = cp, .len = len };
}

fn codepointCount(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += decode(text, i).len) n += 1;
    return n;
}

fn same(a: u21, b: u21, exact: bool) bool {
    if (exact) return a == b;
    return fold(a) == fold(b);
}

fn fold(cp: u21) u21 {
    return if (cp < 0x80) std.ascii.toLower(@intCast(cp)) else cp;
}

fn hasUpper(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

fn isWordStart(text: []const u8, at: usize) bool {
    if (at == 0) return true;
    const before = text[at - 1];
    if (std.mem.indexOfScalar(u8, " -_./\\:", before) != null) return true;
    return std.ascii.isLower(before) and std.ascii.isUpper(text[at]);
}

const testing = std.testing;

test "score: subsequences match, in order" {
    try testing.expect(score("abc", "a-b-c", null) != null);
    try testing.expect(score("abc", "acb", null) == null);
    try testing.expect(score("", "anything", null).? == 0);
    try testing.expect(score("x", "", null) == null);
}

test "score: smart case" {
    try testing.expect(score("readme", "README.md", null) != null);
    try testing.expect(score("README", "readme.md", null) == null);
    try testing.expect(score("Read", "README", null) == null);
    try testing.expect(score("Read", "ReadMe", null) != null);
}

test "score: the exact points" {
    // r at a word start (16 + 8), e and a consecutive (16 + 8 each).
    try testing.expectEqual(72, score("rea", "read", null).?);
    // m after '.', a word start; one gap after it.
    try testing.expectEqual(24 + 16 - 1, score("md", "x.mxd", null).?);
    // camelCase humps start words.
    try testing.expectEqual(24 + 24 - 2, score("fb", "fooBar", null).?);
}

test "score: the best start wins" {
    var positions: [4]usize = undefined;
    // "b" first occurs mid-word; the later one starts a word and is followed by "a".
    _ = score("ba", "abc ba", &positions).?;
    try testing.expectEqualSlices(usize, &.{ 4, 5 }, positions[0..2]);
}

test matchPositions {
    var buffer: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 0, 4 }, matchPositions("sz", "src/zig", &buffer));
    try testing.expectEqualSlices(usize, &.{ 0, 4 }, matchPositions("中b", "中ab", &buffer));
    try testing.expectEqual(0, matchPositions("q", "abc", &buffer).len);
    try testing.expectEqual(0, matchPositions("", "abc", &buffer).len);
}

const Driver = tui.testing.Driver(Filter);
const files = [_][]const u8{ "README.md", "build.zig", "src/main.zig", "src/tui/root.zig" };

fn startFilter(d: *Driver, limit: ?usize) !void {
    var filter: Filter = try .init(testing.allocator, &files);
    filter.limit = limit;
    filter.query.placeholder = "";
    d.* = try .init(testing.allocator, filter, .{});
}

fn finish(d: *Driver) void {
    d.deinit();
}

test "typing narrows and orders the items" {
    var d: Driver = undefined;
    try startFilter(&d, 1);
    defer finish(&d);
    try d.expectFrame(">  \n> README.md\n  build.zig\n  src/main.zig\n  src/tui/root.zig\n4/4");
    try d.typeText("zig");
    try d.expectFrame("> zig \n> build.zig\n  src/main.zig\n  src/tui/root.zig\n3/4");
    try d.typeText("m");
    try d.expectFrame("> zigm \n0/4");
    try d.press("ctrl+u");
    try d.typeText("srt");
    try d.expectFrame("> srt \n> src/tui/root.zig\n1/4");
    try d.press("ctrl+u");
    try d.typeText("main");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(2, d.model().current().?);
    try testing.expect(d.model().isChosen(2));
}

test "matched characters are highlighted" {
    var d: Driver = undefined;
    try startFilter(&d, 1);
    defer finish(&d);
    try d.typeText("bz");
    const frame = d.frameBytes();
    // The cursor row: b and z underlined in the match color, the cursor color restored.
    const want = "\x1b[4;38;5;212mb\x1b[0m\x1b[38;5;212muild.\x1b[4;38;5;212mz\x1b[0m" ++
        "\x1b[38;5;212mig";
    if (std.mem.indexOf(u8, frame, want) == null) {
        std.debug.print("frame: {f}\n", .{std.ascii.hexEscape(frame, .lower)});
        return error.TestUnexpectedResult;
    }
}

test "navigation, no match, and esc" {
    var d: Driver = undefined;
    try startFilter(&d, 1);
    defer finish(&d);
    try d.press("down");
    try d.press("ctrl+n");
    try testing.expectEqual(2, d.model().current().?);
    try d.press("up");
    try testing.expectEqual(1, d.model().current().?);
    try d.typeText("qq");
    try testing.expectEqual(null, d.model().current());
    try d.press("enter");
    try testing.expect(!d.done());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "tab chooses several up to the limit" {
    var d: Driver = undefined;
    try startFilter(&d, 2);
    defer finish(&d);
    try d.typeText("src");
    try d.expectFrame("> src \n> • src/main.zig\n  • src/tui/root.zig\n2/4, 0 chosen");
    try d.press("tab");
    try d.press("tab");
    try d.press("ctrl+u");
    try d.press("tab"); // the limit is reached
    try d.expectFrame(">  \n  • README.md\n  • build.zig\n> ✓ src/main.zig\n  ✓ src/tui/root.zig" ++
        "\n4/4, 2 chosen");
    try d.press("enter");
    try testing.expect(d.model().isChosen(2) and d.model().isChosen(3));
    try testing.expectEqual(2, d.model().count());
}

test "a paste refilters" {
    var d: Driver = undefined;
    try startFilter(&d, null);
    defer finish(&d);
    try d.paste("READ");
    try testing.expectEqual(1, d.model().matches.items.len);
    try d.press("enter");
    try testing.expect(d.model().isChosen(0));
}

test substring {
    var buffer: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 4, 5 }, substring("MA", "src/main.zig", &buffer).?);
    try testing.expectEqual(null, substring("sz", "src/zig", &buffer));
    try testing.expectEqual(0, substring("", "abc", &buffer).?.len);
}

test "strict off: the query is a row of its own, and the answer" {
    var d: Driver = undefined;
    try startFilter(&d, 1);
    defer finish(&d);
    d.model().strict = false;
    try d.typeText("zi");
    try d.expectFrame("> zi \n> zi\n  build.zig\n  src/main.zig\n  src/tui/root.zig\n3/4");
    try d.typeText("p");
    try d.expectFrame("> zip \n> zip\n0/4");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqual(0, d.model().count());
    try testing.expectEqualStrings("zip", d.model().query.value());
}

test "strict off: no query row for an item typed in full, or for nothing typed" {
    var d: Driver = undefined;
    try startFilter(&d, 1);
    defer finish(&d);
    d.model().strict = false;
    try d.typeText("build.zig");
    try d.expectFrame("> build.zig \n> build.zig\n1/4");
    try d.press("ctrl+u");
    try testing.expectEqual(4, d.model().list.items.len);
    try d.typeText("x");
    try d.press("down");
    try d.press("enter");
    try testing.expectEqual(0, d.model().count());
}

test "fuzzy off: the query as it is, items in their order" {
    var d: Driver = undefined;
    try startFilter(&d, 1);
    defer finish(&d);
    d.model().fuzzy = false;
    try d.typeText("I");
    try d.expectFrame("> I \n> build.zig\n  src/main.zig\n  src/tui/root.zig\n3/4");
    try d.typeText("n");
    try d.expectFrame("> In \n> src/main.zig\n1/4");
    try d.press("ctrl+u");
    try d.typeText("sz");
    try d.expectFrame("> sz \n0/4");
}

test "sort off: fuzzy matches in their order" {
    var d: Driver = undefined;
    try startFilter(&d, 1);
    defer finish(&d);
    d.model().sort = false;
    try d.typeText("r");
    // Sorted, src/tui/root.zig (where r starts a word) would come before src/main.zig.
    try d.expectFrame("> r \n> README.md\n  src/main.zig\n  src/tui/root.zig\n3/4");
}

test "reverse: from the bottom up, up moves to the next match" {
    var filter: Filter = try .init(testing.allocator, &files);
    filter.reverse = true;
    filter.header = "Pick";
    filter.list.height = 5;
    filter.query.placeholder = "";
    var d: Driver = try .init(testing.allocator, filter, .{});
    defer finish(&d);
    try d.typeText("zig");
    try d.expectFrame("\n\n  src/tui/root.zig\n  src/main.zig\n> build.zig\n3/4\nPick\n> zig ");
    try d.press("up");
    try d.press("enter");
    try testing.expect(d.model().isChosen(2));
}

test "fill: as many rows as the terminal leaves" {
    var filter: Filter = try .init(testing.allocator, &files);
    filter.fill = true;
    filter.header = "two\nlines";
    var d: Driver = try .init(testing.allocator, filter, .{
        .program = .{ .size = .{ .width = 40, .height = 6 } },
    });
    defer finish(&d);
    // 6 rows: the header's two, the query, the count, and two items.
    try testing.expectEqual(2, d.model().list.height);
    try d.resize(.{ .width = 40, .height = 3 });
    try testing.expectEqual(1, d.model().list.height);
}

test "shift+tab chooses and moves up; ctrl+a chooses the matches, then clears" {
    var d: Driver = undefined;
    try startFilter(&d, 3);
    defer finish(&d);
    try d.press("pgdown");
    try d.press("shift+tab");
    try testing.expect(d.model().isChosen(3));
    try testing.expectEqual(2, d.model().list.cursor);
    try d.typeText("src");
    try d.press("ctrl+a");
    try testing.expectEqual(2, d.model().count());
    try testing.expect(d.model().isChosen(2));
    try d.press("ctrl+u");
    try d.press("ctrl+a");
    try testing.expectEqual(3, d.model().count());
    try d.press("ctrl+a");
    try testing.expectEqual(0, d.model().count());
}

test "the unchosen mark has a style of its own" {
    var filter: Filter = try .init(testing.allocator, files[0..1]);
    filter.limit = null;
    filter.styles.unchosen = .{ .bold = true };
    filter.list.styles = .{ .cursor = .{}, .cursor_text = .{ .italic = true } };
    var d: Driver = try .init(testing.allocator, filter, .{});
    defer finish(&d);
    try d.expectFrameContains("> • README.md");
    // The mark in its style, then the row's own text style again.
    const want = "\x1b[3m\x1b[1m• \x1b[0m\x1b[3mREADME.md";
    if (std.mem.indexOf(u8, d.frameBytes(), want) == null) {
        std.debug.print("frame: {f}\n", .{std.ascii.hexEscape(d.frameBytes(), .lower)});
        return error.TestUnexpectedResult;
    }
}
