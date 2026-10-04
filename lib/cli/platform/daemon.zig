const std = @import("std");
const builtin = @import("builtin");

pub const DaemonError = error{
    ProcessAlreadyRunning,
    PidFileCorrupt,
};

pub const PidFile = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !PidFile {
        // 1. Check if PID file already exists
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
            defer file.close(io);
            var buf: [32]u8 = undefined;
            const buffers = [_][]u8{&buf};
            const bytes_read = file.readStreaming(io, &buffers) catch 0;
            const pid_str = std.mem.trim(u8, buf[0..bytes_read], " \r\n\t");
            if (pid_str.len > 0) {
                const existing_pid = std.fmt.parseInt(u32, pid_str, 10) catch return DaemonError.PidFileCorrupt;
                if (isPidRunning(existing_pid)) {
                    return DaemonError.ProcessAlreadyRunning;
                }
            }
        } else |_| {}

        // 2. Write current PID
        const current_pid = getCurrentPid();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var buf: [32]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{d}\n", .{current_pid});
        try file.writePositionalAll(io, out, 0);

        return .{
            .path = path,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *PidFile) void {
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
    }

    pub fn getCurrentPid() u32 {
        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const kernel32 = struct {
                pub extern "kernel32" fn GetCurrentProcessId() win.DWORD;
            };
            return kernel32.GetCurrentProcessId();
        } else {
            // `std.posix.getpid` does not exist in this std; the syscall layer is
            // where it lives, and it is spelled per platform - `std.os.linux` on
            // Linux, `std.c` elsewhere. `std.posix.system` is exactly that alias,
            // so this is the portable spelling rather than a Linux-only one.
            return @intCast(std.posix.system.getpid());
        }
    }

    pub fn isPidRunning(pid: u32) bool {
        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const kernel32 = struct {
                pub extern "kernel32" fn OpenProcess(dwDesiredAccess: win.DWORD, bInheritHandle: win.BOOL, dwProcessId: win.DWORD) ?win.HANDLE;
                pub extern "kernel32" fn CloseHandle(hObject: win.HANDLE) win.BOOL;
            };
            const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
            if (kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid)) |h| {
                _ = kernel32.CloseHandle(h);
                return true;
            }
            return false;
        } else {
            // POSIX has no "is this pid alive" call. The idiom is `kill(pid, 0)`,
            // which runs the existence and permission checks without delivering a
            // signal. `std.posix.kill` takes the platform's `SIG` enum, and 0 is
            // not a named member of it, so it is constructed from the integer -
            // legal because the enum is non-exhaustive.
            std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| switch (err) {
                // ESRCH: no such process.
                error.ProcessNotFound => return false,
                // EPERM: the pid exists but belongs to another user. That is
                // still running, which is the question being asked.
                error.PermissionDenied => return true,
                else => return false,
            };
            return true;
        }
    }
};
