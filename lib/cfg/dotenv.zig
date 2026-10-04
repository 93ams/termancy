//! `.env` parsing: reading a file of `KEY=value` lines, with variable expansion.
//!
//! ## What was missing
//!
//! `[measured]` the tree had **no `.env` reader at all**. Every environment path
//! went through `std.process.Environ.Map`, and `.env` appeared only as an *export
//! target* - `writeDotEnv` and the `dotenv` output format. So a program could write
//! a `.env` it could not read back, and "recursive parsing with variable
//! expansion" had nothing to be recursive about.
//!
//! ## The grammar, and where it comes from
//!
//! There is no specification for `.env`. This follows the behaviour of the tools
//! that made it popular (`docker compose`, `dotenv`, `direnv`) rather than
//! inventing a dialect, because a `.env` that a user's editor, their compose file
//! and their CLI disagree about is worse than no `.env` support:
//!
//!   * blank lines and `#` comments are ignored;
//!   * an optional `export ` prefix is accepted, because `.env` files are also
//!     sourced by shells;
//!   * `'single quotes'` are **literal** - no escapes, no expansion;
//!   * `"double quotes"` expand variables and honour `\n`, `\t`, `\r`, `\\`, `\"`;
//!   * an unquoted value runs to a trailing ` #` comment and is trimmed;
//!   * a later assignment to the same key wins, as in a shell;
//!   * an undefined variable expands to the empty string, also as in a shell.
//!
//! ## Recursion, and why it is bounded
//!
//! A value may reference another key, which may reference another. Two things are
//! therefore required and both are implemented:
//!
//!   * **A depth bound.** `max_expansion_depth` is not optional; an expansion that
//!     does not terminate would otherwise be an unbounded loop over user input
//!     (`AGENTS.md` 5.2).
//!   * **Cycle detection.** `A=$B` / `B=$A` is a cycle, not a deep chain, and it is
//!     reported as `error.CircularExpansion` rather than being allowed to hit the
//!     depth bound and be misreported as "too deep". The two are different bugs
//!     and a caller diagnosing one should not be told the other.

const std = @import("std");
const assert = std.debug.assert;

/// The default ceiling on `$A` -> `$B` -> ... chains.
pub const default_max_expansion_depth: u8 = 16;

pub const Error = error{
    /// A line was neither blank, a comment, nor a valid assignment.
    InvalidLine,
    /// A key that does not match `[A-Za-z_][A-Za-z0-9_]*`.
    InvalidKey,
    /// A quoted value with no closing quote before end of input.
    UnterminatedQuote,
    /// `A=$B` and `B=$A`, directly or through a chain.
    CircularExpansion,
    /// A chain longer than `max_expansion_depth`.
    ExpansionTooDeep,
    OutOfMemory,
};

/// One parsed assignment.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParseOptions = struct {
    /// Consulted for names the document does not define itself. A document key
    /// always wins over this, so a `.env` can override an ambient variable - which
    /// is the entire point of shipping one.
    fallback: ?*const std.process.Environ.Map = null,
    max_expansion_depth: u8 = default_max_expansion_depth,
};

/// A parsed document. Owns every byte it returns; one `deinit` frees it all.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    values: std.StringHashMapUnmanaged([]const u8) = .empty,
    ordered: std.ArrayListUnmanaged(Entry) = .empty,

    /// Frees the document. The keys and values handed out by `get`, `entries` and
    /// `keys` are all inside the arena, so nothing else needs releasing - which is
    /// the point of owning every byte rather than mixing literals with allocations.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The value for `key`, or null. Not the fallback environment: this is what the
    /// file said.
    pub fn get(self: Document, key: []const u8) ?[]const u8 {
        assert(key.len > 0);
        return self.values.get(key);
    }

    /// Every assignment, in file order, later duplicates excluded.
    pub fn entries(self: Document) []const Entry {
        return self.ordered.items;
    }

    pub fn count(self: Document) usize {
        return self.ordered.items.len;
    }

    /// A freshly allocated copy of every key, in file order.
    pub fn keys(self: Document, allocator: std.mem.Allocator) ![][]const u8 {
        const out = try allocator.alloc([]const u8, self.ordered.items.len);
        errdefer allocator.free(out);
        for (self.ordered.items, 0..) |entry, i| out[i] = entry.key;
        return out;
    }
};

/// Parses `text`.
pub fn parse(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: ParseOptions,
) Error!Document {
    assert(options.max_expansion_depth > 0);

    var document = Document{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer document.arena.deinit();
    const scratch = document.arena.allocator();

    // Pass one: split the text into raw (unexpanded) assignments. Expansion needs
    // the whole key set first, because a value may reference a key defined further
    // down the file - which is legal in this grammar and a real ordering hazard if
    // expansion happened while reading.
    var raw = std.ArrayListUnmanaged(RawEntry).empty;
    try splitInto(scratch, text, &raw);

    // Pass two: expand. Every value is resolved through the same resolver, so a
    // chain resolves once for all of its referrers and a cycle is caught wherever
    // it starts.
    var resolver = Resolver{
        .scratch = scratch,
        .raw = raw.items,
        .fallback = options.fallback,
        .max_depth = options.max_expansion_depth,
    };
    for (raw.items, 0..) |entry, index| {
        const value = try resolver.resolve(index, 1);
        assert(value.len <= text.len * options.max_expansion_depth);
        const owned = try scratch.dupe(u8, value);
        try document.values.put(scratch, entry.key, owned);
        try document.ordered.append(scratch, .{ .key = entry.key, .value = owned });
    }

    return document;
}

/// A line, split but not yet expanded.
const RawEntry = struct {
    key: []const u8,
    /// The value verbatim, still quoted and still containing `$`.
    value: []const u8,
    /// Whether `$` in `value` should be expanded. False for single-quoted values.
    expand: bool,
};

/// Splits `text` into assignments, tolerating everything the grammar allows.
fn splitInto(
    scratch: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayListUnmanaged(RawEntry),
) Error!void {
    assert(out.items.len == 0);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        // A trailing `\r` is what a CRLF file leaves behind, and treating it as
        // part of the value produces a variable that compares unequal to the same
        // variable set on a Unix host.
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const body = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trimStart(u8, line["export ".len..], " \t")
        else
            line;
        if (body.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, body, '=') orelse return error.InvalidLine;
        const key = std.mem.trim(u8, body[0..eq], " \t");
        if (!isValidKey(key)) return error.InvalidKey;

        const rest = std.mem.trimStart(u8, body[eq + 1 ..], " \t");
        const entry = try parseValue(scratch, key, rest);
        // A later assignment wins. The map does that naturally, but the ordered
        // list would otherwise carry both and `entries` would lie about the file.
        for (out.items) |*existing| {
            if (std.mem.eql(u8, existing.key, entry.key)) {
                existing.* = entry;
                break;
            }
        } else {
            try out.append(scratch, entry);
        }
    }
}

/// Decides quoting and whether the value expands.
fn parseValue(scratch: std.mem.Allocator, key: []const u8, rest: []const u8) Error!RawEntry {
    assert(key.len > 0);

    if (rest.len == 0) return .{ .key = key, .value = "", .expand = true };

    if (rest[0] == '\'') {
        // Literal: no escapes and no expansion, which is the whole reason to reach
        // for single quotes - a value containing `$` that must stay as typed.
        const end = std.mem.indexOfScalar(u8, rest[1..], '\'') orelse
            return error.UnterminatedQuote;
        return .{
            .key = key,
            .value = try scratch.dupe(u8, rest[1 .. 1 + end]),
            .expand = false,
        };
    }

    if (rest[0] == '"') {
        var out = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 1;
        while (i < rest.len) {
            const c = rest[i];
            if (c == '\\' and i + 1 < rest.len) {
                const escaped = rest[i + 1];
                // Only the escapes a double-quoted shell string defines. An
                // unknown escape keeps the backslash, because silently dropping it
                // corrupts a Windows path.
                switch (escaped) {
                    'n' => try out.append(scratch, '\n'),
                    't' => try out.append(scratch, '\t'),
                    'r' => try out.append(scratch, '\r'),
                    '"' => try out.append(scratch, '"'),
                    '\\' => try out.append(scratch, '\\'),
                    '$' => try out.append(scratch, '$'),
                    else => {
                        try out.append(scratch, '\\');
                        try out.append(scratch, escaped);
                    },
                }
                i += 2;
                continue;
            }
            if (c == '"') {
                return .{ .key = key, .value = try out.toOwnedSlice(scratch), .expand = true };
            }
            try out.append(scratch, c);
            i += 1;
        }
        return error.UnterminatedQuote;
    }

    // Unquoted: ends at a ` #` comment, and is otherwise trimmed.
    var end = rest.len;
    var scan: usize = 0;
    while (scan < rest.len) : (scan += 1) {
        if (rest[scan] == '#' and scan > 0 and (rest[scan - 1] == ' ' or rest[scan - 1] == '\t')) {
            end = scan;
            break;
        }
    }
    const trimmed = std.mem.trimEnd(u8, rest[0..end], " \t");
    return .{ .key = key, .value = try scratch.dupe(u8, trimmed), .expand = true };
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!std.ascii.isAlphabetic(key[0]) and key[0] != '_') return false;
    for (key[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Resolves one entry's value, memoizing so a shared referent resolves once.
const Resolver = struct {
    scratch: std.mem.Allocator,
    raw: []const RawEntry,
    fallback: ?*const std.process.Environ.Map,
    max_depth: u8,
    /// `null` means "not yet resolved"; an absent key means "not in the document".
    memo: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// The chain currently being resolved, for cycle detection. A set of indices.
    active: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn resolve(self: *Resolver, index: usize, depth: u8) Error![]const u8 {
        assert(index < self.raw.len);

        const entry = self.raw[index];
        if (!entry.expand or std.mem.indexOfScalar(u8, entry.value, '$') == null) {
            return entry.value;
        }

        // A key already on the current chain is a cycle, and saying so is more
        // useful than letting the depth bound report it as merely deep.
        if (self.active.contains(index)) return error.CircularExpansion;
        if (depth > self.max_depth) return error.ExpansionTooDeep;

        try self.active.put(self.scratch, index, {});
        defer _ = self.active.remove(index);

        var out = std.ArrayListUnmanaged(u8).empty;
        try expandInto(self, &out, entry.value, depth);
        return out.toOwnedSlice(self.scratch);
    }

    /// Looks a name up in the document first, then the fallback environment.
    fn lookup(self: *Resolver, name: []const u8, depth: u8) Error!?[]const u8 {
        assert(name.len > 0);

        for (self.raw, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate.key, name)) return try self.resolve(i, depth + 1);
        }
        if (self.fallback) |map| return map.get(name);
        return null;
    }
};

/// The name a `$NAME` at `value[i]` refers to, and the index just past it.
///
/// A free function rather than a method: it reads nothing but its arguments, and
/// hanging it off `Resolver` would claim a dependency it does not have.
fn reference(value: []const u8, i: usize) struct { name: []const u8, next: usize } {
    assert(value[i] == '$');

    if (i + 1 >= value.len) return .{ .name = "", .next = i + 1 };

    if (value[i + 1] == '{') {
        const close = std.mem.indexOfScalar(u8, value[i + 2 ..], '}') orelse
            return .{ .name = "", .next = i + 1 };
        return .{ .name = value[i + 2 .. i + 2 + close], .next = i + 2 + close + 1 };
    }

    var end = i + 1;
    while (end < value.len) : (end += 1) {
        const c = value[end];
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
    }
    return .{ .name = value[i + 1 .. end], .next = end };
}

/// Walks a value, appending it to `out` and expanding every `$` reference.
fn expandInto(
    resolver: *Resolver,
    out: *std.ArrayListUnmanaged(u8),
    value: []const u8,
    depth: u8,
) Error!void {
    assert(depth > 0);

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '$') {
            try out.append(resolver.scratch, value[i]);
            i += 1;
            continue;
        }

        // `$$` is a literal dollar, which is how a value escapes expansion without
        // having to be single-quoted.
        if (i + 1 < value.len and value[i + 1] == '$') {
            try out.append(resolver.scratch, '$');
            i += 2;
            continue;
        }

        const ref = reference(value, i);
        if (ref.name.len == 0) {
            // A bare `$` with nothing to name: keep it rather than dropping it.
            try out.append(resolver.scratch, '$');
            i = ref.next;
            continue;
        }

        // Undefined expands to empty, matching a shell. Reported nowhere, which is
        // deliberate: an unset optional variable is not an error.
        if (try resolver.lookup(ref.name, depth)) |resolved| {
            try out.appendSlice(resolver.scratch, resolved);
        }
        i = ref.next;
    }
}

const testing = std.testing;

test "parses the plain form, ignoring blanks and comments" {
    var doc = try parse(testing.allocator,
        \\# a comment
        \\
        \\HOST=localhost
        \\PORT=8080
        \\
    , .{});
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.count());
    try testing.expectEqualStrings("localhost", doc.get("HOST").?);
    try testing.expectEqualStrings("8080", doc.get("PORT").?);
    try testing.expectEqual(@as(?[]const u8, null), doc.get("MISSING"));
}

test "an export prefix is accepted because shells source these files" {
    var doc = try parse(testing.allocator, "export TOKEN=abc\nexport  OTHER=def\n", .{});
    defer doc.deinit();

    try testing.expectEqualStrings("abc", doc.get("TOKEN").?);
    try testing.expectEqualStrings("def", doc.get("OTHER").?);
}

test "single quotes are literal and double quotes expand" {
    var doc = try parse(testing.allocator,
        \\BASE=/opt
        \\LITERAL='$BASE/keep'
        \\EXPANDED="$BASE/change"
        \\
    , .{});
    defer doc.deinit();

    // The whole reason to reach for single quotes.
    try testing.expectEqualStrings("$BASE/keep", doc.get("LITERAL").?);
    try testing.expectEqualStrings("/opt/change", doc.get("EXPANDED").?);
}

test "double quotes honour the escapes a shell defines" {
    // The escapes are doubled so the *input* contains a literal backslash-t and
    // backslash-n. Writing `\t` here would put a real tab in the `.env` text, which
    // is a different test - and the one that made this test fail the first time.
    var doc = try parse(testing.allocator, "M=\"tab\\there\\nnewline\"\n", .{});
    defer doc.deinit();

    try testing.expectEqualStrings("tab\there\nnewline", doc.get("M").?);
}

test "an unknown escape keeps its backslash rather than eating it" {
    // Silently dropping it would corrupt a Windows path, which is the case that
    // makes this worth pinning.
    var doc = try parse(testing.allocator, "PATH=\"C:\\Users\\ada\"\n", .{});
    defer doc.deinit();

    // `\\` is an escaped backslash; `\U` is unknown and survives intact.
    try testing.expectEqualStrings("C:\\Users\\ada", doc.get("PATH").?);
}

test "an unquoted value stops at a trailing comment and is trimmed" {
    var doc = try parse(testing.allocator, "PORT=8080   # the listen port\n", .{});
    defer doc.deinit();

    try testing.expectEqualStrings("8080", doc.get("PORT").?);
}

test "a later assignment wins, as it does in a shell" {
    var doc = try parse(testing.allocator, "A=1\nA=2\n", .{});
    defer doc.deinit();

    try testing.expectEqualStrings("2", doc.get("A").?);
    // And the ordered list carries one entry, not two, so `entries` does not
    // claim the file defines `A` twice.
    try testing.expectEqual(@as(usize, 1), doc.count());
}

test "expansion is recursive, and a forward reference resolves" {
    var doc = try parse(testing.allocator,
        \\URL=$SCHEME://$HOST:$PORT
        \\SCHEME=https
        \\HOST=example.com
        \\PORT=443
        \\
    , .{});
    defer doc.deinit();

    // `URL` references keys defined *after* it, so expansion cannot happen while
    // reading the file line by line.
    try testing.expectEqualStrings("https://example.com:443", doc.get("URL").?);
}

test "braced and bare references are both understood, and $$ is a literal" {
    var doc = try parse(testing.allocator,
        \\A=one
        \\BRACED=${A}-two
        \\BARE=$A-three
        \\MONEY=$$A
        \\
    , .{});
    defer doc.deinit();

    try testing.expectEqualStrings("one-two", doc.get("BRACED").?);
    try testing.expectEqualStrings("one-three", doc.get("BARE").?);
    try testing.expectEqualStrings("$A", doc.get("MONEY").?);
}

test "an undefined variable expands to empty, matching a shell" {
    var doc = try parse(testing.allocator, "M=[$NOPE]\n", .{});
    defer doc.deinit();

    try testing.expectEqualStrings("[]", doc.get("M").?);
}

test "the fallback environment fills gaps but never overrides the document" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("FROM_ENV", "ambient");
    try env.put("SHADOWED", "ambient");

    var doc = try parse(testing.allocator,
        \\INHERITED=$FROM_ENV
        \\SHADOWED=from-file
        \\
    , .{ .fallback = &env });
    defer doc.deinit();

    try testing.expectEqualStrings("ambient", doc.get("INHERITED").?);
    // A `.env` that could not override the ambient value would be pointless.
    try testing.expectEqualStrings("from-file", doc.get("SHADOWED").?);
}

test "a two-key cycle is reported as a cycle, not as excessive depth" {
    // These are different bugs, and a caller diagnosing one should not be told
    // the other.
    try testing.expectError(error.CircularExpansion, parse(testing.allocator,
        \\A=$B
        \\B=$A
        \\
    , .{}));
}

test "a self-reference is a cycle" {
    try testing.expectError(error.CircularExpansion, parse(
        testing.allocator,
        "A=$A-x\n",
        .{},
    ));
}

test "a chain longer than the bound is reported as too deep" {
    // A chain, not a cycle: each key references the next and nothing points back.
    var text = std.ArrayList(u8).empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "K0=end\n");
    for (1..12) |i| {
        try text.print(testing.allocator, "K{d}=$K{d}\n", .{ i, i - 1 });
    }

    try testing.expectError(error.ExpansionTooDeep, parse(
        testing.allocator,
        text.items,
        .{ .max_expansion_depth = 3 },
    ));

    // And the same input resolves once the bound is raised above the chain length,
    // so the error is about the bound rather than about the input.
    var ok = try parse(testing.allocator, text.items, .{ .max_expansion_depth = 32 });
    defer ok.deinit();
    try testing.expectEqualStrings("end", ok.get("K11").?);
}

test "malformed input is reported rather than silently ignored" {
    try testing.expectError(error.InvalidLine, parse(testing.allocator, "NOT_AN_ASSIGNMENT\n", .{}));
    try testing.expectError(error.InvalidKey, parse(testing.allocator, "1BAD=x\n", .{}));
    try testing.expectError(error.InvalidKey, parse(testing.allocator, "BAD KEY=x\n", .{}));
    try testing.expectError(error.UnterminatedQuote, parse(testing.allocator, "A=\"unclosed\n", .{}));
    try testing.expectError(error.UnterminatedQuote, parse(testing.allocator, "A='unclosed\n", .{}));
}

test "CRLF input does not leave a carriage return in the value" {
    // A `.env` written on Windows and read on Linux would otherwise define a
    // variable that compares unequal to the same variable set by a shell.
    var doc = try parse(testing.allocator, "A=one\r\nB=two\r\n", .{});
    defer doc.deinit();

    try testing.expectEqualStrings("one", doc.get("A").?);
    try testing.expectEqualStrings("two", doc.get("B").?);
}

test "keys preserves file order" {
    var doc = try parse(testing.allocator, "Z=1\nA=2\nM=3\n", .{});
    defer doc.deinit();

    const names = try doc.keys(testing.allocator);
    defer testing.allocator.free(names);

    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("Z", names[0]);
    try testing.expectEqualStrings("A", names[1]);
    try testing.expectEqualStrings("M", names[2]);
}

test "the document owns every byte, so one deinit is enough" {
    // Run under the testing allocator, which fails the test on a leak: this is
    // what the value-ownership rule buys, and it is checked rather than asserted.
    var doc = try parse(testing.allocator,
        \\A=one
        \\B="$A/two"
        \\C='$A/three'
        \\
    , .{});
    defer doc.deinit();

    try testing.expectEqualStrings("one", doc.get("A").?);
    try testing.expectEqualStrings("one/two", doc.get("B").?);
    try testing.expectEqualStrings("$A/three", doc.get("C").?);
}
