//! WebAuthn assertions on Windows, through Windows Hello (`webauthn.dll`, Windows 10 1903
//! and later): the system asks for the security key, a touch, and the PIN or biometrics
//! in its own dialog, and returns the assertion. It is how a program reaches a FIDO key
//! on Windows, where an unelevated process cannot open the device for `ctap` (which also
//! makes it the way to the platform authenticator: a Hello PIN, a face, a fingerprint).
//!
//! ```zig
//! if (windows_hello.apiVersion() == null) return error.NoWindowsHello;
//! const assertion = try windows_hello.assert(arena, options, "https://example.com", .{});
//! try assertion.writeJson(out);
//! ```
//!
//! The result is the same `webauthn.Assertion` `ctap.assert` returns, clientDataJSON
//! included (built here, hashed by Windows). The library is loaded when first used, so a
//! program that never asks runs on a Windows without it.

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
} || Allocator.Error;

/// How `assert` asks.
pub const AssertOptions = struct {
    /// The window the dialog belongs to; null for the console's, or the foreground one.
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
    const window = how.window orelse api.console_window() orelse api.foreground_window();
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

fn requestOf(
    options: webauthn.RequestOptions,
    credentials: []const Credential,
    attachment: Attachment,
) GetAssertionOptionsV1 {
    return .{
        .timeout_ms = options.timeout_ms orelse 0, // 0: Windows' default
        .credentials = .{ .count = @intCast(credentials.len), .items = credentials.ptr },
        .attachment = @backingInt(attachment),
        .user_verification = switch (options.user_verification) {
            .required => 1,
            .preferred => 2,
            .discouraged => 3,
        },
    };
}

fn errorOf(status: i32) Error {
    const code: u32 = @bitCast(status);
    return switch (code) {
        // NTE_USER_CANCELLED, HRESULT_FROM_WIN32(ERROR_CANCELLED), NTE_NOT_FOUND,
        // HRESULT_FROM_WIN32(ERROR_TIMEOUT).
        0x80090036, 0x800704C7, 0x80090011, 0x800705B4 => error.NotAllowed,
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
    console_window: *const fn () callconv(.winapi) ?*anyopaque,
    foreground_window: *const fn () callconv(.winapi) ?*anyopaque,
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
        .console_window = @ptrCast(@alignCast(kernel32.GetProcAddress(k32, "GetConsoleWindow") orelse return null)),
        .foreground_window = @ptrCast(@alignCast(kernel32.GetProcAddress(user32, "GetForegroundWindow") orelse return null)),
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
