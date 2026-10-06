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
//!
//! ## GitHub Releases, and what a checksum does not prove
//!
//! A checksum file downloaded from the same host as the binary proves only that the
//! download was not corrupted in transit. Whoever can publish a release can publish a
//! matching checksum, so a checksum is not a trust anchor - it is a consistency check.
//! The parts below describe the GitHub Releases registry, so the caller does not have
//! to hand-roll the JSON, and add an **optional second check**: a detached Ed25519
//! signature over the downloaded bytes, verified against a public key compiled into
//! the caller. That key is the anchor, because it does not travel with the release.
//!
//! The signature is checked *after* the checksum - cheap first, expensive second -
//! and both run before anything is written. A `Request` with a `public_key` set must
//! carry a `signature`, and `install` asserts that pairing rather than quietly
//! skipping the stronger check on a caller's wiring mistake.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Length of a raw Ed25519 public key, as RFC 8032 encodes it.
const public_key_length = 32;
/// Length of a raw Ed25519 signature: the compressed `R` point and the scalar `S`.
const signature_length = 64;

pub const Error = error{
    /// The digest of what was downloaded does not match the request.
    ChecksumMismatch,
    /// `expected_sha256` was not 64 hex characters, or the checksum file had no
    /// usable line for the target asset.
    MalformedChecksum,
    /// The version could not be parsed.
    MalformedVersion,
    /// The release body was not JSON, or did not have the shape this expects.
    MalformedRelease,
    /// The release carried no asset with the requested name.
    AssetNotFound,
    /// The Ed25519 public key or signature was the wrong size or encoding.
    MalformedSignature,
    /// The signature is well formed but does not cover these bytes. Treat it as an
    /// attack, not as corruption: the payload is not what the key holder signed.
    SignatureInvalid,
    /// Writing the replacement failed. The original was restored if it could be.
    ReplaceFailed,
    /// A builder was handed a buffer smaller than the string it produced.
    ReleaseUrlTooLong,
    FetchFailed,
    OutOfMemory,
};

/// What reading a release from the registry can fail with.
///
/// Narrower than `Error` on purpose: nothing here can touch the filesystem, so
/// nothing here can raise `ReplaceFailed`, and a caller wiring up a version check
/// should not have to handle it.
pub const ReleaseError = error{
    MalformedRelease,
    MalformedVersion,
    AssetNotFound,
    ReleaseUrlTooLong,
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
    /// A detached Ed25519 signature over the downloaded bytes, as raw 64 bytes or
    /// as standard base64 of those bytes. `null` means "no signature to check",
    /// which is only allowed when `public_key` is also `null`.
    signature: ?[]const u8 = null,
    /// The 32-byte Ed25519 public key `signature` must verify against. Supplying it
    /// is what makes the signature mandatory, so this field is the policy switch.
    public_key: ?[public_key_length]u8 = null,
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

/// The largest URL or asset name these builders will produce.
///
/// A release download URL is well under this; 512 bytes is the size the rest of this
/// module already stages paths in, and it keeps every builder result out of the
/// allocator with a compile-time bound instead of a runtime one.
pub const max_url_len = 512;

/// One downloadable file in a release.
pub const Asset = struct {
    /// `browser_download_url`: the URL a plain `GET` can read, as opposed to
    /// `url`, which is the JSON metadata for the asset and serves no bytes.
    url: []const u8,
    /// The size GitHub recorded. Meaningful as a cross-check on the download, not
    /// as a limit: the digest and signature are what decide whether bytes are
    /// accepted, and a wrong size here must not become a truncation.
    size: usize,
};

/// The parts of `GET /repos/<owner>/<repo>/releases/latest` this module needs.
///
/// `asset.url` is a slice of the JSON document the release was parsed from, so that
/// document - the caller's arena - must outlive every `Release` taken from it.
pub const Release = struct {
    /// The release's tag, parsed. `v1.2.3` and `1.2.3` both land here.
    version: Version,
    /// The asset the caller asked for by name.
    asset: Asset,
};

/// The API URL for the latest release of `owner/repo`.
///
/// `latest` rather than the release list, because an update check wants exactly one
/// answer. GitHub already excludes drafts and pre-releases from `latest`, which is
/// the same policy `Version` encodes when it orders a pre-release below its release.
pub fn releaseApiUrl(
    buffer: []u8,
    owner: []const u8,
    repo: []const u8,
) ReleaseError![]const u8 {
    assert(owner.len > 0);
    assert(repo.len > 0);

    const url = std.fmt.bufPrint(
        buffer,
        "https://api.github.com/repos/{s}/{s}/releases/latest",
        .{ owner, repo },
    ) catch return error.ReleaseUrlTooLong;
    assert(url.len > 0);
    return url;
}

/// The conventional checksum asset name for `asset_name`: `<asset>.sha256`.
///
/// The convention, not a standard, which is why the caller still supplies the
/// expected digest in the `Request`: this names the file to look for, and the
/// digest inside it is what gets trusted.
pub fn checksumAssetName(buffer: []u8, asset_name: []const u8) ReleaseError![]const u8 {
    assert(asset_name.len > 0);
    assert(buffer.len > 0);

    const name = std.fmt.bufPrint(buffer, "{s}.sha256", .{asset_name}) catch
        return error.ReleaseUrlTooLong;
    assert(name.len > asset_name.len);
    return name;
}

/// Reads a string field of `object`, or `null` if it is absent or not a string.
///
/// GitHub omits fields freely and types drift, so every field is optional here and
/// absence is reported rather than asserted: a missing `tag_name` is a `MalformedRelease`
/// the caller can act on, not a panic in a program whose whole job is to stay running
/// while it replaces itself.
fn getString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

/// Parses a release JSON body, yielding the version and the named asset.
///
/// Returns `MalformedVersion` for a tag that is not a version - GitHub will happily
/// serve a release tagged `nightly` - and `AssetNotFound` when the release simply
/// does not carry the file this platform needs.
///
/// `arena` owns every string in the result: `Release.asset.url` points into JSON
/// scalar storage that must outlive it. The first version of this function took a
/// plain allocator and freed the document on return, which left the caller holding a
/// dangling URL - so the lifetime is now the caller's to state, and an arena is the
/// only allocator whose `deinit` can free the whole document without walking it.
pub fn parseRelease(
    arena: std.mem.Allocator,
    body: []const u8,
    asset_name: []const u8,
) ReleaseError!Release {
    assert(asset_name.len > 0);
    assert(body.len > 0);

    // Leaky on purpose: the result is returned, so its allocations must survive this
    // call. The caller's arena is what frees them, which is why `arena` is a
    // parameter rather than a `std.json.Parsed` this function would have to deinit.
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        body,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Every grammar and type failure from the scanner means the same thing to
        // the caller, and naming it that way keeps the error set narrow.
        else => return error.MalformedRelease,
    };

    const root = switch (value) {
        .object => |object| object,
        else => return error.MalformedRelease,
    };

    const tag = getString(root, "tag_name") orelse return error.MalformedRelease;
    // `Version.parse`'s error set is wider than this one's, but `MalformedVersion`
    // is the only failure it can produce, so the mapping is by name rather than by
    // a `try` that the narrower set would reject.
    const version = Version.parse(tag) catch return error.MalformedVersion;

    // The tag is validated before the assets are searched, so a release tagged
    // `nightly` reports `MalformedVersion` rather than whichever asset error the
    // search happened to reach first.
    const asset = try findAsset(root, asset_name);
    assert(asset.url.len > 0);
    return .{ .version = version, .asset = asset };
}

/// Finds `asset_name` in the release's `assets` array.
///
/// The size is carried through so a caller can sanity-check the download, but it is
/// taken with `@min` rather than a cast: an `i64` from a hostile or buggy response is
/// not allowed to wrap a `usize`.
fn findAsset(root: std.json.ObjectMap, asset_name: []const u8) ReleaseError!Asset {
    assert(asset_name.len > 0);

    const assets_value = root.get("assets") orelse return error.AssetNotFound;
    const assets = switch (assets_value) {
        .array => |array| array,
        else => return error.AssetNotFound,
    };

    for (assets.items) |entry| {
        const object = switch (entry) {
            .object => |map| map,
            else => continue,
        };
        const name = getString(object, "name") orelse continue;
        if (!std.mem.eql(u8, name, asset_name)) continue;

        // A named asset with no download URL is unusable. This is the only shape
        // check that can fail *after* the name matched, so it is an error rather
        // than a `continue`: skipping it would report `AssetNotFound` for an asset
        // that is present, which sends the caller looking for the wrong problem.
        const url = getString(object, "browser_download_url") orelse
            return error.MalformedRelease;
        const size_value = object.get("size") orelse return error.MalformedRelease;
        const size = switch (size_value) {
            .integer => |count| @min(count, std.math.maxInt(usize)),
            else => return error.MalformedRelease,
        };
        if (size < 0) return error.MalformedRelease;

        return .{ .url = url, .size = @intCast(size) };
    }

    return error.AssetNotFound;
}

/// Fetches and parses `owner/repo`'s latest release through the caller's transport.
///
/// The fetch is the caller's and so is the failure: `FetchFailed` collapses every
/// transport error, exactly as `install` does, because the updater's response to all
/// of them is the same - stay on the current version.
///
/// `arena` is both the scratch space for the response body and the owner of the
/// returned strings, so the body is not freed individually - the arena's `deinit`
/// releases it with everything else. That is deliberate: the body and the JSON
/// storage it is parsed into have the same lifetime here.
pub fn fetchLatestRelease(
    arena: std.mem.Allocator,
    fetcher: Fetcher,
    owner: []const u8,
    repo: []const u8,
    asset_name: []const u8,
) ReleaseError!Release {
    assert(owner.len > 0);
    assert(asset_name.len > 0);

    var url_buffer: [max_url_len]u8 = undefined;
    const url = try releaseApiUrl(&url_buffer, owner, repo);

    const body = fetcher.get(arena, url) catch return error.FetchFailed;
    assert(body.len > 0);

    return parseRelease(arena, body, asset_name);
}

/// `true` when every byte of `text` is a hex digit, either case.
fn isHex(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

/// `true` when `candidate` names the same file as `wanted`.
///
/// Local tooling writes `sha256sum` output as the bare filename while release
/// automation frequently writes a path such as `dist/snek.exe`, and both refer to
/// the same asset. The basename is what is compared, and a backslash counts as a
/// separator too - a checksum file produced on Windows says `dist\snek.exe`.
fn namesMatch(candidate: []const u8, wanted: []const u8) bool {
    assert(wanted.len > 0);

    if (std.mem.eql(u8, candidate, wanted)) return true;
    const base = std.mem.lastIndexOfAny(u8, candidate, "/\\") orelse return false;
    return std.mem.eql(u8, candidate[base + 1 ..], wanted);
}

/// Picks the digest for `wanted_name` out of a `sha256sum`-style checksum file.
///
/// The accepted line is `<64 hex><whitespace>[ *]<filename>`, which covers both the
/// text (`  `) and binary (` *`) forms the tool writes. Lines that do not match are
/// skipped rather than rejected, because a real checksum file is a list of every
/// artifact in the release and only one of them is ours; a *file* with no usable
/// line for ours is `MalformedChecksum`, the same error a malformed digest raises,
/// so a caller has one thing to handle.
pub fn parseChecksumFile(body: []const u8, wanted_name: []const u8) Error![]const u8 {
    assert(wanted_name.len > 0);
    assert(body.len > 0);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        // Also strips the `\r` of a CRLF checksum file written on Windows.
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 66) continue;

        const digest = line[0..64];
        if (!isHex(digest)) continue;
        if (!std.ascii.isWhitespace(line[64])) continue;

        // The binary marker is attached to the filename, not separated by space,
        // so it has to be dropped before the name is compared.
        var name = std.mem.trimStart(u8, line[65..], " \t");
        if (name.len > 0 and name[0] == '*') name = std.mem.trimStart(u8, name[1..], " \t");
        if (name.len == 0) continue;
        if (namesMatch(name, wanted_name)) return digest;
    }

    return error.MalformedChecksum;
}

/// Normalizes a detached signature to the 64 raw bytes Ed25519 verifies.
///
/// Two encodings are accepted, and **raw 64 bytes wins**: a slice that is already
/// exactly 64 bytes is taken as the signature itself, so a release that ships the
/// raw form needs no encoding decision from the caller. Anything else is decoded as
/// standard base64 with padding, the form a `.sig` file downloaded as text arrives
/// in, and must decode to exactly 64 bytes - a shorter or longer result is
/// `MalformedSignature`, never a truncated or padded one.
///
/// Surrounding whitespace is trimmed before either check, because the base64 form
/// arrives from a file and files end in newlines.
fn decodeSignature(signature: []const u8) Error![signature_length]u8 {
    assert(signature.len > 0);
    assert(signature.len < 1024);

    const text = std.mem.trim(u8, signature, " \t\r\n");
    // A 64-byte slice is the raw form by construction, so it cannot be at once the
    // right length and empty; the branch below never sees an empty base64 buffer.
    if (text.len == signature_length) return text[0..signature_length].*;
    assert(text.len != signature_length);

    const decoder = std.base64.standard.Decoder;
    // Size first so the decoded length is known to be exactly 64 before any byte
    // is written; a decode into a fixed buffer would only fail after writing.
    const decoded_length = decoder.calcSizeForSlice(text) catch
        return error.MalformedSignature;
    if (decoded_length != signature_length) return error.MalformedSignature;
    assert(decoded_length == signature_length);

    var raw: [signature_length]u8 = undefined;
    decoder.decode(&raw, text) catch return error.MalformedSignature;
    return raw;
}

/// Verifies a detached Ed25519 signature over `message`.
///
/// The public key is a raw 32-byte RFC 8032 encoding. The signature is raw 64 bytes
/// or standard base64 of them; see `decodeSignature` for the exact rule.
///
/// 32 bytes rather than `std.crypto.sign.Ed25519.PublicKey` because that type's field
/// is private, so a caller outside this file could not build one. This is the form a
/// key has in a config file or a constant, and it is the form this module can check
/// the length of.
pub fn verifyEd25519(
    public_key: [public_key_length]u8,
    signature: []const u8,
    message: []const u8,
) Error!void {
    assert(signature.len > 0);
    assert(public_key.len == public_key_length);

    const Ed25519 = std.crypto.sign.Ed25519;
    const key = Ed25519.PublicKey.fromBytes(public_key) catch
        return error.MalformedSignature;
    const raw = try decodeSignature(signature);

    // Cofactored verification, which is the broader-interoperability of the two
    // modes and the one the RFC 8032 vectors pass under. A signature produced by
    // `KeyPair.sign` verifies under both, so the stricter mode buys nothing here
    // beyond rejecting inputs that are already unusable.
    Ed25519.Signature.fromBytes(raw).verify(message, key) catch
        return error.SignatureInvalid;
}

/// Runs the pipeline: check, download, verify, replace.
///
/// Returns `up_to_date` **without fetching** when the running version is not older,
/// so the common case costs nothing and the network is only touched when there is
/// something to do.
///
/// Both checks run before the filesystem is touched, in ascending cost: SHA-256 over
/// the bytes first, then Ed25519 if `public_key` is set. Setting `public_key` makes
/// the signature mandatory, so a caller that configures a key cannot accidentally
/// get checksum-only behaviour by forgetting one field.
pub fn install(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) Error!Outcome {
    assert(request.url.len > 0);
    assert(request.target_path.len > 0);
    // A configured key with no signature, or a signature with no key, is a wiring
    // error: there would be nothing to check against, and silently downgrading to
    // checksum-only is exactly the failure this pairing exists to prevent.
    assert((request.public_key == null) == (request.signature == null));

    if (!request.new_version.isNewerThan(request.current_version)) return .up_to_date;

    const binary = request.fetcher.get(allocator, request.url) catch return error.FetchFailed;
    defer allocator.free(binary);

    // Verification happens before a single byte is written. An updater that wrote
    // first and checked after would have already replaced the executable it is
    // running from.
    const matches = try checksumMatches(request.expected_sha256, binary);
    if (!matches) return error.ChecksumMismatch;

    if (request.signature) |signature| {
        const key = request.public_key orelse return error.MalformedSignature;
        try verifyEd25519(key, signature, binary);
    }

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

/// An arena over the testing allocator.
///
/// The release parsers hand back strings that live in the caller's arena, so a test
/// that asserts on a URL after `parseRelease` returns needs the arena to outlive the
/// call. Backing it with `testing.allocator` keeps leak detection: an arena that is
/// never deinited is reported exactly like a leaked allocation.
fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

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
    /// The length of the last URL requested, so a test can assert that the URL a
    /// builder produced is the one that was fetched.
    last_url_len: usize = 0,

    fn fetch(ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) anyerror![]u8 {
        const self: *StubFetcher = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.last_url_len = url.len;
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

test "the release API URL is built for owner and repo" {
    var buffer: [max_url_len]u8 = undefined;
    try testing.expectEqualStrings(
        "https://api.github.com/repos/93ams/snek/releases/latest",
        try releaseApiUrl(&buffer, "93ams", "snek"),
    );

    // A buffer that cannot hold the result is an error, not a truncation: a
    // truncated URL would be requested and 404, which reads as "no release".
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.ReleaseUrlTooLong, releaseApiUrl(&tiny, "93ams", "snek"));
}

test "the checksum asset name follows the .sha256 convention" {
    var buffer: [max_url_len]u8 = undefined;
    try testing.expectEqualStrings(
        "snek-x86_64-windows.zip.sha256",
        try checksumAssetName(&buffer, "snek-x86_64-windows.zip"),
    );

    var tiny: [4]u8 = undefined;
    try testing.expectError(
        error.ReleaseUrlTooLong,
        checksumAssetName(&tiny, "snek-x86_64-windows.zip"),
    );
}

test "a release body yields its version and the named asset" {
    // The shape of `GET /repos/.../releases/latest`, reduced to the fields this
    // reads. The unrelated fields are there on purpose: the parser must not
    // depend on their presence, order, or type.
    const body =
        \\{
        \\  "url": "https://api.github.com/repos/93ams/snek/releases/1",
        \\  "tag_name": "v2.1.0",
        \\  "draft": false,
        \\  "assets": [
        \\    {
        \\      "name": "snek-linux-x86_64.tar.gz",
        \\      "size": 1048576,
        \\      "browser_download_url": "https://example.invalid/linux"
        \\    },
        \\    {
        \\      "name": "snek-windows-x86_64.zip",
        \\      "size": 2097152,
        \\      "browser_download_url": "https://example.invalid/windows"
        \\    }
        \\  ]
        \\}
    ;

    var arena = testArena();
    defer arena.deinit();

    const release = try parseRelease(arena.allocator(), body, "snek-windows-x86_64.zip");
    // The URL is checked *after* the parse returned, which is the lifetime claim
    // the first version of this function got wrong: it freed the JSON document on
    // the way out and left this slice dangling.
    try testing.expectEqualStrings("https://example.invalid/windows", release.asset.url);
    try testing.expectEqual(@as(usize, 2097152), release.asset.size);
    try testing.expectEqual(@as(u32, 2), release.version.major);
    try testing.expectEqual(@as(u32, 1), release.version.minor);
    try testing.expectEqual(@as(u32, 0), release.version.patch);
    try testing.expectEqualStrings("", release.version.prerelease);

    // The tag is what decides whether this is an update, so it is asserted against
    // a version parsed independently rather than field by field alone.
    try testing.expect(release.version.isNewerThan(try Version.parse("2.0.9")));
    try testing.expect(!release.version.isNewerThan(try Version.parse("2.1.0")));

    var second = testArena();
    defer second.deinit();
    try testing.expectError(
        error.AssetNotFound,
        parseRelease(second.allocator(), body, "snek-macos-arm64.tar.gz"),
    );
}

test "a release with no assets array reports AssetNotFound" {
    const body =
        \\{"tag_name": "v1.0.0", "assets": []}
    ;
    const no_array =
        \\{"tag_name": "v1.0.0"}
    ;

    var arena = testArena();
    defer arena.deinit();

    try testing.expectError(
        error.AssetNotFound,
        parseRelease(arena.allocator(), body, "snek.zip"),
    );
    try testing.expectError(
        error.AssetNotFound,
        parseRelease(arena.allocator(), no_array, "snek.zip"),
    );
}

test "a release tagged with something that is not a version is rejected" {
    // GitHub will serve this happily, and a checker that defaulted to 0.0.0 here
    // would decide every such release is newer than what is running.
    const body =
        \\{"tag_name": "nightly", "assets": [
        \\  {"name": "snek.zip", "size": 1, "browser_download_url": "https://x.invalid/a"}
        \\]}
    ;
    // And a release with no tag at all is a malformed body, not a crash.
    const no_tag =
        \\{"assets": []}
    ;

    var arena = testArena();
    defer arena.deinit();

    try testing.expectError(
        error.MalformedVersion,
        parseRelease(arena.allocator(), body, "snek.zip"),
    );
    try testing.expectError(
        error.MalformedRelease,
        parseRelease(arena.allocator(), no_tag, "snek.zip"),
    );
}

test "a malformed release body is reported rather than panicking" {
    const cases = [_][]const u8{
        "not json at all",
        "{",
        "[]",
        "\"a string\"",
        "null",
        "{]",
        // The named asset is present but has no download URL, which is the one
        // failure that happens after the name matched.
        \\{"tag_name": "v1.0.0", "assets": [{"name": "snek.zip", "size": 1}]}
        ,
        // The size is not a number.
        \\{"tag_name": "v1.0.0", "assets": [
        \\  {"name": "snek.zip", "browser_download_url": "https://x.invalid/a"}
        \\]}
        ,
        // The tag is not a string. GitHub would not do this; a compromised mirror
        // or a truncated response might, and it must not be a panic.
        \\{"tag_name": 7, "assets": []}
        ,
    };

    var arena = testArena();
    defer arena.deinit();

    for (cases) |body| {
        try testing.expectError(
            error.MalformedRelease,
            parseRelease(arena.allocator(), body, "snek.zip"),
        );
    }

    // A negative size is a lie about the payload, not a payload of zero bytes.
    const negative =
        \\{"tag_name": "v1.0.0", "assets": [
        \\  {"name": "snek.zip", "size": -1, "browser_download_url": "https://x.invalid/a"}
        \\]}
    ;
    try testing.expectError(
        error.MalformedRelease,
        parseRelease(arena.allocator(), negative, "snek.zip"),
    );
}

test "the latest release is fetched from the API URL, not from a caller-supplied one" {
    const body =
        \\{"tag_name": "v3.0.0", "assets": [
        \\  {"name": "snek.zip", "size": 12,
        \\   "browser_download_url": "https://example.invalid/v3.zip"}
        \\]}
    ;
    var stub = StubFetcher{ .payload = body };

    var arena = testArena();
    defer arena.deinit();

    const release = try fetchLatestRelease(
        arena.allocator(),
        stub.interface(),
        "93ams",
        "snek",
        "snek.zip",
    );
    try testing.expectEqual(@as(u32, 3), release.version.major);
    try testing.expectEqualStrings("https://example.invalid/v3.zip", release.asset.url);
    // The fetch went through the caller's transport exactly once, and the URL it
    // was handed is the derived one.
    try testing.expectEqual(@as(usize, 1), stub.calls);
    try testing.expectEqual(
        "https://api.github.com/repos/93ams/snek/releases/latest".len,
        stub.last_url_len,
    );

    // A transport failure is the caller's to see, not to have converted into
    // "there is no new release".
    var failing = StubFetcher{ .payload = body, .fail = true };
    try testing.expectError(
        error.FetchFailed,
        fetchLatestRelease(
            arena.allocator(),
            failing.interface(),
            "93ams",
            "snek",
            "snek.zip",
        ),
    );
}

/// A valid lowercase-hex SHA-256 digest, for tests that need "some digest".
///
/// One constant rather than a literal per case: a 64-character literal repeated
/// through a test file forces either a line over the 100-column budget or a wrapped
/// string, and it makes the tests that flip a nibble harder to read.
const test_digest = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

test "a checksum line is found for the wanted file and not for another" {
    const body =
        \\d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2  other.zip
        \\a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00  snek.zip
        \\00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *snek.zip
        \\
    ;

    // Two lines name the file: the plain text form and the star-marked binary
    // form. The first match wins, and it is the text one.
    const found = try parseChecksumFile(body, "snek.zip");
    try testing.expectEqualStrings(
        "a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00",
        found,
    );

    try testing.expectError(error.MalformedChecksum, parseChecksumFile(body, "absent.zip"));
}

test "the binary marker, CRLF endings and path prefixes are tolerated" {
    var line_buffer: [160]u8 = undefined;

    // The star form on its own, with a CRLF ending.
    const binary = try std.fmt.bufPrint(&line_buffer, "{s} *snek.exe\r\n", .{test_digest});
    try testing.expectEqualStrings(test_digest, try parseChecksumFile(binary, "snek.exe"));

    // The same file named with a directory: `sha256sum dist/*` writes the path.
    const prefixed = try std.fmt.bufPrint(&line_buffer, "{s}  dist/snek.exe\n", .{test_digest});
    try testing.expectEqualStrings(test_digest, try parseChecksumFile(prefixed, "snek.exe"));

    // And a Windows-style separator, for a checksum file produced on Windows.
    const backslashed = try std.fmt.bufPrint(
        &line_buffer,
        "{s}  dist\\snek.exe\n",
        .{test_digest},
    );
    try testing.expectEqualStrings(test_digest, try parseChecksumFile(backslashed, "snek.exe"));

    // A newline after the digest but no filename names nothing.
    const no_name = try std.fmt.bufPrint(&line_buffer, "{s}  \n", .{test_digest});
    try testing.expectError(error.MalformedChecksum, parseChecksumFile(no_name, "snek.exe"));
}

test "a checksum file with no usable line is malformed" {
    var line_buffer: [160]u8 = undefined;
    var body_buffer: [320]u8 = undefined;

    // A digest with no filename separator, and a line whose digest is only 60
    // characters followed by a complete line for a different file: the wanted name
    // appears nowhere usable, so the file is malformed rather than a mismatch.
    const no_separator = try std.fmt.bufPrint(&line_buffer, "{s}", .{test_digest});
    const truncated_then_other = try std.fmt.bufPrint(
        &body_buffer,
        "{s}\n{s}  other.zip\n",
        .{ test_digest[0..60], test_digest },
    );

    const cases = [_][]const u8{
        "\n\n\n",
        // The wrong digest length.
        "abc123  snek.zip",
        // Right length, but not hex.
        "zz112233445566778899aabbccddeeff00112233445566778899aabbccddeeff  snek.zip",
        no_separator,
        truncated_then_other,
    };

    for (cases) |body| {
        try testing.expectError(error.MalformedChecksum, parseChecksumFile(body, "snek.zip"));
    }
}

/// A deterministic Ed25519 key pair plus one signature over `signed_message`.
///
/// Deterministic on purpose: a test that generated a fresh key each run would prove
/// only that the library round-trips with itself, and it could not carry a base64
/// fixture. The constants below are the output of the pairing for `seed`, which the
/// first test in this group re-derives rather than trusting.
const TestKey = struct {
    const seed = [_]u8{0x42} ** 32;
    const signed_message = "the payload that was signed";
    /// The signature over `signed_message`, base64, as a `.sig` file downloaded
    /// from a release would hold it.
    const base64_signature =
        "AouVrl31Oalf3gUePmnUyoI2T7mEi4Nu2Fi2T775zshEGQfvIiFFzaNIl/3FRBKEnw4mydTp" ++
        "GDyLhaFD+8wiAA==";

    fn pair() std.crypto.sign.Ed25519.KeyPair {
        return std.crypto.sign.Ed25519.KeyPair
            .generateDeterministic(seed) catch @panic("the fixed seed is not a valid key");
    }

    fn signature() std.crypto.sign.Ed25519.Signature {
        return pair().sign(signed_message, null) catch @panic("the fixed key pair cannot sign");
    }

    fn publicKey() [public_key_length]u8 {
        return pair().public_key.toBytes();
    }

    fn rawSignature() [signature_length]u8 {
        return signature().toBytes();
    }
};

test "the test signature is the one the fixtures describe" {
    // This is a guard on the fixture itself: if the standard library's
    // deterministic key derivation ever changes, the base64 fixture below stops
    // describing this key and the failure would otherwise look like a bug in
    // `verifyEd25519`.
    const signature = TestKey.signature();
    try signature.verify(TestKey.signed_message, TestKey.pair().public_key);

    var encoded_buffer: [std.base64.standard.Encoder.calcSize(signature_length)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, &TestKey.rawSignature());
    try testing.expectEqualStrings(TestKey.base64_signature, encoded);
}

test "a detached signature over the payload verifies, and one over other bytes does not" {
    const key = TestKey.publicKey();
    const raw = TestKey.rawSignature();

    // Raw 64 bytes, and the same signature as base64 text. Both must verify: the
    // encoding is a transport detail, the signature is the same 64 bytes.
    try verifyEd25519(key, &raw, TestKey.signed_message);
    try verifyEd25519(key, TestKey.base64_signature, TestKey.signed_message);
    // Surrounding whitespace is part of how the base64 form arrives from a file.
    const padded = "\n  " ++ TestKey.base64_signature ++ "\r\n";
    try verifyEd25519(key, padded, TestKey.signed_message);

    // A different message under a valid signature is the attack this exists to
    // stop, and it must not be confused with the payload.
    try testing.expectError(
        error.SignatureInvalid,
        verifyEd25519(key, &raw, "the payload that was signeD"),
    );

    // A different key over the same message is a valid signature by someone else.
    const other_key = (std.crypto.sign.Ed25519.KeyPair
        .generateDeterministic([_]u8{0x43} ** 32) catch
        @panic("the fixed seed is not a valid key"))
        .public_key.toBytes();
    try testing.expectError(
        error.SignatureInvalid,
        verifyEd25519(other_key, &raw, TestKey.signed_message),
    );
}

test "a malformed key or signature is its own error, not a failed verification" {
    const key = TestKey.publicKey();

    // Well-formed base64 that decodes to the wrong number of bytes: too short to be
    // a signature. A decode that would have to pad or truncate is refused rather
    // than quietly accepted.
    try testing.expectError(
        error.MalformedSignature,
        verifyEd25519(key, "AAAA", TestKey.signed_message),
    );

    const cases = [_][]const u8{
        // Not base64 at all, and base64 containing a character outside the
        // alphabet. Both are under 64 bytes, so neither is read as raw.
        "this is not a signature",
        "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
        // 87 base64 characters: a length that is exactly representable, decoding to
        // 65 bytes. Too long is as malformed as too short.
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ++
            "AAAAAAAAAAAAAAAAAAAAAAA=",
    };
    for (cases) |signature| {
        try testing.expectError(
            error.MalformedSignature,
            verifyEd25519(key, signature, TestKey.signed_message),
        );
    }

    // A 64-byte slice is raw by definition, even when it is text that happens to be
    // 64 bytes long: it is a well-formed encoding of *some* signature, so it fails
    // verification rather than being called malformed.
    try testing.expectError(
        error.SignatureInvalid,
        verifyEd25519(key, "x" ** signature_length, TestKey.signed_message),
    );

    // A public key that is not a canonical curve point is a malformed key, not a
    // mismatch: there is no key to have matched.
    try testing.expectError(
        error.MalformedSignature,
        verifyEd25519([_]u8{0xff} ** public_key_length, &TestKey.rawSignature(), "message"),
    );
}

test "install verifies the signature before anything is written" {
    const io = testing.io;
    const path = ".zig-cache/update-signature-test.bin";
    const payload = "the signed binary";

    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, ".zig-cache") catch {};
    {
        const file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, "ORIGINAL", 0);
    }
    defer dir.deleteFile(io, path) catch {};
    defer dir.deleteFile(io, ".zig-cache/update-signature-test.bin.old") catch {};

    // A signature over different bytes, with a checksum that *does* match: the
    // signature is the only thing standing between this payload and the disk, so
    // it must be checked and must fail.
    const pair = TestKey.pair();
    const signature = try pair.sign("a different payload", null);
    const raw = signature.toBytes();

    const digest = try sha256Hex(testing.allocator, payload);
    defer testing.allocator.free(digest);

    var stub = StubFetcher{ .payload = payload };
    try testing.expectError(error.SignatureInvalid, install(testing.allocator, io, .{
        .current_version = try Version.parse("1.0.0"),
        .new_version = try Version.parse("2.0.0"),
        .url = "https://example.invalid/v2",
        .expected_sha256 = digest,
        .signature = &raw,
        .public_key = pair.public_key.toBytes(),
        .target_path = path,
        .fetcher = stub.interface(),
    }));

    const after = try dir.readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("ORIGINAL", after);

    // A bad checksum still wins the race, because it is checked first. The
    // signature here is valid, so only the digest can be the reason for refusal.
    const good_signature = try pair.sign(payload, null);
    const good_raw = good_signature.toBytes();
    try testing.expectError(error.ChecksumMismatch, install(testing.allocator, io, .{
        .current_version = try Version.parse("1.0.0"),
        .new_version = try Version.parse("2.0.0"),
        .url = "https://example.invalid/v2",
        .expected_sha256 = "0" ** 64,
        .signature = &good_raw,
        .public_key = pair.public_key.toBytes(),
        .target_path = path,
        .fetcher = stub.interface(),
    }));

    // And with both correct, the update lands.
    const outcome = try install(testing.allocator, io, .{
        .current_version = try Version.parse("1.0.0"),
        .new_version = try Version.parse("2.0.0"),
        .url = "https://example.invalid/v2",
        .expected_sha256 = digest,
        .signature = &good_raw,
        .public_key = pair.public_key.toBytes(),
        .target_path = path,
        .fetcher = stub.interface(),
    });
    try testing.expectEqual(Outcome.installed, outcome);

    const installed = try dir.readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings(payload, installed);
}

test "the pieces compose into the flow a caller runs" {
    // The registration order a real updater would use: parse the release, name the
    // checksum asset, fetch that file, pick our line out of it, then hand the
    // request to `install`. Each piece is tested alone above; this is the seam
    // between them - the checksum asset name, the asset URL, and the digest all
    // have to agree with the release body for the update to land.
    const io = testing.io;
    const path = ".zig-cache/update-pipeline-test.bin";
    const payload = "the composed binary";

    const release_body =
        \\{"tag_name": "v4.2.0", "assets": [
        \\  {"name": "snek-linux-x86_64.tar.gz", "size": 111,
        \\   "browser_download_url": "https://example.invalid/linux"},
        \\  {"name": "snek-windows-x86_64.zip", "size": 222,
        \\   "browser_download_url": "https://example.invalid/windows"}
        \\]}
    ;

    // The fetcher serves whichever body the caller asks for, which is what lets one
    // stub stand in for two different URLs - the release API and the asset.
    const ServingStub = struct {
        release_body: []const u8,
        asset_body: []const u8,
        asset_url: []const u8,
        calls: usize = 0,

        fn fetch(ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (std.mem.eql(u8, url, self.asset_url)) return allocator.dupe(u8, self.asset_body);
            return allocator.dupe(u8, self.release_body);
        }

        fn interface(self: *@This()) Fetcher {
            return .{ .ctx = self, .fetch = fetch };
        }
    };

    var arena = testArena();
    defer arena.deinit();

    const digest = try sha256Hex(arena.allocator(), payload);

    var asset_stub = ServingStub{
        .release_body = release_body,
        .asset_body = payload,
        .asset_url = "https://example.invalid/windows",
    };

    // 1. The release, including which URL the asset lives at.
    const release = try fetchLatestRelease(
        arena.allocator(),
        asset_stub.interface(),
        "93ams",
        "snek",
        "snek-windows-x86_64.zip",
    );
    try testing.expectEqual(@as(u32, 4), release.version.major);

    // 2. The checksum file's *name* for publishing, from the same asset name.
    var checksum_buffer: [max_url_len]u8 = undefined;
    const checksum_asset = try checksumAssetName(&checksum_buffer, "snek-windows-x86_64.zip");
    try testing.expectEqualStrings("snek-windows-x86_64.zip.sha256", checksum_asset);

    // 3. The checksum file's contents, as a release would publish them next to the
    //    asset, and the digest picked out of it for our file.
    var checksum_body: [160]u8 = undefined;
    const checksum_file = try std.fmt.bufPrint(
        &checksum_body,
        "{s}  {s}\n",
        .{ digest, "snek-windows-x86_64.zip" },
    );
    const expected = try parseChecksumFile(checksum_file, "snek-windows-x86_64.zip");
    try testing.expectEqualStrings(digest, expected);

    // 4. Nothing is on disk yet.
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, ".zig-cache") catch {};
    defer dir.deleteFile(io, path) catch {};
    defer dir.deleteFile(io, ".zig-cache/update-pipeline-test.bin.old") catch {};
    {
        const file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, "ORIGINAL", 0);
    }

    const outcome = try install(arena.allocator(), io, .{
        .current_version = try Version.parse("4.1.0"),
        .new_version = release.version,
        .url = release.asset.url,
        .expected_sha256 = expected,
        .target_path = path,
        .fetcher = asset_stub.interface(),
    });
    try testing.expectEqual(Outcome.installed, outcome);

    const installed = try dir.readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings(payload, installed);

    // One fetch for the release and one for the asset: the checksum came out of a
    // body the caller already had, so it cost no request of its own.
    try testing.expectEqual(@as(usize, 2), asset_stub.calls);
}
