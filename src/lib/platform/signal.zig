//! Graceful shutdown for a command-line program.
//!
//! ## Why the handler does not call your cleanup code
//!
//! The obvious design - `onShutdown(cleanup)` - is a data race with a stack
//! trace. A POSIX signal handler runs **on top of** whichever thread the kernel
//! picked, at an arbitrary instruction boundary, and the set of functions that are
//! safe to call there (`async-signal-safe`) excludes essentially everything a
//! cleanup routine wants: `malloc`/`free`, `std.ArrayList`, mutexes, `std.debug.print`,
//! flushing a buffered writer. A handler that calls one of them can deadlock on a
//! lock the interrupted thread already holds - and the deadlock reproduces once,
//! under load, in production.
//!
//! So the handler does exactly one thing: an atomic store. Cleanup runs on the
//! **normal** control flow, once the program chooses to notice:
//!
//! ```zig
//! signal.install();
//! defer cleanup();            // ordinary defer, runs on the normal path
//! while (!signal.received()) |sig| { ... }
//! ```
//!
//! That is why `install` takes no callbacks and this module has no hook registry.
//!
//! ## Placement in the process
//!
//! Installation is explicit and cheap, and `received` is a single atomic load, so
//! a program can poll it in its main loop at whatever granularity it likes. There
//! is no watcher thread and nothing runs on a schedule - the same posture the
//! config suite committed to, for the same reason.
//!
//! ## What is not covered
//!
//! SIGKILL cannot be caught by any program, and SIGSEGV/SIGABRT are crash
//! reporting rather than shutdown; they need a different mechanism because the
//! process state at that point is not trustworthy. See `panic.zig`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const is_windows = builtin.os.tag == .windows;
/// POSIX signal handling needs `sigaction`, which WASI and freestanding do not
/// have. Those targets get a handler that is a no-op rather than a compile error,
/// so a program stays portable without an `if` at every call site.
const has_posix_signals = builtin.os.tag != .windows and
    builtin.os.tag != .wasi and
    builtin.os.tag != .freestanding;

/// The shutdown signals a CLI conventionally cares about.
///
/// A closed enum rather than raw numbers so `received` can be matched on, and so
/// the platform's numbering never leaks into a caller's `switch`.
pub const Signal = enum(u8) {
    /// `SIGINT`, and `CTRL_C_EVENT` on Windows. Ctrl+C.
    interrupt = 1,
    /// `SIGTERM`, and `CTRL_CLOSE_EVENT` on Windows. `kill`, service stop.
    terminate = 2,
    /// `SIGHUP`. Conventionally "reload your configuration"; there is no Windows
    /// equivalent, so it is unreachable there.
    hangup = 3,
    /// `SIGQUIT`. Ctrl+\ on a terminal.
    quit = 4,
    /// A handled signal that is none of the above.
    other = 5,
};

/// Zero means "nothing received"; every real value is `@intFromEnum(Signal) > 0`,
/// so a single atomic can represent the whole state without a second flag.
var pending = std.atomic.Value(u8).init(0);

/// Records `signal` as the shutdown request, if none is recorded yet.
///
/// The **first** signal wins. A program that has already decided to shut down
/// should not have that decision replaced by a second Ctrl+C, and the first signal
/// is the one a user pressed deliberately rather than the one they pressed because
/// the first appeared to do nothing.
///
/// Safe to call from a signal handler: one atomic load and one atomic store, with
/// no allocation, no lock, and no syscall.
pub fn record(signal: Signal) void {
    assert(@intFromEnum(signal) != 0);
    if (pending.load(.acquire) == 0) pending.store(@intFromEnum(signal), .release);
}

/// The signal that requested shutdown, or `null` if none has.
///
/// Does not clear: a program usually checks this in a loop, and a value that
/// vanished on read would make the check order-dependent.
pub fn received() ?Signal {
    const value = pending.load(.acquire);
    if (value == 0) return null;
    return @enumFromInt(value);
}

/// Clears the recorded signal. For a program that survives a shutdown request and
/// wants to be interruptible again - and for tests, which must not leak state into
/// each other.
pub fn reset() void {
    pending.store(0, .release);
}

/// Installs handlers for the conventional shutdown signals.
///
/// Idempotent: installing twice replaces the handler with an equivalent one.
/// Returns the number of signals actually installed, so a caller can log what it
/// did rather than assume - the value is `0` on a platform with no signal support.
pub fn install() usize {
    if (comptime is_windows) return installWindows();
    if (comptime has_posix_signals) return installPosix();
    return 0;
}

/// Blocks until a shutdown signal arrives, polling `pending` every `poll_ms`.
///
/// A poll loop rather than a condition variable on purpose: a condvar would have
/// to be signalled from the handler, which cannot take its lock. The cost is one
/// atomic load per interval, and the interval is the caller's to choose because
/// only the caller knows how quickly it needs to react.
pub fn wait(io: std.Io, poll_ms: u32) Signal {
    assert(poll_ms > 0);
    while (true) {
        if (received()) |signal| return signal;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch {};
    }
}

// ── POSIX ─────────────────────────────────────────────────────────────────────

/// The type the platform's signal API hands to a handler.
///
/// POSIX `Sigaction` requires `*const fn (SIG) callconv(.c) void` where `SIG` is
/// the platform's **own enum**, not `c_int`. Getting this wrong compiles on
/// Windows - where the POSIX branch is never analysed - and fails only when the
/// tests are built for Linux, which is exactly what happened the first time.
/// Windows has no `std.posix.SIG` at all, so its arm names the console
/// control-event code instead.
const RawSignal = switch (builtin.os.tag) {
    .windows => u32,
    else => std.posix.SIG,
};

/// Translates the platform's number for a signal into this module's enum.
///
/// Called from the handler, so it is a chain of comparisons and nothing else: no
/// allocation, no lock, no syscall. `@hasField` guards the two signals that not
/// every POSIX target defines.
fn classify(raw: RawSignal) Signal {
    if (comptime is_windows) {
        // `SetConsoleCtrlHandler` passes a control-event code, not a signal
        // number: 0 is CTRL_C_EVENT, 2 is CTRL_CLOSE_EVENT.
        return switch (raw) {
            0 => .interrupt,
            2 => .terminate,
            else => .other,
        };
    } else {
        const S = std.posix.SIG;
        if (raw == S.INT) return .interrupt;
        if (raw == S.TERM) return .terminate;
        if (@hasField(S, "HUP")) {
            if (raw == S.HUP) return .hangup;
        }
        if (@hasField(S, "QUIT")) {
            if (raw == S.QUIT) return .quit;
        }
        return .other;
    }
}

fn handle(raw: RawSignal) callconv(.c) void {
    record(classify(raw));
}

fn installPosix() usize {
    if (comptime !has_posix_signals) {
        return 0;
    } else {
        var action = std.mem.zeroes(std.posix.Sigaction);
        action.handler = .{ .handler = handle };
        // An empty mask, which `zeroes` already gives: the handler must not block
        // the other shutdown signals, or a second Ctrl+C would queue behind the
        // first.
        action.flags = 0;

        const S = std.posix.SIG;
        var count: usize = 0;

        std.posix.sigaction(S.INT, &action, null);
        count += 1;
        std.posix.sigaction(S.TERM, &action, null);
        count += 1;

        if (@hasField(S, "HUP")) {
            std.posix.sigaction(S.HUP, &action, null);
            count += 1;
        }
        if (@hasField(S, "QUIT")) {
            std.posix.sigaction(S.QUIT, &action, null);
            count += 1;
        }
        return count;
    }
}

// ── Windows ───────────────────────────────────────────────────────────────────

const kernel32 = struct {
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (u32) callconv(.winapi) i32,
        add: i32,
    ) callconv(.winapi) i32;
};

fn handleWindows(ctrl_type: u32) callconv(.winapi) i32 {
    record(classify(ctrl_type));
    // Returning 1 claims the event, which suppresses the default handler and lets
    // the program exit on its own terms. Returning 0 would let Windows terminate
    // the process immediately, which is the opposite of graceful.
    return 1;
}

fn installWindows() usize {
    // The Windows branch is `if (comptime ...)` rather than an early return so
    // that on a POSIX target the `kernel32` reference below is never analysed -
    // an `extern "kernel32"` declaration that is analysed on Linux is a link
    // error, not a warning.
    if (comptime is_windows) {
        _ = kernel32.SetConsoleCtrlHandler(&handleWindows, 1);
        // Ctrl+C and close, the two events the handler reacts to.
        return 2;
    } else {
        return 0;
    }
}

const testing = std.testing;

test "recording a signal makes it observable, and the first one wins" {
    reset();
    defer reset();

    try testing.expectEqual(@as(?Signal, null), received());

    record(.terminate);
    try testing.expectEqual(@as(?Signal, .terminate), received());

    // A second signal must not replace the decision the first one made.
    record(.interrupt);
    try testing.expectEqual(@as(?Signal, .terminate), received());
}

test "received is stable across repeated reads rather than consuming the value" {
    reset();
    defer reset();

    record(.hangup);
    // Three reads, because a program's loop may check more than once before it
    // finishes its current unit of work.
    try testing.expectEqual(@as(?Signal, .hangup), received());
    try testing.expectEqual(@as(?Signal, .hangup), received());
    try testing.expectEqual(@as(?Signal, .hangup), received());
}

test "reset clears the request so a program can become interruptible again" {
    reset();
    defer reset();

    record(.quit);
    try testing.expectEqual(@as(?Signal, .quit), received());

    reset();
    try testing.expectEqual(@as(?Signal, null), received());

    // And a new signal is recorded after a reset, not swallowed by stale state.
    record(.interrupt);
    try testing.expectEqual(@as(?Signal, .interrupt), received());
}

test "every Signal value round-trips through the atomic without colliding with none" {
    reset();
    defer reset();

    // The zero-is-none encoding is the thing worth pinning: if any Signal were
    // numbered 0, `received` could never report it.
    inline for (@typeInfo(Signal).@"enum".fields) |field| {
        const signal: Signal = @enumFromInt(field.value);
        try testing.expect(@intFromEnum(signal) != 0);

        reset();
        record(signal);
        try testing.expectEqual(@as(?Signal, signal), received());
    }
}

test "classification maps the shutdown signals the specification names" {
    if (comptime is_windows) {
        try testing.expectEqual(Signal.interrupt, classify(0));
        try testing.expectEqual(Signal.terminate, classify(2));
        return;
    }
    if (comptime !has_posix_signals) return;

    const S = std.posix.SIG;
    try testing.expectEqual(Signal.interrupt, classify(S.INT));
    try testing.expectEqual(Signal.terminate, classify(S.TERM));
    // Something handled-but-not-shutdown, so the fallback is exercised too. Not
    // every POSIX target defines SIGWINCH, hence the guard.
    if (@hasField(S, "WINCH")) {
        try testing.expectEqual(Signal.other, classify(S.WINCH));
    }
}

test "install is callable on every platform and reports what it did" {
    const count = install();
    if (comptime is_windows) {
        try testing.expectEqual(@as(usize, 2), count);
    } else if (comptime has_posix_signals) {
        // SIGINT and SIGTERM at minimum.
        try testing.expect(count >= 2);
    } else {
        try testing.expectEqual(@as(usize, 0), count);
    }

    // Idempotent: a second install must not fail or change the count.
    try testing.expectEqual(count, install());
}
