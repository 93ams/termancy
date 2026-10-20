//! Headless testing: run a `Program` over memory, feed it keys and bytes, move a virtual
//! clock, and check what it drew, both as the view's text and as what a terminal would
//! show after interpreting every byte written.
//!
//! ```zig
//! test "counter counts" {
//!     var driver: tui.testing.Driver(Counter) = try .init(std.testing.allocator, .{}, .{});
//!     defer driver.deinit();
//!     try driver.press("up");
//!     try driver.expectFrame("count: 1");
//!     try driver.press("q");
//!     try std.testing.expect(driver.done());
//! }
//! ```
//!
//! `Screen` is a terminal emulator (`term.vt.Screen`), so tests can check that redraws
//! leave nothing stale behind. `Screen.writeSvg` draws it as an SVG image, for
//! documentation and for reviewing a change by eye.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ansi = @import("term").ansi;
const input = @import("term").input;
const width = @import("term").width;
const golden = @import("term").golden;
const program_zig = @import("Program.zig");
const Size = program_zig.Size;

/// The virtual terminal the driver draws on: `term.vt.Screen`, which interprets every
/// byte a program writes as a real terminal would.
pub const Screen = @import("term").vt.Screen;

/// How `Driver.init` sets up the program and the screen.
pub const DriverOptions = struct {
    program: program_zig.Options = .{},
    /// Passed to `Model.handoff`.
    io: Io = if (@import("builtin").is_test) std.testing.io else undefined,
    /// Written to the screen before the program starts, as earlier output a shell left.
    before: []const u8 = "",
};

/// The compile error for a model's `deinit` of type `F`, which `Driver` cannot call.
fn deinitError(comptime Model: type, comptime F: type) []const u8 {
    const m = @typeName(Model);
    return "tui.testing.Driver(" ++ m ++ "): deinit must be fn (*" ++ m ++ ") void or fn (*" ++
        m ++ ", std.mem.Allocator) void, found " ++ @typeName(F);
}

/// Runs a `Program(Model)` headlessly. The driver owns its model (`deinit` frees it,
/// with `Model.deinit` when declared: `fn (*Model) void` or `fn (*Model, Allocator) void`,
/// given the driver's allocator; any other `deinit` is a compile error) and keeps it and the
/// program on the heap, so a `Driver` may be moved and the model's address stays put.
pub fn Driver(comptime Model: type) type {
    return struct {
        gpa: Allocator,
        output: *Io.Writer.Allocating,
        program: *Program,
        screen: Screen,
        /// Bytes of `output` the screen has interpreted.
        consumed: usize = 0,
        clock: Io.Timestamp = .zero,
        io: Io,
        /// How many times the program stopped the process (Ctrl-Z); the driver continues it
        /// at once, as `fg` would.
        suspends: u32 = 0,

        const Self = @This();
        /// The program type driven.
        pub const Program = program_zig.Program(Model);
        /// What a step can fail with.
        pub const Error = Program.Error;

        /// Creates the program over memory, taking ownership of `initial` (freed on failure
        /// too), and starts it.
        pub fn init(gpa: Allocator, initial: Model, options: DriverOptions) Error!Self {
            const owned = gpa.create(Model) catch |err| {
                var copy = initial;
                freeModel(gpa, &copy);
                return err;
            };
            owned.* = initial;
            errdefer {
                freeModel(gpa, owned);
                gpa.destroy(owned);
            }
            const output = try gpa.create(Io.Writer.Allocating);
            output.* = .init(gpa);
            errdefer {
                output.deinit();
                gpa.destroy(output);
            }
            const program = try gpa.create(Program);
            errdefer gpa.destroy(program);
            program.* = .init(gpa, owned, &output.writer, options.program);
            errdefer program.deinit();
            var d: Self = .{
                .gpa = gpa,
                .output = output,
                .program = program,
                .screen = try .init(gpa, options.program.size),
                .io = options.io,
            };
            errdefer d.screen.deinit();
            d.screen.write(options.before);
            try program.start();
            try d.lend();
            return d;
        }

        /// Frees everything, the model included; the program need not have quit.
        pub fn deinit(d: *Self) void {
            const owned = d.program.model;
            d.program.deinit();
            d.gpa.destroy(d.program);
            freeModel(d.gpa, owned);
            d.gpa.destroy(owned);
            d.screen.deinit();
            d.output.deinit();
            d.gpa.destroy(d.output);
            d.* = undefined;
        }

        fn freeModel(gpa: Allocator, m: *Model) void {
            // A non-pub `deinit` in another file is invisible here, and so skipped.
            if (!@hasDecl(Model, "deinit")) return;
            switch (@TypeOf(Model.deinit)) {
                fn (*Model) void => m.deinit(),
                fn (*Model, Allocator) void => m.deinit(gpa),
                else => |F| @compileError(deinitError(Model, F)),
            }
        }

        /// The model, for inspecting state or calling its methods.
        pub fn model(d: *Self) *Model {
            return d.program.model;
        }

        /// Whether the program has quit.
        pub fn done(d: *const Self) bool {
            return d.program.done();
        }

        /// Whether it quit on Ctrl-C.
        pub fn interrupted(d: *const Self) bool {
            return d.program.interrupted;
        }

        /// Runs background work at once, lends the terminal out while the program asks
        /// to, then syncs the screen.
        fn lend(d: *Self) Error!void {
            if (@hasDecl(Model, "work") and Program.App != void) {
                while (d.program.takeWork()) |work| {
                    try d.program.send(.{ .app = Model.work(d.io, d.gpa, work.id, work.arg) });
                }
            }
            while (d.program.pending != null) {
                const cmd: Cmd = switch (try d.program.release()) {
                    .handoff => |id| if (@hasDecl(Model, "handoff"))
                        d.program.model.handoff(d.io, id)
                    else
                        unreachable,
                    .suspend_process => stop: {
                        d.suspends += 1;
                        break :stop .none;
                    },
                };
                d.sync();
                try d.program.reacquire(cmd);
            }
            d.sync();
        }

        fn sync(d: *Self) void {
            const written = d.output.written();
            d.screen.write(written[d.consumed..]);
            d.consumed = written.len;
        }

        /// Types the key `name` names (see `input.Key.parse`), as the terminal encodes it.
        /// Escape also advances the clock by the escape timeout, as a real keypress would
        /// wait for it.
        pub fn press(d: *Self, comptime name: []const u8) Error!void {
            const key = comptime input.Key.parse(name) catch @compileError("not a key: " ++ name);
            try d.pressKey(key);
        }

        /// `press` for a key built at run time.
        pub fn pressKey(d: *Self, key: input.Key) Error!void {
            var buffer: [32]u8 = undefined;
            var w: Io.Writer = .fixed(&buffer);
            input.encode(&w, .{ .key = key }) catch unreachable; // any key fits in 32 bytes
            try d.feed(w.buffered());
            // A lone ESC becomes the Escape key only after the escape timeout.
            if (key.code == .escape and key.mods.isEmpty()) {
                try d.advance(d.program.options.escape_timeout);
            }
        }

        /// Types `text` as keystrokes.
        pub fn typeText(d: *Self, text: []const u8) Error!void {
            try d.feed(text);
        }

        /// Sends `text` as a bracketed paste.
        pub fn paste(d: *Self, text: []const u8) Error!void {
            var buffer: std.ArrayList(u8) = .empty;
            defer buffer.deinit(d.gpa);
            try buffer.print(d.gpa, "\x1b[200~{s}\x1b[201~", .{text});
            try d.feed(buffer.items);
        }

        /// Feeds raw input bytes.
        pub fn feed(d: *Self, bytes: []const u8) Error!void {
            try d.program.feed(bytes);
            try d.lend();
        }

        /// Delivers a message directly, as `Program.send`.
        pub fn send(d: *Self, msg: Program.Msg) Error!void {
            try d.program.send(msg);
            try d.lend();
        }

        /// Moves the virtual clock forward by `duration`, firing everything due on the way
        /// at the time it is due, so a repeating tick fires once per period. The escape
        /// timeout is a deadline like any other: after a lone ESC, advancing by
        /// `Options.escape_timeout` turns it into the Escape key.
        pub fn advance(d: *Self, duration: Io.Duration) Error!void {
            const target = d.clock.addDuration(duration);
            while (!d.done()) {
                const deadline = d.program.nextDeadline() orelse break;
                if (deadline.nanoseconds > target.nanoseconds) break;
                d.clock = .{ .nanoseconds = @max(deadline.nanoseconds, d.clock.nanoseconds) };
                try d.program.advance(d.clock);
                try d.lend();
            }
            d.clock = target;
            try d.program.advance(d.clock);
            try d.lend();
        }

        /// The terminal changed size.
        pub fn resize(d: *Self, size: Size) Error!void {
            try d.screen.resize(size);
            try d.program.resize(size);
            try d.lend();
        }

        /// Ends the program as if its input closed.
        pub fn stop(d: *Self) Error!void {
            try d.program.stop();
            d.sync();
        }

        /// The current frame as the view wrote it, escapes included (colors not yet
        /// lowered to the capability).
        pub fn frameBytes(d: *const Self) []const u8 {
            return d.program.frame.items;
        }

        /// Everything written to the terminal so far.
        pub fn outputBytes(d: *Self) []const u8 {
            return d.output.written();
        }

        /// The current frame as plain text, escapes stripped. Caller frees.
        pub fn frameText(d: *const Self, gpa: Allocator) Allocator.Error![]u8 {
            var text: Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            ansi.strip(&text.writer, d.program.frame.items) catch return error.OutOfMemory;
            return text.toOwnedSlice();
        }

        /// What the virtual terminal shows. Caller frees.
        pub fn screenText(d: *Self, gpa: Allocator) Allocator.Error![]u8 {
            var text: Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            d.screen.writeText(&text.writer) catch return error.OutOfMemory;
            return text.toOwnedSlice();
        }

        /// What the virtual terminal shows, as `writeTrimmed` writes it: for printing a
        /// snapshot. Caller frees.
        pub fn screenTextTrimmed(d: *Self, gpa: Allocator) Allocator.Error![]u8 {
            const text = try d.screenText(gpa);
            defer gpa.free(text);
            var out: Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            writeTrimmed(&out.writer, text) catch return error.OutOfMemory;
            return out.toOwnedSlice();
        }

        /// Fails unless the frame, as plain text, is `expected`.
        pub fn expectFrame(d: *const Self, expected: []const u8) !void {
            const text = try d.frameText(d.gpa);
            defer d.gpa.free(text);
            try std.testing.expectEqualStrings(expected, text);
        }

        /// Fails unless the frame, as plain text, contains `needle`.
        pub fn expectFrameContains(d: *const Self, needle: []const u8) !void {
            const text = try d.frameText(d.gpa);
            defer d.gpa.free(text);
            if (std.mem.indexOf(u8, text, needle) == null) {
                std.debug.print("frame does not contain \"{s}\":\n{s}\n", .{ needle, text });
                return error.TestExpectedContains;
            }
        }

        /// Checks the screen's text against the golden file at `path` (see `term.golden`;
        /// `TERMANCY_UPDATE_GOLDEN=1` rewrites it).
        pub fn expectScreenGolden(d: *Self, path: []const u8) !void {
            const text = try d.screenText(d.gpa);
            defer d.gpa.free(text);
            try golden.expect(d.io, path, text, .{});
        }

        /// Checks every byte the program has written (escape sequences as text) against
        /// the golden file at `path`.
        pub fn expectOutputGolden(d: *Self, path: []const u8) !void {
            try golden.expect(d.io, path, d.outputBytes(), .{});
        }

        /// Moves the clock on by `step` until the screen shows `needle`, for at most
        /// `limit`; whether it showed. For waiting on spinners, timers, and background work
        /// without guessing how long they take.
        pub fn advanceUntil(
            d: *Self,
            needle: []const u8,
            step: Io.Duration,
            limit: Io.Duration,
        ) Error!bool {
            var waited: i96 = 0;
            while (true) {
                if (d.screen.contains(needle)) return true;
                if (waited >= limit.nanoseconds or d.done()) return false;
                try d.advance(step);
                waited += step.nanoseconds;
            }
        }

        /// Fails unless the virtual terminal shows `expected`.
        pub fn expectScreen(d: *Self, expected: []const u8) !void {
            const text = try d.screenText(d.gpa);
            defer d.gpa.free(text);
            try std.testing.expectEqualStrings(expected, text);
        }
    };
}

/// Writes a screen's `text` as lines without trailing spaces, each ending in a newline,
/// leaving out the empty lines at the bottom.
pub fn writeTrimmed(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    const shown = std.mem.trimEnd(u8, text, "\n ");
    if (shown.len == 0) return;
    var lines = std.mem.splitScalar(u8, shown, '\n');
    while (lines.next()) |line| try w.print("{s}\n", .{std.mem.trimEnd(u8, line, " ")});
}

const testing = std.testing;
const Cmd = program_zig.Cmd;
const Msg = program_zig.Msg;

fn expectScreenText(screen: *Screen, expected: []const u8) !void {
    var text: Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try screen.writeText(&text.writer);
    try testing.expectEqualStrings(expected, text.written());
}

test "Screen: printing, wrapping, and the pending-wrap column" {
    var screen: Screen = try .init(testing.allocator, .{ .width = 4, .height = 3 });
    defer screen.deinit();
    screen.write("abcd");
    try testing.expect(screen.pending_wrap);
    try testing.expectEqual(0, screen.row);
    screen.write("ef");
    try expectScreenText(&screen, "abcd\nef");
    screen.write("\r\nab中");
    try expectScreenText(&screen, "abcd\nef\nab中");
    screen.write("\x1b[K"); // a pending wrap leaves the cursor on the last column
    try expectScreenText(&screen, "abcd\nef\nab");
    screen.write("x"); // a full screen scrolls
    try expectScreenText(&screen, "ef\nab\nx");
}

test "Screen: wide characters wrap whole, and scrolling" {
    var screen: Screen = try .init(testing.allocator, .{ .width = 3, .height = 2 });
    defer screen.deinit();
    screen.write("ab中");
    try expectScreenText(&screen, "ab\n中");
    screen.write("\r\nxyz");
    try expectScreenText(&screen, "中\nxyz");
}

test "Screen: cursor movement and erasing" {
    var screen: Screen = try .init(testing.allocator, .{ .width = 5, .height = 4 });
    defer screen.deinit();
    screen.write("11111\r\n22222\r\n33333\r\n44444");
    screen.write("\x1b[2A\x1b[3G\x1b[K");
    try expectScreenText(&screen, "11111\n22\n33333\n44444");
    screen.write("\x1b[1;2H\x1b[1K");
    try expectScreenText(&screen, "  111\n22\n33333\n44444");
    screen.write("\x1b[2;1H\x1b[J");
    try expectScreenText(&screen, "  111");
    screen.write("\x1b[2J");
    try expectScreenText(&screen, "");
}

test "Screen: the alternate screen keeps the main one" {
    var screen: Screen = try .init(testing.allocator, .{ .width = 5, .height = 2 });
    defer screen.deinit();
    screen.write("main");
    screen.write("\x1b[?1049h\x1b[Halt");
    try expectScreenText(&screen, "alt");
    screen.write("\x1b[?1049l");
    try expectScreenText(&screen, "main");
    try testing.expectEqual(4, screen.column);
}

/// A list the tests drive: arrow keys move, enter quits, ticks count, `.app` appends.
const Menu = struct {
    items: []const []const u8 = &.{ "apple", "banana", "cherry" },
    cursor: usize = 0,
    ticks: u32 = 0,
    size: Size = .{ .width = 0, .height = 0 },
    pasted: [32]u8 = undefined,
    pasted_len: usize = 0,
    focused: ?bool = null,
    extra_lines: usize = 0,
    long_line: bool = false,
    started: bool = false,
    background: ?ansi.Color.Rgb = null,
    replies_done: bool = false,

    pub const Message = u8;

    pub fn start(m: *Menu) Cmd {
        m.started = true;
        return .tick(.fromMilliseconds(100), 1);
    }

    pub fn update(m: *Menu, msg: program_zig.Message(u8)) Cmd {
        switch (msg) {
            .report => |report| switch (report) {
                .background => |rgb| m.background = rgb,
                .device_attributes => m.replies_done = true,
                else => {},
            },
            .key => |key| {
                if (key.matches("enter")) return .quit;
                if (key.matches("down")) m.cursor = @min(m.cursor + 1, m.items.len - 1);
                if (key.matches("up")) m.cursor -|= 1;
                if (key.matches("+")) m.extra_lines += 1;
                if (key.matches("-")) m.extra_lines -|= 1;
                if (key.matches("l")) m.long_line = !m.long_line;
                if (key.matches("esc")) return .batch(&.{ .tick(.fromMilliseconds(1), 9), .quit });
            },
            .tick => |id| {
                if (id == 1) {
                    m.ticks += 1;
                    return .tick(.fromMilliseconds(100), 1);
                }
            },
            .resize => |size| m.size = size,
            .paste => |text| {
                m.pasted_len = @min(text.len, m.pasted.len);
                @memcpy(m.pasted[0..m.pasted_len], text[0..m.pasted_len]);
            },
            .focus => |focused| m.focused = focused,
            .app => |extra| m.extra_lines = extra,
            .mouse => |mouse| m.cursor = @min(mouse.y, m.items.len - 1),
            .resumed => {},
        }
        return .none;
    }

    pub fn view(m: *const Menu, w: *Io.Writer) Io.Writer.Error!void {
        for (m.items, 0..) |item, i| {
            if (i == m.cursor) {
                try w.print("\x1b[1m> {s}\x1b[0m\n", .{item});
            } else {
                try w.print("  {s}\n", .{item});
            }
        }
        for (0..m.extra_lines) |i| try w.print("extra {d}\n", .{i});
        if (m.long_line) try w.writeAll("0123456789abcdefghijKLMNO\n");
    }
};

const MenuDriver = Driver(Menu);

fn startMenu(d: *MenuDriver, options: DriverOptions) !void {
    d.* = try .init(testing.allocator, .{}, options);
}

test "Driver: first frame, keys, and quit in inline mode" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{
        .program = .{ .size = .{ .width = 20, .height = 10 } },
        .before = "$ termancy\r\n",
    });
    defer d.deinit();
    try testing.expect(d.model().started);
    try testing.expectEqual(Size{ .width = 20, .height = 10 }, d.model().size);
    try d.expectFrame("> apple\n  banana\n  cherry");
    try d.expectScreen("$ termancy\n> apple\n  banana\n  cherry");
    try testing.expect(!d.screen.cursor_visible);
    try d.press("down");
    try d.expectFrame("  apple\n> banana\n  cherry");
    try d.expectScreen("$ termancy\n  apple\n> banana\n  cherry");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expect(!d.interrupted());
    // The final frame stays, the cursor is back and below it.
    try d.expectScreen("$ termancy\n  apple\n> banana\n  cherry");
    try testing.expect(d.screen.cursor_visible);
    try testing.expectEqual(4, d.screen.row);
    try testing.expectEqual(0, d.screen.column);
    try testing.expect(std.mem.endsWith(u8, d.outputBytes(), "\x1b[?2004l\x1b[?25h"));
}

test "Driver: the exact bytes of a first frame and a redraw" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .size = .{ .width = 20, .height = 10 } } });
    defer d.deinit();
    try testing.expectEqualStrings(
        "\x1b[?25l\x1b[?2004h" ++
            "\x1b[?2026h" ++
            "\x1b[1m> apple\x1b[0m\r\n  banana\r\n  cherry" ++
            "\x1b[?2026l",
        d.outputBytes(),
    );
    const before = d.outputBytes().len;
    try d.press("down");
    try testing.expectEqualStrings(
        // Only the cells that changed: both rows' first columns and the boldness.
        "\x1b[?2026h" ++
            "\r\x1b[2A  apple" ++
            "\r\x1b[1B\x1b[1m> banana\x1b[0m" ++
            "\r\x1b[1B" ++
            "\x1b[?2026l",
        d.outputBytes()[before..],
    );
    // An unchanged view draws nothing.
    const after = d.outputBytes().len;
    try d.press("x");
    try testing.expectEqual(after, d.outputBytes().len);
}

test "Driver: growing and shrinking frames leave nothing behind" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{
        .program = .{ .size = .{ .width = 20, .height = 10 } },
        .before = "prompt\r\n",
    });
    defer d.deinit();
    try d.press("+");
    try d.press("+");
    try d.expectScreen("prompt\n> apple\n  banana\n  cherry\nextra 0\nextra 1");
    try d.press("-");
    try d.expectScreen("prompt\n> apple\n  banana\n  cherry\nextra 0");
    try d.press("-");
    try d.expectScreen("prompt\n> apple\n  banana\n  cherry");
}

test "Driver: wrapped lines are counted when redrawing" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{
        .program = .{ .size = .{ .width = 10, .height = 10 } },
        .before = "top\r\n",
    });
    defer d.deinit();
    try d.press("l"); // a 25-column line: three rows at width 10
    try d.expectScreen("top\n> apple\n  banana\n  cherry\n0123456789\nabcdefghij\nKLMNO");
    try d.press("down");
    try d.expectScreen("top\n  apple\n> banana\n  cherry\n0123456789\nabcdefghij\nKLMNO");
    try d.press("l");
    try d.expectScreen("top\n  apple\n> banana\n  cherry");
    try d.press("up");
    try d.expectScreen("top\n> apple\n  banana\n  cherry");
}

test "Driver: a line exactly as wide as the terminal takes one row" {
    const Exact = struct {
        lines: u8 = 2,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key) m.lines -= 1;
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            for (0..m.lines) |_| try w.writeAll("0123456789\n");
        }
    };
    var d: Driver(Exact) = try .init(testing.allocator, .{}, .{
        .program = .{ .size = .{ .width = 10, .height = 5 } },
        .before = "x\r\n",
    });
    defer d.deinit();
    try d.expectScreen("x\n0123456789\n0123456789");
    try d.press("a");
    try d.expectScreen("x\n0123456789");
}

test "Driver: a model's deinit may take the driver's allocator" {
    const Owning = struct {
        text: []u8,
        pub fn update(_: *@This(), _: Msg) Cmd {
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll(m.text);
        }
        pub fn deinit(m: *@This(), gpa: Allocator) void {
            gpa.free(m.text);
        }
    };
    // testing.allocator reports the text as a leak if deinit is skipped.
    const text = try testing.allocator.dupe(u8, "owned");
    var d: Driver(Owning) = try .init(testing.allocator, .{ .text = text }, .{});
    defer d.deinit();
    try d.expectScreen("owned");
}

test "Driver: a frame taller than the terminal keeps its last rows" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .size = .{ .width = 20, .height = 4 } } });
    defer d.deinit();
    for (0..3) |_| try d.press("+");
    try d.expectScreen("  cherry\nextra 0\nextra 1\nextra 2");
    try d.press("-");
    try d.expectScreen("  banana\n  cherry\nextra 0\nextra 1");
    try d.expectFrame("> apple\n  banana\n  cherry\nextra 0\nextra 1");
}

test "Driver: Ctrl-C interrupts without reaching the model" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .clear_on_quit = true }, .before = "$ cmd\r\n" });
    defer d.deinit();
    try d.press("ctrl+c");
    try testing.expect(d.done());
    try testing.expect(d.interrupted());
    try d.expectScreen("$ cmd");
    try testing.expectEqual(1, d.screen.row);
    // Nothing reaches a finished program.
    try d.press("down");
    try testing.expectEqual(0, d.model().cursor);
}

test "Driver: with interrupt off, Ctrl-C is a key" {
    const Keys = struct {
        last: ?input.Key = null,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key) m.last = msg.key;
            return .none;
        }
        // An inferred error set works as well as an explicit one.
        pub fn view(_: *const @This(), w: *Io.Writer) !void {
            try w.writeAll("keys");
        }
    };
    var d: Driver(Keys) = try .init(
        testing.allocator,
        .{},
        .{ .program = .{ .interrupt = false } },
    );
    defer d.deinit();
    try d.press("ctrl+c");
    try testing.expect(!d.done());
    try testing.expect(d.model().last.?.matches("ctrl+c"));
    try d.press("esc");
    try testing.expect(d.model().last.?.matches("esc"));
}

test "Driver: advanceUntil, and screens and output against golden files" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{});
    defer d.deinit();
    try testing.expect(try d.advanceUntil("apple", .fromMilliseconds(10), .fromMilliseconds(50)));
    try testing.expect(
        !try d.advanceUntil("mango", .fromMilliseconds(100), .fromMilliseconds(300)),
    );
    try testing.expectEqual(3, d.model().ticks);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const screen_path = try std.fs.path.join(testing.allocator, &.{ dir, "screen.golden" });
    defer testing.allocator.free(screen_path);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "screen.golden",
        .data = "> apple\n  banana\n  cherry",
    });
    try d.expectScreenGolden(screen_path);
    const output_path = try std.fs.path.join(testing.allocator, &.{ dir, "output.golden" });
    defer testing.allocator.free(output_path);
    // A mismatch would print to standard error, which fails the build's test step: write
    // the file first, then check against it.
    try golden.expect(testing.io, output_path, d.outputBytes(), .{ .update = true });
    try d.expectOutputGolden(output_path);
}

test "Driver: ticks fire on the virtual clock and repeat" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{});
    defer d.deinit();
    try d.advance(.fromMilliseconds(99));
    try testing.expectEqual(0, d.model().ticks);
    try d.advance(.fromMilliseconds(1));
    try testing.expectEqual(1, d.model().ticks);
    try d.advance(.fromMilliseconds(450));
    try testing.expectEqual(5, d.model().ticks);
    try testing.expectEqual(
        600,
        @divExact(d.program.nextDeadline().?.nanoseconds, std.time.ns_per_ms),
    );
}

test "Driver: a batch command and the escape timeout" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{});
    defer d.deinit();
    try d.feed("\x1b");
    try testing.expect(!d.done()); // waiting: maybe the start of a sequence
    try d.advance(.fromMilliseconds(10));
    try testing.expect(!d.done());
    try d.advance(.fromMilliseconds(50));
    try testing.expect(d.done()); // the lone ESC became the Escape key, which quits
}

test "Driver: an escape sequence split across reads is one key" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{});
    defer d.deinit();
    try d.feed("\x1b[");
    try d.feed("B");
    try testing.expectEqual(1, d.model().cursor);
}

test "Driver: paste, focus, mouse, and application messages" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .mouse = true, .focus_events = true } });
    defer d.deinit();
    try testing.expect(
        std.mem.startsWith(u8, d.outputBytes(), "\x1b[?25l\x1b[?2004h" ++
            "\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1004h"),
    );
    try d.paste("hello\nthere");
    try testing.expectEqualStrings("hello\nthere", d.model().pasted[0..d.model().pasted_len]);
    try d.feed("\x1b[O");
    try testing.expectEqual(false, d.model().focused.?);
    try d.feed("\x1b[<0;3;3M");
    try testing.expectEqual(2, d.model().cursor);
    try d.send(.{ .app = 2 });
    try d.expectFrameContains("extra 1");
    try d.stop();
    try testing.expect(d.done());
    try testing.expect(
        std.mem.endsWith(u8, d.outputBytes(), "\x1b[?1006l\x1b[?1002l\x1b[?1000l" ++
            "\x1b[?1004l\x1b[?2004l\x1b[?25h"),
    );
}

test "Driver: full-screen mode draws from the top and restores the main screen" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{
        .program = .{ .alt_screen = true, .size = .{ .width = 20, .height = 3 } },
        .before = "shell",
    });
    defer d.deinit();
    try testing.expect(d.screen.on_alt);
    try d.expectScreen("> apple\n  banana\n  cherry");
    try d.press("+");
    try d.expectScreen("> apple\n  banana\n  cherry"); // the bottom is cut off
    try d.press("down");
    try d.expectScreen("  apple\n> banana\n  cherry");
    try d.press("enter");
    try testing.expect(!d.screen.on_alt);
    try d.expectScreen("shell");
}

test "Driver: resize redraws and tells the model" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{
        .program = .{ .size = .{ .width = 20, .height = 10 } },
        .before = "p\r\n",
    });
    defer d.deinit();
    const before = d.outputBytes().len;
    try d.resize(.{ .width = 30, .height = 8 });
    try testing.expectEqual(Size{ .width = 30, .height = 8 }, d.model().size);
    try testing.expect(d.outputBytes().len > before); // redrawn though the view is the same
    try d.expectScreen("p\n> apple\n  banana\n  cherry");
    try d.press("down");
    try d.expectScreen("p\n  apple\n> banana\n  cherry");
    try d.resize(.{ .width = 30, .height = 8 }); // the same size: nothing to do
}

test "Driver: after narrowing, the terminal's cursor says whether the old frame reflowed" {
    // The cursor ends the frame after "  cherry", on column 8; at 6 wide it would be on
    // column 2 if the terminal rewrapped the lines, and on 5 (the last) if it cut them.
    const Case = struct { reply: []const u8, erase: []const u8 };
    for ([_]Case{
        // Rewrapped: each 7- and 8-column line takes 2 rows.
        .{ .reply = "\x1b[?5;3R", .erase = "\x1b[?2026h\r\x1b[5A\x1b[J" },
        // Cut: a row each.
        .{ .reply = "\x1b[?3;6R", .erase = "\x1b[?2026h\r\x1b[2A\x1b[J" },
    }) |case| {
        var d: MenuDriver = undefined;
        try startMenu(&d, .{ .program = .{ .size = .{ .width = 20, .height = 10 } } });
        defer d.deinit();
        const before = d.outputBytes().len;
        try d.program.resize(.{ .width = 6, .height = 10 });
        // The redraw waits for the answer.
        try testing.expectEqualStrings("\x1b[?6n", d.outputBytes()[before..]);
        try d.feed(case.reply);
        try testing.expect(std.mem.startsWith(u8, d.outputBytes()[before + 5 ..], case.erase));
        // Learned: the next narrowing asks nothing.
        const again = d.outputBytes().len;
        try d.program.resize(.{ .width = 4, .height = 10 });
        try testing.expect(std.mem.indexOf(u8, d.outputBytes()[again..], "\x1b[?6n") == null);
    }
}

test "Driver: a terminal that does not answer keeps the guess, after a moment" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .size = .{ .width = 20, .height = 10 } } });
    defer d.deinit();
    const before = d.outputBytes().len;
    try d.program.resize(.{ .width = 6, .height = 10 });
    try d.advance(.fromMilliseconds(99));
    try testing.expectEqualStrings("\x1b[?6n", d.outputBytes()[before..]);
    try d.advance(.fromMilliseconds(1));
    // `Capability.reflows`, true by default: the rewrapped rows.
    try testing.expect(std.mem.startsWith(u8, d.outputBytes()[before + 5 ..], "\x1b[?2026h\r\x1b[5A\x1b[J"));
    // Not asked again.
    const again = d.outputBytes().len;
    try d.program.resize(.{ .width = 4, .height = 10 });
    try testing.expect(std.mem.indexOf(u8, d.outputBytes()[again..], "\x1b[?6n") == null);
}

test "Driver: without escapes, only the final frame is written, as plain text" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .capability = .plain } });
    defer d.deinit();
    try d.press("down");
    try testing.expectEqualStrings("", d.outputBytes());
    try d.press("enter");
    try testing.expectEqualStrings("  apple\n> banana\n  cherry\n", d.outputBytes());
}

test "Driver: colors are lowered to the capability" {
    const Colored = struct {
        pub fn update(_: *@This(), _: Msg) Cmd {
            return .none;
        }
        pub fn view(_: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll("\x1b[38;2;255;0;0mred\x1b[0m");
        }
    };
    var d: Driver(Colored) = try .init(testing.allocator, .{}, .{
        .program = .{ .capability = .{ .color = .basic, .escapes = true } },
    });
    defer d.deinit();
    try testing.expect(std.mem.indexOf(u8, d.outputBytes(), "\x1b[91mred") != null);
    try testing.expectEqualStrings("\x1b[38;2;255;0;0mred\x1b[0m", d.frameBytes());
}

test "Driver: a view error reaches the caller" {
    const Failing = struct {
        fail: bool = false,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key) m.fail = true;
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) error{ WriteFailed, Broken }!void {
            if (m.fail) return error.Broken;
            try w.writeAll("ok");
        }
    };
    var d: Driver(Failing) = try .init(testing.allocator, .{}, .{});
    defer d.deinit();
    try testing.expectError(error.Broken, d.press("a"));
}

/// The rows a terminal of `columns` by `height` shows for `text` drawn inline: each line
/// cut every `columns` columns (ASCII only), the last `height` rows, trailing spaces and
/// blank rows at the end dropped.
fn visibleRows(gpa: Allocator, text: []const u8, columns: usize, height: usize) ![]u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var rest = line;
        while (true) {
            const row = rest[0..@min(rest.len, columns)];
            try rows.append(gpa, std.mem.trimEnd(u8, row, " "));
            rest = rest[row.len..];
            if (rest.len == 0) break;
        }
    }
    const shown = rows.items[rows.items.len -| height..];
    const joined = try std.mem.join(gpa, "\n", shown);
    var end = joined.len;
    while (end > 0 and joined[end - 1] == '\n') end -= 1;
    return gpa.realloc(joined, end);
}

/// The rows a terminal of `columns` shows for `text`: each line cut every `columns`
/// columns (ASCII only), trailing spaces and blank rows at the end dropped.
fn expectedRows(gpa: Allocator, text: []const u8, columns: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var rest = line;
        while (true) {
            const row = rest[0..@min(rest.len, columns)];
            try out.appendSlice(gpa, std.mem.trimEnd(u8, row, " "));
            try out.append(gpa, '\n');
            rest = rest[row.len..];
            if (rest.len == 0) break;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

test "Driver: random input never breaks the program, and the screen always matches" {
    var prng: std.Random.DefaultPrng = .init(0xdecaf);
    const random = prng.random();
    const gpa = testing.allocator;
    for (0..60) |_| {
        var d: MenuDriver = undefined;
        try startMenu(&d, .{
            .program = .{ .size = .{ .width = 7, .height = 5 }, .interrupt = random.boolean() },
        });
        defer d.deinit();
        for (0..40) |_| {
            if (d.done()) break;
            const keys = "++--l\x1b[A\x1b[Bxy";
            var bytes: [8]u8 = undefined;
            for (&bytes) |*b| {
                const key = keys[random.uintLessThan(usize, keys.len)];
                b.* = if (random.boolean()) key else random.int(u8);
            }
            try d.feed(bytes[0..random.uintLessThan(usize, bytes.len)]);
            try d.advance(.fromMilliseconds(random.intRangeLessThan(i64, 0, 200)));
            if (d.done()) break;
            const plain = try std.fmt.allocPrint(gpa, "{f}", .{stripped(d.program.frame.items)});
            defer gpa.free(plain);
            const expected = try visibleRows(gpa, plain, 7, 5);
            defer gpa.free(expected);
            try d.expectScreen(expected);
        }
    }
}

fn stripped(text: []const u8) Stripped {
    return .{ .text = text };
}

const Stripped = struct {
    text: []const u8,
    pub fn format(s: Stripped, w: *Io.Writer) Io.Writer.Error!void {
        try ansi.strip(w, s.text);
    }
};

test "Driver: redrawing changed lines shows what redrawing everything shows" {
    const Frames = struct {
        text: []const u8 = "",
        pub const Message = []const u8;
        pub fn update(m: *@This(), msg: program_zig.Message([]const u8)) Cmd {
            if (msg == .app) m.text = msg.app;
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll(m.text);
        }
    };
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x11fe);
    const random = prng.random();
    const words = [_][]const u8{ "a", "bb", "\x1b[1mcc\x1b[0m", "12345678", "dddddd", "" };
    for (0..200) |round| {
        const options: DriverOptions = .{
            .program = .{ .size = .{ .width = 8, .height = 6 }, .alt_screen = round % 2 == 0 },
            .before = "$ run\r\n",
        };
        var diffing: Driver(Frames) = try .init(gpa, .{}, options);
        defer diffing.deinit();
        var whole: Driver(Frames) = try .init(gpa, .{}, options);
        defer whole.deinit();
        var frames: [12]std.ArrayList(u8) = @splat(.empty);
        defer for (&frames) |*f| f.deinit(gpa);
        for (&frames) |*frame| {
            // Mostly short lines that line up, now and then one that wraps.
            for (0..random.uintAtMost(usize, 8)) |i| {
                if (i > 0) try frame.append(gpa, '\n');
                try frame.appendSlice(gpa, words[random.uintLessThan(usize, words.len)]);
                if (random.uintLessThan(u8, 12) == 0) try frame.appendSlice(gpa, "-wrapping");
            }
            try diffing.send(.{ .app = frame.items });
            whole.program.dirty = true;
            whole.program.redraw = true;
            try whole.send(.{ .app = frame.items });
            const expected = try whole.screenText(gpa);
            defer gpa.free(expected);
            try diffing.expectScreen(expected);
            try testing.expectEqual(whole.screen.row, diffing.screen.row);
        }
    }
}

test "Driver: a handoff gives the terminal up and takes it back" {
    const Editor = struct {
        edited: u32 = 0,
        /// `edited` when "x" arrived.
        x_after: ?u32 = null,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key and msg.key.matches("e")) return .handoff(7);
            if (msg == .key and msg.key.matches("x")) m.x_after = m.edited;
            return .none;
        }
        pub fn handoff(m: *@This(), _: Io, id: u32) Cmd {
            assert(id == 7);
            m.edited += 1;
            return .tick(.fromMilliseconds(5), 1);
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("edited {d}\nline two", .{m.edited});
        }
    };
    var d: Driver(Editor) = try .init(testing.allocator, .{}, .{ .before = "$ app\r\n" });
    defer d.deinit();
    try d.expectScreen("$ app\nedited 0\nline two");
    const before = d.outputBytes().len;
    // "e" hands off; "x" arrives meanwhile and is delivered after.
    try d.typeText("ex");
    try testing.expectEqual(1, d.model().edited);
    try testing.expectEqual(1, d.model().x_after);
    const out = d.outputBytes()[before..];
    // The frame was erased and the cursor shown before the handoff, hidden again after.
    const shown = std.mem.indexOf(u8, out, "\x1b[?25h").?;
    const hidden = std.mem.indexOf(u8, out, "\x1b[?25l").?;
    try testing.expect(std.mem.indexOf(u8, out[0..shown], "\x1b[J") != null);
    try testing.expect(shown < hidden);
    try d.expectScreen("$ app\nedited 1\nline two");
    try testing.expect(!d.screen.cursor_visible);
    try testing.expectEqual(1, d.program.timers.items.len);
}

test "Driver: with suspend_on_ctrl_z, ctrl+z suspends without reaching the model" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .suspend_on_ctrl_z = true } });
    defer d.deinit();
    try d.press("ctrl+z");
    try testing.expectEqual(1, d.suspends);
    try testing.expect(!d.done());
    try d.press("down");
    try d.expectFrame("  apple\n> banana\n  cherry");
}

test "Driver: queries go out at start and replies arrive as reports" {
    var d: MenuDriver = undefined;
    try startMenu(&d, .{ .program = .{ .queries = .{
        .background = true,
        .modes = &.{.synchronized_output},
    } } });
    defer d.deinit();
    const out = d.outputBytes();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]11;?\x1b\\\x1b[?2026$p\x1b[c") != null);
    try d.feed("\x1b]11;rgb:0000/0000/0000\x1b\\\x1b[?62c");
    try testing.expect(d.model().background.?.isDark());
    try testing.expect(d.model().replies_done);
    // Nothing reaches the screen or the frame.
    try d.expectFrame("> apple\n  banana\n  cherry");
}

const Loader = struct {
    results: [4]u64 = @splat(0),
    received: usize = 0,
    log: [2][]const u8 = .{ "", "" },
    log_len: usize = 0,
    presses: usize = 0,

    pub const Message = struct { id: u32, value: u64 };

    pub fn update(m: *Loader, msg: program_zig.Message(Message)) Cmd {
        switch (msg) {
            .key => |key| {
                if (key.matches("l")) return .batch(&.{ .work(1, 20), .work(2, 21) });
                if (key.matches("p")) {
                    m.log[m.log_len] = if (m.presses == 0) "first line" else "second line";
                    m.log_len += 1;
                    m.presses += 1;
                }
            },
            .app => |result| {
                m.results[result.id] = result.value;
                m.received += 1;
            },
            else => {},
        }
        return .none;
    }

    pub fn work(_: Io, _: Allocator, id: u32, arg: u64) Message {
        return .{ .id = id, .value = arg * 2 };
    }

    pub fn above(m: *Loader, w: *Io.Writer) Io.Writer.Error!void {
        for (m.log[0..m.log_len]) |line| try w.print("{s}\n", .{line});
        m.log_len = 0;
    }

    pub fn view(m: *const Loader, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("got {d}: {d} {d}", .{ m.received, m.results[1], m.results[2] });
    }
};

test "Driver: background work delivers its results as messages" {
    var d: Driver(Loader) = try .init(testing.allocator, .{}, .{});
    defer d.deinit();
    try d.press("l");
    try d.expectFrame("got 2: 40 42");
}

test "Driver: lines printed above stay above the frame" {
    var d: Driver(Loader) = try .init(testing.allocator, .{}, .{ .before = "$ app\r\n" });
    defer d.deinit();
    try d.press("p");
    try d.expectScreen("$ app\nfirst line\ngot 0: 0 0");
    try d.press("p");
    try d.press("l");
    try d.expectScreen("$ app\nfirst line\nsecond line\ngot 2: 40 42");
}

test "Screen: colors and attributes, and the SVG image" {
    var screen: Screen = try .init(testing.allocator, .{ .width = 6, .height = 3 });
    defer screen.deinit();
    screen.write("\x1b[1;31mab\x1b[0m c\r\n\x1b[48;5;21m<&\x1b[m");
    try testing.expect(screen.cell(0, 0).pen.bold);
    try testing.expectEqual(ansi.Color.red, screen.cell(0, 1).pen.fg);
    try testing.expectEqual(ansi.Color.default, screen.cell(0, 3).pen.fg);
    try testing.expectEqual(ansi.Color{ .indexed = 21 }, screen.cell(1, 0).pen.bg);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try screen.writeSvg(&out.writer, .{});
    const svg = out.written();
    try testing.expect(std.mem.startsWith(u8, svg, "<svg xmlns="));
    try testing.expect(std.mem.indexOf(u8, svg, "fill=\"#cd0000\" font-weight=\"bold\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, ">ab</text>") != null);
    try testing.expect(std.mem.indexOf(u8, svg, ">&lt;&amp;</text>") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "fill=\"#0000ff\"/>") != null);
    try testing.expect(std.mem.endsWith(u8, svg, "</svg>\n"));
}

test "Driver: the terminal's cursor goes where the model says" {
    const Field = struct {
        text: []const u8 = "name: ada",
        at: ?usize = 6,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key and msg.key.matches("left")) m.at = if (m.at) |x| x -| 1 else null;
            if (msg == .key and msg.key.matches("h")) m.at = null;
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("title\n{s}", .{m.text});
        }
        pub fn cursor(m: *const @This()) ?program_zig.Cursor {
            const x = m.at orelse return null;
            return .{ .x = x, .y = 1, .shape = .block, .blink = false };
        }
    };
    var d: Driver(Field) = try .init(testing.allocator, .{}, .{});
    defer d.deinit();
    try testing.expect(d.screen.cursor_visible);
    try testing.expectEqual(1, d.screen.row);
    try testing.expectEqual(6, d.screen.column);
    try testing.expectEqual(@import("term").vt.CursorShape.block, d.screen.cursor_shape);
    try d.press("left");
    try testing.expectEqual(5, d.screen.column);
    try d.press("h");
    try testing.expect(!d.screen.cursor_visible);
}

test "Driver: titles, the bell, the clipboard, and screen switches" {
    const Many = struct {
        name: []const u8 = "first",
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg != .key) return .none;
            if (msg.key.matches("t")) m.name = "second";
            if (msg.key.matches("b")) return .bell;
            if (msg.key.matches("c")) return .clipboard;
            if (msg.key.matches("a")) return .altScreen(true);
            if (msg.key.matches("i")) return .altScreen(false);
            if (msg.key.matches("m")) return .mouse(.motion);
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("showing {s}", .{m.name});
        }
        pub fn title(m: *const @This()) []const u8 {
            return m.name;
        }
        pub fn clipboard(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("copied {s}", .{m.name});
        }
    };
    var d: Driver(Many) = try .init(testing.allocator, .{}, .{ .before = "$ app\r\n" });
    defer d.deinit();
    try testing.expectEqualStrings("first", d.screen.title.items);
    try d.press("t");
    try testing.expectEqualStrings("second", d.screen.title.items);
    try d.press("b");
    try testing.expectEqual(1, d.screen.bells);
    try d.press("c");
    try testing.expectEqualStrings("copied second", d.screen.clipboard.items);
    try d.press("a");
    try testing.expect(d.screen.on_alt);
    try d.expectScreen("showing second");
    try d.press("i");
    try testing.expect(!d.screen.on_alt);
    try d.expectScreen("$ app\nshowing second");
    try d.press("m");
    try testing.expectEqual(.motion, d.screen.mouse);
}

test "Driver: every lines ticks up with the clock" {
    const Clock = struct {
        fired: [3]i96 = undefined,
        count: usize = 0,
        now: *const Io.Timestamp,
        pub fn start(_: *@This()) Cmd {
            return .every(.fromSeconds(1), 1);
        }
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg != .tick or m.count == m.fired.len) return .none;
            m.fired[m.count] = m.now.nanoseconds;
            m.count += 1;
            return .every(.fromSeconds(1), 1);
        }
        pub fn view(_: *const @This(), _: *Io.Writer) Io.Writer.Error!void {}
    };
    var d: Driver(Clock) = try .init(testing.allocator, .{ .now = undefined }, .{});
    defer d.deinit();
    d.model().now = &d.program.now;
    try d.advance(.fromMilliseconds(3500));
    try testing.expectEqual(3, d.model().count);
    for (d.model().fired, 1..) |at, second| {
        try testing.expectEqual(@as(i96, @intCast(second)) * std.time.ns_per_s, at);
    }
}

test "Driver: max_fps holds changes back and draws the latest" {
    const Counter = struct {
        n: u32 = 0,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key) m.n += 1;
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("n={d}", .{m.n});
        }
    };
    var d: Driver(Counter) = try .init(testing.allocator, .{}, .{ .program = .{ .max_fps = 10 } });
    defer d.deinit();
    try d.expectScreen("n=0");
    try d.press("x");
    try d.press("x");
    try d.press("x");
    // Within the first tenth of a second nothing more is drawn...
    try d.expectScreen("n=0");
    // ...then the latest view, once.
    try d.advance(.fromMilliseconds(100));
    try d.expectScreen("n=3");
}

test "Driver: filter sees every message first, and posting crosses threads" {
    const Filtered = struct {
        seen: u32 = 0,
        last: u8 = 0,
        pub const Message = u8;
        pub fn filter(_: *@This(), msg: program_zig.Message(u8)) ?program_zig.Message(u8) {
            if (msg == .key and msg.key.matches("x")) return null;
            return msg;
        }
        pub fn update(m: *@This(), msg: program_zig.Message(u8)) Cmd {
            switch (msg) {
                .key => m.seen += 1,
                .app => |value| m.last = value,
                else => {},
            }
            return .none;
        }
        pub fn view(_: *const @This(), _: *Io.Writer) Io.Writer.Error!void {}
    };
    var d: Driver(Filtered) = try .init(testing.allocator, .{}, .{});
    defer d.deinit();
    try d.press("x");
    try d.press("y");
    try testing.expectEqual(1, d.model().seen);
    const Poster = struct {
        fn run(program: *Driver(Filtered).Program) void {
            program.post(.{ .app = 42 }) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Poster.run, .{d.program});
    thread.join();
    try d.program.deliverPosted();
    try testing.expectEqual(42, d.model().last);
}

test "Driver: ctrl+z reaches the model, which suspends; a resumed message follows" {
    const Suspends = struct {
        resumed: bool = false,
        keys: u32 = 0,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            switch (msg) {
                .resumed => m.resumed = true,
                .key => |key| if (key.matches("ctrl+z")) {
                    m.keys += 1;
                    return .suspend_process;
                },
                else => {},
            }
            return .none;
        }
        pub fn view(_: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll("x");
        }
    };
    var d: Driver(Suspends) = try .init(testing.allocator, .{}, .{});
    defer d.deinit();
    try d.press("ctrl+z");
    try testing.expectEqual(1, d.model().keys);
    try testing.expectEqual(1, d.suspends);
    try testing.expect(d.model().resumed);
}

test "Driver: owns its model and frees it, may be moved, and trims a snapshot" {
    const Owning = struct {
        text: std.ArrayList(u8) = .empty,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key) m.text.append(testing.allocator, 'x') catch {};
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("got {s}   \n\n", .{m.text.items});
        }
        pub fn deinit(m: *@This()) void {
            m.text.deinit(testing.allocator);
        }
    };
    const make = struct {
        fn make() !Driver(Owning) {
            const size: Size = .{ .width = 12, .height = 4 };
            return .init(testing.allocator, .{}, .{ .program = .{ .size = size } });
        }
    }.make;
    var d = try make();
    defer d.deinit(); // the leak check fails unless this frees the model's list
    try d.press("a");
    try d.press("b");
    const text = try d.screenTextTrimmed(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("got xx\n", text);
}

test writeTrimmed {
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeTrimmed(&w, "a  \n b \n   \n\n");
    try writeTrimmed(&w, "\n  \n");
    try testing.expectEqualStrings("a\n b\n", w.buffered());
}
