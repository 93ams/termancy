//! Spinners, progress bars, and step lists for plain command-line output: redrawn in place
//! at a terminal, written as plain lines everywhere else. No event loop: `tui.Program` is
//! not involved, so a `cli` command can show one between two `print`s.
//!
//! ```zig
//! var bar: live.Bar = .{ .label = "download", .total = size, .units = .bytes };
//! const items = [_]live.Item{.{ .bar = &bar }};
//! var display: live.Live = .detect(io, environ, .stderr(), err, &items);
//! try display.draw(.now(io, .awake));
//! while (try next(&chunk)) |n| {
//!     bar.add(n);
//!     try display.tick(.now(io, .awake)); // draws when `interval` has passed
//! }
//! bar.finish(.success);
//! try display.finish(.now(io, .awake));
//! ```
//!
//! A `Live` draws its `items` (a `Spinner`, `Bar`, `Text`, or `Steps` list, one line each,
//! a line per step for `Steps`) in one of two ways:
//!
//! - animated (`animate`): the lines are redrawn in place with the cursor hidden, each frame
//!   one synchronized update (mode 2026), each line cut to the terminal's width (read again
//!   every frame when `file` is set) and the list to its height. `print` writes lines
//!   above them.
//! - otherwise: a line for each change worth a log line: an item seen for the first time,
//!   a spinner's new title, a bar crossing a quarter, a step changing state, the outcome.
//!
//! Nothing runs by itself. `tick(now)` draws when `interval` has passed since the last
//! frame, `draw(now)` draws at once. `start(io)` animates on a task of its own
//! (`io.concurrent`) until `finish` or `clear`. Code that changes the items from several
//! tasks, or while `start`'s task may be running, does it through `update`, which locks
//! and ticks as needed. The clock is the caller's: every call takes `now`, so tests pass
//! the times they like.
//!
//! While an animation hides the cursor on a terminal (`file`), a SIGINT, SIGTERM, SIGHUP,
//! or SIGQUIT that would end the process (its action is the default) first ends the
//! synchronized update, shows the cursor, and leaves the line; then the process ends as it
//! would have. A signal the program handles itself is left to it: it stops and calls
//! `finish` or `clear`. `finish` and `clear` put the default actions back. On Windows,
//! Ctrl-C, Ctrl-Break, and closing the console do the same through a console control
//! handler, which passes the event on; a handler the program installed after `start`
//! runs first, and one that handles the event keeps the process (and the cursor) going.

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const capability = @import("capability.zig");
const width = @import("width.zig");
const Style = @import("Style.zig");
const Terminal = @import("Terminal.zig");
const Color = ansi.Color;
const Io = std.Io;
const Writer = Io.Writer;
const Duration = Io.Duration;
const Timestamp = Io.Timestamp;

/// Spinner frame sets.
pub const frames = struct {
    pub const dots = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    /// gum's `dot`.
    pub const dot = [_][]const u8{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" };
    pub const line = [_][]const u8{ "-", "\\", "|", "/" };
    pub const mini_dot = [_][]const u8{ "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" };
    pub const points = [_][]const u8{ "∙∙∙", "●∙∙", "∙●∙", "∙∙●" };
    pub const pulse = [_][]const u8{ "█", "▓", "▒", "░" };
    pub const globe = [_][]const u8{ "🌍", "🌎", "🌏" };
    pub const moon = [_][]const u8{ "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" };
    pub const jump = [_][]const u8{ "⢄", "⢂", "⢁", "⡁", "⡈", "⡐", "⡠" };
    pub const meter = [_][]const u8{ "▱▱▱", "▰▱▱", "▰▰▱", "▰▰▰", "▰▰▱", "▰▱▱", "▱▱▱" };
    pub const hamburger = [_][]const u8{ "☱", "☲", "☴", "☲" };
    pub const ellipsis = [_][]const u8{ "   ", ".  ", ".. ", "..." };
    pub const monkey = [_][]const u8{ "🙈", "🙉", "🙊" };
    pub const arc = [_][]const u8{ "◜", "◠", "◝", "◞", "◡", "◟" };
    pub const bounce = [_][]const u8{ "⠁", "⠂", "⠄", "⠂" };
    pub const circle = [_][]const u8{ "◐", "◓", "◑", "◒" };
    pub const arrow = [_][]const u8{ "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" };
    pub const bouncing_bar = [_][]const u8{
        "[    ]", "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]",
        "[   =]", "[  ==]", "[ ===]", "[====]", "[=== ]", "[==  ]",
    };
};

/// How something ended, and the symbol that says so.
pub const Status = enum {
    success,
    failure,
    warning,
    info,

    /// `✓ ✗ ! i`, or `+ x ! i` in ASCII.
    pub fn symbol(status: Status, ascii: bool) []const u8 {
        return switch (status) {
            .success => if (ascii) "+" else "✓",
            .failure => if (ascii) "x" else "✗",
            .warning => "!",
            .info => "i",
        };
    }

    /// The color the status is shown in.
    pub fn style(status: Status) Style {
        return .{ .fg = switch (status) {
            .success => .green,
            .failure => .red,
            .warning => .yellow,
            .info => .blue,
        } };
    }
};

/// What a line is drawn with.
pub const Frame = struct {
    now: Timestamp,
    /// Redrawn in place: spinners turn. Otherwise a spinner shows `→` (`>` in ASCII).
    animate: bool = true,
    ascii: bool = false,
    color: capability.Color = .truecolor,
    /// The width a bar that fills the line fills.
    columns: usize = 80,

    fn paint(f: Frame, w: *Writer, style: Style, text: []const u8) Writer.Error!void {
        try f.lower(style).paint(w, text);
    }

    /// `style` as the output can show it: nothing at all without color.
    fn lower(f: Frame, style: Style) Style {
        return if (f.color == .none) .{} else style.lowered(f.color);
    }

    fn running(f: Frame) []const u8 {
        return if (f.ascii) ">" else "→";
    }
};

/// The time from `started` to `ended`, or to `now` while running.
fn elapsed(started: ?Timestamp, ended: ?Timestamp, now: Timestamp) Duration {
    const from = started orelse return .zero;
    const to = ended orelse now;
    return .fromNanoseconds(@max(from.durationTo(to).nanoseconds, 0));
}

/// Records the first frame, and the first after the end.
fn stamp(started: *?Timestamp, ended: *?Timestamp, done: bool, now: Timestamp) void {
    if (started.* == null) started.* = now;
    if (done and ended.* == null) ended.* = now;
}

fn isAscii(set: []const []const u8) bool {
    for (set) |frame| for (frame) |c| if (c >= 0x80) return false;
    return true;
}

/// What a log line is keyed on: an outcome, a text, and a number.
fn hash(outcome: ?Status, text: []const u8, n: u8) u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(&.{ if (outcome) |o| @backingInt(o) + 1 else 0, n });
    h.update(text);
    return h.final() | 1; // never 0, which means "not logged yet"
}

/// A spinner with a title, for work of unknown length.
pub const Spinner = struct {
    frames: []const []const u8 = &frames.dots,
    /// Time between frames.
    interval: Duration = .fromMilliseconds(80),
    title: []const u8 = "",
    /// Written after the title, unstyled.
    suffix: []const u8 = "",
    /// The time since the first frame, in parentheses after the title: `(2.50s)`.
    show_elapsed: bool = false,
    style: Style = .{ .fg = .{ .indexed = 212 } },
    title_style: Style = .{},
    /// Set by `finish`; the spinner shows its symbol from then on.
    outcome: ?Status = null,
    started: ?Timestamp = null,
    ended: ?Timestamp = null,
    logged: u64 = 0,

    /// Stops the spinner with `outcome`'s symbol, and `title` in place of its own if given.
    pub fn finish(s: *Spinner, outcome: Status, title: ?[]const u8) void {
        s.outcome = outcome;
        if (title) |t| s.title = t;
    }

    /// The frame shown at `now`: one per `interval` since the first frame.
    pub fn frameAt(s: *const Spinner, now: Timestamp, ascii: bool) []const u8 {
        const set = if (ascii and !isAscii(s.frames)) &frames.line else s.frames;
        const ns = elapsed(s.started, null, now).nanoseconds;
        const step = @divTrunc(ns, @max(s.interval.nanoseconds, 1));
        return set[@intCast(@mod(step, set.len))];
    }

    /// Writes the spinner's line for frame `f`.
    pub fn writeLine(s: *Spinner, w: *Writer, f: Frame) Writer.Error!void {
        stamp(&s.started, &s.ended, s.outcome != null, f.now);
        if (s.outcome) |outcome| {
            try f.paint(w, outcome.style(), outcome.symbol(f.ascii));
        } else {
            try f.paint(w, s.style, if (f.animate) s.frameAt(f.now, f.ascii) else f.running());
        }
        if (s.title.len > 0) {
            try w.writeByte(' ');
            try f.paint(w, s.title_style, s.title);
        }
        if (s.suffix.len > 0) try w.print(" {s}", .{s.suffix});
        if (s.show_elapsed) {
            try w.writeAll(" (");
            try writeElapsed(w, elapsed(s.started, s.ended, f.now));
            try w.writeByte(')');
        }
    }

    fn key(s: *const Spinner) u64 {
        return hash(s.outcome, s.title, 0);
    }
};

/// The glyphs of a bar.
pub const Cells = struct {
    full: []const u8 = "█",
    empty: []const u8 = "░",
    /// Cells filled in part, smallest first: with n of them a cell fills in n+1 steps.
    partial: []const []const u8 = &.{},

    /// Whole blocks, filling in eighths of a cell.
    pub const blocks: Cells = .{ .partial = &.{ "▏", "▎", "▍", "▌", "▋", "▊", "▉" } };
    /// Whole blocks only.
    pub const block: Cells = .{};
    /// A thin line.
    pub const thin: Cells = .{ .full = "━", .empty = "─", .partial = &.{"╸"} };
    /// ASCII only.
    pub const ascii: Cells = .{ .full = "#", .empty = "-" };

    fn isAsciiOnly(cells: Cells) bool {
        return isAscii(&.{ cells.full, cells.empty }) and isAscii(cells.partial);
    }
};

/// The styles `writeCells` fills with.
pub const Fill = struct {
    full: Style = .{},
    empty: Style = .{},
    /// Colors the filled cells blend through (two or more), in place of `full`'s.
    gradient: []const Color = &.{},
    /// Spread `gradient` over the filled part rather than the whole bar.
    scale_gradient: bool = false,
    /// What the gradient's colors are lowered to; no gradient at `.none`.
    level: capability.Color = .truecolor,
};

/// Writes `columns` cells of a bar `fraction` (0 to 1) full: whole cells, then one partial
/// cell, then empty ones.
pub fn writeCells(
    w: *Writer,
    fraction: f64,
    columns: usize,
    cells: Cells,
    fill: Fill,
) Writer.Error!void {
    const span_columns: f64 = @floatFromInt(columns);
    const exact = std.math.clamp(fraction, 0, 1) * span_columns;
    const filled: usize = @intFromFloat(@floor(exact));
    const steps: f64 = @floatFromInt(cells.partial.len + 1);
    const part: usize = @intFromFloat(@floor((exact - @floor(exact)) * steps));
    const partial: usize = @intFromBool(part > 0 and filled < columns);
    var styled = false;
    if (fill.gradient.len > 1 and fill.level != .none) {
        const span: f64 = if (fill.scale_gradient) @max(exact, 1) else span_columns;
        for (0..filled + partial) |i| {
            const t: f32 = @floatCast(@as(f64, @floatFromInt(i)) / @max(span - 1, 1));
            const cell: Style = .{ .fg = Color.along(fill.gradient, t).downsample(fill.level) };
            try cell.writeSgr(w);
            try w.writeAll(if (i < filled) cells.full else cells.partial[part - 1]);
        }
        styled = filled + partial > 0;
    } else {
        styled = fill.full.hasSgr() and filled + partial > 0;
        if (styled) try fill.full.writeSgr(w);
        try w.splatBytesAll(cells.full, filled);
        if (partial > 0) try w.writeAll(cells.partial[part - 1]);
    }
    const empty = columns - filled - partial;
    const empty_styled = fill.empty.hasSgr() and empty > 0;
    if (styled and empty_styled) try w.writeAll(ansi.reset);
    if (empty_styled) try fill.empty.writeSgr(w);
    try w.splatBytesAll(cells.empty, empty);
    if (styled or empty_styled) try w.writeAll(ansi.reset);
}

/// A progress bar: of a known total, or (`total` null) of work whose size is not known,
/// where a segment sweeps across while animated.
pub const Bar = struct {
    /// Null when unknown.
    total: ?u64 = null,
    current: u64 = 0,
    label: []const u8 = "",
    /// Columns of the bar itself; null fills what the line leaves.
    width: ?usize = 30,
    /// `Cells.ascii` in ASCII.
    cells: Cells = .blocks,
    style: Style = .{ .fg = .{ .indexed = 212 } },
    empty_style: Style = .{ .fg = .{ .indexed = 238 } },
    /// Colors the filled cells blend through, in place of `style`'s.
    gradient: []const Color = &.{},
    /// The label and the numbers.
    text_style: Style = .{},
    show_percent: bool = true,
    /// `3/10`, or `1.5MiB/10.0MiB` for bytes.
    show_count: bool = false,
    /// `2.5/s`, or `1.5MiB/s` for bytes.
    show_rate: bool = false,
    show_eta: bool = true,
    show_elapsed: bool = false,
    units: Units = .items,
    /// Set by `finish`.
    outcome: ?Status = null,
    started: ?Timestamp = null,
    ended: ?Timestamp = null,
    logged: u64 = 0,

    /// What `current` and `total` count.
    pub const Units = enum { items, bytes };

    /// `current` is `n`, at most `total`.
    pub fn set(b: *Bar, n: u64) void {
        b.current = if (b.total) |total| @min(n, total) else n;
    }

    /// `n` more done.
    pub fn add(b: *Bar, n: u64) void {
        b.set(b.current +| n);
    }

    /// Ends the bar with `outcome`'s symbol before it; a success fills it.
    pub fn finish(b: *Bar, outcome: Status) void {
        b.outcome = outcome;
        if (outcome == .success) {
            if (b.total) |total| b.current = total;
        }
    }

    /// The part done, from 0 to 1; null when the total is unknown.
    pub fn fraction(b: *const Bar) ?f64 {
        const total = b.total orelse return null;
        if (total == 0) return 1;
        return @as(f64, @floatFromInt(b.current)) / @as(f64, @floatFromInt(total));
    }

    /// The time left at the rate so far, or null before any progress.
    pub fn eta(b: *const Bar, so_far: Duration) ?Duration {
        const total = b.total orelse return null;
        if (b.current == 0 or so_far.nanoseconds <= 0) return null;
        const left: i96 = @intCast(total - b.current);
        return .fromNanoseconds(@divTrunc(so_far.nanoseconds * left, b.current));
    }

    /// Writes the bar's line for frame `f`.
    pub fn writeLine(b: *Bar, w: *Writer, f: Frame) Writer.Error!void {
        stamp(&b.started, &b.ended, b.outcome != null, f.now);
        const so_far = elapsed(b.started, b.ended, f.now);
        var suffix_buffer: [160]u8 = undefined;
        var suffix: Writer = .fixed(&suffix_buffer);
        b.writeNumbers(&suffix, so_far) catch {};
        const numbers = suffix.buffered();
        const show_cells = b.total != null or f.animate;

        var lead: usize = 0;
        if (b.outcome) |outcome| {
            try f.paint(w, outcome.style(), outcome.symbol(f.ascii));
            lead += width.of(outcome.symbol(f.ascii)) + 1;
        }
        if (b.label.len > 0) {
            if (lead > 0) try w.writeByte(' ');
            try f.paint(w, b.text_style, b.label);
            lead += width.of(b.label) + 1;
        }
        if (show_cells) {
            if (lead > 0) try w.writeByte(' ');
            const rest = lead + (if (numbers.len > 0) width.of(numbers) + 1 else 0);
            const columns = b.width orelse @max(f.columns -| rest, 5);
            const cells = if (f.ascii and !b.cells.isAsciiOnly()) Cells.ascii else b.cells;
            const fill: Fill = .{
                .full = f.lower(b.style),
                .empty = f.lower(b.empty_style),
                .gradient = b.gradient,
                .level = f.color,
            };
            if (b.fraction()) |done| {
                try writeCells(w, done, columns, cells, fill);
            } else {
                try writeSweep(w, columns, so_far, cells, fill);
            }
        }
        if (numbers.len > 0) {
            if (lead > 0 or show_cells) try w.writeByte(' ');
            try f.paint(w, b.text_style, numbers);
        }
    }

    /// The percentage, count, rate, estimate, and time, as `show_*` ask, space-separated.
    fn writeNumbers(b: *const Bar, w: *Writer, so_far: Duration) Writer.Error!void {
        var sep: []const u8 = "";
        if (b.show_percent) {
            if (b.fraction()) |done| {
                try w.print("{d:>3}%", .{@as(u8, @intFromFloat(@floor(done * 100)))});
                sep = " ";
            }
        }
        if (b.show_count) {
            try w.writeAll(sep);
            sep = " ";
            switch (b.units) {
                .items => try w.print("{d}", .{b.current}),
                .bytes => try w.print("{Bi:.1}", .{b.current}),
            }
            if (b.total) |total| switch (b.units) {
                .items => try w.print("/{d}", .{total}),
                .bytes => try w.print("/{Bi:.1}", .{total}),
            };
        }
        const seconds = @as(f64, @floatFromInt(so_far.nanoseconds)) / std.time.ns_per_s;
        if (b.show_rate and seconds > 0) {
            const rate = @as(f64, @floatFromInt(b.current)) / seconds;
            try w.writeAll(sep);
            sep = " ";
            switch (b.units) {
                .items => try w.print("{d:.1}/s", .{rate}),
                .bytes => try w.print("{Bi:.1}/s", .{@as(u64, @intFromFloat(rate))}),
            }
        }
        if (b.show_eta and b.outcome == null) {
            if (b.eta(so_far)) |left| {
                try w.print("{s}ETA ", .{sep});
                sep = " ";
                try writeEta(w, left);
            }
        }
        if (b.show_elapsed) {
            try w.writeAll(sep);
            try writeElapsed(w, so_far);
        }
    }
};

/// A quarter of the bar sweeping back and forth, a column every 80ms.
fn writeSweep(
    w: *Writer,
    columns: usize,
    so_far: Duration,
    cells: Cells,
    fill: Fill,
) Writer.Error!void {
    if (columns == 0) return;
    const segment = @max(columns / 4, 1);
    const travel = columns - segment;
    const step: usize = @intCast(@divTrunc(so_far.nanoseconds, 80 * std.time.ns_per_ms));
    const phase = step % @max(2 * travel, 1);
    const at = if (phase > travel) 2 * travel - phase else phase;
    const empty = fill.empty.hasSgr();
    try fill.empty.writeSgr(w);
    try w.splatBytesAll(cells.empty, at);
    if (empty) try w.writeAll(ansi.reset);
    try fill.full.writeSgr(w);
    try w.splatBytesAll(cells.full, segment);
    if (fill.full.hasSgr()) try w.writeAll(ansi.reset);
    try fill.empty.writeSgr(w);
    try w.splatBytesAll(cells.empty, columns - segment - at);
    if (empty) try w.writeAll(ansi.reset);
}

/// A line of text, which the caller may change between frames.
pub const Text = struct {
    /// One line: no `\n`.
    text: []const u8 = "",
    style: Style = .{},
    logged: u64 = 0,

    /// Writes the text for frame `f`.
    pub fn writeLine(t: *const Text, w: *Writer, f: Frame) Writer.Error!void {
        try f.paint(w, t.style, t.text);
    }
};

/// A checklist of named steps, a line each, for installers and the like: the running ones
/// spin, the others show their state.
pub const Steps = struct {
    /// The caller's; change a step's `state` (and `note`) as the work goes.
    items: []Step,
    /// Frames, interval, and style of the running steps.
    spinner: Spinner = .{},
    pending_style: Style = .{ .dim = true },
    /// After a step's name.
    note_style: Style = .{ .dim = true },

    /// Where a step is.
    pub const State = enum { pending, running, done, failed, skipped };

    /// One step: its name, state, and a note after it.
    pub const Step = struct {
        name: []const u8,
        state: State = .pending,
        /// Written after the name; none when empty.
        note: []const u8 = "",
        logged: ?State = null,
    };

    /// Writes step `index`'s line for frame `f`.
    pub fn writeStep(s: *Steps, w: *Writer, f: Frame, index: usize) Writer.Error!void {
        stamp(&s.spinner.started, &s.spinner.ended, false, f.now);
        const step = s.items[index];
        switch (step.state) {
            .pending => try f.paint(w, s.pending_style, if (f.ascii) "." else "·"),
            .running => try f.paint(
                w,
                s.spinner.style,
                if (f.animate) s.spinner.frameAt(f.now, f.ascii) else f.running(),
            ),
            .done => try f.paint(w, Status.success.style(), Status.success.symbol(f.ascii)),
            .failed => try f.paint(w, Status.failure.style(), Status.failure.symbol(f.ascii)),
            .skipped => try f.paint(w, s.pending_style, "-"),
        }
        try w.writeByte(' ');
        const quiet = step.state == .pending or step.state == .skipped;
        try f.paint(w, if (quiet) s.pending_style else .{}, step.name);
        if (step.note.len > 0) {
            try w.writeByte(' ');
            try f.paint(w, s.note_style, step.note);
        }
    }
};

/// One thing a `Live` draws.
pub const Item = union(enum) {
    spinner: *Spinner,
    bar: *Bar,
    text: *Text,
    steps: *Steps,

    fn lines(item: Item) usize {
        return switch (item) {
            .steps => |s| s.items.len,
            else => 1,
        };
    }

    fn writeLine(item: Item, w: *Writer, f: Frame, index: usize) Writer.Error!void {
        switch (item) {
            .steps => |s| try s.writeStep(w, f, index),
            inline else => |it| try it.writeLine(w, f),
        }
    }

    /// Writes, a line each, what changed since it was last logged.
    fn log(item: Item, w: *Writer, f: Frame) Writer.Error!void {
        const logged: *u64, const key = switch (item) {
            .spinner => |s| .{ &s.logged, s.key() },
            .bar => |b| .{ &b.logged, hash(
                b.outcome,
                b.label,
                if (b.fraction()) |done| @intFromFloat(@floor(done * 4)) else 0,
            ) },
            .text => |t| .{ &t.logged, hash(null, t.text, 0) },
            .steps => |s| {
                for (s.items, 0..) |*step, i| {
                    if (step.state == .pending or step.logged == step.state) continue;
                    step.logged = step.state;
                    try s.writeStep(w, f, i);
                    try w.writeByte('\n');
                }
                return;
            },
        };
        if (logged.* == key) return;
        logged.* = key;
        try item.writeLine(w, f, 0);
        try w.writeByte('\n');
    }
};

/// The longest line drawn; anything past it is lost.
const line_max = 2048;

/// Lines redrawn in place, or logged as they change. See the top of the file.
pub const Live = struct {
    out: *Writer,
    /// The caller's, in a variable that outlives the `Live`.
    items: []const Item,
    /// Redraw in place; otherwise log changes as lines.
    animate: bool,
    color: capability.Color = .none,
    /// ASCII spinners, bars, and symbols.
    ascii: bool = false,
    /// Whether the terminal rewraps lines when it narrows (`Capability.reflows`).
    reflows: bool = true,
    /// The terminal's size when `file` cannot say; a height of 0 limits nothing.
    columns: u16 = 80,
    rows: u16 = 0,
    /// The terminal whose size is read before each animated frame.
    file: ?Io.File = null,
    io: ?Io = null,
    /// The least time between two frames `tick` draws.
    interval: Duration = .fromMilliseconds(50),

    /// Rows on the screen now; the cursor is on the last.
    drawn: usize = 0,
    /// The columns each drawn row takes, for `toTop` once the terminal narrows and rewraps
    /// them. shortcut: rows past the first 256 count as one each; enough while `rows`
    /// keeps a frame to the terminal's height.
    widths: [256]u16 = undefined,
    last: ?Timestamp = null,
    cursor_hidden: bool = false,
    /// This `Live` armed the signal restore (see the top of the file).
    restore_armed: bool = false,
    mutex: Io.Mutex = .init,
    task: ?Io.Future(Io.Cancelable!void) = null,

    /// Draws for an output that can take `cap`: animated when it takes escapes.
    pub fn init(out: *Writer, cap: capability.Capability, items: []const Item) Live {
        return .{
            .out = out,
            .items = items,
            .animate = cap.escapes,
            .color = cap.color,
            .reflows = cap.reflows,
        };
    }

    /// Draws to `out`, which writes to `file`: animated only at a terminal that shows
    /// color (not with `NO_COLOR`, `TERM=dumb`, or under CI); ASCII on the Linux console.
    pub fn detect(
        io: Io,
        environ: *const std.process.Environ.Map,
        file: Io.File,
        out: *Writer,
        items: []const Item,
    ) Live {
        const tty = file.isTty(io) catch false;
        const cap = capability.detect(environ, .{ .is_tty = tty });
        var l: Live = .init(out, cap, items);
        l.animate = cap.escapes and cap.color != .none and !capability.ci(environ);
        l.ascii = std.mem.eql(u8, environ.get("TERM") orelse "", "linux");
        if (tty) {
            l.file = file;
            l.io = io;
        }
        return l;
    }

    /// `draw`, when `interval` has passed since the last frame.
    pub fn tick(l: *Live, now: Timestamp) Writer.Error!void {
        if (l.last) |last| {
            if (last.durationTo(now).nanoseconds < l.interval.nanoseconds) return;
        }
        try l.draw(now);
    }

    /// Draws a frame (or logs what changed) now, and flushes.
    pub fn draw(l: *Live, now: Timestamp) Writer.Error!void {
        l.last = now;
        if (!l.animate) {
            const f = l.frame(now);
            for (l.items) |item| try item.log(l.out, f);
            return l.out.flush();
        }
        l.measure();
        const w = l.out;
        try ansi.setMode(w, .synchronized_output, true);
        if (!l.cursor_hidden) {
            if (l.file) |file| l.restore_armed = restore.arm(file.handle);
            try ansi.setMode(w, .cursor_visible, false);
        }
        l.cursor_hidden = true;
        try l.toTop();
        var total: usize = 0;
        for (l.items) |item| total += item.lines();
        const room: usize = if (l.rows > 1) l.rows - 1 else total;
        var skip = total -| room;
        const f = l.frame(now);
        var row: usize = 0;
        for (l.items) |item| for (0..item.lines()) |i| {
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            if (row > 0) try w.writeByte('\n');
            try w.writeByte('\r');
            try ansi.eraseLine(w, .all);
            var buffer: [line_max]u8 = undefined;
            var line: Writer = .fixed(&buffer);
            // shortcut: a line past `line_max` bytes is cut there, maybe mid-sequence.
            item.writeLine(&line, f, i) catch {};
            // One column short: a full row would leave the cursor waiting to wrap.
            const room_columns = l.columns -| 1;
            try width.truncate(w, line.buffered(), room_columns, if (l.ascii) "~" else "…");
            if (row < l.widths.len) {
                l.widths[row] = @intCast(@min(width.of(line.buffered()), room_columns));
            }
            row += 1;
        };
        try ansi.eraseScreen(w, .to_end);
        l.drawn = row;
        try ansi.setMode(w, .synchronized_output, false);
        try w.flush();
    }

    /// Writes a line above the live lines, which stays when they are redrawn.
    pub fn print(l: *Live, comptime fmt: []const u8, args: anytype) Writer.Error!void {
        if (l.task != null) l.mutex.lockUncancelable(l.io.?);
        defer if (l.task != null) l.mutex.unlock(l.io.?);
        if (l.animate and l.drawn > 0) {
            try ansi.setMode(l.out, .synchronized_output, true);
            l.measure();
            try l.toTop();
            try ansi.eraseScreen(l.out, .to_end);
            l.drawn = 0;
        }
        try l.out.print(fmt ++ "\n", args);
        if (l.animate) {
            if (l.last) |last| return l.draw(last);
        }
        try l.out.flush();
    }

    /// Stops the task `start` began, draws the last frame, and leaves the cursor, shown,
    /// on the line after it.
    pub fn finish(l: *Live, now: Timestamp) Writer.Error!void {
        l.stop();
        try l.draw(now);
        if (!l.animate) return;
        if (l.drawn > 0) try l.out.writeAll("\r\n");
        l.drawn = 0;
        try l.showCursor();
    }

    /// Stops the task `start` began and erases the live lines, as though never drawn.
    pub fn clear(l: *Live) Writer.Error!void {
        l.stop();
        if (!l.animate) return;
        l.measure();
        try l.toTop();
        try ansi.eraseScreen(l.out, .to_end);
        l.drawn = 0;
        try l.showCursor();
    }

    /// Animates on a task of its own (`io.concurrent`), a frame every `interval`, until
    /// `finish` or `clear`. Until then, change the items with `update` (or between `lock`
    /// and `unlock`), and call neither `tick` nor `draw`. Without concurrency it fails, and
    /// `update` ticks instead, so a caller may ignore the error.
    pub fn start(l: *Live, io: Io) Io.ConcurrentError!void {
        std.debug.assert(l.task == null);
        l.io = io;
        l.task = try io.concurrent(run, .{ l, io });
    }

    /// Changes the items safely from any task: runs `change(context)` holding the lock
    /// the `start` task draws under (so concurrent updaters need no lock of their own),
    /// then, when no such task is animating, `tick`s.
    pub fn update(
        l: *Live,
        io: Io,
        context: anytype,
        comptime change: fn (@TypeOf(context)) void,
    ) Writer.Error!void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        change(context);
        if (l.task == null) try l.tick(.now(io, .awake));
    }

    /// Holds off the `start` task's next frame, while the items change; does nothing
    /// unless that task is running. `update` locks always, and ticks.
    pub fn lock(l: *Live) void {
        if (l.task != null) l.mutex.lockUncancelable(l.io.?);
    }

    /// Ends `lock`.
    pub fn unlock(l: *Live) void {
        if (l.task != null) l.mutex.unlock(l.io.?);
    }

    fn run(l: *Live, io: Io) Io.Cancelable!void {
        while (true) {
            try io.sleep(l.interval, .awake);
            l.mutex.lockUncancelable(io);
            defer l.mutex.unlock(io);
            // A failed write shows again in `finish`, which draws once more.
            l.draw(.now(io, .awake)) catch {};
        }
    }

    fn stop(l: *Live) void {
        var task = l.task orelse return;
        task.cancel(l.io.?) catch {};
        l.task = null;
    }

    fn frame(l: *const Live, now: Timestamp) Frame {
        return .{
            .now = now,
            .animate = l.animate,
            .ascii = l.ascii,
            .color = l.color,
            .columns = l.columns,
        };
    }

    /// Reads the terminal's size, when there is a terminal to ask.
    fn measure(l: *Live) void {
        const file = l.file orelse return;
        const size = Terminal.sizeOf(l.io.?, file) catch return;
        l.columns = size.width;
        l.rows = size.height;
    }

    /// To the start of the first live row: up as many rows as the drawn ones take at the
    /// width now, which is more once the terminal narrowed and rewrapped them (not where it
    /// cuts them).
    fn toTop(l: *Live) Writer.Error!void {
        try l.out.writeByte('\r');
        var above: usize = 0;
        for (0..l.drawn) |row| {
            const columns: usize = if (row < l.widths.len) l.widths[row] else 1;
            const rows = if (columns == 0 or l.columns == 0 or !l.reflows)
                1
            else
                (columns + l.columns - 1) / l.columns;
            // The cursor is on the last row of the last line.
            above += if (row + 1 < l.drawn) rows else rows - 1;
        }
        if (above > 0) try ansi.cursorUp(l.out, above);
    }

    fn showCursor(l: *Live) Writer.Error!void {
        if (l.cursor_hidden) try ansi.setMode(l.out, .cursor_visible, true);
        l.cursor_hidden = false;
        if (l.restore_armed) restore.disarm();
        l.restore_armed = false;
        try l.out.flush();
    }
};

/// Shows the cursor on a terminating signal while a `Live` animates. Process-global, as
/// signal dispositions are: one `Live` at a time arms it.
const restore = struct {
    const supported = switch (builtin.os.tag) {
        .windows, .wasi, .freestanding => false,
        else => true,
    };
    const posix = std.posix;
    const signals = if (supported) [_]posix.SIG{ .INT, .TERM, .HUP, .QUIT } else [_]void{};

    /// Ends a synchronized update, resets the style, shows the cursor, leaves the line.
    const bytes = "\x1b[?2026l\x1b[0m\x1b[?25h\r\n";

    /// The terminal to write `bytes` to; -1 when not armed.
    var fd: std.atomic.Value(i32) = .init(-1);
    var armed: [signals.len]bool = @splat(false);

    /// The console to write `bytes` to on Windows; null when not armed.
    var console: std.atomic.Value(?Io.File.Handle) = .init(null);

    /// Catches the signals whose action is the default, writing to `terminal`. False when
    /// another `Live` has it armed, or there are no signals.
    fn arm(terminal: Io.File.Handle) bool {
        if (comptime builtin.os.tag == .windows) {
            if (console.cmpxchgStrong(null, terminal, .acq_rel, .acquire) != null) return false;
            _ = win32.SetConsoleCtrlHandler(&handleConsole, .TRUE);
            return true;
        }
        if (comptime !supported) return false;
        if (fd.cmpxchgStrong(-1, terminal, .acq_rel, .acquire) != null) return false;
        const action: posix.Sigaction = .{
            .handler = .{ .handler = handle },
            .mask = posix.sigemptyset(),
            // The default action again once caught, so the re-raised signal ends the process.
            .flags = posix.SA.RESETHAND,
        };
        for (signals, &armed) |sig, *on| {
            var old: posix.Sigaction = undefined;
            posix.sigaction(sig, null, &old);
            on.* = old.handler.handler == posix.SIG.DFL;
            if (on.*) posix.sigaction(sig, &action, null);
        }
        return true;
    }

    /// Puts back the default actions `arm` replaced, unless the program has replaced them.
    fn disarm() void {
        if (comptime builtin.os.tag == .windows) {
            _ = win32.SetConsoleCtrlHandler(&handleConsole, .FALSE);
            console.store(null, .release);
            return;
        }
        if (comptime !supported) return;
        const default: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        for (signals, &armed) |sig, *on| {
            if (!on.*) continue;
            on.* = false;
            var old: posix.Sigaction = undefined;
            posix.sigaction(sig, null, &old);
            if (old.handler.handler == handle) posix.sigaction(sig, &default, null);
        }
        fd.store(-1, .release);
    }

    /// One `write` and a re-raise: all async-signal-safe. The signal stays blocked until
    /// the handler returns, then its default action ends the process.
    fn handle(sig: posix.SIG) callconv(.c) void {
        const terminal = fd.load(.acquire);
        if (terminal >= 0) _ = posix.system.write(terminal, bytes, bytes.len);
        posix.raise(sig) catch {};
    }

    /// Runs on its own thread for a console event; FALSE passes the event to the next
    /// handler, in the end the default one, which ends the process.
    fn handleConsole(event: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
        switch (event) {
            0, 1, 2 => {}, // CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT
            else => return .FALSE,
        }
        const terminal = console.load(.acquire) orelse return .FALSE;
        var written: std.os.windows.DWORD = 0;
        _ = win32.WriteFile(terminal, bytes, bytes.len, &written, null);
        return .FALSE;
    }

    const win32 = struct {
        const windows = std.os.windows;
        extern "kernel32" fn SetConsoleCtrlHandler(
            handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
            add: windows.BOOL,
        ) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn WriteFile(
            file: windows.HANDLE,
            buffer: [*]const u8,
            len: windows.DWORD,
            written: ?*windows.DWORD,
            overlapped: ?*anyopaque,
        ) callconv(.winapi) windows.BOOL;
    };
};

/// Writes a time left as `1h02m`, `3m05s`, or `12s`, rounded up to the second.
pub fn writeEta(w: *Writer, duration: Duration) Writer.Error!void {
    const ns = duration.toNanoseconds();
    const second_ns = std.time.ns_per_s;
    const seconds: u64 = @intCast(@divTrunc(@max(ns, 0) + second_ns - 1, second_ns));
    if (seconds >= 3600) return w.print("{d}h{d:0>2}m", .{ seconds / 3600, seconds % 3600 / 60 });
    if (seconds >= 60) return w.print("{d}m{d:0>2}s", .{ seconds / 60, seconds % 60 });
    try w.print("{d}s", .{seconds});
}

/// Writes a time taken as people read it: `1h02m03s`, `2m05s`, `7s`, `0.25s`.
pub fn writeElapsed(w: *Writer, duration: Duration) Writer.Error!void {
    const ns = @max(duration.nanoseconds, 0);
    const total_ms: u64 = @intCast(@divTrunc(ns, std.time.ns_per_ms));
    const seconds = total_ms / 1000;
    const hours = seconds / 3600;
    const minutes = seconds / 60 % 60;
    const rest = seconds % 60;
    if (hours > 0) return w.print("{d}h{d:0>2}m{d:0>2}s", .{ hours, minutes, rest });
    if (minutes > 0) return w.print("{d}m{d:0>2}s", .{ minutes, rest });
    if (total_ms % 1000 != 0 and seconds < 10) {
        return w.print("{d}.{d:0>2}s", .{ seconds, total_ms % 1000 / 10 });
    }
    try w.print("{d}s", .{seconds});
}

const testing = std.testing;
const vt = @import("vt.zig");

fn ms(n: i64) Timestamp {
    return Timestamp.zero.addDuration(.fromMilliseconds(n));
}

/// What the screen shows after `bytes`.
fn screenText(bytes: []const u8, columns: u16) ![]u8 {
    var screen: vt.Screen = try .init(testing.allocator, .{ .width = columns, .height = 6 });
    defer screen.deinit();
    screen.write(bytes);
    return screen.textAlloc(testing.allocator);
}

fn expectScreen(expected: []const u8, bytes: []const u8, columns: u16) !void {
    const text = try screenText(bytes, columns);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn plainLine(item: Item, f: Frame) ![]const u8 {
    const S = struct {
        var buffer: [256]u8 = undefined;
    };
    var w: Writer = .fixed(&S.buffer);
    try item.writeLine(&w, f, 0);
    return w.buffered();
}

test "a spinner turns once per interval, and ends with a symbol" {
    var s: Spinner = .{ .frames = &frames.line, .title = "Fetching", .show_elapsed = true };
    const plain: Frame = .{ .now = ms(0), .color = .none };
    try testing.expectEqualStrings("- Fetching (0s)", try plainLine(.{ .spinner = &s }, plain));
    var f = plain;
    f.now = ms(79);
    try testing.expectEqualStrings("- Fetching (0.07s)", try plainLine(.{ .spinner = &s }, f));
    f.now = ms(170);
    try testing.expectEqualStrings("| Fetching (0.17s)", try plainLine(.{ .spinner = &s }, f));
    s.finish(.success, "Fetched");
    f.now = ms(2500);
    try testing.expectEqualStrings("✓ Fetched (2.50s)", try plainLine(.{ .spinner = &s }, f));
    f.now = ms(9000); // stays at the time it ended
    f.ascii = true;
    try testing.expectEqualStrings("+ Fetched (2.50s)", try plainLine(.{ .spinner = &s }, f));
}

test "ASCII falls back to the line spinner, ASCII cells, and ASCII symbols" {
    var s: Spinner = .{ .title = "x" };
    const f: Frame = .{ .now = ms(0), .ascii = true, .color = .none };
    try testing.expectEqualStrings("- x", try plainLine(.{ .spinner = &s }, f));
    var b: Bar = .{ .total = 4, .current = 1, .width = 8, .show_percent = false };
    try testing.expectEqualStrings("##------", try plainLine(.{ .bar = &b }, f));
    b.finish(.failure);
    try testing.expectEqualStrings("x ##------", try plainLine(.{ .bar = &b }, f));
}

test "a bar's numbers: percent, count, rate, estimate, time" {
    var b: Bar = .{
        .total = 10 * 1024 * 1024,
        .label = "get",
        .width = 4,
        .cells = .ascii,
        .units = .bytes,
        .show_count = true,
        .show_rate = true,
        .show_elapsed = true,
    };
    var f: Frame = .{ .now = ms(0), .color = .none };
    try testing.expectEqualStrings("get ----   0% 0B/10.0MiB 0s", try plainLine(.{ .bar = &b }, f));
    b.set(5 * 1024 * 1024);
    f.now = ms(2000);
    try testing.expectEqualStrings(
        "get ##--  50% 5.0MiB/10.0MiB 2.5MiB/s ETA 2s 2s",
        try plainLine(.{ .bar = &b }, f),
    );
    var items: Bar = .{ .total = 3, .current = 1, .width = 3, .cells = .ascii };
    items.show_count = true;
    items.show_rate = true;
    items.show_eta = false;
    items.started = ms(0);
    try testing.expectEqualStrings("#--  33% 1/3 0.5/s", try plainLine(.{ .bar = &items }, f));
}

test "a bar fills in eighths, with a gradient lowered to the output" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeCells(&w, 5.0 / 16.0, 4, .blocks, .{});
    try testing.expectEqualStrings("█▎░░", w.buffered());
    w = .fixed(&buffer);
    try writeCells(&w, 1, 2, .block, .{
        .gradient = &.{ .hex(0xff0000), .hex(0x0000ff) },
        .level = .ansi256,
    });
    try testing.expectEqualStrings("\x1b[38;5;196m█\x1b[38;5;21m█\x1b[0m", w.buffered());
    w = .fixed(&buffer);
    try writeCells(&w, 0.5, 2, .ascii, .{ .full = .{ .fg = .green }, .empty = .{ .dim = true } });
    try testing.expectEqualStrings("\x1b[32m#\x1b[0m\x1b[2m-\x1b[0m", w.buffered());
}

test "a bar that fills the line takes what the label and numbers leave" {
    var b: Bar = .{ .total = 2, .current = 1, .label = "ab", .width = null, .cells = .ascii };
    const f: Frame = .{ .now = ms(0), .color = .none, .columns = 20 };
    // 20 columns: "ab " and "  50%" leave 12 for the bar.
    try testing.expectEqualStrings("ab ######------  50%", try plainLine(.{ .bar = &b }, f));
}

test "an unknown total sweeps while animated and is left out of logs" {
    var b: Bar = .{ .label = "scan", .width = 8, .cells = .ascii, .show_count = true };
    var f: Frame = .{ .now = ms(0), .color = .none };
    try testing.expectEqualStrings("scan ##------ 0", try plainLine(.{ .bar = &b }, f));
    f.now = ms(240);
    b.set(7);
    try testing.expectEqualStrings("scan ---##--- 7", try plainLine(.{ .bar = &b }, f));
    f.animate = false;
    try testing.expectEqualStrings("scan 7", try plainLine(.{ .bar = &b }, f));
}

test "redrawn in place: one region on the screen, log lines above it" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var title: Text = .{ .text = "deploy" };
    var spin: Spinner = .{ .frames = &frames.line, .title = "build" };
    var bar: Bar = .{ .total = 4, .label = "push", .width = 4, .cells = .ascii };
    const items = [_]Item{ .{ .text = &title }, .{ .spinner = &spin }, .{ .bar = &bar } };
    var live: Live = .init(&bytes.writer, .{ .color = .none, .escapes = true }, &items);
    try bytes.writer.writeAll("$ run\n");
    try live.draw(ms(0));
    try expectScreen("$ run\ndeploy\n- build\npush ----   0%", bytes.written(), 30);
    bar.set(2);
    try live.draw(ms(100));
    try expectScreen("$ run\ndeploy\n\\ build\npush ##--  50% ETA 1s", bytes.written(), 30);
    try live.print("pushed {s}", .{"layer 1"});
    try expectScreen(
        "$ run\npushed layer 1\ndeploy\n\\ build\npush ##--  50% ETA 1s",
        bytes.written(),
        30,
    );
    spin.finish(.success, null);
    bar.finish(.success);
    try live.finish(ms(200));
    try expectScreen(
        "$ run\npushed layer 1\ndeploy\n✓ build\n✓ push #### 100%",
        bytes.written(),
        30,
    );
    // The cursor hid for the frames and shows again; frames were synchronized.
    const out = bytes.written();
    try testing.expect(std.mem.startsWith(u8, out[6..], "\x1b[?2026h\x1b[?25l"));
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\x1b[?25h"));
}

test "a shorter frame erases the rows it no longer uses; clear erases all" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var steps_list = [_]Steps.Step{ .{ .name = "a" }, .{ .name = "b" } };
    var steps: Steps = .{ .items = &steps_list };
    const items = [_]Item{.{ .steps = &steps }};
    var live: Live = .init(&bytes.writer, .{ .color = .none, .escapes = true }, &items);
    try live.draw(ms(0));
    try expectScreen("· a\n· b", bytes.written(), 10);
    steps.items = steps_list[0..1];
    try live.draw(ms(10));
    try expectScreen("· a", bytes.written(), 10);
    try live.clear();
    try expectScreen("", bytes.written(), 10);
}

test "after the terminal narrows, the next frame starts above the rewrapped rows" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var a: Text = .{ .text = "aaaaaaaaaaaaaaaaaaaa" };
    var b: Text = .{ .text = "bbbbbbbbbbbbbbbbbbbb" };
    const items = [_]Item{ .{ .text = &a }, .{ .text = &b } };
    var live: Live = .init(&bytes.writer, .{ .color = .none, .escapes = true }, &items);
    live.columns = 30;
    try live.draw(ms(0));
    const first = bytes.written().len;
    // Each 20-column line now takes two rows: three above the cursor, not one.
    live.columns = 10;
    try live.draw(ms(100));
    try testing.expect(std.mem.indexOf(u8, bytes.written()[first..], "\r\x1b[3A") != null);
    // Wider again (and rejoined): a row each.
    live.columns = 40;
    const second = bytes.written().len;
    try live.draw(ms(200));
    try testing.expect(std.mem.indexOf(u8, bytes.written()[second..], "\r\x1b[1A") != null);
    // A terminal that cuts lines instead: one row each, narrowed or not.
    live.reflows = false;
    try live.draw(ms(300));
    live.columns = 10;
    const third = bytes.written().len;
    try live.draw(ms(400));
    try testing.expect(std.mem.indexOf(u8, bytes.written()[third..], "\r\x1b[1A") != null);
}

test "lines are cut to the terminal's width, wide graphemes whole" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var text: Text = .{ .text = "日本語のテキスト" };
    const items = [_]Item{.{ .text = &text }};
    var live: Live = .init(&bytes.writer, .{ .color = .none, .escapes = true }, &items);
    live.columns = 8;
    try live.draw(ms(0));
    // 7 columns usable: three wide characters and the ellipsis.
    try expectScreen("日本語…", bytes.written(), 8);
}

test "only the rows that fit are drawn, the last ones" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var list = [_]Steps.Step{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" } };
    var steps: Steps = .{ .items = &list };
    const items = [_]Item{.{ .steps = &steps }};
    var live: Live = .init(&bytes.writer, .{ .color = .none, .escapes = true }, &items);
    live.rows = 3;
    try live.draw(ms(0));
    try expectScreen("· b\n· c", bytes.written(), 10);
}

test "tick draws at most once per interval" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var text: Text = .{ .text = "x" };
    const items = [_]Item{.{ .text = &text }};
    var live: Live = .init(&bytes.writer, .{ .color = .none, .escapes = true }, &items);
    try live.tick(ms(0));
    const one = bytes.written().len;
    try live.tick(ms(49));
    try testing.expectEqual(one, bytes.written().len);
    try live.tick(ms(50));
    try testing.expect(bytes.written().len > one);
}

test "without a terminal, a line per change: start, quarters, outcome" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var spin: Spinner = .{ .title = "resolve" };
    var bar: Bar = .{ .total = 100, .label = "get", .width = 4, .show_eta = false };
    var list = [_]Steps.Step{ .{ .name = "unpack" }, .{ .name = "link" } };
    var steps: Steps = .{ .items = &list };
    const items = [_]Item{ .{ .spinner = &spin }, .{ .bar = &bar }, .{ .steps = &steps } };
    var live: Live = .init(&bytes.writer, .plain, &items);
    try live.draw(ms(0));
    for (1..100) |n| {
        bar.set(n);
        try live.draw(ms(@intCast(n)));
    }
    spin.finish(.success, "resolved");
    list[0].state = .running;
    try live.draw(ms(200));
    list[0].state = .done;
    list[1].state = .skipped;
    bar.finish(.success);
    try live.finish(ms(300));
    try testing.expectEqualStrings(
        \\→ resolve
        \\get ░░░░   0%
        \\get █░░░  25%
        \\get ██░░  50%
        \\get ███░  75%
        \\✓ resolved
        \\→ unpack
        \\✓ get ████ 100%
        \\✓ unpack
        \\- link
        \\
    , bytes.written());
}

test writeEta {
    var buffer: [32]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeEta(&w, .fromMilliseconds(11_200));
    try w.writeByte(' ');
    try writeEta(&w, .fromSeconds(185));
    try w.writeByte(' ');
    try writeEta(&w, .fromSeconds(3720));
    try testing.expectEqualStrings("12s 3m05s 1h02m", w.buffered());
}

test writeElapsed {
    var buffer: [32]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    for ([_]i64{ 3_723_000, 125_000, 7_000, 250 }, 0..) |n, i| {
        if (i > 0) try w.writeByte(' ');
        try writeElapsed(&w, .fromMilliseconds(n));
    }
    try testing.expectEqualStrings("1h02m03s 2m05s 7s 0.25s", w.buffered());
}

test "start animates on its own task until finish" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var spin: Spinner = .{ .frames = &frames.line, .title = "wait" };
    const items = [_]Item{.{ .spinner = &spin }};
    var live: Live = .init(&bytes.writer, .{ .color = .none, .escapes = true }, &items);
    live.interval = .fromMilliseconds(1);
    live.start(testing.io) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    live.lock();
    spin.finish(.success, "done");
    live.unlock();
    try live.finish(.now(testing.io, .awake));
    try expectScreen("✓ done", bytes.written(), 20);
}

test "update serializes concurrent changes and ticks without a task" {
    var bytes: Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    var bar: Bar = .{ .label = "work", .total = 400 };
    const items = [_]Item{.{ .bar = &bar }};
    var live: Live = .init(&bytes.writer, .plain, &items);
    live.interval = .zero;
    const Worker = struct {
        fn addOne(b: *Bar) void {
            // Not atomic: a lost update shows as a total short of 400.
            const before = b.current;
            std.atomic.spinLoopHint();
            b.current = before + 1;
        }
        fn work(l: *Live, b: *Bar) void {
            for (0..100) |_| l.update(testing.io, b, addOne) catch {};
        }
    };
    var tasks: [4]Io.Future(void) = undefined;
    for (&tasks) |*t| t.* = testing.io.concurrent(Worker.work, .{ &live, &bar }) catch
        return error.SkipZigTest;
    for (&tasks) |*t| t.await(testing.io);
    try testing.expectEqual(400, bar.current);
    // Not animated: each quarter logged its line as it was crossed.
    try testing.expect(std.mem.indexOf(u8, bytes.written(), "100%") != null);
}

test "a terminating signal mid-animation shows the cursor, then ends the process" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var pipe: [2]i32 = undefined;
    try testing.expectEqual(0, linux.pipe(&pipe));
    defer _ = linux.close(pipe[0]);
    const pid: i32 = @intCast(@as(isize, @bitCast(linux.fork())));
    try testing.expect(pid >= 0);
    if (pid == 0) {
        // The child: only system calls, as after any `fork` of a threaded process.
        const default: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &default, null);
        _ = restore.arm(pipe[1]);
        std.posix.raise(.TERM) catch {};
        linux.exit_group(0); // Not reached.
    }
    _ = linux.close(pipe[1]);
    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = linux.read(pipe[0], buffer[len..].ptr, buffer.len - len);
        if (n == 0 or @as(isize, @bitCast(n)) < 0) break;
        len += n;
    }
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    try testing.expectEqualStrings(restore.bytes, buffer[0..len]);
    const s: u32 = @bitCast(status);
    try testing.expect(linux.W.IFSIGNALED(s));
    try testing.expectEqual(.TERM, linux.W.TERMSIG(s));
}

test "the signal restore leaves handled signals alone and disarms to the default" {
    if (!restore.supported) return error.SkipZigTest;
    const posix = std.posix;
    var saved: [restore.signals.len]posix.Sigaction = undefined;
    const Ignore = struct {
        fn handle(_: posix.SIG) callconv(.c) void {}
    };
    const handled: posix.Sigaction = .{
        .handler = .{ .handler = Ignore.handle },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    const default: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (restore.signals, &saved) |sig, *old| posix.sigaction(sig, &default, old);
    defer for (restore.signals, &saved) |sig, *old| posix.sigaction(sig, old, null);
    posix.sigaction(.INT, &handled, null);

    try testing.expect(restore.arm(2));
    try testing.expect(!restore.arm(2)); // One `Live` at a time.
    var now: posix.Sigaction = undefined;
    posix.sigaction(.INT, null, &now);
    try testing.expect(now.handler.handler == Ignore.handle);
    posix.sigaction(.TERM, null, &now);
    try testing.expect(now.handler.handler == restore.handle);
    restore.disarm();
    posix.sigaction(.TERM, null, &now);
    try testing.expect(now.handler.handler == posix.SIG.DFL);
    posix.sigaction(.INT, null, &now);
    try testing.expect(now.handler.handler == Ignore.handle);
    try testing.expect(restore.arm(2));
    restore.disarm();
}
