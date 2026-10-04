const std = @import("std");
const builtin = @import("builtin");

pub const page_size = std.heap.page_size_min;

pub const MmapFile = struct {
    bytes: []align(page_size) const u8,
    file_handle: FileHandleBacking,
    mapping_handle: MappingHandleBacking,
    size: usize,

    const FileHandleBacking = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t;
    const MappingHandleBacking = if (builtin.os.tag == .windows) std.os.windows.HANDLE else void;

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
            const fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
            errdefer std.posix.close(fd);

            const stat = try std.posix.fstat(fd);
            const size_usize: usize = @intCast(stat.size);
            if (size_usize == 0) return error.FileTooSmall;

            const ptr = try std.posix.mmap(
                null,
                size_usize,
                std.posix.PROT.READ,
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
            std.posix.close(self.file_handle);
        }
    }
};
