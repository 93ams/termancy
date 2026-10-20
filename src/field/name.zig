//! Names: spelling field names on a command line, comparing them, and "did you mean".

const std = @import("std");

/// Names longer than this are never compared; suggestions are for typos, not essays.
pub const max_name_len = 64;

/// `dry_run` as typed on a command line: `dry-run`. At compile time.
pub fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = if (c == '_') '-' else c;
        const final = out;
        return &final;
    }
}

/// Whether two names are the same, ignoring ASCII case and treating `-` and `_` alike, so
/// `dry-run`, `dry_run`, and `DRY_RUN` name one thing.
pub fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (fold(x) != fold(y)) return false;
    return true;
}

fn fold(c: u8) u8 {
    return if (c == '-') '_' else std.ascii.toLower(c);
}

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

/// `items` joined by `separator`, at compile time.
pub fn join(comptime items: []const []const u8, comptime separator: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (items, 0..) |item, i| out = out ++ (if (i == 0) "" else separator) ++ item;
        return out;
    }
}

const testing = std.testing;

test editDistance {
    try testing.expectEqual(1, editDistance("gte", "get"));
    try testing.expectEqual(1, editDistance("regoin", "region"));
    try testing.expectEqual(3, editDistance("abc", ""));
    const long: [max_name_len + 1]u8 = @splat('a');
    try testing.expectEqual(null, editDistance(&long, "a"));
}

test suggest {
    try testing.expectEqualStrings("region", suggest("regoin", &.{ "port", "region" }).?);
    try testing.expectEqualStrings("verbose", suggest("verb", &.{ "version", "verbose" }).?);
    try testing.expectEqual(null, suggest("x", &.{"region"}));
    try testing.expectEqual(null, suggest("", &.{"region"}));
}

test sameName {
    try testing.expect(sameName("dry-run", "DRY_RUN"));
    try testing.expect(!sameName("dry-run", "dryrun"));
}
