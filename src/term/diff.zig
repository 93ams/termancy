//! Line diffs in the unified format of `diff -u`, from Myers' O(ND) algorithm: `unified`
//! writes one, colored or not; `editScript` gives the steps for other presentations.
//!
//! ```zig
//! const changed = try term.diff.unified(arena, w, "old", old, "new", new, .{ .color = true });
//! ```
//!
//! Lines keep their terminating `\n`, so a last line without one differs from the same text
//! with one, and prints followed by `\ No newline at end of file`, as diff(1) does.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Lines of context around each change, as `diff -u` uses.
pub const default_context = 3;

/// How `write` shows a diff.
pub const Options = struct {
    /// Lines of unchanged text around each change.
    context: usize = default_context,
    /// Color the lines as `git diff` does: removed red, added green, hunk headers cyan,
    /// file names bold. Off, plain text, as a pipe or a patch wants.
    color: bool = false,
};

const red = "\x1b[31m";
const green = "\x1b[32m";
const cyan = "\x1b[36m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

/// Splits `text` into lines, each with its `\n` except perhaps the last. Empty text has no
/// lines.
pub fn splitLines(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| nl + 1 else text.len;
        try lines.append(arena, text[start..end]);
        start = end;
    }
    return lines.items;
}

/// What one step of an edit script does.
pub const Kind = enum { equal, delete, insert };

/// One step of an edit script: `a` and `b` are the line indices before the step.
pub const Op = struct { kind: Kind, a: usize, b: usize };

/// The shortest edit script turning `a` into `b`, deletions before insertions within each
/// change.
pub fn editScript(
    arena: Allocator,
    a: []const []const u8,
    b: []const []const u8,
) Allocator.Error![]const Op {
    const trace = try forward(arena, a, b);
    return backtrack(arena, trace, a.len, b.len);
}

/// A snapshot of Myers' `V` before round `d`, covering diagonals `-d - 1 ... d + 1`.
const Round = []const isize;

fn at(round: Round, d: isize, k: isize) isize {
    return round[@intCast(k + d + 1)];
}

/// Whether the path to diagonal `k` in round `d` comes down from `k + 1` (an insertion)
/// rather than across from `k - 1` (a deletion).
fn goesDown(round: Round, d: isize, k: isize) bool {
    return k == -d or (k != d and at(round, d, k - 1) < at(round, d, k + 1));
}

/// Runs the greedy forward search, recording `V` before each round, until the end is
/// reached.
fn forward(
    arena: Allocator,
    a: []const []const u8,
    b: []const []const u8,
) Allocator.Error![]const Round {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const max = n + m;
    // `v[k + max + 1]` is the furthest x reached on diagonal `k`.
    const v = try arena.alloc(isize, @intCast(2 * max + 3));
    @memset(v, 0);
    var trace: std.ArrayList(Round) = .empty;
    var d: isize = 0;
    while (d <= max) : (d += 1) {
        const window = v[@intCast(max - d)..][0..@intCast(2 * d + 3)];
        const round = try arena.dupe(isize, window);
        try trace.append(arena, round);
        var k = -d;
        while (k <= d) : (k += 2) {
            var x = if (goesDown(round, d, k)) at(round, d, k + 1) else at(round, d, k - 1) + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            window[@intCast(k + d + 1)] = x;
            if (x >= n and y >= m) return trace.items;
        }
    }
    unreachable; // Round `n + m` always reaches the end.
}

fn backtrack(
    arena: Allocator,
    trace: []const Round,
    n: usize,
    m: usize,
) Allocator.Error![]const Op {
    var ops: std.ArrayList(Op) = .empty;
    var x: isize = @intCast(n);
    var y: isize = @intCast(m);
    var d: isize = @intCast(trace.len - 1);
    while (d >= 0) : (d -= 1) {
        const round = trace[@intCast(d)];
        const k = x - y;
        const prev_k = if (goesDown(round, d, k)) k + 1 else k - 1;
        const prev_x = at(round, d, prev_k);
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try ops.append(arena, .{ .kind = .equal, .a = @intCast(x), .b = @intCast(y) });
        }
        if (d == 0) break;
        if (x == prev_x) {
            try ops.append(arena, .{ .kind = .insert, .a = @intCast(x), .b = @intCast(prev_y) });
        } else {
            try ops.append(arena, .{ .kind = .delete, .a = @intCast(prev_x), .b = @intCast(y) });
        }
        x = prev_x;
        y = prev_y;
    }
    std.mem.reverse(Op, ops.items);
    return ops.items;
}

/// Writes the unified diff of `a` (named `a_name`) and `b` (named `b_name`). Writes
/// nothing and returns false when the texts are equal. All memory comes from `arena`.
pub fn unified(
    arena: Allocator,
    writer: *Writer,
    a_name: []const u8,
    a_text: []const u8,
    b_name: []const u8,
    b_text: []const u8,
    options: Options,
) (Allocator.Error || Writer.Error)!bool {
    if (std.mem.eql(u8, a_text, b_text)) return false;
    const a = try splitLines(arena, a_text);
    const b = try splitLines(arena, b_text);
    const ops = try editScript(arena, a, b);
    if (options.color) {
        try writer.print(bold ++ "--- {s}" ++ reset ++ "\n" ++ bold ++ "+++ {s}" ++ reset ++
            "\n", .{ a_name, b_name });
    } else {
        try writer.print("--- {s}\n+++ {s}\n", .{ a_name, b_name });
    }
    var start: usize = 0;
    while (nextHunk(ops, start, options.context)) |hunk| : (start = hunk.end) {
        try writeHunk(writer, ops[hunk.begin..hunk.end], a, b, options.color);
    }
    return true;
}

const Hunk = struct { begin: usize, end: usize };

/// The next hunk at or after `start`: a run of changes no more than `2 * context` equal
/// lines apart, with up to `context` equal lines on each side.
fn nextHunk(ops: []const Op, start: usize, context: usize) ?Hunk {
    var first = start;
    while (first < ops.len and ops[first].kind == .equal) first += 1;
    if (first == ops.len) return null;
    var last = first;
    var i = first + 1;
    while (i < ops.len) : (i += 1) {
        if (ops[i].kind == .equal) {
            if (i - last > 2 * context) break;
        } else {
            last = i;
        }
    }
    return .{
        .begin = @max(start, first -| context),
        .end = @min(ops.len, last + 1 + context),
    };
}

fn writeHunk(
    writer: *Writer,
    ops: []const Op,
    a: []const []const u8,
    b: []const []const u8,
    color: bool,
) Writer.Error!void {
    assert(ops.len > 0);
    var a_count: usize = 0;
    var b_count: usize = 0;
    for (ops) |op| {
        if (op.kind != .insert) a_count += 1;
        if (op.kind != .delete) b_count += 1;
    }
    if (color) try writer.writeAll(cyan);
    try writer.writeAll("@@ -");
    try writeRange(writer, ops[0].a, a_count);
    try writer.writeAll(" +");
    try writeRange(writer, ops[0].b, b_count);
    try writer.writeAll(" @@");
    if (color) try writer.writeAll(reset);
    try writer.writeByte('\n');
    for (ops) |op| {
        const prefix: u8, const line, const sgr = switch (op.kind) {
            .equal => .{ ' ', a[op.a], "" },
            .delete => .{ '-', a[op.a], red },
            .insert => .{ '+', b[op.b], green },
        };
        const text = std.mem.trimEnd(u8, line, "\n");
        if (color and sgr.len > 0) {
            try writer.print("{s}{c}{s}" ++ reset, .{ sgr, prefix, text });
        } else {
            try writer.print("{c}{s}", .{ prefix, text });
        }
        try writer.writeByte('\n');
        if (text.len == line.len) try writer.writeAll("\\ No newline at end of file\n");
    }
}

/// `start,count` as `diff -u` writes it: 1-based, the count left out when it is 1, and an
/// empty range numbered by the line before it.
fn writeRange(writer: *Writer, start: usize, count: usize) Writer.Error!void {
    switch (count) {
        0 => try writer.print("{d},0", .{start}),
        1 => try writer.print("{d}", .{start + 1}),
        else => try writer.print("{d},{d}", .{ start + 1, count }),
    }
}

const testing = std.testing;

fn expectDiff(a: []const u8, b: []const u8, expected: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var out: Writer.Allocating = .init(arena_state.allocator());
    const different = try unified(arena_state.allocator(), &out.writer, "a", a, "b", b, .{});
    try testing.expectEqual(expected != null, different);
    try testing.expectEqualStrings(expected orelse "", out.written());
}

test splitLines {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(0, (try splitLines(arena, "")).len);
    const lines = try splitLines(arena, "a\n\nb");
    try testing.expectEqual(3, lines.len);
    try testing.expectEqualStrings("\n", lines[1]);
    try testing.expectEqualStrings("b", lines[2]);
}

test "identical texts have no diff" {
    try expectDiff("", "", null);
    try expectDiff("a\nb\n", "a\nb\n", null);
}

test "empty files" {
    try expectDiff("", "x\ny\n", "--- a\n+++ b\n@@ -0,0 +1,2 @@\n+x\n+y\n");
    try expectDiff("x\n", "", "--- a\n+++ b\n@@ -1 +0,0 @@\n-x\n");
}

test "no newline at end of file" {
    try expectDiff("a\nb", "a\nb\n",
        \\--- a
        \\+++ b
        \\@@ -1,2 +1,2 @@
        \\ a
        \\-b
        \\\ No newline at end of file
        \\+b
        \\
    );
}

test "a change in the middle, with context" {
    try expectDiff("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\n2\n3\n4\nfive\n6\n7\n8\n9\n",
        \\--- a
        \\+++ b
        \\@@ -2,7 +2,7 @@
        \\ 2
        \\ 3
        \\ 4
        \\-5
        \\+five
        \\ 6
        \\ 7
        \\ 8
        \\
    );
}

test "distant changes make two hunks, near ones one" {
    const a = "a\n1\n2\n3\n4\n5\n6\n7\n8\nb\n";
    try expectDiff(a, "A\n1\n2\n3\n4\n5\n6\n7\n8\nB\n",
        \\--- a
        \\+++ b
        \\@@ -1,4 +1,4 @@
        \\-a
        \\+A
        \\ 1
        \\ 2
        \\ 3
        \\@@ -7,4 +7,4 @@
        \\ 6
        \\ 7
        \\ 8
        \\-b
        \\+B
        \\
    );
    try expectDiff("a\n1\n2\n3\n4\n5\n6\nb\n", "A\n1\n2\n3\n4\n5\n6\nB\n",
        \\--- a
        \\+++ b
        \\@@ -1,8 +1,8 @@
        \\-a
        \\+A
        \\ 1
        \\ 2
        \\ 3
        \\ 4
        \\ 5
        \\ 6
        \\-b
        \\+B
        \\
    );
}

test "colored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var out: Writer.Allocating = .init(arena_state.allocator());
    const options: Options = .{ .color = true, .context = 1 };
    _ = try unified(arena_state.allocator(), &out.writer, "a", "x\ny\n", "b", "x\nz", options);
    try testing.expectEqualStrings("\x1b[1m--- a\x1b[0m\n\x1b[1m+++ b\x1b[0m\n" ++
        "\x1b[36m@@ -1,2 +1,2 @@\x1b[0m\n x\n\x1b[31m-y\x1b[0m\n" ++
        "\x1b[32m+z\x1b[0m\n\\ No newline at end of file\n", out.written());
}

test "editScript is minimal and replays to b" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The classic example from Myers' paper: ABCABBA to CBABAC takes 5 edits.
    const a = try splitLines(arena, "A\nB\nC\nA\nB\nB\nA\n");
    const b = try splitLines(arena, "C\nB\nA\nB\nA\nC\n");
    const ops = try editScript(arena, a, b);
    var edits: usize = 0;
    var replay: std.ArrayList([]const u8) = .empty;
    for (ops) |op| switch (op.kind) {
        .equal => try replay.append(arena, a[op.a]),
        .insert => {
            edits += 1;
            try replay.append(arena, b[op.b]);
        },
        .delete => edits += 1,
    };
    try testing.expectEqual(5, edits);
    try testing.expectEqual(b.len, replay.items.len);
    for (b, replay.items) |want, got| try testing.expectEqualStrings(want, got);
}
