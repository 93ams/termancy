//! Uncooked ("raw") terminal mode, Windows and POSIX.
//!
//! This file **is** the type. There is no `pub const RawTerminal = struct {...}`
//! wrapper: the file's own scope is the struct, so a consumer writes
//!
//! ```zig
//! const RawTerminal = @import("raw_terminal.zig");
//! var rt = try RawTerminal.enable();
//! defer rt.deinit();
//! ```
//!
//! rather than `@import("raw_terminal.zig").RawTerminal`. See the file-layout
//! rule in `.agents/AGENTS.md`.

const std = @import("std");
const builtin = @import("builtin");

/// `@This()` is the file itself, which is what `self: *Self` and `Self{}` need.
const Self = @This();

enabled: bool = false,
orig_mode: ModeBacking = undefined,

const ModeBacking = if (builtin.os.tag == .windows) u32 else std.posix.termios;

/// Enters raw mode and returns the handle that restores it.
///
/// A handle is returned even when stdin is not a terminal, in which case
/// `enabled` is false and `disable` is a no-op - so callers can `defer` without
/// branching.
pub fn enable() !Self {
    var rt = Self{};
    if (builtin.os.tag == .windows) {
        const win = std.os.windows;
        const kernel32 = struct {
            pub extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) win.HANDLE;
            pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: win.HANDLE, lpMode: *win.DWORD) win.BOOL;
            pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: win.HANDLE, dwMode: win.DWORD) win.BOOL;
        };
        const STD_INPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -10));
        const handle = kernel32.GetStdHandle(STD_INPUT_HANDLE);

        var mode: win.DWORD = 0;
        if (kernel32.GetConsoleMode(handle, &mode) != .FALSE) {
            rt.orig_mode = mode;
            const ENABLE_LINE_INPUT: win.DWORD = 0x0002;
            const ENABLE_ECHO_INPUT: win.DWORD = 0x0004;
            const ENABLE_PROCESSED_INPUT: win.DWORD = 0x0001;
            const ENABLE_VIRTUAL_TERMINAL_INPUT: win.DWORD = 0x0200;

            var raw_mode = mode;
            raw_mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
            raw_mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;
            _ = kernel32.SetConsoleMode(handle, raw_mode);
            rt.enabled = true;
        }
    } else {
        if (std.posix.isatty(0)) {
            const termios = try std.posix.tcgetattr(0);
            rt.orig_mode = termios;
            var raw = termios;
            // Standard POSIX cfmakeraw
            raw.iflag.IGNBRK = false;
            raw.iflag.BRKINT = false;
            raw.iflag.PARMRK = false;
            raw.iflag.ISTRIP = false;
            raw.iflag.INLCR = false;
            raw.iflag.IGNCR = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;

            raw.oflag.OPOST = false;

            raw.lflag.ECHO = false;
            raw.lflag.ECHONL = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;

            raw.cflag.CSIZE = .CS8;
            raw.cflag.PARENB = false;

            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

            try std.posix.tcsetattr(0, .FLUSH, raw);
            rt.enabled = true;
        }
    }
    return rt;
}

/// Restores the mode captured by `enable`. Safe to call when nothing was
/// changed, and safe to call twice.
pub fn disable(self: *Self) void {
    if (!self.enabled) return;
    if (builtin.os.tag == .windows) {
        const win = std.os.windows;
        const kernel32 = struct {
            pub extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) win.HANDLE;
            pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: win.HANDLE, dwMode: win.DWORD) win.BOOL;
        };
        const STD_INPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -10));
        const handle = kernel32.GetStdHandle(STD_INPUT_HANDLE);
        _ = kernel32.SetConsoleMode(handle, self.orig_mode);
    } else {
        std.posix.tcsetattr(0, .FLUSH, self.orig_mode) catch {};
    }
    self.enabled = false;
}

/// `defer rt.deinit();` spelling of `disable`.
pub fn deinit(self: *Self) void {
    self.disable();
}

test "enable is safe when stdin is not a terminal" {
    // In a test runner stdin is not a tty, so `enable` must report that it did
    // not change anything and `disable` must be a no-op rather than restoring
    // garbage over the real mode.
    var rt = try Self.enable();
    defer rt.deinit();
    if (!rt.enabled) {
        // Nothing was captured, so restoring must not touch the terminal.
        rt.disable();
    }
}
