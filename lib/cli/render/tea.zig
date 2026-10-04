const std = @import("std");

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

        model: ModelT,
        channel: *Channel(MsgT),

        pub fn init(model: ModelT, channel: *Channel(MsgT)) Self {
            return .{ .model = model, .channel = channel };
        }

        const StdinContext = struct {
            in: std.Io.Reader,
            channel: *Channel(MsgT),
        };

        fn stdinReaderThread(ctx_ptr: *StdinContext) void {
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

            // Spawn Stdin reader thread
            // Note: ctx.in is passed in generic format. For std.fs.File, we can spawn a thread.
            var stdin_ctx = StdinContext{ .in = ctx.in.*, .channel = self.channel };
            const stdin_thread = try std.Thread.spawn(.{}, stdinReaderThread, .{&stdin_ctx});
            _ = stdin_thread; // We detach or let it block (actually we should terminate it cleanly, but stdin read blocks)

            var prev_lines: usize = 0;

            // Initial view
            var aw = std.Io.Writer.Allocating.init(self.channel.allocator);
            try self.model.view(&aw.writer);
            var view_bytes = aw.writer.buffer[0..aw.writer.end];
            try writer.writeAll(view_bytes);
            prev_lines = std.mem.count(u8, view_bytes, "\n");
            self.channel.allocator.free(aw.writer.buffer);

            // Event Loop
            while (true) {
                // 1. Wait for input or background task message
                const msg = self.channel.pop();

                // 2. Update phase
                const cmd = try self.model.update(msg);

                if (cmd == .quit) {
                    if (prev_lines > 0) {
                        for (0..prev_lines) |_| try writer.writeAll("\x1b[A\x1b[2K\r");
                    }
                    var aw_final = std.Io.Writer.Allocating.init(self.channel.allocator);
                    try self.model.view(&aw_final.writer);
                    view_bytes = aw_final.writer.buffer[0..aw_final.writer.end];
                    try writer.writeAll(view_bytes);
                    try writer.writeAll("\n");
                    self.channel.allocator.free(aw_final.writer.buffer);
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

                var aw_next = std.Io.Writer.Allocating.init(self.channel.allocator);
                try self.model.view(&aw_next.writer);
                view_bytes = aw_next.writer.buffer[0..aw_next.writer.end];
                try writer.writeAll(view_bytes);
                prev_lines = std.mem.count(u8, view_bytes, "\n");
                self.channel.allocator.free(aw_next.writer.buffer);
            }
        }
    };
}

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
