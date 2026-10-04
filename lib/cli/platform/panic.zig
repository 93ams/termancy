const std = @import("std");
const builtin = @import("builtin");

pub const PanicConfig = struct {
    app_name: []const u8 = "tigershark",
    issues_url: []const u8 = "https://github.com/93ams/tigershark/issues/new",
    cache_dir: []const u8 = ".cache/tigershark",
};

pub fn renderStructuredPanic(
    writer: anytype,
    msg: []const u8,
    first_trace_addr: ?usize,
    config: PanicConfig,
) void {
    _ = first_trace_addr;
    // 1. Render boxed alert to stderr
    writer.print("\n\x1b[31;1m╭────────────────────────────────────────────────────────────────────────────╮\x1b[0m\n", .{}) catch return;
    writer.print("\x1b[31;1m│                         💥 UNEXPECTED FATAL ERROR                          │\x1b[0m\n", .{}) catch return;
    writer.print("\x1b[31;1m├────────────────────────────────────────────────────────────────────────────┤\x1b[0m\n", .{}) catch return;
    writer.print("\x1b[31;1m│\x1b[0m {s:74.74} \x1b[31;1m│\x1b[0m\n", .{msg}) catch return;
    writer.print("\x1b[31;1m├────────────────────────────────────────────────────────────────────────────┤\x1b[0m\n", .{}) catch return;
    writer.print("\x1b[31;1m│\x1b[0m Platform: {s:15.15} Arch: {s:10.10} Zig: {s:10.10}              \x1b[31;1m│\x1b[0m\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        builtin.zig_version_string,
    }) catch return;
    writer.print("\x1b[31;1m├────────────────────────────────────────────────────────────────────────────┤\x1b[0m\n", .{}) catch return;
    writer.print("\x1b[31;1m│\x1b[0m Please file a bug report at:                                               \x1b[31;1m│\x1b[0m\n", .{}) catch return;
    writer.print("\x1b[31;1m│\x1b[0m   \x1b[36;4m{s:70.70}\x1b[0m \x1b[31;1m│\x1b[0m\n", .{config.issues_url}) catch return;
    writer.print("\x1b[31;1m╰────────────────────────────────────────────────────────────────────────────╯\x1b[0m\n\n", .{}) catch return;
}

pub fn writeCrashReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    msg: []const u8,
    config: PanicConfig,
) !void {
    const trace = @import("util").trace;
    const timestamp = trace.getMonotonicMs();
    var path_buf: [256]u8 = undefined;
    const crash_path = try std.fmt.bufPrint(&path_buf, "{s}/crash-{d}.json", .{ config.cache_dir, timestamp });

    std.Io.Dir.cwd().createDirPath(io, config.cache_dir) catch {};

    const file = try std.Io.Dir.cwd().createFile(io, crash_path, .{ .truncate = true });
    defer file.close(io);

    const CrashJson = struct {
        app: []const u8,
        message: []const u8,
        os: []const u8,
        arch: []const u8,
        zig_version: []const u8,
        /// `u64`, matching `trace.getMonotonicMs()`. This was `i64` and the
        /// mismatch made `writeCrashReport` fail to compile, which went unnoticed
        /// because nothing referenced it until `platform/root.zig` did - see
        /// `app/cli/lib/ROADMAP.md` B-1.
        timestamp: u64,
    };

    const report = CrashJson{
        .app = config.app_name,
        .message = msg,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .zig_version = builtin.zig_version_string,
        .timestamp = timestamp,
    };

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.json.fmt(report, .{ .whitespace = .indent_2 }).format(&writer);
    const json_out = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try file.writePositionalAll(io, json_out, 0);
    _ = allocator;
}
