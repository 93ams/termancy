//! Coverage-guided fuzz tests of `sys`'s parsers of untrusted input: SSH's wire types,
//! its transport (packets and the key exchange, from either side), public keys and
//! `authorized_keys` lines, private key files, and SSH signatures; the CBOR that
//! WebAuthn authenticators send, their authenticator data and COSE keys, and their CTAPHID
//! reports and CTAP2 responses; and the WebAuthn JSON relying parties and browsers send.
//!
//! `zig build fuzz --fuzz` (or `--fuzz=100K` for a bounded run) explores them from the seeds
//! below; a plain `zig build fuzz` (and `zig build unit`) replays the seeds and the
//! regressions, so a crash the fuzzer finds becomes a regression test by adding its input.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const wire = @import("ssh/wire.zig");
const transport = @import("ssh/transport.zig");
const keys = @import("ssh/keys.zig");
const cbor = @import("security/cbor.zig");
const webauthn = @import("security/webauthn.zig");
const ctap = @import("security/ctap.zig");

/// The longest input a target reads.
const max_input = 1 << 13;

/// `docs` as fuzzer inputs: each a 4-byte little-endian length, then the bytes, which is
/// how `std.testing.Smith.slice` reads them.
fn inputs(arena: Allocator, docs: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, docs.len);
    for (docs, out) |doc, *entry| {
        const bytes = try arena.alloc(u8, 4 + doc.len);
        std.mem.writeInt(u32, bytes[0..4], @intCast(doc.len), .little);
        @memcpy(bytes[4..], doc);
        entry.* = bytes;
    }
    return out;
}

/// The bytes a target reads, in `testing.allocator`: exactly as long as the input, so that
/// reading past its end is caught.
fn take(smith: *testing.Smith) Allocator.Error![]u8 {
    const buffer = try testing.allocator.alloc(u8, max_input);
    errdefer testing.allocator.free(buffer);
    const len = smith.slice(buffer);
    return testing.allocator.realloc(buffer, len);
}

fn fuzzWith(
    comptime testOne: fn (void, *testing.Smith) anyerror!void,
    docs: []const []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.fuzz({}, testOne, .{ .corpus = try inputs(arena_state.allocator(), docs) });
}

fn hostKey() keys.KeyPair {
    return .fromSeed(@splat(3));
}

// Wire types and public keys.

/// A reader never reads past its end; a public key that parses writes as an
/// `authorized_keys` line that reads back as itself, and checking a signature with it is
/// an error at worst.
fn fuzzKeyBlob(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    var r: wire.Reader = .init(bytes);
    for (bytes) |selector| {
        switch (selector % 5) {
            0 => _ = r.string() catch break,
            1 => _ = r.mpint() catch break,
            2 => _ = r.int() catch break,
            3 => _ = r.boolean() catch break,
            else => _ = r.take(selector / 5) catch break,
        }
        try testing.expect(r.index <= bytes.len);
    }
    _ = wire.negotiate(bytes, &transport.kex_algorithms);

    // The first string is the key, the second the signature, the rest the data.
    var parts: wire.Reader = .init(bytes);
    const blob = parts.string() catch return;
    const signature = parts.string() catch "";
    const key = keys.PublicKey.parse(blob) catch return;
    key.verify(signature, parts.rest()) catch {};
    var fingerprint: [50]u8 = undefined;
    _ = key.fingerprint(&fingerprint);
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    try key.writeLine(&line.writer, "comment");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const back = (try keys.parseLine(arena_state.allocator(), line.written())).?;
    try testing.expectEqualSlices(u8, blob, back.key.blob);
    try testing.expectEqualStrings("comment", back.comment);
}

test "fuzz: ssh key blobs and signatures" {
    const gpa = testing.allocator;
    var b: wire.Builder = .init(gpa);
    defer b.deinit();
    const blob = hostKey().publicBlob();
    try b.string(&blob);
    try b.string(&hostKey().sign("data"));
    try b.raw("data");
    const ed25519 = try gpa.dupe(u8, b.bytes());
    defer gpa.free(ed25519);
    b.list.clearRetainingCapacity();
    try b.string("\x00\x00\x00\x07ssh-rsa\x00\x00\x00\x03\x01\x00\x01\x00\x00\x00\x02\x00\xc1");
    try b.string("\x00\x00\x00\x0crsa-sha2-256\x00\x00\x00\x01\x05");
    const rsa = try gpa.dupe(u8, b.bytes());
    defer gpa.free(rsa);
    try fuzzWith(fuzzKeyBlob, &[_][]const u8{ ed25519, rsa } ++ key_blob_regressions);
}

/// Inputs that once broke the wire reader or the key parser.
const key_blob_regressions = [_][]const u8{};

/// Every key `parseAuthorizedKeys` finds writes back as a line that reads as the same key.
fn fuzzAuthorizedKeys(_: void, smith: *testing.Smith) anyerror!void {
    const text = try take(smith);
    defer testing.allocator.free(text);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (try keys.parseAuthorizedKeys(arena, text)) |entry| {
        var line: std.Io.Writer.Allocating = .init(arena);
        try entry.key.writeLine(&line.writer, "");
        const back = (try keys.parseLine(arena, line.written())).?;
        try testing.expect(back.key.eql(entry.key));
    }
}

test "fuzz: authorized_keys" {
    const gpa = testing.allocator;
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    const blob = hostKey().publicBlob();
    const key: keys.PublicKey = try .parse(&blob);
    try key.writeLine(&line.writer, "ada@host");
    const text = try std.mem.concat(gpa, u8, &.{
        "# comment\n\n",
        line.written(),
        "\nfrom=\"10.0.0.1\",command=\"echo a b\",no-pty ",
        line.written(),
        "\nrestrict ssh-rsa AAAA x\necdsa-sha2-nistp256 AAAAE2VjZHNh\n",
        "sk-ssh-ed25519@openssh.com AAAA\n",
    });
    defer gpa.free(text);
    try fuzzWith(fuzzAuthorizedKeys, &[_][]const u8{text} ++ authorized_regressions);
}

/// Inputs that once broke the `authorized_keys` reader.
const authorized_regressions = [_][]const u8{
    // A tab between fields stopped the scan where it was, forever.
    "from=x\tssh-ed25519 AAAA",
};

// Private keys and signatures.

/// No passphrase is given, so an encrypted key stops before its key derivation (whose cost
/// the file sets) and fuzzing stays fast.
fn fuzzPrivateKey(_: void, smith: *testing.Smith) anyerror!void {
    const text = try take(smith);
    defer testing.allocator.free(text);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var comment: []const u8 = undefined;
    const arena = arena_state.allocator();
    const read = keys.KeyPair.readPrivate(testing.allocator, text, "", &comment, arena);
    _ = read catch |err| switch (err) {
        error.InvalidKey, error.UnsupportedKey, error.WrongPassphrase, error.PassphraseNeeded => {},
        error.OutOfMemory => return err,
    };
}

test "fuzz: openssh private keys" {
    const gpa = testing.allocator;
    var plain: std.Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    try hostKey().writePrivate(gpa, testing.io, &plain.writer, "ada@host", "", 0);
    var sealed: std.Io.Writer.Allocating = .init(gpa);
    defer sealed.deinit();
    try hostKey().writePrivate(gpa, testing.io, &sealed.writer, "", "secret", 1);
    try fuzzWith(fuzzPrivateKey, &[_][]const u8{ plain.written(), sealed.written() } ++
        private_regressions);
}

/// Inputs that once broke the private key reader.
const private_regressions = [_][]const u8{};

/// The input is the namespace's length (one byte), the namespace, the message's length
/// (one byte), the message, then the armored signature.
fn fuzzSignature(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    var r: wire.Reader = .init(bytes);
    const namespace = r.take(r.byte() catch 0) catch "";
    const message = r.take(r.byte() catch 0) catch "";
    const verified = keys.verifySignedMessage(testing.allocator, r.rest(), namespace, message);
    const signer = verified catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    if (signer.key()) |key| _ = try keys.PublicKey.parse(key.blob);
}

test "fuzz: ssh signatures" {
    const gpa = testing.allocator;
    var armored: std.Io.Writer.Allocating = .init(gpa);
    defer armored.deinit();
    try keys.signMessage(gpa, &armored.writer, hostKey(), "file", "hello");
    const seed = try std.mem.concat(gpa, u8, &.{ "\x04file\x05hello", armored.written() });
    defer gpa.free(seed);
    try fuzzWith(fuzzSignature, &[_][]const u8{seed} ++ signature_regressions);
}

/// Inputs that once broke the signature reader.
const signature_regressions = [_][]const u8{};

// The transport.

/// The first byte picks the side; the rest is what the peer sends. Without the peer's
/// keys nothing gets past the first `NEWKEYS`, so this covers the version exchange, the
/// plaintext packets, and the key exchange messages.
fn fuzzTransport(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    if (bytes.len == 0) return;
    var in: std.Io.Reader = .fixed(bytes[1..]);
    var sink: [256]u8 = undefined;
    var out: std.Io.Writer.Discarding = .init(&sink);
    var t: transport.Transport = if (bytes[0] & 1 == 0)
        .init(testing.allocator, testing.io, &in, &out.writer, hostKey(), "SSH-2.0-termancy")
    else
        .initClient(testing.allocator, testing.io, &in, &out.writer, "SSH-2.0-termancy");
    defer t.deinit();
    t.handshake() catch |err| return expectTransportError(err);
    while (true) _ = t.read() catch |err| return expectTransportError(err);
}

fn expectTransportError(err: transport.Error) !void {
    switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }
}

/// A plaintext packet carrying `payload`.
fn packet(b: *wire.Builder, payload: []const u8) !void {
    var padding = 8 - (5 + payload.len) % 8;
    if (padding < 4) padding += 8;
    try b.int(@intCast(1 + payload.len + padding));
    try b.byte(@intCast(padding));
    try b.raw(payload);
    for (0..padding) |_| try b.byte(0);
}

fn kexinit(gpa: Allocator, kex: []const []const u8) ![]u8 {
    var b: wire.Builder = .init(gpa);
    defer b.deinit();
    try b.byte(transport.msg.kexinit);
    try b.raw(&@as([16]u8, @splat(9)));
    try b.names(kex);
    try b.names(&.{"ssh-ed25519"});
    try b.names(&transport.ciphers);
    try b.names(&transport.ciphers);
    try b.names(&.{"hmac-sha2-256"});
    try b.names(&.{"hmac-sha2-256"});
    try b.names(&.{"none"});
    try b.names(&.{"none"});
    try b.names(&.{});
    try b.names(&.{});
    try b.boolean(false);
    try b.int(0);
    return b.list.toOwnedSlice(gpa);
}

test "fuzz: ssh transport" {
    const gpa = testing.allocator;
    const client_init = try kexinit(gpa, &.{
        "curve25519-sha256", "kex-strict-c-v00@openssh.com", "ext-info-c",
    });
    defer gpa.free(client_init);
    const server_init = try kexinit(gpa, &.{
        "mlkem768x25519-sha256", "curve25519-sha256", "kex-strict-s-v00@openssh.com",
    });
    defer gpa.free(server_init);

    // To the server: a banner line, the version, KEXINIT, the client's key, NEWKEYS.
    var to_server: wire.Builder = .init(gpa);
    defer to_server.deinit();
    try to_server.raw("\x00banner\r\nSSH-2.0-OpenSSH_9.9\r\n");
    try packet(&to_server, client_init);
    try packet(&to_server, &[_]u8{transport.msg.kex_init} ++ .{ 0, 0, 0, 32 } ++
        @as([32]u8, @splat(5)));
    try packet(&to_server, &.{transport.msg.newkeys});

    // To the client: the version, KEXINIT, the server's reply (signed wrongly), NEWKEYS.
    var reply: wire.Builder = .init(gpa);
    defer reply.deinit();
    try reply.byte(transport.msg.kex_reply);
    try reply.string(&hostKey().publicBlob());
    try reply.string(&@as([32]u8, @splat(5)));
    try reply.string(&hostKey().sign("not the exchange hash"));
    var to_client: wire.Builder = .init(gpa);
    defer to_client.deinit();
    try to_client.raw("\x01SSH-2.0-OpenSSH_9.9\r\n");
    try packet(&to_client, server_init);
    try packet(&to_client, reply.bytes());
    try packet(&to_client, &.{transport.msg.newkeys});

    try fuzzWith(fuzzTransport, &[_][]const u8{ to_server.bytes(), to_client.bytes() } ++
        transport_regressions);
}

/// Inputs that once broke the transport.
const transport_regressions = [_][]const u8{};

// CBOR.

/// Skipping an item reads no further than the input, a map or array is skipped whole, and a
/// boolean is one byte.
fn fuzzCbor(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    var r: cbor.Reader = .{ .bytes = bytes };
    while (!r.atEnd()) {
        r.skip() catch break;
        try testing.expect(r.pos <= bytes.len);
    }
    var typed: cbor.Reader = .{ .bytes = bytes };
    while (!typed.atEnd()) {
        switch (typed.peek() catch break) {
            .unsigned, .negative => _ = typed.int() catch break,
            .bytes => _ = typed.byteString() catch break,
            .text => _ = typed.textString() catch break,
            .array => _ = typed.array() catch break,
            .map => _ = typed.map() catch break,
            .simple => {
                const at = typed.pos;
                _ = typed.boolean() catch break;
                try testing.expectEqual(at + 1, typed.pos);
            },
            .tag => typed.skip() catch break,
        }
    }
}

test "fuzz: cbor" {
    try fuzzWith(fuzzCbor, &[_][]const u8{
        // {1: "public-key", 3: -7, -1: h'0102', "up": true, [1, [2]]: 0}
        "\xa5\x01\x6apublic-key\x03\x26\x20\x42\x01\x02\x62up\xf5\x82\x01\x81\x02\x00",
        "\x1b\xff\xff\xff\xff\xff\xff\xff\xff\x3b\x7f\xff\xff\xff\xff\xff\xff\xff\xc6\x40",
    } ++ cbor_regressions);
}

/// Inputs that once broke the CBOR reader.
const cbor_regressions = [_][]const u8{
    // A half float whose bits are 21 read as `true`.
    "\xf9\x00\x15",
};

// WebAuthn.

/// Authenticator data: what `attestedCredential` reads covers the input unless the ED flag
/// announces extensions, and a COSE key that reads checks a signature, at worst with an
/// error. The input is tried as a COSE key alone too.
fn fuzzAuthenticatorData(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    _ = webauthn.PublicKey.fromCose(bytes) catch {};
    const data = webauthn.AuthenticatorData.parse(bytes) catch return;
    const attested = webauthn.attestedCredential(bytes) catch return;
    if (!data.flags.extension_data) {
        const read = webauthn.AuthenticatorData.min_len + 18 + attested.id.len +
            attested.public_key.len;
        try testing.expectEqual(bytes.len, read);
    }
    const key = webauthn.PublicKey.fromCose(attested.public_key) catch return;
    webauthn.verifySignature(key, .{
        .raw_id = attested.id,
        .client_data_json = "{}",
        .authenticator_data = bytes,
        .signature = attested.id,
    }) catch {};
}

/// Authenticator data for `example.com` with `flags`, a two-byte credential ID, `key`, and
/// `after` it.
fn authenticatorData(gpa: Allocator, flags: u8, key: []const u8, after: []const u8) ![]u8 {
    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("example.com", &rp_id_hash, .{});
    const aaguid: [16]u8 = @splat(0xaa);
    return std.mem.concat(gpa, u8, &.{
        &rp_id_hash, &.{ flags, 0, 0, 0, 3 }, &aaguid, "\x00\x02id", key, after,
    });
}

test "fuzz: webauthn authenticator data" {
    const gpa = testing.allocator;
    // {1: 1, 3: -8, -1: 6, -2: x}
    const ed25519 = "\xa4\x01\x01\x03\x27\x20\x06\x21\x58\x20" ++ @as([32]u8, @splat(0x09));
    // {1: 2, 3: -7, -1: 1, -2: x, -3: y}, P-256's base point.
    const base = std.crypto.ecc.P256.basePoint.affineCoordinates();
    const es256 = try std.mem.concat(gpa, u8, &.{
        "\xa5\x01\x02\x03\x26\x20\x01\x21\x58\x20", &base.x.toBytes(.big),
        "\x22\x58\x20",                             &base.y.toBytes(.big),
    });
    defer gpa.free(es256);
    const plain = try authenticatorData(gpa, 0x45, ed25519, "");
    defer gpa.free(plain);
    const extended = try authenticatorData(gpa, 0xc5, es256, "\xa1\x6bcredProtect\x02");
    defer gpa.free(extended);
    const unannounced = try authenticatorData(gpa, 0x45, ed25519, "\xa0");
    defer gpa.free(unannounced);
    try fuzzWith(fuzzAuthenticatorData, &[_][]const u8{ plain, extended, es256, unannounced } ++
        authenticator_data_regressions);
}

/// Inputs that once broke the authenticator data or COSE key readers. A credential ID
/// length of 0xffee or more overflowed, but needs more than `max_input` bytes: its test is
/// in `webauthn.zig`.
const authenticator_data_regressions = [_][]const u8{
    // {1: 1, 3: -8, -1: 6, -2: x, -2: x'}: the last x was taken.
    "\xa5\x01\x01\x03\x27\x20\x06\x21\x58\x20" ++ @as([32]u8, @splat(0x09)) ++
        "\x21\x58\x20" ++ @as([32]u8, @splat(0x0a)),
};

fn expectJsonError(err: anyerror) !void {
    if (err == error.OutOfMemory) return err;
}

/// The JSON a relying party sends (request and creation options) and a client returns
/// (an assertion, its client data): each parser reads it or refuses it.
fn fuzzWebauthnJson(_: void, smith: *testing.Smith) anyerror!void {
    const text = try take(smith);
    defer testing.allocator.free(text);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = webauthn.RequestOptions.parseJson(arena, text) catch |err| try expectJsonError(err);
    _ = webauthn.CreationOptions.parseJson(arena, text) catch |err| try expectJsonError(err);
    _ = webauthn.Assertion.parseJson(arena, text) catch |err| try expectJsonError(err);
    webauthn.verifyClientData(arena, text, .{
        .challenge = "0123456789abcdef",
        .origin = "https://example.com",
        .rp_id = "example.com",
    }) catch |err| try expectJsonError(err);
}

test "fuzz: webauthn json" {
    const gpa = testing.allocator;
    var client: std.Io.Writer.Allocating = .init(gpa);
    defer client.deinit();
    const data: webauthn.ClientData = .{
        .challenge = "0123456789abcdef",
        .origin = "https://example.com",
        .cross_origin = true,
    };
    try data.writeJson(&client.writer);
    try fuzzWith(fuzzWebauthnJson, &[_][]const u8{
        client.written(),
        \\{"challenge":"AAAA","rpId":"example.com","timeout":60000,"allowCredentials":[
        \\{"type":"public-key","id":"AA","transports":["usb","smart-card"]}],
        \\"userVerification":"required"}
        ,
        \\{"rp":{"id":"example.com","name":"x"},"user":{"id":"AA","name":"n","displayName":"d"},
        \\"challenge":"AA","pubKeyCredParams":[{"type":"public-key","alg":-7}],
        \\"authenticatorSelection":{"residentKey":"required"}}
        ,
        \\{"id":"AQID","rawId":"AQID","type":"public-key","response":{"clientDataJSON":"e30",
        \\"authenticatorData":"AQ","signature":"AQ","userHandle":"AQ"}}
        ,
    });
}

// CTAP.

/// A key that answers with the input, 64 bytes a report, on the channel's ID unless a
/// report starts with 0xff (another channel's), then times out. What it is sent is lost.
const Replay = struct {
    reports: []const u8,
    cid: u32 = 0x0102_0304,

    fn device(replay: *Replay) ctap.Device {
        return .{ .context = replay, .vtable = &.{ .write = write, .read = read } };
    }

    fn write(_: *anyopaque, _: *const ctap.Report) ctap.Device.Error!void {}

    fn read(context: *anyopaque, report: *ctap.Report, _: u32) ctap.Device.Error!void {
        const replay: *Replay = @ptrCast(@alignCast(context));
        if (replay.reports.len == 0) return error.Timeout;
        const n = @min(replay.reports.len, ctap.report_len);
        report.* = @splat(0);
        @memcpy(report[0..n], replay.reports[0..n]);
        replay.reports = replay.reports[n..];
        if (report[0] != 0xff) std.mem.writeInt(u32, report[0..4], replay.cid, .big);
    }

    fn heard(_: *anyopaque, _: ctap.KeepaliveStatus) void {}
};

/// The first byte picks the command; the rest is what the key answers. Messages split
/// over reports are put back together within `max_payload`, and every response parser
/// reads its answer or refuses it.
fn fuzzCtap(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    if (bytes.len == 0) return;
    var replay: Replay = .{ .reports = bytes[1..] };
    var channel: ctap.Channel = .{ .device = replay.device(), .cid = replay.cid, .io = testing.io };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const protocol: ctap.PinProtocol = if (bytes[0] & 0x80 == 0) .one else .two;
    switch (bytes[0] % 5) {
        0 => _ = ctap.getInfo(arena, &channel) catch |err| return expectJsonError(err),
        1 => _ = ctap.getAssertion(arena, &channel, .{
            .rp_id = "example.com",
            .client_data_hash = @splat(1),
            .allow_list = &.{"id"},
        }, .{ .context = &replay, .function = Replay.heard }) catch |err|
            return expectJsonError(err),
        2 => _ = ctap.getPinRetries(&channel, protocol) catch return,
        3 => _ = ctap.getPinToken(&channel, protocol, "1234") catch return,
        else => {
            var out: [ctap.Channel.max_payload]u8 = undefined;
            const reply = channel.transact(.ping, "", &out, null) catch return;
            try testing.expect(reply.len <= out.len);
        },
    }
}

/// `payload` as the reports of a CTAPHID message of `command`, as a key sends them, after
/// the byte that picks the command.
fn frame(b: *wire.Builder, command: ctap.Command, payload: []const u8) !void {
    var report: ctap.Report = @splat(0);
    report[4] = 0x80 | @as(u8, @backingInt(command));
    std.mem.writeInt(u16, report[5..7], @intCast(payload.len), .big);
    const first = @min(payload.len, ctap.report_len - 7);
    @memcpy(report[7..][0..first], payload[0..first]);
    try b.raw(&report);
    var rest = payload[first..];
    var seq: u8 = 0;
    while (rest.len > 0) : (seq += 1) {
        report = @splat(0);
        report[4] = seq;
        const n = @min(rest.len, ctap.report_len - 5);
        @memcpy(report[5..][0..n], rest[0..n]);
        try b.raw(&report);
        rest = rest[n..];
    }
}

test "fuzz: ctap reports and responses" {
    const gpa = testing.allocator;
    var seeds: [5]wire.Builder = @splat(.init(gpa));
    defer for (&seeds) |*seed| seed.deinit();

    // getInfo: {1: ["FIDO_2_1"], 3: aaguid, 4: {"clientPin": true}, 6: [2, 1]}
    try seeds[0].byte(0);
    try frame(&seeds[0], .cbor, "\x00\xa4\x01\x81\x68FIDO_2_1\x03\x50" ++
        @as([16]u8, @splat(0xaa)) ++ "\x04\xa1\x69clientPin\xf5\x06\x82\x02\x01");

    // getAssertion, after a keepalive and another channel's report, over three reports:
    // {1: {"id": h'6964', "type": "public-key"}, 2: authData, 3: signature, 4: {"id": h'75'}}
    try seeds[1].byte(1);
    try frame(&seeds[1], .keepalive, "\x02");
    try seeds[1].raw(&@as(ctap.Report, @splat(0xff)));
    const authenticator_data = "\x58\x25" ++ @as([32]u8, @splat(0x01)) ++ "\x01\x00\x00\x00\x09";
    try frame(&seeds[1], .cbor, "\x00\xa4\x01\xa2\x62id\x42id\x64type\x6apublic-key\x02" ++
        authenticator_data ++ "\x03\x58\x40" ++ @as([64]u8, @splat(0x05)) ++ "\x04\xa1\x62id\x41u");

    // getPinRetries: {3: 8}
    try seeds[2].byte(2);
    try frame(&seeds[2], .cbor, "\x00\xa1\x03\x08");

    // getPinToken, protocol two: the key's agreement key (P-256's base point), then a token.
    const base = std.crypto.ecc.P256.basePoint.affineCoordinates();
    var agreement: wire.Builder = .init(gpa);
    defer agreement.deinit();
    try agreement.raw("\x00\xa1\x01\xa5\x01\x02\x03\x38\x18\x20\x01\x21\x58\x20");
    try agreement.raw(&base.x.toBytes(.big));
    try agreement.raw("\x22\x58\x20");
    try agreement.raw(&base.y.toBytes(.big));
    try seeds[3].byte(0x80);
    try frame(&seeds[3], .cbor, agreement.bytes());
    try frame(&seeds[3], .cbor, "\x00\xa1\x02\x58\x30" ++ @as([48]u8, @splat(0x07)));

    // A ping's reply.
    try seeds[4].byte(4);
    try frame(&seeds[4], .ping, "pong");

    var docs: [seeds.len][]const u8 = undefined;
    for (&docs, &seeds) |*doc, *seed| doc.* = seed.bytes();
    try fuzzWith(fuzzCtap, &docs ++ ctap_regressions);
}

/// Inputs that once broke the CTAPHID or CTAP2 readers. A reply over 7609 bytes into a
/// larger buffer overflowed the sequence number, but needs more than `max_input` bytes:
/// its test is in `ctap.zig`.
const ctap_regressions = [_][]const u8{
    // getAssertion with the credential {1: "id", h'bb': 0}: h'bb' was taken for its ID.
    "\x01\x00\x00\x00\x00\x90\x00\x0d\x00\xa1\x01\xa2\x01\x62id\x41\xbb\x00\x00\x00",
};
