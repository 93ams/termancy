//! SSH's connection layer (RFC 4254), for either side: channels, their windows (flow
//! control), and what arrives on them. One task reads the connection and hands each
//! message to `Mux.dispatch`; the tasks using channels wait on what it delivers. A
//! channel belongs to whoever made it, who frees it once it is `closed` (by then the
//! table no longer holds it).

const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");
const transport = @import("transport.zig");
const Transport = transport.Transport;
const msg = transport.msg;

/// Our window: what the other side may send before we ask for more.
pub const window_size = 2 * 1024 * 1024;
pub const max_packet = 32 * 1024;
pub const max_channels = 8;

/// A terminal's size, in cells.
pub const Size = struct { width: u16, height: u16 };

/// What arrives on a channel.
pub const Event = union(enum) {
    /// Data (valid until the next `next`).
    data: []const u8,
    /// Extended data: standard error (valid until the next `next`).
    stderr: []const u8,
    /// A server's session: the terminal changed size.
    resize: Size,
    /// A server's session: a signal (`INT`, `TERM`, ...).
    signal: []const u8,
    /// No more data will come.
    eof,
    /// The time given to `next` passed.
    timeout,
    /// The channel (or the connection) is gone.
    closed,
};

pub const Channel = struct {
    mux: *Mux,
    local_id: u32 = 0,
    remote_id: u32 = 0,
    /// What we may still send.
    remote_window: u64 = 0,
    remote_max_packet: u32 = 0,
    /// What they may still send before we adjust.
    local_window: u32 = window_size,
    /// Opened by this side and not answered yet.
    opening: bool = false,
    inbox: std.ArrayList(u8) = .empty,
    errbox: std.ArrayList(u8) = .empty,
    taken: std.ArrayList(u8) = .empty,
    resize: ?Size = null,
    signal: ?[]const u8 = null,
    /// The exit status the server sent for the command.
    exit_status: ?u32 = null,
    /// The answer to the request last sent wanting one; null while it is awaited.
    reply: ?bool = null,
    eof: bool = false,
    eof_seen: bool = false,
    /// They closed it, refused it, or the connection ended.
    closed: bool = false,
    /// They refused to open it.
    refused: bool = false,
    sent_eof: bool = false,
    sent_close: bool = false,
    /// Close once both sides sent EOF (forwarded connections).
    close_after_eof: bool = false,

    pub fn deinit(c: *Channel) void {
        const gpa = c.mux.gpa;
        c.inbox.deinit(gpa);
        c.errbox.deinit(gpa);
        c.taken.deinit(gpa);
    }

    /// Waits for data, an event, or the end, at most until `timeout`.
    pub fn next(c: *Channel, timeout: Io.Timeout) Io.Cancelable!Event {
        var adjust: u32 = 0;
        const event = try c.take(timeout, &adjust);
        // Sent once the lock is let go: sending may wait while keys change.
        if (adjust > 0) {
            var b: [9]u8 = undefined;
            b[0] = msg.channel_window_adjust;
            std.mem.writeInt(u32, b[1..5], c.remote_id, .big);
            std.mem.writeInt(u32, b[5..9], adjust, .big);
            c.mux.transport.send(&b) catch {};
        }
        return event;
    }

    fn take(c: *Channel, timeout: Io.Timeout, adjust: *u32) Io.Cancelable!Event {
        const m = c.mux;
        try m.lock.lock(m.io);
        defer m.lock.unlock(m.io);
        const deadline = timeout.toDeadline(m.io);
        while (true) {
            if (c.resize) |size| {
                c.resize = null;
                return .{ .resize = size };
            }
            if (c.signal) |name| {
                c.signal = null;
                return .{ .signal = name };
            }
            inline for (.{ "inbox", "errbox" }) |box| {
                const list = &@field(c, box);
                if (list.items.len > 0) {
                    c.taken.clearRetainingCapacity();
                    c.taken.appendSlice(m.gpa, list.items) catch return .closed;
                    c.local_window -= @intCast(list.items.len);
                    list.clearRetainingCapacity();
                    if (c.local_window < window_size / 2) {
                        adjust.* = window_size - c.local_window;
                        c.local_window = window_size;
                    }
                    return if (comptime std.mem.eql(u8, box, "inbox"))
                        .{ .data = c.taken.items }
                    else
                        .{ .stderr = c.taken.items };
                }
            }
            if (c.closed) return .closed;
            if (c.eof) {
                c.eof = false;
                return .eof;
            }
            m.changed.waitTimeout(m.io, &m.lock, deadline) catch |err| switch (err) {
                error.Timeout => return .timeout,
                error.Canceled => return error.Canceled,
            };
        }
    }

    /// Sends data (`msg.channel_data`) or standard error (`msg.channel_extended_data`),
    /// waiting for the window as needed.
    pub fn write(c: *Channel, kind: u8, bytes: []const u8) transport.Error!void {
        const m = c.mux;
        var rest = bytes;
        while (rest.len > 0) {
            var n: usize = undefined;
            {
                try m.lock.lock(m.io);
                defer m.lock.unlock(m.io);
                while (c.remote_window == 0 and !c.closed) try m.changed.wait(m.io, &m.lock);
                if (c.closed or c.sent_close or c.sent_eof) return error.Disconnected;
                n = @min(rest.len, c.remote_window, c.remote_max_packet, max_packet);
                c.remote_window -= n;
            }
            var b: wire.Builder = .init(m.gpa);
            defer b.deinit();
            try b.byte(kind);
            try b.int(c.remote_id);
            if (kind == msg.channel_extended_data) try b.int(1);
            try b.string(rest[0..n]);
            try m.transport.send(b.bytes());
            rest = rest[n..];
        }
    }

    /// Says no more data will come from this side (once).
    pub fn sendEof(c: *Channel) void {
        const m = c.mux;
        m.lock.lockUncancelable(m.io);
        const skip = c.sent_eof or c.sent_close or c.closed;
        c.sent_eof = true;
        const both = c.eof_seen and c.close_after_eof;
        m.lock.unlock(m.io);
        if (skip) return;
        c.sendId(msg.channel_eof);
        if (both) c.close();
    }

    /// Closes this side (once); the channel is `closed` when they close theirs.
    pub fn close(c: *Channel) void {
        const m = c.mux;
        m.lock.lockUncancelable(m.io);
        const skip = c.sent_close or c.refused;
        c.sent_close = true;
        m.lock.unlock(m.io);
        if (!skip) c.sendId(msg.channel_close);
    }

    /// Waits until they closed it too (or the connection ended); then it may be freed.
    pub fn waitClosed(c: *Channel) void {
        const m = c.mux;
        m.lock.lockUncancelable(m.io);
        defer m.lock.unlock(m.io);
        while (!c.closed) m.changed.waitUncancelable(m.io, &m.lock);
    }

    /// Waits for the answer to an open this side sent; error.ChannelRefused if refused.
    /// Not cancelable: a channel half open could be neither used nor freed.
    pub fn waitOpen(c: *Channel) error{ChannelRefused}!void {
        const m = c.mux;
        m.lock.lockUncancelable(m.io);
        defer m.lock.unlock(m.io);
        while (c.opening and !c.closed) m.changed.waitUncancelable(m.io, &m.lock);
        if (c.closed) return error.ChannelRefused;
    }

    /// Sends the request `name` with `args` (its data after the name and want-reply);
    /// with `want_reply`, waits for the answer: false when refused.
    pub fn request(
        c: *Channel,
        name: []const u8,
        want_reply: bool,
        args: []const u8,
    ) transport.Error!bool {
        const m = c.mux;
        if (want_reply) {
            try m.lock.lock(m.io);
            defer m.lock.unlock(m.io);
            c.reply = null;
        }
        var b: wire.Builder = .init(m.gpa);
        defer b.deinit();
        try b.byte(msg.channel_request);
        try b.int(c.remote_id);
        try b.string(name);
        try b.boolean(want_reply);
        try b.raw(args);
        try m.transport.send(b.bytes());
        if (!want_reply) return true;
        try m.lock.lock(m.io);
        defer m.lock.unlock(m.io);
        while (c.reply == null and !c.closed) try m.changed.wait(m.io, &m.lock);
        return c.reply orelse error.Disconnected;
    }

    fn sendId(c: *Channel, number: u8) void {
        var b: [5]u8 = undefined;
        b[0] = number;
        std.mem.writeInt(u32, b[1..5], c.remote_id, .big);
        c.mux.transport.send(&b) catch {};
    }
};

/// A connection's channels, and the lock and signal its tasks share.
pub const Mux = struct {
    gpa: std.mem.Allocator,
    io: Io,
    transport: *Transport,
    channels: [max_channels]?*Channel = @splat(null),
    lock: Io.Mutex = .init,
    changed: Io.Condition = .init,

    /// Gives `c` a number; error.TooManyChannels when all are in use.
    pub fn add(m: *Mux, c: *Channel) error{ TooManyChannels, Canceled }!void {
        try m.lock.lock(m.io);
        defer m.lock.unlock(m.io);
        for (&m.channels, 0..) |*slot, i| if (slot.* == null) {
            slot.* = c;
            c.local_id = @intCast(i);
            return;
        };
        return error.TooManyChannels;
    }

    pub fn get(m: *Mux, id: u32) ?*Channel {
        if (id >= max_channels) return null;
        m.lock.lockUncancelable(m.io);
        defer m.lock.unlock(m.io);
        return m.channels[id];
    }

    /// Asks the other side to open `c` (made with `.opening = true`) as a channel of
    /// `kind`, with `extra` following the window and packet size; `waitOpen` waits for
    /// the answer.
    pub fn open(m: *Mux, c: *Channel, kind: []const u8, extra: []const u8) !void {
        try m.add(c);
        m.sendOpen(c, kind, extra) catch |err| {
            m.lock.lockUncancelable(m.io);
            defer m.lock.unlock(m.io);
            if (m.channels[c.local_id] == c) m.channels[c.local_id] = null;
            return err;
        };
    }

    /// `open`'s message, for a channel already `add`ed.
    pub fn sendOpen(m: *Mux, c: *Channel, kind: []const u8, extra: []const u8) !void {
        var b: wire.Builder = .init(m.gpa);
        defer b.deinit();
        try b.byte(msg.channel_open);
        try b.string(kind);
        try b.int(c.local_id);
        try b.int(window_size);
        try b.int(max_packet);
        try b.raw(extra);
        try m.transport.send(b.bytes());
    }

    pub const Dispatched = union(enum) {
        done,
        /// Not about a channel's data or state: the caller's to handle.
        unhandled,
        /// They closed (or refused) this channel; it is out of the table, for its owner
        /// to free once nothing else uses it.
        closed: *Channel,
    };

    /// Handles a message about a channel's data, window, end, or answers.
    pub fn dispatch(m: *Mux, payload: []const u8) !Dispatched {
        var r: wire.Reader = .init(payload[1..]);
        switch (payload[0]) {
            msg.channel_window_adjust,
            msg.channel_data,
            msg.channel_extended_data,
            msg.channel_eof,
            msg.channel_close,
            msg.channel_open_confirmation,
            msg.channel_open_failure,
            msg.channel_success,
            msg.channel_failure,
            => {},
            msg.channel_request => {
                const c = m.get(try r.int()) orelse return .done;
                const name = try r.string();
                _ = try r.boolean();
                if (!std.mem.eql(u8, name, "exit-status")) return .unhandled;
                const status = try r.int();
                try m.lock.lock(m.io);
                defer m.lock.unlock(m.io);
                c.exit_status = status;
                return .done;
            },
            else => return .unhandled,
        }
        const c = m.get(try r.int()) orelse return .done;
        if (payload[0] == msg.channel_close) {
            // Answered before it counts as closed: once it does, its owner may free it.
            c.close();
            m.lock.lockUncancelable(m.io);
            defer m.lock.unlock(m.io);
            c.closed = true;
            m.channels[c.local_id] = null;
            m.changed.broadcast(m.io);
            return .{ .closed = c };
        }
        var close_now = false;
        var result: Dispatched = .done;
        {
            try m.lock.lock(m.io);
            defer m.lock.unlock(m.io);
            defer m.changed.broadcast(m.io);
            switch (payload[0]) {
                msg.channel_window_adjust => c.remote_window +|= try r.int(),
                msg.channel_data, msg.channel_extended_data => {
                    const extended = payload[0] == msg.channel_extended_data;
                    if (extended) _ = try r.int();
                    const data = try r.string();
                    const pending = c.inbox.items.len + c.errbox.items.len;
                    if (data.len > c.local_window - pending) return error.ProtocolError;
                    try (if (extended) &c.errbox else &c.inbox).appendSlice(m.gpa, data);
                },
                msg.channel_eof => {
                    c.eof = true;
                    c.eof_seen = true;
                    close_now = c.sent_eof and c.close_after_eof;
                },
                msg.channel_open_failure => {
                    if (!c.opening) return error.ProtocolError;
                    c.closed = true;
                    c.refused = true;
                    c.opening = false;
                    m.channels[c.local_id] = null;
                    result = .{ .closed = c };
                },
                msg.channel_open_confirmation => {
                    if (!c.opening) return error.ProtocolError;
                    c.remote_id = try r.int();
                    c.remote_window = try r.int();
                    c.remote_max_packet = @max(try r.int(), 256);
                    c.opening = false;
                },
                msg.channel_success, msg.channel_failure => {
                    c.reply = payload[0] == msg.channel_success;
                },
                else => unreachable,
            }
        }
        if (close_now) c.close();
        return result;
    }

    /// Marks every channel closed (the connection ended) and empties the table; returns
    /// how many it held, put in `out` for their owners.
    pub fn closeAll(m: *Mux, out: *[max_channels]*Channel) usize {
        m.lock.lockUncancelable(m.io);
        defer m.lock.unlock(m.io);
        var n: usize = 0;
        for (&m.channels) |*slot| if (slot.*) |c| {
            c.closed = true;
            c.opening = false;
            // Nothing more goes out on it.
            c.sent_eof = true;
            c.sent_close = true;
            out[n] = c;
            n += 1;
            slot.* = null;
        };
        m.changed.broadcast(m.io);
        return n;
    }
};

/// Connects to `host` (a name or an address) on `port`.
pub fn dial(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    const options: Io.net.IpAddress.ConnectOptions = .{ .mode = .stream };
    if (Io.net.IpAddress.parse(host, port)) |ip| return ip.connect(io, options) else |_| {}
    const name = try Io.net.HostName.init(host);
    return name.connect(io, port, options);
}

/// Carries a channel's data to and from `stream` until either side ends; closes the
/// stream. The channel is closed (on both sides) when this returns.
pub fn pump(c: *Channel, stream: Io.net.Stream) void {
    const io = c.mux.io;
    defer stream.close(io);
    {
        const m = c.mux;
        m.lock.lockUncancelable(m.io);
        defer m.lock.unlock(m.io);
        c.close_after_eof = true;
    }
    var up = io.concurrent(pumpUp, .{ c, stream }) catch {
        c.close();
        return;
    };
    defer up.cancel(io);
    var buffer: [4096]u8 = undefined;
    var w = stream.writer(io, &buffer);
    while (true) switch (c.next(.none) catch break) {
        .data => |d| {
            w.interface.writeAll(d) catch break;
            w.interface.flush() catch break;
        },
        .eof => stream.shutdown(io, .send) catch {},
        .closed => break,
        else => {},
    };
    c.close();
}

/// The stream's data to the channel, then EOF.
fn pumpUp(c: *Channel, stream: Io.net.Stream) void {
    var buffer: [max_packet]u8 = undefined;
    var r = stream.reader(c.mux.io, &buffer);
    while (true) {
        const got = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return c.sendEof(),
            else => return c.close(),
        };
        c.write(msg.channel_data, got) catch return;
        r.interface.toss(got.len);
    }
}
