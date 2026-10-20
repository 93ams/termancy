//! `termancy ssh`: Ed25519 keys made, shown, kept as words and restored from them (as
//! Charm's keygen and melt), files signed and checked as `ssh-keygen -Y` does, and
//! commands run on other machines, as `ssh host command`.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const sys = @import("sys");
const keys = sys.ssh.keys;
const mnemonic = sys.mnemonic;
const Io = std.Io;

/// What every `--passphrase` means; each command spells it the same.
const passphrase_spec: field.Field([]const u8) = .{
    .help = "Encrypt (or decrypt) the key with this passphrase; better given through " ++
        "$TERMANCY_PASSPHRASE",
    .secret = true,
};

const KeygenFlags = struct {
    file: []const u8 = "id_ed25519",
    comment: ?[]const u8 = null,
    passphrase: []const u8 = "",
    rounds: u32 = 16,
    force: bool = false,
};
const keygen_flags = cli.flags(KeygenFlags, field.Set(.{field.Spec(KeygenFlags){ .fields = .{
    .file = .{ .help = "Where to write the private key (the public one gets .pub)" },
    .comment = .{ .help = "The key's comment (default: user@host)" },
    .passphrase = passphrase_spec,
    .rounds = .{ .help = "bcrypt rounds for the passphrase", .checks = &.{.min(1)} },
    .force = .{ .help = "Replace a key already there" },
} }}), .{ .fields = .{
    .file = .{ .short = 'f' },
    .comment = .{ .short = 'C' },
    .passphrase = .{ .env = "TERMANCY_PASSPHRASE" },
    .rounds = .{ .short = 'a' },
} });

const FileFlags = struct {
    passphrase: []const u8 = "",
};
const file_flags = cli.flags(FileFlags, field.Set(.{field.Spec(FileFlags){ .fields = .{
    .passphrase = passphrase_spec,
} }}), .{ .fields = .{
    .passphrase = .{ .env = "TERMANCY_PASSPHRASE" },
} });

const RestoreFlags = struct {
    file: []const u8 = "id_ed25519",
    comment: []const u8 = "",
    passphrase: []const u8 = "",
    force: bool = false,
};
const restore_flags = cli.flags(RestoreFlags, field.Set(.{field.Spec(RestoreFlags){ .fields = .{
    .file = .{ .help = "Where to write the private key (the public one gets .pub)" },
    .comment = .{ .help = "The key's comment" },
    .passphrase = passphrase_spec,
    .force = .{ .help = "Replace a key already there" },
} }}), .{ .fields = .{
    .file = .{ .short = 'f' },
    .comment = .{ .short = 'C' },
    .passphrase = .{ .env = "TERMANCY_PASSPHRASE" },
} });

const SignFlags = struct {
    key: []const u8,
    namespace: []const u8 = "file",
    passphrase: []const u8 = "",
};
const sign_flags = cli.flags(SignFlags, field.Set(.{field.Spec(SignFlags){ .fields = .{
    .key = .{ .help = "The private key to sign with" },
    .namespace = .{ .help = "What the signature is for (file, git, email...)" },
    .passphrase = passphrase_spec,
} }}), .{ .fields = .{
    .key = .{ .short = 'k' },
    .namespace = .{ .short = 'n' },
    .passphrase = .{ .env = "TERMANCY_PASSPHRASE" },
} });

const VerifyFlags = struct {
    signature: ?[]const u8 = null,
    signers: ?[]const u8 = null,
    namespace: []const u8 = "file",
};
const verify_flags = cli.flags(VerifyFlags, field.Set(.{field.Spec(VerifyFlags){ .fields = .{
    .signature = .{ .help = "The signature (default: <file>.sig)" },
    .signers = .{ .help = "Trust only the keys in this file (authorized_keys or " ++
        "allowed_signers form)" },
    .namespace = .{ .help = "What the signature must be for" },
} }}), .{ .fields = .{
    .signature = .{ .short = 's' },
    .namespace = .{ .short = 'n' },
} });

const RunFlags = struct {
    identity: ?[]const u8 = null,
    port: u16 = 22,
    known_hosts: ?[]const u8 = null,
    accept_new: bool = false,
    passphrase: []const u8 = "",
};
const run_flags = cli.flags(RunFlags, field.Set(.{field.Spec(RunFlags){ .fields = .{
    .identity = .{ .help = "The Ed25519 private key to log in with, " ++
        "tried before the agent's (default: ~/.ssh/id_ed25519, after them)" },
    .port = .{ .help = "The server's port" },
    .known_hosts = .{ .help = "The host keys to trust (default: ~/.ssh/known_hosts)" },
    .accept_new = .{ .help = "Trust and record the key of a host not yet known; a " ++
        "changed key is still refused" },
    .passphrase = passphrase_spec,
} }}), .{ .fields = .{
    .identity = .{ .short = 'i' },
    .port = .{ .short = 'p' },
    .passphrase = .{ .env = "TERMANCY_PASSPHRASE" },
} });

pub const command = cli.command(.{
    .name = "ssh",
    .summary = "SSH: run commands remotely; keys: make, show, back up as words, sign, verify",
    .subcommands = .{
        cli.command(.{
            .name = "run",
            .summary = "Run a command on another machine, as ssh host command",
            .description =
            \\Connect to the host, check its key against known_hosts, log in (with -i's key,
            \\then the Ed25519 keys of the ssh-agent at $SSH_AUTH_SOCK, or on Windows of
            \\OpenSSH's agent when it is not set, then ~/.ssh/id_ed25519; or as anyone, when
            \\the server allows it), run the command after --, and show its output; termancy ends
            \\with the command's exit status (255 when it has none). Standard input is not
            \\sent (as ssh -n). A host not in known_hosts is refused unless --accept-new,
            \\which records it; a changed key is always refused.
            ,
            .args = .{
                .min = 1,
                .max = 1,
                .usage = "[user@]host -- command...",
                .passthrough = true,
            },
            .flags = run_flags,
            .examples =
            \\termancy ssh run alice@example.com -- uname -a
            \\termancy ssh run -p 2222 -i deploy_key --accept-new localhost -- uptime
            ,
            .run = runRemote,
        }),
        cli.command(.{
            .name = "keygen",
            .summary = "Make an Ed25519 key pair, as ssh-keygen -t ed25519",
            .flags = keygen_flags,
            .examples =
            \\termancy ssh keygen -f ~/.ssh/id_ed25519
            \\TERMANCY_PASSPHRASE=... termancy ssh keygen -f deploy_key -C deploy
            ,
            .run = keygen,
        }),
        cli.command(.{
            .name = "fingerprint",
            .summary = "Show the fingerprints of public or private keys",
            .args = .{ .min = 1, .max = null, .usage = "<key>..." },
            .flags = file_flags,
            .run = fingerprint,
        }),
        cli.command(.{
            .name = "melt",
            .summary = "Show an Ed25519 private key as 24 words, to write down",
            .description =
            \\Print the key's seed (the whole private key) as 24 BIP 39 words, as Charm's melt
            \\does. Anyone with the words has the key: keep them as you would the key. Restore
            \\the key with `termancy ssh restore`.
            ,
            .args = .{ .min = 1, .max = 1, .usage = "<private key>" },
            .flags = file_flags,
            .run = melt,
        }),
        cli.command(.{
            .name = "restore",
            .summary = "Remake a private key from its 24 words (read from standard input)",
            .flags = restore_flags,
            .examples =
            \\termancy ssh restore -f id_ed25519 < words.txt
            ,
            .run = restore,
        }),
        cli.command(.{
            .name = "sign",
            .summary = "Sign files, as ssh-keygen -Y sign (writes <file>.sig)",
            .args = .{ .min = 1, .max = null, .usage = "<file>..." },
            .flags = sign_flags,
            .run = sign,
        }),
        cli.command(.{
            .name = "verify",
            .summary = "Check a file's signature, as ssh-keygen -Y verify",
            .description =
            \\Check that <file>.sig (or --signature) signs the file in the namespace, and
            \\print the signer's fingerprint. With --signers, the signer must also be one of
            \\the keys in that file; without it, any valid signature passes, so check the
            \\fingerprint printed.
            ,
            .args = .{ .min = 1, .max = 1, .usage = "<file>" },
            .flags = verify_flags,
            .run = verify,
        }),
    },
});

fn readFile(ctx: *cli.Context, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 << 20)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return ctx.fail("{s}: {s}", .{ path, @errorName(err) });
    };
}

fn readPrivate(
    ctx: *cli.Context,
    path: []const u8,
    passphrase: []const u8,
    comment: ?*[]const u8,
) !keys.KeyPair {
    const text = try readFile(ctx, path);
    return keys.KeyPair.readPrivate(
        ctx.gpa,
        text,
        passphrase,
        comment,
        ctx.arena,
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PassphraseNeeded => ctx.fail(
            "{s}: encrypted; give the passphrase in $TERMANCY_PASSPHRASE",
            .{path},
        ),
        error.WrongPassphrase => ctx.fail("{s}: wrong passphrase", .{path}),
        error.UnsupportedKey => ctx.fail("{s}: only Ed25519 private keys are supported", .{path}),
        error.InvalidKey => ctx.fail("{s}: not an OpenSSH private key", .{path}),
    };
}

/// Writes the key pair to `path` (owner-only) and `path.pub`, and prints the fingerprint.
fn writePair(
    ctx: *cli.Context,
    kp: keys.KeyPair,
    path: []const u8,
    comment: []const u8,
    passphrase: []const u8,
    rounds: u32,
    force: bool,
) !void {
    const cwd = Io.Dir.cwd();
    if (!force) {
        if (cwd.access(ctx.io, path, .{})) |_| {
            return ctx.fail("{s} exists (--force replaces it)", .{path});
        } else |_| {}
    }
    var private: Io.Writer.Allocating = .init(ctx.arena);
    try kp.writePrivate(ctx.gpa, ctx.io, &private.writer, comment, passphrase, rounds);
    const blob = kp.publicBlob();
    const public_key = keys.PublicKey.parse(&blob) catch unreachable;
    var public: Io.Writer.Allocating = .init(ctx.arena);
    try public_key.writeLine(&public.writer, comment);
    try public.writer.writeByte('\n');
    const pub_path = try std.fmt.allocPrint(ctx.arena, "{s}.pub", .{path});
    sys.files.writeAtomic(ctx.io, cwd, path, private.written(), .{
        .permissions = sys.files.private_file,
    }) catch |err|
        return ctx.fail("{s}: {s}", .{ path, @errorName(err) });
    sys.files.writeAtomic(ctx.io, cwd, pub_path, public.written(), .{}) catch |err|
        return ctx.fail("{s}: {s}", .{ pub_path, @errorName(err) });
    var fp: [50]u8 = undefined;
    const line = public.written()[0 .. public.written().len - 1];
    try ctx.out.print("{s}\n{s} {s}\n", .{ line, public_key.fingerprint(&fp), path });
}

/// The machine's name, as `ssh-keygen` puts it in a comment; "localhost" when unknown.
fn hostName(ctx: *cli.Context, buffer: *[256]u8) []const u8 {
    const os = @import("builtin").os.tag;
    if (os == .windows) return ctx.environ.get("COMPUTERNAME") orelse "localhost";
    if (os == .wasi) return "localhost";
    return std.posix.gethostname(buffer[0..std.posix.HOST_NAME_MAX]) catch "localhost";
}

fn keygen(ctx: *cli.Context, flags: KeygenFlags) !void {
    const comment = flags.comment orelse comment: {
        const user = ctx.environ.get("USER") orelse ctx.environ.get("USERNAME") orelse "user";
        var host_buffer: [256]u8 = undefined;
        const host = hostName(ctx, &host_buffer);
        break :comment try std.fmt.allocPrint(ctx.arena, "{s}@{s}", .{ user, host });
    };
    try writePair(
        ctx,
        .generate(ctx.io),
        flags.file,
        comment,
        flags.passphrase,
        flags.rounds,
        flags.force,
    );
}

fn fingerprint(ctx: *cli.Context, flags: FileFlags) !void {
    for (ctx.args) |path| {
        const text = try readFile(ctx, path);
        var fp: [50]u8 = undefined;
        if (std.mem.indexOf(u8, text, "PRIVATE KEY") != null) {
            var comment: []const u8 = "";
            const kp = try readPrivate(ctx, path, flags.passphrase, &comment);
            const blob = kp.publicBlob();
            const key = keys.PublicKey.parse(&blob) catch unreachable;
            try ctx.out.print("{s} {s} ({s})\n", .{ key.fingerprint(&fp), comment, path });
            continue;
        }
        const list = try keys.parseAuthorizedKeys(ctx.arena, text);
        if (list.len == 0) return ctx.fail("{s}: no public keys", .{path});
        for (list) |entry| try ctx.out.print("{s} {s} ({s})\n", .{
            entry.key.fingerprint(&fp),
            entry.comment,
            entry.key.algorithm(),
        });
    }
}

fn melt(ctx: *cli.Context, flags: FileFlags) !void {
    const kp = try readPrivate(ctx, ctx.args[0], flags.passphrase, null);
    var seed = kp.seed();
    defer std.crypto.secureZero(u8, &seed);
    var words: [24][]const u8 = undefined;
    const list = mnemonic.encode(&seed, &words);
    for (list, 0..) |word, i| {
        try ctx.out.writeAll(word);
        try ctx.out.writeByte(if (i % 6 == 5) '\n' else ' ');
    }
}

fn restore(ctx: *cli.Context, flags: RestoreFlags) !void {
    const stdin = Io.File.stdin();
    var buffer: [1024]u8 = undefined;
    var reader = stdin.readerStreaming(ctx.io, &buffer);
    const words = reader.interface.allocRemaining(ctx.arena, .limited(4096)) catch |err|
        return ctx.fail("standard input: {s}", .{@errorName(err)});
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    mnemonic.decode(words, &seed) catch |err| return ctx.fail("{s}", .{switch (err) {
        error.UnknownWord => "a word is not on the BIP 39 list",
        error.WrongLength => "give the key's 24 words",
        error.BadChecksum => "the words do not check out: one is wrong, or out of order",
    }});
    try writePair(
        ctx,
        .fromSeed(seed),
        flags.file,
        flags.comment,
        flags.passphrase,
        16,
        flags.force,
    );
}

fn sign(ctx: *cli.Context, flags: SignFlags) !void {
    const kp = try readPrivate(ctx, flags.key, flags.passphrase, null);
    for (ctx.args) |path| {
        const data = try readFile(ctx, path);
        var out: Io.Writer.Allocating = .init(ctx.arena);
        try keys.signMessage(ctx.gpa, &out.writer, kp, flags.namespace, data);
        const sig_path = try std.fmt.allocPrint(ctx.arena, "{s}.sig", .{path});
        sys.files.writeAtomic(ctx.io, Io.Dir.cwd(), sig_path, out.written(), .{}) catch |err|
            return ctx.fail("{s}: {s}", .{ sig_path, @errorName(err) });
        try ctx.err.print("wrote {s}\n", .{sig_path});
    }
}

fn verify(ctx: *cli.Context, flags: VerifyFlags) !void {
    const path = ctx.args[0];
    const data = try readFile(ctx, path);
    const sig_path = flags.signature orelse try std.fmt.allocPrint(ctx.arena, "{s}.sig", .{path});
    const armored = try readFile(ctx, sig_path);
    const signer = keys.verifySignedMessage(
        ctx.gpa,
        armored,
        flags.namespace,
        data,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSignature => return ctx.fail(
            "{s}: the signature does not match (or is for another namespace)",
            .{path},
        ),
        error.UnsupportedKey => return ctx.fail(
            "{s}: signed with a key of a kind not supported",
            .{sig_path},
        ),
        else => return ctx.fail("{s}: not an SSH signature", .{sig_path}),
    };
    const key = signer.key() orelse
        return ctx.fail("{s}: the signing key is too large", .{sig_path});
    var fp: [50]u8 = undefined;
    if (flags.signers) |signers_path| {
        const allowed = try keys.parseAuthorizedKeys(ctx.arena, try readFile(ctx, signers_path));
        const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
        // As ssh-keygen -Y verify: any line for the key whose options allow it will do.
        var refused: ?SignerError = null;
        for (allowed) |a| if (a.key.eql(key)) {
            const signer_line = parseSigner(a);
            checkSigner(signer_line.options, flags.namespace, now) catch |err| {
                refused = err;
                continue;
            };
            try ctx.out.print("good signature by {s} ({s})\n", .{
                signer_line.principals,
                key.fingerprint(&fp),
            });
            return;
        };
        if (refused) |err| return ctx.fail("{s}: signed by {s}, but {s} {s}", .{
            path,
            key.fingerprint(&fp),
            signers_path,
            switch (err) {
                error.CertAuthority => "trusts it only as a certificate authority, " ++
                    "and certificates are not supported",
                error.UnknownOption => "gives it an option allowed_signers does not have",
                error.InvalidTime => "gives it a valid-after or valid-before that is not a time",
                error.WrongNamespace => "does not allow it this namespace",
                error.NotYetValid => "does not allow it yet (valid-after)",
                error.Expired => "no longer allows it (valid-before)",
            },
        });
        return ctx.fail("{s}: signed by {s}, which is not in {s}", .{
            path,
            key.fingerprint(&fp),
            signers_path,
        });
    }
    try ctx.out.print(
        "good signature by {s} (not checked against a list of signers)\n",
        .{key.fingerprint(&fp)},
    );
}

/// An allowed_signers line: `principals [options] key`. An authorized_keys line (no
/// principals, a comment after the key) names the signer by its comment instead.
const SignerLine = struct { principals: []const u8, options: []const u8 };

fn parseSigner(a: keys.Authorized) SignerLine {
    if (a.comment.len > 0 and a.options.len == 0) return .{ .principals = a.comment, .options = "" };
    var i: usize = 0;
    var quoted = false;
    while (i < a.options.len and (quoted or (a.options[i] != ' ' and a.options[i] != '\t'))) : (i += 1) {
        if (a.options[i] == '"') quoted = !quoted;
    }
    return .{
        .principals = std.mem.trim(u8, a.options[0..i], "\""),
        .options = std.mem.trim(u8, a.options[i..], " \t"),
    };
}

const SignerError = error{
    CertAuthority,
    UnknownOption,
    InvalidTime,
    WrongNamespace,
    NotYetValid,
    Expired,
};

/// Whether an allowed_signers line's `options` let its key sign in `namespace` at `now`
/// (seconds since the epoch), as ssh-keygen -Y verify decides: `namespaces="a,b*"`
/// (patterns, `!` to exclude), `valid-after=` and `valid-before=` (YYYYMMDD[HHMM[SS]][Z]).
/// `cert-authority` and unknown options refuse, as certificates are not supported.
fn checkSigner(options: []const u8, namespace: []const u8, now: i64) SignerError!void {
    var i: usize = 0;
    while (i < options.len) {
        const start = i;
        var quoted = false;
        while (i < options.len and (quoted or options[i] != ',')) : (i += 1) {
            if (options[i] == '"') quoted = !quoted;
        }
        const option = options[start..i];
        i += 1;
        const eq = std.mem.indexOfScalar(u8, option, '=');
        const name = option[0 .. eq orelse option.len];
        const value = if (eq) |e| std.mem.trim(u8, option[e + 1 ..], "\"") else "";
        if (std.ascii.eqlIgnoreCase(name, "cert-authority") and eq == null) {
            return error.CertAuthority;
        } else if (eq == null) {
            return error.UnknownOption;
        } else if (std.ascii.eqlIgnoreCase(name, "namespaces")) {
            if (!patternListMatches(value, namespace)) return error.WrongNamespace;
        } else if (std.ascii.eqlIgnoreCase(name, "valid-after")) {
            const t = try parseTime(value);
            // shortcut: a time without Z is local time, unknown here; it is taken at the
            // latest it can be (UTC-12), so it never lets in what ssh-keygen keeps out.
            // Upgrade if the time zone becomes readable.
            if (now < t.seconds + @as(i64, if (t.utc) 0 else 12 * 3600)) return error.NotYetValid;
        } else if (std.ascii.eqlIgnoreCase(name, "valid-before")) {
            const t = try parseTime(value);
            // Likewise taken at the earliest (UTC+14) without Z.
            if (now > t.seconds - @as(i64, if (t.utc) 0 else 14 * 3600)) return error.Expired;
        } else return error.UnknownOption;
    }
}

/// Whether a comma-separated pattern list takes `text`: a pattern matches and no `!`
/// pattern does, as OpenSSH's match_pattern_list (case kept).
fn patternListMatches(list: []const u8, text: []const u8) bool {
    var matched = false;
    var patterns = std.mem.splitScalar(u8, list, ',');
    while (patterns.next()) |pattern| {
        if (pattern.len > 0 and pattern[0] == '!') {
            if (glob(pattern[1..], text)) return false;
        } else if (glob(pattern, text)) matched = true;
    }
    return matched;
}

/// `*` (any run) and `?` (one byte) wildcards.
fn glob(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '*') {
        for (0..text.len + 1) |i| if (glob(pattern[1..], text[i..])) return true;
        return false;
    }
    if (text.len == 0 or (pattern[0] != '?' and pattern[0] != text[0])) return false;
    return glob(pattern[1..], text[1..]);
}

/// YYYYMMDD, YYYYMMDDHHMM, or YYYYMMDDHHMMSS, then Z for UTC: seconds since the epoch,
/// as if UTC.
fn parseTime(text: []const u8) error{InvalidTime}!struct { seconds: i64, utc: bool } {
    const utc = std.mem.endsWith(u8, text, "Z") or std.mem.endsWith(u8, text, "z");
    const digits = if (utc) text[0 .. text.len - 1] else text;
    if (digits.len != 8 and digits.len != 12 and digits.len != 14) return error.InvalidTime;
    var fields: [6]u32 = .{ 0, 0, 0, 0, 0, 0 };
    for (&fields, 0..) |*f, n| {
        const at = if (n == 0) 0 else 2 + 2 * n;
        const len: usize = if (n == 0) 4 else 2;
        if (at + len > digits.len) break;
        f.* = std.fmt.parseInt(u32, digits[at..][0..len], 10) catch return error.InvalidTime;
    }
    const year, const month, const day, const hour, const minute, const second = fields;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59)
        return error.InvalidTime;
    // Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return .{ .seconds = days * 86400 + hour * 3600 + minute * 60 + second, .utc = utc };
}

test parseTime {
    try std.testing.expectEqual(0, (try parseTime("19700101Z")).seconds);
    try std.testing.expectEqual(951782400, (try parseTime("20000229Z")).seconds);
    const full = try parseTime("20300102030405Z");
    try std.testing.expectEqual(1893553445, full.seconds);
    try std.testing.expect(full.utc);
    try std.testing.expect(!(try parseTime("203001020304")).utc);
    try std.testing.expectError(error.InvalidTime, parseTime("2030"));
    try std.testing.expectError(error.InvalidTime, parseTime("20301301Z"));
    try std.testing.expectError(error.InvalidTime, parseTime("2030010x"));
}

test checkSigner {
    const now = (try parseTime("20260601Z")).seconds;
    try checkSigner("", "file", now);
    try checkSigner("namespaces=\"git,file\"", "file", now);
    try checkSigner("namespaces=\"f*\"", "file", now);
    try std.testing.expectError(error.WrongNamespace, checkSigner("namespaces=\"git\"", "file", now));
    try std.testing.expectError(error.WrongNamespace, checkSigner("namespaces=\"*,!file\"", "file", now));
    try checkSigner("valid-after=\"20260101Z\",valid-before=\"20270101Z\"", "file", now);
    try std.testing.expectError(error.NotYetValid, checkSigner("valid-after=20260602Z", "file", now));
    try std.testing.expectError(error.Expired, checkSigner("valid-before=20260531Z", "file", now));
    // Local times are taken at their strictest.
    try std.testing.expectError(error.NotYetValid, checkSigner("valid-after=20260601", "file", now));
    try checkSigner("valid-after=20260531", "file", now);
    try std.testing.expectError(error.Expired, checkSigner("valid-before=20260601", "file", now));
    try std.testing.expectError(error.InvalidTime, checkSigner("valid-before=soon", "file", now));
    try std.testing.expectError(error.CertAuthority, checkSigner("cert-authority", "file", now));
    try std.testing.expectError(error.UnknownOption, checkSigner("from=\"10.0.0.1\"", "file", now));
    try std.testing.expectError(error.UnknownOption, checkSigner("restrict", "file", now));
}

fn runRemote(ctx: *cli.Context, flags: RunFlags) !void {
    const target = ctx.args[0];
    const at = std.mem.lastIndexOfScalar(u8, target, '@');
    const host = if (at) |i| target[i + 1 ..] else target;
    const user = if (at) |i| target[0..i] else ctx.environ.get("USER") orelse
        ctx.environ.get("USERNAME") orelse return ctx.fail("give the user: user@host", .{});
    if (ctx.passthrough.len == 0) return ctx.fail("give the command after --", .{});
    const remote_command = try std.mem.join(ctx.arena, " ", ctx.passthrough);
    const home = ctx.environ.get("HOME") orelse ctx.environ.get("USERPROFILE") orelse "";
    const known_path = flags.known_hosts orelse
        try std.fs.path.join(ctx.arena, &.{ home, ".ssh", "known_hosts" });
    // An agent that cannot be reached is passed over, as ssh does.
    const agent_path = ctx.environ.get("SSH_AUTH_SOCK") orelse sys.ssh.Agent.default_path;
    const agent: ?*sys.ssh.Agent = if (agent_path) |sock|
        sys.ssh.Agent.connect(ctx.gpa, ctx.io, sock) catch null
    else
        null;
    defer if (agent) |a| a.close();
    var identity: ?keys.KeyPair = null;
    var default_identity: ?keys.KeyPair = null;
    if (flags.identity) |path| {
        identity = try readPrivate(ctx, path, flags.passphrase, null);
    } else {
        const path = try std.fs.path.join(ctx.arena, &.{ home, ".ssh", "id_ed25519" });
        if (Io.Dir.cwd().access(ctx.io, path, .{})) |_| {
            // With an agent (which likely holds it), a key that will not open is skipped.
            default_identity = if (agent == null)
                try readPrivate(ctx, path, flags.passphrase, null)
            else
                keys.KeyPair.readPrivate(
                    ctx.gpa,
                    try readFile(ctx, path),
                    flags.passphrase,
                    null,
                    ctx.arena,
                ) catch |err| if (err == error.OutOfMemory) return err else null;
        } else |_| {}
    }
    var verifier: sys.ssh.known_hosts.Verifier = .{
        .gpa = ctx.gpa,
        .io = ctx.io,
        .path = known_path,
        .host = host,
        .port = flags.port,
        .policy = if (flags.accept_new) .accept_new else .strict,
    };
    const known = try verifier.read();
    defer ctx.gpa.free(known);
    var preference: [8][]const u8 = undefined;
    const stream = sys.ssh.connection.dial(ctx.io, host, flags.port) catch |err|
        return ctx.fail("{s}:{d}: {s}", .{ host, flags.port, @errorName(err) });
    const client = sys.ssh.Client.connect(ctx.gpa, ctx.io, stream, .{
        .user = user,
        .identity = identity,
        .agent = agent,
        .default_identity = default_identity,
        .verify_host_key = sys.ssh.known_hosts.Verifier.check,
        .context = &verifier,
        .host_key_algorithms = sys.ssh.known_hosts.algorithms(
            known,
            host,
            flags.port,
            &sys.ssh.transport.host_key_algorithms,
            &preference,
        ),
    }) catch |err| return switch (err) {
        error.HostKeyRejected => switch (verifier.found) {
            .unknown => ctx.fail(
                "{s}: unknown host key {s}; check it, then run again with --accept-new " ++
                    "to record it in {s}",
                .{ host, verifier.fingerprint, known_path },
            ),
            .changed => ctx.fail(
                "{s}: the host key changed (now {s}): someone may be in between. If the " ++
                    "change is expected, remove the old key from {s}",
                .{ host, verifier.fingerprint, known_path },
            ),
            .revoked => ctx.fail("{s}: the host key {s} is revoked", .{
                host,
                verifier.fingerprint,
            }),
            .known => ctx.fail("{s}: cannot read {s}", .{ host, known_path }),
        },
        error.AuthenticationFailed => ctx.fail("{s}@{s}: login refused", .{ user, host }),
        else => ctx.fail("{s}: {s}", .{ host, @errorName(err) }),
    };
    defer client.close();
    if (verifier.added) ctx.warn("added {s} ({s}) to {s}", .{
        host,
        verifier.fingerprint,
        known_path,
    });
    const session = client.session() catch |err|
        return ctx.fail("{s}: no session: {s}", .{ host, @errorName(err) });
    defer session.close();
    session.exec(remote_command) catch |err|
        return ctx.fail("{s}: cannot run the command: {s}", .{ host, @errorName(err) });
    session.closeInput();
    while (true) switch (try session.read(.none)) {
        .data => |d| {
            try ctx.out.writeAll(d);
            try ctx.out.flush();
        },
        .stderr => |d| {
            try ctx.err.writeAll(d);
            try ctx.err.flush();
        },
        .closed => break,
        else => {},
    };
    const status = session.exitStatus() orelse 255;
    if (status != 0) return ctx.exit(@truncate(@min(status, 255)));
}

test "verify --signers enforces a signer's namespaces and validity" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(dir);
    const join = struct {
        fn f(d: []const u8, name: []const u8) ![]u8 {
            return std.fs.path.join(testing.allocator, &.{ d, name });
        }
    }.f;
    const key = try join(dir, "k");
    defer gpa.free(key);
    const file = try join(dir, "f");
    defer gpa.free(file);
    const signers = try join(dir, "signers");
    defer gpa.free(signers);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "data" });
    const app: cli.App = .{ .root = &@import("../main.zig").root, .completion_command = false };

    const made = try cli.testing.run(app, &.{ "ssh", "keygen", "-f", key, "-C", "a" }, .{});
    defer made.deinit();
    try testing.expectEqual(0, made.status);
    const signed = try cli.testing.run(app, &.{ "ssh", "sign", "-k", key, file }, .{});
    defer signed.deinit();
    try testing.expectEqual(0, signed.status);
    const public = try tmp.dir.readFileAlloc(testing.io, "k.pub", gpa, .unlimited);
    defer gpa.free(public);

    const args = [_][]const u8{ "ssh", "verify", "--signers", signers, file };
    const plain = try std.fmt.allocPrint(gpa, "alice {s}", .{public});
    defer gpa.free(plain);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "signers", .data = plain });
    const good = try cli.testing.run(app, &args, .{});
    defer good.deinit();
    try testing.expectEqual(0, good.status);

    const git_only = try std.fmt.allocPrint(gpa, "alice namespaces=\"git\" {s}", .{public});
    defer gpa.free(git_only);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "signers", .data = git_only });
    const refused = try cli.testing.run(app, &args, .{});
    defer refused.deinit();
    try testing.expectEqual(1, refused.status);
    try testing.expect(std.mem.endsWith(u8, refused.err, "does not allow it this namespace\n"));

    const lines = try std.fmt.allocPrint(
        gpa,
        "alice valid-before=\"20000101Z\" {s}bob namespaces=\"git,file\" {s}",
        .{ public, public },
    );
    defer gpa.free(lines);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "signers", .data = lines });
    const second = try cli.testing.run(app, &args, .{});
    defer second.deinit();
    try testing.expectEqual(0, second.status);
    try testing.expect(std.mem.startsWith(u8, second.out, "good signature by bob ("));

    const ca = try std.fmt.allocPrint(gpa, "alice cert-authority {s}", .{public});
    defer gpa.free(ca);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "signers", .data = ca });
    const as_ca = try cli.testing.run(app, &args, .{});
    defer as_ca.deinit();
    try testing.expectEqual(1, as_ca.status);
}
