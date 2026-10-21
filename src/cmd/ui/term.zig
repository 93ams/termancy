//! What the gum-style commands share: running a model on the terminal, the Unix rules for
//! how they end, reading items from standard input, and writing styled output.
//!
//! The rules (docs/machine-output.md): the interface always draws on the terminal
//! (standard input and output where they are terminals, `/dev/tty` where not), and results
//! go to standard output, so `x=$(termancy ui choose a b)` works. With no terminal at all, an
//! interactive command fails at once with a usage error, never waiting. Ctrl-C ends with
//! status 130 and esc with status 1, both printing nothing.
//!
//! What gum's commands share, here for every command to use the same way:
//!
//! - `--timeout <duration>` (`cfg.Duration`, `0` for none): `timed` puts it in the
//!   options, and `run` then ends with status 124 and `timed out` on stderr. A command
//!   whose timeout is an answer (confirm takes its current choice) calls `runOutcome`.
//! - `--show-help` and `--padding`: `Framed` draws the key help under a component and
//!   pads the whole.
//! - `--strip-ansi`, `--input-delimiter`, `--output-delimiter`: `items` with `Input`, and
//!   `writeJoined`. Delimiters are typed with escapes (`\n`, `\t`, `\0`).
//! - Style groups (`--cursor.foreground`): styles.zig.
//! - Variables: `.env_prefix = "TERMANCY_<COMMAND>_"` on the flag set.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const tui = @import("tui");
const Io = std.Io;

/// The status after Ctrl-C: 128 + `SIGINT`, as shells report it.
pub const interrupted_status: u8 = 130;

/// The status after `--timeout` passed, as gum's (and `timeout(1)`'s).
pub const timed_out_status: u8 = 124;

/// Help for the flags the commands share, worded once.
pub const help = struct {
    pub const timeout = "End after this long (0 waits forever): status 124, \"timed out\" on stderr";
    pub const show_help = "Show the keys under the component";
    pub const padding = "Space around the component: \"1\", \"1 2\", or \"1 2 1 2\"";
    pub const strip_ansi = "Remove escape sequences from standard input";
    pub const input_delimiter = "What separates items on standard input (\\n, \\t, \\0 work)";
    pub const output_delimiter = "What separates the items printed";
};

/// Runs `model` on the terminal until it quits, updating it in place; returns whether it
/// ended by Ctrl-C. After `Options.timeout`, ends the command with status 124 and
/// `timed out` on stderr. Fails with a usage error when there is no terminal. The model
/// stays the caller's, to read and free as usual.
pub fn run(
    ctx: *cli.Context,
    comptime Model: type,
    model: *Model,
    options: tui.Options,
) !bool {
    const outcome = try runOutcome(ctx, Model, model, options);
    if (outcome.timed_out) return exitTimedOut(ctx);
    return outcome.interrupted;
}

/// `run`, returning how the program ended, timeout included, for a command that reads its
/// model after a timeout as an answer.
pub fn runOutcome(
    ctx: *cli.Context,
    comptime Model: type,
    model: *Model,
    options: tui.Options,
) !tui.Outcome {
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
    return program.run(&terminal);
}

/// `options` ending after `timeout` (`--timeout`); zero waits forever, as gum's.
pub fn timed(options: tui.Options, timeout: cfg.Duration) tui.Options {
    var with = options;
    if (timeout.ns > 0) with.timeout = timeout.toIo();
    return with;
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

/// Ends with status 124 after `--timeout`, writing `timed out` to stderr as gum does. The
/// terminal must already be restored.
pub fn exitTimedOut(ctx: *cli.Context) cli.Context.Exit {
    ctx.err.writeAll("timed out\n") catch {};
    return ctx.exit(timed_out_status);
}

/// How items are read from standard input.
pub const Input = struct {
    /// `--strip-ansi`: escape sequences (colors) go.
    strip_ansi: bool = true,
    /// `--input-delimiter`, as typed: escapes stand for their bytes (see `unescape`).
    delimiter: []const u8 = "\\n",
};

/// The items to choose from: the arguments, or else standard input split at the
/// delimiter. Fails with a usage error when there are no arguments and standard input is
/// a terminal (the items cannot come from where the keys do), and fails when there are no
/// items.
pub fn items(ctx: *cli.Context, input: Input) ![]const []const u8 {
    if (ctx.args.len > 0) return ctx.args;
    const delimiter = try unescape(ctx.arena, input.delimiter);
    if (delimiter.len == 0) return ctx.usageError("--input-delimiter must not be empty", .{});
    var text = try readStdin(ctx) orelse
        return ctx.usageError("no items: give them as arguments or on standard input", .{});
    if (input.strip_ansi) text = try stripAnsi(ctx.arena, text);
    const found = try split(ctx.arena, text, delimiter);
    if (found.len == 0) return ctx.fail("no items to choose from", .{});
    return found;
}

/// `text` without its escape sequences.
pub fn stripAnsi(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
    var out: Io.Writer.Allocating = .init(arena);
    tui.ansi.strip(&out.writer, text) catch return error.OutOfMemory;
    return out.written();
}

/// A delimiter as typed, with `\n`, `\t`, `\r`, `\0`, and `\\` standing for their bytes
/// (so the default reads `\n` in help); any other backslash stays.
pub fn unescape(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
    var out: Io.Writer.Allocating = .init(arena);
    writeUnescaped(&out.writer, text) catch return error.OutOfMemory;
    return out.written();
}

fn writeUnescaped(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte: ?u8 = if (text[i] == '\\' and i + 1 < text.len) switch (text[i + 1]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            '\\' => '\\',
            else => null,
        } else null;
        if (byte) |b| {
            try w.writeByte(b);
            i += 1;
        } else try w.writeByte(text[i]);
    }
}

/// Writes `chosen` with the delimiter (as typed, see `unescape`) between them and a line
/// break after, as gum prints results (`--output-delimiter`).
pub fn writeJoined(
    w: *Io.Writer,
    chosen: []const []const u8,
    delimiter: []const u8,
) Io.Writer.Error!void {
    for (chosen, 0..) |item, i| {
        if (i > 0) try writeUnescaped(w, delimiter);
        try w.writeAll(item);
    }
    try w.writeByte('\n');
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

/// `text` split at each `delimiter` (not empty); a final delimiter ends the last item
/// rather than starting an empty one. At line breaks (`\n`), `\r\n` ends a line too; at
/// anything else, a final line break goes, as `echo` adds one.
pub fn split(
    arena: std.mem.Allocator,
    text: []const u8,
    delimiter: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    std.debug.assert(delimiter.len > 0);
    const by_line = std.mem.eql(u8, delimiter, "\n");
    const rest = if (by_line) text else std.mem.trimEnd(u8, text, "\r\n");
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, rest, delimiter);
    while (it.next()) |item| {
        if (it.index == null and item.len == 0) break;
        try list.append(arena, if (by_line) std.mem.trimEnd(u8, item, "\r") else item);
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

/// The keys the help line under a component shows (`--show-help`), in `tui.Keymap`'s
/// look: `↑/↓ navigate • enter submit`. Only for showing: every action is `.hint`.
pub const Hints = tui.Keymap(enum { hint });
pub const Hint = Hints.Binding;

/// `Inner` with what gum puts around every component: below it, after a blank line, the
/// help line of its keys (`--show-help`); around it all, `--padding`. The component sees
/// the terminal narrower by the padding, so it cuts its rows to fit. An `Inner` with
/// background work (`Message` and `work`, see `tui.Cmd.work`) keeps it.
pub fn Framed(comptime Inner: type) type {
    return struct {
        inner: Inner,
        /// For laying the view out.
        gpa: std.mem.Allocator,
        /// `--padding`.
        padding: tui.Style.Sides = .{},
        /// The help line; none when empty (`--no-show-help`).
        hints: []const Hint = &.{},
        /// Written on the help line before the keys, as gum's table writes `2/10 • `.
        status: ?*const fn (inner: *const Inner, w: *Io.Writer) Io.Writer.Error!void = null,
        /// The terminal's width less the padding, for cutting the help line.
        width: ?usize = null,

        const Self = @This();
        pub const Message = if (@hasDecl(Inner, "Message")) Inner.Message else void;
        // The program runs `work` only when `Message` is not void.
        pub const work = if (@hasDecl(Inner, "work")) Inner.work else {};

        pub fn start(model: *Self) tui.Cmd {
            return if (@hasDecl(Inner, "start")) model.inner.start() else .none;
        }

        // shortcut: mouse rows are not shifted by the padding; offset them when a
        // command runs a framed component with the mouse on.
        pub fn update(model: *Self, msg: tui.Message(Message)) tui.Cmd {
            if (msg != .resize) return model.inner.update(msg);
            var size = msg.resize;
            const sides = model.padding.left + model.padding.right;
            size.width = std.math.lossyCast(u16, size.width -| sides);
            model.width = size.width;
            return model.inner.update(.{ .resize = size });
        }

        pub fn view(model: *const Self, w: *Io.Writer) Io.Writer.Error!void {
            var body: Io.Writer.Allocating = .init(model.gpa);
            defer body.deinit();
            try model.inner.view(&body.writer);
            // The program ignores a final line break; so must the help line below.
            const text = body.written();
            if (std.mem.endsWith(u8, text, "\n")) body.shrinkRetainingCapacity(text.len - 1);
            if (model.hints.len > 0) {
                try body.writer.writeAll("\n\n");
                const line = body.written().len;
                if (model.status) |status| try status(&model.inner, &body.writer);
                const used = tui.width.of(body.written()[line..]);
                const hints: Hints = .{ .bindings = model.hints };
                const width = if (model.width) |width| width -| used else null;
                try hints.writeHelp(&body.writer, .{ .width = width });
            }
            if (std.meta.eql(model.padding, .{})) return w.writeAll(body.written());
            const style: tui.Style = .{ .padding = model.padding };
            try style.render(w, body.written());
        }

        pub fn deinit(model: *Self) void {
            if (@hasDecl(Inner, "deinit")) model.inner.deinit();
        }
    };
}

const testing = std.testing;

test split {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try split(a, "a\r\nb\n\nc\n", "\n");
    try testing.expectEqual(4, got.len);
    try testing.expectEqualStrings("a", got[0]);
    try testing.expectEqualStrings("", got[2]);
    try testing.expectEqualStrings("c", got[3]);
    try testing.expectEqual(0, (try split(a, "", "\n")).len);
    try testing.expectEqual(1, (try split(a, "x", "\n")).len);
    const commas = try split(a, "a,b\r,c,\n", ",");
    try testing.expectEqual(3, commas.len);
    try testing.expectEqualStrings("b\r", commas[1]);
    try testing.expectEqualStrings("c", commas[2]);
    try testing.expectEqual(2, (try split(a, "a::b", "::")).len);
}

test "unescape, stripAnsi, and writeJoined" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\n", try unescape(a, "\\n"));
    try testing.expectEqualStrings("a\tb\x00\\\\x\\", try unescape(a, "a\\tb\\0\\\\\\x\\"));
    try testing.expectEqualStrings(", ", try unescape(a, ", "));
    try testing.expectEqualStrings("red x", try stripAnsi(a, "\x1b[31mred\x1b[0m x"));
    var buffer: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeJoined(&w, &.{ "a", "b" }, "\\n");
    try writeJoined(&w, &.{ "c", "d" }, ", ");
    try writeJoined(&w, &.{}, ",");
    try testing.expectEqualStrings("a\nb\nc, d\n\n", w.buffered());
}

test timed {
    try testing.expectEqual(null, timed(.{}, .zero).timeout);
    const options = timed(inline_options, try .parse("1m30s"));
    try testing.expectEqual(90 * std.time.ns_per_s, options.timeout.?.toNanoseconds());
    try testing.expect(options.clear_on_quit);
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
