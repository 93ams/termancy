//! Long help through a pager, as git and man do: `$PAGER` (split into words as a shell
//! would, without expansions), else `less -FRX` (on POSIX systems; Windows pages only with
//! `$PAGER` set). `PAGER=cat` or an empty `PAGER` turns paging off. `less -F` leaves at
//! once when the text fits; `-R` keeps colors; `-X` leaves the text on the screen.
//!
//! `App.pager` turns this on for help longer than the terminal.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const shell = @import("shell.zig");

/// The command `page` runs, or null for none.
pub fn command(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
) Allocator.Error!?[]const []const u8 {
    const configured = environ.get("PAGER") orelse {
        if (builtin.os.tag == .windows) return null;
        return &.{ "less", "-FRX" };
    };
    // On Windows, a command line's rules: `C:\tools\less.exe` keeps its backslashes, which
    // a POSIX shell would take as escapes.
    const words = if (builtin.os.tag == .windows)
        try windowsWords(arena, configured)
    else
        shell.tokenize(arena, configured) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    if (words.len == 0 or std.mem.eql(u8, words[0], "cat")) return null;
    return words;
}

/// `line` split as `CommandLineToArgvW` splits a command line.
fn windowsWords(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    const line_w = std.unicode.wtf8ToWtf16LeAlloc(arena, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return &.{},
    };
    var it: std.process.Args.Iterator.Windows = try .init(arena, line_w);
    defer it.deinit();
    var words: std.ArrayList([]const u8) = .empty;
    while (it.next()) |word| try words.append(arena, try arena.dupe(u8, word));
    return words.items;
}

/// Writes `text` through the pager and waits for it to quit. False when there is no pager
/// or it could not be started, so the caller writes `text` itself. Flush what is buffered
/// for standard output first: the pager writes to it directly.
pub fn page(
    io: Io,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    text: []const u8,
) Allocator.Error!bool {
    const argv = try command(arena, environ) orelse return false;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ,
        .stdin = .pipe,
    }) catch return false;
    // A pager quit early (`q` in less) closes the pipe; the rest is not wanted.
    child.stdin.?.writeStreamingAll(io, text) catch {};
    child.stdin.?.close(io);
    child.stdin = null;
    _ = child.wait(io) catch {};
    return true;
}

const testing = std.testing;

test command {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    if (builtin.os.tag != .windows) {
        const default = (try command(a, &environ)).?;
        try testing.expectEqualStrings("less", default[0]);
    }
    const windows = builtin.os.tag == .windows;
    try environ.put("PAGER", if (windows) "most -s \"with space\"" else "most -s 'with space'");
    const words = (try command(a, &environ)).?;
    try testing.expectEqual(3, words.len);
    try testing.expectEqualStrings("with space", words[2]);
    if (windows) {
        try environ.put("PAGER", "\"C:\\Program Files\\less.exe\" -R");
        const program = (try command(a, &environ)).?;
        try testing.expectEqualStrings("C:\\Program Files\\less.exe", program[0]);
        try testing.expectEqualStrings("-R", program[1]);
    }
    try environ.put("PAGER", "cat");
    try testing.expectEqual(null, try command(a, &environ));
    try environ.put("PAGER", "");
    try testing.expectEqual(null, try command(a, &environ));
}

/// A pager command that copies what it is given into `out`: `sh` on POSIX, a batch file
/// in `dir` on Windows (`findstr "^"` copies its input byte for byte), which needs
/// `SystemRoot` in `environ` to start.
fn testPager(
    a: Allocator,
    environ: *std.process.Environ.Map,
    dir: Io.Dir,
    dir_path: []const u8,
    out: []const u8,
) ![]const u8 {
    if (builtin.os.tag != .windows) return std.fmt.allocPrint(a, "sh -c 'cat >\"$0\"' {s}", .{out});
    try environ.put("SystemRoot", try testing.environ.getAlloc(a, "SystemRoot"));
    try dir.writeFile(testing.io, .{
        .sub_path = "pager.cmd",
        .data = "@echo off\r\n\"%SystemRoot%\\System32\\findstr.exe\" \"^\" > \"%~1\"\r\n",
    });
    const script = try std.fs.path.join(a, &.{ dir_path, "pager.cmd" });
    return std.fmt.allocPrint(a, "{s} {s}", .{ script, out });
}

test "page sends the text to the pager" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const out = try std.fs.path.join(a, &.{ dir, "paged" });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PAGER", try testPager(a, &environ, tmp.dir, dir, out));
    try testing.expect(try page(io, a, &environ, "line one\nline two\n"));
    const written = try tmp.dir.readFileAlloc(io, "paged", a, .unlimited);
    try testing.expectEqualStrings("line one\nline two\n", written);
    // A pager that is not there: the caller writes the text.
    try environ.put("PAGER", "/nonexistent/pager");
    try testing.expect(!try page(io, a, &environ, "x"));
}
