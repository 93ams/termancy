//! An SSH server for terminal programs, as Charm's wish: people connect with `ssh`, log in
//! with a public key or a password (or freely, for demos), and each session runs the
//! `handler` with what they asked for: a terminal (its type and size) and a shell, or a
//! command. A `Session` reads like a terminal (`next` gives input, resizes, and the end)
//! and writes like one, so a `tui.Program` runs over it with `runSession`. Port forwarding
//! (`ssh -L`, `ssh -R`) is off unless `direct_tcpip` or `tcpip_forward` allows it.
//!
//! ```zig
//! try sys.ssh.Server.listen(gpa, io, address, .{
//!     .host_key = host_key,
//!     .handler = serveCounter,
//!     .public_key = allowListed,
//! });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("wire.zig");
const keys = @import("keys.zig");
const transport = @import("transport.zig");
const connection = @import("connection.zig");
const Transport = transport.Transport;
const Channel = connection.Channel;
const msg = transport.msg;

pub const Config = struct {
    host_key: keys.KeyPair,
    /// Runs once for each session (a shell or a command); the session ends when it
    /// returns. Runs on its own task.
    handler: *const fn (context: ?*anyopaque, session: *Session) anyerror!void,
    context: ?*anyopaque = null,
    /// Whether `user` may log in with `key` (already proven theirs); null for no public
    /// key logins.
    public_key: ?*const fn (
        context: ?*anyopaque,
        user: []const u8,
        key: keys.PublicKey,
    ) bool = null,
    /// Whether `user` may log in with `password`; null for no password logins.
    password: ?*const fn (context: ?*anyopaque, user: []const u8, password: []const u8) bool = null,
    /// Whether `user` may have the server connect to `host`:`port` for them (`ssh -L`,
    /// `direct-tcpip`); null refuses every such connection.
    direct_tcpip: ?*const fn (
        context: ?*anyopaque,
        user: []const u8,
        host: []const u8,
        port: u16,
    ) bool = null,
    /// Whether `user` may have the server listen on `address`:`port` and send what
    /// connects there back to them (`ssh -R`, `tcpip-forward`); null refuses.
    tcpip_forward: ?*const fn (
        context: ?*anyopaque,
        user: []const u8,
        address: []const u8,
        port: u16,
    ) bool = null,
    /// Let anyone in without a key or password: for demos on a trusted network only.
    anyone: bool = false,
    /// Shown before logging in.
    banner: []const u8 = "",
    /// The version this server says it is.
    version: []const u8 = "SSH-2.0-termancy",
    /// Login attempts before hanging up.
    max_auth_tries: u8 = 6,
    /// Connections at once; more are turned away.
    max_connections: usize = 256,
    /// Hang up on a connection quiet this long before logging in.
    login_timeout: Io.Duration = .fromSeconds(60),
};

/// A terminal's size, in cells.
pub const Size = connection.Size;

/// What a session's client sends.
pub const Event = union(enum) {
    /// Typed input (valid until the next `next`).
    data: []const u8,
    /// The terminal changed size.
    resize: Size,
    /// A signal (`INT`, `TERM`, `HUP`, ...).
    signal: []const u8,
    /// No more input will come; output still goes out.
    eof,
    /// The time given to `next` passed.
    timeout,
    /// The connection is gone.
    closed,
};

/// One session: who, what they asked for, and their terminal.
pub const Session = struct {
    /// The name they logged in as.
    user: []const u8,
    /// The key they logged in with, if they did with one.
    public_key: ?keys.PublicKey,
    /// The address they connect from.
    remote: Io.net.IpAddress,
    /// The command they gave (`ssh host command`), or null for a shell.
    command: ?[]const u8 = null,
    /// Their terminal, when they asked for one (`pty-req`).
    pty: ?Pty = null,
    /// The variables they sent (`SendEnv`), as `NAME=value`.
    env: std.ArrayList([]const u8) = .empty,

    channel: *Channel,

    pub const Pty = struct { term: []const u8, size: Size };

    /// Waits for input, a resize, a signal, or the end, at most until `timeout`.
    pub fn next(s: *Session, timeout: Io.Timeout) Io.Cancelable!Event {
        while (true) return switch (try s.channel.next(timeout)) {
            .data => |d| .{ .data = d },
            .stderr => continue,
            .resize => |size| .{ .resize = size },
            .signal => |name| .{ .signal = name },
            .eof => .eof,
            .timeout => .timeout,
            .closed => .closed,
        };
    }

    /// Writes to their terminal (standard output), waiting for the window as needed.
    pub fn write(s: *Session, bytes: []const u8) transport.Error!void {
        return s.channel.write(msg.channel_data, bytes);
    }

    /// Writes to their standard error.
    pub fn writeStderr(s: *Session, bytes: []const u8) transport.Error!void {
        return s.channel.write(msg.channel_extended_data, bytes);
    }

    /// A writer over `write`, buffered in `buffer`.
    pub fn writer(s: *Session, buffer: []u8) SessionWriter {
        return .{ .session = s, .interface = .{
            .buffer = buffer,
            .vtable = &.{ .drain = SessionWriter.drain },
        } };
    }

    /// Ends the session with `status`, as the command's exit status.
    pub fn exit(s: *Session, status: u32) void {
        finish(s.channel, status);
    }

    /// The value of the variable `name` they sent, if they did.
    pub fn getEnv(s: *const Session, name: []const u8) ?[]const u8 {
        for (s.env.items) |entry| {
            if (entry.len > name.len and entry[name.len] == '=' and
                std.mem.startsWith(u8, entry, name))
                return entry[name.len + 1 ..];
        }
        return null;
    }
};

pub const SessionWriter = struct {
    session: *Session,
    interface: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const sw: *SessionWriter = @alignCast(@fieldParentPtr("interface", w));
        sw.session.write(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            sw.session.write(d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| sw.session.write(last) catch return error.WriteFailed;
        return n + last.len * splat;
    }
};

/// Sends the exit status, end of output, and close (once).
fn finish(c: *Channel, status: u32) void {
    const m = c.mux;
    m.lock.lockUncancelable(m.io);
    const already = c.sent_close or c.closed;
    m.lock.unlock(m.io);
    if (already) return;
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, status, .big);
    _ = c.request("exit-status", false, &b) catch {};
    c.sendEof();
    c.close();
}

/// A channel the server keeps: a session, or a forwarded connection.
const Served = struct {
    channel: Channel,
    session: Session,
    started: bool = false,
    /// The task serving it.
    future: ?Io.Future(void) = null,
    /// A forwarded connection, whose task is canceled rather than awaited at the end.
    forward: bool = false,
    /// What its requests keep (terminal type, variables, command); freed with it.
    arena: std.heap.ArenaAllocator,
};

/// The most variables (`env` requests) a session keeps, and the longest one.
const max_env = 64;
const max_env_len = 4096;

/// The signals a client may send (RFC 4254 section 6.10); names outside are refused.
const signal_names = [_][]const u8{
    "ABRT", "ALRM", "FPE", "HUP", "ILL", "INT", "KILL", "PIPE", "QUIT", "SEGV", "TERM", "USR1",
    "USR2",
};

/// A listener `ssh -R` asked for.
const Forward = struct {
    address: []const u8,
    port: u16,
    listener: Io.net.Server,
    future: Io.Future(void) = undefined,
};

const max_forwards = 4;

const Connection = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    config: *const Config,
    transport: Transport,
    remote: Io.net.IpAddress,
    user: []const u8 = "",
    public_key: ?keys.PublicKey = null,
    mux: connection.Mux,
    forwards: [max_forwards]?*Forward = @splat(null),

    fn run(conn: *Connection) !void {
        // A connection that has not logged in by the timeout is given up on. The login is
        // canceled, not cut off with `shutdown`: on Windows that does not wake a pending
        // read (docs/zig-issues.md, issue 4).
        const io = conn.io;
        var login: Login = .{ .conn = conn };
        var logging_in = try io.concurrent(Login.run, .{&login});
        const deadline: Io.Timeout = .{ .duration = .{ .raw = conn.config.login_timeout, .clock = .awake } };
        login.done.waitTimeout(io, deadline) catch {};
        logging_in.cancel(io);
        try (login.result orelse return error.Timeout);
        try conn.serve();
    }

    /// The handshake and the login, in a task of their own so that they can be given up on.
    const Login = struct {
        conn: *Connection,
        /// Null until they end.
        result: ?anyerror!void = null,
        done: Io.Event = .unset,

        fn run(l: *Login) void {
            l.result = l.go();
            l.done.set(l.conn.io);
        }

        fn go(l: *Login) !void {
            try l.conn.transport.handshake();
            try l.conn.authenticate();
        }
    };

    fn authenticate(conn: *Connection) !void {
        const t = &conn.transport;
        const asked = try t.read();
        if (asked[0] != msg.service_request) return error.ProtocolError;
        var r: wire.Reader = .init(asked[1..]);
        if (!std.mem.eql(u8, try r.string(), "ssh-userauth")) {
            t.disconnect(.service_not_available, "only ssh-userauth");
            return error.ProtocolError;
        }
        {
            var b: wire.Builder = .init(conn.gpa);
            defer b.deinit();
            try b.byte(msg.service_accept);
            try b.string("ssh-userauth");
            try t.send(b.bytes());
        }
        var tries: u8 = 0;
        var bannered = conn.config.banner.len == 0;
        while (true) {
            const payload = try t.read();
            if (payload[0] != msg.userauth_request) return error.ProtocolError;
            if (!bannered) {
                bannered = true;
                var b: wire.Builder = .init(conn.gpa);
                defer b.deinit();
                try b.byte(msg.userauth_banner);
                try b.string(conn.config.banner);
                try b.string("");
                try t.send(b.bytes());
            }
            var ar: wire.Reader = .init(payload[1..]);
            const user = try ar.string();
            const service = try ar.string();
            const method = try ar.string();
            if (!std.mem.eql(u8, service, "ssh-connection")) return error.ProtocolError;
            const ok = if (std.mem.eql(u8, method, "none"))
                conn.config.anyone
            else if (std.mem.eql(u8, method, "publickey"))
                try conn.publicKeyAuth(user, &ar) orelse continue
            else if (std.mem.eql(u8, method, "password")) password: {
                const check = conn.config.password orelse break :password false;
                _ = try ar.boolean();
                break :password check(conn.config.context, user, try ar.string());
            } else false;
            if (ok) {
                conn.user = try conn.arena.dupe(u8, user);
                try t.send(&.{msg.userauth_success});
                return;
            }
            if (!std.mem.eql(u8, method, "none")) tries += 1;
            if (tries >= conn.config.max_auth_tries) {
                t.disconnect(.no_more_auth_methods_available, "too many tries");
                return error.AuthenticationFailed;
            }
            var b: wire.Builder = .init(conn.gpa);
            defer b.deinit();
            try b.byte(msg.userauth_failure);
            var methods: [2][]const u8 = undefined;
            var n: usize = 0;
            if (conn.config.public_key != null) {
                methods[n] = "publickey";
                n += 1;
            }
            if (conn.config.password != null) {
                methods[n] = "password";
                n += 1;
            }
            try b.names(methods[0..n]);
            try b.boolean(false);
            try t.send(b.bytes());
        }
    }

    /// A public key login: true or false once proven, null after answering a query (is
    /// this key acceptable?) with `PK_OK`.
    fn publicKeyAuth(conn: *Connection, user: []const u8, r: *wire.Reader) !?bool {
        const check = conn.config.public_key orelse return false;
        const signed = try r.boolean();
        const algorithm = try r.string();
        const blob = try r.string();
        const key = keys.PublicKey.parse(blob) catch return false;
        if (!key.signsAs(algorithm)) return false;
        if (!signed) {
            if (!check(conn.config.context, user, key)) return false;
            var b: wire.Builder = .init(conn.gpa);
            defer b.deinit();
            try b.byte(msg.userauth_pk_ok);
            try b.string(algorithm);
            try b.string(blob);
            try conn.transport.send(b.bytes());
            return null;
        }
        const signature = try r.string();
        var data: wire.Builder = .init(conn.gpa);
        defer data.deinit();
        try data.string(&conn.transport.session_id.?);
        try data.byte(msg.userauth_request);
        try data.string(user);
        try data.string("ssh-connection");
        try data.string("publickey");
        try data.boolean(true);
        try data.string(algorithm);
        try data.string(blob);
        key.verify(signature, data.bytes()) catch return false;
        if (!check(conn.config.context, user, key)) return false;
        const kept = try conn.arena.dupe(u8, blob);
        conn.public_key = .{ .blob = kept, .kind = key.kind };
        return true;
    }

    fn serve(conn: *Connection) !void {
        defer conn.closeAll();
        const t = &conn.transport;
        while (true) {
            const payload = t.read() catch |err| switch (err) {
                error.Disconnected, error.EndOfStream => return,
                else => |e| return e,
            };
            switch (try conn.mux.dispatch(payload)) {
                .done => continue,
                .closed => |c| {
                    conn.release(@fieldParentPtr("channel", c));
                    continue;
                },
                .unhandled => {},
            }
            var r: wire.Reader = .init(payload[1..]);
            switch (payload[0]) {
                msg.global_request => {
                    const name = try r.string();
                    const want_reply = try r.boolean();
                    const ok = if (std.mem.eql(u8, name, "tcpip-forward"))
                        try conn.startForward(&r, want_reply)
                    else if (std.mem.eql(u8, name, "cancel-tcpip-forward"))
                        try conn.stopForward(&r)
                    else
                        false;
                    if (want_reply and !ok) try t.send(&.{msg.request_failure});
                    if (want_reply and ok and !std.mem.eql(u8, name, "tcpip-forward"))
                        try t.send(&.{msg.request_success});
                },
                msg.channel_open => try conn.open(&r),
                msg.channel_request => try conn.request(&r),
                msg.request_success, msg.request_failure => {},
                msg.service_request, msg.userauth_request => {},
                else => {
                    var b: [5]u8 = undefined;
                    b[0] = msg.unimplemented;
                    std.mem.writeInt(u32, b[1..5], t.recv_seq -% 1, .big);
                    try t.send(&b);
                },
            }
        }
    }

    fn served(conn: *Connection, id: u32) ?*Served {
        const c = conn.mux.get(id) orelse return null;
        return @fieldParentPtr("channel", c);
    }

    fn newServed(conn: *Connection, forward: bool) !*Served {
        const s = try conn.gpa.create(Served);
        s.* = .{
            .channel = .{ .mux = &conn.mux },
            .session = .{
                .user = conn.user,
                .public_key = conn.public_key,
                .remote = conn.remote,
                .channel = undefined,
            },
            .forward = forward,
            .arena = .init(conn.gpa),
        };
        s.session.channel = &s.channel;
        return s;
    }

    fn refuse(conn: *Connection, sender: u32, reason: u32, why: []const u8) !void {
        var b: wire.Builder = .init(conn.gpa);
        defer b.deinit();
        try b.byte(msg.channel_open_failure);
        try b.int(sender);
        try b.int(reason);
        try b.string(why);
        try b.string("");
        return conn.transport.send(b.bytes());
    }

    fn open(conn: *Connection, r: *wire.Reader) !void {
        const kind = try r.string();
        const sender = try r.int();
        const window = try r.int();
        const packet = try r.int();
        const session = std.mem.eql(u8, kind, "session");
        var host: []const u8 = "";
        var port: u16 = 0;
        if (std.mem.eql(u8, kind, "direct-tcpip")) {
            host = try r.string();
            const asked = try r.int();
            const check = conn.config.direct_tcpip orelse
                return conn.refuse(sender, 1, "forwarding is off");
            if (asked > 65535 or !check(conn.config.context, conn.user, host, @intCast(asked)))
                return conn.refuse(sender, 1, "not allowed");
            port = @intCast(asked);
        } else if (!session) return conn.refuse(sender, 3, "only sessions and direct-tcpip");
        conn.sweep();
        const s = try conn.newServed(!session);
        s.channel.remote_id = sender;
        s.channel.remote_window = window;
        s.channel.remote_max_packet = @max(packet, 256);
        conn.mux.add(&s.channel) catch {
            conn.gpa.destroy(s);
            return conn.refuse(sender, 4, "too many channels");
        };
        if (session) return conn.confirm(&s.channel);
        host = try s.arena.allocator().dupe(u8, host);
        // Connecting may take long: the forwarding task does, and answers the open.
        s.future = conn.io.concurrent(connectForward, .{ conn, s, host, port }) catch {
            s.channel.refused = true;
            conn.sweep();
            return conn.refuse(sender, 2, "cannot connect here");
        };
    }

    fn confirm(conn: *Connection, c: *Channel) !void {
        var b: wire.Builder = .init(conn.gpa);
        defer b.deinit();
        try b.byte(msg.channel_open_confirmation);
        try b.int(c.remote_id);
        try b.int(c.local_id);
        try b.int(connection.window_size);
        try b.int(connection.max_packet);
        try conn.transport.send(b.bytes());
    }

    /// `direct-tcpip`: connects, answers the open, and carries the data.
    fn connectForward(conn: *Connection, s: *Served, host: []const u8, port: u16) void {
        const c = &s.channel;
        const stream = connection.dial(conn.io, host, port) catch {
            conn.refuse(c.remote_id, 2, "cannot connect") catch {};
            // Left for `sweep` to free.
            conn.mux.lock.lockUncancelable(conn.io);
            defer conn.mux.lock.unlock(conn.io);
            c.refused = true;
            c.closed = true;
            return;
        };
        conn.confirm(c) catch return stream.close(conn.io);
        connection.pump(c, stream);
    }

    /// Frees the channels refused after all (their forwarding could not connect).
    fn sweep(conn: *Connection) void {
        var dead: [connection.max_channels]*Channel = undefined;
        var n: usize = 0;
        {
            const m = &conn.mux;
            m.lock.lockUncancelable(conn.io);
            defer m.lock.unlock(conn.io);
            for (&m.channels) |*slot| if (slot.*) |c| if (c.refused) {
                dead[n] = c;
                n += 1;
                slot.* = null;
            };
        }
        for (dead[0..n]) |c| conn.release(@fieldParentPtr("channel", c));
    }

    fn request(conn: *Connection, r: *wire.Reader) !void {
        const s = conn.served(try r.int()) orelse return;
        const c = &s.channel;
        const kind = try r.string();
        const want_reply = try r.boolean();
        var ok = true;
        // Kept with the channel, and bounded: a client cannot grow it without end.
        const arena = s.arena.allocator();
        if (s.forward) {
            ok = false;
        } else if (std.mem.eql(u8, kind, "pty-req") and s.session.pty == null) {
            const term_name = try arena.dupe(u8, try r.string());
            const width = try r.int();
            const height = try r.int();
            s.session.pty = .{ .term = term_name, .size = sizeOf(width, height) };
        } else if (std.mem.eql(u8, kind, "env")) {
            const name = try r.string();
            const value = try r.string();
            if (s.session.env.items.len < max_env and name.len + value.len < max_env_len) {
                const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{ name, value });
                try s.session.env.append(arena, pair);
            } else ok = false;
        } else if (std.mem.eql(u8, kind, "window-change")) {
            const size = sizeOf(try r.int(), try r.int());
            try conn.mux.lock.lock(conn.io);
            defer conn.mux.lock.unlock(conn.io);
            if (s.session.pty) |*pty| pty.size = size;
            c.resize = size;
            conn.mux.changed.broadcast(conn.io);
        } else if (std.mem.eql(u8, kind, "signal")) {
            const asked = try r.string();
            for (signal_names) |name| {
                if (!std.mem.eql(u8, name, asked)) continue;
                try conn.mux.lock.lock(conn.io);
                defer conn.mux.lock.unlock(conn.io);
                c.signal = name;
                conn.mux.changed.broadcast(conn.io);
                break;
            } else ok = false;
        } else if ((std.mem.eql(u8, kind, "shell") or std.mem.eql(u8, kind, "exec")) and
            !s.started)
        {
            if (std.mem.eql(u8, kind, "exec"))
                s.session.command = try arena.dupe(u8, try r.string());
            s.started = true;
            if (want_reply) try conn.reply(c, true);
            // The handler waits on input this task reads, so it needs a task of its own.
            s.future = conn.io.concurrent(runHandler, .{s}) catch {
                s.session.writeStderr("termancy: cannot start the session here\r\n") catch {};
                finish(c, 1);
                return;
            };
            return;
        } else ok = false;
        if (want_reply) try conn.reply(c, ok);
    }

    fn reply(conn: *Connection, c: *Channel, ok: bool) !void {
        var b: [5]u8 = undefined;
        b[0] = if (ok) msg.channel_success else msg.channel_failure;
        std.mem.writeInt(u32, b[1..5], c.remote_id, .big);
        try conn.transport.send(&b);
    }

    fn runHandler(s: *Served) void {
        const conn: *Connection = @fieldParentPtr("mux", s.channel.mux);
        conn.config.handler(conn.config.context, &s.session) catch |err| {
            var text: [128]u8 = undefined;
            const shown = std.fmt.bufPrint(&text, "error: {s}\r\n", .{@errorName(err)}) catch
                "error\r\n";
            s.session.writeStderr(shown) catch {};
            finish(&s.channel, 1);
            return;
        };
        finish(&s.channel, 0);
    }

    /// Frees a channel the client closed, after its task ends.
    fn release(conn: *Connection, s: *Served) void {
        if (s.future) |*f| {
            if (s.forward) f.cancel(conn.io) else f.await(conn.io);
        }
        s.channel.deinit();
        s.arena.deinit();
        conn.gpa.destroy(s);
    }

    /// `tcpip-forward`: listens where asked, if allowed; whether it does.
    fn startForward(conn: *Connection, r: *wire.Reader, want_reply: bool) !bool {
        const address = try r.string();
        const port = try r.int();
        const check = conn.config.tcpip_forward orelse return false;
        if (port > 65535 or !check(conn.config.context, conn.user, address, @intCast(port)))
            return false;
        const slot = for (&conn.forwards) |*f| {
            if (f.* == null) break f;
        } else return false;
        const any = address.len == 0 or std.mem.eql(u8, address, "*") or
            std.mem.eql(u8, address, "0.0.0.0");
        const local = std.mem.eql(u8, address, "localhost");
        const bind: []const u8 = if (any) "0.0.0.0" else if (local) "127.0.0.1" else address;
        const ip = Io.net.IpAddress.parse(bind, @intCast(port)) catch return false;
        const f = try conn.gpa.create(Forward);
        f.* = .{
            .address = try conn.arena.dupe(u8, address),
            .port = 0,
            .listener = ip.listen(conn.io, .{ .reuse_address = true }) catch {
                conn.gpa.destroy(f);
                return false;
            },
        };
        f.port = f.listener.socket.address.getPort();
        f.future = conn.io.concurrent(acceptForwarded, .{ conn, f }) catch {
            f.listener.deinit(conn.io);
            conn.gpa.destroy(f);
            return false;
        };
        slot.* = f;
        if (want_reply) {
            var b: [5]u8 = undefined;
            b[0] = msg.request_success;
            std.mem.writeInt(u32, b[1..5], f.port, .big);
            // The port goes back only when the server chose it.
            try conn.transport.send(if (port == 0) &b else b[0..1]);
        }
        return true;
    }

    /// `cancel-tcpip-forward`: whether there was such a listener.
    fn stopForward(conn: *Connection, r: *wire.Reader) !bool {
        const address = try r.string();
        const port = try r.int();
        for (&conn.forwards) |*slot| if (slot.*) |f| {
            if (f.port == port and std.mem.eql(u8, f.address, address)) {
                conn.endForward(f);
                slot.* = null;
                return true;
            }
        };
        return false;
    }

    fn endForward(conn: *Connection, f: *Forward) void {
        f.future.cancel(conn.io);
        f.listener.deinit(conn.io);
        conn.gpa.destroy(f);
    }

    /// Opens a `forwarded-tcpip` channel for each connection `f` accepts.
    fn acceptForwarded(conn: *Connection, f: *Forward) void {
        while (true) {
            const stream = f.listener.accept(conn.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return,
            };
            conn.forwardBack(f, stream) catch stream.close(conn.io);
        }
    }

    fn forwardBack(conn: *Connection, f: *Forward, stream: Io.net.Stream) !void {
        const s = try conn.newServed(true);
        s.channel.opening = true;
        conn.mux.add(&s.channel) catch |err| {
            conn.gpa.destroy(s);
            return err;
        };
        // The task starts before the open goes out: the reader frees the channel (and
        // awaits the task) once the client answers. From then on the task owns the stream.
        s.future = conn.io.concurrent(forwardOpened, .{ &s.channel, stream }) catch |err| {
            // Left for `sweep` to free.
            conn.mux.lock.lockUncancelable(conn.io);
            defer conn.mux.lock.unlock(conn.io);
            s.channel.refused = true;
            return err;
        };
        conn.sendForwardOpen(f, s, stream) catch {};
    }

    fn sendForwardOpen(conn: *Connection, f: *Forward, s: *Served, stream: Io.net.Stream) !void {
        var origin: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&origin);
        stream.socket.address.format(&w) catch {};
        const shown = w.buffered();
        const colon = std.mem.lastIndexOfScalar(u8, shown, ':') orelse shown.len;
        var b: wire.Builder = .init(conn.gpa);
        defer b.deinit();
        try b.string(f.address);
        try b.int(f.port);
        try b.string(std.mem.trim(u8, shown[0..colon], "[]"));
        try b.int(stream.socket.address.getPort());
        try conn.mux.sendOpen(&s.channel, "forwarded-tcpip", b.bytes());
    }

    fn forwardOpened(c: *Channel, stream: Io.net.Stream) void {
        c.waitOpen() catch return stream.close(c.mux.io);
        connection.pump(c, stream);
    }

    fn closeAll(conn: *Connection) void {
        for (&conn.forwards) |*slot| if (slot.*) |f| {
            conn.endForward(f);
            slot.* = null;
        };
        var left: [connection.max_channels]*Channel = undefined;
        const n = conn.mux.closeAll(&left);
        for (left[0..n]) |c| conn.release(@fieldParentPtr("channel", c));
    }
};

/// A terminal size as the client sends it; 0 (unknown) means 80 by 24.
fn sizeOf(width: u32, height: u32) Size {
    return .{
        .width = if (width == 0) 80 else @intCast(@min(width, 1000)),
        .height = if (height == 0) 24 else @intCast(@min(height, 1000)),
    };
}

/// Serves one connection on `stream` until it ends; closes the stream.
pub fn serveConnection(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    remote: Io.net.IpAddress,
    config: *const Config,
) void {
    defer stream.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buffer);
    var writer = stream.writer(io, &out_buffer);
    var conn: Connection = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .io = io,
        .config = config,
        .transport = .init(
            gpa,
            io,
            &reader.interface,
            &writer.interface,
            config.host_key,
            config.version,
        ),
        .remote = remote,
        .mux = .{ .gpa = gpa, .io = io, .transport = undefined },
    };
    conn.transport.socket_err = &reader.err;
    conn.mux.transport = &conn.transport;
    defer conn.transport.deinit();
    conn.run() catch |err| switch (err) {
        error.ProtocolError,
        error.MacError,
        => conn.transport.disconnect(.protocol_error, "protocol error"),
        error.KeyExchangeFailed => conn.transport.disconnect(
            .key_exchange_failed,
            "no common algorithms",
        ),
        else => {},
    };
}

/// Listens on `address` and serves every connection on its own task, until canceled.
pub fn listen(gpa: Allocator, io: Io, address: Io.net.IpAddress, config: Config) !void {
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    try serve(gpa, io, &server, &config);
}

/// Serves every connection `server` accepts, each on its own task, until canceled.
pub fn serve(gpa: Allocator, io: Io, server: *Io.net.Server, config: *const Config) !void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    var active: std.atomic.Value(usize) = .init(0);
    while (true) {
        const stream = try server.accept(io);
        if (active.fetchAdd(1, .monotonic) >= config.max_connections) {
            _ = active.fetchSub(1, .monotonic);
            stream.close(io);
            continue;
        }
        group.concurrent(io, serveCounted, .{ gpa, io, stream, config, &active }) catch {
            _ = active.fetchSub(1, .monotonic);
            stream.close(io);
        };
    }
}

fn serveCounted(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    config: *const Config,
    active: *std.atomic.Value(usize),
) void {
    defer _ = active.fetchSub(1, .monotonic);
    serveConnection(gpa, io, stream, stream.socket.address, config);
}
