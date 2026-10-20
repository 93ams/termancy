//! Encrypted configuration files, for secrets kept in a repository: XChaCha20-Poly1305
//! with a key derived from a passphrase by Argon2id, all from `std.crypto`.
//!
//! The envelope is text, one header line and base64 lines, so it sits in a repository like
//! any file:
//!
//! ```text
//! termancy-encrypted v1 argon2id t=3 m=65536 p=1 format=toml
//! <base64 of: 16-byte salt, 24-byte nonce, ciphertext, 16-byte tag; 64 columns a line>
//! ```
//!
//! The header line is authenticated with the ciphertext, so changing the parameters or the
//! format makes decryption fail rather than misread. The costs are paid before that check,
//! so they are bounded (`Params`): a file from elsewhere cannot take all memory, or hours.
//! `Config.usePassphrase` lets `Config.loadFile` read such a file directly; `app.toml.enc`
//! is a TOML file encrypted.
//!
//! What is wiped: the derived key, always, and the plaintext buffer when decryption fails.
//! The plaintext `decrypt` returns belongs to the caller, who should `secureZero` it once
//! done with it, as `Config.loadFile` does after parsing. What is not: the values parsed
//! from it (they are the configuration), copies a parser made on the way (unescaped
//! strings), and Argon2's working memory, all in the arena given; an arena does not wipe
//! what it frees. A process that must not keep secrets in memory after use should give
//! these an allocator that zeroes on free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Format = @import("format.zig").Format;

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const argon2 = std.crypto.pwhash.argon2;
const base64 = std.base64.standard;

/// The first word of every envelope.
pub const magic = "termancy-encrypted";

/// Argon2id costs. The defaults follow the RFC 9106 second recommendation: 64 MiB, three
/// passes, which takes a fraction of a second. At most 1 GiB, 16 lanes, and `t * m` at
/// most four passes over 1 GiB: an envelope asking for more is refused (`WeakParameters`)
/// before any of it is paid, and `encrypt` refuses the same, so what it writes can be read.
pub const Params = struct {
    /// Passes over memory.
    t: u32 = 3,
    /// Memory, in KiB.
    m: u32 = 64 * 1024,
    /// Lanes.
    p: u24 = 1,

    const max_m = 1024 * 1024;
    const max_work = 4 * max_m;
    const max_p = 16;
};

/// What encrypting and decrypting can fail with.
pub const Error = error{
    /// The text is not an envelope.
    NotEncrypted,
    /// An envelope of a version, cipher, or format this code does not know.
    Unsupported,
    /// The envelope's body is not valid base64 or is too short.
    Corrupt,
    /// The passphrase is wrong, or the envelope was changed.
    WrongPassphrase,
    /// The Argon2 parameters are out of range, or memory for them is not available.
    WeakParameters,
    /// The system has no secure random numbers to give.
    EntropyUnavailable,
    /// `encrypt` was given an empty passphrase, which protects nothing.
    EmptyPassphrase,
} || Allocator.Error;

const salt_len = 16;
const key_len = Aead.key_length;
const nonce_len = Aead.nonce_length;
const tag_len = Aead.tag_length;

/// Whether `text` is an envelope, as opposed to plain configuration.
pub fn isEncrypted(text: []const u8) bool {
    return std.mem.startsWith(u8, text, magic ++ " ");
}

/// Encrypts `plaintext`, configuration in `format`, into a new envelope in `arena`.
pub fn encrypt(
    arena: Allocator,
    io: Io,
    plaintext: []const u8,
    passphrase: []const u8,
    format: Format,
    params: Params,
) Error![]const u8 {
    if (passphrase.len == 0) return error.EmptyPassphrase;
    const header = try std.fmt.allocPrint(arena, "{s} v1 argon2id t={d} m={d} p={d} format={t}", .{
        magic, params.t, params.m, params.p, format,
    });
    var salt: [salt_len]u8 = undefined;
    var nonce: [nonce_len]u8 = undefined;
    io.randomSecure(&salt) catch return error.EntropyUnavailable;
    io.randomSecure(&nonce) catch return error.EntropyUnavailable;
    var key: [key_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(arena, io, &key, passphrase, &salt, params);

    const body = try arena.alloc(u8, salt_len + nonce_len + plaintext.len + tag_len);
    @memcpy(body[0..salt_len], &salt);
    @memcpy(body[salt_len..][0..nonce_len], &nonce);
    const ciphertext = body[salt_len + nonce_len ..][0..plaintext.len];
    const tag = body[body.len - tag_len ..][0..tag_len];
    Aead.encrypt(ciphertext, tag, plaintext, header, nonce, key);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, header);
    try out.append(arena, '\n');
    const encoded = try arena.alloc(u8, base64.Encoder.calcSize(body.len));
    _ = base64.Encoder.encode(encoded, body);
    var rest: []const u8 = encoded;
    while (rest.len > 0) {
        const line = rest[0..@min(64, rest.len)];
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
        rest = rest[line.len..];
    }
    return out.items;
}

/// What `decrypt` returns: the text and the format it names.
pub const Decrypted = struct {
    /// Mutable, so the caller can `std.crypto.secureZero` it when done.
    plaintext: []u8,
    format: Format,
};

/// Decrypts an envelope made by `encrypt`, into `arena`. Wipe the plaintext when done with
/// it.
pub fn decrypt(
    arena: Allocator,
    io: Io,
    envelope: []const u8,
    passphrase: []const u8,
) Error!Decrypted {
    if (!isEncrypted(envelope)) return error.NotEncrypted;
    const header_end = std.mem.indexOfScalar(u8, envelope, '\n') orelse return error.Corrupt;
    const header = std.mem.trimEnd(u8, envelope[0..header_end], "\r");
    const parsed = try parseHeader(header);

    var encoded: std.ArrayList(u8) = .empty;
    for (envelope[header_end + 1 ..]) |c| {
        if (c != '\n' and c != '\r' and c != ' ') try encoded.append(arena, c);
    }
    const size = base64.Decoder.calcSizeForSlice(encoded.items) catch return error.Corrupt;
    if (size < salt_len + nonce_len + tag_len) return error.Corrupt;
    const body = try arena.alloc(u8, size);
    base64.Decoder.decode(body, encoded.items) catch return error.Corrupt;

    const salt = body[0..salt_len];
    const nonce = body[salt_len..][0..nonce_len].*;
    const ciphertext = body[salt_len + nonce_len .. body.len - tag_len];
    const tag = body[body.len - tag_len ..][0..tag_len].*;
    var key: [key_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(arena, io, &key, passphrase, salt, parsed.params);
    const plaintext = try arena.alloc(u8, ciphertext.len);
    Aead.decrypt(plaintext, ciphertext, tag, header, nonce, key) catch {
        // Unauthenticated bytes are not handed out, nor left behind.
        std.crypto.secureZero(u8, plaintext);
        return error.WrongPassphrase;
    };
    return .{ .plaintext = plaintext, .format = parsed.format };
}

/// What an envelope's first line says.
pub const Header = struct {
    params: Params,
    format: Format,
};

/// Reads an envelope's first line, without its line ending. `decrypt` calls it; it is
/// public so a fuzzer can see an envelope's costs before paying them.
pub fn parseHeader(header: []const u8) Error!Header {
    var words = std.mem.tokenizeScalar(u8, header, ' ');
    if (!std.mem.eql(u8, words.next() orelse "", magic)) return error.NotEncrypted;
    if (!std.mem.eql(u8, words.next() orelse "", "v1")) return error.Unsupported;
    if (!std.mem.eql(u8, words.next() orelse "", "argon2id")) return error.Unsupported;
    var params: Params = .{};
    var format: ?Format = null;
    while (words.next()) |word| {
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse return error.Corrupt;
        const name = word[0..eq];
        const value = word[eq + 1 ..];
        if (std.mem.eql(u8, name, "t")) {
            params.t = std.fmt.parseInt(u32, value, 10) catch return error.Corrupt;
        } else if (std.mem.eql(u8, name, "m")) {
            params.m = std.fmt.parseInt(u32, value, 10) catch return error.Corrupt;
        } else if (std.mem.eql(u8, name, "p")) {
            params.p = std.fmt.parseInt(u24, value, 10) catch return error.Corrupt;
        } else if (std.mem.eql(u8, name, "format")) {
            format = Format.fromName(value) orelse return error.Unsupported;
        } else return error.Unsupported;
    }
    return .{ .params = params, .format = format orelse return error.Corrupt };
}

fn deriveKey(
    arena: Allocator,
    io: Io,
    key: *[key_len]u8,
    passphrase: []const u8,
    salt: []const u8,
    params: Params,
) Error!void {
    const work = @as(u64, params.t) * params.m;
    if (params.m > Params.max_m or params.p > Params.max_p or work > Params.max_work) {
        return error.WeakParameters;
    }
    const argon_params: argon2.Params = .{ .t = params.t, .m = params.m, .p = params.p };
    argon2.kdf(arena, key, passphrase, salt, argon_params, .argon2id, io) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.WeakParameters,
        };
    };
}

const testing = std.testing;

/// Cheap costs, so tests run quickly; never use them for real secrets.
const test_params: Params = .{ .t = 1, .m = 64, .p = 1 };

test "encrypt then decrypt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plaintext = "token = \"s3cret\"\n";
    const envelope = try encrypt(a, testing.io, plaintext, "correct horse", .toml, test_params);
    try testing.expect(isEncrypted(envelope));
    const header = "termancy-encrypted v1 argon2id t=1 m=64 p=1 format=toml\n";
    try testing.expect(std.mem.startsWith(u8, envelope, header));
    try testing.expect(std.mem.indexOf(u8, envelope, "s3cret") == null);
    const back = try decrypt(a, testing.io, envelope, "correct horse");
    try testing.expectEqualStrings(plaintext, back.plaintext);
    try testing.expectEqual(Format.toml, back.format);

    try testing.expectError(error.WrongPassphrase, decrypt(a, testing.io, envelope, "wrong"));
    // The header is authenticated: a changed format fails, it does not misread.
    const edited = try std.mem.replaceOwned(u8, a, envelope, "format=toml", "format=json");
    try testing.expectError(error.WrongPassphrase, decrypt(a, testing.io, edited, "correct horse"));
    try testing.expectError(error.NotEncrypted, decrypt(a, testing.io, plaintext, "x"));
    const garbled = "termancy-encrypted v1 argon2id format=toml\n!!";
    try testing.expectError(error.Corrupt, decrypt(a, testing.io, garbled, "x"));
    // Valid base64, but shorter than a salt, a nonce, and a tag.
    const short = "termancy-encrypted v1 argon2id format=toml\nAAAAAAAAAAAAAAAAAAAAAAAA\n";
    try testing.expectError(error.Corrupt, decrypt(a, testing.io, short, "x"));
}

test "each encryption is different" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try encrypt(a, testing.io, "a = 1", "p", .toml, test_params);
    const two = try encrypt(a, testing.io, "a = 1", "p", .toml, test_params);
    try testing.expect(!std.mem.eql(u8, one, two));
}

test "costs past the ceiling are refused before they are paid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A salt, a nonce, and a tag, all zero: the least that reaches key derivation.
    const body: []const u8 = &@as([75]u8, @splat('A')) ++ "=\n";
    for ([_][]const u8{
        "t=4294967295 m=8 p=1", // hours of passes
        "t=1 m=4294967295 p=1", // 4 TiB, which the OOM killer stopped
        "t=1 m=2097152 p=1", // 2 GiB
        "t=5 m=1048576 p=1", // 1 GiB, five times over
        "t=1 m=1048576 p=17", // more lanes than allowed
    }) |costs| {
        const parts = &.{ magic, " v1 argon2id ", costs, " format=toml\n", body };
        const envelope = try std.mem.concat(a, u8, parts);
        try testing.expectError(error.WeakParameters, decrypt(a, testing.io, envelope, "x"));
    }
    const greedy: Params = .{ .t = 1, .m = 2 * Params.max_m };
    const sealed = encrypt(a, testing.io, "a = 1", "p", .toml, greedy);
    try testing.expectError(error.WeakParameters, sealed);
}

test "an empty passphrase is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sealed = encrypt(arena.allocator(), testing.io, "a = 1", "", .toml, test_params);
    try testing.expectError(error.EmptyPassphrase, sealed);
}
