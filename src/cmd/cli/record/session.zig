//! Running a tape: a shell on a pseudo-terminal, the tape's commands typed into it at
//! their pace, and what the terminal shows captured as frames on a clock, then written
//! as GIF, PNG frames, text, or video.

const std = @import("std");
const builtin = @import("builtin");
const term = @import("term");
const tape = @import("tape.zig");
const themes = @import("theme.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Duration = Io.Duration;

/// Everything `Set` sets, with vhs's defaults.
pub const Config = struct {
    shell: []const u8 = default_shell,
    font_family: []const u8 = "",
    font_size: f32 = 22,
    letter_spacing: f32 = 0,
    line_height: f32 = 1.0,
    width: u32 = 1200,
    height: u32 = 600,
    columns: ?u16 = null,
    rows: ?u16 = null,
    padding: u32 = 60,
    margin: u32 = 0,
    margin_fill: term.image.Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    window_bar: term.raster.WindowBar = .none,
    window_bar_size: u32 = 30,
    border_radius: u32 = 0,
    theme: themes.Theme = themes.themes[0],
    typing_speed: Duration = .fromMilliseconds(50),
    framerate: u32 = 50,
    playback_speed: f32 = 1,
    loop_offset: f32 = 0,
    cursor_blink: bool = true,
    wait_timeout: Duration = .fromSeconds(15),
    wait_pattern: []const u8 = ">$",
    title: []const u8 = "",
    shadow: bool = false,

    pub const default_shell = if (builtin.os.tag == .windows) "pwsh" else "bash";
};

pub const Error = error{ RecordFailed, Canceled } || Allocator.Error;

/// A frame: the screen's cells, the cursor, and how long it showed.
pub const Frame = struct {
    cells: []term.vt.Cell,
    row: usize,
    column: usize,
    cursor_visible: bool,
    cursor_shape: term.vt.CursorShape,
    duration: Duration,
};

/// What a run produced: frames, screenshots taken, and where the outputs go.
pub const Recording = struct {
    arena: std.heap.ArenaAllocator,
    frames: std.ArrayList(Frame) = .empty,
    outputs: std.ArrayList([]const u8) = .empty,
    screenshots: std.ArrayList(Screenshot) = .empty,
    size: term.Size,
    config: Config,

    pub const Screenshot = struct { path: []const u8, frame: Frame };

    pub fn deinit(r: *Recording) void {
        r.arena.deinit();
    }
};

/// Shared between the run and the thread that reads the pty.
const Shared = struct {
    mutex: Io.Mutex = .init,
    screen: term.vt.Screen,
    done: std.atomic.Value(bool) = .init(false),
};

/// What a run reports as it goes, and on failure.
pub const Reporter = struct {
    context: *anyopaque,
    fail: *const fn (context: *anyopaque, line: u32, message: []const u8) void,
};

/// Runs `lines` and returns what it recorded. `painter_cell` is the size of a cell in
/// pixels, to turn `Width` and `Height` into columns and rows.
pub fn run(
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    lines: []const tape.Line,
    base_config: Config,
    cell: [2]usize,
    report: Reporter,
) Error!Recording {
    var recording: Recording = .{ .arena = .init(gpa), .size = undefined, .config = base_config };
    errdefer recording.deinit();
    const arena = recording.arena.allocator();
    var config = base_config;
    var env = try environ.clone(arena);
    // Settings and outputs come first, as vhs reads them before running anything.
    for (lines) |line| switch (line.command) {
        .set => |s| applySetting(&config, s, arena) catch {
            report.fail(report.context, line.number, "a setting with a bad value");
            return error.RecordFailed;
        },
        .output => |path| try recording.outputs.append(arena, path),
        .env => |e| try env.put(e.name, e.value),
        .require => |program| if (!onPath(io, &env, program)) {
            report.fail(
                report.context,
                line.number,
                try std.fmt.allocPrint(arena, "{s} is not installed", .{program}),
            );
            return error.RecordFailed;
        },
        else => {},
    };
    recording.config = config;
    const size = terminalSize(config, cell);
    recording.size = size;

    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("PS1", "> ");
    try env.put("PROMPT", "> ");
    try env.put("SNEK_RECORDING", "1");
    var argv_buffer: [8][]const u8 = undefined;
    const argv = shellArgv(config.shell, &argv_buffer);
    var pty = term.Pty.spawn(
        io,
        gpa,
        .{ .argv = argv, .environ = &env, .size = size },
    ) catch |err| {
        const message = switch (err) {
            error.SpawnFailed => try std.fmt.allocPrint(
                arena,
                "cannot start the shell {s}",
                .{config.shell},
            ),
            error.PtyUnavailable => "no pseudo-terminal on this system",
            error.OutOfMemory => return error.OutOfMemory,
        };
        report.fail(report.context, 0, message);
        return error.RecordFailed;
    };
    defer pty.deinit();
    var shared: Shared = .{ .screen = try .initOptions(gpa, size, .{}) };
    defer shared.screen.deinit();
    config.theme.apply(&shared.screen);
    var reader = io.concurrent(readLoop, .{ io, gpa, &pty, &shared }) catch {
        report.fail(report.context, 0, "cannot read the terminal concurrently on this system");
        return error.RecordFailed;
    };
    defer {
        shared.done.store(true, .release);
        pty.kill();
        reader.cancel(io);
    }

    var runner: Runner = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .pty = &pty,
        .shared = &shared,
        .recording = &recording,
        .config = &config,
        .report = report,
        .interval = .fromNanoseconds(@divTrunc(std.time.ns_per_s, @as(i96, config.framerate))),
    };
    // The shell's start is not recorded: wait for its first prompt, quietly.
    runner.hidden = true;
    runner.waitQuiet(.fromMilliseconds(300), .fromSeconds(5));
    runner.hidden = false;
    runner.next_tick = Io.Timestamp.now(io, .awake);
    try runner.runLines(lines, 0);
    // Hold the last frame a moment, as vhs does.
    try runner.idle(.fromMilliseconds(100));
    return recording;
}

fn onPath(io: Io, env: *const std.process.Environ.Map, program: []const u8) bool {
    const path = env.get("PATH") orelse return false;
    var dirs = std.mem.tokenizeScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
    var buffer: [4096]u8 = undefined;
    while (dirs.next()) |dir| {
        const candidate = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, program }) catch continue;
        Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return true;
    }
    return false;
}

/// The columns and rows: as set, or what fits the picture's size after its padding and
/// margin.
pub fn terminalSize(config: Config, cell: [2]usize) term.Size {
    const chrome_w = 2 * (config.padding + config.margin);
    const bar = if (config.window_bar == .none) 0 else config.window_bar_size;
    const chrome_h = chrome_w + bar;
    const fit_columns: u16 = @intCast(
        std.math.clamp((config.width -| chrome_w) / @max(cell[0], 1), 10, 1000),
    );
    const fit_rows: u16 = @intCast(
        std.math.clamp((config.height -| chrome_h) / @max(cell[1], 1), 2, 1000),
    );
    const columns = config.columns orelse fit_columns;
    const rows = config.rows orelse fit_rows;
    return .{ .width = columns, .height = rows };
}

/// How to start `shell` with a plain `> ` prompt and none of the user's configuration.
fn shellArgv(shell: []const u8, buffer: *[8][]const u8) []const []const u8 {
    const name = std.fs.path.stem(std.fs.path.basename(shell));
    const forms = [_]struct { []const u8, []const []const u8 }{
        .{ "bash", &.{ "--noprofile", "--norc" } },
        .{ "zsh", &.{ "-f", "-i" } },
        .{ "fish", &.{ "--no-config", "-C", "function fish_prompt; echo -n '> '; end" } },
        .{
            "pwsh",
            &.{ "-NoLogo", "-NoProfile", "-NoExit", "-Command", "function prompt { '> ' }" },
        },
        .{
            "powershell",
            &.{ "-NoLogo", "-NoProfile", "-NoExit", "-Command", "function prompt { '> ' }" },
        },
        // `/d`: none of the AutoRun commands in the registry (clink and the like).
        .{ "cmd", &.{ "/d", "/k", "prompt $G$S" } },
        .{
            "nu",
            &.{
                "--no-config-file",
                "-e",
                "$env.PROMPT_COMMAND = {|| '' }; $env.PROMPT_INDICATOR = {|| '> ' }",
            },
        },
        .{ "sh", &.{"-i"} },
        .{ "dash", &.{"-i"} },
    };
    buffer[0] = shell;
    for (forms) |form| if (std.mem.eql(u8, form[0], name)) {
        for (form[1], 1..) |arg, i| buffer[i] = arg;
        return buffer[0 .. form[1].len + 1];
    };
    return buffer[0..1];
}

fn applySetting(config: *Config, setting: tape.Setting, arena: Allocator) !void {
    switch (setting) {
        .shell => |v| config.shell = v,
        .font_family => |v| config.font_family = v,
        .font_size => |v| config.font_size = std.math.clamp(v, 4, 200),
        .letter_spacing => |v| config.letter_spacing = v,
        .line_height => |v| config.line_height = std.math.clamp(v, 0.5, 4),
        .width => |v| config.width = v,
        .height => |v| config.height = v,
        .columns => |v| config.columns = @max(v, 2),
        .rows => |v| config.rows = @max(v, 1),
        .padding => |v| config.padding = v,
        .margin => |v| config.margin = v,
        .margin_fill => |v| {
            const c = try term.Color.parse(v);
            const rgb = c.toRgb(.{ .r = 0, .g = 0, .b = 0 });
            config.margin_fill = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
        },
        .window_bar => |v| config.window_bar = windowBar(v) orelse return error.BadValue,
        .window_bar_size => |v| config.window_bar_size = v,
        .border_radius => |v| config.border_radius = v,
        .theme => |v| config.theme = if (v.len > 0 and v[0] == '{')
            try themes.parseJson(arena, v, config.theme)
        else
            (themes.named(v) orelse return error.BadValue).*,
        .typing_speed => |v| config.typing_speed = v,
        .framerate => |v| config.framerate = v,
        .playback_speed => |v| config.playback_speed = std.math.clamp(v, 0.1, 10),
        .loop_offset => |v| config.loop_offset = std.math.clamp(v, 0, 100),
        .cursor_blink => |v| config.cursor_blink = v,
        .wait_timeout => |v| config.wait_timeout = v,
        .wait_pattern => |v| config.wait_pattern = v,
        .title => |v| config.title = v,
        .shadow => |v| config.shadow = v,
    }
}

fn windowBar(name: []const u8) ?term.raster.WindowBar {
    const names = [_]struct { []const u8, term.raster.WindowBar }{
        .{ "Colorful", .colorful }, .{ "ColorfulRight", .colorful_right },
        .{ "Rings", .rings },       .{ "RingsRight", .rings_right },
        .{ "None", .none },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(n[0], name)) return n[1];
    return null;
}

/// Reads the pty into the screen until it closes, and answers the program's queries.
fn readLoop(io: Io, gpa: Allocator, pty: *term.Pty, shared: *Shared) void {
    _ = gpa;
    var buffer: [8192]u8 = undefined;
    while (!shared.done.load(.acquire)) {
        const n = pty.read(&buffer) catch return;
        if (n == 0) return;
        shared.mutex.lockUncancelable(io);
        shared.screen.write(buffer[0..n]);
        const answers: ?[]u8 = shared.screen.takeResponses() catch null;
        shared.mutex.unlock(io);
        if (answers) |bytes| {
            defer shared.screen.gpa.free(bytes);
            if (bytes.len > 0) pty.write(bytes) catch {};
        }
    }
}

const Runner = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    pty: *term.Pty,
    shared: *Shared,
    recording: *Recording,
    config: *Config,
    report: Reporter,
    interval: Duration,
    next_tick: Io.Timestamp = .zero,
    hidden: bool = false,
    clipboard: []const u8 = "",
    depth: u8 = 0,

    fn runLines(r: *Runner, lines: []const tape.Line, depth: u8) Error!void {
        for (lines) |line| try r.command(line, depth);
    }

    fn command(r: *Runner, line: tape.Line, depth: u8) Error!void {
        switch (line.command) {
            .set, .output, .require, .env => {},
            .type => |t| {
                const speed = t.speed orelse r.config.typing_speed;
                var it: term.width.Iterator = .init(t.text);
                while (it.next()) |cluster| {
                    const bytes = if (cluster.bytes.len == 1 and cluster.bytes[0] == '\n')
                        "\r"
                    else
                        cluster.bytes;
                    try r.send(bytes);
                    try r.idle(speed);
                }
            },
            .key => |k| {
                const speed = k.speed orelse r.config.typing_speed;
                var buffer: [8]u8 = undefined;
                for (0..k.count) |_| {
                    try r.send(k.key.bytes(&buffer));
                    try r.idle(speed);
                }
            },
            .sleep => |d| try r.idle(d),
            .wait => |w| try r.wait(w, line.number),
            .hide => r.hidden = true,
            .show => {
                r.hidden = false;
                r.next_tick = Io.Timestamp.now(r.io, .awake);
            },
            .screenshot => |path| try r.recording.screenshots.append(
                r.arena,
                .{ .path = path, .frame = try r.snapshot(.zero) },
            ),
            .copy => |text| r.clipboard = text,
            .paste => {
                try r.send(r.clipboard);
                try r.idle(r.config.typing_speed);
            },
            .source => |path| {
                if (depth > 8) {
                    r.report.fail(r.report.context, line.number, "Source nested too deep");
                    return error.RecordFailed;
                }
                const text = Io.Dir.cwd().readFileAlloc(
                    r.io,
                    path,
                    r.arena,
                    .limited(1 << 20),
                ) catch {
                    r.report.fail(
                        r.report.context,
                        line.number,
                        try std.fmt.allocPrint(r.arena, "{s}: cannot read it", .{path}),
                    );
                    return error.RecordFailed;
                };
                var diag: tape.Diagnostic = .{};
                const sourced = tape.parse(r.arena, text, &diag) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ParseFailed => {
                        r.report.fail(
                            r.report.context,
                            line.number,
                            try std.fmt.allocPrint(
                                r.arena,
                                "{s}:{d}: {s}",
                                .{ path, diag.line, diag.message },
                            ),
                        );
                        return error.RecordFailed;
                    },
                };
                try r.runLines(sourced, depth + 1);
            },
        }
    }

    fn send(r: *Runner, bytes: []const u8) Error!void {
        r.pty.write(bytes) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.WriteFailed => {},
        };
    }

    /// Lets `duration` pass, capturing a frame every interval.
    fn idle(r: *Runner, duration: Duration) Error!void {
        const io = r.io;
        const until = Io.Timestamp.now(io, .awake).addDuration(duration);
        while (true) {
            const now = Io.Timestamp.now(io, .awake);
            if (r.next_tick.nanoseconds <= now.nanoseconds) {
                try r.capture();
                r.next_tick = r.next_tick.addDuration(r.interval);
                // Behind by more than a frame (a slow machine): skip ahead rather than burst.
                if (r.next_tick.nanoseconds < now.nanoseconds) {
                    r.next_tick = now.addDuration(r.interval);
                }
                continue;
            }
            if (now.nanoseconds >= until.nanoseconds) return;
            const wake = @min(r.next_tick.nanoseconds, until.nanoseconds);
            io.sleep(.fromNanoseconds(wake - now.nanoseconds), .awake) catch return error.Canceled;
        }
    }

    /// Adds the screen as a frame (or the interval to the last frame, when it did not
    /// change).
    fn capture(r: *Runner) Error!void {
        if (r.hidden) return;
        const frames = &r.recording.frames;
        const io = r.io;
        r.shared.mutex.lockUncancelable(io);
        defer r.shared.mutex.unlock(io);
        const screen = &r.shared.screen;
        if (frames.items.len > 0) {
            const last = &frames.items[frames.items.len - 1];
            const same = last.row == screen.row and last.column == screen.column and
                last.cursor_visible == screen.cursor_visible and
                std.mem.eql(
                    u8,
                    std.mem.sliceAsBytes(last.cells),
                    std.mem.sliceAsBytes(screen.grid().cells),
                );
            if (same) {
                last.duration = .fromNanoseconds(
                    last.duration.nanoseconds + r.interval.nanoseconds,
                );
                return;
            }
        }
        try frames.append(r.arena, .{
            .cells = try r.arena.dupe(term.vt.Cell, screen.grid().cells),
            .row = screen.row,
            .column = screen.column,
            .cursor_visible = screen.cursor_visible,
            .cursor_shape = screen.cursor_shape,
            .duration = r.interval,
        });
    }

    fn snapshot(r: *Runner, duration: Duration) Error!Frame {
        r.shared.mutex.lockUncancelable(r.io);
        defer r.shared.mutex.unlock(r.io);
        const screen = &r.shared.screen;
        return .{
            .cells = try r.arena.dupe(term.vt.Cell, screen.grid().cells),
            .row = screen.row,
            .column = screen.column,
            .cursor_visible = screen.cursor_visible,
            .cursor_shape = screen.cursor_shape,
            .duration = duration,
        };
    }

    /// Until the line the cursor is on (or the whole screen) matches, or the timeout.
    fn wait(r: *Runner, w: anytype, line: u32) Error!void {
        const pattern = w.pattern orelse r.config.wait_pattern;
        var re = term.Regex.compile(r.gpa, pattern) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => {
                r.report.fail(r.report.context, line, "not a valid regular expression");
                return error.RecordFailed;
            },
        };
        defer re.deinit(r.gpa);
        const timeout = w.timeout orelse r.config.wait_timeout;
        const deadline = Io.Timestamp.now(r.io, .awake).addDuration(timeout);
        while (true) {
            if (try r.matches(&re, w.scope)) return;
            if (Io.Timestamp.now(r.io, .awake).nanoseconds > deadline.nanoseconds) {
                r.report.fail(
                    r.report.context,
                    line,
                    try std.fmt.allocPrint(r.arena, "timed out waiting for /{s}/", .{pattern}),
                );
                return error.RecordFailed;
            }
            try r.idle(.fromMilliseconds(10));
        }
    }

    fn matches(r: *Runner, re: *const term.Regex, scope: tape.WaitScope) Error!bool {
        r.shared.mutex.lockUncancelable(r.io);
        defer r.shared.mutex.unlock(r.io);
        const screen = &r.shared.screen;
        var text: Io.Writer.Allocating = .init(r.gpa);
        defer text.deinit();
        switch (scope) {
            .screen => screen.writeText(&text.writer) catch return error.OutOfMemory,
            .line => {
                // The cursor's line, or the last line with anything on it.
                var row = screen.row;
                if (screen.rowIsBlank(row)) {
                    var k = screen.size.height;
                    while (k > 0) : (k -= 1) if (!screen.rowIsBlank(k - 1)) {
                        row = k - 1;
                        break;
                    };
                }
                screen.writeRow(&text.writer, row) catch return error.OutOfMemory;
            },
        }
        return re.isMatch(std.mem.trimEnd(u8, text.written(), " "));
    }

    /// Waits until output has been quiet for `quiet` (the shell is ready), `limit` at most.
    fn waitQuiet(r: *Runner, quiet: Duration, limit: Duration) void {
        const io = r.io;
        const start = Io.Timestamp.now(io, .awake);
        var last_text: u64 = 0;
        var stable_since = start;
        while (true) {
            const now = Io.Timestamp.now(io, .awake);
            r.shared.mutex.lockUncancelable(io);
            const hash = std.hash.Wyhash.hash(
                0,
                std.mem.sliceAsBytes(r.shared.screen.grid().cells),
            );
            const blank = r.shared.screen.rowIsBlank(r.shared.screen.row) and
                r.shared.screen.row == 0;
            r.shared.mutex.unlock(io);
            if (hash != last_text) {
                last_text = hash;
                stable_since = now;
            } else if (!blank and
                now.nanoseconds - stable_since.nanoseconds >= quiet.nanoseconds) return;
            if (now.nanoseconds - start.nanoseconds >= limit.nanoseconds) return;
            io.sleep(.fromMilliseconds(20), .awake) catch return;
        }
    }
};

const testing = std.testing;

test terminalSize {
    const size = terminalSize(.{}, .{ 12, 26 });
    try testing.expectEqual(90, size.width);
    try testing.expectEqual(18, size.height);
    try testing.expectEqual(40, terminalSize(.{ .columns = 40, .rows = 5 }, .{ 12, 26 }).width);
}

test shellArgv {
    var buffer: [8][]const u8 = undefined;
    try testing.expectEqualStrings("--norc", shellArgv("/bin/bash", &buffer)[2]);
    try testing.expectEqual(1, shellArgv("tcsh", &buffer).len);
}
