//! What the gum-style commands share: running a model on the terminal, the Unix rules for
//! how they end, reading items from standard input, and writing styled output.
//!
//! The rules (docs/machine-output.md): the interface always draws on the terminal
//! (standard input and output where they are terminals, `/dev/tty` where not), and results
//! go to standard output, so `x=$(snek tui choose a b)` works. With no terminal at all, an
//! interactive command fails at once with a usage error, never waiting. Ctrl-C ends with
//! status 130 and esc with status 1, both printing nothing.

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const Io = std.Io;

/// The status after Ctrl-C: 128 + `SIGINT`, as shells report it.
pub const interrupted_status: u8 = 130;

/// Runs `model` on the terminal until it quits, updating it in place; returns whether it
/// ended by Ctrl-C. Fails with a usage error when there is no terminal. The model stays
/// the caller's, to read and free as usual.
pub fn run(
    ctx: *cli.Context,
    comptime Model: type,
    model: *Model,
    options: tui.Options,
) !bool {
    var buffer: [4096]u8 = undefined;
    var terminal = tui.Terminal.open(ctx.io, &buffer) catch |err| switch (err) {
        error.NotATerminal => return noTerminal(ctx),
        error.Canceled => return error.Canceled,
    };
    defer terminal.close();
    var with_capability = options;
    with_capability.capability = terminal.capabilityIn(ctx.environ);
    var program: tui.Program(Model) = .init(ctx.gpa, model, terminal.writer(), with_capability);
    defer program.deinit();
    const outcome = try program.run(&terminal);
    return outcome.interrupted;
}

/// The options interactive commands run with: inline, erased when done.
pub const inline_options: tui.Options = .{ .clear_on_quit = true };

/// `inline_options` with Ctrl-Z suspending, for commands with no text field to undo in.
pub const suspend_options: tui.Options = .{ .clear_on_quit = true, .suspend_on_ctrl_z = true };

/// Reports that there is no terminal to draw on (status 2).
pub fn noTerminal(ctx: *cli.Context) cli.Context.UsageFailure {
    return ctx.usageError(
        "no terminal to draw on: standard input and output are not terminals and " ++
            "/dev/tty cannot be opened",
        .{},
    );
}

/// Ends with status 130 after Ctrl-C, writing nothing more. The terminal must already be
/// restored (`run` has returned).
pub fn exitInterrupted(ctx: *cli.Context) cli.Context.Exit {
    return ctx.exit(interrupted_status);
}

/// The items to choose from: the arguments, or else the lines of standard input. Fails
/// with a usage error when there are no arguments and standard input is a terminal (the
/// items cannot come from where the keys do), and fails when there are no items.
pub fn items(ctx: *cli.Context) ![]const []const u8 {
    if (ctx.args.len > 0) return ctx.args;
    const text = try readStdin(ctx) orelse
        return ctx.usageError("no items: give them as arguments or on standard input", .{});
    const found = try lines(ctx.arena, text);
    if (found.len == 0) return ctx.fail("no items to choose from", .{});
    return found;
}

/// All of standard input, or null when it is a terminal.
pub fn readStdin(ctx: *cli.Context) !?[]const u8 {
    const stdin = Io.File.stdin();
    if (try stdin.isTty(ctx.io)) return null;
    var buffer: [4096]u8 = undefined;
    var reader = stdin.readerStreaming(ctx.io, &buffer);
    return reader.interface.allocRemaining(ctx.arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => |e| ctx.fail("standard input: {s}", .{@errorName(e)}),
    };
}

/// The lines of `text`, without their `\n` or `\r\n`; a final line break ends the last
/// line rather than starting an empty one.
pub fn lines(
    arena: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (it.index == null and line.len == 0) break;
        try list.append(arena, std.mem.trimEnd(u8, line, "\r"));
    }
    return list.items;
}

/// What standard output can show under the environment: colors only on a terminal (or
/// when forced), none under `NO_COLOR`.
pub fn stdoutColor(ctx: *cli.Context) Io.Cancelable!tui.capability.Color {
    const is_tty = try Io.File.stdout().isTty(ctx.io);
    return tui.capability.detect(ctx.environ, .{ .is_tty = is_tty }).color;
}

/// Writes styled `text` for an output that shows `color`: colors lowered to it, and with
/// no color at all, no escapes either (bold and the other attributes go too).
pub fn writeStyled(
    w: *Io.Writer,
    text: []const u8,
    color: tui.capability.Color,
) Io.Writer.Error!void {
    if (color == .none) return tui.ansi.strip(w, text);
    try tui.ansi.downsample(w, text, color);
}

/// A model with a line of text above it, for components that have no header of their own.
pub fn Headed(comptime Inner: type) type {
    return struct {
        header: []const u8,
        inner: Inner,
        style: tui.Style = .{ .fg = .{ .indexed = 99 }, .bold = true },

        const Self = @This();

        pub fn update(model: *Self, msg: tui.Msg) tui.Cmd {
            return model.inner.update(msg);
        }

        pub fn view(model: *const Self, w: *Io.Writer) Io.Writer.Error!void {
            if (model.header.len > 0) {
                try model.style.paint(w, model.header);
                try w.writeByte('\n');
            }
            try model.inner.view(w);
        }
    };
}

const testing = std.testing;

test lines {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try lines(arena.allocator(), "a\r\nb\n\nc\n");
    try testing.expectEqual(4, got.len);
    try testing.expectEqualStrings("a", got[0]);
    try testing.expectEqualStrings("", got[2]);
    try testing.expectEqualStrings("c", got[3]);
    try testing.expectEqual(0, (try lines(arena.allocator(), "")).len);
    try testing.expectEqual(1, (try lines(arena.allocator(), "x")).len);
}

test writeStyled {
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeStyled(&w, "\x1b[1;38;5;212mx\x1b[0m", .none);
    try writeStyled(&w, "\x1b[1;38;5;196my\x1b[0m", .basic);
    try testing.expectEqualStrings("x\x1b[1;91my\x1b[0m", w.buffered());
}

test Headed {
    const Static = struct {
        pub fn update(_: *@This(), _: tui.Msg) tui.Cmd {
            return .quit;
        }
        pub fn view(_: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll("body");
        }
    };
    var d: tui.testing.Driver(Headed(Static)) = try .init(
        testing.allocator,
        .{ .header = "Title", .inner = .{} },
        .{},
    );
    defer d.deinit();
    try d.expectFrame("Title\nbody");
    try d.press("x");
    try testing.expect(d.done());
}
