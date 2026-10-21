//! The global flags, and turning them into a loaded `cfg.Config`.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const cfg = @import("cfg");
const sys = @import("sys");

/// How results are printed. `text` is for people: scalars bare, structures as YAML.
pub const Output = enum { text, json, yaml, toml, zon, env, ini, systemd };

/// Flags every command accepts.
pub const Global = struct {
    config: []const []const u8 = &.{},
    profile: ?[]const u8 = null,
    env_prefix: ?[]const u8 = null,
    set: []const []const u8 = &.{},
    output: Output = .text,
};
pub const global_flags = cli.flags(Global, field.Set(.{field.Spec(Global){ .fields = .{
    .config = .{
        .help = "Config file to load; repeatable, later files win (default: discover termancy.*)",
    },
    .profile = .{ .help = "Apply the profiles.<name> section" },
    .env_prefix = .{ .help = "Read key a.b from the variable <PREFIX>_A_B" },
    .set = .{ .help = "Override a value; repeatable" },
    .output = .{ .help = "Output format" },
} }}), .{ .fields = .{
    .config = .{
        .short = 'c',
        .value_name = "path",
        .env = "TERMANCY_CONFIG",
        .split = ',',
        .complete = .from(completeConfigFiles),
    },
    .profile = .{
        .value_name = "name",
        .env = "TERMANCY_PROFILE",
        .complete = .from(completeProfiles),
    },
    .env_prefix = .{ .value_name = "prefix" },
    .set = .{ .value_name = "key=value" },
    .output = .{ .short = 'o' },
} });

/// The message for a file whose extension names no supported format.
pub const unknown_format =
    "unknown format (use .toml, .yaml, .json, .jsonc, .zon, .env, or .ini)";

/// Where `termancy` looks for `termancy.toml`, `termancy.yaml`, `termancy.json`, `termancy.zon`, `termancy.env`,
/// `termancy.jsonc`, or `termancy.ini`
/// when no `--config` is given.
pub const search_dirs = [_][]const u8{ ".", "$XDG_CONFIG_HOME/termancy", "~/.config/termancy" };

/// Loads the configuration the global flags describe. The caller owns the result and must
/// `deinit` it. Failures are reported through `ctx.fail`.
pub fn load(ctx: *cli.Context, global: Global) !cfg.Config {
    var config: cfg.Config = .init(ctx.gpa);
    errdefer config.deinit();
    config.useEnv(ctx.environ);
    if (ctx.environ.get("TERMANCY_PASSPHRASE")) |passphrase| config.usePassphrase(passphrase);
    if (global.env_prefix) |prefix| try config.automaticEnv(prefix);

    const files = if (global.config.len > 0) global.config else discovered: {
        const found = try config.findFile(ctx.io, .{ .name = "termancy", .dirs = &search_dirs });
        if (found) |file| {
            ctx.log(.debug, "found {s}", .{file});
        } else ctx.log(.debug, "no termancy.* file in {s}, {s}, or {s}", .{
            search_dirs[0], search_dirs[1], search_dirs[2],
        });
        break :discovered if (found) |file| try ctx.arena.dupe([]const u8, &.{file}) else &.{};
    };
    for (files) |file| {
        try loadFile(ctx, &config, file);
        ctx.log(.debug, "loaded {s}", .{file});
    }

    if (global.profile) |profile| {
        if (!hasProfile(&config, profile)) {
            return ctx.fail("no profile \"{s}\" in the loaded files", .{profile});
        }
        try config.useProfile(profile);
        ctx.log(.debug, "profile {s}", .{profile});
    } else if (try currentProfile(&config)) |profile| {
        // Chosen with `termancy cfg profile use`; one since removed is ignored.
        if (hasProfile(&config, profile)) {
            try config.useProfile(profile);
            ctx.log(.debug, "profile {s}, chosen with termancy cfg profile use", .{profile});
        } else ctx.log(.debug, "no profile {s} any more; none applied", .{profile});
    }
    for (global.set) |assignment| {
        const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse {
            return ctx.usageError("--set expects key=value, got \"{s}\"", .{assignment});
        };
        const key = assignment[0..eq];
        config.set(key, cfg.infer(assignment[eq + 1 ..])) catch |err| switch (err) {
            error.InvalidPath => return ctx.usageError("--set: invalid key \"{s}\"", .{key}),
            error.IndexOutOfRange => return ctx.fail(
                "--set: \"{s}\" indexes past the end of an array",
                .{key},
            ),
            error.NotATable => return ctx.fail(
                "--set: \"{s}\" crosses a value that is not a table",
                .{key},
            ),
            else => |e| return e,
        };
    }
    return config;
}

fn loadFile(ctx: *cli.Context, config: *cfg.Config, file: []const u8) !void {
    if (isUrl(file)) return loadUrl(ctx, config, file);
    var diag: cfg.Diagnostic = .{};
    config.loadFile(ctx.io, .cwd(), file, null, &diag) catch |err| switch (err) {
        error.SyntaxError => return ctx.fail("{f}", .{diag}),
        error.SecretNotFound => return ctx.fail("{s}: {s}: {s}", .{ file, diag.key, diag.message }),
        error.PassphraseRequired => return ctx.fail(
            "{s}: encrypted; set TERMANCY_PASSPHRASE to read it",
            .{file},
        ),
        error.WrongPassphrase => return ctx.fail(
            "{s}: wrong passphrase, or the file was changed",
            .{file},
        ),
        error.FileNotFound => return ctx.fail("{s}: no such file", .{file}),
        error.UnknownFormat => return ctx.fail(
            "{s}: " ++ unknown_format,
            .{file},
        ),
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return ctx.fail("{s}: {s}", .{ file, @errorName(e) }),
    };
}

fn isUrl(file: []const u8) bool {
    return std.mem.startsWith(u8, file, "https://") or std.mem.startsWith(u8, file, "http://");
}

/// Loads a configuration file served over HTTP, through a cache in termancy's cache
/// directory: fetched again only when it changed, and read from the cache (with a
/// warning) when the server cannot be reached.
fn loadUrl(ctx: *cli.Context, config: *cfg.Config, url: []const u8) !void {
    const path = (std.Uri.parse(url) catch return ctx.fail("{s}: not a URL", .{url})).path;
    var path_buffer: [512]u8 = undefined;
    const path_text = path.toRaw(&path_buffer) catch "";
    const format = cfg.Format.fromPath(path_text) orelse
        return ctx.fail("{s}: " ++ unknown_format, .{url});
    const cache_root = sys.dirs.nativePath(ctx.arena, ctx.environ, .cache, "termancy") catch
        return ctx.fail("{s}: no cache directory (HOME is not set)", .{url});
    const cache_path = try std.fs.path.join(ctx.arena, &.{ cache_root, "remote" });
    var cache = std.Io.Dir.cwd().createDirPathOpen(ctx.io, cache_path, .{}) catch |err|
        return ctx.fail("{s}: {s}", .{ cache_path, @errorName(err) });
    defer cache.close(ctx.io);
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    var http: sys.remote.HttpFetcher = .{ .client = &client };
    const file = sys.remote.get(
        ctx.io,
        ctx.gpa,
        http.fetcher(),
        cache,
        url,
        cfg.Config.max_file_size,
    ) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotFound => ctx.fail("{s}: not found", .{url}),
            error.TooLarge => ctx.fail("{s}: too large", .{url}),
            error.FetchFailed => ctx.fail("{s}: cannot be fetched, and is not cached", .{url}),
        };
    defer ctx.gpa.free(file.bytes);
    if (file.stale) ctx.warn("{s}: cannot be fetched; using the copy cached earlier", .{url});
    var diag: cfg.Diagnostic = .{};
    config.loadSource(url, file.bytes, format, &diag) catch |err| switch (err) {
        error.SyntaxError => return ctx.fail("{s}:{f}", .{ url, diag }),
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// The key `termancy cfg profile use` records the default profile under.
pub const current_profile_key = "current_profile";

/// The profile `termancy cfg profile use` chose, if any.
pub fn currentProfile(config: *cfg.Config) !?[]const u8 {
    const value = try config.get(current_profile_key) orelse return null;
    // A name that reads like a date was written bare before `cfg set` quoted strings.
    return switch (value) {
        .string, .datetime => |name| name,
        else => null,
    };
}

pub fn hasProfile(config: *cfg.Config, profile: []const u8) bool {
    for (config.profileNames()) |name| {
        if (std.mem.eql(u8, name, profile)) return true;
    }
    return false;
}

/// The file an editing command changes: the first `--config`, else the discovered file.
pub fn targetFile(ctx: *cli.Context, global: Global) ![]const u8 {
    if (global.config.len > 0) return global.config[0];
    var config: cfg.Config = .init(ctx.gpa);
    defer config.deinit();
    config.useEnv(ctx.environ);
    const found = try config.findFile(
        ctx.io,
        .{ .name = "termancy", .dirs = &search_dirs },
    ) orelse {
        return ctx.fail("no config file found; pass --config <path>", .{});
    };
    ctx.log(.debug, "found {s}", .{found});
    return ctx.arena.dupe(u8, found);
}

/// Reads and parses one file into a tree in `ctx.arena`.
pub fn parseFile(ctx: *cli.Context, file: []const u8, format: ?cfg.Format) !cfg.Value {
    const resolved = format orelse cfg.Format.fromPath(file) orelse {
        return ctx.fail("{s}: " ++ unknown_format, .{file});
    };
    return parseText(ctx, file, try readSource(ctx, file), resolved);
}

/// Parses `source`, the text of `file`, into a tree in `ctx.arena`.
pub fn parseText(
    ctx: *cli.Context,
    file: []const u8,
    source: []const u8,
    format: cfg.Format,
) !cfg.Value {
    var diag: cfg.Diagnostic = .{};
    return format.parse(ctx.arena, source, &diag) catch |err| switch (err) {
        error.SyntaxError => ctx.fail("{s}:{f}", .{ file, diag }),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The bytes of `file`, or of standard input for `-`.
pub fn readSource(ctx: *cli.Context, file: []const u8) ![]const u8 {
    const limit: std.Io.Limit = .limited(cfg.Config.max_file_size);
    if (std.mem.eql(u8, file, "-")) {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(ctx.io, &buffer);
        return reader.interface.allocRemaining(ctx.arena, limit) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => |e| ctx.fail("standard input: {s}", .{@errorName(e)}),
        };
    }
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, file, ctx.arena, limit) catch |err| switch (err) {
        error.FileNotFound => ctx.fail("{s}: no such file", .{file}),
        error.OutOfMemory => error.OutOfMemory,
        else => |e| ctx.fail("{s}: {s}", .{ file, @errorName(e) }),
    };
}

/// Writes `value` in the requested output format. Nothing is written unless all of it can
/// be: a value the format cannot represent fails without partial output.
pub fn writeValue(ctx: *cli.Context, value: cfg.Value, output: Output) !void {
    switch (output) {
        .text => switch (value) {
            .table, .array => try ctx.out.writeAll(try encode(ctx, value, .yaml)),
            else => try ctx.out.print("{f}\n", .{value}),
        },
        .json => try ctx.out.writeAll(try encode(ctx, value, .json)),
        .yaml => try ctx.out.writeAll(try encode(ctx, value, .yaml)),
        .toml => try ctx.out.writeAll(try encode(ctx, value, .toml)),
        .zon => try ctx.out.writeAll(try encode(ctx, value, .zon)),
        .env => try ctx.out.writeAll(try encode(ctx, value, .dotenv)),
        .ini => try ctx.out.writeAll(try encode(ctx, value, .ini)),
        .systemd => try writeSystemd(ctx, value),
    }
}

/// Writes `value`, a table, as a systemd drop-in: `[Service]` and one `Environment=` line
/// per leaf, named as `-o env` names them (`SERVER__PORT`). Nothing is written unless all of
/// it can be.
pub fn writeSystemd(ctx: *cli.Context, value: cfg.Value) !void {
    if (value != .table) return ctx.fail("-o systemd needs a table", .{});
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    try w.writeAll("[Service]\n");
    var leaves: std.ArrayList([]const u8) = .empty;
    try value.leafPaths(ctx.arena, "", &leaves);
    for (leaves.items) |key| {
        const leaf = value.lookup(key).?;
        if (leaf == .null or leaf == .table) continue;
        var name: std.Io.Writer.Allocating = .init(ctx.arena);
        const segments = cfg.path.split(ctx.arena, key) catch unreachable; // From `leafPaths`.
        for (segments, 0..) |segment, i| {
            if (i > 0) try name.writer.writeAll("__");
            try cfg.dotenv.writeName(&name.writer, segment);
        }
        var text: std.Io.Writer.Allocating = .init(ctx.arena);
        switch (leaf) {
            .array => |a| for (a.items, 0..) |item, i| {
                if (item == .array or item == .table) {
                    const message = "{s}: an array of arrays or tables is not one variable";
                    return ctx.fail(message, .{key});
                }
                if (i > 0) try text.writer.writeByte(',');
                try text.writer.print("{f}", .{item});
            },
            else => try text.writer.print("{f}", .{leaf}),
        }
        try sys.daemon.writeSystemdEnvironment(w, name.written(), text.written());
    }
    try ctx.out.writeAll(out.written());
}

/// Writes `value` as `format` into a new string in `ctx.arena`.
pub fn encode(ctx: *cli.Context, value: cfg.Value, format: cfg.Format) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    format.write(&out.writer, value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.Unrepresentable => return ctx.fail(
            "this value cannot be written as {s}",
            .{formatName(format)},
        ),
    };
    return out.written();
}

/// `encode`, for a file being rewritten from `source`: keeps what the format can carry over,
/// such as TOML's inline tables.
pub fn rewrite(
    ctx: *cli.Context,
    value: cfg.Value,
    format: cfg.Format,
    source: []const u8,
) ![]const u8 {
    if (format != .toml) return encode(ctx, value, format);
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const inline_tables = try cfg.toml.inlineTables(ctx.arena, source);
    const options: cfg.toml.WriteOptions = .{ .inline_tables = inline_tables };
    cfg.toml.write(&out.writer, value, options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.Unrepresentable => return ctx.fail("this value cannot be written as toml", .{}),
    };
    return out.written();
}

/// The name of `format` as the command line spells it.
pub fn formatName(format: cfg.Format) []const u8 {
    return if (format == .dotenv) "env" else @tagName(format);
}

/// Replaces `file` with `data` atomically: readers see the old or the new file, never half.
/// The new file keeps the old one's permissions, so a `0600` file stays private.
pub fn writeFileAtomic(ctx: *cli.Context, file: []const u8, data: []const u8) !void {
    return writeFileAs(ctx, file, data, permissionsOf(ctx, file));
}

/// `writeFileAtomic` with the new file's `permissions` given.
pub fn writeFileAs(
    ctx: *cli.Context,
    file: []const u8,
    data: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    sys.files.writeAtomic(ctx.io, std.Io.Dir.cwd(), file, data, .{
        .permissions = permissions,
    }) catch |err| return ctx.fail("{s}: cannot write: {s}", .{ file, @errorName(err) });
}

/// The permissions of `file`, or the default for a new file when it does not exist.
pub fn permissionsOf(ctx: *cli.Context, file: []const u8) std.Io.File.Permissions {
    const stat = std.Io.Dir.cwd().statFile(ctx.io, file, .{}) catch return .default_file;
    return stat.permissions;
}

// -- Completion ------------------------------------------------------------------------
//
// Completers load what the flags typed so far describe (`-c`, `--set`, ...). Failures
// print nothing: `cli` discards the output and offers no candidates.

/// The effective keys, for the first positional.
pub fn completeKeys(ctx: *cli.Context, prefix: []const u8) ![]const cli.Candidate {
    _ = prefix;
    if (ctx.args.len > 0) return &.{};
    var config = try load(ctx, try ctx.flags(Global));
    defer config.deinit();
    return candidatesOf(ctx, try config.keys());
}

/// The keys of the file an editing command changes, for the first positional.
pub fn completeFileKeys(ctx: *cli.Context, prefix: []const u8) ![]const cli.Candidate {
    _ = prefix;
    if (ctx.args.len > 0) return &.{};
    const tree = try parseFile(ctx, try targetFile(ctx, try ctx.flags(Global)), null);
    var leaves: std.ArrayList([]const u8) = .empty;
    try tree.leafPaths(ctx.arena, "", &leaves);
    return candidatesOf(ctx, leaves.items);
}

/// Files in a format termancy reads, for `--config` and file arguments.
pub fn completeConfigFiles(ctx: *cli.Context, prefix: []const u8) ![]const cli.Candidate {
    _ = ctx;
    _ = prefix;
    return &config_files;
}

const config_files = [_]cli.Candidate{
    .files("toml"), .files("yaml"), .files("yml"),   .files("json"),
    .files("zon"),  .files("env"),  .files("jsonc"), .files("ini"),
};

pub fn completeProfiles(ctx: *cli.Context, prefix: []const u8) ![]const cli.Candidate {
    _ = prefix;
    var global = try ctx.flags(Global);
    global.profile = null; // A profile from TERMANCY_PROFILE that does not exist must not fail.
    var config = try load(ctx, global);
    defer config.deinit();
    return candidatesOf(ctx, config.profileNames());
}

/// Values are not shown as descriptions: they may be secrets.
fn candidatesOf(ctx: *cli.Context, names: []const []const u8) ![]const cli.Candidate {
    const out = try ctx.arena.alloc(cli.Candidate, names.len);
    for (out, names) |*candidate, name| candidate.* = .{ .value = try ctx.arena.dupe(u8, name) };
    return out;
}
