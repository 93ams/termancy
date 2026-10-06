//! Detaching the current program so it outlives the terminal that started it.
//!
//! ## Why this is re-exec and not `fork`
//!
//! `[measured]` `std.posix` in this Zig has **no `fork`, `setsid` or `chdir`**.
//! The classic daemon recipe - `fork`, `setsid`, `fork` again, redirect stdio - is
//! therefore not available, and reaching for it would be the wrong answer even if
//! it were:
//!
//!   * `fork` in a process that holds this framework's allocators, its `std.Io`
//!     handle and possibly threads duplicates all of that state, and the child may
//!     only call async-signal-safe functions until it `exec`s. Any allocation
//!     between the `fork` and the `exec` is a latent deadlock.
//!   * The two-`fork` dance exists to prevent the daemon from reacquiring a
//!     controlling terminal. A fresh `exec` never had one, so the problem does not
//!     arise.
//!
//! So detachment is **two halves that cooperate**, which is also how every real
//! service manager works:
//!
//! 1. The parent calls `spawn`, which starts a copy of the program with all three
//!    standard streams pointed at nothing, and returns without waiting.
//! 2. The child calls `becomeSessionLeader` early in its `main`, which on POSIX
//!    makes it the leader of a session with no controlling terminal.
//!
//! ```zig
//! // In main, before anything else touches the terminal:
//! if (args.daemon) try cli.detach.becomeSessionLeader();
//! ```
//!
//! and to start it:
//!
//! ```zig
//! const child = try cli.detach.spawn(io, .{ .argv = &.{ "cfg", "serve", "--daemon" } });
//! try pid_file.write(child.pid);
//! ```
//!
//! ## `chdir` is deliberately not done
//!
//! The recipe says `chdir("/")` so the daemon does not pin a filesystem. That is
//! right for a service and wrong for a CLI: a program started as `cfg --daemon` in
//! a directory expects its relative config paths to keep resolving there. `Options`
//! exposes `cwd` so a caller that wants `/` can ask for it, and the default keeps
//! what the user typed.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Error = error{
    /// The child could not be started. The underlying reason is not distinguished:
    /// a caller wanting to report one should use `std.process.spawn` directly.
    SpawnFailed,
    /// `becomeSessionLeader` was called by the leader of a session that already
    /// exists.
    AlreadySessionLeader,
    /// No way to detach this platform's session, as distinct from the operation
    /// failing.
    UnsupportedPlatform,
    OutOfMemory,
};

pub const Options = struct {
    /// The child's arguments, **including `argv[0]`**. A bare program name is
    /// resolved against `PATH`, which is what makes the common `spawn(.{ .argv =
    /// &.{ "myapp", "--daemon" } })` work without knowing where `myapp` lives.
    argv: []const []const u8,
    /// Where the child runs. `.inherit` keeps the parent's directory, which is what
    /// a relative config path in the child depends on. See the module comment for
    /// why `/` is not forced.
    cwd: std.process.Child.Cwd = .inherit,
    /// Replaces the child's environment when set. Passing the parent's is the
    /// caller's decision rather than this module's, because a daemon's environment
    /// is part of its contract with the service manager that started it.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// A started child. Deliberately just the pid: nothing here can wait for it, which
/// is the entire point.
pub const Child = struct {
    pid: u32,
};

/// Starts a detached copy of the program and returns without waiting for it.
///
/// All three standard streams are set to **`.ignore`**, so the child cannot hold
/// the parent's terminal open and a caller redirecting the parent's output does not
/// stall on a child that never exits. `.ignore` rather than `.pipe` because a pipe
/// nobody reads fills and blocks the writer - which would turn a detached daemon
/// into a hung one on its first log line.
pub fn spawn(io: std.Io, options: Options) Error!Child {
    assert(options.argv.len >= 1);
    assert(options.argv[0].len > 0);

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Windows-only, and ignored elsewhere. It is what stops the child from
        // attaching to the parent's console, and so what stops a Ctrl+C aimed at
        // the terminal from reaching it.
        .create_no_window = true,
    }) catch return error.SpawnFailed;

    return .{ .pid = try processIdOf(&child) };
}

/// The child's process id, releasing whatever handle was needed to learn it.
fn processIdOf(child: *std.process.Child) Error!u32 {
    const id = child.id orelse return error.SpawnFailed;

    if (comptime builtin.os.tag == .windows) {
        const win = std.os.windows;
        const kernel32 = struct {
            extern "kernel32" fn GetProcessId(handle: win.HANDLE) callconv(.winapi) win.DWORD;
            extern "kernel32" fn CloseHandle(handle: win.HANDLE) callconv(.winapi) win.BOOL;
        };
        const pid = kernel32.GetProcessId(id);
        // The handle is the parent's and the child keeps running without it.
        // Leaving it open would leak one handle per detached child.
        _ = kernel32.CloseHandle(id);
        if (pid == 0) return error.SpawnFailed;
        return pid;
    }

    return @intCast(id);
}

/// Makes the calling process the leader of a new session with no controlling
/// terminal. Call this **early** in the child, before it opens or writes anything
/// that assumes a terminal.
///
/// A no-op on Windows, where `create_no_window` at spawn time already gave the
/// child a console of its own and there is no session to lead.
pub fn becomeSessionLeader() Error!void {
    if (comptime builtin.os.tag == .windows) return;

    // Linux without libc has the syscall wrapper; the check comes first because
    // `std.c` is only meaningful when a libc is actually linked.
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.setsid();
        // The Linux wrapper returns `usize`, so an error comes back as a very large
        // value. The signed reinterpretation is the errno.
        if (@as(isize, @bitCast(rc)) < 0) return error.AlreadySessionLeader;
        return;
    }

    if (comptime builtin.link_libc) {
        if (std.c.setsid() < 0) return error.AlreadySessionLeader;
        return;
    }

    // Some other POSIX target with no libc and no wrapper. Reported rather than
    // silently continuing, because a daemon that believes it detached but did not
    // will die with the terminal it was started from - intermittently, and only on
    // one platform.
    return error.UnsupportedPlatform;
}

const testing = std.testing;

test "spawning a detached child reports its pid without waiting for it" {
    // `zig` is guaranteed present: the build running this test ships with it.
    const child = try spawn(testing.io, .{ .argv = &.{ "zig", "version" } });
    try testing.expect(child.pid > 0);

    // Nothing here waits. On POSIX the child may briefly outlive this test as a
    // zombie until the test process exits - which is exactly the behaviour a
    // detached child is supposed to have, so it is not asserted away.
}

test "a program that does not exist is SpawnFailed, not a pid of zero" {
    try testing.expectError(error.SpawnFailed, spawn(testing.io, .{
        .argv = &.{"snek-no-such-daemon-exists-anywhere"},
    }));
}

test "becoming a session leader is callable on every platform" {
    // This runs for real on POSIX, which means the test process leads a new session
    // with no controlling terminal for the rest of the run. That is a genuine side
    // effect and it is accepted deliberately: the alternative is not calling the
    // function, and then the platform branch this module exists to get right is
    // never analysed. Nothing else in this suite requires a terminal - the one
    // caller that reads termios treats the failure as "not a terminal" - so the
    // blast radius is the assertion below.
    //
    // On Windows this is a documented no-op. On POSIX, a process that is already a
    // session leader gets `AlreadySessionLeader`, which is a success for the
    // purposes of this test: what is being asserted is that neither branch panics.
    becomeSessionLeader() catch |err| switch (err) {
        error.AlreadySessionLeader, error.UnsupportedPlatform => return,
        else => return err,
    };
}
