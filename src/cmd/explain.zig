//! `termancy explain`: terminal output in words, as sequin shows it. Reads files or
//! standard input, or runs a command on a pseudo-terminal (so it draws as it would for a
//! person) and explains what it wrote.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const term = @import("term");
const Writer = std.Io.Writer;

const Flags = struct {
    text: bool = true,
    width: u16 = 80,
    height: u16 = 24,
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .text = .{ .help = "Show the text between sequences (--no-text: sequences only)" },
    .width = .{ .help = "Columns of the terminal a command runs on", .checks = &.{.min(1)} },
    .height = .{ .help = "Rows of the terminal a command runs on", .checks = &.{.min(1)} },
} }}), .{});

pub const command = cli.command(.{
    .name = "explain",
    .summary = "Explain the escape sequences in a program's output",
    .description =
    \\Show what each control character and escape sequence in terminal output does, one
    \\per line: colors and attributes, cursor movement, erasing, modes, titles,
    \\hyperlinks, queries, and the text between them. The output comes from the files
    \\given, from standard input, or from a command after `--`, which runs on a
    \\pseudo-terminal of --width by --height, so it draws as it does for a person; its
    \\questions to the terminal (colors, cursor position, modes) are answered.
    ,
    .args = .{ .max = null, .usage = "[file...] [-- command...]", .passthrough = true },
    .flags = flags_flags,
    .output = true,
    .examples =
    \\printf '\033[1;31mred\033[0m\n' | termancy explain
    \\termancy explain -- ls --color=always
    \\termancy explain --no-text -- termancy ui choose a b
    ,
    .run = run,
});

/// One explained piece, as `-o json` lists it.
const Entry = struct {
    kind: []const u8,
    raw: []const u8,
    description: []const u8,
};

fn run(ctx: *cli.Context, flags: Flags) !void {
    const output = if (ctx.passthrough.len > 0)
        try capture(ctx, ctx.passthrough, .{ .width = flags.width, .height = flags.height })
    else if (ctx.args.len > 0)
        try readFiles(ctx)
    else
        try readStdin(ctx) orelse
            return ctx.usageError(
                "nothing to explain: give files, standard input, or -- command",
                .{},
            );

    var entries: std.ArrayList(Entry) = .empty;
    var it: term.explain.Iterator = .init(output);
    while (it.next()) |item| {
        switch (item) {
            .text => |text| if (flags.text) try entries.append(ctx.arena, .{
                .kind = "text",
                .raw = text,
                .description = text,
            }),
            .control, .sequence => |raw| {
                var description: Writer.Allocating = .init(ctx.arena);
                try term.explain.describe(&description.writer, raw);
                try entries.append(ctx.arena, .{
                    .kind = if (item == .control) "control" else "sequence",
                    .raw = raw,
                    .description = description.written(),
                });
            },
        }
    }
    if (ctx.output != .text) return ctx.render(entries.items);
    try writeText(ctx, entries.items);
}

/// One line per entry: the raw bytes as they are usually written, then what they do.
fn writeText(ctx: *cli.Context, entries: []const Entry) !void {
    const column = 18;
    const raw_style: term.Style = .{ .fg = .cyan };
    const text_style: term.Style = .{ .dim = true };
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.kind, "text")) {
            try ctx.paint(text_style, "text");
            try ctx.out.splatByteAll(' ', column - 4);
            try ctx.out.print("\"{s}\"\n", .{entry.raw});
            continue;
        }
        var raw: Writer.Allocating = .init(ctx.arena);
        try term.explain.writeRaw(&raw.writer, entry.raw);
        const shown = raw.written();
        try ctx.paint(raw_style, shown);
        const used = term.width.of(shown);
        if (used + 2 > column) {
            try ctx.out.writeByte('\n');
            try ctx.out.splatByteAll(' ', column);
        } else {
            try ctx.out.splatByteAll(' ', column - used);
        }
        try ctx.out.print("{s}\n", .{entry.description});
    }
}

fn readFiles(ctx: *cli.Context) ![]const u8 {
    var all: std.ArrayList(u8) = .empty;
    for (ctx.args) |path| {
        const cwd = std.Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return ctx.fail("{s}: {s}", .{ path, @errorName(err) });
        };
        try all.appendSlice(ctx.arena, bytes);
    }
    return all.items;
}

pub fn readStdin(ctx: *cli.Context) !?[]const u8 {
    const stdin = std.Io.File.stdin();
    if (try stdin.isTty(ctx.io)) return null;
    var buffer: [4096]u8 = undefined;
    var reader = stdin.readerStreaming(ctx.io, &buffer);
    return reader.interface.allocRemaining(ctx.arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => |e| ctx.fail("standard input: {s}", .{@errorName(e)}),
    };
}

/// Runs `argv` on a pseudo-terminal and returns everything it wrote. A virtual screen
/// behind it answers the program's queries, as a terminal would. Without pseudo-terminals,
/// the program runs on pipes with color forced on.
pub fn capture(ctx: *cli.Context, argv: []const []const u8, size: term.Size) ![]const u8 {
    var environ = try ctx.environ.clone(ctx.arena);
    try environ.put("TERM", "xterm-256color");
    try environ.put("COLORTERM", "truecolor");
    if (!term.Pty.supported) return capturePiped(ctx, argv, &environ);
    var pty = term.Pty.spawn(ctx.io, ctx.gpa, .{
        .argv = argv,
        .environ = &environ,
        .size = size,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PtyUnavailable => return capturePiped(ctx, argv, &environ),
        error.SpawnFailed => return ctx.fail("{s}: cannot run it", .{argv[0]}),
    };
    defer pty.deinit();
    var screen: term.vt.Screen = try .init(ctx.gpa, size);
    defer screen.deinit();
    var output: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try pty.read(&buffer);
        if (n == 0) break;
        try output.appendSlice(ctx.arena, buffer[0..n]);
        screen.write(buffer[0..n]);
        const answers = try screen.takeResponses();
        defer ctx.gpa.free(answers);
        if (answers.len > 0) pty.write(answers) catch {};
    }
    _ = pty.wait() catch {};
    return output.items;
}

fn capturePiped(
    ctx: *cli.Context,
    argv: []const []const u8,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    try environ.put("FORCE_COLOR", "3");
    try environ.put("CLICOLOR_FORCE", "1");
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .environ_map = environ,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return ctx.fail("{s}: {s}", .{ argv[0], @errorName(err) });
    };
    return std.mem.concat(ctx.arena, u8, &.{ result.stdout, result.stderr });
}

const testing = std.testing;

fn termancy(args: []const []const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{});
}

test "a file's sequences, one per line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out", .data = "\x1b[1;31mhi\x1b[0m\r\n" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/out", .{
        tmp.sub_path,
    });
    defer testing.allocator.free(path);
    const r = try termancy(&.{ "explain", path });
    defer r.deinit();
    try r.expect(0,
        \\ESC[1;31m         SGR: bold, red text
        \\text              "hi"
        \\ESC[0m            SGR: reset
        \\CR LF             carriage return, line feed
        \\
    , "");
    const json = try termancy(&.{ "explain", "--no-text", "-o", "json", path });
    defer json.deinit();
    try testing.expect(std.mem.indexOf(u8, json.out, "\"description\": \"SGR: reset\"") != null);
    try testing.expect(std.mem.indexOf(u8, json.out, "\"hi\"") == null);
}

test "a command runs on a pseudo console, on Windows" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    // What shows is the console host's drawing of the output, not the program's bytes.
    // `/d`: no AutoRun commands (clink and the like) from the registry.
    const r = try termancy(&.{ "explain", "--", "cmd.exe", "/d", "/c", "echo hi" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "text              \"hi\"\n") != null);
}

test "a command runs on a pseudo-terminal" {
    if (!term.Pty.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const r = try termancy(&.{ "explain", "--", "sh", "-c", "[ -t 1 ] && printf '\\033[2J'" });
    defer r.deinit();
    try r.expect(0, "ESC[2J            erase all of the screen (ED)\n", "");
}
