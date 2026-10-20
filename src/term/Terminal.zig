//! The terminal an interactive program talks to: raw mode with guaranteed restore, size,
//! and the modes a program turns on (alternate screen, hidden cursor, bracketed paste,
//! mouse, focus events).
//!
//! `open` uses standard input and output when they are terminals and otherwise opens the
//! controlling terminal (`/dev/tty`; `CONIN$` and `CONOUT$` on Windows), so a program run
//! as `x=$(termancy ui choose a b)` draws on the terminal while its result goes to the pipe.
//!
//! ```zig
//! var buffer: [4096]u8 = undefined;
//! var terminal: term.Terminal = try .open(io, &buffer);
//! defer terminal.close();
//! try terminal.enterRaw();
//! ```
//!
//! Restoring: `restore` (called by `close`) undoes raw mode and every recorded mode. A
//! panic skips `defer`, so the application's panic handler should call `restoreOnPanic`,
//! which restores the terminal most recently put in raw mode. That one record is the only
//! global state in `term`; it is written by `enterRaw`, `recordModes`, and `restore`.
//!
//! A `Terminal` must not be moved after `writer` is first called: the writer is a field.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const Io = std.Io;
const File = Io.File;
const posix = std.posix;
const windows = std.os.windows;
const ansi = @import("ansi.zig");
const capability = @import("capability.zig");

const Terminal = @This();

io: Io,
input: File,
output: File,
/// Whether `close` closes `input` (it was opened here, not inherited).
owns_input: bool,
/// Whether `close` closes `output`.
owns_output: bool,
file_writer: File.Writer,
/// The mode before `enterRaw`, to put back.
saved: ?Saved = null,
/// Modes turned on that `restore` must turn off.
modes: Modes = .{},
/// Input read but not used by the last program, for the next one (`unread`).
pending: [256]u8 = undefined,
pending_len: usize = 0,

/// A size in cells.
pub const Size = struct {
    width: u16,
    height: u16,
};

/// The modes a program may turn on, which restoring turns off again.
pub const Modes = struct {
    alt_screen: bool = false,
    hidden_cursor: bool = false,
    bracketed_paste: bool = false,
    mouse: bool = false,
    focus_events: bool = false,
    kitty_keyboard: bool = false,

    /// Writes the sequences that turn off every mode set here.
    pub fn writeOff(modes: Modes, w: *Io.Writer) Io.Writer.Error!void {
        if (modes.kitty_keyboard) try ansi.setKittyKeyboard(w, false);
        if (modes.mouse) try ansi.setMouse(w, false);
        if (modes.focus_events) try ansi.setMode(w, .focus_events, false);
        if (modes.bracketed_paste) try ansi.setMode(w, .bracketed_paste, false);
        if (modes.hidden_cursor) try ansi.setMode(w, .cursor_visible, true);
        if (modes.alt_screen) try ansi.setMode(w, .alt_screen, false);
    }
};

const Saved = switch (native_os) {
    .windows => struct {
        input_mode: u32,
        output_mode: u32,
        input_code_page: u32,
        output_code_page: u32,
    },
    else => posix.termios,
};

/// Neither standard stream nor the controlling terminal is a terminal.
pub const OpenError = error{NotATerminal} || Io.Cancelable;

/// The terminal: standard input and output where they are terminals, the controlling
/// terminal where they are not. `buffer` holds output until `flush`.
pub fn open(io: Io, buffer: []u8) OpenError!Terminal {
    var input = File.stdin();
    var owns_input = false;
    if (!try input.isTty(io)) {
        input = try openControlling(io, .input);
        owns_input = true;
    }
    errdefer if (owns_input) input.close(io);
    var output = File.stdout();
    var owns_output = false;
    if (!try output.isTty(io)) {
        if (owns_input and native_os != .windows) {
            output = input; // /dev/tty was opened for reading and writing
        } else {
            output = try openControlling(io, .output);
            owns_output = true;
        }
    }
    return .{
        .io = io,
        .input = input,
        .output = output,
        .owns_input = owns_input,
        .owns_output = owns_output,
        .file_writer = output.writerStreaming(io, buffer),
    };
}

const Direction = enum { input, output };

fn openControlling(io: Io, direction: Direction) OpenError!File {
    if (native_os == .windows) return openConsole(direction);
    if (comptime native_os.isDarwin()) if (try openDevice(io)) |file| return file;
    const file = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch |err|
        return switch (err) {
            error.Canceled => error.Canceled,
            else => error.NotATerminal,
        };
    errdefer file.close(io);
    if (!try file.isTty(io)) return error.NotATerminal;
    return file;
}

/// The controlling terminal's own device (`/dev/ttys003`): macOS's `poll` refuses
/// `/dev/tty` itself, so reads from it could not time out (a lone Esc would wait for the
/// next key). The device a standard stream is open on, else the one the kernel records
/// for the process, when every stream is redirected.
fn openDevice(io: Io) Io.Cancelable!?File {
    var name: [256]u8 = undefined;
    for ([_]posix.fd_t{ 2, 1, 0 }) |fd| {
        if (darwin.ttyname_r(fd, &name, name.len) != 0) continue;
        if (try openPath(io, std.mem.sliceTo(&name, 0))) |file| return file;
    }
    const path = darwin.controllingDevice(&name) orelse return null;
    return openPath(io, path);
}

fn openPath(io: Io, path: []const u8) Io.Cancelable!?File {
    return Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        else => null,
    };
}

const darwin = struct {
    extern "c" fn ttyname_r(fd: c_int, buffer: [*]u8, len: usize) c_int;
    extern "c" fn devname(dev: i32, mode: u16) ?[*:0]const u8;

    /// `struct kinfo_proc` (648 bytes on arm64 and x86_64), of which only `kp_eproc.e_tdev`
    /// is read: at 296 (`sizeof(struct extern_proc)`) + 276 within `struct eproc`.
    const kinfo_proc_size = 648;
    const e_tdev_offset = 296 + 276;

    /// `/dev/<name>` of the process's controlling terminal, in `buffer`; null without one.
    fn controllingDevice(buffer: []u8) ?[]const u8 {
        var info: [kinfo_proc_size]u8 align(8) = undefined;
        var len: usize = info.len;
        // CTL_KERN, KERN_PROC, KERN_PROC_PID, this process.
        const mib = [4]c_int{ 1, 14, 1, std.c.getpid() };
        if (std.c.sysctl(&mib, mib.len, &info, &len, null, 0) != 0 or len < e_tdev_offset + 4) return null;
        const dev = std.mem.readInt(i32, info[e_tdev_offset..][0..4], builtin.cpu.arch.endian());
        if (dev == -1) return null; // NODEV: no controlling terminal
        const name = std.mem.sliceTo(devname(dev, 0o020000) orelse return null, 0); // S_IFCHR
        return std.fmt.bufPrint(buffer, "/dev/{s}", .{name}) catch null;
    }
};

const kernel32 = struct {
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: windows.DWORD,
        share: windows.DWORD,
        security: ?*anyopaque,
        disposition: windows.DWORD,
        flags: windows.DWORD,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn PeekConsoleInputW(
        input: windows.HANDLE,
        records: [*]InputRecord,
        len: windows.DWORD,
        count: *windows.DWORD,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn ReadConsoleInputW(
        input: windows.HANDLE,
        records: [*]InputRecord,
        len: windows.DWORD,
        count: *windows.DWORD,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn PeekNamedPipe(
        pipe: windows.HANDLE,
        buffer: ?*anyopaque,
        len: windows.DWORD,
        read: ?*windows.DWORD,
        available: ?*windows.DWORD,
        left: ?*windows.DWORD,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(
        handle: windows.HANDLE,
        milliseconds: windows.DWORD,
    ) callconv(.winapi) windows.DWORD;

    const wait_failed: windows.DWORD = 0xFFFFFFFF;
    const key_event: u16 = 0x1;

    /// `INPUT_RECORD`, with only the key event spelled out.
    const InputRecord = extern struct {
        event_type: u16,
        event: extern union {
            key: extern struct {
                down: c_int,
                repeat: u16,
                virtual_key: u16,
                virtual_scan: u16,
                char: u16,
                control_keys: windows.DWORD,
            },
            other: [16]u8,
        },
    };
};

fn openConsole(direction: Direction) OpenError!File {
    const generic_read: windows.DWORD = 0x80000000;
    const generic_write: windows.DWORD = 0x40000000;
    const share_read_write: windows.DWORD = 0x1 | 0x2;
    const open_existing: windows.DWORD = 3;
    const name = switch (direction) {
        .input => std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"),
        .output => std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
    };
    const handle = kernel32.CreateFileW(
        name,
        generic_read | generic_write,
        share_read_write,
        null,
        open_existing,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.NotATerminal;
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

/// Restores the terminal and closes what `open` opened.
pub fn close(t: *Terminal) void {
    t.restore();
    if (t.owns_output) t.output.close(t.io);
    if (t.owns_input) t.input.close(t.io);
    t.* = undefined;
}

/// The buffered writer to the terminal.
pub fn writer(t: *Terminal) *Io.Writer {
    return &t.file_writer.interface;
}

/// The color and escape capability of this terminal under `environ`.
pub fn capabilityIn(
    t: *const Terminal,
    environ: *const std.process.Environ.Map,
) capability.Capability {
    _ = t;
    return capability.detect(environ, .{ .is_tty = true });
}

/// The input is not a terminal, or the system refused the change.
pub const RawError = error{ NotATerminal, Unexpected } || Io.Cancelable;

/// Puts the terminal in raw mode: no echo, no line buffering, no signals from Ctrl-C or
/// Ctrl-Z (they arrive as keys), no output processing (`\n` does not return the carriage),
/// UTF-8 in and out. On Windows, also turns on virtual-terminal input and output. Does
/// nothing when already raw.
pub fn enterRaw(t: *Terminal) RawError!void {
    if (t.saved != null) return;
    t.saved = switch (native_os) {
        .windows => try t.enterRawWindows(),
        .wasi => return error.NotATerminal,
        else => try t.enterRawPosix(),
    };
    t.publish();
}

fn enterRawPosix(t: *Terminal) RawError!Saved {
    const original = posix.tcgetattr(t.input.handle) catch |err| return switch (err) {
        error.NotATerminal => error.NotATerminal,
        error.Unexpected => error.Unexpected,
    };
    var raw = original;
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
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    setTermios(t.input, raw) catch |err| return switch (err) {
        error.NotATerminal => error.NotATerminal,
        error.ProcessOrphaned, error.Unexpected => error.Unexpected,
    };
    return original;
}

/// Changes modes at once, keeping unread input: keys typed ahead (between two prompts, or
/// while a program starts) reach whoever reads next instead of being discarded.
fn setTermios(file: File, termios: posix.termios) posix.TermiosSetError!void {
    try posix.tcsetattr(file.handle, .NOW, termios);
}

const console = struct {
    const processed_input = 0x1;
    const line_input = 0x2;
    const echo_input = 0x4;
    const virtual_terminal_input = 0x200;
    const processed_output = 0x1;
    const virtual_terminal_processing = 0x4;
    const disable_newline_auto_return = 0x8;
    const utf8 = 65001;
};

fn enterRawWindows(t: *Terminal) RawError!Saved {
    const saved: Saved = .{
        .input_mode = try getMode(t.io, t.input),
        .output_mode = try getMode(t.io, t.output),
        .input_code_page = try getCodePage(t.io, .Input),
        .output_code_page = try getCodePage(t.io, .Output),
    };
    const input_mode = (saved.input_mode &
        ~@as(u32, console.processed_input | console.line_input | console.echo_input)) |
        console.virtual_terminal_input;
    const output_mode = saved.output_mode | console.processed_output |
        console.virtual_terminal_processing | console.disable_newline_auto_return;
    try setMode(t.io, t.input, input_mode);
    try setMode(t.io, t.output, output_mode);
    try setCodePage(t.io, .Input, console.utf8);
    try setCodePage(t.io, .Output, console.utf8);
    return saved;
}

const user_io = if (native_os == .windows) windows.CONSOLE.USER_IO else struct {};

fn getMode(io: Io, file: File) RawError!u32 {
    var request = user_io.GET_MODE;
    if (try request.operate(io, file) != .SUCCESS) return error.NotATerminal;
    return request.Data;
}

fn setMode(io: Io, file: File, mode: u32) RawError!void {
    var request = user_io.SET_MODE(mode);
    if (try request.operate(io, file) != .SUCCESS) return error.NotATerminal;
}

fn getCodePage(io: Io, which: anytype) RawError!u32 {
    var request = user_io.GET_CP(which);
    if (try request.operate(io, null) != .SUCCESS) return error.NotATerminal;
    return request.Data.CodePage;
}

fn setCodePage(io: Io, which: anytype, code_page: u32) RawError!void {
    var request = user_io.SET_CP(which, code_page);
    if (try request.operate(io, null) != .SUCCESS) return error.NotATerminal;
}

/// Keeps `bytes`, read from the input but not used, for the next reader (`takePending`):
/// keys typed ahead while one program was ending reach the next. What does not fit is
/// dropped.
pub fn unread(t: *Terminal, bytes: []const u8) void {
    const n = @min(bytes.len, t.pending.len - t.pending_len);
    @memcpy(t.pending[t.pending_len..][0..n], bytes[0..n]);
    t.pending_len += n;
}

/// The input `unread` kept, emptied.
pub fn takePending(t: *Terminal) []const u8 {
    defer t.pending_len = 0;
    return t.pending[0..t.pending_len];
}

/// Windows only: waits until reading the input returns at once, or until `deadline`;
/// false then. A console handle cannot be read asynchronously, so `Io.Batch` cannot wait
/// on it and a clock together; this waits on the handle instead. Console events that read
/// as no bytes (key releases, focus, resizes) are taken out of the queue here, or the read
/// that follows would block on them. A pipe (mintty) is polled. Elsewhere, true at once.
pub fn waitInput(t: *Terminal, deadline: Io.Timestamp) Io.Cancelable!bool {
    if (native_os != .windows) return true;
    const handle = t.input.handle;
    const is_console = if (getMode(t.io, t.input)) |_| true else |_| false;
    while (true) {
        try t.io.checkCancel();
        if (is_console) {
            var records: [32]kernel32.InputRecord = undefined;
            var count: windows.DWORD = 0;
            if (kernel32.PeekConsoleInputW(handle, &records, records.len, &count) == 0)
                return true; // let the read report it
            for (records[0..count]) |record| {
                if (record.event_type == kernel32.key_event and
                    record.event.key.down != 0 and record.event.key.char != 0) return true;
            }
            if (count > 0) {
                var taken: windows.DWORD = 0;
                _ = kernel32.ReadConsoleInputW(handle, &records, count, &taken);
                continue;
            }
        } else {
            var available: windows.DWORD = 0;
            if (kernel32.PeekNamedPipe(handle, null, 0, null, &available, null) == 0 or
                available > 0) return true;
        }
        const left = Io.Timestamp.now(t.io, .awake).durationTo(deadline).toMilliseconds();
        if (left <= 0) return false;
        if (is_console) {
            const waited = kernel32.WaitForSingleObject(handle, @intCast(@min(left, 100)));
            if (waited == kernel32.wait_failed) return true;
        } else {
            try t.io.sleep(.fromMilliseconds(@min(left, 10)), .awake);
        }
    }
}

/// Records which modes are on, so `restore` (and `restoreOnPanic`) turn them off. Writes
/// nothing: whoever turned the modes on already wrote the sequences.
pub fn recordModes(t: *Terminal, modes: Modes) void {
    t.modes = modes;
    if (t.saved != null) t.publish();
}

/// Turns off the recorded modes and leaves raw mode. Safe to call more than once, and
/// when nothing was changed. Errors are ignored: there is nothing left to do about them.
pub fn restore(t: *Terminal) void {
    const w = t.writer();
    t.modes.writeOff(w) catch {};
    w.flush() catch {};
    t.modes = .{};
    if (t.saved) |saved| restoreSaved(t.io, t.input, t.output, saved);
    t.saved = null;
    panic_record = null;
}

fn restoreSaved(io: Io, input: File, output: File, saved: Saved) void {
    if (native_os == .wasi) return;
    if (native_os == .windows) {
        setMode(io, input, saved.input_mode) catch {};
        setMode(io, output, saved.output_mode) catch {};
        setCodePage(io, .Input, saved.input_code_page) catch {};
        setCodePage(io, .Output, saved.output_code_page) catch {};
    } else {
        setTermios(input, saved) catch {};
    }
}

/// The output is not a terminal, or did not report a size.
pub const SizeError = error{NotATerminal} || Io.Cancelable;

/// The terminal's size in cells.
pub fn size(t: *const Terminal) SizeError!Size {
    return sizeOf(t.io, t.output);
}

/// The size of the terminal `file` is, for a file that is not a `Terminal` (standard
/// output, say). `error.NotATerminal` when it is not one, and always on WASI.
pub fn sizeOf(io: Io, file: File) SizeError!Size {
    switch (native_os) {
        .windows => {
            var request = user_io.GET_SCREEN_BUFFER_INFO;
            if (try request.operate(io, file) != .SUCCESS) return error.NotATerminal;
            const window = request.Data.dwWindowSize;
            if (window.X <= 0 or window.Y <= 0) return error.NotATerminal;
            return .{ .width = @intCast(window.X), .height = @intCast(window.Y) };
        },
        .wasi, .freestanding => return error.NotATerminal,
        else => {
            var winsize: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            const result = try io.operate(.{ .device_io_control = .{
                .file = file,
                .code = posix.T.IOCGWINSZ,
                .arg = &winsize,
            } });
            if (result.device_io_control < 0 or winsize.col == 0) return error.NotATerminal;
            return .{ .width = winsize.col, .height = @max(winsize.row, 1) };
        },
    }
}

/// What `restoreOnPanic` needs, copied out of the most recent raw-mode `Terminal`.
const PanicRecord = struct {
    io: Io,
    input: File,
    output: File,
    saved: Saved,
    modes: Modes,
};

var panic_record: ?PanicRecord = null;

fn publish(t: *const Terminal) void {
    panic_record = .{
        .io = t.io,
        .input = t.input,
        .output = t.output,
        .saved = t.saved.?,
        .modes = t.modes,
    };
}

/// Restores the terminal most recently put in raw mode, for a panic handler, which runs
/// without `defer`. Ends any synchronized update, resets colors, turns off the recorded
/// modes, and leaves raw mode, writing directly to the terminal (bypassing the buffer,
/// which a panic may have left half-written). Does nothing when no terminal is raw.
///
/// ```zig
/// pub const panic = std.debug.FullPanic(struct {
///     fn panic(message: []const u8, ra: ?usize) noreturn {
///         term.Terminal.restoreOnPanic();
///         std.debug.defaultPanic(message, ra);
///     }
/// }.panic);
/// ```
pub fn restoreOnPanic() void {
    const record = panic_record orelse return;
    panic_record = null;
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    w.writeAll(ansi.csi ++ "?2026l" ++ ansi.reset) catch {};
    record.modes.writeOff(&w) catch {};
    w.writeAll("\r\n") catch {};
    record.output.writeStreamingAll(record.io, w.buffered()) catch {};
    restoreSaved(record.io, record.input, record.output, record.saved);
}

const testing = std.testing;

test "Modes.writeOff turns off exactly what is on" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try (Modes{}).writeOff(&w);
    try testing.expectEqualStrings("", w.buffered());
    try (Modes{ .alt_screen = true, .hidden_cursor = true }).writeOff(&w);
    try testing.expectEqualStrings("\x1b[?25h\x1b[?1049l", w.buffered());
    w = .fixed(&buffer);
    try (Modes{ .mouse = true, .bracketed_paste = true, .focus_events = true }).writeOff(&w);
    try testing.expectEqualStrings(
        "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?1004l\x1b[?2004l",
        w.buffered(),
    );
}

test "restoreOnPanic does nothing when no terminal is raw" {
    try testing.expectEqual(null, panic_record);
    restoreOnPanic();
}

test "raw mode on something that is not a terminal fails cleanly" {
    // The test runner's standard input is a pipe or /dev/null (NUL), never a terminal.
    var buffer: [16]u8 = undefined;
    var t: Terminal = .{
        .io = testing.io,
        .input = File.stdin(),
        .output = File.stdout(),
        .owns_input = false,
        .owns_output = false,
        .file_writer = File.stdout().writerStreaming(testing.io, &buffer),
    };
    if (try t.input.isTty(testing.io)) return error.SkipZigTest;
    try testing.expectError(error.NotATerminal, t.enterRaw());
    try testing.expectEqual(null, t.saved);
    try testing.expectEqual(null, panic_record);
    t.restore();
}

test "unread keeps input for the next reader, as much as fits" {
    var t: Terminal = undefined;
    t.pending_len = 0;
    t.unread("ab");
    t.unread("c");
    try std.testing.expectEqualStrings("abc", t.takePending());
    try std.testing.expectEqualStrings("", t.takePending());
    const big: [300]u8 = @splat('x');
    t.unread(&big);
    try std.testing.expectEqual(256, t.takePending().len);
}
