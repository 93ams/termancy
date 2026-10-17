//! End-to-end tests for SSH:
//!
//! - `snek platform ssh run` (our client) into `snek tui serve`: an unknown host key is
//!   refused, `--accept-new` records it, a changed one is refused, a stranger's key is
//!   refused, and the command's output and exit status come back. Needs only `sh`.
//! - OpenSSH's `ssh` into `snek tui serve` with a key `snek platform ssh keygen` made.
//!   Skipped without `ssh`.
//! - OpenSSH's `ssh -L` and `ssh -R` against `platform.ssh.Server` with forwarding
//!   allowed, each tunnel carrying our client back to the server itself (this file's
//!   `main`). Skipped without `ssh`.
//!
//! All are skipped on systems without pseudo-terminals.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const setup =
    \\snek=$1
    \\dir=$(mktemp -d) || exit 90
    \\pid=
    \\trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$dir"' EXIT
    \\cd "$dir" || exit 91
    \\export HOME="$dir"
    \\port=$((20000 + $$ % 20000))
    \\"$snek" platform ssh keygen -f client -C e2e >/dev/null || exit 92
    \\"$snek" tui serve -l 127.0.0.1:$port --host-key host -k client.pub -- \
    \\    sh -c 'echo "hi $SSH_USER: $SSH_ORIGINAL_COMMAND"; echo oops >&2; exit 7' 2>serve.log &
    \\pid=$!
    \\i=0
    \\until grep -q serving serve.log 2>/dev/null; do
    \\    i=$((i + 1)); [ $i -gt 200 ] && { cat serve.log >&2; exit 93; }
    \\    sleep 0.05
    \\done
    \\
;

const openssh = setup ++
    \\ssh -T -i client -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    \\    -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes alice@127.0.0.1 hello \
    \\    </dev/null 2>/dev/null
    \\echo "status $?"
    \\ssh -T -i host -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    \\    -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes mallory@127.0.0.1 hello \
    \\    </dev/null 2>/dev/null
    \\echo "stranger $?"
;

const ours = setup ++
    \\run() { "$snek" platform ssh run -p $port "$@"; }
    \\run -i client alice@127.0.0.1 -- hello 2>/dev/null
    \\echo "unknown $?"
    \\run -i client --accept-new alice@127.0.0.1 -- hello there 2>err.log
    \\echo "status $?"
    \\grep -q "^snek: warning: added 127.0.0.1" err.log && grep -q "^oops" err.log && echo "stderr ok"
    \\run -i client alice@127.0.0.1 -- again 2>/dev/null
    \\echo "status $?"
    \\run -i host mallory@127.0.0.1 -- hello 2>/dev/null
    \\echo "stranger $?"
    \\"$snek" platform ssh keygen -f other -C other >/dev/null || exit 94
    \\printf '[127.0.0.1]:%s %s\n' $port "$(cut -d' ' -f1,2 other.pub)" >.ssh/known_hosts
    \\run -i client --accept-new alice@127.0.0.1 -- hello 2>/dev/null
    \\echo "changed $?"
;

pub fn addCases(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    platform: *std.Build.Module,
    step: *std.Build.Step,
) void {
    const os = builtin.os.tag;
    if (os != .linux and !os.isDarwin()) return;
    const sh = b.findProgram(.{ .names = &.{"sh"} }) orelse return;
    const client = shell(b, exe, sh, "e2e: snek platform ssh run into snek tui serve", ours);
    client.expectStdOutEqual(
        \\unknown 1
        \\hi alice: hello there
        \\status 7
        \\stderr ok
        \\hi alice: again
        \\status 7
        \\stranger 1
        \\changed 1
        \\
    );
    step.dependOn(&client.step);

    _ = b.findProgram(.{ .names = &.{"ssh"} }) orelse return;
    const run = shell(b, exe, sh, "e2e: ssh into snek tui serve", openssh);
    run.expectStdOutEqual("hi alice: hello\nstatus 7\nstranger 255\n");
    step.dependOn(&run.step);

    const forwarding = b.addExecutable(.{
        .name = "e2e-ssh-forward",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e_ssh.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "platform", .module = platform }},
        }),
    });
    const tunnels = b.addRunArtifact(forwarding);
    tunnels.setName("e2e: ssh -L and ssh -R through platform.ssh.Server");
    tunnels.expectStdOutEqual("-L: through -L 0\n-R: through -R 0\n");
    tunnels.expectExitCode(0);
    step.dependOn(&tunnels.step);
}

fn shell(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    sh: []const u8,
    name: []const u8,
    script: []const u8,
) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, name);
    run.addArgs(&.{ sh, "-c", script, "sh" });
    run.addArtifactArg(exe);
    run.clearEnvironment();
    if (b.graph.environ_map.get("PATH")) |path| run.setEnvironmentVariable("PATH", path);
    run.expectExitCode(0);
    return run;
}

fn handler(_: ?*anyopaque, session: *Session) anyerror!void {
    try session.write(session.command orelse "no command");
}

const Session = @import("platform").ssh.Session;

fn allow(_: ?*anyopaque, _: []const u8, _: []const u8, _: u16) bool {
    return true;
}

var host_blob: [51]u8 = undefined;

/// Only the server this test runs.
fn isOurs(_: ?*anyopaque, key: @import("platform").ssh.keys.PublicKey) bool {
    return std.mem.eql(u8, key.blob, &host_blob);
}

pub fn main(init: std.process.Init) !void {
    const ssh = @import("platform").ssh;
    const io = init.io;
    const gpa = init.gpa;
    var watchdog = try io.concurrent(giveUp, .{io});
    defer watchdog.cancel(io);

    const host_key: ssh.keys.KeyPair = .generate(io);
    host_blob = host_key.publicBlob();
    const config: ssh.Server.Config = .{
        .host_key = host_key,
        .handler = handler,
        .anyone = true,
        .direct_tcpip = allow,
        .tcpip_forward = allow,
    };
    const loopback = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var serving = try io.concurrent(ssh.Server.serve, .{ gpa, io, &listener, &config });
    defer _ = serving.cancel(io) catch {};

    var out_buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    for ([_][]const u8{ "-L", "-R" }) |flag| {
        const tunnel = try freePort(io);
        var spec_buffer: [64]u8 = undefined;
        const spec = try std.fmt.bufPrint(&spec_buffer, "127.0.0.1:{d}:127.0.0.1:{d}", .{
            tunnel,
            port,
        });
        var port_buffer: [8]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{port});
        var child = try std.process.spawn(io, .{
            .argv = &.{
                "ssh",           "-N",
                "-F",            "/dev/null",
                "-o",            "BatchMode=yes",
                "-o",            "StrictHostKeyChecking=no",
                "-o",            "UserKnownHostsFile=/dev/null",
                "-o",            "LogLevel=ERROR",
                "-o",            "ExitOnForwardFailure=yes",
                flag,            spec,
                "-p",            port_text,
                "e2e@127.0.0.1",
            },
            .stdin = .ignore,
            .stdout = .ignore,
        });
        defer child.kill(io);
        // Through the tunnel (once ssh has set it up) to the server again.
        const address = try Io.net.IpAddress.parse("127.0.0.1", tunnel);
        const client = for (0..200) |_| {
            if (connectThrough(gpa, io, address)) |c| break c else |_| {}
            try io.sleep(.fromMilliseconds(50), .awake);
        } else return error.NoTunnel;
        defer client.close();
        var command_buffer: [16]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_buffer, "through {s}", .{flag});
        const result = try client.run(gpa, command);
        defer result.deinit(gpa);
        try out.print("{s}: {s} {d}\n", .{ flag, result.stdout, result.status orelse 255 });
    }
    try out.flush();
}

fn connectThrough(
    gpa: std.mem.Allocator,
    io: Io,
    address: Io.net.IpAddress,
) !*@import("platform").ssh.Client {
    const stream = try address.connect(io, .{ .mode = .stream });
    return @import("platform").ssh.Client.connect(gpa, io, stream, .{
        .user = "e2e",
        .verify_host_key = isOurs,
    });
}

/// A port nothing listens on just now.
fn freePort(io: Io) !u16 {
    const any = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

fn giveUp(io: Io) void {
    io.sleep(.fromSeconds(30), .awake) catch return;
    std.debug.print("e2e-ssh-forward: no answer in 30 seconds\n", .{});
    std.process.exit(1);
}
