//! `termancy serve`: a terminal program for everyone who connects with `ssh`, as Charm's
//! wish serves Bubble Tea programs, or with a browser (`--web`), as ttyd does. Each session
//! runs the command on a pseudo-terminal the size of theirs, follows their resizes, and
//! ends when it exits.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const field = @import("field");
const sys = @import("sys");
const term = @import("tui").term;
const ssh = sys.ssh;
const web = sys.web;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Flags = struct {
    listen: ?[]const u8 = null,
    web: bool = false,
    host_key: ?[]const u8 = null,
    authorized_keys: ?[]const u8 = null,
    anyone: bool = false,
    banner: []const u8 = "",
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .listen = .{ .help = "The address and port to listen on (default: " ++
        "127.0.0.1:2222, or 127.0.0.1:7681 with --web)" },
    .web = .{ .help = "Serve to browsers instead: a page with a terminal, behind a token" },
    .host_key = .{ .help = "The server's Ed25519 key (made when missing; default: in " ++
        "termancy's state directory)" },
    .authorized_keys = .{ .help = "Who may connect: an authorized_keys file " ++
        "(default: ~/.ssh/authorized_keys)" },
    .anyone = .{ .help = "Let anyone connect, without a key or token (for demos on " ++
        "trusted networks)" },
    .banner = .{ .help = "Text shown before logging in" },
} }}), .{ .fields = .{
    .listen = .{ .short = 'l' },
    .authorized_keys = .{ .short = 'k' },
} });

pub const command = cli.command(.{
    .name = "serve",
    .summary = "Serve a terminal program over SSH (wish) or the web (ttyd)",
    .description =
    \\Listen for SSH connections and run the command after -- for each one, on a pseudo-
    \\terminal the size of the client's, following its resizes. Logins are by public key:
    \\the keys in --authorized-keys (by default your own ~/.ssh/authorized_keys), or, with
    \\--anyone, no login at all. The command sees TERM, SSH_USER, SSH_CLIENT_KEY (the
    \\key's fingerprint) and SSH_ORIGINAL_COMMAND (what the client asked to run, never run
    \\itself). The host key is made on first use and kept.
    \\
    \\With --web, browsers connect instead: open the link it prints, whose token (new each
    \\run) lets you in; --anyone drops the token. Each tab runs its own command, with
    \\TERM=xterm-256color and COLORTERM=truecolor. There is no TLS: off this machine, put
    \\it behind a reverse proxy that adds it.
    ,
    .args = .{ .max = null, .usage = "-- command...", .passthrough = true },
    .flags = flags_flags,
    .logging = true,
    .examples =
    \\termancy serve -- termancy ui demo
    \\termancy serve --anyone -l 0.0.0.0:2222 -- htop
    \\ssh -p 2222 localhost
    \\termancy serve --web -- htop
    ,
    .run = run,
});

const Served = struct {
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
    allowed: []const ssh.keys.Authorized,
    /// For `log`; sessions report from tasks of their own.
    ctx: *cli.Context,
    mutex: std.Io.Mutex = .init,

    fn log(served: *Served, comptime fmt: []const u8, args: anytype) void {
        served.mutex.lockUncancelable(served.io);
        defer served.mutex.unlock(served.io);
        served.ctx.log(.info, fmt, args);
    }
};

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (!term.Pty.supported)
        return ctx.fail("serving needs pseudo-terminals, which this system lacks", .{});
    const argv = if (ctx.passthrough.len > 0) ctx.passthrough else ctx.args;
    if (argv.len == 0) return ctx.usageError("give the command to serve after --", .{});
    if (flags.web) return serveWeb(ctx, flags, argv);
    const listen = flags.listen orelse "127.0.0.1:2222";
    const address = parseAddress(listen) orelse
        return ctx.usageError("--listen {s}: give an address and port, as 127.0.0.1:2222", .{
            listen,
        });

    const key_path = flags.host_key orelse try std.fs.path.join(ctx.arena, &.{
        try sys.dirs.nativePath(ctx.arena, ctx.environ, .state, "termancy"),
        "ssh_host_ed25519_key",
    });
    const host_key = loadOrCreateKey(ctx, key_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("{s}: {s}", .{ key_path, @errorName(err) }),
    };

    var allowed: []const ssh.keys.Authorized = &.{};
    if (!flags.anyone) {
        const path = flags.authorized_keys orelse if (ctx.environ.get("HOME")) |home|
            try std.fs.path.join(ctx.arena, &.{ home, ".ssh", "authorized_keys" })
        else
            return ctx.usageError("give --authorized-keys, or --anyone", .{});
        const text = Io.Dir.cwd().readFileAlloc(
            ctx.io,
            path,
            ctx.arena,
            .limited(1 << 20),
        ) catch |err| return ctx.fail(
            "{s}: {s} (give --authorized-keys, or --anyone)",
            .{ path, @errorName(err) },
        );
        const all = try ssh.keys.parseAuthorizedKeys(ctx.arena, text);
        allowed = try withoutOptions(ctx.arena, all);
        if (allowed.len < all.len) ctx.warn(
            "{s}: {d} keys with options (from=, command=, restrict...) left out: " ++
                "this server does not enforce them",
            .{ path, all.len - allowed.len },
        );
        if (allowed.len == 0) return ctx.fail("{s}: no keys this server can check", .{path});
    }

    var served: Served = .{
        .gpa = ctx.gpa,
        .io = ctx.io,
        .argv = argv,
        .environ = ctx.environ,
        .allowed = allowed,
        .ctx = ctx,
    };
    var listener = address.listen(ctx.io, .{ .reuse_address = true }) catch |err|
        return ctx.fail("{s}: {s}", .{ listen, @errorName(err) });
    defer listener.deinit(ctx.io);
    var fp_buffer: [50]u8 = undefined;
    const host_blob = host_key.publicBlob();
    const fp = (ssh.keys.PublicKey.parse(&host_blob) catch unreachable).fingerprint(&fp_buffer);
    try ctx.err.print("serving {s} on {s} (host key {s}){s}\n", .{
        argv[0], listen, fp, if (flags.anyone) ", open to anyone" else "",
    });
    try ctx.err.flush();
    const config: ssh.Server.Config = .{
        .host_key = host_key,
        .handler = handle,
        .context = &served,
        .public_key = if (flags.anyone) null else allow,
        .anyone = flags.anyone,
        .banner = flags.banner,
    };
    ssh.Server.serve(ctx.gpa, ctx.io, &listener, &config) catch |err|
        return ctx.fail("{s}: {s}", .{ listen, @errorName(err) });
}

/// The command for each browser that opens the page.
fn serveWeb(ctx: *cli.Context, flags: Flags, argv: []const []const u8) !void {
    if (flags.host_key != null or flags.authorized_keys != null or flags.banner.len > 0)
        return ctx.usageError("--host-key, --authorized-keys and --banner are for SSH", .{});
    const listen = flags.listen orelse "127.0.0.1:7681";
    const address = parseAddress(listen) orelse
        return ctx.usageError("--listen {s}: give an address and port, as 127.0.0.1:7681", .{
            listen,
        });
    var served: Served = .{
        .gpa = ctx.gpa,
        .io = ctx.io,
        .argv = argv,
        .environ = ctx.environ,
        .allowed = &.{},
        .ctx = ctx,
    };
    var listener = address.listen(ctx.io, .{ .reuse_address = true }) catch |err|
        return ctx.fail("{s}: {s}", .{ listen, @errorName(err) });
    defer listener.deinit(ctx.io);
    const bound = listener.socket.address;
    if (!web.Server.isLoopback(bound)) if (flags.anyone) ctx.warn(
        "{f} is reachable from other machines, with no token: anyone who reaches it, or " ++
            "a web page they visit, runs the command as you.",
        .{bound},
    ) else ctx.warn(
        "{f} is reachable from other machines over plain HTTP: anyone on the way " ++
            "can read the token and the session. Put a TLS reverse proxy in front.",
        .{bound},
    );
    const token = web.Server.newToken(ctx.io);
    const config: web.Server.Config = .{
        .handler = web.Server.handlerFor(Served, handleWeb),
        .context = &served,
        .token = &token,
        .anyone = flags.anyone,
        .title = std.fs.path.basename(argv[0]),
    };
    try ctx.err.print("serving {s} on {f}{s}\n", .{
        argv[0], web.Server.link(bound, &config), if (flags.anyone) ", open to anyone" else "",
    });
    try ctx.err.flush();
    web.Server.serve(ctx.gpa, ctx.io, &listener, &config) catch |err|
        return ctx.fail("{s}: {s}", .{ listen, @errorName(err) });
}

fn handleWeb(served: *Served, session: *web.Session) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(served.gpa);
    defer arena_state.deinit();
    var env = try served.environ.clone(arena_state.allocator());
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    served.log("a browser connected from {f}", .{session.remote});
    const size: ssh.Server.Size = .{ .width = session.size.width, .height = session.size.height };
    const status = try runOnPty(served, session, &env, size);
    served.log("the browser from {f} left (exit status {d})", .{ session.remote, status });
    session.exit(status);
}

fn parseAddress(text: []const u8) ?Io.net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host = host[1 .. host.len - 1];
    if (host.len == 0) host = "0.0.0.0";
    return Io.net.IpAddress.parse(host, port) catch null;
}

/// The Ed25519 key at `path`, made (and kept, readable only by the owner) when missing.
pub fn loadOrCreateKey(ctx: *cli.Context, path: []const u8) !ssh.keys.KeyPair {
    const cwd = Io.Dir.cwd();
    if (cwd.readFileAlloc(ctx.io, path, ctx.arena, .limited(64 * 1024))) |text| {
        return ssh.keys.KeyPair.readPrivate(ctx.gpa, text, "", null, ctx.arena);
    } else |err| if (err != error.FileNotFound) return err;
    const key: ssh.keys.KeyPair = .generate(ctx.io);
    var out: Io.Writer.Allocating = .init(ctx.arena);
    try key.writePrivate(ctx.gpa, ctx.io, &out.writer, "termancy host key", "", 16);
    try sys.files.writeAtomic(ctx.io, cwd, path, out.written(), .{
        .permissions = sys.files.private_file,
        .make_path = true,
    });
    return key;
}

/// The keys without options: options restrict a key (to an address, a command), and a
/// key whose restrictions are not enforced must not get in.
fn withoutOptions(
    arena: Allocator,
    all: []const ssh.keys.Authorized,
) Allocator.Error![]const ssh.keys.Authorized {
    var kept: std.ArrayList(ssh.keys.Authorized) = .empty;
    for (all) |a| if (a.options.len == 0) try kept.append(arena, a);
    return kept.items;
}

fn allow(context: ?*anyopaque, _: []const u8, key: ssh.keys.PublicKey) bool {
    const served: *Served = @ptrCast(@alignCast(context.?));
    for (served.allowed) |a| if (a.key.eql(key)) return true;
    return false;
}

fn handle(context: ?*anyopaque, session: *ssh.Session) anyerror!void {
    const served: *Served = @ptrCast(@alignCast(context.?));
    const gpa = served.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try served.environ.clone(arena);
    const pty = session.pty orelse ssh.Session.Pty{
        .term = "xterm-256color",
        .size = .{ .width = 80, .height = 24 },
    };
    // Only a terminal has a type; without one, TERM says nothing true.
    if (session.pty != null) try env.put("TERM", pty.term) else _ = env.swapRemove("TERM");
    try env.put("SSH_USER", session.user);
    if (session.public_key) |key| {
        var fp: [50]u8 = undefined;
        try env.put("SSH_CLIENT_KEY", key.fingerprint(&fp));
    }
    if (session.command) |c| try env.put("SSH_ORIGINAL_COMMAND", c);
    // The locale they sent, as sshd's AcceptEnv does by default.
    for (session.env.items) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..eq];
        if (std.mem.eql(u8, name, "LANG") or
            std.mem.startsWith(u8, name, "LC_") or
            std.mem.eql(u8, name, "COLORTERM"))
            try env.put(name, entry[eq + 1 ..]);
    }
    // The client picks the name: escaped, so it cannot drive the terminal.
    served.log("{f} connected from {f}", .{ std.zig.fmtString(session.user), session.remote });

    const status = if (session.pty != null)
        try runOnPty(served, session, &env, pty.size)
    else
        try runPiped(served, session, &env);
    served.log("{f} from {f} left (exit status {d})", .{
        std.zig.fmtString(session.user),
        session.remote,
        status,
    });
    session.exit(status);
}

const poll: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } };

fn isStopSignal(name: []const u8) bool {
    return std.mem.eql(u8, name, "INT") or
        std.mem.eql(u8, name, "TERM") or
        std.mem.eql(u8, name, "HUP");
}

/// The command on a pseudo-terminal of `size`, for a session that asked for a terminal.
fn runOnPty(
    served: *Served,
    session: anytype,
    env: *const std.process.Environ.Map,
    size: ssh.Server.Size,
) !u32 {
    const io = served.io;
    var child = term.Pty.spawn(io, served.gpa, .{
        .argv = served.argv,
        .environ = env,
        .size = .{ .width = size.width, .height = size.height },
    }) catch |err| {
        try session.writeStderr("termancy: cannot start the program\r\n");
        return err;
    };
    defer child.deinit();
    var ended: std.atomic.Value(bool) = .init(false);
    var pump = try io.concurrent(pumpPty(@TypeOf(session)), .{ &child, session, &ended });
    // They went (or the server stops): the program was told to end, and `deinit` waits.
    var gone = false;
    // Input until the program's output ends (it exited) or they go.
    while (!ended.load(.acquire)) {
        // Canceled (the server stops): end the program, and clean up below as when it ends.
        const event = session.next(poll) catch {
            child.kill();
            gone = true;
            break;
        };
        switch (event) {
            .data => |bytes| child.write(bytes) catch break,
            .resize => |new| child.resize(.{ .width = new.width, .height = new.height }) catch {},
            .signal => |name| if (isStopSignal(name)) child.kill(),
            .eof, .timeout => {},
            .closed => {
                child.kill();
                gone = true;
                break;
            },
        }
    }
    pump.cancel(io);
    // Nobody is left to tell the status, and a program ignoring SIGHUP would hold `wait`
    // forever: `deinit` ends it instead.
    if (gone) return 255;
    const status = child.wait() catch term.Pty.Exit{ .exited = 255 };
    return status.status();
}

/// The program's output to `Session` (an SSH or a web session), until it ends.
fn pumpPty(comptime Session: type) fn (*term.Pty, Session, *std.atomic.Value(bool)) void {
    return struct {
        fn pump(child: *term.Pty, session: Session, ended: *std.atomic.Value(bool)) void {
            defer ended.store(true, .release);
            var buffer: [16 * 1024]u8 = undefined;
            while (true) {
                const n = child.read(&buffer) catch return;
                if (n == 0) return;
                session.write(buffer[0..n]) catch return;
            }
        }
    }.pump;
}

/// The command on pipes, as sshd runs commands without a terminal: bytes pass through
/// untouched (`ssh host cat file > copy`), standard error stays apart.
fn runPiped(served: *Served, session: *ssh.Session, env: *const std.process.Environ.Map) !u32 {
    const io = served.io;
    var child = std.process.spawn(io, .{
        .argv = served.argv,
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        try session.writeStderr("termancy: cannot start the program\n");
        return err;
    };
    var ended: std.atomic.Value(u8) = .init(0);
    var out_pump = try io.concurrent(pumpFile, .{ io, child.stdout.?, session, false, &ended });
    var err_pump = try io.concurrent(pumpFile, .{ io, child.stderr.?, session, true, &ended });
    var stdin: ?Io.File = child.stdin;
    var stopped = false;
    while (ended.load(.acquire) < 2) {
        const event = session.next(poll) catch {
            stop(&child);
            stopped = true;
            break;
        };
        switch (event) {
            .data => |bytes| if (stdin) |f| f.writeStreamingAll(io, bytes) catch {},
            .eof => if (stdin) |f| {
                f.close(io);
                stdin = null;
            },
            .signal => |name| if (isStopSignal(name)) {
                stop(&child);
                stopped = true;
            },
            .resize, .timeout => {},
            .closed => {
                stop(&child);
                stopped = true;
                break;
            },
        }
    }
    if (stdin) |f| f.close(io);
    child.stdin = null;
    out_pump.cancel(io);
    err_pump.cancel(io);
    if (stopped and builtin.os.tag != .windows) if (reapWithin(io, &child)) |code| return code;
    const term_status = child.wait(io) catch return 255;
    return switch (term_status) {
        .exited => |code| code,
        else => 255,
    };
}

/// Tells a piped program to end without waiting for it, so the session keeps reading:
/// `SIGHUP`, as for a pseudo-terminal (std's `kill` sends `SIGTERM`, then blocks until
/// the program obeys). Windows ends it outright.
fn stop(child: *std.process.Child) void {
    const id = child.id orelse return;
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1));
    } else std.posix.kill(id, .HUP) catch {};
}

/// POSIX: the exit status of a `stop`ped program that ended within a second; past that,
/// it is sent `SIGKILL` and null returned, for `wait` to reap it.
fn reapWithin(io: Io, child: *std.process.Child) ?u32 {
    const pid = child.id.?;
    for (0..20) |_| {
        var status: if (builtin.link_libc) c_int else i32 = 0;
        const rc = std.posix.system.wait4(pid, &status, std.posix.W.NOHANG, null);
        if (std.posix.errno(rc) == .SUCCESS and rc != 0) {
            // Reaped here, so here is where std's bookkeeping for it ends too.
            if (child.stdout) |f| f.close(io);
            if (child.stderr) |f| f.close(io);
            child.stdout = null;
            child.stderr = null;
            child.id = null;
            const bits: u32 = @bitCast(status);
            return if (std.posix.W.IFEXITED(bits)) std.posix.W.EXITSTATUS(bits) else 255;
        }
        // Canceled (the server stops): no grace.
        io.sleep(.fromMilliseconds(50), .awake) catch break;
    }
    std.posix.kill(pid, .KILL) catch {};
    return null;
}

fn pumpFile(
    io: Io,
    file: Io.File,
    session: *ssh.Session,
    stderr: bool,
    ended: *std.atomic.Value(u8),
) void {
    defer _ = ended.fetchAdd(1, .acq_rel);
    var buffer: [16 * 1024]u8 = undefined;
    var data = [1][]u8{&buffer};
    while (true) {
        const n = file.readStreaming(io, &data) catch return;
        if (n == 0) return;
        const chunk = buffer[0..n];
        (if (stderr) session.writeStderr(chunk) else session.write(chunk)) catch return;
    }
}

test parseAddress {
    try std.testing.expect(parseAddress("127.0.0.1:2222") != null);
    try std.testing.expect(parseAddress("[::1]:22") != null);
    try std.testing.expect(parseAddress(":2222") != null);
    try std.testing.expectEqual(null, parseAddress("localhost"));
}

test withoutOptions {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blob = ssh.keys.KeyPair.fromSeed(@splat(1)).publicBlob();
    var line: Io.Writer.Allocating = .init(arena.allocator());
    try (try ssh.keys.PublicKey.parse(&blob)).writeLine(&line.writer, "");
    const text = try std.fmt.allocPrint(arena.allocator(), "{s} plain\n" ++
        "from=\"10.0.0.1\" {s} limited\n", .{ line.written(), line.written() });
    const all = try ssh.keys.parseAuthorizedKeys(arena.allocator(), text);
    try std.testing.expectEqual(2, all.len);
    const kept = try withoutOptions(arena.allocator(), all);
    try std.testing.expectEqual(1, kept.len);
    try std.testing.expectEqualStrings("plain", kept[0].comment);
}
