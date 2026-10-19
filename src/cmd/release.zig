//! `termancy release`: the publishing side of `sys.update`. Signing keys and
//! signatures in the form `update.verifySignature` checks, and package-manager manifests
//! from a release's checksum file.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const sys = @import("sys");

const Ed25519 = std.crypto.sign.Ed25519;
const base64 = std.base64.standard;
const manifests = sys.manifests;
const update = sys.update;

/// Where `sign` reads the secret key when `--key` is not given, so CI can pass it as a
/// secret without writing it to disk.
const key_variable = "TERMANCY_SIGNING_KEY";

pub const command = cli.command(.{
    .name = "release",
    .summary = "Sign release assets and write package manifests",
    .description =
    \\Tools for publishing releases that sys.update installs: an Ed25519 signing key,
    \\a signature beside each asset (<asset>.sig, base64), and Homebrew, Scoop, and Arch
    \\Linux manifests generated from the release's SHA256SUMS.
    ,
    .subcommands = .{ keygen, sign, verify, manifest },
});

const keygen = cli.command(.{
    .name = "keygen",
    .summary = "Make a signing key",
    .description =
    \\Write a new Ed25519 secret key to <file>, readable only by its owner, and print the
    \\public key, base64, for the program that verifies updates (update.Options.public_key).
    \\Refuses to replace a file that exists. Keep the secret key out of the repository; in
    \\CI, pass its contents in $TERMANCY_SIGNING_KEY.
    ,
    .args = .{ .min = 1, .max = 1, .usage = "<file>" },
    .examples =
    \\termancy release keygen release.key
    ,
    .run = runKeygen,
});

fn runKeygen(ctx: *cli.Context) !void {
    const path = ctx.args[0];
    const pair = Ed25519.KeyPair.generate(ctx.io);
    var seed = pair.secret_key.seed();
    defer std.crypto.secureZero(u8, &seed);
    var text: [base64.Encoder.calcSize(Ed25519.KeyPair.seed_length) + 1]u8 = undefined;
    _ = base64.Encoder.encode(text[0 .. text.len - 1], &seed);
    text[text.len - 1] = '\n';
    defer std.crypto.secureZero(u8, &text);
    const file = std.Io.Dir.cwd().createFile(ctx.io, path, .{
        .exclusive = true,
        .permissions = sys.files.private_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return ctx.fail("{s}: exists; not replacing a key", .{path}),
        else => return ctx.fail("{s}: cannot create: {t}", .{ path, err }),
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, &text) catch |err| {
        return ctx.fail("{s}: cannot write: {t}", .{ path, err });
    };
    try writeBase64Line(ctx.out, &pair.public_key.toBytes());
}

const SignFlags = struct {
    key: ?[]const u8 = null,
};
const sign_flags = cli.flags(SignFlags, field.Set(.{field.Spec(SignFlags){ .fields = .{
    .key = .{ .help = "The secret key file (default: $TERMANCY_SIGNING_KEY)" },
} }}), .{ .fields = .{
    .key = .{ .value_name = "file" },
} });

const sign = cli.command(.{
    .name = "sign",
    .summary = "Sign release assets",
    .description =
    \\Sign each <file> with the Ed25519 secret key and write the signature, base64, to
    \\<file>.sig, which sys.update downloads and checks when a public key is set.
    ,
    .flags = sign_flags,
    .args = .{ .min = 1, .max = null, .usage = "<file>..." },
    .examples =
    \\termancy release sign --key release.key termancy-linux-x86_64.tar.gz
    \\TERMANCY_SIGNING_KEY=... termancy release sign *.tar.gz *.zip
    ,
    .run = runSign,
});

fn runSign(ctx: *cli.Context, flags: SignFlags) !void {
    const text = if (flags.key) |path|
        try readFile(ctx, path, .limited(1024))
    else
        ctx.environ.get(key_variable) orelse
            return ctx.usageError("no key: pass --key or set ${s}", .{key_variable});
    const pair = parseSecretKey(text) orelse {
        return ctx.fail("{s}: not a signing key made by keygen", .{flags.key orelse
            "$" ++ key_variable});
    };
    for (ctx.args) |path| {
        const data = try readFile(ctx, path, .unlimited);
        const signature = try pair.sign(data, null);
        var line: std.Io.Writer.Allocating = .init(ctx.arena);
        try writeBase64Line(&line.writer, &signature.toBytes());
        const sig_path = try std.fmt.allocPrint(ctx.arena, "{s}.sig", .{path});
        const written = std.Io.Dir.cwd().writeFile(ctx.io, .{
            .sub_path = sig_path,
            .data = line.written(),
        });
        written catch |err| return ctx.fail("{s}: cannot write: {t}", .{ sig_path, err });
        try ctx.out.print("{s}\n", .{sig_path});
    }
}

/// A secret key file: the base64 Ed25519 seed on one line.
fn parseSecretKey(text: []const u8) ?Ed25519.KeyPair {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    const size = base64.Decoder.calcSizeForSlice(trimmed) catch return null;
    if (size != seed.len) return null;
    base64.Decoder.decode(&seed, trimmed) catch return null;
    return Ed25519.KeyPair.generateDeterministic(seed) catch null;
}

const VerifyFlags = struct {
    public_key: []const u8 = "",
};
const verify_flags = cli.flags(VerifyFlags, field.Set(.{field.Spec(VerifyFlags){ .fields = .{
    .public_key = .{ .help = "The public key keygen printed (base64)" },
} }}), .{ .fields = .{
    .public_key = .{ .value_name = "key" },
} });

const verify = cli.command(.{
    .name = "verify",
    .summary = "Check release assets against their signatures",
    .description =
    \\Check each <file> against <file>.sig with the public key, as sys.update does
    \\before it installs. Exit status 1 when any signature is missing or does not verify.
    ,
    .flags = verify_flags,
    .args = .{ .min = 1, .max = null, .usage = "<file>..." },
    .examples =
    \\termancy release verify --public-key MCowBQ... termancy-linux-x86_64.tar.gz
    ,
    .run = runVerify,
});

fn runVerify(ctx: *cli.Context, flags: VerifyFlags) !void {
    if (flags.public_key.len == 0) return ctx.usageError("--public-key is required", .{});
    var key: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    const trimmed = std.mem.trim(u8, flags.public_key, " \t\r\n");
    const size = base64.Decoder.calcSizeForSlice(trimmed) catch 0;
    if (size != key.len) return ctx.usageError("--public-key: not a base64 Ed25519 key", .{});
    base64.Decoder.decode(&key, trimmed) catch {
        return ctx.usageError("--public-key: not a base64 Ed25519 key", .{});
    };
    var failed = false;
    for (ctx.args) |path| {
        const data = try readFile(ctx, path, .unlimited);
        const sig_path = try std.fmt.allocPrint(ctx.arena, "{s}.sig", .{path});
        const cwd = std.Io.Dir.cwd();
        const signature = cwd.readFileAlloc(ctx.io, sig_path, ctx.arena, .limited(1024)) catch null;
        if (update.verifySignature(key, signature, data)) {
            try ctx.out.print("{s}: OK\n", .{path});
        } else |err| {
            failed = true;
            try ctx.out.print("{s}: {s}\n", .{ path, switch (err) {
                error.SignatureMissing => "no signature",
                error.SignatureInvalid => "BAD SIGNATURE",
                error.InvalidPublicKey => "invalid public key",
            } });
        }
    }
    if (failed) return ctx.fail("verification failed", .{});
}

const Format = enum { homebrew, scoop, winget, pkgbuild };

const ManifestFlags = struct {
    format: Format = .homebrew,
    sums: []const u8 = "SHA256SUMS",
    url: []const u8 = "",
    version: []const u8 = "",
    name: []const u8 = "termancy",
    description: []const u8 = "Build command-line tools in Zig",
    homepage: []const u8 = "https://github.com/93ams/termancy",
    license: []const u8 = "MIT",
    publisher: []const u8 = "93ams",
};
const manifest_flags = cli.flags(ManifestFlags, field.Set(.{field.Spec(ManifestFlags){ .fields = .{
    .format = .{ .help = "The package manager" },
    .sums = .{ .help = "The checksum file listing the assets" },
    .url = .{ .help = "Where the assets are downloaded from, without the file name" },
    .version = .{ .help = "The version released, without v" },
    .name = .{ .help = "The package and command name" },
    .description = .{ .help = "One line for listings" },
    .homepage = .{ .help = "The project's home page" },
    .license = .{ .help = "SPDX license identifier" },
    .publisher = .{ .help = "winget's publisher, the first part of the package identifier" },
} }}), .{ .fields = .{
    .format = .{ .short = 'f' },
    .sums = .{ .value_name = "file" },
} });

const manifest = cli.command(.{
    .name = "manifest",
    .summary = "Write a package manifest from a checksum file",
    .description =
    \\Print a Homebrew formula, Scoop or winget manifest, or Arch PKGBUILD for the assets
    \\listed in --sums. An asset's OS and CPU come from its name (termancy-linux-x86_64.tar.gz,
    \\termancy-windows-aarch64.zip); its download is --url joined with the name. An archive is
    \\taken to hold the executable at its top level, named --name (with .exe on Windows).
    ,
    .flags = manifest_flags,
    .examples =
    \\termancy release manifest -f homebrew --version 0.3.0 \
    \\    --url https://github.com/93ams/termancy/releases/download/v0.3.0 > termancy.rb
    ,
    .run = runManifest,
});

fn runManifest(ctx: *cli.Context, flags: ManifestFlags) !void {
    if (flags.url.len == 0 or flags.version.len == 0) {
        return ctx.usageError("--url and --version are required", .{});
    }
    const sums = try readFile(ctx, flags.sums, .limited(1 << 20));
    const assets = try assetsFrom(ctx.arena, sums, flags.url, flags.name);
    const package: manifests.Package = .{
        .name = flags.name,
        .version = std.mem.trimStart(u8, flags.version, "v"),
        .description = flags.description,
        .homepage = flags.homepage,
        .license = flags.license,
        .publisher = flags.publisher,
        .assets = assets,
    };
    const result = switch (flags.format) {
        .homebrew => manifests.writeHomebrew(ctx.out, package),
        .scoop => manifests.writeScoop(ctx.out, package),
        .winget => manifests.writeWinget(ctx.out, package),
        .pkgbuild => manifests.writePkgbuild(ctx.out, package),
    };
    result catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.NoAssets => {
            return ctx.fail("{s} lists no asset for {t}", .{ flags.sums, flags.format });
        },
        else => return ctx.fail("cannot write the manifest: {t}", .{err}),
    };
}

/// The assets of a checksum file whose names say which OS and CPU they are for.
fn assetsFrom(
    arena: std.mem.Allocator,
    sums: []const u8,
    url: []const u8,
    name: []const u8,
) ![]const manifests.Asset {
    var assets: std.ArrayList(manifests.Asset) = .empty;
    const base = std.mem.trimEnd(u8, url, "/");
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const hex = fields.next() orelse continue;
        const file = std.mem.trimStart(u8, fields.rest(), "*");
        if (file.len == 0) continue;
        const os, const arch = targetOf(file) orelse continue;
        const archive = update.packagingOf(file) != .bare;
        const path = if (!archive)
            file
        else if (os == .windows)
            try std.fmt.allocPrint(arena, "{s}.exe", .{name})
        else
            name;
        try assets.append(arena, .{
            .os = os,
            .arch = arch,
            .url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, file }),
            .sha256 = hex,
            .path = path,
        });
    }
    return assets.items;
}

/// The OS and CPU an asset name spells, with the words `update.selectAsset` knows.
fn targetOf(file: []const u8) ?struct { manifests.Os, manifests.Arch } {
    var os: ?manifests.Os = null;
    var arch: ?manifests.Arch = null;
    var words = std.mem.tokenizeAny(u8, file, "-.");
    while (words.next()) |word| {
        for (update.Naming.default_os_names) |entry| for (entry.names) |spelling| {
            if (!std.ascii.eqlIgnoreCase(word, spelling)) continue;
            os = switch (entry.os) {
                .linux => .linux,
                .macos => .macos,
                .windows => .windows,
                else => os,
            };
        };
        for (update.Naming.default_arch_names) |entry| for (entry.names) |spelling| {
            if (!std.ascii.eqlIgnoreCase(word, spelling)) continue;
            arch = switch (entry.arch) {
                .x86_64 => .x86_64,
                .aarch64 => .aarch64,
                else => arch,
            };
        };
    }
    return .{ os orelse return null, arch orelse return null };
}

fn readFile(ctx: *cli.Context, path: []const u8, limit: std.Io.Limit) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, limit) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => ctx.fail("{s}: cannot read: {t}", .{ path, err }),
    };
}

fn writeBase64Line(w: *std.Io.Writer, bytes: []const u8) !void {
    try base64.Encoder.encodeWriter(w, bytes);
    try w.writeByte('\n');
}

const testing = std.testing;

fn termancy(args: []const []const u8, env: []const [2][]const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{ .env = env });
}

test "keygen, sign, verify: what sys.update accepts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(dir);
    const key = try std.fs.path.join(gpa, &.{ dir, "release.key" });
    defer gpa.free(key);
    const asset = try std.fs.path.join(gpa, &.{ dir, "app-linux-x86_64.tar.gz" });
    defer gpa.free(asset);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app-linux-x86_64.tar.gz", .data = "NEW" });

    const made = try termancy(&.{ "release", "keygen", key }, &.{});
    defer made.deinit();
    try testing.expectEqual(0, made.status);
    const public = std.mem.trimEnd(u8, made.out, "\n");
    const again = try termancy(&.{ "release", "keygen", key }, &.{});
    defer again.deinit();
    try testing.expectEqual(1, again.status);

    const signed = try termancy(&.{ "release", "sign", "--key", key, asset }, &.{});
    defer signed.deinit();
    try testing.expectEqual(0, signed.status);

    // The library's check accepts the signature.
    const sig_name = "app-linux-x86_64.tar.gz.sig";
    const signature = try tmp.dir.readFileAlloc(testing.io, sig_name, gpa, .unlimited);
    defer gpa.free(signature);
    var raw_key: [32]u8 = undefined;
    try base64.Decoder.decode(&raw_key, public);
    try update.verifySignature(raw_key, signature, "NEW");

    const verify_args = [_][]const u8{
        "release", "verify", "--public-key", public, asset,
    };
    const good = try termancy(&verify_args, &.{});
    defer good.deinit();
    try testing.expectEqual(0, good.status);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app-linux-x86_64.tar.gz", .data = "EVIL" });
    const bad = try termancy(&verify_args, &.{});
    defer bad.deinit();
    try testing.expectEqual(1, bad.status);
    try testing.expect(std.mem.endsWith(u8, bad.out, ": BAD SIGNATURE\n"));

    // The key can come from the environment instead of a file.
    const secret = try tmp.dir.readFileAlloc(testing.io, "release.key", gpa, .unlimited);
    defer gpa.free(secret);
    const sign_args = [_][]const u8{ "release", "sign", asset };
    const from_env = try termancy(&sign_args, &.{.{ key_variable, secret }});
    defer from_env.deinit();
    try testing.expectEqual(0, from_env.status);
    const missing = try termancy(&sign_args, &.{});
    defer missing.deinit();
    try testing.expectEqual(2, missing.status);
}

test "assetsFrom reads OS, CPU, and the executable's path from names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sums =
        \\aaaa  termancy-linux-x86_64.tar.gz
        \\bbbb *termancy-windows-arm64.zip
        \\cccc  termancy-darwin-aarch64
        \\dddd  termancy-freebsd-x86_64.tar.gz
        \\eeee  SHA256SUMS.sig
        \\
    ;
    const assets = try assetsFrom(arena.allocator(), sums, "https://dl/v1/", "termancy");
    try testing.expectEqual(3, assets.len);
    try testing.expectEqual(manifests.Os.linux, assets[0].os);
    try testing.expectEqualStrings("https://dl/v1/termancy-linux-x86_64.tar.gz", assets[0].url);
    try testing.expectEqualStrings("termancy", assets[0].path);
    try testing.expectEqual(manifests.Arch.aarch64, assets[1].arch);
    try testing.expectEqualStrings("termancy.exe", assets[1].path);
    try testing.expectEqualStrings("bbbb", assets[1].sha256);
    try testing.expectEqual(manifests.Os.macos, assets[2].os);
    try testing.expectEqualStrings("termancy-darwin-aarch64", assets[2].path);
}
