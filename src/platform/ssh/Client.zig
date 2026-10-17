//! An SSH client: connects over a stream, checks the server's host key (with
//! `known_hosts` or a function of the caller's; nothing is trusted silently), logs in with
//! an Ed25519 key or a password, and opens sessions: commands with their input, output,
//! and exit status, or shells on a terminal. It also forwards local connections through the
//! server (`ssh -L`). One task, started by `connect`, reads the connection. Keys are
//! tried as OpenSSH tries them: `identity`, then the Ed25519 keys an ssh-agent holds, then
//! `default_identity`.
//!
//! ```zig
//! var client = try platform.ssh.Client.connect(gpa, io, stream, .{
//!     .user = "alice",
//!     .identity = key,
//!     .verify_host_key = KnownHosts.Verifier.check,
//!     .context = &verifier,
//! });
//! defer client.close();
//! const result = try client.run(gpa, "uname -a");
//! ```

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("wire.zig");
const keys = @import("keys.zig");
const transport_layer = @import("transport.zig");
const connection = @import("connection.zig");
const Agent = @import("Agent.zig");
const Transport = transport_layer.Transport;
const Channel = connection.Channel;
const msg = transport_layer.msg;

gpa: Allocator,
io: Io,
stream: Io.net.Stream,
reader: Io.net.Stream.Reader,
writer: Io.net.Stream.Writer,
in_buffer: [64 * 1024]u8,
out_buffer: [64 * 1024]u8,
transport: Transport,
mux: connection.Mux,
reading: ?Io.Future(void) = null,

pub const Config = struct {
    user: []const u8,
    /// Whether `key` is the server's (as `KnownHosts.Verifier.check` decides); required,
    /// so that no host key is trusted without a decision.
    verify_host_key: *const fn (context: ?*anyopaque, key: keys.PublicKey) bool,
    context: ?*anyopaque = null,
    /// The key to log in with (as `ssh -i`).
    identity: ?keys.KeyPair = null,
    /// An ssh-agent whose Ed25519 keys to log in with, after `identity`; other kinds are
    /// skipped.
    agent: ?*Agent = null,
    /// The key tried after the agent's (as OpenSSH tries `~/.ssh/id_ed25519`).
    default_identity: ?keys.KeyPair = null,
    /// The password to log in with, when the key is not enough.
    password: ?[]const u8 = null,
    /// The version this client says it is.
    version: []const u8 = "SSH-2.0-snek",
    /// The host key algorithms to offer, best first (put the kinds already known for the
    /// host first, as `KnownHosts.algorithms` gives).
    host_key_algorithms: []const []const u8 = &transport_layer.host_key_algorithms,
};

pub const Error = error{ HostKeyRejected, AuthenticationFailed } || transport_layer.Error ||
    wire.Error || Io.ConcurrentError;

/// Connects over `stream` (which the client then owns): the key exchange, the host key
/// check, and the login.
pub fn connect(gpa: Allocator, io: Io, stream: Io.net.Stream, config: Config) Error!*Client {
    const c = gpa.create(Client) catch |err| {
        stream.close(io);
        return err;
    };
    c.gpa = gpa;
    c.io = io;
    c.stream = stream;
    c.reader = stream.reader(io, &c.in_buffer);
    c.writer = stream.writer(io, &c.out_buffer);
    c.transport = .initClient(gpa, io, &c.reader.interface, &c.writer.interface, config.version);
    c.transport.socket_err = &c.reader.err;
    c.transport.host_key_preference = config.host_key_algorithms;
    c.mux = .{ .gpa = gpa, .io = io, .transport = &c.transport };
    c.reading = null;
    errdefer c.close();
    try c.transport.handshake();
    const host_key = keys.PublicKey.parse(c.transport.peer_host_key.items) catch unreachable;
    if (!config.verify_host_key(config.context, host_key)) {
        c.transport.disconnect(.by_application, "host key rejected");
        return error.HostKeyRejected;
    }
    try c.authenticate(config);
    c.reading = try io.concurrent(readLoop, .{c});
    return c;
}

/// Hangs up and frees the client; close sessions first.
pub fn close(c: *Client) void {
    // The reader stops first: a read cut off by `shutdown` fails on Windows with
    // `error.Unexpected` (and a stack trace in Debug) where POSIX ends the stream.
    if (c.reading) |*f| f.cancel(c.io);
    c.transport.disconnect(.by_application, "bye");
    c.stream.shutdown(c.io, .both) catch {};
    c.stream.close(c.io);
    c.transport.deinit();
    c.gpa.destroy(c);
}

/// The server's host key, as checked.
pub fn hostKey(c: *const Client) keys.PublicKey {
    return keys.PublicKey.parse(c.transport.peer_host_key.items) catch unreachable;
}

fn authenticate(c: *Client, config: Config) Error!void {
    const t = &c.transport;
    {
        var b: wire.Builder = .init(c.gpa);
        defer b.deinit();
        try b.byte(msg.service_request);
        try b.string("ssh-userauth");
        try t.send(b.bytes());
    }
    if ((try t.read())[0] != msg.service_accept) return error.ProtocolError;
    // "none" first: some servers let anyone in, and the others list what they take.
    if (try c.tryLogin(config.user, .none)) return;
    if (config.identity) |key| if (try c.tryLogin(config.user, .{ .key = key })) return;
    if (config.agent) |agent| if (try c.tryAgent(config.user, agent)) return;
    if (config.default_identity) |key|
        if (try c.tryLogin(config.user, .{ .key = key })) return;
    if (config.password) |p| if (try c.tryLogin(config.user, .{ .password = p })) return;
    t.disconnect(.no_more_auth_methods_available, "no way in");
    return error.AuthenticationFailed;
}

const Method = union(enum) {
    none,
    key: keys.KeyPair,
    agent: struct { agent: *Agent, blob: []const u8 },
    password: []const u8,
};

/// Tries each Ed25519 key the agent holds; an agent that fails is passed over.
fn tryAgent(c: *Client, user: []const u8, agent: *Agent) Error!bool {
    // Copied out: each request overwrites the agent's reply.
    var blobs: std.ArrayList([51]u8) = .empty;
    defer blobs.deinit(c.gpa);
    var it = agent.identities() catch return false;
    while (it.next() catch null) |id| {
        const key = keys.PublicKey.parse(id.blob) catch continue;
        if (key.kind != .ed25519) continue;
        try blobs.append(c.gpa, id.blob[0..51].*);
    }
    for (blobs.items) |*blob|
        if (try c.tryLogin(user, .{ .agent = .{ .agent = agent, .blob = blob } })) return true;
    return false;
}

fn tryLogin(c: *Client, user: []const u8, method: Method) Error!bool {
    var b: wire.Builder = .init(c.gpa);
    defer b.deinit();
    try b.byte(msg.userauth_request);
    try b.string(user);
    try b.string("ssh-connection");
    switch (method) {
        .none => try b.string("none"),
        .password => |p| {
            try b.string("password");
            try b.boolean(false);
            try b.string(p);
        },
        .key => |key| {
            const blob = key.publicBlob();
            try b.string("publickey");
            try b.boolean(true);
            try b.string("ssh-ed25519");
            try b.string(&blob);
            const data = try c.signedData(b.bytes());
            defer c.gpa.free(data);
            try b.string(&key.sign(data));
        },
        .agent => |a| {
            // Ask first, so that the agent (which may ask its user) signs only for a key
            // the server takes.
            const head = b.list.items.len;
            try b.string("publickey");
            try b.boolean(false);
            try b.string("ssh-ed25519");
            try b.string(a.blob);
            try c.transport.send(b.bytes());
            if (try c.awaitAuth(true) != msg.userauth_pk_ok) return false;
            // The same request, now saying a signature follows.
            b.list.items[head + 4 + "publickey".len] = 1;
            const data = try c.signedData(b.bytes());
            defer c.gpa.free(data);
            try b.string(a.agent.sign(a.blob, data) catch return false);
        },
    }
    try c.transport.send(b.bytes());
    return try c.awaitAuth(false) == msg.userauth_success;
}

/// What a signature covers: the session and the request so far (RFC 4252 7).
fn signedData(c: *Client, request: []const u8) Error![]u8 {
    var data: wire.Builder = .init(c.gpa);
    errdefer data.deinit();
    try data.string(&c.transport.session_id.?);
    try data.raw(request);
    return data.list.toOwnedSlice(c.gpa);
}

/// The server's answer to a login request: success, failure, or (to a key offered
/// without a signature, when `query`) that it would take the key.
fn awaitAuth(c: *Client, query: bool) Error!u8 {
    while (true) {
        const reply = try c.transport.read();
        switch (reply[0]) {
            msg.userauth_banner => continue,
            msg.userauth_success, msg.userauth_failure => return reply[0],
            msg.userauth_pk_ok => if (query) return reply[0] else return error.ProtocolError,
            else => return error.ProtocolError,
        }
    }
}

/// Reads the connection until it ends, refusing what the client does not take.
fn readLoop(c: *Client) void {
    defer {
        var left: [connection.max_channels]*Channel = undefined;
        _ = c.mux.closeAll(&left);
    }
    while (true) {
        const payload = c.transport.read() catch return;
        const handled = c.mux.dispatch(payload) catch return;
        if (handled == .unhandled) c.refuse(payload) catch return;
    }
}

fn refuse(c: *Client, payload: []const u8) !void {
    var r: wire.Reader = .init(payload[1..]);
    switch (payload[0]) {
        msg.global_request => {
            _ = try r.string();
            if (try r.boolean()) try c.transport.send(&.{msg.request_failure});
        },
        msg.channel_request => {
            const id = try r.int();
            _ = try r.string();
            if (!try r.boolean()) return;
            const ch = c.mux.get(id) orelse return;
            var b: [5]u8 = undefined;
            b[0] = msg.channel_failure;
            std.mem.writeInt(u32, b[1..5], ch.remote_id, .big);
            try c.transport.send(&b);
        },
        msg.channel_open => {
            _ = try r.string();
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try b.byte(msg.channel_open_failure);
            try b.int(try r.int());
            try b.int(1);
            try b.string("not taken");
            try b.string("");
            try c.transport.send(b.bytes());
        },
        else => {},
    }
}

/// Opens a channel of `kind` (with `extra` after the window and packet size); the
/// caller frees it with `finishChannel`.
fn openChannel(c: *Client, kind: []const u8, extra: []const u8) !*Channel {
    const ch = try c.gpa.create(Channel);
    ch.* = .{ .mux = &c.mux, .opening = true };
    c.mux.open(ch, kind, extra) catch |err| {
        c.gpa.destroy(ch);
        return err;
    };
    ch.waitOpen() catch |err| {
        ch.waitClosed();
        c.gpa.destroy(ch);
        return err;
    };
    return ch;
}

/// Closes `ch`, waits for the server to close it too, and frees it.
fn finishChannel(c: *Client, ch: *Channel) void {
    ch.close();
    ch.waitClosed();
    ch.deinit();
    c.gpa.destroy(ch);
}

/// A session: a command or a shell, with its input, output, and exit status.
pub const Session = struct {
    client: *Client,
    channel: *Channel,

    /// Asks for a terminal of type `term` and `size` (before `shell` or `exec`).
    pub fn pty(s: Session, term: []const u8, size: connection.Size) !void {
        var b: wire.Builder = .init(s.client.gpa);
        defer b.deinit();
        try b.string(term);
        try b.int(size.width);
        try b.int(size.height);
        try b.int(0);
        try b.int(0);
        try b.string(&.{0});
        if (!try s.channel.request("pty-req", true, b.bytes())) return error.Refused;
    }

    /// Sets a variable for the command (servers take only those they allow).
    pub fn env(s: Session, name: []const u8, value: []const u8) !void {
        var b: wire.Builder = .init(s.client.gpa);
        defer b.deinit();
        try b.string(name);
        try b.string(value);
        _ = try s.channel.request("env", false, b.bytes());
    }

    /// Starts the user's shell.
    pub fn shell(s: Session) !void {
        if (!try s.channel.request("shell", true, "")) return error.Refused;
    }

    /// Runs `command`.
    pub fn exec(s: Session, command: []const u8) !void {
        var b: wire.Builder = .init(s.client.gpa);
        defer b.deinit();
        try b.string(command);
        if (!try s.channel.request("exec", true, b.bytes())) return error.Refused;
    }

    /// Says the terminal changed size.
    pub fn resize(s: Session, size: connection.Size) !void {
        var b: [16]u8 = @splat(0);
        std.mem.writeInt(u32, b[0..4], size.width, .big);
        std.mem.writeInt(u32, b[4..8], size.height, .big);
        _ = try s.channel.request("window-change", false, &b);
    }

    /// Sends a signal (`INT`, `TERM`, ...: the name without `SIG`).
    pub fn signal(s: Session, name: []const u8) !void {
        var b: wire.Builder = .init(s.client.gpa);
        defer b.deinit();
        try b.string(name);
        _ = try s.channel.request("signal", false, b.bytes());
    }

    /// Writes to the command's standard input, waiting for the window as needed.
    pub fn write(s: Session, bytes: []const u8) !void {
        try s.channel.write(msg.channel_data, bytes);
    }

    /// Ends the command's standard input.
    pub fn closeInput(s: Session) void {
        s.channel.sendEof();
    }

    /// The next output (`data` for standard output, `stderr`), `eof`, or `closed` once the
    /// session is over; `timeout` when nothing came in time.
    pub fn read(s: Session, timeout: Io.Timeout) Io.Cancelable!connection.Event {
        return s.channel.next(timeout);
    }

    /// The command's exit status, once the server sent it (null when it ended by a
    /// signal, or not yet).
    pub fn exitStatus(s: Session) ?u32 {
        const m = s.channel.mux;
        m.lock.lockUncancelable(m.io);
        defer m.lock.unlock(m.io);
        return s.channel.exit_status;
    }

    /// Ends the session and frees it.
    pub fn close(s: Session) void {
        s.client.finishChannel(s.channel);
    }
};

/// Opens a session.
pub fn session(c: *Client) !Session {
    return .{ .client = c, .channel = try c.openChannel("session", "") };
}

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    /// Null when the command ended without one (by a signal).
    status: ?u32,

    pub fn deinit(r: Result, gpa: Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

/// The most `run` keeps of each output.
pub const max_output = 64 * 1024 * 1024;

/// Runs `command` with no input and returns its output and exit status.
pub fn run(c: *Client, gpa: Allocator, command: []const u8) !Result {
    const s = try c.session();
    defer s.close();
    try s.exec(command);
    s.closeInput();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    while (true) {
        const event = try s.read(.none);
        const list, const d = switch (event) {
            .data => |d| .{ &out, d },
            .stderr => |d| .{ &err, d },
            .closed => break,
            else => continue,
        };
        if (list.items.len + d.len > max_output) return error.StreamTooLong;
        try list.appendSlice(gpa, d);
    }
    return .{
        .stdout = try out.toOwnedSlice(gpa),
        .stderr = try err.toOwnedSlice(gpa),
        .status = s.exitStatus(),
    };
}

/// Forwards each connection `listener` accepts to `host`:`port` as the server sees it
/// (`ssh -L`), each on its own task, until canceled.
pub fn forwardLocal(c: *Client, listener: *Io.net.Server, host: []const u8, port: u16) !void {
    var group: Io.Group = .init;
    defer group.cancel(c.io);
    while (true) {
        const stream = try listener.accept(c.io);
        group.concurrent(c.io, forwardOne, .{ c, stream, host, port }) catch stream.close(c.io);
    }
}

fn forwardOne(c: *Client, stream: Io.net.Stream, host: []const u8, port: u16) void {
    var b: wire.Builder = .init(c.gpa);
    defer b.deinit();
    b.string(host) catch return stream.close(c.io);
    b.int(port) catch return stream.close(c.io);
    b.string("127.0.0.1") catch return stream.close(c.io);
    b.int(0) catch return stream.close(c.io);
    const ch = c.openChannel("direct-tcpip", b.bytes()) catch return stream.close(c.io);
    connection.pump(ch, stream);
    c.finishChannel(ch);
}
