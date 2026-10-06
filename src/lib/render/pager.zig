//! Pager integration: how tall the terminal is, whether to page, and handing
//! content to `$PAGER`.
//!
//! This file **is** the type: the file's own scope is the pager, so a consumer
//! writes `const pager = @import("pager.zig");` and calls `pager.shouldPage(...)`.
//! See the file-layout rule in `.agents/AGENTS.md`.
//!
//! **Migrated to `std.Io`.** The previous body used `std.process.Child.init(...)`
//! and `child.spawn()`, neither of which exists in 0.16 - the API is
//! `std.process.spawn(io, .{ .argv = ..., .stdin = .pipe, ... })`, and `wait` takes
//! the `io`. That is why `pipeToPager` now takes an `io` parameter. Nothing called
//! it, so the stale call had never been compiled; converting this file to
//! file-as-type is what put it in front of the compiler.

const std = @import("std");
const builtin = @import("builtin");

const Self = @This();

/// The terminal's usable height in rows.
///
/// Queries the Windows console buffer directly; elsewhere, and on any failure,
/// returns the conventional 24. There is no `io` to consult `TIOCGWINSZ` with
/// here, which is why the POSIX side is a constant - see ROADMAP 5.5.
pub fn getTerminalHeight() usize {
    if (builtin.os.tag == .windows) {
        const win = std.os.windows;
        const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
            dwSize: extern struct { X: i16, Y: i16 },
            dwCursorPosition: extern struct { X: i16, Y: i16 },
            wAttributes: u16,
            srWindow: extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 },
            dwMaximumWindowSize: extern struct { X: i16, Y: i16 },
        };
        const kernel32 = struct {
            pub extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) ?win.HANDLE;
            pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleHandle: win.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) c_int;
        };
        const STD_OUTPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -11));
        if (kernel32.GetStdHandle(STD_OUTPUT_HANDLE)) |handle| {
            if (handle != win.INVALID_HANDLE_VALUE) {
                var csbi: CONSOLE_SCREEN_BUFFER_INFO = undefined;
                if (kernel32.GetConsoleScreenBufferInfo(handle, &csbi) != 0) {
                    const h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
                    if (h > 0) return @intCast(h);
                }
            }
        }
    }
    return 24;
}

/// Whether `content` has more lines than `height`.
///
/// Counts newlines, so a trailing newline counts as a line - content ending in
/// `"\n"` is treated as one line longer than it visually is.
pub fn shouldPage(content: []const u8, height: usize) bool {
    var lines: usize = 0;
    for (content) |c| {
        if (c == '\n') lines += 1;
    }
    return lines > height;
}

/// Writes `content` to `$PAGER` (default `more` on Windows, `less -R` elsewhere)
/// and waits for it to exit.
///
/// `io` is required because spawning and writing to the child's stdin both go
/// through it.
pub fn pipeToPager(
    io: std.Io,
    allocator: std.mem.Allocator,
    content: []const u8,
    env_map: *std.process.Environ.Map,
) !void {
    const pager_cmd = env_map.get("PAGER") orelse (if (builtin.os.tag == .windows) "more" else "less -R");

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, pager_cmd, ' ');
    while (it.next()) |token| {
        try argv.append(allocator, token);
    }
    // An empty or whitespace-only `$PAGER` would otherwise reach spawn with no
    // argv[0], which is a spawn error rather than a no-op.
    if (argv.items.len == 0) return error.EmptyPagerCommand;

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    // Close the pipe before waiting, or the pager waits forever for EOF.
    if (child.stdin) |stdin_file| {
        var buf: [4096]u8 = undefined;
        var w = stdin_file.writer(io, &buf);
        try w.interface.writeAll(content);
        try w.flush();
        stdin_file.close(io);
        child.stdin = null;
    }

    _ = try child.wait(io);
}

test "shouldPage compares the newline count against the height" {
    try std.testing.expect(!Self.shouldPage("one\ntwo\n", 10));
    try std.testing.expect(Self.shouldPage("one\ntwo\nthree\nfour\n", 2));
    // Exactly equal is not "more than".
    try std.testing.expect(!Self.shouldPage("a\nb\n", 2));
    try std.testing.expect(Self.shouldPage("a\nb\nc\n", 2));
    try std.testing.expect(!Self.shouldPage("", 0));
}

test "getTerminalHeight returns a usable positive row count" {
    // Not asserting a specific number: it is 24 off-Windows and the real
    // console height on Windows, both of which must be positive.
    try std.testing.expect(Self.getTerminalHeight() > 0);
}
