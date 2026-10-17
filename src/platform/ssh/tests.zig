//! The client against the server, in one process over loopback TCP: commands, exit
//! status, terminals, flow control on a large transfer, host key checks, forwarding, and
//! logins through an ssh-agent.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const keys = @import("keys.zig");
const known_hosts = @import("known_hosts.zig");
const Server = @import("Server.zig");
const Client = @import("Client.zig");
const Agent = @import("Agent.zig");
const wire = @import("wire.zig");

const big = 5 * 1024 * 1024;

fn handler(_: ?*anyopaque, s: *Server.Session) anyerror!void {
    const command = s.command orelse {
        // A shell: say what terminal, then report one resize and end.
        const pty = s.pty.?;
        var line: [64]u8 = undefined;
        try s.write(try std.fmt.bufPrint(&line, "{s} {d}x{d}\r\n", .{
            pty.term,
            pty.size.width,
            pty.size.height,
        }));
        while (true) switch (try s.next(.none)) {
            .resize => |size| {
                try s.write(try std.fmt.bufPrint(&line, "now {d}x{d}\r\n", .{
                    size.width,
                    size.height,
                }));
                return;
            },
            .closed => return,
            else => {},
        };
    };
    if (std.mem.eql(u8, command, "sink")) {
        // Counts the input, then sends as much back.
        var n: usize = 0;
        while (true) switch (try s.next(.none)) {
            .data => |d| n += d.len,
            .eof, .closed => break,
            else => {},
        };
        var chunk: [65536]u8 = @splat('x');
        var left = n;
        while (left > 0) {
            const k = @min(left, chunk.len);
            try s.write(chunk[0..k]);
            left -= k;
        }
        return;
    }
    try s.write(command);
    try s.writeStderr(s.getEnv("GREETING") orelse "none");
    s.exit(3);
}

fn allowAll(_: ?*anyopaque, _: []const u8, _: keys.PublicKey) bool {
    return true;
}

fn allowForward(_: ?*anyopaque, _: []const u8, _: []const u8, _: u16) bool {
    return true;
}

fn trust(_: ?*anyopaque, _: keys.PublicKey) bool {
    return true;
}

fn distrust(_: ?*anyopaque, _: keys.PublicKey) bool {
    return false;
}

const Fixture = struct {
    config: Server.Config,
    listener: Io.net.Server,
    future: Io.Future(anyerror!void) = undefined,

    fn start(f: *Fixture) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        f.listener = try address.listen(testing.io, .{ .reuse_address = true });
        f.future = try testing.io.concurrent(serve, .{f});
    }

    fn serve(f: *Fixture) anyerror!void {
        return Server.serve(testing.allocator, testing.io, &f.listener, &f.config);
    }

    fn stop(f: *Fixture) void {
        _ = f.future.cancel(testing.io) catch {};
        f.listener.deinit(testing.io);
    }

    fn port(f: *const Fixture) u16 {
        return f.listener.socket.address.getPort();
    }

    fn connect(f: *const Fixture, config: Client.Config) !*Client {
        const address = try Io.net.IpAddress.parse("127.0.0.1", f.port());
        const stream = try address.connect(testing.io, .{ .mode = .stream });
        return Client.connect(testing.allocator, testing.io, stream, config);
    }
};

fn hostKey() keys.KeyPair {
    return .fromSeed(@splat(9));
}

test "a command: output, standard error, variables, exit status" {
    var f: Fixture = .{
        .config = .{ .host_key = hostKey(), .handler = handler, .public_key = allowAll },
        .listener = undefined,
    };
    try f.start();
    defer f.stop();
    const client = try f.connect(.{
        .user = "alice",
        .identity = .fromSeed(@splat(8)),
        .verify_host_key = trust,
    });
    defer client.close();
    const result = try client.run(testing.allocator, "hello there");
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("hello there", result.stdout);
    try testing.expectEqualStrings("none", result.stderr);
    try testing.expectEqual(3, result.status);

    const s = try client.session();
    defer s.close();
    try s.env("GREETING", "hi");
    try s.exec("again");
    var err: [16]u8 = undefined;
    var err_len: usize = 0;
    while (true) switch (try s.read(.none)) {
        .stderr => |d| {
            @memcpy(err[err_len..][0..d.len], d);
            err_len += d.len;
        },
        .closed => break,
        else => {},
    };
    try testing.expectEqualStrings("hi", err[0..err_len]);
    try testing.expectEqual(3, s.exitStatus());
}

test "a terminal and a shell, resized" {
    var f: Fixture = .{
        .config = .{ .host_key = hostKey(), .handler = handler, .anyone = true },
        .listener = undefined,
    };
    try f.start();
    defer f.stop();
    const client = try f.connect(.{ .user = "bob", .verify_host_key = trust });
    defer client.close();
    const s = try client.session();
    defer s.close();
    try s.pty("xterm-256color", .{ .width = 80, .height = 24 });
    try s.shell();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var resized = false;
    while (true) switch (try s.read(.none)) {
        .data => |d| {
            try out.appendSlice(testing.allocator, d);
            if (!resized and std.mem.indexOfScalar(u8, out.items, '\n') != null) {
                resized = true;
                try s.resize(.{ .width = 100, .height = 40 });
            }
        },
        .closed => break,
        else => {},
    };
    try testing.expectEqualStrings("xterm-256color 80x24\r\nnow 100x40\r\n", out.items);
    try testing.expectEqual(0, s.exitStatus());
}

test "megabytes each way, past both windows" {
    var f: Fixture = .{
        .config = .{ .host_key = hostKey(), .handler = handler, .anyone = true },
        .listener = undefined,
    };
    try f.start();
    defer f.stop();
    const client = try f.connect(.{ .user = "carol", .verify_host_key = trust });
    defer client.close();
    const s = try client.session();
    defer s.close();
    try s.exec("sink");
    const chunk: [40000]u8 = @splat('y');
    var sent: usize = 0;
    while (sent < big) : (sent += chunk.len) try s.write(&chunk);
    s.closeInput();
    var got: usize = 0;
    while (true) switch (try s.read(.none)) {
        .data => |d| got += d.len,
        .closed => break,
        else => {},
    };
    try testing.expectEqual(sent, got);
}

test "host keys: refused by the check, and known_hosts" {
    var f: Fixture = .{
        .config = .{ .host_key = hostKey(), .handler = handler, .anyone = true },
        .listener = undefined,
    };
    try f.start();
    defer f.stop();
    try testing.expectError(
        error.HostKeyRejected,
        f.connect(.{ .user = "dave", .verify_host_key = distrust }),
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/ssh/known_hosts",
        .{path_buffer[0..dir_len]},
    );
    defer testing.allocator.free(path);
    var verifier: known_hosts.Verifier = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .path = path,
        .host = "127.0.0.1",
        .port = f.port(),
    };
    const config: Client.Config = .{
        .user = "dave",
        .verify_host_key = known_hosts.Verifier.check,
        .context = &verifier,
    };
    // Strict: not on file, refused.
    try testing.expectError(error.HostKeyRejected, f.connect(config));
    try testing.expectEqual(.unknown, verifier.found);
    // Accept new: recorded.
    verifier.policy = .accept_new;
    (try f.connect(config)).close();
    try testing.expect(verifier.added);
    // Strict again: known.
    verifier.policy = .strict;
    (try f.connect(config)).close();
    try testing.expectEqual(.known, verifier.found);
    // Another key on file for this address and port: changed, refused even accepting new.
    var line: Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    const other_blob = (keys.KeyPair.fromSeed(@splat(10))).publicBlob();
    try known_hosts.writeLine(
        &line.writer,
        "127.0.0.1",
        f.port(),
        try keys.PublicKey.parse(&other_blob),
    );
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ssh/known_hosts", .data = line.written() });
    verifier.policy = .accept_new;
    try testing.expectError(error.HostKeyRejected, f.connect(config));
    try testing.expectEqual(.changed, verifier.found);
}

fn echo(listener: *Io.net.Server) void {
    const stream = listener.accept(testing.io) catch return;
    defer stream.close(testing.io);
    var in_buffer: [256]u8 = undefined;
    var out_buffer: [256]u8 = undefined;
    var r = stream.reader(testing.io, &in_buffer);
    var w = stream.writer(testing.io, &out_buffer);
    _ = r.interface.streamRemaining(&w.interface) catch return;
    w.interface.flush() catch return;
}

fn forward(client: *Client, listener: *Io.net.Server, port: u16) void {
    client.forwardLocal(listener, "127.0.0.1", port) catch {};
}

test "local forwarding (ssh -L): off by default, through when allowed" {
    var f: Fixture = .{
        .config = .{ .host_key = hostKey(), .handler = handler, .anyone = true },
        .listener = undefined,
    };
    try f.start();
    defer f.stop();
    const loopback = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var target = try loopback.listen(testing.io, .{ .reuse_address = true });
    defer target.deinit(testing.io);
    var echoing = try testing.io.concurrent(echo, .{&target});
    defer echoing.cancel(testing.io);
    var local = try loopback.listen(testing.io, .{ .reuse_address = true });
    defer local.deinit(testing.io);
    const target_port = target.socket.address.getPort();
    const local_address = try Io.net.IpAddress.parse("127.0.0.1", local.socket.address.getPort());

    {
        // Refused: the server's policy is unset. The local connection is just closed.
        const client = try f.connect(.{ .user = "erin", .verify_host_key = trust });
        defer client.close();
        var forwarding = try testing.io.concurrent(forward, .{ client, &local, target_port });
        defer forwarding.cancel(testing.io);
        const stream = try local_address.connect(testing.io, .{ .mode = .stream });
        defer stream.close(testing.io);
        var buffer: [16]u8 = undefined;
        var r = stream.reader(testing.io, &buffer);
        try testing.expectError(error.EndOfStream, r.interface.takeByte());
    }

    f.stop();
    f.config.direct_tcpip = allowForward;
    try f.start();
    const client = try f.connect(.{ .user = "erin", .verify_host_key = trust });
    defer client.close();
    var forwarding = try testing.io.concurrent(forward, .{ client, &local, target_port });
    defer forwarding.cancel(testing.io);
    const stream = try local_address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var out_buffer: [16]u8 = undefined;
    var w = stream.writer(testing.io, &out_buffer);
    try w.interface.writeAll("ping through the tunnel");
    try w.interface.flush();
    try stream.shutdown(testing.io, .send);
    var in_buffer: [64]u8 = undefined;
    var r = stream.reader(testing.io, &in_buffer);
    const back = try r.interface.allocRemaining(testing.allocator, .limited(64));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("ping through the tunnel", back);
}

/// An ssh-agent in the test: it holds an RSA key (which the client must pass over) and the
/// keys `held`, and signs with them, counting.
const FakeAgent = struct {
    held: [2]keys.KeyPair,
    listener: Io.net.Server,
    signed: usize = 0,

    fn serve(a: *FakeAgent) void {
        const stream = a.listener.accept(testing.io) catch return;
        defer stream.close(testing.io);
        var in_buffer: [1024]u8 = undefined;
        var out_buffer: [1024]u8 = undefined;
        var r = stream.reader(testing.io, &in_buffer);
        var w = stream.writer(testing.io, &out_buffer);
        while (a.answer(&r.interface, &w.interface)) {} else |_| {}
    }

    fn answer(a: *FakeAgent, r: *Io.Reader, w: *Io.Writer) !void {
        const body = try r.take(try r.takeInt(u32, .big));
        var b: wire.Builder = .init(testing.allocator);
        defer b.deinit();
        switch (body[0]) {
            Agent.msg.request_identities => {
                try b.byte(Agent.msg.identities_answer);
                try b.int(1 + a.held.len);
                var rsa: wire.Builder = .init(testing.allocator);
                defer rsa.deinit();
                try rsa.string("ssh-rsa");
                try rsa.mpint(&.{3});
                try rsa.mpint(&.{ 0xc5, 0x01 });
                try b.string(rsa.bytes());
                try b.string("an rsa key");
                for (a.held) |kp| {
                    try b.string(&kp.publicBlob());
                    try b.string("held");
                }
            },
            Agent.msg.sign_request => {
                var req: wire.Reader = .init(body[1..]);
                const blob = try req.string();
                const data = try req.string();
                for (a.held) |kp| {
                    if (!std.mem.eql(u8, blob, &kp.publicBlob())) continue;
                    a.signed += 1;
                    try b.byte(Agent.msg.sign_response);
                    try b.string(&kp.sign(data));
                    break;
                } else try b.byte(Agent.msg.failure);
            },
            else => try b.byte(Agent.msg.failure),
        }
        try w.writeInt(u32, @intCast(b.bytes().len), .big);
        try w.writeAll(b.bytes());
        try w.flush();
    }
};

fn agentKey(seed: u8) keys.KeyPair {
    return .fromSeed(@splat(seed));
}

fn allowAgentKey(_: ?*anyopaque, _: []const u8, key: keys.PublicKey) bool {
    return std.mem.eql(u8, key.blob, &agentKey(22).publicBlob());
}

test "the agent: its Ed25519 keys offered, signed only once the server takes one" {
    // shortcut: an abstract socket keeps the test off the file system; Linux only.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var name: [24]u8 = undefined;
    const sock = try std.fmt.bufPrint(&name, "\x00snek-agent-{x}", .{testing.random_seed});
    const address: Io.net.UnixAddress = try .init(sock);
    var agent: FakeAgent = .{
        .held = .{ agentKey(21), agentKey(22) },
        .listener = try address.listen(testing.io, .{}),
    };
    defer agent.listener.deinit(testing.io);
    var serving = try testing.io.concurrent(FakeAgent.serve, .{&agent});
    defer serving.cancel(testing.io);

    var f: Fixture = .{
        .config = .{ .host_key = hostKey(), .handler = handler, .public_key = allowAgentKey },
        .listener = undefined,
    };
    try f.start();
    defer f.stop();
    const a = try Agent.connect(testing.allocator, testing.io, sock);
    defer a.close();

    var it = try a.identities();
    try testing.expectEqualStrings("an rsa key", (try it.next()).?.comment);
    try testing.expectEqualStrings("held", (try it.next()).?.comment);
    try testing.expectEqualStrings("held", (try it.next()).?.comment);
    try testing.expectEqual(null, try it.next());
    try testing.expectError(error.AgentRefused, a.sign("not a key", "data"));

    const client = try f.connect(.{ .user = "fay", .agent = a, .verify_host_key = trust });
    defer client.close();
    const result = try client.run(testing.allocator, "in");
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("in", result.stdout);
    // Key 21 was queried and refused, never signed with.
    try testing.expectEqual(1, agent.signed);
}

test "the agent over a Windows named pipe, as OpenSSH's agent listens" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const windows = std.os.windows;
    const pipe = struct {
        extern "kernel32" fn CreateNamedPipeW(
            name: [*:0]const u16,
            open_mode: windows.DWORD,
            pipe_mode: windows.DWORD,
            instances: windows.DWORD,
            out_size: windows.DWORD,
            in_size: windows.DWORD,
            timeout: windows.DWORD,
            security: ?*anyopaque,
        ) callconv(.winapi) windows.HANDLE;
        extern "kernel32" fn ConnectNamedPipe(
            handle: windows.HANDLE,
            overlapped: ?*anyopaque,
        ) callconv(.winapi) windows.BOOL;

        /// Waits for the client, then answers it until it hangs up.
        fn serve(agent: *FakeAgent, handle: windows.HANDLE) void {
            _ = ConnectNamedPipe(handle, null);
            const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
            var in_buffer: [1024]u8 = undefined;
            var out_buffer: [1024]u8 = undefined;
            var r = file.readerStreaming(testing.io, &in_buffer);
            var w = file.writerStreaming(testing.io, &out_buffer);
            while (agent.answer(&r.interface, &w.interface)) {} else |_| {}
        }
    };
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "\\\\.\\pipe\\snek-agent-{x}", .{testing.random_seed});
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, name);
    defer testing.allocator.free(name_w);
    // PIPE_ACCESS_DUPLEX; PIPE_TYPE_BYTE | PIPE_WAIT; one instance.
    const handle = pipe.CreateNamedPipeW(name_w, 0x3, 0, 1, 4096, 4096, 0, null);
    try testing.expect(handle != windows.INVALID_HANDLE_VALUE);
    defer windows.CloseHandle(handle);
    var agent: FakeAgent = .{ .held = .{ agentKey(21), agentKey(22) }, .listener = undefined };
    const serving = try std.Thread.spawn(.{}, pipe.serve, .{ &agent, handle });
    defer serving.join();

    const a = try Agent.connect(testing.allocator, testing.io, name);
    defer a.close();
    var it = try a.identities();
    try testing.expectEqualStrings("an rsa key", (try it.next()).?.comment);
    const blob = (try it.next()).?.blob;
    const kp = agentKey(21);
    try testing.expectEqualSlices(u8, &kp.publicBlob(), blob);
    var r: wire.Reader = .init(try a.sign(&kp.publicBlob(), "data"));
    try testing.expectEqualStrings("ssh-ed25519", try r.string());
    try testing.expectEqual(1, agent.signed);
    const missing = "\\\\.\\pipe\\snek-no-agent";
    try testing.expectError(error.FileNotFound, Agent.connect(testing.allocator, testing.io, missing));
}
