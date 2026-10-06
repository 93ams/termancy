//! A simple spin lock for control-plane critical sections.
//!
//! This file **is** the type: the file's own scope is `SpinLock`, so a consumer
//! writes `const SpinLock = @import("spin_lock.zig");`. See the file-layout rule
//! in `.agents/AGENTS.md`.
//!
//! The data plane must never take locks (see AGENTS.md), but control-plane paths
//! (subscription maps, write buffers, reconnect) need short critical sections that
//! do not depend on an `std.Io` context. This lock uses an atomic flag with
//! bounded spinning + thread yield; it requires no OS primitives, so it works in
//! unit tests and embedded contexts alike.
//!
//! **On the test variable names below:** at file scope the `lock` method and a
//! local `var lock` collide (`error: local variable shadows declaration of
//! 'lock'`). The tests therefore name their instances `sl`. Renaming the method
//! would be a worse trade - `lock.lock()` is the shipped spelling.

const std = @import("std");

const Self = @This();

locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// Acquires the lock, spinning with a bounded backoff that yields to the
/// scheduler so a contended lock does not starve other threads.
pub fn lock(self: *Self) void {
    var spins: u32 = 0;
    while (self.locked.swap(true, .acquire)) {
        spins += 1;
        if (spins < 64) {
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
            spins = 0;
        }
    }
}

/// Acquires the lock if free. Returns true on success.
pub fn tryLock(self: *Self) bool {
    return !self.locked.swap(true, .acquire);
}

/// Releases the lock.
pub fn unlock(self: *Self) void {
    self.locked.store(false, .release);
}

const testing = std.testing;

test "SpinLock mutual exclusion" {
    var sl: Self = .{};
    sl.lock();
    try testing.expect(!sl.tryLock());
    sl.unlock();
    try testing.expect(sl.tryLock());
    sl.unlock();
}

test "SpinLock concurrent increment" {
    var sl: Self = .{};
    var counter: usize = 0;
    const ThreadCount = 8;
    const Increments = 1000;

    const Worker = struct {
        fn run(l: *Self, c: *usize) void {
            for (0..Increments) |_| {
                l.lock();
                c.* += 1;
                l.unlock();
            }
        }
    };

    var threads: [ThreadCount]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &sl, &counter });
    for (&threads) |*t| t.join();

    try testing.expectEqual(@as(usize, ThreadCount * Increments), counter);
}
