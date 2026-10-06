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
            // `win.BOOL` is a typed `Bool(c_int)`, not an integer: comparing it against `0`
            // is what made this function fail to compile, and it failed silently because no
            // caller ever instantiated it. Compare against the enum.
            if (advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), TOKEN_QUERY, &token) != .FALSE) {
                defer _ = kernel32.CloseHandle(token);
                var elevation: struct { TokenIsElevated: win.DWORD } = undefined;
                var ret_len: win.DWORD = 0;
                if (advapi32.GetTokenInformation(token, TokenElevation, &elevation, @sizeOf(@TypeOf(elevation)), &ret_len) != .FALSE) {
                    return elevation.TokenIsElevated != 0;
                }
            }
            return false;
        } else {
            // POSIX: uid 0 is the superuser, and the effective uid is what the permission
            // checks actually use.
            return std.os.linux.geteuid() == 0;
        }
    }

    /// Dispatches an OS desktop notification via OSC 9 / OSC 777 escape sequences.
    pub fn notifyTerminal(writer: anytype, title: []const u8, body: []const u8) !void {
        // OSC 777: notify;title;body
        try writer.print("\x1b]777;notify;{s};{s}\x1b\\", .{ title, body });
        // OSC 9: body
        try writer.print("\x1b]9;{s}\x1b\\", .{body});
    }

    /// Spawns the user's `$VISUAL`/`$EDITOR` with initial content, waits for exit, and
    /// returns the edited content.
    ///
    /// ## What changed and why
    ///
    /// This used `std.process.Child.init`, which Zig 0.16 replaced with `std.process.spawn`
    /// (argv, stream disposition and PATH resolution are all in `SpawnOptions` now), and
    /// `file.readStreaming`, which is gone. It also called `util.trace.getMonotonicMs` for
    /// the temporary file's name - a *clock read* inside a platform helper, and a
    /// dependency from `platform` onto a sibling module for no reason a caller can see. The
    /// name is now random, which is both simpler and strictly better: two edits in the same
    /// millisecond no longer collide.
    ///
    /// The child inherits the terminal, because an editor without a terminal is not an
    /// editor; the temporary file is deleted whether the editor succeeded or not.
    pub fn openEditor(
        allocator: std.mem.Allocator,
        initial_content: []const u8,
        extension: []const u8,
        env_map: *std.process.Environ.Map,
        io: std.Io,
    ) ![]u8 {
        const editor_cmd = env_map.get("VISUAL") orelse (env_map.get("EDITOR") orelse (if (builtin.os.tag == .windows) "notepad" else "nano"));

        var temp_path_buf: [256]u8 = undefined;
        // Random rather than clock-derived: `std.Io` owns entropy in Zig 0.16
        // (`std.crypto.random` is gone), and a name that cannot repeat is what a temporary
        // file in a shared directory needs.
        var nonce: u64 = 0;
        io.random(std.mem.asBytes(&nonce));
        const temp_path = try std.fmt.bufPrint(&temp_path_buf, "tmp_edit_{x}{s}", .{
            nonce,
            extension,
        });

        // Write initial content
        {
            const f = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .truncate = true });
            defer f.close(io);
            try f.writePositionalAll(io, initial_content, 0);
        }
        defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

        // Parse editor command into argv. `$EDITOR` may carry arguments (`code --wait`), so
        // it is split rather than treated as a single program name.
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        var it = std.mem.tokenizeScalar(u8, editor_cmd, ' ');
        while (it.next()) |token| {
            try argv.append(allocator, token);
        }
        try argv.append(allocator, temp_path);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .expand_arg0 = .expand,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        _ = try child.wait(io);

        // Read modified file
        const modified = try std.Io.Dir.cwd().readFileAlloc(io, temp_path, allocator, .limited(1 << 20));
        return modified;
    }
};

const testing = std.testing;

test "the elevation probe is instantiable and answers with a bool" {
    // This test exists because both declarations in this file were *unreachable* for a
    // while: nothing called them, so the compiler never analysed their bodies, and they
    // had rotted onto APIs Zig 0.16 removed (`win.BOOL` compared against `0`,
    // `std.process.Child.init`, `file.readStreaming`, `std.crypto.random`). Referencing the
    // function is what forces its body to be analysed, so this is the gate that keeps them
    // compiling rather than a check of the answer - the test host may or may not be
    // running elevated, and asserting either would be asserting the CI machine.
    const elevated: bool = System.isElevated();
    try testing.expect(elevated == true or elevated == false);
}

test "the editor helper is instantiable" {
    // The body spawns `$EDITOR`, so it cannot be *run* here; taking its address is what
    // makes the compiler analyse it, which is the failure this test pins.
    _ = &System.openEditor;
}
