//! `termancy passkey`: a WebAuthn client for scripts. `get` and `create` take the
//! options a relying party sends for `navigator.credentials.get()` and `create()`, in their
//! JSON form, ask the authenticator, and print the response in its JSON form, ready to send
//! back. On Windows, Windows Hello asks (a security key, or the PIN, face, or fingerprint);
//! on Linux, `get` asks the first FIDO key under /dev/hidraw.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const field = @import("field");
const sys = @import("sys");
const webauthn = sys.webauthn;
const windows_hello = sys.windows_hello;
const ctap = sys.ctap;
const Io = std.Io;

const Authenticator = enum { any, platform, @"security-key" };

/// What `--origin` and `--authenticator` mean, for both commands.
const origin_spec: field.Field([]const u8) = .{
    .help = "The relying party's origin, such as https://example.com",
};
const authenticator_spec: field.Field(Authenticator) = .{
    .help = "Windows: which authenticator may answer (platform: Windows Hello itself)",
};

const GetFlags = struct {
    origin: []const u8,
    authenticator: Authenticator = .any,
    pin: []const u8 = "",
};
const get_flags = cli.flags(GetFlags, field.Set(.{field.Spec(GetFlags){ .fields = .{
    .origin = origin_spec,
    .authenticator = authenticator_spec,
    .pin = .{ .help = "Linux: the key's PIN, when the relying party requires user " ++
        "verification; better given through $TERMANCY_FIDO_PIN", .secret = true },
} }}), .{ .fields = .{
    .pin = .{ .env = "TERMANCY_FIDO_PIN" },
} });

const CreateFlags = struct {
    origin: []const u8,
    authenticator: Authenticator = .any,
};
const create_flags = cli.flags(CreateFlags, field.Set(.{field.Spec(CreateFlags){ .fields = .{
    .origin = origin_spec,
    .authenticator = authenticator_spec,
} }}), .{});

pub const command = cli.command(.{
    .name = "passkey",
    .summary = "Sign in with a passkey or security key, or create one, from a script",
    .description =
    \\A WebAuthn client: get and create read the options a relying party sends (the JSON
    \\form of navigator.credentials.get() and create(), from the file or standard input),
    \\ask the authenticator, and print the response's JSON form. On Windows, Windows Hello
    \\asks; on Linux, get asks the first FIDO security key under /dev/hidraw, with its PIN
    \\when the relying party requires user verification. create needs Windows Hello.
    ,
    .subcommands = .{
        cli.command(.{
            .name = "get",
            .summary = "Sign a challenge with a credential (navigator.credentials.get)",
            .args = .{ .max = 1, .usage = "[options.json]" },
            .flags = get_flags,
            .examples =
            \\curl -s https://example.com/login/options | termancy passkey get --origin https://example.com
            ,
            .run = runGet,
        }),
        cli.command(.{
            .name = "create",
            .summary = "Create a credential (navigator.credentials.create)",
            .args = .{ .max = 1, .usage = "[options.json]" },
            .flags = create_flags,
            .examples =
            \\termancy passkey create --origin https://example.com options.json > response.json
            ,
            .run = runCreate,
        }),
    },
});

fn runGet(ctx: *cli.Context, flags: GetFlags) !void {
    const options = webauthn.RequestOptions.parseJson(ctx.arena, try readOptions(ctx)) catch |err|
        return badOptions(ctx, err);
    const assertion = switch (builtin.os.tag) {
        .windows => windows_hello.assert(ctx.arena, options, flags.origin, .{
            .attachment = attachmentOf(flags.authenticator),
        }) catch |err| return helloFailed(ctx, err),
        .linux => try securityKeyAssert(ctx, options, flags),
        else => return ctx.fail("passkey get is not supported on this system yet", .{}),
    };
    try assertion.writeJson(ctx.out);
    try ctx.out.writeByte('\n');
}

fn runCreate(ctx: *cli.Context, flags: CreateFlags) !void {
    const options = webauthn.CreationOptions.parseJson(ctx.arena, try readOptions(ctx)) catch |err|
        return badOptions(ctx, err);
    if (builtin.os.tag != .windows) {
        return ctx.fail(
            "passkey create needs Windows Hello; not supported on this system yet",
            .{},
        );
    }
    const registration = windows_hello.register(ctx.arena, options, flags.origin, .{
        .attachment = attachmentOf(flags.authenticator),
    }) catch |err| return helloFailed(ctx, err);
    try registration.writeJson(ctx.out);
    try ctx.out.writeByte('\n');
}

/// The options JSON: the file named, or standard input.
fn readOptions(ctx: *cli.Context) ![]const u8 {
    const limit: Io.Limit = .limited(1 << 20);
    if (ctx.args.len == 1 and !std.mem.eql(u8, ctx.args[0], "-")) {
        const path = ctx.args[0];
        return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, limit) catch |err|
            ctx.fail("{s}: cannot read: {t}", .{ path, err });
    }
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(ctx.io, &buffer);
    return reader.interface.allocRemaining(ctx.arena, limit) catch |err|
        ctx.fail("standard input: {t}", .{err});
}

fn badOptions(ctx: *cli.Context, err: anyerror) error{ CommandFailed, OutOfMemory } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidJson => ctx.fail("the options are not a JSON object", .{}),
        error.MissingField => ctx.fail("the options lack a required field", .{}),
        else => ctx.fail("the options have a field of the wrong type or value", .{}),
    };
}

fn attachmentOf(authenticator: Authenticator) windows_hello.Attachment {
    return switch (authenticator) {
        .any => .any,
        .platform => .platform,
        .@"security-key" => .cross_platform,
    };
}

fn helloFailed(ctx: *cli.Context, err: windows_hello.Error) error{ CommandFailed, OutOfMemory } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotAllowed => ctx.fail("not allowed: cancelled, timed out, or no authenticator " ++
            "has a credential for it", .{}),
        error.Excluded => ctx.fail(
            "this authenticator already has a credential for the account",
            .{},
        ),
        error.InvalidOrigin => ctx.fail("--origin names no host, and the options no RP ID", .{}),
        error.Unavailable => ctx.fail("Windows Hello is not available here (webauthn.dll)", .{}),
        error.Failed => ctx.fail("Windows Hello refused the request", .{}),
    };
}

/// `get` against the first FIDO key on Linux, saying on standard error when to touch it.
fn securityKeyAssert(
    ctx: *cli.Context,
    options: webauthn.RequestOptions,
    flags: GetFlags,
) !webauthn.Assertion {
    const paths = try ctap.Hidraw.list(ctx.arena, ctx.io);
    if (paths.len == 0) return ctx.fail("no FIDO security key found (in /dev/hidraw*)", .{});
    var hid = ctap.Hidraw.open(ctx.io, paths[0]) catch |err|
        return ctx.fail("{s}: cannot open: {t}", .{ paths[0], err });
    defer hid.close();
    var channel = ctap.Channel.open(ctx.io, hid.device()) catch |err|
        return ctx.fail("{s}: not answering as a FIDO key: {t}", .{ paths[0], err });
    try webauthn.writePresencePrompt(ctx.err, options.rp_id);
    try ctx.err.flush();
    const pin: ?[]const u8 = if (flags.pin.len > 0) flags.pin else null;
    return ctap.assert(ctx.arena, &channel, options, flags.origin, .{ .pin = pin }) catch |err|
        ctx.fail("the security key refused: {t}", .{err});
}

test "the authenticator names map to Windows' attachments" {
    try std.testing.expectEqual(.cross_platform, attachmentOf(.@"security-key"));
    try std.testing.expectEqual(.platform, attachmentOf(.platform));
}
