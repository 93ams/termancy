const std = @import("std");
const builtin = @import("builtin");

pub const ProcessTitle = struct {
    /// Scrub sensitive in-memory string arguments by wiping them in-place with zero bytes
    pub fn scrubSecretArg(arg: []u8) void {
        @memset(arg, 0);
        std.mem.doNotOptimizeAway(arg.ptr);
    }

    /// Set process title dynamically
    pub fn setTitle(new_title: []const u8) void {
        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const kernel32 = struct {
                pub extern "kernel32" fn SetConsoleTitleA(lpConsoleTitle: [*:0]const u8) win.BOOL;
            };
            var title_buf: [256]u8 = undefined;
            if (new_title.len < title_buf.len) {
                @memcpy(title_buf[0..new_title.len], new_title);
                title_buf[new_title.len] = 0;
                _ = kernel32.SetConsoleTitleA(@ptrCast(title_buf[0..new_title.len]));
            }
        }
    }
};
