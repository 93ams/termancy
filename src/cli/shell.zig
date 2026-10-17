//! Shell-style words: `tokenize` splits a command line the way a POSIX shell splits words,
//! without expansions; `quote` writes a word so that `tokenize` gives it back unchanged.
//!
//! | input                  | meaning                                                     |
//! |------------------------|-------------------------------------------------------------|
//! | spaces, tabs, newlines | separate words                                              |
//! | `'...'`                | literal text; no escapes inside                             |
//! | `"..."`                | text where `\\`, `\"`, `\$`, and `` \` `` are escapes and a |
//! |                        | backslash-newline is removed; other backslashes are kept    |
//! | `\x`                   | outside quotes: `x` literally; backslash-newline is removed |
//! | `#`                    | at the start of a word: a comment to the end of the line    |
//!
//! Quoted parts join the surrounding word (`a'b c'd` is one word), and `''` is an empty
//! word. `$`, `*`, `~`, `;`, `|`, and the like are ordinary characters: nothing is
//! expanded and nothing is run.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What `tokenize` can fail with.
pub const Error = error{
    /// A `'` or `"` without its closing quote.
    UnterminatedQuote,
    /// The line ends with an unquoted backslash.
    TrailingBackslash,
} || Allocator.Error;

/// A message for a tokenizing error, for the user.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.UnterminatedQuote => "unterminated quote",
        error.TrailingBackslash => "line ends with a backslash",
        error.OutOfMemory => "out of memory",
    };
}

const State = enum { space, word, comment, single, double };

/// Splits `line` into words. Words and the list are allocated from `arena`; the caller frees
/// them by freeing the arena.
pub fn tokenize(arena: Allocator, line: []const u8) Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var state: State = .space;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        switch (state) {
            .space, .word => {
                if (isSpace(c)) {
                    if (state == .word) try finish(arena, &words, &word);
                    state = .space;
                    continue;
                }
                if (state == .space and c == '#') {
                    state = .comment;
                    continue;
                }
                if (c == '\\') {
                    i += 1;
                    if (i == line.len) return error.TrailingBackslash;
                    // A backslash-newline joins lines without starting a word.
                    if (line[i] == '\n') continue;
                }
                state = switch (line[i]) {
                    '\'' => if (c == '\\') .word else .single,
                    '"' => if (c == '\\') .word else .double,
                    else => .word,
                };
                if (state == .word) try word.append(arena, line[i]);
            },
            .comment => if (c == '\n') {
                state = .space;
            },
            .single => if (c == '\'') {
                state = .word;
            } else {
                try word.append(arena, c);
            },
            .double => i = try doubleQuoted(arena, line, i, &word, &state),
        }
    }
    switch (state) {
        .single, .double => return error.UnterminatedQuote,
        .word => try finish(arena, &words, &word),
        .space, .comment => {},
    }
    return words.items;
}

/// Handles the byte at `i` inside double quotes; returns the index of the last byte used.
fn doubleQuoted(
    arena: Allocator,
    line: []const u8,
    i: usize,
    word: *std.ArrayList(u8),
    state: *State,
) Allocator.Error!usize {
    assert(state.* == .double);
    switch (line[i]) {
        '"' => state.* = .word,
        '\\' => if (i + 1 < line.len) switch (line[i + 1]) {
            '\\', '"', '$', '`' => {
                try word.append(arena, line[i + 1]);
                return i + 1;
            },
            '\n' => return i + 1,
            else => try word.append(arena, '\\'),
        } else try word.append(arena, '\\'),
        else => |c| try word.append(arena, c),
    }
    return i;
}

fn finish(
    arena: Allocator,
    words: *std.ArrayList([]const u8),
    word: *std.ArrayList(u8),
) Allocator.Error!void {
    try words.append(arena, try word.toOwnedSlice(arena));
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Whether `word` reads the same unquoted.
fn isPlain(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ',', ':', '=', '+', '@', '%' => {},
        else => return false,
    };
    return true;
}

/// Writes `word` so that `tokenize` reads it back as exactly one word: as is when that is
/// safe, otherwise in single quotes, with each `'` written as `'\''`.
pub fn quote(writer: *Writer, word: []const u8) Writer.Error!void {
    if (isPlain(word)) return writer.writeAll(word);
    try writer.writeByte('\'');
    for (word) |c| {
        if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
    }
    try writer.writeByte('\'');
}

/// Writes `words` quoted and separated by spaces: the inverse of `tokenize`.
pub fn join(writer: *Writer, words: []const []const u8) Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try writer.writeByte(' ');
        try quote(writer, word);
    }
}

const testing = std.testing;

fn expectWords(line: []const u8, expected: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const words = try tokenize(arena_state.allocator(), line);
    try testing.expectEqual(expected.len, words.len);
    for (expected, words) |want, got| try testing.expectEqualStrings(want, got);
}

fn expectError(line: []const u8, expected: Error) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(expected, tokenize(arena_state.allocator(), line));
}

test tokenize {
    try expectWords("", &.{});
    try expectWords("  \t\n ", &.{});
    try expectWords("get  server.port", &.{ "get", "server.port" });
    try expectWords("set 'a b' \"c d\"", &.{ "set", "a b", "c d" });
    try expectWords("a'b c'd", &.{"ab cd"});
    try expectWords("'' \"\"", &.{ "", "" });
    try expectWords("'it''s'", &.{"its"});
    try expectWords("'\\n $x'", &.{"\\n $x"});
}

test "tokenize: escapes" {
    try expectWords("a\\ b", &.{"a b"});
    try expectWords("\\'\\\"\\\\", &.{"'\"\\"});
    try expectWords("a\\\nb", &.{"ab"});
    try expectWords("\"\\\\ \\\" \\$ \\` \\n\"", &.{"\\ \" $ ` \\n"});
    try expectWords("\"a\\\nb\"", &.{"ab"});
    try expectWords("a \\\n b", &.{ "a", "b" });
}

test "tokenize: comments start only at a word" {
    try expectWords("get x # the rest", &.{ "get", "x" });
    try expectWords("# all comment", &.{});
    try expectWords("a#b '#c' \\#d", &.{ "a#b", "#c", "#d" });
    try expectWords("a # one\nb", &.{ "a", "b" });
}

test "tokenize: errors" {
    try expectError("'open", error.UnterminatedQuote);
    try expectError("say \"hi", error.UnterminatedQuote);
    try expectError("\"\\\"", error.UnterminatedQuote);
    try expectError("tail\\", error.TrailingBackslash);
    try testing.expectEqualStrings("unterminated quote", describe(error.UnterminatedQuote));
}

test quote {
    var buffer: [128]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try join(&writer, &.{ "plain", "", "a b", "it's", "$HOME", "x=1,2" });
    try testing.expectEqualStrings("plain '' 'a b' 'it'\\''s' '$HOME' x=1,2", writer.buffered());
}

/// Bytes the fuzzer favours: everything the tokenizer treats specially, plus some plain
/// and non-ASCII bytes.
const interesting = " \t\n\r'\"\\#$`ab=-\xff\x00";

fn randomBytes(random: std.Random, buffer: []u8) []u8 {
    const len = random.uintLessThan(usize, buffer.len + 1);
    for (buffer[0..len]) |*b| {
        b.* = if (random.boolean())
            interesting[random.uintLessThan(usize, interesting.len)]
        else
            random.int(u8);
    }
    return buffer[0..len];
}

test "fuzz: tokenize never fails except as documented" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_5e11);
    const random = prng.random();
    var buffer: [64]u8 = undefined;
    for (0..20_000) |_| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const line = randomBytes(random, &buffer);
        _ = tokenize(arena_state.allocator(), line) catch |err| switch (err) {
            error.UnterminatedQuote, error.TrailingBackslash => continue,
            error.OutOfMemory => return err,
        };
    }
}

test "fuzz: tokenize(join(words)) == words" {
    var prng: std.Random.DefaultPrng = .init(0x0dd_ba11);
    const random = prng.random();
    var storage: [8][24]u8 = undefined;
    var words: [8][]const u8 = undefined;
    var line_buffer: [1024]u8 = undefined;
    for (0..20_000) |_| {
        const count = random.uintLessThan(usize, words.len + 1);
        for (words[0..count], storage[0..count]) |*word, *bytes| {
            word.* = randomBytes(random, bytes);
        }
        var writer: Writer = .fixed(&line_buffer);
        try join(&writer, words[0..count]);
        try expectWords(writer.buffered(), words[0..count]);
    }
}
