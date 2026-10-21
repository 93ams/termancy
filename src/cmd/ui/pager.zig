//! `termancy ui pager`: scroll through a file, some text, or standard input.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const tui = @import("tui");
const sys = @import("sys");
const term = @import("term.zig");
const styles = @import("styles.zig");
const Pager = @import("../tui/registry/pager.zig");

pub const Flags = struct {
    show_line_numbers: bool = true,
    soft_wrap: bool = true,
    timeout: cfg.Duration = .zero,
    show_help: bool = true,
    style: styles.Styles = .{},
    line_number_style: styles.Styles = .{},
    match_style: styles.Styles = .{},
    match_highlight_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field.Set(.{ field.Spec(Flags){ .fields = .{
    .show_line_numbers = .{ .help = "Number the lines" },
    .soft_wrap = .{ .help = "Wrap long lines; with --no-soft-wrap, left/right scroll sideways" },
    .timeout = .{ .help = term.help.timeout },
    .show_help = .{ .help = term.help.show_help },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_PAGER_", .fields = .{
    .style = styles.top,
    .line_number_style = styles.group("line-number"),
    .match_style = styles.group("match"),
    .match_highlight_style = styles.group("match-highlight"),
} });

pub const command = cli.command(.{
    .name = "pager",
    .summary = "Scroll through text",
    .description =
    \\Show text full screen in a rounded border, its lines numbered and wrapped to the
    \\terminal's width. The argument is a file to show, or else the text itself (as gum's
    \\`pager "$text"`); with no argument, standard input. Colors in the text stay (`git
    \\diff --color`); other escape sequences go. Tabs become four spaces, and an overstruck
    \\character (one, backspace, another, as `man` writes bold) the last one.
    \\
    \\Keys: j/k or up/down scroll a line, space/b or pgdown/pgup a screen, d/u half a
    \\screen, g/G or home/end jump to either end, and with --no-soft-wrap left/right
    \\scroll sideways. / searches for a regular expression, ignoring case unless it has a
    \\capital letter (one that is not a regular expression is searched for as typed):
    \\every match is highlighted, and n and N go to the next and previous one, round from
    \\either end. v opens the file in $VISUAL or $EDITOR and shows it again when the editor
    \\exits. q or esc quits with status 0, as there is nothing to cancel; Ctrl-C ends with
    \\130, --timeout with 124.
    \\
    \\The box is the top-level style flags: --border, --padding, --border-foreground,
    \\--foreground and the other colors and attributes for the text, and --width and
    \\--height for its size (padding included), at most the terminal's. --line-number.*,
    \\--match.*, and --match-highlight.* (the current match) style the rest. Every flag
    \\can come from a variable: TERMANCY_PAGER_SHOW_LINE_NUMBERS=false,
    \\TERMANCY_PAGER_BORDER=none.
    ,
    .flags = flags_flags,
    .args = .{ .max = 1, .usage = "[file|text]" },
    .examples =
    \\termancy ui pager README.md
    \\termancy cfg show | termancy ui pager --no-show-line-numbers
    \\termancy ui pager "$(git log)" --border none --padding 0
    \\man ls | termancy ui pager --no-soft-wrap --match.foreground 212
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const source = try read(ctx);
    var model: Viewer = .{
        .pager = try .init(ctx.gpa, try clean(ctx.arena, source.text)),
        .gpa = ctx.gpa,
        .ctx = ctx,
        .path = source.path,
        .box = boxStyle(flags, ctx.theme),
        .hints = hintsFor(flags),
    };
    defer model.pager.deinit();
    look(&model.pager, flags, ctx.theme, model.box);
    const options = term.timed(.{ .alt_screen = true }, flags.timeout);
    // q and esc both just close the pager, as gum's: there is no answer to cancel.
    if (try term.run(ctx, Viewer, &model, options)) return term.exitInterrupted(ctx);
}

/// The border around the pager: gum's, rounded in the accent and padded a column each
/// side, with the top-level style flags over it.
fn boxStyle(flags: Flags, theme: *const cli.Theme) tui.Style {
    const base: tui.Style = .{
        .border = .rounded,
        .border_fg = theme.accent.fg,
        .padding = .symmetric(0, 1),
    };
    return flags.style.over(base);
}

/// The pager's options and styles: the theme's, with the flags over them, all over the
/// box's colors.
fn look(pager: *Pager, flags: Flags, theme: *const cli.Theme, box: tui.Style) void {
    pager.styles.text = box;
    pager.line_numbers = flags.show_line_numbers;
    pager.soft_wrap = flags.soft_wrap;
    var match = theme.accent;
    match.bold = true;
    var current = match;
    current.reverse = true;
    pager.styles.match = flags.match_style.over(match);
    pager.styles.current_match = flags.match_highlight_style.over(current);
    pager.styles.line_number = flags.line_number_style.over(theme.note);
    pager.styles.status = theme.note;
}

fn hintsFor(flags: Flags) []const term.Hint {
    if (!flags.show_help) return &.{};
    return if (flags.soft_wrap) &wrapped_hints else &sideways_hints;
}

const navigate: term.Hint = .{ .keys = &.{ "up", "down" }, .action = .hint, .help = "navigate" };
const scroll: term.Hint = .{ .keys = &.{ "left", "right" }, .action = .hint, .help = "scroll" };
const quit: term.Hint = .{ .keys = &.{"q"}, .action = .hint, .help = "quit" };
const search: term.Hint = .{ .keys = &.{"/"}, .action = .hint, .help = "search" };
const next: term.Hint = .{ .keys = &.{"n"}, .action = .hint, .help = "next match" };
const previous: term.Hint = .{ .keys = &.{"N"}, .action = .hint, .help = "previous match" };
// n and N last, left out until there is a search, as gum's.
const wrapped_hints = [_]term.Hint{ navigate, quit, search, next, previous };
const sideways_hints = [_]term.Hint{ navigate, scroll, quit, search, next, previous };

/// The pager in its border with the help line under it, plus `v` to edit the file shown.
const Viewer = struct {
    pager: Pager,
    /// For laying the view out.
    gpa: std.mem.Allocator,
    ctx: *cli.Context,
    /// The file shown; null for text, which cannot be edited.
    path: ?[]const u8,
    /// Around the pager; its width and height, if set, are the most it takes.
    box: tui.Style,
    /// The help line; none when empty (`--no-show-help`).
    hints: []const term.Hint,
    /// The terminal's width, from the last resize.
    width: usize = 80,
    /// The box's width, padding included, from the last resize.
    box_width: usize = 78,

    pub fn update(viewer: *Viewer, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .resize => |size| {
                viewer.width = size.width;
                return viewer.pager.update(.{ .resize = viewer.inside(size) });
            },
            .key => |key| if (key.matches("v") and viewer.path != null and
                !viewer.pager.searching) return .handoff(0),
            else => {},
        }
        return viewer.pager.update(msg);
    }

    /// Columns of the border and margin, outside the box's width.
    fn edges(viewer: *const Viewer) usize {
        const box = viewer.box;
        const border: usize = if (box.border != null) 2 else 0;
        return box.margin.left + box.margin.right + border;
    }

    /// The size inside the box, which takes the terminal (or `--width` and `--height`
    /// of it) less the help line under it.
    fn inside(viewer: *Viewer, size: tui.Size) tui.Size {
        const box = viewer.box;
        const border: usize = if (box.border != null) 2 else 0;
        const help: usize = if (viewer.hints.len > 0) 2 else 0;
        const across = size.width -| viewer.edges();
        viewer.box_width = @min(box.width orelse across, across);
        const down = size.height -| (box.margin.top + box.margin.bottom + border + help);
        const tall = @min(box.height orelse down, down);
        const padding = box.padding;
        return .{
            .width = std.math.lossyCast(u16, viewer.box_width -| (padding.left + padding.right)),
            .height = std.math.lossyCast(u16, tall -| (padding.top + padding.bottom)),
        };
    }

    /// Runs the editor on the terminal the program lent out, then reads the file again.
    pub fn handoff(viewer: *Viewer, io: std.Io, _: u32) tui.Cmd {
        const ctx = viewer.ctx;
        const path = viewer.path.?;
        if (sys.process.edit(ctx.gpa, io, ctx.environ, path)) |_| {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, ctx.arena, .unlimited) catch |err|
                return viewer.say(@errorName(err));
            const shown = clean(ctx.arena, text) catch return viewer.say("out of memory");
            viewer.pager.setText(shown) catch return viewer.say("out of memory");
        } else |err| return viewer.say(@errorName(err));
        return .none;
    }

    fn say(viewer: *Viewer, message: []const u8) tui.Cmd {
        viewer.pager.message = message;
        return .none;
    }

    pub fn view(viewer: *const Viewer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var body: std.Io.Writer.Allocating = .init(viewer.gpa);
        defer body.deinit();
        try viewer.pager.view(&body.writer);
        // Rows cut to the box, so a long status line cannot wrap and push it taller.
        var rows: std.Io.Writer.Allocating = .init(viewer.gpa);
        defer rows.deinit();
        var lines = std.mem.splitScalar(u8, body.written(), '\n');
        var first = true;
        while (lines.next()) |line| : (first = false) {
            if (!first) try rows.writer.writeByte('\n');
            try tui.width.truncate(&rows.writer, line, viewer.pager.size.width, "…");
        }
        var box = viewer.box;
        box.width = viewer.box_width;
        box.height = null; // the pager fills it
        try box.render(w, rows.written());
        if (viewer.hints.len == 0) return;
        try w.writeAll("\n\n");
        const hints = viewer.hints;
        const shown = if (viewer.pager.searched()) hints else hints[0 .. hints.len - 2];
        const help: term.Hints = .{ .bindings = shown };
        try help.writeHelp(w, .{ .width = viewer.width });
    }
};

/// What to show, and the file it is from.
const Source = struct { text: []const u8, path: ?[]const u8 = null };

/// The file the argument names, or else the argument itself; with no argument (or an
/// empty one, as gum), standard input. Fails when there is no text.
fn read(ctx: *cli.Context) !Source {
    const argument = if (ctx.args.len > 0) ctx.args[0] else "";
    if (argument.len > 0) {
        if (std.Io.Dir.cwd().readFileAlloc(ctx.io, argument, ctx.arena, .unlimited)) |text| {
            return .{ .text = text, .path = argument };
        } else |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Not the name of a file: the text itself.
            error.FileNotFound, error.NameTooLong, error.BadPathName => .{ .text = argument },
            else => |e| ctx.fail("{s}: {s}", .{ argument, @errorName(e) }),
        };
    }
    const text = try term.readStdin(ctx) orelse "";
    if (text.len == 0) {
        return ctx.usageError("no text: give a file, the text, or standard input", .{});
    }
    return .{ .text = text };
}

/// `text` with each tab as four spaces and each overstruck character (one, backspace,
/// another, as `man` writes bold and underlines) as the last one, as gum shows it.
fn clean(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "\t\x08") == null) return text;
    var out: std.ArrayList(u8) = try .initCapacity(arena, text.len);
    for (text) |byte| switch (byte) {
        '\t' => try out.appendSlice(arena, "    "),
        0x08 => if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            // The whole UTF-8 sequence before it goes.
            var end = out.items.len - 1;
            while (end > 0 and out.items[end] & 0xc0 == 0x80) end -= 1;
            out.shrinkRetainingCapacity(end);
        } else try out.append(arena, byte),
        else => try out.append(arena, byte),
    };
    return out.items;
}

const testing = std.testing;

test clean {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("plain", try clean(a, "plain"));
    try testing.expectEqualStrings("a    b", try clean(a, "a\tb"));
    try testing.expectEqualStrings("bold é_x\n\x08", try clean(a, "b\x08bo\x08old é\x08é_x\n\x08"));
}

/// A viewer of `text` with `flags`, on a 24 by 7 terminal (or `width` wide).
fn startViewer(d: *tui.testing.Driver(Viewer), text: []const u8, flags: Flags) !void {
    try startSized(d, text, flags, 24);
}

fn startSized(d: *tui.testing.Driver(Viewer), text: []const u8, flags: Flags, width: u16) !void {
    var model: Viewer = .{
        .pager = try .init(testing.allocator, text),
        .gpa = testing.allocator,
        .ctx = undefined,
        .path = null,
        .box = boxStyle(flags, &cli.Theme.default),
        .hints = hintsFor(flags),
    };
    look(&model.pager, flags, &cli.Theme.default, model.box);
    d.* = try .init(testing.allocator, model, .{
        .program = .{ .size = .{ .width = width, .height = 7 }, .alt_screen = true },
    });
}

fn stopViewer(d: *tui.testing.Driver(Viewer)) void {
    d.model().pager.deinit();
    d.deinit();
}

test "in a border, lines numbered, the help line under it, filling the terminal" {
    var d: tui.testing.Driver(Viewer) = undefined;
    try startViewer(&d, "one two three four\nfive", .{});
    defer stopViewer(&d);
    try d.expectFrame("╭──────────────────────╮\n" ++
        "│    1 │ one two three │\n" ++
        "│      │ four          │\n" ++
        "│ 1-2 of 3 (66%)       │\n" ++
        "╰──────────────────────╯\n" ++
        "\n" ++
        "↑/↓ navigate • q quit …");
    // The border in the accent, the line numbers in the theme's note style.
    try testing.expect(std.mem.indexOf(u8, d.frameBytes(), "\x1b[35m╭") != null);
    try testing.expect(std.mem.indexOf(u8, d.frameBytes(), "\x1b[2m   1 │ \x1b[0m") != null);
    try d.press("esc");
    try testing.expect(d.done());
}

test "no border, numbers, wrapping, or help" {
    var d: tui.testing.Driver(Viewer) = undefined;
    try startViewer(&d, "one two three four five six seven\nx", .{
        .show_line_numbers = false,
        .soft_wrap = false,
        .show_help = false,
        .style = .{ .border = .none, .padding = .{} },
    });
    defer stopViewer(&d);
    // Rows are padded to the width all the same.
    const blank: [24]u8 = @splat(' ');
    const tail = "\n" ++ blank ++ "\n" ++ blank ++ "\n" ++ blank ++ "\n" ++ blank ++
        "\n1-2 of 2 (100%)" ++ blank[15..];
    try d.expectFrame("one two three four five \nx" ++ blank[1..] ++ tail);
    try d.press("right");
    try d.expectFrame("o three four five six se\n" ++ blank ++ tail);
}

test "search highlights in the match styles, and n and N show up in the help" {
    var d: tui.testing.Driver(Viewer) = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try startSized(&d, "ab ab", .{
        .show_line_numbers = false,
        .match_style = .{ .underline = true },
    }, 80);
    defer stopViewer(&d);
    try testing.expect(!std.mem.endsWith(u8, try d.frameText(arena.allocator()), "match"));
    try d.press("/");
    try d.typeText("ab");
    try d.press("enter");
    try testing.expect(std.mem.indexOf(u8, d.frameBytes(), "\x1b[1;7;35mab\x1b[0m \x1b[1;4;35mab") != null);
    try d.expectFrameContains("/ search • n next match • N previous match");
}

test "--width and --height size the box, at most the terminal; its colors survive" {
    var d: tui.testing.Driver(Viewer) = undefined;
    try startViewer(&d, "one\ntwo\nthree", .{
        .show_line_numbers = false,
        .show_help = false,
        .style = .{ .width = 12, .height = 9, .foreground = .blue },
    });
    defer stopViewer(&d);
    // Twelve columns with the padding; nine rows would not fit in seven.
    try d.expectFrame("╭────────────╮\n" ++
        "│ one        │\n" ++
        "│ two        │\n" ++
        "│ three      │\n" ++
        "│            │\n" ++
        "│ 1-3 of 3 … │\n" ++
        "╰────────────╯");
    // The status line blue and dim, then blue again.
    try testing.expect(std.mem.indexOf(u8, d.frameBytes(), "\x1b[34m \x1b[2m1-3 of 3 …\x1b[0;34m") != null);
}
