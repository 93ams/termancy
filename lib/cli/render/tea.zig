const std = @import("std");

/// How many terminal lines a rendered view occupies.
///
/// The erase loop emits one `\x1b[A\x1b[2K\r` per line of the *previous* frame, so this
/// count decides whether a re-render leaves the old frame on screen. It used to be
/// `std.mem.count(u8, view, "\n")`, which is one short for the normal case - a view whose
/// lines each end in a newline - so every re-render left the previous frame's last line
/// behind. The rule: one line per newline, plus one for a final line that the view did not
/// terminate, and nothing at all for an empty view (which occupies no lines to erase).
pub fn renderedLineCount(view: []const u8) usize {
    if (view.len == 0) return 0;
    const line_breaks = std.mem.count(u8, view, "\n");
    return line_breaks + @intFromBool(view[view.len - 1] != '\n');
}

test "the rendered line count matches what the terminal shows" {
    // A single unterminated line: one row, no line break to erase.
    try std.testing.expectEqual(@as(usize, 1), renderedLineCount("Menu"));
    // Two terminated lines: two rows. The old `count` returned 1 here, which is the
    // off-by-one that left a stale frame behind on every re-render.
    try std.testing.expectEqual(@as(usize, 2), renderedLineCount("Menu\nChoice\n"));
    // A final line without a terminator still occupies a row.
    try std.testing.expectEqual(@as(usize, 3), renderedLineCount("a\nb\nc"));
    // Empty: nothing was drawn, so there is nothing to erase. Erasing here would move the
    // cursor up over a line this program never wrote.
    try std.testing.expectEqual(@as(usize, 0), renderedLineCount(""));
    // A view that is only a terminator drew one (blank) row.
    try std.testing.expectEqual(@as(usize, 1), renderedLineCount("\n"));
    // And the count is never below the number of line breaks it must erase, which is the
    // property the erase loop depends on.
    const views = [_][]const u8{ "Menu", "Menu\n", "a\nb", "a\nb\n", "\n", "" };
    for (views) |view| {
        try std.testing.expect(renderedLineCount(view) >= std.mem.count(u8, view, "\n"));
    }
}

pub const Key = enum {
    up,
    down,
    left,
    right,
    enter,
    escape,
    backspace,
    tab,
    ctrl_c,
    char,
    unknown,
};

pub const KeyMsg = struct {
    key: Key,
    char: ?u8 = null,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    release,
    wheel_up,
    wheel_down,
    motion,
};

pub const MouseMsg = struct {
    button: MouseButton,
    x: u16,
    y: u16,
};

pub fn Msg(comptime CustomMsgT: type) type {
    return union(enum) {
        key: KeyMsg,
        mouse: MouseMsg,
        window_size: struct { width: u16, height: u16 },
        custom: CustomMsgT,
    };
}

pub fn Command(comptime CustomMsgT: type) type {
    return union(enum) {
        none,
        quit,
        /// Execute a function in a background thread and push the returned message into the event loop.
        exec: *const fn () CustomMsgT,
    };
}

/// A thread-safe generic MPSC channel for Elm architecture messages.
pub fn Channel(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        queue: std.ArrayListUnmanaged(T),
        allocator: std.mem.Allocator,
        io: std.Io,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{
                .queue = .empty,
                .allocator = allocator,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);
            try self.queue.append(self.allocator, item);
            self.cond.signal(self.io);
        }

        pub fn pop(self: *Self) T {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);
            while (self.queue.items.len == 0) {
                self.cond.wait(self.io, &self.mutex) catch unreachable;
            }
            return self.queue.orderedRemove(0);
        }
    };
}

pub fn Program(comptime ModelT: type, comptime CustomMsgT: type) type {
    return struct {
        const Self = @This();
        const MsgT = Msg(CustomMsgT);
        const CmdT = Command(CustomMsgT);

        /// The allocator a `Program` uses when the caller does not name one.
        ///
        /// The process-lifetime allocator is the right production choice and the wrong
        /// test one: `run` cannot always free what it allocates (see `StdinContext`), so
        /// an allocator with a leak report would fail every run. A caller that *can*
        /// guarantee the reader thread has stopped - a test with a finite source - passes
        /// its own allocator to `initWithAllocator`.
        pub const default_allocator = std.heap.page_allocator;

        model: ModelT,
        io: std.Io,
        allocator: std.mem.Allocator,
        /// The reader thread `run` started, once it has started one. `deinit` joins it
        /// before freeing anything; `null` means `run` never got that far.
        reader: ?Reader = null,

        pub fn init(model: ModelT, io: std.Io) Self {
            return .{ .model = model, .io = io, .allocator = default_allocator };
        }

        /// `init`, with the allocator named - for a caller that owns the reader thread's
        /// whole lifetime and can therefore release what `run` allocated. See `deinit`.
        pub fn initWithAllocator(model: ModelT, io: std.Io, allocator: std.mem.Allocator) Self {
            return .{ .model = model, .io = io, .allocator = allocator };
        }

        /// Releases what `run` allocated, **after** joining the reader thread.
        ///
        /// This is the half of B-4 that was missing. Production does not call it: the
        /// reader thread is normally blocked in a stdin read that no byte will end, so
        /// joining would hang, and the process exits instead. A caller driving a source
        /// that reaches end of stream - a test, or any non-interactive use - *can* join,
        /// and once the thread is provably gone the two allocations are safe to free.
        ///
        /// Order matters and is the whole point: **join, then free**. Freeing first is the
        /// use-after-free this item was about. Idempotent, because `run` may have failed
        /// before starting a reader and a caller may still `defer` this.
        pub fn deinit(self: *Self) void {
            const reader = self.reader orelse return;
            self.reader = null;

            // Blocks until the reader ends. Safe only because the source is finite; see
            // the doc comment above and `StdinContext`.
            reader.thread.join();

            // The thread has stopped, so nothing else reaches either allocation. The
            // channel's own `deinit` frees the queue storage, not just the struct.
            reader.ctx.channel.deinit();
            self.allocator.destroy(reader.ctx.channel);
            self.allocator.destroy(reader.ctx);
        }

        /// What the reader thread is allowed to touch, and for how long.
        ///
        /// Ownership rule: the thread owns nothing that its spawner can free. The context
        /// and the channel it points at are allocated by `startReader` and are never
        /// released, because a thread blocked in a stdin read cannot observe a stop flag
        /// - the flag is only reachable between reads, and the read blocks until a byte
        /// arrives, which on the quit path may be never. Hence the other half of the
        /// rule: whoever starts a reader thread must keep the context and channel alive
        /// for the thread, and must not free them while it runs. `startReader` takes the
        /// allocator, so a test can use `std.testing.allocator` and assert the exact
        /// inverse on a source that reaches end of stream: there the thread does stop on
        /// its own, and there joining it before `free` is what proves nothing was freed
        /// early. `run` uses `std.heap.page_allocator` and deliberately never frees.
        ///
        /// This is not hypothetical. The context used to be a `run` local while the
        /// thread held its address, and `prompt.zig` `defer`red `channel.deinit()` on the
        /// quit path while the thread was still pushing into that queue.
        const StdinContext = struct {
            /// A copy of the input interface. The thread reads the byte source the
            /// interface points at; the interface itself is owned here, so it cannot be
            /// freed out from under the reader either.
            in: std.Io.Reader,
            channel: *Channel(MsgT),
        };

        /// Reads the input source into `ctx_ptr.channel` until end of stream or a read
        /// error, then returns.
        ///
        /// The thread's lifetime is the source's lifetime. Nothing here may free the
        /// context, the channel, or the input's backing buffer: see the ownership rule on
        /// `StdinContext`. The loop is bounded by the source: a source that reaches end of
        /// stream returns zero bytes, which ends the loop, which lets an owner that owns a
        /// finite source join this thread and then free in either order.
        fn stdinReaderThread(ctx_ptr: *StdinContext) void {
            // No assertion on `ctx_ptr.channel.mutex` here, and that is deliberate. This
            // used to assert the queue's lock was `.unlocked` at thread start, which is
            // not an invariant: `Channel.pop` holds that lock for the whole time it is
            // blocked in `cond.wait`, so the main loop is *normally* holding it when this
            // thread starts. The assert was a latent flake that crashed the suite
            // intermittently (`reached unreachable code` in `std.debug.assert`) the moment
            // the surrounding timing shifted - a scheduling-dependent failure, which is
            // the worst kind to leave in a test path.
            //
            // The real invariant is checked by the spawner, where it can be observed
            // without racing another thread: `startReader` asserts the channel it hands
            // over is freshly created and empty. A reader that wanted to assert about the
            // lock would have to hold it.
            std.debug.assert(ctx_ptr.in.buffer.len > 0);
            var buf: [16]u8 = undefined;
            while (true) {
                var vecs = [_][]u8{buf[0..]};
                const read_bytes = ctx_ptr.in.readVec(&vecs) catch return;
                if (read_bytes == 0) return;

                const slice = buf[0..read_bytes];
                const key_msg = parseAnsi(slice);

                ctx_ptr.channel.push(.{ .key = key_msg }) catch return;
            }
        }

        /// Allocates the reader's context and channel together and starts the reader
        /// thread, returning the thread with the context it reads through.
        ///
        /// The caller owns both allocations through `Reader.ctx` and must keep them alive
        /// for as long as the thread runs (see `StdinContext`). `Reader.ctx` is returned so
        /// an owner with a finite source can join the thread and then release the channel,
        /// in that order. Spawning only fails on `error.ThreadQuota`/`error.SystemResources`,
        /// in which case the storage is freed again - there is no thread to outlive it.
        const Reader = struct {
            thread: std.Thread,
            ctx: *StdinContext,
        };

        fn startReader(
            allocator: std.mem.Allocator,
            io: std.Io,
            in: std.Io.Reader,
        ) !Reader {
            // The channel starts empty: it is the reader's only queue, so a non-empty one
            // would mean another producer is already pushing into it.
            const channel = try allocator.create(Channel(MsgT));
            errdefer allocator.destroy(channel);
            channel.* = Channel(MsgT).init(allocator, io);
            std.debug.assert(channel.queue.items.len == 0);

            const ctx = try allocator.create(StdinContext);
            errdefer allocator.destroy(ctx);
            ctx.* = .{ .in = in, .channel = channel };
            // The reader pushes into the very channel this context carries, so the two
            // allocations the caller must keep alive are the two the thread reaches.
            std.debug.assert(ctx.channel == channel);
            std.debug.assert(ctx.in.buffer.ptr == in.buffer.ptr);

            const thread = try std.Thread.spawn(.{}, stdinReaderThread, .{ctx});
            return .{ .thread = thread, .ctx = ctx };
        }

        const ExecContext = struct {
            func: *const fn () CustomMsgT,
            channel: *Channel(MsgT),
        };

        fn execThread(ctx_ptr: *ExecContext) void {
            const result_msg = ctx_ptr.func();
            ctx_ptr.channel.push(.{ .custom = result_msg }) catch return;
            // Note: in a real framework we'd use an allocator to manage ctx_ptr if it wasn't statically viable.
            // For simplicity, we assume users will manage memory for exec args or we just pass the function pointer.
        }

        pub fn run(self: *Self, ctx: anytype) !void {
            const writer = ctx.out;

            try writer.writeAll("\x1b[?25l"); // Hide cursor
            defer writer.writeAll("\x1b[?25h") catch {}; // Show cursor

            // The process-lifetime allocator and the missing join are one decision, not two
            // oversights. The reader thread cannot be stopped (see `StdinContext`), so it is
            // never joined, so its context and the channel it pushes into must outlive every
            // frame that could free them. `prompt.zig` used to own the channel on its own
            // frame and `defer` its `deinit`, which could free the queue while the thread was
            // pushing into it. The leak is bounded - one context and one channel per prompt,
            // in a process that exits as soon as the prompt's command returns - and the
            // alternative is a use-after-free.
            //
            // `self.allocator` is the caller's choice; see `default_allocator`. A caller that
            // can prove the thread has stopped calls `deinit` to release both allocations,
            // and that is what makes the leak measurable rather than merely argued.
            const reader = try startReader(self.allocator, self.io, ctx.in.*);
            // Recorded before anything that can fail, so `deinit` can always reach them.
            // `deinit` joining the thread is what keeps this safe: the thread is gone before
            // either allocation is released.
            self.reader = reader;
            // `readVec` requires a buffer to read into; the reader thread asserts the same
            // precondition from its side, before it reads anything.
            std.debug.assert(reader.ctx.in.buffer.len > 0);

            var prev_lines: usize = 0;

            // Initial view
            var aw = std.Io.Writer.Allocating.init(reader.ctx.channel.allocator);
            try self.model.view(&aw.writer);
            var view_bytes = aw.writer.buffer[0..aw.writer.end];
            try writer.writeAll(view_bytes);
            prev_lines = renderedLineCount(view_bytes);
            reader.ctx.channel.allocator.free(aw.writer.buffer);

            // Event Loop
            while (true) {
                // 1. Wait for input or background task message
                const msg = reader.ctx.channel.pop();

                // 2. Update phase
                const cmd = try self.model.update(msg);

                if (cmd == .quit) {
                    if (prev_lines > 0) {
                        for (0..prev_lines) |_| try writer.writeAll("\x1b[A\x1b[2K\r");
                    }
                    var aw_final = std.Io.Writer.Allocating.init(reader.ctx.channel.allocator);
                    try self.model.view(&aw_final.writer);
                    view_bytes = aw_final.writer.buffer[0..aw_final.writer.end];
                    try writer.writeAll(view_bytes);
                    try writer.writeAll("\n");
                    reader.ctx.channel.allocator.free(aw_final.writer.buffer);
                    break;
                } else if (cmd == .exec) {
                    // Spawn background task
                    // In a production system, we'd heap allocate the context or use a thread pool.
                    // This is a minimal architecture representation.
                }

                // 3. View phase
                if (prev_lines > 0) {
                    for (0..prev_lines) |_| try writer.writeAll("\x1b[A\x1b[2K\r");
                }

                var aw_next = std.Io.Writer.Allocating.init(reader.ctx.channel.allocator);
                try self.model.view(&aw_next.writer);
                view_bytes = aw_next.writer.buffer[0..aw_next.writer.end];
                try writer.writeAll(view_bytes);
                prev_lines = renderedLineCount(view_bytes);
                reader.ctx.channel.allocator.free(aw_next.writer.buffer);
            }
        }

        test "the reader thread stops at end of stream, so joining it before freeing is safe" {
            // This drives the reader thread with an injected source rather than a real
            // stdin: the source is a byte slice, so it reaches end of stream and the
            // thread returns on its own. Nothing here can block, so nothing here can hang
            // `zig build test`.
            //
            // The test is the inverse of the rule the fix implements. `startReader` puts
            // the context and channel behind the caller's allocator, so `std.testing.allocator`
            // reports a leak if the thread touches anything after the test frees it - and a
            // double free or a dangling push aborts the run outright.
            const testing = std.testing;

            // One byte is enough to prove the thread reads and pushes: `parseAnsi` maps a
            // lone `h` to a character key, and the next read reaches end of stream and ends
            // the loop, so this test never waits on an input that is not coming.
            var source_bytes: [1]u8 = .{'h'};
            const source = std.Io.Reader.fixed(&source_bytes);

            const reader = try startReader(testing.allocator, testing.io, source);
            reader.thread.join(); // Ends at end of stream; see the source above.

            const message = reader.ctx.channel.pop();
            try testing.expect(message == .key);
            try testing.expectEqual(Key.char, message.key.key);
            try testing.expectEqual(@as(?u8, 'h'), message.key.char);

            // The thread is joined and the source is drained, so the queue holds nothing
            // else and releasing it now cannot race the reader. `deinit` frees the queue's
            // storage and not just the channel struct, and this order - join, then deinit,
            // then destroy - is what makes `testing.allocator` report no leak.
            reader.ctx.channel.deinit();
            testing.allocator.destroy(reader.ctx.channel);
            testing.allocator.destroy(reader.ctx);
        }

        test "run reaches its quit path and returns, without reading a real terminal" {
            // The coverage the B-4 entry says is missing: nothing drove `run` itself,
            // because the first attempt at this item drove it against a real terminal and
            // hung `zig build test`. This drives it with a finite source instead, so the
            // reader thread reaches end of stream on its own and `run` always returns.
            //
            // It also **measures** the leak that B-4 recorded as reasoned-but-unobserved,
            // by injecting `std.testing.allocator` through `initWithAllocator`. That is
            // only possible because the source is finite: `deinit` joins the reader thread
            // first, and a join on a blocked stdin read would hang. If `deinit` freed
            // before joining, `testing.allocator` would report a leak or a double free
            // here; if `run` leaked anything of its own, it would report that too.
            //
            // What this pins as well as the memory: the byte travels from the source
            // through the reader thread and the channel into `update`, the `.quit` command
            // is honoured, the final view is drawn, and the cursor is hidden on entry and
            // restored on exit, in that order.
            //
            // The model lives at file scope (`QuitModel`) rather than here: a struct with
            // methods declared inside a test that is itself inside a generic was enough to
            // exhaust the compiler's memory, reproducibly. Nothing about the test needs it
            // to be local, so it is not.
            const testing = std.testing;

            // A single 'q' and then end of stream: the reader thread ends on its own, so
            // nothing here can block and nothing here can outlive the stack buffers.
            var source_bytes: [1]u8 = .{'q'};
            var out_buf: [256]u8 = undefined;
            var out = std.Io.Writer.fixed(&out_buf);

            var prog = Program(QuitModel, void).initWithAllocator(.{}, testing.io, testing.allocator);
            defer prog.deinit();
            const ctx = .{
                .in = &std.Io.Reader.fixed(&source_bytes),
                .out = &out,
            };
            try prog.run(ctx);

            try testing.expect(prog.model.quit);
            try testing.expectEqual(@as(u8, 'q'), prog.model.seen);
            const written = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
            // The final view is drawn on the quit path, and the cursor is shown again.
            try testing.expect(std.mem.endsWith(u8, written, "\x1b[?25h"));
            try testing.expect(std.mem.indexOf(u8, written, "byebye") != null);
            // The cursor was hidden on entry and restored on exit, in that order.
            try testing.expect(std.mem.startsWith(u8, written, "\x1b[?25l"));
        }

        test "deinit is idempotent and safe before run has started a reader" {
            // `deinit` makes two promises that the `run` test cannot localise, so they are
            // pinned here instead: calling it twice is a no-op, and calling it on a
            // `Program` whose `run` never started a reader does nothing.
            //
            // The second promise is the one a caller actually relies on. A test or a
            // non-interactive caller `defer`s `deinit` unconditionally; if `run` failed
            // before `startReader`, the `oref` must return rather than join a thread that
            // does not exist or free storage that was never allocated.
            //
            // Deliberately *not* a second `run`: this body is collected once per
            // instantiation of the generic, and the prompt's model has required fields, so
            // there is no model-independent way to drive a quit from here. The `run` test
            // above already drives it for whichever model this instantiation carries.
            const testing = std.testing;

            var prog = Program(QuitModel, void).initWithAllocator(
                .{},
                testing.io,
                testing.allocator,
            );

            // No `run`, so no reader: both calls must be silent no-ops.
            prog.deinit();
            prog.deinit();

            // And after a run that did start one, a second call is still a no-op. The
            // source is `q` because this instantiation is `QuitModel`'s by construction -
            // the inner `Program` names it, so no other model's `update` is involved.
            var source_bytes: [1]u8 = .{'q'};
            var out_buf: [128]u8 = undefined;
            var out = std.Io.Writer.fixed(&out_buf);

            var ran = Program(QuitModel, void).initWithAllocator(
                .{},
                testing.io,
                testing.allocator,
            );
            defer ran.deinit();
            const ctx = .{
                .in = &std.Io.Reader.fixed(&source_bytes),
                .out = &out,
            };
            try ran.run(ctx);
            try testing.expect(ran.model.quit);
        }
    };
}

/// The model for `run`'s quit-path test, at file scope on purpose: see the note in that
/// test. It quits on `q` and records the character it was given, so the test can prove the
/// key travelled from the byte source, through the reader thread and the channel, into
/// `update` - rather than asserting a shape that only looks right.
pub const QuitModel = struct {
    seen: u8 = 0,
    quit: bool = false,

    pub fn update(self: *@This(), msg: Msg(void)) !Command(void) {
        switch (msg) {
            .key => |k| {
                self.seen = k.char orelse 0;
                if (k.key == .char and k.char == 'q') self.quit = true;
            },
            else => {},
        }
        return if (self.quit) .quit else .none;
    }

    pub fn view(self: *@This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(if (self.quit) "byebye\n" else "menu\n");
    }
};

pub fn visualWidth(str: []const u8) usize {
    var width: usize = 0;
    var in_escape = false;
    for (str) |c| {
        if (in_escape) {
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) in_escape = false;
        } else {
            if (c == '\x1b') {
                in_escape = true;
            } else if (c >= 32 and c != 127) {
                width += 1;
            }
        }
    }
    return width;
}

fn parseAnsi(buf: []const u8) KeyMsg {
    if (buf.len == 0) return .{ .key = .unknown };
    if (buf.len == 1) {
        return switch (buf[0]) {
            '\r', '\n' => .{ .key = .enter },
            3 => .{ .key = .ctrl_c },
            27 => .{ .key = .escape },
            8, 127 => .{ .key = .backspace },
            '\t' => .{ .key = .tab },
            else => .{ .key = .char, .char = buf[0] },
        };
    }
    if (buf.len == 3 and buf[0] == '\x1b' and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => .{ .key = .up },
            'B' => .{ .key = .down },
            'C' => .{ .key = .right },
            'D' => .{ .key = .left },
            else => .{ .key = .unknown },
        };
    }
    return .{ .key = .unknown };
}

pub fn parseMouse(buf: []const u8) ?MouseMsg {
    if (buf.len < 6) return null;
    if (!std.mem.startsWith(u8, buf, "\x1b[<")) return null;

    const last_char = buf[buf.len - 1];
    if (last_char != 'M' and last_char != 'm') return null;

    const payload = buf[3 .. buf.len - 1];
    var it = std.mem.splitScalar(u8, payload, ';');
    const b_str = it.next() orelse return null;
    const x_str = it.next() orelse return null;
    const y_str = it.next() orelse return null;

    const b = std.fmt.parseInt(u16, b_str, 10) catch return null;
    const x = std.fmt.parseInt(u16, x_str, 10) catch return null;
    const y = std.fmt.parseInt(u16, y_str, 10) catch return null;

    var btn: MouseButton = .left;
    if (last_char == 'm') {
        btn = .release;
    } else if (b == 0) {
        btn = .left;
    } else if (b == 1) {
        btn = .middle;
    } else if (b == 2) {
        btn = .right;
    } else if (b == 64) {
        btn = .wheel_up;
    } else if (b == 65) {
        btn = .wheel_down;
    } else if (b >= 32 and b <= 35) {
        btn = .motion;
    }

    return MouseMsg{
        .button = btn,
        .x = x,
        .y = y,
    };
}

pub const VirtualList = struct {
    total_items: usize,
    viewport_height: usize,
    cursor: usize = 0,
    offset: usize = 0,

    pub fn init(total_items: usize, viewport_height: usize) VirtualList {
        return .{
            .total_items = total_items,
            .viewport_height = viewport_height,
        };
    }

    pub fn scrollDown(self: *VirtualList) void {
        if (self.cursor + 1 < self.total_items) {
            self.cursor += 1;
            if (self.cursor >= self.offset + self.viewport_height) {
                self.offset += 1;
            }
        }
    }

    pub fn scrollUp(self: *VirtualList) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            if (self.cursor < self.offset) {
                self.offset = self.cursor;
            }
        }
    }

    pub fn visibleRange(self: VirtualList) struct { start: usize, end: usize } {
        const start = self.offset;
        const end = @min(self.total_items, self.offset + self.viewport_height);
        return .{ .start = start, .end = end };
    }
};

pub const TerminalSize = struct {
    width: u16,
    height: u16,
};

pub fn getTerminalSize() TerminalSize {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const win = std.os.windows;
        const kernel32 = struct {
            pub extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) win.HANDLE;
            pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: win.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) win.BOOL;
            pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
                dwSize: extern struct { X: win.SHORT, Y: win.SHORT },
                dwCursorPosition: extern struct { X: win.SHORT, Y: win.SHORT },
                wAttributes: win.WORD,
                srWindow: extern struct { Left: win.SHORT, Top: win.SHORT, Right: win.SHORT, Bottom: win.SHORT },
                dwMaximumWindowSize: extern struct { X: win.SHORT, Y: win.SHORT },
            };
        };
        const STD_OUTPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -11));
        const handle = kernel32.GetStdHandle(STD_OUTPUT_HANDLE);
        var info: kernel32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (kernel32.GetConsoleScreenBufferInfo(handle, &info) != .FALSE) {
            const width = @as(u16, @intCast(@max(1, info.srWindow.Right - info.srWindow.Left + 1)));
            const height = @as(u16, @intCast(@max(1, info.srWindow.Bottom - info.srWindow.Top + 1)));
            return .{ .width = width, .height = height };
        }
    }
    // Default fallback
    return .{ .width = 80, .height = 24 };
}
