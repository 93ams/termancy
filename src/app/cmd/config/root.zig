//! `app/cfg/cmd` - the `App.command` registrations over `app/cfg/lib/ops`.
//!
//! Each command is **thin by design**: parse flags, call an operation, render.
//! Anything that decides *what* the answer is belongs in `ops/`, so it can be called
//! without the framework. If a file in this folder grows logic that does not touch
//! `cli.Ctx`, that logic is in the wrong folder.
//!
//! ## Why the command *declarations* are here
//!
//! `AppT.command(meta, run)` needs `AppT`, and `AppT` is `Commands(App, ConfigT)`'s
//! first parameter - so the registration can only happen inside this file, which is
//! where the app is known. (An earlier version of this comment blamed a name collision
//! with a field called `command`; there is no such field, and the real reason is the
//! one above.)
//!
//! The split is therefore: each child file owns its **flags** (and any positional
//! arguments) and its **`run` body** - both `AppT`-independent and independently
//! testable - and this file owns the **metadata** and the registration, where `AppT`
//! is known.

const std = @import("std");
const cli = @import("framework");
const cfg = @import("cfg");
const ops = @import("../../lib/ops/root.zig");

/// `config export`'s flags and body.
pub const exporter = @import("exporter.zig");
/// `config dry-run`'s flags and body.
pub const dry_run = @import("dry_run.zig");
/// `config inspect`'s flags and body.
pub const inspect = @import("inspect.zig");
/// `config schema`'s flags and body.
pub const schema = @import("schema.zig");
/// `config get`'s flags and body.
pub const get = @import("get.zig");
/// `config keys`'s flags and body.
pub const keys = @import("keys.zig");
/// `config cast`'s flags and body.
pub const cast = @import("cast.zig");
/// `config set` / `config del`'s flags and bodies.
pub const mutate = @import("mutate.zig");
/// `config format` / `config profile`'s flags and bodies.
pub const profiles_cmd = @import("profiles.zig");
/// `config encrypt` / `decrypt` / `redact`'s flags and bodies.
pub const secrets_cmd = @import("secrets.zig");

/// Builds the `config` command group for `AppT`, over `ConfigT`.
///
/// ## Why `ConfigT` is a parameter
///
/// The commands are defined over a *configuration type*, not over an app. Every
/// binary has its own config, and `app/kvs` and `app/scp` have no `cli.App` at all -
/// which is why the operations live in `ops/` and can be called without one.
pub fn Commands(comptime AppT: type, comptime ConfigT: type) type {
    return struct {
        /// Flags for bare `config`.
        pub const ConfigFlags = struct {};

        /// `config export`
        pub const export_cmd = AppT.command(.{
            .name = "export",
            .description = "Write the resolved configuration as environment variables",
            .flags = exporter.ExportFlags,
        }, exportRun);

        /// `config dry-run`
        pub const dry_run_cmd = AppT.command(.{
            .name = "dry-run",
            .aliases = &.{"dryrun"},
            .description = "Validate configuration overrides without applying them",
            .flags = dry_run.DryRunFlags,
        }, dryRunRun);

        /// `config inspect`
        pub const inspect_cmd = AppT.command(.{
            .name = "inspect",
            .description = "Explain where a configuration value came from",
            .flags = inspect.InspectFlags,
        }, inspectRun);

        /// `config schema`
        pub const schema_cmd = AppT.command(.{
            .name = "schema",
            .description = "Emit a JSON Schema for the configuration",
            .flags = schema.SchemaFlags,
        }, schemaRun);

        /// `config get`
        pub const get_cmd = AppT.command(.{
            .name = "get",
            .description = "Print one configuration value",
            .flags = get.GetFlags,
        }, getRun);

        /// `config keys`
        pub const keys_cmd = AppT.command(.{
            .name = "keys",
            .description = "List the configuration's key paths, one per line",
            .flags = keys.KeysFlags,
        }, keysRun);

        /// `config cast`
        pub const cast_cmd = AppT.command(.{
            .name = "cast",
            .description = "Coerce a value into a named type",
            .flags = cast.CastFlags,
        }, castRun);

        /// `config set`
        pub const set_cmd = AppT.command(.{
            .name = "set",
            .description = "Set a key in a TOML file",
            .flags = mutate.SetFlags,
        }, setRun);

        /// `config del`
        pub const del_cmd = AppT.command(.{
            .name = "del",
            .aliases = &.{"delete"},
            .description = "Remove a key from a TOML file",
            .flags = mutate.DelFlags,
        }, delRun);

        /// `config format`
        pub const format_cmd = AppT.command(.{
            .name = "format",
            .description = "Normalise whitespace in a TOML file",
            .flags = profiles_cmd.FormatFlags,
        }, formatRun);

        /// `config profile`
        pub const profile_cmd = AppT.command(.{
            .name = "profile",
            .description = "List or switch configuration contexts",
            .flags = profiles_cmd.ProfileFlags,
        }, profileRun);

        /// `config encrypt`
        pub const encrypt_cmd = AppT.command(.{
            .name = "encrypt",
            .description = "Encrypt a configuration file at rest",
            .flags = secrets_cmd.EncryptFlags,
        }, encryptRun);

        /// `config decrypt`
        pub const decrypt_cmd = AppT.command(.{
            .name = "decrypt",
            .description = "Decrypt an encrypted configuration blob",
            .flags = secrets_cmd.DecryptFlags,
        }, decryptRun);

        /// `config redact`
        pub const redact_cmd = AppT.command(.{
            .name = "redact",
            .description = "Print a config with sensitive values replaced",
            .flags = secrets_cmd.RedactFlags,
        }, redactRun);

        /// The `config` command itself.
        pub const config = AppT.command(.{
            .name = "config",
            .description = "Inspect, validate and export the configuration",
            .flags = ConfigFlags,
            .subcommands = .{
                export_cmd,
                dry_run_cmd,
                inspect_cmd,
                schema_cmd,
                get_cmd,
                keys_cmd,
                cast_cmd,
                set_cmd,
                del_cmd,
                format_cmd,
                profile_cmd,
                encrypt_cmd,
                decrypt_cmd,
                redact_cmd,
            },
        }, configRun);

        fn encryptRun(ctx: AppT.Ctx, flags: AppT.Flags(secrets_cmd.EncryptFlags)) !void {
            const pass = secrets_cmd.passphraseFrom(ctx.env_map, flags.passphrase_env) orelse {
                try ctx.err.print("no passphrase: set ${s}\n", .{flags.passphrase_env});
                return error.MissingRequiredFlag;
            };
            const plain = try std.Io.Dir.cwd().readFileAlloc(ctx.io, flags.positionals.input, ctx.allocator, .limited(1 << 24));
            defer ctx.allocator.free(plain);
            try secrets_cmd.encrypt(ctx.io, ctx.allocator, ctx.out, ctx.err, plain, pass, flags.out);
        }

        fn decryptRun(ctx: AppT.Ctx, flags: AppT.Flags(secrets_cmd.DecryptFlags)) !void {
            const pass = secrets_cmd.passphraseFrom(ctx.env_map, flags.passphrase_env) orelse {
                try ctx.err.print("no passphrase: set ${s}\n", .{flags.passphrase_env});
                return error.MissingRequiredFlag;
            };
            const blob = try std.Io.Dir.cwd().readFileAlloc(ctx.io, flags.positionals.input, ctx.allocator, .limited(1 << 24));
            defer ctx.allocator.free(blob);
            secrets_cmd.decrypt(ctx.allocator, ctx.out, blob, pass) catch |err| {
                // Every failure is mapped into the framework''s error set, which has neither
                // `AuthenticationFailed` nor the allocation errors `decrypt` can raise. The
                // message is the part a user acts on; returning `err` unchanged made this
                // function''s inferred set wider than `AppError` and failed to compile.
                switch (err) {
                    error.AuthenticationFailed => try ctx.err.writeAll(
                        "decryption failed: wrong passphrase, or the file is corrupted\n",
                    ),
                    error.InvalidEncryptedPayload => try ctx.err.writeAll(
                        "not an encrypted configuration blob\n",
                    ),
                    else => try ctx.err.print("decryption failed: {s}\n", .{@errorName(err)}),
                }
                return error.InvalidFormat;
            };
        }

        fn redactRun(ctx: AppT.Ctx, flags: AppT.Flags(secrets_cmd.RedactFlags)) !void {
            const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, flags.positionals.input, ctx.allocator, .limited(1 << 24));
            defer ctx.allocator.free(text);
            try secrets_cmd.redact(ctx.allocator, ctx.out, text, flags.placeholder);
        }

        fn formatRun(ctx: AppT.Ctx, flags: AppT.Flags(profiles_cmd.FormatFlags)) !void {
            try profiles_cmd.formatFile(ctx.allocator, ctx.io, ctx.out, ctx.err, flags.file, .{
                .file = flags.file,
                .sort = flags.sort,
                .dry_run = flags.dry_run,
                .no_align = flags.no_align,
            });
        }

        fn profileRun(ctx: AppT.Ctx, flags: AppT.Flags(profiles_cmd.ProfileFlags)) !void {
            try profiles_cmd.profile(ctx.allocator, ctx.io, ctx.out, ctx.err, flags.file, .{
                .positionals = .{
                    .action = flags.positionals.action,
                    .name = flags.positionals.name,
                },
                .file = flags.file,
            });
        }

        fn setRun(ctx: AppT.Ctx, flags: AppT.Flags(mutate.SetFlags)) !void {
            try mutate.setFile(
                ctx.allocator,
                ctx.io,
                ctx.out,
                ctx.err,
                flags.positionals.path,
                flags.positionals.value,
                flags.file,
                flags.string,
            );
        }

        fn delRun(ctx: AppT.Ctx, flags: AppT.Flags(mutate.DelFlags)) !void {
            try mutate.delFile(
                ctx.allocator,
                ctx.io,
                ctx.out,
                ctx.err,
                flags.positionals.path,
                flags.file,
            );
        }

        fn castRun(ctx: AppT.Ctx, flags: AppT.Flags(cast.CastFlags)) !void {
            try cast.run(ctx.allocator, ctx.out, ctx.err, ctx.env_map, ConfigT, .{
                .positionals = .{
                    .path = flags.positionals.path,
                    .type_name = flags.positionals.type_name,
                },
            });
        }

        fn getRun(ctx: AppT.Ctx, flags: AppT.Flags(get.GetFlags)) !void {
            // `AppT.Flags(X)` is `X` merged with the global flags and is a different
            // type, so the plain struct is rebuilt - the same reason `export` does it.
            try get.run(ctx.allocator, ctx.out, ctx.err, ctx.env_map, ConfigT, .{
                .positionals = .{ .path = flags.positionals.path },
                .raw = flags.raw,
            });
        }

        fn keysRun(ctx: AppT.Ctx, flags: AppT.Flags(keys.KeysFlags)) !void {
            try keys.run(ctx.allocator, ctx.out, ConfigT, flags.positionals.prefix);
        }

        fn schemaRun(ctx: AppT.Ctx, flags: AppT.Flags(schema.SchemaFlags)) !void {
            const path = flags.positionals.output;
            if (path.len == 0) {
                try cfg.loader.generateSchema(ctx.out, ConfigT);
                return;
            }

            // Buffered then written positionally, which is how `app/cfg/lib/cfg/remote_config.zig`
            // and the rest of this tree write a whole file.
            var schema_buf: [16384]u8 = undefined;
            var w = std.Io.Writer.fixed(&schema_buf);
            try cfg.loader.generateSchema(&w, ConfigT);
            const bytes = schema_buf[0 .. schema_buf.len - w.unusedCapacityLen()];

            var file = std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = true }) catch |err| {
                try ctx.err.print("cannot create {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            };
            defer file.close(ctx.io);
            try file.writePositionalAll(ctx.io, bytes, 0);
        }

        fn exportRun(ctx: AppT.Ctx, flags: AppT.Flags(exporter.ExportFlags)) !void {
            // `AppT.Flags(X)` is `X` merged with the framework's global flags (yes,
            // output, interactive), so it is a *different type* from `X` and cannot
            // be passed as one. Rebuild the plain struct so `run` keeps a narrow
            // signature a test can construct directly.
            try exporter.run(ctx.allocator, ctx.out, ctx.err, ctx.env_map, ConfigT, .{
                .format = flags.format,
                .service_name = flags.service_name,
                .description = flags.description,
                .exec_path = flags.exec_path,
                .prefix = flags.prefix,
            });
        }

        fn dryRunRun(ctx: AppT.Ctx, flags: AppT.Flags(dry_run.DryRunFlags)) !void {
            // The framework renders a flag value as one string, so the override list
            // arrives space-separated and is split here.
            const overrides = try ops.dry_run.splitOverrides(ctx.allocator, flags.overrides);
            defer ctx.allocator.free(overrides);

            dry_run.run(ctx.allocator, ctx.out, ConfigT, overrides) catch |err| switch (err) {
                error.ValidationFailed => {
                    // Report, then return the error rather than exiting here: the
                    // framework owns the exit status, and a library that calls
                    // `std.process.exit` cannot be tested or embedded.
                    try ctx.err.writeAll("one or more configuration overrides are invalid\n");
                    return err;
                },
                else => |e| return e,
            };
        }

        fn inspectRun(ctx: AppT.Ctx, flags: AppT.Flags(inspect.InspectFlags)) !void {
            try inspectMapped(ctx, flags.positionals.path);
        }

        fn configRun(ctx: AppT.Ctx, flags: AppT.Flags(ConfigFlags)) !void {
            _ = flags;
            // Bare `config` reports the resolved picture, which is more useful than
            // a usage message and matches what the previous demonstration did.
            try inspectMapped(ctx, "");
        }

        /// Runs `inspect` with `InsufficientCapacity` mapped into the framework's
        /// error set.
        ///
        /// `collect` reports that error when its buffer array is smaller than the
        /// reportable field count, which cannot happen for a caller using
        /// `fieldCount(ConfigT)`. It is not a member of `AppError`, and widening that
        /// set for an error meaning "the caller miscounted" would be worse than
        /// mapping it here once.
        fn inspectMapped(ctx: AppT.Ctx, path: []const u8) !void {
            inspect.run(ctx.allocator, ctx.out, ctx.env_map, ConfigT, path) catch |err| switch (err) {
                error.InsufficientCapacity => return error.OutOfMemory,
                else => |e| return e,
            };
        }
    };
}

/// The configuration schema the `config` command group operates on.
///
/// **Not a demo.** `ConfigT` is threaded into nine real operations - `cast`, `get`, `keys`,
/// `schema`, `export`, `dry-run`, `inspect`, `redact` and `set` (all at their `run` call
/// sites below) - so it has to be a real schema with real `meta`, not a placeholder. This
/// replaces a placeholder that was invented purely to satisfy the parameter and
/// then became the thing every caller passed.
///
/// These fields are the settings every binary in this tree actually shares: the network
/// surface, the on-disk data location, and the log level. The `meta` entries are what make
/// `cfg inspect` and `cfg export` meaningful, and `.secret` is what makes redaction
/// observable.
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    data_dir: []const u8 = "./data",
    log_level: []const u8 = "info",
    /// A secret, so `inspect` reports it by length and never by value.
    api_key: ?[]const u8 = null,

    pub const meta = .{
        .host = .{ .env = "HOST", .help = "Interface to bind" },
        .port = .{ .env = "PORT", .help = "TCP port to listen on" },
        .data_dir = .{ .env = "DATA_DIR", .help = "Directory for persisted data" },
        .log_level = .{ .env = "LOG_LEVEL", .help = "One of: debug, info, warn, error" },
        .api_key = .{ .env = "API_KEY", .secret = true, .help = "Secret API key" },
    };
};

test {
    // `refAllDecls` reaches the declarations of the namespaces it is handed. The
    // child modules are namespaces; `Commands` is a *function* returning a type, so
    // it cannot be handed to `refAllDecls` - it is exercised by the test below
    // instead.
    std.testing.refAllDecls(exporter);
    std.testing.refAllDecls(dry_run);
    std.testing.refAllDecls(inspect);
}

test "Commands builds a config group with the three subcommands" {
    const App = cli.App(struct {}, cli.Config{});
    const Group = Commands(App, Config);

    // `App.Command(...){ ... }` is a struct literal, so `config` is already a value.
    // `subcommands` is a *declaration* on that value's type, not a field, so it is
    // reached through `@TypeOf`. (Earlier versions of this test wrote
    // `Group.config{}` and `Group.config.subcommands`, which fail respectively with
    // `expected type 'type'` and `no field named 'subcommands'`.)
    const ConfigCmd = @TypeOf(Group.config);
    try std.testing.expectEqualStrings("config", Group.config.name);
    try std.testing.expectEqual(@as(usize, 14), ConfigCmd.subcommands.len);
    try std.testing.expectEqualStrings("export", ConfigCmd.subcommands[0].name);
    try std.testing.expectEqualStrings("dry-run", ConfigCmd.subcommands[1].name);
    try std.testing.expectEqualStrings("inspect", ConfigCmd.subcommands[2].name);
    try std.testing.expectEqualStrings("schema", ConfigCmd.subcommands[3].name);
    try std.testing.expectEqualStrings("get", ConfigCmd.subcommands[4].name);
    try std.testing.expectEqualStrings("keys", ConfigCmd.subcommands[5].name);
    try std.testing.expectEqualStrings("cast", ConfigCmd.subcommands[6].name);
    try std.testing.expectEqualStrings("set", ConfigCmd.subcommands[7].name);
    try std.testing.expectEqualStrings("del", ConfigCmd.subcommands[8].name);
    try std.testing.expectEqualStrings("format", ConfigCmd.subcommands[9].name);
    try std.testing.expectEqualStrings("profile", ConfigCmd.subcommands[10].name);
    try std.testing.expectEqualStrings("encrypt", ConfigCmd.subcommands[11].name);
    try std.testing.expectEqualStrings("decrypt", ConfigCmd.subcommands[12].name);
    try std.testing.expectEqualStrings("redact", ConfigCmd.subcommands[13].name);
}

test "the demo config is reportable end to end, with its secret withheld" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("API_KEY", "demo-secret-value");

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try inspect.run(std.testing.allocator, &w, &env, Config, "");
    // The lineage line names the value, not the field, so the presence of the
    // secret is asserted through its redacted form rather than the key.
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "SECRET") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Source:") != null);
    // The assertion that matters: redaction returning the value would fail here.
    try std.testing.expect(std.mem.indexOf(u8, out, "demo-secret-value") == null);
}

// -- The `cfg` binary's own root command -------------------------------------
//
// This lives here rather than in a sibling `cfg.zig` because this file **is** the
// package root of `app/cfg/cmd`: it already owns the command-type declarations that
// need `AppT`, and the `cfg` binary's root command is the same kind of thing. An
// earlier revision put it in `cmd/cfg.zig`, which made `cfg` appear twice in the path
// (`app/cfg/cmd/cfg.zig`) for no gain.
//
// It must NOT move into `app/cfg/root.zig` instead: that file is `app_cfg`'s **module
// root**, and the module is compiled by `app/cli` too, which has no use for the `cfg`
// binary's root command.

/// The `cfg` binary's framework state.
///
/// `struct {}` because `cfg` holds no session state: every command reads, validates or
/// renders a configuration and exits. The `cli` binary needs state for its REPL; this
/// one would be carrying an empty struct for no reason if it copied that shape.
pub const State = struct {};

/// The `cfg` binary's `App`, which is what `Commands` specialises its command types
/// against. `Config` is the real shared schema: no per-app
/// configuration type has been threaded through yet. When one is, this is the single
/// line that changes - which is what taking `ConfigT` as a parameter bought.
pub const CfgApp = cli.App(State, cli.Config{ .version = "v0.1.0" });

/// `Commands` returns a **type**, so the group is instantiated with `{}` to get the
/// command values a root tuple needs. Named `CfgGroup` rather than `Group` because the
/// file already declares command namespaces and a bare `Group` would read as one.
const CfgGroup = Commands(CfgApp, Config);

/// Flags for `cfg` itself.
pub const RootFlags = struct {
    version: bool = false,

    pub const meta = .{
        .version = .{ .short = 'v', .help = "Print the version" },
    };
};

/// The `cfg` root command.
///
/// The group is exposed **directly** as the root's subcommands rather than nested under
/// a `config` subcommand: `cfg get port` is the documented spelling, and requiring
/// `cfg config get port` would defeat the point of a dedicated binary.
pub const RootCmd = CfgApp.command(.{
    .name = "cfg",
    .description = "Inspect, validate and export a configuration",
    .flags = RootFlags,
    .subcommands = .{
        CfgGroup.export_cmd,
        CfgGroup.dry_run_cmd,
        CfgGroup.inspect_cmd,
        CfgGroup.schema_cmd,
        CfgGroup.get_cmd,
        CfgGroup.keys_cmd,
        CfgGroup.cast_cmd,
        CfgGroup.set_cmd,
        CfgGroup.del_cmd,
        CfgGroup.format_cmd,
        CfgGroup.profile_cmd,
        CfgGroup.encrypt_cmd,
        CfgGroup.decrypt_cmd,
        CfgGroup.redact_cmd,
    },
}, cfgRootRun);

fn cfgRootRun(ctx: CfgApp.Ctx, flags: CfgApp.Flags(RootFlags)) !void {
    if (flags.version) {
        try ctx.out.writeAll("cfg v0.1.0\n");
        return;
    }
    // No subcommand matched, so nothing was asked for. Printing the resolved
    // configuration would be a guess at intent, and on a machine with secrets set it
    // would print more than the user asked for. Usage is the only safe default.
    //
    // Written out rather than delegating to the framework's help renderer, which is
    // private (`app/cli/lib/cli.zig`). `cfg --help` still goes through the framework's
    // own interception, so this text is only what a *bare* `cfg` prints.
    try ctx.out.writeAll(
        \\Usage: cfg <command> [options]
        \\
        \\Commands:
        \\  get <path>        Print one configuration value (--raw to strip decoration)
        \\  keys [prefix]     List key paths, one per line
        \\  cast <path> <type>  Coerce a value into a named type
        \\  set <path> <value>  Set a key in a TOML file (--file)
        \\  inspect [path]    Explain where a value came from
        \\  schema [output]   Emit a JSON Schema
        \\  export            Write the config as environment variables
        \\                    (--format dotenv|systemd|bash|json)
        \\  del <path>        Remove a key from a TOML file (--file)
        \\  format            Normalise whitespace in a TOML file (--file)
        \\  profile list|switch  List or switch contexts (--file)
        \\  encrypt           Encrypt a config file at rest (--out)
        \\  decrypt           Decrypt an encrypted blob
        \\  redact            Print a config with sensitive values replaced
        \\  dry-run           Validate overrides without applying them
        \\
        \\Run 'cfg <command> --help' for a command's flags.
        \\
    );
}

test "the cfg root exposes the config commands and nothing else" {
    // `subcommands` is a declaration on the command's type, not a field of the value,
    // so it is reached through `@TypeOf`.
    const subcommands = @TypeOf(RootCmd).subcommands;
    try std.testing.expectEqual(@as(usize, 14), subcommands.len);
    try std.testing.expectEqualStrings("export", subcommands[0].name);
    try std.testing.expectEqualStrings("dry-run", subcommands[1].name);
    try std.testing.expectEqualStrings("inspect", subcommands[2].name);
    try std.testing.expectEqualStrings("schema", subcommands[3].name);
    try std.testing.expectEqualStrings("get", subcommands[4].name);
    try std.testing.expectEqualStrings("keys", subcommands[5].name);
    try std.testing.expectEqualStrings("cast", subcommands[6].name);
    try std.testing.expectEqualStrings("set", subcommands[7].name);
    try std.testing.expectEqualStrings("del", subcommands[8].name);
    try std.testing.expectEqualStrings("format", subcommands[9].name);
    try std.testing.expectEqualStrings("profile", subcommands[10].name);
    try std.testing.expectEqualStrings("encrypt", subcommands[11].name);
    try std.testing.expectEqualStrings("decrypt", subcommands[12].name);
    try std.testing.expectEqualStrings("redact", subcommands[13].name);

    // The group is reachable **directly** as the root's subcommands, so `cfg get port`
    // works rather than `cfg config get port`.
    try std.testing.expectEqualStrings("cfg", RootCmd.name);

    // The workspace tools must NOT be reachable from here. Their absence is the reason
    // this binary exists; adding one should be a deliberate decision, not a drift.
    inline for (subcommands) |sub| {
        try std.testing.expect(!std.mem.eql(u8, sub.name, "add"));
        try std.testing.expect(!std.mem.eql(u8, sub.name, "init"));
        try std.testing.expect(!std.mem.eql(u8, sub.name, "repl"));
        try std.testing.expect(!std.mem.eql(u8, sub.name, "config"));
    }
}
