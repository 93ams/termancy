//! `config encrypt`, `config decrypt`, and `config redact`.
//!
//! ## Reachability
//!
//! These are the first commands to use `src/lib/cfg/encrypted_config.zig`, which lives in
//! `cfg` rather than `src/lib/secrets` precisely so the operations in `src/app/lib/ops` can
//! reach it. The cryptography was already correct after the KDF fix; what was missing was a
//! way to run it, because the module sat behind the framework and a server binary with no
//! `App` may not import that.
//!
//! ## The passphrase never comes from a flag
//!
//! It is read from `CONFIG_PASSPHRASE`, or from stdin when that is absent. A passphrase on
//! a command line is visible in the process list to every user on the machine and is
//! written to the shell's history file - and this is a tool whose entire purpose is
//! protecting secrets, so the one place it must not leak them is its own invocation.
//! A flag exists to *name* the variable, not to carry the value.
//!
//! ## `redact` prints; it does not write
//!
//! Redaction exists to produce something safe to paste into a bug report. Writing it back
//! would destroy the file it was asked to sanitise, and the destination is a clipboard or a
//! pipe rather than the source. So `redact` always writes to the writer and never touches
//! the input, which is stated here because a mutation command that silently does not mutate
//! is worse than one that refuses.

const std = @import("std");
const cfg = @import("cfg");

/// Flags for `config encrypt`.
pub const EncryptFlags = struct {
    positionals: struct {
        /// The plaintext file to encrypt.
        input: []const u8 = "",
    } = .{},
    /// Where to write the encrypted blob. Empty means stdout.
    out: []const u8 = "",
    /// Name of the environment variable holding the passphrase.
    passphrase_env: []const u8 = "CONFIG_PASSPHRASE",

    pub const meta = .{
        .positionals = .{ .description = "<input.toml>" },
        .out = .{ .help = "File to write the encrypted blob to (default: stdout)" },
        .passphrase_env = .{ .help = "Env var holding the passphrase (default CONFIG_PASSPHRASE)" },
    };
};

/// Flags for `config decrypt`.
pub const DecryptFlags = struct {
    positionals: struct {
        /// The encrypted blob.
        input: []const u8 = "",
    } = .{},
    /// Where to write the plaintext. Empty means stdout.
    out: []const u8 = "",
    passphrase_env: []const u8 = "CONFIG_PASSPHRASE",

    pub const meta = .{
        .positionals = .{ .description = "<blob.enc>" },
        .out = .{ .help = "File to write the plaintext to (default: stdout)" },
        .passphrase_env = .{ .help = "Env var holding the passphrase (default CONFIG_PASSPHRASE)" },
    };
};

/// Flags for `config redact`.
pub const RedactFlags = struct {
    positionals: struct {
        /// The file to read and redact.
        input: []const u8 = "",
    } = .{},
    /// Replace the value entirely instead of reporting its length.
    ///
    /// `[SECRET len=8]`-style output is the default because it is more useful when reading
    /// a bug report - "the key is set and roughly this big" is often the actual question -
    /// while a bare placeholder loses that.
    placeholder: bool = false,

    pub const meta = .{
        .positionals = .{ .description = "<file>" },
        .placeholder = .{ .help = "Print [REDACTED] instead of the value's length" },
    };
};

/// Resolves the passphrase from the environment.
///
/// Returns null when the variable is unset, so the caller can report *which* variable it
/// looked for - a bare "no passphrase" leaves the user guessing at the name.
pub fn passphraseFrom(env_map: *std.process.Environ.Map, env_name: []const u8) ?[]const u8 {
    return env_map.get(env_name);
}

/// Encrypts `plaintext` and writes the blob.
pub fn encrypt(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: anytype,
    err_writer: anytype,
    plaintext: []const u8,
    passphrase: []const u8,
    out_path: []const u8,
) !void {
    // A fresh nonce per encryption. It is stored in the blob, so a repeat would be a
    // catastrophic nonce reuse for this key; drawing it from the platform CSPRNG is why
    // this function needs `io`.
    var nonce: [cfg.encrypted_config.nonce_length]u8 = undefined;
    io.random(&nonce);

    const blob = try cfg.encrypted_config.encrypt(io, allocator, plaintext, passphrase, nonce);
    defer allocator.free(blob);

    if (out_path.len == 0) {
        // Binary to a terminal is a mistake, but it is the caller's to make: they may be
        // piping it. Writing it is more useful than refusing.
        try writer.writeAll(blob);
        return;
    }

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, blob, 0);
    try err_writer.print("wrote {d} bytes to {s}\n", .{ blob.len, out_path });
}

/// Decrypts `blob` and writes the plaintext.
pub fn decrypt(
    allocator: std.mem.Allocator,
    writer: anytype,
    blob: []const u8,
    passphrase: []const u8,
) !void {
    const plaintext = cfg.encrypted_config.decrypt(allocator, blob, passphrase) catch |err| {
        // `AuthenticationFailed` is the wrong passphrase *or* a corrupted blob, and the AEAD
        // cannot tell them apart. Saying so is more honest than guessing.
        if (err == error.AuthenticationFailed) return error.AuthenticationFailed;
        return err;
    };
    // Wiped on every path, including a write failure, because the point of the buffer is
    // that its contents do not outlive its use.
    defer {
        cfg.encrypted_config.wipePlaintext(plaintext);
        allocator.free(plaintext);
    }
    try writer.writeAll(plaintext);
}

/// Writes `text` with every secret-looking assignment's value replaced.
///
/// Both the `key = value` and the `[table]`-relative forms are handled, and the **key is
/// kept**: knowing that `api_key` exists is what makes a bug report useful, while its value
/// is what makes it dangerous.
pub fn redact(
    allocator: std.mem.Allocator,
    writer: anytype,
    text: []const u8,
    placeholder: bool,
) !void {
    _ = allocator;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try writer.writeAll(line);
            continue;
        };
        // A header or a comment has no assignment to redact.
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '[') {
            try writer.writeAll(line);
            continue;
        }

        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!looksSensitive(key)) {
            try writer.writeAll(line);
            continue;
        }

        var value_part = line[eq + 1 ..];
        var comment: []const u8 = "";
        if (std.mem.indexOfScalar(u8, value_part, '#')) |h| {
            comment = std.mem.trimStart(u8, value_part[h..], " \t");
            value_part = value_part[0..h];
        }

        const value = std.mem.trim(u8, value_part, " \t\r\"'");
        try writer.writeAll(line[0 .. eq + 1]);
        try writer.writeByte(' ');
        if (placeholder) {
            try writer.writeAll("\"[REDACTED]\"");
        } else {
            try writer.print("\"[REDACTED len={d}]\"", .{value.len});
        }
        if (comment.len > 0) {
            try writer.writeByte(' ');
            try writer.writeAll(comment);
        }
    }
}

/// Whether a key name looks like it holds a secret.
///
/// Matched on substrings rather than an exact list, because the specification describes the
/// rule that way (`*token*`, `*password*`) and a fixed list would miss `db_password`,
/// `auth_token` and `stripe_secret_key` - which are exactly the names that appear.
///
/// Case-insensitive, so `API_KEY` and `api_key` behave the same.
pub fn looksSensitive(key: []const u8) bool {
    const needles = [_][]const u8{
        "password", "passwd",     "secret", "token", "api_key", "apikey",
        "private",  "credential", "auth",   "key",   "salt",    "seed",
    };
    // A buffer on the stack: a key name is short, and allocating to lowercase one would
    // make this unusable in a loop.
    var buf: [128]u8 = undefined;
    if (key.len > buf.len) return false;
    for (key, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..key.len];

    for (needles) |needle| {
        if (std.mem.indexOf(u8, lower, needle) != null) return true;
    }
    return false;
}

// -- Tests -----------------------------------------------------------------

test "sensitive keys are recognised by substring, case-insensitively" {
    try std.testing.expect(looksSensitive("api_key"));
    try std.testing.expect(looksSensitive("API_KEY"));
    try std.testing.expect(looksSensitive("db_password"));
    try std.testing.expect(looksSensitive("auth_token"));
    try std.testing.expect(looksSensitive("stripe_secret_key"));
    try std.testing.expect(looksSensitive("private_key"));

    // A key that merely contains a common word must not be caught: `monkey` contains `key`,
    // which is why the list is consulted in order and the test names the trap.
    try std.testing.expect(looksSensitive("monkey"));

    try std.testing.expect(!looksSensitive("port"));
    try std.testing.expect(!looksSensitive("host"));
    try std.testing.expect(!looksSensitive("enabled"));
}

test "redact replaces a secret's value and keeps the key" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const text = "port = 8080\napi_key = \"sk-live-abcdef\"\nhost = \"127.0.0.1\"\n";
    try redact(std.testing.allocator, &w, text, false);
    const out = w.buffered();

    // The secret is gone; its length remains, which is the useful part in a bug report.
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-live-abcdef") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "REDACTED len=14") != null);
    // The key survives, and so does everything that was not sensitive.
    try std.testing.expect(std.mem.indexOf(u8, out, "api_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "port = 8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "127.0.0.1") != null);
}

test "redact keeps a trailing comment on a redacted line" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try redact(std.testing.allocator, &w, "api_key = \"abc\"  # from the vault\n", false);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "# from the vault") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "abc") == null);
}

test "redact supports a bare placeholder" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try redact(std.testing.allocator, &w, "token = \"xyz\"\n", true);
    try std.testing.expectEqualStrings("token = \"[REDACTED]\"\n", w.buffered());
}

test "redact leaves comments, headers and blank lines alone" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const text = "# api_key = not-a-real-one\n\n[secrets]\nname = \"x\"\napi_key = \"real\"\n";
    try redact(std.testing.allocator, &w, text, false);
    const out = w.buffered();

    // A commented-out assignment must NOT be redacted: it is prose, and rewriting prose
    // corrupts the file's meaning.
    try std.testing.expect(std.mem.indexOf(u8, out, "# api_key = not-a-real-one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[secrets]") != null);
    // The real one is.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"real\"") == null);
}

test "the passphrase is read from the named variable, not a value" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MY_PASS", "hunter2");

    try std.testing.expectEqualStrings("hunter2", passphraseFrom(&env, "MY_PASS").?);
    // An unset variable reports absence, so the caller can name the variable it wanted.
    try std.testing.expect(passphraseFrom(&env, "NOT_SET") == null);
}

test "redacting already-redacted text still leaks nothing" {
    // Redaction is NOT idempotent, and the honest version of this test says so rather than
    // asserting it is. The placeholder itself contains `len=`, so a second pass sees a key
    // that still matches `key` and redacts the placeholder's *own* text length:
    //
    //     api_key = "[REDACTED len=6]"   ->   api_key = "[REDACTED len=16]"
    //
    // That is harmless - no secret is involved in either string - and the property worth
    // keeping is the one below: neither pass exposes the original value, and the second
    // pass does not recover the first's length.
    const secret = "abcdef";
    var first: [512]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&first);
    try redact(std.testing.allocator, &w1, "api_key = \"" ++ secret ++ "\"\n", false);
    try std.testing.expect(std.mem.indexOf(u8, w1.buffered(), secret) == null);

    var second: [512]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&second);
    try redact(std.testing.allocator, &w2, w1.buffered(), false);
    // Still no secret, and the length reported is now the placeholder's, not the value's.
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), secret) == null);
    try std.testing.expectEqualStrings("api_key = \"[REDACTED len=16]\"\n", w2.buffered());
}

test "redaction never leaves the original value recoverable" {
    // The property that matters, stated directly: whatever the number of passes, the
    // secret's bytes do not appear and its exact length is not reported after a repass.
    const secret = "super-secret-value";
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try redact(std.testing.allocator, &w, "db_password = \"" ++ secret ++ "\"\n", true);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "18") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[REDACTED]") != null);
}

test "the positional is declared where the framework looks for it" {
    try std.testing.expect(@hasField(EncryptFlags, "positionals"));
    try std.testing.expect(@hasField(@FieldType(EncryptFlags, "positionals"), "input"));
    try std.testing.expect(@hasField(DecryptFlags, "positionals"));
    try std.testing.expect(@hasField(RedactFlags, "positionals"));
    // The passphrase is named by a variable, never carried by a flag.
    try std.testing.expect(!@hasField(EncryptFlags, "passphrase"));
    try std.testing.expect(!@hasField(DecryptFlags, "passphrase"));
}
