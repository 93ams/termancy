//! WebAuthn on Windows, through Windows Hello (`webauthn.dll`, Windows 10 1903 and later):
//! the system asks for the security key, a touch, and the PIN or biometrics in its own
//! dialog, and returns the credential or the assertion. It is how a program reaches a
//! FIDO key on Windows, where an unelevated process cannot open the device for `ctap`
//! (which also makes it the way to the platform authenticator: a Hello PIN, a face, a
//! fingerprint).
//!
//! ```zig
//! if (windows_hello.apiVersion() == null) return error.NoWindowsHello;
//! const registration = try windows_hello.register(arena, creation, "https://example.com", .{});
//! const credential = try registration.credential(); // what the relying party keeps
//! const assertion = try windows_hello.assert(arena, options, "https://example.com", .{});
//! try assertion.writeJson(out);
//! ```
//!
//! The results are the same `webauthn.Registration` and `webauthn.Assertion` types the
//! rest of `webauthn` reads, clientDataJSON included (built here, hashed by Windows). The
//! library is loaded when first used, so a program that never asks runs on a Windows
//! without it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const webauthn = @import("webauthn.zig");

const is_windows = builtin.os.tag == .windows;

pub const Error = error{
    /// Not Windows, or a Windows without `webauthn.dll`.
    Unavailable,
    /// The person cancelled, the time ran out, or no authenticator had a credential.
    NotAllowed,
    /// Windows refused the request for another reason.
    Failed,
    /// The request options name no RP ID and none can be taken from `origin`.
    InvalidOrigin,
    /// `register`: the authenticator already holds one of `exclude_credentials`.
    Excluded,
} || Allocator.Error;

/// How `assert` asks.
pub const AssertOptions = struct {
    /// The window the dialog belongs to; null for the console's when it is on screen, or
    /// the foreground one.
    window: ?*anyopaque = null,
    /// Which authenticators may answer.
    attachment: Attachment = .any,
};

pub const Attachment = enum(u32) {
    any = 0,
    /// Windows Hello itself: PIN, face, fingerprint.
    platform = 1,
    /// A security key (USB, NFC, Bluetooth).
    cross_platform = 2,
};

/// The version of the Windows WebAuthn API, or null where there is none.
pub fn apiVersion() ?u32 {
    if (!is_windows) return null;
    const api = load() orelse return null;
    return api.get_api_version();
}

/// A whole `navigator.credentials.get()` through Windows Hello: builds clientDataJSON for
/// `options` and `origin`, shows the system's dialog, and returns the assertion, in
/// `arena`. Blocks until the person answers. The RP ID defaults to the host of `origin`.
pub fn assert(
    arena: Allocator,
    options: webauthn.RequestOptions,
    origin: []const u8,
    how: AssertOptions,
) Error!webauthn.Assertion {
    if (!is_windows) return error.Unavailable;
    const api = load() orelse return error.Unavailable;
    const rp_id = options.rp_id orelse hostOf(origin) orelse return error.InvalidOrigin;
    var client: Io.Writer.Allocating = .init(arena);
    const data: webauthn.ClientData = .{ .challenge = options.challenge, .origin = origin };
    data.writeJson(&client.writer) catch return error.OutOfMemory;
    const client_json = client.written();

    const rp_id_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, rp_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidOrigin,
    };
    const credentials = try arena.alloc(Credential, options.allow_credentials.len);
    for (options.allow_credentials, credentials) |allowed, *credential| credential.* = .{
        .id_len = @intCast(allowed.id.len),
        .id = allowed.id.ptr,
    };
    const client_data: ClientData = .{
        .json_len = @intCast(client_json.len),
        .json = client_json.ptr,
    };
    const request = requestOf(options, credentials, how.attachment);
    const window = how.window orelse ownerOf(api);
    var result: ?*const AssertionV1 = null;
    const status = api.get_assertion(window, rp_id_w, &client_data, &request, &result);
    if (status < 0 or result == null) return errorOf(status);
    defer api.free_assertion(result.?);
    const got = result.?;
    const raw_id = try arena.dupe(u8, got.credential.id[0..got.credential.id_len]);
    return .{
        .raw_id = raw_id,
        .client_data_json = client_json,
        .authenticator_data = try arena.dupe(u8, got.authenticator_data[0..got.authenticator_data_len]),
        .signature = try arena.dupe(u8, got.signature[0..got.signature_len]),
        .user_handle = if (got.user_id_len > 0)
            try arena.dupe(u8, got.user_id.?[0..got.user_id_len])
        else
            null,
    };
}

/// A whole `navigator.credentials.create()` through Windows Hello: builds clientDataJSON
/// for `options` and `origin`, shows the system's dialog, and returns the new credential,
/// in `arena`. Blocks until the person answers. Attestation is not asked for (`none`).
/// With `.platform`, the credential lives in Windows Hello, and Settings > Accounts >
/// Passkeys lists it.
pub fn register(
    arena: Allocator,
    options: webauthn.CreationOptions,
    origin: []const u8,
    how: AssertOptions,
) Error!webauthn.Registration {
    if (!is_windows) return error.Unavailable;
    const api = load() orelse return error.Unavailable;
    const rp_id = options.rp.id orelse hostOf(origin) orelse return error.InvalidOrigin;
    var client: Io.Writer.Allocating = .init(arena);
    const data: webauthn.ClientData = .{ .ceremony = .create, .challenge = options.challenge, .origin = origin };
    data.writeJson(&client.writer) catch return error.OutOfMemory;
    const client_json = client.written();

    const rp: RpEntity = .{
        .id = try wide(arena, rp_id, error.InvalidOrigin),
        .name = try wide(arena, options.rp.name, error.Failed),
    };
    const user: UserEntity = .{
        .id_len = @intCast(options.user.id.len),
        .id = options.user.id.ptr,
        .name = try wide(arena, options.user.name, error.Failed),
        .display_name = try wide(arena, options.user.display_name, error.Failed),
    };
    const parameters = try arena.alloc(CoseParameter, options.algorithms.len);
    for (options.algorithms, parameters) |algorithm, *parameter| parameter.* = .{ .algorithm = algorithm };
    const excluded = try arena.alloc(Credential, options.exclude_credentials.len);
    for (options.exclude_credentials, excluded) |descriptor, *credential| credential.* = .{
        .id_len = @intCast(descriptor.id.len),
        .id = descriptor.id.ptr,
    };
    const client_data: ClientData = .{
        .json_len = @intCast(client_json.len),
        .json = client_json.ptr,
    };
    const request = creationOf(options, excluded, how.attachment);
    const window = how.window orelse ownerOf(api);
    var result: ?*const AttestationV1 = null;
    const status = api.make_credential(
        window,
        &rp,
        &user,
        &.{ .count = @intCast(parameters.len), .items = parameters.ptr },
        &client_data,
        &request,
        &result,
    );
    if (status < 0 or result == null) return errorOf(status);
    defer api.free_attestation(result.?);
    const got = result.?;
    return .{
        .raw_id = try arena.dupe(u8, got.credential_id[0..got.credential_id_len]),
        .client_data_json = client_json,
        .authenticator_data = try arena.dupe(u8, got.authenticator_data[0..got.authenticator_data_len]),
        .attestation_object = try arena.dupe(u8, got.attestation_object[0..got.attestation_object_len]),
    };
}

/// The window the dialog belongs to: the console's while it is on screen, else the
/// foreground one. A pseudo console (Windows Terminal, an IDE's terminal) has a console
/// window that is never shown, and a dialog owned by it may not appear.
fn ownerOf(api: Api) ?*anyopaque {
    if (api.console_window()) |console| {
        if (api.window_visible(console) != 0) return console;
    }
    return api.foreground_window();
}

fn wide(arena: Allocator, text: []const u8, invalid: Error) Error![*:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => invalid,
    };
}

fn creationOf(
    options: webauthn.CreationOptions,
    excluded: []const Credential,
    attachment: Attachment,
) MakeCredentialOptionsV1 {
    return .{
        .timeout_ms = options.timeout_ms orelse 0,
        .excluded = .{ .count = @intCast(excluded.len), .items = excluded.ptr },
        .attachment = @backingInt(attachment),
        .require_resident_key = @intFromBool(options.resident_key),
        .user_verification = userVerificationOf(options.user_verification),
    };
}

fn userVerificationOf(requirement: webauthn.UserVerification) DWORD {
    return switch (requirement) {
        .required => 1,
        .preferred => 2,
        .discouraged => 3,
    };
}

fn requestOf(
    options: webauthn.RequestOptions,
    credentials: []const Credential,
    attachment: Attachment,
) GetAssertionOptionsV1 {
    return .{
        .timeout_ms = options.timeout_ms orelse 0, // 0: Windows' default
        .credentials = .{ .count = @intCast(credentials.len), .items = credentials.ptr },
        .attachment = @backingInt(attachment),
        .user_verification = userVerificationOf(options.user_verification),
    };
}

fn errorOf(status: i32) Error {
    const code: u32 = @bitCast(status);
    return switch (code) {
        // NTE_USER_CANCELLED, HRESULT_FROM_WIN32(ERROR_CANCELLED), NTE_NOT_FOUND,
        // HRESULT_FROM_WIN32(ERROR_TIMEOUT).
        0x80090036, 0x800704C7, 0x80090011, 0x800705B4 => error.NotAllowed,
        0x8009000F => error.Excluded, // NTE_EXISTS
        else => error.Failed,
    };
}

fn hostOf(origin: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return null;
    const rest = origin[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;
    return if (end == 0) null else rest[0..end];
}

// -- webauthn.h, the first version of each structure --------------------------------------

const DWORD = u32;
const HRESULT = i32;
const public_key = std.unicode.utf8ToUtf16LeStringLiteral("public-key");
const sha_256 = std.unicode.utf8ToUtf16LeStringLiteral("SHA-256");

/// `WEBAUTHN_CLIENT_DATA`
const ClientData = extern struct {
    version: DWORD = 1,
    json_len: DWORD,
    json: [*]const u8,
    hash_algorithm: [*:0]const u16 = sha_256,
};

/// `WEBAUTHN_CREDENTIAL`
const Credential = extern struct {
    version: DWORD = 1,
    id_len: DWORD,
    id: [*]const u8,
    kind: [*:0]const u16 = public_key,
};

/// `WEBAUTHN_CREDENTIALS`
const Credentials = extern struct {
    count: DWORD = 0,
    items: ?[*]const Credential = null,
};

/// `WEBAUTHN_EXTENSIONS`
const Extensions = extern struct {
    count: DWORD = 0,
    items: ?*const anyopaque = null,
};

/// `WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS`, version 1.
const GetAssertionOptionsV1 = extern struct {
    version: DWORD = 1,
    timeout_ms: DWORD,
    credentials: Credentials,
    extensions: Extensions = .{},
    attachment: DWORD,
    user_verification: DWORD,
    flags: DWORD = 0,
};

/// `WEBAUTHN_RP_ENTITY_INFORMATION`
const RpEntity = extern struct {
    version: DWORD = 1,
    id: [*:0]const u16,
    name: [*:0]const u16,
    icon: ?[*:0]const u16 = null,
};

/// `WEBAUTHN_USER_ENTITY_INFORMATION`
const UserEntity = extern struct {
    version: DWORD = 1,
    id_len: DWORD,
    id: [*]const u8,
    name: [*:0]const u16,
    icon: ?[*:0]const u16 = null,
    display_name: [*:0]const u16,
};

/// `WEBAUTHN_COSE_CREDENTIAL_PARAMETER`
const CoseParameter = extern struct {
    version: DWORD = 1,
    kind: [*:0]const u16 = public_key,
    algorithm: i32,
};

/// `WEBAUTHN_COSE_CREDENTIAL_PARAMETERS`
const CoseParameters = extern struct {
    count: DWORD,
    items: [*]const CoseParameter,
};

/// `WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS`, version 1.
const MakeCredentialOptionsV1 = extern struct {
    version: DWORD = 1,
    timeout_ms: DWORD,
    excluded: Credentials,
    extensions: Extensions = .{},
    attachment: DWORD,
    require_resident_key: i32, // BOOL
    user_verification: DWORD,
    attestation: DWORD = 1, // WEBAUTHN_ATTESTATION_CONVEYANCE_PREFERENCE_NONE
};

/// `WEBAUTHN_CREDENTIAL_ATTESTATION`: the fields of version 1, which every version
/// starts with.
const AttestationV1 = extern struct {
    version: DWORD,
    format: [*:0]const u16,
    authenticator_data_len: DWORD,
    authenticator_data: [*]const u8,
    attestation_len: DWORD,
    attestation: ?[*]const u8,
    decode_type: DWORD,
    decoded: ?*const anyopaque,
    attestation_object_len: DWORD,
    attestation_object: [*]const u8,
    credential_id_len: DWORD,
    credential_id: [*]const u8,
};

/// `WEBAUTHN_ASSERTION`: the fields of version 1, which every version starts with.
const AssertionV1 = extern struct {
    version: DWORD,
    authenticator_data_len: DWORD,
    authenticator_data: [*]const u8,
    signature_len: DWORD,
    signature: [*]const u8,
    credential: Credential,
    user_id_len: DWORD,
    user_id: ?[*]const u8,
};

/// Empty elsewhere: other targets have no `.winapi` calling convention to name.
const Api = if (!is_windows) struct {} else struct {
    get_api_version: *const fn () callconv(.winapi) DWORD,
    get_assertion: *const fn (
        window: ?*anyopaque,
        rp_id: [*:0]const u16,
        client_data: *const ClientData,
        options: *const GetAssertionOptionsV1,
        assertion: *?*const AssertionV1,
    ) callconv(.winapi) HRESULT,
    free_assertion: *const fn (assertion: *const AssertionV1) callconv(.winapi) void,
    make_credential: *const fn (
        window: ?*anyopaque,
        rp: *const RpEntity,
        user: *const UserEntity,
        parameters: *const CoseParameters,
        client_data: *const ClientData,
        options: *const MakeCredentialOptionsV1,
        attestation: *?*const AttestationV1,
    ) callconv(.winapi) HRESULT,
    free_attestation: *const fn (attestation: *const AttestationV1) callconv(.winapi) void,
    console_window: *const fn () callconv(.winapi) ?*anyopaque,
    foreground_window: *const fn () callconv(.winapi) ?*anyopaque,
    window_visible: *const fn (window: *anyopaque) callconv(.winapi) i32,
};

/// The functions, looked up on each use: a load of a loaded library only counts a
/// reference, which is nothing next to a dialog. The libraries stay loaded.
fn load() ?Api {
    if (!is_windows) return null;
    const dll = kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("webauthn.dll")) orelse
        return null;
    const user32 = kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse
        return null;
    const k32 = kernel32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse
        return null;
    return .{
        .get_api_version = @ptrCast(@alignCast(kernel32.GetProcAddress(dll, "WebAuthNGetApiVersionNumber") orelse return null)),
        .get_assertion = @ptrCast(@alignCast(kernel32.GetProcAddress(dll, "WebAuthNAuthenticatorGetAssertion") orelse return null)),
        .free_assertion = @ptrCast(@alignCast(kernel32.GetProcAddress(dll, "WebAuthNFreeAssertion") orelse return null)),
        .make_credential = @ptrCast(@alignCast(kernel32.GetProcAddress(dll, "WebAuthNAuthenticatorMakeCredential") orelse return null)),
        .free_attestation = @ptrCast(@alignCast(kernel32.GetProcAddress(dll, "WebAuthNFreeCredentialAttestation") orelse return null)),
        .console_window = @ptrCast(@alignCast(kernel32.GetProcAddress(k32, "GetConsoleWindow") orelse return null)),
        .foreground_window = @ptrCast(@alignCast(kernel32.GetProcAddress(user32, "GetForegroundWindow") orelse return null)),
        .window_visible = @ptrCast(@alignCast(kernel32.GetProcAddress(user32, "IsWindowVisible") orelse return null)),
    };
}

const kernel32 = struct {
    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
};

const testing = std.testing;

test "the structures have webauthn.h's layout on 64-bit Windows" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try testing.expectEqual(24, @sizeOf(ClientData));
    try testing.expectEqual(24, @sizeOf(Credential));
    try testing.expectEqual(56, @sizeOf(GetAssertionOptionsV1));
    try testing.expectEqual(40, @offsetOf(GetAssertionOptionsV1, "attachment"));
    try testing.expectEqual(32, @offsetOf(AssertionV1, "credential"));
    try testing.expectEqual(64, @offsetOf(AssertionV1, "user_id"));
    try testing.expectEqual(32, @sizeOf(RpEntity));
    try testing.expectEqual(40, @sizeOf(UserEntity));
    try testing.expectEqual(32, @offsetOf(UserEntity, "display_name"));
    try testing.expectEqual(24, @sizeOf(CoseParameter));
    try testing.expectEqual(16, @offsetOf(CoseParameter, "algorithm"));
    try testing.expectEqual(56, @sizeOf(MakeCredentialOptionsV1));
    try testing.expectEqual(40, @offsetOf(MakeCredentialOptionsV1, "attachment"));
    try testing.expectEqual(52, @offsetOf(MakeCredentialOptionsV1, "attestation"));
    try testing.expectEqual(96, @sizeOf(AttestationV1));
    try testing.expectEqual(64, @offsetOf(AttestationV1, "attestation_object_len"));
    try testing.expectEqual(88, @offsetOf(AttestationV1, "credential_id"));
}

test "a creation request carries the excluded credentials and its requirements" {
    const ids = [_]Credential{.{ .id_len = 3, .id = "abc" }};
    const request = creationOf(.{
        .challenge = "0123456789abcdef",
        .rp = .{ .name = "Example" },
        .user = .{ .id = "u1", .name = "ana", .display_name = "Ana" },
        .timeout_ms = 30_000,
        .user_verification = .required,
        .resident_key = true,
    }, &ids, .platform);
    try testing.expectEqual(1, request.excluded.count);
    try testing.expectEqual(30_000, request.timeout_ms);
    try testing.expectEqual(1, request.user_verification);
    try testing.expectEqual(1, request.attachment);
    try testing.expectEqual(1, request.require_resident_key);
    try testing.expectEqual(1, request.attestation);
}

test "a request carries the allowed credentials, the timeout, and user verification" {
    const ids = [_]Credential{ .{ .id_len = 3, .id = "abc" }, .{ .id_len = 1, .id = "z" } };
    const request = requestOf(.{
        .challenge = "0123456789abcdef",
        .timeout_ms = 30_000,
        .user_verification = .required,
    }, &ids, .cross_platform);
    try testing.expectEqual(2, request.credentials.count);
    try testing.expectEqual(30_000, request.timeout_ms);
    try testing.expectEqual(1, request.user_verification);
    try testing.expectEqual(2, request.attachment);
    const default = requestOf(.{ .challenge = "0123456789abcdef" }, &.{}, .any);
    try testing.expectEqual(0, default.timeout_ms);
    try testing.expectEqual(2, default.user_verification);
}

test "a cancelled or timed-out request is NotAllowed; others Failed" {
    try testing.expectEqual(error.NotAllowed, errorOf(@bitCast(@as(u32, 0x80090036))));
    try testing.expectEqual(error.NotAllowed, errorOf(@bitCast(@as(u32, 0x800704C7))));
    try testing.expectEqual(error.Excluded, errorOf(@bitCast(@as(u32, 0x8009000F))));
    try testing.expectEqual(error.Failed, errorOf(@bitCast(@as(u32, 0x80070057))));
}

test "the API is found on Windows, and nowhere else" {
    if (!is_windows) {
        try testing.expectEqual(null, apiVersion());
        try testing.expectError(error.Unavailable, assert(testing.allocator, .{
            .challenge = "0123456789abcdef",
        }, "https://example.com", .{}));
        return;
    }
    // Present since Windows 10 1903; a Windows Server Core may lack it.
    const version = apiVersion() orelse return error.SkipZigTest;
    try testing.expect(version >= 1);
}
