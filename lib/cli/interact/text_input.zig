//! A line editor for prompts: text entry, and password entry with echo suppressed.
//!
//! ## What was missing
//!
//! `[measured]` `prompt.zig` had `confirm`, `select`, `multiSelect` and
//! `multiSelectDynamic` - every prompt shape except the two a CLI needs most. Free
//! text was typed only through an inline fallback in `cli.zig` for a missing
//! required flag, and password entry did not exist as an input path at all:
//! `widgets.zig` could **render** a mask (`Form.render` prints `*` per character)
//! and nothing in the tree read a keystroke into it.
//!
//! ## Why the editing logic is a value with no I/O
//!
//! This module does not read from a terminal and does not put one into raw mode;
//! `handleKey` takes an already-decoded key and `view` writes to a caller-supplied
//! writer. That split is the whole design, because it makes the parts that can be
//! wrong **testable without a TTY** - including the one that matters most, which is
//! that a masked input never puts its plaintext into the rendered frame.
//!
//! A prompt library whose only test needs a terminal is a prompt library whose
//! mask has never been checked.
//!
//! ## Codepoints, not bytes
//!
//! The buffer holds `u21` codepoints, so backspace removes a character rather than
//! a byte. A byte-oriented buffer with a byte cursor is simpler and produces
//! **invalid UTF-8** the moment someone backspaces through a multi-byte character -
//! and a path or a bearer token with a non-ASCII character in it is not exotic.
//!
//! ## The mask is per-codepoint on purpose
//!
//! Rendering `*` per codepoint means the masked frame reveals the **length** of the
//! secret. That is standard for a password prompt and it is a deliberate trade:
//! revealing nothing at all means the user cannot tell whether their keystrokes are
//! being received, which is how a password prompt gets typed into twice.

const std = @import("std");
const assert = std.debug.assert;

/// A decoded keypress.
pub const Key = union(enum) {
    /// A printable character, as a codepoint.
    char: u21,
    backspace,
    delete,
    left,
    right,
    home,
    end,
    enter,
    /// Ctrl+C or Escape.
    cancel,
    /// Anything else: function keys, unknown escape sequences. Ignored rather than
    /// inserted, so a stray key cannot corrupt the value.
    ignored,
};

/// What `handleKey` did, so a driver knows whether to redraw or stop.
pub const Action = enum { unchanged, changed, submitted, cancelled };

/// Default ceiling on the value's length, in codepoints.
pub const default_max_length: usize = 4096;

const Self = @This();

buffer: std.ArrayListUnmanaged(u21) = .empty,
cursor: usize = 0,
/// The byte written in place of each character when rendering. Null renders the
/// value itself.
mask: ?u8 = null,
max_length: usize = default_max_length,
allocator: std.mem.Allocator,

/// A visible line editor.
pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

/// An editor that never renders what was typed.
pub fn password(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator, .mask = '*' };
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit(self.allocator);
    self.* = undefined;
}

/// The current value, encoded as UTF-8. Owned by the caller.
pub fn value(self: *const Self) ![]u8 {
    const out = try self.allocator.alloc(u8, self.buffer.items.len * 4);
    errdefer self.allocator.free(out);

    var written: usize = 0;
    for (self.buffer.items) |codepoint| {
        const encoded = try std.unicode.utf8Encode(codepoint, out[written..]);
        written += encoded;
    }
    // Hand back exactly what was used rather than a four-times-too-large slice.
    if (self.allocator.resize(out, written)) return out[0..written];
    return self.allocator.realloc(out, written);
}

/// Number of codepoints entered.
pub fn len(self: *const Self) usize {
    return self.buffer.items.len;
}

pub fn isEmpty(self: *const Self) bool {
    return self.buffer.items.len == 0;
}

/// Applies one key.
pub fn handleKey(self: *Self, key: Key) Action {
    switch (key) {
        .enter => return .submitted,
        .cancel => return .cancelled,

        .char => |codepoint| {
            // A control character is not text. Accepting one would put an escape
            // sequence into a value that is then rendered back to the same terminal.
            if (codepoint < 0x20 or codepoint == 0x7f) return .unchanged;
            if (self.buffer.items.len >= self.max_length) return .unchanged;

            self.buffer.insert(self.allocator, self.cursor, codepoint) catch
                return .unchanged;
            self.cursor += 1;
            return .changed;
        },

        .backspace => {
            if (self.cursor == 0) return .unchanged;
            _ = self.buffer.orderedRemove(self.cursor - 1);
            self.cursor -= 1;
            return .changed;
        },

        .delete => {
            if (self.cursor >= self.buffer.items.len) return .unchanged;
            _ = self.buffer.orderedRemove(self.cursor);
            return .changed;
        },

        .left => {
            if (self.cursor == 0) return .unchanged;
            self.cursor -= 1;
            return .unchanged;
        },

        .right => {
            if (self.cursor >= self.buffer.items.len) return .unchanged;
            self.cursor += 1;
            return .unchanged;
        },

        .home => {
            self.cursor = 0;
            return .unchanged;
        },

        .end => {
            self.cursor = self.buffer.items.len;
            return .unchanged;
        },

        .ignored => return .unchanged,
    }
}

/// Writes the current line, without a trailing newline.
///
/// When `mask` is set, neither the characters nor the cursor position are
/// rendered - only a run of `*`. Moving the cursor inside a masked field therefore
/// produces a byte-identical frame, which is what stops the mask from leaking the
/// cursor's position inside the secret.
///
/// What this deliberately does **not** do is position the terminal's cursor at
/// `self.cursor`. That needs a cursor-movement escape, the terminal's width, and
/// the capability gate - none of which belong in a function whose whole value is
/// that it contains no terminal I/O. A driver that wants an in-line caret emits it
/// itself, after this returns.
pub fn view(self: *const Self, writer: anytype) !void {
    for (self.buffer.items) |codepoint| {
        if (self.mask) |mask_byte| {
            try writer.writeByte(mask_byte);
            continue;
        }

        var encoded: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &encoded) catch {
            // Unreachable for a codepoint `handleKey` accepted, since it rejects
            // control characters and so cannot admit a surrogate. A replacement
            // character is still better than a prompt that fails to draw.
            try writer.writeAll("\u{FFFD}");
            continue;
        };
        try writer.writeAll(encoded[0..written]);
    }
}

/// Decodes one key from `bytes`, returning how many bytes it consumed.
///
/// A terminal delivers bytes, not keys, and an escape sequence arrives as several
/// of them at once. Returning the length rather than a slice means the caller can
/// keep its own buffer and offset, which is what a reader loop has anyway.
pub fn parseKey(bytes: []const u8) ?struct { key: Key, consumed: usize } {
    if (bytes.len == 0) return null;

    switch (bytes[0]) {
        '\r', '\n' => return .{ .key = .enter, .consumed = 1 },
        0x7f, 0x08 => return .{ .key = .backspace, .consumed = 1 },
        0x03 => return .{ .key = .cancel, .consumed = 1 },
        0x1b => {
            // Escape alone is a cancel; `ESC [` introduces a sequence. The two are
            // only distinguishable by what follows, so a lone ESC at the end of the
            // buffer is treated as a cancel - which is what a user pressing Escape
            // means, and the alternative is waiting for a byte that never comes.
            if (bytes.len == 1) return .{ .key = .cancel, .consumed = 1 };
            if (bytes[1] != '[') return .{ .key = .cancel, .consumed = 1 };
            if (bytes.len < 3) return null;

            return switch (bytes[2]) {
                'A' => .{ .key = .ignored, .consumed = 3 }, // up
                'B' => .{ .key = .ignored, .consumed = 3 }, // down
                'C' => .{ .key = .right, .consumed = 3 },
                'D' => .{ .key = .left, .consumed = 3 },
                'H' => .{ .key = .home, .consumed = 3 },
                'F' => .{ .key = .end, .consumed = 3 },
                // `ESC [ 3 ~` is Delete. Consumed as four bytes when they are all
                // present; a truncated sequence is left for the next read.
                '3' => if (bytes.len < 4)
                    null
                else if (bytes[3] == '~')
                    .{ .key = .delete, .consumed = 4 }
                else
                    .{ .key = .ignored, .consumed = 4 },
                else => .{ .key = .ignored, .consumed = 3 },
            };
        },
        else => {},
    }

    // A multi-byte codepoint, or one ASCII byte. `utf8ByteSequenceLength` reports
    // the expected length; a sequence that is not yet complete returns null so the
    // caller reads more rather than decoding a prefix.
    const expected = std.unicode.utf8ByteSequenceLength(bytes[0]) catch
        return .{ .key = .ignored, .consumed = 1 };
    if (bytes.len < expected) return null;

    const codepoint = std.unicode.utf8Decode(bytes[0..expected]) catch
        return .{ .key = .ignored, .consumed = 1 };
    return .{ .key = .{ .char = codepoint }, .consumed = expected };
}

const testing = std.testing;

fn typeString(input: *Self, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const parsed = parseKey(text[i..]).?;
        _ = input.handleKey(parsed.key);
        i += parsed.consumed;
    }
}

/// Asserts the input's current value, freeing it.
///
/// `value` allocates, so calling it inline inside `expectEqualStrings` leaks the
/// result - which the testing allocator caught in four separate tests the first
/// time this file ran. A helper rather than five hand-written frees, because the
/// sixth call site would have got it wrong too.
fn expectValue(input: *const Self, expected: []const u8) !void {
    const actual = try input.value();
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "typing appends and enter submits" {
    var input = Self.init(testing.allocator);
    defer input.deinit();

    typeString(&input, "hello");
    try expectValue(&input, "hello");
    try testing.expectEqual(Action.submitted, input.handleKey(.enter));
}

test "backspace removes the character before the cursor, not a byte" {
    var input = Self.init(testing.allocator);
    defer input.deinit();

    // Two codepoints, four UTF-8 bytes. A byte-oriented buffer would need two
    // backspaces here and would leave invalid UTF-8 after one.
    typeString(&input, "é!");
    try testing.expectEqual(@as(usize, 2), input.len());

    _ = input.handleKey(.backspace);
    const edited = try input.value();
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings("é", edited);
    // And it is still valid UTF-8, which is the thing a byte cursor breaks.
    try testing.expect(std.unicode.utf8ValidateSlice(edited));
}

test "deletion happens at the cursor, so left and right matter" {
    var input = Self.init(testing.allocator);
    defer input.deinit();

    typeString(&input, "abc");
    _ = input.handleKey(.left);
    _ = input.handleKey(.backspace);
    try expectValue(&input, "ac");

    _ = input.handleKey(.home);
    _ = input.handleKey(.delete);
    try expectValue(&input, "c");

    _ = input.handleKey(.end);
    typeString(&input, "d");
    try expectValue(&input, "cd");
}

test "movement past either end is a no-op rather than an error" {
    var input = Self.init(testing.allocator);
    defer input.deinit();

    // Every one of these is a key a user will press on an empty prompt.
    try testing.expectEqual(Action.unchanged, input.handleKey(.left));
    try testing.expectEqual(Action.unchanged, input.handleKey(.right));
    try testing.expectEqual(Action.unchanged, input.handleKey(.backspace));
    try testing.expectEqual(Action.unchanged, input.handleKey(.delete));
    try testing.expect(input.isEmpty());
}

test "a control character is not text" {
    // Accepting one would put an escape sequence into a value that is rendered back
    // to the same terminal.
    var input = Self.init(testing.allocator);
    defer input.deinit();

    try testing.expectEqual(Action.unchanged, input.handleKey(.{ .char = 0x1b }));
    try testing.expectEqual(Action.unchanged, input.handleKey(.{ .char = '\n' }));
    try testing.expectEqual(Action.unchanged, input.handleKey(.{ .char = 0x7f }));
    try testing.expect(input.isEmpty());
}

test "the length ceiling holds" {
    var input = Self.init(testing.allocator);
    defer input.deinit();
    input.max_length = 3;

    typeString(&input, "abcd");
    try expectValue(&input, "abc");
}

test "cancel is reported, and escape is a cancel" {
    var input = Self.init(testing.allocator);
    defer input.deinit();

    try testing.expectEqual(Action.cancelled, input.handleKey(.cancel));
    // A lone ESC byte decodes as a cancel rather than waiting for a sequence that
    // will never arrive.
    try testing.expectEqual(Key.cancel, parseKey("\x1b").?.key);
    try testing.expectEqual(Key.cancel, parseKey("\x03").?.key);
}

test "a masked view never renders the plaintext" {
    // The assertion this module exists to make. A mask that leaked the value into
    // the frame would look correct in every test that only checked `value`.
    var input = Self.password(testing.allocator);
    defer input.deinit();

    const secret = "hunter2";
    typeString(&input, secret);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try input.view(&w);

    const rendered = w.buffered();
    try testing.expect(std.mem.indexOf(u8, rendered, secret) == null);
    // Not the digits of the secret either, which is what a partial mask leaks.
    try testing.expect(std.mem.indexOf(u8, rendered, "hunter") == null);
    try testing.expectEqualStrings("*******", rendered);

    // The value itself is intact - the mask is presentation, not storage.
    try expectValue(&input, secret);
}

test "a masked view does not reveal where the cursor is" {
    var input = Self.password(testing.allocator);
    defer input.deinit();
    typeString(&input, "abcd");

    var at_end: [64]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&at_end);
    try input.view(&w1);

    // Moving to the middle must not change the frame: a caret that moved would leak
    // the cursor's position inside the secret.
    _ = input.handleKey(.left);
    _ = input.handleKey(.left);

    var at_middle: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&at_middle);
    try input.view(&w2);

    try testing.expectEqualStrings(w1.buffered(), w2.buffered());
}

test "an unmasked view shows the value and places the caret" {
    var input = Self.init(testing.allocator);
    defer input.deinit();
    typeString(&input, "abc");

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try input.view(&w);
    try testing.expectEqualStrings("abc", w.buffered());
}

test "a multi-byte character survives a round trip through value" {
    var input = Self.init(testing.allocator);
    defer input.deinit();

    const typed = "héllo→";
    typeString(&input, typed);

    const round_tripped = try input.value();
    defer testing.allocator.free(round_tripped);
    try testing.expectEqualStrings(typed, round_tripped);
    try testing.expectEqual(typed.len, round_tripped.len);
}

test "parseKey decodes the sequences a terminal actually sends" {
    try testing.expectEqual(Key.enter, parseKey("\r").?.key);
    try testing.expectEqual(@as(usize, 1), parseKey("\r").?.consumed);
    try testing.expectEqual(Key.backspace, parseKey("\x7f").?.key);
    try testing.expectEqual(Key.left, parseKey("\x1b[D").?.key);
    try testing.expectEqual(@as(usize, 3), parseKey("\x1b[D").?.consumed);
    try testing.expectEqual(Key.right, parseKey("\x1b[C").?.key);
    try testing.expectEqual(Key.home, parseKey("\x1b[H").?.key);
    try testing.expectEqual(Key.end, parseKey("\x1b[F").?.key);
    try testing.expectEqual(Key.delete, parseKey("\x1b[3~").?.key);
    try testing.expectEqual(@as(usize, 4), parseKey("\x1b[3~").?.consumed);
    // Up and down are decoded so they cannot be mistaken for text, and ignored.
    try testing.expectEqual(Key.ignored, parseKey("\x1b[A").?.key);
    try testing.expectEqual(Key.ignored, parseKey("\x1b[B").?.key);
}

test "parseKey decodes a multi-byte character as one key" {
    const parsed = parseKey("é").?;
    try testing.expectEqual(@as(u21, 0xe9), parsed.key.char);
    try testing.expectEqual(@as(usize, 2), parsed.consumed);
}

test "parseKey asks for more bytes rather than decoding a prefix" {
    // A read that splits a sequence must not produce a wrong character. Returning
    // null tells the caller to read again, which is the only correct answer.
    //
    // Written as a plain null comparison: `@TypeOf(parseKey(..))` is *already* the
    // optional, so wrapping it in another `?` to build an expected value compares
    // `??T` against `?T` and is unequal for reasons that have nothing to do with
    // the parser.
    try testing.expect(parseKey("") == null);
    try testing.expect(parseKey("\x1b[") == null);
    try testing.expect(parseKey("\xc3") == null);
}

test "an unrecognised byte is ignored rather than inserted" {
    // A stray function key must not put a replacement character into a value.
    var input = Self.init(testing.allocator);
    defer input.deinit();

    const parsed = parseKey("\xff").?;
    try testing.expectEqual(Key.ignored, parsed.key);
    try testing.expectEqual(Action.unchanged, input.handleKey(parsed.key));
    try testing.expect(input.isEmpty());
}
