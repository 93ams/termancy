//! A client for ssh-agent (draft-miller-ssh-agent): the keys it holds, and signatures made
//! with them, so that the private keys never leave the agent. It talks over a Unix socket,
//! the one `$SSH_AUTH_SOCK` names, or on Windows over a named pipe: OpenSSH's agent
//! listens on `default_path` (`\\.\pipe\openssh-ssh-agent`).
//!
//! ```zig
//! const agent = try platform.ssh.Agent.connect(gpa, io, sock_path);
//! defer agent.close();
//! var it = try agent.identities();
//! while (try it.next()) |id| std.debug.print("{s}\n", .{id.comment});
//! ```

const Agent = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("wire.zig");

gpa: Allocator,
io: Io,
link: Link,
in_buffer: [4096]u8,
out_buffer: [4096]u8,
/// The last reply's body (its type, then its contents).
reply: std.ArrayList(u8),

/// What the agent is reached through.
const Link = union(enum) {
    socket: struct {
        stream: Io.net.Stream,
        reader: Io.net.Stream.Reader,
        writer: Io.net.Stream.Writer,
    },
    pipe: struct {
        file: Io.File,
        reader: Io.File.Reader,
        writer: Io.File.Writer,
    },
};

/// The protocol's message numbers.
pub const msg = struct {
    pub const failure = 5;
    pub const request_identities = 11;
    pub const identities_answer = 12;
    pub const sign_request = 13;
    pub const sign_response = 14;
};

/// The longest reply taken (OpenSSH's own limit).
pub const max_reply = 256 * 1024;

/// Where the agent is when `$SSH_AUTH_SOCK` is not set: Windows' OpenSSH agent's pipe;
/// null elsewhere, where there is no fixed place.
pub const default_path: ?[]const u8 = if (builtin.os.tag == .windows)
    "\\\\.\\pipe\\openssh-ssh-agent"
else
    null;

pub const Error = error{AgentRefused} || wire.Error || Io.Reader.Error || Io.Writer.Error ||
    Allocator.Error;

pub const ConnectError = Io.net.UnixAddress.InitError || Io.net.UnixAddress.ConnectError ||
    PipeError || Allocator.Error;

/// The pipe is not there (no agent running), or could not be opened.
pub const PipeError = error{ FileNotFound, AccessDenied, Unexpected };

/// Connects to the agent listening at `path`: a named pipe on Windows when `path` is one
/// (`\\.\pipe\...`), a Unix socket otherwise.
pub fn connect(gpa: Allocator, io: Io, path: []const u8) ConnectError!*Agent {
    const a = try gpa.create(Agent);
    errdefer gpa.destroy(a);
    a.gpa = gpa;
    a.io = io;
    a.reply = .empty;
    if (builtin.os.tag == .windows and isPipe(path)) {
        a.link = .{ .pipe = .{
            .file = try openPipe(gpa, path),
            .reader = undefined,
            .writer = undefined,
        } };
        a.link.pipe.reader = a.link.pipe.file.readerStreaming(io, &a.in_buffer);
        a.link.pipe.writer = a.link.pipe.file.writerStreaming(io, &a.out_buffer);
        return a;
    }
    const address: Io.net.UnixAddress = try .init(path);
    a.link = .{ .socket = .{
        .stream = try address.connect(io),
        .reader = undefined,
        .writer = undefined,
    } };
    a.link.socket.reader = a.link.socket.stream.reader(io, &a.in_buffer);
    a.link.socket.writer = a.link.socket.stream.writer(io, &a.out_buffer);
    return a;
}

pub fn close(a: *Agent) void {
    switch (a.link) {
        .socket => |*s| s.stream.close(a.io),
        .pipe => |*p| p.file.close(a.io),
    }
    a.reply.deinit(a.gpa);
    a.gpa.destroy(a);
}

fn isPipe(path: []const u8) bool {
    if (path.len < 9) return false;
    const sep = struct {
        fn is(c: u8) bool {
            return c == '\\' or c == '/';
        }
    }.is;
    return sep(path[0]) and sep(path[1]) and path[2] == '.' and sep(path[3]) and
        std.ascii.eqlIgnoreCase(path[4..8], "pipe") and sep(path[8]);
}

/// `Io.net` opens sockets only; a named pipe is a file, opened for synchronous reads and
/// writes, which `Io.File` streams over.
fn openPipe(gpa: Allocator, path: []const u8) (PipeError || Allocator.Error)!Io.File {
    const windows = std.os.windows;
    const name = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.FileNotFound,
    };
    defer gpa.free(name);
    const generic_read: windows.DWORD = 0x80000000;
    const generic_write: windows.DWORD = 0x40000000;
    const open_existing: windows.DWORD = 3;
    const handle = kernel32.CreateFileW(name, generic_read | generic_write, 0, null, open_existing, 0, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (kernel32.GetLastError()) {
        2, 3 => error.FileNotFound, // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
        5, 231 => error.AccessDenied, // ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY
        else => error.Unexpected,
    };
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

const kernel32 = struct {
    const windows = std.os.windows;
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: windows.DWORD,
        share: windows.DWORD,
        security: ?*anyopaque,
        disposition: windows.DWORD,
        flags: windows.DWORD,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
};

/// A key the agent holds; valid until the next request.
pub const Identity = struct { blob: []const u8, comment: []const u8 };

pub const Identities = struct {
    r: wire.Reader,
    left: u32,

    pub fn next(it: *Identities) wire.Error!?Identity {
        if (it.left == 0) return null;
        it.left -= 1;
        return .{ .blob = try it.r.string(), .comment = try it.r.string() };
    }
};

/// The keys the agent holds, of every kind; valid until the next request.
pub fn identities(a: *Agent) Error!Identities {
    var r: wire.Reader = .init(try a.request(&.{msg.request_identities}, msg.identities_answer));
    return .{ .left = try r.int(), .r = r };
}

/// The agent's signature of `data` with the key `blob`, in its wire form (the algorithm,
/// then the signature); valid until the next request.
pub fn sign(a: *Agent, blob: []const u8, data: []const u8) Error![]const u8 {
    var b: wire.Builder = .init(a.gpa);
    defer b.deinit();
    try b.byte(msg.sign_request);
    try b.string(blob);
    try b.string(data);
    try b.int(0);
    var r: wire.Reader = .init(try a.request(b.bytes(), msg.sign_response));
    return r.string();
}

/// Sends `body`, and returns the contents of a reply of type `want`.
fn request(a: *Agent, body: []const u8, want: u8) Error![]const u8 {
    const w, const r = switch (a.link) {
        .socket => |*s| .{ &s.writer.interface, &s.reader.interface },
        .pipe => |*p| .{ &p.writer.interface, &p.reader.interface },
    };
    try w.writeInt(u32, @intCast(body.len), .big);
    try w.writeAll(body);
    try w.flush();
    const len = try r.takeInt(u32, .big);
    if (len == 0 or len > max_reply) return error.Malformed;
    try a.reply.resize(a.gpa, len);
    try r.readSliceAll(a.reply.items);
    if (a.reply.items[0] == want) return a.reply.items[1..];
    // FAILURE, or (as old agents send) another refusal.
    return error.AgentRefused;
}
