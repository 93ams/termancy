//! Package-manager manifests generated from one `Package` description: a Homebrew formula
//! (Ruby), a Scoop manifest (JSON), a winget manifest (YAML), an Arch Linux `PKGBUILD`
//! (bash), and a Debian `control` file. Output is deterministic, so it can be committed and
//! compared byte for byte.
//!
//! Every text field is escaped for the format it lands in: Ruby double-quoted strings
//! (`\`, `"`, `#`), JSON strings (which are also YAML double-quoted strings), bash
//! single-quoted words (`'\''`), and Debian folded fields (continuation lines, ` .` for
//! blank ones). Fields a format cannot represent at all, such as a line break in a Debian
//! `Maintainer`, are errors rather than mangled.
//!
//! Each `Asset` names where the executable is once the download is unpacked (`path`): an
//! archive member, or the downloaded file itself for a bare binary. When that path's base
//! name differs from the package name, the manifests install it under the package name.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

/// Why a description cannot be rendered.
pub const Error = error{
    /// `name` is not lower-case `[a-z0-9][a-z0-9+.-]*` of at least two bytes.
    InvalidName,
    /// `version` is empty, or holds bytes the format forbids (`:`, `/`, whitespace).
    InvalidVersion,
    /// An asset's `sha256` is not 64 hex digits.
    InvalidChecksum,
    /// A required field is empty, or a single-line field holds a line break.
    InvalidField,
    /// No asset exists for any target the format covers.
    NoAssets,
    /// Two assets name the same target.
    DuplicateTarget,
};

/// What the generators can fail with: a bad description, or the writer.
pub const WriteError = Error || Writer.Error;

/// The operating systems the manifests cover.
pub const Os = enum { linux, macos, windows };
/// The CPU architectures the manifests cover.
pub const Arch = enum { x86_64, aarch64 };

/// One downloadable build.
pub const Asset = struct {
    os: Os,
    arch: Arch,
    url: []const u8,
    /// Lower-case or upper-case hex SHA-256 of the file at `url`.
    sha256: []const u8,
    /// The executable after download and extraction: an archive member path, or the
    /// downloaded file's name for a bare binary.
    path: []const u8,
};

/// Everything the manifests are generated from.
pub const Package = struct {
    /// Package and command name: `snek`.
    name: []const u8,
    /// Semantic version without a leading `v`: `0.2.0`, `1.0.0-rc.1`.
    version: []const u8,
    /// One line: the summary each format shows in listings.
    description: []const u8,
    homepage: []const u8,
    /// SPDX license identifier: `MIT`.
    license: []const u8,
    /// `Name <email>`; only the Debian control file uses it, and requires it.
    maintainer: []const u8 = "",
    /// Who publishes the package, one word: `93ams`. Only winget uses it, and requires
    /// it: the package identifier is `<publisher>.<name>`.
    publisher: []const u8 = "",
    /// The Arch package release and the Debian revision.
    release: u32 = 1,
    assets: []const Asset,

    /// The asset for one target, if any.
    pub fn find(package: Package, os: Os, arch: Arch) ?Asset {
        for (package.assets) |asset| {
            if (asset.os == os and asset.arch == arch) return asset;
        }
        return null;
    }
};

/// Writes a Homebrew formula covering the macOS and Linux assets.
pub fn writeHomebrew(writer: *Writer, package: Package) WriteError!void {
    try validate(package);
    try writer.writeAll("class ");
    try writeClassName(writer, package.name);
    try writer.writeAll(" < Formula\n");
    try rubyField(writer, "desc", package.description);
    try rubyField(writer, "homepage", package.homepage);
    try rubyField(writer, "version", package.version);
    try rubyField(writer, "license", package.license);
    var any = false;
    for ([_]Os{ .macos, .linux }) |os| {
        if (try homebrewPlatform(writer, package, os)) any = true;
    }
    if (!any) return error.NoAssets;
    try writer.writeAll("\n  def install\n");
    try homebrewInstall(writer, package);
    try writer.writeAll("  end\n\n  test do\n    system \"#{bin}/");
    try rubyEscaped(writer, package.name);
    try writer.writeAll("\", \"--version\"\n  end\nend\n");
}

/// Writes a Scoop manifest covering the Windows assets.
pub fn writeScoop(writer: *Writer, package: Package) WriteError!void {
    try validate(package);
    const x64 = package.find(.windows, .x86_64);
    const arm = package.find(.windows, .aarch64);
    if (x64 == null and arm == null) return error.NoAssets;
    try writer.writeAll("{\n");
    try jsonField(writer, 1, "version", package.version);
    try jsonField(writer, 1, "description", package.description);
    try jsonField(writer, 1, "homepage", package.homepage);
    try jsonField(writer, 1, "license", package.license);
    try writer.writeAll("    \"architecture\": {\n");
    if (x64) |asset| try scoopArch(writer, package, "64bit", asset, arm != null);
    if (arm) |asset| try scoopArch(writer, package, "arm64", asset, false);
    try writer.writeAll("    }\n}\n");
}

/// Writes a winget manifest covering the Windows assets, in the single-file form
/// (`ManifestType: singleton`) that `winget install --manifest` and `winget validate` read.
/// The winget-pkgs repository takes the multi-file form, which `wingetcreate` makes from
/// the same fields.
pub fn writeWinget(writer: *Writer, package: Package) WriteError!void {
    try validate(package);
    try validatePublisher(package.publisher);
    const x64 = package.find(.windows, .x86_64);
    const arm = package.find(.windows, .aarch64);
    if (x64 == null and arm == null) return error.NoAssets;
    try writer.writeAll("# yaml-language-server: $schema=https://aka.ms/winget-manifest.singleton.1.6.0.schema.json\n");
    try writer.print("PackageIdentifier: {s}.{s}\n", .{ package.publisher, package.name });
    try yamlField(writer, "PackageVersion", package.version);
    try writer.writeAll("PackageLocale: en-US\n");
    try yamlField(writer, "Publisher", package.publisher);
    try yamlField(writer, "PackageName", package.name);
    try yamlField(writer, "License", package.license);
    try yamlField(writer, "ShortDescription", package.description);
    try yamlField(writer, "PackageUrl", package.homepage);
    try writer.writeAll("Installers:\n");
    if (x64) |asset| try wingetInstaller(writer, package, "x64", asset);
    if (arm) |asset| try wingetInstaller(writer, package, "arm64", asset);
    try writer.writeAll("ManifestType: singleton\nManifestVersion: 1.6.0\n");
}

/// Writes an Arch Linux `PKGBUILD` covering the Linux assets.
pub fn writePkgbuild(writer: *Writer, package: Package) WriteError!void {
    try validate(package);
    const arches = linuxAssets(package);
    if (arches.len == 0) return error.NoAssets;
    try writer.print("pkgname={s}\npkgver=", .{package.name});
    try writePkgver(writer, package.version);
    try writer.print("\npkgrel={d}\npkgdesc=", .{package.release});
    try shellQuoted(writer, package.description);
    try writer.writeAll("\narch=(");
    for (arches.slice(), 0..) |asset, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.print("'{s}'", .{archLinuxName(asset.arch)});
    }
    try writer.writeAll(")\nurl=");
    try shellQuoted(writer, package.homepage);
    try writer.writeAll("\nlicense=(");
    try shellQuoted(writer, package.license);
    try writer.writeAll(")\n");
    for (arches.slice()) |asset| try pkgbuildSource(writer, asset);
    try writer.writeAll("\npackage() {\n");
    try pkgbuildInstall(writer, package, arches.slice());
    try writer.writeAll("}\n");
}

/// Writes a Debian binary-package `control` file for one architecture.
pub fn writeDebianControl(writer: *Writer, package: Package, arch: Arch) WriteError!void {
    try validate(package);
    if (package.find(.linux, arch) == null) return error.NoAssets;
    try singleLine(package.maintainer);
    try singleLine(package.homepage);
    try writer.print("Package: {s}\nVersion: ", .{package.name});
    try writeDebianVersion(writer, package.version);
    try writer.print("-{d}\n", .{package.release});
    try writer.writeAll("Section: utils\nPriority: optional\n");
    try writer.print("Architecture: {s}\n", .{debianArchName(arch)});
    try writer.print("Maintainer: {s}\nHomepage: {s}\n", .{ package.maintainer, package.homepage });
    try writer.writeAll("Description:");
    try debianFolded(writer, package.description);
}

// Validation.

fn validate(package: Package) Error!void {
    try validateName(package.name);
    try validateVersion(package.version);
    try singleLine(package.description);
    try singleLine(package.license);
    if (package.homepage.len == 0) return error.InvalidField;
    for (package.assets, 0..) |asset, i| {
        if (asset.url.len == 0 or asset.path.len == 0) return error.InvalidField;
        if (asset.sha256.len != 64) return error.InvalidChecksum;
        for (asset.sha256) |byte| {
            if (!std.ascii.isHex(byte)) return error.InvalidChecksum;
        }
        for (package.assets[0..i]) |earlier| {
            if (earlier.os == asset.os and earlier.arch == asset.arch) {
                return error.DuplicateTarget;
            }
        }
    }
}

/// The intersection of the Debian, Arch, Homebrew, and Scoop package-name rules.
/// One segment of a winget package identifier: 1 to 32 bytes, none of them a dot,
/// whitespace, a control byte, or `\/:*?"<>|`.
fn validatePublisher(publisher: []const u8) Error!void {
    if (publisher.len == 0 or publisher.len > 32) return error.InvalidField;
    for (publisher) |byte| switch (byte) {
        0...32, 127, '.', '\\', '/', ':', '*', '?', '"', '<', '>', '|' => return error.InvalidField,
        else => {},
    };
}

fn validateName(name: []const u8) Error!void {
    if (name.len < 2) return error.InvalidName;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return error.InvalidName;
    for (name) |byte| {
        const ok = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or
            byte == '+' or byte == '.' or byte == '-';
        if (!ok) return error.InvalidName;
    }
}

fn validateVersion(version: []const u8) Error!void {
    if (version.len == 0) return error.InvalidVersion;
    if (!std.ascii.isDigit(version[0])) return error.InvalidVersion;
    for (version) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '+';
        if (!ok) return error.InvalidVersion;
    }
}

fn singleLine(text: []const u8) Error!void {
    if (text.len == 0) return error.InvalidField;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidField;
}

/// The base name of `path`, with `/` or `\` as separators.
fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash + 1 ..];
}

/// Whether `path` names a file called `name` (or `name.exe` when `exe`).
fn namedAs(path: []const u8, name: []const u8, exe: bool) bool {
    const base = baseName(path);
    if (!exe) return std.mem.eql(u8, base, name);
    return base.len == name.len + 4 and std.mem.startsWith(u8, base, name) and
        std.ascii.eqlIgnoreCase(base[name.len..], ".exe");
}

// Homebrew.

/// Homebrew's class name for a formula: `snek-cli` -> `SnekCli`, `+` -> `x`.
fn writeClassName(writer: *Writer, name: []const u8) Writer.Error!void {
    assert(name.len > 0);
    var upper = true;
    for (name) |byte| {
        if (byte == '-' or byte == '.' or byte == '_') {
            upper = true;
        } else if (byte == '+') {
            try writer.writeByte('x');
        } else {
            try writer.writeByte(if (upper) std.ascii.toUpper(byte) else byte);
            upper = false;
        }
    }
}

fn rubyField(writer: *Writer, key: []const u8, value: []const u8) Writer.Error!void {
    try writer.print("  {s} \"", .{key});
    try rubyEscaped(writer, value);
    try writer.writeAll("\"\n");
}

/// Escapes for a Ruby double-quoted string; `#` too, so `#{...}` never interpolates.
fn rubyEscaped(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |byte| switch (byte) {
        '\\', '"', '#' => try writer.print("\\{c}", .{byte}),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...31, 127 => try writer.print("\\x{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
}

/// `on_macos do ... end` with an `on_arm`/`on_intel` block per present asset.
fn homebrewPlatform(writer: *Writer, package: Package, os: Os) Writer.Error!bool {
    const arm = package.find(os, .aarch64);
    const intel = package.find(os, .x86_64);
    if (arm == null and intel == null) return false;
    try writer.print("\n  on_{s} do\n", .{@tagName(os)});
    if (arm) |asset| try homebrewArch(writer, "on_arm", asset);
    if (intel) |asset| try homebrewArch(writer, "on_intel", asset);
    try writer.writeAll("  end\n");
    return true;
}

fn homebrewArch(writer: *Writer, block: []const u8, asset: Asset) Writer.Error!void {
    try writer.print("    {s} do\n      url \"", .{block});
    try rubyEscaped(writer, asset.url);
    try writer.writeAll("\"\n      sha256 \"");
    try lowerHex(writer, asset.sha256);
    try writer.writeAll("\"\n    end\n");
}

/// One `bin.install` when every asset has the same path; otherwise a branch per target.
fn homebrewInstall(writer: *Writer, package: Package) Writer.Error!void {
    var first: ?[]const u8 = null;
    var uniform = true;
    for (package.assets) |asset| {
        if (asset.os == .windows) continue;
        if (first) |path| uniform = uniform and std.mem.eql(u8, path, asset.path);
        if (first == null) first = asset.path;
    }
    if (uniform) return homebrewBin(writer, "    ", package.name, first.?);
    var keyword: []const u8 = "if";
    for (package.assets) |asset| {
        if (asset.os == .windows) continue;
        const os_test = if (asset.os == .macos) "OS.mac?" else "OS.linux?";
        const cpu_test = if (asset.arch == .aarch64)
            "Hardware::CPU.arm?"
        else
            "Hardware::CPU.intel?";
        try writer.print("    {s} {s} && {s}\n", .{ keyword, os_test, cpu_test });
        try homebrewBin(writer, "      ", package.name, asset.path);
        keyword = "elsif";
    }
    try writer.writeAll("    end\n");
}

fn homebrewBin(
    writer: *Writer,
    indent: []const u8,
    name: []const u8,
    path: []const u8,
) Writer.Error!void {
    try writer.print("{s}bin.install \"", .{indent});
    try rubyEscaped(writer, path);
    try writer.writeByte('"');
    if (!namedAs(path, name, false)) {
        try writer.writeAll(" => \"");
        try rubyEscaped(writer, name);
        try writer.writeByte('"');
    }
    try writer.writeByte('\n');
}

fn lowerHex(writer: *Writer, hex: []const u8) Writer.Error!void {
    for (hex) |byte| try writer.writeByte(std.ascii.toLower(byte));
}

// Scoop.

fn jsonField(writer: *Writer, depth: usize, key: []const u8, value: []const u8) Writer.Error!void {
    try writer.splatByteAll(' ', depth * 4);
    try writer.print("\"{s}\": ", .{key});
    try jsonString(writer, value);
    try writer.writeAll(",\n");
}

fn jsonString(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"', '\\' => try writer.print("\\{c}", .{byte}),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn scoopArch(
    writer: *Writer,
    package: Package,
    key: []const u8,
    asset: Asset,
    more: bool,
) Writer.Error!void {
    try writer.print("        \"{s}\": {{\n", .{key});
    try jsonField(writer, 3, "url", asset.url);
    try writer.writeAll("            \"hash\": \"");
    try lowerHex(writer, asset.sha256);
    try writer.writeAll("\",\n            \"bin\": ");
    if (namedAs(asset.path, package.name, true)) {
        try jsonString(writer, asset.path);
    } else {
        // `[[path, alias]]` makes Scoop expose the executable under the package name.
        try writer.writeAll("[[");
        try jsonString(writer, asset.path);
        try writer.writeAll(", ");
        try jsonString(writer, package.name);
        try writer.writeAll("]]");
    }
    try writer.writeAll(if (more) "\n        },\n" else "\n        }\n");
}

// winget.

fn yamlField(writer: *Writer, key: []const u8, value: []const u8) Writer.Error!void {
    try writer.print("{s}: ", .{key});
    try jsonString(writer, value);
    try writer.writeByte('\n');
}

fn wingetInstaller(writer: *Writer, package: Package, arch: []const u8, asset: Asset) Writer.Error!void {
    try writer.print("  - Architecture: {s}\n", .{arch});
    if (std.ascii.endsWithIgnoreCase(asset.url, ".zip")) {
        try writer.writeAll("    InstallerType: zip\n    NestedInstallerType: portable\n" ++
            "    NestedInstallerFiles:\n      - RelativeFilePath: ");
        try jsonString(writer, asset.path);
        try writer.writeAll("\n        PortableCommandAlias: ");
        try jsonString(writer, package.name);
        try writer.writeByte('\n');
    } else {
        try writer.writeAll("    InstallerType: portable\n    Commands:\n      - ");
        try jsonString(writer, package.name);
        try writer.writeByte('\n');
    }
    try writer.writeAll("    InstallerUrl: ");
    try jsonString(writer, asset.url);
    try writer.writeAll("\n    InstallerSha256: ");
    for (asset.sha256) |byte| try writer.writeByte(std.ascii.toUpper(byte));
    try writer.writeByte('\n');
}

// PKGBUILD.

/// The Linux assets, `x86_64` first; validation leaves at most one per architecture.
const LinuxAssets = struct {
    buffer: [2]Asset = undefined,
    len: usize = 0,

    fn slice(assets: *const LinuxAssets) []const Asset {
        return assets.buffer[0..assets.len];
    }
};

fn linuxAssets(package: Package) LinuxAssets {
    var result: LinuxAssets = .{};
    for ([_]Arch{ .x86_64, .aarch64 }) |arch| {
        const asset = package.find(.linux, arch) orelse continue;
        assert(result.len < result.buffer.len);
        result.buffer[result.len] = asset;
        result.len += 1;
    }
    return result;
}

fn archLinuxName(arch: Arch) []const u8 {
    return @tagName(arch);
}

/// `pkgver` may not contain `-`; a semver pre-release separator becomes `_`.
fn writePkgver(writer: *Writer, version: []const u8) Writer.Error!void {
    for (version) |byte| try writer.writeByte(if (byte == '-') '_' else byte);
}

/// A bash single-quoted word; an embedded `'` becomes `'\''`.
fn shellQuoted(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') try writer.writeAll("'\\''") else try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}

fn pkgbuildSource(writer: *Writer, asset: Asset) Writer.Error!void {
    const arch = archLinuxName(asset.arch);
    try writer.print("source_{s}=(", .{arch});
    try shellQuoted(writer, asset.url);
    try writer.print(")\nsha256sums_{s}=('", .{arch});
    try lowerHex(writer, asset.sha256);
    try writer.writeAll("')\n");
}

fn pkgbuildInstall(writer: *Writer, package: Package, arches: []const Asset) Writer.Error!void {
    assert(arches.len > 0);
    const uniform = arches.len == 1 or std.mem.eql(u8, arches[0].path, arches[1].path);
    if (uniform) return pkgbuildInstallLine(writer, "  ", package.name, arches[0].path);
    try writer.writeAll("  case \"$CARCH\" in\n");
    for (arches) |asset| {
        try writer.print("    {s})\n", .{archLinuxName(asset.arch)});
        try pkgbuildInstallLine(writer, "      ", package.name, asset.path);
        try writer.writeAll("      ;;\n");
    }
    try writer.writeAll("  esac\n");
}

fn pkgbuildInstallLine(
    writer: *Writer,
    indent: []const u8,
    name: []const u8,
    path: []const u8,
) Writer.Error!void {
    try writer.print("{s}install -Dm755 \"$srcdir\"/", .{indent});
    try shellQuoted(writer, path);
    try writer.writeAll(" \"$pkgdir\"/usr/bin/");
    try shellQuoted(writer, name);
    try writer.writeByte('\n');
}

// Debian.

fn debianArchName(arch: Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
    };
}

/// The first `-` (the semver pre-release separator) becomes `~`, which Debian sorts
/// before the release: `1.0.0-rc.1` -> `1.0.0~rc.1`, below `1.0.0`.
fn writeDebianVersion(writer: *Writer, version: []const u8) Writer.Error!void {
    const build_start = std.mem.indexOfScalar(u8, version, '+') orelse version.len;
    const dash = std.mem.indexOfScalar(u8, version[0..build_start], '-');
    for (version, 0..) |byte, i| {
        try writer.writeByte(if (dash != null and i == dash.?) '~' else byte);
    }
}

/// A folded field value: the first line after the colon, the rest indented by one
/// space, blank lines as ` .`.
fn debianFolded(writer: *Writer, text: []const u8) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    try writer.print(" {s}\n", .{lines.first()});
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) {
            try writer.writeAll(" .\n");
        } else {
            try writer.print(" {s}\n", .{line});
        }
    }
}

const testing = std.testing;

const sha_a: []const u8 = &@as([64]u8, @splat('a'));
const sha_b: []const u8 = &@as([64]u8, @splat('B'));
const sha_c: []const u8 = &@as([64]u8, @splat('c'));
const sha_d: []const u8 = &@as([64]u8, @splat('d'));

const example: Package = .{
    .name = "snek",
    .version = "0.2.0-rc.1",
    .description = "A \"typed\" CLI kit #1 \\ it's fast",
    .homepage = "https://github.com/93ams/snek",
    .license = "MIT",
    .maintainer = "Ann Example <ann@example.com>",
    .assets = &.{
        .{
            .os = .macos,
            .arch = .aarch64,
            .url = "https://x.test/snek-macos-aarch64.tar.gz",
            .sha256 = sha_a,
            .path = "snek",
        },
        .{
            .os = .macos,
            .arch = .x86_64,
            .url = "https://x.test/snek-macos-x86_64.tar.gz",
            .sha256 = sha_b,
            .path = "snek",
        },
        .{
            .os = .linux,
            .arch = .x86_64,
            .url = "https://x.test/snek-linux-x86_64.tar.gz",
            .sha256 = sha_c,
            .path = "snek",
        },
        .{
            .os = .windows,
            .arch = .x86_64,
            .url = "https://x.test/snek-windows-x86_64.zip",
            .sha256 = sha_d,
            .path = "snek.exe",
        },
    },
};

fn render(
    comptime function: anytype,
    extra: anytype,
) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try @call(.auto, function, .{&out.writer} ++ extra);
    return out.toOwnedSlice();
}

fn expectRendered(expected: []const u8, comptime function: anytype, extra: anytype) !void {
    const actual = try render(function, extra);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "homebrew: formula with escaping and one install line" {
    try expectRendered(
        \\class Snek < Formula
        \\  desc "A \"typed\" CLI kit \#1 \\ it's fast"
        \\  homepage "https://github.com/93ams/snek"
        \\  version "0.2.0-rc.1"
        \\  license "MIT"
        \\
        \\  on_macos do
        \\    on_arm do
        \\      url "https://x.test/snek-macos-aarch64.tar.gz"
        \\      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    end
        \\    on_intel do
        \\      url "https://x.test/snek-macos-x86_64.tar.gz"
        \\      sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\    end
        \\  end
        \\
        \\  on_linux do
        \\    on_intel do
        \\      url "https://x.test/snek-linux-x86_64.tar.gz"
        \\      sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        \\    end
        \\  end
        \\
        \\  def install
        \\    bin.install "snek"
        \\  end
        \\
        \\  test do
        \\    system "#{bin}/snek", "--version"
        \\  end
        \\end
        \\
    , writeHomebrew, .{example});
}

test "homebrew: bare binaries with different paths get a branch per target" {
    var package = example;
    package.name = "snek-cli+x";
    package.description = "plain";
    package.assets = &.{
        .{
            .os = .linux,
            .arch = .aarch64,
            .url = "u1",
            .sha256 = sha_a,
            .path = "snek-linux-aarch64",
        },
        .{
            .os = .linux,
            .arch = .x86_64,
            .url = "u2",
            .sha256 = sha_c,
            .path = "snek-linux-x86_64",
        },
    };
    try expectRendered(
        \\class SnekClixx < Formula
        \\  desc "plain"
        \\  homepage "https://github.com/93ams/snek"
        \\  version "0.2.0-rc.1"
        \\  license "MIT"
        \\
        \\  on_linux do
        \\    on_arm do
        \\      url "u1"
        \\      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    end
        \\    on_intel do
        \\      url "u2"
        \\      sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        \\    end
        \\  end
        \\
        \\  def install
        \\    if OS.linux? && Hardware::CPU.arm?
        \\      bin.install "snek-linux-aarch64" => "snek-cli+x"
        \\    elsif OS.linux? && Hardware::CPU.intel?
        \\      bin.install "snek-linux-x86_64" => "snek-cli+x"
        \\    end
        \\  end
        \\
        \\  test do
        \\    system "#{bin}/snek-cli+x", "--version"
        \\  end
        \\end
        \\
    , writeHomebrew, .{package});
}

test "scoop: manifest with JSON escaping" {
    var package = example;
    package.description = "tab\there \"q\" \\ ctl\x01";
    try expectRendered(
        \\{
        \\    "version": "0.2.0-rc.1",
        \\    "description": "tab\there \"q\" \\ ctl\u0001",
        \\    "homepage": "https://github.com/93ams/snek",
        \\    "license": "MIT",
        \\    "architecture": {
        \\        "64bit": {
        \\            "url": "https://x.test/snek-windows-x86_64.zip",
        \\            "hash": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        \\            "bin": "snek.exe"
        \\        }
        \\    }
        \\}
        \\
    , writeScoop, .{package});
}

test "scoop: two architectures, a renamed bare binary" {
    var package = example;
    package.assets = &.{
        .{
            .os = .windows,
            .arch = .aarch64,
            .url = "a",
            .sha256 = sha_a,
            .path = "snek-arm64.exe",
        },
        .{
            .os = .windows,
            .arch = .x86_64,
            .url = "b",
            .sha256 = sha_b,
            .path = "bin\\SNEK.EXE",
        },
    };
    try expectRendered(
        \\{
        \\    "version": "0.2.0-rc.1",
        \\    "description": "A \"typed\" CLI kit #1 \\ it's fast",
        \\    "homepage": "https://github.com/93ams/snek",
        \\    "license": "MIT",
        \\    "architecture": {
        \\        "64bit": {
        \\            "url": "b",
        \\            "hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\            "bin": [["bin\\SNEK.EXE", "snek"]]
        \\        },
        \\        "arm64": {
        \\            "url": "a",
        \\            "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\            "bin": [["snek-arm64.exe", "snek"]]
        \\        }
        \\    }
        \\}
        \\
    , writeScoop, .{package});
}

test "winget: one zip with a nested executable, one bare binary" {
    var package = example;
    package.publisher = "93ams";
    package.assets = &.{
        .{
            .os = .windows,
            .arch = .x86_64,
            .url = "https://x.test/snek-windows-x86_64.zip",
            .sha256 = sha_d,
            .path = "snek.exe",
        },
        .{
            .os = .windows,
            .arch = .aarch64,
            .url = "https://x.test/snek-arm64.exe",
            .sha256 = sha_a,
            .path = "snek-arm64.exe",
        },
    };
    try expectRendered(
        \\# yaml-language-server: $schema=https://aka.ms/winget-manifest.singleton.1.6.0.schema.json
        \\PackageIdentifier: 93ams.snek
        \\PackageVersion: "0.2.0-rc.1"
        \\PackageLocale: en-US
        \\Publisher: "93ams"
        \\PackageName: "snek"
        \\License: "MIT"
        \\ShortDescription: "A \"typed\" CLI kit #1 \\ it's fast"
        \\PackageUrl: "https://github.com/93ams/snek"
        \\Installers:
        \\  - Architecture: x64
        \\    InstallerType: zip
        \\    NestedInstallerType: portable
        \\    NestedInstallerFiles:
        \\      - RelativeFilePath: "snek.exe"
        \\        PortableCommandAlias: "snek"
        \\    InstallerUrl: "https://x.test/snek-windows-x86_64.zip"
        \\    InstallerSha256: DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD
        \\  - Architecture: arm64
        \\    InstallerType: portable
        \\    Commands:
        \\      - "snek"
        \\    InstallerUrl: "https://x.test/snek-arm64.exe"
        \\    InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        \\ManifestType: singleton
        \\ManifestVersion: 1.6.0
        \\
    , writeWinget, .{package});
}

test "winget: the publisher is one identifier segment" {
    var sink: Writer.Discarding = .init(&.{});
    var package = example;
    for ([_][]const u8{ "", "93.ams", "a b", "a/b", &@as([33]u8, @splat('x')) }) |publisher| {
        package.publisher = publisher;
        try testing.expectError(error.InvalidField, writeWinget(&sink.writer, package));
    }
    package.publisher = "93ams";
    try writeWinget(&sink.writer, package);
    package.assets = example.assets[0..1];
    try testing.expectError(error.NoAssets, writeWinget(&sink.writer, package));
}

test "pkgbuild: quoting, pkgver, one install line" {
    try expectRendered(
        \\pkgname=snek
        \\pkgver=0.2.0_rc.1
        \\pkgrel=1
        \\pkgdesc='A "typed" CLI kit #1 \ it'\''s fast'
        \\arch=('x86_64')
        \\url='https://github.com/93ams/snek'
        \\license=('MIT')
        \\source_x86_64=('https://x.test/snek-linux-x86_64.tar.gz')
        \\sha256sums_x86_64=('cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc')
        \\
        \\package() {
        \\  install -Dm755 "$srcdir"/'snek' "$pkgdir"/usr/bin/'snek'
        \\}
        \\
    , writePkgbuild, .{example});
}

test "pkgbuild: per-architecture paths use a case on CARCH" {
    var package = example;
    package.release = 3;
    package.assets = &.{
        .{
            .os = .linux,
            .arch = .aarch64,
            .url = "u1",
            .sha256 = sha_a,
            .path = "snek-aarch64",
        },
        .{
            .os = .linux,
            .arch = .x86_64,
            .url = "u2",
            .sha256 = sha_b,
            .path = "snek-x86_64",
        },
    };
    try expectRendered(
        \\pkgname=snek
        \\pkgver=0.2.0_rc.1
        \\pkgrel=3
        \\pkgdesc='A "typed" CLI kit #1 \ it'\''s fast'
        \\arch=('x86_64' 'aarch64')
        \\url='https://github.com/93ams/snek'
        \\license=('MIT')
        \\source_x86_64=('u2')
        \\sha256sums_x86_64=('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
        \\source_aarch64=('u1')
        \\sha256sums_aarch64=('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
        \\
        \\package() {
        \\  case "$CARCH" in
        \\    x86_64)
        \\      install -Dm755 "$srcdir"/'snek-x86_64' "$pkgdir"/usr/bin/'snek'
        \\      ;;
        \\    aarch64)
        \\      install -Dm755 "$srcdir"/'snek-aarch64' "$pkgdir"/usr/bin/'snek'
        \\      ;;
        \\  esac
        \\}
        \\
    , writePkgbuild, .{package});
}

test "debian: control file with version mapping and folded description" {
    try expectRendered(
        \\Package: snek
        \\Version: 0.2.0~rc.1-1
        \\Section: utils
        \\Priority: optional
        \\Architecture: amd64
        \\Maintainer: Ann Example <ann@example.com>
        \\Homepage: https://github.com/93ams/snek
        \\Description: A "typed" CLI kit #1 \ it's fast
        \\
    , writeDebianControl, .{ example, Arch.x86_64 });
}

test "debian: build metadata keeps its hyphens, only the pre-release dash maps" {
    var package = example;
    package.version = "1.0.0+build-7";
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeDebianVersion(&out.writer, package.version);
    try testing.expectEqualStrings("1.0.0+build-7", out.written());
    out.clearRetainingCapacity();
    try debianFolded(&out.writer, "summary\nmore\n\nend");
    try testing.expectEqualStrings(" summary\n more\n .\n end\n", out.written());
}

test "every generator rejects a bad description" {
    var sink: Writer.Discarding = .init(&.{});
    const w = &sink.writer;
    var package = example;

    package.name = "Snek";
    try testing.expectError(error.InvalidName, writeHomebrew(w, package));
    package.name = "s";
    try testing.expectError(error.InvalidName, writeScoop(w, package));
    package = example;
    package.version = "1:2.0";
    try testing.expectError(error.InvalidVersion, writePkgbuild(w, package));
    package = example;
    package.description = "two\nlines";
    try testing.expectError(error.InvalidField, writeHomebrew(w, package));
    package = example;
    try testing.expectError(error.NoAssets, writeDebianControl(w, package, .aarch64));
    package.maintainer = "";
    try testing.expectError(error.InvalidField, writeDebianControl(w, package, .x86_64));
    package = example;
    package.assets = &.{.{
        .os = .linux,
        .arch = .x86_64,
        .url = "u",
        .sha256 = "zz",
        .path = "p",
    }};
    try testing.expectError(error.InvalidChecksum, writePkgbuild(w, package));
    package.assets = &.{
        .{
            .os = .linux,
            .arch = .x86_64,
            .url = "u",
            .sha256 = sha_a,
            .path = "p",
        },
        .{
            .os = .linux,
            .arch = .x86_64,
            .url = "v",
            .sha256 = sha_b,
            .path = "p",
        },
    };
    try testing.expectError(error.DuplicateTarget, writePkgbuild(w, package));
    package.assets = &.{.{
        .os = .windows,
        .arch = .x86_64,
        .url = "u",
        .sha256 = sha_a,
        .path = "p",
    }};
    try testing.expectError(error.NoAssets, writeHomebrew(w, package));
    try testing.expectError(error.NoAssets, writePkgbuild(w, package));
    package.assets = &.{.{
        .os = .linux,
        .arch = .x86_64,
        .url = "u",
        .sha256 = sha_a,
        .path = "p",
    }};
    try testing.expectError(error.NoAssets, writeScoop(w, package));
}
