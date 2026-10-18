//! File commands: `convert`, `validate`, `fmt`, `redact`, `diff`, `encrypt`, `decrypt`.
//! They work on files directly, without the layered configuration (but for `validate` and
//! `diff` asked to check or compare it).

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const load = @import("load.zig");
const query = @import("query.zig");
const edit = @import("edit.zig");

const group = "File Commands";

/// A file format as the command line spells it: `env` for dotenv, as in `--output`.
const FileFormat = enum {
    json,
    yaml,
    toml,
    zon,
    env,
    jsonc,
    ini,

    fn toCfg(format: FileFormat) cfg.Format {
        return switch (format) {
            .json => .json,
            .yaml => .yaml,
            .toml => .toml,
            .zon => .zon,
            .env => .dotenv,
            .jsonc => .jsonc,
            .ini => .ini,
        };
    }
};

const ConvertFlags = struct {
    to: FileFormat,
    from: ?FileFormat = null,
    pub const meta = .{
        .to = .{ .short = 't', .help = "Format to write" },
        .from = .{ .short = 'f', .help = "Format to read (default: from the extension)" },
    };
};

pub const convert = cli.command(.{
    .name = "convert",
    .summary = "Convert a file to another format",
    .group = group,
    .flags = ConvertFlags,
    .args = .{ .min = 1, .max = 1, .usage = "<file|->", .complete = load.completeConfigFiles },
    .examples =
    \\termancy cfg convert app.toml --to yaml
    \\cat app.json | termancy cfg convert - --from json --to toml
    ,
    .run = runConvert,
});

fn runConvert(ctx: *cli.Context, flags: ConvertFlags) !void {
    const file = ctx.args[0];
    if (std.mem.eql(u8, file, "-") and flags.from == null) {
        return ctx.fail("reading standard input needs --from", .{});
    }
    const from: ?cfg.Format = if (flags.from) |format| format.toCfg() else null;
    if (from == null and cfg.Format.fromPath(file) == null) {
        return ctx.fail("{s}: unknown format; pass --from", .{file});
    }
    const tree = try load.parseFile(ctx, file, from);
    try ctx.out.writeAll(try load.encode(ctx, tree, flags.to.toCfg()));
}

const ValidateFlags = struct {
    schema: ?[]const u8 = null,
    pub const meta = .{
        .schema = .{
            .help = "Also check each file against this JSON Schema (in any format)",
            .value_name = "file",
            .complete = load.completeConfigFiles,
        },
    };
};

pub const validate = cli.command(.{
    .name = "validate",
    .summary = "Check that files parse, and match a schema",
    .description =
    \\Parse each file and report the first error in each, with its line and column. With
    \\--schema, also check each file against a JSON Schema and report every place it does
    \\not conform, as "<file>: <key>: <problem>". Text where the schema wants a number or
    \\a boolean is accepted when it reads as one, as dotenv and INI hold only text.
    \\Exits with status 1 if any file is invalid.
    \\
    \\With no files, check the effective configuration instead, as every other command
    \\reads it: the files --config names (or the termancy.* file found), with the profile,
    \\the environment (--env-prefix), and --set applied. Every problem is reported, at
    \\the file and line that set the key, or naming the variable or flag that did. Nothing
    \\is written.
    \\
    \\A file is also checked (with a warning, not a failure; -q silences it) for what
    \\parses but is likely a mistake: a value that looks like a secret written in plain
    \\text (a key such as password or token, not a ${secret:...} reference), a key the
    \\schema marks deprecated, and a key the schema does not declare but that is close to
    \\one it does (as prot is to port).
    ,
    .group = group,
    .exit_statuses = &.{
        .{ .code = 0, .meaning = "Every file is valid" },
        .{ .code = 1, .meaning = "A file does not parse or does not match the schema" },
    },
    .flags = ValidateFlags,
    .args = .{
        .max = null,
        .usage = "[<file>...]",
        .complete = load.completeConfigFiles,
    },
    .examples =
    \\termancy cfg validate app.toml prod.yaml --schema schema.json
    \\termancy cfg validate --schema schema.json -c app.toml --profile prod --set port=0
    ,
    .run = runValidate,
});

fn runValidate(ctx: *cli.Context, flags: ValidateFlags) !void {
    const schema: ?cfg.Value = if (flags.schema) |file|
        try load.parseFile(ctx, file, null)
    else
        null;
    if (ctx.args.len == 0) return validateEffective(ctx, schema);
    try validateFiles(ctx, schema, ctx.args);
}

/// Loads the configuration the global flags describe (which reports a file that does not
/// parse) and, with a `schema`, checks the effective tree against it, printing every
/// problem where the key was set. Prints `configuration: ok` when there is none.
fn validateEffective(ctx: *cli.Context, schema: ?cfg.Value) !void {
    const global = try ctx.flags(load.Global);
    var config = try load.load(ctx, global);
    defer config.deinit();
    if (schema) |s| {
        var problems: std.ArrayList(cfg.Diagnostic) = .empty;
        if (!try cfg.schema.validate(ctx.arena, s, try config.resolve(), .{}, &problems)) {
            for (problems.items) |*problem| {
                config.locateDiagnostic(problem);
                try ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error");
                try ctx.err.print("{f}", .{problem.*});
                const origin = if (problem.file.len > 0) null else try config.explain(problem.key);
                if (origin) |o| try ctx.err.print(" (from {s}{s})", switch (o.layer) {
                    .env => .{ "$", o.source },
                    .override => .{ "", "--set" },
                    .default => .{ "", "a default" },
                    .profile => .{ "the profile in ", o.source },
                    .file, .flag => .{ "", o.source },
                });
                try ctx.err.writeByte('\n');
                if (config.sourceText(problem.file)) |text| try problem.writeSnippet(ctx.err, text);
            }
            return error.CommandFailed;
        }
    }
    try ctx.out.writeAll("configuration: ok\n");
}

/// Checks that each of `files` parses and, with a `schema`, conforms to it; prints
/// `<file>: ok` for each that does and the problems of each that does not.
pub fn validateFiles(ctx: *cli.Context, schema: ?cfg.Value, files: []const []const u8) !void {
    var failed = false;
    for (files) |file| {
        const parsed = parseKeepingText(ctx, file) catch |err| switch (err) {
            // The message has been printed; carry on with the next file.
            error.CommandFailed => {
                failed = true;
                continue;
            },
            else => |e| return e,
        };
        var warnings: std.ArrayList(cfg.Diagnostic) = .empty;
        try lint(ctx.arena, parsed.tree, schema, "", &warnings);
        for (warnings.items) |*warning| {
            if (ctx.quiet) break;
            try locate(ctx, file, parsed.text, parsed.format, warning);
            ctx.warn("{f}", .{warning.*});
            try warning.writeSnippet(ctx.err, parsed.text);
        }
        if (schema) |s| {
            var problems: std.ArrayList(cfg.Diagnostic) = .empty;
            if (!try cfg.schema.validate(ctx.arena, s, parsed.tree, .{}, &problems)) {
                for (problems.items) |*problem| {
                    try printProblem(ctx, file, parsed.text, parsed.format, problem);
                }
                failed = true;
                continue;
            }
        }
        try ctx.out.print("{s}: ok\n", .{file});
    }
    if (failed) return error.CommandFailed;
}

const Parsed = struct { tree: cfg.Value, text: []const u8, format: cfg.Format };

fn parseKeepingText(ctx: *cli.Context, file: []const u8) !Parsed {
    const format = cfg.Format.fromPath(file) orelse {
        return ctx.fail("{s}: " ++ load.unknown_format, .{file});
    };
    const text = try load.readSource(ctx, file);
    return .{ .tree = try load.parseText(ctx, file, text, format), .text = text, .format = format };
}

/// Words in a key's name that make its value a secret.
const secret_words = [_][]const u8{
    "password", "passwd", "secret", "token", "api_key", "apikey", "private_key",
};

/// Collects what parses but is likely a mistake: plain-text secrets, keys `schema` marks
/// deprecated, and keys it does not declare that are close to ones it does. `prefix` is
/// the dotted path of `tree`.
fn lint(
    arena: std.mem.Allocator,
    tree: cfg.Value,
    schema: ?cfg.Value,
    prefix: []const u8,
    out: *std.ArrayList(cfg.Diagnostic),
) !void {
    if (tree != .table) return;
    const properties = if (schema) |s| switch (s) {
        .table => |t| if (t.get("properties")) |p| if (p == .table) p.table else null else null,
        else => null,
    } else null;
    // Where the schema rejects other keys, validating reports them; elsewhere they are
    // allowed, so only one close to a declared key (a typo) is worth a warning.
    const open = properties != null and schema.?.table.get("additionalProperties") == null and
        schema.?.table.get("patternProperties") == null;
    var it = tree.table.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const key = if (prefix.len == 0)
            name
        else
            try std.mem.concat(arena, u8, &.{ prefix, ".", name });
        const property: ?cfg.Value = if (properties) |p| p.get(name) else null;
        if (property == null and open) {
            if (cli.internal.text.suggest(name, properties.?.keys())) |near| {
                try out.append(arena, .{ .key = key, .message = try std.fmt.allocPrint(
                    arena,
                    "unknown key; did you mean '{s}'?",
                    .{near},
                ) });
            }
        }
        if (property) |prop| if (prop == .table) {
            if (prop.table.get("deprecated")) |d| if (d == .bool and d.bool) {
                const reason = if (prop.table.get("deprecationMessage")) |m|
                    if (m == .string) m.string else ""
                else
                    "";
                const message = if (reason.len > 0)
                    try std.mem.concat(arena, u8, &.{ "deprecated: ", reason })
                else
                    "deprecated";
                try out.append(arena, .{ .key = key, .message = message });
            };
        };
        switch (entry.value_ptr.*) {
            .table => try lint(arena, entry.value_ptr.*, property, key, out),
            .string => |text| if (isSecretName(name) and text.len > 0 and
                !std.mem.startsWith(u8, text, "${"))
            {
                try out.append(arena, .{
                    .key = key,
                    .message = "a secret in plain text (use ${secret:...})",
                });
            },
            else => {},
        }
    }
}

/// Whether a key named `name` (one part of a dotted key) looks like it holds a secret.
fn isSecretName(name: []const u8) bool {
    for (secret_words) |word| {
        if (std.ascii.findIgnoreCase(name, word) != null) return true;
    }
    return false;
}

/// Prints a schema problem in `file` as `file:line:column: key: message`, with the line
/// and a caret under the value, when the key is in the text.
fn printProblem(
    ctx: *cli.Context,
    file: []const u8,
    source: []const u8,
    format: cfg.Format,
    problem: *cfg.Diagnostic,
) !void {
    try locate(ctx, file, source, format, problem);
    try ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error");
    try ctx.err.print("{f}\n", .{problem.*});
    try problem.writeSnippet(ctx.err, source);
}

/// Points `problem` at `file`, and at the line and column of its key when the key is in
/// the text.
fn locate(
    ctx: *cli.Context,
    file: []const u8,
    source: []const u8,
    format: cfg.Format,
    problem: *cfg.Diagnostic,
) !void {
    problem.file = file;
    if (try cfg.locate.locate(ctx.arena, format, source, problem.key)) |at| {
        problem.line = at.line;
        problem.column = at.column;
    }
}

const FmtFlags = struct {
    check: bool = false,
    null: bool = false,
    sort: bool = false,
    pub const meta = .{
        .sort = .{ .help = "Sort keys, at every level (TOML keeps its comments)" },
        .check = .{ .help = "Report files that are not formatted, without changing them" },
        .null = .{ .short = '0', .help = "End lines with NUL, not newline (for xargs -0)" },
    };
};

pub const fmt = cli.command(.{
    .name = "fmt",
    .summary = "Rewrite files in canonical form",
    .description =
    \\Rewrite each file in canonical form: consistent indentation, quoting, and spacing.
    \\TOML, ZON, and dotenv files keep their comments and key order; other formats are
    \\written as termancy writes them, and lose their comments (with a warning). With --check,
    \\list the files that would change and exit with status 1 if there are any.
    \\
    \\--sort sorts keys and tables by name. In TOML, keys are sorted within each group
    \\(lines a blank line sets apart stay apart), and a key or a table takes the comments
    \\directly above it along; other formats lose their comments.
    ,
    .group = group,
    .exit_statuses = &.{
        .{ .code = 0, .meaning = "The files were rewritten, or with --check, none would change" },
        .{ .code = 1, .meaning = "With --check, some file would change" },
    },
    .flags = FmtFlags,
    .args = .{
        .min = 1,
        .max = null,
        .usage = "<file>...",
        .complete = load.completeConfigFiles,
    },
    .run = runFmt,
});

fn runFmt(ctx: *cli.Context, flags: FmtFlags) !void {
    var unformatted = false;
    for (ctx.args) |file| {
        const format = cfg.Format.fromPath(file) orelse
            return ctx.fail("{s}: " ++ load.unknown_format, .{file});
        const source = try load.readSource(ctx, file);
        var tree = try load.parseFile(ctx, file, format);
        // Keeping comments where the format allows it; otherwise rewritten whole.
        const kept = if (flags.sort)
            try cfg.edit.sort(ctx.arena, format, source)
        else
            try cfg.edit.reformat(ctx.arena, format, source);
        if (kept == null and flags.sort) tree.sortKeys();
        const formatted = kept orelse try load.rewrite(ctx, tree, format, source);
        if (std.mem.eql(u8, source, formatted)) continue;
        if (flags.check) {
            try ctx.out.print("{s}{c}", .{ file, query.terminator(flags.null) });
            unformatted = true;
        } else {
            if (kept == null and edit.hasComments(source, format)) {
                ctx.warn("{s}: comments are not preserved", .{file});
            }
            try load.writeFileAtomic(ctx, file, formatted);
        }
    }
    if (unformatted) return error.CommandFailed;
}

const RedactFlags = struct {
    from: ?FileFormat = null,
    secret: []const []const u8 = &.{},
    pub const meta = .{
        .from = .{ .short = 'f', .help = "Format to read (default: from the extension)" },
        .secret = .{
            .help = "Also redact this key, or everything under it; repeatable",
            .value_name = "key",
        },
    };
};

pub const redact = cli.command(.{
    .name = "redact",
    .summary = "Print a file with its secrets hidden, to share it",
    .description =
    \\Print <file> with the value of every key that looks secret replaced by
    \\"<redacted>", keeping its keys, comments, and layout: for a bug report. A key looks
    \\secret when its name holds password, passwd, secret, token, api_key, apikey, or
    \\private_key, the names "termancy cfg validate" warns about; everything under such a
    \\table is secret too. --secret names more keys. Empty values and ${...} references
    \\give nothing away and are kept. The file itself is not changed.
    \\
    \\Where a value cannot be replaced in place (an item of a JSON array, say), the whole
    \\file is written as termancy writes it, losing its comments, with a warning.
    ,
    .group = group,
    .flags = RedactFlags,
    .args = .{ .min = 1, .max = 1, .usage = "<file|->", .complete = load.completeConfigFiles },
    .examples =
    \\termancy cfg redact app.toml > app-redacted.toml
    \\termancy cfg redact app.yaml --secret db.url
    \\cat .env | termancy cfg redact - --from env
    ,
    .run = runRedact,
});

fn runRedact(ctx: *cli.Context, flags: RedactFlags) !void {
    const file = ctx.args[0];
    if (std.mem.eql(u8, file, "-") and flags.from == null) {
        return ctx.fail("reading standard input needs --from", .{});
    }
    const format = if (flags.from) |f| f.toCfg() else cfg.Format.fromPath(file) orelse
        return ctx.fail("{s}: unknown format; pass --from", .{file});
    const source = try load.readSource(ctx, file);
    if (cfg.encrypted.isEncrypted(source)) {
        return ctx.fail("{s}: encrypted, so there is nothing in plain text to redact", .{file});
    }
    var tree = try load.parseText(ctx, file, source, format);
    var keys: std.ArrayList([]const u8) = .empty;
    try secretKeys(ctx.arena, tree, "", false, flags.secret, &keys);
    const hidden: cfg.Value = .{ .string = cfg.Config.redacted };
    var text: ?[]const u8 = source;
    for (keys.items) |key| {
        try tree.put(ctx.arena, key, hidden);
        const in_place = text orelse continue;
        const change: cfg.edit.Change = .{ .set = .{ .key = key, .value = hidden } };
        text = try cfg.edit.apply(ctx.arena, format, in_place, change);
    }
    if (text == null and edit.hasComments(source, format)) {
        ctx.warn("{s}: comments are not preserved", .{file});
    }
    try ctx.out.writeAll(text orelse try load.rewrite(ctx, tree, format, source));
}

/// Collects the key of every value under `value` (at the dotted key `prefix`) to redact:
/// those under a key `isSecretName` picks or `extra` names, or under a secret table when
/// `secret`. An array of scalars is redacted whole. Values that give nothing away are left
/// out: empty strings, `${...}` references, and nulls.
fn secretKeys(
    arena: std.mem.Allocator,
    value: cfg.Value,
    prefix: []const u8,
    secret: bool,
    extra: []const []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    switch (value) {
        .table => |table| {
            var it = table.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const key = try cfg.path.join(arena, prefix, name);
                const named = for (extra) |wanted| {
                    if (std.mem.eql(u8, wanted, key)) break true;
                } else false;
                const child_secret = secret or named or isSecretName(name);
                try secretKeys(arena, entry.value_ptr.*, key, child_secret, extra, out);
            }
        },
        .array => |array| {
            const scalars = for (array.items) |item| {
                if (item == .table or item == .array) break false;
            } else true;
            if (scalars) {
                const revealing = for (array.items) |item| {
                    if (gives(item)) break true;
                } else false;
                if (secret and revealing) try out.append(arena, prefix);
                return;
            }
            for (array.items, 0..) |item, i| {
                const key = try std.fmt.allocPrint(arena, "{s}.{d}", .{ prefix, i });
                try secretKeys(arena, item, key, secret, extra, out);
            }
        },
        else => if (secret and gives(value)) try out.append(arena, prefix),
    }
}

/// Whether showing `value` would give a secret away.
fn gives(value: cfg.Value) bool {
    return switch (value) {
        .null => false,
        .string => |text| text.len > 0 and !std.mem.startsWith(u8, text, "${"),
        else => true,
    };
}

const DiffFlags = struct {
    layer: []const cfg.Config.Layer = &.{},
    pub const meta = .{
        .layer = .{ .help = "Compare two layers of the configuration instead; give it twice" },
    };
};

pub const diff = cli.command(.{
    .name = "diff",
    .summary = "Compare two files, or two layers, key by key",
    .description =
    \\Print the keys whose values differ between <old> and <new>, which may be in different
    \\formats. A key only in <old> prints as "- key = value", one only in <new> as "+ key =
    \\value", and a changed key as both lines. Exits with status 0 when the files hold the
    \\same configuration and 1 when they differ, as diff(1) does.
    \\
    \\-o json prints one object per key, sorted by key:
    \\  [{"key": string, "change": "added" | "removed" | "changed", "old": any, "new": any}]
    \\"old" is null for an added key and "new" for a removed one.
    \\
    \\With --layer twice and no files, compare two layers of the loaded configuration
    \\instead: --layer file --layer env shows what the environment overrides.
    ,
    .group = group,
    .exit_statuses = &.{
        .{ .code = 0, .meaning = "The configurations are the same" },
        .{ .code = 1, .meaning = "They differ" },
    },
    .flags = DiffFlags,
    .args = .{ .max = 2, .usage = "<old> <new>", .complete = load.completeConfigFiles },
    .examples =
    \\termancy cfg diff base.toml prod.yaml
    \\termancy cfg diff old.json new.json -o json
    \\termancy cfg diff --layer file --layer env --env-prefix APP
    ,
    .run = runDiff,
});

fn runDiff(ctx: *cli.Context, flags: DiffFlags) !void {
    const global = try ctx.flags(load.Global);
    var old: cfg.Value = undefined;
    var new: cfg.Value = undefined;
    if (flags.layer.len > 0) {
        if (flags.layer.len != 2 or ctx.args.len != 0) {
            return ctx.usageError("give --layer twice, and no files", .{});
        }
        var config = try load.load(ctx, global);
        defer config.deinit();
        old = try (try config.layerTree(flags.layer[0])).clone(ctx.arena);
        new = try (try config.layerTree(flags.layer[1])).clone(ctx.arena);
    } else {
        if (ctx.args.len != 2) return ctx.usageError("give two files, or --layer twice", .{});
        old = try load.parseFile(ctx, ctx.args[0], null);
        new = try load.parseFile(ctx, ctx.args[1], null);
    }
    const changes = try cfg.diff(ctx.arena, old, new);
    if (global.output == .text) {
        for (changes) |change| {
            if (change.old) |value| try ctx.out.print("- {s} = {f}\n", .{ change.key, value });
            if (change.new) |value| try ctx.out.print("+ {s} = {f}\n", .{ change.key, value });
        }
    } else {
        var list: cfg.Array = .empty;
        for (changes) |change| {
            var entry: cfg.Value = .empty_table;
            try entry.put(ctx.arena, "key", .{ .string = change.key });
            try entry.put(ctx.arena, "change", .{ .string = @tagName(change.kind()) });
            try entry.put(ctx.arena, "old", change.old orelse .null);
            try entry.put(ctx.arena, "new", change.new orelse .null);
            try list.append(ctx.arena, entry);
        }
        try load.writeValue(ctx, .{ .array = list }, global.output);
    }
    if (changes.len > 0) return ctx.exit(1);
}

const SecretFlags = struct {
    passphrase: []const u8,
    pub const meta = .{
        .passphrase = .{
            .help = "The passphrase; better given through the environment than here",
            .env = "TERMANCY_PASSPHRASE",
            .prompt = "Passphrase",
            .secret = true,
            .hidden = true,
        },
    };
};

pub const encrypt = cli.command(.{
    .name = "encrypt",
    .summary = "Encrypt a file for keeping secrets in a repository",
    .description =
    \\Write <file>.enc: the file encrypted with XChaCha20-Poly1305 under a key derived
    \\from the passphrase (Argon2id). The passphrase comes from $TERMANCY_PASSPHRASE, or is
    \\asked for at a terminal. Every termancy command reads the .enc file with -c when
    \\$TERMANCY_PASSPHRASE is set, treating all of its values as secret.
    ,
    .group = group,
    .flags = SecretFlags,
    .args = .{ .min = 1, .max = 1, .usage = "<file>", .complete = load.completeConfigFiles },
    .examples =
    \\TERMANCY_PASSPHRASE=... termancy cfg encrypt secrets.toml
    \\termancy cfg -c secrets.toml.enc get db.password
    ,
    .run = runEncrypt,
});

fn runEncrypt(ctx: *cli.Context, flags: SecretFlags) !void {
    const file = ctx.args[0];
    const format = cfg.Format.fromPath(file) orelse
        return ctx.fail("{s}: " ++ load.unknown_format, .{file});
    const plaintext = try load.readSource(ctx, file);
    // Wiped when sealed; the tree parsed from it stays in the arena until the run ends.
    defer std.crypto.secureZero(u8, @constCast(plaintext));
    // It must parse, so that what is sealed can be read back.
    _ = try load.parseText(ctx, file, plaintext, format);
    const passphrase = flags.passphrase;
    const sealed = cfg.encrypted.encrypt(ctx.arena, ctx.io, plaintext, passphrase, format, .{});
    const envelope = sealed catch |err| {
        return ctx.fail("{s}: cannot encrypt: {s}", .{ file, @errorName(err) });
    };
    const target = try std.mem.concat(ctx.arena, u8, &.{ file, ".enc" });
    try load.writeFileAtomic(ctx, target, envelope);
}

pub const decrypt = cli.command(.{
    .name = "decrypt",
    .summary = "Print an encrypted file's contents",
    .description =
    \\Print what <file> (made by "termancy cfg encrypt") holds. The passphrase comes from
    \\$TERMANCY_PASSPHRASE, or is asked for at a terminal.
    ,
    .group = group,
    .flags = SecretFlags,
    .args = .{ .min = 1, .max = 1, .usage = "<file>" },
    .examples =
    \\termancy cfg decrypt secrets.toml.enc > secrets.toml
    ,
    .run = runDecrypt,
});

fn runDecrypt(ctx: *cli.Context, flags: SecretFlags) !void {
    const file = ctx.args[0];
    const envelope = try load.readSource(ctx, file);
    const result = cfg.encrypted.decrypt(ctx.arena, ctx.io, envelope, flags.passphrase);
    const opened = result catch |err| {
        return ctx.fail("{s}: {s}", .{ file, switch (err) {
            error.WrongPassphrase => "wrong passphrase, or the file was changed",
            error.NotEncrypted => "not an encrypted file",
            else => @errorName(err),
        } });
    };
    defer std.crypto.secureZero(u8, opened.plaintext);
    try ctx.out.writeAll(opened.plaintext);
}
