//! Background processes: PID files, daemonizing on POSIX, and starting a detached child on
//! every OS.
//!
//! - `PidFile` is a `files.Lock`: created exclusively with the PID inside, broken when
//!   the PID it names is dead, removed on release. `isRunning` answers "is the daemon up?".
//! - `daemonize` is the POSIX recipe: `fork`, `setsid` in the child (a new session with
//!   no controlling terminal), standard streams redirected to `/dev/null`. The parent
//!   learns the daemon's PID and usually exits. Call it before starting threads: only the
//!   calling thread survives a `fork`, so locks held elsewhere stay held forever in the
//!   child. A single fork is done; a daemon that opens a terminal device should pass
//!   `O_NOCTTY`.
//! - `detach` starts another program (often this executable, see `exe.path`) in the
//!   background with its streams discarded. POSIX: a new process group, so terminal
//!   signals aimed at the parent's group miss it. Windows: `CreateProcessW` with
//!   `DETACHED_PROCESS` (no console) and `CREATE_NEW_PROCESS_GROUP` (no Ctrl-C from the
//!   parent's console). Windows has no `fork`, so this is its way to daemonize.
//! - `SystemdUnit` writes a complete systemd service unit; `writeSystemdQuoted` and
//!   `writeSystemdEnvironment` write single values with systemd's quoting rules.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = @import("files.zig");
const process = @import("process.zig");

const native = builtin.os.tag;
const is_windows = native == .windows;
const has_fork = !is_windows and native != .wasi and native != .freestanding;

/// A process ID.
pub const Pid = process.Pid;

/// A PID file: a lock file holding the daemon's PID. See `files.Lock`.
pub const PidFile = files.Lock;

/// Whether a process with ID `pid` exists. See `process.isAlive`.
pub const isAlive = process.isAlive;

/// Whether the PID file at `sub_path` names a running process. A missing or unreadable
/// file means "not running".
pub fn isRunning(io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.ReadFileError!bool {
    const pid = (try PidFile.owner(io, dir, sub_path)) orelse return false;
    return process.isAlive(pid);
}

/// Which side of `daemonize` the caller is on.
pub const Role = union(enum) {
    /// The original process; the payload is the daemon's PID.
    parent: Pid,
    /// The daemon.
    daemon,
};

/// Options for `daemonize`.
pub const DaemonizeOptions = struct {
    /// Points standard input, output, and error at `/dev/null`.
    redirect_stdio: bool = true,
    /// Changes to `/` so the daemon does not keep a mounted file system busy.
    chdir_root: bool = false,
};

/// Errors from `daemonize`.
pub const DaemonizeError = error{
    /// The OS has no `fork` (Windows, WASI). Use `detach`.
    OperationUnsupported,
    /// The process limit was reached or memory ran out.
    SystemResources,
    /// The daemon could not set itself up; it reports this from its own side.
    Unexpected,
};

/// Forks a daemon. Returns `.parent` with the daemon's PID in the original process and
/// `.daemon` in the new one, which leads a new session with no controlling terminal.
pub fn daemonize(options: DaemonizeOptions) DaemonizeError!Role {
    if (comptime !has_fork) return error.OperationUnsupported;
    const system = std.posix.system;
    const rc = system.fork();
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    if (rc != 0) return .{ .parent = @intCast(rc) };
    // The child of a fork is never a process-group leader, so `setsid` cannot fail.
    assert(std.posix.errno(system.setsid()) == .SUCCESS);
    if (options.chdir_root and std.posix.errno(system.chdir("/")) != .SUCCESS) {
        return error.Unexpected;
    }
    if (options.redirect_stdio) try redirectToNull();
    return .daemon;
}

fn redirectToNull() error{Unexpected}!void {
    const posix = std.posix;
    const fd = posix.openat(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0) catch
        return error.Unexpected;
    for ([_]posix.fd_t{ 0, 1, 2 }) |target| {
        if (posix.errno(posix.system.dup2(fd, target)) != .SUCCESS) return error.Unexpected;
    }
    if (fd > 2) _ = posix.system.close(fd);
}

/// Options for `detach`.
pub const DetachOptions = struct {
    /// The child's working directory; `null` inherits the parent's.
    cwd: ?[]const u8 = null,
    /// Replaces the child's environment.
    environ: ?*const std.process.Environ.Map = null,
};

/// Errors from `detach`.
pub const DetachError = std.process.SpawnError || error{InvalidArg0};

/// Starts `argv` in the background with its standard streams discarded and returns its
/// PID without waiting. On POSIX the child stays this process's child until this process
/// exits (a parent that keeps running should reap it); on Windows its handles are closed
/// at once. `argv[0]` is resolved with the parent's `PATH`.
pub fn detach(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    options: DetachOptions,
) DetachError!Pid {
    assert(argv.len > 0);
    if (comptime is_windows) return detachWindows(gpa, argv, options);
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (options.cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = options.environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    return @intCast(child.id.?);
}

fn detachWindows(gpa: Allocator, argv: []const []const u8, options: DetachOptions) DetachError!Pid {
    const windows = std.os.windows;
    const line = try windowsCommandLine(gpa, argv);
    defer gpa.free(line);
    const line_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, line);
    defer gpa.free(line_w);
    const cwd_w = if (options.cwd) |dir| try std.unicode.wtf8ToWtf16LeAllocZ(gpa, dir) else null;
    defer if (cwd_w) |w| gpa.free(w);
    const block = if (options.environ) |map| try map.createWindowsBlock(gpa, .{}) else null;
    defer if (block) |b| b.deinit(gpa);

    var startup = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    var info: windows.PROCESS.INFORMATION = undefined;
    const ok = windows.kernel32.CreateProcessW(null, line_w.ptr, null, null, .FALSE, .{
        .detached_process = true,
        .create_new_process_group = true,
        .create_unicode_environment = true,
    }, if (block) |b| b.slice.ptr else null, if (cwd_w) |w| w.ptr else null, &startup, &info);
    if (!ok.toBool()) return switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .NOT_ENOUGH_MEMORY => error.SystemResources,
        else => error.Unexpected,
    };
    windows.CloseHandle(info.hThread);
    windows.CloseHandle(info.hProcess);
    return info.dwProcessId;
}

/// Serializes `argv` into one Windows command line that `CommandLineToArgvW` (and the
/// Microsoft C runtime) splits back into the same arguments. `argv[0]` is quoted without
/// escapes, as Windows parses it, so it must not contain `"`. Caller owns the result.
/// Not for `.bat`/`.cmd` files, whose arguments `cmd.exe` re-parses.
pub fn windowsCommandLine(
    gpa: Allocator,
    argv: []const []const u8,
) error{ OutOfMemory, InvalidArg0 }![]u8 {
    assert(argv.len > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const first = argv[0];
    if (std.mem.indexOfScalar(u8, first, '"') != null) return error.InvalidArg0;
    if (needsQuotes(first)) {
        try out.print(gpa, "\"{s}\"", .{first});
    } else {
        try out.appendSlice(gpa, first);
    }
    for (argv[1..]) |arg| {
        try out.append(gpa, ' ');
        try appendQuoted(gpa, &out, arg);
    }
    return out.toOwnedSlice(gpa);
}

fn needsQuotes(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| if (c <= ' ' or c == '"') return true;
    return false;
}

/// Backslashes are literal unless they precede a `"`, where each one must be doubled.
fn appendQuoted(gpa: Allocator, out: *std.ArrayList(u8), arg: []const u8) Allocator.Error!void {
    if (!needsQuotes(arg)) return out.appendSlice(gpa, arg);
    try out.append(gpa, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        const count = if (c == '"') backslashes * 2 + 1 else backslashes;
        try out.appendNTimes(gpa, '\\', count);
        try out.append(gpa, c);
        backslashes = 0;
    }
    try out.appendNTimes(gpa, '\\', backslashes * 2);
    try out.append(gpa, '"');
}

/// A systemd service unit: `[Unit]`, `[Service]`, `[Install]`. Fill the fields and `write`.
pub const SystemdUnit = struct {
    /// `Description=`, one line.
    description: []const u8,
    /// `After=` units, such as `network-online.target`; none writes no line.
    after: []const []const u8 = &.{},
    /// `ExecStart=`: the program, as an absolute path, and its arguments, each quoted as
    /// needed (see `writeSystemdArg`).
    exec_start: []const []const u8,
    restart: Restart = .on_failure,
    /// `Environment=` lines, in order.
    environment: []const EnvVar = &.{},
    working_directory: ?[]const u8 = null,
    /// `User=`; null runs as root for a system unit, as the user for a user unit.
    user: ?[]const u8 = null,
    /// `WantedBy=`: `multi-user.target` for a system unit, `default.target` for a user one.
    wanted_by: []const u8 = "multi-user.target",

    /// `Restart=` values.
    pub const Restart = enum {
        no,
        always,
        on_success,
        on_failure,
        on_abnormal,
        on_abort,
        on_watchdog,
    };

    /// One `Environment=` variable.
    pub const EnvVar = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Writes the unit file. Single-line values (`Description=`, `User=`, ...) have `%`
    /// doubled and control characters replaced by spaces, so no value can add a line.
    pub fn write(unit: SystemdUnit, w: *Io.Writer) Io.Writer.Error!void {
        assert(unit.exec_start.len > 0);
        try w.writeAll("[Unit]\nDescription=");
        try writeSystemdLine(w, unit.description);
        try w.writeByte('\n');
        if (unit.after.len > 0) {
            try w.writeAll("After=");
            for (unit.after, 0..) |name, i| {
                if (i > 0) try w.writeByte(' ');
                try writeSystemdLine(w, name);
            }
            try w.writeByte('\n');
        }
        try w.writeAll("\n[Service]\nExecStart=");
        for (unit.exec_start, 0..) |arg, i| {
            if (i > 0) try w.writeByte(' ');
            try writeSystemdArg(w, arg);
        }
        try w.writeAll("\nRestart=");
        for (@tagName(unit.restart)) |c| try w.writeByte(if (c == '_') '-' else c);
        try w.writeByte('\n');
        for (unit.environment) |variable| {
            try writeSystemdEnvironment(w, variable.name, variable.value);
        }
        if (unit.working_directory) |dir| {
            try w.writeAll("WorkingDirectory=");
            try writeSystemdLine(w, dir);
            try w.writeByte('\n');
        }
        if (unit.user) |user| {
            try w.writeAll("User=");
            try writeSystemdLine(w, user);
            try w.writeByte('\n');
        }
        try w.writeAll("\n[Install]\nWantedBy=");
        try writeSystemdLine(w, unit.wanted_by);
        try w.writeByte('\n');
    }
};

/// Writes `Environment="NAME=value"` and a newline, quoted by `writeSystemdQuoted`.
pub fn writeSystemdEnvironment(
    w: *Io.Writer,
    name: []const u8,
    value: []const u8,
) Io.Writer.Error!void {
    try w.writeAll("Environment=\"");
    try writeSystemdEscaped(w, name, false);
    try w.writeByte('=');
    try writeSystemdEscaped(w, value, false);
    try w.writeAll("\"\n");
}

/// Writes `text` as a double-quoted unit-file string: `"` and `\` escaped, `%` doubled
/// (unit files expand `%` specifiers even inside quotes), and control characters as C
/// escapes, which systemd decodes inside quotes.
pub fn writeSystemdQuoted(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    try writeSystemdEscaped(w, text, false);
    try w.writeByte('"');
}

/// Writes one `ExecStart=` word: bare when it is made only of letters, digits, and
/// `/._+-=:,@`, else quoted as `writeSystemdQuoted` does, with `$` also doubled so systemd
/// does not substitute a variable. systemd reads a leading `@-:+!` of the first word (the
/// program) as a prefix even when quoted, so that one should be an absolute path.
pub fn writeSystemdArg(w: *Io.Writer, arg: []const u8) Io.Writer.Error!void {
    const bare = arg.len > 0 and for (arg) |c| {
        if (!std.ascii.isAlphanumeric(c) and
            std.mem.indexOfScalar(u8, "/._+-=:,@", c) == null) break false;
    } else true;
    if (bare) return w.writeAll(arg);
    try w.writeByte('"');
    try writeSystemdEscaped(w, arg, true);
    try w.writeByte('"');
}

fn writeSystemdEscaped(w: *Io.Writer, text: []const u8, dollar: bool) Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        '%' => try w.writeAll("%%"),
        '$' => try w.writeAll(if (dollar) "$$" else "$"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
}

/// An unquoted value that must stay on its line.
fn writeSystemdLine(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '%' => try w.writeAll("%%"),
        0...0x1f, 0x7f => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
}

const testing = std.testing;

test "windowsCommandLine quotes like CommandLineToArgvW expects" {
    const cases = [_]struct { argv: []const []const u8, line: []const u8 }{
        .{ .argv = &.{"app"}, .line = "app" },
        .{ .argv = &.{ "C:\\Program Files\\app.exe", "a b", "" }, .line =
        \\"C:\Program Files\app.exe" "a b" ""
        },
        .{ .argv = &.{ "app", "say \"hi\"", "C:\\dir\\", "x\\y" }, .line =
        \\app "say \"hi\"" C:\dir\ x\y
        },
        .{ .argv = &.{ "app", "end\\ ", "q\\\"" }, .line =
        \\app "end\ " "q\\\""
        },
        .{ .argv = &.{ "app", "trail \\" }, .line =
        \\app "trail \\"
        },
    };
    for (cases) |case| {
        const line = try windowsCommandLine(testing.allocator, case.argv);
        defer testing.allocator.free(line);
        try testing.expectEqualStrings(case.line, line);
    }
    try testing.expectError(error.InvalidArg0, windowsCommandLine(testing.allocator, &.{"a\"b"}));
}

test "isRunning follows the PID file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(!try isRunning(testing.io, tmp.dir, "d.pid"));
    const pid_file = try PidFile.acquire(testing.io, tmp.dir, "d.pid");
    try testing.expect(try isRunning(testing.io, tmp.dir, "d.pid"));
    pid_file.release(testing.io);
    try testing.expect(!try isRunning(testing.io, tmp.dir, "d.pid"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dead.pid", .data = "2000000000" });
    try testing.expect(!try isRunning(testing.io, tmp.dir, "dead.pid"));
}

test "daemonize forks a session leader" {
    if (native != .linux or builtin.link_libc) return error.SkipZigTest;
    const linux = std.os.linux;
    switch (try daemonize(.{ .redirect_stdio = true, .chdir_root = true })) {
        .daemon => {
            // Only async-signal-safe calls in the child of a multi-threaded parent.
            const leader = linux.getsid(0) == linux.getpid();
            linux.exit_group(if (leader) 42 else 1);
        },
        .parent => |pid| {
            var status: i32 = 0;
            const rc = linux.waitpid(@intCast(pid), &status, 0);
            try testing.expectEqual(.SUCCESS, linux.errno(rc));
            try testing.expect(linux.W.IFEXITED(@bitCast(status)));
            try testing.expectEqual(42, linux.W.EXITSTATUS(@bitCast(status)));
        },
    }
}

test "detach starts a background process" {
    if (native != .linux or builtin.link_libc) return error.SkipZigTest;
    const linux = std.os.linux;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buffer);
    const pid = try detach(testing.allocator, testing.io, &.{
        "/bin/sh", "-c", "echo $$ > out",
    }, .{ .cwd = buffer[0..len] });
    try testing.expect(pid > 0);
    // Reap it, which also waits for it to finish.
    var status: i32 = 0;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.waitpid(@intCast(pid), &status, 0)));
    var out: [32]u8 = undefined;
    const text = try tmp.dir.readFile(testing.io, "out", &out);
    try testing.expectEqual(pid, try std.fmt.parseInt(Pid, std.mem.trim(u8, text, "\n"), 10));
}

test "detach starts a background process on Windows" {
    if (!is_windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buffer);
    const pid = try detach(testing.allocator, testing.io, &.{
        "cmd.exe", "/c", "echo detached> out",
    }, .{ .cwd = buffer[0..len] });
    try testing.expect(pid > 0);
    var tries: usize = 0;
    while (isAlive(pid) and tries < 500) : (tries += 1) {
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    var out: [32]u8 = undefined;
    const text = try tmp.dir.readFile(testing.io, "out", &out);
    try testing.expectEqualStrings("detached", std.mem.trimEnd(u8, text, "\r\n "));
}

test "SystemdUnit writes a complete unit" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const unit: SystemdUnit = .{
        .description = "termancy daemon, 100% fine\nInjected=1",
        .after = &.{ "network-online.target", "time-sync.target" },
        .exec_start = &.{ "/usr/bin/termancy", "serve", "--name=a b", "$HOME", "say \"hi\"", "" },
        .restart = .on_abnormal,
        .environment = &.{
            .{ .name = "PORT", .value = "8080" },
            .{ .name = "MOTD", .value = "50% \"off\"\nC:\\x $HOME" },
        },
        .working_directory = "/var/lib/termancy",
        .user = "termancy",
    };
    try unit.write(&w);
    try testing.expectEqualStrings(
        \\[Unit]
        \\Description=termancy daemon, 100%% fine Injected=1
        \\After=network-online.target time-sync.target
        \\
        \\[Service]
        \\ExecStart=/usr/bin/termancy serve "--name=a b" "$$HOME" "say \"hi\"" ""
        \\Restart=on-abnormal
        \\Environment="PORT=8080"
        \\Environment="MOTD=50%% \"off\"\nC:\\x $HOME"
        \\WorkingDirectory=/var/lib/termancy
        \\User=termancy
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , w.buffered());

    w = .fixed(&buffer);
    try (SystemdUnit{
        .description = "minimal",
        .exec_start = &.{ "/opt/x", "-v", "%h" },
        .wanted_by = "default.target",
    }).write(&w);
    try testing.expectEqualStrings(
        \\[Unit]
        \\Description=minimal
        \\
        \\[Service]
        \\ExecStart=/opt/x -v "%%h"
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , w.buffered());
}

test "writeSystemdQuoted and writeSystemdArg" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeSystemdQuoted(&w, "tab\there\x01 $x");
    try w.writeByte(' ');
    try writeSystemdArg(&w, "a;b");
    try w.writeByte(' ');
    try writeSystemdArg(&w, "a-b_c.d/e");
    try testing.expectEqualStrings(
        \\"tab\there\x01 $x" "a;b" a-b_c.d/e
    , w.buffered());
}

test "detach of a missing program fails" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const argv: []const []const u8 = &.{"termancy-no-such-program-anywhere"};
    try testing.expectError(error.FileNotFound, detach(testing.allocator, testing.io, argv, .{}));
}
