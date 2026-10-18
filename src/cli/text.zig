//! Small text utilities: edit distance and "did you mean" suggestions, and reading user
//! aliases from a configuration file.

const std = @import("std");
const assert = std.debug.assert;

/// Names longer than this are never compared; suggestions are for typos, not essays.
pub const max_name_len = 64;

/// Edit distance between `a` and `b`, counting an insertion, a deletion, a substitution,
/// or a swap of two adjacent bytes as one edit (optimal string alignment), or `null` when
/// either is longer than `max_name_len`. Swaps count once because `gte` for `get` is the
/// most common typo of all.
pub fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (a.len > max_name_len or b.len > max_name_len) return null;
    const width = b.len + 1;
    var rows: [3][max_name_len + 1]usize = undefined;
    for (0..width) |j| rows[1][j] = j;
    for (a, 0..) |ca, i| {
        const before = &rows[(i + 0) % 3]; // row i - 1
        const previous = &rows[(i + 1) % 3]; // row i
        const current = &rows[(i + 2) % 3]; // row i + 1
        current[0] = i + 1;
        for (b, 0..) |cb, j| {
            const substitution = previous[j] + @intFromBool(ca != cb);
            var best = @min(substitution, previous[j + 1] + 1, current[j] + 1);
            if (i > 0 and j > 0 and ca == b[j - 1] and a[i - 1] == cb) {
                best = @min(best, before[j - 1] + 1);
            }
            current[j + 1] = best;
        }
    }
    return rows[(a.len + 1) % 3][b.len];
}

/// The candidate closest to `input`, if any is close enough to be a plausible typo: within
/// an edit distance of a third of the input's length (at least 1, at most 3), or having
/// `input` as a prefix. Ties go to the earliest candidate.
pub fn suggest(input: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    const limit = std.math.clamp(input.len / 3, 1, 3);
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        if (candidate.len > input.len and std.mem.startsWith(u8, candidate, input)) {
            if (best_distance > 0) {
                best = candidate;
                best_distance = 0;
            }
            continue;
        }
        const distance = editDistance(input, candidate) orelse continue;
        if (distance <= limit and distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

/// `dry_run` -> `dry-run`, at compile time.
pub fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = if (c == '_') '-' else c;
        const final = out;
        return &final;
    }
}

/// The `[alias]` section of an INI-style file, as git keeps `alias.<name>`, in the shape
/// `App.aliases` takes: `co = checkout -b` becomes `.{ "co", "checkout -b" }`. Names and
/// expansions are trimmed, and a value quoted whole (`"..."` or `'...'`) loses its quotes;
/// lines starting with `#` or `;`, blank lines, lines without `=`, and every other section
/// are skipped. Section names ignore case. The result points into `content` and `arena`.
pub fn aliasesFromIni(
    arena: std.mem.Allocator,
    content: []const u8,
) std.mem.Allocator.Error![]const [2][]const u8 {
    var found: std.ArrayList([2][]const u8) = .empty;
    var in_alias = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
            const section = std.mem.trim(u8, line[1..end], " \t");
            in_alias = std.ascii.eqlIgnoreCase(section, "alias");
            continue;
        }
        if (!in_alias) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and
            value[value.len - 1] == value[0])
        {
            value = value[1 .. value.len - 1];
        }
        if (name.len == 0) continue;
        try found.append(arena, .{ name, value });
    }
    return found.items;
}

const testing = std.testing;

test aliasesFromIni {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aliases = try aliasesFromIni(arena.allocator(),
        \\# a comment
        \\co = ignored, not in a section
        \\[core]
        \\editor = vim
        \\[ Alias ]
        \\co = checkout -b
        \\  ; another comment
        \\st="status --short"
        \\lg = 'log --oneline'
        \\half = "quoted at one end
        \\no equals sign
        \\ = nameless
        \\[other]
        \\x = y
        \\
    );
    try testing.expectEqual(4, aliases.len);
    try testing.expectEqualStrings("co", aliases[0][0]);
    try testing.expectEqualStrings("checkout -b", aliases[0][1]);
    try testing.expectEqualStrings("st", aliases[1][0]);
    try testing.expectEqualStrings("status --short", aliases[1][1]);
    try testing.expectEqualStrings("log --oneline", aliases[2][1]);
    try testing.expectEqualStrings("\"quoted at one end", aliases[3][1]);
    try testing.expectEqual(0, (try aliasesFromIni(arena.allocator(), "")).len);
}

test editDistance {
    try testing.expectEqual(0, editDistance("get", "get").?);
    try testing.expectEqual(1, editDistance("gte", "get").?);
    try testing.expectEqual(3, editDistance("", "abc").?);
    try testing.expectEqual(1, editDistance("port", "prot").?);
    try testing.expectEqual(3, editDistance("kitten", "sitting").?);
    try testing.expectEqual(null, editDistance(&@as([65]u8, @splat('a')), "a"));
}

test suggest {
    const commands = [_][]const u8{ "get", "set", "keys", "explain", "convert" };
    try testing.expectEqualStrings("get", suggest("gt", &commands).?);
    try testing.expectEqualStrings("get", suggest("gte", &commands).?);
    try testing.expectEqualStrings("explain", suggest("expl", &commands).?);
    try testing.expectEqualStrings("convert", suggest("convret", &commands).?);
    try testing.expectEqual(null, suggest("zzzzzz", &commands));
    try testing.expectEqual(null, suggest("", &commands));
}

test kebab {
    try testing.expectEqualStrings("dry-run", comptime kebab("dry_run"));
}

test "suggest: prefixes win, ties go to the first, the limit grows with the input" {
    try testing.expectEqualStrings("status", suggest("stat", &.{ "start", "status" }).?);
    try testing.expectEqualStrings("serve", suggest("serv", &.{ "serve", "server" }).?);
    try testing.expectEqualStrings("cat", suggest("bat", &.{ "cat", "hat" }).?);
    try testing.expectEqualStrings("get", suggest("get", &.{ "get", "getter" }).?);
    // Three edits are allowed from nine bytes of input, never more.
    try testing.expectEqualStrings("abcdefghi", suggest("xyzdefghi", &.{"abcdefghi"}).?);
    try testing.expectEqual(null, suggest("wxyzefghijkl", &.{"abcdefghijkl"}));
    try testing.expectEqual(null, suggest("ab", &.{"xy"}));
    const long: [max_name_len + 1]u8 = @splat('a');
    try testing.expectEqual(null, suggest(&long, &.{"aaa"}));
}

test "editDistance: swaps, empty strings, and the length limit" {
    try testing.expectEqual(1, editDistance("ab", "ba").?);
    try testing.expectEqual(0, editDistance("", "").?);
    try testing.expectEqual(2, editDistance("ab", "").?);
    const exact: [max_name_len]u8 = @splat('a');
    try testing.expectEqual(0, editDistance(&exact, &exact).?);
    try testing.expectEqual(null, editDistance("a", &@as([max_name_len + 1]u8, @splat('a'))));
}
