//! What the runner asks of the terminal: its width, for wrapping help, its height, for
//! paging it, how much color is wanted, and whether anyone is there to answer a question.
//! Built on `term`; everything degrades to "not a terminal".

const std = @import("std");
const Io = std.Io;
const term = @import("term");

/// The number of columns of the terminal `file` is, or null when it is not one (or the
/// system does not say).
pub fn width(io: Io, file: Io.File) ?u16 {
    const size = term.Terminal.sizeOf(io, file) catch return null;
    return size.width;
}

/// The number of rows of the terminal `file` is, or null when it is not one.
pub fn height(io: Io, file: Io.File) ?u16 {
    const size = term.Terminal.sizeOf(io, file) catch return null;
    return size.height;
}

/// The width help wraps to: the terminal's, else `$COLUMNS`, else `fallback`; kept between
/// 40 and 160 columns, since very long lines are hard to read.
pub fn helpWidth(terminal_width: ?u16, environ: *const std.process.Environ.Map, fallback: u16) u16 {
    const columns = terminal_width orelse if (environ.get("COLUMNS")) |text|
        std.fmt.parseInt(u16, text, 10) catch fallback
    else
        fallback;
    return std.math.clamp(columns, 40, 160);
}

/// How many colors output to a stream should use, by `term.capability`'s rules: `NO_COLOR`
/// turns color off, `FORCE_COLOR` and `CLICOLOR_FORCE` on; otherwise a terminal (or a CI
/// log) gets what its variables say it shows.
pub fn colorLevel(environ: *const std.process.Environ.Map, is_tty: bool) term.capability.Color {
    return term.capability.detect(environ, .{ .is_tty = is_tty }).color;
}

/// Whether output to a stream should be colored at all (`colorLevel` is not `.none`).
pub fn colorWanted(environ: *const std.process.Environ.Map, is_tty: bool) bool {
    return colorLevel(environ, is_tty) != .none;
}

/// Whether a run may ask questions (prompts, confirmations, a shell on a bare command):
/// standard input and standard error are terminals, and the run is not under continuous
/// integration, whose runners sometimes provide a terminal nobody watches.
pub fn interactive(
    environ: *const std.process.Environ.Map,
    stdin_tty: bool,
    stderr_tty: bool,
) bool {
    return stdin_tty and stderr_tty and !term.capability.ci(environ);
}

/// The console's code pages before `useUtf8`, to put back.
pub const CodePages = struct { input: u32, output: u32 };

/// On Windows, switches the console this process is attached to to UTF-8 for input and
/// output, and returns what it was; null elsewhere, or without a console. Output is UTF-8
/// throughout, and a console on its default code page (437, 850, ...) would show `✓` as
/// `Γ£ô`; typed answers would arrive in that code page too. The console is shared with
/// the shell, so put it back with `restoreCodePages` before exiting.
pub fn useUtf8() ?CodePages {
    if (@import("builtin").os.tag != .windows) return null;
    const saved: CodePages = .{ .input = kernel32.GetConsoleCP(), .output = kernel32.GetConsoleOutputCP() };
    if (saved.input == 0 or saved.output == 0) return null; // no console
    if (saved.input == utf8 and saved.output == utf8) return null;
    _ = kernel32.SetConsoleCP(utf8);
    _ = kernel32.SetConsoleOutputCP(utf8);
    return saved;
}

/// Puts back the code pages `useUtf8` replaced.
pub fn restoreCodePages(saved: ?CodePages) void {
    if (@import("builtin").os.tag != .windows) return;
    const pages = saved orelse return;
    _ = kernel32.SetConsoleCP(pages.input);
    _ = kernel32.SetConsoleOutputCP(pages.output);
}

const utf8 = 65001;

const kernel32 = struct {
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) i32;
};

const testing = std.testing;

test interactive {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expect(interactive(&environ, true, true));
    try testing.expect(!interactive(&environ, true, false));
    try testing.expect(!interactive(&environ, false, true));
    try environ.put("CI", "true");
    try testing.expect(!interactive(&environ, true, true));
    try environ.put("CI", "false");
    try testing.expect(interactive(&environ, true, true));
}

test helpWidth {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectEqual(100, helpWidth(null, &environ, 100));
    try testing.expectEqual(120, helpWidth(120, &environ, 100));
    try testing.expectEqual(160, helpWidth(400, &environ, 100));
    try environ.put("COLUMNS", "70");
    try testing.expectEqual(70, helpWidth(null, &environ, 100));
    try testing.expectEqual(40, helpWidth(10, &environ, 100));
}

test colorLevel {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("TERM", "xterm-256color");
    try testing.expectEqual(.ansi256, colorLevel(&environ, true));
    try testing.expectEqual(.none, colorLevel(&environ, false));
    try environ.put("COLORTERM", "truecolor");
    try testing.expectEqual(.truecolor, colorLevel(&environ, true));
}

test colorWanted {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expect(!colorWanted(&environ, false));
    try environ.put("TERM", "xterm");
    try testing.expect(colorWanted(&environ, true));
    try environ.put("TERM", "dumb");
    try testing.expect(!colorWanted(&environ, true));
    try environ.put("FORCE_COLOR", "1");
    try testing.expect(colorWanted(&environ, false));
    try environ.put("NO_COLOR", "1");
    try testing.expect(!colorWanted(&environ, true));
}
