const std = @import("std");

/// The shared spin lock, from `lib/util`. This file used to carry its own
/// thirteen-line copy, which was the same algorithm with the scheduler yield and
/// `tryLock` left out - two implementations of one primitive is a correctness
/// risk, not a tidy-up (`AGENT.md` 4.2, `ROADMAP.md` R-2). `cli` already imports
/// the `util` module, so the copy was pure loss.
const SpinLock = @import("util").spin_lock;

pub const Bar = struct {
    label: []const u8,
    total: u64,
    current: u64 = 0,
    done: bool = false,
    color: []const u8 = "\x1b[36m", // Cyan
};

pub const MultiProgress = struct {
    bars: std.ArrayList(Bar),
    lock: SpinLock = .{},
    allocator: std.mem.Allocator,
    rendered_lines: usize = 0,
    width: usize = 30,

    pub fn init(allocator: std.mem.Allocator) MultiProgress {
        return .{
            .bars = std.ArrayList(Bar).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MultiProgress) void {
        self.bars.deinit(self.allocator);
    }

    pub fn addBar(self: *MultiProgress, label: []const u8, total: u64) !usize {
        self.lock.lock();
        defer self.lock.unlock();

        const id = self.bars.items.len;
        try self.bars.append(self.allocator, .{
            .label = label,
            .total = total,
        });
        return id;
    }

    pub fn update(self: *MultiProgress, id: usize, delta: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (id < self.bars.items.len) {
            self.bars.items[id].current = @min(self.bars.items[id].current + delta, self.bars.items[id].total);
            if (self.bars.items[id].current >= self.bars.items[id].total) {
                self.bars.items[id].done = true;
            }
        }
    }

    pub fn set(self: *MultiProgress, id: usize, value: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (id < self.bars.items.len) {
            self.bars.items[id].current = @min(value, self.bars.items[id].total);
            if (self.bars.items[id].current >= self.bars.items[id].total) {
                self.bars.items[id].done = true;
            }
        }
    }

    pub fn isAllDone(self: *MultiProgress) bool {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.bars.items) |b| {
            if (!b.done) return false;
        }
        return self.bars.items.len > 0;
    }

    /// Renders all progress bars. Uses ANSI cursor movement to redraw in-place without screen tearing.
    pub fn render(self: *MultiProgress, writer: anytype) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.rendered_lines > 0) {
            try writer.print("\x1b[{d}A", .{self.rendered_lines});
        }

        for (self.bars.items) |b| {
            try writer.writeAll("\x1b[2K\r");

            const pct: usize = if (b.total > 0) @intCast((b.current * 100) / b.total) else 0;
            const filled: usize = if (b.total > 0) @intCast((b.current * self.width) / b.total) else 0;

            try writer.print(" {s:16.16} {s}[", .{ b.label, b.color });
            for (0..filled) |_| try writer.writeAll("=");
            if (filled < self.width) {
                try writer.writeAll(">");
                for (filled + 1..self.width) |_| try writer.writeAll(" ");
            }
            try writer.print("\x1b[0m] {d:3}% ({d}/{d})", .{ pct, b.current, b.total });
            if (b.done) {
                try writer.writeAll(" \x1b[32m✓\x1b[0m\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        self.rendered_lines = self.bars.items.len;
    }
};
