//! Several labelled progress bars, one per task, each finishing on its own.
//!
//! ```zig
//! var tasks = [_]MultiProgress.Task{
//!     .{ .label = "download", .bar = .{ .total = 100 } },
//!     .{ .label = "unpack", .bar = .{ .total = 20 } },
//! };
//! var multi: MultiProgress = .{ .tasks = &tasks };
//! // as a program: send `.app = .{ .task = 0, .sample = .{ .current = 40, .at = now } }`
//! ```
//!
//! A finished task shows `done` in place of its estimate. With `quit_when_done`, the
//! program ends when every task has.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;
const progress = @import("progress.zig");

pub const MultiProgress = struct {
    /// The caller's; the bars are updated in place.
    tasks: []Task,
    quit_when_done: bool = false,
    styles: Styles = .{},

    pub const Task = struct {
        label: []const u8,
        bar: progress.Progress,
    };

    pub const Styles = struct {
        label: tui.Style = .{ .bold = true },
        done: tui.Style = .{ .fg = .{ .indexed = 78 } },
    };

    /// Progress of one task.
    pub const Message = struct { task: usize, sample: progress.Sample };

    pub fn update(multi: *MultiProgress, msg: tui.Message(Message)) tui.Cmd {
        switch (msg) {
            .app => |m| {
                if (m.task < multi.tasks.len) {
                    multi.tasks[m.task].bar.set(m.sample.current, m.sample.at);
                }
                if (multi.quit_when_done and multi.done()) return .quit;
            },
            else => {},
        }
        return .none;
    }

    /// Whether every task is finished.
    pub fn done(multi: *const MultiProgress) bool {
        for (multi.tasks) |task| if (task.bar.current < task.bar.total) return false;
        return true;
    }

    pub fn view(multi: *const MultiProgress, w: *Writer) Writer.Error!void {
        var label_width: usize = 0;
        for (multi.tasks) |task| label_width = @max(label_width, tui.width.of(task.label));
        for (multi.tasks, 0..) |task, i| {
            if (i > 0) try w.writeByte('\n');
            try multi.styles.label.paint(w, task.label);
            try w.splatByteAll(' ', label_width - tui.width.of(task.label) + 1);
            var bar = task.bar;
            const finished = bar.current >= bar.total;
            if (finished) bar.show_eta = false;
            try bar.view(w);
            if (finished) {
                try w.writeByte(' ');
                try multi.styles.done.paint(w, "done");
            }
        }
    }
};

const testing = std.testing;

fn at(seconds: i64) std.Io.Timestamp {
    return std.Io.Timestamp.zero.addDuration(.fromSeconds(seconds));
}

test "each task fills on its own, and the program quits when all are done" {
    const plain: progress.Progress.Styles = .{ .full = .{}, .empty = .{} };
    var tasks = [_]MultiProgress.Task{
        .{
            .label = "get",
            .bar = .{ .total = 2, .width = 4, .full = "#", .empty = ".", .styles = plain },
        },
        .{
            .label = "unpack",
            .bar = .{ .total = 1, .width = 4, .full = "#", .empty = ".", .styles = plain },
        },
    };
    var d: tui.testing.Driver(MultiProgress) = try .init(testing.allocator, .{
        .tasks = &tasks,
        .quit_when_done = true,
        .styles = .{ .label = .{}, .done = .{} },
    }, .{});
    defer d.deinit();
    try d.expectFrame("get    ....   0%\nunpack ....   0%");
    try d.send(.{ .app = .{ .task = 1, .sample = .{ .current = 1, .at = at(1) } } });
    try d.expectFrame("get    ....   0%\nunpack #### 100% done");
    try testing.expect(!d.done());
    try d.send(.{ .app = .{ .task = 0, .sample = .{ .current = 2, .at = at(2) } } });
    try testing.expect(d.done());
    try d.expectFrame("get    #### 100% done\nunpack #### 100% done");
}
