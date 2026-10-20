//! A web server for terminal programs, as ttyd and gotty: a browser opens the page, the
//! page opens a WebSocket next to it, and each socket runs the `handler` with a `Session`
//! that reads and writes like the SSH server's, so a `tui.Program` runs over it with
//! `runSession`.
//!
//! The protocol: binary frames carry terminal bytes both ways; the page sends its size as
//! a text frame, `{"type":"resize","cols":80,"rows":24}`, first and on every change; the
//! server ends with `{"type":"exit","status":0}` and a close frame. The server pings now
//! and then, so proxies keep idle sessions open; the page sends `{"type":"heartbeat"}`
//! every 20 seconds, and a session silent for `idle_timeout` is hung up on (std's
//! WebSocket reads pongs away unseen, so they cannot tell a live browser from a dead one).
//!
//! Every request carries the token (constant-time compared) unless `anyone` is set: the
//! link's `?token=` once, which the page trades for an HttpOnly cookie and a redirect to the
//! clean URL, then the cookie (scripts may keep sending `?token=`). A socket's `Origin` must
//! be its `Host`, so other sites cannot open one with the visitor's browser. At most
//! `max_sessions` sockets are open at once; past that, upgrades get 503. There is no TLS:
//! off the loopback, put a reverse proxy in front (it should set `X-Forwarded-Proto`).
//!
//! ```zig
//! const Server = sys.web.Server;
//! const token = Server.newToken(io);
//! const config: Server.Config = .{
//!     .handler = Server.handlerFor(App, visit), // fn visit(app: *App, s: *Session) !void
//!     .context = &app,
//!     .token = &token,
//!     .title = "my app",
//! };
//! try out.print("open {f}\n", .{Server.link(listener.socket.address, &config)});
//! try Server.serve(gpa, io, &listener, &config);
//! ```
//!
//! A `tui` model runs in each session with `tui.runSession(gpa, io, &model, session, .{})`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const WebSocket = http.Server.WebSocket;

/// The page served at `/`: xterm.js and its fit addon, pinned, with integrity hashes.
pub const page = @embedFile("terminal.html");

/// What `serve` serves, and to whom.
pub const Config = struct {
    /// Runs once for each socket; the session ends when it returns. Runs on its own task.
    /// `handlerFor` makes one from a function that takes its context typed.
    handler: Handler,
    /// Passed to `handler`.
    context: ?*anyopaque = null,
    /// What every request must carry, as `?token=` or its cookie (see `newToken`); cookie-safe
    /// characters only, as hex is.
    token: []const u8,
    /// Let anyone in without the token: for demos on a trusted network only. On a loopback
    /// listener, `Host` must then be `localhost` or an address, so a site whose name resolves
    /// here (DNS rebinding) cannot open sessions: a proxy in front must keep such a `Host`.
    anyone: bool = false,
    /// The page served at `/`.
    page: []const u8 = page,
    /// The browser tab's title, in place of the page's `<title>terminal</title>` (escaped
    /// as HTML); null keeps the page's own.
    title: ?[]const u8 = null,
    /// How often a session pings the browser, and checks how long it has been silent.
    ping_interval: Io.Duration = .fromSeconds(30),
    /// How long a browser may send nothing (the page's heartbeat included) before it is hung
    /// up on. Hidden tabs may run the heartbeat only once a minute, so keep this above that.
    idle_timeout: Io.Duration = .fromSeconds(120),
    /// The most sessions open at once; more sockets are refused with 503.
    max_sessions: u32 = 32,
    /// How long a connection may take to send its request, before it is hung up on.
    head_timeout: Io.Duration = .fromSeconds(10),
};

/// What `Config.handler` is: it gets `Config.context` and the session.
pub const Handler = *const fn (context: ?*anyopaque, session: *Session) anyerror!void;

/// A `Config.handler` that calls `run` with `Config.context` as a `*Context`: set
/// `.context` to a `*Context`.
pub fn handlerFor(
    comptime Context: type,
    comptime run: fn (context: *Context, session: *Session) anyerror!void,
) Handler {
    return struct {
        fn handle(context: ?*anyopaque, session: *Session) anyerror!void {
            return run(@ptrCast(@alignCast(context.?)), session);
        }
    }.handle;
}

/// The link to print for `config` served at `address`, as `{f}`: `http://host:port/`,
/// with `?token=` unless `config.anyone`.
pub fn link(address: Io.net.IpAddress, config: *const Config) Link {
    return .{ .address = address, .token = if (config.anyone) "" else config.token };
}

/// See `link`.
pub const Link = struct {
    address: Io.net.IpAddress,
    token: []const u8,

    /// Writes the link.
    pub fn format(l: Link, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("http://{f}/", .{l.address});
        if (l.token.len > 0) try w.print("?token={s}", .{l.token});
    }
};

/// The largest message (and request head) a browser may send; the page sends no more.
pub const max_message = 64 * 1024;
/// Input waiting for the handler; past this, the connection stops reading.
const max_inbox = 1024 * 1024;

/// A terminal's size, in cells.
pub const Size = struct { width: u16, height: u16 };

/// What a session's browser sends: the same as an SSH session's events.
pub const Event = union(enum) {
    /// Typed input (valid until the next `next`).
    data: []const u8,
    /// The terminal changed size.
    resize: Size,
    /// Never sent here; for code written for SSH sessions.
    signal: []const u8,
    /// Never sent here; for code written for SSH sessions.
    eof,
    /// The time given to `next` passed.
    timeout,
    /// The connection is gone.
    closed,
};

/// A token of 128 random bits, in hex.
pub fn newToken(io: Io) [32]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Whether only this machine can reach `address`.
pub fn isLoopback(address: Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| a.isLoopBack(),
    };
}

/// One browser's terminal.
pub const Session = struct {
    /// The address they connect from.
    remote: Io.net.IpAddress,
    /// Their terminal's size: the one the page sent first, then the latest.
    size: Size = .{ .width = 80, .height = 24 },

    conn: *Connection,

    /// Waits for input, a resize, or the end, at most until `timeout`.
    pub fn next(s: *Session, timeout: Io.Timeout) Io.Cancelable!Event {
        return s.conn.next(timeout);
    }

    /// Writes to their terminal.
    pub fn write(s: *Session, bytes: []const u8) error{Disconnected}!void {
        return s.conn.send(bytes, .binary);
    }

    /// Writes to their terminal too: a browser has one screen.
    pub fn writeStderr(s: *Session, bytes: []const u8) error{Disconnected}!void {
        return s.write(bytes);
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
        s.conn.finish(status);
    }
};

/// What `Session.writer` returns: write to `interface`.
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

/// One socket: its reader hands input to the handler, each on a task of its own, while the
/// connection's task waits for either to end the connection.
const Connection = struct {
    gpa: Allocator,
    io: Io,
    config: *const Config,
    stream: Io.net.Stream,
    ws: WebSocket,
    /// Guards the frames going out, from the handler and the reader (pongs).
    send_lock: Io.Mutex = .init,
    finished: bool = false,
    /// Guards what follows, which `changed` announces.
    lock: Io.Mutex = .init,
    changed: Io.Condition = .init,
    inbox: std.ArrayList(u8) = .empty,
    taken: std.ArrayList(u8) = .empty,
    resize: ?Size = null,
    closed: std.atomic.Value(bool) = .init(false),
    /// The reader has the page's first message (and its size, if it was one).
    started: bool = false,
    /// The connection is over: the reader ended, the handler finished, or the browser went
    /// silent. The connection's task then cancels the reader.
    stopping: bool = false,
    /// When the browser last sent anything, in nanoseconds of the awake clock.
    last_seen: std.atomic.Value(i64),
    session: Session,

    fn next(c: *Connection, timeout: Io.Timeout) Io.Cancelable!Event {
        const io = c.io;
        try c.lock.lock(io);
        defer c.lock.unlock(io);
        const deadline = timeout.toDeadline(io);
        while (true) {
            if (c.resize) |size| {
                c.resize = null;
                c.session.size = size;
                return .{ .resize = size };
            }
            if (c.inbox.items.len > 0) {
                std.mem.swap(std.ArrayList(u8), &c.inbox, &c.taken);
                c.inbox.clearRetainingCapacity();
                c.changed.broadcast(io);
                return .{ .data = c.taken.items };
            }
            if (c.closed.load(.acquire)) return .closed;
            c.changed.waitTimeout(io, &c.lock, deadline) catch |err| switch (err) {
                error.Timeout => return .timeout,
                error.Canceled => return error.Canceled,
            };
        }
    }

    fn send(c: *Connection, bytes: []const u8, op: WebSocket.Opcode) error{Disconnected}!void {
        c.send_lock.lockUncancelable(c.io);
        defer c.send_lock.unlock(c.io);
        if (c.finished or c.closed.load(.acquire)) return error.Disconnected;
        c.ws.writeMessage(bytes, op) catch {
            c.close();
            return error.Disconnected;
        };
    }

    fn sendClose(c: *Connection, code: u16) void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        c.send(&payload, .connection_close) catch {};
    }

    /// Sends the exit status and a close frame (once), and hangs up.
    fn finish(c: *Connection, status: u32) void {
        var text: [48]u8 = undefined;
        const format = "{{\"type\":\"exit\",\"status\":{d}}}";
        const exit = std.fmt.bufPrint(&text, format, .{status}) catch unreachable;
        c.send(exit, .text) catch {};
        c.sendClose(1000);
        c.send_lock.lockUncancelable(c.io);
        c.finished = true;
        c.send_lock.unlock(c.io);
        // Stops the reader, which may wait on a browser that never answers the close.
        c.stop();
    }

    /// Ends the connection: the connection's task cancels the reader.
    fn stop(c: *Connection) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        c.stopping = true;
        c.changed.broadcast(c.io);
    }

    /// Waits until the reader has the page's first message (true) or the connection ends.
    fn awaitStart(c: *Connection) bool {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        while (!c.started) {
            if (c.stopping) return false;
            c.changed.wait(c.io, &c.lock) catch return false;
        }
        return true;
    }

    /// Waits until the connection ends.
    fn awaitStop(c: *Connection) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        while (!c.stopping) c.changed.wait(c.io, &c.lock) catch return;
    }

    /// The reader's task: the page's first message, which is its size, then the rest.
    fn read(c: *Connection) void {
        defer c.stop();
        defer c.close();
        if (!c.receive()) return;
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            if (c.resize) |size| {
                c.session.size = size;
                c.resize = null;
            }
            c.started = true;
            c.changed.broadcast(c.io);
        }
        while (c.receive()) {}
    }

    fn close(c: *Connection) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        c.closed.store(true, .release);
        c.changed.broadcast(c.io);
    }

    /// Reads and handles one message; false once the connection is over.
    fn receive(c: *Connection) bool {
        const message = c.ws.readSmallMessage() catch |err| {
            switch (err) {
                error.ConnectionClose => c.sendClose(1000),
                error.MessageOversize => c.sendClose(1009),
                error.UnexpectedOpCode, error.MissingMaskBit => c.sendClose(1002),
                error.ReadFailed, error.EndOfStream => {},
            }
            return false;
        };
        c.last_seen.store(awakeNow(c.io), .monotonic);
        switch (message.opcode) {
            .ping => c.send(message.data, .pong) catch return false,
            .binary => return c.deliver(message.data),
            .text => c.control(message.data),
            else => {},
        }
        return true;
    }

    fn deliver(c: *Connection, bytes: []const u8) bool {
        const io = c.io;
        c.lock.lock(io) catch return false;
        defer c.lock.unlock(io);
        // Backpressure: stop reading (and so the browser) until the handler catches up.
        while (c.inbox.items.len >= max_inbox and !c.closed.load(.acquire))
            c.changed.wait(io, &c.lock) catch return false;
        c.inbox.appendSlice(c.gpa, bytes) catch return false;
        c.changed.broadcast(io);
        return true;
    }

    fn control(c: *Connection, text: []const u8) void {
        var memory: [1024]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&memory);
        const Control = struct { type: []const u8, cols: u16 = 0, rows: u16 = 0 };
        const m = std.json.parseFromSliceLeaky(Control, fixed.allocator(), text, .{
            .ignore_unknown_fields = true,
        }) catch return;
        if (!std.mem.eql(u8, m.type, "resize") or m.cols == 0 or m.rows == 0) return;
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        c.resize = .{ .width = @min(m.cols, 1000), .height = @min(m.rows, 1000) };
        c.changed.broadcast(c.io);
    }

    /// Pings every `ping_interval`, and hangs up once the browser is silent for too long.
    fn watch(c: *Connection) void {
        const io = c.io;
        while (true) {
            io.sleep(c.config.ping_interval, .awake) catch return;
            const silent = awakeNow(io) - c.last_seen.load(.monotonic);
            if (silent >= c.config.idle_timeout.nanoseconds) {
                // No close frame: the peer is gone, and a write to it could block. This stops
                // the reader, and `shutdown` wakes a handler stuck writing.
                c.close();
                c.stop();
                c.stream.shutdown(io, .both) catch {};
                return;
            }
            // While the handler writes, its bytes keep the proxies awake instead.
            if (!c.send_lock.tryLock()) continue;
            defer c.send_lock.unlock(io);
            if (c.finished or c.closed.load(.acquire)) return;
            c.ws.writeMessage("", .ping) catch {
                c.close();
                return;
            };
        }
    }

    fn runHandler(c: *Connection) void {
        c.config.handler(c.config.context, &c.session) catch |err| {
            var text: [128]u8 = undefined;
            const shown = std.fmt.bufPrint(&text, "error: {s}\r\n", .{@errorName(err)}) catch
                "error\r\n";
            c.session.writeStderr(shown) catch {};
            c.finish(1);
            return;
        };
        c.finish(0);
    }
};

fn awakeNow(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

/// Serves one connection on `stream` until it ends: the page, a refusal, or a session.
/// Closes the stream. `sessions` counts the open ones, against `config.max_sessions`.
fn serveConnection(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    remote: Io.net.IpAddress,
    config: *const Config,
    sessions: *std.atomic.Value(u32),
    local: bool,
) void {
    defer stream.close(io);
    var in_buffer: [max_message]u8 = undefined;
    var out_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buffer);
    var writer = stream.writer(io, &out_buffer);
    var server: http.Server = .init(&reader.interface, &writer.interface);
    // Slow (or no) requests must not hold a task each forever. The read is canceled, not
    // cut off with `shutdown`: on Windows that does not wake a pending read
    // (docs/zig-issues.md, issue 4).
    var head: Head = .{ .server = &server };
    var receiving = io.concurrent(Head.receive, .{ &head, io }) catch return;
    const deadline: Io.Timeout = .{ .duration = .{ .raw = config.head_timeout, .clock = .awake } };
    head.done.waitTimeout(io, deadline) catch {};
    receiving.cancel(io);
    var request = (head.request orelse return) catch return;
    const ws = (accept(&request, config, sessions, local) catch return) orelse return;
    defer _ = sessions.fetchSub(1, .release);
    var conn: Connection = .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .stream = stream,
        .ws = ws,
        .last_seen = .init(awakeNow(io)),
        .session = .{ .remote = remote, .conn = undefined },
    };
    conn.session.conn = &conn;
    defer conn.inbox.deinit(gpa);
    defer conn.taken.deinit(gpa);
    // From the start: a socket that never says its size must not keep its slot either.
    var watchdog = io.concurrent(Connection.watch, .{&conn}) catch {
        conn.finish(1);
        return;
    };
    defer watchdog.cancel(io);
    // The reader is canceled, not stopped with `shutdown`: on Windows, `shutdown` does not
    // wake a pending read (docs/zig-issues.md, issue 4), so a browser that never answers the
    // close would keep it, and this task, forever.
    var reading = io.concurrent(Connection.read, .{&conn}) catch {
        conn.finish(1);
        return;
    };
    // The page's first message is its size, so the program starts at that size.
    if (!conn.awaitStart()) {
        reading.cancel(io);
        return;
    }
    var handler = io.concurrent(Connection.runHandler, .{&conn}) catch {
        conn.session.write("termancy: cannot start the session here\r\n") catch {};
        conn.finish(1);
        reading.cancel(io);
        return;
    };
    conn.awaitStop();
    reading.cancel(io);
    conn.close();
    handler.await(io);
}

/// A request head read in a task of its own, so that it can be given up on.
const Head = struct {
    server: *http.Server,
    /// Null until the read ends.
    request: ?(http.Server.ReceiveHeadError!http.Server.Request) = null,
    done: Io.Event = .unset,

    fn receive(h: *Head, io: Io) void {
        h.request = h.server.receiveHead();
        h.done.set(io);
    }
};

/// Answers a request for the page (or a refused one) and returns null, or accepts the
/// socket, holding one of `sessions` for it. `local`: the listener is on the loopback.
fn accept(
    request: *http.Server.Request,
    config: *const Config,
    sessions: *std.atomic.Value(u32),
    local: bool,
) !?WebSocket {
    const target = request.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |i| target[i + 1 ..] else "";
    const socket = std.mem.eql(u8, path, "/ws");
    if (!socket and !std.mem.eql(u8, path, "/"))
        return refuse(request, .not_found, "not found\n");
    if (config.anyone and local and !hostIsLiteral(request))
        return refuse(request, .misdirected_request, "open it as localhost or by address\n");
    const name = cookieName(config.token);
    const from_link = queryValue(query, "token");
    const given = from_link orelse headerCookie(request, &name);
    if (!config.anyone and !tokenMatches(config.token, given))
        return refuse(request, .unauthorized, "open the link the server printed, token and all\n");
    if (!socket and !config.anyone and from_link != null) {
        // Trade the link's token for a cookie, so it leaves the address bar and the history.
        // No Path: it defaults to this page's directory, behind a proxy's prefix too.
        var cookie: [256]u8 = undefined;
        try request.respond("", .{
            .status = .see_other,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "location", .value = "./" },
                .{ .name = "set-cookie", .value = try std.fmt.bufPrint(
                    &cookie,
                    "{s}={s}; HttpOnly; SameSite=Strict{s}",
                    .{ &name, config.token, if (viaHttps(request)) "; Secure" else "" },
                ) },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "referrer-policy", .value = "no-referrer" },
            },
        });
        return null;
    }
    if (!socket) {
        var titled: [16 * 1024]u8 = undefined;
        try request.respond(withTitle(&titled, config.page, config.title), .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "referrer-policy", .value = "no-referrer" },
                .{ .name = "x-frame-options", .value = "DENY" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
                // What holds for any `Config.page`; scripts and styles are the page's own.
                .{ .name = "content-security-policy", .value = csp },
            },
        });
        return null;
    }
    const key = switch (request.upgradeRequested()) {
        .websocket => |key| key orelse return refuse(request, .bad_request, "no key\n"),
        else => return refuse(request, .bad_request, "expected a WebSocket\n"),
    };
    if (!sameOrigin(request)) return refuse(request, .forbidden, "another site's page\n");
    if (!takeSlot(sessions, config.max_sessions))
        return refuse(request, .service_unavailable, "too many sessions; try again later\n");
    errdefer _ = sessions.fetchSub(1, .release);
    var ws = try request.respondWebSocket(.{ .key = key });
    try ws.flush();
    return ws;
}

const csp = "frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'";

/// `html` with `title` in place of its `<title>terminal</title>`, written to `buffer`; `html`
/// itself when there is no title, no such tag, or no room.
fn withTitle(buffer: []u8, html: []const u8, title: ?[]const u8) []const u8 {
    const tag = "<title>terminal</title>";
    const new = title orelse return html;
    const at = std.mem.indexOf(u8, html, tag) orelse return html;
    var w: Io.Writer = .fixed(buffer);
    w.writeAll(html[0..at]) catch return html;
    w.writeAll("<title>") catch return html;
    for (new) |c| (switch (c) {
        '&' => w.writeAll("&amp;"),
        '<' => w.writeAll("&lt;"),
        '>' => w.writeAll("&gt;"),
        '"' => w.writeAll("&quot;"),
        else => w.writeByte(c),
    }) catch return html;
    w.writeAll("</title>") catch return html;
    w.writeAll(html[at + tag.len ..]) catch return html;
    return w.buffered();
}

test withTitle {
    var buffer: [128]u8 = undefined;
    const html = "<head><title>terminal</title></head>";
    try testing.expectEqualStrings(
        "<head><title>a &lt;b&gt; &amp; &quot;c&quot;</title></head>",
        withTitle(&buffer, html, "a <b> & \"c\""),
    );
    try testing.expectEqualStrings(html, withTitle(&buffer, html, null));
    try testing.expectEqualStrings(html, withTitle(buffer[0..10], html, "long"));
    try testing.expectEqualStrings("<p>", withTitle(&buffer, "<p>", "x"));
}

test link {
    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:7681");
    const token = "abc";
    var text: [64]u8 = undefined;
    const config: Config = .{ .handler = echo, .token = token };
    try testing.expectEqualStrings(
        "http://127.0.0.1:7681/?token=abc",
        try std.fmt.bufPrint(&text, "{f}", .{link(address, &config)}),
    );
    const open: Config = .{ .handler = echo, .token = token, .anyone = true };
    try testing.expectEqualStrings(
        "http://127.0.0.1:7681/",
        try std.fmt.bufPrint(&text, "{f}", .{link(address, &open)}),
    );
}

fn takeSlot(sessions: *std.atomic.Value(u32), max: u32) bool {
    var n = sessions.load(.monotonic);
    while (n < max) n = sessions.cmpxchgWeak(n, n + 1, .acquire, .monotonic) orelse return true;
    return false;
}

/// The cookie's name, from the token: servers on other ports of one host (cookies ignore
/// ports) keep a cookie each.
fn cookieName(token: []const u8) [17]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return ("termancy_" ++ std.fmt.bytesToHex(digest[0..4].*, .lower)).*;
}

/// The value of cookie `name` in the request's `Cookie` headers.
fn headerCookie(request: *const http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
        var pairs = std.mem.splitScalar(u8, h.value, ';');
        while (pairs.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t");
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
        }
    }
    return null;
}

/// Whether the browser came over https: through a proxy that says so.
fn viaHttps(request: *const http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "x-forwarded-proto")) continue;
        // The first proxy's word is the browser's scheme.
        var hops = std.mem.splitScalar(u8, h.value, ',');
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, hops.first(), " \t"), "https");
    }
    return false;
}

fn refuse(request: *http.Server.Request, status: http.Status, text: []const u8) !?WebSocket {
    try request.respond(text, .{ .status = status, .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    } });
    return null;
}

fn queryValue(query: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// In time independent of where they differ: both are hashed, and the digests compared.
fn tokenMatches(want: []const u8, got: ?[]const u8) bool {
    if (want.len == 0) return false;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a: [Sha256.digest_length]u8 = undefined;
    var b: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(want, &a, .{});
    Sha256.hash(got orelse return false, &b, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, a, b);
}

/// Whether the page that opens the socket came from this server: `Origin` is the scheme
/// and `Host` (browsers always send it; without one, no).
fn sameOrigin(request: *const http.Server.Request) bool {
    var origin: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
    }
    const o = origin orelse return false;
    const h = host orelse return false;
    for ([_][]const u8{ "http://", "https://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(o, scheme))
            return std.ascii.eqlIgnoreCase(o[scheme.len..], h);
    }
    return false;
}

/// Whether `Host` is `localhost` or an address, port or not: no name DNS could rebind.
fn hostIsLiteral(request: *const http.Server.Request) bool {
    var it = request.iterateHeaders();
    const value = while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) break h.value;
    } else return false;
    var host = value;
    if (std.mem.startsWith(u8, value, "[")) {
        host = value[1 .. std.mem.indexOfScalar(u8, value, ']') orelse return false];
    } else if (std.mem.indexOfScalar(u8, value, ':')) |colon| host = value[0..colon];
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        if (Io.net.IpAddress.parse(host, 0)) |_| true else |_| false;
}

/// Serves every connection `server` accepts, each on its own task, until canceled.
pub fn serve(gpa: Allocator, io: Io, server: *Io.net.Server, config: *const Config) !void {
    var sessions: std.atomic.Value(u32) = .init(0);
    const local = isLoopback(server.socket.address);
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = try server.accept(io);
        group.concurrent(io, serveConnection, .{
            gpa,
            io,
            stream,
            stream.socket.address,
            config,
            &sessions,
            local,
        }) catch {
            stream.close(io);
        };
    }
}

const testing = std.testing;
const Client = @import("Client.zig");

/// Says its size, echoes input and resizes, and ends with status 7 on "bye".
fn echo(_: ?*anyopaque, s: *Session) anyerror!void {
    var text: [64]u8 = undefined;
    try s.write(try std.fmt.bufPrint(&text, "size {d}x{d}", .{ s.size.width, s.size.height }));
    while (true) switch (try s.next(.none)) {
        .data => |bytes| {
            if (std.mem.eql(u8, bytes, "bye")) return s.exit(7);
            try s.write(try std.fmt.bufPrint(&text, "got {s}", .{bytes}));
        },
        .resize => |z| try s.write(try std.fmt.bufPrint(&text, "now {d}x{d}", .{
            z.width, z.height,
        })),
        .closed => return,
        else => {},
    };
}

fn expectMessage(client: *Client, opcode: WebSocket.Opcode, data: []const u8) !void {
    const m = try client.receive();
    try testing.expectEqual(opcode, m.opcode);
    try testing.expectEqualStrings(data, m.data);
}

test "the page and the socket want the token and this server's origin" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const token = newToken(io);
    const config: Config = .{ .handler = echo, .token = &token };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};

    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});
    var target_buffer: [64]u8 = undefined;
    const ws_target = try std.fmt.bufPrint(&target_buffer, "/ws?token={s}", .{&token});
    var page_buffer: [64]u8 = undefined;
    const page_target = try std.fmt.bufPrint(&page_buffer, "/?token={s}", .{&token});
    const Case = struct { target: []const u8, origin: ?[]const u8, status: u16 };
    const cases = [_]Case{
        .{ .target = "/", .origin = null, .status = 401 },
        .{ .target = "/?token=nope", .origin = null, .status = 401 },
        .{ .target = page_target, .origin = null, .status = 303 },
        .{ .target = "/elsewhere", .origin = null, .status = 404 },
        .{ .target = "/ws", .origin = origin, .status = 401 },
        .{ .target = ws_target, .origin = "http://evil.example", .status = 403 },
        .{ .target = ws_target, .origin = null, .status = 400 },
    };
    for (cases) |case| {
        var client: Client = undefined;
        const status = try client.open(io, address, case.target, case.origin);
        client.close();
        testing.expectEqual(case.status, status) catch |err| {
            std.debug.print("{s}\n", .{case.target});
            return err;
        };
    }
}

test "a session: its size first, data both ways, a resize, and its exit" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const token = newToken(io);
    const config: Config = .{ .handler = echo, .token = &token };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};

    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});
    var target_buffer: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "/ws?token={s}", .{&token});
    var client: Client = undefined;
    try testing.expectEqual(101, try client.open(io, address, target, origin));
    defer client.close();
    try client.send(.text, "{\"type\":\"resize\",\"cols\":100,\"rows\":30}");
    try expectMessage(&client, .binary, "size 100x30");
    try client.send(.binary, "hi");
    try expectMessage(&client, .binary, "got hi");
    try client.send(.text, "{\"type\":\"resize\",\"cols\":90,\"rows\":20,\"extra\":1}");
    try expectMessage(&client, .binary, "now 90x20");
    try client.send(.text, "not json");
    try client.send(.ping, "beat");
    try expectMessage(&client, .pong, "beat");
    try client.send(.binary, "bye");
    try expectMessage(&client, .text, "{\"type\":\"exit\",\"status\":7}");
    try expectMessage(&client, .connection_close, "\x03\xe8");
}

test "a message past the limit closes the socket" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const config: Config = .{ .handler = echo, .token = "", .anyone = true };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};

    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});
    var client: Client = undefined;
    try testing.expectEqual(101, try client.open(io, address, "/ws", origin));
    defer client.close();
    try client.send(.binary, "first");
    try expectMessage(&client, .binary, "size 80x24");
    try expectMessage(&client, .binary, "got first");
    // Only the header: the server refuses before reading the rest.
    const w = &client.writer.interface;
    try w.writeAll(&.{ 0x82, 0x80 | 127 });
    try w.writeInt(u64, max_message + 1, .big);
    try w.writeAll("mask");
    try w.flush();
    try expectMessage(&client, .connection_close, "\x03\xf1");
}

/// A plain GET with `headers` (whole lines), and its whole response, in `out`.
fn get(
    io: Io,
    address: Io.net.IpAddress,
    target: []const u8,
    headers: []const u8,
    out: []u8,
) ![]u8 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var w_buffer: [512]u8 = undefined;
    var w = stream.writer(io, &w_buffer);
    try w.interface.print("GET {s} HTTP/1.1\r\nhost: {f}\r\n{s}\r\n", .{
        target, address, headers,
    });
    try w.interface.flush();
    var r_buffer: [1024]u8 = undefined;
    var r = stream.reader(io, &r_buffer);
    return out[0..try r.interface.readSliceShort(out)];
}

fn expectHas(haystack: []const u8, needle: []const u8) !void {
    testing.expect(std.mem.indexOf(u8, haystack, needle) != null) catch |err| {
        std.debug.print("no {s} in:\n{s}\n", .{ needle, haystack });
        return err;
    };
}

test "the link's token turns into a cookie, which opens the page and the socket" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const token = newToken(io);
    const config: Config = .{ .handler = echo, .token = &token };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};

    var buffer: [128]u8 = undefined;
    const with_token = try std.fmt.bufPrint(&buffer, "/?token={s}", .{&token});
    var out: [4096]u8 = undefined;
    var response = try get(io, address, with_token, "", &out);
    try expectHas(response, "HTTP/1.1 303 ");
    try expectHas(response, "location: ./\r\n");
    const name = cookieName(&token);
    var want: [128]u8 = undefined;
    try expectHas(response, try std.fmt.bufPrint(&want, "set-cookie: {s}={s}; HttpOnly; " ++
        "SameSite=Strict\r\n", .{ &name, &token }));
    response = try get(io, address, with_token, "x-forwarded-proto: https, http\r\n", &out);
    try expectHas(response, "SameSite=Strict; Secure\r\n");

    var cookie_buffer: [128]u8 = undefined;
    const cookie = try std.fmt.bufPrint(&cookie_buffer, "cookie: a=b; {s}={s}\r\n", .{
        &name, &token,
    });
    response = try get(io, address, "/", cookie, &out);
    try expectHas(response, "HTTP/1.1 200 ");
    try expectHas(response, "<title>terminal</title>");
    var wrong_buffer: [128]u8 = undefined;
    const wrong = try std.fmt.bufPrint(&wrong_buffer, "cookie: {s}=nope\r\n", .{&name});
    try expectHas(try get(io, address, "/", wrong, &out), "HTTP/1.1 401 ");

    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});
    var client: Client = undefined;
    try testing.expectEqual(101, try client.openWith(io, address, "/ws", origin, cookie));
    defer client.close();
    try client.send(.binary, "bye");
    try expectMessage(&client, .binary, "size 80x24");
    try expectMessage(&client, .text, "{\"type\":\"exit\",\"status\":7}");
}

test "past max_sessions, sockets get 503 until one ends, however it ends" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const config: Config = .{ .handler = echo, .token = "", .anyone = true, .max_sessions = 1 };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});

    // Ends three ways: the program exits, the browser hangs up, before or after its size.
    for (0..3) |how| {
        var first: Client = undefined;
        try testing.expectEqual(101, try openSoon(&first, io, address, origin));
        var second: Client = undefined;
        try testing.expectEqual(503, try second.open(io, address, "/ws", origin));
        second.close();
        if (how > 0) {
            if (how == 2) try first.send(.binary, "x");
            first.close();
            continue;
        }
        try first.send(.binary, "bye");
        try expectMessage(&first, .binary, "size 80x24");
        try expectMessage(&first, .text, "{\"type\":\"exit\",\"status\":7}");
        first.close();
    }
    var last: Client = undefined;
    try testing.expectEqual(101, try openSoon(&last, io, address, origin));
    last.close();
}

test "a session ends though its browser never answers the close" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const config: Config = .{ .handler = echo, .token = "", .anyone = true, .max_sessions = 1 };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});

    var mute: Client = undefined;
    try testing.expectEqual(101, try mute.open(io, address, "/ws", origin));
    defer mute.close();
    try mute.send(.binary, "bye");
    try expectMessage(&mute, .binary, "size 80x24");
    try expectMessage(&mute, .text, "{\"type\":\"exit\",\"status\":7}");
    try expectMessage(&mute, .connection_close, "\x03\xe8");
    // `mute` stays open and silent: the session's slot comes back only if its reader stops.
    var next: Client = undefined;
    try testing.expectEqual(101, try openSoon(&next, io, address, origin));
    next.close();
}

/// Opens "/ws", retrying while the server still frees the last session's slot.
fn openSoon(client: *Client, io: Io, address: Io.net.IpAddress, origin: []const u8) !u16 {
    for (0..200) |_| {
        const status = try client.open(io, address, "/ws", origin);
        if (status != 503) return status;
        client.close();
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return 503;
}

test "a silent browser is hung up on; one that sends heartbeats is not" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const config: Config = .{
        .handler = echo,
        .token = "",
        .anyone = true,
        .ping_interval = .fromMilliseconds(20),
        // Ten times a heartbeat's interval, for a loaded machine's late wakeups.
        .idle_timeout = .fromMilliseconds(500),
    };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});

    var lively: Client = undefined;
    try testing.expectEqual(101, try lively.open(io, address, "/ws", origin));
    defer lively.close();
    try lively.send(.text, "{\"type\":\"resize\",\"cols\":80,\"rows\":24}");
    try expectMessage(&lively, .binary, "size 80x24");
    // Twice the idle timeout, so only the heartbeats keep it open.
    for (0..20) |_| {
        try io.sleep(.fromMilliseconds(50), .awake);
        try lively.send(.text, "{\"type\":\"heartbeat\"}");
    }
    try lively.send(.binary, "still here");
    var pings: usize = 0;
    while (true) {
        const m = try lively.receive();
        if (m.opcode == .ping) {
            pings += 1;
            continue;
        }
        try testing.expectEqualStrings("got still here", m.data);
        break;
    }
    try testing.expect(pings > 0);

    var silent: Client = undefined;
    try testing.expectEqual(101, try silent.open(io, address, "/ws", origin));
    defer silent.close();
    while (true) {
        const m = silent.receive() catch break;
        try testing.expectEqual(.ping, m.opcode);
    }
}

test tokenMatches {
    try testing.expect(tokenMatches("abc", "abc"));
    try testing.expect(!tokenMatches("abc", "abd"));
    try testing.expect(!tokenMatches("abc", null));
    try testing.expect(!tokenMatches("", ""));
}

test "a typed handler gets its context, and the page carries the title" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const Greeter = struct {
        greeting: []const u8,
        fn greet(g: *@This(), s: *Session) anyerror!void {
            try s.write(g.greeting);
        }
    };
    var greeter: Greeter = .{ .greeting = "hello" };
    const config: Config = .{
        .handler = handlerFor(Greeter, Greeter.greet),
        .context = &greeter,
        .token = "",
        .anyone = true,
        .title = "lobby & co",
    };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};

    var response: [8192]u8 = undefined;
    try expectHas(try get(io, address, "/", "", &response), "<title>lobby &amp; co</title>");
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});
    var client: Client = undefined;
    try testing.expectEqual(101, try client.open(io, address, "/ws", origin));
    defer client.close();
    try client.send(.text, "{\"type\":\"resize\",\"cols\":80,\"rows\":24}");
    try expectMessage(&client, .binary, "hello");
}

/// Sends `head` (a whole request head) and returns the response, in `out`.
fn raw(io: Io, address: Io.net.IpAddress, head: []const u8, out: []u8) ![]u8 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var w = stream.writer(io, &.{});
    try w.interface.writeAll(head);
    var r_buffer: [1024]u8 = undefined;
    var r = stream.reader(io, &r_buffer);
    return out[0..try r.interface.readSliceShort(out)];
}

test "without a token on the loopback, a Host DNS could rebind is refused" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const config: Config = .{ .handler = echo, .token = "", .anyone = true };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};

    var out: [8192]u8 = undefined;
    const rebound = "GET /ws HTTP/1.1\r\nhost: evil.example:7681\r\n" ++
        "origin: http://evil.example:7681\r\nupgrade: websocket\r\nconnection: upgrade\r\n" ++
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n";
    try expectHas(try raw(io, address, rebound, &out), "HTTP/1.1 421 ");
    for ([_][]const u8{ "localhost:7681", "[::1]:7681", "127.0.0.1" }) |host| {
        var head: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&head, "GET / HTTP/1.1\r\nhost: {s}\r\n\r\n", .{host});
        const response = try raw(io, address, request, &out);
        try expectHas(response, "HTTP/1.1 200 ");
        try expectHas(response, "content-security-policy: frame-ancestors 'none';");
    }
}

test "a connection that never sends its request is hung up on" {
    const io = testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const quick: Io.Duration = .fromMilliseconds(50);
    const config: Config = .{ .handler = echo, .token = "x", .head_timeout = quick };
    var serving = try io.concurrent(serve, .{ testing.allocator, io, &listener, &config });
    defer serving.cancel(io) catch {};
    var out: [64]u8 = undefined;
    try testing.expectEqual(0, (try raw(io, address, "GET / HTTP/1.1\r\n", &out)).len);
}
