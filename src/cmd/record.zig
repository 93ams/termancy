//! `termancy record`: record terminal sessions from scripts, as vhs does: a tape of
//! commands typed into a shell, recorded as a GIF, PNG frames, text, an animated SVG, or
//! (with ffmpeg) a video. No browser, no ttyd, no ffmpeg needed for GIFs: the terminal is
//! emulated (`term.vt`), drawn in the machine's fonts (`term.raster`), and encoded here.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const term = @import("term");
const tape = @import("record/tape.zig");
const session = @import("record/session.zig");
const output = @import("record/output.zig");
const themes = @import("record/theme.zig");
const capture_zig = @import("record/capture.zig");
const Io = std.Io;

const RunFlags = struct {
    output: []const []const u8 = &.{},
};
const run_flags = cli.flags(RunFlags, field.Set(.{field.Spec(RunFlags){ .fields = .{
    .output = .{ .help = "Also write this (repeatable): .gif, .png, .txt, .svg, .mp4, " ++
        "or a directory/ of frames" },
} }}), .{ .fields = .{
    .output = .{ .short = 'o' },
} });

pub const command = cli.command(.{
    .name = "record",
    .summary = "Record terminal sessions from tapes, as GIFs and more (vhs)",
    .description =
    \\Run a tape (a script of commands: Type "text", Enter, Sleep 2s, Wait /regex/, ...)
    \\in a shell on a pseudo-terminal and record what the terminal shows. Tapes written
    \\for vhs run as they are. Outputs (Output lines, or -o): .gif, .png (the last frame),
    \\a directory/ of PNG frames, .txt or .ascii (each screen as text, for golden tests),
    \\.svg (animated, sharp at any size), and .mp4 or .webm (needs ffmpeg). Fonts are the
    \\machine's: Set FontFamily names one, else a common monospace font is found.
    ,
    .args = .{ .min = 1, .max = 1, .usage = "<file.tape>" },
    .flags = run_flags,
    .logging = true,
    .examples =
    \\termancy record new demo
    \\termancy record demo.tape
    \\termancy record demo.tape -o demo.svg -o golden.txt
    \\termancy record validate demo.tape
    ,
    .subcommands = .{
        cli.command(.{
            .name = "new",
            .summary = "Write a new tape to start from",
            .args = .{ .min = 1, .max = 1, .usage = "<name>" },
            .run = newTape,
        }),
        cli.command(.{
            .name = "validate",
            .summary = "Check tapes for errors without running them",
            .args = .{ .min = 1, .max = null, .usage = "<file.tape>..." },
            .run = validate,
        }),
        cli.command(.{
            .name = "capture",
            .summary = "Write a tape of what you type in a shell",
            .description =
            \\Start a shell in this terminal and note everything typed in it; when the shell
            \\exits, write it as a tape (Type, the keys, Sleep for pauses) to record later.
            ,
            .args = .{ .min = 1, .max = 1, .usage = "<file.tape>" },
            .flags = capture_flags,
            .run = captureTape,
        }),
        cli.command(.{
            .name = "themes",
            .summary = "List the color themes",
            .output = true,
            .run = listThemes,
        }),
    },
    .run = record,
});

/// Keeps a run's first failure, to report once the progress lines are done.
const Reporter = struct {
    arena: std.mem.Allocator,
    line: u32 = 0,
    message: ?[]const u8 = null,

    fn fail(context: *anyopaque, line: u32, message: []const u8) void {
        const r: *Reporter = @ptrCast(@alignCast(context));
        if (r.message != null) return;
        r.line = line;
        r.message = r.arena.dupe(u8, message) catch "out of memory";
    }
};

fn readTape(ctx: *cli.Context, path: []const u8) ![]const tape.Line {
    const text = Io.Dir.cwd().readFileAlloc(
        ctx.io,
        path,
        ctx.arena,
        .limited(4 << 20),
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return ctx.fail("{s}: cannot read it ({s})", .{ path, @errorName(err) });
    };
    var diag: tape.Diagnostic = .{};
    return tape.parse(ctx.arena, text, &diag) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseFailed => ctx.fail("{s}:{d}: {s}", .{ path, diag.line, diag.message }),
    };
}

fn record(ctx: *cli.Context, flags: RunFlags) !void {
    const path = ctx.args[0];
    const lines = try readTape(ctx, path);
    // Outputs must be known kinds before anything runs.
    var outputs: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        if (line.command == .output) try outputs.append(ctx.arena, line.command.output);
    }
    try outputs.appendSlice(ctx.arena, flags.output);
    if (outputs.items.len == 0) return ctx.usageError(
        "{s}: no Output, and no -o: nothing to write",
        .{path},
    );
    for (outputs.items) |out| if (output.kindOf(out) == null) {
        return ctx.usageError(
            "{s}: an output must end in .gif, .png, .txt, .ascii, .svg, .mp4, .webm, or /",
            .{out},
        );
    };
    // The font first: the terminal's size in cells follows from it.
    var config: session.Config = .{};
    for (lines) |line| if (line.command == .set) switch (line.command.set) {
        .font_family => |v| config.font_family = v,
        .font_size => |v| config.font_size = v,
        .line_height => |v| config.line_height = v,
        .letter_spacing => |v| config.letter_spacing = v,
        else => {},
    };
    var fonts = term.fonts.load(
        ctx.gpa,
        ctx.io,
        ctx.environ,
        config.font_family,
    ) catch |err| switch (err) {
        error.FontNotFound => return ctx.fail(
            "no font {s}{s}found: name an installed one with Set FontFamily",
            .{ config.font_family, if (config.font_family.len > 0) " " else "" },
        ),
        error.UnsupportedOutlines => return ctx.fail(
            "{s}: CFF (OpenType) fonts are not supported; use a TrueType one",
            .{config.font_family},
        ),
        else => |e| return e,
    };
    defer fonts.deinit();
    var painter: term.raster.Painter = .init(ctx.gpa, fonts.fonts(), .{
        .font_size = config.font_size,
        .line_height = config.line_height,
        .letter_spacing = config.letter_spacing,
    });
    defer painter.deinit();
    ctx.log(.info, "font {s} at {d}px, cells of {d}x{d} pixels", .{
        fonts.family, config.font_size, painter.cell_width, painter.cell_height,
    });

    // A step for the recording, then one per output.
    const steps = try ctx.arena.alloc(term.live.Steps.Step, outputs.items.len + 1);
    steps[0] = .{
        .name = try std.fmt.allocPrint(ctx.arena, "recording {s}", .{path}),
        .note = try std.fmt.allocPrint(ctx.arena, "in {s}", .{fonts.family}),
        .state = .running,
    };
    for (steps[1..], outputs.items) |*step, out| step.* = .{
        .name = try std.fmt.allocPrint(ctx.arena, "writing {s}", .{out}),
    };
    var list: term.live.Steps = .{ .items = steps };
    const items = [_]term.live.Item{.{ .steps = &list }};
    var display = ctx.live(&items);
    // Without concurrency the lines change only between steps.
    display.start(ctx.io) catch {};
    errdefer display.clear() catch {};

    var reporter: Reporter = .{ .arena = ctx.arena };
    var recording = session.run(
        ctx.gpa,
        ctx.io,
        ctx.environ,
        lines,
        config,
        .{ painter.cell_width, painter.cell_height },
        .{ .context = &reporter, .fail = Reporter.fail },
    ) catch |err| switch (err) {
        error.RecordFailed => {
            try endSteps(ctx, &display, steps, 0);
            const message = reporter.message orelse "the recording failed";
            if (reporter.line == 0) return ctx.fail("{s}: {s}", .{ path, message });
            return ctx.fail("{s}:{d}: {s}", .{ path, reporter.line, message });
        },
        else => |e| return e,
    };
    defer recording.deinit();
    for (flags.output) |extra| try recording.outputs.append(recording.arena.allocator(), extra);
    if (recording.frames.items.len == 0) {
        try endSteps(ctx, &display, steps, 0);
        return ctx.fail("{s}: nothing was recorded (all hidden?)", .{path});
    }
    var seconds: f64 = 0;
    for (recording.frames.items) |f| {
        seconds += @as(f64, @floatFromInt(f.duration.nanoseconds)) / 1e9;
    }
    display.lock();
    steps[0] = .{
        .name = try std.fmt.allocPrint(ctx.arena, "recorded {s}", .{path}),
        .note = try std.fmt.allocPrint(
            ctx.arena,
            "{d:.1}s, {d} frames",
            .{ seconds, recording.frames.items.len },
        ),
        .state = .done,
    };
    display.unlock();

    var drawing: output.Drawing = try .init(ctx.gpa, &painter, &recording, &fonts.regular);
    defer drawing.deinit();
    const timeline = try output.Timeline.init(ctx.arena, &recording);
    for (outputs.items, 1..) |out, i| {
        display.lock();
        steps[i].state = .running;
        display.unlock();
        const written = output.write(
            ctx.gpa,
            ctx.io,
            out,
            &recording,
            &timeline,
            &drawing,
            ctx.environ,
        );
        written catch |err| switch (err) {
            error.Unsupported => {
                try endSteps(ctx, &display, steps, i);
                return ctx.fail("a video output needs ffmpeg on PATH", .{});
            },
            error.WriteFailed => {
                try endSteps(ctx, &display, steps, i);
                return ctx.fail("{s}: cannot write it", .{out});
            },
            else => |e| return e,
        };
        display.lock();
        steps[i].name = try std.fmt.allocPrint(ctx.arena, "wrote {s}", .{out});
        steps[i].state = .done;
        display.unlock();
    }
    output.writeScreenshots(ctx.gpa, ctx.io, &recording, &drawing) catch |err| switch (err) {
        error.WriteFailed => {
            try endSteps(ctx, &display, steps, steps.len);
            return ctx.fail("cannot write the screenshots", .{});
        },
        else => |e| return e,
    };
    try display.finish(.now(ctx.io, .awake));
    ctx.log(.info, "{d}x{d} cells, {d} frames, {d} screenshots", .{
        recording.size.width,
        recording.size.height,
        recording.frames.items.len,
        recording.screenshots.items.len,
    });
    for (outputs.items) |out| {
        const stat = Io.Dir.cwd().statFile(ctx.io, out, .{}) catch continue;
        if (stat.kind == .file) ctx.log(.info, "{s}: {d} bytes", .{ out, stat.size });
    }
}

/// Marks step `failed` (when there is one) failed and leaves the progress lines, so that
/// what is printed next comes after them.
fn endSteps(
    ctx: *cli.Context,
    display: *term.live.Live,
    steps: []term.live.Steps.Step,
    failed: usize,
) !void {
    display.lock();
    if (failed < steps.len) steps[failed].state = .failed;
    display.unlock();
    try display.finish(.now(ctx.io, .awake));
}

fn newTape(ctx: *cli.Context) !void {
    const name = ctx.args[0];
    const file_name = if (std.mem.endsWith(u8, name, ".tape")) name else try std.fmt.allocPrint(
        ctx.arena,
        "{s}.tape",
        .{name},
    );
    const stem = std.fs.path.stem(file_name);
    const text = try std.fmt.allocPrint(ctx.arena,
        \\# {s}: a tape for `termancy record {s}`.
        \\#
        \\# Output: .gif, .png, .txt (golden text), .svg (animated), .mp4/.webm (ffmpeg), dir/
        \\Output {s}.gif
        \\
        \\# Settings (all optional):
        \\#   Set FontFamily "JetBrains Mono"   Set FontSize 22        Set LineHeight 1.2
        \\#   Set Width 1200   Set Height 600   (or Set Columns 80 and Set Rows 24)
        \\#   Set Theme "Catppuccin Mocha"      (termancy record themes lists them)
        \\#   Set Padding 40   Set Margin 20    Set MarginFill "#674EFF"   Set BorderRadius 8
        \\#   Set WindowBar Colorful             Set Shadow true          Set Title "demo"
        \\#   Set TypingSpeed 50ms               Set Framerate 50         Set PlaybackSpeed 1
        \\#   Set Shell bash                     Set CursorBlink false    Set LoopOffset 50%
        \\Set FontSize 22
        \\Set Width 1000
        \\Set Height 500
        \\Set Padding 40
        \\Set WindowBar Colorful
        \\Set BorderRadius 8
        \\
        \\# Commands: Type "text", Enter, Backspace 3, Ctrl+C, Up, Tab, Sleep 2s,
        \\# Wait /regex/, Hide, Show, Screenshot x.png, Copy "text", Paste, Env K "v"
        \\Type "echo 'Welcome to termancy!'"
        \\Sleep 500ms
        \\Enter
        \\Wait
        \\Sleep 2s
        \\
    , .{ file_name, file_name, stem });
    const exists = if (Io.Dir.cwd().access(ctx.io, file_name, .{})) true else |_| false;
    if (exists) return ctx.fail("{s}: already exists", .{file_name});
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = file_name, .data = text }) catch |err|
        return ctx.fail("{s}: {s}", .{ file_name, @errorName(err) });
    try ctx.out.print("created {s}\n", .{file_name});
}

const CaptureFlags = struct {
    shell: ?[]const u8 = null,
};
const capture_flags = cli.flags(CaptureFlags, field.Set(.{field.Spec(CaptureFlags){ .fields = .{
    .shell = .{ .help = "The shell to run (default: $SHELL, else bash)" },
} }}), .{});

fn captureTape(ctx: *cli.Context, flags: CaptureFlags) !void {
    const path = ctx.args[0];
    const shell = flags.shell orelse ctx.environ.get("SHELL") orelse session.Config.default_shell;
    try ctx.err.print("capturing to {s}: exit the shell to finish\n", .{path});
    try ctx.err.flush();
    const keys = capture_zig.capture(
        ctx.gpa,
        ctx.arena,
        ctx.io,
        ctx.environ,
        shell,
    ) catch |err| switch (err) {
        error.NotATerminal => return ctx.usageError("capture needs a terminal", .{}),
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("cannot run {s}: {s}", .{ shell, @errorName(err) }),
    };
    var tape_text: Io.Writer.Allocating = .init(ctx.arena);
    try tape_text.writer.print(
        "# Captured by termancy record capture.\nOutput {s}.gif\nSet Shell \"{s}\"\n\n",
        .{ std.fs.path.stem(path), std.fs.path.basename(shell) },
    );
    try capture_zig.writeTape(&tape_text.writer, keys);
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = tape_text.written() }) catch |err|
        return ctx.fail("{s}: {s}", .{ path, @errorName(err) });
    try ctx.err.print("wrote {s}\n", .{path});
}

fn validate(ctx: *cli.Context) !void {
    // Each tape's problem is reported, and the next tape checked.
    var failure: ?cli.Context.Failure = null;
    for (ctx.args) |path| {
        const text = Io.Dir.cwd().readFileAlloc(
            ctx.io,
            path,
            ctx.arena,
            .limited(4 << 20),
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            failure = ctx.fail("{s}: cannot read it", .{path});
            continue;
        };
        var diag: tape.Diagnostic = .{};
        _ = tape.parse(ctx.arena, text, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => {
                failure = ctx.fail("{s}:{d}: {s}", .{ path, diag.line, diag.message });
                continue;
            },
        };
    }
    if (failure) |err| return err;
}

fn listThemes(ctx: *cli.Context) !void {
    const Theme = struct { name: []const u8, background: []const u8, foreground: []const u8 };
    var list: std.ArrayList(Theme) = .empty;
    for (themes.themes) |t| try list.append(ctx.arena, .{
        .name = t.name,
        .background = try std.fmt.allocPrint(
            ctx.arena,
            "#{x:0>2}{x:0>2}{x:0>2}",
            .{ t.background.r, t.background.g, t.background.b },
        ),
        .foreground = try std.fmt.allocPrint(
            ctx.arena,
            "#{x:0>2}{x:0>2}{x:0>2}",
            .{ t.foreground.r, t.foreground.g, t.foreground.b },
        ),
    });
    if (ctx.output != .text) return ctx.render(list.items);
    for (themes.themes) |t| {
        // A swatch of the palette, then the name.
        for (t.palette[0..8]) |c| try ctx.paint(.{ .bg = .{ .rgb = c } }, "  ");
        try ctx.out.print(" {s}\n", .{t.name});
    }
}

const testing = std.testing;

test {
    std.testing.refAllDecls(tape);
    std.testing.refAllDecls(session);
    std.testing.refAllDecls(output);
    std.testing.refAllDecls(themes);
    std.testing.refAllDecls(capture_zig);
}

fn termancy(args: []const []const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{});
}

test "validate reports the line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "bad.tape", .data = "Output x.gif\nTipe \"x\"\n" },
    );
    const path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/bad.tape",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(path);
    const r = try termancy(&.{ "record", "validate", path });
    defer r.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "termancy: {s}:2: an unknown command\n",
        .{path},
    );
    defer testing.allocator.free(expected);
    try r.expect(1, "", expected);
}

test "a tape records golden text" {
    if (!term.Pty.supported) return error.SkipZigTest;
    const shell = if (@import("builtin").os.tag == .windows) "cmd" else "sh";
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const text_path = try std.fmt.allocPrint(testing.allocator, "{s}/out.txt", .{dir});
    defer testing.allocator.free(text_path);
    const source = try std.fmt.allocPrint(testing.allocator,
        \\Output {s}
        \\Set Shell {s}
        \\Set Columns 30
        \\Set Rows 4
        \\Set TypingSpeed 1ms
        \\Type "echo hi"
        \\Enter
        \\Wait+Screen /hi/
    , .{ text_path, shell });
    defer testing.allocator.free(source);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.tape", .data = source });
    const tape_path = try std.fmt.allocPrint(testing.allocator, "{s}/t.tape", .{dir});
    defer testing.allocator.free(tape_path);
    const r = try termancy(&.{ "record", "-v", tape_path });
    defer r.deinit();
    if (r.status != 0) {
        // A machine without fonts cannot record; that is reported, not a test failure.
        if (std.mem.indexOf(u8, r.err, "font") != null) return error.SkipZigTest;
        std.debug.print("{s}", .{r.err});
        return error.TestUnexpectedResult;
    }
    const golden = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        text_path,
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(golden);
    // cmd leaves a blank line before its next prompt.
    const after = if (@import("builtin").os.tag == .windows) "> echo hi\nhi\n\n>" else "> echo hi\nhi\n>";
    try testing.expect(std.mem.indexOf(u8, golden, after) != null);
    // Off a terminal, a line per step; -v adds the font and the sizes.
    try testing.expect(std.mem.indexOf(u8, r.err, "recorded ") != null);
    try testing.expect(std.mem.indexOf(u8, r.err, "wrote ") != null);
    try testing.expect(std.mem.indexOf(u8, r.err, "termancy: info: font ") != null);
}

test "validate reports every tape, and fails" {
    const r = try termancy(&.{ "record", "validate", "no-such-a.tape", "no-such-b.tape" });
    defer r.deinit();
    try r.expect(
        1,
        "",
        "termancy: no-such-a.tape: cannot read it\ntermancy: no-such-b.tape: cannot read it\n",
    );
}
