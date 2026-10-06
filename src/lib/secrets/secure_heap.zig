const std = @import("std");
const builtin = @import("builtin");

pub const SecurePage = struct {
    memory: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !SecurePage {
        const mem = try allocator.alloc(u8, size);
        @memset(mem, 0);

        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const kernel32 = struct {
                pub extern "kernel32" fn VirtualLock(lpAddress: *anyopaque, dwSize: win.SIZE_T) win.BOOL;
            };
            _ = kernel32.VirtualLock(mem.ptr, mem.len);
        }

        return .{
            .memory = mem,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SecurePage) void {
        @memset(self.memory, 0);
        std.mem.doNotOptimizeAway(self.memory.ptr);

        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const kernel32 = struct {
                pub extern "kernel32" fn VirtualUnlock(lpAddress: *anyopaque, dwSize: win.SIZE_T) win.BOOL;
            };
            _ = kernel32.VirtualUnlock(self.memory.ptr, self.memory.len);
        }

        self.allocator.free(self.memory);
    }
};
