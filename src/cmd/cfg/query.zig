//! Reading commands: `get`, `keys`, `show`, `explain`.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const cfg = @import("cfg");
const load = @import("load.zig");

const group = "Query Commands";

pub const get = cli.command(.{
    .name = "get",
    .summary = "Print one value",
    .description =
    \\Print the effective value of a key. Scalars print bare; tables and arrays print in
    \\the --output format (YAML for text).
    ,
    .group = group,
    .flags = get_flags,
    .args = .{ .min = 1, .max = 1, .usage = "<key>", .complete = load.completeKeys },
    .examples =
    \\termancy cfg get server.port --default 8080
    \\termancy cfg get servers.0.host -c prod.toml
    \\termancy cfg get server -o json
    ,
    .run = runGet,
});

/// What `get --as` checks a value as.
const Kind = enum { string, int, float, bool, duration, bytes, list };

const GetFlags = struct {
    default: ?[]const u8 = null,
    raw: bool = false,
    as: ?Kind = null,
};
const get_flags = cli.flags(GetFlags, field.Set(.{field.Spec(GetFlags){ .fields = .{
    .as = .{ .help = "Fail unless the value is one of these, and print it as one" },
    .default = .{ .help = "Print this instead of failing when the key is unset" },
    .raw = .{ .help = "Print a scalar bare, without the output format's quoting" },
} }}), .{ .fields = .{
    .as = .{ .value_name = "type" },
    .default = .{ .value_name = "value" },
} });

fn runGet(ctx: *cli.Context, flags: GetFlags) !void {
    const global = try ctx.flags(load.Global);
    var config = try load.load(ctx, global);
    defer config.deinit();
    const key = ctx.args[0];
    const value = try config.get(key) orelse blk: {
        const fallback = flags.default orelse return ctx.fail("key \"{s}\" is not set", .{key});
        break :blk cfg.infer(fallback);
    };
    const typed = if (flags.as) |kind| try asKind(ctx, key, value, kind) else value;
    if (flags.raw and typed != .table and typed != .array) {
        // `{f}` writes strings without quotes and numbers as numbers.
        return ctx.out.print("{f}\n", .{typed});
    }
    try load.writeValue(ctx, typed, global.output);
}

/// `value` decoded as `kind` (which coerces text, as decoding does) and encoded again, so
/// `"8080"` prints as `8080` and `90m` as `1h30m`.
fn asKind(ctx: *cli.Context, key: []const u8, value: cfg.Value, kind: Kind) !cfg.Value {
    var diag: cfg.Diagnostic = .{};
    const encoded = switch (kind) {
        inline else => |k| encode: {
            const T = switch (k) {
                .string => []const u8,
                .int => i64,
                .float => f64,
                .bool => bool,
                .duration => cfg.Duration,
                .bytes => cfg.ByteSize,
                .list => []const []const u8,
            };
            const decoded = cfg.decode(T, ctx.arena, value, .{}, &diag) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ctx.fail("{s}: {s}", .{ key, diag.message }),
            };
            break :encode try cfg.encode(ctx.arena, decoded);
        },
    };
    return encoded;
}

/// The byte that ends one line of output: NUL under `--null`, else a newline.
pub fn terminator(nul: bool) u8 {
    return if (nul) 0 else '\n';
}

pub const keys = cli.command(.{
    .name = "keys",
    .summary = "List every key that has a value",
    .group = group,
    .flags = keys_flags,
    .args = .{ .max = 1, .usage = "[prefix]", .complete = load.completeKeys },
    .run = runKeys,
});

const KeysFlags = struct {
    null: bool = false,
};
const keys_flags = cli.flags(KeysFlags, field.Set(.{field.Spec(KeysFlags){ .fields = .{
    .null = .{ .help = "End lines with NUL, not newline (for xargs -0)" },
} }}), .{ .fields = .{
    .null = .{ .short = '0' },
} });

fn runKeys(ctx: *cli.Context, flags: KeysFlags) !void {
    const global = try ctx.flags(load.Global);
    if (flags.null and global.output != .text) {
        const output = @tagName(global.output);
        return ctx.usageError("--null applies to text output; drop -o {s}", .{output});
    }
    var config = try load.load(ctx, global);
    defer config.deinit();
    const prefix = if (ctx.args.len > 0) ctx.args[0] else "";
    var list: cfg.Array = .empty;
    for (try config.keys()) |key| {
        if (!underPrefix(key, prefix)) continue;
        if (global.output == .text) {
            try ctx.out.print("{s}{c}", .{ key, terminator(flags.null) });
        } else {
            try list.append(ctx.arena, .{ .string = key });
        }
    }
    if (global.output != .text) try load.writeValue(ctx, .{ .array = list }, global.output);
}

/// Whether `key` is a secret or lies under one (a secret table or array).
fn underSecret(config: *const cfg.Config, key: []const u8) bool {
    for (config.secrets.keys()) |secret| {
        if (key.len < secret.len) continue;
        const head = key[0..secret.len];
        const same = if (config.case_insensitive)
            std.ascii.eqlIgnoreCase(head, secret)
        else
            std.mem.eql(u8, head, secret);
        if (same and (key.len == secret.len or key[secret.len] == '.')) return true;
    }
    return false;
}

/// `server.port` is under `server` and `server.port`, but not under `serv`.
fn underPrefix(key: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!std.mem.startsWith(u8, key, prefix)) return false;
    return key.len == prefix.len or key[prefix.len] == '.';
}

const ShowFlags = struct {
    secret: []const []const u8 = &.{},
    reveal: bool = false,
    layer: ?cfg.Config.Layer = null,
};
const show_flags = cli.flags(ShowFlags, field.Set(.{field.Spec(ShowFlags){ .fields = .{
    .secret = .{ .help = "Treat this key as secret and redact it; repeatable" },
    .reveal = .{ .help = "Do not redact secrets" },
    .layer = .{ .help = "Show one layer instead of the effective configuration" },
} }}), .{ .fields = .{
    .secret = .{ .value_name = "key" },
} });

pub const show = cli.command(.{
    .name = "show",
    .summary = "Print the whole effective configuration",
    .group = group,
    .flags = show_flags,
    .examples =
    \\termancy cfg show -c base.toml -c local.yaml -o toml
    \\termancy cfg show --secret db.password
    \\termancy cfg show --layer env --env-prefix APP
    ,
    .run = runShow,
});

fn runShow(ctx: *cli.Context, flags: ShowFlags) !void {
    const global = try ctx.flags(load.Global);
    var config = try load.load(ctx, global);
    defer config.deinit();
    for (flags.secret) |key| try config.markSecret(key);
    if (global.output == .systemd) {
        return load.writeSystemd(ctx, try config.snapshot(.{
            .layer = flags.layer,
            .redact = !flags.reveal,
        }));
    }
    const format: cfg.Format = switch (global.output) {
        .text, .yaml => .yaml,
        .json => .json,
        .toml => .toml,
        .zon => .zon,
        .env => .dotenv,
        .ini => .ini,
        .systemd => unreachable, // Written above.
    };
    // Rendered in full first, so a configuration the format cannot hold prints nothing.
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    config.write(&out.writer, format, .{
        .layer = flags.layer,
        .redact = !flags.reveal,
    }) catch |err| switch (err) {
        error.Unrepresentable => return ctx.fail(
            "the configuration cannot be written as {s}",
            .{load.formatName(format)},
        ),
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    try ctx.out.writeAll(out.written());
}

pub const explain = cli.command(.{
    .name = "explain",
    .summary = "Show where each value comes from",
    .description =
    \\For every key, or the keys under a prefix, print the effective value and the layer
    \\that supplied it: default, file, profile, env, flag, or override (--set). Secrets
    \\(from encrypted files, ${secret:...}, or --secret) are redacted unless --reveal.
    ,
    .group = group,
    .flags = explain_flags,
    .args = .{ .max = 1, .usage = "[prefix]", .complete = load.completeKeys },
    .run = runExplain,
});

const ExplainFlags = struct {
    secret: []const []const u8 = &.{},
    reveal: bool = false,
};
const explain_flags = cli.flags(ExplainFlags, field.Set(.{field.Spec(ExplainFlags){ .fields = .{
    .secret = .{ .help = "Treat this key as secret and redact it; repeatable" },
    .reveal = .{ .help = "Do not redact secrets" },
} }}), .{ .fields = .{
    .secret = .{ .value_name = "key" },
} });

fn runExplain(ctx: *cli.Context, flags: ExplainFlags) !void {
    const global = try ctx.flags(load.Global);
    var config = try load.load(ctx, global);
    defer config.deinit();
    for (flags.secret) |key| try config.markSecret(key);
    const prefix = if (ctx.args.len > 0) ctx.args[0] else "";

    var rows: std.ArrayList(Row) = .empty;
    for (try config.keys()) |key| {
        if (!underPrefix(key, prefix)) continue;
        const value: cfg.Value = if (!flags.reveal and underSecret(&config, key))
            .{ .string = cfg.Config.redacted }
        else
            (try config.get(key)).?;
        const origin = (try config.explain(key)) orelse cfg.Config.Origin{ .layer = .default };
        try rows.append(ctx.arena, .{
            .key = key,
            .typed = try value.clone(ctx.arena),
            .value = try std.fmt.allocPrint(ctx.arena, "{f}", .{value}),
            .origin = try std.fmt.allocPrint(ctx.arena, "{f}", .{origin}),
            .layer = origin.layer,
            .source = origin.source,
        });
    }
    if (rows.items.len == 0 and prefix.len > 0) return ctx.fail("no keys under \"{s}\"", .{prefix});
    if (global.output == .text) return writeTable(ctx.out, rows.items);

    var list: cfg.Array = .empty;
    for (rows.items) |row| {
        var entry: cfg.Value = .empty_table;
        try entry.put(ctx.arena, "key", .{ .string = row.key });
        try entry.put(ctx.arena, "value", row.typed);
        try entry.put(ctx.arena, "layer", .{ .string = @tagName(row.layer) });
        try entry.put(ctx.arena, "source", .{ .string = row.source });
        try list.append(ctx.arena, entry);
    }
    try load.writeValue(ctx, .{ .array = list }, global.output);
}

/// The shell `env` writes for.
const Shell = enum { sh, fish, powershell };

const EnvFlags = struct {
    prefix: ?[]const u8 = null,
    shell: Shell = .sh,
};
const env_flags = cli.flags(EnvFlags, field.Set(.{field.Spec(EnvFlags){ .fields = .{
    .prefix = .{ .help = "Prepend this and _ to every name, as --env-prefix reads them" },
    .shell = .{ .help = "Write commands for this shell" },
} }}), .{ .fields = .{
    .prefix = .{ .value_name = "prefix" },
} });

pub const env = cli.command(.{
    .name = "env",
    .summary = "Print the configuration as shell variable exports",
    .description =
    \\Print one command per key that sets an environment variable to the effective value,
    \\named the way --env-prefix reads it: server.port with --prefix APP is
    \\APP_SERVER_PORT. Arrays of scalars join with commas; null values and empty tables
    \\are left out. Values are single-quoted, so evaluating the output runs nothing in them.
    \\
    \\Fails, printing nothing, when two keys map to the same name or a name would not be a
    \\valid variable name.
    ,
    .group = group,
    .flags = env_flags,
    .examples =
    \\eval "$(termancy cfg env --prefix APP)"
    \\termancy cfg env --prefix APP --shell fish | source
    \\termancy cfg env --shell powershell | Out-String | Invoke-Expression
    ,
    .run = runEnv,
});

fn runEnv(ctx: *cli.Context, flags: EnvFlags) !void {
    const global = try ctx.flags(load.Global);
    if (global.output != .text) {
        const output = @tagName(global.output);
        return ctx.usageError("env writes shell commands; drop -o {s}", .{output});
    }
    var config = try load.load(ctx, global);
    defer config.deinit();
    const prefix = flags.prefix orelse "";
    // Rendered in full first, so a failure prints nothing.
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try config.keys()) |key| {
        const value = (try config.get(key)).?;
        if (value == .null or value == .table) continue;
        const name = try cfg.path.toEnvName(ctx.arena, prefix, key);
        if (!isVariableName(name)) {
            return ctx.fail("{s}: \"{s}\" is not a valid variable name", .{ key, name });
        }
        const entry = try names.getOrPut(ctx.arena, name);
        if (entry.found_existing) {
            return ctx.fail("{s} and {s} both map to {s}", .{ entry.value_ptr.*, key, name });
        }
        entry.value_ptr.* = key;
        const text = shellText(ctx.arena, value) catch |err| switch (err) {
            error.Unrepresentable => {
                return ctx.fail("{s}: an array of arrays or tables is not one variable", .{key});
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        writeAssignment(&out.writer, flags.shell, name, text) catch return error.OutOfMemory;
    }
    try ctx.out.writeAll(out.written());
}

/// A value as the text of one variable: scalars as `{f}` writes them, arrays of scalars
/// joined with commas (as dotenv writes them).
fn shellText(
    arena: std.mem.Allocator,
    value: cfg.Value,
) error{ Unrepresentable, OutOfMemory }![]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    switch (value) {
        .array => |a| for (a.items, 0..) |item, i| {
            if (item == .array or item == .table) return error.Unrepresentable;
            if (i > 0) text.writer.writeByte(',') catch return error.OutOfMemory;
            text.writer.print("{f}", .{item}) catch return error.OutOfMemory;
        },
        else => text.writer.print("{f}", .{value}) catch return error.OutOfMemory,
    }
    return text.written();
}

fn isVariableName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// One assignment, single-quoted for `shell` so that nothing in `text` is expanded.
fn writeAssignment(
    w: *std.Io.Writer,
    shell: Shell,
    name: []const u8,
    text: []const u8,
) std.Io.Writer.Error!void {
    switch (shell) {
        .sh => {
            try w.print("export {s}='", .{name});
            for (text) |c| if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
            try w.writeAll("'\n");
        },
        .fish => {
            try w.print("set -gx {s} '", .{name});
            for (text) |c| switch (c) {
                '\'', '\\' => {
                    try w.writeByte('\\');
                    try w.writeByte(c);
                },
                else => try w.writeByte(c),
            };
            try w.writeAll("'\n");
        },
        .powershell => {
            try w.print("$env:{s} = '", .{name});
            // PowerShell also closes a single-quoted string at the typographic quotes.
            var view = std.unicode.Utf8View.init(text) catch return writeBytesQuoted(w, text);
            var it = view.iterator();
            while (it.nextCodepointSlice()) |cp| {
                if (std.mem.eql(u8, cp, "'") or isTypographicQuote(cp)) try w.writeAll(cp);
                try w.writeAll(cp);
            }
            try w.writeAll("'\n");
        },
    }
}

fn writeBytesQuoted(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| if (c == '\'') try w.writeAll("''") else try w.writeByte(c);
    try w.writeAll("'\n");
}

fn isTypographicQuote(cp: []const u8) bool {
    for ([_][]const u8{ "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) |q| {
        if (std.mem.eql(u8, cp, q)) return true;
    }
    return false;
}

const Row = struct {
    key: []const u8,
    /// The value itself, for the structured outputs.
    typed: cfg.Value,
    /// The value as one line of text, for the table.
    value: []const u8,
    origin: []const u8,
    layer: cfg.Config.Layer,
    source: []const u8,
};

fn writeTable(writer: *std.Io.Writer, rows: []const Row) !void {
    var key_width: usize = "KEY".len;
    var value_width: usize = "VALUE".len;
    for (rows) |row| {
        key_width = @max(key_width, row.key.len);
        value_width = @max(value_width, row.value.len);
    }
    try writeRow(writer, "KEY", "VALUE", "SOURCE", key_width, value_width);
    for (rows) |row| try writeRow(writer, row.key, row.value, row.origin, key_width, value_width);
}

fn writeRow(
    writer: *std.Io.Writer,
    key: []const u8,
    value: []const u8,
    origin: []const u8,
    key_width: usize,
    value_width: usize,
) !void {
    try writer.writeAll(key);
    try writer.splatByteAll(' ', key_width - key.len + 2);
    try writer.writeAll(value);
    try writer.splatByteAll(' ', value_width - value.len + 2);
    try writer.print("{s}\n", .{origin});
}

test underPrefix {
    try std.testing.expect(underPrefix("server.port", "server"));
    try std.testing.expect(underPrefix("server.port", "server.port"));
    try std.testing.expect(!underPrefix("server.port", "serv"));
    try std.testing.expect(underPrefix("x", ""));
}

test isVariableName {
    try std.testing.expect(isVariableName("APP_PORT"));
    try std.testing.expect(isVariableName("_x1"));
    try std.testing.expect(!isVariableName("1X"));
    try std.testing.expect(!isVariableName(""));
}

test writeAssignment {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const text = "it's $(id) `x` \\ \u{2019}";
    try writeAssignment(&out.writer, .sh, "A", text);
    try writeAssignment(&out.writer, .fish, "A", text);
    try writeAssignment(&out.writer, .powershell, "A", text);
    try std.testing.expectEqualStrings(
        "export A='it'\\''s $(id) `x` \\ \u{2019}'\n" ++
            "set -gx A 'it\\'s $(id) `x` \\\\ \u{2019}'\n" ++
            "$env:A = 'it''s $(id) `x` \\ \u{2019}\u{2019}'\n",
        out.written(),
    );
}
