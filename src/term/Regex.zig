//! Regular expressions, small and dependable: for waiting until a screen shows something
//! (`termancy record`'s `Wait /pattern/`) and for matching lines in tests. A backtracking
//! matcher over a compiled program, with a step limit so a pathological pattern fails
//! instead of hanging.
//!
//! Syntax: literals and `\` escapes; `.`; classes `[a-z]`, `[^0-9]`, `\d \w \s \D \W \S`;
//! anchors `^ $ \b`; groups `( )` and `(?: )`; alternation `|`; quantifiers `* + ? {n}
//! {n,} {n,m}`, each greedy, or lazy with a `?` after. Matching is by byte; a `.` or a
//! negated class matches a whole UTF-8 sequence.
//!
//! ```zig
//! var re = try term.Regex.compile(gpa, "ready in [0-9]+ms");
//! defer re.deinit(gpa);
//! if (re.search(text)) |m| ...;
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const Regex = @This();

nodes: []Node,
root: u32,

/// What compiling a pattern can fail with.
pub const Error = error{InvalidPattern} || Allocator.Error;

const Node = union(enum) {
    /// A byte sequence.
    literal: []const u8,
    any,
    class: Class,
    start,
    end,
    word_boundary,
    /// One after another.
    sequence: []const u32,
    /// One of these.
    alternation: []const u32,
    repeat: struct { node: u32, min: u32, max: ?u32, lazy: bool },
};

const Class = struct {
    /// Bytes 0-127 matched, a bit each.
    ascii: [2]u64,
    negated: bool,
    /// Non-ASCII ranges (codepoints).
    ranges: []const [2]u21,
};

/// Compiles `pattern`; the pattern itself need not outlive the result.
pub fn compile(gpa: Allocator, pattern: []const u8) Error!Regex {
    var p: Parser = .{ .gpa = gpa, .src = pattern };
    errdefer p.free();
    const root = try p.alternation();
    if (p.at != pattern.len) return error.InvalidPattern;
    return .{ .nodes = try p.nodes.toOwnedSlice(gpa), .root = root };
}

/// Frees the compiled pattern.
pub fn deinit(re: *Regex, gpa: Allocator) void {
    for (re.nodes) |node| switch (node) {
        .literal => |l| gpa.free(l),
        .sequence, .alternation => |list| gpa.free(list),
        .class => |c| gpa.free(c.ranges),
        else => {},
    };
    gpa.free(re.nodes);
    re.* = undefined;
}

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    at: usize = 0,
    nodes: std.ArrayList(Node) = .empty,

    fn free(p: *Parser) void {
        for (p.nodes.items) |node| switch (node) {
            .literal => |l| p.gpa.free(l),
            .sequence, .alternation => |list| p.gpa.free(list),
            .class => |c| p.gpa.free(c.ranges),
            else => {},
        };
        p.nodes.deinit(p.gpa);
    }

    fn add(p: *Parser, node: Node) Error!u32 {
        try p.nodes.append(p.gpa, node);
        return @intCast(p.nodes.items.len - 1);
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.at < p.src.len) p.src[p.at] else null;
    }

    fn alternation(p: *Parser) Error!u32 {
        var branches: std.ArrayList(u32) = .empty;
        defer branches.deinit(p.gpa);
        try branches.append(p.gpa, try p.sequence());
        while (p.peek() == '|') {
            p.at += 1;
            try branches.append(p.gpa, try p.sequence());
        }
        if (branches.items.len == 1) return branches.items[0];
        return p.add(.{ .alternation = try p.gpa.dupe(u32, branches.items) });
    }

    fn sequence(p: *Parser) Error!u32 {
        var items: std.ArrayList(u32) = .empty;
        defer items.deinit(p.gpa);
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            const unit = try p.atom();
            try items.append(p.gpa, try p.quantified(unit));
        }
        return p.add(.{ .sequence = try p.gpa.dupe(u32, items.items) });
    }

    fn quantified(p: *Parser, unit: u32) Error!u32 {
        const c = p.peek() orelse return unit;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (c) {
            '*' => p.at += 1,
            '+' => {
                p.at += 1;
                min = 1;
            },
            '?' => {
                p.at += 1;
                max = 1;
            },
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, p.src, p.at, '}') orelse return unit;
                const body = p.src[p.at + 1 .. close];
                const comma = std.mem.indexOfScalar(u8, body, ',');
                min = std.fmt.parseInt(
                    u32,
                    body[0 .. comma orelse body.len],
                    10,
                ) catch return error.InvalidPattern;
                max = if (comma) |k|
                    (if (k + 1 == body.len) null else std.fmt.parseInt(
                        u32,
                        body[k + 1 ..],
                        10,
                    ) catch return error.InvalidPattern)
                else
                    min;
                if (max != null and max.? < min) return error.InvalidPattern;
                p.at = close + 1;
            },
            else => return unit,
        }
        const lazy = p.peek() == '?';
        if (lazy) p.at += 1;
        return p.add(.{ .repeat = .{ .node = unit, .min = min, .max = max, .lazy = lazy } });
    }

    fn atom(p: *Parser) Error!u32 {
        const c = p.src[p.at];
        p.at += 1;
        switch (c) {
            '.' => return p.add(.any),
            '^' => return p.add(.start),
            '$' => return p.add(.end),
            '(' => {
                if (std.mem.startsWith(u8, p.src[p.at..], "?:")) p.at += 2;
                const inner = try p.alternation();
                if (p.peek() != ')') return error.InvalidPattern;
                p.at += 1;
                return inner;
            },
            ')' => return error.InvalidPattern,
            '[' => return p.class(),
            '\\' => return p.escape(),
            '*', '+', '?' => return error.InvalidPattern,
            else => {
                // A whole UTF-8 sequence is one literal, so a quantifier applies to all of it.
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(p.at - 1 + len, p.src.len);
                const bytes = try p.gpa.dupe(u8, p.src[p.at - 1 .. end]);
                p.at = end;
                return p.add(.{ .literal = bytes });
            },
        }
    }

    fn escape(p: *Parser) Error!u32 {
        const c = p.peek() orelse return error.InvalidPattern;
        p.at += 1;
        if (classEscape(c)) |cls| return p.add(.{ .class = .{
            .ascii = cls.ascii,
            .negated = cls.negated,
            .ranges = try p.gpa.alloc([2]u21, 0),
        } });
        if (c == 'b') return p.add(.word_boundary);
        const byte: u8 = switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'e' => 0x1b,
            else => c,
        };
        return p.add(.{ .literal = try p.gpa.dupe(u8, &.{byte}) });
    }

    fn class(p: *Parser) Error!u32 {
        var ascii: [2]u64 = .{ 0, 0 };
        var ranges: std.ArrayList([2]u21) = .empty;
        defer ranges.deinit(p.gpa);
        const negated = p.peek() == '^';
        if (negated) p.at += 1;
        var first = true;
        while (true) {
            const c = p.peek() orelse return error.InvalidPattern;
            if (c == ']' and !first) {
                p.at += 1;
                break;
            }
            first = false;
            var low: u21 = undefined;
            if (c == '\\') {
                p.at += 1;
                const e = p.peek() orelse return error.InvalidPattern;
                p.at += 1;
                if (classEscape(e)) |cls| {
                    if (cls.negated) {
                        // A negated escape inside a class: everything ASCII it does not match.
                        ascii[0] |= ~cls.ascii[0];
                        ascii[1] |= ~cls.ascii[1];
                    } else {
                        ascii[0] |= cls.ascii[0];
                        ascii[1] |= cls.ascii[1];
                    }
                    continue;
                }
                low = switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    else => e,
                };
            } else {
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                if (p.at + len > p.src.len) return error.InvalidPattern;
                low = std.unicode.utf8Decode(p.src[p.at..][0..len]) catch c;
                p.at += len;
            }
            var high = low;
            if (p.peek() == '-' and p.at + 1 < p.src.len and p.src[p.at + 1] != ']') {
                p.at += 1;
                const h = p.src[p.at];
                const len = std.unicode.utf8ByteSequenceLength(h) catch 1;
                if (p.at + len > p.src.len) return error.InvalidPattern;
                high = std.unicode.utf8Decode(p.src[p.at..][0..len]) catch h;
                p.at += len;
                if (high < low) return error.InvalidPattern;
            }
            var cp = low;
            while (cp <= high and cp < 128) : (cp += 1) {
                ascii[cp / 64] |= @as(u64, 1) << @intCast(cp % 64);
            }
            if (high >= 128) try ranges.append(p.gpa, .{ @max(low, 128), high });
        }
        return p.add(.{ .class = .{
            .ascii = ascii,
            .negated = negated,
            .ranges = try p.gpa.dupe([2]u21, ranges.items),
        } });
    }
};

const Escaped = struct { ascii: [2]u64, negated: bool };

fn classEscape(c: u8) ?Escaped {
    var bits: [2]u64 = .{ 0, 0 };
    const set = struct {
        fn f(b: *[2]u64, low: u8, high: u8) void {
            var x = low;
            while (x <= high) : (x += 1) b[x / 64] |= @as(u64, 1) << @intCast(x % 64);
        }
    }.f;
    switch (std.ascii.toLower(c)) {
        'd' => set(&bits, '0', '9'),
        'w' => {
            set(&bits, '0', '9');
            set(&bits, 'a', 'z');
            set(&bits, 'A', 'Z');
            set(&bits, '_', '_');
        },
        's' => {
            set(&bits, ' ', ' ');
            set(&bits, '\t', '\r');
        },
        else => return null,
    }
    return .{ .ascii = bits, .negated = std.ascii.isUpper(c) };
}

/// A match: where it starts and ends in the text.
pub const Match = struct { start: usize, end: usize };

/// The leftmost match in `text`, or null.
pub fn search(re: *const Regex, text: []const u8) ?Match {
    return re.searchFrom(text, 0);
}

/// The leftmost match in `text` starting at `from` or later, or null. Anchors and `\b`
/// still see the text before `from`, so a later match in the same text is found as it
/// would be in one pass.
pub fn searchFrom(re: *const Regex, text: []const u8, from: usize) ?Match {
    var start: usize = from;
    while (start <= text.len) : (start += 1) {
        var m: Matcher = .{ .re = re, .text = text, .whole = false };
        const k: Continuation = .{ .what = .{ .node = re.root }, .next = null };
        if (m.run(&k, start)) |end| return .{ .start = start, .end = end };
        if (m.exhausted) return null;
        // Begin only at the start of a UTF-8 sequence.
        while (start + 1 < text.len and text[start + 1] & 0xc0 == 0x80) start += 1;
    }
    return null;
}

/// Whether `text` matches anywhere.
pub fn isMatch(re: *const Regex, text: []const u8) bool {
    return re.search(text) != null;
}

/// Whether the whole of `text` matches.
pub fn matchesWhole(re: *const Regex, text: []const u8) bool {
    var m: Matcher = .{ .re = re, .text = text, .whole = true };
    const k: Continuation = .{ .what = .{ .node = re.root }, .next = null };
    return m.run(&k, 0) != null;
}

/// What remains to be matched: a node, or another round of a repeat, then the rest.
const Continuation = struct {
    what: union(enum) {
        node: u32,
        repeat: struct { index: u32, count: u32, from: usize },
    },
    next: ?*const Continuation,
};

const Matcher = struct {
    re: *const Regex,
    text: []const u8,
    /// A match must end at the end of the text.
    whole: bool,
    steps: usize = 0,
    exhausted: bool = false,

    const step_limit = 1_000_000;

    /// Matches the continuation `k` from `at`; returns where the whole match ends.
    fn run(m: *Matcher, k: ?*const Continuation, at: usize) ?usize {
        m.steps += 1;
        if (m.steps > step_limit) m.exhausted = true;
        if (m.exhausted) return null;
        const cont = k orelse return if (!m.whole or at == m.text.len) at else null;
        switch (cont.what) {
            .node => |index| return m.node(index, cont.next, at),
            .repeat => |r| return m.repeat(r.index, r.count, r.from, cont.next, at),
        }
    }

    fn node(m: *Matcher, index: u32, next: ?*const Continuation, at: usize) ?usize {
        const text = m.text;
        switch (m.re.nodes[index]) {
            .literal => |lit| {
                if (!std.mem.startsWith(u8, text[at..], lit)) return null;
                return m.run(next, at + lit.len);
            },
            .any => {
                if (at >= text.len or text[at] == '\n') return null;
                return m.run(next, at + seqLen(text, at));
            },
            .class => |cls| {
                if (at >= text.len) return null;
                const len = seqLen(text, at);
                if (!classMatches(cls, text[at..][0..len])) return null;
                return m.run(next, at + len);
            },
            .start => return if (at == 0 or text[at - 1] == '\n') m.run(next, at) else null,
            .end => return if (at == text.len or text[at] == '\n') m.run(next, at) else null,
            .word_boundary => {
                const before = at > 0 and isWord(text[at - 1]);
                const after = at < text.len and isWord(text[at]);
                return if (before != after) m.run(next, at) else null;
            },
            .sequence => |items| {
                // The items chained as continuations on the stack, the last first.
                var chain: [64]Continuation = undefined;
                if (items.len > chain.len) return null;
                var after: ?*const Continuation = next;
                var i = items.len;
                while (i > 0) {
                    i -= 1;
                    chain[i] = .{ .what = .{ .node = items[i] }, .next = after };
                    after = &chain[i];
                }
                return m.run(after, at);
            },
            .alternation => |branches| {
                for (branches) |b| {
                    const kb: Continuation = .{ .what = .{ .node = b }, .next = next };
                    if (m.run(&kb, at)) |end| return end;
                    if (m.exhausted) return null;
                }
                return null;
            },
            .repeat => return m.repeat(index, 0, std.math.maxInt(usize), next, at),
        }
    }

    /// `count` rounds of the repeat `index` matched, the last ending at `at` (having
    /// started at `from`): another round, or what follows, in the order greed decides.
    fn repeat(
        m: *Matcher,
        index: u32,
        count: u32,
        from: usize,
        next: ?*const Continuation,
        at: usize,
    ) ?usize {
        const r = m.re.nodes[index].repeat;
        // A round that matched nothing ends the repeat: going round again would loop.
        if (count > 0 and at == from and count > r.min) return null;
        const can_stop = count >= r.min;
        const can_go = r.max == null or count < r.max.?;
        if (r.lazy and can_stop) {
            if (m.run(next, at)) |end| return end;
        }
        if (can_go) {
            const again: Continuation = .{
                .what = .{ .repeat = .{ .index = index, .count = count + 1, .from = at } },
                .next = next,
            };
            const round: Continuation = .{ .what = .{ .node = r.node }, .next = &again };
            if (m.run(&round, at)) |end| return end;
        }
        if (!r.lazy and can_stop) return m.run(next, at);
        return null;
    }
};

fn seqLen(text: []const u8, at: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
    return @min(len, text.len - at);
}

fn classMatches(cls: Class, bytes: []const u8) bool {
    // A sequence the text cuts short is shorter than its first byte says.
    const whole = bytes.len == (std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1);
    const cp: u21 = if (bytes.len == 1)
        bytes[0]
    else if (!whole)
        0xfffd
    else
        std.unicode.utf8Decode(bytes) catch 0xfffd;
    var hit = false;
    if (cp < 128) {
        hit = cls.ascii[cp / 64] & (@as(u64, 1) << @intCast(cp % 64)) != 0;
    } else {
        for (cls.ranges) |r| if (cp >= r[0] and cp <= r[1]) {
            hit = true;
        };
    }
    return hit != cls.negated;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;

fn expectSearch(pattern: []const u8, text: []const u8, expected: ?[]const u8) !void {
    var re = try compile(testing.allocator, pattern);
    defer re.deinit(testing.allocator);
    const got = re.search(text);
    if (expected) |e| {
        const m = got orelse {
            std.debug.print("/{s}/ did not match \"{s}\"\n", .{ pattern, text });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(e, text[m.start..m.end]);
    } else if (got) |m| {
        std.debug.print("/{s}/ matched \"{s}\" unexpectedly\n", .{ pattern, text[m.start..m.end] });
        return error.TestUnexpectedResult;
    }
}

test "literals, classes, anchors" {
    try expectSearch("abc", "xxabcxx", "abc");
    try expectSearch("a.c", "abc", "abc");
    try expectSearch("[0-9]+ms", "ready in 42ms!", "42ms");
    try expectSearch("\\d{2,3}", "a1234", "123");
    try expectSearch("^ready", "not ready", null);
    try expectSearch("^ready", "x\nready", "ready");
    try expectSearch("done$", "done\nmore", "done");
    try expectSearch("[^ ]+", "  word ", "word");
    try expectSearch("\\bcat\\b", "concat cat", "cat");
    try expectSearch("\\$ $", "prompt$ ", "$ ");
    try expectSearch("[ä-ü]+", "xäöüx", "äöü");
}

test "groups, alternation, quantifiers" {
    try expectSearch("(ab)+", "xababab", "ababab");
    try expectSearch("colou?r", "the color", "color");
    try expectSearch("(cat|dog)s", "dogs", "dogs");
    try expectSearch("a(b|c)*d", "abcbcd", "abcbcd");
    try expectSearch("<.+>", "<a><b>", "<a><b>");
    try expectSearch("<.+?>", "<a><b>", "<a>");
    try expectSearch("x{3}", "xxxx", "xxx");
    try expectSearch("(?:ab){2,}", "abababx", "ababab");
    try expectSearch("(a|ab)(c|bcd)", "abcd", "abcd");
}

test searchFrom {
    var re = try compile(testing.allocator, "\\bab");
    defer re.deinit(testing.allocator);
    // From inside "xab", the boundary before "ab" is still not one.
    try testing.expectEqual(Match{ .start = 5, .end = 7 }, re.searchFrom("xab, ab", 1).?);
    try testing.expectEqual(null, re.searchFrom("xab, ab", 6));
}

test matchesWhole {
    var re = try compile(testing.allocator, "[a-z]+(-[a-z]+)*");
    defer re.deinit(testing.allocator);
    try testing.expect(re.matchesWhole("termancy-record"));
    try testing.expect(!re.matchesWhole("termancy-"));
    try testing.expect(!re.matchesWhole("termancy cli"));
}

test "bad patterns, and a pathological one ends" {
    for ([_][]const u8{ "(", "a)", "[a", "*a", "x{3,1}", "\\" }) |bad| {
        try testing.expectError(error.InvalidPattern, compile(testing.allocator, bad));
    }
    var re = try compile(testing.allocator, "(a*)*b");
    defer re.deinit(testing.allocator);
    try testing.expect(re.search("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == null);
}
