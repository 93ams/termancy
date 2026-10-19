//! `termancy ui format`: format text for the terminal, as gum's `format`: Markdown (rendered
//! by `term.markdown`), code (highlighted by `term.highlight`), emoji shortcodes, or a
//! template of styling functions.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const Writer = std.Io.Writer;
const markdown = tui.term.markdown;
const highlight = tui.term.highlight;

const Flags = struct {
    type: Kind = .markdown,
    language: []const u8 = "",
    theme: []const u8 = "",
    width: ?u16 = null,
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .type = .{ .help = "What the text is" },
    .language = .{ .help = "The language of code (--type code)" },
    .theme = .{ .help = "Markdown's style sheet (dark, light, dracula, tokyo-night, " ++
        "pink, ascii, notty, or a JSON file), or code's theme (charm, dracula, monokai, " ++
        "tokyo-night, github, ansi)" },
    .width = .{ .help = "Columns to wrap Markdown to (default: the terminal's)" },
} }}), .{ .fields = .{
    .type = .{ .short = 't' },
    .language = .{ .short = 'l' },
    .width = .{ .short = 'w' },
} });

const Kind = enum { markdown, code, emoji, template };

pub const command = cli.command(.{
    .name = "format",
    .summary = "Format Markdown, code, emoji, or a template for the terminal",
    .description =
    \\Format the arguments (one per line), or standard input. As Markdown (the default):
    \\headings, emphasis, lists, quotes, tables, task lists, links, and highlighted code
    \\blocks, wrapped to the width. As code: highlighted for --language. As emoji:
    \\:shortcodes: replaced. As a template: {{ Bold "x" }}, {{ Italic "x" }},
    \\{{ Faint "x" }}, {{ Underline "x" }}, {{ CrossOut "x" }}, {{ Color "fg" "bg" "x" }},
    \\{{ Foreground "fg" "x" }}, {{ Background "bg" "x" }}, and pipes:
    \\{{ "x" | Bold | Color "212" "" }}. Colors are written only where standard output
    \\shows them (as for termancy ui style).
    ,
    .args = .{ .max = null, .usage = "[text...]" },
    .flags = flags_flags,
    .examples =
    \\termancy ui format "# Done" "Everything **passed**."
    \\termancy ui format < CHANGELOG.md
    \\termancy ui format -t code -l zig < build.zig
    \\termancy ui format -t emoji ":rocket: shipped"
    \\termancy ui format -t template '{{ Bold "Hello" }} {{ "world" | Color "212" "" }}'
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const source = if (ctx.args.len > 0)
        try std.mem.join(ctx.arena, "\n", ctx.args)
    else
        try term.readStdin(ctx) orelse
            return ctx.usageError("no text: give it as arguments or on standard input", .{});
    const color = try term.stdoutColor(ctx);
    var out: Writer.Allocating = .init(ctx.arena);
    switch (flags.type) {
        .markdown => {
            const sheet = try styleSheet(ctx, flags.theme, color);
            const width = flags.width orelse
                cli.terminal.width(ctx.io, std.Io.File.stdout()) orelse 80;
            const options: markdown.Options = .{ .width = width, .style = sheet };
            try markdown.render(ctx.arena, &out.writer, source, options);
        },
        .code => {
            const theme = if (flags.theme.len > 0)
                highlight.Theme.named(flags.theme) orelse
                    return ctx.usageError("no code theme named {s}", .{flags.theme})
            else
                highlight.Theme.charm;
            if (flags.language.len == 0) {
                try out.writer.writeAll(source);
            } else {
                const lang = highlight.language(flags.language) orelse
                    return ctx.usageError("no language named {s}", .{flags.language});
                try highlight.write(&out.writer, source, lang, theme);
            }
            if (!std.mem.endsWith(u8, source, "\n")) try out.writer.writeByte('\n');
        },
        .emoji => {
            try markdown.writeEmoji(&out.writer, source);
            if (!std.mem.endsWith(u8, source, "\n")) try out.writer.writeByte('\n');
        },
        .template => {
            renderTemplate(&out.writer, source) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return ctx.usageError("template: {s}", .{templateMessage(err)}),
            };
            if (!std.mem.endsWith(u8, source, "\n")) try out.writer.writeByte('\n');
        },
    }
    try term.writeStyled(ctx.out, out.written(), color);
}

/// The style sheet `name` names (or a JSON file of one); by default dark, or light when
/// the terminal's background is (by `COLORFGBG`), or notty without color.
fn styleSheet(
    ctx: *cli.Context,
    name: []const u8,
    color: tui.capability.Color,
) !markdown.StyleSheet {
    if (name.len == 0) {
        if (color == .none) return .notty;
        return if (lightBackground(ctx.environ)) .light else .dark;
    }
    if (markdown.StyleSheet.named(name)) |sheet| return sheet;
    const json = std.Io.Dir.cwd().readFileAlloc(ctx.io, name, ctx.arena, .limited(1 << 20)) catch
        return ctx.usageError("no style sheet named {s}", .{name});
    return markdown.StyleSheet.parse(ctx.arena, json, .dark) catch
        ctx.usageError("{s}: not a style sheet", .{name});
}

/// Whether `COLORFGBG` (`fg;bg`, as rxvt and others set it) says the background is light.
pub fn lightBackground(environ: *const std.process.Environ.Map) bool {
    const value = environ.get("COLORFGBG") orelse return false;
    const semicolon = std.mem.lastIndexOfScalar(u8, value, ';') orelse return false;
    const bg = std.fmt.parseInt(u8, value[semicolon + 1 ..], 10) catch return false;
    return bg == 7 or bg >= 9 and bg != 8;
}

const TemplateError = error{
    Unterminated,
    UnknownFunction,
    BadArgument,
    InvalidColor,
} || Writer.Error;

fn templateMessage(err: TemplateError) []const u8 {
    return switch (err) {
        error.Unterminated => "a {{ without its }}",
        error.UnknownFunction => "an unknown function (Bold, Italic, Faint, Underline, " ++
            "CrossOut, Blink, Reverse, Color, Foreground, Background)",
        error.BadArgument => "a function given the wrong arguments",
        error.InvalidColor => "not a color",
        error.WriteFailed => "out of memory",
    };
}

/// Writes `text` with each `{{ ... }}` replaced by what its pipeline makes.
pub fn renderTemplate(w: *Writer, text: []const u8) TemplateError!void {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "{{")) |open| {
        try w.writeAll(rest[0..open]);
        const close = std.mem.indexOfPos(u8, rest, open + 2, "}}") orelse return error.Unterminated;
        try pipeline(w, rest[open + 2 .. close]);
        rest = rest[close + 2 ..];
    }
    try w.writeAll(rest);
}

/// `"text" | F a b | G` or `F a b "text"`: each stage a function, the last argument the
/// value so far.
fn pipeline(w: *Writer, source: []const u8) TemplateError!void {
    var buffers: [2][4096]u8 = undefined;
    var value: []const u8 = "";
    var have_value = false;
    var stages = std.mem.splitScalar(u8, source, '|');
    var turn: usize = 0;
    while (stages.next()) |stage| : (turn += 1) {
        var words: [6][]const u8 = undefined;
        const count = try split(stage, &words);
        if (count == 0) return error.BadArgument;
        if (isQuoted(words[0])) {
            if (count != 1 or have_value) return error.BadArgument;
            value = unquote(words[0]);
            have_value = true;
            continue;
        }
        var args: [6][]const u8 = undefined;
        for (words[1..count], 0..) |word, i| {
            if (!isQuoted(word)) return error.BadArgument;
            args[i] = unquote(word);
        }
        var n = count - 1;
        if (have_value) {
            args[n] = value;
            n += 1;
        }
        var out: Writer = .fixed(&buffers[turn % 2]);
        try apply(&out, words[0], args[0..n]);
        value = out.buffered();
        have_value = true;
    }
    try w.writeAll(value);
}

fn apply(w: *Writer, name: []const u8, args: []const []const u8) TemplateError!void {
    const attributes = [_]struct { []const u8, tui.Style }{
        .{ "Bold", .{ .bold = true } },
        .{ "Italic", .{ .italic = true } },
        .{ "Faint", .{ .dim = true } },
        .{ "Underline", .{ .underline = true } },
        .{ "CrossOut", .{ .strikethrough = true } },
        .{ "Blink", .{ .blink = true } },
        .{ "Reverse", .{ .reverse = true } },
    };
    for (attributes) |pair| if (std.mem.eql(u8, name, pair[0])) {
        if (args.len != 1) return error.BadArgument;
        return pair[1].paint(w, args[0]);
    };
    if (std.mem.eql(u8, name, "Color")) {
        if (args.len != 3) return error.BadArgument;
        const style: tui.Style = .{ .fg = try parseColor(args[0]), .bg = try parseColor(args[1]) };
        return style.paint(w, args[2]);
    }
    if (std.mem.eql(u8, name, "Foreground")) {
        if (args.len != 2) return error.BadArgument;
        return (tui.Style{ .fg = try parseColor(args[0]) }).paint(w, args[1]);
    }
    if (std.mem.eql(u8, name, "Background")) {
        if (args.len != 2) return error.BadArgument;
        return (tui.Style{ .bg = try parseColor(args[0]) }).paint(w, args[1]);
    }
    return error.UnknownFunction;
}

fn parseColor(text: []const u8) error{InvalidColor}!tui.Color {
    if (text.len == 0) return .default;
    return tui.Color.parse(text);
}

/// Splits `stage` into words: names and double-quoted strings (with `\"` inside).
fn split(stage: []const u8, words: *[6][]const u8) error{BadArgument}!usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < stage.len) {
        if (stage[i] == ' ' or stage[i] == '\t' or stage[i] == '\n') {
            i += 1;
            continue;
        }
        if (n == words.len) return error.BadArgument;
        const start = i;
        if (stage[i] == '"') {
            i += 1;
            while (i < stage.len and stage[i] != '"') : (i += 1) {
                if (stage[i] == '\\') i += 1;
            }
            if (i >= stage.len) return error.BadArgument;
            i += 1;
        } else {
            while (i < stage.len and stage[i] != ' ' and stage[i] != '"') i += 1;
        }
        words[n] = stage[start..i];
        n += 1;
    }
    return n;
}

fn isQuoted(word: []const u8) bool {
    return word.len >= 2 and word[0] == '"' and word[word.len - 1] == '"';
}

fn unquote(word: []const u8) []const u8 {
    return word[1 .. word.len - 1];
}

const testing = std.testing;

test renderTemplate {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try renderTemplate(&w, "a {{ Bold \"b\" }} {{ \"c\" | Italic | Color \"1\" \"\" }} d");
    try testing.expectEqualStrings(
        "a \x1b[1mb\x1b[0m \x1b[31m\x1b[3mc\x1b[0m\x1b[0m d",
        w.buffered(),
    );
    w = .fixed(&buffer);
    try testing.expectError(error.UnknownFunction, renderTemplate(&w, "{{ Shout \"x\" }}"));
    try testing.expectError(error.Unterminated, renderTemplate(&w, "{{ Bold \"x\""));
}

test lightBackground {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expect(!lightBackground(&environ));
    try environ.put("COLORFGBG", "15;0");
    try testing.expect(!lightBackground(&environ));
    try environ.put("COLORFGBG", "0;15");
    try testing.expect(lightBackground(&environ));
}
