//! `termancy ui log`: write a log record from a shell script, as gum's `log`: a message at a
//! level (or none), with key-value fields, as charm-styled text, logfmt, or JSON.

const std = @import("std");
const cli = @import("cli");
const field_ = @import("field");
const tui = @import("tui");
const sys = @import("sys");
const styles = @import("styles.zig");
const log = sys.log;
const Writer = std.Io.Writer;

const Flags = struct {
    level: Level = .none,
    prefix: []const u8 = "",
    format: bool = false,
    structured: bool = false,
    formatter: log.Format = .text,
    time: ?log.TimeFormat = null,
    file: ?[]const u8 = null,
    min_level: ?Level = null,
    level_style: styles.Styles = .{},
    time_style: styles.Styles = .{},
    prefix_style: styles.Styles = .{},
    message_style: styles.Styles = .{},
    key_style: styles.Styles = .{},
    value_style: styles.Styles = .{},
    separator_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field_.Set(.{ field_.Spec(Flags){ .fields = .{
    .level = .{ .help = "The record's level; none writes none" },
    .prefix = .{ .help = "Written before the message" },
    .format = .{ .help = "The first argument is a printf format for the rest: %s, %d, %v, %%" },
    .structured = .{ .help = "The arguments after the message are key value pairs" },
    .formatter = .{ .help = "How the record is written" },
    .time = .{ .help = "Add the local time in Go's layout of this name, as gum's: kitchen, " ++
        "layout, ansic, unixdate, rubydate, rfc822, rfc822z, rfc850, rfc1123, rfc1123z, " ++
        "rfc3339, rfc3339nano, stamp, stampmilli, stampmicro, stampnano, datetime, " ++
        "dateonly, timeonly; or date-time (2006/01/02 15:04:05) or time" },
    .file = .{ .help = "Append to this file instead of standard error" },
    .min_level = .{ .help = "Write nothing for levels below this (a record with no level " ++
        "is always written)" },
} }, styles.spec }), .{
    .env_prefix = "TERMANCY_LOG_",
    .exclusive = &.{&.{ .format, .structured }},
    .fields = .{
        // TERMANCY_LOG_LEVEL is --min-level's, as GUM_LOG_LEVEL is gum's.
        .level = .{ .short = 'l', .env = "" },
        .format = .{ .short = 'f' },
        .structured = .{ .short = 's' },
        .time = .{ .short = 't', .value_name = "name" },
        .file = .{ .short = 'o' },
        .min_level = .{ .env = "TERMANCY_LOG_LEVEL" },
        .level_style = styles.group("level"),
        .time_style = styles.group("time"),
        .prefix_style = styles.group("prefix"),
        .message_style = styles.group("message"),
        .key_style = styles.group("key"),
        .value_style = styles.group("value"),
        .separator_style = styles.group("separator"),
    },
});

/// gum's levels, and termancy's trace.
const Level = enum { none, trace, debug, info, warn, @"error", fatal };

pub const command = cli.command(.{
    .name = "log",
    .summary = "Write a log record: a level, a message, and fields",
    .description =
    \\Write the arguments, joined by spaces, as one log record on standard error, as gum's
    \\log: styled as charm's log at a terminal, or as logfmt or JSON lines (--formatter).
    \\With --structured, the first argument is the message and the rest are key value
    \\pairs; with --format, the first is a printf format for the rest (%s, %d, and %v each
    \\write the next argument, padded to a width such as %8s or %-8s; %% writes %).
    \\
    \\--level none (the default) writes no level, and such a record is never left out by
    \\--min-level (or TERMANCY_LOG_LEVEL). A fatal record ends with status 1. Values whose
    \\keys look secret (password, token, ...) are redacted. Times are local (TZ, or else
    \\the system's zone); JSON and logfmt write them as RFC 3339 whatever --time names.
    \\
    \\Style a part with --level.*, --time.*, --prefix.*, --message.*, --key.*, --value.*,
    \\and --separator.* (foreground, background, bold, and the rest of termancy ui style's
    \\flags). Every flag but --level can also come from a variable: TERMANCY_LOG_FORMATTER,
    \\TERMANCY_LOG_KEY_FOREGROUND.
    ,
    .args = .{ .min = 1, .max = null, .usage = "<text>..." },
    .flags = flags_flags,
    .examples =
    \\termancy ui log --level warn "disk almost full"
    \\termancy ui log -s -l info deployed version 1.4.0 region eu
    \\termancy ui log -f "%s took %ss" build 42
    \\termancy ui log --formatter json --time rfc3339 -s deployed version 1.4.0
    \\TERMANCY_LOG_LEVEL=warn termancy ui log -l debug "left out"
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const message = if (flags.format)
        printf(ctx.arena, ctx.args[0], ctx.args[1..]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownVerb => return ctx.usageError("--format: use %s, %d, %v, or %%", .{}),
            error.MissingArgument => return ctx.usageError("--format: too few arguments", .{}),
            error.ExtraArgument => return ctx.usageError("--format: too many arguments", .{}),
        }
    else if (flags.structured)
        ctx.args[0]
    else
        try std.mem.join(ctx.arena, " ", ctx.args);
    const pairs = if (flags.structured) ctx.args[1..] else &.{};
    if (pairs.len % 2 != 0) return ctx.usageError("fields come in key value pairs", .{});
    const fields = try ctx.arena.alloc(log.Field, pairs.len / 2);
    for (fields, 0..) |*field, i| {
        field.* = .{ .key = pairs[2 * i], .value = .{ .string = pairs[2 * i + 1] } };
    }
    var file_buffer: [1024]u8 = undefined;
    var file_writer: ?std.Io.File.Writer = null;
    defer if (file_writer) |*fw| fw.file.close(ctx.io);
    const w = if (flags.file) |path| blk: {
        const file = std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = false }) catch |err|
            return ctx.fail("{s}: {s}", .{ path, @errorName(err) });
        file_writer = file.writer(ctx.io, &file_buffer);
        const end = file.length(ctx.io) catch 0;
        file_writer.?.seekTo(end) catch {};
        break :blk &file_writer.?.interface;
    } else ctx.err;
    const level = sysLevel(flags.level);
    const logger: log.Logger = .{
        .writer = w,
        .level = if (flags.min_level) |min| sysLevel(min) else .trace,
        .format = flags.formatter,
        .color = flags.file == null and ctx.err_color != .none,
        .style = .charm,
        .styles = try stylesOf(ctx.arena, flags, level, ctx.err_color),
        .clock = if (flags.time != null) .{ .io = ctx.io } else .none,
        .time_format = flags.time orelse .rfc3339,
        .zone = if (flags.time != null) sys.timezone.local(ctx.arena, ctx.io, ctx.environ.get("TZ")) else .utc,
        .prefix = flags.prefix,
        .fields = fields,
    };
    try logger.log(level, message, .{});
    // charm's Fatal ends the program, written or not.
    if (level == .fatal) return error.CommandFailed;
}

fn sysLevel(level: Level) log.Level {
    return switch (level) {
        .@"error" => .err,
        inline else => |tag| @field(log.Level, @tagName(tag)),
    };
}

/// Each part as gum's log draws it (bold levels in charm's colors, the prefix bold and
/// faint, keys and `=` faint), with the style flags over it, for an output showing `color`.
fn stylesOf(
    arena: std.mem.Allocator,
    flags: Flags,
    level: log.Level,
    color: tui.capability.Color,
) std.mem.Allocator.Error!log.Styles {
    const level_style: tui.Style = .{ .bold = true, .fg = .{ .indexed = level.charmColor() } };
    return .{
        .time = try sgr(arena, flags.time_style.over(.{}), color),
        .level = try sgr(arena, flags.level_style.over(level_style), color),
        .short_levels = false,
        .prefix = try sgr(arena, flags.prefix_style.over(.{ .bold = true, .dim = true }), color),
        .message = try sgr(arena, flags.message_style.over(.{}), color),
        .key = try sgr(arena, flags.key_style.over(.{ .dim = true }), color),
        .separator = try sgr(arena, flags.separator_style.over(.{ .dim = true }), color),
        .value = try sgr(arena, flags.value_style.over(.{}), color),
    };
}

/// The sequence that starts `style`, its colors lowered to `color`.
fn sgr(
    arena: std.mem.Allocator,
    style: tui.Style,
    color: tui.capability.Color,
) std.mem.Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    style.lowered(color).writeSgr(&out.writer) catch return error.OutOfMemory;
    return out.written();
}

pub const PrintfError = error{ UnknownVerb, MissingArgument, ExtraArgument };

/// `format` with each verb replaced by the next of `args`, as Go's printf fills it with
/// strings for gum's `--format`: `%s`, `%d`, and `%v` write the argument, padded with
/// spaces to a width (`%8s`; `%-8s` pads on the right); `%%` writes `%`. Every argument
/// must be used.
pub fn printf(
    arena: std.mem.Allocator,
    format: []const u8,
    args: []const []const u8,
) (PrintfError || std.mem.Allocator.Error)![]const u8 {
    var out: Writer.Allocating = .init(arena);
    writePrintf(&out.writer, format, args) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |e| e,
    };
    return out.written();
}

fn writePrintf(
    w: *Writer,
    format: []const u8,
    args: []const []const u8,
) (PrintfError || Writer.Error)!void {
    var next: usize = 0;
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%') {
            try w.writeByte(format[i]);
            continue;
        }
        i += 1;
        if (i < format.len and format[i] == '%') {
            try w.writeByte('%');
            continue;
        }
        const left = i < format.len and format[i] == '-';
        if (left) i += 1;
        const digits = i;
        while (i < format.len and std.ascii.isDigit(format[i])) i += 1;
        const width = std.fmt.parseInt(usize, format[digits..i], 10) catch 0;
        if (i == format.len or std.mem.indexOfScalar(u8, "sdv", format[i]) == null) {
            return error.UnknownVerb;
        }
        if (next == args.len) return error.MissingArgument;
        const arg = args[next];
        next += 1;
        const pad = width -| tui.width.of(arg);
        if (!left) try w.splatByteAll(' ', pad);
        try w.writeAll(arg);
        if (left) try w.splatByteAll(' ', pad);
    }
    if (next < args.len) return error.ExtraArgument;
}

const testing = std.testing;

test printf {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("build took 42s: 100%", try printf(a, "%s took %ds: %v%%", &.{
        "build", "42", "100",
    }));
    try testing.expectEqualStrings("[  ab|ab  |é ]", try printf(a, "[%4s|%-4s|%-2s]", &.{
        "ab", "ab",
        "é",
    }));
    try testing.expectEqualStrings("no verbs", try printf(a, "no verbs", &.{}));
    try testing.expectError(error.MissingArgument, printf(a, "%s %s", &.{"x"}));
    try testing.expectError(error.ExtraArgument, printf(a, "%s", &.{ "x", "y" }));
    try testing.expectError(error.UnknownVerb, printf(a, "%x", &.{"x"}));
    try testing.expectError(error.UnknownVerb, printf(a, "100%", &.{}));
}

test stylesOf {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{
        .level_style = .{ .background = .{ .indexed = 1 } },
        .key_style = .{ .faint = false, .foreground = .{ .indexed = 212 } },
    };
    const st = try stylesOf(arena.allocator(), flags, .warn, .ansi256);
    // gum's level: bold, in charm's color unless the flags give one.
    try testing.expectEqualStrings("\x1b[1;38;5;192;48;5;1m", st.level);
    try testing.expectEqualStrings("\x1b[1;2m", st.prefix);
    try testing.expectEqualStrings("\x1b[38;5;212m", st.key);
    try testing.expectEqualStrings("\x1b[2m", st.separator);
    try testing.expectEqualStrings("", st.time);
    try testing.expect(!st.short_levels);
}

const test_root = cli.command(.{ .name = "termancy", .subcommands = .{command} });

/// Runs `termancy log <args>` in memory with `env` as the whole environment.
fn expectLog(
    args: []const []const u8,
    env: []const [2][]const u8,
    status: u8,
    err: []const u8,
) !void {
    const app: cli.App = .{ .root = &test_root };
    const result = try cli.testing.run(app, args, .{ .env = env });
    defer result.deinit();
    try result.expect(status, "", err);
}

test "gum's ways to write a record" {
    try expectLog(&.{ "log", "two", "words" }, &.{}, 0, "two words\n");
    try expectLog(&.{ "log", "-l", "error", "-s", "--prefix", "app", "failed", "code", "7" }, &.{}, 0, "ERROR app: failed code=7\n");
    try expectLog(&.{ "log", "-f", "%s=%d", "n", "1" }, &.{}, 0, "n=1\n");
    try expectLog(&.{ "log", "--formatter", "json", "-l", "info", "hi" }, &.{}, 0, "{\"level\":\"info\",\"msg\":\"hi\"}\n");
    try expectLog(&.{ "log", "-l", "fatal", "x" }, &.{}, 1, "FATAL x\n");
    try expectLog(&.{ "log", "-f", "%q", "x" }, &.{}, 2, "termancy: --format: use %s, %d, %v, " ++
        "or %%\nRun 'termancy log --help' for usage.\n");
}

test "TERMANCY_LOG_LEVEL is the least level written, and not --level's" {
    const warn = [_][2][]const u8{.{ "TERMANCY_LOG_LEVEL", "warn" }};
    try expectLog(&.{ "log", "-l", "info", "x" }, &warn, 0, "");
    try expectLog(&.{ "log", "-l", "error", "x" }, &warn, 0, "ERROR x\n");
    // A record with no level is always written.
    try expectLog(&.{ "log", "x" }, &warn, 0, "x\n");
    try expectLog(&.{ "log", "--min-level", "info", "-l", "debug", "x" }, &.{}, 0, "");
}

test sysLevel {
    try testing.expectEqual(log.Level.none, sysLevel(.none));
    try testing.expectEqual(log.Level.err, sysLevel(.@"error"));
    try testing.expectEqual(log.Level.trace, sysLevel(.trace));
}
