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
//! (ctrl+p/ctrl+n) and pgup/pgdown move; tab chooses or clears the highlighted item when
//! `limit` allows more than one; enter submits (choosing the highlighted item when nothing
//! else is chosen); esc cancels. Enter does nothing when no item matches.
//!
//! Scoring (`score`): the query matches when its characters appear in the item in order,
//! not necessarily together. Matching ignores ASCII case unless the query has an uppercase
//! letter ("smart case"). Every matched character scores 16, plus 8 when it starts a word
//! (the item's first character, one after a space or one of `-_./\:`, or an uppercase
//! letter after a lowercase one) and 8 when it directly follows the previous match; every
//! unmatched character between the first and last match costs 1. Each place the first
//! character occurs is tried as a start, matching the rest as early as possible after it,
//! and the best total wins. Items are shown best first; equal scores keep the shorter item
//! first, then the original order. An empty query matches everything, in order.

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
status: Status = .active,
styles: Styles = .{},

pub const Styles = struct {
    header: tui.Style = .{ .fg = .{ .indexed = 99 }, .bold = true },
    /// Matched characters: colored, and underlined so they show under `NO_COLOR`.
    match: tui.Style = .{ .fg = .{ .indexed = 212 }, .underline = true },
    chosen: tui.Style = .{ .fg = .{ .indexed = 212 } },
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
    filter.matches.clearRetainingCapacity();
    for (filter.items, 0..) |item, i| {
        const points = score(pattern, item, null) orelse continue;
        try filter.matches.append(filter.gpa, .{ .index = i, .score = points });
    }
    std.mem.sort(Match, filter.matches.items, filter.items, better);
    filter.shown.clearRetainingCapacity();
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

/// The index in `items` of the highlighted match, or null when nothing matches.
pub fn current(filter: *const Filter) ?usize {
    if (filter.matches.items.len == 0) return null;
    return filter.matches.items[filter.list.cursor].index;
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

pub fn update(filter: *Filter, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .key => |key| return filter.handleKey(key),
        .paste => |text| {
            filter.query.insert(text) catch {};
            filter.refilter() catch {};
        },
        .resize => _ = filter.list.update(msg),
        .mouse => |mouse| {
            // The items start below the header and the query line.
            const items_top = filter.list.top + @intFromBool(filter.header.len > 0) + 1;
            _ = filter.list.handleMouse(mouse, items_top);
        },
        else => {},
    }
    return .none;
}

fn handleKey(filter: *Filter, key: tui.input.Key) tui.Cmd {
    if (key.matches("enter")) {
        const index = filter.current() orelse return .none;
        if (filter.count() == 0) filter.chosen[index] = true;
        filter.status = .submitted;
        return .quit;
    }
    if (key.matches("esc")) {
        filter.status = .canceled;
        return .quit;
    }
    if (key.matches("tab") and filter.multiple()) {
        if (filter.current()) |index| filter.toggle(index);
        filter.list.moveBy(1);
    } else if (key.matches("up") or key.matches("ctrl+p")) {
        filter.list.moveBy(-1);
    } else if (key.matches("down") or key.matches("ctrl+n")) {
        filter.list.moveBy(1);
    } else if (key.matches("pgup")) {
        filter.list.page(-1);
    } else if (key.matches("pgdown")) {
        filter.list.page(1);
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
    if (filter.header.len > 0) {
        try filter.styles.header.paint(w, filter.header);
        try w.writeByte('\n');
    }
    try filter.query.view(w);
    var row: Writer.Allocating = .init(filter.gpa);
    defer row.deinit();
    const shown = filter.list.window();
    for (shown.start..shown.end) |i| {
        try w.writeByte('\n');
        row.clearRetainingCapacity();
        try filter.writeItem(&row.writer, i);
        try filter.list.writeRow(w, i, row.written());
    }
    try w.writeByte('\n');
    try filter.styles.count.writeSgr(w);
    try w.print("{d}/{d}", .{ filter.matches.items.len, filter.items.len });
    if (filter.limit != 1) try w.print(", {d} chosen", .{filter.count()});
    if (filter.styles.count.hasSgr()) try w.writeAll(tui.ansi.reset);
}

/// Writes match `row` (an index into `matches`): its mark when several may be chosen,
/// then the item with the matched characters highlighted.
fn writeItem(filter: *const Filter, w: *Writer, row: usize) Writer.Error!void {
    const index = filter.matches.items[row].index;
    const on_cursor = row == filter.list.cursor;
    // A highlight's reset ends the row's own style; this starts it again.
    const restyle: tui.Style = if (on_cursor) filter.list.styles.cursor else .{};
    if (filter.multiple()) {
        const chosen = filter.chosen[index];
        const style: tui.Style = if (chosen) filter.styles.chosen else .{};
        try style.paint(w, if (chosen) filter.chosen_mark else filter.unchosen_mark);
        if (chosen) try restyle.writeSgr(w);
    }
    const text = filter.items[index];
    var positions: [max_positions]usize = undefined;
    const matched = matchPositions(filter.query.value(), text, &positions);
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
