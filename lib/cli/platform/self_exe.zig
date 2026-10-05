//! The path of the running executable.
//!
//! `std.process.Init` in Zig 0.16 hands a program its environment, its arguments, an
//! arena, an allocator, an `Io` and its preopened directories - and *not* its own path,
//! and there is no `std.process.selfExePath` to fall back on. Everything that needs to
//! know "which binary am I" therefore needs this module: replacing itself during an
//! update, re-executing after a configuration change, or writing a service unit that
//! runs this program.
//!
//! ## Per platform
//!
//! * **Windows** reads `ImagePathName` from the process environment block, which is what
//!   the loader recorded for this process. It is the same field `std` itself uses when it
//!   needs the image path, so there is one source of truth rather than a second guess made
//!   through `GetModuleFileNameW`.
//! * **Linux** reads the `/proc/self/exe` symlink, which the kernel resolves to the real
//!   path even when the binary was found through `PATH` or reached through a chain of
//!   links. That matters: an updater that renamed the *link* would replace the wrong file.
//! * **Anything else** reports `error.Unsupported` rather than guessing. A wrong path here
//!   means replacing the wrong file, which is worse than refusing - and the caller
//!   (`App.updateCommand`) already has a seam for supplying one.

const std = @import("std");
const builtin = @import("builtin");

/// The longest path this module will return, which is the platform's own limit.
pub const max_path_bytes = std.fs.max_path_bytes;

pub const Error = error{
    /// This platform has no implementation. See the module comment.
    Unsupported,
    /// The path did not fit the platform's maximum.
    PathTooLong,
} || std.mem.Allocator.Error || std.unicode.Utf16LeToUtf8AllocError || std.Io.Dir.ReadLinkError;

/// The absolute path of the running executable, allocated from `allocator`.
///
/// The caller owns the returned slice. The path is *not* resolved further: on Windows it
/// is what the loader recorded (absolute for any process started normally), and on Linux
/// it is already the kernel's resolved target.
pub fn pathAlloc(allocator: std.mem.Allocator, io: std.Io) Error![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const image = std.os.windows.peb().ProcessParameters.ImagePathName.sliceZ();
            // The loader always records an image path for a running process; an empty one
            // would mean this is not a normal process, and guessing from there is worse
            // than failing.
            if (image.len == 0) return error.Unsupported;
            return std.unicode.utf16LeToUtf8Alloc(allocator, image);
        },
        .linux => {
            var buffer: [max_path_bytes]u8 = undefined;
            const len = std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer) catch |err| switch (err) {
                error.NameTooLong => return error.PathTooLong,
                else => return err,
            };
            std.debug.assert(len > 0);
            if (len == 0) return error.Unsupported;
            return allocator.dupe(u8, buffer[0..len]);
        },
        else => return error.Unsupported,
    }
}

/// A `resolve_target` for `App.updateCommand`, so an app can write
/// `.resolve_target = self_exe.pathAlloc` instead of adapting the signature itself.
pub fn resolveTarget(allocator: std.mem.Allocator, io: std.Io) anyerror![]u8 {
    return pathAlloc(allocator, io);
}

const testing = std.testing;

test "the running executable's path is absolute, non-empty and openable" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;

    const path = try pathAlloc(testing.allocator, testing.io);
    defer testing.allocator.free(path);

    try testing.expect(path.len > 0);
    // Absolute, because every caller (an updater above all) is about to use it from an
    // unknown working directory.
    try testing.expect(std.Io.Dir.path.isAbsolute(path));
    // It exists and is a file we can open: the assertion that separates a real path from
    // a plausible-looking string.
    var file = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    file.close(testing.io);
}

test "the resolver adapter is the same function as the direct path" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;

    const direct = try pathAlloc(testing.allocator, testing.io);
    defer testing.allocator.free(direct);
    const adapted = try resolveTarget(testing.allocator, testing.io);
    defer testing.allocator.free(adapted);

    try testing.expectEqualStrings(direct, adapted);
}

test "an unsupported platform is refused rather than guessed at" {
    // The switch is on `builtin.os.tag`, so this documents the contract for the targets
    // that return `Unsupported` without needing one of them to run the test.
    if (builtin.os.tag == .windows or builtin.os.tag == .linux) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, pathAlloc(testing.allocator, testing.io));
}
