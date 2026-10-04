const std = @import("std");
const builtin = @import("builtin");

pub const System = struct {
    /// Checks if the process is running with root or Administrator privileges.
    pub fn isElevated() bool {
        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const advapi32 = struct {
                pub extern "advapi32" fn OpenProcessToken(ProcessHandle: win.HANDLE, DesiredAccess: win.DWORD, TokenHandle: *win.HANDLE) win.BOOL;
                pub extern "advapi32" fn GetTokenInformation(TokenHandle: win.HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: win.DWORD, ReturnLength: *win.DWORD) win.BOOL;
            };
            const kernel32 = struct {
                pub extern "kernel32" fn GetCurrentProcess() win.HANDLE;
                pub extern "kernel32" fn CloseHandle(hObject: win.HANDLE) win.BOOL;
            };
            const TOKEN_QUERY = 0x0008;
            const TokenElevation = 20;

            var token: win.HANDLE = undefined;
            if (advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), TOKEN_QUERY, &token) != 0) {
                defer _ = kernel32.CloseHandle(token);
                var elevation: struct { TokenIsElevated: win.DWORD } = undefined;
                var ret_len: win.DWORD = 0;
                if (advapi32.GetTokenInformation(token, TokenElevation, &elevation, @sizeOf(@TypeOf(elevation)), &ret_len) != 0) {
                    return elevation.TokenIsElevated != 0;
                }
            }
            return false;
        } else {
            // POSIX
            return std.posix.geteuid() == 0;
        }
    }

    /// Dispatches an OS desktop notification via OSC 9 / OSC 777 escape sequences.
    pub fn notifyTerminal(writer: anytype, title: []const u8, body: []const u8) !void {
        // OSC 777: notify;title;body
        try writer.print("\x1b]777;notify;{s};{s}\x1b\\", .{ title, body });
        // OSC 9: body
        try writer.print("\x1b]9;{s}\x1b\\", .{body});
    }

    /// Spawns the user's $EDITOR or $VISUAL with initial content, waits for exit, and returns the modified content.
    pub fn openEditor(
        allocator: std.mem.Allocator,
        initial_content: []const u8,
        extension: []const u8,
        env_map: *std.process.Environ.Map,
        io: std.Io,
    ) ![]u8 {
        const editor_cmd = env_map.get("VISUAL") orelse (env_map.get("EDITOR") orelse (if (builtin.os.tag == .windows) "notepad" else "nano"));

        const trace = @import("util").trace;
        const timestamp = trace.getMonotonicMs();
        var temp_path_buf: [256]u8 = undefined;
        const temp_path = try std.fmt.bufPrint(&temp_path_buf, "tmp_edit_{d}{s}", .{ timestamp, extension });

        // Write initial content
        {
            const f = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .truncate = true });
            defer f.close(io);
            try f.writePositionalAll(io, initial_content, 0);
        }
        defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

        // Parse editor command into argv
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        var it = std.mem.tokenizeScalar(u8, editor_cmd, ' ');
        while (it.next()) |token| {
            try argv.append(allocator, token);
        }
        try argv.append(allocator, temp_path);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        _ = try child.wait();

        // Read modified file
        const modified_file = try std.Io.Dir.cwd().openFile(io, temp_path, .{});
        defer modified_file.close(io);

        var buf: [65536]u8 = undefined;
        const buffers = [_][]u8{&buf};
        const bytes_read = try modified_file.readStreaming(io, &buffers);
        return try allocator.dupe(u8, buf[0..bytes_read]);
    }
};
