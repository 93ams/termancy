//! An HTTP client's command line (it prints the request instead of sending it), to show the
//! grammar of flags and arguments `cli` derives from types:
//!
//! - typed positionals: an enum method (checked and completed), a URL with a completer, and
//!   a list taking the remaining words;
//! - repeatable flags (`-H a -H b`), split lists (`--accept json,html`), bounds, a string
//!   with fixed choices, and `cfg.Duration`/`cfg.ByteSize` as flag types (any type with
//!   `parse` is one);
//! - a secret read from the environment, a flag that requires another, flags that exclude
//!   each other, a renamed flag's old name, a deprecated flag, a hidden one, and a check
//!   across fields (`validate`);
//! - a required flag asked for at a terminal, hidden as it is typed (`auth login`), and a
//!   confirmation (`auth logout`);
//! - a help topic, examples in help, `help --search`, `-o json`, `-v` with a middleware
//!   that times every command, response files (`@file`), and unambiguous prefixes
//!   (`httpc au logi` is `httpc auth login`; `httpc au lo` is ambiguous).
//!
//!     zig build examples
//!     zig-out/bin/httpc send post https://api.example.com/users name=ada -H 'X-Trace: 1'
//!     zig-out/bin/httpc @examples/httpc/request.args -o json
//!     zig-out/bin/httpc help items
//!     zig-out/bin/httpc help --search token

const std = @import("std");
const cli = @import("cli");
const field_ = @import("field");
const cfg = @import("cfg");

const Method = enum { get, head, post, put, patch, delete };

const SendArgs = struct {
    method: Method,
    url: []const u8,
    items: []const []const u8 = &.{},
};
const send_args = cli.args(SendArgs, field_.none, .{ .fields = .{
    .url = .{ .complete = .from(completeUrl) },
    .items = .{ .name = "item" },
} });

const SendFlags = struct {
    header: []const []const u8 = &.{},
    accept: []const []const u8 = &.{},
    json: bool = false,
    form: bool = false,
    timeout: cfg.Duration = .{ .ns = 30 * std.time.ns_per_s },
    max_size: cfg.ByteSize = .{ .bytes = 10 << 20 },
    retries: u8 = 2,
    http_version: []const u8 = "1.1",
    token: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    insecure: bool = false,
    proxy: ?[]const u8 = null,
    trace: bool = false,
};

/// A check across fields, after each flag was checked alone.
fn boundedWait(flags: SendFlags, w: *std.Io.Writer) !void {
    const worst = flags.timeout.ns * (@as(u64, flags.retries) + 1);
    if (worst > 5 * std.time.ns_per_min) return field_.fail(
        w,
        "--timeout {f} with --retries {d} could take {f}; at most 5m is allowed",
        .{ flags.timeout, flags.retries, cfg.Duration{ .ns = worst } },
    );
}
const send_flags = cli.flags(SendFlags, field_.Set(.{field_.Spec(SendFlags){ .checks = &.{.from(boundedWait)}, .fields = .{
    .header = .{ .help = "A header, `Name: value`; repeat for more" },
    .accept = .{ .help = "Media types to accept, comma-separated" },
    .json = .{ .help = "Send the body fields as JSON" },
    .form = .{ .help = "Send the body fields as a form" },
    .timeout = .{ .help = "Give up on a try after this long" },
    .max_size = .{ .help = "The largest response to read" },
    .retries = .{ .help = "Tries after the first that fails", .checks = &.{.max(10)} },
    .http_version = .{ .help = "The HTTP version", .checks = &.{.oneOf(&.{ "1.0", "1.1", "2" })} },
    .token = .{ .secret = true, .help = "A bearer token" },
    .user = .{ .help = "The user, for basic auth" },
    .password = .{ .secret = true, .help = "The password of --user" },
    .insecure = .{ .help = "Do not verify the server's certificate" },
    .proxy = .{ .deprecated = "set HTTPS_PROXY instead", .help = "A proxy to go through" },
} }}), .{ .fields = .{
    .header = .{ .short = 'H' },
    .accept = .{ .split = ',' },
    .form = .{ .short = 'f' },
    .timeout = .{ .short = 't' },
    .token = .{ .env = "HTTPC_TOKEN" },
    .user = .{ .short = 'u', .requires = &.{.password} },
    .insecure = .{ .short = 'k', .aliases = &.{"no-verify"} },
    .trace = .{ .hidden = true },
}, .exclusive = &.{&.{ .json, .form }} });

/// What `send` prints: as `field: value` lines, or as JSON with `-o json`.
const Request = struct {
    method: []const u8,
    url: []const u8,
    query: []const []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u64,
    max_bytes: u64,
    tries: u8,
};

fn send(ctx: *cli.Context, flags: SendFlags, args: SendArgs) !void {
    var query: std.ArrayList([]const u8) = .empty;
    var headers: std.ArrayList([]const u8) = .empty;
    var fields: std.ArrayList([2][]const u8) = .empty;
    for (args.items) |item| {
        // `name==value` is a query parameter, `Name:value` a header, `name=value` a field.
        if (std.mem.indexOf(u8, item, "==")) |at| {
            try query.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}={s}", .{
                item[0..at], item[at + 2 ..],
            }));
        } else if (std.mem.indexOfScalar(u8, item, '=')) |at| {
            try fields.append(ctx.arena, .{ item[0..at], item[at + 1 ..] });
        } else if (std.mem.indexOfScalar(u8, item, ':')) |at| {
            try headers.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{
                item[0..at], std.mem.trim(u8, item[at + 1 ..], " "),
            }));
        } else {
            return ctx.usageError("\"{s}\" is not an item; see httpc help items", .{item});
        }
    }
    try headers.appendSlice(ctx.arena, flags.header);
    if (flags.accept.len > 0) {
        const joined = try std.mem.join(ctx.arena, ", ", flags.accept);
        try headers.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "Accept: {s}", .{joined}));
    }
    // A secret is never printed, whichever flag or variable it came from.
    if (flags.token != null) try headers.append(ctx.arena, "Authorization: Bearer ••••");
    if (flags.user) |user| {
        const line = try std.fmt.allocPrint(ctx.arena, "Authorization: Basic {s}:••••", .{user});
        try headers.append(ctx.arena, line);
    }
    if (flags.insecure) ctx.warn("not verifying the certificate of {s}", .{args.url});
    ctx.log(.debug, "HTTP/{s}, {d} items", .{ flags.http_version, args.items.len });

    var body: ?[]const u8 = null;
    if (fields.items.len > 0) {
        if (args.method == .get or args.method == .head) {
            return ctx.usageError("a {t} request has no body; use name==value", .{args.method});
        }
        var out: std.Io.Writer.Allocating = .init(ctx.arena);
        if (flags.form) {
            for (fields.items, 0..) |field, i| {
                try out.writer.print("{s}{s}={s}", .{ if (i > 0) "&" else "", field[0], field[1] });
            }
        } else {
            var json: std.json.Stringify = .{ .writer = &out.writer };
            try json.beginObject();
            for (fields.items) |field| {
                try json.objectField(field[0]);
                try json.write(field[1]);
            }
            try json.endObject();
        }
        body = out.written();
    }
    try ctx.render(Request{
        .method = try std.ascii.allocUpperString(ctx.arena, @tagName(args.method)),
        .url = args.url,
        .query = query.items,
        .headers = headers.items,
        .body = body,
        .timeout_ms = flags.timeout.ns / std.time.ns_per_ms,
        .max_bytes = flags.max_size.bytes,
        .tries = flags.retries + 1,
    });
}

/// URLs to complete, as a client would offer from its history.
fn completeUrl(ctx: *cli.Context, prefix: []const u8) ![]const cli.Candidate {
    const known = [_]cli.Candidate{
        .{ .value = "https://api.example.com/users", .description = "yesterday" },
        .{ .value = "https://api.example.com/orders", .description = "last week" },
    };
    var out: std.ArrayList(cli.Candidate) = .empty;
    for (known) |candidate| {
        if (std.mem.startsWith(u8, candidate.value, prefix)) try out.append(ctx.arena, candidate);
    }
    return out.items;
}

const LoginFlags = struct {
    token: []const u8,
};
const login_flags = cli.flags(LoginFlags, field_.Set(.{field_.Spec(LoginFlags){ .fields = .{
    .token = .{ .secret = true, .help = "The token to save" },
} }}), .{ .fields = .{
    .token = .{ .prompt = "Token" },
} });

fn login(ctx: *cli.Context, flags: LoginFlags) !void {
    try ctx.out.print("saved a token of {d} characters\n", .{flags.token.len});
}

fn logout(ctx: *cli.Context) !void {
    try ctx.out.writeAll("forgot the token\n");
}

pub const root = cli.command(.{
    .name = "httpc",
    .summary = "Make HTTP requests from the command line",
    .logging = true,
    .subcommands = .{
        cli.command(.{
            .name = "send",
            .aliases = &.{"s"},
            .summary = "Send a request",
            .description =
            \\Send a request to URL. Items after the URL add to it: name==value a query
            \\parameter, Name:value a header, name=value a body field.
            ,
            .group = "Requests",
            .flags = send_flags,
            .args = send_args,
            .output = true,
            .examples =
            \\httpc send get https://api.example.com/users page==2 --accept json,html
            \\httpc send post https://api.example.com/users name=ada -f -H 'X-Trace: 1'
            \\HTTPC_TOKEN=... httpc send delete https://api.example.com/users/7
            ,
            .run = send,
        }),
        cli.command(.{
            .name = "auth",
            .summary = "Manage the saved token",
            .group = "Setup",
            .subcommands = .{
                cli.command(.{
                    .name = "login",
                    .summary = "Save a token, asking for it when not given",
                    .flags = login_flags,
                    .run = login,
                }),
                cli.command(.{
                    .name = "logout",
                    .summary = "Forget the saved token",
                    .confirm = "Forget the saved token?",
                    .run = logout,
                }),
            },
        }),
        cli.command(.{
            .name = "items",
            .topic = true,
            .summary = "How request items are written",
            .description =
            \\Request items follow the URL:
            \\
            \\  name==value   a query parameter     page==2
            \\  Name:value    a header              X-Trace:1
            \\  name=value    a body field          name=ada
            \\
            \\Body fields are sent as JSON unless --form is given.
            ,
        }),
    },
});

/// Logs how long every command took, at `-vv`.
fn timed(ctx: *cli.Context, next: cli.Context.Next) anyerror!void {
    const start = std.Io.Timestamp.now(ctx.io, .awake);
    defer {
        const elapsed = start.durationTo(std.Io.Timestamp.now(ctx.io, .awake));
        ctx.log(.debug, "{s} took {d}µs", .{
            ctx.command().name,
            @divTrunc(elapsed.toNanoseconds(), std.time.ns_per_us),
        });
    }
    return next.run();
}

const app: cli.App = .{
    .root = &root,
    .version = cli.version.string(.{ .version = "0.3.0", .date = "2026-10-14" }),
    .response_files = true,
    .prefix_matching = true,
    .middleware = &.{timed},
};

pub fn main(init: std.process.Init) u8 {
    return app.run(init);
}

const testing = std.testing;

fn expectRun(
    args: []const []const u8,
    options: cli.testing.Options,
    status: u8,
    out: []const u8,
) !void {
    const result = try cli.testing.run(app, args, options);
    defer result.deinit();
    testing.expectEqual(status, result.status) catch |err| {
        std.debug.print("{s}", .{result.err});
        return err;
    };
    try testing.expectEqualStrings(out, result.out);
}

test "items, repeated and split flags, and a secret from the environment" {
    try expectRun(&.{
        "s",      "post", "https://x/users", "name=ada",   "page==2",
        "X-A:1",  "-H",   "X-B: 2",          "--accept",   "json,html",
        "--form", "-t",   "5s",              "--max-size", "1MiB",
    }, .{ .env = &.{.{ "HTTPC_TOKEN", "hunter2" }} }, 0,
        \\method:     POST
        \\url:        https://x/users
        \\query:      page=2
        \\headers:    X-A: 1, X-B: 2, Accept: json, html, Authorization: Bearer ••••
        \\body:       name=ada
        \\timeout_ms: 5000
        \\max_bytes:  1048576
        \\tries:      3
        \\
    );
}

test "the grammar refuses what the types refuse" {
    try expectRun(&.{ "send", "fetch", "https://x" }, .{}, 2, ""); // not a method
    try expectRun(&.{ "send", "get", "https://x", "--retries", "11" }, .{}, 2, ""); // bounds
    try expectRun(&.{ "send", "get", "https://x", "--http-version", "3" }, .{}, 2, "");
    try expectRun(&.{ "send", "post", "https://x", "--json", "--form" }, .{}, 2, "");
    try expectRun(&.{ "send", "get", "https://x", "-u", "ada" }, .{}, 2, ""); // needs --password
    try expectRun(&.{ "send", "get", "https://x", "-t", "2m", "--retries", "3" }, .{}, 2, "");
    try expectRun(&.{ "send", "get", "https://x", "a=1" }, .{}, 2, ""); // a GET has no body
}

test "an old name still works, and a deprecated flag says so" {
    const result = try cli.testing.run(app, &.{
        "send", "get", "https://x", "--no-verify", "--proxy", "p",
    }, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expect(std.mem.indexOf(u8, result.err, "--proxy is deprecated") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "not verifying") != null);
}

test "a required secret is asked for at a terminal, and refused without one" {
    const saved = "saved a token of 7 characters\n";
    try expectRun(&.{ "au", "logi" }, .{ .stdin = "hunter2\n" }, 0, saved);
    try expectRun(&.{ "au", "lo" }, .{}, 2, ""); // login or logout?
    try expectRun(&.{ "auth", "login" }, .{}, 2, "");
    try expectRun(&.{ "auth", "logout", "--yes" }, .{}, 0, "forgot the token\n");
}

test "JSON for programs, and errors as JSON too" {
    const result = try cli.testing.run(app, &.{ "send", "get", "https://x", "-o", "json" }, .{});
    defer result.deinit();
    try testing.expect(std.mem.startsWith(u8, result.out, "{\n  \"method\": \"GET\""));
    const bad: []const []const u8 = &.{ "send", "get", "https://x", "a=1", "-o", "json" };
    const failed = try cli.testing.run(app, bad, .{});
    defer failed.deinit();
    const said = "{\"error\":\"a get request has no body";
    try testing.expect(std.mem.startsWith(u8, failed.err, said));
}

test "completion offers the methods and the URLs" {
    const methods = try cli.testing.run(app, &.{ "__complete", "send", "p" }, .{});
    defer methods.deinit();
    try testing.expect(std.mem.startsWith(u8, methods.out, "post\nput\npatch\n"));
    const typed = "https://api.example.com/o";
    const urls = try cli.testing.run(app, &.{ "__complete", "send", "get", typed }, .{});
    defer urls.deinit();
    const offered = "https://api.example.com/orders\tlast week\n";
    try testing.expect(std.mem.startsWith(u8, urls.out, offered));
}
