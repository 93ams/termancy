//! Files fetched from a URL and kept in a cache directory: a configuration file served
//! over HTTP, read again only when it changed (`If-None-Match` with the cached `ETag`),
//! and read from the cache when the server cannot be reached, so a program keeps working
//! offline with what it last saw.
//!
//! ```zig
//! var client: std.http.Client = .{ .allocator = gpa, .io = io };
//! defer client.deinit();
//! var http: remote.HttpFetcher = .{ .client = &client };
//! const file = try remote.get(io, gpa, http.fetcher(), cache_dir, url, 1 << 20);
//! defer gpa.free(file.bytes);
//! if (file.stale) log.warn("using the cached copy of {s}", .{url});
//! try config.loadSource(url, file.bytes, format, &diag); // `cfg`, in the program
//! ```
//!
//! The cache holds two files per URL, named by a hash of it: `<hash>.body` and
//! `<hash>.etag`. Nothing is fetched or cached except when `get` is called.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{ FetchFailed, NotFound, TooLarge } || Allocator.Error;

/// What a fetch got.
pub const Response = union(enum) {
    /// The server says the cached copy (the `etag` given) is current.
    not_modified,
    /// The body, and its `ETag` when the server sent one; both owned by the caller.
    body: struct { bytes: []u8, etag: ?[]u8 = null },
};

/// Gets a URL, conditionally on `etag`. `HttpFetcher` is the real one; tests pass fakes.
pub const Fetcher = struct {
    context: *anyopaque,
    fetchFn: *const fn (
        context: *anyopaque,
        gpa: Allocator,
        url: []const u8,
        etag: ?[]const u8,
        limit: usize,
    ) Error!Response,

    pub fn fetch(
        f: Fetcher,
        gpa: Allocator,
        url: []const u8,
        etag: ?[]const u8,
        limit: usize,
    ) Error!Response {
        return f.fetchFn(f.context, gpa, url, etag, limit);
    }
};

/// A file got by `get`.
pub const File = struct {
    /// Owned by the caller.
    bytes: []u8,
    /// Read from the cache: the server said it had not changed, or could not be reached.
    from_cache: bool,
    /// Read from the cache because the server could not be reached, so it may be out of
    /// date.
    stale: bool = false,
};

/// The body at `url`, at most `limit` bytes: fetched when it changed (or was never
/// cached), from `cache` otherwise or when fetching fails. Fails when fetching fails and
/// nothing is cached. A failure to write the cache is not an error: the body is still
/// returned.
pub fn get(
    io: Io,
    gpa: Allocator,
    fetcher: Fetcher,
    cache: Io.Dir,
    url: []const u8,
    limit: usize,
) Error!File {
    var names: Names = .of(url);
    const cached_etag = cache.readFileAlloc(io, names.etag(), gpa, .limited(1024)) catch null;
    defer if (cached_etag) |e| gpa.free(e);
    const cached = cache.readFileAlloc(io, names.body(), gpa, .limited(limit)) catch null;
    errdefer if (cached) |c| gpa.free(c);
    // Without a body to fall back on, a conditional request could be answered with nothing.
    const condition = if (cached != null) cached_etag else null;
    const response = fetcher.fetch(gpa, url, condition, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotFound, error.FetchFailed, error.TooLarge => {
            const bytes = cached orelse return err;
            return .{ .bytes = bytes, .from_cache = true, .stale = true };
        },
    };
    switch (response) {
        .not_modified => {
            const bytes = cached orelse return error.FetchFailed;
            return .{ .bytes = bytes, .from_cache = true };
        },
        .body => |fresh| {
            defer if (fresh.etag) |e| gpa.free(e);
            if (cached) |c| gpa.free(c);
            cache.writeFile(io, .{ .sub_path = names.body(), .data = fresh.bytes }) catch {};
            if (fresh.etag) |etag| {
                cache.writeFile(io, .{ .sub_path = names.etag(), .data = etag }) catch {};
            } else {
                cache.deleteFile(io, names.etag()) catch {};
            }
            return .{ .bytes = fresh.bytes, .from_cache = false };
        },
    }
}

/// The cache's file names for a URL: the first 16 bytes of its SHA-256, in hex.
const Names = struct {
    buffer: [32 + ".body".len]u8,

    fn of(url: []const u8) Names {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        var names: Names = undefined;
        _ = std.fmt.bufPrint(&names.buffer, "{x}", .{digest[0..16]}) catch unreachable;
        return names;
    }

    fn body(n: *Names) []const u8 {
        @memcpy(n.buffer[32..], ".body");
        return &n.buffer;
    }

    fn etag(n: *Names) []const u8 {
        @memcpy(n.buffer[32..][0..5], ".etag");
        return &n.buffer;
    }
};

/// A `Fetcher` over `std.http.Client`. The caller owns the client (and its `Io`).
pub const HttpFetcher = struct {
    client: *std.http.Client,
    max_redirects: u16 = 5,
    user_agent: []const u8 = "snek",

    pub fn fetcher(http: *HttpFetcher) Fetcher {
        return .{ .context = http, .fetchFn = fetchErased };
    }

    fn fetchErased(
        context: *anyopaque,
        gpa: Allocator,
        url: []const u8,
        etag: ?[]const u8,
        limit: usize,
    ) Error!Response {
        const http: *HttpFetcher = @ptrCast(@alignCast(context));
        return http.fetch(gpa, url, etag, limit);
    }

    /// One GET, following redirects, with `If-None-Match` when `etag` is given.
    pub fn fetch(
        http: *HttpFetcher,
        gpa: Allocator,
        url: []const u8,
        etag: ?[]const u8,
        limit: usize,
    ) Error!Response {
        const uri = std.Uri.parse(url) catch return error.FetchFailed;
        const conditional = [_]std.http.Header{
            .{ .name = "if-none-match", .value = etag orelse "" },
        };
        var request = http.client.request(.GET, uri, .{
            .redirect_behavior = .init(http.max_redirects),
            .headers = .{
                .user_agent = .{ .override = http.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = if (etag != null) &conditional else &.{},
        }) catch |err| return failure(err);
        defer request.deinit();
        request.sendBodiless() catch return error.FetchFailed;
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |err| return failure(err);
        switch (response.head.status) {
            .not_modified => return .not_modified,
            .not_found => return error.NotFound,
            else => |status| if (status.class() != .success) return error.FetchFailed,
        }
        if (response.head.content_length) |length| if (length > limit) return error.TooLarge;
        var new_etag: ?[]u8 = null;
        errdefer if (new_etag) |e| gpa.free(e);
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag"))
                new_etag = try gpa.dupe(u8, header.value);
        }
        var transfer_buffer: [64]u8 = undefined;
        const body = response.reader(&transfer_buffer);
        const bytes = body.allocRemaining(gpa, .limited(limit)) catch |err| return switch (err) {
            error.StreamTooLong => error.TooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.FetchFailed,
        };
        return .{ .body = .{ .bytes = bytes, .etag = new_etag } };
    }

    fn failure(err: anyerror) Error {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.FetchFailed;
    }
};

const testing = std.testing;

/// A server in memory: its current body and ETag, whether it is reachable, and what it
/// was asked.
const Fake = struct {
    body: []const u8 = "a = 1\n",
    etag: ?[]const u8 = "\"v1\"",
    down: bool = false,
    /// A copy of the ETag the last fetch was conditional on.
    asked_with: ?[]const u8 = null,
    asked_buffer: [16]u8 = undefined,
    calls: usize = 0,

    fn fetcher(f: *Fake) Fetcher {
        return .{ .context = f, .fetchFn = fetch };
    }

    fn fetch(
        context: *anyopaque,
        gpa: Allocator,
        _: []const u8,
        etag: ?[]const u8,
        _: usize,
    ) Error!Response {
        const f: *Fake = @ptrCast(@alignCast(context));
        f.calls += 1;
        f.asked_with = null;
        if (etag) |e| {
            @memcpy(f.asked_buffer[0..e.len], e);
            f.asked_with = f.asked_buffer[0..e.len];
        }
        if (f.down) return error.FetchFailed;
        if (etag != null and f.etag != null and std.mem.eql(u8, etag.?, f.etag.?))
            return .not_modified;
        return .{ .body = .{
            .bytes = try gpa.dupe(u8, f.body),
            .etag = if (f.etag) |e| try gpa.dupe(u8, e) else null,
        } };
    }
};

test "fetched once, then revalidated with the ETag, then read from the cache offline" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var server: Fake = .{};
    const url = "https://example.com/app.toml";

    const first = try get(io, gpa, server.fetcher(), tmp.dir, url, 1024);
    defer gpa.free(first.bytes);
    try testing.expectEqualStrings("a = 1\n", first.bytes);
    try testing.expect(!first.from_cache);
    try testing.expectEqual(null, server.asked_with);

    const second = try get(io, gpa, server.fetcher(), tmp.dir, url, 1024);
    defer gpa.free(second.bytes);
    try testing.expectEqualStrings("\"v1\"", server.asked_with.?);
    try testing.expect(second.from_cache and !second.stale);
    try testing.expectEqualStrings("a = 1\n", second.bytes);

    server.body = "a = 2\n";
    server.etag = "\"v2\"";
    const changed = try get(io, gpa, server.fetcher(), tmp.dir, url, 1024);
    defer gpa.free(changed.bytes);
    try testing.expectEqualStrings("a = 2\n", changed.bytes);
    try testing.expect(!changed.from_cache);

    server.down = true;
    const offline = try get(io, gpa, server.fetcher(), tmp.dir, url, 1024);
    defer gpa.free(offline.bytes);
    try testing.expectEqualStrings("a = 2\n", offline.bytes);
    try testing.expect(offline.stale);

    // Never cached and unreachable: the error.
    try testing.expectError(
        error.FetchFailed,
        get(io, gpa, server.fetcher(), tmp.dir, "https://x.y/other", 1024),
    );
}

test "a body without an ETag is cached and fetched again in full" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var server: Fake = .{ .etag = null };
    const a = try get(io, gpa, server.fetcher(), tmp.dir, "https://example.com/x", 1024);
    gpa.free(a.bytes);
    const b = try get(io, gpa, server.fetcher(), tmp.dir, "https://example.com/x", 1024);
    gpa.free(b.bytes);
    try testing.expectEqual(null, server.asked_with);
    try testing.expectEqual(2, server.calls);
}

test "HttpFetcher: the interface compiles without being called" {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    var http: HttpFetcher = .{ .client = &client };
    const f = http.fetcher();
    try testing.expect(f.context == @as(*anyopaque, &http));
}
