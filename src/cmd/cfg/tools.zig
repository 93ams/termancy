//! Commands for whole files: `merge`, `init`, `schema infer|check`, and `edit`.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const sys = @import("sys");
const load = @import("load.zig");
const files = @import("files.zig");

const group = "File Commands";

pub const merge = cli.command(.{
    .name = "merge",
    .summary = "Merge files into one",
    .description =
    \\Merge the files in order, later files winning, tables merging key by key, and print
    \\the result in the --output format (YAML for text). The files may be in different
    \\formats; profiles, the environment, and --set do not apply.
    ,
    .group = group,
    .args = .{ .min = 1, .max = null, .usage = "<file>...", .complete = load.completeConfigFiles },
    .examples =
    \\termancy cfg merge base.toml prod.yaml -o toml > merged.toml
    ,
    .run = runMerge,
});

fn runMerge(ctx: *cli.Context) !void {
    const global = try ctx.flags(load.Global);
    var merged: cfg.Value = .empty_table;
    for (ctx.args) |file| try merged.merge(ctx.arena, try load.parseFile(ctx, file, null));
    try load.writeValue(ctx, merged, if (global.output == .text) .yaml else global.output);
}

const InitFlags = struct {
    force: bool = false,
    schema: ?[]const u8 = null,
    pub const meta = .{
        .force = .{ .help = "Replace a file that exists" },
        .schema = .{
            .help = "Fill the file from this JSON Schema's defaults",
            .value_name = "file",
            .complete = load.completeConfigFiles,
        },
    };
};

pub const init = cli.command(.{
    .name = "init",
    .summary = "Write a starter config file",
    .description =
    \\Write [file] (default: termancy.toml), in the format its extension names: a short example,
    \\or with --schema, every property the schema declares, set to its default (or to an
    \\empty value of its type). Refuses to replace a file unless --force.
    ,
    .group = group,
    .flags = InitFlags,
    .args = .{ .max = 1, .usage = "[file]" },
    .examples =
    \\termancy cfg init
    \\termancy cfg init app.yaml --schema schema.json
    ,
    .run = runInit,
});

/// What `termancy cfg init` writes as TOML without a schema; other formats get the same keys.
const starter_toml =
    \\# Configuration for termancy: `termancy cfg show` prints it, `termancy cfg explain` says where each
    \\# value comes from. Environment variables override it with --env-prefix.
    \\name = "app"
    \\
    \\[server]
    \\host = "localhost"
    \\port = 8080
    \\
;

fn runInit(ctx: *cli.Context, flags: InitFlags) !void {
    const file = if (ctx.args.len > 0) ctx.args[0] else "termancy.toml";
    const format = cfg.Format.fromPath(file) orelse
        return ctx.fail("{s}: " ++ load.unknown_format, .{file});
    const exists = if (std.Io.Dir.cwd().access(ctx.io, file, .{})) true else |_| false;
    if (exists and !flags.force) {
        return ctx.fail("{s}: exists; pass --force to replace it", .{file});
    }
    const text = if (flags.schema) |schema_file| blk: {
        const schema = try load.parseFile(ctx, schema_file, null);
        break :blk try load.encode(ctx, try defaultsOf(ctx.arena, schema), format);
    } else if (format == .toml)
        starter_toml
    else
        try load.encode(ctx, try cfg.toml.parse(ctx.arena, starter_toml, null), format);
    try load.writeFileAtomic(ctx, file, text);
}

/// A document holding every property `schema` declares: its `default`, or an empty value
/// of its type.
fn defaultsOf(arena: std.mem.Allocator, schema: cfg.Value) !cfg.Value {
    if (schema != .table) return .null;
    if (schema.table.get("default")) |default| return default.clone(arena);
    const kind = if (schema.table.get("type")) |t| switch (t) {
        .string => |s| s,
        .array => |a| if (a.items.len > 0 and a.items[0] == .string) a.items[0].string else "",
        else => "",
    } else if (schema.table.get("properties") != null) "object" else "";
    if (std.mem.eql(u8, kind, "object")) {
        var out: cfg.Value = .empty_table;
        const properties = schema.table.get("properties") orelse return out;
        if (properties != .table) return out;
        var it = properties.table.iterator();
        while (it.next()) |entry| {
            const value = try defaultsOf(arena, entry.value_ptr.*);
            if (value != .null) try out.table.put(arena, entry.key_ptr.*, value);
        }
        return out;
    }
    if (schema.table.get("enum")) |choices| {
        if (choices == .array and choices.array.items.len > 0) return choices.array.items[0];
    }
    if (std.mem.eql(u8, kind, "string")) return .{ .string = "" };
    if (std.mem.eql(u8, kind, "integer")) return .{ .int = 0 };
    if (std.mem.eql(u8, kind, "number")) return .{ .float = 0 };
    if (std.mem.eql(u8, kind, "boolean")) return .{ .bool = false };
    if (std.mem.eql(u8, kind, "array")) return .{ .array = .empty };
    return .null;
}

pub const schema_command = cli.command(.{
    .name = "schema",
    .summary = "Infer a JSON Schema, or check files against one",
    .group = group,
    .subcommands = .{ infer, check },
});

const infer = cli.command(.{
    .name = "infer",
    .summary = "Print a JSON Schema the file conforms to",
    .description =
    \\Print a JSON Schema (draft-07) describing <file>: its keys and their types, every key
    \\required. A starting point to edit: loosen what may vary, add bounds and enums, then
    \\check files with "termancy cfg schema check".
    ,
    .args = .{ .min = 1, .max = 1, .usage = "<file>", .complete = load.completeConfigFiles },
    .examples =
    \\termancy cfg schema infer termancy.toml > schema.json
    ,
    .run = runInfer,
});

fn runInfer(ctx: *cli.Context) !void {
    const tree = try load.parseFile(ctx, ctx.args[0], null);
    try ctx.out.writeAll(try load.encode(ctx, try cfg.schema.infer(ctx.arena, tree), .json));
}

const check = cli.command(.{
    .name = "check",
    .summary = "Check files against a JSON Schema",
    .description =
    \\The same as "termancy cfg validate --schema <schema> <file>...".
    ,
    .args = .{
        .min = 2,
        .max = null,
        .usage = "<schema> <file>...",
        .complete = load.completeConfigFiles,
    },
    .run = runCheck,
});

fn runCheck(ctx: *cli.Context) !void {
    const tree = try load.parseFile(ctx, ctx.args[0], null);
    try files.validateFiles(ctx, tree, ctx.args[1..]);
}

pub const edit = cli.command(.{
    .name = "edit",
    .summary = "Open the config file in your editor, and check it before saving",
    .description =
    \\Open a copy of [file] (default: the first --config, or the discovered termancy.* file) in
    \\$VISUAL or $EDITOR. When the editor exits, the copy must parse: if it does, it replaces
    \\the file at once; if not, the error is shown and you choose to edit again or give up,
    \\leaving the file as it was, as visudo does. Needs a terminal.
    ,
    .group = "Edit Commands",
    .args = .{ .max = 1, .usage = "[file]", .complete = load.completeConfigFiles },
    .run = runEdit,
});

fn runEdit(ctx: *cli.Context) !void {
    const stdin = std.Io.File.stdin();
    if (!(stdin.isTty(ctx.io) catch false)) {
        return ctx.usageError("edit needs a terminal; use \"termancy cfg set\" in scripts", .{});
    }
    const global = try ctx.flags(load.Global);
    const file = if (ctx.args.len > 0) ctx.args[0] else try load.targetFile(ctx, global);
    const format = cfg.Format.fromPath(file) orelse
        return ctx.fail("{s}: " ++ load.unknown_format, .{file});
    const original = try load.readSource(ctx, file);
    const dir = std.fs.path.dirname(file) orelse ".";
    const copy = try std.fs.path.join(ctx.arena, &.{ dir, try std.fmt.allocPrint(
        ctx.arena,
        ".{s}.termancy-edit{s}",
        .{ std.fs.path.stem(file), std.fs.path.extension(file) },
    ) });
    try load.writeFileAtomic(ctx, copy, original);
    defer std.Io.Dir.cwd().deleteFile(ctx.io, copy) catch {};

    var buffer: [256]u8 = undefined;
    var answers = stdin.readerStreaming(ctx.io, &buffer);
    while (true) {
        const term = sys.process.edit(ctx.gpa, ctx.io, ctx.environ, copy) catch |err| {
            return ctx.fail("cannot start the editor: {s}", .{@errorName(err)});
        };
        const status = sys.process.exitStatus(term);
        if (status != 0) {
            const message = "the editor exited with status {d}; {s} is unchanged";
            return ctx.fail(message, .{ status, file });
        }
        const edited = try load.readSource(ctx, copy);
        var diag: cfg.Diagnostic = .{};
        if (format.parse(ctx.arena, edited, &diag)) |_| {
            if (std.mem.eql(u8, edited, original)) return;
            const cwd = std.Io.Dir.cwd();
            // The replacement is a new file; it keeps the old one's permissions (`0600`).
            const mode = if (cwd.statFile(ctx.io, file, .{})) |stat| stat.permissions else |_| null;
            try load.writeFileAtomic(ctx, file, edited);
            if (mode) |permissions| cwd.setFilePermissions(ctx.io, file, permissions, .{}) catch {};
            return;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => {},
        }
        try ctx.err.print("{s}: {s}:{f}\nWhat now? (e)dit again, or (x) leave {s} unchanged: ", .{
            ctx.app_name, file, diag, file,
        });
        try ctx.err.flush();
        const answer = answers.interface.takeDelimiter('\n') catch null orelse "";
        if (!std.mem.startsWith(u8, std.mem.trim(u8, answer, " \t\r"), "e")) {
            return ctx.fail("{s} is unchanged", .{file});
        }
    }
}

const testing = std.testing;

fn readTmp(tmp: testing.TmpDir, name: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
}

fn termancy(args: []const []const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{});
}

test "init writes a starter file, from a schema too, and will not replace one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const toml = try std.fs.path.join(testing.allocator, &.{ dir, "app.toml" });
    defer testing.allocator.free(toml);

    const first = try termancy(&.{ "cfg", "init", toml });
    defer first.deinit();
    try first.expect(0, "", "");
    const written = try readTmp(tmp, "app.toml");
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(starter_toml, written);

    const again = try termancy(&.{ "cfg", "init", toml });
    defer again.deinit();
    try testing.expectEqual(1, again.status);
    const refused = "app.toml: exists; pass --force to replace it\n";
    try testing.expect(std.mem.endsWith(u8, again.err, refused));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "schema.json", .data =
        \\{"properties": {"name": {"type": "string", "default": "x"},
        \\ "port": {"type": "integer"}, "mode": {"enum": ["fast", "safe"]},
        \\ "tls": {"type": "object", "properties": {"on": {"type": "boolean"}}}}}
    });
    const schema_path = try std.fs.path.join(testing.allocator, &.{ dir, "schema.json" });
    defer testing.allocator.free(schema_path);
    const yaml = try std.fs.path.join(testing.allocator, &.{ dir, "app.yaml" });
    defer testing.allocator.free(yaml);
    const from_schema = try termancy(&.{ "cfg", "init", yaml, "--schema", schema_path });
    defer from_schema.deinit();
    try from_schema.expect(0, "", "");
    const generated = try readTmp(tmp, "app.yaml");
    defer testing.allocator.free(generated);
    try testing.expectEqualStrings("name: x\nport: 0\nmode: fast\ntls:\n  on: false\n", generated);
}

test "merge and schema infer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.toml", .data = "a = 1\n[t]\nx = 1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.json", .data = "{\"t\": {\"y\": true}}" });
    const a_path = try std.fs.path.join(testing.allocator, &.{ dir, "a.toml" });
    defer testing.allocator.free(a_path);
    const b_path = try std.fs.path.join(testing.allocator, &.{ dir, "b.json" });
    defer testing.allocator.free(b_path);

    const merged = try termancy(&.{ "cfg", "merge", a_path, b_path, "-o", "toml" });
    defer merged.deinit();
    try merged.expect(0, "a = 1\n\n[t]\nx = 1\ny = true\n", "");

    const inferred = try termancy(&.{ "cfg", "schema", "infer", b_path });
    defer inferred.deinit();
    try testing.expectEqual(0, inferred.status);
    try testing.expect(std.mem.indexOf(u8, inferred.out, "\"type\": \"boolean\"") != null);
}
