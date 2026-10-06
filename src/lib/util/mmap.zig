const std = @import("std");
const builtin = @import("builtin");

pub const page_size = std.heap.page_size_min;

/// The POSIX branch, and why it does not simply call `std.posix`.
///
/// Zig 0.16 removed `std.posix.open`, `std.posix.fstat` **and** `std.posix.close`
/// from the `posix` surface, and `std.posix.Stat` is `void` on Linux, so `fstat`
/// has no replacement there at all. The standard library's own guidance
/// (`std/posix.zig`, above `Stat`) is that Linux callers should use `statx`, which
/// is what `Io.File.stat` does. This branch is therefore assembled from the
/// documented replacements, and `PROT` is spelled as the packed struct it became:
///
/// * `open`     → `std.posix.openat(std.posix.AT.FDCWD, ...)`, still on `posix`
/// * `fstat`    → `statx` with `AT.EMPTY_PATH` (see `statSize`), which sizes the
///                descriptor rather than re-resolving the path
/// * `close`    → `std.os.linux.close`, which returns an error **code** rather
///                than an error union, so callers discard it
/// * `PROT.READ` → `std.posix.PROT{ .READ = true }`
///
/// `std.os.linux` is named directly rather than `std.posix.system`, because the
/// only non-Windows target this repository builds is Linux-static-musl: a second
/// spelling that pretends to be portable while being wrong on Linux (which
/// `system` is, since it resolves to `std.c` under libc and that layer has no
/// `statx` wrapper) would be the same defect in a new costume.
///
/// All of this rotted while nothing called `MmapFile.open`: the Windows branch was
/// analysed on every host build and the POSIX one never was. That is why the
/// regression test calls `open`, and why `zig build test-linux-compile` exists.
pub const MmapFile = struct {
    bytes: []align(page_size) const u8,
    file_handle: FileHandleBacking,
    mapping_handle: MappingHandleBacking,
    size: usize,

    const FileHandleBacking = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t;
    const MappingHandleBacking = if (builtin.os.tag == .windows) std.os.windows.HANDLE else void;

    /// The size of an open descriptor, for the POSIX branch's `fstat` step.
    ///
    /// `statx` reports which fields the kernel actually filled, and support
    /// varies by kernel and filesystem, so a missing `SIZE` bit is an error
    /// rather than a zero that would later be read as "the file is empty".
    fn statSize(fd: std.posix.fd_t) StatError!u64 {
        var stx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .NOSYS => return error.StatxUnsupported,
            .NOENT => return error.FileNotFound,
            .ACCES => return error.AccessDenied,
            .NOMEM => return error.SystemResources,
            // A bad descriptor is impossible here: `fd` was opened on the line
            // above statSize's only call site, and nothing has closed it.
            .BADF => return error.Unexpected,
            else => |e| return std.posix.unexpectedErrno(e),
        }
        if (!stx.mask.SIZE) return error.StatxIncomplete;
        return stx.size;
    }

    /// Errors `statSize` adds on top of what `openat` and `mmap` already return.
    const StatError = error{
        /// `statx` is not available on this kernel (`ENOSYS`).
        StatxUnsupported,
        /// The kernel did not fill the `SIZE` field that was requested.
        StatxIncomplete,
        FileNotFound,
        AccessDenied,
        SystemResources,
        Unexpected,
    };

    pub fn open(path: []const u8) !MmapFile {
        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const kernel32 = struct {
                pub extern "kernel32" fn CreateFileA(
                    lpFileName: [*:0]const u8,
                    dwDesiredAccess: win.DWORD,
                    dwShareMode: win.DWORD,
                    lpSecurityAttributes: ?*anyopaque,
                    dwCreationDisposition: win.DWORD,
                    dwFlagsAndAttributes: win.DWORD,
                    hTemplateFile: ?win.HANDLE,
                ) win.HANDLE;
                pub extern "kernel32" fn GetFileSizeEx(hFile: win.HANDLE, lpFileSize: *win.LARGE_INTEGER) win.BOOL;
                pub extern "kernel32" fn CreateFileMappingA(
                    hFile: win.HANDLE,
                    lpFileMappingAttributes: ?*anyopaque,
                    flProtect: win.DWORD,
                    dwMaximumSizeHigh: win.DWORD,
                    dwMaximumSizeLow: win.DWORD,
                    lpName: ?[*:0]const u8,
                ) ?win.HANDLE;
                pub extern "kernel32" fn MapViewOfFile(
                    hFileMappingObject: win.HANDLE,
                    dwDesiredAccess: win.DWORD,
                    dwFileOffsetHigh: win.DWORD,
                    dwFileOffsetLow: win.DWORD,
                    dwNumberOfBytesToMap: win.SIZE_T,
                ) ?*anyopaque;
                pub extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) win.BOOL;
                pub extern "kernel32" fn CloseHandle(hObject: win.HANDLE) win.BOOL;
            };

            var path_z_buf: [512]u8 = undefined;
            if (path.len >= path_z_buf.len) return error.NameTooLong;
            @memcpy(path_z_buf[0..path.len], path);
            path_z_buf[path.len] = 0;
            const path_z: [*:0]const u8 = @ptrCast(path_z_buf[0..path.len]);

            const GENERIC_READ = 0x80000000;
            const FILE_SHARE_READ = 1;
            const OPEN_EXISTING = 3;
            const FILE_ATTRIBUTE_NORMAL = 0x80;

            const h_file = kernel32.CreateFileA(path_z, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
            if (h_file == win.INVALID_HANDLE_VALUE) return error.FileNotFound;
            errdefer _ = kernel32.CloseHandle(h_file);

            var file_size: win.LARGE_INTEGER = 0;
            if (kernel32.GetFileSizeEx(h_file, &file_size) == .FALSE) return error.ReadError;
            if (file_size <= 0) return error.FileTooSmall;

            const PAGE_READONLY = 0x02;
            const h_map = kernel32.CreateFileMappingA(h_file, null, PAGE_READONLY, 0, 0, null) orelse return error.OutOfMemory;
            errdefer _ = kernel32.CloseHandle(h_map);

            const FILE_MAP_READ = 0x0004;
            const ptr = kernel32.MapViewOfFile(h_map, FILE_MAP_READ, 0, 0, 0) orelse return error.OutOfMemory;

            const size_usize: usize = @intCast(file_size);
            const aligned_ptr: [*]align(page_size) const u8 = @ptrCast(@alignCast(ptr));
            const byte_slice = aligned_ptr[0..size_usize];

            return MmapFile{
                .bytes = byte_slice,
                .file_handle = h_file,
                .mapping_handle = h_map,
                .size = size_usize,
            };
        } else {
            // See the file-level note above `MmapFile`: none of these three
            // spellings exists on the 0.16 `posix` surface any more.
            const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
            errdefer _ = std.os.linux.close(fd);

            const size_u64 = try statSize(fd);
            const size_usize: usize = @intCast(size_u64);
            if (size_usize == 0) return error.FileTooSmall;
            // A length that does not fit `usize` would have wrapped above, so
            // the cast is safe on every target this file can be built for.
            std.debug.assert(@as(u64, size_usize) == size_u64);

            const ptr = try std.posix.mmap(
                null,
                size_usize,
                // `PROT` is a packed struct in 0.16, not a set of constants.
                std.posix.PROT{ .READ = true },
                .{ .TYPE = .SHARED },
                fd,
                0,
            );

            return MmapFile{
                .bytes = ptr,
                .file_handle = fd,
                .mapping_handle = {},
                .size = size_usize,
            };
        }
    }

    pub fn deinit(self: *MmapFile) void {
        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const kernel32 = struct {
                pub extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) win.BOOL;
                pub extern "kernel32" fn CloseHandle(hObject: win.HANDLE) win.BOOL;
            };
            _ = kernel32.UnmapViewOfFile(self.bytes.ptr);
            _ = kernel32.CloseHandle(self.mapping_handle);
            _ = kernel32.CloseHandle(self.file_handle);
        } else {
            std.posix.munmap(self.bytes);
            // The syscall layer's `close` returns an error *code*, not an error
            // union; there is no recoverable failure at this point.
            _ = std.os.linux.close(self.file_handle);
        }
    }
};
