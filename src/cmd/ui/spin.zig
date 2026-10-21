//! `termancy ui spin`: run a command with a spinner on the terminal while it works, as gum's
//! `spin` does.
//!
//! The spinner is a `tui.Program` and the command its background work (`tui.Cmd.work`):
//! `Job.finish` reads the command's pipes into the `Job`, which the view shows from while
//! it runs, then waits for it. The command runs in a process group of its own, so Ctrl-C
//! and `--timeout` can stop all of it (SIGINT, as a terminal's Ctrl-C does, or SIGTERM, as
//! timeout(1) does) before termancy ends at once, as gum does, without waiting.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const tui = @import("tui");
const sys = @import("sys");
const term = @import("term.zig");
const styles = @import("styles.zig");
const Spinner = @import("../tui/registry/spinner.zig");
const live = tui.term.live;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// gum's spinners, then termancy's older names.
pub const Name = enum {
    line,
    dot,
    minidot,
    jump,
    pulse,
    points,
    globe,
    moon,
    monkey,
    meter,
    hamburger,
    dots,
    mini_dot,
    arc,
    bouncing_bar,
};

pub const Align = enum { left, right };

pub const Flags = struct {
    title: []const u8 = "Loading...",
    spinner: Name = .dot,
    @"align": Align = .left,
    show_output: bool = false,
    show_error: bool = false,
    show_stdout: bool = false,
    show_stderr: bool = false,
    timeout: cfg.Duration = .zero,
    padding: styles.Spacing = .{},
    spinner_style: styles.Styles = .{},
    title_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field.Set(.{ field.Spec(Flags){ .fields = .{
    .title = .{ .help = "Text next to the spinner" },
    .spinner = .{ .help = "The spinner's frames, by gum's names (dots, mini-dot, arc, and " ++
        "bouncing-bar are termancy's own)" },
    .@"align" = .{ .help = "Where the spinner is: left or right of the title" },
    .show_output = .{
        .help = "Show the command's output as it runs, and print it if the command succeeds",
    },
    .show_error = .{ .help = "Print the command's output if it fails" },
    .show_stdout = .{ .help = "--show-output for standard output only" },
    .show_stderr = .{ .help = "--show-output for standard error only" },
    .timeout = .{
        .help = "Stop the command after this long (0 waits): status 124, \"timed out\" on stderr",
    },
    .padding = .{ .help = term.help.padding },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_SPIN_", .fields = .{
    .spinner = .{ .short = 's' },
    .@"align" = .{ .short = 'a' },
    .spinner_style = styles.group("spinner"),
    .title_style = styles.group("title"),
} });

pub const command = cli.command(.{
    .name = "spin",
    .summary = "Run a command with a spinner",
    .description =
    \\Run the command after -- with a spinner on the terminal, and exit with its status.
    \\
    \\Where standard output is a terminal, the command's output stays hidden unless asked
    \\for: --show-output shows both its streams under the spinner as they come and prints
    \\them if the command succeeds; --show-stdout and --show-stderr do that for one;
    \\--show-error prints both if it fails. Where standard output is not a terminal
    \\(files=$(termancy ui spin -- find .)), the command's standard output goes straight
    \\there, and its standard error follows once the spinner is gone.
    \\
    \\Ctrl-C stops the command and exits with status 130; --timeout stops it with status
    \\124 and "timed out" on stderr. A command that cannot be found exits with status 127.
    \\With no terminal at all, the command runs with no spinner. Style the parts with
    \\--spinner.* and --title.*; every flag can also come from a variable:
    \\TERMANCY_SPIN_TITLE, TERMANCY_SPIN_SPINNER_FOREGROUND.
    ,
    .flags = flags_flags,
    .args = .{ .min = 1, .max = null, .usage = "-- <command> [arg...]" },
    .examples =
    \\termancy ui spin --title "Building..." -- zig build
    \\termancy ui spin --spinner moon --show-error -- make test
    \\files=$(termancy ui spin -- find / -name '*.zig')
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const io = ctx.io;
    var buffer: [64]u8 = undefined;
    var terminal = tui.Terminal.open(io, &buffer) catch |err| switch (err) {
        error.NotATerminal => return runPlain(ctx, flags),
        error.Canceled => return error.Canceled,
    };
    terminal.close();
    const caught = try Io.File.stdout().isTty(io);
    var job = Job.spawn(ctx.gpa, io, ctx.args, .{
        // The keys come from a terminal on standard input; the command gets nothing there.
        .stdin = if (try Io.File.stdin().isTty(io)) .ignore else .inherit,
        .stdout = if (caught) .pipe else .inherit,
        .stderr = .pipe,
    }) catch |err| return spawnFailed(ctx, err);
    defer job.deinit();
    var model: term.Framed(Spin) = .{
        .inner = try .init(ctx.arena, ctx.theme, &job, flags),
        .gpa = ctx.gpa,
        .padding = flags.padding.sides,
    };
    const options = term.timed(term.inline_options, flags.timeout);
    const outcome = term.runOutcome(ctx, @TypeOf(model), &model, options) catch |err| {
        job.stop(false);
        return err;
    };
    const result = model.inner.result orelse {
        job.stop(!outcome.timed_out);
        if (outcome.timed_out) return term.exitTimedOut(ctx);
        return term.exitInterrupted(ctx);
    };
    const ended = result catch |err| return ctx.fail("{s}: {s}", .{ ctx.args[0], @errorName(err) });
    const status = sys.process.exitStatus(ended);
    if (caught) {
        try ctx.out.writeAll(printed(flags, status, job.output()));
    } else {
        try ctx.err.writeAll(job.stderr.items);
    }
    return exitWith(ctx, status);
}

/// With no terminal: the command runs on termancy's own streams, `--timeout` still
/// stopping it.
fn runPlain(ctx: *cli.Context, flags: Flags) !void {
    const io = ctx.io;
    var job = Job.spawn(ctx.gpa, io, ctx.args, .{}) catch |err| return spawnFailed(ctx, err);
    defer job.deinit();
    if (flags.timeout.ns == 0) return exitWith(ctx, sys.process.exitStatus(try job.child.wait(io)));
    var done: Io.Event = .unset;
    var task = io.concurrent(waitAndSet, .{ &job, &done }) catch
        return exitWith(ctx, sys.process.exitStatus(try job.child.wait(io)));
    const timeout: Io.Timeout = .{ .duration = .{ .raw = flags.timeout.toIo(), .clock = .awake } };
    done.waitTimeout(io, timeout) catch |err| switch (err) {
        error.Timeout => {
            // It may have ended meanwhile.
            if (task.cancel(io)) |ended| {
                return exitWith(ctx, sys.process.exitStatus(ended));
            } else |_| {}
            job.stop(false);
            return term.exitTimedOut(ctx);
        },
        error.Canceled => return error.Canceled,
    };
    return exitWith(ctx, sys.process.exitStatus(try task.await(io)));
}

fn waitAndSet(job: *Job, done: *Io.Event) Child.WaitError!Child.Term {
    defer done.set(job.io);
    return job.child.wait(job.io);
}

/// Reports a command that could not start: 127 when it is not found, 126 when it cannot
/// run, as sh(1) does.
fn spawnFailed(ctx: *cli.Context, err: std.process.SpawnError) !void {
    switch (err) {
        error.FileNotFound => {
            try ctx.err.print("{s}: {s}: command not found\n", .{ ctx.app_name, ctx.args[0] });
            return ctx.exit(127);
        },
        error.AccessDenied, error.PermissionDenied => {
            try ctx.err.print("{s}: {s}: permission denied\n", .{ ctx.app_name, ctx.args[0] });
            return ctx.exit(126);
        },
        else => |e| return e,
    }
}

/// Ends with the command's `status`.
fn exitWith(ctx: *cli.Context, status: u8) !void {
    switch (status) {
        0 => {},
        1 => return error.CommandFailed,
        2 => return error.UsageFailed,
        else => return ctx.exit(status),
    }
}

/// What the command wrote: each stream, and both in the order they came.
pub const Output = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    both: []const u8 = "",
};

/// What gum prints once the command has ended, where standard output is a terminal: the
/// streams the flags show when it succeeded, both with `--show-error` when it failed, and
/// otherwise nothing.
pub fn printed(flags: Flags, status: u8, output: Output) []const u8 {
    if (status != 0) return if (flags.show_error) output.both else "";
    if (flags.show_output or (flags.show_stdout and flags.show_stderr)) return output.both;
    if (flags.show_stdout) return output.stdout;
    if (flags.show_stderr) return output.stderr;
    return "";
}

/// The command, and what it has written to the pipes it was given.
pub const Job = struct {
    child: Child,
    io: Io,
    gpa: Allocator,
    /// Held while the output grows, and while the view reads it.
    mutex: Io.Mutex = .init,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    /// Both, in the order they came.
    both: std.ArrayList(u8) = .empty,

    pub const Error = Allocator.Error || Io.File.MultiReader.UnendingError ||
        Io.Batch.AwaitConcurrentError || Child.WaitError;

    /// Where the command's standard streams go: termancy's own by default.
    pub const Streams = struct {
        stdin: std.process.SpawnOptions.StdIo = .inherit,
        stdout: std.process.SpawnOptions.StdIo = .inherit,
        stderr: std.process.SpawnOptions.StdIo = .inherit,
    };

    /// Starts `argv` in a process group of its own.
    pub fn spawn(
        gpa: Allocator,
        io: Io,
        argv: []const []const u8,
        streams: Streams,
    ) std.process.SpawnError!Job {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = streams.stdin,
            .stdout = streams.stdout,
            .stderr = streams.stderr,
            .pgid = if (builtin.os.tag == .windows) null else 0,
        });
        return .{ .child = child, .io = io, .gpa = gpa };
    }

    pub fn deinit(job: *Job) void {
        job.stdout.deinit(job.gpa);
        job.stderr.deinit(job.gpa);
        job.both.deinit(job.gpa);
    }

    /// Reads the pipes to their end, then waits for the command. Canceled, it leaves the
    /// command running, for `stop`.
    pub fn finish(job: *Job) Error!Child.Term {
        if (job.child.stdout) |out| {
            try job.read(2, .{ out, job.child.stderr.? }, .{ &job.stdout, &job.stderr });
        } else if (job.child.stderr) |err| {
            try job.read(1, .{err}, .{&job.stderr});
        }
        return job.child.wait(job.io);
    }

    fn read(
        job: *Job,
        comptime n: usize,
        files: [n]Io.File,
        sinks: [n]*std.ArrayList(u8),
    ) Error!void {
        var buffer: Io.File.MultiReader.Buffer(n) = undefined;
        var reader: Io.File.MultiReader = undefined;
        reader.init(job.gpa, job.io, buffer.toStreams(), &files);
        defer reader.deinit();
        while (reader.fill(256, .none)) |_| {
            job.mutex.lockUncancelable(job.io);
            defer job.mutex.unlock(job.io);
            for (sinks, 0..) |sink, i| {
                const r = reader.reader(i);
                try sink.appendSlice(job.gpa, r.buffered());
                try job.both.appendSlice(job.gpa, r.buffered());
                r.tossBuffered();
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try reader.checkAnyError();
    }

    /// What the command wrote so far. Only once it has ended, or under `mutex`.
    pub fn output(job: *const Job) Output {
        return .{ .stdout = job.stdout.items, .stderr = job.stderr.items, .both = job.both.items };
    }

    /// Stops the command and what it started: its process group gets SIGINT (`interrupt`,
    /// as from a terminal's Ctrl-C) or SIGTERM (as from timeout(1)). Does not wait for it.
    pub fn stop(job: *Job, interrupt: bool) void {
        if (comptime builtin.os.tag == .windows) return job.child.kill(job.io);
        const pid = job.child.id orelse return;
        std.posix.kill(-pid, if (interrupt) .INT else .TERM) catch {};
    }
};

/// The spinner and its title, over what the command writes as it runs.
pub const Spin = struct {
    spinner: Spinner,
    /// `--title`, laid out in its style.
    title: []const u8,
    @"align": Align = .left,
    job: *Job,
    /// The streams shown under the spinner while the command runs.
    show_stdout: bool = false,
    show_stderr: bool = false,
    /// The terminal's height, and the rows the view takes besides the output, so the
    /// spinner stays on screen.
    rows: usize = 24,
    reserved: usize = 3,
    /// How the command ended; null while it runs.
    result: ?Message = null,

    pub const Message = Job.Error!Child.Term;

    pub fn init(
        arena: Allocator,
        theme: *const cli.Theme,
        job: *Job,
        flags: Flags,
    ) Allocator.Error!Spin {
        var spinner = spinnerOf(flags.spinner);
        spinner.styles = .{ .spinner = flags.spinner_style.over(theme.accent), .title = .{} };
        return .{
            .spinner = spinner,
            .title = try styles.render(arena, flags.title_style.over(.{}), flags.title),
            .@"align" = flags.@"align",
            .job = job,
            .show_stdout = flags.show_output or flags.show_stdout,
            .show_stderr = flags.show_output or flags.show_stderr,
            .reserved = 3 + flags.padding.sides.top + flags.padding.sides.bottom,
        };
    }

    pub fn start(spin: *Spin) tui.Cmd {
        return .batch(&.{ spin.spinner.start(), .work(0, @intFromPtr(spin.job)) });
    }

    pub fn work(_: Io, _: Allocator, _: u32, arg: u64) Message {
        const job: *Job = @ptrFromInt(@as(usize, @intCast(arg)));
        return job.finish();
    }

    pub fn update(spin: *Spin, msg: tui.Message(Message)) tui.Cmd {
        switch (msg) {
            .app => |result| {
                spin.result = result;
                return .quit;
            },
            .resize => |size| spin.rows = size.height,
            else => {},
        }
        return spin.spinner.update(msg.base().?);
    }

    pub fn view(spin: *const Spin, w: *Io.Writer) Io.Writer.Error!void {
        const gap: []const u8 = if (spin.title.len > 0) " " else "";
        if (spin.@"align" == .right) try w.print("{s}{s}", .{ spin.title, gap });
        try spin.spinner.view(w);
        if (spin.@"align" == .left) try w.print("{s}{s}", .{ gap, spin.title });
        if (!spin.show_stdout and !spin.show_stderr) return;
        const job = spin.job;
        job.mutex.lockUncancelable(job.io);
        defer job.mutex.unlock(job.io);
        const output = job.output();
        const text = if (spin.show_stdout and spin.show_stderr)
            output.both
        else if (spin.show_stdout)
            output.stdout
        else
            output.stderr;
        if (text.len == 0) return;
        try w.writeAll("\n\n");
        try w.writeAll(tail(text, @max(spin.rows -| spin.reserved, 1)));
    }
};

/// The last `lines` lines of `text`, without its final line break.
pub fn tail(text: []const u8, lines: usize) []const u8 {
    const body = std.mem.trimEnd(u8, text, "\n");
    var start = body.len;
    var count: usize = 0;
    while (start > 0) : (start -= 1) {
        if (body[start - 1] != '\n') continue;
        count += 1;
        if (count == lines) break;
    }
    return body[start..];
}

/// The spinner `name` names, with its frames and pace: gum's, for gum's names.
pub fn spinnerOf(name: Name) Spinner {
    const f = live.frames;
    const frames: []const []const u8, const ms: i64 = switch (name) {
        .line => .{ &f.line, 100 },
        .dot => .{ &f.dot, 100 },
        .minidot, .dots => .{ &f.dots, 83 },
        .jump => .{ &f.jump, 100 },
        .pulse => .{ &f.pulse, 125 },
        .points => .{ &f.points, 143 },
        .globe => .{ &f.globe, 250 },
        .moon => .{ &f.moon, 125 },
        .monkey => .{ &f.monkey, 333 },
        .meter => .{ &f.meter, 143 },
        .hamburger => .{ &f.hamburger, 333 },
        .mini_dot => .{ &f.mini_dot, 80 },
        .arc => .{ &f.arc, 80 },
        .bouncing_bar => .{ &f.bouncing_bar, 80 },
    };
    return .{ .frames = frames, .interval = .fromMilliseconds(ms) };
}

const testing = std.testing;

test spinnerOf {
    try testing.expectEqualStrings("⣾", spinnerOf(.dot).frames[0]);
    try testing.expectEqualStrings("🙈", spinnerOf(.monkey).frames[0]);
    try testing.expectEqual(333, spinnerOf(.hamburger).interval.toMilliseconds());
    // termancy's older names: dots is gum's minidot.
    try testing.expectEqual(spinnerOf(.minidot).frames.ptr, spinnerOf(.dots).frames.ptr);
    try testing.expectEqualStrings("[    ]", spinnerOf(.bouncing_bar).frames[0]);
}

test "printed: gum's rules, where standard output is a terminal" {
    const output: Output = .{ .stdout = "out\n", .stderr = "err\n", .both = "out\nerr\n" };
    try testing.expectEqualStrings("", printed(.{}, 0, output));
    try testing.expectEqualStrings("out\nerr\n", printed(.{ .show_output = true }, 0, output));
    try testing.expectEqualStrings("out\n", printed(.{ .show_stdout = true }, 0, output));
    try testing.expectEqualStrings("err\n", printed(.{ .show_stderr = true }, 0, output));
    const both: Flags = .{ .show_stdout = true, .show_stderr = true };
    try testing.expectEqualStrings("out\nerr\n", printed(both, 0, output));
    // --show-error: only on failure, then everything.
    try testing.expectEqualStrings("", printed(.{ .show_error = true }, 0, output));
    try testing.expectEqualStrings("out\nerr\n", printed(.{ .show_error = true }, 3, output));
    // Failed without --show-error: nothing, whatever the other flags say.
    try testing.expectEqualStrings("", printed(.{ .show_output = true }, 1, output));
}

test tail {
    try testing.expectEqualStrings("c\nd", tail("a\nb\nc\nd\n", 2));
    try testing.expectEqualStrings("a\nb", tail("a\nb", 5));
    try testing.expectEqualStrings("b", tail("a\nb\n", 1));
    try testing.expectEqualStrings("", tail("", 3));
}

const piped: Job.Streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .pipe };

fn testJob(argv: []const []const u8) !Job {
    return Job.spawn(testing.allocator, testing.io, argv, piped);
}

test "Job: the streams caught, and the status" {
    const windows = builtin.os.tag == .windows;
    const argv: []const []const u8 = if (windows)
        &.{ "cmd.exe", "/c", "echo out& 1>&2 echo err& exit /b 3" }
    else
        &.{ "sh", "-c", "echo out; echo err >&2; exit 3" };
    var job = try testJob(argv);
    defer job.deinit();
    const ended = try job.finish();
    const eol = if (windows) "\r\n" else "\n";
    try testing.expectEqual(3, sys.process.exitStatus(ended));
    try testing.expectEqualStrings("out" ++ eol, job.stdout.items);
    try testing.expectEqualStrings("err" ++ eol, job.stderr.items);
    try testing.expectEqual(2 * ("out" ++ eol).len, job.both.items.len);
}

test "Job: a missing command" {
    try testing.expectError(error.FileNotFound, testJob(&.{"termancy-test-no-such-command"}));
}

test "Job.stop ends the command's whole process group" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var job = try testJob(&.{ "sh", "-c", "sleep 30; echo late" });
    defer job.deinit();
    job.stop(false);
    // The pipes close only once sh and its sleep have both gone.
    const ended = try job.finish();
    try testing.expectEqual(128 + 15, sys.process.exitStatus(ended));
    try testing.expectEqualStrings("", job.stdout.items);
}

test "the spinner, the title on either side, and the output under it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var job = try testJob(&.{ "sh", "-c", "echo one; echo two" });
    defer job.deinit();
    const flags: Flags = .{ .spinner = .line, .title = "Wait", .show_stdout = true };
    const spin: Spin = try .init(arena.allocator(), &cli.Theme.default, &job, flags);
    var d: tui.testing.Driver(Spin) = try .init(testing.allocator, spin, .{});
    defer d.deinit();
    // The driver runs the work at once: the command has ended.
    try testing.expect(d.done());
    try testing.expectEqual(0, sys.process.exitStatus(try d.model().result.?));
    try d.expectFrame("- Wait\n\none\ntwo");
    d.model().@"align" = .right;
    d.model().rows = 4; // room for one line of output
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try d.model().view(&out.writer);
    try testing.expectEqualStrings("Wait \x1b[35m-\x1b[0m\n\ntwo", out.written());
}
