//! End-to-end test for `snek tui serve --web`: it listens on a free port, prints a link
//! with a token, and a WebSocket client (`platform.web.Client`) opens it like the page
//! would, sends its size, and sees the command's output and exit status. Also checks that
//! the link without its token is refused. Skipped on systems without pseudo-terminals.
//!
//! The build runs this file's `main` with the path to `snek`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub fn addCases(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    platform: *std.Build.Module,
    step: *std.Build.Step,
) void {
    const os = builtin.os.tag;
    if (os != .linux and !os.isDarwin()) return;
    const client = b.addExecutable(.{
        .name = "e2e-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e_web.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "platform", .module = platform }},
        }),
    });
    const run = b.addRunArtifact(client);
    run.setName("e2e: a browser's socket into snek tui serve --web");
    run.addArtifactArg(exe);
    run.expectStdOutEqual("401\n101\nhi\nexit 3\n");
    run.expectExitCode(0);
    step.dependOn(&run.step);
}

pub fn main(init: std.process.Init) !void {
    const web = @import("platform").web;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var child = try std.process.spawn(io, .{
        .argv = &.{
            args[1], "tui", "serve",           "--web", "-l", "127.0.0.1:0", "--",
            "sh",    "-c",  "echo hi; exit 3",
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var watchdog = try io.concurrent(giveUp, .{io});
    defer watchdog.cancel(io);

    var buffer: [1024]u8 = undefined;
    var stderr = child.stderr.?.readerStreaming(io, &buffer);
    // serving sh on http://127.0.0.1:<port>/?token=<hex>
    const line = try stderr.interface.takeDelimiterExclusive('\n');
    const start = (std.mem.indexOf(u8, line, "http://") orelse return error.NoLink) + 7;
    const slash = std.mem.indexOfScalarPos(u8, line, start, '/') orelse return error.NoLink;
    const host = line[start..slash];
    const colon = std.mem.lastIndexOfScalar(u8, host, ':').?;
    const address = try Io.net.IpAddress.parse(
        host[0..colon],
        try std.fmt.parseInt(u16, host[colon + 1 ..], 10),
    );
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{s}", .{host});
    var target_buffer: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "/ws{s}", .{line[slash + 1 ..]});

    var out_buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;

    var refused: web.Client = undefined;
    try out.print("{d}\n", .{try refused.open(io, address, "/ws", origin)});
    refused.close();

    var client: web.Client = undefined;
    try out.print("{d}\n", .{try client.open(io, address, target, origin)});
    defer client.close();
    try client.send(.text, "{\"type\":\"resize\",\"cols\":80,\"rows\":24}");
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(init.gpa);
    while (true) {
        const message = try client.receive();
        switch (message.opcode) {
            .binary => try seen.appendSlice(init.gpa, message.data),
            .text => {
                try out.print("{s}\n", .{std.mem.trim(u8, seen.items, "\r\n")});
                const at = std.mem.lastIndexOfScalar(u8, message.data, ':').?;
                const status = std.mem.trimEnd(u8, message.data[at + 1 ..], "}");
                try out.print("exit {s}\n", .{status});
            },
            .connection_close => break,
            else => {},
        }
    }
    try out.flush();
}

fn giveUp(io: Io) void {
    io.sleep(.fromSeconds(30), .awake) catch return;
    std.debug.print("e2e-web: no answer in 30 seconds\n", .{});
    std.process.exit(1);
}
