//! A program running on a pseudo-terminal: it sees a real terminal (`isatty`, a size,
//! raw mode, job control), and its output can be read and its input written here. How
//! `termancy record` records sessions, `termancy explain` and `freeze` capture programs as
//! they draw for people, and end-to-end tests drive interactive programs.
//!
//! ```zig
//! var pty: term.Pty = try .spawn(io, gpa, .{ .argv = &.{ "ls", "--color" }, .environ = env });
//! defer pty.deinit();
//! var buffer: [4096]u8 = undefined;
//! while (true) {
//!     const n = try pty.read(&buffer);
//!     if (n == 0) break;
//!     screen.write(buffer[0..n]);
//! }
//! const status = try pty.wait();
//! ```
//!
//! On Linux and macOS: a new session whose controlling terminal is the pty's (so Ctrl-C
//! and resizes reach the program as signals). On Windows: a pseudo console (ConPTY,
//! Windows 10 1809 and later). Reads block; run them concurrently (`std.Io.concurrent`)
//! to wait on input and a clock at once.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const Size = @import("Terminal.zig").Size;

const native_os = builtin.os.tag;
const Pty = @This();

/// Whether this platform has pseudo-terminals here.
pub const supported = switch (native_os) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .windows => true,
    else => false,
};

/// The terminal ioctls, which not every platform's `posix.T` lists.
const tty = switch (native_os) {
    .linux => struct {
        const IOCSWINSZ = std.os.linux.T.IOCSWINSZ;
        const IOCSCTTY = std.os.linux.T.IOCSCTTY;
    },
    else => struct {
        const IOCSWINSZ = 0x80087467;
        const IOCSCTTY = 0x20007461;
    },
};

io: Io,
/// Where the program's output comes from.
output: File,
/// Where its input goes; the same file as `output` except on Windows.
input: File,
process: Process,
exited: ?Exit = null,

const Process = switch (native_os) {
    // `closer` closes the pseudo console once the program ends: until then its output
    // pipe stays open, and a read would never return 0.
    .windows => struct { handle: win.HANDLE, console: win.HANDLE, closer: std.Thread },
    else => if (supported) struct { pid: posix.pid_t } else struct {},
};

/// How a program ended.
pub const Exit = union(enum) {
    exited: u8,
    signaled: u8,

    /// The status a shell would report: the exit code, or 128 plus the signal.
    pub fn status(e: Exit) u8 {
        return switch (e) {
            .exited => |code| code,
            .signaled => |signal| 128 +| signal,
        };
    }
};

/// What `spawn` runs, and how.
pub const SpawnOptions = struct {
    /// The program and its arguments; the program is looked up on `PATH` unless it names
    /// a path.
    argv: []const []const u8,
    /// The program's whole environment.
    environ: *const std.process.Environ.Map,
    /// Its working directory; null for this process's.
    cwd: ?[]const u8 = null,
    size: Size = .{ .width = 80, .height = 24 },
};

/// What `spawn` can fail with.
pub const SpawnError = error{
    /// The platform has no pseudo-terminals here (WASI), or creating one failed.
    PtyUnavailable,
    /// The program was not found on `PATH`, or could not be started.
    SpawnFailed,
} || Allocator.Error;

/// Starts `options.argv` on a new pseudo-terminal of `options.size`.
pub fn spawn(io: Io, gpa: Allocator, options: SpawnOptions) SpawnError!Pty {
    return switch (native_os) {
        .windows => spawnWindows(io, gpa, options),
        .linux, .macos, .freebsd, .netbsd, .openbsd => spawnPosix(io, gpa, options),
        else => error.PtyUnavailable,
    };
}

/// Reads what the program wrote: at least one byte, or 0 once it has closed the terminal
/// (it ended). Blocks until there is something.
pub fn read(p: *Pty, buffer: []u8) Io.Cancelable!usize {
    var data = [1][]u8{buffer};
    return p.output.readStreaming(p.io, &data) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        // Linux reports the other side closing as an I/O error.
        else => 0,
    };
}

/// Types `bytes` into the program.
pub fn write(p: *Pty, bytes: []const u8) error{ WriteFailed, Canceled }!void {
    p.input.writeStreamingAll(p.io, bytes) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.WriteFailed,
    };
}

/// Changes the terminal's size; the program gets `SIGWINCH` (a resize event on Windows).
pub fn resize(p: *Pty, size: Size) error{ResizeFailed}!void {
    if (!supported) return error.ResizeFailed;
    switch (native_os) {
        .windows => {
            const coord: win.Coord = .{ .x = @intCast(size.width), .y = @intCast(size.height) };
            if (win.ResizePseudoConsole(p.process.console, coord) < 0) return error.ResizeFailed;
        },
        else => {
            var winsize: posix.winsize = .{
                .row = size.height,
                .col = size.width,
                .xpixel = 0,
                .ypixel = 0,
            };
            if (sys.ioctl(p.output.handle, tty.IOCSWINSZ, @intFromPtr(&winsize)) != 0) {
                return error.ResizeFailed;
            }
        },
    }
}

/// Waits for the program to end.
pub fn wait(p: *Pty) error{WaitFailed}!Exit {
    if (!supported) return error.WaitFailed;
    if (p.exited) |e| return e;
    const result: Exit = switch (native_os) {
        .windows => windows: {
            _ = win.WaitForSingleObject(p.process.handle, win.infinite);
            var code: u32 = 0;
            if (win.GetExitCodeProcess(p.process.handle, &code) == 0) return error.WaitFailed;
            break :windows .{ .exited = @truncate(code) };
        },
        else => try sys.waitpid(p.process.pid),
    };
    p.exited = result;
    return result;
}

/// Ends the program: `SIGHUP`, as when a terminal window closes (it ends the process on
/// Windows).
pub fn kill(p: *Pty) void {
    if (!supported or p.exited != null) return;
    switch (native_os) {
        .windows => _ = win.TerminateProcess(p.process.handle, 1),
        else => _ = sys.kill(p.process.pid, posix.SIG.HUP),
    }
}

/// Ends the program if it still runs, and closes the terminal. A program that ignores
/// `kill`'s `SIGHUP` for a second gets `SIGKILL`, with its whole process group.
pub fn deinit(p: *Pty) void {
    p.kill();
    if (comptime supported and native_os != .windows) p.escalate();
    _ = p.wait() catch {};
    switch (native_os) {
        .windows => {
            // The closer has closed the console, which ends the reads blocked on its output.
            p.process.closer.join();
            _ = win.CloseHandle(p.process.handle);
            p.input.close(p.io);
            p.output.close(p.io);
        },
        else => p.output.close(p.io),
    }
    p.* = undefined;
}

/// Waits up to a second for the program to end, then kills its process group (the
/// program leads its own session, so the group's id is its pid), so `wait` cannot block
/// forever on a program that ignores `SIGHUP`.
fn escalate(p: *Pty) void {
    if (p.exited != null) return;
    for (0..20) |_| {
        if (sys.poll(p.process.pid)) |e| {
            p.exited = e;
            return;
        }
        p.io.sleep(.fromMilliseconds(50), .awake) catch break;
    }
    _ = sys.kill(-p.process.pid, posix.SIG.KILL);
}

// POSIX: a new session on the pty's slave side, set up between fork and exec.

fn spawnPosix(io: Io, gpa: Allocator, options: SpawnOptions) SpawnError!Pty {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Everything the child needs is prepared before `fork`, which leaves it one thread
    // that may only make system calls.
    const program = try findProgram(arena, options.argv[0], options.environ) orelse
        return error.SpawnFailed;
    const argv = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (options.argv, argv) |arg, *slot| slot.* = try arena.dupeSentinel(u8, arg, 0);
    const envp = try arena.allocSentinel(?[*:0]const u8, options.environ.count(), null);
    var it = options.environ.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        envp[i] = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{
            entry.key_ptr.*,
            entry.value_ptr.*,
        }, 0);
    }
    const cwd: ?[*:0]const u8 = if (options.cwd) |dir| try arena.dupeSentinel(u8, dir, 0) else null;

    const master = sys.openMaster() orelse return error.PtyUnavailable;
    errdefer _ = sys.close(master);
    var slave_name: [64]u8 = undefined;
    const slave_path = sys.slaveName(master, &slave_name) orelse return error.PtyUnavailable;
    var winsize: posix.winsize = .{
        .row = options.size.height,
        .col = options.size.width,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = sys.ioctl(master, tty.IOCSWINSZ, @intFromPtr(&winsize));
    // The child reports a failed exec through this pipe, which closes on a good one.
    var report: [2]posix.fd_t = undefined;
    if (!sys.pipeCloexec(&report)) return error.PtyUnavailable;
    defer _ = sys.close(report[0]);

    const pid = sys.fork();
    if (pid < 0) {
        _ = sys.close(report[1]);
        return error.SpawnFailed;
    }
    if (pid == 0) child(master, slave_path, &winsize, report[1], program, argv, envp, cwd);
    _ = sys.close(report[1]);
    var errno: [4]u8 = undefined;
    if (sys.readAll(report[0], &errno) > 0) {
        _ = sys.waitpid(pid) catch {};
        return error.SpawnFailed;
    }
    const file: File = .{ .handle = master, .flags = .{ .nonblocking = false } };
    return .{ .io = io, .output = file, .input = file, .process = .{ .pid = pid } };
}

/// Runs in the child: becomes a session leader whose controlling terminal is the slave,
/// with it as standard input, output, and error, then runs the program.
fn child(
    master: posix.fd_t,
    slave_path: [*:0]const u8,
    winsize: *const posix.winsize,
    report: posix.fd_t,
    program: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
) noreturn {
    _ = sys.close(master);
    _ = sys.setsid();
    const slave = sys.openSlave(slave_path);
    if (slave < 0) sys.fail(report);
    // Again: macOS forgets a size set before the slave side was first opened.
    _ = sys.ioctl(slave, tty.IOCSWINSZ, @intFromPtr(winsize));
    _ = sys.ioctl(slave, tty.IOCSCTTY, @as(usize, 0));
    for ([_]posix.fd_t{ 0, 1, 2 }) |fd| _ = sys.dup2(slave, fd);
    if (slave > 2) _ = sys.close(slave);
    if (cwd) |dir| if (sys.chdir(dir) != 0) sys.fail(report);
    _ = sys.execve(program, argv, envp);
    sys.fail(report);
}

/// `name` as a path to run: as given when it names a path, else the first executable
/// file of that name in a `PATH` directory.
fn findProgram(
    arena: Allocator,
    name: []const u8,
    environ: *const std.process.Environ.Map,
) Allocator.Error!?[*:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return try arena.dupeSentinel(u8, name, 0);
    const path = environ.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{
            if (dir.len == 0) "." else dir,
            name,
        }, 0);
        if (sys.isExecutable(candidate)) return candidate;
    }
    return null;
}

/// The system calls the POSIX side needs: Linux's directly, the C library's elsewhere.
const sys = switch (native_os) {
    .linux => struct {
        const linux = std.os.linux;

        fn ok(rc: usize) bool {
            return posix.errno(rc) == .SUCCESS;
        }

        fn openMaster() ?posix.fd_t {
            const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
            const rc = linux.open("/dev/ptmx", flags, 0);
            if (!ok(rc)) return null;
            const fd: posix.fd_t = @intCast(rc);
            var unlock: c_int = 0;
            if (!ok(linux.ioctl(fd, linux.T.IOCSPTLCK, @intFromPtr(&unlock)))) {
                _ = linux.close(fd);
                return null;
            }
            return fd;
        }

        fn slaveName(master: posix.fd_t, buffer: *[64]u8) ?[*:0]const u8 {
            var number: c_uint = 0;
            if (!ok(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&number)))) return null;
            const name = std.fmt.bufPrintSentinel(buffer, "/dev/pts/{d}", .{number}, 0) catch
                return null;
            return name.ptr;
        }

        fn openSlave(path: [*:0]const u8) posix.fd_t {
            const rc = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
            return if (ok(rc)) @intCast(rc) else -1;
        }

        fn ioctl(fd: posix.fd_t, request: u32, arg: usize) c_int {
            return if (ok(linux.ioctl(fd, request, arg))) 0 else -1;
        }

        fn pipeCloexec(fds: *[2]posix.fd_t) bool {
            return ok(linux.pipe2(fds, .{ .CLOEXEC = true }));
        }

        fn fork() posix.pid_t {
            const rc = linux.fork();
            return if (ok(rc)) @intCast(rc) else -1;
        }

        fn setsid() void {
            _ = linux.setsid();
        }

        fn dup2(from: posix.fd_t, to: posix.fd_t) void {
            _ = linux.dup2(from, to);
        }

        fn close(fd: posix.fd_t) void {
            _ = linux.close(fd);
        }

        fn chdir(path: [*:0]const u8) c_int {
            return if (ok(linux.chdir(path))) 0 else -1;
        }

        fn execve(
            path: [*:0]const u8,
            argv: [*:null]const ?[*:0]const u8,
            envp: [*:null]const ?[*:0]const u8,
        ) void {
            _ = linux.execve(path, argv, envp);
        }

        fn fail(report: posix.fd_t) noreturn {
            const byte = [1]u8{1};
            _ = linux.write(report, &byte, 1);
            linux.exit_group(127);
        }

        fn readAll(fd: posix.fd_t, buffer: []u8) usize {
            const rc = linux.read(fd, buffer.ptr, buffer.len);
            return if (ok(rc)) rc else 0;
        }

        fn waitpid(pid: posix.pid_t) error{WaitFailed}!Exit {
            var status: i32 = 0;
            while (true) {
                const rc = linux.wait4(pid, &status, 0, null);
                switch (posix.errno(rc)) {
                    .SUCCESS => break,
                    .INTR => continue,
                    else => return error.WaitFailed,
                }
            }
            return decodeStatus(@bitCast(status));
        }

        /// How the program ended, without waiting; null while it runs.
        fn poll(pid: posix.pid_t) ?Exit {
            var status: i32 = 0;
            const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
            if (!ok(rc) or rc == 0) return null;
            return decodeStatus(@bitCast(status));
        }

        fn kill(pid: posix.pid_t, signal: posix.SIG) c_int {
            return if (ok(linux.kill(pid, signal))) 0 else -1;
        }

        fn isExecutable(path: [*:0]const u8) bool {
            return ok(linux.access(path, linux.X_OK));
        }
    },
    .macos, .freebsd, .netbsd, .openbsd => struct {
        const c = std.c;
        extern "c" fn posix_openpt(flags: c_int) c_int;
        extern "c" fn grantpt(fd: c_int) c_int;
        extern "c" fn unlockpt(fd: c_int) c_int;
        extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
        extern "c" fn fork() c_int;
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
        extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
        extern "c" fn close(fd: c_int) c_int;

        fn openMaster() ?posix.fd_t {
            const fd = posix_openpt(@bitCast(c.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
            if (fd < 0) return null;
            if (grantpt(fd) != 0 or unlockpt(fd) != 0) {
                _ = close(fd);
                return null;
            }
            _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
            return fd;
        }

        fn slaveName(master: posix.fd_t, buffer: *[64]u8) ?[*:0]const u8 {
            const name = ptsname(master) orelse return null;
            const text = std.mem.span(name);
            if (text.len >= buffer.len) return null;
            @memcpy(buffer[0..text.len], text);
            buffer[text.len] = 0;
            return buffer[0..text.len :0].ptr;
        }

        fn openSlave(path: [*:0]const u8) posix.fd_t {
            return c.open(path, .{ .ACCMODE = .RDWR });
        }

        fn pipeCloexec(fds: *[2]posix.fd_t) bool {
            if (c.pipe(fds) != 0) return false;
            for (fds) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
            return true;
        }

        fn setsid() void {
            _ = c.setsid();
        }

        fn dup2(from: posix.fd_t, to: posix.fd_t) void {
            _ = c.dup2(from, to);
        }

        fn chdir(path: [*:0]const u8) c_int {
            return c.chdir(path);
        }

        fn execve(
            path: [*:0]const u8,
            argv: [*:null]const ?[*:0]const u8,
            envp: [*:null]const ?[*:0]const u8,
        ) void {
            _ = c.execve(path, argv, envp);
        }

        fn fail(report: posix.fd_t) noreturn {
            const byte = [1]u8{1};
            _ = c.write(report, &byte, 1);
            c._exit(127);
        }

        fn readAll(fd: posix.fd_t, buffer: []u8) usize {
            const n = c.read(fd, buffer.ptr, buffer.len);
            return if (n > 0) @intCast(n) else 0;
        }

        fn waitpid(pid: posix.pid_t) error{WaitFailed}!Exit {
            var status: c_int = 0;
            while (true) {
                const rc = c.waitpid(pid, &status, 0);
                if (rc >= 0) break;
                if (posix.errno(rc) != .INTR) return error.WaitFailed;
            }
            return decodeStatus(@bitCast(status));
        }

        /// How the program ended, without waiting; null while it runs.
        fn poll(pid: posix.pid_t) ?Exit {
            var status: c_int = 0;
            if (c.waitpid(pid, &status, c.W.NOHANG) <= 0) return null;
            return decodeStatus(@bitCast(status));
        }

        fn kill(pid: posix.pid_t, signal: posix.SIG) c_int {
            return c.kill(pid, signal);
        }

        fn isExecutable(path: [*:0]const u8) bool {
            return access(path, 1) == 0;
        }
    },
    else => struct {},
};

/// A `wait` status: the exit code, or the signal that ended the process.
fn decodeStatus(status: u32) Exit {
    const signal = status & 0x7f;
    if (signal == 0) return .{ .exited = @truncate(status >> 8) };
    return .{ .signaled = @truncate(signal) };
}

// Windows: a pseudo console, with pipes for its input and output.

const win = struct {
    const HANDLE = *anyopaque;
    const BOOL = i32;
    const infinite: u32 = 0xffffffff;

    const Coord = extern struct { x: i16, y: i16 };

    const StartupInfo = extern struct {
        cb: u32,
        reserved: ?[*:0]u16 = null,
        desktop: ?[*:0]u16 = null,
        title: ?[*:0]u16 = null,
        x: u32 = 0,
        y: u32 = 0,
        x_size: u32 = 0,
        y_size: u32 = 0,
        x_count_chars: u32 = 0,
        y_count_chars: u32 = 0,
        fill_attribute: u32 = 0,
        flags: u32 = 0,
        show_window: u16 = 0,
        reserved2_len: u16 = 0,
        reserved2: ?*u8 = null,
        std_input: ?HANDLE = null,
        std_output: ?HANDLE = null,
        std_error: ?HANDLE = null,
    };

    const StartupInfoEx = extern struct {
        info: StartupInfo,
        attributes: ?*anyopaque,
    };

    const ProcessInformation = extern struct {
        process: HANDLE,
        thread: HANDLE,
        process_id: u32,
        thread_id: u32,
    };

    const extended_startupinfo_present = 0x00080000;
    const create_unicode_environment = 0x00000400;
    const proc_thread_attribute_pseudoconsole = 0x00020016;
    const startf_usestdhandles = 0x00000100;

    extern "kernel32" fn CreatePipe(
        read: *HANDLE,
        write: *HANDLE,
        attributes: ?*anyopaque,
        size: u32,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePseudoConsole(
        size: Coord,
        input: HANDLE,
        output: HANDLE,
        flags: u32,
        console: *HANDLE,
    ) callconv(.winapi) i32;
    extern "kernel32" fn ResizePseudoConsole(console: HANDLE, size: Coord) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(console: HANDLE) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(
        list: ?*anyopaque,
        count: u32,
        flags: u32,
        size: *usize,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(
        list: *anyopaque,
        flags: u32,
        attribute: usize,
        value: ?*anyopaque,
        size: usize,
        previous: ?*anyopaque,
        returned: ?*usize,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(
        application: ?[*:0]const u16,
        command_line: ?[*:0]u16,
        process_attributes: ?*anyopaque,
        thread_attributes: ?*anyopaque,
        inherit_handles: BOOL,
        flags: u32,
        environment: ?*anyopaque,
        directory: ?[*:0]const u16,
        startup: *StartupInfo,
        information: *ProcessInformation,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(
        handle: HANDLE,
        milliseconds: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
};

fn spawnWindows(io: Io, gpa: Allocator, options: SpawnOptions) SpawnError!Pty {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var input_read: win.HANDLE = undefined;
    var input_write: win.HANDLE = undefined;
    var output_read: win.HANDLE = undefined;
    var output_write: win.HANDLE = undefined;
    if (win.CreatePipe(&input_read, &input_write, null, 0) == 0) return error.PtyUnavailable;
    if (win.CreatePipe(&output_read, &output_write, null, 0) == 0) return error.PtyUnavailable;
    var console: win.HANDLE = undefined;
    const size: win.Coord = .{
        .x = @intCast(options.size.width),
        .y = @intCast(options.size.height),
    };
    if (win.CreatePseudoConsole(size, input_read, output_write, 0, &console) < 0) {
        return error.PtyUnavailable;
    }
    // The pseudo console holds its own references to its ends of the pipes.
    _ = win.CloseHandle(input_read);
    _ = win.CloseHandle(output_write);
    errdefer win.ClosePseudoConsole(console);

    var list_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &list_size);
    const list = try arena.alignedAlloc(u8, .of(usize), list_size);
    if (win.InitializeProcThreadAttributeList(list.ptr, 1, 0, &list_size) == 0) {
        return error.PtyUnavailable;
    }
    defer win.DeleteProcThreadAttributeList(list.ptr);
    if (win.UpdateProcThreadAttribute(
        list.ptr,
        0,
        win.proc_thread_attribute_pseudoconsole,
        console,
        @sizeOf(win.HANDLE),
        null,
        null,
    ) == 0) return error.PtyUnavailable;

    const command_line = try commandLine(arena, options.argv);
    const environment = try environmentBlock(arena, options.environ);
    const directory: ?[*:0]const u16 = if (options.cwd) |dir|
        std.unicode.wtf8ToWtf16LeAllocZ(arena, dir) catch return error.SpawnFailed
    else
        null;
    var startup: win.StartupInfoEx = .{
        // Null standard handles, so the program gets the pseudo console's rather than
        // inheriting this process's.
        .info = .{ .cb = @sizeOf(win.StartupInfoEx), .flags = win.startf_usestdhandles },
        .attributes = list.ptr,
    };
    var info: win.ProcessInformation = undefined;
    if (win.CreateProcessW(
        null,
        command_line,
        null,
        null,
        0,
        win.extended_startupinfo_present | win.create_unicode_environment,
        environment.ptr,
        directory,
        &startup.info,
        &info,
    ) == 0) return error.SpawnFailed;
    _ = win.CloseHandle(info.thread);
    const closer = std.Thread.spawn(.{}, closeWhenDone, .{ info.process, console }) catch {
        _ = win.TerminateProcess(info.process, 1);
        _ = win.WaitForSingleObject(info.process, win.infinite);
        _ = win.CloseHandle(info.process);
        return error.SpawnFailed;
    };
    return .{
        .io = io,
        .output = .{ .handle = output_read, .flags = .{ .nonblocking = false } },
        .input = .{ .handle = input_write, .flags = .{ .nonblocking = false } },
        .process = .{ .handle = info.process, .console = console, .closer = closer },
    };
}

/// Closes the pseudo console when `process` ends, so that reads of its output return 0
/// once the last of it is read, as they do on POSIX when the program exits. Closing
/// waits for the output to be read (before Windows 11 24H2).
fn closeWhenDone(process: win.HANDLE, console: win.HANDLE) void {
    _ = win.WaitForSingleObject(process, win.infinite);
    win.ClosePseudoConsole(console);
}

/// `argv` as one Windows command line: each argument quoted as `CommandLineToArgvW` reads
/// it back (backslashes doubled before a quote).
fn commandLine(arena: Allocator, argv: []const []const u8) SpawnError![*:0]u16 {
    var line: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try line.append(arena, ' ');
        const plain = arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null;
        if (plain) {
            try line.appendSlice(arena, arg);
            continue;
        }
        try line.append(arena, '"');
        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
                continue;
            }
            const doubled = if (c == '"') backslashes * 2 + 1 else backslashes;
            try line.appendNTimes(arena, '\\', doubled);
            backslashes = 0;
            try line.append(arena, c);
        }
        try line.appendNTimes(arena, '\\', backslashes * 2);
        try line.append(arena, '"');
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, line.items) catch error.SpawnFailed;
}

/// The environment as `CreateProcessW` takes it: `KEY=VALUE` strings in UTF-16, each
/// ended by a zero, and one more zero at the end.
fn environmentBlock(arena: Allocator, environ: *const std.process.Environ.Map) SpawnError![]u16 {
    var block: std.ArrayList(u16) = .empty;
    var it = environ.iterator();
    while (it.next()) |entry| {
        const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{
            entry.key_ptr.*,
            entry.value_ptr.*,
        });
        const wide = std.unicode.wtf8ToWtf16LeAlloc(arena, pair) catch return error.SpawnFailed;
        try block.appendSlice(arena, wide);
        try block.append(arena, 0);
    }
    if (block.items.len == 0) try block.append(arena, 0);
    try block.append(arena, 0);
    return block.items;
}

const testing = std.testing;

test commandLine {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const line = try commandLine(arena.allocator(), &.{ "app", "two words", "q\"uote", "end\\" });
    const text = try std.unicode.wtf16LeToWtf8Alloc(arena.allocator(), std.mem.span(line));
    try testing.expectEqualStrings("app \"two words\" \"q\\\"uote\" end\\", text);
}

test decodeStatus {
    try testing.expectEqual(Exit{ .exited = 3 }, decodeStatus(3 << 8));
    try testing.expectEqual(Exit{ .signaled = 9 }, decodeStatus(9));
    try testing.expectEqual(137, (Exit{ .signaled = 9 }).status());
}

test "a program on a pty sees a terminal, its size, and its input" {
    if (native_os != .linux and !native_os.isDarwin()) return error.SkipZigTest;
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("TERM", "xterm-256color");
    var pty = spawn(testing.io, testing.allocator, .{
        .argv = &.{ "sh", "-c", "stty size; [ -t 0 ] && echo tty; read line; echo got $line" },
        .environ = &environ,
        .size = .{ .width = 33, .height = 7 },
    }) catch |err| switch (err) {
        error.PtyUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer pty.deinit();
    try pty.write("hello\r");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    var buffer: [256]u8 = undefined;
    while (true) {
        const n = try pty.read(&buffer);
        if (n == 0) break;
        try output.appendSlice(testing.allocator, buffer[0..n]);
    }
    const exit = try pty.wait();
    try testing.expectEqual(0, exit.status());
    const text = output.items;
    try testing.expect(std.mem.indexOf(u8, text, "7 33") != null);
    try testing.expect(std.mem.indexOf(u8, text, "tty") != null);
    try testing.expect(std.mem.indexOf(u8, text, "got hello") != null);
}

test "a program on a pseudo console sees its size and its input, on Windows" {
    if (native_os != .windows) return error.SkipZigTest;
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    for ([_][]const u8{ "SystemRoot", "PATH", "PATHEXT" }) |name| {
        const value = testing.environ.getAlloc(testing.allocator, name) catch continue;
        defer testing.allocator.free(value);
        try environ.put(name, value);
    }
    var pty = try spawn(testing.io, testing.allocator, .{
        .argv = &.{ "cmd.exe", "/v:on", "/c", "mode con & set /p line=& echo got !line!" },
        .environ = &environ,
        .size = .{ .width = 33, .height = 7 },
    });
    defer pty.deinit();
    try pty.write("hello\r");
    // The output ends when the program does, as on POSIX.
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    var buffer: [256]u8 = undefined;
    while (true) {
        const n = try pty.read(&buffer);
        if (n == 0) break;
        try output.appendSlice(testing.allocator, buffer[0..n]);
    }
    const exit = try pty.wait();
    try testing.expectEqual(0, exit.status());
    const text = output.items;
    try testing.expect(std.mem.indexOf(u8, text, "33") != null); // `mode con`: Columns
    try testing.expect(std.mem.indexOf(u8, text, "got hello") != null);
}

test "a program that does not exist fails to spawn" {
    if (native_os != .linux and !native_os.isDarwin() and native_os != .windows)
        return error.SkipZigTest;
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PATH", "/nonexistent");
    try testing.expectError(error.SpawnFailed, spawn(testing.io, testing.allocator, .{
        .argv = &.{"no-such-program"},
        .environ = &environ,
    }));
}

test "deinit kills a program that ignores SIGHUP, with its children" {
    if (native_os != .linux and !native_os.isDarwin()) return error.SkipZigTest;
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    var pty = spawn(testing.io, testing.allocator, .{
        .argv = &.{ "sh", "-c", "trap '' HUP; echo ready; while :; do sleep 1; done" },
        .environ = &environ,
    }) catch |err| switch (err) {
        error.PtyUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer pty.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    var buffer: [256]u8 = undefined;
    while (std.mem.indexOf(u8, output.items, "ready") == null) {
        const n = try pty.read(&buffer);
        if (n == 0) return error.TestUnexpectedResult;
        try output.appendSlice(testing.allocator, buffer[0..n]);
    }
    pty.kill();
    pty.escalate();
    const exit = try pty.wait();
    try testing.expectEqual(Exit{ .signaled = @backingInt(posix.SIG.KILL) }, exit);
}
