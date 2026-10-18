//! WebAuthn (Level 3) for command-line programs: the user-presence prompt, request options
//! and assertion responses with their JSON forms (binary fields as base64url), client data
//! construction, and the checks a relying party makes on an assertion.
//!
//! **Not implemented: the authenticator transport.** Talking to a security key over USB HID
//! (CTAP2/CTAPHID), NFC, or BLE is on the roadmap. Until then this module covers both ends
//! of the exchange that do not touch hardware: a CLI that obtains an assertion some other
//! way (a browser hand-off, a platform helper), and a server checking what it receives.
//! `verifyAssertion` makes the checks that need no stored state; `verify` adds the
//! signature, ES256 or EdDSA, against the credential's public key (`PublicKey.fromCose`
//! reads the COSE key registration returned), and the signature counter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64url = std.base64.url_safe_no_pad;
const JsonObject = @import("JsonObject.zig");
const secure = @import("secure.zig");
const cbor = @import("cbor.zig");
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

/// The line shown while waiting for the user to touch the key, without a relying party.
pub const presence_prompt = "Touch your security key to continue.";

/// Writes the user-presence prompt, naming the relying party when there is one.
pub fn writePresencePrompt(writer: *Io.Writer, rp_id: ?[]const u8) Io.Writer.Error!void {
    const id = rp_id orelse return writer.writeAll(presence_prompt ++ "\n");
    try writer.print("Touch your security key to sign in to {s}.\n", .{id});
}

/// Whether the authenticator must verify the user (PIN, biometrics).
pub const UserVerification = enum { required, preferred, discouraged };

/// How the client may reach an authenticator. Unknown values are ignored when parsing.
pub const Transport = enum {
    usb,
    nfc,
    ble,
    hybrid,
    internal,
    smart_card,

    fn jsonName(transport: Transport) []const u8 {
        return if (transport == .smart_card) "smart-card" else @tagName(transport);
    }

    fn fromJsonName(name: []const u8) ?Transport {
        if (std.mem.eql(u8, name, "smart-card")) return .smart_card;
        if (std.mem.eql(u8, name, "smart_card")) return null;
        return std.meta.stringToEnum(Transport, name);
    }
};

/// A credential the relying party will accept (`PublicKeyCredentialDescriptor`).
pub const CredentialDescriptor = struct {
    /// The raw credential ID.
    id: []const u8,
    transports: []const Transport = &.{},
};

/// `PublicKeyCredentialRequestOptions`: what the relying party asks the client to sign.
pub const RequestOptions = struct {
    /// Raw bytes, at least 16 of them, fresh for each ceremony.
    challenge: []const u8,
    timeout_ms: ?u32 = null,
    rp_id: ?[]const u8 = null,
    allow_credentials: []const CredentialDescriptor = &.{},
    user_verification: UserVerification = .preferred,

    /// Writes the JSON form (`PublicKeyCredentialRequestOptionsJSON`).
    pub fn writeJson(options: RequestOptions, writer: *Io.Writer) Io.Writer.Error!void {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("challenge");
        try writeBase64(&jw, options.challenge);
        if (options.timeout_ms) |ms| {
            try jw.objectField("timeout");
            try jw.write(ms);
        }
        if (options.rp_id) |id| {
            try jw.objectField("rpId");
            try jw.write(id);
        }
        try jw.objectField("allowCredentials");
        try jw.beginArray();
        for (options.allow_credentials) |credential| try writeDescriptor(&jw, credential);
        try jw.endArray();
        try jw.objectField("userVerification");
        try jw.write(@tagName(options.user_verification));
        try jw.endObject();
    }

    /// Parses the JSON form into `arena`.
    pub fn parseJson(arena: Allocator, json: []const u8) JsonObject.Error!RequestOptions {
        const object: JsonObject = try .parse(arena, json);
        const verification = try object.optionalString("userVerification") orelse "preferred";
        return .{
            .challenge = try object.bytes(arena, "challenge"),
            .timeout_ms = try object.optionalUnsigned("timeout"),
            .rp_id = try object.optionalString("rpId"),
            .allow_credentials = try parseDescriptors(arena, object, "allowCredentials"),
            .user_verification = std.meta.stringToEnum(UserVerification, verification) orelse
                return error.InvalidField,
        };
    }
};

fn writeDescriptor(jw: *std.json.Stringify, credential: CredentialDescriptor) Io.Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("public-key");
    try jw.objectField("id");
    try writeBase64(jw, credential.id);
    if (credential.transports.len > 0) {
        try jw.objectField("transports");
        try jw.beginArray();
        for (credential.transports) |t| try jw.write(t.jsonName());
        try jw.endArray();
    }
    try jw.endObject();
}

fn parseDescriptors(
    arena: Allocator,
    object: JsonObject,
    field: []const u8,
) JsonObject.Error![]CredentialDescriptor {
    const value = object.get(field) orelse return &.{};
    if (value != .array) return error.InvalidField;
    const items = value.array.items;
    const out = try arena.alloc(CredentialDescriptor, items.len);
    for (items, out) |item, *descriptor| {
        if (item != .object) return error.InvalidField;
        const entry: JsonObject = .{ .map = item.object };
        if (!std.mem.eql(u8, try entry.string("type"), "public-key")) return error.InvalidField;
        descriptor.* = .{
            .id = try entry.bytes(arena, "id"),
            .transports = try parseTransports(arena, entry),
        };
    }
    return out;
}

fn parseTransports(arena: Allocator, entry: JsonObject) JsonObject.Error![]Transport {
    const value = entry.get("transports") orelse return &.{};
    if (value != .array) return error.InvalidField;
    var list: std.ArrayList(Transport) = .empty;
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidField;
        const transport = Transport.fromJsonName(item.string) orelse continue;
        try list.append(arena, transport);
    }
    return list.items;
}

fn writeBase64(jw: *std.json.Stringify, bytes: []const u8) Io.Writer.Error!void {
    // base64url needs no JSON escaping, so it is written as raw string content.
    try jw.beginWriteRaw();
    defer jw.endWriteRaw();
    try jw.writer.writeByte('"');
    try base64url.Encoder.encodeWriter(jw.writer, bytes);
    try jw.writer.writeByte('"');
}

/// A `PublicKeyCredential` carrying an `AuthenticatorAssertionResponse`.
pub const Assertion = struct {
    /// The raw credential ID (`rawId`; `id` is its base64url form).
    raw_id: []const u8,
    /// The exact bytes the authenticator signed over, together with `authenticator_data`.
    client_data_json: []const u8,
    authenticator_data: []const u8,
    signature: []const u8,
    user_handle: ?[]const u8 = null,
    /// `sys` or `cross-platform`, when the client reports it.
    authenticator_attachment: ?[]const u8 = null,

    /// Writes the JSON form (`AuthenticationResponseJSON`).
    pub fn writeJson(assertion: Assertion, writer: *Io.Writer) Io.Writer.Error!void {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("id");
        try writeBase64(&jw, assertion.raw_id);
        try jw.objectField("rawId");
        try writeBase64(&jw, assertion.raw_id);
        try jw.objectField("type");
        try jw.write("public-key");
        try jw.objectField("response");
        try jw.beginObject();
        try jw.objectField("clientDataJSON");
        try writeBase64(&jw, assertion.client_data_json);
        try jw.objectField("authenticatorData");
        try writeBase64(&jw, assertion.authenticator_data);
        try jw.objectField("signature");
        try writeBase64(&jw, assertion.signature);
        if (assertion.user_handle) |handle| {
            try jw.objectField("userHandle");
            try writeBase64(&jw, handle);
        }
        try jw.endObject();
        if (assertion.authenticator_attachment) |attachment| {
            try jw.objectField("authenticatorAttachment");
            try jw.write(attachment);
        }
        try jw.objectField("clientExtensionResults");
        try jw.beginObject();
        try jw.endObject();
        try jw.endObject();
    }

    /// Parses the JSON form into `arena`. `id` must match `rawId`.
    pub fn parseJson(arena: Allocator, json: []const u8) JsonObject.Error!Assertion {
        const object: JsonObject = try .parse(arena, json);
        if (!std.mem.eql(u8, try object.string("type"), "public-key")) return error.InvalidField;
        const raw_id = try object.bytes(arena, "rawId");
        const id = try object.bytes(arena, "id");
        if (!std.mem.eql(u8, id, raw_id)) return error.InvalidField;
        const response = try object.optionalObject("response") orelse return error.MissingField;
        return .{
            .raw_id = raw_id,
            .client_data_json = try response.bytes(arena, "clientDataJSON"),
            .authenticator_data = try response.bytes(arena, "authenticatorData"),
            .signature = try response.bytes(arena, "signature"),
            .user_handle = try response.optionalBytes(arena, "userHandle"),
            .authenticator_attachment = try object.optionalString("authenticatorAttachment"),
        };
    }
};

/// Which ceremony client data belongs to.
pub const Ceremony = enum {
    get,
    create,

    fn typeName(ceremony: Ceremony) []const u8 {
        return switch (ceremony) {
            .get => "webauthn.get",
            .create => "webauthn.create",
        };
    }
};

/// `CollectedClientData`: what the client binds the signature to.
pub const ClientData = struct {
    ceremony: Ceremony = .get,
    /// The raw challenge from the request options.
    challenge: []const u8,
    /// The caller's origin, such as `https://example.com`.
    origin: []const u8,
    cross_origin: bool = false,
    top_origin: ?[]const u8 = null,

    /// Writes clientDataJSON in the exact serialization of WebAuthn §5.8.1.1, so a relying
    /// party using the limited verification algorithm accepts it.
    pub fn writeJson(data: ClientData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("{\"type\":");
        try writeCcdString(writer, data.ceremony.typeName());
        try writer.writeAll(",\"challenge\":\"");
        try base64url.Encoder.encodeWriter(writer, data.challenge);
        try writer.writeAll("\",\"origin\":");
        try writeCcdString(writer, data.origin);
        try writer.print(",\"crossOrigin\":{}", .{data.cross_origin});
        if (data.top_origin) |top| {
            try writer.writeAll(",\"topOrigin\":");
            try writeCcdString(writer, top);
        }
        try writer.writeByte('}');
    }
};

/// `CCDToString`: quotes, escapes `"` and `\`, and writes control characters as `\u00xx`.
fn writeCcdString(writer: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '"', '\\' => try writer.writeAll(&.{ '\\', c }),
        0...0x1f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

/// What the relying party expects of an assertion.
pub const Expected = struct {
    ceremony: Ceremony = .get,
    /// The raw challenge it issued.
    challenge: []const u8,
    /// Its origin, compared exactly.
    origin: []const u8,
    /// Its RP ID; the authenticator data must carry its SHA-256.
    rp_id: []const u8,
    allow_cross_origin: bool = false,
    user_verification: UserVerification = .preferred,
};

/// Why a check failed.
pub const VerifyError = JsonObject.Error || error{
    /// `type` is not the expected ceremony.
    WrongCeremony,
    ChallengeMismatch,
    OriginMismatch,
    /// `crossOrigin` is true and that was not allowed.
    CrossOrigin,
    /// The authenticator data is shorter than 37 bytes.
    InvalidAuthenticatorData,
    /// The authenticator data is for another RP ID.
    RpIdMismatch,
    /// The user-present flag is clear.
    UserNotPresent,
    /// Verification was required and the user-verified flag is clear.
    UserNotVerified,
    /// The signature does not verify against the credential's public key.
    SignatureInvalid,
    /// The signature counter did not grow: the authenticator may have been cloned.
    SignCountRegressed,
};

/// Checks clientDataJSON against `expected`: ceremony, challenge (in constant time),
/// origin, and cross-origin use. Scratch memory comes from `arena`.
pub fn verifyClientData(
    arena: Allocator,
    client_data_json: []const u8,
    expected: Expected,
) VerifyError!void {
    const object: JsonObject = try .parse(arena, client_data_json);
    const ceremony = try object.string("type");
    if (!std.mem.eql(u8, ceremony, expected.ceremony.typeName())) return error.WrongCeremony;
    const challenge = try object.bytes(arena, "challenge");
    if (!secure.eql(challenge, expected.challenge)) return error.ChallengeMismatch;
    if (!std.mem.eql(u8, try object.string("origin"), expected.origin)) {
        return error.OriginMismatch;
    }
    const cross_origin = try object.optionalBool("crossOrigin") orelse false;
    if (cross_origin and !expected.allow_cross_origin) return error.CrossOrigin;
}

/// The fixed part of authenticator data (WebAuthn §6.1).
pub const AuthenticatorData = struct {
    rp_id_hash: [Sha256.digest_length]u8,
    flags: Flags,
    sign_count: u32,

    /// The flags byte.
    pub const Flags = packed struct(u8) {
        user_present: bool,
        reserved1: bool,
        user_verified: bool,
        backup_eligible: bool,
        backed_up: bool,
        reserved2: bool,
        attested_credential_data: bool,
        extension_data: bool,
    };

    /// The length of the fixed part.
    pub const min_len = Sha256.digest_length + 1 + 4;

    /// Reads the fixed part; see `attestedCredential` for what a registration adds.
    pub fn parse(bytes: []const u8) error{InvalidAuthenticatorData}!AuthenticatorData {
        if (bytes.len < min_len) return error.InvalidAuthenticatorData;
        return .{
            .rp_id_hash = bytes[0..Sha256.digest_length].*,
            .flags = @bitCast(bytes[Sha256.digest_length]),
            .sign_count = std.mem.readInt(u32, bytes[Sha256.digest_length + 1 ..][0..4], .big),
        };
    }

    /// Checks that the data is for `rp_id`.
    pub fn checkRpId(data: AuthenticatorData, rp_id: []const u8) error{RpIdMismatch}!void {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(rp_id, &digest, .{});
        if (!std.mem.eql(u8, &digest, &data.rp_id_hash)) return error.RpIdMismatch;
    }
};

/// Every check of WebAuthn §7.2 that needs no stored state: client data, RP ID hash,
/// user presence, and user verification when `expected` requires it. The signature
/// over `authenticator_data ++ SHA-256(client_data_json)` and the signature counter are
/// left to the caller, who holds the public key and the last count.
pub fn verifyAssertion(
    arena: Allocator,
    assertion: Assertion,
    expected: Expected,
) VerifyError!void {
    try verifyClientData(arena, assertion.client_data_json, expected);
    const data: AuthenticatorData = try .parse(assertion.authenticator_data);
    try data.checkRpId(expected.rp_id);
    if (!data.flags.user_present) return error.UserNotPresent;
    if (expected.user_verification == .required and !data.flags.user_verified) {
        return error.UserNotVerified;
    }
}

/// A credential's public key, as the relying party stores it.
pub const PublicKey = union(enum) {
    /// ECDSA over P-256 with SHA-256 (COSE algorithm -7): an uncompressed SEC1 point.
    es256: [EcdsaP256.PublicKey.uncompressed_sec1_encoded_length]u8,
    /// EdDSA over Ed25519 (COSE algorithm -8).
    ed25519: [Ed25519.PublicKey.encoded_length]u8,

    pub const Error = error{
        /// Not a COSE key, or one missing a coordinate.
        InvalidPublicKey,
        /// A key type, curve, or algorithm other than ES256 and EdDSA over Ed25519.
        UnsupportedAlgorithm,
    };

    /// Reads a COSE_Key (RFC 9053): the CBOR map in the attested credential data a
    /// registration returns.
    pub fn fromCose(bytes: []const u8) Error!PublicKey {
        var reader: cbor.Reader = .{ .bytes = bytes };
        const entries = reader.map() catch return error.InvalidPublicKey;
        var kty: ?i64 = null;
        var alg: ?i64 = null;
        var crv: ?i64 = null;
        var x: ?[]const u8 = null;
        var y: ?[]const u8 = null;
        for (0..entries) |_| {
            if ((reader.peek() catch return error.InvalidPublicKey) == .text) {
                // A text label, for a parameter outside the registry: not one of ours.
                reader.skip() catch return error.InvalidPublicKey;
                reader.skip() catch return error.InvalidPublicKey;
                continue;
            }
            const label = reader.int() catch return error.InvalidPublicKey;
            switch (label) {
                1 => kty = reader.int() catch return error.InvalidPublicKey,
                3 => alg = reader.int() catch return error.InvalidPublicKey,
                -1 => crv = reader.int() catch return error.InvalidPublicKey,
                -2 => x = reader.byteString() catch return error.InvalidPublicKey,
                -3 => y = reader.byteString() catch return error.InvalidPublicKey,
                else => reader.skip() catch return error.InvalidPublicKey,
            }
        }
        if (!reader.atEnd()) return error.InvalidPublicKey;
        const ec2 = 2;
        const okp = 1;
        const es256 = -7;
        const eddsa = -8;
        const p256 = 1;
        const ed25519 = 6;
        const x_bytes = x orelse return error.InvalidPublicKey;
        if (kty == ec2 and alg orelse es256 == es256 and crv == p256) {
            const y_bytes = y orelse return error.InvalidPublicKey;
            if (x_bytes.len != 32 or y_bytes.len != 32) return error.InvalidPublicKey;
            var point: [65]u8 = undefined;
            point[0] = 0x04;
            @memcpy(point[1..33], x_bytes);
            @memcpy(point[33..], y_bytes);
            _ = EcdsaP256.PublicKey.fromSec1(&point) catch return error.InvalidPublicKey;
            return .{ .es256 = point };
        }
        if (kty == okp and alg orelse eddsa == eddsa and crv == ed25519) {
            if (x_bytes.len != Ed25519.PublicKey.encoded_length) return error.InvalidPublicKey;
            return .{ .ed25519 = x_bytes[0..Ed25519.PublicKey.encoded_length].* };
        }
        return error.UnsupportedAlgorithm;
    }
};

/// Checks `assertion.signature` over `authenticator_data ++ SHA-256(client_data_json)`.
/// An ES256 signature is DER-encoded, as authenticators send it.
pub fn verifySignature(key: PublicKey, assertion: Assertion) error{SignatureInvalid}!void {
    var client_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(assertion.client_data_json, &client_hash, .{});
    switch (key) {
        .es256 => |point| {
            const public_key = EcdsaP256.PublicKey.fromSec1(&point) catch
                return error.SignatureInvalid;
            const signature = EcdsaP256.Signature.fromDer(assertion.signature) catch
                return error.SignatureInvalid;
            var verifier = signature.verifier(public_key) catch return error.SignatureInvalid;
            verifier.update(assertion.authenticator_data);
            verifier.update(&client_hash);
            verifier.verify() catch return error.SignatureInvalid;
        },
        .ed25519 => |bytes| {
            const public_key = Ed25519.PublicKey.fromBytes(bytes) catch
                return error.SignatureInvalid;
            if (assertion.signature.len != Ed25519.Signature.encoded_length) {
                return error.SignatureInvalid;
            }
            const signature: Ed25519.Signature = .fromBytes(assertion.signature[0..64].*);
            var verifier = signature.verifier(public_key) catch return error.SignatureInvalid;
            verifier.update(assertion.authenticator_data);
            verifier.update(&client_hash);
            verifier.verify() catch return error.SignatureInvalid;
        },
    }
}

/// The signature counter rule of WebAuthn §7.2 step 22: when either count is nonzero the
/// received one must be greater than the stored one. Authenticators without a counter
/// always send zero.
pub fn checkSignCount(stored: u32, received: u32) error{SignCountRegressed}!void {
    if ((stored != 0 or received != 0) and received <= stored) return error.SignCountRegressed;
}

/// What the relying party keeps for a registered credential.
pub const Credential = struct {
    public_key: PublicKey,
    /// The last signature count seen.
    sign_count: u32 = 0,
};

/// The relying party a credential is created for (`PublicKeyCredentialRpEntity`).
pub const RelyingParty = struct {
    /// Null for the host of the caller's origin.
    id: ?[]const u8 = null,
    name: []const u8,
};

/// The account a credential is created for (`PublicKeyCredentialUserEntity`).
pub const User = struct {
    /// The user handle: opaque bytes, at most 64, with no personal information.
    id: []const u8,
    name: []const u8,
    display_name: []const u8,
};

/// COSE algorithm numbers `PublicKey` reads.
pub const cose_es256 = -7;
pub const cose_eddsa = -8;

/// `PublicKeyCredentialCreationOptions`: what the relying party asks the client to create.
/// Attestation is not asked for.
pub const CreationOptions = struct {
    /// Raw bytes, at least 16 of them, fresh for each ceremony.
    challenge: []const u8,
    rp: RelyingParty,
    user: User,
    /// In order of preference; the default is what `PublicKey` can verify.
    algorithms: []const i32 = &.{ cose_es256, cose_eddsa },
    timeout_ms: ?u32 = null,
    /// Credentials the account already has, so the same authenticator is not added twice.
    exclude_credentials: []const CredentialDescriptor = &.{},
    user_verification: UserVerification = .preferred,
    /// Whether the credential must be discoverable (a passkey found without its ID).
    resident_key: bool = false,

    /// Parses the JSON form (`PublicKeyCredentialCreationOptionsJSON`) into `arena`.
    /// `attestation` and `extensions` are ignored: attestation is never asked for.
    pub fn parseJson(arena: Allocator, json: []const u8) JsonObject.Error!CreationOptions {
        const object: JsonObject = try .parse(arena, json);
        const rp = try object.optionalObject("rp") orelse return error.MissingField;
        const user = try object.optionalObject("user") orelse return error.MissingField;
        var options: CreationOptions = .{
            .challenge = try object.bytes(arena, "challenge"),
            .rp = .{ .id = try rp.optionalString("id"), .name = try rp.string("name") },
            .user = .{
                .id = try user.bytes(arena, "id"),
                .name = try user.string("name"),
                .display_name = try user.string("displayName"),
            },
            .algorithms = try parseAlgorithms(arena, object),
            .timeout_ms = try object.optionalUnsigned("timeout"),
            .exclude_credentials = try parseDescriptors(arena, object, "excludeCredentials"),
        };
        if (try object.optionalObject("authenticatorSelection")) |selection| {
            const verification = try selection.optionalString("userVerification") orelse "preferred";
            options.user_verification = std.meta.stringToEnum(UserVerification, verification) orelse
                return error.InvalidField;
            const resident = try selection.optionalString("residentKey");
            options.resident_key = if (resident) |r|
                std.mem.eql(u8, r, "required")
            else
                try selection.optionalBool("requireResidentKey") orelse false;
        }
        return options;
    }
};

/// `pubKeyCredParams`: the COSE algorithms of its public-key entries, in order.
fn parseAlgorithms(arena: Allocator, object: JsonObject) JsonObject.Error![]const i32 {
    const value = object.get("pubKeyCredParams") orelse return error.MissingField;
    if (value != .array) return error.InvalidField;
    var list: std.ArrayList(i32) = .empty;
    for (value.array.items) |item| {
        if (item != .object) return error.InvalidField;
        const entry: JsonObject = .{ .map = item.object };
        if (!std.mem.eql(u8, try entry.string("type"), "public-key")) continue;
        const alg = entry.get("alg") orelse return error.MissingField;
        if (alg != .integer) return error.InvalidField;
        try list.append(arena, std.math.cast(i32, alg.integer) orelse return error.InvalidField);
    }
    return list.items;
}

/// The credential in a registration's authenticator data.
pub const AttestedCredential = struct {
    aaguid: [16]u8,
    id: []const u8,
    /// The COSE_Key, for `PublicKey.fromCose`.
    public_key: []const u8,
};

/// Reads the attested credential data that follows the fixed part of `bytes`.
pub fn attestedCredential(bytes: []const u8) error{InvalidAuthenticatorData}!AttestedCredential {
    const data: AuthenticatorData = try .parse(bytes);
    if (!data.flags.attested_credential_data) return error.InvalidAuthenticatorData;
    const rest = bytes[AuthenticatorData.min_len..];
    if (rest.len < 18) return error.InvalidAuthenticatorData;
    const id_len = std.mem.readInt(u16, rest[16..18], .big);
    if (rest.len - 18 < id_len) return error.InvalidAuthenticatorData;
    const key = rest[18 + id_len ..];
    var reader: cbor.Reader = .{ .bytes = key };
    reader.skip() catch return error.InvalidAuthenticatorData;
    return .{ .aaguid = rest[0..16].*, .id = rest[18..][0..id_len], .public_key = key[0..reader.pos] };
}

/// A `PublicKeyCredential` carrying an `AuthenticatorAttestationResponse`.
pub const Registration = struct {
    /// The raw credential ID.
    raw_id: []const u8,
    client_data_json: []const u8,
    /// Holds the credential: see `attestedCredential`.
    authenticator_data: []const u8,
    /// The CBOR attestation object, for a relying party that checks attestation.
    attestation_object: []const u8,

    /// What the relying party keeps: the public key and the first signature count. The
    /// caller still checks clientDataJSON (type `webauthn.create`, challenge, origin).
    pub fn credential(r: Registration) (PublicKey.Error || error{InvalidAuthenticatorData})!Credential {
        const attested = try attestedCredential(r.authenticator_data);
        if (!std.mem.eql(u8, attested.id, r.raw_id)) return error.InvalidAuthenticatorData;
        const data: AuthenticatorData = try .parse(r.authenticator_data);
        return .{ .public_key = try .fromCose(attested.public_key), .sign_count = data.sign_count };
    }

    /// Writes the JSON form (`RegistrationResponseJSON`), without `publicKey`, which a
    /// relying party can read from the authenticator data instead.
    pub fn writeJson(r: Registration, writer: *Io.Writer) Io.Writer.Error!void {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("id");
        try writeBase64(&jw, r.raw_id);
        try jw.objectField("rawId");
        try writeBase64(&jw, r.raw_id);
        try jw.objectField("type");
        try jw.write("public-key");
        try jw.objectField("response");
        try jw.beginObject();
        try jw.objectField("clientDataJSON");
        try writeBase64(&jw, r.client_data_json);
        try jw.objectField("attestationObject");
        try writeBase64(&jw, r.attestation_object);
        try jw.objectField("authenticatorData");
        try writeBase64(&jw, r.authenticator_data);
        try jw.endObject();
        try jw.objectField("clientExtensionResults");
        try jw.beginObject();
        try jw.endObject();
        try jw.endObject();
    }
};

/// Every check of WebAuthn §7.2: `verifyAssertion`, the signature against the
/// credential's public key, and the signature counter. Returns the count to store.
pub fn verify(
    arena: Allocator,
    assertion: Assertion,
    expected: Expected,
    credential: Credential,
) VerifyError!u32 {
    try verifyAssertion(arena, assertion, expected);
    try verifySignature(credential.public_key, assertion);
    const data: AuthenticatorData = try .parse(assertion.authenticator_data);
    try checkSignCount(credential.sign_count, data.sign_count);
    return data.sign_count;
}

// Tests ---------------------------------------------------------------------------------

test writePresencePrompt {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writePresencePrompt(&w, "example.com");
    try writePresencePrompt(&w, null);
    try std.testing.expectEqualStrings("Touch your security key to sign in to example.com.\n" ++
        "Touch your security key to continue.\n", w.buffered());
}

test "RequestOptions JSON round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options: RequestOptions = .{
        .challenge = &.{ 0xfb, 0xff, 0x00, 0x01 },
        .timeout_ms = 60000,
        .rp_id = "example.com",
        .allow_credentials = &.{
            .{ .id = "cred-1", .transports = &.{ .usb, .smart_card } },
            .{ .id = &.{0xff} },
        },
        .user_verification = .required,
    };
    var out: Io.Writer.Allocating = .init(a);
    try options.writeJson(&out.writer);
    try std.testing.expectEqualStrings(
        \\{"challenge":"-_8AAQ","timeout":60000,"rpId":"example.com","allowCredentials":[
    ++
        \\{"type":"public-key","id":"Y3JlZC0x","transports":["usb","smart-card"]},
    ++
        \\{"type":"public-key","id":"_w"}],"userVerification":"required"}
    , out.written());

    const back: RequestOptions = try .parseJson(a, out.written());
    try std.testing.expectEqualSlices(u8, options.challenge, back.challenge);
    try std.testing.expectEqual(60000, back.timeout_ms);
    try std.testing.expectEqualStrings("example.com", back.rp_id.?);
    try std.testing.expectEqual(2, back.allow_credentials.len);
    try std.testing.expectEqualStrings("cred-1", back.allow_credentials[0].id);
    const transports = back.allow_credentials[0].transports;
    try std.testing.expectEqualSlices(Transport, &.{ .usb, .smart_card }, transports);
    try std.testing.expectEqual(.required, back.user_verification);
}

test "RequestOptions.parseJson defaults and refusals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const minimal: RequestOptions = try .parseJson(a,
        \\{"challenge":"AAAA","allowCredentials":[
    ++
        \\{"type":"public-key","id":"AA","transports":["usb","laser"]}]}
    );
    try std.testing.expectEqual(.preferred, minimal.user_verification);
    try std.testing.expectEqual(null, minimal.rp_id);
    try std.testing.expectEqualSlices(Transport, &.{.usb}, minimal.allow_credentials[0].transports);
    const e = std.testing.expectError;
    try e(error.MissingField, RequestOptions.parseJson(a, "{}"));
    try e(error.InvalidField, RequestOptions.parseJson(a, "{\"challenge\":\"a+b\"}"));
    try e(error.InvalidField, RequestOptions.parseJson(a,
        \\{"challenge":"AA","userVerification":"always"}
    ));
    try e(error.InvalidField, RequestOptions.parseJson(a,
        \\{"challenge":"AA","allowCredentials":[{"type":"password","id":"AA"}]}
    ));
}

test "Assertion JSON round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const assertion: Assertion = .{
        .raw_id = &.{ 1, 2, 3 },
        .client_data_json = "{\"type\":\"webauthn.get\"}",
        .authenticator_data = &.{ 9, 9 },
        .signature = &.{ 0x30, 0x45 },
        .user_handle = "user-7",
        .authenticator_attachment = "cross-platform",
    };
    var out: Io.Writer.Allocating = .init(a);
    try assertion.writeJson(&out.writer);
    const back: Assertion = try .parseJson(a, out.written());
    try std.testing.expectEqualSlices(u8, assertion.raw_id, back.raw_id);
    try std.testing.expectEqualStrings(assertion.client_data_json, back.client_data_json);
    try std.testing.expectEqualSlices(u8, assertion.authenticator_data, back.authenticator_data);
    try std.testing.expectEqualSlices(u8, assertion.signature, back.signature);
    try std.testing.expectEqualStrings("user-7", back.user_handle.?);
    try std.testing.expectEqualStrings("cross-platform", back.authenticator_attachment.?);

    try std.testing.expectError(error.InvalidField, Assertion.parseJson(a,
        \\{"id":"AQID","rawId":"AQIE","type":"public-key","response":{}}
    ));
    try std.testing.expectError(error.MissingField, Assertion.parseJson(a,
        \\{"id":"AQID","rawId":"AQID","type":"public-key"}
    ));
}

test "ClientData serialization" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const data: ClientData = .{
        .challenge = &.{ 0xfb, 0xff },
        .origin = "https://ex\"ample.com\n",
        .top_origin = "https://top.example",
        .cross_origin = true,
    };
    try data.writeJson(&w);
    try std.testing.expectEqualStrings(
        \\{"type":"webauthn.get","challenge":"-_8","origin":"https://ex\"ample.com\u000a",
    ++
        \\"crossOrigin":true,"topOrigin":"https://top.example"}
    , w.buffered());
}

fn testAssertion(
    a: Allocator,
    data: ClientData,
    rp_id: []const u8,
    flags: AuthenticatorData.Flags,
) !Assertion {
    var client: Io.Writer.Allocating = .init(a);
    try data.writeJson(&client.writer);
    const auth = try a.alloc(u8, AuthenticatorData.min_len);
    Sha256.hash(rp_id, auth[0..32], .{});
    auth[32] = @bitCast(flags);
    std.mem.writeInt(u32, auth[33..37], 42, .big);
    return .{
        .raw_id = "id",
        .client_data_json = client.written(),
        .authenticator_data = auth,
        .signature = "sig",
    };
}

const Case = struct {
    data: ClientData,
    rp_id: []const u8 = "example.com",
    flags: u8 = 0x01,
    expected: Expected,

    fn verify(case: Case, a: Allocator) !void {
        const assertion = try testAssertion(a, case.data, case.rp_id, @bitCast(case.flags));
        return verifyAssertion(a, assertion, case.expected);
    }
};

test "verifyAssertion and the challenge check" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const challenge = "0123456789abcdef";
    const expected: Expected = .{
        .challenge = challenge,
        .origin = "https://example.com",
        .rp_id = "example.com",
    };
    const good: Case = .{
        .data = .{ .challenge = challenge, .origin = "https://example.com" },
        .expected = expected,
    };
    try good.verify(a);

    const e = std.testing.expectError;
    var case = good;
    case.data.challenge = "0123456789abcdeX";
    try e(error.ChallengeMismatch, case.verify(a));
    case = good;
    case.data.origin = "https://evil.example";
    try e(error.OriginMismatch, case.verify(a));
    case = good;
    case.data.ceremony = .create;
    try e(error.WrongCeremony, case.verify(a));
    case = good;
    case.data.cross_origin = true;
    try e(error.CrossOrigin, case.verify(a));
    case.expected.allow_cross_origin = true;
    try case.verify(a);
    case = good;
    case.rp_id = "evil.example";
    try e(error.RpIdMismatch, case.verify(a));
    case = good;
    case.flags = 0;
    try e(error.UserNotPresent, case.verify(a));
    case = good;
    case.expected.user_verification = .required;
    try e(error.UserNotVerified, case.verify(a));
    case.flags = 0x05;
    try case.verify(a);

    var short = try testAssertion(a, good.data, "example.com", @bitCast(@as(u8, 1)));
    short.authenticator_data = short.authenticator_data[0..10];
    try e(error.InvalidAuthenticatorData, verifyAssertion(a, short, expected));
    try e(error.InvalidJson, verifyClientData(a, "not json", expected));
}

test "AuthenticatorData.parse" {
    var bytes: [AuthenticatorData.min_len + 3]u8 = @splat(0);
    bytes[32] = 0x45;
    std.mem.writeInt(u32, bytes[33..37], 7, .big);
    const data: AuthenticatorData = try .parse(&bytes);
    try std.testing.expect(data.flags.user_present);
    try std.testing.expect(data.flags.user_verified);
    try std.testing.expect(data.flags.attested_credential_data);
    try std.testing.expect(!data.flags.backed_up);
    try std.testing.expectEqual(7, data.sign_count);
}

test "a registration's credential: ID, COSE key, and first count" {
    const point = EcdsaP256.KeyPair.generate(std.testing.io).public_key.toUncompressedSec1();
    const cose = testCoseEs256(point);
    const id = "credential-7";
    var bytes: [AuthenticatorData.min_len + 18 + id.len + cose.len + 2]u8 = @splat(0);
    bytes[32] = 0x45; // user present and verified, attested credential data
    std.mem.writeInt(u32, bytes[33..37], 3, .big);
    bytes[37] = 0xaa; // first byte of the AAGUID
    std.mem.writeInt(u16, bytes[53..55], id.len, .big);
    @memcpy(bytes[55..][0..id.len], id);
    @memcpy(bytes[55 + id.len ..][0..cose.len], &cose);
    bytes[bytes.len - 2] = 0xa0; // an extensions map after the key: not part of it
    const attested = try attestedCredential(&bytes);
    try std.testing.expectEqual(0xaa, attested.aaguid[0]);
    try std.testing.expectEqualStrings(id, attested.id);
    try std.testing.expectEqualSlices(u8, &cose, attested.public_key);

    const registration: Registration = .{
        .raw_id = id,
        .client_data_json = "{}",
        .authenticator_data = &bytes,
        .attestation_object = &.{},
    };
    const credential = try registration.credential();
    try std.testing.expectEqualSlices(u8, &point, &credential.public_key.es256);
    try std.testing.expectEqual(3, credential.sign_count);

    var other = registration;
    other.raw_id = "another";
    try std.testing.expectError(error.InvalidAuthenticatorData, other.credential());
    bytes[32] = 0x05; // no attested credential data
    try std.testing.expectError(error.InvalidAuthenticatorData, attestedCredential(&bytes));
    bytes[32] = 0x45;
    try std.testing.expectError(error.InvalidAuthenticatorData, attestedCredential(bytes[0..60]));
}

test "CreationOptions.parseJson: what a relying party sends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options: CreationOptions = try .parseJson(a,
        \\{"rp":{"id":"example.com","name":"Example"},
        \\ "user":{"id":"dTE","name":"ana","displayName":"Ana"},
        \\ "challenge":"AAECAwQFBgcICQoLDA0ODw",
        \\ "pubKeyCredParams":[{"type":"public-key","alg":-8},{"type":"other","alg":1},
        \\   {"type":"public-key","alg":-7}],
        \\ "timeout":60000,
        \\ "excludeCredentials":[{"type":"public-key","id":"_w"}],
        \\ "authenticatorSelection":{"residentKey":"required","userVerification":"required"},
        \\ "attestation":"direct"}
    );
    try std.testing.expectEqualStrings("example.com", options.rp.id.?);
    try std.testing.expectEqualStrings("Example", options.rp.name);
    try std.testing.expectEqualStrings("u1", options.user.id);
    try std.testing.expectEqualStrings("Ana", options.user.display_name);
    try std.testing.expectEqual(16, options.challenge.len);
    try std.testing.expectEqualSlices(i32, &.{ cose_eddsa, cose_es256 }, options.algorithms);
    try std.testing.expectEqual(60000, options.timeout_ms.?);
    try std.testing.expectEqualSlices(u8, &.{0xff}, options.exclude_credentials[0].id);
    try std.testing.expect(options.resident_key);
    try std.testing.expectEqual(.required, options.user_verification);

    const plain: CreationOptions = try .parseJson(a,
        \\{"rp":{"name":"x"},"user":{"id":"AA","name":"n","displayName":"d"},
        \\ "challenge":"AA","pubKeyCredParams":[{"type":"public-key","alg":-7}],
        \\ "authenticatorSelection":{"requireResidentKey":true}}
    );
    try std.testing.expectEqual(null, plain.rp.id);
    try std.testing.expect(plain.resident_key);
    try std.testing.expectEqual(.preferred, plain.user_verification);

    const e = std.testing.expectError;
    try e(error.MissingField, CreationOptions.parseJson(a, "{\"challenge\":\"AA\"}"));
    try e(error.MissingField, CreationOptions.parseJson(a,
        \\{"rp":{"name":"x"},"user":{"id":"AA","name":"n","displayName":"d"},"challenge":"AA"}
    ));
    try e(error.InvalidField, CreationOptions.parseJson(a,
        \\{"rp":{"name":"x"},"user":{"id":"AA","name":"n","displayName":"d"},"challenge":"AA",
        \\ "pubKeyCredParams":[{"type":"public-key","alg":"ES256"}]}
    ));
}

test "Registration.writeJson" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const registration: Registration = .{
        .raw_id = &.{0xff},
        .client_data_json = "{}",
        .authenticator_data = &.{ 1, 2 },
        .attestation_object = &.{0xa0},
    };
    try registration.writeJson(&w);
    try std.testing.expectEqualStrings(
        \\{"id":"_w","rawId":"_w","type":"public-key","response":{"clientDataJSON":"e30","attestationObject":"oA","authenticatorData":"AQI"},"clientExtensionResults":{}}
    , w.buffered());
}

/// The COSE key of an ES256 credential, as an authenticator encodes it.
fn testCoseEs256(point: [65]u8) [77]u8 {
    var out: [77]u8 = undefined;
    // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
    const prefix = [_]u8{ 0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20 };
    @memcpy(out[0..10], &prefix);
    @memcpy(out[10..42], point[1..33]);
    @memcpy(out[42..44], &[_]u8{ 0x22, 0x58 });
    out[44] = 0x20;
    @memcpy(out[45..77], point[33..65]);
    return out;
}

/// The COSE key of an Ed25519 credential, with an unknown text label to skip.
fn testCoseEd25519(x: [32]u8) [46]u8 {
    var out: [46]u8 = undefined;
    // {1: 1, 3: -8, -1: 6, "k": "v", -2: x}
    const prefix = [_]u8{ 0xa5, 0x01, 0x01, 0x03, 0x27, 0x20, 0x06, 0x61, 'k', 0x61, 'v' };
    @memcpy(out[0..11], &prefix);
    @memcpy(out[11..14], &[_]u8{ 0x21, 0x58, 0x20 });
    @memcpy(out[14..46], &x);
    return out;
}

/// Signs `assertion` as an authenticator would, with either kind of key.
fn testSign(
    arena: Allocator,
    assertion: *Assertion,
    key: union(enum) { es256: EcdsaP256.KeyPair, ed25519: Ed25519.KeyPair },
) !void {
    var client_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(assertion.client_data_json, &client_hash, .{});
    const message = try std.mem.concat(arena, u8, &.{ assertion.authenticator_data, &client_hash });
    switch (key) {
        .es256 => |pair| {
            const signature = try pair.sign(message, null);
            var der: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
            assertion.signature = try arena.dupe(u8, signature.toDer(&der));
        },
        .ed25519 => |pair| {
            const signature = try pair.sign(message, null);
            assertion.signature = try arena.dupe(u8, &signature.toBytes());
        },
    }
}

test "verify: ES256 and EdDSA signatures, from COSE keys, and the sign count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = std.testing.expectError;
    const challenge = "0123456789abcdef";
    const expected: Expected = .{
        .challenge = challenge,
        .origin = "https://example.com",
        .rp_id = "example.com",
    };
    const data: ClientData = .{ .challenge = challenge, .origin = "https://example.com" };
    var assertion = try testAssertion(a, data, "example.com", @bitCast(@as(u8, 1)));
    // A count of 5 in the authenticator data.
    const authenticator_data = try a.dupe(u8, assertion.authenticator_data);
    std.mem.writeInt(u32, authenticator_data[33..37], 5, .big);
    assertion.authenticator_data = authenticator_data;

    const ec_pair = EcdsaP256.KeyPair.generate(std.testing.io);
    const ec_cose = testCoseEs256(ec_pair.public_key.toUncompressedSec1());
    const ec_key: PublicKey = try .fromCose(&ec_cose);
    try std.testing.expect(ec_key == .es256);
    try testSign(a, &assertion, .{ .es256 = ec_pair });
    try std.testing.expectEqual(5, try verify(a, assertion, expected, .{ .public_key = ec_key }));
    try e(error.SignCountRegressed, verify(a, assertion, expected, .{
        .public_key = ec_key,
        .sign_count = 5,
    }));

    const ed_pair = Ed25519.KeyPair.generate(std.testing.io);
    const ed_cose = testCoseEd25519(ed_pair.public_key.toBytes());
    const ed_key: PublicKey = try .fromCose(&ed_cose);
    try std.testing.expect(ed_key == .ed25519);
    try e(error.SignatureInvalid, verify(a, assertion, expected, .{ .public_key = ed_key }));
    try testSign(a, &assertion, .{ .ed25519 = ed_pair });
    try std.testing.expectEqual(5, try verify(a, assertion, expected, .{
        .public_key = ed_key,
        .sign_count = 4,
    }));

    // Any change to the signed bytes breaks the signature.
    var tampered = assertion;
    const changed = try a.dupe(u8, assertion.authenticator_data);
    changed[32] |= 0x04; // Claims user verification it did not sign.
    tampered.authenticator_data = changed;
    try e(error.SignatureInvalid, verify(a, tampered, expected, .{ .public_key = ed_key }));
    tampered = assertion;
    tampered.signature = assertion.signature[0..10];
    try e(error.SignatureInvalid, verify(a, tampered, expected, .{ .public_key = ed_key }));
    // The other checks still come first.
    tampered = assertion;
    try e(error.OriginMismatch, verify(a, tampered, .{
        .challenge = challenge,
        .origin = "https://evil.example",
        .rp_id = "example.com",
    }, .{ .public_key = ed_key }));
}

test checkSignCount {
    try checkSignCount(0, 0);
    try checkSignCount(0, 1);
    try checkSignCount(7, 8);
    try std.testing.expectError(error.SignCountRegressed, checkSignCount(7, 7));
    try std.testing.expectError(error.SignCountRegressed, checkSignCount(7, 0));
}

test "PublicKey.fromCose refusals" {
    const e = std.testing.expectError;
    try e(error.InvalidPublicKey, PublicKey.fromCose(""));
    try e(error.InvalidPublicKey, PublicKey.fromCose(&.{0x80})); // An array, not a map.
    try e(error.InvalidPublicKey, PublicKey.fromCose(&.{ 0xa1, 0x01 })); // Truncated.
    // RSA (kty 3, alg -257).
    try e(error.UnsupportedAlgorithm, PublicKey.fromCose(&.{
        0xa3, 0x01, 0x03, 0x03, 0x39, 0x01, 0x00, 0x21, 0x41, 0x00,
    }));
    // A P-256 point that is not on the curve.
    var point: [65]u8 = @splat(1);
    point[0] = 0x04;
    try e(error.InvalidPublicKey, PublicKey.fromCose(&testCoseEs256(point)));
    // Trailing bytes after the map.
    const ed_cose = testCoseEd25519(@splat(0)) ++ [_]u8{0};
    try e(error.InvalidPublicKey, PublicKey.fromCose(&ed_cose));
}
