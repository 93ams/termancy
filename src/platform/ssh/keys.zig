//! SSH keys: public keys as the protocol sends them (blobs) and as files write them
//! (`ssh-ed25519 AAAA... comment`), their SHA-256 fingerprints, signatures checked for
//! Ed25519, ECDSA P-256, and RSA (SHA-256 and SHA-512); `authorized_keys` files; and
//! Ed25519 key pairs, generated, signed with, and kept in OpenSSH's private key format
//! (optionally under a passphrase: bcrypt-pbkdf and AES-256-CTR, as `ssh-keygen` does).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const wire = @import("wire.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const rsa = std.crypto.Certificate.rsa;
const base64 = std.base64.standard;

pub const Error = error{ InvalidKey, UnsupportedKey, BadSignature } || wire.Error;

/// A public key, as its wire form (the blob); borrowed, not owned.
pub const PublicKey = struct {
    blob: []const u8,
    kind: Kind,

    pub const Kind = enum { ed25519, ecdsa_p256, rsa };

    /// The key in `blob`, checked enough to know its kind; other kinds are unsupported.
    pub fn parse(blob: []const u8) Error!PublicKey {
        var r: wire.Reader = .init(blob);
        const name = try r.string();
        const kind: Kind = if (std.mem.eql(u8, name, "ssh-ed25519")) kind: {
            if ((try r.string()).len != 32) return error.InvalidKey;
            break :kind .ed25519;
        } else if (std.mem.eql(u8, name, "ecdsa-sha2-nistp256")) kind: {
            if (!std.mem.eql(u8, try r.string(), "nistp256")) return error.InvalidKey;
            _ = EcdsaP256.PublicKey.fromSec1(try r.string()) catch return error.InvalidKey;
            break :kind .ecdsa_p256;
        } else if (std.mem.eql(u8, name, "ssh-rsa")) kind: {
            _ = try r.mpint();
            _ = try r.mpint();
            break :kind .rsa;
        } else return error.UnsupportedKey;
        if (!r.done()) return error.InvalidKey;
        return .{ .blob = blob, .kind = kind };
    }

    /// The key's type name, as files write it.
    pub fn algorithm(key: PublicKey) []const u8 {
        return switch (key.kind) {
            .ed25519 => "ssh-ed25519",
            .ecdsa_p256 => "ecdsa-sha2-nistp256",
            .rsa => "ssh-rsa",
        };
    }

    pub fn eql(a: PublicKey, b: PublicKey) bool {
        return std.mem.eql(u8, a.blob, b.blob);
    }

    /// Whether this key accepts signatures made with `algorithm` (RSA keys sign as
    /// `rsa-sha2-256` or `rsa-sha2-512`; SHA-1 `ssh-rsa` signatures are refused).
    pub fn signsAs(key: PublicKey, sig_algorithm: []const u8) bool {
        return switch (key.kind) {
            .rsa => std.mem.eql(u8, sig_algorithm, "rsa-sha2-256") or
                std.mem.eql(u8, sig_algorithm, "rsa-sha2-512"),
            else => std.mem.eql(u8, sig_algorithm, key.algorithm()),
        };
    }

    /// Checks `signature` (its wire form: the algorithm, then the signature) over `data`.
    pub fn verify(key: PublicKey, signature: []const u8, data: []const u8) Error!void {
        var sig: wire.Reader = .init(signature);
        const sig_algorithm = try sig.string();
        if (!key.signsAs(sig_algorithm)) return error.BadSignature;
        const sig_bytes = try sig.string();
        var k: wire.Reader = .init(key.blob);
        _ = try k.string();
        switch (key.kind) {
            .ed25519 => {
                const public = Ed25519.PublicKey.fromBytes((try k.string())[0..32].*) catch
                    return error.InvalidKey;
                if (sig_bytes.len != 64) return error.BadSignature;
                const s: Ed25519.Signature = .fromBytes(sig_bytes[0..64].*);
                s.verify(data, public) catch return error.BadSignature;
            },
            .ecdsa_p256 => {
                _ = try k.string();
                const public = EcdsaP256.PublicKey.fromSec1(try k.string()) catch
                    return error.InvalidKey;
                var parts: wire.Reader = .init(sig_bytes);
                var raw: [64]u8 = @splat(0);
                const r_part = try parts.mpint();
                const s_part = try parts.mpint();
                if (r_part.len > 32 or s_part.len > 32) return error.BadSignature;
                @memcpy(raw[32 - r_part.len .. 32], r_part);
                @memcpy(raw[64 - s_part.len ..], s_part);
                const s: EcdsaP256.Signature = .fromBytes(raw);
                s.verify(data, public) catch return error.BadSignature;
            },
            .rsa => {
                const e = try k.mpint();
                const n = try k.mpint();
                switch (n.len) {
                    inline 128, 256, 384, 512, 768, 1024 => |len| {
                        if (sig_bytes.len > len) return error.BadSignature;
                        var padded: [len]u8 = @splat(0);
                        @memcpy(padded[len - sig_bytes.len ..], sig_bytes);
                        const public = rsa.PublicKey.fromBytes(e, n) catch return error.InvalidKey;
                        const sha512 = std.mem.eql(u8, sig_algorithm, "rsa-sha2-512");
                        (if (sha512)
                            rsa.PKCS1v1_5Signature.verify(
                                len,
                                &padded,
                                data,
                                public,
                                std.crypto.hash.sha2.Sha512,
                            )
                        else
                            rsa.PKCS1v1_5Signature.verify(
                                len,
                                &padded,
                                data,
                                public,
                                std.crypto.hash.sha2.Sha256,
                            )) catch
                            return error.BadSignature;
                    },
                    else => return error.UnsupportedKey,
                }
            },
        }
    }

    /// `SHA256:` and the key's SHA-256 hash in unpadded base64, as `ssh-keygen -l` shows.
    pub fn fingerprint(key: PublicKey, buffer: *[50]u8) []const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key.blob, &digest, .{});
        @memcpy(buffer[0..7], "SHA256:");
        const encoded = std.base64.standard_no_pad.Encoder.encode(buffer[7..], &digest);
        return buffer[0 .. 7 + encoded.len];
    }

    /// Writes the key as a line of `authorized_keys`: its type, the blob in base64, and
    /// the comment when there is one (no newline).
    pub fn writeLine(key: PublicKey, w: *Writer, comment: []const u8) Writer.Error!void {
        try w.print("{s} ", .{key.algorithm()});
        try base64.Encoder.encodeWriter(w, key.blob);
        if (comment.len > 0) try w.print(" {s}", .{comment});
    }
};

/// One line of an `authorized_keys` file.
pub const Authorized = struct {
    key: PublicKey,
    comment: []const u8,
    /// The options before the key (`from="..."`, `command="..."`, `restrict`), unparsed.
    options: []const u8,
};

/// The keys in an `authorized_keys` file (or a single public key file); blank lines,
/// comments, and keys of unsupported types are skipped. Blobs are allocated in `arena`.
pub fn parseAuthorizedKeys(arena: Allocator, text: []const u8) Allocator.Error![]Authorized {
    var list: std.ArrayList(Authorized) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (try parseLine(arena, line)) |entry| try list.append(arena, entry);
    }
    return list.items;
}

/// A public key line: `[options] type base64 [comment]`; null when it holds no supported
/// key.
pub fn parseLine(arena: Allocator, line: []const u8) Allocator.Error!?Authorized {
    // The key type is the first field that names one; options (which may hold quoted
    // spaces) come before it.
    var i: usize = 0;
    var options_end: usize = 0;
    while (i < line.len) {
        // Tabs separate fields too; a field that stopped at one must not stop the scan.
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const start = i;
        var quoted = false;
        while (i < line.len and (quoted or (line[i] != ' ' and line[i] != '\t'))) : (i += 1) {
            if (line[i] == '"') quoted = !quoted;
        }
        const field = line[start..i];
        if (isKeyType(field)) {
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            const data_start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
            const data = line[data_start..i];
            const size = base64.Decoder.calcSizeForSlice(data) catch return null;
            const blob = try arena.alloc(u8, size);
            base64.Decoder.decode(blob, data) catch return null;
            const key = PublicKey.parse(blob) catch return null;
            if (!std.mem.eql(u8, key.algorithm(), field)) return null;
            return .{
                .key = key,
                .comment = std.mem.trim(u8, line[i..], " \t"),
                .options = std.mem.trim(u8, line[0..options_end], " "),
            };
        }
        options_end = i;
    }
    return null;
}

fn isKeyType(field: []const u8) bool {
    return std.mem.startsWith(u8, field, "ssh-") or std.mem.startsWith(u8, field, "ecdsa-sha2-") or
        std.mem.startsWith(u8, field, "sk-");
}

/// An Ed25519 key pair: host keys, and the keys `snek ssh keygen` makes.
pub const KeyPair = struct {
    inner: Ed25519.KeyPair,

    pub fn generate(io: Io) KeyPair {
        return .{ .inner = .generate(io) };
    }

    /// The key pair a 32-byte seed makes (the same seed, the same keys).
    pub fn fromSeed(bytes: [32]u8) KeyPair {
        return .{ .inner = Ed25519.KeyPair.generateDeterministic(bytes) catch unreachable };
    }

    pub fn seed(kp: KeyPair) [32]u8 {
        return kp.inner.secret_key.seed();
    }

    /// The public key's blob.
    pub fn publicBlob(kp: KeyPair) [51]u8 {
        var out: [51]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], 11, .big);
        @memcpy(out[4..15], "ssh-ed25519");
        std.mem.writeInt(u32, out[15..19], 32, .big);
        @memcpy(out[19..51], &kp.inner.public_key.toBytes());
        return out;
    }

    /// Signs `data`; the signature's wire form.
    pub fn sign(kp: KeyPair, data: []const u8) [83]u8 {
        const s = kp.inner.sign(data, null) catch unreachable;
        var out: [83]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], 11, .big);
        @memcpy(out[4..15], "ssh-ed25519");
        std.mem.writeInt(u32, out[15..19], 64, .big);
        @memcpy(out[19..83], &s.toBytes());
        return out;
    }

    /// Writes the private key in OpenSSH's format (`-----BEGIN OPENSSH PRIVATE KEY-----`),
    /// encrypted under `passphrase` when it is not empty (bcrypt-pbkdf with `rounds`, and
    /// AES-256-CTR).
    pub fn writePrivate(
        kp: KeyPair,
        gpa: Allocator,
        io: Io,
        w: *Writer,
        comment: []const u8,
        passphrase: []const u8,
        rounds: u32,
    ) (Writer.Error || Allocator.Error)!void {
        const encrypted = passphrase.len > 0;
        var salt: [16]u8 = undefined;
        if (encrypted) io.random(&salt);
        var check: [4]u8 = undefined;
        io.random(&check);
        const blob = kp.publicBlob();

        var private: wire.Builder = .init(gpa);
        defer private.deinit();
        try private.raw(&check);
        try private.raw(&check);
        try private.string("ssh-ed25519");
        try private.string(blob[19..51]);
        try private.string(&kp.inner.secret_key.toBytes());
        try private.string(comment);
        const block: usize = if (encrypted) 16 else 8;
        var pad: u8 = 1;
        while (private.bytes().len % block != 0) : (pad += 1) try private.byte(pad);
        if (encrypted) {
            var key_iv: [48]u8 = undefined;
            std.crypto.pwhash.bcrypt.opensshKdf(passphrase, &salt, &key_iv, rounds) catch
                unreachable;
            aesCtr(key_iv[0..32].*, key_iv[32..48].*, private.list.items);
        }

        var whole: wire.Builder = .init(gpa);
        defer whole.deinit();
        try whole.raw("openssh-key-v1\x00");
        try whole.string(if (encrypted) "aes256-ctr" else "none");
        try whole.string(if (encrypted) "bcrypt" else "none");
        if (encrypted) {
            var kdf: wire.Builder = .init(gpa);
            defer kdf.deinit();
            try kdf.string(&salt);
            try kdf.int(rounds);
            try whole.string(kdf.bytes());
        } else try whole.string("");
        try whole.int(1);
        try whole.string(&blob);
        try whole.string(private.bytes());

        const encoded = try gpa.alloc(u8, base64.Encoder.calcSize(whole.bytes().len));
        defer gpa.free(encoded);
        _ = base64.Encoder.encode(encoded, whole.bytes());
        try w.writeAll("-----BEGIN OPENSSH PRIVATE KEY-----\n");
        var i: usize = 0;
        while (i < encoded.len) : (i += 70)
            try w.print("{s}\n", .{encoded[i..@min(encoded.len, i + 70)]});
        try w.writeAll("-----END OPENSSH PRIVATE KEY-----\n");
    }

    pub const ReadError = error{ InvalidKey, UnsupportedKey, WrongPassphrase, PassphraseNeeded } ||
        Allocator.Error;

    /// Reads an Ed25519 private key in OpenSSH's format, decrypting it with `passphrase`
    /// when it is encrypted. The comment, when wanted, is copied into `arena`.
    pub fn readPrivate(
        gpa: Allocator,
        text: []const u8,
        passphrase: []const u8,
        comment: ?*[]const u8,
        arena: Allocator,
    ) ReadError!KeyPair {
        const begin = "-----BEGIN OPENSSH PRIVATE KEY-----";
        const end = "-----END OPENSSH PRIVATE KEY-----";
        const start = (std.mem.indexOf(u8, text, begin) orelse return error.InvalidKey) + begin.len;
        const stop = std.mem.indexOfPos(u8, text, start, end) orelse return error.InvalidKey;
        var compact: std.ArrayList(u8) = .empty;
        defer compact.deinit(gpa);
        for (text[start..stop]) |c| if (!std.ascii.isWhitespace(c)) try compact.append(gpa, c);
        const decoded_len = base64.Decoder.calcSizeForSlice(compact.items) catch
            return error.InvalidKey;
        const decoded = try gpa.alloc(u8, decoded_len);
        defer {
            std.crypto.secureZero(u8, decoded);
            gpa.free(decoded);
        }
        base64.Decoder.decode(decoded, compact.items) catch return error.InvalidKey;
        const magic = "openssh-key-v1\x00";
        if (!std.mem.startsWith(u8, decoded, magic)) return error.InvalidKey;
        var r: wire.Reader = .init(decoded[magic.len..]);
        return readSections(&r, passphrase, comment, arena) catch |err| switch (err) {
            error.Malformed => error.InvalidKey,
            else => |e| e,
        };
    }

    fn readSections(
        r: *wire.Reader,
        passphrase: []const u8,
        comment: ?*[]const u8,
        arena: Allocator,
    ) (ReadError || wire.Error)!KeyPair {
        const cipher = try r.string();
        const kdf = try r.string();
        const kdf_options = try r.string();
        if (try r.int() != 1) return error.UnsupportedKey;
        _ = try r.string();
        const sealed = try r.string();
        // The private section is decrypted in place: `decoded` is the caller's copy.
        const private: []u8 = @constCast(sealed);
        if (std.mem.eql(u8, cipher, "aes256-ctr")) {
            if (!std.mem.eql(u8, kdf, "bcrypt")) return error.UnsupportedKey;
            if (passphrase.len == 0) return error.PassphraseNeeded;
            var options: wire.Reader = .init(kdf_options);
            const salt = try options.string();
            const rounds = try options.int();
            var key_iv: [48]u8 = undefined;
            std.crypto.pwhash.bcrypt.opensshKdf(passphrase, salt, &key_iv, rounds) catch
                return error.InvalidKey;
            aesCtr(key_iv[0..32].*, key_iv[32..48].*, private);
        } else if (!std.mem.eql(u8, cipher, "none")) return error.UnsupportedKey;
        var p: wire.Reader = .init(private);
        if (try p.int() != try p.int()) return error.WrongPassphrase;
        if (!std.mem.eql(u8, try p.string(), "ssh-ed25519")) return error.UnsupportedKey;
        _ = try p.string();
        const secret = try p.string();
        if (secret.len != 64) return error.InvalidKey;
        if (comment) |c| c.* = try arena.dupe(u8, try p.string());
        const sk = Ed25519.SecretKey.fromBytes(secret[0..64].*) catch return error.InvalidKey;
        return .{ .inner = Ed25519.KeyPair.fromSecretKey(sk) catch return error.InvalidKey };
    }
};

/// Who signed `message`, after checking that `armored` (a `-----BEGIN SSH SIGNATURE-----`
/// block, as `ssh-keygen -Y sign` writes it) signs it in `namespace`. Whether that key is
/// trusted is the caller's to decide (compare `Signer.key` with the keys allowed).
pub fn verifySignedMessage(
    gpa: Allocator,
    armored: []const u8,
    namespace: []const u8,
    message: []const u8,
) (Error || Allocator.Error)!Signer {
    const begin = "-----BEGIN SSH SIGNATURE-----";
    const end = "-----END SSH SIGNATURE-----";
    const start = (std.mem.indexOf(u8, armored, begin) orelse return error.InvalidKey) + begin.len;
    const stop = std.mem.indexOfPos(u8, armored, start, end) orelse return error.InvalidKey;
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(gpa);
    for (armored[start..stop]) |c| if (!std.ascii.isWhitespace(c)) try compact.append(gpa, c);
    const blob_size = base64.Decoder.calcSizeForSlice(compact.items) catch
        return error.InvalidKey;
    const blob = try gpa.alloc(u8, blob_size);
    defer gpa.free(blob);
    base64.Decoder.decode(blob, compact.items) catch return error.InvalidKey;
    if (!std.mem.startsWith(u8, blob, "SSHSIG")) return error.InvalidKey;
    var r: wire.Reader = .init(blob[6..]);
    if (try r.int() != 1) return error.UnsupportedKey;
    const key: PublicKey = try .parse(try r.string());
    if (!std.mem.eql(u8, try r.string(), namespace)) return error.BadSignature;
    const reserved = try r.string();
    const hash_name = try r.string();
    const signature = try r.string();
    var digest_buffer: [64]u8 = undefined;
    const digest = if (std.mem.eql(u8, hash_name, "sha512")) d: {
        std.crypto.hash.sha2.Sha512.hash(message, digest_buffer[0..64], .{});
        break :d digest_buffer[0..64];
    } else if (std.mem.eql(u8, hash_name, "sha256")) d: {
        std.crypto.hash.sha2.Sha256.hash(message, digest_buffer[0..32], .{});
        break :d digest_buffer[0..32];
    } else return error.UnsupportedKey;
    var signed: wire.Builder = .init(gpa);
    defer signed.deinit();
    try signed.raw("SSHSIG");
    try signed.string(namespace);
    try signed.string(reserved);
    try signed.string(hash_name);
    try signed.string(digest);
    try key.verify(signature, signed.bytes());
    var out: Signer = .{ .kind = key.kind, .blob_len = key.blob.len };
    if (key.blob.len <= out.blob.len) @memcpy(out.blob[0..key.blob.len], key.blob);
    return out;
}

/// Signs `message` in `namespace` with `key`, writing the armored signature as
/// `ssh-keygen -Y sign` does (SHA-512 of the message).
pub fn signMessage(
    gpa: Allocator,
    w: *Writer,
    key: KeyPair,
    namespace: []const u8,
    message: []const u8,
) (Writer.Error || Allocator.Error)!void {
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(message, &digest, .{});
    var signed: wire.Builder = .init(gpa);
    defer signed.deinit();
    try signed.raw("SSHSIG");
    try signed.string(namespace);
    try signed.string("");
    try signed.string("sha512");
    try signed.string(&digest);
    const signature = key.sign(signed.bytes());
    var blob: wire.Builder = .init(gpa);
    defer blob.deinit();
    try blob.raw("SSHSIG");
    try blob.int(1);
    try blob.string(&key.publicBlob());
    try blob.string(namespace);
    try blob.string("");
    try blob.string("sha512");
    try blob.string(&signature);
    const encoded = try gpa.alloc(u8, base64.Encoder.calcSize(blob.bytes().len));
    defer gpa.free(encoded);
    _ = base64.Encoder.encode(encoded, blob.bytes());
    try w.writeAll("-----BEGIN SSH SIGNATURE-----\n");
    var i: usize = 0;
    while (i < encoded.len) : (i += 70)
        try w.print("{s}\n", .{encoded[i..@min(encoded.len, i + 70)]});
    try w.writeAll("-----END SSH SIGNATURE-----\n");
}

/// Who signed: the key's kind and its blob (kept when it fits).
pub const Signer = struct {
    kind: PublicKey.Kind,
    blob: [600]u8 = undefined,
    blob_len: usize,

    /// The signing key, when its blob fit (Ed25519, ECDSA, and RSA up to 4096 bits do).
    pub fn key(s: *const Signer) ?PublicKey {
        if (s.blob_len > s.blob.len) return null;
        return .{ .blob = s.blob[0..s.blob_len], .kind = s.kind };
    }
};

fn aesCtr(key: [32]u8, iv: [16]u8, data: []u8) void {
    const ctx = std.crypto.core.aes.Aes256.initEnc(key);
    std.crypto.core.modes.ctr(@TypeOf(ctx), ctx, data, data, iv, .big);
}

const testing = std.testing;

test "Ed25519: sign, verify, fingerprint, line, and back" {
    const kp: KeyPair = .fromSeed(@splat(7));
    const blob = kp.publicBlob();
    const key: PublicKey = try .parse(&blob);
    try testing.expectEqual(PublicKey.Kind.ed25519, key.kind);
    const sig = kp.sign("data");
    try key.verify(&sig, "data");
    try testing.expectError(error.BadSignature, key.verify(&sig, "date"));
    var fp: [50]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, key.fingerprint(&fp), "SHA256:"));
    try testing.expectEqual(50, key.fingerprint(&fp).len);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var line: Writer.Allocating = .init(arena.allocator());
    try key.writeLine(&line.writer, "me@host");
    const text = try std.fmt.allocPrint(
        arena.allocator(),
        "# keys\n\nrestrict,command=\"echo a b\" {s}\nssh-dss AAAA x\n",
        .{line.written()},
    );
    const keys = try parseAuthorizedKeys(arena.allocator(), text);
    try testing.expectEqual(1, keys.len);
    try testing.expect(keys[0].key.eql(key));
    try testing.expectEqualStrings("me@host", keys[0].comment);
    try testing.expectEqualStrings("restrict,command=\"echo a b\"", keys[0].options);
}

test "OpenSSH private keys, plain and under a passphrase" {
    const kp: KeyPair = .fromSeed(@splat(3));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "hunter2" }) |passphrase| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try kp.writePrivate(testing.allocator, testing.io, &out.writer, "a comment", passphrase, 4);
        var comment: []const u8 = "";
        const back = try KeyPair.readPrivate(
            testing.allocator,
            out.written(),
            passphrase,
            &comment,
            arena.allocator(),
        );
        try testing.expectEqualSlices(u8, &kp.seed(), &back.seed());
        try testing.expectEqualStrings("a comment", comment);
        if (passphrase.len > 0) {
            try testing.expectError(error.WrongPassphrase, KeyPair.readPrivate(
                testing.allocator,
                out.written(),
                "wrong",
                null,
                arena.allocator(),
            ));
            try testing.expectError(error.PassphraseNeeded, KeyPair.readPrivate(
                testing.allocator,
                out.written(),
                "",
                null,
                arena.allocator(),
            ));
        }
    }
}

test "keys ssh-keygen made, plain and encrypted" {
    // `ssh-keygen -t ed25519 -N "" -C test`, and `-N pw -a 4 -C enc`.
    const plain =
        \\-----BEGIN OPENSSH PRIVATE KEY-----
        \\b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        \\QyNTUxOQAAACDBF5+KVKFSrQkLoATeopLWMqf+kDFa9LYecB2Imm3SfAAAAIhMrDd9TKw3
        \\fQAAAAtzc2gtZWQyNTUxOQAAACDBF5+KVKFSrQkLoATeopLWMqf+kDFa9LYecB2Imm3SfA
        \\AAAECuELfE+kTsxDBEZfUSz7u5PLSYnRTd0haFbOIlAe7RjMEXn4pUoVKtCQugBN6iktYy
        \\p/6QMVr0th5wHYiabdJ8AAAABHRlc3QB
        \\-----END OPENSSH PRIVATE KEY-----
    ;
    const encrypted =
        \\-----BEGIN OPENSSH PRIVATE KEY-----
        \\b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABA1FnrGB3
        \\/3np3bqPl1R3SdAAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHqCMdxXdQq8vtwH
        \\2TuMI+fsJNWOpHILZedNz4vi/qT7AAAAkKZQbfTCIv5DW7Jg5MO1ELueA1hYNksrJcb1GO
        \\QOJCTWpZxh8vd+84MMz6/0jpzHq/AIP5lbbLcFPXIF58N3CHp0LPyt5RZB+gDfHB+i1ld7
        \\h6SRANJqcL81CiKiabiLwWAb6COBX6T7QZbTw3Tyz0jMf3vdwClDUuQAvU+/WVy0ISllE2
        \\OAAuugpnxBVLx0cg==
        \\-----END OPENSSH PRIVATE KEY-----
    ;
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{
            plain,
            "",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMEXn4pUoVKtCQugBN6iktYyp/6QMVr0th5wHYiabdJ8 test",
        },
        .{
            encrypted,
            "pw",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqCMdxXdQq8vtwH2TuMI+fsJNWOpHILZedNz4vi/qT7 enc",
        },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        var comment: []const u8 = "";
        const kp = try KeyPair.readPrivate(
            testing.allocator,
            case[0],
            case[1],
            &comment,
            arena.allocator(),
        );
        var line: Writer.Allocating = .init(arena.allocator());
        const blob = kp.publicBlob();
        try (try PublicKey.parse(&blob)).writeLine(&line.writer, comment);
        try testing.expectEqualStrings(case[2], line.written());
    }
}

test "sign a message, and check it" {
    const kp: KeyPair = .fromSeed(@splat(9));
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try signMessage(testing.allocator, &out.writer, kp, "file", "hello");
    const signer = try verifySignedMessage(testing.allocator, out.written(), "file", "hello");
    const blob = kp.publicBlob();
    try testing.expectEqualSlices(u8, &blob, signer.key().?.blob);
    try testing.expectError(
        error.BadSignature,
        verifySignedMessage(testing.allocator, out.written(), "file", "bye"),
    );
}

test "signatures ssh-keygen made: ECDSA P-256 and RSA (SHA-512)" {
    // `printf hello > msg; ssh-keygen -Y sign -n file -f <key> msg`.
    const signatures = [_][]const u8{
        \\-----BEGIN SSH SIGNATURE-----
        \\U1NIU0lHAAAAAQAAAGgAAAATZWNkc2Etc2hhMi1uaXN0cDI1NgAAAAhuaXN0cDI1NgAAAE
        \\EEhDJuo4eHGKYoSu9C38rZ1v5PjvOBO9tJ2PEajG818S+shseskmGHKErZqQfeie42BUSS
        \\+T39I1hMk/mPlw0h/wAAAARmaWxlAAAAAAAAAAZzaGE1MTIAAABjAAAAE2VjZHNhLXNoYT
        \\ItbmlzdHAyNTYAAABIAAAAIC3lAJEJ8Ct38oGTRMDKsqsKnJ/eCGZ3hoAKDbJwHOv/AAAA
        \\IE9L2tx9Eo/6ze0dwgtFauqdAHqAuk23bxsNgcgvd8+M
        \\-----END SSH SIGNATURE-----
        ,
        \\-----BEGIN SSH SIGNATURE-----
        \\U1NIU0lHAAAAAQAAARcAAAAHc3NoLXJzYQAAAAMBAAEAAAEBALZ1JVQiEgpVBwsln9Fsu4
        \\r0SSGfy0y9rebv0Wo0FQP4QI3fdGvTAjUgHIttF091NIIG0AInccvZqMGsqv5uQO2LdGJG
        \\hM6M7hb7s1fkFJeZJChJG3dAT0WEG1jgYJiL8Yf7ir5ayQtyIwYDiZTv5qCJNE7G0+8oNv
        \\hk5cUlWRXryLhZdEjRO9TYu9LWJ1cDthzhKcqPejrfPwNQrygtfIvYVKupoU4/Ck8VfJi/
        \\t8fqRnkUJWRXjd3ai1qEWq6mjnE9pUX4yTzXzQy1gRQ7B4JaUqMuiUXs71cEjy8uTV0UMW
        \\2LbNR5VzNRnT7LPlSgFKFiUKwMJM67KazgxKyjWeEAAAAEZmlsZQAAAAAAAAAGc2hhNTEy
        \\AAABFAAAAAxyc2Etc2hhMi01MTIAAAEAdsXSgssqC/3kAKlQrY6VMSEkwQJ4L0BTbZa8p2
        \\F/V8WVBxc+fI6dw+36Dl4Y1SzsbN3cAacT1M2GaMORF0VVxRd29Z/umIYzSrYJD3abEZDC
        \\zObGANkUhMzInahwWj0U+SvAD4oJroxWVeh65xX+98yOgW9ty6pFm63kGLGpy1mBKxw73W
        \\DQY3hBF2dxJ3Bald0Prnv6TmUjCesvUYVQr5Q0pbxMq0jYP7MKAhC5qnxQmH4dGvajbWZD
        \\KI8/0ZQ8Zid1H5uyBKuW+IO0K9UBeYj15kVsow5uq4U3fte7htYyEhKHiATu2pDWANLpy5
        \\Jr/5L5IEk/ZbOVVotA1knehQ==
        \\-----END SSH SIGNATURE-----
        ,
    };
    const kinds = [_]PublicKey.Kind{ .ecdsa_p256, .rsa };
    for (signatures, kinds) |armored, kind| {
        const key = try verifySignedMessage(testing.allocator, armored, "file", "hello");
        try testing.expectEqual(kind, key.kind);
        try testing.expectError(
            error.BadSignature,
            verifySignedMessage(testing.allocator, armored, "file", "hellO"),
        );
        try testing.expectError(
            error.BadSignature,
            verifySignedMessage(testing.allocator, armored, "git", "hello"),
        );
    }
}
