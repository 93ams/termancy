//! The Elm architecture: a model, messages that update it, and a view drawn from it.
//!
//! ```zig
//! const Counter = struct {
//!     count: u32 = 0,
//!
//!     pub fn update(model: *Counter, msg: tui.Msg) tui.Cmd {
//!         switch (msg) {
//!             .key => |key| {
//!                 if (key.matches("q")) return .quit;
//!                 if (key.matches("up")) model.count += 1;
//!             },
//!             else => {},
//!         }
//!         return .none;
//!     }
//!
//!     pub fn view(model: *const Counter, w: *std.Io.Writer) std.Io.Writer.Error!void {
//!         try w.print("count: {d}\n", .{model.count});
//!     }
//! };
//!
//! var counter: Counter = .{};
//! var program: tui.Program(Counter) = .init(gpa, &counter, terminal.writer(), .{});
//! defer program.deinit();
//! const outcome = try program.run(&terminal);
//! if (outcome.interrupted) return 130;
//! ```
//!
//! A model may also declare:
//!
//! | declaration | |
//! |---|---|
//! | `pub fn start(*Model) Cmd` | called once, before the first frame |
//! | `pub const Message = T` | the type of `.app` messages; `void` otherwise |
//! | `pub fn cursor(*const Model) ?Cursor` | where the terminal's own cursor shows, in the view |
//! | `pub fn title(*const Model) []const u8` | the window title, set when it changes |
//! | `pub fn filter(*Model, Msg) ?Msg` | sees each message first: change it, or drop it (null) |
//! | `pub fn above(*const Model, *Writer) !void` | lines to print above the frame, once |
//! | `pub fn clipboard(*const Model, *Writer) !void` | the text `Cmd.clipboard` copies |
//! | `pub fn handoff`, `pub fn work` | see `Cmd.handoff`, `Cmd.work` |
//!
//! The program core is free of I/O and clocks: `start`, `send`, `feed`, `advance`, and
//! `resize` drive it and write frames to a `*std.Io.Writer`. `run` connects it to a
//! `Terminal` with `std.Io`; `testing.Driver` connects it to memory and a virtual clock.
//!
//! Rendering: each step that changes the view draws a frame, inside a synchronized update
//! so the terminal shows no intermediate state. The view is laid out into cells as the
//! terminal would show it (long lines wrap at its width), and only the cells that changed
//! since the last frame are written (`term.Renderer`). A resize redraws the whole frame.
//! A frame taller than the terminal keeps its last rows inline; full-screen mode
//! (`alt_screen`) draws on the alternate screen from the top and keeps the first rows. A
//! trailing newline in a view is ignored, as are escape sequences other than colors,
//! attributes, and hyperlinks. `Options.max_fps` limits how often frames go out. On quit,
//! inline mode leaves the final frame and moves below it, or erases it with
//! `clear_on_quit`; full-screen mode returns to the main screen.
//!
//! Ctrl-C quits without reaching the model and sets `interrupted`, which a command maps to
//! exit status 130; set `Options.interrupt = false` to receive it as a key instead.
//! `Options.timeout` ends the program the same way once it passes, setting `timed_out`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ansi = @import("term").ansi;
const capability = @import("term").capability;
const input = @import("term").input;
const width = @import("term").width;
const Terminal = @import("term").Terminal;
const term = @import("term");

/// A size in cells.
pub const Size = Terminal.Size;

/// A message to a model: an input event, a resize, a timer, or the application's own.
pub fn Message(comptime App: type) type {
    return union(enum) {
        key: input.Key,
        mouse: input.Mouse,
        /// Bracketed paste. Valid only during `update`; copy it to keep it.
        paste: []const u8,
        /// True when the terminal gains focus, false when it loses it (needs
        /// `Options.focus_events`).
        focus: bool,
        /// The terminal's size; also sent once before the first frame.
        resize: Size,
        /// The terminal's reply to a query (see `Options.queries`).
        report: input.Report,
        /// A timer set by `Cmd.tick` or `Cmd.every` fired; the payload is its id.
        tick: u32,
        /// The program was continued after Ctrl-Z (`Cmd.suspend_process`).
        resumed,
        /// Sent by the application through `send`.
        app: App,

        const Self = @This();

        /// The same message as a `Msg`, for passing to a component that takes `Msg`; null
        /// for `.app`.
        pub fn base(msg: Self) ?Msg {
            return switch (msg) {
                .app => null,
                inline else => |payload, tag| @unionInit(Msg, @tagName(tag), payload),
            };
        }
    };
}

/// The message type of a model without application messages.
pub const Msg = Message(void);

/// What `update` asks the program to do next: nothing, quit, start timers, or several of
/// these. A plain value with no pointers, so it is always safe to return.
pub const Cmd = struct {
    items: [capacity]Item = undefined,
    len: u8 = 0,

    /// The most items one command holds.
    pub const capacity = 8;

    /// One thing to do.
    pub const Item = union(enum) {
        quit,
        tick: Tick,
        /// Give the terminal to `Model.handoff` (see `handoff`).
        handoff: u32,
        /// Run `Model.work` in the background (see `work`).
        work: Work,
        /// Stop the process as Ctrl-Z does in a shell (see `suspend_process`).
        suspend_process,
        /// A timer aligned to the clock (see `every`).
        every: Tick,
        /// Copy `Model.clipboard`'s text to the system clipboard (see `clipboard`).
        clipboard,
        /// Ring the terminal's bell.
        bell,
        /// Switch to the alternate screen (true) or back inline (false).
        alt_screen: bool,
        /// Change what the mouse reports.
        mouse: Mouse,
        /// Ask the terminal for its size; it arrives as `.resize`.
        window_size,
    };

    /// What the mouse reports (`Cmd.mouse`).
    pub const Mouse = enum {
        off,
        /// Presses, releases, the wheel, and drags.
        on,
        /// All of that, and every movement.
        motion,
    };

    /// Background work: `Model.work(io, gpa, id, arg)`, whose result arrives as an `.app`
    /// message.
    pub const Work = struct { id: u32, arg: u64 = 0 };

    /// A timer: after `after`, the model receives `.tick = id`. Timers fire once; set the
    /// next one from the `.tick` handler to repeat.
    pub const Tick = struct {
        after: Io.Duration,
        id: u32,
    };

    /// Nothing to do.
    pub const none: Cmd = .{};
    /// End the program after drawing the current view.
    pub const quit: Cmd = one(.quit);

    fn one(item: Item) Cmd {
        var cmd: Cmd = .{};
        cmd.items[0] = item;
        cmd.len = 1;
        return cmd;
    }

    /// Lends the terminal out: the program erases its frame (inline) or leaves the
    /// alternate screen, turns its modes off, and leaves raw mode; then `run` calls
    /// `Model.handoff(model, io, id) Cmd`, which may run an editor or a pager in the
    /// terminal; then the program takes the terminal back, redraws, and carries out the
    /// returned command. Input that arrives meanwhile goes to the other program. A model
    /// that returns this must declare `handoff`.
    pub fn handoff(id: u32) Cmd {
        return one(.{ .handoff = id });
    }

    /// Runs `Model.work(io, gpa, id, arg) Message` concurrently with the program, for
    /// work that would freeze the interface: reading files, network requests, running a
    /// command. Its return value arrives as an `.app` message. `work` is a plain function,
    /// not a method: it cannot see the model, which keeps changing meanwhile, so `id` and
    /// `arg` say what to do (an index into data the model owns and does not change, say).
    /// It allocates with the program's allocator, which must then be thread-safe. Without
    /// concurrency (a single-threaded `Io`), it runs at once, before the next frame. A
    /// model that returns this must declare `work` and `Message`.
    pub fn work(id: u32, arg: u64) Cmd {
        return one(.{ .work = .{ .id = id, .arg = arg } });
    }

    /// Stops the process as Ctrl-Z does in a shell: the terminal is restored, the process
    /// group stopped with SIGTSTP, and when the shell continues it (`fg`), the program
    /// takes the terminal back and redraws. Nothing happens on Windows, which has no job
    /// control.
    pub const suspend_process: Cmd = one(.suspend_process);

    /// A timer `id` firing after `after`.
    pub fn tick(after: Io.Duration, id: u32) Cmd {
        return one(.{ .tick = .{ .after = after, .id = id } });
    }

    /// A timer `id` firing at the next multiple of `period` on the program's clock, as
    /// Bubble Tea's `Every`: ticks set again on each fire stay in step (a clock that shows
    /// whole seconds changes on the second).
    pub fn every(period: Io.Duration, id: u32) Cmd {
        return one(.{ .every = .{ .after = period, .id = id } });
    }

    /// Copies the text `Model.clipboard(model, writer)` writes to the system clipboard,
    /// through the terminal (OSC 52; many terminals ask first or refuse).
    pub const clipboard: Cmd = one(.clipboard);
    /// Rings the bell.
    pub const bell: Cmd = one(.bell);
    /// Asks for the terminal's size, which arrives as a `.resize` message.
    pub const window_size: Cmd = one(.window_size);

    /// Switches between the alternate screen (full-screen) and inline drawing at run time.
    pub fn altScreen(on: bool) Cmd {
        return one(.{ .alt_screen = on });
    }

    /// Changes what the mouse reports at run time.
    pub fn mouse(mode: Mouse) Cmd {
        return one(.{ .mouse = mode });
    }

    /// All of `cmds`, in order. Asserts they hold at most `capacity` items in all.
    pub fn batch(cmds: []const Cmd) Cmd {
        var result: Cmd = .{};
        for (cmds) |cmd| {
            for (cmd.slice()) |item| {
                assert(result.len < capacity);
                result.items[result.len] = item;
                result.len += 1;
            }
        }
        return result;
    }

    /// The items, in order.
    pub fn slice(cmd: *const Cmd) []const Item {
        return cmd.items[0..cmd.len];
    }
};

/// How a program draws and what it asks of the terminal.
pub const Options = struct {
    /// Full-screen on the alternate screen instead of inline.
    alt_screen: bool = false,
    mouse: bool = false,
    /// Ask for the kitty keyboard protocol, so modified keys are unambiguous: ctrl+i is not
    /// tab, alt+[ is not an escape sequence. Terminals without it ignore the request.
    kitty_keyboard: bool = false,
    bracketed_paste: bool = true,
    focus_events: bool = false,
    hide_cursor: bool = true,
    /// Erase the final frame on quit (inline mode).
    clear_on_quit: bool = false,
    /// Ctrl-C quits with `interrupted` set, without reaching the model.
    interrupt: bool = true,
    /// Ctrl-Z stops the process (`Cmd.suspend_process`) without reaching the model. Off by
    /// default, so Ctrl-Z reaches the model as a key (undo in text fields); a model can also
    /// suspend on a key of its choosing by returning `Cmd.suspend_process`. Ignored on
    /// Windows, which has no job control.
    suspend_on_ctrl_z: bool = false,
    /// What the output can show. Without escapes, nothing is drawn while running and the
    /// final frame is written once, as plain lines, on quit.
    capability: capability.Capability = .full,
    /// The size until the first `resize`; `run` asks the terminal.
    size: Size = .{ .width = 80, .height = 24 },
    /// What to ask the terminal at start; each reply arrives as a `.report` message, and
    /// a `.report = .device_attributes` follows the last of them (terminals that do not
    /// know a query stay silent, so that is how a model knows the answers are in).
    queries: Queries = .{},
    /// How long a lone ESC waits for the rest of a sequence before it is the Escape key.
    escape_timeout: Io.Duration = .fromMilliseconds(50),
    /// At most this many frames a second (60 is Bubble Tea's); changes in between are
    /// drawn together once the time comes. 0 draws every change at once.
    max_fps: u16 = 0,
    /// End the program this long after `start`, without the model, as on Ctrl-C but with
    /// `Outcome.timed_out` set (gum's `--timeout`). A deadline like any other, so it needs
    /// no signals.
    timeout: ?Io.Duration = null,
};

/// Where the terminal's cursor shows (`Model.cursor`): `x` columns into line `y` of the
/// view.
pub const Cursor = struct {
    x: usize,
    y: usize,
    shape: term.vt.CursorShape = .bar,
    blink: bool = true,
};

/// Questions for the terminal, asked by `Program.start`.
pub const Queries = struct {
    /// The default foreground color: `.report = .foreground`.
    foreground: bool = false,
    /// The default background color, to pick colors for a dark or light theme (see
    /// `ansi.Color.Rgb.isDark`): `.report = .background`.
    background: bool = false,
    /// DEC private modes to ask about, such as `.synchronized_output`: one
    /// `.report = .mode` each.
    modes: []const ansi.Mode = &.{},
    /// Whether the kitty keyboard protocol is there: `.report = .kitty_keyboard`, or no
    /// reply.
    kitty_keyboard: bool = false,

    fn any(q: Queries) bool {
        return q.foreground or q.background or q.modes.len > 0 or q.kitty_keyboard;
    }

    fn write(q: Queries, w: *Io.Writer) Io.Writer.Error!void {
        if (!q.any()) return;
        if (q.foreground) try ansi.queryForeground(w);
        if (q.background) try ansi.queryBackground(w);
        for (q.modes) |mode| try ansi.queryMode(w, mode);
        if (q.kitty_keyboard) try ansi.queryKittyKeyboard(w);
        try ansi.queryDeviceAttributes(w);
    }
};

/// How a program ended.
pub const Outcome = struct {
    /// Ended by Ctrl-C; by convention the command exits with status 130.
    interrupted: bool,
    /// Ended by `Options.timeout`; gum exits with status 124.
    timed_out: bool = false,
};

/// How often `run` checks the terminal size while idle, which a resize signal (`winch`)
/// otherwise makes it do at once.
const resize_poll: Io.Duration = .fromMilliseconds(200);

/// A program running `Model`, which must declare `update` and `view` (see the file header).
/// Read `model`, `options`, `size`, and `interrupted`; the other fields are the runner's
/// own and may change in any release.
pub fn Program(comptime Model: type) type {
    comptime {
        if (!@hasDecl(Model, "update")) @compileError(@typeName(Model) ++ " has no update");
        if (!@hasDecl(Model, "view")) @compileError(@typeName(Model) ++ " has no view");
    }
    return struct {
        gpa: Allocator,
        /// The caller's model (see `init`).
        model: *Model,
        out: *Io.Writer,
        options: Options,
        size: Size,
        /// The program's clock, set by `advance`.
        now: Io.Timestamp = .zero,
        /// When the last input bytes arrived, for the escape timeout.
        input_at: Io.Timestamp = .zero,
        decoder: input.Decoder,
        timers: std.ArrayList(Timer) = .empty,
        timer_seq: u64 = 0,
        /// The view as last drawn, and a buffer for the next one.
        frame: std.ArrayList(u8) = .empty,
        scratch: std.ArrayList(u8) = .empty,
        /// The view laid out in cells, and what draws it.
        cells: term.Buffer,
        renderer: term.Renderer,
        /// The next frame must be drawn even if the view is unchanged.
        dirty: bool = true,
        /// The next frame must be drawn whole.
        redraw: bool = true,
        state: State = .ready,
        interrupted: bool = false,
        /// Ended by `Options.timeout`, which passes at `timeout_at`.
        timed_out: bool = false,
        timeout_at: ?Io.Timestamp = null,
        /// The terminal is to be lent out (see `release`); events wait in the decoder.
        pending: ?Release = null,
        /// The frame is off screen and the modes are off, until `reacquire`.
        released: bool = false,
        /// Background work asked for and not started yet (see `takeWork`).
        queued_work: std.ArrayList(Cmd.Work) = .empty,
        /// What `Model.above` wrote, to print above the frame.
        above: std.ArrayList(u8) = .empty,
        /// Full-screen now (`Options.alt_screen`, then `Cmd.altScreen`).
        alt_screen: bool,
        /// What the mouse reports now (`Options.mouse`, then `Cmd.mouse`).
        mouse: Cmd.Mouse,
        /// When the last frame went out, for `Options.max_fps`.
        drawn_at: ?Io.Timestamp = null,
        /// A change waits for its frame (`Options.max_fps`).
        frame_due: bool = false,
        /// The window title as last set.
        title_shown: std.ArrayList(u8) = .empty,
        /// Where the cursor was last shown, when it was.
        cursor_shown: ?Cursor = null,
        /// Messages posted from other threads (`post`), and the lock that guards them.
        inbox: std.ArrayList(Self.Msg) = .empty,
        inbox_lock: std.atomic.Mutex = .unlocked,
        /// Some thread has posted: `run` checks the inbox, often when `post` cannot wake it.
        posting: std.atomic.Value(bool) = .init(false),
        /// `run` listens on the signal pipe, so `post` wakes it there (see `winch.wake`).
        wakeable: std.atomic.Value(bool) = .init(false),
        /// What commands asked for, written with the next frame.
        suspended: bool = false,
        mouse_changed: bool = false,
        size_requested: bool = false,
        copy_pending: bool = false,
        bells: u8 = 0,
        screen_switch: ?bool = null,
        /// The first row of the laid-out frame that is on screen.
        frame_first: usize = 0,
        /// After the terminal narrowed: where its cursor would be if it rewrapped the
        /// frame's lines, and if it cut them, while its reply to where the cursor is, is
        /// awaited (see `probeReflow`). Frames wait for it, until `deadline`.
        reflow_probe: ?ReflowProbe = null,
        /// The terminal showed, by where its cursor went, whether it rewraps lines.
        reflow_learned: bool = false,
        /// The answer to `probeReflow` has not come yet, even after `deadline`: it is the
        /// program's when it does, not the model's.
        reflow_asked: bool = false,

        const Self = @This();

        /// The type of `.app` messages: `Model.Message`, or `void`.
        pub const App = if (@hasDecl(Model, "Message")) Model.Message else void;
        /// The messages `Model.update` receives.
        pub const Msg = Message(App);
        const ViewReturn = @typeInfo(@TypeOf(Model.view)).@"fn".return_type.?;
        const ViewError = @typeInfo(ViewReturn).error_union.error_set;
        /// What a step can fail with: the view's own errors, output, and memory.
        pub const Error = ViewError || Io.Writer.Error || Allocator.Error;

        const Timer = struct { deadline: Io.Timestamp, id: u32, seq: u64 };
        const ReflowProbe = struct {
            rewrapped: usize,
            cut: usize,
            deadline: Io.Timestamp,
            /// The width asked at: after another resize, the answer may be for either.
            width: u16,
        };
        /// How long a redraw waits for the terminal to say where its cursor went.
        const reflow_wait: Io.Duration = .fromMilliseconds(100);
        /// Why the terminal is lent out.
        pub const Release = union(enum) { handoff: u32, suspend_process };
        const State = enum { ready, running, quitting, done };

        /// A program over `model`, drawing to `out`. Nothing is written until `start`.
        ///
        /// The model stays the caller's: the program updates it in place, through this
        /// pointer, and never frees it, so after `run` it holds the final state. It must
        /// outlive the program and not move while the program runs; a component in it may
        /// borrow slices of the model's other fields.
        pub fn init(gpa: Allocator, model: *Model, out: *Io.Writer, options: Options) Self {
            return .{
                .gpa = gpa,
                .model = model,
                .out = out,
                .options = options,
                .size = options.size,
                .decoder = .init(gpa),
                .cells = .init(gpa),
                .renderer = .init(gpa, .{
                    .mode = if (options.alt_screen) .full_screen else .inline_frame,
                    .level = options.capability.color,
                    .reflows = options.capability.reflows,
                }),
                .alt_screen = options.alt_screen,
                .mouse = if (options.mouse) .on else .off,
            };
        }

        /// Frees the program's buffers. Does not touch the model or the output.
        pub fn deinit(p: *Self) void {
            p.decoder.deinit();
            p.timers.deinit(p.gpa);
            p.frame.deinit(p.gpa);
            p.scratch.deinit(p.gpa);
            p.cells.deinit();
            p.renderer.deinit();
            p.queued_work.deinit(p.gpa);
            p.above.deinit(p.gpa);
            p.title_shown.deinit(p.gpa);
            p.inbox.deinit(p.gpa);
            p.* = undefined;
        }

        /// Whether the program has quit and torn down.
        pub fn done(p: *const Self) bool {
            return p.state == .done;
        }

        /// The terminal modes the program turns on, for `Terminal.recordModes`.
        pub fn modes(p: *const Self) Terminal.Modes {
            if (!p.options.capability.escapes) return .{};
            return .{
                .alt_screen = p.alt_screen,
                .hidden_cursor = p.options.hide_cursor or @hasDecl(Model, "cursor"),
                .bracketed_paste = p.options.bracketed_paste,
                .mouse = p.mouse != .off,
                .focus_events = p.options.focus_events,
                .kitty_keyboard = p.options.kitty_keyboard,
            };
        }

        /// Turns on the modes, calls `Model.start` if declared, sends the size, and draws
        /// the first frame.
        pub fn start(p: *Self) Error!void {
            assert(p.state == .ready);
            p.state = .running;
            if (p.options.timeout) |timeout| p.timeout_at = p.now.addDuration(timeout);
            if (p.options.capability.escapes) {
                try p.writeModesOn();
                try p.options.queries.write(p.out);
            }
            if (@hasDecl(Model, "start")) try p.execute(p.model.start());
            try p.apply(.{ .resize = p.size });
            try p.settle();
        }

        fn writeModesOn(p: *Self) Io.Writer.Error!void {
            const on = p.modes();
            if (on.alt_screen) try ansi.setMode(p.out, .alt_screen, true);
            if (on.hidden_cursor) try ansi.setMode(p.out, .cursor_visible, false);
            if (on.bracketed_paste) try ansi.setMode(p.out, .bracketed_paste, true);
            if (on.mouse) try p.writeMouse(p.mouse);
            if (on.focus_events) try ansi.setMode(p.out, .focus_events, true);
            if (on.kitty_keyboard) try ansi.setKittyKeyboard(p.out, true);
        }

        fn writeMouse(p: *Self, mode: Cmd.Mouse) Io.Writer.Error!void {
            switch (mode) {
                .off => try ansi.setMouse(p.out, false),
                .on => try ansi.setMouse(p.out, true),
                .motion => {
                    try ansi.setMouse(p.out, true);
                    try ansi.setMode(p.out, .mouse_motion, true);
                },
            }
        }

        /// Delivers `msg` to the model and draws the result.
        pub fn send(p: *Self, msg: Self.Msg) Error!void {
            try p.apply(msg);
            try p.settle();
        }

        /// Queues `msg` for the model from any thread, as Bubble Tea's `Program.Send`: `run`
        /// delivers it within a few milliseconds. (`send` is for the program's own thread.)
        pub fn post(p: *Self, msg: Self.Msg) Allocator.Error!void {
            while (!p.inbox_lock.tryLock()) std.atomic.spinLoopHint();
            defer p.inbox_lock.unlock();
            try p.inbox.append(p.gpa, msg);
            p.posting.store(true, .release);
            if (builtin.os.tag != .windows and p.wakeable.load(.acquire)) winch.wake();
        }

        /// Delivers what was posted, oldest first, and draws the result once.
        pub fn deliverPosted(p: *Self) Error!void {
            if (!p.posting.load(.acquire)) return;
            var posted = take: {
                while (!p.inbox_lock.tryLock()) std.atomic.spinLoopHint();
                defer p.inbox_lock.unlock();
                const posted = p.inbox;
                p.inbox = .empty;
                break :take posted;
            };
            defer posted.deinit(p.gpa);
            if (posted.items.len == 0) return;
            for (posted.items) |msg| try p.apply(msg);
            try p.settle();
        }

        /// Decodes input bytes, delivers the events, and draws the result. An incomplete
        /// escape sequence waits for more bytes or for the escape timeout (`advance`).
        pub fn feed(p: *Self, bytes: []const u8) Error!void {
            if (p.state != .running) return;
            try p.decoder.feed(bytes);
            p.input_at = p.now;
            try p.drain();
            try p.settle();
        }

        /// Delivers decoded events until there are none, the program quits, or the
        /// terminal is to be lent out.
        fn drain(p: *Self) Allocator.Error!void {
            while (p.state == .running and p.pending == null) {
                try p.dispatch(p.decoder.next() orelse break);
            }
        }

        /// Gives the terminal up for `pending`: erases the frame (inline) and turns the
        /// modes off. The caller then leaves raw mode, lets the other program or the shell
        /// have the terminal, and calls `reacquire`. Returns why, and clears `pending`.
        pub fn release(p: *Self) Error!Release {
            const why = p.pending.?;
            p.pending = null;
            assert(p.state == .running and !p.released);
            p.released = true;
            if (!p.options.capability.escapes) return why;
            if (!p.alt_screen) try p.renderer.erase(p.out, p.size.width);
            p.renderer.forget();
            try p.modes().writeOff(p.out);
            p.cursor_shown = null;
            try p.out.flush();
            return why;
        }

        /// Takes the terminal back after `release`: turns the modes on, carries out `cmd`
        /// (what `Model.handoff` returned), delivers the input that waited, and redraws.
        pub fn reacquire(p: *Self, cmd: Cmd) Error!void {
            assert(p.released);
            const why_resumed = p.suspended;
            p.released = false;
            p.dirty = true;
            p.redraw = true;
            if (p.options.capability.escapes) try p.writeModesOn();
            if (why_resumed) {
                p.suspended = false;
                try p.apply(.resumed);
            }
            try p.execute(cmd);
            try p.drain();
            try p.settle();
        }

        /// Sets the clock to `now`, then fires the escape timeout and the timers that are
        /// due, earliest first, and draws a frame `max_fps` held back. A timer set while
        /// firing waits for the next `advance`.
        pub fn advance(p: *Self, now: Io.Timestamp) Error!void {
            if (p.state != .running) return;
            assert(now.nanoseconds >= p.now.nanoseconds);
            p.now = now;
            if (p.timeout_at) |at| if (at.nanoseconds <= now.nanoseconds) {
                p.timed_out = true;
                return p.stop();
            };
            // No answer in time: the guess stands, and a terminal that does not answer is
            // not asked again.
            if (p.reflow_probe) |probe| {
                if (probe.deadline.nanoseconds <= now.nanoseconds) {
                    p.reflow_probe = null;
                    p.reflow_learned = true;
                }
            }
            if (p.escapeDeadline()) |deadline| {
                if (deadline.nanoseconds <= now.nanoseconds) {
                    while (p.state == .running) try p.dispatch(p.decoder.flush() orelse break);
                }
            }
            const limit = p.timer_seq;
            while (p.state == .running) {
                const index = p.dueTimer(limit) orelse break;
                const timer = p.timers.orderedRemove(index);
                try p.apply(.{ .tick = timer.id });
            }
            try p.settle();
        }

        /// The terminal changed size: redraws for the new size and tells the model.
        pub fn resize(p: *Self, size: Size) Error!void {
            if (p.state != .running) return;
            if (std.meta.eql(size, p.size)) return;
            try p.probeReflow(size);
            p.size = size;
            p.dirty = true;
            p.redraw = true;
            try p.apply(.{ .resize = size });
            try p.settle();
        }

        /// After the terminal narrowed to `size`, asks where its cursor went, when its column
        /// tells whether the terminal rewrapped the frame's lines or cut them: the answer
        /// replaces `Capability.reflows`'s guess for every later redraw (`learnReflow`).
        /// There is no asking a terminal which it does; a terminal that does not answer
        /// keeps the guess.
        fn probeReflow(p: *Self, size: Size) Io.Writer.Error!void {
            if (p.reflow_learned or p.reflow_probe != null) return;
            if (p.alt_screen or !p.options.capability.escapes) return;
            if (size.width == 0 or size.width >= p.size.width) return;
            const column = p.renderer.cursorColumn() orelse return;
            const columns: usize = size.width;
            // Inside the narrower width, the cursor stays put either way.
            if (column < columns) return;
            const rewrapped = column % columns;
            const cut = columns - 1;
            if (rewrapped == cut) return;
            try ansi.queryCursorPosition(p.out);
            try p.out.flush();
            p.reflow_asked = true;
            p.reflow_probe = .{
                .rewrapped = rewrapped,
                .cut = cut,
                .deadline = p.now.addDuration(reflow_wait),
                .width = size.width,
            };
        }

        /// The terminal's answer to `probeReflow`: the cursor's column says which it did.
        /// The held redraw goes out when the input is settled.
        fn learnReflow(p: *Self, column: usize) void {
            p.reflow_asked = false;
            const probe = p.reflow_probe orelse return; // late: the guess already stood
            p.reflow_probe = null;
            // Resized again meanwhile: the column may be for the newer width, where a cut
            // line can land where the older width predicted a rewrapped one.
            if (p.size.width != probe.width) return;
            if (column == probe.rewrapped or column == probe.cut) {
                p.renderer.options.reflows = column == probe.rewrapped;
                p.reflow_learned = true;
            }
        }

        /// Ends the program without the model: as on quit, but `interrupted` is unchanged.
        /// For input that ended or an error in the caller's loop.
        pub fn stop(p: *Self) Error!void {
            if (p.state != .running and p.state != .quitting) return;
            p.state = .quitting;
            try p.settle();
        }

        /// When `advance` next has work: the earliest timer, the escape timeout, a frame
        /// `max_fps` held back, or `Options.timeout`.
        pub fn nextDeadline(p: *const Self) ?Io.Timestamp {
            var best = p.escapeDeadline();
            if (p.timeout_at) |at| {
                if (best == null or at.nanoseconds < best.?.nanoseconds) best = at;
            }
            if (p.reflow_probe) |probe| {
                if (best == null or probe.deadline.nanoseconds < best.?.nanoseconds) best = probe.deadline;
            }
            for (p.timers.items) |timer| {
                if (best == null or timer.deadline.nanoseconds < best.?.nanoseconds) {
                    best = timer.deadline;
                }
            }
            if (p.frame_due) if (p.frameTime()) |due| {
                if (best == null or due.nanoseconds < best.?.nanoseconds) best = due;
            };
            return best;
        }

        /// When the next frame may go out under `max_fps`; null when it may at once.
        fn frameTime(p: *const Self) ?Io.Timestamp {
            if (p.options.max_fps == 0) return null;
            const last = p.drawn_at orelse return null;
            const second: i96 = std.time.ns_per_s;
            const interval: Io.Duration = .fromNanoseconds(@divTrunc(second, p.options.max_fps));
            return last.addDuration(interval);
        }

        fn escapeDeadline(p: *const Self) ?Io.Timestamp {
            if (!p.decoder.hasPending() or p.decoder.pasting) return null;
            return p.input_at.addDuration(p.options.escape_timeout);
        }

        /// The index of the earliest due timer created before `limit`.
        fn dueTimer(p: *const Self, limit: u64) ?usize {
            var best: ?usize = null;
            for (p.timers.items, 0..) |timer, i| {
                if (timer.seq >= limit or timer.deadline.nanoseconds > p.now.nanoseconds) continue;
                const earliest = if (best) |b| p.timers.items[b].deadline.nanoseconds else null;
                if (earliest == null or timer.deadline.nanoseconds < earliest.?) best = i;
            }
            return best;
        }

        fn dispatch(p: *Self, event: input.Event) Allocator.Error!void {
            switch (event) {
                .key => |key| {
                    if (p.options.interrupt and key.matches("ctrl+c")) {
                        p.interrupted = true;
                        p.state = .quitting;
                    } else if (p.options.suspend_on_ctrl_z and builtin.os.tag != .windows and
                        key.matches("ctrl+z"))
                    {
                        p.suspendProcess();
                    } else try p.apply(.{ .key = key });
                },
                .mouse => |mouse| try p.apply(.{ .mouse = mouse }),
                .paste => |text| try p.apply(.{ .paste = text }),
                .focus_in => try p.apply(.{ .focus = true }),
                .focus_out => try p.apply(.{ .focus = false }),
                .report => |report| {
                    // The answer to `probeReflow` is the program's; any other, the model's.
                    if (report == .cursor and p.reflow_asked) {
                        return p.learnReflow(report.cursor.column);
                    }
                    try p.apply(.{ .report = report });
                },
            }
        }

        fn apply(p: *Self, msg: Self.Msg) Allocator.Error!void {
            if (p.state != .running) return;
            const delivered = if (@hasDecl(Model, "filter"))
                p.model.filter(msg) orelse return
            else
                msg;
            try p.execute(p.model.update(delivered));
        }

        fn suspendProcess(p: *Self) void {
            p.pending = .suspend_process;
            p.suspended = true;
        }

        fn execute(p: *Self, cmd: Cmd) Allocator.Error!void {
            for (cmd.slice()) |item| switch (item) {
                .quit => p.state = .quitting,
                .tick => |tick| try p.addTimer(p.now.addDuration(tick.after), tick.id),
                .every => |tick| {
                    const period: i96 = @max(tick.after.nanoseconds, 1);
                    const now = p.now.nanoseconds;
                    const next = now + (period - @mod(now, period));
                    try p.addTimer(.{ .nanoseconds = next }, tick.id);
                },
                .handoff => |id| {
                    if (!@hasDecl(Model, "handoff")) {
                        @panic(@typeName(Model) ++ " returned Cmd.handoff but has no handoff");
                    }
                    p.pending = .{ .handoff = id };
                },
                .suspend_process => p.suspendProcess(),
                .work => |job| {
                    if (!@hasDecl(Model, "work") or App == void) {
                        @panic(@typeName(Model) ++ " returned Cmd.work but has no work and " ++
                            "Message");
                    }
                    try p.queued_work.append(p.gpa, job);
                },
                .clipboard => {
                    if (!@hasDecl(Model, "clipboard")) {
                        @panic(@typeName(Model) ++ " returned Cmd.clipboard but has no clipboard");
                    }
                    try p.pendingOutput(.clipboard);
                },
                .bell => try p.pendingOutput(.bell),
                .alt_screen => |on| p.switchScreen(on),
                .mouse => |mode| {
                    if (mode != p.mouse) {
                        p.mouse = mode;
                        p.mouse_changed = true;
                    }
                },
                .window_size => p.size_requested = true,
            };
        }

        fn addTimer(p: *Self, deadline: Io.Timestamp, id: u32) Allocator.Error!void {
            try p.timers.append(p.gpa, .{ .deadline = deadline, .id = id, .seq = p.timer_seq });
            p.timer_seq += 1;
        }

        /// Output a command asks for, written with the next frame.
        const Extra = enum { clipboard, bell };

        fn pendingOutput(p: *Self, extra: Extra) Allocator.Error!void {
            switch (extra) {
                .clipboard => p.copy_pending = true,
                .bell => p.bells += 1,
            }
            p.dirty = true;
        }

        fn switchScreen(p: *Self, on: bool) void {
            if (on == p.alt_screen) return;
            p.screen_switch = on;
            p.dirty = true;
        }

        /// The next background job asked for, for whoever runs them: `run` starts each
        /// concurrently, `testing.Driver` runs it at once. Deliver its result with `send`.
        pub fn takeWork(p: *Self) ?Cmd.Work {
            if (p.queued_work.items.len == 0) return null;
            return p.queued_work.orderedRemove(0);
        }

        /// Draws the view if it changed, then tears down if the program is quitting.
        fn settle(p: *Self) Error!void {
            if (p.state == .ready or p.state == .done or p.released) return;
            // How far up the redraw starts waits on the terminal's answer.
            if (p.reflow_probe != null and p.state == .running) return;
            try p.render();
            if (p.state == .quitting) try p.finish();
        }

        fn render(p: *Self) Error!void {
            if (@hasDecl(Model, "above")) try p.printAbove();
            if (p.options.capability.escapes) try p.writeCommandOutput();
            var view: Io.Writer.Allocating = .fromArrayList(p.gpa, &p.scratch);
            p.model.view(&view.writer) catch |err| {
                p.scratch = view.toArrayList();
                return err;
            };
            p.scratch = view.toArrayList();
            if (std.mem.endsWith(u8, p.scratch.items, "\n")) p.scratch.items.len -= 1;
            const changed = p.dirty or !std.mem.eql(u8, p.scratch.items, p.frame.items);
            // Held back by `max_fps`: drawn when the time comes (or at the end), from the
            // latest view.
            if (changed and p.state == .running and p.frameTime() != null and
                p.frameTime().?.nanoseconds > p.now.nanoseconds)
            {
                p.frame_due = true;
                std.mem.swap(std.ArrayList(u8), &p.frame, &p.scratch);
                p.scratch.clearRetainingCapacity();
                p.dirty = true;
                return;
            }
            if (!changed and !p.frame_due) {
                p.scratch.clearRetainingCapacity();
                if (p.options.capability.escapes) try p.placeCursor(false);
                return;
            }
            const next = if (changed) p.scratch.items else p.frame.items;
            if (p.options.capability.escapes) try p.draw(next);
            if (changed) std.mem.swap(std.ArrayList(u8), &p.frame, &p.scratch);
            p.scratch.clearRetainingCapacity();
            p.dirty = false;
            p.frame_due = false;
            p.drawn_at = p.now;
        }

        /// What commands asked to write: the bell, the clipboard, a screen switch, a mouse
        /// change, a size request; and the title when it changed.
        fn writeCommandOutput(p: *Self) Error!void {
            const w = p.out;
            if (p.screen_switch) |on| {
                p.screen_switch = null;
                try ansi.setMode(w, .synchronized_output, true);
                if (on) {
                    if (p.renderer.showing) try p.renderer.erase(w, p.size.width);
                    try ansi.setMode(w, .alt_screen, true);
                } else {
                    try ansi.setMode(w, .alt_screen, false);
                }
                p.alt_screen = on;
                p.renderer.options.mode = if (on) .full_screen else .inline_frame;
                p.renderer.forget();
                p.redraw = true;
                p.cursor_shown = null;
                try ansi.setMode(w, .synchronized_output, false);
            }
            if (p.mouse_changed) {
                p.mouse_changed = false;
                try ansi.setMouse(w, false);
                try ansi.setMode(w, .mouse_motion, false);
                if (p.mouse != .off) try p.writeMouse(p.mouse);
            }
            if (p.size_requested) {
                p.size_requested = false;
                // The size the program has is the terminal's, kept up to date by `run`.
                try p.apply(.{ .resize = p.size });
            }
            while (p.bells > 0) : (p.bells -= 1) try w.writeByte(0x07);
            if (p.copy_pending) {
                p.copy_pending = false;
                if (@hasDecl(Model, "clipboard")) {
                    var text: Io.Writer.Allocating = .init(p.gpa);
                    defer text.deinit();
                    p.model.clipboard(&text.writer) catch {};
                    try ansi.copyToClipboard(w, text.written());
                }
            }
            if (@hasDecl(Model, "title")) {
                const title = p.model.title();
                if (!std.mem.eql(u8, title, p.title_shown.items)) {
                    try ansi.setTitle(w, title);
                    p.title_shown.clearRetainingCapacity();
                    try p.title_shown.appendSlice(p.gpa, title);
                }
            }
        }

        /// Prints what `Model.above` writes above the frame, where it stays (in the
        /// terminal's scrollback, inline), as Ink's `<Static>` does: log lines, finished
        /// tasks. The frame is drawn again below. In full-screen mode it is dropped: there is
        /// nothing above the screen.
        fn printAbove(p: *Self) Error!void {
            var text: Io.Writer.Allocating = .fromArrayList(p.gpa, &p.above);
            p.model.above(&text.writer) catch |err| {
                p.above = text.toArrayList();
                return err;
            };
            p.above = text.toArrayList();
            defer p.above.clearRetainingCapacity();
            if (p.above.items.len == 0 or p.alt_screen) return;
            const lines = std.mem.trimEnd(u8, p.above.items, "\n");
            if (!p.options.capability.escapes) {
                try p.writeLines(lines, "\n");
                try p.out.writeByte('\n');
                return p.out.flush();
            }
            try ansi.setMode(p.out, .synchronized_output, true);
            try p.renderer.erase(p.out, p.size.width);
            try p.writeLines(lines, "\r\n");
            try p.out.writeAll("\r\n");
            try ansi.setMode(p.out, .synchronized_output, false);
            p.renderer.forget();
            p.cursor_shown = null;
            p.dirty = true;
        }

        /// Puts `next` on screen: laid out in cells at the terminal's width, the rows that
        /// fit, only what changed (all of it after a resize or a screen switch).
        fn draw(p: *Self, next: []const u8) Error!void {
            const w = p.out;
            try ansi.setMode(w, .synchronized_output, true);
            if (p.cursor_shown != null) try ansi.setMode(w, .cursor_visible, false);
            try p.cells.layout(next, .{ .width = p.size.width });
            const height: usize = p.size.height;
            // Inline, a frame taller than the terminal keeps its last rows; full-screen,
            // its first.
            const first = if (p.alt_screen) 0 else p.cells.rows -| height;
            p.cells.window(first, height);
            p.frame_first = first;
            p.renderer.options.level = p.options.capability.color;
            try p.renderer.draw(w, &p.cells, .{ .whole = p.redraw });
            p.redraw = false;
            p.cursor_shown = null;
            try p.placeCursorIn(next, first);
            try ansi.setMode(w, .synchronized_output, false);
            try w.flush();
        }

        /// Shows the terminal's cursor where `Model.cursor` says, when it moved.
        fn placeCursor(p: *Self, force: bool) Error!void {
            if (!@hasDecl(Model, "cursor")) return;
            const wanted = p.model.cursor();
            if (!force and std.meta.eql(wanted, p.cursor_shown)) return;
            try ansi.setMode(p.out, .synchronized_output, true);
            try p.placeCursorIn(p.frame.items, p.frame_first);
            try ansi.setMode(p.out, .synchronized_output, false);
            try p.out.flush();
        }

        /// Moves the terminal's cursor to `Model.cursor`'s place in the frame `text`, whose
        /// rows from `first` are on screen; hides it when there is none.
        fn placeCursorIn(p: *Self, text: []const u8, first: usize) Error!void {
            if (!@hasDecl(Model, "cursor")) return;
            const w = p.out;
            const wanted = p.model.cursor() orelse {
                if (p.cursor_shown != null) try ansi.setMode(w, .cursor_visible, false);
                p.cursor_shown = null;
                return;
            };
            // The row of the cursor's line, counting the rows longer lines wrap into.
            var row: usize = 0;
            var lines = std.mem.splitScalar(u8, text, '\n');
            var line_index: usize = 0;
            while (lines.next()) |line| : (line_index += 1) {
                if (line_index == wanted.y) break;
                row += rowsOf(line, p.size.width);
            }
            const columns: usize = p.size.width;
            row += wanted.x / columns;
            const column = wanted.x % columns;
            if (row < first or row - first >= p.renderer.rows()) {
                try ansi.setMode(w, .cursor_visible, false);
                p.cursor_shown = null;
                return;
            }
            try p.renderer.moveCursor(w, row - first, column);
            const shape: u8 = switch (wanted.shape) {
                .block => 2,
                .underline => 4,
                .bar => 6,
            };
            try w.print(ansi.csi ++ "{d} q", .{shape - @intFromBool(wanted.blink)});
            try ansi.setMode(w, .cursor_visible, true);
            p.cursor_shown = wanted;
        }

        /// Writes `text`'s lines separated by `separator`, colors lowered to the capability.
        fn writeLines(p: *Self, text: []const u8, separator: []const u8) Io.Writer.Error!void {
            var lines = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) try p.out.writeAll(separator);
                first = false;
                const cap = p.options.capability;
                if (!cap.escapes and cap.color == .none) {
                    try ansi.strip(p.out, line);
                } else {
                    try ansi.downsample(p.out, line, cap.color);
                }
            }
            if (std.mem.indexOfScalar(u8, text, 0x1b) != null and p.options.capability.escapes) {
                try p.out.writeAll(ansi.reset);
            }
        }

        fn finish(p: *Self) Error!void {
            p.state = .done;
            const w = p.out;
            if (!p.options.capability.escapes) {
                try p.writeLines(p.frame.items, "\n");
                if (p.frame.items.len > 0) try w.writeByte('\n');
                return w.flush();
            }
            if (p.frame_due) {
                // The last change `max_fps` held back still goes out.
                p.frame_due = false;
                try p.draw(p.frame.items);
            }
            if (!p.alt_screen and p.renderer.showing) {
                if (p.options.clear_on_quit) {
                    try p.renderer.erase(w, p.size.width);
                } else {
                    try p.renderer.moveCursor(w, p.renderer.rows() -| 1, 0);
                    try w.writeAll("\r\n");
                }
            }
            if (p.cursor_shown != null or @hasDecl(Model, "cursor")) {
                try w.writeAll(ansi.csi ++ "0 q");
            }
            try p.modes().writeOff(w);
            try w.flush();
        }

        /// What `run` can fail with: a step, the terminal, or reading input.
        pub const RunError = Error || Terminal.RawError ||
            Io.Operation.FileReadStreaming.UnendingError || Io.Cancelable;

        /// Runs the program on `terminal` until it quits: raw mode, the event loop, and
        /// restoring the terminal however the loop ends. Reads input with a timeout so
        /// timers fire on time; checks the terminal size on a resize signal, and every
        /// 200 ms (on Windows, or with another program listening for the signal). SIGTERM and
        /// SIGHUP end it as Ctrl-C does, the terminal restored. With an `Io`
        /// that cannot wait on a read and a clock at once, timers fire only when input
        /// arrives.
        pub fn run(p: *Self, terminal: *Terminal) RunError!Outcome {
            const io = terminal.io;
            try terminal.enterRaw();
            defer terminal.restore();
            p.size = terminal.size() catch p.size;
            p.now = .now(io, .awake);
            // Recorded before they go on, so a first frame that fails still turns them off.
            terminal.recordModes(p.modes());
            try p.start();
            // What an earlier program on this terminal read and did not use.
            const pending = terminal.takePending();
            if (pending.len > 0) {
                var copy: [256]u8 = undefined;
                @memcpy(copy[0..pending.len], pending);
                try p.feed(copy[0..pending.len]);
            }
            // And what this one leaves, for the next.
            defer terminal.unread(p.decoder.buffer.items[p.decoder.start..]);
            // Slot 0 reads the terminal; slot 1, resize and stop signals (see `winch`).
            var storage: [2]Io.Operation.Storage = undefined;
            var batch: Io.Batch = .init(&storage);
            defer batch.cancel(io);
            var buffer: [1024]u8 = undefined;
            var data = [1][]u8{&buffer};
            var armed = false;
            const resizes: ?Io.File = if (builtin.os.tag == .windows) null else if (winch.listen()) |fd|
                .{ .handle = fd, .flags = .{ .nonblocking = false } }
            else
                null;
            defer if (resizes != null) winch.stop();
            // A post wakes the loop through the pipe; without one, the loop polls for posts.
            p.wakeable.store(resizes != null, .release);
            defer p.wakeable.store(false, .release);
            // What was posted before the pipe could say so.
            try p.deliverPosted();
            var signal_buffer: [64]u8 = undefined;
            var signal_data = [1][]u8{&signal_buffer};
            var signal_armed = false;
            var jobs: Jobs = .{ .gpa = p.gpa, .io = io };
            defer jobs.cancelAll();
            while (!p.done()) {
                // `Cmd.altScreen` and `Cmd.mouse` change them; an error or a panic restores
                // what was last recorded.
                terminal.recordModes(p.modes());
                try jobs.start(p);
                try jobs.collect(p);
                if (p.done()) break;
                if (p.pending != null) {
                    if (armed or signal_armed) {
                        // Stop reading, so the input goes to whoever has the terminal.
                        batch.cancel(io);
                        while (batch.next()) |completion| {
                            const n = completion.result.file_read_streaming catch 0;
                            if (completion.index == 0) try p.decoder.feed(buffer[0..n]);
                        }
                        armed = false;
                        signal_armed = false;
                    }
                    try p.lend(terminal);
                    p.now = .now(io, .awake);
                    continue;
                }
                const busy = jobs.running.items.len > 0 or
                    (p.posting.load(.acquire) and !p.wakeable.load(.acquire));
                if (builtin.os.tag == .windows) {
                    // shortcut: on Windows a console handle is never asynchronous, and
                    // `Io.Batch.awaitConcurrent` leaves the batch broken when it says
                    // `ConcurrencyUnavailable` (Zig 0.17), so wait on the handle here.
                    const ready = try terminal.waitInput(p.waitDeadline(busy));
                    p.now = .now(io, .awake);
                    try p.deliverPosted();
                    if (ready) {
                        const n = terminal.input.readStreaming(io, &data) catch |err| switch (err) {
                            error.EndOfStream => {
                                try p.stop();
                                break;
                            },
                            else => |e| return e,
                        };
                        try p.feed(buffer[0..n]);
                    }
                    if (terminal.size()) |size| try p.resize(size) else |_| {}
                    try p.advance(p.now);
                    continue;
                }
                if (!armed) {
                    batch.addAt(0, .{
                        .file_read_streaming = .{ .file = terminal.input, .data = &data },
                    });
                    armed = true;
                }
                if (resizes) |file| if (!signal_armed) {
                    batch.addAt(1, .{
                        .file_read_streaming = .{ .file = file, .data = &signal_data },
                    });
                    signal_armed = true;
                };
                try p.wait(io, &batch, busy);
                p.now = .now(io, .awake);
                try p.deliverPosted();
                while (batch.next()) |completion| {
                    if (completion.index == 1) {
                        // A resize: the size is read below, whatever woke the loop. SIGTERM
                        // or SIGHUP: end as on Ctrl-C, putting the terminal back.
                        signal_armed = false;
                        const n = completion.result.file_read_streaming catch 0;
                        if (std.mem.indexOfScalar(u8, signal_buffer[0..n], winch.stop_byte) != null) {
                            p.interrupted = true;
                            try p.stop();
                        }
                        continue;
                    }
                    armed = false;
                    const n = completion.result.file_read_streaming catch |err| switch (err) {
                        error.EndOfStream => {
                            try p.stop();
                            break;
                        },
                        else => |e| return e,
                    };
                    try p.feed(buffer[0..n]);
                }
                if (terminal.size()) |size| try p.resize(size) else |_| {}
                try p.advance(p.now);
            }
            terminal.recordModes(.{});
            return .{ .interrupted = p.interrupted, .timed_out = p.timed_out };
        }

        /// Runs the program over a remote terminal until it quits or the other end goes:
        /// an SSH session (`sys.ssh.Session`), or anything with `next(Io.Timeout)`
        /// returning `.data`, `.resize`, `.signal`, `.eof`, `.timeout`, or `.closed`. The
        /// program writes to the writer it was made with (the session's); set
        /// `Options.size` to the session's terminal. Handing the terminal to another
        /// program and suspending are not possible remotely: those commands do nothing.
        pub fn runSession(p: *Self, io: Io, session: anytype) (Error || Io.Cancelable)!Outcome {
            p.now = .now(io, .awake);
            try p.start();
            var jobs: Jobs = .{ .gpa = p.gpa, .io = io };
            defer jobs.cancelAll();
            while (!p.done()) {
                try jobs.start(p);
                try jobs.collect(p);
                if (p.done()) break;
                if (p.pending != null) {
                    _ = try p.release();
                    try p.reacquire(.none);
                    continue;
                }
                const busy = jobs.running.items.len > 0 or p.posting.load(.acquire);
                const event = try session.next(.{
                    .deadline = .{ .raw = p.waitDeadline(busy), .clock = .awake },
                });
                p.now = .now(io, .awake);
                try p.deliverPosted();
                switch (event) {
                    .data => |bytes| try p.feed(bytes),
                    .resize => |size| try p.resize(.{ .width = size.width, .height = size.height }),
                    .signal => |name| if (std.mem.eql(u8, name, "INT") or
                        std.mem.eql(u8, name, "TERM") or
                        std.mem.eql(u8, name, "HUP"))
                    {
                        p.interrupted = true;
                        try p.stop();
                    },
                    .eof, .closed => {
                        try p.stop();
                        break;
                    },
                    .timeout => {},
                }
                try p.advance(p.now);
            }
            return .{ .interrupted = p.interrupted, .timed_out = p.timed_out };
        }

        /// Lends the terminal out for `pending` and takes it back.
        fn lend(p: *Self, terminal: *Terminal) RunError!void {
            const why = try p.release();
            terminal.recordModes(.{});
            terminal.restore();
            const cmd: Cmd = switch (why) {
                .handoff => |id| if (@hasDecl(Model, "handoff"))
                    p.model.handoff(terminal.io, id)
                else
                    unreachable, // `execute` panics first
                .suspend_process => stop: {
                    if (builtin.os.tag != .windows) {
                        // Returns once the shell continues the process group.
                        std.posix.kill(0, .TSTP) catch {};
                    }
                    break :stop .none;
                },
            };
            try terminal.enterRaw();
            try p.reacquire(cmd);
            terminal.recordModes(p.modes());
        }

        /// Background jobs running under `run`.
        const Jobs = struct {
            gpa: Allocator,
            io: Io,
            running: std.ArrayList(*Job) = .empty,

            const Job = struct {
                work: Cmd.Work,
                done: std.atomic.Value(bool) = .init(false),
                result: App = undefined,
                future: Io.Future(void) = undefined,

                fn run(job: *Job, io: Io, gpa: Allocator) void {
                    job.result = Model.work(io, gpa, job.work.id, job.work.arg);
                    job.done.store(true, .release);
                }
            };

            /// Starts every queued job; runs one at once when there is no concurrency.
            fn start(jobs: *Jobs, p: *Self) Error!void {
                if (!@hasDecl(Model, "work") or App == void) return;
                while (p.takeWork()) |work| {
                    const job = try jobs.gpa.create(Job);
                    job.* = .{ .work = work };
                    job.future = jobs.io.concurrent(Job.run, .{ job, jobs.io, jobs.gpa }) catch {
                        Job.run(job, jobs.io, jobs.gpa);
                        const result = job.result;
                        jobs.gpa.destroy(job);
                        try p.send(.{ .app = result });
                        continue;
                    };
                    try jobs.running.append(jobs.gpa, job);
                }
            }

            /// Delivers the results of the jobs that finished.
            fn collect(jobs: *Jobs, p: *Self) Error!void {
                if (!@hasDecl(Model, "work") or App == void) return;
                var i: usize = 0;
                while (i < jobs.running.items.len) {
                    const job = jobs.running.items[i];
                    if (!job.done.load(.acquire)) {
                        i += 1;
                        continue;
                    }
                    job.future.await(jobs.io);
                    _ = jobs.running.orderedRemove(i);
                    const result = job.result;
                    jobs.gpa.destroy(job);
                    try p.send(.{ .app = result });
                }
            }

            fn cancelAll(jobs: *Jobs) void {
                if (@hasDecl(Model, "work") and App != void) {
                    for (jobs.running.items) |job| {
                        job.future.cancel(jobs.io);
                        jobs.gpa.destroy(job);
                    }
                }
                jobs.running.deinit(jobs.gpa);
            }
        };

        /// How often `run` looks for finished background work.
        const work_poll: Io.Duration = .fromMilliseconds(15);

        /// When to stop waiting for input: the next timer, or the next poll.
        fn waitDeadline(p: *const Self, working: bool) Io.Timestamp {
            const poll = p.now.addDuration(if (working) work_poll else resize_poll);
            const next = p.nextDeadline() orelse return poll;
            return if (next.nanoseconds < poll.nanoseconds) next else poll;
        }

        /// Waits for input or the next deadline, whichever comes first.
        fn wait(p: *Self, io: Io, batch: *Io.Batch, working: bool) Io.Cancelable!void {
            const timeout: Io.Timeout = .{ .deadline = .{ .raw = p.waitDeadline(working), .clock = .awake } };
            batch.awaitConcurrent(io, timeout) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
                error.ConcurrencyUnavailable => try batch.awaitAsync(io),
            };
        }
    };
}

/// SIGWINCH as a byte on a pipe, which `run` waits on beside the terminal, so a resize is
/// drawn at once rather than at the next size check; SIGTERM and SIGHUP as `stop_byte`, so
/// the program ends and restores the terminal instead of dying with it raw. Process-wide,
/// as signal handlers are: one program at a time listens; another checks every
/// `resize_poll` (and dies on SIGTERM as before).
const winch = struct {
    const posix = std.posix;
    const linux = std.os.linux;

    /// What SIGTERM and SIGHUP write; SIGWINCH and `wake` write anything else.
    const stop_byte = 's';
    const signals = [_]posix.SIG{ .WINCH, .TERM, .HUP };

    /// A program listens.
    var listening: std.atomic.Value(bool) = .init(false);
    /// The pipe, made by the first `listen` and never closed: a handler or `wake` that
    /// writes after `stop` reaches the pipe, never a file that took its descriptor number.
    var write_end: std.atomic.Value(i32) = .init(-1);
    var read_end: posix.fd_t = -1;
    var previous: [signals.len]posix.Sigaction = undefined;

    /// The pipe's read end, emptied, with the handlers installed; null when another
    /// program listens or there is no pipe.
    fn listen() ?posix.fd_t {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
        if (listening.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return null;
        if (read_end < 0) {
            var fds: [2]posix.fd_t = undefined;
            if (!pipe(&fds)) {
                listening.store(false, .release);
                return null;
            }
            read_end = fds[0];
            write_end.store(fds[1], .release);
        }
        drain();
        const action: posix.Sigaction = .{
            .handler = .{ .handler = handle },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        for (signals, &previous) |sig, *old| posix.sigaction(sig, &action, old);
        return read_end;
    }

    /// Puts the previous handlers back; the pipe stays for the next listener.
    fn stop() void {
        for (signals, &previous) |sig, *old| posix.sigaction(sig, old, null);
        listening.store(false, .release);
    }

    /// Drops what an earlier listener left unread, such as a SIGTERM that came too late
    /// for it, which would otherwise stop the next program at once.
    fn drain() void {
        var bytes: [64]u8 = undefined;
        var fds = [1]posix.pollfd{.{ .fd = read_end, .events = posix.POLL.IN, .revents = 0 }};
        while ((posix.poll(&fds, 0) catch 0) > 0) {
            if ((posix.read(read_end, &bytes) catch 0) == 0) break;
        }
    }

    fn handle(sig: posix.SIG) callconv(.c) void {
        const fd = write_end.load(.acquire);
        // The write end does not block: with the pipe full, a resize is already waiting
        // (a stop may then be lost; the next SIGTERM gets through once it drains).
        if (fd >= 0) write(fd, if (sig == .WINCH) 'w' else stop_byte);
    }

    /// A pipe closed on exec, whose write end does not block.
    fn pipe(fds: *[2]posix.fd_t) bool {
        if (builtin.os.tag == .linux) {
            if (posix.errno(linux.pipe2(fds, .{ .CLOEXEC = true })) != .SUCCESS) return false;
            const flags = linux.fcntl(fds[1], linux.F.GETFL, 0);
            _ = linux.fcntl(fds[1], linux.F.SETFL, flags | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
            return true;
        }
        const c = std.c;
        if (c.pipe(fds) != 0) return false;
        for (fds) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        const flags = c.fcntl(fds[1], c.F.GETFL);
        _ = c.fcntl(fds[1], c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        return true;
    }

    /// Wakes the listening program, from any thread: a message was posted (`post`).
    fn wake() void {
        const fd = write_end.load(.acquire);
        if (fd >= 0 and listening.load(.acquire)) write(fd, 'p');
    }

    fn write(fd: posix.fd_t, b: u8) void {
        const byte = [1]u8{b};
        if (builtin.os.tag == .linux) _ = linux.write(fd, &byte, 1) else _ = std.c.write(fd, &byte, 1);
    }
};

/// The terminal rows `text` takes at `columns` wide: one per line, plus one each time a
/// line wraps. A cluster that does not fit in the columns left wraps whole, as terminals
/// do with wide characters.
pub fn rowsOf(text: []const u8, columns: u16) usize {
    assert(columns > 0);
    var rows: usize = 1;
    var column: usize = 0;
    var it: width.Iterator = .init(text);
    while (it.next()) |cluster| {
        if (cluster.bytes[0] == '\n') {
            rows += 1;
            column = 0;
        } else if (cluster.bytes[0] == '\t') {
            // As `term.Buffer.layout`: to the next stop of 8, and no further than the edge.
            column = @min(column / 8 * 8 + 8, columns);
        } else if (cluster.width > 0) {
            if (column + cluster.width > columns) {
                rows += 1;
                column = 0;
            }
            column += cluster.width;
        }
    }
    return rows;
}

const testing = std.testing;

test rowsOf {
    try testing.expectEqual(1, rowsOf("", 10));
    try testing.expectEqual(1, rowsOf("0123456789", 10));
    try testing.expectEqual(2, rowsOf("0123456789a", 10));
    try testing.expectEqual(3, rowsOf("a\nb\nc", 10));
    try testing.expectEqual(2, rowsOf("\x1b[1m0123456789\x1b[0m\n", 10));
    try testing.expectEqual(2, rowsOf("012345678中", 10)); // the wide char wraps whole
    try testing.expectEqual(3, rowsOf("0123456789012345678901", 10));
    try testing.expectEqual(2, rowsOf("\txxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 40)); // the tab takes 8 columns
    try testing.expectEqual(1, rowsOf("\t\t\t\t\t\t", 40)); // and stops at the edge
}

test "Cmd: constructors and batch" {
    try testing.expectEqual(0, Cmd.none.len);
    try testing.expectEqual(Cmd.Item.quit, Cmd.quit.slice()[0]);
    const cmd: Cmd = .batch(&.{ .tick(.fromMilliseconds(5), 7), .none, .quit });
    try testing.expectEqual(2, cmd.len);
    try testing.expectEqual(7, cmd.slice()[0].tick.id);
    try testing.expectEqual(Cmd.Item.quit, cmd.slice()[1]);
}

test "Message.base drops the application payload" {
    const M = Message(u8);
    try testing.expectEqual(Msg{ .tick = 3 }, (M{ .tick = 3 }).base().?);
    try testing.expectEqual(null, (M{ .app = 1 }).base());
}

test "every declaration of an instance compiles, `run` included" {
    const Empty = struct {
        pub fn update(_: *@This(), _: Msg) Cmd {
            return .none;
        }
        pub fn view(_: *const @This(), _: *Io.Writer) Io.Writer.Error!void {}
    };
    testing.refAllDecls(Program(Empty));
}

test "winch: a resize signal is a byte on the pipe; one listener at a time" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const fd = winch.listen() orelse return error.SkipZigTest;
    defer winch.stop();
    try std.testing.expectEqual(null, winch.listen());
    try std.posix.raise(.WINCH);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(1, try std.posix.read(fd, &byte));
    try std.testing.expect(byte[0] != winch.stop_byte);
    // SIGTERM is caught too, as a request to stop, rather than killing the test.
    try std.posix.raise(.TERM);
    try std.testing.expectEqual(1, try std.posix.read(fd, &byte));
    try std.testing.expectEqual(winch.stop_byte, byte[0]);
}

test "winch: the next listener does not see a stop the last one left unread" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const first = winch.listen() orelse return error.SkipZigTest;
    try std.posix.raise(.TERM);
    winch.stop();
    const fd = winch.listen() orelse return error.SkipZigTest;
    defer winch.stop();
    try std.testing.expectEqual(first, fd); // the same pipe: never closed, never reused
    try std.posix.raise(.WINCH);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(1, try std.posix.read(fd, &byte));
    try std.testing.expect(byte[0] != winch.stop_byte);
}

test "post wakes a program listening on the signal pipe, rather than its polling" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const Empty = struct {
        pub fn update(_: *@This(), _: Msg) Cmd {
            return .none;
        }
        pub fn view(_: *const @This(), _: *Io.Writer) Io.Writer.Error!void {}
    };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var model: Empty = .{};
    var p: Program(Empty) = .init(testing.allocator, &model, &out.writer, .{});
    defer p.deinit();
    const fd = winch.listen() orelse return error.SkipZigTest;
    defer winch.stop();
    p.wakeable.store(true, .release); // as `run` sets it
    try p.post(.{ .tick = 1 });
    var byte: [1]u8 = undefined;
    try testing.expectEqual(1, try std.posix.read(fd, &byte));
    try testing.expectEqual('p', byte[0]);
}

test "runSession: input, a resize, and the end, from a remote session" {
    const Size2 = struct { width: u16, height: u16 };
    const Event = union(enum) {
        data: []const u8,
        resize: Size2,
        signal: []const u8,
        eof,
        timeout,
        closed,
    };
    const Fake = struct {
        events: []const Event,
        index: usize = 0,
        pub fn next(f: *@This(), _: Io.Timeout) Io.Cancelable!Event {
            if (f.index == f.events.len) return .closed;
            f.index += 1;
            return f.events[f.index - 1];
        }
    };
    const Typist = struct {
        text: [16]u8 = undefined,
        len: usize = 0,
        width: u16 = 0,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            switch (msg) {
                .key => |key| {
                    if (key.matches("enter")) return .quit;
                    if (key.printable()) |c| {
                        m.text[m.len] = @intCast(c);
                        m.len += 1;
                    }
                },
                .resize => |size| m.width = size.width,
                else => {},
            }
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("typed {s} at {d}", .{ m.text[0..m.len], m.width });
        }
    };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var typist: Typist = .{};
    var p: Program(Typist) = .init(testing.allocator, &typist, &out.writer, .{
        .size = .{ .width = 40, .height = 5 },
    });
    defer p.deinit();
    var session: Fake = .{ .events = &.{
        .{ .data = "hi" },
        .timeout,
        .{ .resize = .{ .width = 50, .height = 5 } },
        .{ .data = "\r" },
    } };
    const outcome = try p.runSession(testing.io, &session);
    try testing.expect(!outcome.interrupted);
    try testing.expectEqualStrings("hi", p.model.text[0..p.model.len]);
    try testing.expectEqual(50, p.model.width);
    try testing.expect(std.mem.indexOf(u8, out.written(), "typed hi at 50") != null);

    // A session that just goes away ends the program too.
    var other: Typist = .{};
    var gone: Program(Typist) = .init(testing.allocator, &other, &out.writer, .{});
    defer gone.deinit();
    var empty: Fake = .{ .events = &.{} };
    _ = try gone.runSession(testing.io, &empty);
    try testing.expect(gone.done());
}

test "the kitty keyboard protocol is requested and released when asked for" {
    const testing_mod = @import("testing.zig");
    const Echo = struct {
        last: ?input.Key = null,
        pub fn update(m: *@This(), msg: Msg) Cmd {
            if (msg == .key) m.last = msg.key;
            return if (msg == .key and msg.key.matches("q")) .quit else .none;
        }
        pub fn view(_: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll("x");
        }
    };
    var d: testing_mod.Driver(Echo) = try .init(std.testing.allocator, .{}, .{
        .program = .{ .kitty_keyboard = true },
    });
    defer d.deinit();
    try std.testing.expect(std.mem.indexOf(u8, d.outputBytes(), "\x1b[>1u") != null);
    // ctrl+i arrives as itself, not as tab.
    try d.feed("\x1b[105;5u");
    try std.testing.expect(d.model().last.?.matches("ctrl+i"));
    try d.press("q");
    try std.testing.expect(std.mem.indexOf(u8, d.outputBytes(), "\x1b[<u") != null);
}

test "background work runs concurrently and its result arrives as a message" {
    const Msg64 = Message(u64);
    const Model = struct {
        value: u64 = 0,
        pub const Message = u64;
        pub fn update(m: *@This(), msg: Msg64) Cmd {
            switch (msg) {
                .key => return .work(0, 21),
                .app => |value| m.value = value,
                else => {},
            }
            return .none;
        }
        pub fn work(io: Io, _: Allocator, _: u32, arg: u64) u64 {
            io.sleep(.fromMilliseconds(5), .awake) catch {};
            return arg * 2;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("{d}", .{m.value});
        }
    };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var model: Model = .{};
    var p: Program(Model) = .init(std.testing.allocator, &model, &out.writer, .{});
    defer p.deinit();
    try p.start();
    try p.feed("x");
    var jobs: Program(Model).Jobs = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer jobs.cancelAll();
    try jobs.start(&p);
    var waited: usize = 0;
    while (p.model.value == 0 and waited < 2000) : (waited += 1) {
        try jobs.collect(&p);
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(42, p.model.value);
    try std.testing.expectEqual(0, jobs.running.items.len);
}
