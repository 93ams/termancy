//! Display width of UTF-8 text in terminal columns, and the operations built on it:
//! truncation with an ellipsis and word wrapping. Escape sequences take no columns.
//!
//! Text is split into extended grapheme clusters as Unicode Standard Annex #29 defines
//! them (emoji ZWJ sequences, flags, Hangul syllables, Indic conjuncts, combining marks
//! included), from tables generated from the Unicode Character Database (`unicode_tables.zig`,
//! `tools/unicode.zig`). Two departures, both how terminals behave: CR LF is two clusters,
//! since a terminal acts on each control alone, and escape sequences are clusters of their
//! own.
//!
//! A cluster's width is that of its first codepoint with any (0 for controls, combining
//! marks, format characters, default-ignorable codepoints, Hangul medial and final jamo; 2
//! for East Asian Wide and Fullwidth and for emoji presented as emoji; 1 otherwise, East
//! Asian Ambiguous included), widened to 2 by VS16 (U+FE0F); a flag (two regional
//! indicators) is 2. Tabs are controls (0 columns); expand them before measuring. A byte
//! that is not valid UTF-8 is one cluster of 1 column (terminals draw U+FFFD).

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");
const Parser = @import("Parser.zig");
const Pen = @import("Pen.zig");
const tables = @import("unicode_tables.zig");

/// The Unicode version the tables follow.
pub const unicode_version = tables.version;

/// The Grapheme_Cluster_Break property (UAX #29).
pub const Break = enum(u4) {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
};

/// The Indic_Conjunct_Break property.
pub const ConjunctBreak = enum(u2) { none, linker, consonant, extend };

/// What segmentation and measuring need to know about a codepoint.
pub const Properties = struct {
    grapheme_break: Break,
    extended_pictographic: bool,
    conjunct_break: ConjunctBreak,
    width: u2,
};

/// The properties of `cp`.
pub fn properties(cp: u21) Properties {
    const block: usize = tables.stage1[cp >> 8];
    const value = tables.values[tables.stage2[block * 256 + (cp & 0xff)]];
    return .{
        .grapheme_break = @fromBackingInt(@intCast(@as(u4, @truncate(value)))),
        .extended_pictographic = value & 0x10 != 0,
        .conjunct_break = @fromBackingInt(@intCast(@as(u2, @truncate(value >> 5)))),
        .width = @truncate(value >> 7),
    };
}

/// The width of one codepoint, outside any cluster.
pub fn ofCodepoint(cp: u21) u2 {
    return properties(cp).width;
}

/// Decides, codepoint by codepoint, where grapheme clusters end: rules GB3 to GB13 of UAX
/// #29, which need what came before (a run of regional indicators, an emoji and its
/// extenders, an Indic consonant and its linkers).
pub const Segmenter = struct {
    previous: ?Properties = null,
    /// The run of regional indicators ending at `previous` has an odd length.
    odd_indicators: bool = false,
    emoji: enum { none, pictographic, joined } = .none,
    conjunct: enum { none, consonant, linked } = .none,

    /// Whether a cluster boundary falls before a codepoint with `next`'s properties, then
    /// moves past it.
    pub fn breaksBefore(seg: *Segmenter, next: Properties) bool {
        const result = if (seg.previous) |prev| seg.boundary(prev, next) else true;
        seg.advance(next);
        return result;
    }

    fn boundary(seg: *const Segmenter, prev: Properties, next: Properties) bool {
        const a = prev.grapheme_break;
        const b = next.grapheme_break;
        if (a == .cr and b == .lf) return false; // GB3
        if (a == .control or a == .cr or a == .lf) return true; // GB4
        if (b == .control or b == .cr or b == .lf) return true; // GB5
        if (a == .l and (b == .l or b == .v or b == .lv or b == .lvt)) return false; // GB6
        if ((a == .lv or a == .v) and (b == .v or b == .t)) return false; // GB7
        if ((a == .lvt or a == .t) and b == .t) return false; // GB8
        if (b == .extend or b == .zwj or b == .spacing_mark) return false; // GB9, GB9a
        if (a == .prepend) return false; // GB9b
        if (seg.conjunct == .linked and next.conjunct_break == .consonant) return false; // GB9c
        if (seg.emoji == .joined and next.extended_pictographic) return false; // GB11
        if (a == .regional_indicator and b == .regional_indicator and seg.odd_indicators) {
            return false; // GB12, GB13
        }
        return true; // GB999
    }

    fn advance(seg: *Segmenter, next: Properties) void {
        const b = next.grapheme_break;
        seg.odd_indicators = b == .regional_indicator and !seg.odd_indicators;
        seg.emoji = if (next.extended_pictographic)
            .pictographic
        else if (seg.emoji == .pictographic and b == .extend)
            .pictographic
        else if (seg.emoji == .pictographic and b == .zwj)
            .joined
        else
            .none;
        seg.conjunct = switch (next.conjunct_break) {
            .consonant => .consonant,
            .linker => if (seg.conjunct != .none) .linked else .none,
            .extend => seg.conjunct,
            .none => .none,
        };
        seg.previous = next;
    }
};

/// One unit of display: a grapheme cluster, an escape sequence, or a byte that is not
/// valid UTF-8.
pub const Cluster = struct {
    bytes: []const u8,
    width: u2,
    /// An escape sequence, which takes no columns but must be kept in place.
    escape: bool = false,
};

/// Splits text into clusters.
pub const Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    /// An iterator from the start of `bytes`.
    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    /// The next cluster, or null at the end.
    pub fn next(it: *Iterator) ?Cluster {
        if (it.index >= it.bytes.len) return null;
        const start = it.index;
        if (it.bytes[start] == 0x1b) {
            it.index += ansi.sequenceLen(it.bytes[start..]);
            return .{ .bytes = it.bytes[start..it.index], .width = 0, .escape = true };
        }
        const first = it.peek() orelse {
            it.index += 1;
            return .{ .bytes = it.bytes[start..it.index], .width = 1 };
        };
        it.index += first.len;
        const props = properties(first.cp);
        // A control is a cluster alone, CR before LF included (see the file header).
        if (isControl(props)) return .{ .bytes = it.bytes[start..it.index], .width = 0 };
        var seg: Segmenter = .{};
        _ = seg.breaksBefore(props);
        var width: u2 = props.width;
        var indicators: u2 = @intFromBool(props.grapheme_break == .regional_indicator);
        while (it.peek()) |following| {
            const more = properties(following.cp);
            if (isControl(more) or seg.breaksBefore(more)) break;
            it.index += following.len;
            if (width == 0) width = more.width;
            if (following.cp == 0xfe0f and width == 1) width = 2;
            if (more.grapheme_break == .regional_indicator) indicators +|= 1;
        }
        if (indicators == 2) width = 2;
        return .{ .bytes = it.bytes[start..it.index], .width = width };
    }

    const Peeked = struct { cp: u21, len: u3 };

    fn peek(it: *const Iterator) ?Peeked {
        const rest = it.bytes[it.index..];
        if (rest.len == 0 or rest[0] == 0x1b) return null;
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return null;
        if (len > rest.len) return null;
        const cp = std.unicode.utf8Decode(rest[0..len]) catch return null;
        return .{ .cp = cp, .len = len };
    }
};

fn isControl(props: Properties) bool {
    return switch (props.grapheme_break) {
        .cr, .lf, .control => true,
        else => false,
    };
}

const zwj = 0x200d;

/// The display width of `text`: the width of its widest line. Escape sequences take no
/// columns.
pub fn of(text: []const u8) usize {
    var widest: usize = 0;
    var current: usize = 0;
    var it: Iterator = .init(text);
    while (it.next()) |cluster| {
        if (cluster.bytes[0] == '\n') {
            current = 0;
            continue;
        }
        current += cluster.width;
        widest = @max(widest, current);
    }
    return widest;
}

/// Writes the single line `text`, cut to at most `max_width` columns with `tail` (such as
/// "…") marking the cut. Text that fits is written unchanged. Escape sequences after the
/// cut are still written, so a closing reset is not lost. When `tail` itself is wider than
/// `max_width`, the cut has no tail.
pub fn truncate(
    w: *Writer,
    text: []const u8,
    max_width: usize,
    tail: []const u8,
) Writer.Error!void {
    if (of(text) <= max_width) return w.writeAll(text);
    const tail_width = of(tail);
    const fits_tail = tail_width <= max_width;
    const budget = if (fits_tail) max_width - tail_width else max_width;
    var used: usize = 0;
    var done = false;
    var it: Iterator = .init(text);
    while (it.next()) |cluster| {
        if (cluster.escape) {
            try w.writeAll(cluster.bytes);
        } else if (!done and used + cluster.width <= budget) {
            try w.writeAll(cluster.bytes);
            used += cluster.width;
        } else if (!done) {
            done = true;
            if (fits_tail) try w.writeAll(tail);
        }
    }
}

/// One row of wrapped text: a slice of the line and its width.
pub const Row = struct {
    bytes: []const u8,
    width: usize,
};

/// Word-wraps one line (no `\n`) into rows of at most `limit` columns. Breaks at spaces,
/// dropping the spaces at a break; a word longer than a row is cut between clusters. A
/// cluster wider than `limit` gets a row of its own. Rows are slices of the line, so escape
/// sequences stay where they were.
pub const Wrapper = struct {
    line: []const u8,
    limit: usize,
    index: usize = 0,
    started: bool = false,

    /// Rows of `line` at most `limit` columns wide; `limit` must be positive.
    pub fn init(line: []const u8, limit: usize) Wrapper {
        assert(limit > 0);
        return .{ .line = line, .limit = limit };
    }

    /// The next row, or null after the last. An empty line yields one empty row.
    pub fn next(wr: *Wrapper) ?Row {
        if (wr.index >= wr.line.len) {
            if (wr.started) return null;
            wr.started = true;
            return .{ .bytes = wr.line[wr.index..], .width = 0 };
        }
        wr.started = true;
        const start = wr.index;
        var end = start;
        var width: usize = 0;
        while (true) {
            const spaces = run(wr.line, end, true);
            const word = run(wr.line, spaces.end, false);
            if (word.end == end) break;
            const added = spaces.width + word.width;
            if (width + added <= wr.limit) {
                end = word.end;
                width += added;
                continue;
            }
            if (end == start) return wr.cut(start);
            break;
        }
        wr.index = end;
        while (wr.index < wr.line.len and wr.line[wr.index] == ' ') wr.index += 1;
        return .{ .bytes = wr.line[start..end], .width = width };
    }

    /// A row of as many clusters from `start` as fit, at least one.
    fn cut(wr: *Wrapper, start: usize) Row {
        var it: Iterator = .{ .bytes = wr.line, .index = start };
        var end = start;
        var width: usize = 0;
        while (it.next()) |cluster| {
            if (width + cluster.width > wr.limit and end > start) break;
            end = it.index;
            width += cluster.width;
            if (width >= wr.limit) break;
        }
        // Escapes right after the cut belong to the text they introduce, on the next row.
        wr.index = end;
        return .{ .bytes = wr.line[start..end], .width = width };
    }

    const Run = struct { end: usize, width: usize };

    /// The run of spaces (or of anything else) starting at `from`.
    fn run(line: []const u8, from: usize, spaces: bool) Run {
        var it: Iterator = .{ .bytes = line, .index = from };
        var end = from;
        var width: usize = 0;
        while (it.next()) |cluster| {
            const is_space = cluster.bytes[0] == ' ';
            if (is_space != spaces) break;
            end = it.index;
            width += cluster.width;
        }
        return .{ .end = end, .width = width };
    }
};

/// Writes `text` word-wrapped to `limit` columns, keeping its own line breaks.
pub fn wrap(w: *Writer, text: []const u8, limit: usize) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        var wrapper: Wrapper = .init(line, limit);
        while (wrapper.next()) |row| {
            if (!first) try w.writeByte('\n');
            first = false;
            try w.writeAll(row.bytes);
        }
    }
}

/// Writes the single line `text` cut to its last `max_width` columns, with `head` (such as
/// "…") marking the cut at the start. Text that fits is written unchanged. Escape sequences
/// before the cut are still written, so the colors in effect carry over.
pub fn truncateLeft(
    w: *Writer,
    text: []const u8,
    max_width: usize,
    head: []const u8,
) Writer.Error!void {
    const total = of(text);
    if (total <= max_width) return w.writeAll(text);
    const head_width = of(head);
    const fits_head = head_width <= max_width;
    const budget = if (fits_head) max_width - head_width else max_width;
    // Skip clusters until what is left fits in the budget.
    var skip = total - budget;
    var wrote_head = false;
    var it: Iterator = .init(text);
    while (it.next()) |cluster| {
        if (cluster.escape) {
            try w.writeAll(cluster.bytes);
        } else if (skip > 0) {
            skip -|= cluster.width;
            // A wide cluster cut in half leaves a column, filled with a space.
            if (skip == 0 and cluster.width > 0) continue;
        } else {
            if (!wrote_head) {
                wrote_head = true;
                if (fits_head) try w.writeAll(head);
            }
            try w.writeAll(cluster.bytes);
        }
    }
    if (!wrote_head and fits_head) try w.writeAll(head);
}

/// Writes columns `start` up to `end` of the single line `text`, as x/ansi's `Cut`: the
/// part of a wide character the cut splits becomes a space. Every escape sequence is
/// written where it was, so the colors in effect at `start` still apply and a closing reset
/// is not lost.
pub fn cut(w: *Writer, text: []const u8, start: usize, end: usize) Writer.Error!void {
    var column: usize = 0;
    var it: Iterator = .init(text);
    while (it.next()) |cluster| {
        if (cluster.escape) {
            try w.writeAll(cluster.bytes);
            continue;
        }
        const left = column;
        const right = column + cluster.width;
        column = right;
        if (cluster.width == 0) {
            if (left >= start and left < end) try w.writeAll(cluster.bytes);
            continue;
        }
        if (left >= start and right <= end) {
            try w.writeAll(cluster.bytes);
        } else if (right > start and left < end) {
            // Straddling an edge: the columns inside become spaces.
            try w.splatByteAll(' ', @min(right, end) - @max(left, start));
        }
    }
}

/// The colors and hyperlink in effect at a point of styled text: what a line must reopen
/// to look the same on its own.
pub const Carry = struct {
    pen: Pen = .{},
    /// The open hyperlink's OSC 8 parameters and URL (`id=x;https://...`), or empty.
    link: [max_link]u8 = undefined,
    link_len: usize = 0,

    /// The longest hyperlink carried; longer ones are not reopened.
    pub const max_link = 512;

    /// Takes in the escape sequences of `bytes`.
    pub fn feed(carry: *Carry, bytes: []const u8) void {
        var parser: Parser = .{};
        parser.feed(bytes, carry);
    }

    /// For `Parser`.
    pub fn csi(carry: *Carry, seq: Parser.Csi) void {
        if (seq.final == 'm' and seq.private == 0 and seq.intermediates.len == 0) {
            carry.pen.apply(seq.params);
        }
    }

    /// For `Parser`.
    pub fn osc(carry: *Carry, data: []const u8) void {
        if (!std.mem.startsWith(u8, data, "8;")) return;
        const rest = data[2..];
        const url_at = std.mem.indexOfScalar(u8, rest, ';') orelse return;
        if (url_at + 1 == rest.len or rest.len > max_link) {
            carry.link_len = 0;
            return;
        }
        @memcpy(carry.link[0..rest.len], rest);
        carry.link_len = rest.len;
    }

    /// Writes what reopens this state on a fresh line.
    pub fn open(carry: *const Carry, w: *Writer) Writer.Error!void {
        try carry.pen.write(w, .truecolor);
        if (carry.link_len > 0) {
            try w.print(ansi.osc ++ "8;{s}" ++ ansi.st, .{carry.link[0..carry.link_len]});
        }
    }

    /// Writes what closes this state at the end of a line.
    pub fn close(carry: *const Carry, w: *Writer) Writer.Error!void {
        if (carry.link_len > 0) try w.writeAll(ansi.osc ++ "8;;" ++ ansi.st);
        if (!carry.pen.eql(.{})) try w.writeAll(ansi.reset);
    }
};

/// `wrap`, with each row made whole: it reopens the colors and hyperlink in effect where
/// it starts and closes them where it ends, so rows can be placed apart (side by side,
/// in boxes) and still look as they did in one piece. A `limit` of null keeps the lines as
/// they are, only making each whole.
pub fn wrapStyled(w: *Writer, text: []const u8, limit: ?usize) Writer.Error!void {
    var carry: Carry = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        var wrapper: Wrapper = .init(line, limit orelse std.math.maxInt(usize));
        while (wrapper.next()) |row| {
            if (!first) try w.writeByte('\n');
            first = false;
            try carry.open(w);
            try w.writeAll(row.bytes);
            carry.feed(row.bytes);
            try carry.close(w);
        }
        // The spaces dropped at the breaks may hold escapes too; none are expected, but
        // the line's own escapes are already counted row by row.
    }
}

const testing = std.testing;

test "every case of Unicode's grapheme break test" {
    // Lines like `÷ 0061 × 0308 ÷ 0062 ÷  # comment`: codepoints in hex, with ÷ where a
    // cluster boundary is and × where there is none.
    const data = @embedFile("testdata/GraphemeBreakTest.txt");
    var lines = std.mem.splitScalar(u8, data, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        const body = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse
            line.len], " \t");
        if (body.len == 0) continue;
        var seg: Segmenter = .{};
        var tokens = std.mem.tokenizeAny(u8, body, " \t");
        var expect_break = false;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                expect_break = true;
            } else if (std.mem.eql(u8, token, "×")) {
                expect_break = false;
            } else {
                const cp = try std.fmt.parseInt(u21, token, 16);
                const got = seg.breaksBefore(properties(cp));
                if (got != expect_break) {
                    std.debug.print("break before {s} expected {}: {s}\n", .{
                        token, expect_break, line,
                    });
                    return error.TestUnexpectedResult;
                }
            }
        }
        cases += 1;
    }
    try testing.expect(cases > 700);
}

test "clusters follow the segmenter, controls aside" {
    try testing.expectEqual(1, countClusters("\u{915}\u{94d}\u{937}")); // क्ष, a conjunct
    try testing.expectEqual(1, countClusters("\u{600}a")); // a prepended mark
    try testing.expectEqual(2, countClusters("\r\n")); // two controls
    try testing.expectEqual(1, of("\u{915}\u{94d}\u{937}"));
}

test ofCodepoint {
    try testing.expectEqual(1, ofCodepoint('a'));
    try testing.expectEqual(0, ofCodepoint(0));
    try testing.expectEqual(0, ofCodepoint('\t'));
    try testing.expectEqual(0, ofCodepoint(0x7f));
    try testing.expectEqual(0, ofCodepoint(0x9b));
    try testing.expectEqual(1, ofCodepoint(0xe9)); // é
    try testing.expectEqual(0, ofCodepoint(0x301)); // combining acute
    try testing.expectEqual(0, ofCodepoint(0x200b)); // zero-width space
    try testing.expectEqual(0, ofCodepoint(zwj));
    try testing.expectEqual(0, ofCodepoint(0xfe0f));
    try testing.expectEqual(2, ofCodepoint(0x4e2d)); // 中
    try testing.expectEqual(2, ofCodepoint(0xac00)); // 가
    try testing.expectEqual(2, ofCodepoint(0xff21)); // Ａ fullwidth
    try testing.expectEqual(1, ofCodepoint(0xff61)); // ｡ halfwidth
    try testing.expectEqual(2, ofCodepoint(0x1f600)); // 😀
    try testing.expectEqual(2, ofCodepoint(0x231a)); // ⌚
    try testing.expectEqual(1, ofCodepoint(0x2764)); // ❤ (text presentation by default)
    try testing.expectEqual(1, ofCodepoint(0x2500)); // ─
    try testing.expectEqual(1, ofCodepoint(0x2026)); // … (ambiguous: narrow)
    try testing.expectEqual(2, ofCodepoint(0x20000));
    try testing.expectEqual(0, ofCodepoint(0xe0100));
    try testing.expectEqual(1, ofCodepoint(0xad)); // soft hyphen
    try testing.expectEqual(1, ofCodepoint(0x1f1f5)); // a lone regional indicator
    try testing.expectEqual(2, ofCodepoint(0x3fffd)); // unassigned, in a wide block
}

test "of: plain, wide, combining, and escaped text" {
    try testing.expectEqual(0, of(""));
    try testing.expectEqual(5, of("hello"));
    try testing.expectEqual(4, of("中文"));
    try testing.expectEqual(4, of("cafe\u{301}"));
    try testing.expectEqual(5, of("\x1b[1;31mhello\x1b[0m"));
    try testing.expectEqual(4, of("\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\"));
    try testing.expectEqual(5, of("ab\ncdefg\nh"));
    try testing.expectEqual(3, of("a\xffb")); // invalid byte: one column
    try testing.expectEqual(2, of("\xe4\xb8")); // truncated sequence: a column per byte
}

test "of: emoji sequences" {
    try testing.expectEqual(2, of("😀"));
    try testing.expectEqual(2, of("❤️")); // VS16 widens
    try testing.expectEqual(1, of("❤︎")); // VS15 keeps text presentation
    try testing.expectEqual(2, of("👍🏽")); // skin tone joins
    try testing.expectEqual(2, of("👨‍👩‍👧")); // ZWJ family
    try testing.expectEqual(2, of("🏳️‍🌈")); // flag via VS16 and ZWJ
    try testing.expectEqual(2, of("🇵🇹")); // regional indicator pair
    try testing.expectEqual(3, of("🇵🇹🇧")); // a lone indicator is narrow
    try testing.expectEqual(2, of("🏽")); // a lone modifier is a wide emoji
    try testing.expectEqual(2, of("한")); // precomposed Hangul
    try testing.expectEqual(2, of("\u{1100}\u{1161}\u{11a8}")); // conjoining jamo
    try testing.expectEqual(1, of("a\u{200d}")); // a trailing joiner joins nothing
}

test "Iterator: cluster boundaries" {
    var it: Iterator = .init("e\u{301}\x1b[0m中\n👨‍👩‍👧x");
    const expected = [_]struct { []const u8, u2, bool }{
        .{ "e\u{301}", 1, false },
        .{ "\x1b[0m", 0, true },
        .{ "中", 2, false },
        .{ "\n", 0, false },
        .{ "👨‍👩‍👧", 2, false },
        .{ "x", 1, false },
    };
    for (expected) |e| {
        const cluster = it.next().?;
        try testing.expectEqualStrings(e[0], cluster.bytes);
        try testing.expectEqual(e[1], cluster.width);
        try testing.expectEqual(e[2], cluster.escape);
    }
    try testing.expectEqual(null, it.next());
}

test "Iterator: a ZWJ before a control does not swallow it" {
    var it: Iterator = .init("a\u{200d}\nb");
    try testing.expectEqualStrings("a\u{200d}", it.next().?.bytes);
    try testing.expectEqualStrings("\n", it.next().?.bytes);
    try testing.expectEqualStrings("b", it.next().?.bytes);
}

fn expectTruncate(expected: []const u8, text: []const u8, max: usize, tail: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try truncate(&w, text, max, tail);
    try testing.expectEqualStrings(expected, w.buffered());
}

test truncate {
    try expectTruncate("hello", "hello", 5, "…");
    try expectTruncate("hell…", "hello world", 5, "…");
    try expectTruncate("hello", "hello world", 5, "");
    try expectTruncate("he...", "hello world", 5, "...");
    try expectTruncate("he", "hello", 2, "...");
    try expectTruncate("…", "hello", 1, "…");
    try expectTruncate("", "hello", 0, "…");
    // A wide character never straddles the cut.
    try expectTruncate("中…", "中文字", 4, "…");
    try expectTruncate("中 …", "中 文字", 4, "…");
    // Escapes after the cut are kept, so the reset still arrives.
    try expectTruncate("\x1b[1mhel…\x1b[0m", "\x1b[1mhello\x1b[0m", 4, "…");
    try expectTruncate("👨‍👩‍👧…", "👨‍👩‍👧👨‍👩‍👧", 3, "…");
}

fn expectCut(expected: []const u8, text: []const u8, start: usize, end: usize) !void {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try cut(&w, text, start, end);
    try testing.expectEqualStrings(expected, w.buffered());
}

test cut {
    try expectCut("llo w", "hello world", 2, 7);
    try expectCut("", "hello", 5, 9);
    try expectCut("hello", "hello", 0, 99);
    try expectCut(" 文", "中文字", 1, 4); // half of 中 is a space
    try expectCut("文 ", "中文字", 2, 5);
    try expectCut("\x1b[1mel\x1b[0m", "\x1b[1mhello\x1b[0m", 1, 3);
    try expectCut("e\u{301}", "ae\u{301}b", 1, 2);
}

fn expectTruncateLeft(expected: []const u8, text: []const u8, max: usize, head: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try truncateLeft(&w, text, max, head);
    try testing.expectEqualStrings(expected, w.buffered());
}

test truncateLeft {
    try expectTruncateLeft("hello", "hello", 5, "…");
    try expectTruncateLeft("…orld", "hello world", 5, "…");
    try expectTruncateLeft("world", "hello world", 5, "");
    try expectTruncateLeft("…字", "中文字", 3, "…");
    try expectTruncateLeft("\x1b[1m…llo\x1b[0m", "\x1b[1mhello\x1b[0m", 4, "…");
    try expectTruncateLeft("…", "hello", 1, "…");
}

test wrapStyled {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try wrapStyled(&w, "\x1b[1;31mred bold\x1b[0m plain", 4);
    try testing.expectEqualStrings(
        "\x1b[1;31mred\x1b[0m\n\x1b[1;31mbold\x1b[0m\nplai\nn",
        w.buffered(),
    );
    w = .fixed(&buffer);
    try wrapStyled(&w, "\x1b]8;;http://x\x1b\\a b\x1b]8;;\x1b\\", 1);
    try testing.expectEqualStrings(
        "\x1b]8;;http://x\x1b\\a\x1b]8;;\x1b\\\n\x1b]8;;http://x\x1b\\b\x1b]8;;\x1b\\",
        w.buffered(),
    );
    w = .fixed(&buffer);
    try wrapStyled(&w, "\x1b[32mone\ntwo\x1b[0m", null);
    try testing.expectEqualStrings("\x1b[32mone\x1b[0m\n\x1b[32mtwo\x1b[0m", w.buffered());
}

fn expectWrap(expected: []const u8, text: []const u8, limit: usize) !void {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try wrap(&w, text, limit);
    try testing.expectEqualStrings(expected, w.buffered());
}

test wrap {
    try expectWrap("the quick\nbrown fox", "the quick brown fox", 10);
    try expectWrap("the quick brown fox", "the quick brown fox", 19);
    try expectWrap("the\nquick\nbrown\nfox", "the quick brown fox", 5);
    try expectWrap("abcde\nfghij\nk", "abcdefghijk", 5);
    try expectWrap("a\nbcdef\ngh", "a bcdefgh", 5);
    try expectWrap("one\n\ntwo", "one\n\ntwo", 10);
    try expectWrap("", "", 10);
    try expectWrap("  indented\ntext", "  indented text", 10);
    // Spaces at a break vanish; runs of spaces inside a row stay.
    try expectWrap("a  b\nc", "a  b    c", 4);
    // Wide characters: never split, and one wider than the row gets a row of its own.
    try expectWrap("中文\n字", "中文字", 5);
    try expectWrap("中\n文", "中文", 1);
    // Escapes travel with their text and take no room.
    try expectWrap("\x1b[1mbold\x1b[0m\nplain", "\x1b[1mbold\x1b[0m plain", 6);
}

test "Wrapper: rows carry their widths" {
    var wrapper: Wrapper = .init("hello 世界 again", 8);
    const rows = [_]struct { []const u8, usize }{
        .{ "hello", 5 },
        .{ "世界", 4 },
        .{ "again", 5 },
    };
    for (rows) |expected| {
        const row = wrapper.next().?;
        try testing.expectEqualStrings(expected[0], row.bytes);
        try testing.expectEqual(expected[1], row.width);
    }
    try testing.expectEqual(null, wrapper.next());
}

test "Wrapper: every row fits and nothing is lost but break spaces" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    const alphabet = [_][]const u8{ "a", "b", " ", "中", "é", "😀", "  ", "\x1b[1m" };
    for (0..500) |_| {
        var text_buffer: [128]u8 = undefined;
        var text: Writer = .fixed(&text_buffer);
        for (0..random.uintLessThan(usize, 24)) |_| {
            text.writeAll(alphabet[random.uintLessThan(usize, alphabet.len)]) catch break;
        }
        const limit = random.intRangeAtMost(usize, 1, 12);
        var wrapper: Wrapper = .init(text.buffered(), limit);
        var non_space: usize = 0;
        var rows: usize = 0;
        while (wrapper.next()) |row| : (rows += 1) {
            try testing.expectEqual(of(row.bytes), row.width);
            if (row.width > limit) try testing.expectEqual(1, countClusters(row.bytes));
            non_space += countNonSpace(row.bytes);
            try testing.expect(rows <= text.end + 1);
        }
        try testing.expectEqual(countNonSpace(text.buffered()), non_space);
    }
}

fn countClusters(text: []const u8) usize {
    var it: Iterator = .init(text);
    var n: usize = 0;
    while (it.next()) |c| n += @intFromBool(!c.escape);
    return n;
}

fn countNonSpace(text: []const u8) usize {
    return text.len - std.mem.count(u8, text, " ");
}
