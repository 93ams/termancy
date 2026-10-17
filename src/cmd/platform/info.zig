//! `snek platform info`: the system snek runs on, as a bug report or a script needs it.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const platform = @import("platform");
const group = @import("main.zig");
const version = @import("../../main.zig").version;

pub const command = cli.command(.{
    .name = "info",
    .summary = "Print the OS, architecture, CI service, and terminal state",
    .description =
    \\Print what snek knows about the system it runs on: OS and architecture (as compiled),
    \\the Zig and snek versions, the CI service (from its environment variables), whether
    \\standard input and output are terminals, whether the process runs elevated (root or
    \\an administrator), and the host name.
    \\
    \\-o json prints one object, keys in this order:
    \\  {"os": string, "arch": string, "zig": string, "snek": string,
    \\   "ci": string or null, "stdin_tty": bool, "stdout_tty": bool,
    \\   "elevated": bool, "hostname": string or null}
    \\"ci" is one of github_actions, gitlab, buildkite, circleci, travis, jenkins,
    \\azure_pipelines, teamcity, bitbucket, appveyor, drone, codebuild, or generic.
    ,
    .output = true,
    .examples =
    \\snek platform info
    \\snek platform info -o json
    ,
    .run = run,
});

/// The shape of `-o json`; field order is the output order.
const Info = struct {
    os: []const u8 = @tagName(builtin.os.tag),
    arch: []const u8 = @tagName(builtin.cpu.arch),
    zig: []const u8 = builtin.zig_version_string,
    snek: []const u8 = version,
    ci: ?platform.env.Ci,
    stdin_tty: bool,
    stdout_tty: bool,
    elevated: bool,
    hostname: ?[]const u8,
};

fn run(ctx: *cli.Context) !void {
    var host_buffer: [platform.env.max_hostname_bytes]u8 = undefined;
    const info: Info = .{
        .ci = platform.env.ci(ctx.environ),
        .stdin_tty = try std.Io.File.stdin().isTty(ctx.io),
        .stdout_tty = try std.Io.File.stdout().isTty(ctx.io),
        .elevated = platform.env.isElevated(),
        .hostname = platform.env.hostname(&host_buffer) catch null,
    };
    if (ctx.output != .text) return ctx.render(info);
    try writeText(ctx.out, info);
}

fn writeText(writer: *std.Io.Writer, info: Info) std.Io.Writer.Error!void {
    try group.writeRows(writer, &.{
        .{ "os", info.os },
        .{ "arch", info.arch },
        .{ "zig", info.zig },
        .{ "snek", info.snek },
        .{ "ci", if (info.ci) |ci| @tagName(ci) else "none" },
        .{ "stdin_tty", yesNo(info.stdin_tty) },
        .{ "stdout_tty", yesNo(info.stdout_tty) },
        .{ "elevated", yesNo(info.elevated) },
        .{ "hostname", info.hostname orelse "unknown" },
    });
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

const testing = std.testing;

test "the JSON shape" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try cli.internal.output.write(testing.allocator, &w, .json, Info{
        .os = "linux",
        .arch = "x86_64",
        .zig = "0.17.0",
        .snek = "0.1.0",
        .ci = .github_actions,
        .stdin_tty = false,
        .stdout_tty = true,
        .elevated = false,
        .hostname = null,
    });
    try testing.expectEqualStrings(
        \\{
        \\  "os": "linux",
        \\  "arch": "x86_64",
        \\  "zig": "0.17.0",
        \\  "snek": "0.1.0",
        \\  "ci": "github_actions",
        \\  "stdin_tty": false,
        \\  "stdout_tty": true,
        \\  "elevated": false,
        \\  "hostname": null
        \\}
        \\
    , w.buffered());
}

test writeText {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeText(&w, .{
        .os = "macos",
        .arch = "aarch64",
        .zig = "0.17.0",
        .snek = "0.1.0",
        .ci = null,
        .stdin_tty = true,
        .stdout_tty = false,
        .elevated = true,
        .hostname = "box",
    });
    try testing.expectEqualStrings(
        \\os          macos
        \\arch        aarch64
        \\zig         0.17.0
        \\snek        0.1.0
        \\ci          none
        \\stdin_tty   yes
        \\stdout_tty  no
        \\elevated    yes
        \\hostname    box
        \\
    , w.buffered());
}
