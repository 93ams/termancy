//! Self-update from GitHub releases, in five pieces that each work without a network:
//!
//! 1. **Lookup**: `parseRelease` reads the JSON of `/repos/{owner}/{repo}/releases/latest`;
//!    `selectAsset` picks the asset for a `Target` by configurable OS and CPU names.
//! 2. **Decide**: `decide` compares the release's version with the running one.
//! 3. **Verify**: `findChecksum` + `verifyChecksum` check SHA-256 against `<asset>.sha256`
//!    or a `SHA256SUMS`-style file; `verifySignature` checks a detached Ed25519 signature
//!    (`<asset>.sig`). With a public key configured, a release without a valid signature is
//!    rejected, never installed on its checksum alone.
//! 4. **Install**: `install` replaces an executable atomically and keeps a rollback copy
//!    (`<exe>.old`) until the new one is in place and accepted.
//! 5. **Fetch**: `HttpTransport` over `std.http.Client`: https only (redirects too), with a
//!    size limit and an optional timeout.
//!
//! `check` and `apply` run the whole flow through a `Transport`, so tests drive it with an
//! in-memory fake. Nothing here reads the executable's path, the clock, or the network on
//! its own: the caller passes the path, the `Io`, and the transport.
//!
//! An asset may be a bare executable, a `.tar.gz` (or `.tgz`), or a `.zip`: from an
//! archive, the file named like the executable is installed (`extractExecutable`). The
//! checksum and signature are of the asset as published. With `allow_prerelease`, `check`
//! reads the list of releases (`/releases`), since `/releases/latest` never returns a
//! pre-release.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
const Version = @import("version.zig");

// 1. Lookup.

/// One downloadable file of a release.
pub const Asset = struct {
    name: []const u8,
    /// `browser_download_url`: a direct link (GitHub answers it with a redirect).
    url: []const u8,
    /// Bytes, as GitHub reports it; 0 when unknown.
    size: u64 = 0,
};

/// The parts of a GitHub release an update needs.
pub const Release = struct {
    tag: []const u8,
    version: Version,
    draft: bool = false,
    prerelease: bool = false,
    assets: []const Asset,

    /// The asset named exactly `name`.
    pub fn find(release: Release, name: []const u8) ?Asset {
        for (release.assets) |asset| {
            if (std.mem.eql(u8, asset.name, name)) return asset;
        }
        return null;
    }
};

/// Where releases are published.
pub const Source = struct {
    owner: []const u8,
    repo: []const u8,
    api_base: []const u8 = "https://api.github.com",
};

/// Why a release object could not be read.
pub const ParseError = error{
    /// Not JSON, or no `tag_name`, or an asset without `name`/`browser_download_url`.
    InvalidRelease,
    /// The tag is not a semantic version.
    InvalidVersion,
} || Allocator.Error;

/// Parses a GitHub release object. Strings are copied into `arena`.
pub fn parseRelease(arena: Allocator, json: []const u8) ParseError!Release {
    return fromRaw(arena, try parseRaw(RawRelease, arena, json));
}

const RawRelease = struct {
    tag_name: []const u8,
    draft: bool = false,
    prerelease: bool = false,
    assets: []const RawAsset = &.{},

    const RawAsset = struct { name: []const u8, browser_download_url: []const u8, size: u64 = 0 };
};

fn parseRaw(comptime T: type, arena: Allocator, json: []const u8) ParseError!T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRelease,
    };
}

fn fromRaw(arena: Allocator, raw: RawRelease) ParseError!Release {
    const assets = try arena.alloc(Asset, raw.assets.len);
    for (raw.assets, assets) |from, *to| {
        to.* = .{ .name = from.name, .url = from.browser_download_url, .size = from.size };
    }
    return .{
        .tag = raw.tag_name,
        .version = try Version.parse(raw.tag_name),
        .draft = raw.draft,
        .prerelease = raw.prerelease,
        .assets = assets,
    };
}

/// `{api_base}/repos/{owner}/{repo}/releases`, the most recent first, allocated in `arena`.
pub fn releasesUrl(
    arena: Allocator,
    source: Source,
) (Allocator.Error || error{InvalidSource})![]const u8 {
    if (!isRepoName(source.owner) or !isRepoName(source.repo)) return error.InvalidSource;
    const base = std.mem.trimEnd(u8, source.api_base, "/");
    return std.fmt.allocPrint(arena, "{s}/repos/{s}/{s}/releases?per_page=30", .{
        base, source.owner, source.repo,
    });
}

/// Parses a JSON array of GitHub release objects, skipping releases whose tag is not a
/// semantic version.
pub fn parseReleases(arena: Allocator, json: []const u8) ParseError![]const Release {
    const raw = try parseRaw([]const RawRelease, arena, json);
    var releases: std.ArrayList(Release) = .empty;
    for (raw) |item| {
        const release = fromRaw(arena, item) catch |err| switch (err) {
            error.InvalidVersion => continue,
            else => |e| return e,
        };
        try releases.append(arena, release);
    }
    return releases.items;
}

/// The release with the highest version, leaving out drafts, and pre-releases unless
/// `allow_prerelease`; null when none is left.
pub fn newest(releases: []const Release, allow_prerelease: bool) ?Release {
    var best: ?Release = null;
    for (releases) |release| {
        if (release.draft) continue;
        const prerelease = release.prerelease or release.version.isPrerelease();
        if (prerelease and !allow_prerelease) continue;
        if (best == null or best.?.version.order(release.version) == .lt) best = release;
    }
    return best;
}

/// `{api_base}/repos/{owner}/{repo}/releases/latest`, allocated in `arena`.
pub fn latestReleaseUrl(
    arena: Allocator,
    source: Source,
) (Allocator.Error || error{InvalidSource})![]const u8 {
    if (!isRepoName(source.owner) or !isRepoName(source.repo)) return error.InvalidSource;
    const base = std.mem.trimEnd(u8, source.api_base, "/");
    return std.fmt.allocPrint(arena, "{s}/repos/{s}/{s}/releases/latest", .{
        base, source.owner, source.repo,
    });
}

fn isRepoName(text: []const u8) bool {
    if (text.len == 0 or std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return false;
    for (text) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!ok) return false;
    }
    return true;
}

/// The platform an asset must be built for.
pub const Target = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,

    /// The platform this program was compiled for.
    pub const native: Target = .{ .os = builtin.os.tag, .arch = builtin.cpu.arch };
};

/// The spellings of one OS in asset names.
pub const OsNames = struct { os: std.Target.Os.Tag, names: []const []const u8 };
/// The spellings of one CPU architecture in asset names.
pub const ArchNames = struct { arch: std.Target.Cpu.Arch, names: []const []const u8 };

/// How asset names spell targets. A name matches when it contains one spelling of the
/// target's OS and one of its architecture, each as a whole word (bounded by the ends of
/// the name or by a byte that is not a letter or digit), ignoring case.
pub const Naming = struct {
    os: []const OsNames = &default_os_names,
    arch: []const ArchNames = &default_arch_names,
    /// When set, the asset name must also end with this (case-insensitive): `".exe"`.
    suffix: ?[]const u8 = null,

    /// The OS spellings release tooling commonly uses.
    pub const default_os_names = [_]OsNames{
        .{ .os = .linux, .names = &.{"linux"} },
        .{ .os = .macos, .names = &.{ "macos", "darwin", "apple", "osx" } },
        .{ .os = .windows, .names = &.{ "windows", "win64", "win32", "win" } },
        .{ .os = .freebsd, .names = &.{"freebsd"} },
    };
    /// The CPU spellings release tooling commonly uses.
    pub const default_arch_names = [_]ArchNames{
        .{ .arch = .x86_64, .names = &.{ "x86_64", "amd64", "x64" } },
        .{ .arch = .aarch64, .names = &.{ "aarch64", "arm64" } },
        .{ .arch = .x86, .names = &.{ "i386", "i686", "x86" } },
        .{ .arch = .arm, .names = &.{ "armv7", "armhf", "arm" } },
        .{ .arch = .riscv64, .names = &.{"riscv64"} },
    };
};

/// Why no single asset fits the target.
pub const SelectError = error{
    /// No asset matches the target.
    NoMatchingAsset,
    /// More than one asset matches; tighten `Naming` (for example with `suffix`).
    AmbiguousAsset,
};

/// The release asset built for `target`. Checksum and signature files never match.
pub fn selectAsset(release: Release, target: Target, naming: Naming) SelectError!Asset {
    const os_names = namesFor(OsNames, naming.os, target.os) orelse return error.NoMatchingAsset;
    const arch_names = namesFor(ArchNames, naming.arch, target.arch) orelse
        return error.NoMatchingAsset;
    var found: ?Asset = null;
    for (release.assets) |asset| {
        if (isSidecar(asset.name)) continue;
        if (naming.suffix) |suffix| if (!endsWithIgnoreCase(asset.name, suffix)) continue;
        if (!containsAnyWord(asset.name, os_names)) continue;
        if (!containsAnyWord(asset.name, arch_names)) continue;
        if (found != null) return error.AmbiguousAsset;
        found = asset;
    }
    return found orelse error.NoMatchingAsset;
}

fn namesFor(comptime Entry: type, entries: []const Entry, tag: anytype) ?[]const []const u8 {
    for (entries) |entry| {
        const entry_tag = if (Entry == OsNames) entry.os else entry.arch;
        if (entry_tag == tag) return entry.names;
    }
    return null;
}

/// Checksums, signatures, and the like, which ride along with the binaries.
fn isSidecar(name: []const u8) bool {
    const suffixes = [_][]const u8{ ".sha256", ".sha256sum", ".sig", ".minisig", ".asc", ".pem" };
    for (suffixes) |suffix| {
        if (endsWithIgnoreCase(name, suffix)) return true;
    }
    for (default_checksum_files) |file| {
        if (std.ascii.eqlIgnoreCase(name, file)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and
        std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn containsAnyWord(text: []const u8, words: []const []const u8) bool {
    for (words) |word| {
        if (containsWord(text, word)) return true;
    }
    return false;
}

fn containsWord(text: []const u8, word: []const u8) bool {
    assert(word.len > 0);
    var start: usize = 0;
    while (start + word.len <= text.len) : (start += 1) {
        if (!std.ascii.eqlIgnoreCase(text[start..][0..word.len], word)) continue;
        const end = start + word.len;
        const open = start == 0 or !std.ascii.isAlphanumeric(text[start - 1]);
        const close = end == text.len or !std.ascii.isAlphanumeric(text[end]);
        if (open and close) return true;
    }
    return false;
}

// 2. Decide.

/// What the update needs to download, once a newer release has been found.
pub const Plan = struct {
    current: Version,
    latest: Version,
    tag: []const u8,
    binary: Asset,
    /// `<binary>.sha256`, or the first of `Options.checksum_files` the release has.
    checksum: Asset,
    /// `<binary>.sig`, when the release has one.
    signature: ?Asset,
};

/// The result of `check`.
pub const Check = union(enum) {
    /// Nothing newer: the running version is the latest acceptable one (or newer).
    up_to_date: Version,
    available: Plan,
};

/// Checksum-list file names looked for when an asset has no `<asset>.sha256`.
pub const default_checksum_files = [_][]const u8{
    "SHA256SUMS", "sha256sums.txt", "checksums.txt",
};

/// Size limits for downloads, in bytes.
pub const Limits = struct {
    /// The release JSON.
    metadata: usize = 1 << 20,
    /// The executable.
    binary: usize = 256 << 20,
    /// Checksum and signature files.
    sidecar: usize = 64 << 10,
};

/// How `check` and `apply` find, verify, and install an update.
pub const Options = struct {
    source: Source,
    /// The running program's version.
    current: Version,
    target: Target = .native,
    naming: Naming = .{},
    /// Whether a release marked as a pre-release, or tagged with one, may be installed.
    allow_prerelease: bool = false,
    /// A raw Ed25519 public key. When set, every update must carry a valid
    /// `<binary>.sig` over the downloaded bytes, or it is rejected.
    public_key: ?[Ed25519.PublicKey.encoded_length]u8 = null,
    checksum_files: []const []const u8 = &default_checksum_files,
    limits: Limits = .{},
    install: InstallOptions = .{},
    /// The executable's name inside an archive asset; by default, the base name of the
    /// path being replaced.
    executable_name: ?[]const u8 = null,
};

/// Why a newer release cannot be planned.
pub const DecideError = SelectError || error{
    /// The release has neither `<binary>.sha256` nor a checksum-list file.
    ChecksumMissing,
};

/// Whether `release` is an update for `options.current`, and if so what to download.
pub fn decide(
    arena: Allocator,
    release: Release,
    options: Options,
) (DecideError || Allocator.Error)!Check {
    const prerelease = release.prerelease or release.version.isPrerelease();
    if (release.draft or (prerelease and !options.allow_prerelease)) {
        return .{ .up_to_date = options.current };
    }
    if (!release.version.newerThan(options.current)) return .{ .up_to_date = options.current };
    const binary = try selectAsset(release, options.target, options.naming);
    const checksum_name = try std.fmt.allocPrint(arena, "{s}.sha256", .{binary.name});
    const signature_name = try std.fmt.allocPrint(arena, "{s}.sig", .{binary.name});
    return .{ .available = .{
        .current = options.current,
        .latest = release.version,
        .tag = release.tag,
        .binary = binary,
        .checksum = release.find(checksum_name) orelse
            findChecksumList(release, options.checksum_files) orelse
            return error.ChecksumMissing,
        .signature = release.find(signature_name),
    } };
}

fn findChecksumList(release: Release, names: []const []const u8) ?Asset {
    for (names) |name| {
        if (release.find(name)) |asset| return asset;
    }
    return null;
}

// 3. Verify.

/// A raw SHA-256 digest.
pub const Digest = [Sha256.digest_length]u8;

/// Why a download failed its checksum.
pub const ChecksumError = error{
    /// The checksum file has no usable line for the asset.
    ChecksumMissing,
    /// The bytes do not hash to the published digest.
    ChecksumMismatch,
};

/// The digest for `asset_name` in a checksum file. Accepted lines: `sha256sum` output
/// (`<hex>  name`, `<hex> *name`, names compared by base name), BSD `SHA256 (name) = <hex>`,
/// and a bare `<hex>` (the whole content of a per-asset `.sha256` file). Other lines are
/// skipped, since a list covers every asset of the release.
pub fn findChecksum(body: []const u8, asset_name: []const u8) error{ChecksumMissing}!Digest {
    assert(asset_name.len > 0);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const hex, const name = splitChecksumLine(line) orelse continue;
        if (name) |n| if (!sameFile(n, asset_name)) continue;
        var digest: Digest = undefined;
        // `splitChecksumLine` returns exactly 64 hex digits, which always decode.
        _ = std.fmt.hexToBytes(&digest, hex) catch unreachable;
        return digest;
    }
    return error.ChecksumMissing;
}

/// `{ hex, name }` from one line, `name` null for a bare digest.
fn splitChecksumLine(line: []const u8) ?struct { []const u8, ?[]const u8 } {
    const hex_len = Sha256.digest_length * 2;
    if (std.mem.startsWith(u8, line, "SHA256 (")) {
        const close = std.mem.lastIndexOf(u8, line, ") = ") orelse return null;
        const hex = line[close + 4 ..];
        if (!isHexDigest(hex)) return null;
        return .{ hex, line["SHA256 (".len..close] };
    }
    if (line.len < hex_len or !isHexDigest(line[0..hex_len])) return null;
    if (line.len == hex_len) return .{ line, null };
    if (line[hex_len] != ' ' and line[hex_len] != '\t') return null;
    var name = std.mem.trimStart(u8, line[hex_len..], " \t");
    if (name.len > 0 and name[0] == '*') name = name[1..];
    if (name.len == 0) return null;
    return .{ line[0..hex_len], name };
}

fn isHexDigest(text: []const u8) bool {
    if (text.len != Sha256.digest_length * 2) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

/// Whether `listed` (possibly `dist/name` or `dist\name`) names `wanted`.
fn sameFile(listed: []const u8, wanted: []const u8) bool {
    const slash = std.mem.lastIndexOfAny(u8, listed, "/\\");
    const base = if (slash) |i| listed[i + 1 ..] else listed;
    return std.mem.eql(u8, base, wanted);
}

/// Whether `bytes` hash to `expected`.
pub fn verifyChecksum(bytes: []const u8, expected: Digest) error{ChecksumMismatch}!void {
    var actual: Digest = undefined;
    Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &actual, &expected)) return error.ChecksumMismatch;
}

/// Why a download failed its signature check.
pub const SignatureError = error{
    /// A public key is configured but the release has no signature.
    SignatureMissing,
    /// The signature is malformed or does not verify.
    SignatureInvalid,
    /// The configured public key is not a valid Ed25519 point encoding.
    InvalidPublicKey,
};

/// Checks a detached Ed25519 signature over `message`. `signature` is the content of the
/// `.sig` file: 64 raw bytes, or their standard base64 (surrounding whitespace ignored).
/// A null `signature` is `SignatureMissing`: when a key is configured, one is required.
pub fn verifySignature(
    public_key: [Ed25519.PublicKey.encoded_length]u8,
    signature: ?[]const u8,
    message: []const u8,
) SignatureError!void {
    const key = Ed25519.PublicKey.fromBytes(public_key) catch return error.InvalidPublicKey;
    const raw = try decodeSignature(signature orelse return error.SignatureMissing);
    Ed25519.Signature.fromBytes(raw).verify(message, key) catch return error.SignatureInvalid;
}

fn decodeSignature(text: []const u8) error{SignatureInvalid}![Ed25519.Signature.encoded_length]u8 {
    const length = Ed25519.Signature.encoded_length;
    if (text.len == length) return text[0..length].*;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(trimmed) catch return error.SignatureInvalid;
    if (size != length) return error.SignatureInvalid;
    var raw: [length]u8 = undefined;
    decoder.decode(&raw, trimmed) catch return error.SignatureInvalid;
    return raw;
}

// 4. Install.

/// How the executable is replaced.
pub const Strategy = enum {
    /// Copy the current file to `<exe>.old`, then rename the new one over it. The path
    /// always names a complete executable; a running process keeps its old image (POSIX).
    rename_over,
    /// Rename the current file to `<exe>.old`, then move the new one in. Windows cannot
    /// replace or delete a running image but can rename it, so `<exe>.old` stays behind
    /// until `removeLeftovers` runs on the next start.
    move_aside,

    /// `move_aside` on Windows, `rename_over` elsewhere.
    pub const native: Strategy = if (builtin.os.tag == .windows) .move_aside else .rename_over;
};

/// A step run after the new executable is in place and before the rollback copy is
/// removed; failing it restores the old executable. For example: run `<exe> --version`.
pub const Hook = struct {
    context: ?*anyopaque = null,
    run: *const fn (
        context: ?*anyopaque,
        io: Io,
        dir: Io.Dir,
        exe_path: []const u8,
    ) error{Rejected}!void,
};

/// How `install` replaces the executable.
pub const InstallOptions = struct {
    strategy: Strategy = .native,
    /// Run once the new file is in place; its failure rolls the swap back.
    accept: ?Hook = null,
};

/// Why `install` failed; every case but `RollbackFailed` leaves the old executable.
pub const InstallError = error{
    /// `<exe>.old` or `<exe>.new` would not fit in a path buffer.
    NameTooLong,
    /// The new executable could not be written next to the old one.
    StageFailed,
    /// The rollback copy could not be made; nothing was changed.
    BackupFailed,
    /// The new executable could not be moved into place; the old one was restored.
    SwapFailed,
    /// The `accept` hook failed; the old executable was restored.
    Rejected,
    /// A step failed and so did restoring the old executable, which is left at `<exe>.old`.
    RollbackFailed,
};

const max_path = Io.Dir.max_path_bytes;

/// Writes `bytes` as the executable at `exe_path` (relative to `dir`), keeping a rollback
/// copy at `<exe>.old` until the new file is in place and accepted. When `exe_path` does
/// not exist yet, the file is simply created.
pub fn install(
    io: Io,
    dir: Io.Dir,
    exe_path: []const u8,
    bytes: []const u8,
    options: InstallOptions,
) InstallError!void {
    assert(exe_path.len > 0);
    var new_buffer: [max_path]u8 = undefined;
    var old_buffer: [max_path]u8 = undefined;
    const new_path = try sibling(&new_buffer, exe_path, ".new");
    const old_path = try sibling(&old_buffer, exe_path, ".old");

    try stage(io, dir, new_path, bytes);
    const backed_up = backUp(io, dir, exe_path, old_path, options.strategy) catch |err| {
        dir.deleteFile(io, new_path) catch {};
        return err;
    };
    dir.rename(new_path, dir, exe_path, io) catch {
        dir.deleteFile(io, new_path) catch {};
        try rollBack(io, dir, exe_path, old_path, backed_up);
        return error.SwapFailed;
    };
    if (options.accept) |hook| {
        hook.run(hook.context, io, dir, exe_path) catch {
            try rollBack(io, dir, exe_path, old_path, backed_up);
            return error.Rejected;
        };
    }
    // Windows refuses to delete the running image; `removeLeftovers` retries later.
    if (backed_up) dir.deleteFile(io, old_path) catch {};
}

/// Deletes `<exe>.old` and `<exe>.new` left by an earlier `install`; call it on start.
/// Files that do not exist are not an error.
pub fn removeLeftovers(io: Io, dir: Io.Dir, exe_path: []const u8) error{
    NameTooLong,
    CleanupFailed,
}!void {
    var buffer: [max_path]u8 = undefined;
    for ([_][]const u8{ ".old", ".new" }) |suffix| {
        const path = try sibling(&buffer, exe_path, suffix);
        dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.CleanupFailed,
        };
    }
}

fn sibling(buffer: []u8, exe_path: []const u8, suffix: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ exe_path, suffix }) catch error.NameTooLong;
}

fn stage(io: Io, dir: Io.Dir, new_path: []const u8, bytes: []const u8) InstallError!void {
    // Executable permissions are set at creation, so the swap never loses `+x`.
    const file = dir.createFile(io, new_path, .{ .permissions = .executable_file }) catch
        return error.StageFailed;
    defer file.close(io);
    // Synced before the rename: otherwise a crash can persist the rename but not the data,
    // leaving an empty executable after `<exe>.old` was removed.
    writeSynced(io, file, bytes) catch {
        dir.deleteFile(io, new_path) catch {};
        return error.StageFailed;
    };
}

fn writeSynced(io: Io, file: Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

/// Makes `<exe>.old`; false when there was no executable to back up.
fn backUp(
    io: Io,
    dir: Io.Dir,
    exe_path: []const u8,
    old_path: []const u8,
    strategy: Strategy,
) InstallError!bool {
    const result = switch (strategy) {
        .rename_over => dir.copyFile(exe_path, dir, old_path, io, .{}),
        .move_aside => renameImage(io, dir, exe_path, old_path),
    };
    result catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.BackupFailed,
    };
    return true;
}

/// `dir.rename` of `from` to `to`, its sibling, that also moves a running executable on
/// Windows. shortcut: Zig 0.17's rename opens the file to write it as well as to move it,
/// which Windows refuses for a running image (`FileBusy`; docs/zig-issues.md, issue 6);
/// `MoveFileExW` asks only to move it. Remove when std's rename asks for less.
fn renameImage(io: Io, dir: Io.Dir, from: []const u8, to: []const u8) !void {
    if (builtin.os.tag != .windows) return dir.rename(from, dir, to, io);
    assert(std.mem.eql(u8, std.fs.path.dirname(from) orelse "", std.fs.path.dirname(to) orelse ""));
    var real: [max_path]u8 = undefined;
    const real_from = real[0..try dir.realPathFile(io, from, &real)];
    const parent = std.fs.path.dirname(real_from) orelse return error.RenameFailed;
    var joined: [max_path]u8 = undefined;
    const real_to = std.fmt.bufPrint(&joined, "{s}\\{s}", .{ parent, std.fs.path.basename(to) }) catch
        return error.NameTooLong;
    var from_w: [max_path:0]u16 = undefined;
    var to_w: [max_path:0]u16 = undefined;
    from_w[std.unicode.wtf8ToWtf16Le(&from_w, real_from) catch return error.RenameFailed] = 0;
    to_w[std.unicode.wtf8ToWtf16Le(&to_w, real_to) catch return error.RenameFailed] = 0;
    if (MoveFileExW(&from_w, &to_w, move_file_replace_existing) == 0) return error.RenameFailed;
}

const move_file_replace_existing = 0x1;
extern "kernel32" fn MoveFileExW(
    existing: [*:0]const u16,
    new: [*:0]const u16,
    flags: u32,
) callconv(.winapi) i32;

/// Puts `<exe>.old` back at `exe_path`, or removes `exe_path` if there was no backup.
fn rollBack(
    io: Io,
    dir: Io.Dir,
    exe_path: []const u8,
    old_path: []const u8,
    backed_up: bool,
) error{RollbackFailed}!void {
    if (!backed_up) {
        dir.deleteFile(io, exe_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.RollbackFailed,
        };
        return;
    }
    renameImage(io, dir, old_path, exe_path) catch return error.RollbackFailed;
}

// 5. Fetch, and the flow.

/// Fetches a URL into memory. `check` and `apply` take one so tests can pass a fake.
pub const Transport = struct {
    context: *anyopaque,
    getFn: *const fn (
        context: *anyopaque,
        gpa: Allocator,
        url: []const u8,
        limit: usize,
    ) Transport.Error![]u8,

    /// Why a fetch failed.
    pub const Error = error{
        OutOfMemory,
        /// The server answered 404 Not Found: for the latest-release URL, the repository
        /// has no published release (or does not exist).
        NotFound,
        /// Connection, TLS, protocol, or a non-2xx status other than 404.
        FetchFailed,
        /// The body exceeds the limit.
        TooLarge,
        /// The timeout passed before the body arrived.
        Timeout,
    };

    /// The body at `url`, at most `limit` bytes, owned by the caller (freed with `gpa`).
    pub fn get(transport: Transport, gpa: Allocator, url: []const u8, limit: usize) Error![]u8 {
        const body = try transport.getFn(transport.context, gpa, url, limit);
        assert(body.len <= limit);
        return body;
    }
};

/// A `Transport` over `std.http.Client`. The caller owns the client (and its `Io`).
pub const HttpTransport = struct {
    client: *std.http.Client,
    max_redirects: u16 = 5,
    /// The whole request, connection to last byte. Needs an `Io` with concurrency;
    /// without it every request fails with `FetchFailed`.
    timeout: ?Io.Duration = null,
    user_agent: []const u8 = "termancy-update",

    /// The type-erased interface.
    pub fn transport(http: *HttpTransport) Transport {
        return .{ .context = http, .getFn = getErased };
    }

    fn getErased(
        context: *anyopaque,
        gpa: Allocator,
        url: []const u8,
        limit: usize,
    ) Transport.Error![]u8 {
        const http: *HttpTransport = @ptrCast(@alignCast(context));
        const duration = http.timeout orelse return http.fetch(gpa, url, limit);
        return http.fetchWithTimeout(gpa, url, limit, duration);
    }

    /// One GET, following redirects, without a timeout.
    pub fn fetch(
        http: *HttpTransport,
        gpa: Allocator,
        url: []const u8,
        limit: usize,
    ) Transport.Error![]u8 {
        const uri = std.Uri.parse(url) catch return error.FetchFailed;
        if (!isHttps(uri)) return error.FetchFailed;
        var request = http.client.request(.GET, uri, .{
            .redirect_behavior = .init(http.max_redirects),
            .headers = .{
                .user_agent = .{ .override = http.user_agent },
                .accept_encoding = .omit,
            },
        }) catch |err| return failure(err);
        defer request.deinit();
        request.sendBodiless() catch return error.FetchFailed;
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |err| return failure(err);
        // std follows a redirect to plain http too: such a body is never read.
        if (!isHttps(request.uri)) return error.FetchFailed;
        if (statusError(response.head.status)) |err| return err;
        if (response.head.content_length) |length| {
            if (length > limit) return error.TooLarge;
        }
        var transfer_buffer: [64]u8 = undefined;
        const body = response.reader(&transfer_buffer);
        return body.allocRemaining(gpa, .limited(limit)) catch |err| switch (err) {
            error.StreamTooLong => error.TooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.FetchFailed,
        };
    }

    /// `fetch` raced against a sleep of `duration`; the loser is canceled.
    fn fetchWithTimeout(
        http: *HttpTransport,
        gpa: Allocator,
        url: []const u8,
        limit: usize,
        duration: Io.Duration,
    ) Transport.Error![]u8 {
        const io = http.client.io;
        const Race = union(enum) { body: Transport.Error![]u8, expired: Io.Cancelable!void };
        var slots: [2]Race = undefined;
        var select: Io.Select(Race) = .init(io, &slots);
        defer while (select.cancel()) |left| switch (left) {
            .body => |result| if (result) |bytes| gpa.free(bytes) else |_| {},
            .expired => {},
        };
        select.concurrent(.body, fetch, .{ http, gpa, url, limit }) catch
            return error.FetchFailed;
        select.async(.expired, Io.sleep, .{ io, duration, .awake });
        const first = select.await() catch return error.Timeout;
        return switch (first) {
            .body => |result| result,
            .expired => error.Timeout,
        };
    }

    fn isHttps(uri: std.Uri) bool {
        return std.ascii.eqlIgnoreCase(uri.scheme, "https");
    }

    /// The error for a response with `status`, or null for success.
    fn statusError(status: std.http.Status) ?Transport.Error {
        if (status.class() == .success) return null;
        return if (status == .not_found) error.NotFound else error.FetchFailed;
    }

    fn failure(err: anyerror) Transport.Error {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.FetchFailed;
    }
};

/// Everything `check` can fail with.
pub const CheckError = Transport.Error || ParseError || DecideError || error{InvalidSource};

/// Looks up the latest release and decides whether it is an update. Results live in
/// `arena`.
pub fn check(arena: Allocator, transport: Transport, options: Options) CheckError!Check {
    if (options.allow_prerelease) {
        const url = try releasesUrl(arena, options.source);
        const body = try transport.get(arena, url, options.limits.metadata);
        const release = newest(try parseReleases(arena, body), true) orelse
            return .{ .up_to_date = options.current };
        return decide(arena, release, options);
    }
    const url = try latestReleaseUrl(arena, options.source);
    const body = try transport.get(arena, url, options.limits.metadata);
    const release = try parseRelease(arena, body);
    return decide(arena, release, options);
}

/// Everything `apply` can fail with.
pub const ApplyError = Transport.Error || ChecksumError || SignatureError || InstallError ||
    error{
        /// The download's length differs from the size the release reports.
        SizeMismatch,
        /// The asset is an archive that cannot be read.
        ArchiveInvalid,
        /// The asset is an archive without a file named like the executable.
        ExecutableMissing,
    };

/// Downloads `plan.binary`, verifies its checksum (and signature, when
/// `options.public_key` is set), then installs it at `exe_path` relative to `dir`.
/// Nothing on disk changes unless every check passes.
pub fn apply(
    gpa: Allocator,
    io: Io,
    transport: Transport,
    plan: Plan,
    options: Options,
    dir: Io.Dir,
    exe_path: []const u8,
) ApplyError!void {
    const binary = try transport.get(gpa, plan.binary.url, options.limits.binary);
    defer gpa.free(binary);
    if (plan.binary.size != 0 and plan.binary.size != binary.len) return error.SizeMismatch;
    try verifyDownload(gpa, transport, plan, options, binary);
    const packaging = packagingOf(plan.binary.name);
    if (packaging == .bare) return install(io, dir, exe_path, binary, options.install);
    const name = options.executable_name orelse std.fs.path.basename(exe_path);
    const executable = try extractExecutable(gpa, io, dir, exe_path, binary, packaging, name);
    defer gpa.free(executable);
    try install(io, dir, exe_path, executable, options.install);
}

/// How an asset is packaged, by its name.
pub const Packaging = enum { bare, tar_gz, zip };

pub fn packagingOf(name: []const u8) Packaging {
    if (endsWithIgnoreCase(name, ".tar.gz") or endsWithIgnoreCase(name, ".tgz")) return .tar_gz;
    if (endsWithIgnoreCase(name, ".zip")) return .zip;
    return .bare;
}

pub const ExtractError = error{
    /// The archive is damaged or of a kind the standard library cannot read.
    ArchiveInvalid,
    /// No regular file in the archive is named like the executable.
    ExecutableMissing,
} || Allocator.Error;

/// The contents of the regular file in `archive` whose base name is `name` (or, on
/// Windows, `name` with `.exe`). A `.zip` is read from a file staged next to `exe_path`
/// in `dir`, which is removed afterwards. Caller owns the result.
pub fn extractExecutable(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    exe_path: []const u8,
    archive: []const u8,
    packaging: Packaging,
    name: []const u8,
) ExtractError![]u8 {
    return switch (packaging) {
        .bare => gpa.dupe(u8, archive),
        .tar_gz => extractTarGz(gpa, archive, name),
        .zip => extractZip(gpa, io, dir, exe_path, archive, name),
    };
}

fn isExecutableName(entry: []const u8, name: []const u8) bool {
    const base = std.fs.path.basenamePosix(entry);
    if (std.mem.eql(u8, base, name)) return true;
    return base.len == name.len + 4 and std.mem.startsWith(u8, base, name) and
        std.ascii.eqlIgnoreCase(base[name.len..], ".exe");
}

fn extractTarGz(gpa: Allocator, archive: []const u8, name: []const u8) ExtractError![]u8 {
    var input: Io.Reader = .fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var file_name: [std.fs.max_path_bytes]u8 = undefined;
    var link_name: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gzip.reader, .{
        .file_name_buffer = &file_name,
        .link_name_buffer = &link_name,
    });
    while (it.next() catch return error.ArchiveInvalid) |file| {
        if (file.kind != .file or !isExecutableName(file.name, name)) continue;
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        it.streamRemaining(file, &out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return error.ArchiveInvalid,
        };
        return out.toOwnedSlice();
    }
    return error.ExecutableMissing;
}

fn extractZip(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    exe_path: []const u8,
    archive: []const u8,
    name: []const u8,
) ExtractError![]u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const staged = sibling(&path_buffer, exe_path, ".zip") catch return error.ArchiveInvalid;
    dir.writeFile(io, .{ .sub_path = staged, .data = archive }) catch return error.ArchiveInvalid;
    defer dir.deleteFile(io, staged) catch {};
    const file = dir.openFile(io, staged, .{}) catch return error.ArchiveInvalid;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var it = std.zip.Iterator.init(&reader) catch return error.ArchiveInvalid;
    var entry_name: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next() catch return error.ArchiveInvalid) |entry| {
        const entry_path = entry.getFilename(&reader, &entry_name, .{}) catch
            return error.ArchiveInvalid;
        if (!isExecutableName(entry_path, name)) continue;
        if (std.mem.endsWith(u8, entry_path, "/")) continue;
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        entry.extractTo(&reader, &out.writer) catch return error.ArchiveInvalid;
        return out.toOwnedSlice();
    }
    return error.ExecutableMissing;
}

fn verifyDownload(
    gpa: Allocator,
    transport: Transport,
    plan: Plan,
    options: Options,
    binary: []const u8,
) (Transport.Error || ChecksumError || SignatureError)!void {
    const sums = try transport.get(gpa, plan.checksum.url, options.limits.sidecar);
    defer gpa.free(sums);
    try verifyChecksum(binary, try findChecksum(sums, plan.binary.name));
    const key = options.public_key orelse return;
    const asset = plan.signature orelse return error.SignatureMissing;
    const signature = try transport.get(gpa, asset.url, options.limits.sidecar);
    defer gpa.free(signature);
    try verifySignature(key, signature, binary);
}

// Tests.

const testing = std.testing;

const release_json =
    \\{
    \\  "url": "https://api.github.com/repos/o/r/releases/1",
    \\  "tag_name": "v1.4.0",
    \\  "name": "1.4.0",
    \\  "draft": false,
    \\  "prerelease": false,
    \\  "body": null,
    \\  "assets": [
    \\    { "name": "app-linux-x86_64", "size": 6, "label": null,
    \\      "browser_download_url": "https://dl/app-linux-x86_64" },
    \\    { "name": "app-linux-x86_64.sig", "size": 64,
    \\      "browser_download_url": "https://dl/app-linux-x86_64.sig" },
    \\    { "name": "app-linux-aarch64",
    \\      "browser_download_url": "https://dl/app-linux-aarch64" },
    \\    { "name": "app-darwin-arm64",
    \\      "browser_download_url": "https://dl/app-darwin-arm64" },
    \\    { "name": "app-windows-amd64.exe",
    \\      "browser_download_url": "https://dl/app-windows-amd64.exe" },
    \\    { "name": "SHA256SUMS",
    \\      "browser_download_url": "https://dl/SHA256SUMS" }
    \\  ]
    \\}
;

test "parseRelease: tag, flags, assets; unknown fields ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const release = try parseRelease(arena.allocator(), release_json);
    try testing.expectEqualStrings("v1.4.0", release.tag);
    try testing.expectEqual(@as(u64, 4), release.version.minor);
    try testing.expect(!release.draft and !release.prerelease);
    try testing.expectEqual(@as(usize, 6), release.assets.len);
    try testing.expectEqualStrings("https://dl/app-linux-x86_64", release.assets[0].url);
    try testing.expectEqual(@as(u64, 6), release.assets[0].size);
    try testing.expectEqual(@as(u64, 0), release.assets[2].size);
    try testing.expect(release.find("SHA256SUMS") != null);
    try testing.expect(release.find("nope") == null);
}

test "parseRelease: malformed input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidRelease, parseRelease(a, "not json"));
    try testing.expectError(error.InvalidRelease, parseRelease(a, "{\"assets\": []}"));
    try testing.expectError(error.InvalidRelease, parseRelease(a,
        \\{"tag_name": "v1.0.0", "assets": [{"name": "x"}]}
    ));
    try testing.expectError(error.InvalidVersion, parseRelease(a, "{\"tag_name\": \"nightly\"}"));
    const empty = try parseRelease(a, "{\"tag_name\": \"2.0.0-rc.1\", \"prerelease\": true}");
    try testing.expectEqual(@as(usize, 0), empty.assets.len);
    try testing.expect(empty.prerelease);
}

test "latestReleaseUrl" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const url = try latestReleaseUrl(arena.allocator(), .{
        .owner = "93ams",
        .repo = "termancy",
        .api_base = "https://ghe.test/api/v3/",
    });
    try testing.expectEqualStrings("https://ghe.test/api/v3/repos/93ams/termancy/releases/latest", url);
    try testing.expectError(error.InvalidSource, latestReleaseUrl(arena.allocator(), .{
        .owner = "a/b",
        .repo = "termancy",
    }));
    try testing.expectError(error.InvalidSource, latestReleaseUrl(arena.allocator(), .{
        .owner = "o",
        .repo = "..",
    }));
}

test "selectAsset: by OS and CPU spelling, sidecars excluded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const release = try parseRelease(arena.allocator(), release_json);
    const pick = struct {
        fn name(r: Release, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ![]const u8 {
            return (try selectAsset(r, .{ .os = os, .arch = arch }, .{})).name;
        }
    }.name;
    try testing.expectEqualStrings("app-linux-x86_64", try pick(release, .linux, .x86_64));
    try testing.expectEqualStrings("app-linux-aarch64", try pick(release, .linux, .aarch64));
    try testing.expectEqualStrings("app-darwin-arm64", try pick(release, .macos, .aarch64));
    try testing.expectEqualStrings("app-windows-amd64.exe", try pick(release, .windows, .x86_64));
    try testing.expectError(error.NoMatchingAsset, pick(release, .macos, .x86_64));
    try testing.expectError(error.NoMatchingAsset, pick(release, .netbsd, .x86_64));
}

test "selectAsset: whole words only, ambiguity, suffix, custom names" {
    const assets = [_]Asset{
        .{ .name = "tool-darwinx-arm64", .url = "1" },
        .{ .name = "tool-Linux-ARM64.tar.gz", .url = "2" },
        .{ .name = "tool-linux-arm64", .url = "3" },
        .{ .name = "tool-penguin-arm64", .url = "4" },
    };
    const release: Release = .{
        .tag = "v1.0.0",
        .version = try Version.parse("1.0.0"),
        .assets = &assets,
    };
    const linux_arm: Target = .{ .os = .linux, .arch = .aarch64 };
    const mac_arm: Target = .{ .os = .macos, .arch = .aarch64 };
    try testing.expectError(error.NoMatchingAsset, selectAsset(release, mac_arm, .{}));
    try testing.expectError(error.AmbiguousAsset, selectAsset(release, linux_arm, .{}));
    const gz = try selectAsset(release, linux_arm, .{ .suffix = ".TAR.GZ" });
    try testing.expectEqualStrings("2", gz.url);
    const custom = try selectAsset(release, linux_arm, .{
        .os = &.{.{ .os = .linux, .names = &.{"penguin"} }},
    });
    try testing.expectEqualStrings("4", custom.url);
}

test "decide: newer, same, draft, pre-release, missing checksum" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var release = try parseRelease(a, release_json);
    var options: Options = .{
        .source = .{ .owner = "o", .repo = "r" },
        .current = try Version.parse("1.3.9"),
        .target = .{ .os = .linux, .arch = .x86_64 },
    };
    const plan = (try decide(a, release, options)).available;
    try testing.expectEqualStrings("app-linux-x86_64", plan.binary.name);
    try testing.expectEqualStrings("SHA256SUMS", plan.checksum.name);
    try testing.expectEqualStrings("app-linux-x86_64.sig", plan.signature.?.name);

    options.current = try Version.parse("1.4.0+local");
    try testing.expect((try decide(a, release, options)) == .up_to_date);
    options.current = try Version.parse("1.0.0");
    release.draft = true;
    try testing.expect((try decide(a, release, options)) == .up_to_date);
    release.draft = false;
    release.prerelease = true;
    try testing.expect((try decide(a, release, options)) == .up_to_date);
    options.allow_prerelease = true;
    try testing.expect((try decide(a, release, options)) == .available);

    options.target = .{ .os = .linux, .arch = .aarch64 };
    const no_sums = [_]Asset{.{ .name = "app-linux-aarch64", .url = "u" }};
    release.assets = &no_sums;
    try testing.expectError(error.ChecksumMissing, decide(a, release, options));
    const own_sum = [_]Asset{ no_sums[0], .{ .name = "app-linux-aarch64.sha256", .url = "s" } };
    release.assets = &own_sum;
    const own = (try decide(a, release, options)).available;
    try testing.expectEqualStrings("s", own.checksum.url);
    try testing.expect(own.signature == null);
}

fn hexDigest(bytes: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: Digest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "findChecksum: sha256sum, BSD, bare, paths, CRLF" {
    const hex = hexDigest("binary");
    var expected: Digest = undefined;
    Sha256.hash("binary", &expected, .{});
    var other = hex;
    other[0] = if (hex[0] == '0') '1' else '0';
    var buffer: [512]u8 = undefined;
    const list = try std.fmt.bufPrint(
        &buffer,
        "# comment\r\n{s}  other\r\n{s} *dist\\app\r\n",
        .{ &other, &hex },
    );
    try testing.expectEqual(expected, try findChecksum(list, "app"));
    try testing.expectError(error.ChecksumMissing, findChecksum(list, "missing"));

    const bsd = try std.fmt.bufPrint(&buffer, "SHA256 (app) = {s}\n", .{hex});
    try testing.expectEqual(expected, try findChecksum(bsd, "app"));
    const bare = try std.fmt.bufPrint(&buffer, "{s}\n", .{hex});
    try testing.expectEqual(expected, try findChecksum(bare, "anything"));
    try testing.expectError(error.ChecksumMissing, findChecksum("abc  app\n", "app"));
    try testing.expectError(error.ChecksumMissing, findChecksum("", "app"));

    try verifyChecksum("binary", expected);
    try testing.expectError(error.ChecksumMismatch, verifyChecksum("binarY", expected));
}

test "verifySignature: good, base64, tampered binary, tampered signature, missing" {
    const pair = Ed25519.KeyPair.generate(testing.io);
    const key = pair.public_key.toBytes();
    const message = "the new executable";
    const raw = (try pair.sign(message, null)).toBytes();

    try verifySignature(key, &raw, message);
    var base64: [std.base64.standard.Encoder.calcSize(raw.len) + 1]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(base64[0 .. base64.len - 1], &raw);
    base64[base64.len - 1] = '\n';
    try verifySignature(key, &base64, message);

    const changed = "the new executablE";
    try testing.expectError(error.SignatureInvalid, verifySignature(key, &raw, changed));
    var tampered = raw;
    tampered[10] ^= 1;
    try testing.expectError(error.SignatureInvalid, verifySignature(key, &tampered, message));
    try testing.expectError(error.SignatureInvalid, verifySignature(key, "short", message));
    try testing.expectError(error.SignatureMissing, verifySignature(key, null, message));
    const other = Ed25519.KeyPair.generate(testing.io).public_key.toBytes();
    try testing.expectError(error.SignatureInvalid, verifySignature(other, &raw, message));
}

fn readFile(dir: Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1024));
}

fn expectFile(dir: Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try readFile(dir, path);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectMissing(dir: Io.Dir, path: []const u8) !void {
    try testing.expectError(error.FileNotFound, dir.access(testing.io, path, .{}));
}

test "renameImage moves a running executable aside, and back" {
    // This test's own executable, which runs: what `move_aside` does to termancy.exe.
    const io = testing.io;
    var self_buffer: [max_path]u8 = undefined;
    const self = self_buffer[0..try std.process.executablePath(io, &self_buffer)];
    var moved_buffer: [max_path]u8 = undefined;
    const moved = try std.fmt.bufPrint(&moved_buffer, "{s}.moved", .{self});
    const cwd = Io.Dir.cwd();
    try renameImage(io, cwd, self, moved);
    defer renameImage(io, cwd, moved, self) catch {};
    try cwd.access(io, moved, .{});
    try testing.expectError(error.FileNotFound, cwd.access(io, self, .{}));
}

test "install: both strategies replace the file and remove the backup" {
    for ([_]Strategy{ .rename_over, .move_aside }) |strategy| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "app", .data = "old" });
        try install(testing.io, tmp.dir, "app", "new", .{ .strategy = strategy });
        try expectFile(tmp.dir, "app", "new");
        try expectMissing(tmp.dir, "app.old");
        try expectMissing(tmp.dir, "app.new");
        if (builtin.os.tag != .windows) {
            const stat = try tmp.dir.statFile(testing.io, "app", .{});
            try testing.expect(stat.permissions.toMode() & 0o100 != 0);
        }
    }
}

test "install: a fresh path is created" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try install(testing.io, tmp.dir, "app", "new", .{});
    try expectFile(tmp.dir, "app", "new");
}

const Rejecter = struct {
    calls: usize = 0,
    seen: [8]u8 = undefined,
    seen_len: usize = 0,

    fn hook(r: *Rejecter) Hook {
        return .{ .context = r, .run = run };
    }

    fn run(context: ?*anyopaque, io: Io, dir: Io.Dir, exe_path: []const u8) error{Rejected}!void {
        const r: *Rejecter = @ptrCast(@alignCast(context.?));
        r.calls += 1;
        // The new executable is in place when the hook runs.
        const content = dir.readFile(io, exe_path, &r.seen) catch return error.Rejected;
        r.seen_len = content.len;
        return error.Rejected;
    }
};

test "install: a failing accept step rolls back, for both strategies" {
    for ([_]Strategy{ .rename_over, .move_aside }) |strategy| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "app", .data = "old" });
        var rejecter: Rejecter = .{};
        try testing.expectError(error.Rejected, install(testing.io, tmp.dir, "app", "new", .{
            .strategy = strategy,
            .accept = rejecter.hook(),
        }));
        try testing.expectEqual(@as(usize, 1), rejecter.calls);
        try testing.expectEqualStrings("new", rejecter.seen[0..rejecter.seen_len]);
        try expectFile(tmp.dir, "app", "old");
        try expectMissing(tmp.dir, "app.old");
        try expectMissing(tmp.dir, "app.new");
    }
}

test "install: rollback without a previous executable removes the new one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rejecter: Rejecter = .{};
    try testing.expectError(error.Rejected, install(testing.io, tmp.dir, "app", "new", .{
        .accept = rejecter.hook(),
    }));
    try expectMissing(tmp.dir, "app");
}

test "install: staging failure leaves everything untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const no_dir = install(testing.io, tmp.dir, "missing/app", "new", .{});
    try testing.expectError(error.StageFailed, no_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app", .data = "old" });
    // A directory where the backup must go makes the backup fail before any change.
    try tmp.dir.createDir(testing.io, "app.old", .default_dir);
    try testing.expectError(error.BackupFailed, install(testing.io, tmp.dir, "app", "new", .{
        .strategy = .move_aside,
    }));
    try expectFile(tmp.dir, "app", "old");
    try expectMissing(tmp.dir, "app.new");
}

test "removeLeftovers: deletes what is there, ignores what is not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try removeLeftovers(testing.io, tmp.dir, "app");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.old", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.new", .data = "y" });
    try removeLeftovers(testing.io, tmp.dir, "app");
    try expectMissing(tmp.dir, "app.old");
    try expectMissing(tmp.dir, "app.new");
}

/// An in-memory transport: a URL-to-body map, recording what was requested.
const FakeTransport = struct {
    routes: []const Route,
    requests: usize = 0,

    const Route = struct { url: []const u8, body: []const u8 };

    fn transport(fake: *FakeTransport) Transport {
        return .{ .context = fake, .getFn = get };
    }

    fn get(
        context: *anyopaque,
        gpa: Allocator,
        url: []const u8,
        limit: usize,
    ) Transport.Error![]u8 {
        const fake: *FakeTransport = @ptrCast(@alignCast(context));
        fake.requests += 1;
        for (fake.routes) |route| {
            if (!std.mem.eql(u8, route.url, url)) continue;
            if (route.body.len > limit) return error.TooLarge;
            return gpa.dupe(u8, route.body);
        }
        return error.FetchFailed;
    }
};

const Fixture = struct {
    pair: Ed25519.KeyPair,
    sums: [128]u8,
    sums_len: usize,
    signature: [Ed25519.Signature.encoded_length]u8,

    const binary = "NEWAPP";

    fn init() !Fixture {
        var fixture: Fixture = .{
            .pair = Ed25519.KeyPair.generate(testing.io),
            .sums = undefined,
            .sums_len = 0,
            .signature = undefined,
        };
        const line = "{s}  app-linux-x86_64\n";
        const sums = try std.fmt.bufPrint(&fixture.sums, line, .{hexDigest(binary)});
        fixture.sums_len = sums.len;
        fixture.signature = (try fixture.pair.sign(binary, null)).toBytes();
        return fixture;
    }

    fn routes(
        f: *const Fixture,
        binary_body: []const u8,
        signature: ?[]const u8,
    ) [4]FakeTransport.Route {
        return .{
            .{ .url = "https://api.github.com/repos/o/r/releases/latest", .body = release_json },
            .{ .url = "https://dl/app-linux-x86_64", .body = binary_body },
            .{ .url = "https://dl/SHA256SUMS", .body = f.sums[0..f.sums_len] },
            .{ .url = "https://dl/app-linux-x86_64.sig", .body = signature orelse "" },
        };
    }

    fn options(f: *const Fixture, signed: bool) Options {
        return .{
            .source = .{ .owner = "o", .repo = "r" },
            .current = Version.parse("1.0.0") catch unreachable, // A valid literal.
            .target = .{ .os = .linux, .arch = .x86_64 },
            .public_key = if (signed) f.pair.public_key.toBytes() else null,
        };
    }
};

fn checkAndApply(fake: *FakeTransport, options: Options, dir: Io.Dir) ApplyError!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The fixture always describes an available update.
    const result = check(arena.allocator(), fake.transport(), options) catch unreachable;
    const plan = result.available;
    try apply(testing.allocator, testing.io, fake.transport(), plan, options, dir, "app");
}

test "check + apply: signed update installs" {
    const fixture = try Fixture.init();
    const routes = fixture.routes(Fixture.binary, &fixture.signature);
    var fake: FakeTransport = .{ .routes = &routes };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app", .data = "OLDAPP" });
    try checkAndApply(&fake, fixture.options(true), tmp.dir);
    try expectFile(tmp.dir, "app", Fixture.binary);
    try testing.expectEqual(@as(usize, 4), fake.requests);
}

test "check + apply: rejections leave the executable untouched" {
    const fixture = try Fixture.init();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app", .data = "OLDAPP" });

    // Tampered binary (same size): checksum fails before the signature is fetched.
    const tampered = fixture.routes("EVILAP", &fixture.signature);
    var fake: FakeTransport = .{ .routes = &tampered };
    const signed = fixture.options(true);
    try testing.expectError(error.ChecksumMismatch, checkAndApply(&fake, signed, tmp.dir));

    // Tampered signature.
    var bad_signature = fixture.signature;
    bad_signature[0] ^= 0xff;
    const forged = fixture.routes(Fixture.binary, &bad_signature);
    fake = .{ .routes = &forged };
    try testing.expectError(error.SignatureInvalid, checkAndApply(&fake, signed, tmp.dir));

    // Unsigned release while a key is configured.
    const unsigned = fixture.routes(Fixture.binary, null);
    var plan_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer plan_arena.deinit();
    fake = .{ .routes = &unsigned };
    const options = fixture.options(true);
    var plan = (try check(plan_arena.allocator(), fake.transport(), options)).available;
    plan.signature = null;
    try testing.expectError(
        error.SignatureMissing,
        apply(testing.allocator, testing.io, fake.transport(), plan, options, tmp.dir, "app"),
    );

    // Wrong size, and over the limit.
    const short = fixture.routes("NEW", &fixture.signature);
    fake = .{ .routes = &short };
    const plain = fixture.options(false);
    try testing.expectError(error.SizeMismatch, checkAndApply(&fake, plain, tmp.dir));
    var limited = fixture.options(false);
    limited.limits.binary = 3;
    const routes = fixture.routes(Fixture.binary, null);
    fake = .{ .routes = &routes };
    try testing.expectError(error.TooLarge, checkAndApply(&fake, limited, tmp.dir));

    try expectFile(tmp.dir, "app", "OLDAPP");
    try expectMissing(tmp.dir, "app.new");
    try expectMissing(tmp.dir, "app.old");

    // Without a key, a checksum alone is enough.
    fake = .{ .routes = &routes };
    try checkAndApply(&fake, fixture.options(false), tmp.dir);
    try expectFile(tmp.dir, "app", Fixture.binary);
}

test "check: up to date, and transport failure" {
    const fixture = try Fixture.init();
    const routes = fixture.routes(Fixture.binary, null);
    var fake: FakeTransport = .{ .routes = &routes };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var options = fixture.options(false);
    options.current = try Version.parse("v1.4.0");
    try testing.expect((try check(arena.allocator(), fake.transport(), options)) == .up_to_date);
    options.source.repo = "elsewhere";
    try testing.expectError(error.FetchFailed, check(arena.allocator(), fake.transport(), options));
    options.limits.metadata = 10;
    options.source.repo = "r";
    try testing.expectError(error.TooLarge, check(arena.allocator(), fake.transport(), options));
}

const releases_json =
    \\[
    \\  { "tag_name": "v2.0.0-rc.1", "prerelease": true, "assets": [] },
    \\  { "tag_name": "nightly", "assets": [] },
    \\  { "tag_name": "v3.0.0", "draft": true },
    \\  { "tag_name": "v1.5.0", "assets": [] }
    \\]
;

test "parseReleases and newest: drafts and non-versions skipped, pre-releases on request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const releases = try parseReleases(a, releases_json);
    try testing.expectEqual(3, releases.len);
    try testing.expectEqualStrings("v1.5.0", newest(releases, false).?.tag);
    try testing.expectEqualStrings("v2.0.0-rc.1", newest(releases, true).?.tag);
    try testing.expect(newest(releases[2..2], true) == null);
    try testing.expectError(error.InvalidRelease, parseReleases(a, "{}"));
}

test "check: allow_prerelease reads the list of releases" {
    const routes = [_]FakeTransport.Route{
        .{ .url = "https://api.github.com/repos/o/r/releases?per_page=30", .body = releases_json },
    };
    var fake: FakeTransport = .{ .routes = &routes };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var options: Options = .{
        .source = .{ .owner = "o", .repo = "r" },
        .current = try Version.parse("2.0.0-rc.1"),
        .target = .{ .os = .linux, .arch = .x86_64 },
        .allow_prerelease = true,
    };
    try testing.expect((try check(a, fake.transport(), options)) == .up_to_date);
    options.current = try Version.parse("1.0.0");
    // The newest is the release candidate, which publishes no asset for the target.
    try testing.expectError(error.NoMatchingAsset, check(a, fake.transport(), options));
}

/// A gzip-compressed tar archive of `files`, stored without compression, in `arena`.
fn testTarGz(arena: Allocator, files: []const [2][]const u8) ![]const u8 {
    var tar_bytes: Io.Writer.Allocating = .init(arena);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    for (files) |file| try tar.writeFileBytes(file[0], file[1], .{ .mode = 0o755 });
    try tar_bytes.writer.splatByteAll(0, 1024); // The end-of-archive marker.
    var out: Io.Writer.Allocating = .init(arena);
    const buffer = try arena.alloc(u8, std.compress.flate.max_window_len);
    var gzip: std.compress.flate.Compress.Raw = try .init(&out.writer, buffer, .gzip);
    try gzip.writer.writeAll(tar_bytes.written());
    try gzip.finish();
    return out.written();
}

/// A zip archive of `files`, stored without compression, in `arena`.
fn testZip(arena: Allocator, files: []const [2][]const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const offsets = try arena.alloc(u32, files.len);
    for (files, offsets) |file, *offset| {
        offset.* = @intCast(out.written().len);
        try w.writeAll("PK\x03\x04");
        try zipHeader(w, file[0], file[1]);
        try w.writeInt(u16, 0, .little); // Extra field length.
        try w.writeAll(file[0]);
        try w.writeAll(file[1]);
    }
    const directory_start: u32 = @intCast(out.written().len);
    for (files, offsets) |file, offset| {
        try w.writeAll("PK\x01\x02");
        try w.writeInt(u16, 20, .little); // Made by.
        try zipHeader(w, file[0], file[1]);
        // Extra and comment lengths, disk, internal and external attributes.
        try w.splatByteAll(0, 2 + 2 + 2 + 2 + 4);
        try w.writeInt(u32, offset, .little);
        try w.writeAll(file[0]);
    }
    const directory_end: u32 = @intCast(out.written().len);
    try w.writeAll("PK\x05\x06");
    try w.splatByteAll(0, 4); // Disk numbers.
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u32, directory_end - directory_start, .little);
    try w.writeInt(u32, directory_start, .little);
    try w.writeInt(u16, 0, .little); // Comment length.
    return out.written();
}

/// The fields a local and a central zip header share, up to the name's length.
fn zipHeader(w: *Io.Writer, name: []const u8, data: []const u8) !void {
    try w.writeInt(u16, 20, .little); // Version needed.
    try w.writeInt(u16, 0, .little); // Flags.
    try w.writeInt(u16, 0, .little); // Stored.
    try w.writeInt(u32, 0, .little); // Time and date.
    try w.writeInt(u32, std.hash.Crc32.hash(data), .little);
    try w.writeInt(u32, @intCast(data.len), .little);
    try w.writeInt(u32, @intCast(data.len), .little);
    try w.writeInt(u16, @intCast(name.len), .little);
}

test "extractExecutable: tar.gz and zip, by base name, with or without .exe" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "app-1.4.0/README.md", "read me" },
        .{ "app-1.4.0/bin/app", "NEWAPP" },
    };
    const windows = [_][2][]const u8{.{ "app.EXE", "NEWAPP.EXE" }};
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_]Packaging{ .tar_gz, .zip }) |packaging| {
        const build = if (packaging == .zip) &testZip else &testTarGz;
        const archive = try build(a, &files);
        const found = try extractExecutable(gpa, io, tmp.dir, "app", archive, packaging, "app");
        defer gpa.free(found);
        try testing.expectEqualStrings("NEWAPP", found);
        const exe = try build(a, &windows);
        const found_exe = try extractExecutable(gpa, io, tmp.dir, "app", exe, packaging, "app");
        defer gpa.free(found_exe);
        try testing.expectEqualStrings("NEWAPP.EXE", found_exe);
        try testing.expectError(
            error.ExecutableMissing,
            extractExecutable(gpa, io, tmp.dir, "app", archive, packaging, "other"),
        );
        try testing.expectError(
            error.ArchiveInvalid,
            extractExecutable(gpa, io, tmp.dir, "app", archive[0..40], packaging, "app"),
        );
    }
    try expectMissing(tmp.dir, "app.zip");
    try testing.expectEqual(Packaging.tar_gz, packagingOf("app-linux-x86_64.TGZ"));
    try testing.expectEqual(Packaging.zip, packagingOf("app-windows-x64.zip"));
    try testing.expectEqual(Packaging.bare, packagingOf("app-linux-x86_64"));
}

test "check + apply: an archive asset is verified as published, then unpacked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archive = try testTarGz(a, &.{.{ "app", "NEWAPP" }});
    const json =
        \\{ "tag_name": "v1.4.0", "assets": [
        \\  { "name": "app-linux-x86_64.tar.gz", "browser_download_url": "https://dl/a.tar.gz" },
        \\  { "name": "SHA256SUMS", "browser_download_url": "https://dl/SHA256SUMS" } ] }
    ;
    const sums = try std.fmt.allocPrint(a, "{s}  app-linux-x86_64.tar.gz\n", .{
        hexDigest(archive),
    });
    const routes = [_]FakeTransport.Route{
        .{ .url = "https://api.github.com/repos/o/r/releases/latest", .body = json },
        .{ .url = "https://dl/a.tar.gz", .body = archive },
        .{ .url = "https://dl/SHA256SUMS", .body = sums },
    };
    var fake: FakeTransport = .{ .routes = &routes };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app", .data = "OLDAPP" });
    const options: Options = .{
        .source = .{ .owner = "o", .repo = "r" },
        .current = try Version.parse("1.0.0"),
        .target = .{ .os = .linux, .arch = .x86_64 },
    };
    try checkAndApply(&fake, options, tmp.dir);
    try expectFile(tmp.dir, "app", "NEWAPP");
}

test "HttpTransport: 404 is NotFound, other failures are FetchFailed" {
    try testing.expectEqual(null, HttpTransport.statusError(.ok));
    try testing.expectEqual(error.NotFound, HttpTransport.statusError(.not_found).?);
    try testing.expectEqual(error.FetchFailed, HttpTransport.statusError(.forbidden).?);
    try testing.expectEqual(error.FetchFailed, HttpTransport.statusError(.bad_gateway).?);
}

test "HttpTransport: plain http is refused, even from a server that answers" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const answer = struct {
        fn run(i: Io, l: *Io.net.Server) !void {
            const stream = try l.accept(i);
            defer stream.close(i);
            var w = stream.writer(i, &.{});
            try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi");
        }
    }.run;
    var answering = try io.concurrent(answer, .{ io, &listener });
    defer answering.cancel(io) catch {};
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var http: HttpTransport = .{ .client = &client };
    var url: [64]u8 = undefined;
    const plain = try std.fmt.bufPrint(&url, "http://{f}/", .{listener.socket.address});
    try testing.expectError(error.FetchFailed, http.fetch(testing.allocator, plain, 64));
}

test "HttpTransport: the interface compiles without being called" {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    var http: HttpTransport = .{ .client = &client, .timeout = .fromSeconds(5) };
    const t = http.transport();
    // Building the interface analyses `fetch` and `fetchWithTimeout` for every target;
    // tests never touch the network.
    try testing.expect(t.context == @as(*anyopaque, &http));
}
