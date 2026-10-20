//! `termancy freeze`: images of code and terminal output, as freeze makes them. Code is
//! highlighted (`term.highlight`), a command's output is taken from a pseudo-terminal; both
//! are drawn by the terminal emulator (`term.vt`) into a PNG in the machine's fonts
//! (`term.raster`), in a window with a bar, rounded corners, and a shadow, or into an SVG.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const sys = @import("sys");
const term = @import("term");
const explain = @import("explain.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Screen = term.vt.Screen;
const Rgb = term.Color.Rgb;

const Flags = struct {
    output: []const u8 = "freeze.png",
    language: ?[]const u8 = null,
    theme: []const u8 = "charm",
    execute: ?[]const u8 = null,
    window: bool = false,
    title: ?[]const u8 = null,
    shadow: bool = false,
    radius: u16 = 8,
    border: u16 = 0,
    border_color: []const u8 = "#515151",
    padding: u16 = 20,
    margin: u16 = 0,
    background: ?[]const u8 = null,
    font_family: []const u8 = "",
    font_size: u16 = 22,
    line_numbers: bool = false,
    lines: ?[]const u8 = null,
    width: u16 = 0,
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .output = .{ .help = "The image to write: .png or .svg" },
    .language = .{ .help = "The code's language (default: from the file name)" },
    .theme = .{ .help = "Colors: charm, dracula, monokai, tokyo-night, github, ansi" },
    .execute = .{ .help = "Run this command and draw what it writes" },
    .window = .{ .help = "Draw a window bar with its three buttons" },
    .title = .{ .help = "The window bar's title (default: the file's name)" },
    .shadow = .{ .help = "Draw a drop shadow under the window" },
    .radius = .{ .help = "The window's corner radius, in pixels" },
    .border = .{ .help = "The window border's width, in pixels" },
    .border_color = .{ .help = "The window border's color" },
    .padding = .{ .help = "Pixels between the text and the window's edge" },
    .margin = .{ .help = "Pixels around the window (transparent)" },
    .background = .{ .help = "The window's color (default: the theme's)" },
    .font_family = .{ .help = "An installed monospace font (default: a common one)" },
    .font_size = .{ .help = "The font's size, in pixels", .checks = &.{.min(4)} },
    .line_numbers = .{ .help = "Number the lines" },
    .lines = .{ .help = "Only these lines, first and last (as 10,20), counting from 1" },
    .width = .{ .help = "Wrap lines at this many columns (0: never)" },
} }}), .{ .fields = .{
    .output = .{ .short = 'o' },
    .language = .{ .short = 'l' },
    .theme = .{ .short = 't' },
    .execute = .{ .short = 'x' },
    .radius = .{ .short = 'r' },
    .padding = .{ .short = 'p' },
    .margin = .{ .short = 'm' },
    .background = .{ .short = 'b' },
    .line_numbers = .{ .short = 'n' },
    .width = .{ .short = 'w' },
} });

pub const command = cli.command(.{
    .name = "freeze",
    .summary = "Make images of code and terminal output (freeze)",
    .description =
    \\Draw a file (or standard input) as highlighted code, or the output of a command
    \\(-x, run on a pseudo-terminal so its colors show), into a PNG, in a window with an
    \\optional bar, rounded corners, a border and a drop shadow; or into an SVG. The
    \\font is the machine's: --font-family names one, else a common monospace font.
    ,
    .args = .{ .max = 1, .usage = "[file]" },
    .flags = flags_flags,
    .examples =
    \\termancy freeze main.zig --window --shadow -o main.png
    \\termancy freeze main.zig -n --lines 10,30 -t dracula
    \\termancy freeze -x "ls --color=always" -o ls.svg
    \\cat query.sql | termancy freeze -l sql
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const svg = std.ascii.endsWithIgnoreCase(flags.output, ".svg");
    if (!svg and !std.ascii.endsWithIgnoreCase(flags.output, ".png"))
        return ctx.usageError("{s}: the output must end in .png or .svg", .{flags.output});
    const theme = term.highlight.Theme.named(flags.theme) orelse
        return ctx.usageError("{s}: no such theme", .{flags.theme});
    const range = if (flags.lines) |text| parseRange(text) orelse
        return ctx.usageError(
            "--lines {s}: give the first and last line, as 10,20",
            .{text},
        ) else null;
    const background = if (flags.background) |text| parseRgb(text) orelse
        return ctx.usageError(
            "--background {s}: not a color",
            .{text},
        ) else theme.background.toRgb(default_background);
    const border_color = parseRgb(flags.border_color) orelse
        return ctx.usageError("--border-color {s}: not a color", .{flags.border_color});

    // What to draw, as text with escape sequences.
    var name: []const u8 = "";
    const ansi_text = if (flags.execute) |cmd| blk: {
        name = cmd;
        const columns = if (flags.width > 0) flags.width else 80;
        break :blk try explain.capture(
            ctx,
            &.{ "sh", "-c", cmd },
            .{ .width = columns, .height = 24 },
        );
    } else blk: {
        const source = if (ctx.args.len > 0) src: {
            name = std.fs.path.basename(ctx.args[0]);
            break :src Io.Dir.cwd().readFileAlloc(
                ctx.io,
                ctx.args[0],
                ctx.arena,
                .unlimited,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return ctx.fail("{s}: {s}", .{ ctx.args[0], @errorName(err) });
            };
        } else try explain.readStdin(ctx) orelse
            return ctx.usageError(
                "nothing to freeze: give a file, standard input, or -x command",
                .{},
            );
        const lang = if (flags.language) |l|
            term.highlight.language(l) orelse return ctx.usageError("{s}: no such language", .{l})
        else
            term.highlight.languageOfPath(name);
        break :blk try highlight(ctx.arena, source, lang, theme);
    };

    var screen = try layout(ctx.gpa, ansi_text, .{
        .wrap = flags.width,
        .numbers = flags.line_numbers,
        .range = range,
        .foreground = theme.text.fg.toRgb(default_foreground),
        .background = background,
    });
    defer screen.deinit();

    // Drawing a PNG takes a while.
    var spinner: term.live.Spinner = .{
        .title = try std.fmt.allocPrint(ctx.arena, "drawing {s}", .{flags.output}),
    };
    const items = [_]term.live.Item{.{ .spinner = &spinner }};
    var display = ctx.live(&items);
    display.start(ctx.io) catch {};
    // Before any failure is printed, as the lines would mix.
    errdefer display.clear() catch {};
    // Drawn in memory, then written whole: a failure leaves the file there as it was.
    var drawn: Io.Writer.Allocating = .init(ctx.gpa);
    defer drawn.deinit();
    const w = &drawn.writer;
    if (svg) {
        try screen.writeSvg(w, .{ .font_size = flags.font_size, .padding = flags.padding });
    } else {
        var fonts = term.fonts.load(
            ctx.gpa,
            ctx.io,
            ctx.environ,
            flags.font_family,
        ) catch |err| switch (err) {
            error.FontNotFound => {
                try display.clear();
                return ctx.fail(
                    "no font {s}{s}found: name an installed one with --font-family",
                    .{ flags.font_family, if (flags.font_family.len > 0) " " else "" },
                );
            },
            error.UnsupportedOutlines => {
                try display.clear();
                return ctx.fail(
                    "{s}: CFF (OpenType) fonts are not supported; use a TrueType one",
                    .{flags.font_family},
                );
            },
            else => |e| return e,
        };
        defer fonts.deinit();
        var painter: term.raster.Painter = .init(ctx.gpa, fonts.fonts(), .{
            .font_size = @floatFromInt(flags.font_size),
            .cursor = false,
            .trim = true,
        });
        defer painter.deinit();
        var content = try painter.paint(&screen);
        defer content.deinit(ctx.gpa);
        const fg = theme.text.fg.toRgb(default_foreground);
        var img = try term.raster.decorate(ctx.gpa, &content, .{
            .padding = flags.padding,
            .window_bar = if (flags.window) .colorful else .none,
            .window_color = rgba(background),
            .title = if (flags.window) flags.title orelse name else "",
            .title_font = &fonts.regular,
            .title_color = .{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 160 },
            .border_radius = flags.radius,
            .border_width = flags.border,
            .border_color = rgba(border_color),
            .margin = flags.margin,
            .shadow_blur = if (flags.shadow) 24 else 0,
            .shadow_y = if (flags.shadow) 10 else 0,
        });
        defer img.deinit(ctx.gpa);
        try term.image.writePng(ctx.gpa, w, &img);
    }
    sys.files.writeAtomic(ctx.io, Io.Dir.cwd(), flags.output, drawn.written(), .{}) catch |err| {
        try display.clear();
        return ctx.fail("{s}: cannot write it: {s}", .{ flags.output, @errorName(err) });
    };
    const wrote = try std.fmt.allocPrint(ctx.arena, "wrote {s}", .{flags.output});
    display.lock();
    spinner.finish(.success, wrote);
    display.unlock();
    try display.finish(.now(ctx.io, .awake));
}

const default_background: Rgb = .{ .r = 0x17, .g = 0x17, .b = 0x17 };
const default_foreground: Rgb = .{ .r = 0xdd, .g = 0xdd, .b = 0xdd };

fn rgba(c: Rgb) term.image.Rgba {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

fn parseRgb(text: []const u8) ?Rgb {
    const color = term.Color.parse(text) catch return null;
    return switch (color) {
        .rgb => |rgb| rgb,
        else => color.toRgb(default_background),
    };
}

/// `first,last` (or `first-last`), counting from 1.
fn parseRange(text: []const u8) ?[2]usize {
    const sep = std.mem.indexOfAny(u8, text, ",-") orelse return null;
    const first = std.fmt.parseInt(
        usize,
        std.mem.trim(u8, text[0..sep], " "),
        10,
    ) catch return null;
    const last = std.fmt.parseInt(
        usize,
        std.mem.trim(u8, text[sep + 1 ..], " "),
        10,
    ) catch return null;
    if (first == 0 or last < first) return null;
    return .{ first, last };
}

/// `source` highlighted, tabs as four spaces, without a final newline.
fn highlight(
    arena: Allocator,
    source: []const u8,
    lang: ?*const term.highlight.Language,
    theme: term.highlight.Theme,
) ![]const u8 {
    var spaced: std.ArrayList(u8) = .empty;
    for (std.mem.trimEnd(u8, source, "\r\n")) |c| switch (c) {
        '\t' => try spaced.appendSlice(arena, "    "),
        '\r' => {},
        else => try spaced.append(arena, c),
    };
    var out: Io.Writer.Allocating = .init(arena);
    if (lang) |l|
        try term.highlight.write(&out.writer, spaced.items, l, theme)
    else
        try theme.styleOf(.text).paint(&out.writer, spaced.items);
    return out.written();
}

pub const Layout = struct {
    /// Wrap at this many columns; 0 for never.
    wrap: usize = 0,
    numbers: bool = false,
    /// The source lines to keep, first and last, counting from 1.
    range: ?[2]usize = null,
    foreground: Rgb = default_foreground,
    background: Rgb = default_background,
};

/// The screen `text` draws: run through the emulator, cut to the lines wanted, and with
/// their numbers in a gutter (once per source line, not on the rows it wraps onto).
pub fn layout(gpa: Allocator, text: []const u8, options: Layout) !Screen {
    var lines: usize = 1;
    var widest: usize = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const w = term.width.of(line);
        widest = @max(widest, w);
        if (options.wrap > 0) lines += w / options.wrap;
        lines += 1;
    }
    // A screen side is a u16: longer lines wrap at its limit.
    const max_side = std.math.maxInt(u16);
    const columns: usize = @min(if (options.wrap > 0) options.wrap else widest, max_side);
    // Bounded by the emulator's largest grid.
    const rows: usize = @min(lines, Screen.max_cells / columns, max_side);
    var source: Screen = try .init(gpa, .{ .width = @intCast(columns), .height = @intCast(rows) });
    defer source.deinit();
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| : (start = nl + 1) {
        source.write(text[start..nl]);
        source.write("\r\n");
    }
    source.write(text[start..]);

    // The rows that show something, and which source line each starts.
    var used: usize = 0;
    for (0..rows) |r| if (!source.rowIsBlank(r)) {
        used = r + 1;
    };
    const wrapped = source.grid().wrapped;
    var first_row: usize = 0;
    var last_row: usize = used;
    var number: usize = 1;
    if (options.range) |range| {
        first_row = used;
        last_row = used;
        for (0..used) |r| {
            if (number == range[0] and first_row == used) first_row = r;
            if (!wrapped[r]) {
                if (number == range[1]) {
                    last_row = r + 1;
                    break;
                }
                number += 1;
            }
        }
        number = range[0];
    }
    if (first_row >= last_row) {
        first_row = 0;
        last_row = 1;
    }
    var last_number = number;
    for (first_row..last_row) |r| if (!wrapped[r] and r + 1 < last_row) {
        last_number += 1;
    };
    var digits: usize = 1;
    var n = last_number;
    while (n >= 10) : (n /= 10) digits += 1;
    const gutter: usize = if (options.numbers) digits + 2 else 0;

    var width: usize = 1;
    for (first_row..last_row) |r| {
        var end = columns;
        while (end > 0 and source.cell(r, end - 1).isBlank()) end -= 1;
        width = @max(width, end);
    }
    width = @min(width, max_side - gutter);
    var screen: Screen = try .init(gpa, .{
        .width = @intCast(gutter + width),
        .height = @intCast(last_row - first_row),
    });
    errdefer screen.deinit();
    screen.foreground = options.foreground;
    screen.background = options.background;
    screen.cursor_visible = false;
    var continuing = false;
    for (first_row..last_row, 0..) |r, row| {
        if (options.numbers and !continuing) {
            var buffer: [48]u8 = undefined;
            const shown = std.fmt.bufPrint(&buffer, "\x1b[{d};1H\x1b[2m{d: >[2]}\x1b[0m", .{
                row + 1, number, digits,
            }) catch unreachable;
            screen.write(shown);
            number += 1;
        }
        continuing = wrapped[r];
        for (0..width) |c| screen.cell(row, gutter + c).* = source.cell(r, c).*;
    }
    return screen;
}

const testing = std.testing;

fn rowText(screen: *Screen, row: usize) ![]u8 {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    try screen.writeRow(&out.writer, row);
    return out.toOwnedSlice();
}

test "layout: numbers, a range, and wrapped lines numbered once" {
    var screen = try layout(testing.allocator, "one\ntwo\n\x1b[31mthree three\x1b[0m\nfour", .{
        .wrap = 6,
        .numbers = true,
        .range = .{ 2, 3 },
    });
    defer screen.deinit();
    try testing.expectEqual(3, screen.size.height);
    const expected = [_][]const u8{ "2  two", "3  three", "   three" };
    for (expected, 0..) |e, r| {
        const got = try rowText(&screen, r);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(e, got);
    }
    try testing.expectEqual(term.Color.red, screen.cell(1, 3).pen.fg);
}

test "parse a range" {
    try testing.expectEqual([2]usize{ 10, 20 }, parseRange("10,20").?);
    try testing.expectEqual([2]usize{ 3, 3 }, parseRange("3-3").?);
    try testing.expectEqual(null, parseRange("0,2"));
    try testing.expectEqual(null, parseRange("5,2"));
}

test "freeze says what it wrote, and nothing under -q" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const source = try std.fs.path.join(testing.allocator, &.{ dir, "a.zig" });
    defer testing.allocator.free(source);
    const svg = try std.fs.path.join(testing.allocator, &.{ dir, "a.svg" });
    defer testing.allocator.free(svg);
    const app: cli.App = .{ .root = &@import("../main.zig").root, .completion_command = false };
    const loud = try cli.testing.run(app, &.{ "freeze", source, "-o", svg }, .{});
    defer loud.deinit();
    const said = try std.fmt.allocPrint(testing.allocator, "✓ wrote {s}\n", .{svg});
    defer testing.allocator.free(said);
    try testing.expectEqual(0, loud.status);
    // A slow machine also shows the spinner's first line.
    try testing.expect(std.mem.endsWith(u8, loud.err, said));
    const quiet = try cli.testing.run(app, &.{ "freeze", "-q", source, "-o", svg }, .{});
    defer quiet.deinit();
    try quiet.expect(0, "", "");
}

test "layout: a line wider than a screen can be wraps instead of crashing" {
    const long = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(long);
    @memset(long, 'x');
    var screen = try layout(testing.allocator, long, .{ .numbers = true });
    defer screen.deinit();
    try testing.expect(screen.size.height >= 2);
}

test "a failed freeze leaves the output as it was" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.png", .data = "old" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const source = try std.fs.path.join(testing.allocator, &.{ dir, "a.zig" });
    defer testing.allocator.free(source);
    const png = try std.fs.path.join(testing.allocator, &.{ dir, "a.png" });
    defer testing.allocator.free(png);
    const app: cli.App = .{ .root = &@import("../main.zig").root, .completion_command = false };
    const args = [_][]const u8{ "freeze", "-q", source, "-o", png, "--font-family", "No Such Font" };
    const failed = try cli.testing.run(app, &args, .{});
    defer failed.deinit();
    try testing.expectEqual(1, failed.status);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("old", try tmp.dir.readFile(testing.io, "a.png", &buffer));
}
