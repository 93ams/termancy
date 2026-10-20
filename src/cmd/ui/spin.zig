//! `termancy ui spin`: run a command with a spinner on the terminal while it works.
//!
//! The command runs as a concurrent task; the main task animates the spinner until the
//! task signals that it is done. The terminal stays in its normal mode, so Ctrl-C reaches
//! the command as `SIGINT` (it is in the same process group) and termancy records it with
//! `sys.signal`, then ends with status 130 once the command has stopped.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const sys = @import("sys");
const term = @import("term.zig");
const live = tui.term.live;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Frames = enum { dots, line, mini_dot, points, pulse, globe, moon, arc, bouncing_bar };

pub const Flags = struct {
    title: []const u8 = "Loading...",
    spinner: Frames = .dots,
    show_output: bool = false,
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .title = .{ .help = "Text next to the spinner" },
    .spinner = .{ .help = "The spinner's frames" },
    .show_output = .{ .help = "Let the command write to the terminal as it runs" },
} }}), .{});

pub const command = cli.command(.{
    .name = "spin",
    .summary = "Run a command with a spinner",
    .description =
    \\Run the command after -- and show a spinner on the terminal until it ends. Then
    \\print what the command wrote to standard output (and standard error, to standard
    \\error), and exit with its status. With --show-output, the command writes directly
    \\as it runs instead.
    \\
    \\Without a terminal, the command runs the same way with no spinner. Ctrl-C stops
    \\the command and exits with status 130, printing nothing. A command that cannot be
    \\found exits with status 127.
    ,
    .flags = flags_flags,
    .args = .{ .min = 1, .max = null, .usage = "-- <command> [arg...]" },
    .examples =
    \\termancy ui spin --title "Building..." -- zig build
    \\files=$(termancy ui spin -- find / -name '*.zig')
    ,
    .run = run,
});

/// How the command ended and what it wrote.
pub const Child = struct {
    term: std.process.Child.Term,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    pub fn deinit(child: Child, gpa: Allocator) void {
        gpa.free(child.stdout);
        gpa.free(child.stderr);
    }
};

pub const RunError = sys.process.CaptureError || sys.process.StreamError;

fn run(ctx: *cli.Context, flags: Flags) !void {
    const child = execute(ctx, ctx.args, flags) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.err.print("{s}: {s}: command not found\n", .{ ctx.app_name, ctx.args[0] });
            return ctx.exit(127);
        },
        error.AccessDenied, error.PermissionDenied => {
            try ctx.err.print("{s}: {s}: permission denied\n", .{ ctx.app_name, ctx.args[0] });
            return ctx.exit(126);
        },
        else => |e| return e,
    };
    defer child.deinit(ctx.gpa);
    if (sys.signal.interrupted()) return term.exitInterrupted(ctx);
    try ctx.out.writeAll(child.stdout);
    try ctx.err.writeAll(child.stderr);
    switch (sys.process.exitStatus(child.term)) {
        0 => {},
        1 => return error.CommandFailed,
        2 => return error.UsageFailed,
        else => |status| return ctx.exit(status),
    }
}

/// Runs `argv`, with a spinner when there is a terminal that can show one.
fn execute(ctx: *cli.Context, argv: []const []const u8, flags: Flags) !Child {
    var buffer: [1024]u8 = undefined;
    var terminal = tui.Terminal.open(ctx.io, &buffer) catch |err| switch (err) {
        error.NotATerminal => return runChild(ctx.gpa, ctx.io, argv, flags.show_output),
        error.Canceled => return error.Canceled,
    };
    defer terminal.close();
    const capability = terminal.capabilityIn(ctx.environ);
    if (!capability.escapes) return runChild(ctx.gpa, ctx.io, argv, flags.show_output);

    sys.signal.install();
    defer sys.signal.uninstall();
    var done: Io.Event = .unset;
    var task = ctx.io.concurrent(runAndSignal, .{
        ctx.gpa, ctx.io, argv, flags.show_output, &done,
    }) catch return runChild(ctx.gpa, ctx.io, argv, flags.show_output);
    spin(ctx, &terminal, capability, &done, flags) catch |err| {
        if (task.cancel(ctx.io)) |child| child.deinit(ctx.gpa) else |_| {}
        return err;
    };
    return task.await(ctx.io);
}

/// Animates the spinner on `terminal` until `done` is set, then erases it.
fn spin(
    ctx: *cli.Context,
    terminal: *tui.Terminal,
    capability: tui.capability.Capability,
    done: *Io.Event,
    flags: Flags,
) !void {
    const io = ctx.io;
    var model: live.Spinner = .{ .title = flags.title, .frames = framesOf(flags.spinner) };
    const items = [_]live.Item{.{ .spinner = &model }};
    var display: live.Live = .init(terminal.writer(), capability, &items);
    terminal.recordModes(.{ .hidden_cursor = true });
    defer terminal.recordModes(.{});
    defer display.clear() catch {};
    while (!done.isSet()) {
        try display.draw(.now(io, .awake));
        const timeout: Io.Timeout = .{ .duration = .{ .raw = model.interval, .clock = .awake } };
        done.waitTimeout(io, timeout) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
}

fn runAndSignal(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    show_output: bool,
    done: *Io.Event,
) RunError!Child {
    defer done.set(io);
    return runChild(gpa, io, argv, show_output);
}

/// Runs `argv` to the end: its output captured, or (`show_output`) written directly.
pub fn runChild(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    show_output: bool,
) RunError!Child {
    if (show_output) return .{ .term = try sys.process.stream(io, argv, .{}) };
    const output = try sys.process.capture(gpa, io, argv, .{});
    return .{ .term = output.term, .stdout = output.stdout, .stderr = output.stderr };
}

/// The frames `--spinner` names.
pub fn framesOf(name: Frames) []const []const u8 {
    return switch (name) {
        inline else => |tag| &@field(live.frames, @tagName(tag)),
    };
}

const testing = std.testing;
const builtin = @import("builtin");

test framesOf {
    try testing.expectEqualStrings("-", framesOf(.line)[0]);
    try testing.expectEqual(10, framesOf(.dots).len);
}

test "runChild captures output and status" {
    const windows = builtin.os.tag == .windows;
    const argv: []const []const u8 = if (windows)
        &.{ "cmd.exe", "/c", "echo out& 1>&2 echo err& exit /b 3" }
    else
        &.{ "sh", "-c", "echo out; echo err >&2; exit 3" };
    const child = try runChild(testing.allocator, testing.io, argv, false);
    defer child.deinit(testing.allocator);
    const eol = if (windows) "\r\n" else "\n";
    try testing.expectEqualStrings("out" ++ eol, child.stdout);
    try testing.expectEqualStrings("err" ++ eol, child.stderr);
    try testing.expectEqual(3, sys.process.exitStatus(child.term));
}

test "runChild: a missing command" {
    const argv: []const []const u8 = &.{"termancy-test-no-such-command"};
    const result = runChild(testing.allocator, testing.io, argv, false);
    try testing.expectError(error.FileNotFound, result);
}
