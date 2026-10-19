//! Small text utilities: edit distance and "did you mean" suggestions, and reading user
//! aliases from a configuration file.

const std = @import("std");
const assert = std.debug.assert;

const field = @import("field");

/// Names longer than this are never compared; suggestions are for typos, not essays.
pub const max_name_len = field.max_name_len;

/// Edit distance; see `field.editDistance`.
pub const editDistance = field.editDistance;

/// The candidate closest to `input`, if any is close enough to be a plausible typo; see
/// `field.suggest`.
pub const suggest = field.suggest;

/// `dry_run` -> `dry-run`, at compile time.
pub const kebab = field.kebab;

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
