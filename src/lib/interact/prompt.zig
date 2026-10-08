const std = @import("std");
const tea = @import("render").tea;
const style = @import("render").style;

/// The reader thread every prompt in this process shares, and the input stream it was built
/// for (ROADMAP S-8).
///
/// Four prompt functions used to each start their own reader thread over the same `ctx.in`.
/// `add` runs two of them in one command - a multi-select, then a confirm per colliding
/// component - so a run could leave several threads blocked in `readVec` on one stream,
/// racing for the bytes. The user-visible symptom is a prompt that ignores what was typed.
///
/// **Why a process global rather than a field on the caller's `Ctx`.** The first attempt put
/// the dialog on `Ctx` and cached it from inside the prompt function. That cannot work:
/// `App.Ctx` is passed **by value** - `fn addRun(ctx: App.Ctx, ...)`, `runShell(..., ctx:
/// anytype)`, and each prompt signature - so the cache landed in a per-call copy and died when
/// the prompt returned. Every prompt still built its own reader. Storing it here needs no
/// framework signature change, and it matches the thing being shared: there is exactly **one
/// stdin per process**.
///
/// Correctness is unaffected by the wider sharing. `skip` is measured at the end of each `run`
/// by `Program.onRunEnd`, so the prompt that is currently asking consumes its own leftover and
/// the next one discards the rest - true whether the sharing is per-command or per-process.
///
/// The allocation is deliberately never freed while a real terminal lives. A thread blocked in
/// a read that no byte will end cannot be joined, and the process exits when the command
/// returns - the same trade B-4 documented, moved from one reader per prompt to one per process.
var shared: ?struct {
    /// Identifies the stream the dialog reads from. Each test builds its own `Ctx` with its own
    /// `in`, so the cache must notice when the stream changes rather than handing a prompt a
    /// reader attached to a different source.
    for_input: *std.Io.Reader,
    reader: *tea.DialogReader(void),
} = null;

/// The shared dialog for `ctx.in`, built on first use and reused afterwards.
///
/// Not thread-safe, and does not need to be: prompts run on the command's own thread, one at a
/// time. A caller that ever prompted from two threads would need a lock here.
fn dialogFor(ctx: anytype) !*tea.DialogReader(void) {
    if (shared) |existing| {
        if (existing.for_input == ctx.in) return existing.reader;
        // A different stream: a test, or a second invocation in one process. The previous
        // dialog is only safe to release because its source reached end of stream - otherwise
        // `deinit` would block joining a thread that is still reading.
        dropShared();
    }
    return installShared(ctx.in, ctx.io);
}

/// Builds the dialog for `in` and makes it the shared one. Separate from `dialogFor` so the test
/// accessor below can install a dialog whose channel the test already holds - which is the only
/// way to test the wiring without hanging; see `installSharedForTest`.
fn installShared(in: *std.Io.Reader, io: std.Io) !*tea.DialogReader(void) {
    const Reader = tea.DialogReader(void);
    const reader = try page_allocator().create(Reader);
    errdefer page_allocator().destroy(reader);
    reader.* = try Reader.init(page_allocator(), io, in.*);
    shared = .{ .for_input = in, .reader = reader };
    return reader;
}

/// Releases the shared dialog **without joining its reader**.
///
/// `DialogReader.deinit` joins, which is right when the source reaches end of stream and would
/// hang otherwise: on a real terminal stdin never ends, so the thread stays blocked in `readVec`
/// forever. Since this is called to *replace* a dialog while the process runs, it must detach -
/// the thread leaks, which is the trade B-4 already documents, and nothing it touches is freed.
fn dropShared() void {
    if (shared) |existing| {
        existing.reader.detach();
        shared = null;
    }
}

/// The shared dialog, for tests. Null when nothing has prompted yet.
pub fn sharedDialogForTest() ?*tea.DialogReader(void) {
    return if (shared) |s| s.reader else null;
}

/// Installs a dialog as the shared one for `in` and returns its channel.
///
/// This is what makes the wiring testable, and it exists because the obvious test cannot work:
/// calling `confirm` twice over a finite source **hangs**. The reader thread returns at end of
/// stream, and `run` is then blocked in `Channel.pop` for a message that never arrives. So the
/// answer has to be queued *before* the prompt runs, which means the test needs the channel
/// first, which means the dialog has to exist first. This hands it that channel.
///
/// The test then drives the real `confirm` model - not a stand-in - and asserts that a second
/// prompt reaches the same dialog.
pub fn installSharedForTest(in: *std.Io.Reader, io: std.Io) !*tea.Channel(tea.Msg(void)) {
    const reader = try installShared(in, io);
    return reader.channel();
}

/// Drops the shared dialog so one case's dialog cannot answer another's prompt. Detaches rather
/// than joining, so it is safe whether or not the source ended; see `dropShared`.
pub fn resetSharedDialogForTest() void {
    dropShared();
}

/// `std.heap.page_allocator`, reached through a function so the call sites above cannot drift
/// from the framework's own choice for anything a reader thread outlives. No test allocator
/// accounts for it, which is why the dialog needs no leak suppression.
fn page_allocator() std.mem.Allocator {
    return tea.Program(void, void).default_allocator;
}

// --- CONFIRM PROMPT ---
pub const ConfirmOptions = struct {
    default: bool = false,
};

pub fn confirm(ctx: anytype, question: []const u8, options: ConfirmOptions) !bool {
    const Model = struct {
        q: []const u8,
        val: bool,
        done: bool = false,

        pub fn init(q: []const u8, def: bool) @This() {
            return .{ .q = q, .val = def };
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .left, .right => {
                        self.val = !self.val;
                    },
                    .char => {
                        const c = k.char orelse return .none;
                        if (c == 'y' or c == 'Y') {
                            self.val = true;
                            self.done = true;
                            return .quit;
                        } else if (c == 'n' or c == 'N') {
                            self.val = false;
                            self.done = true;
                            return .quit;
                        }
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new().faint(true);

            try writer.print("? {s} ", .{self.q});

            if (self.done) {
                const text = if (self.val) "Yes" else "No";
                try active_style.render(writer, text);
            } else {
                if (self.val) {
                    try active_style.render(writer, "[Y]");
                    try writer.writeAll(" ");
                    try inactive_style.render(writer, "n");
                } else {
                    try inactive_style.render(writer, "y");
                    try writer.writeAll(" ");
                    try active_style.render(writer, "[N]");
                }
            }
            try writer.writeAll("\n");
        }
    };

    const m = Model.init(question, options.default);

    // The dialog's shared reader, not one per prompt: two prompts in one command used to
    // leave two threads reading the same stdin (ROADMAP S-8). See `dialogFor`.
    const dialog = try dialogFor(ctx);
    var prog = dialog.program(m);
    try prog.run(ctx);

    return prog.model.val;
}

// --- SELECT PROMPT ---
pub fn select(ctx: anytype, comptime EnumType: type, question: []const u8) !EnumType {
    const type_info = @typeInfo(EnumType);
    if (type_info != .@"enum") @compileError("select prompt requires an enum type");

    const fields = type_info.@"enum".fields;

    const Model = struct {
        q: []const u8,
        cursor: usize = 0,
        done: bool = false,

        pub fn init(q: []const u8) @This() {
            return .{ .q = q };
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .up => {
                        if (self.cursor > 0) self.cursor -= 1;
                    },
                    .down => {
                        if (self.cursor < fields.len - 1) self.cursor += 1;
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new();

            try writer.print("? {s}\n", .{self.q});

            if (self.done) {
                inline for (fields, 0..) |field, i| {
                    if (self.cursor == i) {
                        try writer.writeAll("  ");
                        try active_style.render(writer, field.name);
                        try writer.writeAll("\n");
                    }
                }
            } else {
                inline for (fields, 0..) |field, i| {
                    if (self.cursor == i) {
                        try active_style.render(writer, "> ");
                        try active_style.render(writer, field.name);
                    } else {
                        try inactive_style.render(writer, "  ");
                        try inactive_style.render(writer, field.name);
                    }
                    try writer.writeAll("\n");
                }
            }
        }
    };

    const m = Model.init(question);
    const dialog = try dialogFor(ctx);
    var prog = dialog.program(m);
    try prog.run(ctx);

    inline for (fields, 0..) |field, i| {
        if (prog.model.cursor == i) {
            return @field(EnumType, field.name);
        }
    }
    unreachable;
}

// --- MULTI-SELECT PROMPT ---
pub fn multiSelect(ctx: anytype, comptime EnumType: type, question: []const u8) ![]EnumType {
    const type_info = @typeInfo(EnumType);
    if (type_info != .Enum) @compileError("multiSelect prompt requires an enum type");

    const fields = type_info.Enum.fields;

    const Model = struct {
        q: []const u8,
        cursor: usize = 0,
        selected: [fields.len]bool = [_]bool{false} ** fields.len,
        done: bool = false,

        pub fn init(q: []const u8) @This() {
            return .{ .q = q };
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .up => {
                        if (self.cursor > 0) self.cursor -= 1;
                    },
                    .down => {
                        if (self.cursor < fields.len - 1) self.cursor += 1;
                    },
                    .char => {
                        const c = k.char orelse return .none;
                        if (c == ' ') {
                            self.selected[self.cursor] = !self.selected[self.cursor];
                        }
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new();

            try writer.print("? {s} (Press Space to select, Enter to confirm)\n", .{self.q});

            if (self.done) {
                inline for (fields, 0..) |field, i| {
                    if (self.selected[i]) {
                        try writer.writeAll("  ");
                        try active_style.render(writer, field.name);
                        try writer.writeAll("\n");
                    }
                }
            } else {
                inline for (fields, 0..) |field, i| {
                    if (self.cursor == i) {
                        try active_style.render(writer, "> ");
                    } else {
                        try inactive_style.render(writer, "  ");
                    }

                    if (self.selected[i]) {
                        try active_style.render(writer, "[x] ");
                    } else {
                        try inactive_style.render(writer, "[ ] ");
                    }

                    if (self.cursor == i) {
                        try active_style.render(writer, field.name);
                    } else {
                        try inactive_style.render(writer, field.name);
                    }
                    try writer.writeAll("\n");
                }
            }
        }
    };

    const m = Model.init(question);
    const dialog = try dialogFor(ctx);
    var prog = dialog.program(m);
    try prog.run(ctx);

    var selected_list = std.ArrayListUnmanaged(EnumType).empty;
    errdefer selected_list.deinit(ctx.allocator);

    inline for (fields, 0..) |field, i| {
        if (prog.model.selected[i]) {
            try selected_list.append(ctx.allocator, @field(EnumType, field.name));
        }
    }

    return selected_list.toOwnedSlice(ctx.allocator);
}

// --- DYNAMIC MULTI-SELECT PROMPT ---
pub fn multiSelectDynamic(ctx: anytype, options: []const []const u8, question: []const u8) ![][]const u8 {
    const Model = struct {
        q: []const u8,
        opts: []const []const u8,
        cursor: usize = 0,
        selected: []bool,
        done: bool = false,
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, q: []const u8, opts: []const []const u8) !@This() {
            const selected = try alloc.alloc(bool, opts.len);
            @memset(selected, false);
            return .{ .allocator = alloc, .q = q, .opts = opts, .selected = selected };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.selected);
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .up => {
                        if (self.cursor > 0) self.cursor -= 1;
                    },
                    .down => {
                        if (self.cursor < self.opts.len - 1) self.cursor += 1;
                    },
                    .char => {
                        const c = k.char orelse return .none;
                        if (c == ' ') {
                            self.selected[self.cursor] = !self.selected[self.cursor];
                        }
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new();

            try writer.print("? {s} (Press Space to select, Enter to confirm)\n", .{self.q});

            if (self.done) {
                for (self.opts, 0..) |opt, i| {
                    if (self.selected[i]) {
                        try writer.writeAll("  ");
                        try active_style.render(writer, opt);
                        try writer.writeAll("\n");
                    }
                }
            } else {
                for (self.opts, 0..) |opt, i| {
                    if (self.cursor == i) {
                        try active_style.render(writer, "> ");
                    } else {
                        try inactive_style.render(writer, "  ");
                    }

                    if (self.selected[i]) {
                        try active_style.render(writer, "[x] ");
                    } else {
                        try inactive_style.render(writer, "[ ] ");
                    }

                    if (self.cursor == i) {
                        try active_style.render(writer, opt);
                    } else {
                        try inactive_style.render(writer, opt);
                    }
                    try writer.writeAll("\n");
                }
            }
        }
    };

    var m = try Model.init(ctx.allocator, question, options);
    defer m.deinit();

    const dialog = try dialogFor(ctx);
    var prog = dialog.program(m);
    try prog.run(ctx);

    var selected_list = std.ArrayListUnmanaged([]const u8).empty;
    errdefer selected_list.deinit(ctx.allocator);

    for (options, 0..) |opt, i| {
        if (prog.model.selected[i]) {
            try selected_list.append(ctx.allocator, opt);
        }
    }

    return selected_list.toOwnedSlice(ctx.allocator);
}

test "two prompts through the real functions share one dialog" {
    // The regression test ROADMAP S-8 needed and did not have. It drives the **real** `confirm`
    // model through `dialogFor`, from two separate copies of one context - which is exactly what
    // a command does, because `App.Ctx` is passed by value.
    //
    // The answers are queued into the channel *before* prompting, and that ordering is the whole
    // trick. Driving `confirm` from a finite source instead hangs: the reader thread returns at
    // end of stream and `run` is left blocked in `Channel.pop` for a message that never arrives.
    // Pushing first means the loop finds its answer immediately and returns.
    const testing = std.testing;
    resetSharedDialogForTest();
    defer resetSharedDialogForTest();

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    // One byte so the reader thread has somewhere to read and stops at end of stream; it never
    // produces a message, because the empty-ish source is drained before anything is typed.
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    const Ctx = struct {
        io: std.Io,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
    };
    const base = Ctx{ .io = testing.io, .in = &in_reader, .out = &out };

    // Queue the answers first: `y` resolves the confirm, `q` ends the run.
    const channel = try installSharedForTest(&in_reader, testing.io);
    try channel.push(.{ .key = .{ .key = .char, .char = 'y' } });
    try channel.push(.{ .key = .{ .key = .char, .char = 'q' } });

    // First prompt, from one copy.
    const first_copy = base;
    try testing.expect(try confirm(first_copy, "first?", .{ .default = false }));
    const after_first = sharedDialogForTest();
    try testing.expect(after_first != null);

    // Second prompt, from a *different copy* - the case that used to build a second dialog and
    // start a second reader thread. Same channel, so the same answers are not there any more;
    // queue a fresh pair.
    try channel.push(.{ .key = .{ .key = .char, .char = 'y' } });
    try channel.push(.{ .key = .{ .key = .char, .char = 'q' } });
    const second_copy = base;
    try testing.expect(try confirm(second_copy, "second?", .{ .default = false }));

    // The property that was broken: the second prompt reached the same dialog, so there is one
    // reader thread for the dialog rather than one per prompt.
    try testing.expect(sharedDialogForTest() == after_first);
}
