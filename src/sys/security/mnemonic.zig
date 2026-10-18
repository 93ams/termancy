//! Secrets as words (BIP 39): 16 to 32 bytes become 12 to 24 English words that are
//! easy to write down and type back, with a checksum that catches a wrong or misspelled
//! word. Charm's melt does this for Ed25519 keys: the 32-byte seed is the whole key.
//!
//! ```zig
//! var words: [24][]const u8 = undefined;
//! const phrase = mnemonic.encode(&seed, &words);
//! var back: [32]u8 = undefined;
//! try mnemonic.decode(phrase, &back);
//! ```

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The 2048 words, in order (BIP 39's English list).
pub const words: [2048][]const u8 = blk: {
    @setEvalBranchQuota(100_000);
    const text = @embedFile("bip39_english.txt");
    var list: [2048][]const u8 = undefined;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    for (&list) |*w| w.* = it.next().?;
    std.debug.assert(it.next() == null);
    break :blk list;
};

/// The words for `entropy` (16, 20, 24, 28, or 32 bytes): 3 for each 4 bytes. `out`
/// must hold them; the filled part is returned.
pub fn encode(entropy: []const u8, out: [][]const u8) [][]const u8 {
    std.debug.assert(entropy.len >= 16 and entropy.len <= 32 and entropy.len % 4 == 0);
    const count = entropy.len * 3 / 4;
    std.debug.assert(out.len >= count);
    var digest: [32]u8 = undefined;
    Sha256.hash(entropy, &digest, .{});
    for (0..count) |i| out[i] = words[bitsAt(entropy, digest[0], i * 11)];
    return out[0..count];
}

pub const DecodeError = error{ UnknownWord, WrongLength, BadChecksum };

/// The secret `phrase` (words separated by spaces) holds, into `out`, whose length says
/// how many words to expect. Words compare without case, and the first four letters
/// suffice (no two words share them).
pub fn decode(phrase: []const u8, out: []u8) DecodeError!void {
    std.debug.assert(out.len >= 16 and out.len <= 32 and out.len % 4 == 0);
    const count = out.len * 3 / 4;
    var indices: [24]u11 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, phrase, " \t\r\n,");
    while (it.next()) |word| {
        if (n == count) return error.WrongLength;
        indices[n] = indexOf(word) orelse return error.UnknownWord;
        n += 1;
    }
    if (n != count) return error.WrongLength;
    // 11 bits a word: the entropy, then a checksum of entropy.len / 4 bits.
    @memset(out, 0);
    var checksum: u8 = 0;
    const entropy_bits = out.len * 8;
    for (indices[0..count], 0..) |index, w| {
        for (0..11) |b| {
            const bit: u1 = @intCast((index >> @intCast(10 - b)) & 1);
            const pos = w * 11 + b;
            if (pos < entropy_bits) {
                out[pos / 8] |= @as(u8, bit) << @intCast(7 - pos % 8);
            } else {
                checksum = checksum << 1 | @as(u8, bit);
            }
        }
    }
    var digest: [32]u8 = undefined;
    Sha256.hash(out, &digest, .{});
    // Up to 8 bits (32 bytes); the first byte of the digest's high bits.
    const checksum_bits = out.len / 4;
    const expected: u8 = if (checksum_bits == 8)
        digest[0]
    else
        digest[0] >> @intCast(8 - checksum_bits);
    if (expected != checksum) return error.BadChecksum;
}

/// The index of `word` (or of the word it is the first four letters of, or more).
pub fn indexOf(word: []const u8) ?u11 {
    if (word.len < 3) return null;
    for (words, 0..) |w, i| {
        if (std.ascii.eqlIgnoreCase(w, word)) return @intCast(i);
    }
    if (word.len < 4) return null;
    for (words, 0..) |w, i| {
        if (w.len >= word.len and std.ascii.eqlIgnoreCase(w[0..word.len], word)) return @intCast(i);
    }
    return null;
}

/// The 11 bits at `start` of entropy followed by its checksum byte.
fn bitsAt(entropy: []const u8, checksum: u8, start: usize) u11 {
    var value: u11 = 0;
    for (0..11) |b| {
        const pos = start + b;
        const byte = if (pos / 8 < entropy.len) entropy[pos / 8] else checksum;
        const bit = (byte >> @intCast(7 - pos % 8)) & 1;
        value = value << 1 | bit;
    }
    return value;
}

const testing = std.testing;

test "BIP 39's own vectors" {
    var out: [24][]const u8 = undefined;
    const zeros: [16]u8 = @splat(0);
    const first = try std.mem.join(testing.allocator, " ", encode(&zeros, &out));
    defer testing.allocator.free(first);
    try testing.expectEqualStrings(
        "abandon abandon abandon abandon abandon abandon " ++
            "abandon abandon abandon abandon abandon about",
        first,
    );
    const ff: [32]u8 = @splat(0xff);
    const phrase = try std.mem.join(testing.allocator, " ", encode(&ff, &out));
    defer testing.allocator.free(phrase);
    try testing.expectEqualStrings(
        "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo " ++
            "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
        phrase,
    );
    var back: [32]u8 = undefined;
    try decode(phrase, &back);
    try testing.expectEqualSlices(u8, &ff, &back);
}

test "round trip, short forms, and mistakes" {
    var seed: [32]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i * 7 + 3);
    var out: [24][]const u8 = undefined;
    const list = encode(&seed, &out);
    const phrase = try std.mem.join(testing.allocator, " ", list);
    defer testing.allocator.free(phrase);
    var back: [32]u8 = undefined;
    try decode(phrase, &back);
    try testing.expectEqualSlices(u8, &seed, &back);
    // The first four letters, in capitals.
    var short: std.ArrayList(u8) = .empty;
    defer short.deinit(testing.allocator);
    for (list) |w| {
        for (w[0..@min(4, w.len)]) |c| try short.append(testing.allocator, std.ascii.toUpper(c));
        try short.append(testing.allocator, ' ');
    }
    try decode(short.items, &back);
    try testing.expectEqualSlices(u8, &seed, &back);
    // A swapped word fails the checksum (almost always; this one does).
    const swapped = try std.mem.replaceOwned(u8, testing.allocator, phrase, list[0], list[1]);
    defer testing.allocator.free(swapped);
    try testing.expectError(error.BadChecksum, decode(swapped, &back));
    try testing.expectError(error.UnknownWord, decode("notaword", &back));
    try testing.expectError(error.WrongLength, decode("abandon about", &back));
}
