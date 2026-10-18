//! Ctrl-C for `App.cancel_on_interrupt`: a handler that records the interrupt in one
//! atomic, which the runner polls while the command runs as a task, cancelling the task
//! when it is set. Recording is all a signal handler may safely do; the cancel request goes
//! through `std.Io`, from the runner's own task.
//!
//! A second Ctrl-C, before the command has stopped, gets the default action and ends the
//! process at once (`SA_RESETHAND`; the Windows handler declines the second event), so a
//! command stuck outside any cancellation point can still be stopped.

const std = @import("std");
const builtin = @import("builtin");

const native_os = builtin.os.tag;
const is_windows = native_os == .windows;

/// Whether the target has interrupts to catch.
pub const supported = is_windows or (native_os != .wasi and native_os != .freestanding);

var pending: std.atomic.Value(bool) = .init(false);
var previous: if (supported and !is_windows) std.posix.Sigaction else void = undefined;

/// Starts recording Ctrl-C, and clears an earlier one. Does nothing where there are no
/// interrupts (`supported`).
pub fn install() void {
    pending.store(false, .release);
    if (comptime !supported) return;
    if (is_windows) {
        _ = SetConsoleCtrlHandler(&handleConsole, .TRUE);
    } else {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handlePosix },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESETHAND,
        };
        std.posix.sigaction(.INT, &action, &previous);
    }
}

/// Restores what `install` replaced.
pub fn uninstall() void {
    if (comptime !supported) return;
    if (is_windows) {
        _ = SetConsoleCtrlHandler(&handleConsole, .FALSE);
    } else {
        std.posix.sigaction(.INT, &previous, null);
    }
}

/// Whether Ctrl-C arrived since `install`.
pub fn interrupted() bool {
    return pending.load(.acquire);
}

/// Records an interrupt as Ctrl-C would. For tests, and for a program that wants to stop
/// its own running command.
pub fn request() void {
    pending.store(true, .release);
}

fn handlePosix(_: std.posix.SIG) callconv(.c) void {
    request();
}

fn handleConsole(event: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    // CTRL_C_EVENT and CTRL_BREAK_EVENT; a second one ends the process.
    if ((event != 0 and event != 1) or interrupted()) return .FALSE;
    request();
    return .TRUE;
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;
