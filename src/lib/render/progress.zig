const std = @import("std");
const capability = @import("capability.zig");

/// The shared spin lock, from `src/lib/util`. This file used to carry its own
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
    /// Whether this bar has already been announced on a stream that cannot be
    /// redrawn. Unused when cursor movement is available.
    reported: bool = false,
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
    ///
    /// When the process capability says cursor movement is unavailable - the
    /// output is a pipe, or `TERM=dumb` - redrawing is impossible, because the
    /// cursor-up sequence is exactly what would be redrawn over. Rather than
    /// emitting the sequences anyway and filling a log with them, each bar is
    /// announced **once**, when it completes.
    pub fn render(self: *MultiProgress, writer: anytype) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (!capability.get().cursor) return self.renderPlain(writer);

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

    /// The append-only form used when the cursor cannot be moved.
    ///
    /// Bounded by construction: a bar is announced at most once, so a caller that
    /// renders in a loop cannot grow the output without bound.
    fn renderPlain(self: *MultiProgress, writer: anytype) !void {
        for (self.bars.items) |*bar| {
            if (!bar.done or bar.reported) continue;
            bar.reported = true;

            const pct: usize = if (bar.total > 0)
                @intCast((bar.current * 100) / bar.total)
            else
                0;
            try writer.print("{s}: {d}% ({d}/{d})\n", .{
                bar.label, pct, bar.current, bar.total,
            });
        }
    }
};

const testing = std.testing;

/// Installs a capability for the duration of `body`, restoring it afterwards.
///
/// Process-wide state in a test is a leak waiting to happen: without the restore,
/// whichever test ran last would decide how every later test renders.
fn withCapability(caps: capability.Capability, body: anytype) !void {
    const saved = capability.get();
    defer capability.set(saved);

    capability.set(caps);
    try body();
}

test "a completed bar is announced exactly once when the cursor cannot move" {
    try withCapability(.{ .color = false, .cursor = false, .interactive = false }, struct {
        fn run() !void {
            var mp = MultiProgress.init(testing.allocator);
            defer mp.deinit();

            const id = try mp.addBar("fetch", 10);
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);

            // In progress: nothing is printed, because there is no way to redraw
            // an in-progress bar on a stream you cannot move the cursor on.
            try mp.render(&w);
            try testing.expectEqual(@as(usize, 0), w.buffered().len);

            mp.set(id, 10);
            try mp.render(&w);
            try testing.expectEqualStrings("fetch: 100% (10/10)\n", w.buffered());

            // And a second render does not repeat it. That bound is the whole
            // reason this mode is append-only rather than re-rendering.
            try mp.render(&w);
            try testing.expectEqualStrings("fetch: 100% (10/10)\n", w.buffered());
        }
    }.run);
}

test "an unfinished bar stays silent on a stream that cannot be redrawn" {
    try withCapability(.{ .color = false, .cursor = false, .interactive = false }, struct {
        fn run() !void {
            var mp = MultiProgress.init(testing.allocator);
            defer mp.deinit();

            const id = try mp.addBar("fetch", 4);
            mp.set(id, 3);

            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try mp.render(&w);
            try testing.expectEqual(@as(usize, 0), w.buffered().len);
        }
    }.run);
}

test "the redrawing form still emits the bar when the cursor can move" {
    try withCapability(.{ .color = true, .cursor = true, .interactive = true }, struct {
        fn run() !void {
            var mp = MultiProgress.init(testing.allocator);
            defer mp.deinit();

            const id = try mp.addBar("fetch", 4);
            mp.set(id, 2);

            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try mp.render(&w);

            const out = w.buffered();
            try testing.expect(std.mem.indexOf(u8, out, "fetch") != null);
            try testing.expect(std.mem.indexOf(u8, out, "50%") != null);
            // It redraws in place, so the line is cleared first.
            try testing.expect(std.mem.indexOf(u8, out, "\x1b[2K") != null);
            // And the bar was never announced in the append-only form.
            try testing.expect(!mp.bars.items[0].reported);
        }
    }.run);
}
