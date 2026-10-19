//! Help text, generated from the command tree.

const std = @import("std");
const sets = @import("sets.zig");
const field = @import("field");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const parse = @import("parse.zig");
const Messages = @import("Messages.zig");
const i18n = @import("i18n.zig");
const Theme = @import("Theme.zig");
const term = @import("term");
const Style = term.Style;
const display = term.width;

/// What a help page shows, and how.
pub const Options = struct {
    /// The root offers the `help` command.
    help_command: bool = true,
    /// The root accepts `--version`.
    version: bool = false,
    /// Every command accepts `-q`/`--quiet`.
    quiet: bool = false,
    /// Lines are wrapped to this many columns.
    width: u16 = default_width,
    /// How many colors help may use; `.none` writes plain text.
    color: term.capability.Color = .none,
    /// The styles used when there is color.
    theme: *const Theme = &.default,
    /// Replacements for parts of the page.
    sections: Sections = .{},
    /// External subcommands found on `PATH`, listed on the root under "Plugins".
    plugins: []const []const u8 = &.{},
    /// Headings and the other words help writes.
    messages: *const Messages = &Messages.english,
    /// Translates summaries, descriptions, group headings, flag help, and examples.
    translation: ?*const i18n.Translation = null,

    fn tr(options: Options, english: []const u8) []const u8 {
        return i18n.textIn(options.translation, english);
    }

    /// Starts text in `style`, when there is color.
    fn open(options: Options, writer: *Writer, style: Style) Writer.Error!void {
        if (options.color != .none and style.hasSgr()) {
            try style.lowered(options.color).writeSgr(writer);
        }
    }

    /// Ends text started with `open`.
    fn close(options: Options, writer: *Writer, style: Style) Writer.Error!void {
        if (options.color != .none and style.hasSgr()) try writer.writeAll(term.ansi.reset);
    }

    fn paint(options: Options, writer: *Writer, style: Style, text: []const u8) Writer.Error!void {
        try options.open(writer, style);
        try writer.writeAll(text);
        try options.close(writer, style);
    }
};

/// Writes one part of a help page for the last command of `path`.
pub const Section = *const fn (writer: *Writer, path: []const *const Command) Writer.Error!void;

/// Parts of the help page an app can replace, keeping the rest. Each replaces its part
/// whole, blank lines included; write nothing to drop a part.
pub const Sections = struct {
    /// Above the usage: by default the command's description and a blank line.
    header: ?Section = null,
    /// The `Usage:` lines.
    usage: ?Section = null,
    /// After everything else: by default the `Use "app <command> --help" ...` line.
    footer: ?Section = null,
};

/// The width help wraps to when the terminal's is unknown.
pub const default_width = 100;

/// Internal, for the runner and completion. The built-in `help` command, as help lists it
/// on the root.
pub const help_command = .{ "help", "Help about any command" };

const help_flag: Flag = .{
    .name = "help",
    .field = "help",
    .kind = .bool,
    .short = 'h',
    .check = alwaysValid,
};
const quiet_flag: Flag = .{
    .name = "quiet",
    .field = "quiet",
    .kind = .bool,
    .short = 'q',
    .help = "Suppress warnings",
    .check = alwaysValid,
};
const version_flag: Flag = .{
    .name = "version",
    .field = "version",
    .kind = .bool,
    .short = 'V',
    .help = "Print the version",
    .check = alwaysValid,
};

fn alwaysValid(_: []const u8) bool {
    return true;
}

/// Writes the help for the last command of `path`.
pub fn write(writer: *Writer, path: []const *const Command, options: Options) Writer.Error!void {
    assert(path.len > 0);
    const cmd = path[path.len - 1];
    const is_root = path.len == 1;
    // A topic is a page of text, not a command.
    const about = options.tr(cmd.about());
    if (cmd.topic) return writer.print("{s}\n", .{std.mem.trimEnd(u8, about, "\n")});
    if (options.sections.header) |header| {
        try header(writer, path);
    } else if (about.len > 0) {
        try writer.print("{s}\n\n", .{std.mem.trimEnd(u8, about, "\n")});
    }
    if (options.sections.usage) |usage| try usage(writer, path) else {
        try writeUsageStyled(writer, path, options);
    }
    if (cmd.aliases.len > 0) {
        try heading(writer, options, options.messages.heading_aliases);
        try writer.print("  {s}", .{cmd.name});
        for (cmd.aliases) |alias| try writer.print(", {s}", .{alias});
        try writer.writeByte('\n');
    }
    try writeCommands(writer, cmd, is_root and options.help_command, if (is_root)
        options
    else
        noPlugins(options));
    try writeArguments(writer, cmd, options);
    try writeFlags(writer, path, is_root and options.version, options);
    if (cmd.examples.len > 0) {
        try heading(writer, options, options.messages.heading_examples);
        const examples = options.tr(cmd.examples);
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, examples, "\n"), '\n');
        while (lines.next()) |line| try writeExample(writer, line, options);
    }
    if (options.sections.footer) |footer| return footer(writer, path);
    if (hasVisibleSubcommands(cmd)) {
        var buffer: [512]u8 = undefined;
        var command_path: Writer = .fixed(&buffer);
        writePath(&command_path, path) catch {};
        try writer.writeByte('\n');
        try Messages.render(writer, options.messages.more_information, &.{command_path.buffered()});
        try writer.writeByte('\n');
    }
}

fn noPlugins(options: Options) Options {
    var copy = options;
    copy.plugins = &.{};
    return copy;
}

/// Writes `\n<name>:\n`, in the heading style.
fn heading(writer: *Writer, options: Options, name: []const u8) Writer.Error!void {
    try writer.writeByte('\n');
    try headingLine(writer, options, name);
}

fn headingLine(writer: *Writer, options: Options, name: []const u8) Writer.Error!void {
    try options.open(writer, options.theme.heading);
    try writer.print("{s}:", .{name});
    try options.close(writer, options.theme.heading);
    try writer.writeByte('\n');
}

/// One line of examples, indented: a comment (`# ...`) in the comment style, otherwise
/// flags (words starting with `-`) in the flag style.
fn writeExample(writer: *Writer, line: []const u8, options: Options) Writer.Error!void {
    try writer.writeAll("  ");
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "#")) {
        try options.paint(writer, options.theme.comment, line);
        return writer.writeByte('\n');
    }
    var words = std.mem.splitScalar(u8, line, ' ');
    var first = true;
    while (words.next()) |word| {
        if (!first) try writer.writeByte(' ');
        first = false;
        const style: Style = if (word.len > 1 and word[0] == '-') options.theme.flag else .{};
        try options.paint(writer, style, word);
    }
    try writer.writeByte('\n');
}

/// Writes the Usage section alone.
pub fn writeUsage(writer: *Writer, path: []const *const Command) Writer.Error!void {
    return writeUsageStyled(writer, path, .{});
}

fn writeUsageStyled(
    writer: *Writer,
    path: []const *const Command,
    options: Options,
) Writer.Error!void {
    const cmd = path[path.len - 1];
    const m = options.messages;
    // The section opens the help, so unlike `heading` it has no blank line before it.
    try headingLine(writer, options, m.heading_usage);
    const theme = options.theme;
    if (cmd.run != null or !hasVisibleSubcommands(cmd)) {
        try writer.writeAll("  ");
        try options.open(writer, theme.program);
        try writePath(writer, path);
        try options.close(writer, theme.program);
        try writer.writeByte(' ');
        try options.paint(writer, theme.placeholder, m.usage_flags);
        if (cmd.args.usage.len > 0) {
            try writer.writeByte(' ');
            try options.paint(writer, theme.placeholder, cmd.args.usage);
        } else if (cmd.args.max == null or cmd.args.max.? > 0) {
            try writer.writeByte(' ');
            try options.paint(writer, theme.placeholder, m.usage_args);
        }
        try writer.writeByte('\n');
    }
    if (hasVisibleSubcommands(cmd)) {
        try writer.writeAll("  ");
        try options.open(writer, theme.program);
        try writePath(writer, path);
        try options.close(writer, theme.program);
        try writer.writeByte(' ');
        try options.paint(writer, theme.placeholder, m.usage_command);
        try writer.writeByte('\n');
    }
}

/// Writes the command names of `path` separated by spaces: `app config get`.
pub fn writePath(writer: *Writer, path: []const *const Command) Writer.Error!void {
    for (path, 0..) |cmd, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.writeAll(cmd.name);
    }
}

fn hasVisibleSubcommands(cmd: *const Command) bool {
    for (cmd.subcommands) |sub| {
        if (listed(sub)) return true;
    }
    return false;
}

/// Whether help lists or searches `sub` at all: hidden and deprecated commands still run
/// but are not advertised.
fn advertised(sub: Command) bool {
    return !sub.hidden and sub.deprecated == null;
}

/// A subcommand listed under a command heading: advertised and not a help topic.
fn listed(sub: Command) bool {
    return advertised(sub) and !sub.topic;
}

/// Lists subcommands: ungrouped ones under "Commands:", then each group under its own
/// heading, in order of first appearance; built-ins last.
fn writeCommands(
    writer: *Writer,
    cmd: *const Command,
    with_help: bool,
    options: Options,
) Writer.Error!void {
    var width: usize = 0;
    for (cmd.subcommands) |sub| {
        if (advertised(sub)) width = @max(width, display.of(sub.name));
    }
    if (with_help) width = @max(width, display.of(help_command[0]));
    if (hasUngrouped(cmd)) {
        try heading(writer, options, options.messages.heading_commands);
        for (cmd.subcommands) |sub| {
            if (listed(sub) and sub.group.len == 0) {
                try writeCommandLine(writer, sub.name, options.tr(sub.summary), width, options);
            }
        }
    }
    for (cmd.subcommands, 0..) |sub, i| {
        if (!listed(sub) or sub.group.len == 0) continue;
        const seen = for (cmd.subcommands[0..i]) |earlier| {
            if (listed(earlier) and std.mem.eql(u8, earlier.group, sub.group)) break true;
        } else false;
        if (seen) continue;
        try heading(writer, options, options.tr(sub.group));
        for (cmd.subcommands[i..]) |member| {
            if (listed(member) and std.mem.eql(u8, member.group, sub.group)) {
                try writeCommandLine(
                    writer,
                    member.name,
                    options.tr(member.summary),
                    width,
                    options,
                );
            }
        }
    }
    if (with_help) {
        try heading(writer, options, options.messages.heading_additional);
        const summary = options.messages.help_command;
        try writeCommandLine(writer, help_command[0], summary, width, options);
    }
    const any_topic = for (cmd.subcommands) |sub| {
        if (sub.topic and advertised(sub)) break true;
    } else false;
    if (options.plugins.len > 0) {
        try heading(writer, options, options.messages.heading_plugins);
        for (options.plugins) |name| try writeCommandLine(writer, name, "", width, options);
    }
    if (any_topic) {
        try heading(writer, options, options.messages.heading_topics);
        for (cmd.subcommands) |sub| {
            if (!sub.topic or !advertised(sub)) continue;
            try writeCommandLine(writer, sub.name, options.tr(sub.summary), width, options);
        }
    }
}

/// Writes each command under `root` (hidden and deprecated ones aside) that mentions
/// `query`, ignoring case, in its name, aliases, summary, description, or flags, as
/// `apropos` does: its path and summary, one per line. Returns how many there were.
pub fn search(
    arena: std.mem.Allocator,
    writer: *Writer,
    root: *const Command,
    query: []const u8,
    options: Options,
) (Writer.Error || std.mem.Allocator.Error)!usize {
    var found: std.ArrayList(Found) = .empty;
    var path: std.ArrayList(*const Command) = .empty;
    try collect(arena, &found, &path, root, query, options);
    var width: usize = 0;
    for (found.items) |hit| width = @max(width, display.of(hit.path));
    for (found.items) |hit| try writeCommandLine(writer, hit.path, hit.summary, width, options);
    return found.items.len;
}

const Found = struct { path: []const u8, summary: []const u8 };

fn collect(
    arena: std.mem.Allocator,
    found: *std.ArrayList(Found),
    path: *std.ArrayList(*const Command),
    cmd: *const Command,
    query: []const u8,
    options: Options,
) std.mem.Allocator.Error!void {
    try path.append(arena, cmd);
    defer _ = path.pop();
    if (path.items.len > 1 and mentions(path.items, query, options)) {
        var words: std.Io.Writer.Allocating = .init(arena);
        writePath(&words.writer, path.items) catch return error.OutOfMemory;
        try found.append(arena, .{ .path = words.written(), .summary = options.tr(cmd.summary) });
    }
    for (cmd.subcommands) |*sub| {
        if (advertised(sub.*)) try collect(arena, found, path, sub, query, options);
    }
}

fn mentions(path: []const *const Command, query: []const u8, options: Options) bool {
    const cmd = path[path.len - 1];
    const has = std.ascii.findIgnoreCase;
    for ([_][]const u8{ cmd.name, cmd.summary, cmd.description }) |text| {
        if (has(text, query) != null or has(options.tr(text), query) != null) return true;
    }
    for (cmd.aliases) |alias| if (has(alias, query) != null) return true;
    for (cmd.flags) |flag| {
        if (flag.hidden or flag.deprecated != null) continue;
        if (has(flag.name, query) != null or has(flag.help, query) != null) return true;
        if (has(options.tr(flag.help), query) != null) return true;
    }
    return false;
}

fn hasUngrouped(cmd: *const Command) bool {
    for (cmd.subcommands) |sub| {
        if (listed(sub) and sub.group.len == 0) return true;
    }
    return false;
}

/// `  name   summary`, the names in a column `width` wide and the summary wrapped beside it.
fn writeCommandLine(
    writer: *Writer,
    name: []const u8,
    summary: []const u8,
    width: usize,
    options: Options,
) Writer.Error!void {
    try writer.writeAll("  ");
    try options.paint(writer, options.theme.command, name);
    if (summary.len == 0) return writer.writeByte('\n');
    try writer.splatByteAll(' ', width - display.of(name) + 3);
    try writeWrapped(writer, summary, width + 5, options.width);
}

/// Typed positionals under "Arguments:", each with its help and whether it is required;
/// only when one of them has help, since the usage line already names them.
fn writeArguments(writer: *Writer, cmd: *const Command, options: Options) Writer.Error!void {
    const positionals = cmd.args.positionals;
    const any = for (positionals) |positional| {
        if (positional.help.len > 0) break true;
    } else false;
    if (!any) return;
    var width: usize = 0;
    for (positionals) |positional| width = @max(width, display.of(positional.name));
    try heading(writer, options, options.messages.heading_arguments);
    for (positionals) |positional| {
        try writer.writeAll("  ");
        try options.paint(writer, options.theme.placeholder, positional.name);
        var buffer: [1024]u8 = undefined;
        var description: Writer = .fixed(&buffer);
        // A description longer than the buffer is cut short rather than failing the help.
        describePositional(&description, positional, options) catch {};
        if (description.buffered().len == 0) {
            try writer.writeByte('\n');
            continue;
        }
        try writer.splatByteAll(' ', width - display.of(positional.name) + 3);
        try writeWrapped(writer, description.buffered(), width + 5, options.width);
    }
}

fn describePositional(
    writer: *Writer,
    positional: Command.Positional,
    options: Options,
) Writer.Error!void {
    const help_text = options.tr(positional.help);
    try writer.writeAll(help_text);
    if (positional.required) {
        if (help_text.len > 0) try writer.writeByte(' ');
        try options.paint(writer, options.theme.note, options.messages.required);
    }
}

/// The command's own and persistent flags under "Flags:", inherited ones under
/// "Global Flags:". All flag columns share one width.
fn writeFlags(
    writer: *Writer,
    path: []const *const Command,
    version: bool,
    options: Options,
) Writer.Error!void {
    const quiet = options.quiet;
    const m = options.messages;
    const cmd = path[path.len - 1];
    // A flag of the command's own may take `-h`, `-q`, or `-V`; then only the long form is
    // built in.
    // A flag named `quiet` replaces the built-in one entirely.
    var help_spelling = help_flag;
    var quiet_spelling: ?Flag = if (quiet) quiet_flag else null;
    if (quiet_spelling) |*q| q.help = m.quiet_flag;
    var version_spelling = version_flag;
    version_spelling.help = m.version_flag;
    var visible = parse.visible(path);
    while (visible.next()) |flag| {
        if (flag.short == 'h') help_spelling.short = null;
        if (flag.short == 'V') version_spelling.short = null;
        if (quiet_spelling) |*q| {
            if (flag.short == 'q') q.short = null;
            if (std.mem.eql(u8, flag.name, "quiet")) quiet_spelling = null;
        }
    }
    var width: usize = spellingWidth(&help_spelling);
    if (quiet_spelling) |*q| width = @max(width, spellingWidth(q));
    if (version) width = @max(width, spellingWidth(&version_spelling));
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (shown(path, flag)) width = @max(width, spellingWidth(flag));
    }
    // One long spelling (a flag listing many choices) does not push every description to
    // the right: past a third of the page, it gets a line of its own.
    width = @min(width, @max(max_flag_column, options.width / 3));

    try heading(writer, options, m.heading_flags);
    for (cmd.flags) |*flag| {
        if (shown(path, flag)) try writeFlagLine(writer, flag, width, options);
    }
    for (cmd.persistent_flags) |*flag| {
        if (shown(path, flag)) try writeFlagLine(writer, flag, width, options);
    }
    try writeSpellingColumn(writer, &help_spelling, width, options);
    try Messages.render(writer, m.help_flag, &.{cmd.name});
    try writer.writeByte('\n');
    if (quiet_spelling) |*q| try writeFlagLine(writer, q, width, options);
    if (version) try writeFlagLine(writer, &version_spelling, width, options);

    if (path.len < 2) return;
    var any_global = false;
    var level = path.len - 1;
    while (level > 0) {
        level -= 1;
        for (path[level].persistent_flags) |*flag| {
            if (!shown(path, flag)) continue;
            if (!any_global) try heading(writer, options, m.heading_global_flags);
            any_global = true;
            try writeFlagLine(writer, flag, width, options);
        }
    }
}

/// Visible, not hidden or deprecated, and not shadowed by a nearer flag of the same name.
fn shown(path: []const *const Command, flag: *const Flag) bool {
    if (flag.hidden or flag.deprecated != null) return false;
    var it = parse.visible(path);
    while (it.next()) |candidate| {
        if (std.mem.eql(u8, candidate.name, flag.name)) return candidate == flag;
    }
    return false;
}

fn spellingWidth(flag: *const Flag) usize {
    var counter: Writer.Discarding = .init(&.{});
    flag.writeSpelling(&counter.writer) catch unreachable; // Discarding never fails.
    return @intCast(counter.fullCount());
}

/// The widest the flag column gets on a narrow page; see `writeFlags`.
const max_flag_column = 24;

/// `flag.writeSpelling`, indented, styled, and padded to the column `width` wide; one that
/// is wider ends its line, and the description starts on the next, under the column.
fn writeSpellingColumn(
    writer: *Writer,
    flag: *const Flag,
    width: usize,
    options: Options,
) Writer.Error!void {
    const theme = options.theme;
    try writer.writeAll("  ");
    if (flag.short) |short| {
        try options.open(writer, theme.flag);
        try writer.print("-{c}", .{short});
        try options.close(writer, theme.flag);
        try writer.writeAll(", ");
    } else {
        try writer.writeAll("    ");
    }
    try options.open(writer, theme.flag);
    try writer.print("--{s}", .{flag.name});
    try options.close(writer, theme.flag);
    if (flag.takesValue()) {
        try writer.writeByte(' ');
        try options.open(writer, theme.placeholder);
        try writer.print("<{s}>", .{flag.value_name});
        try options.close(writer, theme.placeholder);
    }
    const spelled = spellingWidth(flag);
    if (spelled <= width) return writer.splatByteAll(' ', width - spelled + 3);
    try writer.writeByte('\n');
    try writer.splatByteAll(' ', width + 5);
}

fn writeFlagLine(
    writer: *Writer,
    flag: *const Flag,
    width: usize,
    options: Options,
) Writer.Error!void {
    var buffer: [1024]u8 = undefined;
    var description: Writer = .fixed(&buffer);
    // A description longer than the buffer is cut short rather than failing the help.
    describeFlag(&description, flag, options) catch {};
    try writeSpellingColumn(writer, flag, width, options);
    try writeWrapped(writer, description.buffered(), width + 5, options.width);
}

fn describeFlag(writer: *Writer, flag: *const Flag, options: Options) Writer.Error!void {
    const m = options.messages;
    const help_text = builtinHelp(m, flag) orelse options.tr(flag.help);
    try writer.writeAll(help_text);
    var separator: []const u8 = if (help_text.len > 0) " " else "";
    var buffer: [256]u8 = undefined;
    const note = options.theme.note;
    if (flag.write_default != null) {
        var default: Writer = .fixed(&buffer);
        // A default that does not fit is cut short rather than failing the help.
        flag.writeDefault(&default) catch {};
        try writer.writeAll(separator);
        try options.open(writer, note);
        try Messages.render(writer, m.default_value, &.{default.buffered()});
        try options.close(writer, note);
        separator = " ";
    }
    const minimum = flag.minimum();
    const maximum = flag.maximum();
    if (minimum != null or maximum != null) {
        try writer.writeAll(separator);
        try options.open(writer, note);
        defer options.close(writer, note) catch {};
        if (minimum != null and maximum != null) {
            try Messages.render(writer, m.range, &.{ minimum.?.text, maximum.?.text });
        } else if (minimum) |low| {
            try Messages.render(writer, m.minimum, &.{low.text});
        } else {
            try Messages.render(writer, m.maximum, &.{maximum.?.text});
        }
        separator = " ";
    }
    if (flag.env) |env| {
        try writer.writeAll(separator);
        try options.open(writer, note);
        try Messages.render(writer, m.env_variable, &.{env});
        try options.close(writer, note);
        separator = " ";
    }
    if (flag.also.len > 0) {
        try writer.writeAll(separator);
        try options.open(writer, note);
        try Messages.render(writer, m.also_set, &.{flag.also});
        try options.close(writer, note);
        separator = " ";
    }
    if (flag.required) {
        try writer.writeAll(separator);
        try options.paint(writer, note, m.required);
    }
}

/// The help of a flag `.confirm`, `.dry_run`, `.output`, `.logging`, or `App.color_flag`
/// added, in `m`'s language.
fn builtinHelp(m: *const Messages, flag: *const Flag) ?[]const u8 {
    const english = &Messages.english;
    if (flag.help.ptr == english.yes_flag.ptr) return m.yes_flag;
    if (flag.help.ptr == english.dry_run_flag.ptr) return m.dry_run_flag;
    if (flag.help.ptr == english.output_flag.ptr) return m.output_flag;
    if (flag.help.ptr == english.verbose_flag.ptr) return m.verbose_flag;
    if (flag.help.ptr == english.log_level_flag.ptr) return m.log_level_flag;
    if (flag.help.ptr == english.color_flag.ptr) return m.color_flag;
    return null;
}

/// Writes `text` starting at column `indent`, breaking at spaces so that no line passes
/// `line`; continuation lines are indented to `indent`. A word longer than the room left is
/// written whole. Widths are display widths: escapes take none, wide characters two.
fn writeWrapped(writer: *Writer, text: []const u8, indent: usize, line: u16) Writer.Error!void {
    const room = @max(line -| indent, 30);
    var column: usize = 0;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        const word_width = display.of(word);
        if (column > 0 and column + 1 + word_width > room) {
            try writer.writeByte('\n');
            try writer.splatByteAll(' ', indent);
            column = 0;
        } else if (column > 0) {
            try writer.writeByte(' ');
            column += 1;
        }
        try writer.writeAll(word);
        column += word_width;
    }
    try writer.writeByte('\n');
}

const testing = std.testing;
const spec = @import("spec.zig");
const Context = @import("Context.zig");

fn noop(_: *Context) !void {}

const test_root = spec.command(.{
    .name = "app",
    .summary = "An example application",
    .persistent_flags = flags: {
        const T = struct {
            config: ?[]const u8 = null,
        };
        break :flags sets.flags(T, field.Set(.{field.Spec(T){ .fields = .{ .config = .{ .help = "Config file" } } }}), .{ .fields = .{ .config = .{ .short = 'c', .value_name = "path" } } });
    },
    .subcommands = .{
        spec.command(.{
            .name = "serve",
            .summary = "Start the server",
            .aliases = &.{"s"},
            .examples = "app serve --port 80\napp s",
            .args = .{ .max = 1, .usage = "[dir]" },
            .flags = flags: {
                const T = struct {
                    port: u16 = 8080,
                    mode: enum { dev, prod } = .dev,
                    name: []const u8,
                    old: bool = false,
                };
                break :flags sets.flags(T, field.Set(.{field.Spec(T){ .fields = .{ .port = .{ .help = "Port to listen on" }, .mode = .{ .help = "Run mode" }, .old = .{ .deprecated = "gone" } } }}), .{ .fields = .{ .port = .{ .short = 'p', .env = "PORT" } } });
            },
            .run = noop,
        }),
        spec.command(.{
            .name = "get",
            .summary = "Print a value",
            .group = "Query Commands",
            .run = noop,
        }),
        spec.command(.{
            .name = "keys",
            .summary = "List keys",
            .group = "Query Commands",
            .run = noop,
        }),
        spec.command(.{ .name = "secret", .hidden = true, .run = noop }),
    },
});

fn render(path: []const *const Command, options: Options) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, path, options);
    return out.toOwnedSlice();
}

test "root help" {
    const text = try render(&.{&test_root}, .{ .version = true });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\An example application
        \\
        \\Usage:
        \\  app <command>
        \\
        \\Commands:
        \\  serve   Start the server
        \\
        \\Query Commands:
        \\  get     Print a value
        \\  keys    List keys
        \\
        \\Additional Commands:
        \\  help    Help about any command
        \\
        \\Flags:
        \\  -c, --config <path>   Config file
        \\  -h, --help            Help for app
        \\  -V, --version         Print the version
        \\
        \\Use "app <command> --help" for more information about a command.
        \\
    , text);
}

test "long descriptions wrap" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeWrapped(&out.writer, "aaaa bbbb cccc dddd", default_width - 32, default_width);
    try testing.expectEqualStrings("aaaa bbbb cccc dddd\n", out.written());
    out.clearRetainingCapacity();
    try writeWrapped(
        &out.writer,
        "aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd",
        default_width - 30,
        default_width,
    );
    const indent: [default_width - 30]u8 = @splat(' ');
    const expected = "aaaaaaaaaa bbbbbbbbbb\n" ++ indent ++ "cccccccccc dddddddddd\n";
    try testing.expectEqualStrings(expected, out.written());
}

test "subcommand help" {
    const text = try render(&.{ &test_root, &test_root.subcommands[0] }, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\Start the server
        \\
        \\Usage:
        \\  app serve [flags] [dir]
        \\
        \\Aliases:
        \\  serve, s
        \\
        \\Flags:
        \\  -p, --port <int>        Port to listen on (default 8080) [env: PORT]
        \\      --mode <dev|prod>   Run mode (default dev)
        \\      --name <string>     (required)
        \\  -h, --help              Help for serve
        \\
        \\Global Flags:
        \\  -c, --config <path>     Config file
        \\
        \\Examples:
        \\  app serve --port 80
        \\  app s
        \\
    , text);
}

const shape_root = spec.command(.{
    .name = "app",
    .persistent_flags = flags: {
        const T = struct {
            output: []const u8 = "text",
        };
        break :flags sets.flags(T, field.Set(.{field.Spec(T){ .fields = .{ .output = .{ .help = "Root output" } } }}), .{ .fields = .{ .output = .{ .short = 'o' } } });
    },
    .args = .{ .max = null },
    .run = noop,
    .subcommands = .{
        spec.command(.{ .name = "get", .summary = "Get", .group = "Query", .run = noop }),
        spec.command(.{ .name = "set", .summary = "Set", .group = "Edit", .run = noop }),
        spec.command(.{ .name = "keys", .group = "Query", .run = noop }),
        spec.command(.{ .name = "debug", .summary = "Hidden", .hidden = true, .run = noop }),
        spec.command(.{
            .name = "show",
            .summary = "Show things",
            .flags = flags: {
                const T = struct {
                    output: []const u8 = "",
                    host: bool = false,
                    secret: bool = false,
                    legacy: bool = false,
                };
                break :flags sets.flags(T, field.Set(.{field.Spec(T){ .fields = .{ .output = .{ .help = "Show output" }, .host = .{ .help = "Show the host" }, .legacy = .{ .deprecated = "gone" } } }}), .{ .fields = .{ .host = .{ .short = 'h' }, .secret = .{ .hidden = true } } });
            },
            .run = noop,
        }),
    },
});

test "groups only, hidden commands omitted, run and subcommands both in usage" {
    const path = [_]*const Command{&shape_root};
    const text = try render(&path, .{ .help_command = false });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\Usage:
        \\  app [flags] [args...]
        \\  app <command>
        \\
        \\Commands:
        \\  show   Show things
        \\
        \\Query:
        \\  get    Get
        \\  keys
        \\
        \\Edit:
        \\  set    Set
        \\
        \\Flags:
        \\  -o, --output <string>   Root output (default text)
        \\  -h, --help              Help for app
        \\
        \\Use "app <command> --help" for more information about a command.
        \\
    , text);
}

test "a command with only groups has no Commands section" {
    const root = comptime spec.command(.{
        .name = "app",
        .subcommands = .{
            spec.command(.{ .name = "a", .group = "First", .run = noop }),
            spec.command(.{ .name = "hidden", .group = "Second", .hidden = true, .run = noop }),
            spec.command(.{ .name = "b", .group = "Second", .run = noop }),
        },
    });
    const text = try render(&.{&root}, .{ .help_command = false });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\Usage:
        \\  app <command>
        \\
        \\First:
        \\  a
        \\
        \\Second:
        \\  b
        \\
        \\Flags:
        \\  -h, --help   Help for app
        \\
        \\Use "app <command> --help" for more information about a command.
        \\
    , text);
}

test "hidden, deprecated, and shadowed flags; a user flag on -h" {
    const path = [_]*const Command{ &shape_root, &shape_root.subcommands[4] };
    const text = try render(&path, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\Show things
        \\
        \\Usage:
        \\  app show [flags]
        \\
        \\Flags:
        \\      --output <string>   Show output
        \\  -h, --host              Show the host
        \\      --help              Help for show
        \\
    , text);
}

test "long flag help wraps under its column" {
    const root = comptime spec.command(.{
        .name = "app",
        .flags = flags: {
            const T = struct {
                name: []const u8 = "",
            };
            break :flags sets.flags(T, field.Set(.{field.Spec(T){ .fields = .{ .name = .{ .help = "The name of the thing that this command operates on, which is " ++
                "given here in a deliberately long sentence so that it has to wrap" } } }}), .{ .fields = .{ .name = .{ .env = "APP_NAME" } } });
        },
        .run = noop,
    });
    const text = try render(&.{&root}, .{ .help_command = false });
    defer testing.allocator.free(text);
    const pad: [24]u8 = @splat(' ');
    try testing.expectEqualStrings(
        "Usage:\n  app [flags]\n\nFlags:\n" ++
            "      --name <string>   The name of the thing that this command operates on, " ++
            "which is given here in\n" ++ pad ++
            "a deliberately long sentence so that it has to wrap [env: APP_NAME]\n" ++
            "  -h, --help            Help for app\n",
        text,
    );
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try testing.expect(line.len <= default_width);
}

const topic_root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{ .name = "run", .summary = "Run it", .run = noopHandler }),
        spec.command(.{
            .name = "environment",
            .summary = "Variables the app reads",
            .description = "APP_HOME  where data lives\nAPP_DEBUG  log more\n",
            .topic = true,
        }),
    },
});

fn noopHandler(_: *@import("Context.zig")) !void {}

test "help topics are listed apart and print their page" {
    const text = try render(&.{&topic_root}, .{ .help_command = false });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\Usage:
        \\  app <command>
        \\
        \\Commands:
        \\  run           Run it
        \\
        \\Help Topics:
        \\  environment   Variables the app reads
        \\
        \\Flags:
        \\  -h, --help   Help for app
        \\
        \\Use "app <command> --help" for more information about a command.
        \\
    , text);
    const page = try render(&.{ &topic_root, &topic_root.subcommands[1] }, .{});
    defer testing.allocator.free(page);
    try testing.expectEqualStrings("APP_HOME  where data lives\nAPP_DEBUG  log more\n", page);
}

const WideFlags = struct {
    name: []const u8 = "",
};
const wide_flags = sets.flags(WideFlags, field.Set(.{field.Spec(WideFlags){ .fields = .{
    .name = .{ .help = "one two three four five six seven eight nine ten" },
} }}), .{});

const wide_root = spec.command(.{ .name = "app", .flags = wide_flags, .run = noopHandler });

test "a flag too wide for the column gets a line of its own" {
    const root = comptime spec.command(.{
        .name = "app",
        .flags = flags: {
            const T = struct {
                format: enum { text, json, yaml, toml, zon, env, ini, systemd } = .text,
                all: bool = false,
            };
            break :flags sets.flags(T, field.Set(.{field.Spec(T){ .fields = .{ .format = .{ .help = "Output format" }, .all = .{ .help = "All" } } }}), .{});
        },
        .run = noop,
    });
    const text = try render(&.{&root}, .{ .help_command = false, .width = 80 });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\Usage:
        \\  app [flags]
        \\
        \\Flags:
        \\      --format <text|json|yaml|toml|zon|env|ini|systemd>
        \\                               Output format (default text)
        \\      --all                    All
        \\  -h, --help                   Help for app
        \\
    , text);
}

test "width and color" {
    // Descriptions keep at least 30 columns however narrow the terminal; at 60 they fit.
    const narrow = try render(&.{&wide_root}, .{ .width = 60 });
    defer testing.allocator.free(narrow);
    var lines = std.mem.splitScalar(u8, narrow, '\n');
    while (lines.next()) |line| try testing.expect(line.len <= 60);
    try testing.expect(std.mem.indexOf(u8, narrow, "one two three four") != null);

    const colored = try render(&.{&wide_root}, .{ .color = .basic, .theme = &Theme.bold });
    defer testing.allocator.free(colored);
    try testing.expect(std.mem.startsWith(u8, colored, "\x1b[1mUsage:\x1b[0m\n"));
    try testing.expect(std.mem.indexOf(u8, colored, "\n\x1b[1mFlags:\x1b[0m\n") != null);
}

test "the default theme styles each kind of text, and plain text is unchanged under it" {
    const path = [_]*const Command{ &test_root, &test_root.subcommands[0] };
    const colored = try render(&path, .{ .color = .ansi256 });
    defer testing.allocator.free(colored);
    for ([_][]const u8{
        "\x1b[1;35mUsage:\x1b[0m\n  \x1b[1mapp serve\x1b[0m \x1b[2m[flags]\x1b[0m " ++
            "\x1b[2m[dir]\x1b[0m\n",
        "  \x1b[32m-p\x1b[0m, \x1b[32m--port\x1b[0m \x1b[2m<int>\x1b[0m",
        "Port to listen on \x1b[2m(default 8080)\x1b[0m \x1b[2m[env: PORT]\x1b[0m\n",
        "  app serve \x1b[32m--port\x1b[0m 80\n",
    }) |needle| {
        if (std.mem.indexOf(u8, colored, needle) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ needle, colored });
            return error.TestExpectedContains;
        }
    }
    // The columns line up as without color.
    var stripped: Writer.Allocating = .init(testing.allocator);
    defer stripped.deinit();
    try term.ansi.strip(&stripped.writer, colored);
    const plain = try render(&path, .{});
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings(plain, stripped.written());
}

test "wide and accented text wraps by its display width" {
    const root = comptime spec.command(.{
        .name = "app",
        .flags = flags: {
            const T = struct {
                name: []const u8 = "",
            };
            break :flags sets.flags(T, field.Set(.{field.Spec(T){ .fields = .{ .name = .{ .help = "Größe änderung überall Größe änderung überall Größe änderung " ++
                "überall Größe änderung überall 名前を設定する 名前を設定する" } } }}), .{});
        },
        .run = noop,
    });
    const text = try render(&.{&root}, .{ .help_command = false, .width = 60 });
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var longest: usize = 0;
    while (lines.next()) |line| longest = @max(longest, display.of(line));
    try testing.expect(longest <= 60);
    // Byte counts would have wrapped the accented line early, at under 50 columns.
    try testing.expect(longest > 50);
}

fn customFooter(writer: *Writer, path: []const *const Command) Writer.Error!void {
    try writer.print("\nReport bugs for {s} at https://example.com/issues\n", .{path[0].name});
}

fn noHeader(_: *Writer, _: []const *const Command) Writer.Error!void {}

test "sections replace parts of the page" {
    const text = try render(&.{&topic_root}, .{
        .help_command = false,
        .sections = .{ .header = noHeader, .footer = customFooter },
    });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "Usage:\n"));
    try testing.expect(std.mem.endsWith(
        u8,
        text,
        "\nReport bugs for app at https://example.com/issues\n",
    ));
    try testing.expect(std.mem.indexOf(u8, text, "for more information") == null);
}

const SecretFlags = struct {
    token: []const u8 = "hunter2",
};
const secret_flags = sets.flags(SecretFlags, field.Set(.{field.Spec(SecretFlags){ .fields = .{
    .token = .{ .secret = true, .help = "API token" },
} }}), .{});

const Copy = struct {
    source: []const u8,
    target: ?[]const u8 = null,
};
const copy_args = sets.args(Copy, field.Set(.{field.Spec(Copy){ .fields = .{
    .source = .{ .help = "File to copy" },
} }}), .{});

const arguments_root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{ .name = "copy", .args = copy_args, .flags = secret_flags, .run = noop }),
        spec.command(.{ .name = "plain", .args = struct { key: []const u8 }, .run = noop }),
        spec.command(.{ .name = "move", .summary = "Move", .run = noop }),
        spec.command(.{ .name = "mv", .summary = "Old", .deprecated = "use move", .run = noop }),
    },
});

test "a secret's default is redacted; typed positionals with help get an Arguments section" {
    const copy = &arguments_root.subcommands[0];
    const text = try render(&.{ &arguments_root, copy }, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\Usage:
        \\  app copy [flags] <source> [target]
        \\
        \\Arguments:
        \\  source   File to copy (required)
        \\  target
        \\
        \\Flags:
        \\      --token <string>   API token (default <redacted>)
        \\  -h, --help             Help for copy
        \\
    , text);
    try testing.expect(std.mem.indexOf(u8, text, "hunter2") == null);

    // Without any help, the usage line says it all.
    const plain = try render(&.{ &arguments_root, &arguments_root.subcommands[1] }, .{});
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "Arguments:") == null);
}

test "deprecated commands are not listed" {
    const text = try render(&.{&arguments_root}, .{ .help_command = false });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "  move    Move\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mv") == null);
}

test "-V is left to a flag that takes it" {
    const root = comptime spec.command(.{
        .name = "app",
        .flags = sets.flags(struct {
            verify: bool = false,
        }, field.none, .{ .fields = .{ .verify = .{ .short = 'V' } } }),
        .run = noop,
    });
    const text = try render(&.{&root}, .{ .version = true });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "  -V, --verify") != null);
    try testing.expect(std.mem.indexOf(u8, text, "      --version") != null);
}
