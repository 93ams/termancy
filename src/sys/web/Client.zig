//! A minimal WebSocket client for a `Server`, for tests and scripts: plain `ws://` (no
//! TLS), whole messages (no fragments), one connection per value. Keep it in place once
//! opened: its reader and writer point into it.
//!
//! ```zig
//! var client: Client = undefined;
//! if (try client.open(io, address, "/ws?token=...", "http://127.0.0.1:7681") != 101) ...
//! defer client.close();
//! try client.send(.text, "{\"type\":\"resize\",\"cols\":80,\"rows\":24}");
//! const message = try client.receive();
//! ```

const std = @import("std");
const Io = std.Io;
const WebSocket = std.http.Server.WebSocket;

const Client = @This();

io: Io,
stream: Io.net.Stream,
reader: Io.net.Stream.Reader,
writer: Io.net.Stream.Writer,
in_buffer: [64 * 1024]u8,
out_buffer: [4096]u8,

/// A message received: its opcode and payload (valid until the next `receive`).
pub const Message = struct { opcode: WebSocket.Opcode, data: []u8 };

/// Connects and asks for `target`, as a socket from a page at `origin` when given (a
/// plain request otherwise), and returns the response's status: 101 when the socket is
/// open. Any other status leaves the response's body unread.
pub fn open(
    c: *Client,
    io: Io,
    address: Io.net.IpAddress,
    target: []const u8,
    origin: ?[]const u8,
) !u16 {
    return c.openWith(io, address, target, origin, "");
}

/// As `open`, with more request headers: whole lines, as "cookie: a=b\r\n".
pub fn openWith(
    c: *Client,
    io: Io,
    address: Io.net.IpAddress,
    target: []const u8,
    origin: ?[]const u8,
    headers: []const u8,
) !u16 {
    c.io = io;
    c.stream = try address.connect(io, .{ .mode = .stream });
    errdefer c.stream.close(io);
    c.reader = c.stream.reader(io, &c.in_buffer);
    c.writer = c.stream.writer(io, &c.out_buffer);
    const w = &c.writer.interface;
    try w.print("GET {s} HTTP/1.1\r\nhost: {f}\r\n", .{ target, address });
    if (origin) |o| {
        var key: [16]u8 = undefined;
        io.random(&key);
        var encoded: [24]u8 = undefined;
        try w.print("origin: {s}\r\nupgrade: websocket\r\nconnection: upgrade\r\n" ++
            "sec-websocket-version: 13\r\nsec-websocket-key: {s}\r\n", .{
            o, std.base64.standard.Encoder.encode(&encoded, &key),
        });
    }
    try w.writeAll(headers);
    try w.writeAll("\r\n");
    try w.flush();
    const r = &c.reader.interface;
    const status_line = try r.takeDelimiterInclusive('\n');
    if (status_line.len < 12) return error.BadResponse;
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadResponse;
    while ((try r.takeDelimiterInclusive('\n')).len > 2) {}
    return status;
}

/// Sends one message, masked as a client must.
pub fn send(c: *Client, opcode: WebSocket.Opcode, payload: []const u8) !void {
    const w = &c.writer.interface;
    try w.writeByte(0x80 | @as(u8, @backingInt(opcode)));
    if (payload.len < 126) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(0x80 | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    var mask: [4]u8 = undefined;
    c.io.random(&mask);
    try w.writeAll(&mask);
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
    try w.flush();
}

/// The next message (valid until the next `receive`); a close frame is one too.
pub fn receive(c: *Client) !Message {
    const r = &c.reader.interface;
    const header = try r.takeArray(2);
    const opcode: WebSocket.Opcode = @fromBackingInt(@intCast(header[0] & 0x0f));
    const len: usize = switch (header[1] & 0x7f) {
        126 => try r.takeInt(u16, .big),
        127 => std.math.cast(usize, try r.takeInt(u64, .big)) orelse return error.TooLong,
        else => |n| n,
    };
    return .{ .opcode = opcode, .data = try r.take(len) };
}

/// Closes the connection.
pub fn close(c: *Client) void {
    c.stream.close(c.io);
}
