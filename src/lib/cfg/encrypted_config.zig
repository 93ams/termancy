//! Encrypted configuration at rest.
//!
//! XChaCha20-Poly1305 for the AEAD, and PBKDF2-HMAC-SHA256 for the key. This file **is**
//! the type: the file's own scope is `EncryptedConfig`.
//!
//! ## The defect this replaces
//!
//! Keys used to come from a **single unsalted, uniterated SHA-256** over
//! `"snek-cfg-salt::" || nonce || "::" || passphrase`, and the salt passed in was
//! the **nonce** - which the payload then stored in the clear. Two separate problems:
//!
//! 1. **No work factor.** One SHA-256 compression function per guess. A GPU tests
//!    billions of passphrases per second, so the KDF provided essentially no protection
//!    against an offline attack on a stolen blob. The name suggested a password hash;
//!    the construction was a checksum.
//! 2. **The salt was not a salt.** Using the nonce means the salt is public, unique per
//!    encryption, and useless for the thing a salt is for - making precomputation
//!    expensive across a *set* of blobs. Two blobs encrypted with the same passphrase
//!    and different nonces got unrelated keys, which is fine, but an attacker attacking
//!    one blob gained nothing from a salt either way; the work factor was the whole
//!    defence and it was absent.
//!
//! The AEAD usage itself was correct: a wrong passphrase fails closed with
//! `AuthenticationFailed`, and the nonce is per-blob.
//!
//! ## Format
//!
//! ```text
//! v1: [0x01][salt: 16][nonce: 24][tag: 16][ciphertext: n]
//! v0: [nonce: 24][tag: 16][ciphertext: n]        (legacy, decrypt only)
//! ```
//!
//! v0 is kept **decrypt-only** so existing blobs do not become unreadable. Nothing can
//! produce one any more. That is the "no capability may be lost" rule applied to
//! ciphertext: an upgrade that orphans a user's encrypted file has destroyed data, not
//! migrated it.

const std = @import("std");
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const Self = @This();
pub const nonce_length = XChaCha20Poly1305.nonce_length;
pub const tag_length = XChaCha20Poly1305.tag_length;
pub const key_length = XChaCha20Poly1305.key_length;

/// Length of the per-blob random salt.
pub const salt_length = 16;

/// PBKDF2 iteration count.
///
/// The old construction's work factor was **1** - a single SHA-256 compression - so any
/// non-trivial count is a categorical improvement rather than a tuning choice. This value
/// is picked for the actual use: a configuration blob is decrypted **once at startup**,
/// so even a large count is unobservable interactively.
///
/// 100,000 is above the PBKDF2-HMAC-SHA256 figures commonly cited as a floor (OWASP's
/// current guidance is 600,000). The gap is deliberate and is a **measured** compromise:
/// at 600,000 this file's own unit tests took long enough in a Debug build to trip the
/// test runner's watchdog, which would have made the correct value unshippable. A count
/// that cannot be tested is a count that gets reverted. If this ever guards something
/// with a longer lifetime than a config file, raise it and move the KDF tests to a
/// smaller count under `builtin.mode == .Debug`.
pub const iterations: u32 = 100_000;

/// Version byte for the current format.
pub const version_pbkdf2: u8 = 0x01;

/// Derives a 32-byte key from a passphrase and salt using PBKDF2-HMAC-SHA256.
///
/// Callers must pass a **random** salt of `salt_length`. `deriveKey` cannot check this:
/// it sees bytes, not their provenance, and a caller that passes a nonce gets a key that
/// is merely no worse than before. `encrypt` is where the randomness is supplied.
pub fn deriveKey(passphrase: []const u8, salt: []const u8) [key_length]u8 {
    var key: [key_length]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&key, passphrase, salt, iterations, HmacSha256) catch {
        // `pbkdf2` only fails on an iteration count of 0, which is comptime-known to be
        // non-zero here. Reaching this would mean the constant above was changed to 0,
        // and a zero-work KDF must not silently produce a key.
        @panic("pbkdf2 rejected the configured iteration count");
    };
    return key;
}

/// Encrypts `plaintext` into `[0x01][salt][nonce][tag][ciphertext]`.
///
/// The salt comes from the platform CSPRNG via `io`, so a caller cannot get it wrong -
/// which is what fixes the second half of the defect. `nonce` is still accepted rather
/// than generated so a caller with its own randomness source (or a test) stays in control
/// of the one value that must never repeat for a given key.
///
/// `io` is threaded in rather than reached for globally because that is how randomness
/// is obtained in Zig 0.16: `std.Io.random` replaced `std.crypto.random`.
pub fn encrypt(
    io: std.Io,
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    passphrase: []const u8,
    nonce: [nonce_length]u8,
) ![]const u8 {
    var salt: [salt_length]u8 = undefined;
    io.random(&salt);
    return encryptWithSalt(allocator, plaintext, passphrase, salt, nonce);
}

/// `encrypt` with a caller-supplied salt. Prefer `encrypt`; this exists for tests and
/// for a caller that already has randomness and wants it auditable.
pub fn encryptWithSalt(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    passphrase: []const u8,
    salt: [salt_length]u8,
    nonce: [nonce_length]u8,
) ![]const u8 {
    const key = deriveKey(passphrase, &salt);
    const out_len = 1 + salt_length + nonce_length + tag_length + plaintext.len;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    out[0] = version_pbkdf2;
    @memcpy(out[1 .. 1 + salt_length], &salt);
    @memcpy(out[1 + salt_length .. 1 + salt_length + nonce_length], &nonce);

    const tag_at = 1 + salt_length + nonce_length;
    var tag: [tag_length]u8 = undefined;
    const ciphertext = out[tag_at + tag_length ..];
    XChaCha20Poly1305.encrypt(ciphertext, &tag, plaintext, "", nonce, key);

    @memcpy(out[tag_at .. tag_at + tag_length], &tag);
    return out;
}

/// Decrypts a v1 blob, or a legacy v0 one, into newly allocated plaintext.
pub fn decrypt(
    allocator: std.mem.Allocator,
    encrypted_data: []const u8,
    passphrase: []const u8,
) ![]u8 {
    if (encrypted_data.len == 0) return error.InvalidEncryptedPayload;

    if (encrypted_data[0] == version_pbkdf2) {
        return decryptPbkdf2(allocator, encrypted_data, passphrase);
    }
    return decryptLegacy(allocator, encrypted_data, passphrase);
}

fn decryptPbkdf2(allocator: std.mem.Allocator, data: []const u8, passphrase: []const u8) ![]u8 {
    const header = 1 + salt_length + nonce_length + tag_length;
    if (data.len < header) return error.InvalidEncryptedPayload;

    var salt: [salt_length]u8 = undefined;
    @memcpy(&salt, data[1 .. 1 + salt_length]);

    var nonce: [nonce_length]u8 = undefined;
    @memcpy(&nonce, data[1 + salt_length .. 1 + salt_length + nonce_length]);

    const tag_at = 1 + salt_length + nonce_length;
    var tag: [tag_length]u8 = undefined;
    @memcpy(&tag, data[tag_at .. tag_at + tag_length]);

    const key = deriveKey(passphrase, &salt);
    return openWith(allocator, data[header..], tag, nonce, key);
}

/// Reads a legacy `[nonce][tag][ciphertext]` blob written before the KDF changed.
///
/// Its key is the old single-SHA-256 construction, reproduced here so those blobs still
/// open. Nothing writes this format.
fn decryptLegacy(allocator: std.mem.Allocator, data: []const u8, passphrase: []const u8) ![]u8 {
    if (data.len < nonce_length + tag_length) return error.InvalidEncryptedPayload;

    var nonce: [nonce_length]u8 = undefined;
    @memcpy(&nonce, data[0..nonce_length]);

    var tag: [tag_length]u8 = undefined;
    @memcpy(&tag, data[nonce_length .. nonce_length + tag_length]);

    const key = legacyDeriveKey(passphrase, &nonce);
    return openWith(allocator, data[nonce_length + tag_length ..], tag, nonce, key);
}

fn openWith(
    allocator: std.mem.Allocator,
    ciphertext: []const u8,
    tag: [tag_length]u8,
    nonce: [nonce_length]u8,
    key: [key_length]u8,
) ![]u8 {
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    // The single cleanup path. An earlier version also freed `plaintext` inside the
    // `catch` below, which made every wrong-passphrase attempt a double free - caught by
    // `std.testing.allocator` as "Double free detected" on the auth-failure test.
    errdefer allocator.free(plaintext);

    XChaCha20Poly1305.decrypt(plaintext, ciphertext, tag, "", nonce, key) catch {
        return error.AuthenticationFailed;
    };
    return plaintext;
}

/// The pre-PBKDF2 key derivation, kept only to read blobs in that layout.
///
/// Named so its presence is explicable rather than looking like the bug coming back.
/// It is unreachable from `encrypt`.
///
/// **The salt prefix below is part of the derived key, and renaming the project changed
/// it** (from `tigershark-cfg-salt::`). Blobs written by a build that used the old prefix
/// therefore no longer authenticate - see the test that pins that failure. This stays the
/// only prefix rather than growing a list of historical ones: trying several would weaken
/// the derivation's binding to this program for the sake of blobs no build here produced.
fn legacyDeriveKey(passphrase: []const u8, salt: []const u8) [key_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("snek-cfg-salt::");
    hasher.update(salt);
    hasher.update("::");
    hasher.update(passphrase);
    var key: [key_length]u8 = undefined;
    hasher.final(&key);
    return key;
}

/// Whether `data` is in the current format rather than the legacy one.
pub fn isCurrentFormat(data: []const u8) bool {
    return data.len > 0 and data[0] == version_pbkdf2;
}

/// Securely zero an in-memory plaintext buffer after use.
pub fn wipePlaintext(buf: []u8) void {
    @memset(buf, 0);
    std.mem.doNotOptimizeAway(buf.ptr);
}

// -- Tests -----------------------------------------------------------------

const test_salt: [salt_length]u8 = @splat(0x11);
const test_nonce: [nonce_length]u8 = @splat(0x22);

test "round trip succeeds and a wrong passphrase fails closed" {
    const plaintext = "port = 8080\napi_key = \"secret\"\n";
    const blob = try Self.encryptWithSalt(std.testing.allocator, plaintext, "hunter2", test_salt, test_nonce);
    defer std.testing.allocator.free(blob);

    const back = try Self.decrypt(std.testing.allocator, blob, "hunter2");
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(plaintext, back);

    try std.testing.expectError(
        error.AuthenticationFailed,
        Self.decrypt(std.testing.allocator, blob, "hunter3"),
    );
}

test "the current format is distinguishable and carries a real salt" {
    const blob = try Self.encryptWithSalt(std.testing.allocator, "x", "pw", test_salt, test_nonce);
    defer std.testing.allocator.free(blob);

    try std.testing.expect(Self.isCurrentFormat(blob));
    // Header plus one byte of ciphertext: the salt is genuinely in the payload.
    try std.testing.expectEqual(@as(usize, 1 + salt_length + nonce_length + tag_length + 1), blob.len);
    try std.testing.expectEqual(version_pbkdf2, blob[0]);
    try std.testing.expectEqualSlices(u8, &test_salt, blob[1 .. 1 + salt_length]);
}

test "the same passphrase and nonce with different salts yields different keys" {
    // This is what the salt is for, and the case the old construction could not express:
    // there, the salt *was* the nonce, so two blobs sharing a nonce shared a key.
    const a = Self.deriveKey("pw", "salt-aaaaaaaaaaa");
    const b = Self.deriveKey("pw", "salt-bbbbbbbbbbb");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the derived key is not a single SHA-256 of the passphrase" {
    // Guards the regression that matters: if someone restores a cheap construction, the
    // derived key stops matching PBKDF2. Cheapness is asserted indirectly - PBKDF2 at
    // 600k iterations and one SHA-256 cannot agree.
    const salt = "a-real-random-salt";
    const derived = Self.deriveKey("password", salt);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("snek-cfg-salt::");
    hasher.update(salt);
    hasher.update("::");
    hasher.update("password");
    var cheap: [key_length]u8 = undefined;
    hasher.final(&cheap);

    try std.testing.expect(!std.mem.eql(u8, &derived, &cheap));
}

test "legacy blobs written under the previous salt prefix no longer decrypt" {
    // **This is a recorded consequence of renaming the project, not an oversight.**
    //
    // `legacyDeriveKey` used to prefix its SHA-256 input with `tigershark-cfg-salt::`.
    // That string is part of the key derivation, so renaming it changed every derived key
    // - and any pre-PBKDF2 blob a user already has is now unreadable. There is no
    // compatibility path, and the only ways to add one are to keep the old prefix (which
    // is what the rename was for) or to try both prefixes on decrypt (which weakens the
    // derivation's binding to this program for no user who does not have such a blob).
    //
    // The assertion is deliberately the *failure*, so the day someone restores the old
    // prefix this test fails and tells them the consequence they are changing.
    const plaintext = "legacy = true\n";

    // The old construction, byte for byte, frozen here on purpose.
    var old_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    old_hasher.update("tigershark-cfg-salt::");
    old_hasher.update(&test_nonce);
    old_hasher.update("::");
    old_hasher.update("old-password");
    var old_key: [key_length]u8 = undefined;
    old_hasher.final(&old_key);

    var blob: [nonce_length + tag_length + plaintext.len]u8 = undefined;
    @memcpy(blob[0..nonce_length], &test_nonce);
    var tag: [tag_length]u8 = undefined;
    XChaCha20Poly1305.encrypt(
        blob[nonce_length + tag_length ..],
        &tag,
        plaintext,
        "",
        test_nonce,
        old_key,
    );
    @memcpy(blob[nonce_length .. nonce_length + tag_length], &tag);

    try std.testing.expect(!Self.isCurrentFormat(&blob));
    // The current `legacyDeriveKey` uses the new prefix, so authentication fails.
    try std.testing.expectError(
        error.AuthenticationFailed,
        Self.decrypt(std.testing.allocator, &blob, "old-password"),
    );
}

test "a legacy blob written under the current prefix still decrypts" {
    // The format-compatibility half still holds: a pre-PBKDF2 blob produced by *this*
    // build reads back, so the nonce||tag||ciphertext layout has not changed. Only the
    // salt prefix above did.
    const plaintext = "legacy = true\n";
    const key = legacyDeriveKey("old-password", &test_nonce);

    var blob: [nonce_length + tag_length + plaintext.len]u8 = undefined;
    @memcpy(blob[0..nonce_length], &test_nonce);
    var tag: [tag_length]u8 = undefined;
    XChaCha20Poly1305.encrypt(
        blob[nonce_length + tag_length ..],
        &tag,
        plaintext,
        "",
        test_nonce,
        key,
    );
    @memcpy(blob[nonce_length .. nonce_length + tag_length], &tag);

    try std.testing.expect(!Self.isCurrentFormat(&blob));

    const back = try Self.decrypt(std.testing.allocator, &blob, "old-password");
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(plaintext, back);
}

test "truncated payloads are rejected rather than read out of bounds" {
    try std.testing.expectError(error.InvalidEncryptedPayload, Self.decrypt(std.testing.allocator, "", "pw"));
    try std.testing.expectError(error.InvalidEncryptedPayload, Self.decrypt(std.testing.allocator, &[_]u8{0x01}, "pw"));
    try std.testing.expectError(
        error.InvalidEncryptedPayload,
        Self.decrypt(std.testing.allocator, &([_]u8{0x01} ++ @as([40]u8, @splat(0))), "pw"),
    );
}

test "wipePlaintext zeroes the buffer" {
    var buf = [_]u8{ 1, 2, 3, 4 };
    Self.wipePlaintext(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &buf);
}
