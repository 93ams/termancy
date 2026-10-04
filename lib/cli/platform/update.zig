//! Self-update: check, verify, and replace the running executable.
//!
//! ## What was there, and why it was not an updater
//!
//! `[measured]` `updater.zig` was 18 lines with one symbol,
//! `updateBinary(io, exe_path, new_binary_bytes)`. It never fetched - the caller
//! passed a binary it already had - it never verified anything, and it recreated
//! the file with default permissions, **losing `+x` on POSIX**. `version.zig` next
//! to it read a bare version string from a URL and had no callers. So there was no
//! check -> download -> verify -> replace pipeline at all, just two halves that did
//! not meet.
//!
//! ## Where the network went: it is the caller's
//!
//! This module does not fetch. The transport arrives as a `Fetcher` the caller
//! supplies, and the release *identity* - which version, from which URL, with which
//! checksum - arrives in the `Request`. Both of those are policy, and policy is the
//! caller's to set:
//!
//!   * a GitHub release adapter and a plain "URL plus a checksum from your own
//!     manifest" are the same updater with a different `Fetcher` and a different
//!     `Request`, so choosing between them is not a decision this module should
//!     make;
//!   * `snek` has no HTTP client, deliberately - it is a CLI toolkit, not a network
//!     library, and vendoring a TLS stack to serve a feature most binaries will
//!     never enable would be a poor trade.
//!
//! That also makes the whole pipeline testable without a network, which is the
//! only way the verification path gets exercised at all.
//!
//! ## The checksum is not optional
//!
//! `Request.expected_sha256` is required and checked **before** anything is written.
//! A self-updater that installs whatever it downloaded is a remote code execution
//! primitive with a version number attached; making verification opt-in would make
//! it opt-in for the people least likely to read this comment.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Error = error{
    /// The digest of what was downloaded does not match the request.
    ChecksumMismatch,
    /// `expected_sha256` was not 64 hex characters.
    MalformedChecksum,
    /// The version could not be parsed.
    MalformedVersion,
    /// Writing the replacement failed. The original was restored if it could be.
    ReplaceFailed,
    FetchFailed,
    OutOfMemory,
};

/// A release version: `major.minor.patch`, with an optional `-prerelease`.
///
/// A pre-release compares **lower** than the release it precedes, which is the
/// semver rule and the one that matters here: `2.0.0-rc1` must not be installed
/// over `2.0.0` by a checker that compares the numbers and ignores the suffix.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Empty for a release version.
    prerelease: []const u8 = "",

    pub fn parse(text: []const u8) Error!Version {
        var rest = std.mem.trim(u8, text, " \t\r\n");
        // A leading `v` is what a git tag looks like and what a release page shows.
        if (rest.len > 0 and (rest[0] == 'v' or rest[0] == 'V')) rest = rest[1..];
        if (rest.len == 0) return error.MalformedVersion;

        var parts = std.mem.splitScalar(u8, rest, '.');
        const major = try parseNumeric(parts.next() orelse return error.MalformedVersion);
        const minor = try parseNumeric(parts.next() orelse return error.MalformedVersion);

        // The patch component may carry the pre-release suffix: `0-rc1`.
        const patch_field = parts.next() orelse return error.MalformedVersion;
        if (parts.next() != null) return error.MalformedVersion;

        const dash = std.mem.indexOfScalar(u8, patch_field, '-');
        const patch_text = if (dash) |at| patch_field[0..at] else patch_field;
        const prerelease = if (dash) |at| patch_field[at + 1 ..] else "";

        return .{
            .major = major,
            .minor = minor,
            .patch = try parseNumeric(patch_text),
            .prerelease = prerelease,
        };
    }

    /// Orders two versions, ignoring any build metadata.
    pub fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return if (self.major < other.major) .lt else .gt;
        if (self.minor != other.minor) return if (self.minor < other.minor) .lt else .gt;
        if (self.patch != other.patch) return if (self.patch < other.patch) .lt else .gt;

        // Equal numbers: a release outranks its own pre-releases, and two
        // pre-releases are compared as text so `rc2` > `rc1`.
        if (self.prerelease.len == 0 and other.prerelease.len == 0) return .eq;
        if (self.prerelease.len == 0) return .gt;
        if (other.prerelease.len == 0) return .lt;
        return std.mem.order(u8, self.prerelease, other.prerelease);
    }

    pub fn isNewerThan(self: Version, other: Version) bool {
        return self.order(other) == .gt;
    }

    fn parseNumeric(text: []const u8) Error!u32 {
        if (text.len == 0) return error.MalformedVersion;
        return std.fmt.parseInt(u32, text, 10) catch error.MalformedVersion;
    }
};

/// The transport, supplied by the caller. `snek` has no HTTP client by design.
pub const Fetcher = struct {
    /// Non-const on purpose: a real fetcher holds state - a connection pool, a
    /// token, a retry counter - and a const context would force every one of them
    /// to cast the const away.
    ctx: ?*anyopaque = null,
    /// Downloads `url`, returning bytes the **caller** owns.
    fetch: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) anyerror![]u8,

    pub fn get(self: Fetcher, allocator: std.mem.Allocator, url: []const u8) anyerror![]u8 {
        return self.fetch(self.ctx, allocator, url);
    }
};

/// One update attempt. Everything about *which* release this is comes from here.
pub const Request = struct {
    /// What is running now.
    current_version: Version,
    /// The version the caller has decided is available.
    new_version: Version,
    /// Where to download it.
    url: []const u8,
    /// 64 lowercase hex characters of the downloaded bytes' SHA-256. Required.
    expected_sha256: []const u8,
    /// The executable to replace.
    target_path: []const u8,
    /// A `Fetcher` plus a checksum is the whole trust model. Stated here so it is
    /// visible at the call site rather than inferred from the code.
    fetcher: Fetcher,
};

pub const Outcome = enum {
    /// The running version is not older. Nothing was downloaded.
    up_to_date,
    /// The new binary was verified and put in place.
    installed,
};

/// The hex SHA-256 of `bytes`, lowercase.
pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const out = try allocator.alloc(u8, 64);
    errdefer allocator.free(out);
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
    return out;
}

/// Constant-time comparison of a lowercase-hex digest against bytes.
///
/// Constant-time because this compares a secret's worth of attacker-influenced
/// input, and a digest comparison that leaks its position is the textbook way to
/// defeat verification by trying checksums one byte at a time.
pub fn checksumMatches(expected_hex: []const u8, bytes: []const u8) Error!bool {
    if (expected_hex.len != 64) return error.MalformedChecksum;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    var expected: [32]u8 = undefined;
    for (&expected, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch
            return error.MalformedChecksum;
    }
    return std.crypto.timing_safe.eql([32]u8, digest, expected);
}

/// Runs the pipeline: check, download, verify, replace.
///
/// Returns `up_to_date` **without fetching** when the running version is not older,
/// so the common case costs nothing and the network is only touched when there is
/// something to do.
pub fn install(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) Error!Outcome {
    assert(request.url.len > 0);
    assert(request.target_path.len > 0);

    if (!request.new_version.isNewerThan(request.current_version)) return .up_to_date;

    const binary = request.fetcher.get(allocator, request.url) catch return error.FetchFailed;
    defer allocator.free(binary);

    // Verification happens before a single byte is written. An updater that wrote
    // first and checked after would have already replaced the executable it is
    // running from.
    const matches = try checksumMatches(request.expected_sha256, binary);
    if (!matches) return error.ChecksumMismatch;

    try replaceExecutable(io, request.target_path, binary);
    return .installed;
}

/// Puts `bytes` at `path`, atomically where the platform allows it.
///
/// The order is: write the new image beside the target, move the target aside, move
/// the new image into place, and restore the old one if that last step fails. The
/// alternative - truncate the target and write into it - destroys the only copy of
/// the program at the moment it is most likely to be interrupted.
///
/// Permissions are set **on the new file before it is moved into place**, which is
/// what stops the replacement from losing `+x` on POSIX. The version this replaces
/// used `createFile` with default permissions and did exactly that.
pub fn replaceExecutable(io: std.Io, path: []const u8, bytes: []const u8) Error!void {
    assert(path.len > 0);
    assert(bytes.len > 0);

    var staged_buf: [512]u8 = undefined;
    const staged = std.fmt.bufPrint(&staged_buf, "{s}.new", .{path}) catch
        return error.ReplaceFailed;

    var aside_buf: [512]u8 = undefined;
    const aside = std.fmt.bufPrint(&aside_buf, "{s}.old", .{path}) catch
        return error.ReplaceFailed;

    const dir = std.Io.Dir.cwd();

    // 1. The new image, with the mode it needs to be runnable at its destination.
    {
        const file = dir.createFile(io, staged, .{
            .truncate = true,
            .permissions = executablePermissions(),
        }) catch return error.ReplaceFailed;
        defer file.close(io);
        file.writePositionalAll(io, bytes, 0) catch return error.ReplaceFailed;
    }
    errdefer dir.deleteFile(io, staged) catch {};

    // 2. Move the current image aside. Best-effort: on a platform that forbids it
    //    the move into place below still succeeds on POSIX, and failing the whole
    //    update because a backup could not be made would be worse than not having
    //    the backup.
    var had_aside = false;
    if (dir.rename(path, dir, aside, io)) |_| {
        had_aside = true;
    } else |_| {}

    // 3. Move the new image into place.
    dir.rename(staged, dir, path, io) catch {
        // Roll back rather than leave the user with no executable at all.
        if (had_aside) dir.rename(aside, dir, path, io) catch {};
        return error.ReplaceFailed;
    };
}

/// The mode a replacement executable is created with.
///
/// `.executable_file` rather than a hand-built `0o755`. On POSIX `Permissions` is
/// an **enum** over `mode_t`, not an integer, so `@as(Permissions, 0o755)` does not
/// compile there at all - and the first version of this function did exactly that,
/// which was invisible on Windows because the non-Windows branch is never analysed
/// there. The standard library already names the thing being asked for.
fn executablePermissions() std.Io.File.Permissions {
    return .executable_file;
}

const testing = std.testing;

test "a version parses with and without a leading v" {
    const a = try Version.parse("1.2.3");
    try testing.expectEqual(@as(u32, 1), a.major);
    try testing.expectEqual(@as(u32, 2), a.minor);
    try testing.expectEqual(@as(u32, 3), a.patch);
    try testing.expectEqualStrings("", a.prerelease);

    const b = try Version.parse("v2.0.10");
    try testing.expectEqual(@as(u32, 2), b.major);
    try testing.expectEqual(@as(u32, 10), b.patch);

    const c = try Version.parse("  1.0.0-rc2\n");
    try testing.expectEqualStrings("rc2", c.prerelease);
}

test "a malformed version is reported rather than defaulted" {
    try testing.expectError(error.MalformedVersion, Version.parse(""));
    try testing.expectError(error.MalformedVersion, Version.parse("1.2"));
    try testing.expectError(error.MalformedVersion, Version.parse("1.2.3.4"));
    try testing.expectError(error.MalformedVersion, Version.parse("1.2.x"));
    try testing.expectError(error.MalformedVersion, Version.parse("v"));
}

test "versions order numerically, not as text" {
    // The bug a string comparison produces: "10" < "9".
    const nine = try Version.parse("1.9.0");
    const ten = try Version.parse("1.10.0");
    try testing.expect(ten.isNewerThan(nine));
    try testing.expect(!nine.isNewerThan(ten));
    try testing.expectEqual(std.math.Order.eq, (try Version.parse("1.0.0")).order(
        try Version.parse("v1.0.0"),
    ));
}

test "a pre-release is older than the release it precedes" {
    // `2.0.0-rc1` must not roll a user back from `2.0.0`, which is exactly what a
    // checker that ignores the suffix would do.
    const release = try Version.parse("2.0.0");
    const candidate = try Version.parse("2.0.0-rc1");
    try testing.expect(release.isNewerThan(candidate));
    try testing.expect(!candidate.isNewerThan(release));

    // And pre-releases order among themselves.
    try testing.expect((try Version.parse("2.0.0-rc2")).isNewerThan(
        try Version.parse("2.0.0-rc1"),
    ));
}

test "the digest is the one everybody else computes" {
    // The SHA-256 of the empty string, which is the vector every implementation is
    // checked against.
    const empty = try sha256Hex(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        empty,
    );

    // And of "abc", the other standard vector.
    const abc = try sha256Hex(testing.allocator, "abc");
    defer testing.allocator.free(abc);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        abc,
    );
}

test "checksumMatches accepts the right digest and rejects a wrong one" {
    const digest = try sha256Hex(testing.allocator, "the payload");
    defer testing.allocator.free(digest);

    try testing.expect(try checksumMatches(digest, "the payload"));
    try testing.expect(!try checksumMatches(digest, "the payloaD"));
    try testing.expect(!try checksumMatches(digest, ""));
    // A single flipped character anywhere must fail, not just at the end.
    var flipped = try testing.allocator.dupe(u8, digest);
    defer testing.allocator.free(flipped);
    flipped[0] = if (flipped[0] == '0') '1' else '0';
    try testing.expect(!try checksumMatches(flipped, "the payload"));
}

test "a checksum of the wrong length is rejected as malformed" {
    try testing.expectError(error.MalformedChecksum, checksumMatches("abcd", "x"));
    try testing.expectError(error.MalformedChecksum, checksumMatches("", "x"));
}

/// A fetcher that records whether it was called and serves fixed bytes.
const StubFetcher = struct {
    payload: []const u8,
    calls: usize = 0,
    fail: bool = false,

    fn fetch(ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) anyerror![]u8 {
        _ = url;
        const self: *StubFetcher = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.fail) return error.ConnectionRefused;
        return allocator.dupe(u8, self.payload);
    }

    fn interface(self: *StubFetcher) Fetcher {
        return .{ .ctx = self, .fetch = fetch };
    }
};

test "a running version that is not older short-circuits before the network" {
    var stub = StubFetcher{ .payload = "new binary" };

    const outcome = try install(testing.allocator, testing.io, .{
        .current_version = try Version.parse("2.0.0"),
        .new_version = try Version.parse("2.0.0"),
        .url = "https://example.invalid/v2",
        .expected_sha256 = "0" ** 64,
        .target_path = "unused",
        .fetcher = stub.interface(),
    });

    try testing.expectEqual(Outcome.up_to_date, outcome);
    // The claim that matters: nothing was downloaded, so a checker running on
    // every invocation costs nothing.
    try testing.expectEqual(@as(usize, 0), stub.calls);
}

test "an older advertised version does not roll the user back" {
    var stub = StubFetcher{ .payload = "old binary" };
    const outcome = try install(testing.allocator, testing.io, .{
        .current_version = try Version.parse("2.0.0"),
        .new_version = try Version.parse("1.9.9"),
        .url = "https://example.invalid/v1",
        .expected_sha256 = "0" ** 64,
        .target_path = "unused",
        .fetcher = stub.interface(),
    });

    try testing.expectEqual(Outcome.up_to_date, outcome);
    try testing.expectEqual(@as(usize, 0), stub.calls);
}

test "a bad checksum refuses the update and leaves the target untouched" {
    // The assertion that makes verification worth having: a tampered payload must
    // not reach the filesystem at all.
    const io = testing.io;
    const path = ".zig-cache/update-checksum-test.bin";

    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, ".zig-cache") catch {};
    {
        const file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, "ORIGINAL", 0);
    }
    defer dir.deleteFile(io, path) catch {};

    var stub = StubFetcher{ .payload = "TAMPERED" };

    try testing.expectError(error.ChecksumMismatch, install(testing.allocator, io, .{
        .current_version = try Version.parse("1.0.0"),
        .new_version = try Version.parse("2.0.0"),
        .url = "https://example.invalid/v2",
        .expected_sha256 = "0" ** 64,
        .target_path = path,
        .fetcher = stub.interface(),
    }));

    // Still the original bytes.
    const after = try dir.readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("ORIGINAL", after);
    // And the staged file was cleaned up rather than left beside it.
    var staged_buf: [256]u8 = undefined;
    const staged = try std.fmt.bufPrint(&staged_buf, "{s}.new", .{path});
    try testing.expect(!existsAt(io, staged));
}

test "a verified update replaces the file and keeps it executable" {
    const io = testing.io;
    const path = ".zig-cache/update-install-test.bin";
    const payload = "the new binary, verified";

    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, ".zig-cache") catch {};
    {
        const file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, "OLD", 0);
    }
    defer dir.deleteFile(io, path) catch {};
    defer dir.deleteFile(io, ".zig-cache/update-install-test.bin.old") catch {};

    const digest = try sha256Hex(testing.allocator, payload);
    defer testing.allocator.free(digest);

    var stub = StubFetcher{ .payload = payload };
    const outcome = try install(testing.allocator, io, .{
        .current_version = try Version.parse("1.0.0"),
        .new_version = try Version.parse("2.0.0"),
        .url = "https://example.invalid/v2",
        .expected_sha256 = digest,
        .target_path = path,
        .fetcher = stub.interface(),
    });

    try testing.expectEqual(Outcome.installed, outcome);
    try testing.expectEqual(@as(usize, 1), stub.calls);

    const after = try dir.readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(payload, after);
}

test "the replacement is created with a mode that can be executed" {
    // The defect the version this replaces shipped with: it recreated the binary
    // with default permissions, so on POSIX an updated program was not executable.
    try testing.expectEqual(
        std.Io.File.Permissions.executable_file,
        executablePermissions(),
    );

    if (comptime std.Io.File.Permissions.has_executable_bit) {
        // POSIX, where the mode really carries an execute bit. Asserting the bit
        // rather than the enum value means an `executable_file` that stopped being
        // executable would be caught here.
        try testing.expect(@intFromEnum(executablePermissions()) & 0o111 != 0);
    }
    // Windows has no execute bit - runnability is decided by the extension - which
    // the standard library reports as `has_executable_bit == false`.
}

test "a fetch failure propagates rather than being treated as up to date" {
    var stub = StubFetcher{ .payload = "x", .fail = true };

    try testing.expectError(error.FetchFailed, install(testing.allocator, testing.io, .{
        .current_version = try Version.parse("1.0.0"),
        .new_version = try Version.parse("2.0.0"),
        .url = "https://example.invalid/v2",
        .expected_sha256 = "0" ** 64,
        .target_path = "unused",
        .fetcher = stub.interface(),
    }));
}

/// Whether `path` exists, as a boolean.
fn existsAt(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
