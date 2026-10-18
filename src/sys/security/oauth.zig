//! OAuth 2.0 for command-line programs: PKCE (RFC 7636), the authorization URL, the
//! device authorization grant (RFC 8628), and token responses (RFC 6749 §5).
//!
//! Everything except `post`, `requestDeviceAuthorization`, and `requestToken` is pure: no
//! clock, no network, no randomness the caller did not pass in. Times are Unix seconds.
//!
//! Authorization code with PKCE:
//!
//! ```zig
//! const verifier: oauth.Nonce = .generate(io);
//! const state: oauth.Nonce = .generate(io);
//! const challenge = oauth.challengeS256(verifier.slice());
//! const url = try (oauth.AuthorizationRequest{
//!     .endpoint = "https://auth.example.com/authorize",
//!     .client_id = "cli",
//!     .redirect_uri = "http://127.0.0.1:8123/callback",
//!     .scopes = &.{ "openid", "offline_access" },
//!     .state = state.slice(),
//!     .code_challenge = &challenge,
//! }).allocUrl(gpa);
//! // ... the browser comes back with `code` and `state` ...
//! try oauth.checkState(state.slice(), returned_state);
//! ```
//!
//! Device authorization: `requestDeviceAuthorization`, `parseDeviceAuthorization`, show
//! `user_code` and `verification_uri`, then loop: wait `DevicePoll.interval`, `requestToken`
//! with `.device_code`, `parseTokenResponse`, and `DevicePoll.next` says what to do.
//!
//! Tokens are secrets: parse them into an arena over a `secure.SecureAllocator`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const base64url = std.base64.url_safe_no_pad;
const JsonObject = @import("JsonObject.zig");
const secure = @import("secure.zig");

/// 32 random bytes as 43 base64url characters: a PKCE code verifier (RFC 7636 §4.1
/// recommends exactly this) or a `state` value.
pub const Nonce = struct {
    text: [len]u8,

    pub const len = base64url.Encoder.calcSize(entropy_len);
    pub const entropy_len = 32;

    /// A fresh value from the cryptographically secure generator of `io`.
    pub fn generate(io: Io) Nonce {
        var entropy: [entropy_len]u8 = undefined;
        io.random(&entropy);
        defer secure.wipe(&entropy);
        return fromEntropy(entropy);
    }

    /// The value for given random bytes.
    pub fn fromEntropy(entropy: [entropy_len]u8) Nonce {
        var nonce: Nonce = undefined;
        const written = base64url.Encoder.encode(&nonce.text, &entropy);
        assert(written.len == len);
        return nonce;
    }

    /// The characters.
    pub fn slice(nonce: *const Nonce) []const u8 {
        return &nonce.text;
    }
};

/// The length of an S256 code challenge.
pub const challenge_len = base64url.Encoder.calcSize(std.crypto.hash.sha2.Sha256.digest_length);

/// The S256 code challenge for `verifier`: base64url(SHA-256(verifier)), no padding.
pub fn challengeS256(verifier: []const u8) [challenge_len]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var out: [challenge_len]u8 = undefined;
    _ = base64url.Encoder.encode(&out, &digest);
    return out;
}

/// Compares the `state` sent with the one returned, in constant time.
pub fn checkState(expected: []const u8, received: []const u8) error{StateMismatch}!void {
    if (expected.len == 0 or !secure.eql(expected, received)) return error.StateMismatch;
}

/// A name-value pair for a query string or a form body.
pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Writes `text` percent-encoded: every byte but the RFC 3986 unreserved characters
/// (`A-Z a-z 0-9 - . _ ~`) becomes `%XX`. Valid in a query and in a form body.
pub fn writePercentEncoded(writer: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) {
            try writer.writeByte(c);
        } else {
            try writer.print("%{X:0>2}", .{c});
        }
    }
}

/// Writes `a=1&b=2`, percent-encoding names and values.
pub fn writeForm(writer: *Io.Writer, params: []const Param) Io.Writer.Error!void {
    for (params, 0..) |param, i| {
        if (i > 0) try writer.writeByte('&');
        try writePercentEncoded(writer, param.name);
        try writer.writeByte('=');
        try writePercentEncoded(writer, param.value);
    }
}

/// Writes `scopes` space-separated (as one parameter value, before encoding).
fn writeScopeParam(writer: *Io.Writer, scopes: []const []const u8) Io.Writer.Error!void {
    try writer.writeAll("scope=");
    for (scopes, 0..) |scope, i| {
        if (i > 0) try writer.writeAll("%20");
        try writePercentEncoded(writer, scope);
    }
}

/// The authorization request of the code flow with PKCE (RFC 6749 §4.1.1, RFC 7636 §4.3).
pub const AuthorizationRequest = struct {
    /// The authorization endpoint. May already carry a query.
    endpoint: []const u8,
    client_id: []const u8,
    redirect_uri: ?[]const u8 = null,
    scopes: []const []const u8 = &.{},
    state: []const u8,
    /// From `challengeS256`.
    code_challenge: []const u8,
    /// Provider-specific parameters (`prompt`, `audience`, `login_hint`, ...).
    extra: []const Param = &.{},

    /// Writes the URL to send the user's browser to.
    pub fn writeUrl(request: AuthorizationRequest, writer: *Io.Writer) Io.Writer.Error!void {
        assert(request.state.len > 0);
        assert(request.code_challenge.len > 0);
        const has_query = std.mem.indexOfScalar(u8, request.endpoint, '?') != null;
        try writer.writeAll(request.endpoint);
        try writer.writeByte(if (has_query) '&' else '?');
        try writeForm(writer, &.{
            .{ .name = "response_type", .value = "code" },
            .{ .name = "client_id", .value = request.client_id },
        });
        if (request.redirect_uri) |uri| {
            try writer.writeAll("&");
            try writeForm(writer, &.{.{ .name = "redirect_uri", .value = uri }});
        }
        if (request.scopes.len > 0) {
            try writer.writeByte('&');
            try writeScopeParam(writer, request.scopes);
        }
        try writer.writeByte('&');
        try writeForm(writer, &.{
            .{ .name = "state", .value = request.state },
            .{ .name = "code_challenge", .value = request.code_challenge },
            .{ .name = "code_challenge_method", .value = "S256" },
        });
        for (request.extra) |param| {
            try writer.writeByte('&');
            try writeForm(writer, &.{param});
        }
    }

    /// `writeUrl` into memory from `gpa`; the caller frees it.
    pub fn allocUrl(request: AuthorizationRequest, gpa: Allocator) Allocator.Error![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        request.writeUrl(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

/// What a token endpoint is asked for.
pub const Grant = union(enum) {
    /// RFC 6749 §4.1.3 with RFC 7636 §4.5.
    authorization_code: struct {
        code: []const u8,
        redirect_uri: ?[]const u8 = null,
        code_verifier: []const u8,
    },
    /// RFC 8628 §3.4.
    device_code: []const u8,
    /// RFC 6749 §6.
    refresh_token: struct {
        refresh_token: []const u8,
        scopes: []const []const u8 = &.{},
    },

    /// Writes the form body of the token request.
    pub fn writeBody(grant: Grant, writer: *Io.Writer, client_id: []const u8) Io.Writer.Error!void {
        const write = writeForm;
        switch (grant) {
            .authorization_code => |g| {
                try write(writer, &.{
                    .{ .name = "grant_type", .value = "authorization_code" },
                    .{ .name = "code", .value = g.code },
                    .{ .name = "code_verifier", .value = g.code_verifier },
                });
                if (g.redirect_uri) |uri| {
                    try writer.writeByte('&');
                    try write(writer, &.{.{ .name = "redirect_uri", .value = uri }});
                }
            },
            .device_code => |code| try write(writer, &.{
                .{ .name = "grant_type", .value = device_grant_type },
                .{ .name = "device_code", .value = code },
            }),
            .refresh_token => |g| {
                try write(writer, &.{
                    .{ .name = "grant_type", .value = "refresh_token" },
                    .{ .name = "refresh_token", .value = g.refresh_token },
                });
                if (g.scopes.len > 0) {
                    try writer.writeByte('&');
                    try writeScopeParam(writer, g.scopes);
                }
            },
        }
        try writer.writeByte('&');
        try write(writer, &.{.{ .name = "client_id", .value = client_id }});
    }
};

/// The `grant_type` of a device access token request.
pub const device_grant_type = "urn:ietf:params:oauth:grant-type:device_code";

/// Writes the form body of a device authorization request (RFC 8628 §3.1).
pub fn writeDeviceAuthorizationForm(
    writer: *Io.Writer,
    client_id: []const u8,
    scopes: []const []const u8,
) Io.Writer.Error!void {
    try writeForm(writer, &.{.{ .name = "client_id", .value = client_id }});
    if (scopes.len > 0) {
        try writer.writeByte('&');
        try writeScopeParam(writer, scopes);
    }
}

/// A device authorization response (RFC 8628 §3.2).
pub const DeviceAuthorization = struct {
    device_code: []const u8,
    /// What the user types.
    user_code: []const u8,
    /// Where the user types it.
    verification_uri: []const u8,
    /// The URI with the code filled in, for a QR code or a link.
    verification_uri_complete: ?[]const u8 = null,
    /// Seconds until `device_code` expires.
    expires_in: u32,
    /// Seconds between polls; RFC 8628 says 5 when absent.
    interval: u32 = 5,
};

/// Parses a device authorization response into `arena`.
pub fn parseDeviceAuthorization(
    arena: Allocator,
    json: []const u8,
) JsonObject.Error!DeviceAuthorization {
    const object: JsonObject = try .parse(arena, json);
    return .{
        .device_code = try object.string("device_code"),
        .user_code = try object.string("user_code"),
        .verification_uri = try object.string("verification_uri"),
        .verification_uri_complete = try object.optionalString("verification_uri_complete"),
        .expires_in = try object.optionalUnsigned("expires_in") orelse
            return error.MissingField,
        .interval = try object.optionalUnsigned("interval") orelse 5,
    };
}

/// A successful token response (RFC 6749 §5.1).
pub const Token = struct {
    access_token: []const u8,
    /// Usually `Bearer`.
    token_type: []const u8,
    refresh_token: ?[]const u8 = null,
    /// Space-separated, when the server granted other scopes than requested.
    scope: ?[]const u8 = null,
    /// OpenID Connect.
    id_token: ?[]const u8 = null,
    /// Unix seconds; `null` when the server gave no lifetime.
    expires_at: ?i64 = null,

    /// Whether the token is expired at `now`, counting `leeway` seconds early.
    pub fn isExpired(token: Token, now: i64, leeway: u32) bool {
        const at = token.expires_at orelse return false;
        return now + leeway >= at;
    }

    /// Writes the type and expiry; the tokens themselves are redacted.
    pub fn format(token: Token, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{s} {s}", .{ token.token_type, secure.Secret.redacted });
        if (token.expires_at) |at| try writer.print(" (expires at {d})", .{at});
    }
};

/// The standard error codes of RFC 6749 §5.2 and RFC 8628 §3.5.
pub const ErrorCode = enum {
    invalid_request,
    invalid_client,
    invalid_grant,
    unauthorized_client,
    unsupported_grant_type,
    invalid_scope,
    authorization_pending,
    slow_down,
    access_denied,
    expired_token,
    /// Anything else; see `ErrorResponse.code`.
    other,
};

/// An error response (RFC 6749 §5.2).
pub const ErrorResponse = struct {
    /// The `error` field as sent.
    code: []const u8,
    description: ?[]const u8 = null,
    uri: ?[]const u8 = null,

    /// `code` as a known value.
    pub fn kind(response: ErrorResponse) ErrorCode {
        const known = std.meta.stringToEnum(ErrorCode, response.code) orelse return .other;
        return if (known == .other) .other else known;
    }
};

/// A token endpoint's answer: a token or an error.
pub const TokenResponse = union(enum) {
    token: Token,
    failure: ErrorResponse,
};

/// Parses a token endpoint response into `arena`. `now` turns `expires_in` into
/// `Token.expires_at`. An error object (any status) is `.failure`, not a Zig error.
pub fn parseTokenResponse(
    arena: Allocator,
    json: []const u8,
    now: i64,
) JsonObject.Error!TokenResponse {
    const object: JsonObject = try .parse(arena, json);
    if (try object.optionalString("error")) |code| return .{ .failure = .{
        .code = code,
        .description = try object.optionalString("error_description"),
        .uri = try object.optionalString("error_uri"),
    } };
    const expires_in = try object.optionalUnsigned("expires_in");
    return .{ .token = .{
        .access_token = try object.string("access_token"),
        .token_type = try object.string("token_type"),
        .refresh_token = try object.optionalString("refresh_token"),
        .scope = try object.optionalString("scope"),
        .id_token = try object.optionalString("id_token"),
        .expires_at = if (expires_in) |s| now + s else null,
    } };
}

/// The polling side of the device flow (RFC 8628 §3.4-3.5) as a state machine.
pub const DevicePoll = struct {
    /// Seconds to wait before the next request.
    interval: u32,
    /// When the device code expires, in Unix seconds.
    deadline: i64,

    /// RFC 8628 §3.5: `slow_down` adds this many seconds to the interval, for good.
    pub const slow_down_step = 5;

    /// What to do after a response.
    pub const Decision = union(enum) {
        /// Wait this many seconds, then request again.
        wait: u32,
        /// The user approved.
        done: Token,
        /// The user refused (`access_denied`).
        denied,
        /// The code expired (`expired_token`, or the deadline passed locally).
        expired,
        /// Any other error; stop.
        failed: ErrorResponse,
    };

    /// Starts polling for `authorization`, received at `now`.
    pub fn init(authorization: DeviceAuthorization, now: i64) DevicePoll {
        return .{
            .interval = @max(authorization.interval, 1),
            .deadline = now + authorization.expires_in,
        };
    }

    /// Decides what follows `response`, received at `now`.
    pub fn next(poll: *DevicePoll, response: TokenResponse, now: i64) Decision {
        const failure = switch (response) {
            .token => |token| return .{ .done = token },
            .failure => |failure| failure,
        };
        switch (failure.kind()) {
            .authorization_pending => {},
            .slow_down => poll.interval += slow_down_step,
            .access_denied => return .denied,
            .expired_token => return .expired,
            else => return .{ .failed = failure },
        }
        if (now + poll.interval >= poll.deadline) return .expired;
        return .{ .wait = poll.interval };
    }
};

/// What `post` and its callers can fail with.
pub const PostError = std.http.Client.FetchError;

/// POSTs `form` (`application/x-www-form-urlencoded`) to `url` asking for JSON, and writes
/// the response body to `response`. Returns the status; an OAuth error arrives as a 4xx
/// with a JSON body, which `parseTokenResponse` reads like any other.
pub fn post(
    client: *std.http.Client,
    url: []const u8,
    form: []const u8,
    response: *Io.Writer,
) PostError!std.http.Status {
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = form,
        .response_writer = response,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    return result.status;
}

/// Starts the device flow at `endpoint`; feed the body to `parseDeviceAuthorization`.
pub fn requestDeviceAuthorization(
    client: *std.http.Client,
    gpa: Allocator,
    endpoint: []const u8,
    client_id: []const u8,
    scopes: []const []const u8,
    response: *Io.Writer,
) (PostError || Allocator.Error)!std.http.Status {
    var form: Io.Writer.Allocating = .init(gpa);
    defer form.deinit();
    writeDeviceAuthorizationForm(&form.writer, client_id, scopes) catch
        return error.OutOfMemory;
    return post(client, endpoint, form.written(), response);
}

/// Asks `endpoint` for a token; feed the body to `parseTokenResponse`. The form, which
/// carries the grant's secrets, is wiped before it is freed; pass a `SecureAllocator` as
/// `gpa` to have the copies left behind by its growth wiped too.
pub fn requestToken(
    client: *std.http.Client,
    gpa: Allocator,
    endpoint: []const u8,
    client_id: []const u8,
    grant: Grant,
    response: *Io.Writer,
) (PostError || Allocator.Error)!std.http.Status {
    var form: Io.Writer.Allocating = .init(gpa);
    defer form.deinit();
    defer secure.wipe(form.writer.buffer);
    grant.writeBody(&form.writer, client_id) catch return error.OutOfMemory;
    return post(client, endpoint, form.written(), response);
}

// Tests ---------------------------------------------------------------------------------

test "RFC 7636 appendix B: S256" {
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = challengeS256(verifier);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &challenge);

    // The appendix's octets produce the appendix's verifier.
    const entropy = [Nonce.entropy_len]u8{
        116, 24,  223, 180, 151, 153, 224, 37,  79,  250, 96, 125, 216, 173,
        187, 186, 22,  212, 37,  77,  105, 214, 191, 240, 91, 88,  5,   88,
        83,  132, 141, 121,
    };
    const nonce: Nonce = .fromEntropy(entropy);
    try std.testing.expectEqualStrings(verifier, nonce.slice());
}

test "Nonce.generate" {
    const a: Nonce = .generate(std.testing.io);
    const b: Nonce = .generate(std.testing.io);
    try std.testing.expectEqual(43, a.slice().len);
    try std.testing.expect(!std.mem.eql(u8, a.slice(), b.slice()));
    for (a.slice()) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
}

test checkState {
    try checkState("abc", "abc");
    try std.testing.expectError(error.StateMismatch, checkState("abc", "abd"));
    try std.testing.expectError(error.StateMismatch, checkState("abc", ""));
    try std.testing.expectError(error.StateMismatch, checkState("", ""));
}

test writePercentEncoded {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writePercentEncoded(&w, "a-Z_0.9~ /?&=+%é");
    try std.testing.expectEqualStrings("a-Z_0.9~%20%2F%3F%26%3D%2B%25%C3%A9", w.buffered());
}

test "authorization URL" {
    const challenge = challengeS256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    const request: AuthorizationRequest = .{
        .endpoint = "https://auth.example.com/authorize",
        .client_id = "my cli",
        .redirect_uri = "http://127.0.0.1:8123/cb",
        .scopes = &.{ "openid", "read:all" },
        .state = "xyz",
        .code_challenge = &challenge,
        .extra = &.{.{ .name = "prompt", .value = "consent" }},
    };
    const url = try request.allocUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://auth.example.com/authorize?response_type=code" ++
        "&client_id=my%20cli&redirect_uri=http%3A%2F%2F127.0.0.1%3A8123%2Fcb" ++
        "&scope=openid%20read%3Aall&state=xyz" ++
        "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" ++
        "&code_challenge_method=S256&prompt=consent", url);

    const with_query: AuthorizationRequest = .{
        .endpoint = "https://h/a?tenant=1",
        .client_id = "c",
        .state = "s",
        .code_challenge = "x",
    };
    const url2 = try with_query.allocUrl(std.testing.allocator);
    defer std.testing.allocator.free(url2);
    try std.testing.expectEqualStrings("https://h/a?tenant=1&response_type=code&client_id=c" ++
        "&state=s&code_challenge=x&code_challenge_method=S256", url2);
}

fn expectForm(grant: Grant, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try grant.writeBody(&w, "cli");
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "token request forms" {
    try expectForm(.{ .authorization_code = .{
        .code = "c/1",
        .code_verifier = "v",
        .redirect_uri = "http://l/",
    } }, "grant_type=authorization_code&code=c%2F1&code_verifier=v" ++
        "&redirect_uri=http%3A%2F%2Fl%2F&client_id=cli");
    try expectForm(.{ .device_code = "d" }, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3A" ++
        "grant-type%3Adevice_code&device_code=d&client_id=cli");
    const scopes: []const []const u8 = &.{ "a", "b" };
    const refresh: Grant = .{ .refresh_token = .{ .refresh_token = "r", .scopes = scopes } };
    try expectForm(refresh, "grant_type=refresh_token&refresh_token=r&scope=a%20b&client_id=cli");

    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeDeviceAuthorizationForm(&w, "cli", &.{"repo"});
    try std.testing.expectEqualStrings("client_id=cli&scope=repo", w.buffered());
}

test parseDeviceAuthorization {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = try parseDeviceAuthorization(a,
        \\{"device_code":"GmRh","user_code":"WDJB-MJHT",
        \\ "verification_uri":"https://example.com/device",
        \\ "verification_uri_complete":"https://example.com/device?user_code=WDJB-MJHT",
        \\ "expires_in":1800,"interval":5,"unknown":[1]}
    );
    try std.testing.expectEqualStrings("WDJB-MJHT", auth.user_code);
    try std.testing.expectEqual(1800, auth.expires_in);
    try std.testing.expect(auth.verification_uri_complete != null);

    const minimal = try parseDeviceAuthorization(a,
        \\{"device_code":"d","user_code":"u","verification_uri":"v","expires_in":"600"}
    );
    try std.testing.expectEqual(5, minimal.interval);
    try std.testing.expectEqual(600, minimal.expires_in);
    try std.testing.expectError(error.MissingField, parseDeviceAuthorization(a,
        \\{"device_code":"d","user_code":"u","verification_uri":"v"}
    ));
}

test parseTokenResponse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try parseTokenResponse(a,
        \\{"access_token":"2YotnFZFEjr1zCsicMWpAA","token_type":"Bearer",
        \\ "expires_in":3600,"refresh_token":"tGzv3JOkF0XG5Qx2TlKWIA","scope":"a b"}
    , 1000);
    const token = ok.token;
    try std.testing.expectEqualStrings("2YotnFZFEjr1zCsicMWpAA", token.access_token);
    try std.testing.expectEqual(4600, token.expires_at.?);
    try std.testing.expect(!token.isExpired(4000, 60));
    try std.testing.expect(token.isExpired(4540, 60));
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{token});
    try std.testing.expectEqualStrings("Bearer <redacted> (expires at 4600)", text);

    const no_expiry = try parseTokenResponse(a,
        \\{"access_token":"t","token_type":"bearer"}
    , 0);
    try std.testing.expectEqual(null, no_expiry.token.expires_at);
    try std.testing.expect(!no_expiry.token.isExpired(std.math.maxInt(i32), 0));

    const failure = try parseTokenResponse(a,
        \\{"error":"invalid_grant","error_description":"bad code"}
    , 0);
    try std.testing.expectEqual(.invalid_grant, failure.failure.kind());
    try std.testing.expectEqualStrings("bad code", failure.failure.description.?);

    const odd = try parseTokenResponse(a, "{\"error\":\"other\"}", 0);
    try std.testing.expectEqual(.other, odd.failure.kind());
    try std.testing.expectError(error.MissingField, parseTokenResponse(a, "{}", 0));
    try std.testing.expectError(error.InvalidJson, parseTokenResponse(a, "<html>", 0));
}

fn expectWait(seconds: u32, decision: DevicePoll.Decision) !void {
    try std.testing.expectEqual(DevicePoll.Decision{ .wait = seconds }, decision);
}

fn pollFailure(code: []const u8) TokenResponse {
    return .{ .failure = .{ .code = code } };
}

test "DevicePoll: every response" {
    const auth: DeviceAuthorization = .{
        .device_code = "d",
        .user_code = "u",
        .verification_uri = "v",
        .expires_in = 60,
        .interval = 5,
    };
    var poll: DevicePoll = .init(auth, 100);
    try std.testing.expectEqual(160, poll.deadline);

    const pending = pollFailure("authorization_pending");
    try expectWait(5, poll.next(pending, 105));
    try expectWait(10, poll.next(pollFailure("slow_down"), 110));
    // The slower interval stays.
    try expectWait(10, poll.next(pending, 120));
    // The next wait would reach the deadline.
    try std.testing.expectEqual(.expired, poll.next(pending, 150));

    var fresh: DevicePoll = .init(auth, 0);
    try std.testing.expectEqual(.denied, fresh.next(pollFailure("access_denied"), 1));
    try std.testing.expectEqual(.expired, fresh.next(pollFailure("expired_token"), 1));
    const failed = fresh.next(pollFailure("invalid_client"), 1);
    try std.testing.expectEqualStrings("invalid_client", failed.failed.code);
    const done = fresh.next(.{ .token = .{ .access_token = "t", .token_type = "Bearer" } }, 1);
    try std.testing.expectEqualStrings("t", done.done.access_token);

    var zero_interval: DevicePoll = .init(.{
        .device_code = "d",
        .user_code = "u",
        .verification_uri = "v",
        .expires_in = 60,
        .interval = 0,
    }, 0);
    try expectWait(1, zero_interval.next(pending, 0));
}
