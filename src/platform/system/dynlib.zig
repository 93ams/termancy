//! Shared libraries: load one, look up symbols, and hot-reload it when its file changes.
//!
//! `Library` is `std.DynLib` (the `dlopen` family, or Zig's own ELF loader on Linux without
//! libc) plus a Windows backend (`LoadLibraryW`), which `std.DynLib` lacks in 0.17.
//!
//! `Reloader` never loads the library file itself. It copies it to a private name
//! (`<path>.<pid>.<generation>`) and loads the copy, because the loader caches libraries by
//! path (a second `dlopen` of the same path returns the old image) and because Windows
//! locks a loaded DLL, which would stop the build from replacing it. `reloadIfChanged`
//! compares the file's modification time with the one seen at the last load; nothing
//! watches the file, so the caller decides when to look (once per frame, on a key press).
//!
//! Loading code runs it: initializers execute on load. Only load trusted files. On Linux
//! without libc, the ELF loader maps the library but does not apply relocations or run
//! initializers, so only self-contained libraries work there; link libc for general use.
//!
//! Symbols looked up before a reload point into the unloaded image. Look them up again
//! after every reload that returns `true`, and keep no pointers into the library's memory
//! (strings, vtables) across one.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = @import("process.zig");

const is_windows = builtin.os.tag == .windows;

/// A loaded shared library.
pub const Library = struct {
    handle: Handle,

    const Handle = if (is_windows) std.os.windows.HMODULE else std.DynLib;

    /// Errors from `open`.
    pub const OpenError = if (is_windows) error{
        FileNotFound,
        NameTooLong,
        InvalidWtf8,
        Unexpected,
    } else std.DynLib.Error;

    /// Loads the library at `path` (absolute, or relative to the working directory).
    pub fn open(path: []const u8) OpenError!Library {
        if (comptime is_windows) return .{ .handle = try openWindows(path) };
        return .{ .handle = try std.DynLib.open(path) };
    }

    /// Unloads the library. Every symbol looked up from it becomes invalid.
    pub fn close(lib: *Library) void {
        if (comptime is_windows) {
            _ = win32.FreeLibrary(lib.handle);
        } else {
            lib.handle.close();
        }
        lib.* = undefined;
    }

    /// The symbol `name` as `T` (a pointer type), or `null` when the library lacks it.
    pub fn lookup(lib: *Library, comptime T: type, name: [:0]const u8) ?T {
        comptime assert(@typeInfo(T) == .pointer);
        if (comptime is_windows) {
            const address = win32.GetProcAddress(lib.handle, name.ptr) orelse return null;
            return @ptrCast(@alignCast(address));
        }
        return lib.handle.lookup(T, name);
    }

    fn openWindows(path: []const u8) OpenError!std.os.windows.HMODULE {
        var wide: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
        if (path.len > wide.len) return error.NameTooLong;
        const len = try std.unicode.wtf8ToWtf16Le(&wide, path);
        wide[len] = 0;
        return win32.LoadLibraryW(wide[0..len :0].ptr) orelse
            switch (std.os.windows.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND, .MOD_NOT_FOUND => error.FileNotFound,
                else => error.Unexpected,
            };
    }
};

const win32 = struct {
    const windows = std.os.windows;
    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetProcAddress(
        module: windows.HMODULE,
        name: [*:0]const u8,
    ) callconv(.winapi) ?*anyopaque;
};

/// A library loaded from a private copy and reloaded on request when its file changes.
pub const Reloader = struct {
    gpa: Allocator,
    io: Io,
    /// Borrowed from the caller; must outlive the reloader.
    path: []const u8,
    library: Library,
    /// The copy `library` was loaded from. Owned.
    copy_path: []u8,
    /// The source's modification time when it was copied.
    mtime: Io.Timestamp,
    /// Incremented by every successful load; part of the copy's name.
    generation: u32,

    /// Errors from `open`, `reload`, and `reloadIfChanged`.
    pub const Error = Allocator.Error || Library.OpenError || Io.Dir.StatFileError ||
        Io.Dir.CopyFileError;

    /// Copies the library at `path` and loads the copy.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) Error!Reloader {
        const loaded = try load(gpa, io, path, 0);
        return .{
            .gpa = gpa,
            .io = io,
            .path = path,
            .library = loaded.library,
            .copy_path = loaded.copy_path,
            .mtime = loaded.mtime,
            .generation = 0,
        };
    }

    /// Unloads the library and deletes its copy.
    pub fn deinit(r: *Reloader) void {
        r.library.close();
        Io.Dir.cwd().deleteFile(r.io, r.copy_path) catch {};
        r.gpa.free(r.copy_path);
        r.* = undefined;
    }

    /// The symbol `name` in the current generation. See the file comment on lifetimes.
    pub fn lookup(r: *Reloader, comptime T: type, name: [:0]const u8) ?T {
        return r.library.lookup(T, name);
    }

    /// Reloads when the file's modification time differs from the last load's. Returns
    /// whether it reloaded. On failure the previous library stays loaded and usable.
    pub fn reloadIfChanged(r: *Reloader) Error!bool {
        const stat = try Io.Dir.cwd().statFile(r.io, r.path, .{});
        if (stat.mtime.nanoseconds == r.mtime.nanoseconds) return false;
        try r.reload();
        return true;
    }

    /// Loads a fresh copy, then unloads the previous one. On failure the previous library
    /// stays loaded and usable.
    pub fn reload(r: *Reloader) Error!void {
        const next = try load(r.gpa, r.io, r.path, r.generation +% 1);
        r.library.close();
        Io.Dir.cwd().deleteFile(r.io, r.copy_path) catch {};
        r.gpa.free(r.copy_path);
        r.library = next.library;
        r.copy_path = next.copy_path;
        r.mtime = next.mtime;
        r.generation +%= 1;
    }

    const Loaded = struct { library: Library, copy_path: []u8, mtime: Io.Timestamp };

    fn load(gpa: Allocator, io: Io, path: []const u8, generation: u32) Error!Loaded {
        const cwd = Io.Dir.cwd();
        // Stat before copying: a write that lands during the copy then still looks like a
        // change on the next check.
        const stat = try cwd.statFile(io, path, .{});
        const copy_path = try std.fmt.allocPrint(gpa, "{s}.{d}.{d}", .{
            path, process.currentId(), generation,
        });
        errdefer gpa.free(copy_path);
        try cwd.copyFile(path, cwd, copy_path, io, .{});
        errdefer cwd.deleteFile(io, copy_path) catch {};
        const library = try Library.open(copy_path);
        return .{ .library = library, .copy_path = copy_path, .mtime = stat.mtime };
    }
};

const testing = std.testing;

/// Builds a one-function library (`answer` returning `value`) into `dir` as `name` with
/// the `zig` on `PATH`; `null` when there is none. Built for the host and with no
/// relocations, so the libc-free ELF loader can run it too.
fn buildPlugin(dir: Io.Dir, dir_path: []const u8, name: []const u8, value: i32) !?void {
    if (!std.process.can_spawn) return null;
    var source: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&source, "export fn answer() i32 {{ return {d}; }}\n", .{
        value,
    });
    try dir.writeFile(testing.io, .{ .sub_path = "plug.zig", .data = text });
    const emit = try std.fmt.allocPrint(testing.allocator, "-femit-bin={s}", .{name});
    defer testing.allocator.free(emit);
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "zig", "build-lib", "-dynamic", "-O", "ReleaseSmall", "plug.zig", emit },
        .cwd = .{ .path = dir_path },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.PluginBuildFailed;
}

const Answer = *const fn () callconv(.c) i32;

test "open, look up, call, and close a library" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    (try buildPlugin(tmp.dir, dir_path, "libplug.so", 42)) orelse return error.SkipZigTest;
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "libplug.so" });
    defer testing.allocator.free(path);

    var lib = try Library.open(path);
    defer lib.close();
    try testing.expectEqual(42, lib.lookup(Answer, "answer").?());
    try testing.expect(lib.lookup(*const anyopaque, "snek_no_such_symbol") == null);
}

test "opening a missing library fails" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testing.expectError(error.FileNotFound, Library.open("/nonexistent/libsnek.so"));
}

test "reloader picks up a rebuilt library and cleans up its copies" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    (try buildPlugin(tmp.dir, dir_path, "libplug.so", 1)) orelse return error.SkipZigTest;
    (try buildPlugin(tmp.dir, dir_path, "next.so", 2)).?;
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "libplug.so" });
    defer testing.allocator.free(path);

    {
        var reloader: Reloader = try .open(testing.allocator, testing.io, path);
        defer reloader.deinit();
        try testing.expectEqual(1, reloader.lookup(Answer, "answer").?());
        try testing.expect(!try reloader.reloadIfChanged());

        try tmp.dir.copyFile("next.so", tmp.dir, "libplug.so", testing.io, .{});
        // A file system with coarse timestamps may not see the copy as newer; push it.
        // (`setTimestamps` is not implemented for Windows in 0.17, whose NTFS clock is fine.)
        const copied = try tmp.dir.statFile(testing.io, "libplug.so", .{});
        if (copied.mtime.nanoseconds == reloader.mtime.nanoseconds) {
            const later: Io.Timestamp = .{
                .nanoseconds = reloader.mtime.nanoseconds + std.time.ns_per_s,
            };
            try tmp.dir.setTimestamps(testing.io, "libplug.so", .{
                .modify_timestamp = .{ .new = later },
            });
        }
        try testing.expect(try reloader.reloadIfChanged());
        try testing.expectEqual(1, reloader.generation);
        try testing.expectEqual(2, reloader.lookup(Answer, "answer").?());
        try testing.expect(!try reloader.reloadIfChanged());
    }

    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".so.") == null);
    }
}

test "a failed reload keeps the previous library" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    (try buildPlugin(tmp.dir, dir_path, "libplug.so", 7)) orelse return error.SkipZigTest;
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "libplug.so" });
    defer testing.allocator.free(path);

    var reloader: Reloader = try .open(testing.allocator, testing.io, path);
    defer reloader.deinit();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "libplug.so", .data = "not a library" });
    try testing.expect(std.meta.isError(reloader.reload()));
    try testing.expectEqual(0, reloader.generation);
    try testing.expectEqual(7, reloader.lookup(Answer, "answer").?());
}
