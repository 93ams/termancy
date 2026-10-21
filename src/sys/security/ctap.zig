//! Security keys over USB: CTAP2 (FIDO Client to Authenticator Protocol 2.1) on CTAPHID,
//! for getting a WebAuthn assertion from a key plugged into the machine.
//!
//! ```zig
//! const paths = try ctap.Hidraw.list(arena, io);
//! var hid: ctap.Hidraw = try .open(io, paths[0]);
//! defer hid.close();
//! var channel: ctap.Channel = try .open(io, hid.device());
//! try webauthn.writePresencePrompt(err, options.rp_id);
//! const origin = "https://example.com";
//! const assertion = try ctap.assert(arena, &channel, options, origin, .{ .pin = pin });
//! try assertion.writeJson(out);
//! ```
//!
//! Three layers, each usable alone:
//!
//! - `Device` reads and writes 64-byte HID reports. `Hidraw` is the Linux one: the
//!   `/dev/hidraw*` nodes whose report descriptor declares the FIDO usage page.
//! - `Channel` is CTAPHID (CTAP 2.1 §11.2): a channel from INIT, messages split into
//!   packets, and the keepalives a key sends while it waits for a touch.
//! - `getInfo`, `getAssertion`, and `assert`, which builds the client data, asks the key,
//!   and returns a `webauthn.Assertion`. With a PIN, `assert` first gets a PIN token from
//!   the key (`getPinToken`, either PIN/UV auth protocol), which user verification needs
//!   on a key that has a PIN set.
//!
//! **Not implemented:** devices on macOS (IOKit) and Windows. On Windows an unelevated
//! process cannot open a FIDO device; Windows Hello (`webauthn.dll`) owns them, and
//! `windows_hello.assert` asks it for the same `webauthn.Assertion`. Nor setting or
//! changing a PIN, or built-in user verification tokens (`getPinUvAuthTokenUsingUv`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes256 = std.crypto.core.aes.Aes256;
const P256 = std.crypto.ecc.P256;
const cbor = @import("cbor.zig");
const secure = @import("secure.zig");
const webauthn = @import("webauthn.zig");

/// The size of a CTAPHID report.
pub const report_len = 64;
pub const Report = [report_len]u8;

/// A source and sink of HID reports.
pub const Device = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        /// The device went away, or refused the read or write.
        DeviceFailed,
        /// No report arrived in time, or the request's deadline passed.
        Timeout,
    };

    pub const VTable = struct {
        write: *const fn (context: *anyopaque, report: *const Report) Error!void,
        /// Fills `report`, or fails with `error.Timeout` after `timeout_ms`.
        read: *const fn (context: *anyopaque, report: *Report, timeout_ms: u32) Error!void,
    };

    pub fn write(device: Device, report: *const Report) Error!void {
        return device.vtable.write(device.context, report);
    }

    pub fn read(device: Device, report: *Report, timeout_ms: u32) Error!void {
        return device.vtable.read(device.context, report, timeout_ms);
    }
};

/// CTAPHID commands, without the high bit the first packet sets.
pub const Command = enum(u7) {
    ping = 0x01,
    msg = 0x03,
    init = 0x06,
    cbor = 0x10,
    cancel = 0x11,
    keepalive = 0x3b,
    @"error" = 0x3f,
    _,
};

/// What a key reports while it works on a request.
pub const KeepaliveStatus = enum(u8) {
    processing = 1,
    /// Waiting for the user to touch the key.
    user_presence_needed = 2,
    _,
};

/// Called for each keepalive, for example to show `webauthn.presence_prompt` once.
pub const Keepalive = struct {
    context: *anyopaque,
    function: *const fn (context: *anyopaque, status: KeepaliveStatus) void,
};

pub const ChannelError = Device.Error || error{
    /// A reply that does not follow the protocol.
    InvalidResponse,
    /// Another program is using the key.
    ChannelBusy,
    /// The key reported a CTAPHID error.
    ProtocolError,
    /// A request longer than `Channel.max_payload`.
    RequestTooLarge,
};

/// A CTAPHID channel to one device.
pub const Channel = struct {
    device: Device,
    cid: u32,
    /// For the randomness of the PIN protocol.
    io: Io,
    /// How long to wait for each report. Keys send keepalives every 100 ms or so while
    /// waiting for a touch, so this bounds silence, not the wait for the user.
    timeout_ms: u32 = 5_000,
    /// How long one request may take in all, keepalives and other channels' reports
    /// included, so a key that keeps sending them cannot hold us forever. WebAuthn's
    /// recommended default for a ceremony; `assert` takes the request's
    /// (`RequestOptions.ceremonyTimeoutMs`).
    deadline_ms: u32 = 300_000,

    pub const broadcast: u32 = 0xffff_ffff;
    const init_data = report_len - 7;
    const cont_data = report_len - 5;
    /// The longest message: one initial packet and 128 continuation packets.
    pub const max_payload = init_data + 128 * cont_data;

    /// Allocates a channel with CTAPHID_INIT on the broadcast channel.
    pub fn open(io: Io, device: Device) ChannelError!Channel {
        var nonce: [8]u8 = undefined;
        io.random(&nonce);
        var probe: Channel = .{ .device = device, .cid = broadcast, .io = io };
        var reply: [max_payload]u8 = undefined;
        const start: Io.Timestamp = .now(io, .awake);
        try probe.send(.init, &nonce);
        // Another program's INIT is answered on the broadcast channel too: not ours.
        const answer = while (true) {
            const got = try probe.receive(.init, &reply, null, start);
            if (got.len >= nonce.len and std.mem.eql(u8, got[0..nonce.len], &nonce)) break got;
        };
        if (answer.len < 17) return error.InvalidResponse;
        const cid = std.mem.readInt(u32, answer[8..12], .big);
        if (cid == 0 or cid == broadcast) return error.InvalidResponse;
        return .{ .device = device, .cid = cid, .io = io };
    }

    /// Sends `payload` as `command` and returns the reply's payload, in `out`, which
    /// should hold `max_payload` bytes.
    pub fn transact(
        channel: *Channel,
        command: Command,
        payload: []const u8,
        out: []u8,
        keepalive: ?Keepalive,
    ) ChannelError![]u8 {
        const start: Io.Timestamp = .now(channel.io, .awake);
        try channel.send(command, payload);
        return channel.receive(command, out, keepalive, start);
    }

    /// The next report, waiting no longer than `timeout_ms`, nor past `deadline_ms` after
    /// `start`.
    fn read(channel: *Channel, report: *Report, start: Io.Timestamp) Device.Error!void {
        const waited = start.untilNow(channel.io, .awake).toMilliseconds();
        if (waited >= channel.deadline_ms) return error.Timeout;
        const left: u32 = @intCast(channel.deadline_ms - waited);
        return channel.device.read(report, @min(channel.timeout_ms, left));
    }

    fn send(channel: *Channel, command: Command, payload: []const u8) ChannelError!void {
        if (payload.len > max_payload) return error.RequestTooLarge;
        var report: Report = @splat(0);
        std.mem.writeInt(u32, report[0..4], channel.cid, .big);
        report[4] = 0x80 | @as(u8, @backingInt(command));
        std.mem.writeInt(u16, report[5..7], @intCast(payload.len), .big);
        const first = @min(payload.len, init_data);
        @memcpy(report[7..][0..first], payload[0..first]);
        try channel.device.write(&report);
        var rest = payload[first..];
        var seq: u8 = 0;
        while (rest.len > 0) : (seq += 1) {
            report = @splat(0);
            std.mem.writeInt(u32, report[0..4], channel.cid, .big);
            report[4] = seq;
            const n = @min(rest.len, cont_data);
            @memcpy(report[5..][0..n], rest[0..n]);
            try channel.device.write(&report);
            rest = rest[n..];
        }
    }

    fn receive(
        channel: *Channel,
        command: Command,
        out: []u8,
        keepalive: ?Keepalive,
        start: Io.Timestamp,
    ) ChannelError![]u8 {
        var report: Report = undefined;
        const len = while (true) {
            try channel.read(&report, start);
            if (!channel.ours(&report) or report[4] & 0x80 == 0) continue;
            const got: Command = @fromBackingInt(@intCast(@as(u7, @truncate(report[4]))));
            switch (got) {
                .keepalive => if (keepalive) |k| {
                    k.function(k.context, @fromBackingInt(@intCast(report[7])));
                },
                .@"error" => {
                    return if (report[7] == 0x06) error.ChannelBusy else error.ProtocolError;
                },
                else => {
                    if (got != command) return error.InvalidResponse;
                    break std.mem.readInt(u16, report[5..7], .big);
                },
            }
        };
        // Past `max_payload` the u7 sequence numbers run out (and `seq` overflows).
        if (len > @min(out.len, max_payload)) return error.InvalidResponse;
        const first = @min(len, init_data);
        @memcpy(out[0..first], report[7..][0..first]);
        var filled: usize = first;
        var seq: u8 = 0;
        while (filled < len) {
            try channel.read(&report, start);
            if (!channel.ours(&report)) continue;
            if (report[4] != seq) return error.InvalidResponse;
            const n = @min(len - filled, cont_data);
            @memcpy(out[filled..][0..n], report[5..][0..n]);
            filled += n;
            seq += 1;
        }
        return out[0..len];
    }

    fn ours(channel: *const Channel, report: *const Report) bool {
        return std.mem.readInt(u32, report[0..4], .big) == channel.cid;
    }
};

/// What a CTAP2 command fails with: the transport's errors and the key's status codes.
pub const CommandError = ChannelError || Allocator.Error || error{
    /// None of the allowed credentials is on this key, or it has none for the RP.
    NoCredentials,
    /// The user declined, or the key refused.
    OperationDenied,
    /// The user did not touch the key in time.
    UserActionTimeout,
    /// User verification needs the key's PIN: pass one to `assert`.
    PinRequired,
    /// The PIN is wrong; `getPinRetries` says how many tries are left.
    PinInvalid,
    /// Too many wrong PINs: the key must be reset (or, for a while, unplugged and plugged
    /// in again).
    PinBlocked,
    /// The key has no PIN set.
    PinNotSet,
    /// The request was canceled.
    Canceled,
    /// Another CTAP2 status code.
    AuthenticatorError,
};

const ctap2_get_assertion = 0x02;
const ctap2_get_info = 0x04;
const ctap2_client_pin = 0x06;

fn statusError(status: u8) CommandError {
    return switch (status) {
        0x2d => error.Canceled,
        0x2e => error.NoCredentials,
        0x27 => error.OperationDenied,
        0x2f, 0x3a => error.UserActionTimeout,
        0x31 => error.PinInvalid,
        0x32, 0x34 => error.PinBlocked,
        0x35 => error.PinNotSet,
        0x36 => error.PinRequired,
        else => error.AuthenticatorError,
    };
}

/// Sends a CTAP2 command with its CBOR parameters, checks the status byte, and returns
/// the CBOR response, in `out`.
fn call(
    channel: *Channel,
    code: u8,
    parameters: []const u8,
    out: []u8,
    keepalive: ?Keepalive,
) CommandError![]const u8 {
    var message: [Channel.max_payload]u8 = undefined;
    if (parameters.len + 1 > message.len) return error.RequestTooLarge;
    message[0] = code;
    @memcpy(message[1..][0..parameters.len], parameters);
    const reply = try channel.transact(.cbor, message[0 .. parameters.len + 1], out, keepalive);
    if (reply.len == 0) return error.InvalidResponse;
    if (reply[0] != 0) return statusError(reply[0]);
    return reply[1..];
}

/// What `getInfo` reports.
pub const Info = struct {
    /// Such as `FIDO_2_0`, `FIDO_2_1`, `U2F_V2`.
    versions: []const []const u8,
    aaguid: [16]u8,
    /// Whether a PIN is set; null when the key has no PIN support.
    client_pin: ?bool = null,
    /// Whether built-in user verification (a fingerprint) is configured.
    uv: ?bool = null,
    /// The PIN/UV auth protocols the key supports, most preferred first.
    pin_protocols: []const u8 = &.{},
};

/// authenticatorGetInfo. Strings are copied into `arena`.
pub fn getInfo(arena: Allocator, channel: *Channel) CommandError!Info {
    var out: [Channel.max_payload]u8 = undefined;
    const response = try call(channel, ctap2_get_info, "", &out, null);
    var r: cbor.Reader = .{ .bytes = response };
    var info: Info = .{ .versions = &.{}, .aaguid = @splat(0) };
    const entries = r.map() catch return error.InvalidResponse;
    for (0..entries) |_| {
        readInfoEntry(arena, &r, &info) catch |err| switch (err) {
            error.InvalidCbor => return error.InvalidResponse,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return info;
}

fn readInfoEntry(arena: Allocator, r: *cbor.Reader, info: *Info) !void {
    if (try r.peek() != .unsigned) {
        try r.skip();
        return r.skip();
    }
    switch (try r.int()) {
        1 => {
            const len = try r.array();
            const versions = try arena.alloc([]const u8, @min(len, 64));
            for (0..len) |i| {
                const version = try r.textString();
                if (i < versions.len) versions[i] = try arena.dupe(u8, version);
            }
            info.versions = versions;
        },
        3 => {
            const aaguid = try r.byteString();
            if (aaguid.len != 16) return error.InvalidCbor;
            info.aaguid = aaguid[0..16].*;
        },
        6 => {
            const len = try r.array();
            const protocols = try arena.alloc(u8, @min(len, 8));
            for (0..len) |i| {
                const protocol = try r.int();
                if (i < protocols.len) protocols[i] = std.math.cast(u8, protocol) orelse 0;
            }
            info.pin_protocols = protocols;
        },
        4 => {
            const options = try r.map();
            for (0..options) |_| {
                const name = try r.textString();
                if (try r.peek() != .simple) {
                    try r.skip();
                    continue;
                }
                const value = try r.boolean();
                if (std.mem.eql(u8, name, "clientPin")) info.client_pin = value;
                if (std.mem.eql(u8, name, "uv")) info.uv = value;
            }
        },
        else => try r.skip(),
    }
}

/// The parameters of authenticatorGetAssertion.
pub const GetAssertion = struct {
    rp_id: []const u8,
    client_data_hash: [Sha256.digest_length]u8,
    /// Raw credential IDs; empty for a discoverable credential.
    allow_list: []const []const u8 = &.{},
    /// Ask for built-in user verification.
    user_verification: bool = false,
    /// Verifies the user by PIN instead (`getPinToken`).
    pin_token: ?PinToken = null,
};

/// What authenticatorGetAssertion returns.
pub const AssertionResponse = struct {
    /// Null when the key leaves it out, which it may when `allow_list` had one entry.
    credential_id: ?[]const u8,
    authenticator_data: []const u8,
    signature: []const u8,
    user_handle: ?[]const u8 = null,
};

/// authenticatorGetAssertion: asks the key to sign, waiting for the user's touch.
/// `keepalive` hears each keepalive while it waits. The result is copied into `arena`.
pub fn getAssertion(
    arena: Allocator,
    channel: *Channel,
    request: GetAssertion,
    keepalive: ?Keepalive,
) CommandError!AssertionResponse {
    var parameters: [Channel.max_payload]u8 = undefined;
    var w: Io.Writer = .fixed(&parameters);
    writeGetAssertion(&w, request) catch return error.RequestTooLarge;
    var out: [Channel.max_payload]u8 = undefined;
    const response = try call(channel, ctap2_get_assertion, w.buffered(), &out, keepalive);
    return readAssertion(arena, response) catch |err| switch (err) {
        error.InvalidCbor => error.InvalidResponse,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn writeGetAssertion(w: *Io.Writer, request: GetAssertion) Io.Writer.Error!void {
    const has_list = request.allow_list.len > 0;
    // A PIN token verifies the user; the `uv` option would ask the key to do it again.
    const uv = request.user_verification and request.pin_token == null;
    const pin: usize = if (request.pin_token != null) 2 else 0;
    try cbor.writeMap(w, 2 + @as(usize, @intFromBool(has_list)) + @intFromBool(uv) + pin);
    try cbor.writeInt(w, 1);
    try cbor.writeText(w, request.rp_id);
    try cbor.writeInt(w, 2);
    try cbor.writeBytes(w, &request.client_data_hash);
    if (has_list) {
        try cbor.writeInt(w, 3);
        try cbor.writeArray(w, request.allow_list.len);
        for (request.allow_list) |id| try writeCredential(w, id);
    }
    if (uv) {
        try cbor.writeInt(w, 5);
        try cbor.writeMap(w, 1);
        try cbor.writeText(w, "uv");
        try cbor.writeBool(w, true);
    }
    if (request.pin_token) |token| {
        var param: [HmacSha256.mac_length]u8 = undefined;
        try cbor.writeInt(w, 6);
        try cbor.writeBytes(w, token.authenticate(&request.client_data_hash, &param));
        try cbor.writeInt(w, 7);
        try cbor.writeInt(w, @backingInt(token.protocol));
    }
}

/// A `PublicKeyCredentialDescriptor`: `{"id": id, "type": "public-key"}`.
fn writeCredential(w: *Io.Writer, id: []const u8) Io.Writer.Error!void {
    try cbor.writeMap(w, 2);
    try cbor.writeText(w, "id");
    try cbor.writeBytes(w, id);
    try cbor.writeText(w, "type");
    try cbor.writeText(w, "public-key");
}

fn readAssertion(arena: Allocator, response: []const u8) !AssertionResponse {
    var r: cbor.Reader = .{ .bytes = response };
    var result: AssertionResponse = .{
        .credential_id = null,
        .authenticator_data = "",
        .signature = "",
    };
    var have_data = false;
    var have_signature = false;
    const entries = try r.map();
    for (0..entries) |_| {
        if (try r.peek() != .unsigned) {
            try r.skip();
            try r.skip();
            continue;
        }
        switch (try r.int()) {
            1 => result.credential_id = try arena.dupe(u8, try readId(&r)),
            2 => {
                result.authenticator_data = try arena.dupe(u8, try r.byteString());
                have_data = true;
            },
            3 => {
                result.signature = try arena.dupe(u8, try r.byteString());
                have_signature = true;
            },
            4 => result.user_handle = try arena.dupe(u8, try readId(&r)),
            else => try r.skip(),
        }
    }
    if (!have_data or !have_signature) return error.InvalidCbor;
    return result;
}

/// The `id` of a credential or user entity map.
fn readId(r: *cbor.Reader) cbor.Error![]const u8 {
    var id: ?[]const u8 = null;
    const entries = try r.map();
    for (0..entries) |_| {
        if (try r.peek() != .text) {
            try r.skip();
            try r.skip();
        } else if (std.mem.eql(u8, try r.textString(), "id")) {
            id = try r.byteString();
        } else try r.skip();
    }
    return id orelse error.InvalidCbor;
}

pub const AssertError = CommandError || error{
    /// `origin` has no host for the RP ID, or the request options name an RP ID it may not
    /// use (`webauthn.rpIdFor`).
    InvalidOrigin,
};

/// How `assert` talks to the key.
pub const AssertOptions = struct {
    /// Hears each keepalive while the key waits for a touch.
    keepalive: ?Keepalive = null,
    /// The key's PIN, which verifies the user: needed when the key has a PIN and the RP
    /// requires user verification.
    pin: ?[]const u8 = null,
};

/// A whole `navigator.credentials.get()` against one key: builds clientDataJSON for
/// `options` and `origin`, asks the key, and returns the assertion, in `arena`. The RP ID
/// defaults to the host of `origin`, and must be that host or a domain it is under. Each
/// exchange with the key takes at most `options.ceremonyTimeoutMs()`.
pub fn assert(
    arena: Allocator,
    channel: *Channel,
    options: webauthn.RequestOptions,
    origin: []const u8,
    how: AssertOptions,
) AssertError!webauthn.Assertion {
    const rp_id = webauthn.rpIdFor(options.rp_id, origin) orelse return error.InvalidOrigin;
    const deadline = channel.deadline_ms;
    defer channel.deadline_ms = deadline;
    channel.deadline_ms = options.ceremonyTimeoutMs();
    var client: Io.Writer.Allocating = .init(arena);
    const data: webauthn.ClientData = .{ .challenge = options.challenge, .origin = origin };
    data.writeJson(&client.writer) catch return error.OutOfMemory;
    var request: GetAssertion = .{
        .rp_id = rp_id,
        .client_data_hash = undefined,
        .user_verification = options.user_verification == .required,
    };
    Sha256.hash(client.written(), &request.client_data_hash, .{});
    const ids = try arena.alloc([]const u8, options.allow_credentials.len);
    for (options.allow_credentials, ids) |credential, *id| id.* = credential.id;
    request.allow_list = ids;
    if (how.pin) |pin| {
        const info = try getInfo(arena, channel);
        request.pin_token = try getPinToken(channel, preferredProtocol(info.pin_protocols), pin);
    }
    const response = try getAssertion(arena, channel, request, how.keepalive);
    const raw_id = response.credential_id orelse
        if (ids.len == 1) ids[0] else return error.InvalidResponse;
    return .{
        .raw_id = raw_id,
        .client_data_json = client.written(),
        .authenticator_data = response.authenticator_data,
        .signature = response.signature,
        .user_handle = response.user_handle,
        .authenticator_attachment = "cross-platform",
    };
}

// -- ClientPIN: PIN/UV auth protocols one and two (CTAP 2.1 §6.5) ------------------------

/// A PIN/UV auth protocol: how the PIN and the token travel, encrypted under a secret
/// agreed by ECDH with the key.
pub const PinProtocol = enum(u8) {
    one = 1,
    two = 2,
};

/// Protocol two when the key lists it, else protocol one, which every key with a PIN
/// supports.
fn preferredProtocol(supported: []const u8) PinProtocol {
    for (supported) |protocol| if (protocol == 2) return .two;
    return .one;
}

/// The secret shared with the key: protocol one uses one key for HMAC and AES; protocol
/// two derives an HMAC key, then an AES key (§6.5.7).
const SharedSecret = struct {
    protocol: PinProtocol,
    bytes: [64]u8,

    fn derive(protocol: PinProtocol, z: [32]u8) SharedSecret {
        var secret: SharedSecret = .{ .protocol = protocol, .bytes = undefined };
        switch (protocol) {
            .one => {
                Sha256.hash(&z, secret.bytes[0..32], .{});
                secret.bytes[32..].* = secret.bytes[0..32].*;
            },
            .two => {
                const prk = HkdfSha256.extract(&@as([32]u8, @splat(0)), &z);
                HkdfSha256.expand(secret.bytes[0..32], "CTAP2 HMAC key", prk);
                HkdfSha256.expand(secret.bytes[32..], "CTAP2 AES key", prk);
            },
        }
        return secret;
    }

    fn aesKey(secret: *const SharedSecret) [32]u8 {
        return secret.bytes[32..64].*;
    }

    /// `plaintext` (whole AES blocks) encrypted into `out`: AES-256-CBC with a zero IV
    /// (protocol one), or with a random IV written first (protocol two).
    fn encrypt(secret: *const SharedSecret, io: Io, plaintext: []const u8, out: []u8) []u8 {
        std.debug.assert(plaintext.len % 16 == 0);
        var iv: [16]u8 = @splat(0);
        var at: usize = 0;
        if (secret.protocol == .two) {
            io.random(&iv);
            out[0..16].* = iv;
            at = 16;
        }
        cbcEncrypt(secret.aesKey(), iv, plaintext, out[at..][0..plaintext.len]);
        return out[0 .. at + plaintext.len];
    }

    /// The inverse of `encrypt`; null for a ciphertext that is not whole blocks.
    fn decrypt(secret: *const SharedSecret, ciphertext: []const u8, out: []u8) ?[]u8 {
        var iv: [16]u8 = @splat(0);
        var body = ciphertext;
        if (secret.protocol == .two) {
            if (body.len < 16) return null;
            iv = body[0..16].*;
            body = body[16..];
        }
        if (body.len % 16 != 0 or body.len > out.len) return null;
        cbcDecrypt(secret.aesKey(), iv, body, out[0..body.len]);
        return out[0..body.len];
    }
};

fn cbcEncrypt(key: [32]u8, iv: [16]u8, plaintext: []const u8, out: []u8) void {
    const aes = Aes256.initEnc(key);
    var chain = iv;
    var i: usize = 0;
    while (i < plaintext.len) : (i += 16) {
        var block: [16]u8 = undefined;
        for (&block, plaintext[i..][0..16], chain) |*b, p, c| b.* = p ^ c;
        aes.encrypt(out[i..][0..16], &block);
        chain = out[i..][0..16].*;
    }
}

fn cbcDecrypt(key: [32]u8, iv: [16]u8, ciphertext: []const u8, out: []u8) void {
    const aes = Aes256.initDec(key);
    var chain = iv;
    var i: usize = 0;
    while (i < ciphertext.len) : (i += 16) {
        const block = ciphertext[i..][0..16].*;
        aes.decrypt(out[i..][0..16], &block);
        for (out[i..][0..16], chain) |*b, c| b.* ^= c;
        chain = block;
    }
}

/// HMAC-SHA-256 of `message` under `key`, cut to 16 bytes for protocol one, in `out`.
fn pinAuthenticate(
    protocol: PinProtocol,
    key: []const u8,
    message: []const u8,
    out: *[HmacSha256.mac_length]u8,
) []const u8 {
    HmacSha256.create(out, message, key);
    return if (protocol == .one) out[0..16] else out;
}

/// What `getPinToken` returns: proof, for a while, that the user gave the PIN.
pub const PinToken = struct {
    protocol: PinProtocol,
    bytes: [32]u8,
    len: u8,

    /// The `pinUvAuthParam` for a request carrying `message`, in `out`.
    pub fn authenticate(
        token: *const PinToken,
        message: []const u8,
        out: *[HmacSha256.mac_length]u8,
    ) []const u8 {
        return pinAuthenticate(token.protocol, token.bytes[0..token.len], message, out);
    }
};

/// The ClientPIN subcommands used here.
const PinCommand = enum(u8) {
    get_retries = 0x01,
    get_key_agreement = 0x02,
    get_pin_token = 0x05,
};

/// authenticatorClientPIN with `parameters` after the protocol and subcommand.
fn clientPin(
    channel: *Channel,
    protocol: PinProtocol,
    command: PinCommand,
    extra: []const u8,
    extra_entries: usize,
    out: []u8,
) CommandError![]const u8 {
    var parameters: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&parameters);
    write: {
        cbor.writeMap(&w, 2 + extra_entries) catch break :write;
        cbor.writeInt(&w, 1) catch break :write;
        cbor.writeInt(&w, @backingInt(protocol)) catch break :write;
        cbor.writeInt(&w, 2) catch break :write;
        cbor.writeInt(&w, @backingInt(command)) catch break :write;
        w.writeAll(extra) catch break :write;
        return call(channel, ctap2_client_pin, w.buffered(), out, null);
    }
    return error.RequestTooLarge;
}

/// The value at integer `key` of the CBOR map `response`; null when it is not there.
fn mapEntry(response: []const u8, key: i64) CommandError!?cbor.Reader {
    var r: cbor.Reader = .{ .bytes = response };
    const entries = r.map() catch return error.InvalidResponse;
    for (0..entries) |_| {
        switch (r.peek() catch return error.InvalidResponse) {
            .unsigned, .negative => {
                const label = r.int() catch return error.InvalidResponse;
                if (label == key) return r;
            },
            else => r.skip() catch return error.InvalidResponse,
        }
        r.skip() catch return error.InvalidResponse;
    }
    return null;
}

/// How many wrong PINs the key still accepts before it blocks.
pub fn getPinRetries(channel: *Channel, protocol: PinProtocol) CommandError!u8 {
    var out: [256]u8 = undefined;
    const response = try clientPin(channel, protocol, .get_retries, "", 0, &out);
    var r = try mapEntry(response, 3) orelse return error.InvalidResponse;
    const retries = r.int() catch return error.InvalidResponse;
    return std.math.cast(u8, retries) orelse error.InvalidResponse;
}

/// The key's half of the key agreement: a COSE_Key on P-256 (§6.5.6).
fn readAgreementKey(response: []const u8) CommandError!P256 {
    var r = try mapEntry(response, 1) orelse return error.InvalidResponse;
    return readCoseP256(&r);
}

fn readCoseP256(r: *cbor.Reader) CommandError!P256 {
    var x: ?[]const u8 = null;
    var y: ?[]const u8 = null;
    const entries = r.map() catch return error.InvalidResponse;
    for (0..entries) |_| {
        const label = r.int() catch return error.InvalidResponse;
        switch (label) {
            -2 => x = r.byteString() catch return error.InvalidResponse,
            -3 => y = r.byteString() catch return error.InvalidResponse,
            else => r.skip() catch return error.InvalidResponse,
        }
    }
    const xs = x orelse return error.InvalidResponse;
    const ys = y orelse return error.InvalidResponse;
    if (xs.len != 32 or ys.len != 32) return error.InvalidResponse;
    return P256.fromSerializedAffineCoordinates(xs[0..32].*, ys[0..32].*, .big) catch
        error.InvalidResponse;
}

/// Writes a P-256 public key as the COSE_Key the PIN protocols exchange.
fn writeAgreementKey(w: *Io.Writer, point: P256) Io.Writer.Error!void {
    const affine = point.affineCoordinates();
    try cbor.writeMap(w, 5);
    try cbor.writeInt(w, 1); // kty: EC2
    try cbor.writeInt(w, 2);
    try cbor.writeInt(w, 3); // alg: ECDH-ES+HKDF-256
    try cbor.writeInt(w, -25);
    try cbor.writeInt(w, -1); // crv: P-256
    try cbor.writeInt(w, 1);
    try cbor.writeInt(w, -2);
    try cbor.writeBytes(w, &affine.x.toBytes(.big));
    try cbor.writeInt(w, -3);
    try cbor.writeBytes(w, &affine.y.toBytes(.big));
}

/// One side of the key agreement: `own` times `theirs`, and the secret from its `x`.
fn agree(protocol: PinProtocol, own: [32]u8, theirs: P256) ?SharedSecret {
    const product = theirs.mul(own, .big) catch return null;
    return .derive(protocol, product.affineCoordinates().x.toBytes(.big));
}

/// Gets a PIN token from the key: agrees a secret, then sends the PIN's hash encrypted
/// under it. A wrong PIN is `error.PinInvalid`, and uses up one of the key's retries.
pub fn getPinToken(
    channel: *Channel,
    protocol: PinProtocol,
    pin: []const u8,
) CommandError!PinToken {
    // CTAP: at least 4 Unicode code points, at most 63 bytes.
    const code_points = std.unicode.utf8CountCodepoints(pin) catch return error.PinInvalid;
    if (code_points < 4 or pin.len > 63) return error.PinInvalid;

    var out: [512]u8 = undefined;
    const agreement = try clientPin(channel, protocol, .get_key_agreement, "", 0, &out);
    const theirs = try readAgreementKey(agreement);
    // The ephemeral scalar, the secret, and the PIN's hash are wiped on every way out.
    var own = P256.scalar.random(channel.io, .big);
    defer secure.wipe(&own);
    const ours = P256.basePoint.mul(own, .big) catch return error.InvalidResponse;
    var secret = agree(protocol, own, theirs) orelse return error.InvalidResponse;
    defer secure.wipe(&secret.bytes);

    var pin_hash: [Sha256.digest_length]u8 = undefined;
    defer secure.wipe(&pin_hash);
    Sha256.hash(pin, &pin_hash, .{});
    var encrypted: [32]u8 = undefined;
    const pin_hash_enc = secret.encrypt(channel.io, pin_hash[0..16], &encrypted);
    var extra: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&extra);
    write: {
        cbor.writeInt(&w, 3) catch break :write;
        writeAgreementKey(&w, ours) catch break :write;
        cbor.writeInt(&w, 6) catch break :write;
        cbor.writeBytes(&w, pin_hash_enc) catch break :write;
        const response = try clientPin(channel, protocol, .get_pin_token, w.buffered(), 2, &out);
        var r = try mapEntry(response, 2) orelse return error.InvalidResponse;
        const wrapped = r.byteString() catch return error.InvalidResponse;
        var token: PinToken = .{ .protocol = protocol, .bytes = undefined, .len = 0 };
        const plain = secret.decrypt(wrapped, &token.bytes) orelse return error.InvalidResponse;
        if (plain.len == 0) return error.InvalidResponse;
        token.len = @intCast(plain.len);
        return token;
    }
    return error.RequestTooLarge;
}

/// Whether a HID report descriptor declares the FIDO usage page (0xF1D0) and the CTAPHID
/// usage (1) for a collection.
pub fn isFido(descriptor: []const u8) bool {
    var usage_page: u32 = 0;
    var usage: ?u32 = null;
    var pos: usize = 0;
    while (pos < descriptor.len) {
        const prefix = descriptor[pos];
        if (prefix == 0xfe) {
            // A long item: its data size, its tag, then the data.
            if (pos + 1 >= descriptor.len) return false;
            pos += 3 + @as(usize, descriptor[pos + 1]);
            continue;
        }
        const size: usize = switch (prefix & 0x03) {
            3 => 4,
            else => |n| n,
        };
        if (pos + 1 + size > descriptor.len) return false;
        var value: u32 = 0;
        for (descriptor[pos + 1 ..][0..size], 0..) |byte, i| {
            value |= @as(u32, byte) << @intCast(8 * i);
        }
        pos += 1 + size;
        switch (prefix & 0xfc) {
            0x04 => usage_page = value, // Usage Page (global).
            0x08 => usage = value, // Usage (local).
            0xa0 => { // Collection (main).
                if (usage_page == 0xf1d0 and usage == 1) return true;
                usage = null;
            },
            else => if (prefix & 0x0c == 0) {
                usage = null; // Other main items end the local state.
            },
        }
    }
    return false;
}

/// A FIDO key through Linux hidraw.
pub const Hidraw = struct {
    io: Io,
    file: Io.File,

    pub const OpenError = Io.File.OpenError;

    /// Opens `/dev/hidrawN`, which needs read and write access (a udev rule usually
    /// grants it to the logged-in user).
    pub fn open(io: Io, path: []const u8) OpenError!Hidraw {
        const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        return .{ .io = io, .file = file };
    }

    pub fn close(hid: *Hidraw) void {
        hid.file.close(hid.io);
        hid.* = undefined;
    }

    pub fn device(hid: *Hidraw) Device {
        return .{ .context = hid, .vtable = &.{ .write = write, .read = read } };
    }

    /// The device nodes of the FIDO keys plugged in, in `arena`; empty when there are
    /// none or the system has no hidraw.
    pub fn list(arena: Allocator, io: Io) Allocator.Error![]const []const u8 {
        var found: std.ArrayList([]const u8) = .empty;
        var dir = Io.Dir.openDirAbsolute(io, "/sys/class/hidraw", .{ .iterate = true }) catch
            return found.items;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            var path: [std.fs.max_path_bytes]u8 = undefined;
            const descriptor_path = std.fmt.bufPrint(&path, "{s}/device/report_descriptor", .{
                entry.name,
            }) catch continue;
            var descriptor: [4096]u8 = undefined;
            const bytes = dir.readFile(io, descriptor_path, &descriptor) catch continue;
            if (!isFido(bytes)) continue;
            try found.append(arena, try std.fmt.allocPrint(arena, "/dev/{s}", .{entry.name}));
        }
        std.mem.sort([]const u8, found.items, {}, lessThan);
        return found.items;
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    fn write(context: *anyopaque, report: *const Report) Device.Error!void {
        const hid: *Hidraw = @ptrCast(@alignCast(context));
        // hidraw takes the report ID first; CTAPHID uses none, which is 0.
        var buffer: [report_len + 1]u8 = undefined;
        buffer[0] = 0;
        @memcpy(buffer[1..], report);
        hid.file.writeStreamingAll(hid.io, &buffer) catch return error.DeviceFailed;
    }

    fn read(context: *anyopaque, report: *Report, timeout_ms: u32) Device.Error!void {
        const hid: *Hidraw = @ptrCast(@alignCast(context));
        if (comptime builtin.os.tag != .linux) return error.DeviceFailed;
        var fds = [_]std.posix.pollfd{.{
            .fd = hid.file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const timeout: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
        const ready = std.posix.poll(&fds, timeout) catch return error.DeviceFailed;
        if (ready == 0) return error.Timeout;
        const n = hid.file.readStreaming(hid.io, &.{report}) catch return error.DeviceFailed;
        if (n != report_len) return error.DeviceFailed;
    }
};

// Tests: a simulated key behind the `Device` interface.

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

/// A key that answers INIT, PING, getInfo, and getAssertion, signing with Ed25519. It
/// sends a keepalive and a stray packet for another channel before each CBOR reply.
const FakeKey = struct {
    pair: Ed25519.KeyPair,
    credential_id: []const u8 = "credential-one",
    cid: u32 = 0x0102_0304,
    sign_count: u32 = 9,
    /// Reports waiting to be read.
    outbox: [160]Report = undefined,
    out_len: usize = 0,
    out_read: usize = 0,
    /// The message being received.
    in: [Channel.max_payload]u8 = undefined,
    in_len: usize = 0,
    in_total: usize = 0,
    in_command: Command = .ping,
    in_cid: u32 = 0,
    /// With a PIN, getAssertion needs a PIN token.
    pin: ?[]const u8 = null,
    protocols: []const u8 = &.{ 2, 1 },
    retries: u8 = 8,
    /// This side of the last key agreement.
    agreement: [32]u8 = undefined,
    token: [32]u8 = @splat(0x5a),
    /// Answers another program's INIT on the broadcast channel first.
    foreign_init: bool = false,

    fn device(key: *FakeKey) Device {
        return .{ .context = key, .vtable = &.{ .write = write, .read = read } };
    }

    fn read(context: *anyopaque, report: *Report, _: u32) Device.Error!void {
        const key: *FakeKey = @ptrCast(@alignCast(context));
        if (key.out_read == key.out_len) return error.Timeout;
        report.* = key.outbox[key.out_read];
        key.out_read += 1;
    }

    fn write(context: *anyopaque, report: *const Report) Device.Error!void {
        const key: *FakeKey = @ptrCast(@alignCast(context));
        if (report[4] & 0x80 != 0) {
            key.in_cid = std.mem.readInt(u32, report[0..4], .big);
            key.in_command = @fromBackingInt(@intCast(@as(u7, @truncate(report[4]))));
            key.in_total = std.mem.readInt(u16, report[5..7], .big);
            key.in_len = @min(key.in_total, Channel.init_data);
            @memcpy(key.in[0..key.in_len], report[7..][0..key.in_len]);
        } else {
            const n = @min(key.in_total - key.in_len, Channel.cont_data);
            @memcpy(key.in[key.in_len..][0..n], report[5..][0..n]);
            key.in_len += n;
        }
        if (key.in_len == key.in_total) key.handle() catch return error.DeviceFailed;
    }

    fn handle(key: *FakeKey) !void {
        key.out_len = 0;
        key.out_read = 0;
        const payload = key.in[0..key.in_total];
        switch (key.in_command) {
            .init => {
                var reply: [17]u8 = undefined;
                @memcpy(reply[0..8], payload[0..8]);
                std.mem.writeInt(u32, reply[8..12], key.cid, .big);
                @memcpy(reply[12..], &[_]u8{ 2, 5, 4, 0, 0x04 });
                if (key.foreign_init) {
                    var other = reply;
                    other[0] ^= 0xff;
                    key.queue(Channel.broadcast, .init, &other);
                }
                key.queue(Channel.broadcast, .init, &reply);
            },
            .ping => key.queue(key.cid, .ping, payload),
            .cbor => {
                key.queue(0x0909_0909, .ping, "someone else's");
                const waiting: u8 = @backingInt(KeepaliveStatus.user_presence_needed);
                key.queue(key.cid, .keepalive, &.{waiting});
                var reply: [1024]u8 = undefined;
                var w: Io.Writer = .fixed(&reply);
                try key.answer(payload, &w);
                key.queue(key.cid, .cbor, w.buffered());
            },
            else => key.queue(key.cid, .@"error", &.{0x01}),
        }
    }

    fn answer(key: *FakeKey, payload: []const u8, w: *Io.Writer) !void {
        switch (payload[0]) {
            ctap2_get_info => {
                try w.writeByte(0);
                try cbor.writeMap(w, 4);
                try cbor.writeInt(w, 1);
                try cbor.writeArray(w, 2);
                try cbor.writeText(w, "FIDO_2_0");
                try cbor.writeText(w, "FIDO_2_1");
                try cbor.writeInt(w, 3);
                try cbor.writeBytes(w, &@as([16]u8, @splat(0xaa)));
                try cbor.writeInt(w, 4);
                try cbor.writeMap(w, 2);
                try cbor.writeText(w, "rk");
                try cbor.writeBool(w, true);
                try cbor.writeText(w, "clientPin");
                try cbor.writeBool(w, key.pin != null);
                try cbor.writeInt(w, 6);
                try cbor.writeArray(w, key.protocols.len);
                for (key.protocols) |protocol| try cbor.writeInt(w, protocol);
            },
            ctap2_client_pin => try key.answerPin(payload[1..], w),
            ctap2_get_assertion => {
                var r: cbor.Reader = .{ .bytes = payload[1..] };
                var rp_id: []const u8 = "";
                var hash: []const u8 = "";
                var allowed = false;
                var param: ?[]const u8 = null;
                var protocol: PinProtocol = .one;
                for (0..try r.map()) |_| switch (try r.int()) {
                    1 => rp_id = try r.textString(),
                    2 => hash = try r.byteString(),
                    3 => for (0..try r.array()) |_| {
                        if (std.mem.eql(u8, try readId(&r), key.credential_id)) allowed = true;
                    },
                    6 => param = try r.byteString(),
                    7 => protocol = @fromBackingInt(@intCast(try r.int())),
                    else => try r.skip(),
                };
                if (key.pin != null and param == null) return w.writeByte(0x36);
                if (param) |given| {
                    var expected: [HmacSha256.mac_length]u8 = undefined;
                    const want = pinAuthenticate(protocol, &key.token, hash, &expected);
                    if (!std.mem.eql(u8, given, want)) return w.writeByte(0x33);
                }
                if (!allowed) return w.writeByte(0x2e);
                var data: [37]u8 = undefined;
                Sha256.hash(rp_id, data[0..32], .{});
                // User present, and verified when a PIN token came.
                data[32] = if (param != null) 0x05 else 0x01;
                std.mem.writeInt(u32, data[33..37], key.sign_count, .big);
                var message: [37 + 32]u8 = undefined;
                @memcpy(message[0..37], &data);
                @memcpy(message[37..], hash);
                const signature = try key.pair.sign(&message, null);
                try w.writeByte(0);
                try cbor.writeMap(w, 3);
                try cbor.writeInt(w, 1);
                try writeCredential(w, key.credential_id);
                try cbor.writeInt(w, 2);
                try cbor.writeBytes(w, &data);
                try cbor.writeInt(w, 3);
                try cbor.writeBytes(w, &signature.toBytes());
            },
            else => try w.writeByte(0x01),
        }
    }

    /// authenticatorClientPIN: retries, key agreement, and PIN tokens.
    fn answerPin(key: *FakeKey, parameters: []const u8, w: *Io.Writer) !void {
        var r: cbor.Reader = .{ .bytes = parameters };
        var protocol: PinProtocol = .one;
        var command: u8 = 0;
        var platform: ?P256 = null;
        var pin_hash_enc: []const u8 = "";
        for (0..try r.map()) |_| switch (try r.int()) {
            1 => protocol = @fromBackingInt(@intCast(try r.int())),
            2 => command = @intCast(try r.int()),
            3 => platform = readCoseP256(&r) catch return w.writeByte(0x11),
            6 => pin_hash_enc = try r.byteString(),
            else => try r.skip(),
        };
        switch (command) {
            @backingInt(PinCommand.get_retries) => {
                try w.writeByte(0);
                try cbor.writeMap(w, 1);
                try cbor.writeInt(w, 3);
                try cbor.writeInt(w, key.retries);
            },
            @backingInt(PinCommand.get_key_agreement) => {
                key.agreement = P256.scalar.random(testing.io, .big);
                try w.writeByte(0);
                try cbor.writeMap(w, 1);
                try cbor.writeInt(w, 1);
                try writeAgreementKey(w, try P256.basePoint.mul(key.agreement, .big));
            },
            @backingInt(PinCommand.get_pin_token) => {
                const pin = key.pin orelse return w.writeByte(0x35);
                if (key.retries == 0) return w.writeByte(0x32);
                const secret = agree(protocol, key.agreement, platform.?).?;
                var plain: [32]u8 = undefined;
                const given = secret.decrypt(pin_hash_enc, &plain) orelse return w.writeByte(0x11);
                var want: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(pin, &want, .{});
                if (!std.mem.eql(u8, given, want[0..16])) {
                    key.retries -= 1;
                    return w.writeByte(if (key.retries == 0) 0x32 else 0x31);
                }
                key.retries = 8;
                var wrapped: [48]u8 = undefined;
                try w.writeByte(0);
                try cbor.writeMap(w, 1);
                try cbor.writeInt(w, 2);
                try cbor.writeBytes(w, secret.encrypt(testing.io, &key.token, &wrapped));
            },
            else => try w.writeByte(0x01),
        }
    }

    /// Splits a message into reports, as a key sends it.
    fn queue(key: *FakeKey, cid: u32, cmd: Command, payload: []const u8) void {
        var report: Report = @splat(0);
        std.mem.writeInt(u32, report[0..4], cid, .big);
        report[4] = 0x80 | @as(u8, @backingInt(cmd));
        std.mem.writeInt(u16, report[5..7], @intCast(payload.len), .big);
        const first = @min(payload.len, Channel.init_data);
        @memcpy(report[7..][0..first], payload[0..first]);
        key.push(report);
        var rest = payload[first..];
        var seq: u8 = 0;
        while (rest.len > 0) : (seq += 1) {
            report = @splat(0);
            std.mem.writeInt(u32, report[0..4], cid, .big);
            report[4] = seq;
            const n = @min(rest.len, Channel.cont_data);
            @memcpy(report[5..][0..n], rest[0..n]);
            key.push(report);
            rest = rest[n..];
        }
    }

    fn push(key: *FakeKey, report: Report) void {
        key.outbox[key.out_len] = report;
        key.out_len += 1;
    }
};

const Prompts = struct {
    count: usize = 0,

    fn keepalive(prompts: *Prompts) Keepalive {
        return .{ .context = prompts, .function = heard };
    }

    fn heard(context: *anyopaque, status: KeepaliveStatus) void {
        const prompts: *Prompts = @ptrCast(@alignCast(context));
        if (status == .user_presence_needed) prompts.count += 1;
    }
};

test "Channel: INIT, then messages over many packets both ways" {
    var key: FakeKey = .{ .pair = .generate(testing.io) };
    var channel: Channel = try .open(testing.io, key.device());
    try testing.expectEqual(key.cid, channel.cid);
    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);
    var out: [Channel.max_payload]u8 = undefined;
    try testing.expectEqualSlices(u8, &payload, try channel.transact(.ping, &payload, &out, null));
    try testing.expectError(error.ProtocolError, channel.transact(.msg, "", &out, null));
    var too_long: [Channel.max_payload + 1]u8 = undefined;
    try testing.expectError(error.RequestTooLarge, channel.transact(.ping, &too_long, &out, null));
    // Nothing answers: the read times out.
    key.out_len = 0;
    key.out_read = 0;
    const now: Io.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.Timeout, channel.receive(.ping, &out, null, now));
}

test "Channel: a reply longer than CTAPHID allows is refused, whatever the buffer" {
    // A key that announces 65535 bytes, then sends continuation packets forever.
    const Endless = struct {
        sent: usize = 0,

        fn read(context: *anyopaque, report: *Report, _: u32) Device.Error!void {
            const endless: *@This() = @ptrCast(@alignCast(context));
            report.* = @splat(0);
            std.mem.writeInt(u32, report[0..4], 7, .big);
            if (endless.sent == 0) {
                report[4] = 0x80 | @as(u8, @backingInt(Command.ping));
                std.mem.writeInt(u16, report[5..7], 0xffff, .big);
            } else report[4] = @truncate(endless.sent - 1);
            endless.sent += 1;
        }

        fn write(_: *anyopaque, _: *const Report) Device.Error!void {}
    };
    var endless: Endless = .{};
    const vtable: Device.VTable = .{ .read = Endless.read, .write = Endless.write };
    var channel: Channel = .{
        .device = .{ .context = &endless, .vtable = &vtable },
        .cid = 7,
        .io = testing.io,
    };
    const out = try testing.allocator.alloc(u8, 0xffff);
    defer testing.allocator.free(out);
    const now: Io.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.InvalidResponse, channel.receive(.ping, out, null, now));
}

/// A key that sends keepalives, and reports for another channel, until the test gives up
/// on the deadline.
const Chatty = struct {
    reads: usize = 0,

    const cid = 7;

    fn device(chatty: *Chatty) Device {
        return .{ .context = chatty, .vtable = &.{ .write = write, .read = read } };
    }

    fn read(context: *anyopaque, report: *Report, _: u32) Device.Error!void {
        const chatty: *Chatty = @ptrCast(@alignCast(context));
        chatty.reads += 1;
        if (chatty.reads > 50_000_000) return error.DeviceFailed;
        report.* = @splat(0);
        std.mem.writeInt(u32, report[0..4], if (chatty.reads % 2 == 0) cid else 9, .big);
        report[4] = 0x80 | @as(u8, @backingInt(Command.keepalive));
        report[6] = 1;
        report[7] = @backingInt(KeepaliveStatus.user_presence_needed);
    }

    fn write(_: *anyopaque, _: *const Report) Device.Error!void {}
};

test "Channel: a key that keeps sending keepalives meets the deadline" {
    var chatty: Chatty = .{};
    var channel: Channel = .{
        .device = chatty.device(),
        .cid = Chatty.cid,
        .io = testing.io,
        .deadline_ms = 20,
    };
    var out: [Channel.max_payload]u8 = undefined;
    try testing.expectError(error.Timeout, channel.transact(.ping, "", &out, null));
}

test "assert takes the request's timeout as a hint: 0 is the default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var key: FakeKey = .{ .pair = .generate(testing.io) };
    var channel: Channel = try .open(testing.io, key.device());
    channel.deadline_ms = 1234;
    for ([_]?u32{ 0, 1, null }) |timeout| {
        const options: webauthn.RequestOptions = .{
            .challenge = "0123456789abcdef",
            .timeout_ms = timeout,
            .allow_credentials = &.{.{ .id = key.credential_id }},
        };
        _ = try assert(arena.allocator(), &channel, options, "https://example.com", .{});
        try testing.expectEqual(1234, channel.deadline_ms);
    }
}

test "Channel.open waits past another program's INIT" {
    var key: FakeKey = .{ .pair = .generate(testing.io), .foreign_init = true };
    const channel: Channel = try .open(testing.io, key.device());
    try testing.expectEqual(key.cid, channel.cid);
}

test "getInfo" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var key: FakeKey = .{ .pair = .generate(testing.io) };
    var channel: Channel = try .open(testing.io, key.device());
    const info = try getInfo(arena.allocator(), &channel);
    try testing.expectEqual(2, info.versions.len);
    try testing.expectEqualStrings("FIDO_2_1", info.versions[1]);
    try testing.expectEqual(0xaa, info.aaguid[15]);
    try testing.expectEqual(false, info.client_pin);
    try testing.expectEqual(null, info.uv);
}

test "assert: an assertion from the key verifies with webauthn.verify" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var key: FakeKey = .{ .pair = .generate(testing.io) };
    var channel: Channel = try .open(testing.io, key.device());
    var prompts: Prompts = .{};
    const challenge = "0123456789abcdef";
    const options: webauthn.RequestOptions = .{
        .challenge = challenge,
        .allow_credentials = &.{ .{ .id = "other" }, .{ .id = key.credential_id } },
    };
    const origin = "https://example.com:8443";
    const assertion = try assert(a, &channel, options, origin, .{
        .keepalive = prompts.keepalive(),
    });
    try testing.expectEqual(1, prompts.count);
    try testing.expectEqualStrings(key.credential_id, assertion.raw_id);

    const credential: webauthn.Credential = .{
        .public_key = .{ .ed25519 = key.pair.public_key.toBytes() },
        .sign_count = 8,
    };
    const expected: webauthn.Expected = .{
        .challenge = challenge,
        .origin = origin,
        .rp_id = "example.com",
    };
    try testing.expectEqual(9, try webauthn.verify(a, assertion, expected, credential));

    const unknown: webauthn.RequestOptions = .{
        .challenge = challenge,
        .allow_credentials = &.{.{ .id = "other" }},
    };
    try testing.expectError(error.NoCredentials, assert(a, &channel, unknown, origin, .{}));
    try testing.expectError(error.InvalidOrigin, assert(a, &channel, unknown, "example", .{}));
    // The key holds a credential for another RP: an origin may not ask for its ID.
    var phish = options;
    phish.rp_id = "example.com";
    const evil = "https://evil.example";
    try testing.expectError(error.InvalidOrigin, assert(a, &channel, phish, evil, .{}));
}

test "assert with a PIN, over either protocol" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const challenge = "0123456789abcdef";
    const origin = "https://example.com";
    for ([_][]const u8{ &.{ 2, 1 }, &.{1} }) |protocols| {
        var key: FakeKey = .{
            .pair = .generate(testing.io),
            .pin = "1234",
            .protocols = protocols,
        };
        var channel: Channel = try .open(testing.io, key.device());
        const options: webauthn.RequestOptions = .{
            .challenge = challenge,
            .allow_credentials = &.{.{ .id = key.credential_id }},
            .user_verification = .required,
        };
        try testing.expectError(error.PinRequired, assert(a, &channel, options, origin, .{}));
        try testing.expectError(error.PinInvalid, assert(a, &channel, options, origin, .{
            .pin = "4321",
        }));
        try testing.expectEqual(7, try getPinRetries(&channel, preferredProtocol(protocols)));
        // Too short to be a PIN: refused without asking the key.
        try testing.expectError(error.PinInvalid, assert(a, &channel, options, origin, .{
            .pin = "12",
        }));
        try testing.expectEqual(7, try getPinRetries(&channel, .one));

        const assertion = try assert(a, &channel, options, origin, .{ .pin = "1234" });
        const credential: webauthn.Credential = .{
            .public_key = .{ .ed25519 = key.pair.public_key.toBytes() },
        };
        const expected: webauthn.Expected = .{
            .challenge = challenge,
            .origin = origin,
            .rp_id = "example.com",
            .user_verification = .required,
        };
        try testing.expectEqual(9, try webauthn.verify(a, assertion, expected, credential));
        try testing.expectEqual(8, key.retries);
    }
}

test "PIN protocol one encrypts with AES-256-CBC (NIST SP 800-38A, F.2.5)" {
    const hex = std.fmt.hexToBytes;
    var key: [32]u8 = undefined;
    _ = try hex(&key, "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    var iv: [16]u8 = undefined;
    _ = try hex(&iv, "000102030405060708090a0b0c0d0e0f");
    var plain: [32]u8 = undefined;
    _ = try hex(&plain, "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
    var want: [32]u8 = undefined;
    _ = try hex(&want, "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d");
    var got: [32]u8 = undefined;
    cbcEncrypt(key, iv, &plain, &got);
    try testing.expectEqualSlices(u8, &want, &got);
    var back: [32]u8 = undefined;
    cbcDecrypt(key, iv, &got, &back);
    try testing.expectEqualSlices(u8, &plain, &back);
}

test "readId skips whole entries, whatever their key" {
    // {1: "id", h'bb': 0}: a key that is not text skipped alone made its value the next key.
    var r: cbor.Reader = .{ .bytes = &.{ 0xa2, 0x01, 0x62, 'i', 'd', 0x41, 0xbb, 0x00 } };
    try testing.expectError(error.InvalidCbor, readId(&r));
    // {1: 2, "id": h'aa'}
    r = .{ .bytes = &.{ 0xa2, 0x01, 0x02, 0x62, 'i', 'd', 0x41, 0xaa } };
    try testing.expectEqualSlices(u8, &.{0xaa}, try readId(&r));
    try testing.expect(r.atEnd());
}

test statusError {
    try testing.expectEqual(error.PinRequired, statusError(0x36));
    try testing.expectEqual(error.PinInvalid, statusError(0x31));
    try testing.expectEqual(error.PinBlocked, statusError(0x32));
    try testing.expectEqual(error.AuthenticatorError, statusError(0x7f));
}

test isFido {
    // The descriptor of a typical FIDO key.
    const fido = [_]u8{
        0x06, 0xd0, 0xf1, 0x09, 0x01, 0xa1, 0x01, 0x09, 0x20, 0x15, 0x00, 0x26, 0xff, 0x00,
        0x75, 0x08, 0x95, 0x40, 0x81, 0x02, 0x09, 0x21, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75,
        0x08, 0x95, 0x40, 0x91, 0x02, 0xc0,
    };
    try testing.expect(isFido(&fido));
    // A keyboard: Generic Desktop, usage 6.
    const keyboard = [_]u8{ 0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0xc0 };
    try testing.expect(!isFido(&keyboard));
    try testing.expect(!isFido(fido[0..2]));
    try testing.expect(!isFido(""));
}

test "Hidraw.list finds no key where there is none" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const paths = try Hidraw.list(arena.allocator(), testing.io);
    for (paths) |path| try testing.expect(std.mem.startsWith(u8, path, "/dev/hidraw"));
    _ = &Hidraw.open;
    _ = &Hidraw.device;
}
