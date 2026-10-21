//! `termancy ui input` and `termancy ui write`: read a line, or several, from the user, as
//! gum's `input` and `write`.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const sys = @import("sys");
const tui = @import("tui");
const term = @import("term.zig");
const plain = @import("plain.zig");
const styles = @import("styles.zig");
const Input = @import("../tui/registry/input.zig");
const Textarea = @import("../tui/registry/textarea.zig");
const Io = std.Io;

/// How the text cursor shows (`--cursor.mode`): the terminal's own, blinking or steady, or
/// none at all.
pub const CursorMode = enum { blink, hide, static };

/// The terminal's cursor at `x`, `y` in `mode`; null when hidden.
fn cursorAt(mode: CursorMode, x: usize, y: usize) ?tui.Cursor {
    if (mode == .hide) return null;
    return .{ .x = x, .y = y, .shape = .block, .blink = mode == .blink };
}

/// The style of the character under the cursor: none when the cursor is hidden.
fn cursorStyle(mode: CursorMode, flags: styles.Styles, theme: *const cli.Theme) tui.Style {
    return if (mode == .hide) .{} else flags.over(theme.accent);
}

/// `--value`, or else standard input (when it is not a terminal) without escapes (with
/// `strip_ansi`) and the white space around it, as gum takes it.
fn startingValue(ctx: *cli.Context, value: []const u8, strip_ansi: bool) ![]const u8 {
    if (value.len > 0) return value;
    var text = try term.readStdin(ctx) orelse return "";
    if (strip_ansi) text = try term.stripAnsi(ctx.arena, text);
    return std.mem.trim(u8, text, " \t\r\n");
}

/// `inner` with `--header` above it, the help line (unless `--no-show-help`), and
/// `--padding`.
fn framed(
    inner: anytype,
    gpa: std.mem.Allocator,
    header: []const u8,
    show_help: bool,
    padding: styles.Spacing,
    hints: []const term.Hint,
) term.Framed(@TypeOf(inner)) {
    return .{
        .inner = inner,
        .gpa = gpa,
        .header = header,
        .padding = padding.sides,
        .hints = if (show_help) hints else &.{},
    };
}

pub const InputFlags = struct {
    placeholder: []const u8 = "Type something...",
    prompt: []const u8 = "> ",
    cursor_mode: CursorMode = .blink,
    value: []const u8 = "",
    char_limit: usize = 400,
    width: usize = 0,
    password: bool = false,
    show_help: bool = true,
    header: []const u8 = "",
    timeout: cfg.Duration = .zero,
    strip_ansi: bool = true,
    padding: styles.Spacing = .{},
    prompt_style: styles.Styles = .{},
    placeholder_style: styles.Styles = .{},
    cursor_style: styles.Styles = .{},
    header_style: styles.Styles = .{},
};
const input_flags = cli.flags(InputFlags, field.Set(.{ field.Spec(InputFlags){ .fields = .{
    .placeholder = .{ .help = "Shown while the input is empty" },
    .prompt = .{ .help = "Written before the input" },
    .cursor_mode = .{ .help = "The cursor: blink, static, or hide" },
    .value = .{ .help = "The text to start with; else standard input's, when piped" },
    .char_limit = .{ .help = "The most characters; 0 for no limit" },
    .width = .{ .help = "Columns for the text, which scrolls past them; 0 for the terminal's" },
    .password = .{ .help = "Mask the characters typed" },
    .show_help = .{ .help = term.help.show_help },
    .header = .{ .help = "Text above the input" },
    .timeout = .{ .help = term.help.timeout },
    .strip_ansi = .{ .help = term.help.strip_ansi },
    .padding = .{ .help = term.help.padding },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_INPUT_", .fields = .{
    .cursor_mode = .{ .name = "cursor.mode" },
    .prompt_style = styles.group("prompt"),
    .placeholder_style = styles.group("placeholder"),
    .cursor_style = styles.group("cursor"),
    .header_style = styles.group("header"),
} });

pub const input = cli.command(.{
    .name = "input",
    .summary = "Read a line of text",
    .description =
    \\Read one line and print it. It starts as --value, or else as what standard input
    \\holds when it is piped (without escapes, with --strip-ansi, and without the white
    \\space around it). Text longer than --width scrolls sideways.
    \\
    \\Keys: the usual line editing (left/right, home/end, backspace, ctrl+w, ctrl+u,
    \\ctrl+k, ctrl+z to undo), enter submits, esc cancels (status 1), Ctrl-C interrupts
    \\(status 130). --timeout ends with status 124.
    \\
    \\Style a part with --prompt.*, --placeholder.*, --cursor.*, and --header.*. Every
    \\flag can also come from a variable: TERMANCY_INPUT_PLACEHOLDER, TERMANCY_INPUT_WIDTH.
    ,
    .flags = input_flags,
    .examples =
    \\name=$(termancy ui input --placeholder "Your name")
    \\token=$(termancy ui input --password --header "API token")
    \\git branch --show-current | termancy ui input --header Branch --cursor.mode static
    ,
    .run = runInput,
});

fn runInput(ctx: *cli.Context, flags: InputFlags) !void {
    const value = try startingValue(ctx, flags.value, flags.strip_ansi);
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const label = if (flags.header.len > 0)
            flags.header
        else
            std.mem.trimEnd(u8, flags.prompt, " >");
        const text = try session.input(
            if (label.len > 0) label else "Text",
            value,
            flags.password,
        ) orelse return error.CommandFailed;
        try ctx.out.print("{s}\n", .{text});
        return;
    }
    const header = try styles.render(
        ctx.arena,
        flags.header_style.over(ctx.theme.note),
        flags.header,
    );
    var model = framed(
        try buildLine(ctx.gpa, flags, value, ctx.theme),
        ctx.gpa,
        header,
        flags.show_help,
        flags.padding,
        &input_hints,
    );
    defer model.deinit();
    const options = term.timed(term.inline_options, flags.timeout);
    if (try term.run(ctx, @TypeOf(model), &model, options)) return term.exitInterrupted(ctx);
    if (model.inner.input.status != .submitted) return error.CommandFailed;
    try ctx.out.print("{s}\n", .{model.inner.input.value()});
}

const input_hints = [_]term.Hint{.{ .keys = &.{"enter"}, .action = .hint, .help = "submit" }};

/// The input line: as wide as `--width` says, or as the terminal.
pub const Line = struct {
    input: Input,
    /// Fill the terminal's width (`--width 0`).
    fill: bool,
    cursor_mode: CursorMode,

    pub fn update(line: *Line, msg: tui.Msg) tui.Cmd {
        if (msg == .resize and line.fill) {
            line.input.width = msg.resize.width;
            line.input.scroll();
        }
        return line.input.update(msg);
    }

    pub fn view(line: *const Line, w: *Io.Writer) Io.Writer.Error!void {
        try line.input.view(w);
    }

    pub fn cursor(line: *const Line) ?tui.Cursor {
        return cursorAt(line.cursor_mode, line.input.cursorColumn(), 0);
    }

    pub fn deinit(line: *Line) void {
        line.input.deinit();
    }
};

/// The `input` model from its flags and starting value.
pub fn buildLine(
    gpa: std.mem.Allocator,
    flags: InputFlags,
    value: []const u8,
    theme: *const cli.Theme,
) std.mem.Allocator.Error!Line {
    var line: Line = .{
        .input = .{
            .gpa = gpa,
            .prompt = flags.prompt,
            .placeholder = flags.placeholder,
            .password = flags.password,
            .char_limit = if (flags.char_limit == 0) null else flags.char_limit,
            // gum's width is the text's; the cursor takes a column after it.
            .width = if (flags.width == 0) null else tui.width.of(flags.prompt) + flags.width + 1,
            .styles = .{
                .prompt = flags.prompt_style.over(.{}),
                .placeholder = flags.placeholder_style.over(theme.note),
                .cursor = cursorStyle(flags.cursor_mode, flags.cursor_style, theme),
            },
        },
        .fill = flags.width == 0,
        .cursor_mode = flags.cursor_mode,
    };
    errdefer line.deinit();
    try line.input.setValue(value);
    return line;
}

pub const WriteFlags = struct {
    width: usize = 0,
    height: usize = 5,
    header: []const u8 = "",
    placeholder: []const u8 = "Write something...",
    prompt: []const u8 = "┃ ",
    show_cursor_line: bool = false,
    show_line_numbers: bool = false,
    value: []const u8 = "",
    char_limit: usize = 0,
    max_lines: usize = 0,
    show_help: bool = true,
    cursor_mode: CursorMode = .blink,
    timeout: cfg.Duration = .zero,
    strip_ansi: bool = true,
    padding: styles.Spacing = .{},
    base_style: styles.Styles = .{},
    cursor_line_number_style: styles.Styles = .{},
    cursor_line_style: styles.Styles = .{},
    cursor_style: styles.Styles = .{},
    end_of_buffer_style: styles.Styles = .{},
    line_number_style: styles.Styles = .{},
    header_style: styles.Styles = .{},
    placeholder_style: styles.Styles = .{},
    prompt_style: styles.Styles = .{},
};
const write_flags = cli.flags(WriteFlags, field.Set(.{ field.Spec(WriteFlags){ .fields = .{
    .width = .{ .help = "Columns, prompt and line numbers included; 0 for the terminal's" },
    .height = .{ .help = "Rows shown at once; 0 for all the text" },
    .header = .{ .help = "Text above the editor" },
    .placeholder = .{ .help = "Shown while the text is empty" },
    .prompt = .{ .help = "Written before each row" },
    .show_cursor_line = .{ .help = "Highlight the line the cursor is on" },
    .show_line_numbers = .{ .help = "Number the lines" },
    .value = .{ .help = "The text to start with; else standard input's, when piped" },
    .char_limit = .{ .help = "The most characters; 0 for no limit" },
    .max_lines = .{ .help = "The most lines; 0 for no limit" },
    .show_help = .{ .help = term.help.show_help },
    .cursor_mode = .{ .help = "The cursor: blink, static, or hide" },
    .timeout = .{ .help = term.help.timeout },
    .strip_ansi = .{ .help = term.help.strip_ansi },
    .padding = .{ .help = term.help.padding },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_WRITE_", .fields = .{
    .cursor_mode = .{ .name = "cursor.mode" },
    .base_style = styles.group("base"),
    .cursor_line_number_style = styles.group("cursor-line-number"),
    .cursor_line_style = styles.group("cursor-line"),
    .cursor_style = styles.group("cursor"),
    .end_of_buffer_style = styles.group("end-of-buffer"),
    .line_number_style = styles.group("line-number"),
    .header_style = styles.group("header"),
    .placeholder_style = styles.group("placeholder"),
    .prompt_style = styles.group("prompt"),
} });

pub const write = cli.command(.{
    .name = "write",
    .summary = "Read several lines of text",
    .description =
    \\Read text of any number of lines and print it. It starts as --value, or else as what
    \\standard input holds when it is piped. Lines longer than --width wrap; the text
    \\scrolls past --height rows.
    \\
    \\Keys: enter submits (so does Ctrl-D); ctrl+j or alt+enter starts a new line (ctrl+j
    \\only where the terminal tells it from enter, with the kitty keyboard protocol);
    \\ctrl+e opens the text in $VISUAL or $EDITOR and takes it back when the editor exits;
    \\the usual editing keys, and ctrl+z to undo; esc cancels (status 1); Ctrl-C interrupts
    \\(status 130). --timeout ends with status 124.
    \\
    \\Style a part with --base.*, --prompt.*, --cursor.*, --cursor-line.*,
    \\--line-number.*, --cursor-line-number.*, --end-of-buffer.*, --placeholder.*, and
    \\--header.*. Every flag can also come from a variable: TERMANCY_WRITE_HEIGHT.
    ,
    .flags = write_flags,
    .examples =
    \\git commit -m "$(termancy ui write --header "Commit message")"
    \\termancy ui write --show-line-numbers --max-lines 10 < notes.txt > notes.new
    ,
    .run = runWrite,
});

fn runWrite(ctx: *cli.Context, flags: WriteFlags) !void {
    const value = try startingValue(ctx, flags.value, flags.strip_ansi);
    const header = try styles.render(
        ctx.arena,
        flags.header_style.over(ctx.theme.note),
        flags.header,
    );
    var model = framed(
        try buildArea(ctx.gpa, ctx.environ, flags, value, ctx.theme),
        ctx.gpa,
        header,
        flags.show_help,
        flags.padding,
        &write_hints,
    );
    defer model.deinit();
    // The kitty keyboard protocol, where there is one, tells ctrl+j from enter.
    var options = term.timed(term.inline_options, flags.timeout);
    options.kitty_keyboard = true;
    if (try term.run(ctx, @TypeOf(model), &model, options)) return term.exitInterrupted(ctx);
    if (model.inner.area.status != .submitted) return error.CommandFailed;
    try ctx.out.print("{s}\n", .{model.inner.area.value()});
}

const write_hints = [_]term.Hint{
    // alt+enter first: ctrl+j is enter where the terminal cannot tell them apart.
    .{ .keys = &.{ "alt+enter", "ctrl+j" }, .action = .hint, .help = "insert newline" },
    .{ .keys = &.{"ctrl+e"}, .action = .hint, .help = "open editor" },
    .{ .keys = &.{"enter"}, .action = .hint, .help = "submit" },
};

/// The editor of `write`, with gum's keys: enter submits, ctrl+j (or alt+enter) starts a
/// line, and ctrl+e hands the text to `$EDITOR`.
pub const Area = struct {
    area: Textarea,
    /// Fill the terminal's width (`--width 0`).
    fill: bool,
    cursor_mode: CursorMode,
    /// `--base.*`: a block around the editor; null when not given.
    base: ?tui.Style,
    /// For finding the editor.
    environ: *const std.process.Environ.Map,

    const editor = 1;
    const newline = tui.input.Key.parse("enter") catch unreachable;

    pub fn update(model: *Area, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .resize => |size| if (model.fill) {
                const sides = model.insets();
                model.area.width = size.width -| (sides.left + sides.right);
                model.area.scroll();
            },
            .key => |key| {
                if (key.matches("enter")) {
                    model.area.status = .submitted;
                    return .quit;
                }
                if (key.matches("ctrl+j") or key.matches("alt+enter")) {
                    _ = model.area.handleKey(newline);
                    return .none;
                }
                if (key.matches("ctrl+e")) return .handoff(editor);
            },
            else => {},
        }
        return model.area.update(msg);
    }

    /// Edits the text in the user's editor, at the cursor's line, as a file whose lines
    /// all end with a line break; the text stays as it was when the editor fails.
    pub fn handoff(model: *Area, io: Io, id: u32) tui.Cmd {
        std.debug.assert(id == editor);
        const gpa = model.area.gpa;
        const value = model.area.value();
        const line: u32 = @intCast(std.mem.count(u8, value[0..model.area.cursor], "\n") + 1);
        const file = std.fmt.allocPrint(gpa, "{s}{s}", .{
            value,
            if (value.len > 0) "\n" else "",
        }) catch return .none;
        defer gpa.free(file);
        const text = sys.process.editText(gpa, io, model.environ, file, .{
            .suffix = ".md",
            .at = .{ .line = line },
        }) catch return .none;
        defer gpa.free(text);
        model.area.setValue(std.mem.trimEnd(u8, text, "\r\n")) catch {};
        return .none;
    }

    pub fn view(model: *const Area, w: *Io.Writer) Io.Writer.Error!void {
        const base = model.base orelse return model.area.view(w);
        var body: Io.Writer.Allocating = .init(model.area.gpa);
        defer body.deinit();
        try model.area.view(&body.writer);
        try base.render(w, body.written());
    }

    pub fn cursor(model: *const Area) ?tui.Cursor {
        const at = model.area.cursorPosition();
        const sides = model.insets();
        return cursorAt(model.cursor_mode, at.column + sides.left, at.row + sides.top);
    }

    /// What `base` puts around the editor: margin, border, and padding.
    fn insets(model: *const Area) tui.Style.Sides {
        const base = model.base orelse return .{};
        const on = base.border != null;
        const sides = base.border_sides;
        return .{
            .top = base.margin.top + base.padding.top + @intFromBool(on and sides.top),
            .right = base.margin.right + base.padding.right + @intFromBool(on and sides.right),
            .bottom = base.margin.bottom + base.padding.bottom +
                @intFromBool(on and sides.bottom),
            .left = base.margin.left + base.padding.left + @intFromBool(on and sides.left),
        };
    }

    pub fn deinit(model: *Area) void {
        model.area.deinit();
    }
};

/// The `write` model from its flags and starting value.
pub fn buildArea(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    flags: WriteFlags,
    value: []const u8,
    theme: *const cli.Theme,
) std.mem.Allocator.Error!Area {
    // A gray band, where the theme has nothing for it.
    const highlight: tui.Style = .{ .bg = .{ .basic = 8 } };
    var model: Area = .{
        .area = .{
            .gpa = gpa,
            .prompt = flags.prompt,
            .placeholder = flags.placeholder,
            .char_limit = if (flags.char_limit == 0) null else flags.char_limit,
            .max_lines = if (flags.max_lines == 0) null else flags.max_lines,
            .height = if (flags.height == 0) null else flags.height,
            .width = if (flags.width == 0) null else flags.width,
            .line_numbers = flags.show_line_numbers,
            .end_of_buffer = " ",
            .styles = .{
                .prompt = flags.prompt_style.over(theme.note),
                .placeholder = flags.placeholder_style.over(theme.note),
                .cursor = cursorStyle(flags.cursor_mode, flags.cursor_style, theme),
                .line_number = flags.line_number_style.over(theme.note),
                .cursor_line = if (flags.show_cursor_line)
                    flags.cursor_line_style.over(highlight)
                else
                    null,
                .cursor_line_number = flags.cursor_line_number_style.over(.{}),
                .end_of_buffer = flags.end_of_buffer_style.over(theme.note),
            },
        },
        .fill = flags.width == 0,
        .cursor_mode = flags.cursor_mode,
        .base = if (std.meta.eql(flags.base_style, styles.Styles{}))
            null
        else
            flags.base_style.over(.{}),
        .environ = environ,
    };
    errdefer model.deinit();
    try model.area.setValue(value);
    return model;
}

const testing = std.testing;
const plain_theme: cli.Theme = .bold;

test "input: header, help line, cursor, starting value, and the limit" {
    const line = try buildLine(testing.allocator, .{ .char_limit = 3 }, "Ad", &plain_theme);
    const model = framed(line, testing.allocator, "Name", true, .{}, &input_hints);
    var d: tui.testing.Driver(@TypeOf(model)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("Name\n> Ad \n\nenter submit");
    // The terminal's own cursor, after "> Ad", below the header.
    try testing.expect(d.screen.cursor_visible);
    try testing.expectEqual(1, d.screen.row);
    try testing.expectEqual(4, d.screen.column);
    try d.typeText("aXYZ");
    try d.press("enter");
    try testing.expectEqualStrings("Ada", d.model().inner.input.value());
    try testing.expectEqual(.submitted, d.model().inner.input.status);
}

test "input: --password masks, and the limit is gum's" {
    const line = try buildLine(testing.allocator, .{ .password = true }, "", &plain_theme);
    var d: tui.testing.Driver(Line) = try .init(testing.allocator, line, .{});
    defer d.deinit();
    try testing.expectEqual(400, d.model().input.char_limit);
    try d.expectFrame("> Type something...");
    try d.typeText("hunter2");
    try d.expectFrame("> ••••••• ");
    try testing.expectEqualStrings("hunter2", d.model().input.value());
}

test "input: --width scrolls the text sideways" {
    const line = try buildLine(testing.allocator, .{ .width = 4 }, "abcdefgh", &plain_theme);
    var d: tui.testing.Driver(Line) = try .init(testing.allocator, line, .{});
    defer d.deinit();
    try d.expectFrame("> efgh ");
    try testing.expectEqual(6, d.screen.column);
    try d.press("home");
    try d.expectFrame("> abcde");
    try testing.expectEqual(2, d.screen.column);
}

test "input: --width 0 fills the terminal, less the padding" {
    const flags: InputFlags = .{ .padding = try .parse("0 3") };
    const xs: [100]u8 = @splat('x');
    const line = try buildLine(testing.allocator, flags, &xs, &plain_theme);
    const model = framed(line, testing.allocator, "", false, flags.padding, &.{});
    var d: tui.testing.Driver(@TypeOf(model)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try testing.expectEqual(74, d.model().inner.input.width);
    // The prompt, 71 x's, and the cursor after them, inside the padding.
    try d.expectFrame("   > " ++ xs[0..71] ++ "    ");
    try testing.expectEqual(3 + 2 + 71, d.screen.column);
}

test "input: --cursor.mode hide shows no cursor; static does not blink" {
    var hidden = try buildLine(testing.allocator, .{ .cursor_mode = .hide }, "", &plain_theme);
    defer hidden.deinit();
    try testing.expectEqual(null, hidden.cursor());
    try testing.expectEqual(tui.Style{}, hidden.input.styles.cursor);
    var steady = try buildLine(testing.allocator, .{ .cursor_mode = .static }, "ab", &plain_theme);
    defer steady.deinit();
    const at = steady.cursor().?;
    try testing.expect(!at.blink);
    try testing.expectEqual(4, at.x);
}

test "input: the style flags reach the parts, over the theme" {
    var line = try buildLine(testing.allocator, .{
        .prompt_style = .{ .bold = true },
        .cursor_style = .{ .foreground = .{ .indexed = 212 } },
    }, "", &cli.Theme.default);
    defer line.deinit();
    try testing.expect(line.input.styles.prompt.bold);
    try testing.expectEqual(tui.Color{ .indexed = 212 }, line.input.styles.cursor.fg);
    try testing.expectEqual(cli.Theme.default.note, line.input.styles.placeholder);
}

fn startArea(environ: *const std.process.Environ.Map, flags: WriteFlags, value: []const u8) !Area {
    return buildArea(testing.allocator, environ, flags, value, &plain_theme);
}

test "write: enter submits, ctrl+j and alt+enter start lines" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const area = try startArea(&environ, .{ .prompt = "", .height = 0 }, "");
    var d: tui.testing.Driver(Area) = try .init(testing.allocator, area, .{});
    defer d.deinit();
    try d.expectFrame("Write something...");
    try d.typeText("a");
    try d.press("ctrl+j");
    try d.typeText("b");
    try d.press("alt+enter");
    try d.typeText("c");
    try d.press("enter");
    try testing.expectEqualStrings("a\nb\nc", d.model().area.value());
    try testing.expectEqual(.submitted, d.model().area.status);
}

test "write: rows to --height, line numbers, the cursor, and --max-lines" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const flags: WriteFlags = .{ .height = 4, .show_line_numbers = true, .max_lines = 2 };
    const area = try startArea(&environ, flags, "one");
    const model = framed(area, testing.allocator, "", true, .{}, &write_hints);
    var d: tui.testing.Driver(@TypeOf(model)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("┃ 1 one \n┃    \n┃    \n┃    \n\n" ++
        "alt+enter/ctrl+j insert newline • ctrl+e open editor • enter submit");
    try testing.expectEqual(0, d.screen.row);
    try testing.expectEqual(7, d.screen.column);
    try d.press("ctrl+j");
    try d.typeText("two");
    // A third line would pass --max-lines.
    try d.press("ctrl+j");
    try d.typeText("!");
    try testing.expectEqualStrings("one\ntwo!", d.model().inner.area.value());
    try testing.expectEqual(1, d.screen.row);
    try testing.expectEqual(8, d.screen.column);
}

test "write: --width wraps long lines, each row behind the prompt" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const area = try startArea(&environ, .{ .width = 8, .height = 0 }, "abcdefghij");
    var d: tui.testing.Driver(Area) = try .init(testing.allocator, area, .{});
    defer d.deinit();
    // Eight columns: the prompt, five letters, and one for the cursor.
    try d.expectFrame("┃ abcde\n┃ fghij ");
    try testing.expectEqual(1, d.screen.row);
    try testing.expectEqual(7, d.screen.column);
    // Up keeps the column, short of the end of a row that wraps: that is the next row's.
    try d.press("up");
    try testing.expectEqual(0, d.screen.row);
    try testing.expectEqual(4, d.model().area.cursor);
}

test "write: --show-cursor-line and the style flags" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var area = try buildArea(testing.allocator, &environ, .{
        .show_cursor_line = true,
        .cursor_line_style = .{ .italic = true },
        .base_style = .{ .border = .ascii },
    }, "", &cli.Theme.default);
    defer area.deinit();
    const line = area.area.styles.cursor_line.?;
    try testing.expect(line.italic);
    try testing.expectEqual(tui.Color{ .basic = 8 }, line.bg);
    try testing.expectEqual(cli.Theme.default.accent, area.area.styles.cursor);
    try testing.expect(area.base.?.border != null);
    try testing.expectEqual(tui.Style.Sides.all(1), area.insets());
    var bare = try startArea(&environ, .{}, "");
    defer bare.deinit();
    try testing.expectEqual(null, bare.base);
}
