//! Running a model the usual way, in one call: on the terminal, with a text snapshot when
//! there is none (`run`), or over a remote session (`runSession`). Both return the exit
//! status a command ends with: 0, or 130 after Ctrl-C.
//!
//! ```zig
//! var monitor: Monitor = .{};
//! const status = try tui.run(ctx.gpa, ctx.io, &monitor, .{
//!     .environ = ctx.environ,
//!     .program = .{ .alt_screen = true },
//!     .snapshot_out = ctx.out, // no terminal: print the first frame instead
//! });
//! if (status != 0) return ctx.exit(status);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const term = @import("term");
const Terminal = term.Terminal;
const program_zig = @import("Program.zig");
const testing_zig = @import("testing.zig");
const Options = program_zig.Options;
const Size = program_zig.Size;

/// The exit status after Ctrl-C: 128 + `SIGINT`, as shells report it.
pub const interrupted_status: u8 = 130;

/// How `run` runs a model.
pub const RunOptions = struct {
    /// How the program draws. Its `capability` is replaced by what the terminal shows
    /// under `environ`.
    program: Options = .{},
    /// The environment, for the terminal's capability (`NO_COLOR`, `TERM`, ...).
    environ: *const std.process.Environ.Map,
    /// Where the first frame goes, as plain text, when there is no terminal (or with
    /// `snapshot`). Null makes a missing terminal `error.NotATerminal`.
    snapshot_out: ?*Io.Writer = null,
    /// Write the snapshot even at a terminal (a `--snapshot` flag).
    snapshot: bool = false,
    /// The size of the virtual terminal the snapshot is drawn on.
    snapshot_size: Size = .{ .width = 80, .height = 24 },
};

/// Runs `model` (a pointer to a model, which stays the caller's) on the terminal until it
/// quits, and returns the exit status: 0, or `interrupted_status` after Ctrl-C. Without a
/// terminal, or with `options.snapshot`, draws the first frame on a virtual terminal and
/// writes it to `options.snapshot_out` as text (lines without trailing spaces), returning 0.
pub fn run(gpa: Allocator, io: Io, model: anytype, options: RunOptions) !u8 {
    const Model = @typeInfo(@TypeOf(model)).pointer.child;
    var buffer: [4096]u8 = undefined;
    var opened: ?Terminal = if (options.snapshot) null else Terminal.open(io, &buffer) catch |err|
        switch (err) {
            error.NotATerminal => null,
            error.Canceled => return error.Canceled,
        };
    const terminal = if (opened) |*t| t else {
        const out = options.snapshot_out orelse return error.NotATerminal;
        try snapshot(Model, gpa, model, options, out);
        return 0;
    };
    defer terminal.close();
    var program_options = options.program;
    program_options.capability = terminal.capabilityIn(options.environ);
    var program: program_zig.Program(Model) = .init(gpa, model, terminal.writer(), program_options);
    defer program.deinit();
    const outcome = try program.run(terminal);
    return if (outcome.interrupted) interrupted_status else 0;
}

/// The first frame of `model` at `options.snapshot_size`, as text, to `out`.
fn snapshot(
    comptime Model: type,
    gpa: Allocator,
    model: *Model,
    options: RunOptions,
    out: *Io.Writer,
) !void {
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var program_options = options.program;
    program_options.size = options.snapshot_size;
    var program: program_zig.Program(Model) = .init(gpa, model, &output.writer, program_options);
    defer program.deinit();
    try program.start();
    var screen: testing_zig.Screen = try .init(gpa, options.snapshot_size);
    defer screen.deinit();
    screen.write(output.written());
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try screen.writeText(&text.writer);
    try testing_zig.writeTrimmed(out, text.written());
    try out.flush();
}

/// Runs `model` (a pointer, which stays the caller's) over a remote session until it
/// quits or the other end goes, and returns the exit status as `run` does. `session` is a
/// `platform.ssh.Session` or `platform.web.Session`: anything `Program.runSession` takes
/// that also has `writer(buffer)`. The program starts at the session's size (its `size`,
/// or its `pty`'s), else at `options.size`.
pub fn runSession(gpa: Allocator, io: Io, model: anytype, session: anytype, options: Options) !u8 {
    const Model = @typeInfo(@TypeOf(model)).pointer.child;
    const Session = @typeInfo(@TypeOf(session)).pointer.child;
    var sized = options;
    if (@hasField(Session, "size")) {
        sized.size = .{ .width = session.size.width, .height = session.size.height };
    } else if (@hasField(Session, "pty")) {
        if (session.pty) |pty| sized.size = .{ .width = pty.size.width, .height = pty.size.height };
    }
    var buffer: [8192]u8 = undefined;
    var out = session.writer(&buffer);
    var program: program_zig.Program(Model) = .init(gpa, model, &out.interface, sized);
    defer program.deinit();
    const outcome = try program.runSession(io, session);
    return if (outcome.interrupted) interrupted_status else 0;
}

const testing = std.testing;

const Counter = struct {
    count: u32 = 0,
    pub fn update(m: *Counter, msg: program_zig.Msg) program_zig.Cmd {
        if (msg == .key) {
            if (msg.key.matches("q")) return .quit;
            m.count += 1;
        }
        return .none;
    }
    pub fn view(m: *const Counter, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("count {d}   \n\n", .{m.count});
    }
};

test "run without a terminal writes the first frame as trimmed text" {
    var counter: Counter = .{ .count = 3 };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const environ: std.process.Environ.Map = .init(testing.allocator);
    const status = try run(testing.allocator, testing.io, &counter, .{
        .environ = &environ,
        .snapshot = true,
        .snapshot_out = &out.writer,
        .snapshot_size = .{ .width = 20, .height = 4 },
    });
    try testing.expectEqual(0, status);
    try testing.expectEqualStrings("count 3\n", out.written());
}

test "run without a terminal and nowhere for a snapshot fails" {
    // Under the test runner standard input is not a terminal, but /dev/tty may be.
    if (Terminal.open(testing.io, &.{})) |t| {
        var opened = t;
        opened.close();
        return error.SkipZigTest;
    } else |_| {}
    var counter: Counter = .{};
    const environ: std.process.Environ.Map = .init(testing.allocator);
    try testing.expectError(error.NotATerminal, run(testing.allocator, testing.io, &counter, .{
        .environ = &environ,
    }));
}

/// A remote session from a script, with a size and a writer, as a web session has.
const Scripted = struct {
    events: []const Event,
    index: usize = 0,
    size: struct { width: u16, height: u16 } = .{ .width = 33, .height = 7 },
    written: *Io.Writer.Allocating,

    const Event = union(enum) {
        data: []const u8,
        resize: struct { width: u16, height: u16 },
        signal: []const u8,
        eof,
        timeout,
        closed,
    };

    pub fn next(s: *Scripted, _: Io.Timeout) Io.Cancelable!Event {
        if (s.index == s.events.len) return .closed;
        s.index += 1;
        return s.events[s.index - 1];
    }

    const Writer = struct {
        interface: Io.Writer,
        session: *Scripted,
        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
            const sink = &self.session.written.writer;
            try sink.writeAll(w.buffered());
            w.end = 0;
            return sink.writeSplat(data, splat);
        }
    };

    pub fn writer(s: *Scripted, buffer: []u8) Writer {
        return .{ .session = s, .interface = .{
            .buffer = buffer,
            .vtable = &.{ .drain = Writer.drain },
        } };
    }
};

test "runSession starts at the session's size and updates the caller's model" {
    var written: Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    const events: []const Scripted.Event = &.{ .{ .data = "ab" }, .{ .data = "q" } };
    var session: Scripted = .{ .events = events, .written = &written };
    const Sized = struct {
        size: Size = .{ .width = 0, .height = 0 },
        keys: u32 = 0,
        pub fn update(m: *@This(), msg: program_zig.Msg) program_zig.Cmd {
            switch (msg) {
                .resize => |size| m.size = size,
                .key => |key| {
                    if (key.matches("q")) return .quit;
                    m.keys += 1;
                },
                else => {},
            }
            return .none;
        }
        pub fn view(m: *const @This(), w: *Io.Writer) Io.Writer.Error!void {
            try w.print("{d} keys", .{m.keys});
        }
    };
    var model: Sized = .{};
    const status = try runSession(testing.allocator, testing.io, &model, &session, .{});
    try testing.expectEqual(0, status);
    try testing.expectEqual(2, model.keys);
    try testing.expectEqual(33, model.size.width);
    try testing.expect(std.mem.indexOf(u8, written.written(), "0 keys") != null);
}
