//! SSH's transport layer (RFC 4253), for either side: the version exchange, binary
//! packets, key exchange, and encryption. Key exchange is `mlkem768x25519-sha256` (post-
//! quantum hybrid, OpenSSH's default since 10.0) or `curve25519-sha256`; a server's host key
//! is Ed25519, and a client checks Ed25519, ECDSA P-256, and RSA host keys; ciphers are
//! `chacha20-poly1305@openssh.com` and `aes256-gcm@openssh.com`. Strict key exchange
//! (`kex-strict-*-v00@openssh.com`, against the Terrapin attack) is on whenever both sides
//! offer it, and the other side may re-key at any time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("wire.zig");
const keys = @import("keys.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const X25519 = std.crypto.dh.X25519;
const MlKem768 = std.crypto.kem.ml_kem.MLKem768;
const ChaCha20 = std.crypto.stream.chacha.ChaCha20With64BitNonce;
const Poly1305 = std.crypto.onetimeauth.Poly1305;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

/// Message numbers.
pub const msg = struct {
    pub const disconnect = 1;
    pub const ignore = 2;
    pub const unimplemented = 3;
    pub const debug = 4;
    pub const service_request = 5;
    pub const service_accept = 6;
    pub const ext_info = 7;
    pub const kexinit = 20;
    pub const newkeys = 21;
    pub const kex_init = 30;
    pub const kex_reply = 31;
    pub const userauth_request = 50;
    pub const userauth_failure = 51;
    pub const userauth_success = 52;
    pub const userauth_banner = 53;
    pub const userauth_pk_ok = 60;
    pub const global_request = 80;
    pub const request_success = 81;
    pub const request_failure = 82;
    pub const channel_open = 90;
    pub const channel_open_confirmation = 91;
    pub const channel_open_failure = 92;
    pub const channel_window_adjust = 93;
    pub const channel_data = 94;
    pub const channel_extended_data = 95;
    pub const channel_eof = 96;
    pub const channel_close = 97;
    pub const channel_request = 98;
    pub const channel_success = 99;
    pub const channel_failure = 100;
};

/// Disconnect reasons.
pub const Reason = enum(u32) {
    protocol_error = 2,
    key_exchange_failed = 3,
    mac_error = 5,
    service_not_available = 7,
    by_application = 11,
    too_many_connections = 12,
    auth_cancelled_by_user = 13,
    no_more_auth_methods_available = 14,
};

pub const kex_algorithms = [_][]const u8{
    "mlkem768x25519-sha256", "curve25519-sha256", "curve25519-sha256@libssh.org",
};
pub const ciphers = [_][]const u8{ "chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com" };
/// The host key algorithms a client accepts, in its order of preference.
pub const host_key_algorithms = [_][]const u8{
    "ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256",
};
const strict_server = "kex-strict-s-v00@openssh.com";
const strict_client = "kex-strict-c-v00@openssh.com";

/// The longest packet accepted (RFC 4253 asks for at least 35000 bytes).
pub const max_packet = 256 * 1024;

pub const Error = error{
    ProtocolError,
    KeyExchangeFailed,
    MacError,
    PacketTooLarge,
    Disconnected,
} || Io.Reader.Error || Io.Writer.Error || Allocator.Error || Io.Cancelable;

const Cipher = union(enum) {
    none,
    chacha: struct { main: [32]u8, header: [32]u8 },
    gcm: struct { key: [32]u8, iv: [12]u8 },

    fn block(c: Cipher) usize {
        return if (c == .gcm) 16 else 8;
    }
};

pub const Role = enum { server, client };

pub const Transport = struct {
    gpa: Allocator,
    io: Io,
    in: *Io.Reader,
    out: *Io.Writer,
    /// When `in` is a socket's reader, its own error: `take` reads it to tell a hang-up
    /// from a failure. Set by whoever made the reader.
    socket_err: ?*const ?Io.net.Stream.Reader.Error = null,
    role: Role = .server,
    /// A server's own key (unused by a client).
    host_key: keys.KeyPair,
    /// The version line this side sends.
    version: []const u8,
    peer_version_buffer: [255]u8 = undefined,
    peer_version_len: usize = 0,
    /// A client's view of the server's host key (its blob), set by the first exchange
    /// and held to by every later one; check it before trusting the connection.
    peer_host_key: std.ArrayList(u8) = .empty,
    /// The host key algorithms a client offers, best first.
    host_key_preference: []const []const u8 = &host_key_algorithms,
    send_seq: u32 = 0,
    recv_seq: u32 = 0,
    send_cipher: Cipher = .none,
    recv_cipher: Cipher = .none,
    session_id: ?[32]u8 = null,
    strict: bool = false,
    /// The client said it reads `SSH_MSG_EXT_INFO` (`ext-info-c`); servers only.
    ext_info: bool = false,
    /// The packet last read.
    packet: std.ArrayList(u8) = .empty,
    /// Sends take turns; while keys change, only the exchange sends.
    send_lock: Io.Mutex = .init,
    kex_done: Io.Condition = .init,
    exchanging: bool = false,

    pub fn init(
        gpa: Allocator,
        io: Io,
        in: *Io.Reader,
        out: *Io.Writer,
        host_key: keys.KeyPair,
        server_version: []const u8,
    ) Transport {
        return .{
            .gpa = gpa,
            .io = io,
            .in = in,
            .out = out,
            .host_key = host_key,
            .version = server_version,
        };
    }

    /// A client's transport: it checks the server's host key instead of having one.
    pub fn initClient(
        gpa: Allocator,
        io: Io,
        in: *Io.Reader,
        out: *Io.Writer,
        client_version: []const u8,
    ) Transport {
        return .{
            .gpa = gpa,
            .io = io,
            .in = in,
            .out = out,
            .role = .client,
            .host_key = undefined,
            .version = client_version,
        };
    }

    pub fn deinit(t: *Transport) void {
        t.packet.deinit(t.gpa);
        t.peer_host_key.deinit(t.gpa);
        std.crypto.secureZero(u8, std.mem.asBytes(&t.send_cipher));
        std.crypto.secureZero(u8, std.mem.asBytes(&t.recv_cipher));
    }

    /// The other side's version line.
    pub fn peerVersion(t: *const Transport) []const u8 {
        return t.peer_version_buffer[0..t.peer_version_len];
    }

    /// The version exchange and the first key exchange.
    pub fn handshake(t: *Transport) Error!void {
        try t.out.print("{s}\r\n", .{t.version});
        try t.out.flush();
        // Lines before the version line are allowed (RFC 4253 section 4.2).
        var lines: usize = 0;
        while (true) : (lines += 1) {
            if (lines > 32) return error.ProtocolError;
            const line = t.in.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.ProtocolError,
                error.EndOfStream => return error.Disconnected,
                else => |e| return e,
            };
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (!std.mem.startsWith(u8, trimmed, "SSH-")) continue;
            if (!std.mem.startsWith(u8, trimmed, "SSH-2.0-") and
                !std.mem.startsWith(u8, trimmed, "SSH-1.99-"))
                return error.ProtocolError;
            if (trimmed.len > t.peer_version_buffer.len) return error.ProtocolError;
            @memcpy(t.peer_version_buffer[0..trimmed.len], trimmed);
            t.peer_version_len = trimmed.len;
            break;
        }
        try t.exchangeKeys(null);
    }

    /// Reads the next packet's payload (valid until the next read), skipping the ones
    /// that carry nothing (ignore, debug, unimplemented).
    pub fn read(t: *Transport) Error![]const u8 {
        while (true) {
            const payload = try t.readPacket();
            if (payload.len == 0) return error.ProtocolError;
            switch (payload[0]) {
                msg.ignore, msg.debug, msg.unimplemented, msg.ext_info => continue,
                msg.disconnect => return error.Disconnected,
                msg.kexinit => {
                    // The other side re-keys; its KEXINIT goes to the exchange.
                    const copy = try t.gpa.dupe(u8, payload);
                    defer t.gpa.free(copy);
                    try t.exchangeKeys(copy);
                    continue;
                },
                else => return payload,
            }
        }
    }

    fn readPacket(t: *Transport) Error![]const u8 {
        defer t.recv_seq +%= 1;
        var nonce: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce, t.recv_seq, .big);
        const first = try t.take(4);
        var length_bytes: [4]u8 = first[0..4].*;
        switch (t.recv_cipher) {
            .chacha => |c| ChaCha20.xor(&length_bytes, &length_bytes, 0, c.header, nonce),
            else => {},
        }
        const length = std.mem.readInt(u32, &length_bytes, .big);
        if (length > max_packet or length < 5) return error.PacketTooLarge;
        const tag_len: usize = if (t.recv_cipher == .none) 0 else 16;
        t.packet.clearRetainingCapacity();
        try t.packet.appendSlice(t.gpa, first[0..4]);
        try t.packet.appendSlice(t.gpa, try t.take(length + tag_len));
        const whole = t.packet.items;
        const body = whole[4 .. 4 + length];
        switch (t.recv_cipher) {
            .none => if ((4 + length) % 8 != 0) return error.ProtocolError,
            .chacha => |c| {
                var poly_key: [64]u8 = @splat(0);
                ChaCha20.xor(&poly_key, &poly_key, 0, c.main, nonce);
                var tag: [16]u8 = undefined;
                Poly1305.create(&tag, whole[0 .. 4 + length], poly_key[0..32]);
                if (!std.crypto.timing_safe.eql([16]u8, tag, whole[4 + length ..][0..16].*))
                    return error.MacError;
                ChaCha20.xor(body, body, 1, c.main, nonce);
                if (length % 8 != 0) return error.ProtocolError;
            },
            .gcm => |*c| {
                const tag = whole[4 + length ..][0..16].*;
                Aes256Gcm.decrypt(body, body, tag, whole[0..4], c.iv, c.key) catch
                    return error.MacError;
                incrementIv(&c.iv);
                if (length % 16 != 0) return error.ProtocolError;
            },
        }
        const padding = body[0];
        if (padding < 4 or @as(usize, padding) + 1 > length) return error.ProtocolError;
        return body[1 .. length - padding];
    }

    fn take(t: *Transport, n: usize) Error![]const u8 {
        return t.in.take(n) catch |err| switch (err) {
            error.EndOfStream => error.Disconnected,
            error.ReadFailed => if (t.hungUp()) error.Disconnected else error.ReadFailed,
        };
    }

    /// Whether the socket failed because the other side went away. shortcut: on Windows,
    /// Zig 0.17's `Io.net` reports a read after the peer closes as `error.Unexpected`
    /// (NTSTATUS `PIPE_DISCONNECTED`) rather than the end of the stream; that is the only
    /// `Unexpected` taken as a hang-up. Remove when std maps the status.
    fn hungUp(t: *const Transport) bool {
        if (@import("builtin").os.tag != .windows) return false;
        const err = (t.socket_err orelse return false).* orelse return false;
        return err == error.Unexpected;
    }

    /// Sends a packet; waits while keys are being exchanged.
    pub fn write(t: *Transport, payload: []const u8) Error!void {
        try t.send_lock.lock(t.io);
        defer t.send_lock.unlock(t.io);
        while (t.exchanging) try t.kex_done.wait(t.io, &t.send_lock);
        try t.sendLocked(payload);
    }

    fn sendDuringKex(t: *Transport, payload: []const u8) Error!void {
        try t.send_lock.lock(t.io);
        defer t.send_lock.unlock(t.io);
        try t.sendLocked(payload);
    }

    fn sendLocked(t: *Transport, payload: []const u8) Error!void {
        defer t.send_seq +%= 1;
        const block = t.send_cipher.block();
        const aead = t.send_cipher != .none;
        // The length field counts toward the block size only without encryption.
        const counted = 1 + payload.len + @as(usize, if (aead) 0 else 4);
        var padding = block - counted % block;
        if (padding < 4) padding += block;
        const length = 1 + payload.len + padding;
        if (length > max_packet) return error.PacketTooLarge;
        var packet = try t.gpa.alloc(u8, 4 + length + 16);
        defer t.gpa.free(packet);
        std.mem.writeInt(u32, packet[0..4], @intCast(length), .big);
        packet[4] = @intCast(padding);
        @memcpy(packet[5..][0..payload.len], payload);
        t.io.random(packet[5 + payload.len ..][0..padding]);
        var nonce: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce, t.send_seq, .big);
        const body = packet[4 .. 4 + length];
        switch (t.send_cipher) {
            .none => return t.out.writeAll(packet[0 .. 4 + length]),
            .chacha => |c| {
                ChaCha20.xor(packet[0..4], packet[0..4], 0, c.header, nonce);
                ChaCha20.xor(body, body, 1, c.main, nonce);
                var poly_key: [64]u8 = @splat(0);
                ChaCha20.xor(&poly_key, &poly_key, 0, c.main, nonce);
                Poly1305.create(
                    packet[4 + length ..][0..16],
                    packet[0 .. 4 + length],
                    poly_key[0..32],
                );
            },
            .gcm => |*c| {
                var tag: [16]u8 = undefined;
                Aes256Gcm.encrypt(body, &tag, body, packet[0..4], c.iv, c.key);
                @memcpy(packet[4 + length ..][0..16], &tag);
                incrementIv(&c.iv);
            },
        }
        try t.out.writeAll(packet[0 .. 4 + length + 16]);
    }

    /// Sends what is buffered.
    pub fn flush(t: *Transport) Error!void {
        try t.send_lock.lock(t.io);
        defer t.send_lock.unlock(t.io);
        try t.out.flush();
    }

    /// Writes and flushes a packet.
    pub fn send(t: *Transport, payload: []const u8) Error!void {
        try t.send_lock.lock(t.io);
        defer t.send_lock.unlock(t.io);
        while (t.exchanging) try t.kex_done.wait(t.io, &t.send_lock);
        try t.sendLocked(payload);
        try t.out.flush();
    }

    /// Says why and hangs up (best effort).
    pub fn disconnect(t: *Transport, reason: Reason, description: []const u8) void {
        var b: wire.Builder = .init(t.gpa);
        defer b.deinit();
        b.byte(msg.disconnect) catch return;
        b.int(@backingInt(reason)) catch return;
        b.string(description) catch return;
        b.string("") catch return;
        t.send(b.bytes()) catch {};
    }

    /// A key exchange: the first, or one the other side started with `peer_kexinit`.
    fn exchangeKeys(t: *Transport, peer_kexinit: ?[]const u8) Error!void {
        const first = t.session_id == null;
        const server = t.role == .server;
        {
            try t.send_lock.lock(t.io);
            defer t.send_lock.unlock(t.io);
            t.exchanging = true;
        }
        defer {
            t.send_lock.lockUncancelable(t.io);
            t.exchanging = false;
            t.kex_done.broadcast(t.io);
            t.send_lock.unlock(t.io);
        }
        // Ours.
        var ours: wire.Builder = .init(t.gpa);
        defer ours.deinit();
        try ours.byte(msg.kexinit);
        var cookie: [16]u8 = undefined;
        t.io.random(&cookie);
        try ours.raw(&cookie);
        if (!first)
            try ours.names(&kex_algorithms)
        else if (server)
            try ours.names(&(kex_algorithms ++ .{ strict_server, "ext-info-s" }))
        else
            try ours.names(&(kex_algorithms ++ .{ strict_client, "ext-info-c" }));
        const host_algorithms: []const []const u8 =
            if (server) &.{"ssh-ed25519"} else t.host_key_preference;
        try ours.names(host_algorithms);
        try ours.names(&ciphers);
        try ours.names(&ciphers);
        // AEAD ciphers bring their own integrity; the MAC lists are not consulted.
        try ours.names(&.{"hmac-sha2-256-etm@openssh.com"});
        try ours.names(&.{"hmac-sha2-256-etm@openssh.com"});
        try ours.names(&.{"none"});
        try ours.names(&.{"none"});
        try ours.names(&.{});
        try ours.names(&.{});
        try ours.boolean(false);
        try ours.int(0);
        try t.sendDuringKex(ours.bytes());
        try t.flushDuringKex();

        // Theirs.
        const theirs = if (peer_kexinit) |k|
            try t.gpa.dupe(u8, k)
        else
            try t.gpa.dupe(u8, try t.expect(msg.kexinit, first));
        defer t.gpa.free(theirs);
        var r: wire.Reader = .init(theirs[1..]);
        _ = r.take(16) catch return error.ProtocolError;
        const lists = blk: {
            var lists: [10][]const u8 = undefined;
            for (&lists) |*l| l.* = r.string() catch return error.ProtocolError;
            break :blk lists;
        };
        const guessed = r.boolean() catch return error.ProtocolError;
        if (first and wire.listHas(lists[0], if (server) strict_client else strict_server))
            t.strict = true;
        if (first and server and wire.listHas(lists[0], "ext-info-c")) t.ext_info = true;
        const kex = t.pick(lists[0], &kex_algorithms) orelse return error.KeyExchangeFailed;
        const host_algorithm = t.pick(lists[1], host_algorithms) orelse
            return error.KeyExchangeFailed;
        const c2s = t.pick(lists[2], &ciphers) orelse return error.KeyExchangeFailed;
        const s2c = t.pick(lists[3], &ciphers) orelse return error.KeyExchangeFailed;
        if (t.pick(lists[6], &.{"none"}) == null or t.pick(lists[7], &.{"none"}) == null)
            return error.KeyExchangeFailed;
        // A guessed first exchange packet for another method is dropped.
        if (guessed) {
            var it = std.mem.splitScalar(u8, lists[0], ',');
            if (!std.mem.eql(u8, it.first(), kex)) _ = try t.readPacket();
        }

        // The exchange.
        const kex_init: Kex = .{ .ours = ours.bytes(), .theirs = theirs, .first = first };
        var shared: wire.Builder = .init(t.gpa);
        defer {
            std.crypto.secureZero(u8, shared.list.items);
            shared.deinit();
        }
        const hybrid = std.mem.eql(u8, kex, "mlkem768x25519-sha256");
        const h = if (server)
            try t.serverExchange(kex_init, hybrid, &shared)
        else
            try t.clientExchange(kex_init, hybrid, host_algorithm, &shared);
        if (first) t.session_id = h;
        try t.sendDuringKex(&.{msg.newkeys});
        try t.flushDuringKex();
        const send_letters: [2]u8 = if (server) .{ 'B', 'D' } else .{ 'A', 'C' };
        const recv_letters: [2]u8 = if (server) .{ 'A', 'C' } else .{ 'B', 'D' };
        const s = shared.bytes();
        const id = &t.session_id.?;
        t.send_cipher =
            deriveCipher(s, &h, id, if (server) s2c else c2s, send_letters[0], send_letters[1]);
        if (t.strict) t.send_seq = 0;
        _ = try t.expect(msg.newkeys, first);
        t.recv_cipher =
            deriveCipher(s, &h, id, if (server) c2s else s2c, recv_letters[0], recv_letters[1]);
        if (t.strict) t.recv_seq = 0;
        if (first and t.ext_info) {
            var info: wire.Builder = .init(t.gpa);
            defer info.deinit();
            try info.byte(msg.ext_info);
            try info.int(1);
            try info.string("server-sig-algs");
            try info.names(&.{
                "ssh-ed25519",
                "ecdsa-sha2-nistp256",
                "rsa-sha2-512",
                "rsa-sha2-256",
            });
            try t.sendDuringKex(info.bytes());
            try t.flushDuringKex();
        }
    }

    const Kex = struct { ours: []const u8, theirs: []const u8, first: bool };

    /// The first of the client's names the server also has (RFC 4253 section 7.1), from
    /// `list` (theirs) and `names` (ours).
    fn pick(t: *const Transport, list: []const u8, names: []const []const u8) ?[]const u8 {
        if (t.role == .server) return wire.negotiate(list, names);
        for (names) |name| if (wire.listHas(list, name)) return name;
        return null;
    }

    /// The exchange hash H over everything both sides said.
    fn exchangeHash(
        t: *Transport,
        k: Kex,
        host_blob: []const u8,
        q_c: []const u8,
        q_s: []const u8,
        shared: []const u8,
    ) Error![32]u8 {
        const server = t.role == .server;
        var exchange: wire.Builder = .init(t.gpa);
        defer exchange.deinit();
        try exchange.string(if (server) t.peerVersion() else t.version);
        try exchange.string(if (server) t.version else t.peerVersion());
        try exchange.string(if (server) k.theirs else k.ours);
        try exchange.string(if (server) k.ours else k.theirs);
        try exchange.string(host_blob);
        try exchange.string(q_c);
        try exchange.string(q_s);
        try exchange.raw(shared);
        var h: [32]u8 = undefined;
        Sha256.hash(exchange.bytes(), &h, .{});
        return h;
    }

    /// The server's half: answers the client's key with ours, signed by the host key.
    fn serverExchange(t: *Transport, k: Kex, hybrid: bool, shared: *wire.Builder) Error![32]u8 {
        const init_packet = try t.expect(msg.kex_init, k.first);
        var ir: wire.Reader = .init(init_packet[1..]);
        const q_c = try t.gpa.dupe(u8, ir.string() catch return error.ProtocolError);
        defer t.gpa.free(q_c);
        var q_s: std.ArrayList(u8) = .empty;
        defer q_s.deinit(t.gpa);
        const ephemeral: X25519.KeyPair = .generate(t.io);
        if (hybrid) {
            if (q_c.len != MlKem768.PublicKey.encoded_length + 32) return error.KeyExchangeFailed;
            const pk = MlKem768.PublicKey.fromBytes(q_c[0..MlKem768.PublicKey.encoded_length]) catch
                return error.KeyExchangeFailed;
            const encapsulated = pk.encaps(t.io);
            const x = X25519.scalarmult(
                ephemeral.secret_key,
                q_c[MlKem768.PublicKey.encoded_length..][0..32].*,
            ) catch return error.KeyExchangeFailed;
            var h = Sha256.init(.{});
            h.update(&encapsulated.shared_secret);
            h.update(&x);
            try shared.string(&h.finalResult());
            try q_s.appendSlice(t.gpa, &encapsulated.ciphertext);
            try q_s.appendSlice(t.gpa, &ephemeral.public_key);
        } else {
            if (q_c.len != 32) return error.KeyExchangeFailed;
            const x = X25519.scalarmult(ephemeral.secret_key, q_c[0..32].*) catch
                return error.KeyExchangeFailed;
            try shared.mpint(&x);
            try q_s.appendSlice(t.gpa, &ephemeral.public_key);
        }
        const host_blob = t.host_key.publicBlob();
        const h = try t.exchangeHash(k, &host_blob, q_c, q_s.items, shared.bytes());
        var reply: wire.Builder = .init(t.gpa);
        defer reply.deinit();
        try reply.byte(msg.kex_reply);
        try reply.string(&host_blob);
        try reply.string(q_s.items);
        try reply.string(&t.host_key.sign(&h));
        try t.sendDuringKex(reply.bytes());
        return h;
    }

    /// The client's half: sends our key, and checks the server's signature over the
    /// exchange with the host key it sent (whether that key is the right one is the
    /// caller's to decide, from `peer_host_key`; a re-key must keep it).
    fn clientExchange(
        t: *Transport,
        k: Kex,
        hybrid: bool,
        host_algorithm: []const u8,
        shared: *wire.Builder,
    ) Error![32]u8 {
        const ephemeral: X25519.KeyPair = .generate(t.io);
        var kem: MlKem768.KeyPair = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&kem));
        var q_c: std.ArrayList(u8) = .empty;
        defer q_c.deinit(t.gpa);
        if (hybrid) {
            kem = .generate(t.io);
            try q_c.appendSlice(t.gpa, &kem.public_key.toBytes());
        }
        try q_c.appendSlice(t.gpa, &ephemeral.public_key);
        {
            var b: wire.Builder = .init(t.gpa);
            defer b.deinit();
            try b.byte(msg.kex_init);
            try b.string(q_c.items);
            try t.sendDuringKex(b.bytes());
            try t.flushDuringKex();
        }
        const reply = try t.gpa.dupe(u8, try t.expect(msg.kex_reply, k.first));
        defer t.gpa.free(reply);
        var r: wire.Reader = .init(reply[1..]);
        const host_blob = r.string() catch return error.ProtocolError;
        const q_s = r.string() catch return error.ProtocolError;
        const signature = r.string() catch return error.ProtocolError;
        const host = keys.PublicKey.parse(host_blob) catch return error.KeyExchangeFailed;
        if (!host.signsAs(host_algorithm)) return error.KeyExchangeFailed;
        const ct_len = MlKem768.ciphertext_length;
        if (q_s.len != @as(usize, if (hybrid) ct_len + 32 else 32)) return error.KeyExchangeFailed;
        const x = X25519.scalarmult(ephemeral.secret_key, q_s[q_s.len - 32 ..][0..32].*) catch
            return error.KeyExchangeFailed;
        if (hybrid) {
            var secret = kem.secret_key.decaps(q_s[0..ct_len]) catch
                return error.KeyExchangeFailed;
            defer std.crypto.secureZero(u8, &secret);
            var h = Sha256.init(.{});
            h.update(&secret);
            h.update(&x);
            try shared.string(&h.finalResult());
        } else try shared.mpint(&x);
        const h = try t.exchangeHash(k, host_blob, q_c.items, q_s, shared.bytes());
        host.verify(signature, &h) catch return error.KeyExchangeFailed;
        if (k.first)
            try t.peer_host_key.appendSlice(t.gpa, host_blob)
        else if (!std.mem.eql(u8, t.peer_host_key.items, host_blob))
            return error.KeyExchangeFailed;
        return h;
    }

    fn flushDuringKex(t: *Transport) Error!void {
        try t.send_lock.lock(t.io);
        defer t.send_lock.unlock(t.io);
        try t.out.flush();
    }

    /// The next packet, which must be `number`; in a strict first exchange nothing else
    /// may come between, otherwise ignore and debug messages may.
    fn expect(t: *Transport, number: u8, first: bool) Error![]const u8 {
        while (true) {
            const payload = try t.readPacket();
            if (payload.len == 0) return error.ProtocolError;
            if (payload[0] == number) return payload;
            if (payload[0] == msg.disconnect) return error.Disconnected;
            if (!(first and t.strict) and
                (payload[0] == msg.ignore or payload[0] == msg.debug)) continue;
            return error.ProtocolError;
        }
    }
};

fn incrementIv(iv: *[12]u8) void {
    const counter = std.mem.readInt(u64, iv[4..12], .big);
    std.mem.writeInt(u64, iv[4..12], counter +% 1, .big);
}

/// The cipher state for one direction, from the shared secret (as encoded for hashing),
/// the exchange hash, and the session: RFC 4253 section 7.2's derivation.
fn deriveCipher(
    shared: []const u8,
    h: *const [32]u8,
    session_id: *const [32]u8,
    name: []const u8,
    iv_letter: u8,
    key_letter: u8,
) Cipher {
    if (std.mem.eql(u8, name, "chacha20-poly1305@openssh.com")) {
        var key: [64]u8 = undefined;
        derive(shared, h, session_id, key_letter, &key);
        return .{ .chacha = .{ .main = key[0..32].*, .header = key[32..64].* } };
    }
    var key: [32]u8 = undefined;
    var iv: [12]u8 = undefined;
    derive(shared, h, session_id, key_letter, &key);
    derive(shared, h, session_id, iv_letter, &iv);
    return .{ .gcm = .{ .key = key, .iv = iv } };
}

fn derive(
    shared: []const u8,
    h: *const [32]u8,
    session_id: *const [32]u8,
    letter: u8,
    out: []u8,
) void {
    var produced: [128]u8 = undefined;
    var len: usize = 0;
    var hasher = Sha256.init(.{});
    hasher.update(shared);
    hasher.update(h);
    hasher.update(&.{letter});
    hasher.update(session_id);
    hasher.final(produced[0..32]);
    len = 32;
    while (len < out.len) {
        hasher = Sha256.init(.{});
        hasher.update(shared);
        hasher.update(h);
        hasher.update(produced[0..len]);
        hasher.final(produced[len..][0..32]);
        len += 32;
    }
    @memcpy(out, produced[0..out.len]);
}

const testing = std.testing;

test "packets round trip under each cipher" {
    var pipe_buffer: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&pipe_buffer);
    var dummy: Io.Reader = .fixed("");
    const key: keys.KeyPair = .fromSeed(@splat(1));
    var sender: Transport = .init(testing.allocator, testing.io, &dummy, &out, key, "SSH-2.0-test");
    defer sender.deinit();
    const states = [_]Cipher{
        .none,
        .{ .chacha = .{ .main = @splat(2), .header = @splat(3) } },
        .{ .gcm = .{ .key = @splat(4), .iv = @splat(5) } },
    };
    for (states) |state| {
        out.end = 0;
        sender.send_cipher = state;
        sender.send_seq = 7;
        try sender.send("\x05hello");
        try sender.send("\x05again, longer than one block of sixteen bytes");
        var in: Io.Reader = .fixed(out.buffered());
        var receiver: Transport = .init(
            testing.allocator,
            testing.io,
            &in,
            &out,
            key,
            "SSH-2.0-test",
        );
        defer receiver.deinit();
        receiver.recv_cipher = state;
        receiver.recv_seq = 7;
        try testing.expectEqualStrings("\x05hello", try receiver.read());
        try testing.expectEqualStrings(
            "\x05again, longer than one block of sixteen bytes",
            try receiver.read(),
        );
    }
}

test "a flipped bit fails the integrity check" {
    var pipe_buffer: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&pipe_buffer);
    var dummy: Io.Reader = .fixed("");
    const key: keys.KeyPair = .fromSeed(@splat(1));
    var sender: Transport = .init(testing.allocator, testing.io, &dummy, &out, key, "SSH-2.0-test");
    defer sender.deinit();
    sender.send_cipher = .{ .chacha = .{ .main = @splat(2), .header = @splat(3) } };
    try sender.send("\x05hello");
    pipe_buffer[10] ^= 1;
    var in: Io.Reader = .fixed(out.buffered());
    var receiver: Transport = .init(testing.allocator, testing.io, &in, &out, key, "SSH-2.0-test");
    defer receiver.deinit();
    receiver.recv_cipher = sender.send_cipher;
    try testing.expectError(error.MacError, receiver.read());
}
