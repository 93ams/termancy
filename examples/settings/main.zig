//! A shop's settings tool, built on `cfg` the way an application's own `config` command
//! would be:
//!
//! - `show`: layers in order (struct defaults, `app.toml`, the `--env` variant and
//!   `app.local.toml`, a `--profile`, an encrypted `secrets.toml.enc`, `SHOP_*` variables),
//!   each value printed with where it came from and secrets redacted;
//! - `check`: every problem at once, each with its file, line, and a caret under it, from
//!   the typed decode and from the JSON Schema the struct generates;
//! - `set`: changes one key in place, keeping comments and layout, refusing a value the
//!   struct would reject; `--dry-run` prints what would change;
//! - `diff`, `migrate` (upgrades a version 1 file), `schema`, and `seal` (encrypts a file).
//!
//!     zig build examples
//!     cd examples/settings
//!     SETTINGS_PASSPHRASE=example ../../zig-out/bin/settings show --env production
//!     ../../zig-out/bin/settings check -f broken.toml
//!     ../../zig-out/bin/settings set server.port 9090 --dry-run
//!     ../../zig-out/bin/settings migrate -f old.toml --dry-run

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const sys = @import("sys");

const LogLevel = enum { debug, info, warn, @"error" };

const Server = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    timeout: cfg.Duration = .{ .ns = 30 * std.time.ns_per_s },
};

const Database = struct {
    url: []const u8 = "postgres://localhost/shop",
    password: ?[]const u8 = null,
    pool: u8 = 5,
};

const Log = struct {
    level: LogLevel = .info,
    format: []const u8 = "text",
};

const Settings = struct {
    schema_version: u32 = 3,
    server: Server = .{},
    database: Database = .{},
    log: Log = .{},
};

/// What each setting means and must be, by type.
const Specs = field.Set(.{
    field.Spec(Server){ .fields = .{
        .port = .{ .help = "Where the shop listens", .checks = &.{.min(1)} },
    } },
    field.Spec(Database){ .fields = .{
        .password = .{ .secret = true },
        .pool = .{ .checks = &.{ .min(1), .max(100) } },
    } },
    field.Spec(Log){ .fields = .{
        .format = .{ .checks = &.{.oneOf(&.{ "text", "json" })} },
    } },
});

/// The settings as files spell them: `server.timeout` was `server.request_timeout`.
const shop = cfg.settings(Settings, Specs, .{ .fields = .{
    .server = .{ .fields = .{ .timeout = .{ .renamed_from = "request_timeout" } } },
} });

const Global = struct {
    file: []const u8 = "app.toml",
};
const global_flags = cli.flags(Global, field.Set(.{field.Spec(Global){ .fields = .{
    .file = .{ .help = "The settings file" },
} }}), .{ .fields = .{
    .file = .{ .short = 'f' },
} });

fn readFile(ctx: *cli.Context, file: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, file, ctx.arena, .limited(1 << 20)) catch |err|
        return ctx.fail("{s}: {t}", .{ file, err });
}

fn formatOf(ctx: *cli.Context, file: []const u8) !cfg.Format {
    return cfg.Format.fromPath(file) orelse ctx.usageError("{s}: not a known format", .{file});
}

/// Prints `problem`, located in `source`, with the line and a caret.
fn printProblem(
    ctx: *cli.Context,
    file: []const u8,
    source: []const u8,
    format: cfg.Format,
    problem: *cfg.Diagnostic,
) !void {
    if (problem.line == 0) {
        if (try cfg.locate.locate(ctx.arena, format, source, problem.key)) |at| {
            problem.line = at.line;
            problem.column = at.column;
        }
    }
    problem.file = std.fs.path.basename(file);
    try ctx.err.print("{f}\n", .{problem.*});
    try problem.writeSnippet(ctx.err, source);
}

// -- show --------------------------------------------------------------------------------

const ShowFlags = struct {
    env: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    passphrase: ?[]const u8 = null,
    reveal: bool = false,
};
const show_flags = cli.flags(ShowFlags, field.Set(.{field.Spec(ShowFlags){ .fields = .{
    .env = .{ .help = "Also load <file>.<env>.toml over the file" },
    .profile = .{ .help = "Merge the file's profiles.<name> table" },
    .passphrase = .{ .secret = true, .help = "Opens secrets.toml.enc next to the file" },
    .reveal = .{ .help = "Print secrets instead of redacting them" },
} }}), .{ .fields = .{
    .env = .{ .short = 'e' },
    .profile = .{ .short = 'p' },
    .passphrase = .{ .env = "SETTINGS_PASSPHRASE" },
} });

fn show(ctx: *cli.Context, flags: ShowFlags) !void {
    const global = try ctx.flags(Global);
    var config: cfg.Config = .init(ctx.gpa);
    defer config.deinit();
    var diag: cfg.Diagnostic = .{};
    const variants: []const []const u8 = &.{ flags.env orelse "", "local" };
    _ = config.loadVariants(ctx.io, .cwd(), global.file, variants, null, &diag) catch |err|
        switch (err) {
            error.SyntaxError => return ctx.fail("{f}", .{diag}),
            else => return ctx.fail("{s}: {t}", .{ global.file, err }),
        };
    // Secrets kept in the repository, encrypted; without the passphrase they stay unset.
    if (flags.passphrase) |passphrase| {
        config.usePassphrase(passphrase);
        const dir = std.fs.path.dirname(global.file) orelse ".";
        const sealed = try std.fs.path.join(ctx.arena, &.{ dir, "secrets.toml.enc" });
        config.loadFile(ctx.io, .cwd(), sealed, null, &diag) catch |err| switch (err) {
            error.FileNotFound => {},
            error.WrongPassphrase => return ctx.fail("{s}: wrong passphrase", .{sealed}),
            else => return ctx.fail("{s}: {t}", .{ sealed, err }),
        };
    }
    try config.useProfile(flags.profile);
    config.useEnv(ctx.environ);
    try config.automaticEnv("SHOP"); // SHOP_SERVER_PORT=9000

    // Decoding checks every value; the settings themselves are what an app would use.
    var problems: std.ArrayList(cfg.Diagnostic) = .empty;
    _ = config.decode(shop, .{ .errors = &problems }, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            for (problems.items) |*problem| {
                const source = config.sourceText(problem.file) orelse "";
                try ctx.err.print("{f}\n", .{problem.*});
                try problem.writeSnippet(ctx.err, source);
            }
            return ctx.exit(1);
        },
    };
    for (try config.keys()) |key| {
        if (std.mem.startsWith(u8, key, "profiles.")) continue;
        const value = (try config.get(key)).?;
        const origin = (try config.explain(key)).?;
        if (config.isSecret(key) and !flags.reveal) {
            try ctx.out.print("{s} = {s}", .{ key, cfg.Config.redacted });
        } else {
            try ctx.out.print("{s} = {f}", .{ key, value });
        }
        try ctx.out.print("  # {t}", .{origin.layer});
        if (origin.source.len > 0) {
            try ctx.out.print(" ({s})", .{std.fs.path.basename(origin.source)});
        }
        try ctx.out.writeByte('\n');
    }
}

// -- check -------------------------------------------------------------------------------

fn check(ctx: *cli.Context) !void {
    const global = try ctx.flags(Global);
    const format = try formatOf(ctx, global.file);
    const source = try readFile(ctx, global.file);
    var diag: cfg.Diagnostic = .{};
    const tree = format.parse(ctx.arena, source, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            try printProblem(ctx, global.file, source, format, &diag);
            return ctx.exit(1);
        },
    };
    // The struct's own checks (types, bounds, choices), all at once...
    var problems: std.ArrayList(cfg.Diagnostic) = .empty;
    var warnings: std.ArrayList(cfg.Diagnostic) = .empty;
    const options: cfg.DecodeOptions = .{ .errors = &problems, .warnings = &warnings };
    _ = cfg.decode(shop, ctx.arena, tree, options, null) catch {};
    // ...and the JSON Schema it generates, which editors and other tools can check too.
    const generated = try cfg.schema.build(shop, ctx.arena);
    var schema_problems: std.ArrayList(cfg.Diagnostic) = .empty;
    _ = try cfg.schema.validate(ctx.arena, generated, tree, .{}, &schema_problems);
    for (schema_problems.items) |problem| {
        // A problem both checks found is reported once.
        for (problems.items) |seen| {
            if (std.mem.eql(u8, seen.key, problem.key)) break;
        } else try problems.append(ctx.arena, problem);
    }
    for (warnings.items) |*warning| {
        if (ctx.quiet) break;
        try ctx.err.writeAll("warning: ");
        try printProblem(ctx, global.file, source, format, warning);
    }
    for (problems.items) |*problem| try printProblem(ctx, global.file, source, format, problem);
    if (problems.items.len > 0) {
        try ctx.err.print("{d} problems\n", .{problems.items.len});
        return ctx.exit(1);
    }
    try ctx.out.print("{s}: ok\n", .{std.fs.path.basename(global.file)});
}

// -- set ---------------------------------------------------------------------------------

const SetArgs = struct { key: []const u8, value: []const u8 };

fn set(ctx: *cli.Context, args: SetArgs) !void {
    const global = try ctx.flags(Global);
    const format = try formatOf(ctx, global.file);
    const source = try readFile(ctx, global.file);
    const value = cfg.infer(args.value);
    const change: cfg.edit.Change = .{ .set = .{ .key = args.key, .value = value } };
    const edited = try cfg.edit.apply(ctx.arena, format, source, change) orelse
        return ctx.fail("{s}: cannot set {s} in place", .{ global.file, args.key });
    // Refuse what the application would refuse to start with.
    var diag: cfg.Diagnostic = .{};
    const tree = try format.parse(ctx.arena, edited, null);
    _ = cfg.decode(shop, ctx.arena, tree, .{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("{f}", .{diag}),
    };
    if (ctx.dry_run) {
        const before = try format.parse(ctx.arena, source, null);
        return printChanges(ctx, before, tree);
    }
    try sys.files.writeAtomic(ctx.io, .cwd(), global.file, edited, .{});
}

// -- diff --------------------------------------------------------------------------------

const DiffArgs = struct { old: []const u8, new: []const u8 };

fn diffFiles(ctx: *cli.Context, args: DiffArgs) !void {
    var trees: [2]cfg.Value = undefined;
    for ([_][]const u8{ args.old, args.new }, &trees) |file, *tree| {
        var diag: cfg.Diagnostic = .{};
        tree.* = (try formatOf(ctx, file)).parse(ctx.arena, try readFile(ctx, file), &diag) catch
            return ctx.fail("{s}:{f}", .{ file, diag });
    }
    try printChanges(ctx, trees[0], trees[1]);
}

/// `+ key = new`, `- key = old`, `~ key = old -> new`, sorted by key.
fn printChanges(ctx: *cli.Context, old: cfg.Value, new: cfg.Value) !void {
    for (try cfg.diff(ctx.arena, old, new)) |change| switch (change.kind()) {
        .added => try ctx.out.print("+ {s} = {f}\n", .{ change.key, change.new.? }),
        .removed => try ctx.out.print("- {s} = {f}\n", .{ change.key, change.old.? }),
        .changed => try ctx.out.print("~ {s} = {f} -> {f}\n", .{
            change.key, change.old.?, change.new.?,
        }),
    };
}

// -- migrate -----------------------------------------------------------------------------

/// Version 2 gave the server its own table; version 3 replaced `debug = true` with a log
/// level.
const migrations = [_]cfg.migrate.Migration{
    .{ .to = 2, .steps = &.{
        .{ .rename = .{ .from = "host", .to = "server.host" } },
        .{ .rename = .{ .from = "port", .to = "server.port" } },
    } },
    .{ .to = 3, .steps = &.{.{ .custom = debugToLevel }} },
};

fn debugToLevel(arena: std.mem.Allocator, tree: *cfg.Value) !void {
    const debug = tree.lookup("debug") orelse return;
    if (debug == .bool and debug.bool) try tree.put(arena, "log.level", .{ .string = "debug" });
    _ = tree.table.orderedRemove("debug");
}

fn migrate(ctx: *cli.Context) !void {
    const global = try ctx.flags(Global);
    const format = try formatOf(ctx, global.file);
    const source = try readFile(ctx, global.file);
    const before = try format.parse(ctx.arena, source, null);
    var tree = try before.clone(ctx.arena);
    const result = cfg.migrate.run(ctx.arena, &tree, &migrations, .{}) catch |err|
        return ctx.fail("{s}: {t}", .{ global.file, err });
    if (result.from == result.to) {
        return ctx.out.print("{s} is already at version {d}\n", .{ global.file, result.to });
    }
    if (ctx.dry_run) return printChanges(ctx, before, tree);
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    try format.write(&out.writer, tree);
    try sys.files.writeAtomic(ctx.io, .cwd(), global.file, out.written(), .{});
    try ctx.out.print("{s}: version {d} -> {d}\n", .{ global.file, result.from, result.to });
}

// -- schema, seal ------------------------------------------------------------------------

fn schema(ctx: *cli.Context) !void {
    try cfg.schema.write(shop, ctx.arena, ctx.out);
    try ctx.out.writeByte('\n');
}

const SealFlags = struct {
    passphrase: []const u8,
    memory: u32 = 64 * 1024,
};
const seal_flags = cli.flags(SealFlags, field.Set(.{field.Spec(SealFlags){ .fields = .{
    .passphrase = .{ .secret = true, .help = "The passphrase to encrypt with" },
    .memory = .{
        .help = "KiB of memory the key derivation needs (its cost)",
        .checks = &.{.min(8)},
    },
} }}), .{ .fields = .{
    .passphrase = .{ .env = "SETTINGS_PASSPHRASE", .prompt = "Passphrase" },
} });

const SealArgs = struct { plain: []const u8 };

fn seal(ctx: *cli.Context, flags: SealFlags, args: SealArgs) !void {
    const format = try formatOf(ctx, args.plain);
    const plain = try readFile(ctx, args.plain);
    const params: cfg.encrypted.Params = .{ .m = flags.memory };
    const envelope =
        try cfg.encrypted.encrypt(ctx.arena, ctx.io, plain, flags.passphrase, format, params);
    try ctx.out.writeAll(envelope);
}

pub const root = cli.command(.{
    .name = "settings",
    .summary = "Show, check, and change the shop's settings",
    .persistent_flags = global_flags,
    .subcommands = .{
        cli.command(.{
            .name = "show",
            .summary = "Print the effective settings and where each came from",
            .flags = show_flags,
            .run = show,
        }),
        cli.command(.{
            .name = "check",
            .summary = "Report every problem in a file",
            .run = check,
        }),
        cli.command(.{
            .name = "set",
            .summary = "Set one key, keeping the file's comments",
            .args = SetArgs,
            .dry_run = true,
            .run = set,
        }),
        cli.command(.{
            .name = "diff",
            .summary = "Compare two files, in any formats",
            .args = DiffArgs,
            .run = diffFiles,
        }),
        cli.command(.{
            .name = "migrate",
            .summary = "Upgrade a file to the current version",
            .dry_run = true,
            .run = migrate,
        }),
        cli.command(.{ .name = "schema", .summary = "Print the JSON Schema", .run = schema }),
        cli.command(.{
            .name = "seal",
            .summary = "Encrypt a file, for secrets kept in a repository",
            .flags = seal_flags,
            .args = SealArgs,
            .run = seal,
        }),
    },
});

const app: cli.App = .{ .root = &root };

pub fn main(init: std.process.Init) u8 {
    return app.run(init);
}

const testing = std.testing;

/// Runs `args` against the files in `examples/settings` (tests run from the repository's
/// root).
fn runHere(args: []const []const u8, env: []const [2][]const u8) !cli.testing.Run {
    return cli.testing.run(app, args, .{ .env = env });
}

test "layers, a variant, an encrypted file, and the environment, each with its origin" {
    const result = try runHere(&.{
        "show", "-f", "examples/settings/app.toml", "--env", "production",
    }, &.{ .{ "SETTINGS_PASSPHRASE", "example" }, .{ "SHOP_LOG_FORMAT", "json" } });
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    for ([_][]const u8{
        "server.port = 443  # file (app.production.toml)",
        "server.host = 0.0.0.0  # file (app.toml)",
        "database.password = <redacted>  # file (secrets.toml.enc)",
        "log.format = json  # env (SHOP_LOG_FORMAT)",
        "server.timeout = 30s  # default",
    }) |line| {
        testing.expect(std.mem.indexOf(u8, result.out, line) != null) catch |err| {
            std.debug.print("missing {s} in\n{s}", .{ line, result.out });
            return err;
        };
    }
}

test "a wrong passphrase, and a profile" {
    const wrong = try runHere(&.{ "show", "-f", "examples/settings/app.toml" }, &.{
        .{ "SETTINGS_PASSPHRASE", "guess" },
    });
    defer wrong.deinit();
    try testing.expectEqual(1, wrong.status);
    const profiled = &.{ "show", "-f", "examples/settings/app.toml", "-p", "debug" };
    const debug = try runHere(profiled, &.{});
    defer debug.deinit();
    try testing.expect(std.mem.indexOf(u8, debug.out, "log.level = debug  # profile") != null);
}

test "check reports every problem, located" {
    const result = try runHere(&.{ "check", "-f", "examples/settings/broken.toml" }, &.{});
    defer result.deinit();
    try testing.expectEqual(1, result.status);
    for ([_][]const u8{
        "warning: broken.toml:4:19: server.request_timeout: renamed; use server.timeout",
        "broken.toml:3:8: server.port: integer out of range for u16",
        "  3 | port = 70000",
        "broken.toml:4:19: server.request_timeout: invalid value",
        "broken.toml:7:9: log.level: expected one of: debug, info, warn, error",
        "3 problems",
    }) |line| {
        testing.expect(std.mem.indexOf(u8, result.err, line) != null) catch |err| {
            std.debug.print("missing {s} in\n{s}", .{ line, result.err });
            return err;
        };
    }
    const good = try runHere(&.{ "check", "-f", "examples/settings/app.toml" }, &.{});
    defer good.deinit();
    try good.expect(0, "app.toml: ok\n", "");
}

test "set keeps comments, refuses bad values, and a dry run shows the change" {
    const dry = try runHere(&.{
        "set", "server.port", "9090", "--dry-run", "-f", "examples/settings/app.toml",
    }, &.{});
    defer dry.deinit();
    try dry.expect(0, "~ server.port = 8080 -> 9090\n", "");
    const refused = try runHere(&.{
        "set", "server.port", "0", "-f", "examples/settings/app.toml",
    }, &.{});
    defer refused.deinit();
    try testing.expectEqual(1, refused.status);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "# kept\n[server]\nport = 8080 # also kept\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.toml", .data = original });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const edited = try cfg.edit.apply(arena.allocator(), .toml, original, .{ .set = .{
        .key = "server.port",
        .value = .{ .int = 9090 },
    } });
    try testing.expectEqualStrings("# kept\n[server]\nport = 9090 # also kept\n", edited.?);
}

test "migrate upgrades a version 1 file" {
    const args = &.{ "migrate", "-f", "examples/settings/old.toml", "--dry-run" };
    const result = try runHere(args, &.{});
    defer result.deinit();
    try result.expect(0,
        \\- debug = true
        \\- host = 0.0.0.0
        \\+ log.level = debug
        \\- port = 8080
        \\+ schema_version = 3
        \\+ server.host = 0.0.0.0
        \\+ server.port = 8080
        \\
    , "");
}

test "seal makes an envelope show can open" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const envelope = try cfg.encrypted.encrypt(a, testing.io, "x = 1\n", "pw", .toml, .{ .m = 8 });
    const opened = try cfg.encrypted.decrypt(a, testing.io, envelope, "pw");
    try testing.expectEqualStrings("x = 1\n", opened.plaintext);
}
