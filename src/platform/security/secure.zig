//! Memory for secrets: an allocator that keeps them out of swap and core dumps and wipes
//! them when they are released, plus `wipe`, a constant-time `eql`, and `Secret`.
//!
//! ```zig
//! var secure: SecureAllocator = .init(std.heap.page_allocator, .{});
//! var config: cfg.Config = .init(secure.allocator());
//! defer config.deinit(); // every byte the configuration held is zeroed before release
//! ```
//!
//! What each operating system provides:
//!
//! | OS                 | page lock     | excluded from core dumps |
//! |--------------------|---------------|--------------------------|
//! | Linux              | `mlock`       | `madvise(MADV_DONTDUMP)` |
//! | FreeBSD, DragonFly | `mlock`       | `madvise(MADV_NOCORE)`   |
//! | macOS, other BSDs  | `mlock`       | not available: macOS writes no core files unless the |
//! |                    |               | process raises `RLIMIT_CORE`, which it should not    |
//! | Windows            | `VirtualLock` | not available: minidumps are opt-in per process      |
//!
//! Locking works on whole pages, so a lock is taken on every page an allocation touches,
//! and released only on pages the allocation covers entirely: a page shared with another
//! allocation stays locked. Locked memory is limited (`RLIMIT_MEMLOCK` on POSIX, the
//! working-set minimum on Windows); what happens when the limit is reached is the
//! `LockPolicy`. Nothing here changes those limits.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Io = std.Io;

/// A page-aligned range handed to the `Os` hooks.
pub const Pages = []align(std.heap.page_size_min) u8;

/// What to do when the operating system refuses to lock memory.
pub const LockPolicy = enum {
    /// Keep the memory unlocked and count the failure (`SecureAllocator.lockFailures`).
    best_effort,
    /// Fail the allocation. Growing in place is then never attempted, so a resize that
    /// would need a new lock returns `false` and the caller reallocates.
    required,
};

/// The operating-system calls the allocator makes. Replaceable for tests.
pub const Os = struct {
    /// Locks `pages` into memory; `false` when refused.
    lock: *const fn (pages: Pages) bool,
    /// Releases a lock taken by `lock`.
    unlock: *const fn (pages: Pages) void,
    /// Excludes `pages` from core dumps, where the OS can.
    exclude_from_dump: *const fn (pages: Pages) void,

    /// The calls of the target operating system.
    pub const native: Os = .{
        .lock = nativeLock,
        .unlock = nativeUnlock,
        .exclude_from_dump = nativeExcludeFromDump,
    };
};

/// Options for `SecureAllocator.init`.
pub const Options = struct {
    policy: LockPolicy = .best_effort,
    os: Os = .native,
};

/// A `std.mem.Allocator` over a backing allocator that page-locks every allocation, keeps
/// it out of core dumps, and zeroes every byte on free and on a shrinking resize. `remap`
/// only succeeds in place, so a moving reallocation goes through `alloc` and `free` here
/// and the old block is wiped too.
///
/// Thread-safe exactly when the backing allocator is.
pub const SecureAllocator = struct {
    backing: Allocator,
    policy: LockPolicy,
    os: Os,
    lock_failures: std.atomic.Value(usize) = .init(0),

    /// Wraps `backing`. `std.heap.page_allocator` gives every allocation its own pages, so
    /// all of them are unlocked on free; put an `ArenaAllocator` on top for small objects.
    pub fn init(backing: Allocator, options: Options) SecureAllocator {
        return .{ .backing = backing, .policy = options.policy, .os = options.os };
    }

    /// The allocator interface. `self` must outlive it.
    pub fn allocator(self: *SecureAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// How many times the OS refused a lock under `.best_effort`.
    pub fn lockFailures(self: *const SecureAllocator) usize {
        return self.lock_failures.load(.monotonic);
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SecureAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        const memory = ptr[0..len];
        if (!self.protect(memory)) {
            wipe(memory);
            self.backing.rawFree(memory, alignment, ret_addr);
            return null;
        }
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *SecureAllocator = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) return self.shrink(memory, alignment, new_len, ret_addr);
        if (self.policy == .required) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        const grown = memory.ptr[0..new_len];
        // `.best_effort` never fails `protect`; the result only feeds the failure count.
        _ = self.protect(grown[memory.len..]);
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        // Never let the backing allocator move the bytes: it would release the old block
        // without wiping it.
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *SecureAllocator = @ptrCast(@alignCast(ctx));
        wipe(memory);
        if (innerPages(memory)) |pages| self.os.unlock(pages);
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    fn shrink(
        self: *SecureAllocator,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        assert(new_len <= memory.len);
        const tail = memory[new_len..];
        // Unlocking happens only once the backing allocator has accepted the shrink, so a
        // refused shrink leaves the lock in place; the tail is wiped either way, since the
        // caller no longer considers those bytes live.
        wipe(tail);
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (innerPages(tail)) |pages| self.os.unlock(pages);
        return true;
    }

    /// Locks and excludes from dumps the pages `memory` touches. `false` only under
    /// `.required` when the lock was refused.
    fn protect(self: *SecureAllocator, memory: []u8) bool {
        const pages = outerPages(memory) orelse return true;
        self.os.exclude_from_dump(pages);
        if (self.os.lock(pages)) return true;
        if (self.policy == .required) return false;
        _ = self.lock_failures.fetchAdd(1, .monotonic);
        return true;
    }
};

var default_instance: SecureAllocator = .init(std.heap.page_allocator, .{});

/// A process-wide `SecureAllocator` over `std.heap.page_allocator` with the default
/// options. Each allocation takes whole pages, so use it as the parent of an arena (as
/// `cfg.Config` does) rather than for many small objects.
pub fn allocator() Allocator {
    return default_instance.allocator();
}

/// Overwrites `bytes` with zeroes in a way the optimizer cannot remove.
pub fn wipe(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

/// Compares in time that depends only on the lengths, never on the contents. The lengths
/// themselves are not secret: unequal lengths return at once.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    // A volatile accumulator keeps the compiler from turning the loop into an early exit.
    const acc: *volatile u8 = &diff;
    for (a, b) |x, y| acc.* |= x ^ y;
    return acc.* == 0;
}

const timingSafeEql = eql;

/// An owned copy of secret bytes that formats as `<redacted>`, compares in constant time,
/// and is wiped by `deinit`.
pub const Secret = struct {
    bytes: []u8,
    gpa: Allocator,

    /// What `format` writes instead of the bytes.
    pub const redacted = "<redacted>";

    /// Copies `value` into memory from `gpa` (ideally a `SecureAllocator`).
    pub fn init(gpa: Allocator, value: []const u8) Allocator.Error!Secret {
        return .{ .bytes = try gpa.dupe(u8, value), .gpa = gpa };
    }

    /// Wipes and frees the bytes.
    pub fn deinit(secret: *Secret) void {
        wipe(secret.bytes);
        secret.gpa.free(secret.bytes);
        secret.* = undefined;
    }

    /// The secret itself. Every use is a place it can leak; keep them few.
    pub fn expose(secret: Secret) []const u8 {
        return secret.bytes;
    }

    /// Constant-time comparison with `other` (see `eql`).
    pub fn eql(secret: Secret, other: []const u8) bool {
        return timingSafeEql(secret.bytes, other);
    }

    /// Writes `<redacted>`, whatever the format string.
    pub fn format(secret: Secret, writer: *Io.Writer) Io.Writer.Error!void {
        _ = secret;
        try writer.writeAll(redacted);
    }
};

/// The page-aligned range covering every page `memory` touches; `null` when empty.
fn outerPages(memory: []u8) ?Pages {
    if (memory.len == 0) return null;
    const page = std.heap.pageSize();
    const start = std.mem.alignBackward(usize, @intFromPtr(memory.ptr), page);
    const end = std.mem.alignForward(usize, @intFromPtr(memory.ptr) + memory.len, page);
    return pagesFrom(start, end);
}

/// The page-aligned range of pages `memory` covers entirely; `null` when there are none.
fn innerPages(memory: []u8) ?Pages {
    if (memory.len == 0) return null;
    const page = std.heap.pageSize();
    const start = std.mem.alignForward(usize, @intFromPtr(memory.ptr), page);
    const end = std.mem.alignBackward(usize, @intFromPtr(memory.ptr) + memory.len, page);
    if (start >= end) return null;
    return pagesFrom(start, end);
}

fn pagesFrom(start: usize, end: usize) Pages {
    assert(start < end);
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    return ptr[0 .. end - start];
}

fn nativeLock(pages: Pages) bool {
    switch (builtin.os.tag) {
        .windows => return windows.VirtualLock(pages.ptr, pages.len).toBool(),
        .linux => {
            const rc = std.os.linux.mlock(pages.ptr, pages.len);
            return std.os.linux.errno(rc) == .SUCCESS;
        },
        .wasi, .freestanding => return false,
        else => return std.c.mlock(pages.ptr, pages.len) == 0,
    }
}

fn nativeUnlock(pages: Pages) void {
    // Failure means the pages were not locked (a refused lock under `.best_effort`), which
    // leaves nothing to undo, so the result is ignored.
    switch (builtin.os.tag) {
        .windows => _ = windows.VirtualUnlock(pages.ptr, pages.len),
        .linux => _ = std.os.linux.munlock(pages.ptr, pages.len),
        .wasi, .freestanding => {},
        else => _ = std.c.munlock(pages.ptr, pages.len),
    }
}

fn nativeExcludeFromDump(pages: Pages) void {
    // Advisory: if the kernel refuses, the memory is still locked and wiped, so the result
    // is ignored.
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.madvise(pages.ptr, pages.len, std.os.linux.MADV.DONTDUMP),
        .freebsd, .dragonfly => _ = std.c.madvise(pages.ptr, pages.len, std.c.MADV.NOCORE),
        else => {},
    }
}

const windows = struct {
    const BOOL = std.os.windows.BOOL;
    extern "kernel32" fn VirtualLock(address: *anyopaque, size: usize) callconv(.winapi) BOOL;
    extern "kernel32" fn VirtualUnlock(address: *anyopaque, size: usize) callconv(.winapi) BOOL;
};

// Tests ---------------------------------------------------------------------------------

/// A backing allocator that records, on every free and every shrink, whether the bytes it
/// was handed back were all zero. It serves from a fixed buffer, which (unlike the testing
/// allocator) shrinks in place, and counts live allocations to catch leaks.
const Recorder = struct {
    fba: std.heap.FixedBufferAllocator,
    buffer: []u8,
    live: usize = 0,
    dirty_frees: usize = 0,
    frees: usize = 0,
    dirty_shrinks: usize = 0,
    shrinks: usize = 0,
    refuse_resize: bool = false,

    fn init(options: struct { refuse_resize: bool = false }) !Recorder {
        const buffer = try std.testing.allocator.alloc(u8, 1 << 18);
        return .{ .fba = .init(buffer), .buffer = buffer, .refuse_resize = options.refuse_resize };
    }

    /// A leak is logged as an error, which fails the test.
    fn deinit(self: *Recorder) void {
        std.testing.allocator.free(self.buffer);
        if (self.live != 0) std.log.err("{d} allocations leaked", .{self.live});
    }

    fn allocator(self: *Recorder) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = recAlloc,
            .resize = recResize,
            .remap = recRemap,
            .free = recFree,
        } };
    }

    fn recAlloc(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const ptr = self.fba.allocator().rawAlloc(len, a, ra) orelse return null;
        self.live += 1;
        return ptr;
    }

    fn recResize(ctx: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_resize) return false;
        if (new_len < memory.len) {
            self.shrinks += 1;
            if (!allZero(memory[new_len..])) self.dirty_shrinks += 1;
        }
        return self.fba.allocator().rawResize(memory, a, new_len, ra);
    }

    fn recRemap(ctx: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (recResize(ctx, memory, a, new_len, ra)) memory.ptr else null;
    }

    fn recFree(ctx: *anyopaque, memory: []u8, a: Alignment, ra: usize) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.live -= 1;
        if (!allZero(memory)) self.dirty_frees += 1;
        self.fba.allocator().rawFree(memory, a, ra);
    }

    fn allZero(bytes: []const u8) bool {
        return std.mem.allEqual(u8, bytes, 0);
    }
};

/// `Os` hooks that record calls instead of making them.
const FakeOs = struct {
    var refuse: bool = false;
    var locks: usize = 0;
    var unlocks: usize = 0;
    var excludes: usize = 0;

    fn reset(refuse_locks: bool) void {
        refuse = refuse_locks;
        locks = 0;
        unlocks = 0;
        excludes = 0;
    }

    fn lock(pages: Pages) bool {
        assert(pages.len % std.heap.pageSize() == 0);
        locks += 1;
        return !refuse;
    }

    fn unlock(pages: Pages) void {
        assert(pages.len % std.heap.pageSize() == 0);
        unlocks += 1;
    }

    fn excludeFromDump(pages: Pages) void {
        assert(pages.len > 0);
        excludes += 1;
    }

    const os: Os = .{ .lock = lock, .unlock = unlock, .exclude_from_dump = excludeFromDump };
};

test "free zeroes every byte and releases the lock" {
    FakeOs.reset(false);
    var recorder: Recorder = try .init(.{});
    defer recorder.deinit();
    var secure: SecureAllocator = .init(recorder.allocator(), .{ .os = FakeOs.os });
    const gpa = secure.allocator();

    const small = try gpa.alloc(u8, 40);
    @memset(small, 0xA5);
    gpa.free(small);
    const page = std.heap.pageSize();
    const big = try gpa.alloc(u8, 3 * page);
    @memset(big, 0x5A);
    gpa.free(big);

    try std.testing.expectEqual(2, recorder.frees);
    try std.testing.expectEqual(0, recorder.dirty_frees);
    try std.testing.expectEqual(2, FakeOs.locks);
    try std.testing.expectEqual(2, FakeOs.excludes);
    // Only the large block covers a page entirely.
    try std.testing.expectEqual(1, FakeOs.unlocks);
    try std.testing.expectEqual(0, secure.lockFailures());
}

test "shrinking resize and remap zero the released tail" {
    FakeOs.reset(false);
    var recorder: Recorder = try .init(.{});
    defer recorder.deinit();
    var secure: SecureAllocator = .init(recorder.allocator(), .{ .os = FakeOs.os });
    const gpa = secure.allocator();

    var buf = try gpa.alloc(u8, 64);
    @memset(buf, 0xFF);
    try std.testing.expect(gpa.resize(buf, 48));
    buf = buf[0..48];
    try std.testing.expectEqual(1, recorder.shrinks);
    buf = gpa.remap(buf, 40) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(2, recorder.shrinks);
    try std.testing.expectEqual(0, recorder.dirty_shrinks);
    try std.testing.expect(std.mem.allEqual(u8, buf, 0xFF));
    gpa.free(buf);
    try std.testing.expectEqual(0, recorder.dirty_frees);
}

test "a refused shrink still wipes the tail" {
    FakeOs.reset(false);
    var recorder: Recorder = try .init(.{ .refuse_resize = true });
    defer recorder.deinit();
    var secure: SecureAllocator = .init(recorder.allocator(), .{ .os = FakeOs.os });
    const gpa = secure.allocator();

    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    try std.testing.expect(!gpa.resize(buf, 4));
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 7, 0, 0, 0, 0 }, buf);
    gpa.free(buf);
    try std.testing.expectEqual(0, recorder.dirty_frees);
}

test "growth reallocates through alloc and free, wiping the old block" {
    FakeOs.reset(false);
    var recorder: Recorder = try .init(.{ .refuse_resize = true });
    defer recorder.deinit();
    var secure: SecureAllocator = .init(recorder.allocator(), .{ .os = FakeOs.os });
    const gpa = secure.allocator();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    for (0..1000) |i| try list.append(gpa, @truncate(i | 1));
    try std.testing.expectEqual(1000, list.items.len);
    try std.testing.expect(recorder.frees > 0);
    try std.testing.expectEqual(0, recorder.dirty_frees);
}

test "best_effort counts refused locks and keeps the memory" {
    FakeOs.reset(true);
    var recorder: Recorder = try .init(.{});
    defer recorder.deinit();
    var secure: SecureAllocator = .init(recorder.allocator(), .{ .os = FakeOs.os });
    const gpa = secure.allocator();

    const a = try gpa.alloc(u8, 10);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, 10);
    defer gpa.free(b);
    try std.testing.expectEqual(2, secure.lockFailures());
}

test "required fails the allocation when the lock is refused" {
    FakeOs.reset(true);
    var recorder: Recorder = try .init(.{});
    defer recorder.deinit();
    var secure: SecureAllocator = .init(recorder.allocator(), .{
        .policy = .required,
        .os = FakeOs.os,
    });
    const gpa = secure.allocator();

    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 10));
    try std.testing.expectEqual(1, recorder.frees);
    try std.testing.expectEqual(0, secure.lockFailures());

    FakeOs.reset(false);
    const buf = try gpa.alloc(u8, 10);
    defer gpa.free(buf);
    try std.testing.expect(!gpa.resize(buf, 20)); // growth never happens in place
}

test "parent of an arena, the way cfg.Config uses it" {
    FakeOs.reset(false);
    var recorder: Recorder = try .init(.{});
    defer recorder.deinit();
    var secure: SecureAllocator = .init(recorder.allocator(), .{ .os = FakeOs.os });

    // A stand-in for `cfg.Config`: an arena over the given allocator holding the secrets.
    const FakeConfig = struct {
        arena: std.heap.ArenaAllocator,
        token: []const u8 = "",

        fn init(gpa: Allocator) @This() {
            return .{ .arena = .init(gpa) };
        }

        fn load(config: *@This(), token: []const u8) !void {
            const a = config.arena.allocator();
            config.token = try a.dupe(u8, token);
            for (0..200) |_| _ = try a.dupe(u8, "padding that forces the arena to grow");
        }
    };

    var config: FakeConfig = .init(secure.allocator());
    try config.load("hunter2-but-longer");
    try std.testing.expectEqualStrings("hunter2-but-longer", config.token);
    config.arena.deinit();

    try std.testing.expect(recorder.frees > 0);
    try std.testing.expectEqual(0, recorder.dirty_frees);
}

test "native calls are safe on any memory" {
    var secure: SecureAllocator = .init(std.testing.allocator, .{});
    const gpa = secure.allocator();
    const buf = try gpa.alloc(u8, 3 * std.heap.pageSize() + 5);
    @memset(buf, 1);
    gpa.free(buf);
    // The default instance takes whole pages.
    const page_backed = try allocator().alloc(u8, 100);
    allocator().free(page_backed);
}

test "page ranges round outward to lock and inward to unlock" {
    const page = std.heap.pageSize();
    // The page size is known only at run time on some targets (aarch64: 4K to 64K), so
    // the alignment comes from `page_allocator`, which hands out whole pages.
    const block = try std.heap.page_allocator.alloc(u8, 3 * page);
    defer std.heap.page_allocator.free(block);

    const middle = block[10 .. 2 * page + 10];
    try std.testing.expectEqual(3 * page, outerPages(middle).?.len);
    try std.testing.expectEqual(page, innerPages(middle).?.len);
    try std.testing.expectEqual(null, innerPages(block[1 .. page + 1]));
    try std.testing.expectEqual(null, outerPages(block[0..0]));
}

test wipe {
    var bytes = "secret".*;
    wipe(&bytes);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0));
}

test eql {
    try std.testing.expect(eql("abc", "abc"));
    try std.testing.expect(!eql("abc", "abd"));
    try std.testing.expect(!eql("abc", "ab"));
    try std.testing.expect(eql("", ""));
}

test Secret {
    var secret: Secret = try .init(std.testing.allocator, "s3cr3t");
    defer secret.deinit();
    try std.testing.expectEqualStrings("s3cr3t", secret.expose());
    try std.testing.expect(secret.eql("s3cr3t"));
    try std.testing.expect(!secret.eql("s3cr3x"));

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "token={f}", .{secret});
    try std.testing.expectEqualStrings("token=<redacted>", text);
}
