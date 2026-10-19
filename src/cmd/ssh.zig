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
    .passphrase = .{ .help = "Encrypt (or decrypt) the key with this passphrase; better given through " ++
        "$TERMANCY_PASSPHRASE", .secret = true },
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
    .passphrase = .{ .help = "Encrypt (or decrypt) the key with this passphrase; better given through " ++
        "$TERMANCY_PASSPHRASE", .secret = true },
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
    .passphrase = .{ .help = "Encrypt (or decrypt) the key with this passphrase; better given through " ++
        "$TERMANCY_PASSPHRASE", .secret = true },
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
    .passphrase = .{ .help = "Encrypt (or decrypt) the key with this passphrase; better given through " ++
        "$TERMANCY_PASSPHRASE", .secret = true },
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
    .passphrase = .{ .help = "Encrypt (or decrypt) the key with this passphrase; better given through " ++
        "$TERMANCY_PASSPHRASE", .secret = true },
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
        for (allowed) |a| if (a.key.eql(key)) {
            // An allowed_signers line names its principals before the key.
            const who = if (a.comment.len > 0) a.comment else a.options;
            try ctx.out.print("good signature by {s} ({s})\n", .{ who, key.fingerprint(&fp) });
            return;
        };
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
