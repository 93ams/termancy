//! The path of the running executable.
//!
//! A thin layer over `std.process.executablePath`, which already does the per-OS work:
//! `readlink("/proc/self/exe")` on Linux, `_NSGetExecutablePath` plus `realpath` on macOS,
//! `sysctl(KERN_PROC_PATHNAME)` on FreeBSD, and the process image name on Windows.
//!
//! Caveats that come with the operating system: on Linux, a binary deleted or replaced
//! after it started reports a path ending in ` (deleted)`, which `path` turns into
//! `error.FileNotFound`; other systems may report the old path. Symbolic links are
//! resolved, so the result names the real file, not the link the user typed.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Errors from `path` and `dir`.
pub const Error = std.process.ExecutablePathError;

/// Errors from `pathAlloc` and `dirAlloc`.
pub const AllocError = std.process.ExecutablePathAllocError;

/// The longest path the OS can return; `path` needs one byte more of buffer.
pub const max_path_bytes = std.fs.max_path_bytes;

const deleted_suffix = " (deleted)";

/// Writes the executable's absolute path into `buffer` and returns it. A path that fills
/// `buffer` exactly is reported as `error.NameTooLong`, because on Linux `readlink`
/// truncates silently and a truncated path cannot be told from a complete one.
pub fn path(io: Io, buffer: []u8) Error![]u8 {
    const len = try std.process.executablePath(io, buffer);
    if (len == buffer.len) return error.NameTooLong;
    const result = buffer[0..len];
    if (builtin.os.tag == .linux and std.mem.endsWith(u8, result, deleted_suffix)) {
        return error.FileNotFound;
    }
    return result;
}

/// The executable's absolute path, allocated. Caller owns it.
pub fn pathAlloc(io: Io, gpa: Allocator) AllocError![]u8 {
    var buffer: [max_path_bytes + 1]u8 = undefined;
    const result = path(io, &buffer) catch |err| switch (err) {
        // `buffer` holds the longest path the OS can return.
        error.NameTooLong => unreachable,
        else => |e| return e,
    };
    return gpa.dupe(u8, result);
}

/// The directory holding the executable, written into `buffer`.
pub fn dir(io: Io, buffer: []u8) Error![]u8 {
    const full = try path(io, buffer);
    // The OS returns absolute paths, which always have a parent.
    return full[0..std.fs.path.dirname(full).?.len];
}

/// The directory holding the executable, allocated. Caller owns it.
pub fn dirAlloc(io: Io, gpa: Allocator) AllocError![]u8 {
    var buffer: [max_path_bytes + 1]u8 = undefined;
    const result = dir(io, &buffer) catch |err| switch (err) {
        // `buffer` holds the longest path the OS can return.
        error.NameTooLong => unreachable,
        else => |e| return e,
    };
    return gpa.dupe(u8, result);
}

const testing = std.testing;

test "path names an existing absolute file" {
    const full = try pathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(full);
    try testing.expect(std.fs.path.isAbsolute(full));
    const stat = try Io.Dir.cwd().statFile(testing.io, full, .{});
    try testing.expectEqual(.file, stat.kind);
}

test "dir is the parent of path" {
    const full = try pathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(full);
    const parent = try dirAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(parent);
    try testing.expect(std.mem.startsWith(u8, full, parent));
    try testing.expect(full.len > parent.len + 1);
}

test "a short buffer is reported, not overrun" {
    var tiny: [2]u8 = undefined;
    try testing.expectError(error.NameTooLong, path(testing.io, &tiny));
}
