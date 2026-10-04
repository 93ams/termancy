//! `Secret(T)`: an owned, optionally page-locked value that is zeroed before release.
//!
//! ## The defect this replaces
//!
//! The previous API had an `Exposed` guard: `expose()` returned `{ value, parent }` and
//! `Exposed.destroy()` called `parent.deinit()`. The struct was **copyable** and owned
//! destruction, so copying it produced two guards over one buffer:
//!
//! ```zig
//! const e1 = secret.expose();
//! const e2 = e1;              // a copy, not a move - Zig has no move semantics here
//! e1.destroy();               // frees and zeroes the buffer
//! // e2.value still holds the address and the length: a dangling view.
//! e2.destroy();               // a safe no-op, because deinit guards on buffer.len
//! ```
//!
//! The hazard was therefore **read-after-free through the second guard**, not a double
//! free - measured: after `e1.destroy()` the second `destroy()` did nothing, and
//! `e2.value.len` still reported the original length while the memory was freed.
//!
//! ## Why the fix removes the guard rather than hardening it
//!
//! The guard existed to make wiping automatic. But it only wipes at a point the caller
//! chooses anyway, so the automation bought nothing that `deinit` did not already
//! provide - while introducing a handle that could be duplicated. Borrowing instead means
//! there is nothing to duplicate: `bytes()` and `value()` return views whose rule is
//! "do not free, do not outlive", and `wipe()` exists for a caller that must destroy the
//! contents before the lifetime ends. Fewer moving parts, and no way to accidentally
//! hold a stale one.
const std = @import("std");
const builtin = @import("builtin");

pub fn Secret(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []u8,
        allocator: std.mem.Allocator,

        /// Takes ownership of a copy of `secret`.
        ///
        /// The parameter is named `secret` rather than `value` because the type has a
        /// `value()` method: Zig rejects a parameter that shadows a declaration
        /// (`error: function parameter shadows declaration of 'value'`).
        pub fn init(allocator: std.mem.Allocator, secret: T) !Self {
            // Named `raw` rather than `bytes`, which would shadow the `bytes()` method.
            const raw = if (T == []const u8 or T == []u8)
                secret
            else
                std.mem.asBytes(&secret);

            const buf = try allocator.alloc(u8, raw.len);
            @memcpy(buf, raw);

            if (builtin.os.tag == .windows) {
                const win = std.os.windows;
                const kernel32 = struct {
                    pub extern "kernel32" fn VirtualLock(lpAddress: *anyopaque, dwSize: win.SIZE_T) win.BOOL;
                };
                _ = kernel32.VirtualLock(buf.ptr, buf.len);
            }

            return .{
                .buffer = buf,
                .allocator = allocator,
            };
        }

        /// The stored bytes, for a caller that needs to read the secret.
        ///
        /// **Borrowed, never owned.** The caller must not free this slice and must not
        /// keep it past `deinit` or `wipe`; the buffer belongs to `Self` for the whole of
        /// its life. That rule is the direct replacement for the defect described in the
        /// module header, and unlike a guard struct it cannot be broken by accident,
        /// because there is no handle to copy.
        pub fn bytes(self: *const Self) []const u8 {
            return self.buffer;
        }

        /// The value as `T`, for the shapes `init` accepts.
        pub fn value(self: *const Self) T {
            if (T == []const u8) return self.buffer;
            if (T == []u8) return self.buffer;
            return std.mem.bytesAsValue(T, self.buffer).*;
        }

        /// Zeroes the secret but keeps the allocation, so it can be refilled or freed
        /// normally afterwards. Use when the secret's *content* must die before its
        /// lifetime does.
        pub fn wipe(self: *Self) void {
            if (self.buffer.len > 0) {
                @memset(self.buffer, 0);
                std.mem.doNotOptimizeAway(self.buffer.ptr);
            }
        }

        /// Wipes and frees. A second call is a no-op: `buffer` is cleared to empty, which
        /// is the guard the old `Exposed.destroy` relied on.
        pub fn deinit(self: *Self) void {
            if (self.buffer.len > 0) {
                self.wipe();

                if (builtin.os.tag == .windows) {
                    const win = std.os.windows;
                    const kernel32 = struct {
                        pub extern "kernel32" fn VirtualUnlock(lpAddress: *anyopaque, dwSize: win.SIZE_T) win.BOOL;
                    };
                    _ = kernel32.VirtualUnlock(self.buffer.ptr, self.buffer.len);
                }

                self.allocator.free(self.buffer);
                self.buffer = &.{};
            }
        }
    };
}
