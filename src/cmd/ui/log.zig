//! `termancy ui log`: write a log record from a shell script, as gum's `log`: a level, a
//! message, and key-value fields, as charm-styled text, logfmt, or JSON.

const std = @import("std");
const cli = @import("cli");
const field_ = @import("field");
const sys = @import("sys");
const log = sys.log;

const Flags = struct {
    level: log.Level = .info,
    prefix: []const u8 = "",
    format: Format = .text,
    time: ?log.TimeFormat = null,
    file: ?[]const u8 = null,
    min_level: log.Level = .trace,
};
const flags_flags = cli.flags(Flags, field_.Set(.{field_.Spec(Flags){ .fields = .{
    .level = .{ .help = "The record's level" },
    .prefix = .{ .help = "Written before the message" },
    .format = .{ .help = "How the record is written" },
    .time = .{ .help = "Add the time, in this format" },
    .file = .{ .help = "Append to this file instead of standard error" },
    .min_level = .{ .help = "Write nothing for levels below this" },
} }}), .{ .fields = .{
    .level = .{ .short = 'l' },
    .format = .{ .short = 'f' },
    .time = .{ .short = 't' },
    .file = .{ .short = 'o' },
    .min_level = .{ .env = "GUM_LOG_LEVEL" },
} });

const Format = enum { text, json, logfmt };

pub const command = cli.command(.{
    .name = "log",
    .summary = "Write a log record: a level, a message, and fields",
    .description =
    \\Write the message (the first argument) and fields (the arguments after it, as key
    \\value pairs) as one log record on standard error, styled as charm's log at a
    \\terminal, or as logfmt or JSON lines. Values whose keys look secret (password,
    \\token, ...) are redacted.
    ,
    .args = .{ .min = 1, .max = null, .usage = "<message> [key value]..." },
    .flags = flags_flags,
    .examples =
    \\termancy ui log --level warn "disk almost full" used 93%
    \\termancy ui log -f json --time rfc3339 "deployed" version 1.4.0
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const pairs = ctx.args[1..];
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
    const logger: log.Logger = .{
        .writer = w,
        .level = flags.min_level,
        .format = switch (flags.format) {
            .text => .text,
            .json => .json,
            .logfmt => .logfmt,
        },
        .color = flags.file == null and ctx.err_color != .none,
        .style = .charm,
        .clock = if (flags.time != null) .{ .io = ctx.io } else .none,
        .time_format = flags.time orelse .rfc3339,
        .prefix = flags.prefix,
        .fields = fields,
    };
    try logger.log(flags.level, ctx.args[0], .{});
}
