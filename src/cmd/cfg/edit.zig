//! Editing commands: `set` and `unset`, which change a config file in place.
//!
//! The file is changed in place where `cfg.edit` can do it (any format, though not every
//! change), keeping its comments and layout. Otherwise it is parsed, changed, and written back
//! whole in its own format, with a warning when that loses comments. Either way the write is
//! atomic.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const cfg = @import("cfg");
const load = @import("load.zig");

const group = "Edit Commands";

const SetFlags = struct {
    string: bool = false,
};
const set_flags = cli.flags(SetFlags, field.Set(.{field.Spec(SetFlags){ .fields = .{
    .string = .{ .help = "Store the value as a string instead of inferring its type" },
} }}), .{ .fields = .{
    .string = .{ .short = 's' },
} });

pub const set = cli.command(.{
    .name = "set",
    .summary = "Set a value in the config file",
    .description =
    \\Set a key in the file named by the first --config, or the discovered termancy.* file.
    \\The value's type is inferred: true/false, integers, and decimals are typed, null is
    \\null, a TOML date or time (2024-01-01, 07:32:00) is a date-time, anything else is a
    \\string. --string keeps it a string. A missing file is created.
    ,
    .group = group,
    .flags = set_flags,
    .args = .{
        .min = 2,
        .max = 2,
        .usage = "<key> <value>",
        .complete = load.completeFileKeys,
    },
    .examples =
    \\termancy cfg set server.port 9090 -c app.toml
    \\termancy cfg set version 1.10 --string -c app.yaml
    ,
    .run = runSet,
});

fn runSet(ctx: *cli.Context, flags: SetFlags) !void {
    const global = try ctx.flags(load.Global);
    const file = try load.targetFile(ctx, global);
    var document = try Document.read(ctx, file, .create);
    const key = ctx.args[0];
    const value: cfg.Value = if (flags.string)
        .{ .string = ctx.args[1] }
    else
        cfg.infer(ctx.args[1]);
    document.tree.put(ctx.arena, key, value) catch |err| switch (err) {
        error.InvalidPath => return ctx.fail("invalid key \"{s}\"", .{key}),
        error.IndexOutOfRange => return ctx.fail(
            "\"{s}\" indexes past the end of an array",
            .{key},
        ),
        error.NotATable => return ctx.fail("\"{s}\" crosses a value that is not a table", .{key}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    try document.save(ctx, .{ .set = .{ .key = key, .value = value } });
}

pub const unset = cli.command(.{
    .name = "unset",
    .summary = "Remove a key from the config file",
    .group = group,
    .aliases = &.{"rm"},
    .args = .{ .min = 1, .max = 1, .usage = "<key>", .complete = load.completeFileKeys },
    .run = runUnset,
});

fn runUnset(ctx: *cli.Context) !void {
    const global = try ctx.flags(load.Global);
    const file = try load.targetFile(ctx, global);
    var document = try Document.read(ctx, file, .must_exist);
    const key = ctx.args[0];
    if (!document.tree.remove(key)) {
        return ctx.fail("key \"{s}\" is not set in {s}", .{ key, file });
    }
    try document.save(ctx, .{ .unset = key });
}

/// A config file read for editing.
pub const Document = struct {
    file: []const u8,
    format: cfg.Format,
    /// Empty for a file that does not exist yet.
    source: []const u8,
    tree: cfg.Value,

    const Missing = enum { create, must_exist };

    pub fn read(ctx: *cli.Context, file: []const u8, missing: Missing) !Document {
        const format = cfg.Format.fromPath(file) orelse {
            return ctx.fail("{s}: " ++ load.unknown_format, .{file});
        };
        const exists = if (std.Io.Dir.cwd().access(ctx.io, file, .{})) true else |_| false;
        if (!exists and missing == .create) {
            return .{ .file = file, .format = format, .source = "", .tree = .empty_table };
        }
        const source = try load.readSource(ctx, file);
        var diag: cfg.Diagnostic = .{};
        const tree = format.parse(ctx.arena, source, &diag) catch |err| switch (err) {
            error.SyntaxError => return ctx.fail("{s}:{f}", .{ file, diag }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .file = file, .format = format, .source = source, .tree = tree };
    }

    /// Writes the document with `change`, which `tree` already has, applied: in place when
    /// possible, else the whole tree.
    pub fn save(document: Document, ctx: *cli.Context, change: cfg.edit.Change) !void {
        if (document.source.len > 0) {
            if (try cfg.edit.apply(ctx.arena, document.format, document.source, change)) |edited| {
                return load.writeFileAtomic(ctx, document.file, edited);
            }
        }
        if (hasComments(document.source, document.format)) {
            ctx.warn("{s}: comments are not preserved", .{document.file});
        }
        const data = try load.rewrite(ctx, document.tree, document.format, document.source);
        try load.writeFileAtomic(ctx, document.file, data);
    }
};

/// Whether any line of `source` is a comment in `format`.
pub fn hasComments(source: []const u8, format: cfg.Format) bool {
    const markers: []const []const u8 = switch (format) {
        .json => return false,
        .zon, .jsonc => &.{ "//", "/*" },
        .ini => &.{ ";", "#" },
        .toml, .yaml, .dotenv => &.{"#"},
    };
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trimStart(u8, line, " \t");
        for (markers) |marker| if (std.mem.startsWith(u8, text, marker)) return true;
    }
    return false;
}

test hasComments {
    try std.testing.expect(hasComments("a = 1\n  # note\n", .toml));
    try std.testing.expect(!hasComments("a = '#'\n", .toml));
    try std.testing.expect(!hasComments("# not json", .json));
    try std.testing.expect(hasComments(".{\n    // note\n    .a = 1,\n}\n", .zon));
    try std.testing.expect(!hasComments(".{ .url = \"http://x\" }\n", .zon));
    try std.testing.expect(hasComments("; note\na = 1\n", .ini));
    try std.testing.expect(hasComments("{\n  /* note */\n}\n", .jsonc));
}
