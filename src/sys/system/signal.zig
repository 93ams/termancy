//! Interrupt handling: Ctrl-C and termination requests become a flag the program polls.
//!
//! ```zig
//! signal.install();
//! defer signal.uninstall();
//! while (work.next()) |item| {
//!     try signal.check(); // error.Interrupted after Ctrl-C
//!     process(item);
//! }
//! // In main: on error.Interrupted, clean up and return signal.exit_status (130).
//! ```
//!
//! The handler does one thing: an atomic store. Everything else a cleanup wants (freeing,
//! flushing, locking) is unsafe inside a signal handler, so it happens on the normal path
//! once the program looks at the flag. A second Ctrl-C before the program has reacted gets
//! the default action and ends the process at once, so a stuck program can still be
//! stopped: POSIX handlers for interrupt, termination, and quit are installed with
//! `SA_RESETHAND`; the Windows handler declines the second event. A hangup is not a stop
//! request, so a second one never ends the process. `reset` clears the flag and re-arms the
//! handlers.
//!
//! POSIX: `SIGINT` (interrupt) and `SIGTERM` (terminate), via `sigaction`. Windows:
//! `SetConsoleCtrlHandler`; Ctrl-C and Ctrl-Break are an interrupt, closing the console,
//! logging off, and shutting down are a termination. Windows ends the process as soon as the
//! handler of a termination returns, and at the latest after its timeout (5 seconds by
//! default), so the handler waits: until the program calls `uninstall` (after cleaning up)
//! or exits, or until `termination_wait_ms` passes.
//!
//! `installWith` also catches, on POSIX only, `SIGHUP` (hangup: a daemon's "reload your
//! configuration", or a closed terminal) and `SIGQUIT` (quit: Ctrl-\). Both are opt-in;
//! `install` leaves their default actions alone. Windows has neither: its console close
//! event stays a termination, so a hangup is never reported there. A hangup is not a stop
//! request: `interrupted` and `check` ignore it, and an interrupt, termination, or quit
//! that follows replaces it. A reload loop polls `received`, handles `.hangup`, and calls
//! `reset` to clear it and catch the next one:
//!
//! ```zig
//! signal.installWith(.{ .hangup = true });
//! while (true) {
//!     if (signal.received()) |sig| switch (sig) {
//!         .hangup => { try reload(); signal.reset(); },
//!         else => return sig.exitStatus(),
//!     };
//!     try serveOne();
//! }
//! ```
//!
//! ## `std.Io` cancellation
//!
//! In Zig 0.17, cancellation belongs to tasks: `Future.cancel` and `Group.cancel` make the
//! task's next cancellation point return `error.Canceled`. Requesting it goes through the
//! `Io` implementation (locks, wakeups), which is not async-signal-safe, and `std.Io` has
//! no hook that turns a signal into a cancel request. So the bridge is the caller's: run
//! the interruptible work as a task (`io.concurrent`), and from the main task poll
//! `interrupted()` between its own waits and call `future.cancel(io)` when it turns true.
//! A blocking system call is not woken by the flag: `std.Io.Threaded` restarts calls that
//! fail with `EINTR`, so the flag is seen once the call returns.
//!
//! The state is process-global, as signal dispositions are. Call `install` and
//! `uninstall` from one thread, normally `main`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const native = builtin.os.tag;
const is_windows = native == .windows;
const has_sigaction = !is_windows and native != .wasi and native != .freestanding;

/// The exit status for a program stopped by Ctrl-C: 128 + `SIGINT`, as shells report it.
pub const exit_status: u8 = 130;

/// What was requested.
pub const Signal = enum(u8) {
    /// `SIGINT`; Ctrl-C or Ctrl-Break on Windows.
    interrupt = 1,
    /// `SIGTERM`; console close, log-off, or shutdown on Windows.
    terminate = 2,
    /// `SIGHUP`, when selected (POSIX only). Not a stop request.
    hangup = 3,
    /// `SIGQUIT` (Ctrl-\\), when selected (POSIX only).
    quit = 4,

    /// The conventional exit status after this signal: 130, 143, 129, or 131.
    pub fn exitStatus(sig: Signal) u8 {
        return switch (sig) {
            .interrupt => exit_status,
            .terminate => 128 + 15,
            .hangup => 128 + 1,
            .quit => 128 + 3,
        };
    }
};

/// Which signals `installWith` catches. The default is `install`'s set.
pub const Set = struct {
    interrupt: bool = true,
    terminate: bool = true,
    /// POSIX only; ignored on Windows.
    hangup: bool = false,
    /// POSIX only; ignored on Windows.
    quit: bool = false,
};

/// Returned by `check` once a signal has arrived.
pub const Error = error{Interrupted};

/// 0 when nothing arrived, else the `Signal` value. One atomic, so the handler needs no
/// lock and readers see a whole value.
var pending: std.atomic.Value(u8) = .init(0);
/// Read by the Windows handler, which runs on a thread of its own.
var installed: std.atomic.Value(bool) = .init(false);
var selected: Set = .{};
var previous: if (has_sigaction) [posix_signals.len]std.posix.Sigaction else void = undefined;

/// The POSIX signals in `Set` field order.
const posix_signals = if (has_sigaction)
    [_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT }
else
    [_]void{};

fn isSelected(set: Set, index: usize) bool {
    return switch (index) {
        0 => set.interrupt,
        1 => set.terminate,
        2 => set.hangup,
        3 => set.quit,
        else => unreachable,
    };
}

/// Installs the handlers for interrupt and termination. Idempotent; the previous
/// dispositions are kept for `uninstall`. A no-op on targets without signals (WASI,
/// freestanding).
pub fn install() void {
    installWith(.{});
}

/// `install`, catching the signals in `set`. Does nothing when already installed; call
/// `uninstall` first to change the set. On Windows, Ctrl-C and Ctrl-Break follow
/// `interrupt` and the close, log-off, and shutdown events follow `terminate`.
pub fn installWith(set: Set) void {
    if (installed.load(.acquire)) return;
    selected = set;
    if (comptime is_windows) {
        // Fails only for an invalid handler pointer.
        assert(win32.SetConsoleCtrlHandler(&handleConsole, .TRUE).toBool());
    } else if (comptime has_sigaction) {
        arm(&previous);
    }
    installed.store(true, .release);
}

/// Restores the dispositions that `install` replaced. The flag is left as it is.
pub fn uninstall() void {
    if (!installed.load(.acquire)) return;
    if (comptime is_windows) {
        _ = win32.SetConsoleCtrlHandler(&handleConsole, .FALSE);
    } else if (comptime has_sigaction) {
        for (posix_signals, 0..) |sig, i| {
            if (isSelected(selected, i)) std.posix.sigaction(sig, &previous[i], null);
        }
    }
    installed.store(false, .release);
}

/// Whether a stop request (interrupt, termination, or quit; not a hangup) has arrived
/// since the last `reset`.
pub fn interrupted() bool {
    const value = pending.load(.acquire);
    return value != 0 and value != @backingInt(Signal.hangup);
}

/// The first request since the last `reset` (a stop request replaces a hangup), or `null`.
/// Reading does not clear it.
pub fn received() ?Signal {
    const value = pending.load(.acquire);
    if (value == 0) return null;
    return @fromBackingInt(value);
}

/// Returns `error.Interrupted` once a request has arrived. For loops that propagate errors.
pub fn check() Error!void {
    if (interrupted()) return error.Interrupted;
}

/// Clears the flag and, when installed, re-arms the handlers (a POSIX handler resets to
/// the default action after it fires), so the program is interruptible again.
pub fn reset() void {
    pending.store(0, .release);
    if (has_sigaction and installed.load(.acquire)) arm(null);
}

/// Records `sig` unless a request is already recorded: the first one wins, except that a
/// stop request replaces a pending hangup. Safe in a signal handler. Exposed so a program
/// can request its own shutdown (or reload) the same way.
pub fn record(sig: Signal) void {
    const hangup = @backingInt(Signal.hangup);
    var current = pending.load(.acquire);
    while (current == 0 or (current == hangup and sig != .hangup)) {
        current = pending.cmpxchgWeak(current, @backingInt(sig), .acq_rel, .acquire) orelse
            return;
    }
}

fn arm(old: ?*[posix_signals.len]std.posix.Sigaction) void {
    comptime assert(has_sigaction);
    for (posix_signals, 0..) |sig, i| {
        if (!isSelected(selected, i)) continue;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handlePosix },
            .mask = std.posix.sigemptyset(),
            // No `SA_RESTART`: the I/O implementation decides about `EINTR` itself. A
            // hangup keeps its handler: a second one (a reload asked twice) must not kill.
            .flags = if (sig == .HUP) 0 else std.posix.SA.RESETHAND,
        };
        std.posix.sigaction(sig, &action, if (old) |o| &o[i] else null);
    }
}

fn handlePosix(sig: std.posix.SIG) callconv(.c) void {
    record(switch (sig) {
        .TERM => .terminate,
        .HUP => .hangup,
        .QUIT => .quit,
        else => .interrupt,
    });
}

fn handleConsole(event: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    const sig: Signal = switch (event) {
        0, 1 => .interrupt, // CTRL_C_EVENT, CTRL_BREAK_EVENT
        2, 5, 6 => .terminate, // CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT
        else => return .FALSE,
    };
    const wanted = if (sig == .interrupt) selected.interrupt else selected.terminate;
    if (!wanted) return .FALSE;
    // A second event before the program reacted: let the default handler end the process.
    if (interrupted()) return .FALSE;
    record(sig);
    // Windows ends the process once this returns: give the program its cleanup first.
    if (sig == .terminate) awaitCleanup();
    return .TRUE;
}

/// How long the Windows handler of a termination waits for the program to clean up and
/// `uninstall`; Windows itself ends the process after its own timeout (5 seconds by
/// default for a closed console), whichever comes first.
pub const termination_wait_ms = 10_000;

fn awaitCleanup() void {
    var waited: u32 = 0;
    while (installed.load(.acquire) and waited < termination_wait_ms) : (waited += 50) {
        win32.Sleep(50);
    }
}

const win32 = struct {
    const windows = std.os.windows;
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
        add: windows.BOOL,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
};

const testing = std.testing;

test "record keeps the first request; reset clears it" {
    reset();
    defer reset();
    try testing.expect(!interrupted());
    try check();
    record(.terminate);
    record(.interrupt);
    try testing.expectEqual(.terminate, received().?);
    try testing.expectError(error.Interrupted, check());
    reset();
    try testing.expectEqual(null, received());
}

test "exit statuses" {
    try testing.expectEqual(130, exit_status);
    try testing.expectEqual(130, Signal.interrupt.exitStatus());
    try testing.expectEqual(143, Signal.terminate.exitStatus());
    try testing.expectEqual(129, Signal.hangup.exitStatus());
    try testing.expectEqual(131, Signal.quit.exitStatus());
}

test "received does not consume; a hangup is not a stop and yields to one" {
    reset();
    defer reset();
    record(.hangup);
    for (0..3) |_| try testing.expectEqual(.hangup, received().?);
    try testing.expect(!interrupted());
    try check();
    record(.hangup);
    record(.quit);
    try testing.expectEqual(.quit, received().?);
    record(.hangup);
    record(.interrupt);
    for (0..3) |_| try testing.expectEqual(.quit, received().?);
    try testing.expectError(error.Interrupted, check());
}

test "installWith catches SIGHUP and SIGQUIT only when asked" {
    if (!has_sigaction) return error.SkipZigTest;
    reset();
    defer reset();
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.HUP, null, &before);
    install();
    var during: std.posix.Sigaction = undefined;
    std.posix.sigaction(.HUP, null, &during);
    try testing.expectEqual(before.handler.handler, during.handler.handler);
    uninstall();

    installWith(.{ .hangup = true, .quit = true });
    defer uninstall();
    try std.posix.raise(.HUP);
    try testing.expectEqual(.hangup, received().?);
    reset(); // Clears the flag, so the next hangup is reported again.
    try std.posix.raise(.HUP);
    try testing.expectEqual(.hangup, received().?);
    try std.posix.raise(.QUIT);
    try testing.expectEqual(.quit, received().?);
}

test "a second SIGHUP before reset is caught again, not the default action" {
    if (!has_sigaction) return error.SkipZigTest;
    reset();
    defer reset();
    installWith(.{ .hangup = true });
    defer uninstall();
    try std.posix.raise(.HUP);
    // Without `reset`: under `SA_RESETHAND` this one would end the test process.
    try std.posix.raise(.HUP);
    try testing.expectEqual(.hangup, received().?);
}

test "a raised SIGINT sets the flag; reset re-arms for SIGTERM" {
    if (!has_sigaction) return error.SkipZigTest;
    reset();
    install();
    install(); // Idempotent.
    defer uninstall();
    defer reset();
    try std.posix.raise(.INT);
    try testing.expectEqual(.interrupt, received().?);
    reset();
    try std.posix.raise(.TERM);
    try testing.expectEqual(.terminate, received().?);
    reset();
    try std.posix.raise(.INT);
    try testing.expect(interrupted());
}

test "the Windows console handler classifies events and declines a second one" {
    if (!is_windows) return error.SkipZigTest;
    reset();
    defer reset();
    try testing.expect(handleConsole(0).toBool());
    try testing.expectEqual(.interrupt, received().?);
    try testing.expect(!handleConsole(2).toBool());
    reset();
    try testing.expect(handleConsole(2).toBool());
    try testing.expectEqual(.terminate, received().?);
    try testing.expect(!handleConsole(99).toBool());
}

test "uninstall restores the previous disposition" {
    if (!has_sigaction) return error.SkipZigTest;
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &before);
    install();
    uninstall();
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &after);
    try testing.expectEqual(before.handler.handler, after.handler.handler);
}
