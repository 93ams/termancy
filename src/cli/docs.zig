//! Reference documentation for a whole command tree: one Markdown document, one man page,
//! one HTML page, or one JSON document for tools (see `json.zig`); or, with `writeManTree`,
//! one man page per command. Hidden commands and flags are left out. Help topics appear as
//! their text alone. `command` is a ready-made `docs` command writing them for the tree it
//! is mounted in.

const std = @import("std");
const sets = @import("sets.zig");
const field = @import("field");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const parse = @import("parse.zig");
const help = @import("help.zig");
const json = @import("json.zig");
const spec = @import("spec.zig");
const Context = @import("Context.zig");
const App = @import("App.zig");

/// Commands nested deeper than this are not documented.
const max_depth = parse.max_depth;

/// What `write` writes.
pub const Format = enum {
    markdown,
    man,
    /// One self-contained page: a table of contents and a section per command.
    html,
    /// The tree as data, shaped to map onto LLM tool schemas; see `json.zig`.
    json,
};

/// One exit status and what it means, for the "Exit status" section.
pub const ExitStatus = Command.ExitStatus;

/// What the documents say beyond the tree.
pub const Options = struct {
    /// Listed under "Exit status" (EXIT STATUS in man pages); empty: no such section. See
    /// `exitStatuses`. JSON leaves them out.
    exit_statuses: []const ExitStatus = &.{},
    /// HTML only: link this style sheet instead of the page's own styles, to fit the page
    /// into a site.
    stylesheet: ?[]const u8 = null,
};

/// Writes the documentation for the tree under `root`: `.{}` for the plain options.
pub fn write(
    writer: *Writer,
    root: *const Command,
    format: Format,
    options: Options,
) Writer.Error!void {
    var path: [max_depth]*const Command = undefined;
    path[0] = root;
    const statuses = options.exit_statuses;
    switch (format) {
        .markdown => {
            try markdown(writer, &path, 1);
            if (statuses.len > 0) {
                try writer.writeAll("## Exit status\n\n| Status | Meaning |\n|---|---|\n");
                for (statuses) |status| {
                    try writer.print("| `{d}` | ", .{status.code});
                    try markdownText(writer, status.meaning);
                    try writer.writeAll(" |\n");
                }
                try writer.writeByte('\n');
            }
        },
        .man => {
            try manHeader(writer, root);
            try man(writer, &path, 1);
            if (statuses.len > 0) {
                try manExitStatuses(writer, statuses, &.{});
                try writer.writeByte('\n');
            }
        },
        .json => try json.write(writer, root),
        .html => {
            try htmlHeader(writer, root, &path, options.stylesheet);
            try html(writer, &path, 1);
            if (statuses.len > 0) {
                try writer.writeAll("<section id=\"exit-status\">\n<h2>Exit status</h2>\n" ++
                    "<table>\n<tr><th>Status</th><th>Meaning</th></tr>\n");
                for (statuses) |status| {
                    try writer.print("<tr><td><code>{d}</code></td><td>", .{status.code});
                    try htmlText(writer, status.meaning);
                    try writer.writeAll("</td></tr>\n");
                }
                try writer.writeAll("</table>\n</section>\n");
            }
            try writer.writeAll("</main>\n</body>\n</html>\n");
        },
    }
}

/// The statuses the app's commands exit with: the runner's own, in `ctx.messages`'
/// language (0, 1, 2, 126 when `App.plugins` is on, 130), and `App.exit_statuses` through
/// `ctx.translate`, by code. An app's meaning replaces the runner's for the same code.
pub fn exitStatuses(ctx: *const Context) std.mem.Allocator.Error![]const ExitStatus {
    const m = ctx.messages;
    const runner = [_]ExitStatus{
        .{ .code = App.exit_success, .meaning = m.status_success },
        .{ .code = App.exit_failure, .meaning = m.status_failure },
        .{ .code = App.exit_usage, .meaning = m.status_usage },
        .{ .code = App.exit_cannot_run, .meaning = m.status_cannot_run },
        .{ .code = App.exit_interrupted, .meaning = m.status_interrupted },
    };
    var list: std.ArrayList(ExitStatus) = .empty;
    outer: for (runner) |status| {
        if (status.code == App.exit_cannot_run and !ctx.plugins) continue;
        for (ctx.exit_statuses) |own| if (own.code == status.code) continue :outer;
        try list.append(ctx.arena, status);
    }
    for (ctx.exit_statuses) |own| {
        try list.append(ctx.arena, .{ .code = own.code, .meaning = ctx.translate(own.meaning) });
    }
    std.mem.sort(ExitStatus, list.items, {}, struct {
        fn lessThan(_: void, a: ExitStatus, b: ExitStatus) bool {
            return a.code < b.code;
        }
    }.lessThan);
    return list.items;
}

const CommandFlags = struct {
    format: Format = .markdown,
    dir: ?[]const u8 = null,
    stylesheet: ?[]const u8 = null,
};
const command_flags = sets.flags(CommandFlags, field.Set(.{field.Spec(CommandFlags){ .fields = .{
    .format = .{ .help = "Documentation format" },
    .stylesheet = .{ .help = "With --format html, link this style sheet instead of inline styles" },
    .dir = .{ .help = "With --format man, write one page per command into this directory" },
} }}), .{ .fields = .{
    .format = .{ .short = 'f' },
    .stylesheet = .{ .value_name = "url" },
    .dir = .{ .short = 'd', .value_name = "path", .complete = .from(completeDirectories) },
} });

/// A `docs` command for the tree it is mounted in, as the run sees it: without the commands
/// of features that are off, with what `App` adds (`completion`, `--color`), and with an
/// "Exit status" section (`exitStatuses`). Mount it wherever it belongs, as
/// `complete.command`; copy it to change its name or examples.
pub const command = spec.command(.{
    .name = "docs",
    .summary = "Print reference documentation for every command",
    .description =
    \\Print the documentation of the whole command tree to standard output: Markdown, one
    \\man page, one HTML page, or JSON. With --dir and --format man, write one page per
    \\command instead (<app>.1, <app>-<command>.1, ...), linked to each other under SEE
    \\ALSO.
    ,
    .flags = command_flags,
    .run = runCommand,
});

fn completeDirectories(_: *Context, _: []const u8) ![]const Command.Candidate {
    return &.{.directories};
}

fn runCommand(ctx: *Context, flags: CommandFlags) !void {
    const root = ctx.path[0];
    if (flags.stylesheet != null and flags.format != .html) {
        return ctx.usageError("--stylesheet applies to --format html", .{});
    }
    const options: Options = .{
        .exit_statuses = try exitStatuses(ctx),
        .stylesheet = flags.stylesheet,
    };
    const dir_path = flags.dir orelse return write(ctx.out, root, flags.format, options);
    if (flags.format != .man) return ctx.usageError("--dir applies to --format man", .{});
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(ctx.io, dir_path) catch |err| {
        return ctx.fail("{s}: cannot create: {s}", .{ dir_path, @errorName(err) });
    };
    var dir = cwd.openDir(ctx.io, dir_path, .{}) catch |err| {
        return ctx.fail("{s}: cannot open: {s}", .{ dir_path, @errorName(err) });
    };
    defer dir.close(ctx.io);
    writeManTree(ctx.io, dir, root, options) catch |err| {
        return ctx.fail("{s}: cannot write: {s}", .{ dir_path, @errorName(err) });
    };
}

fn markdown(writer: *Writer, path: *[max_depth]*const Command, depth: usize) Writer.Error!void {
    const current = path[0..depth];
    const cmd = current[depth - 1];
    try writer.writeAll(if (depth == 1) "# " else "## ");
    try help.writePath(writer, current);
    try writer.writeAll("\n\n");
    if (cmd.topic) {
        return writer.print("```\n{s}\n```\n\n", .{std.mem.trimEnd(u8, cmd.about(), "\n")});
    }
    if (cmd.about().len > 0) {
        try markdownText(writer, std.mem.trimEnd(u8, cmd.about(), "\n"));
        try writer.writeAll("\n\n");
    }
    try writer.writeAll("```\n");
    try help.writeUsage(writer, current);
    try writer.writeAll("```\n\n");
    if (cmd.aliases.len > 0) {
        try writer.writeAll("Aliases:");
        for (cmd.aliases) |alias| try writer.print(" `{s}`", .{alias});
        try writer.writeAll("\n\n");
    }
    try markdownArguments(writer, cmd);
    try markdownFlags(writer, current);
    if (cmd.exit_statuses.len > 0) {
        try writer.writeAll("Exit status:\n\n| Status | Meaning |\n|---|---|\n");
        for (cmd.exit_statuses) |status| {
            try writer.print("| `{d}` | ", .{status.code});
            try markdownText(writer, status.meaning);
            try writer.writeAll(" |\n");
        }
        try writer.writeByte('\n');
    }
    if (cmd.examples.len > 0) {
        try writer.print(
            "Examples:\n\n```\n{s}\n```\n\n",
            .{std.mem.trimEnd(u8, cmd.examples, "\n")},
        );
    }
    var any = false;
    for (cmd.subcommands) |sub| {
        if (sub.hidden) continue;
        if (!any) try writer.writeAll("| Command | Description |\n|---|---|\n");
        any = true;
        try writer.print("| `{s}` | ", .{sub.name});
        try markdownText(writer, sub.summary);
        try writer.writeAll(" |\n");
    }
    if (any) try writer.writeByte('\n');
    for (cmd.subcommands) |*sub| {
        if (sub.hidden or depth >= max_depth) continue;
        path[depth] = sub;
        try markdown(writer, path, depth + 1);
    }
}

/// Whether a command's typed positionals are worth a section: one of them has help. The
/// usage line already names them.
fn hasArgumentHelp(cmd: *const Command) bool {
    for (cmd.args.positionals) |positional| {
        if (positional.help.len > 0) return true;
    }
    return false;
}

fn markdownArguments(writer: *Writer, cmd: *const Command) Writer.Error!void {
    if (!hasArgumentHelp(cmd)) return;
    try writer.writeAll("| Argument | Description |\n|---|---|\n");
    for (cmd.args.positionals) |positional| {
        try writer.writeAll("| `");
        try markdownCell(writer, positional.name);
        try writer.writeAll("` | ");
        try markdownText(writer, positional.help);
        if (positional.required) {
            try writer.writeAll(if (positional.help.len > 0) " (required)" else "(required)");
        }
        try writer.writeAll(" |\n");
    }
    try writer.writeByte('\n');
}

fn markdownFlags(writer: *Writer, path: []const *const Command) Writer.Error!void {
    var any = false;
    var buffer: [128]u8 = undefined;
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (flag.hidden or flag.deprecated != null) continue;
        if (!any) try writer.writeAll("| Flag | Default | Description |\n|---|---|---|\n");
        any = true;
        try writer.writeAll("| `");
        try markdownCell(writer, spelling(flag, &buffer));
        try writer.writeAll("` | ");
        if (flag.write_default != null) {
            var default_writer: Writer = .fixed(&buffer);
            // A default that does not fit is cut short rather than failing the document.
            flag.writeDefault(&default_writer) catch {};
            try writer.writeByte('`');
            try markdownCell(writer, default_writer.buffered());
            try writer.writeByte('`');
        }
        try writer.writeAll(" | ");
        try markdownText(writer, flag.help);
        if (flag.env) |env| try writer.print(" (env `{s}`)", .{env});
        if (flag.required) try writer.writeAll(" (required)");
        try writer.writeAll(" |\n");
    }
    if (any) try writer.writeByte('\n');
}

/// Writes prose for Markdown: `<` and `>` become entities so that a placeholder such as
/// `<PREFIX>` is not read as an HTML tag, and `|` is escaped so it cannot end a table cell.
/// Not for code spans, where entities would show literally; use `markdownCell` there.
fn markdownText(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '|' => try writer.writeAll("\\|"),
        else => try writer.writeByte(c),
    };
}

/// Writes `text` for a table cell: `|` would end the cell, so it is escaped (also inside
/// code spans, as GitHub Flavored Markdown requires).
fn markdownCell(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| {
        if (c == '|') try writer.writeByte('\\');
        try writer.writeByte(c);
    }
}

fn manHeader(writer: *Writer, root: *const Command) Writer.Error!void {
    try writer.writeAll(".TH ");
    for (root.name) |c| try writer.writeByte(std.ascii.toUpper(c));
    try writer.writeAll(" 1\n.SH NAME\n");
    try manText(writer, root.name);
    if (root.summary.len > 0) {
        try writer.writeAll(" \\- ");
        try manText(writer, root.summary);
    }
    try writer.writeAll("\n.SH DESCRIPTION\n");
    try manText(writer, root.about());
    try writer.writeAll("\n.SH COMMANDS\n");
}

fn man(writer: *Writer, path: *[max_depth]*const Command, depth: usize) Writer.Error!void {
    const current = path[0..depth];
    const cmd = current[depth - 1];
    try writer.writeAll(".SS \"");
    for (current, 0..) |c, i| {
        if (i > 0) try writer.writeByte(' ');
        try manText(writer, c.name);
    }
    try writer.writeAll("\"\n");
    if (cmd.about().len > 0) {
        if (cmd.topic) try writer.writeAll(".nf\n");
        try manText(writer, std.mem.trimEnd(u8, cmd.about(), "\n"));
        try writer.writeAll(if (cmd.topic) "\n.fi\n" else "\n");
    }
    if (cmd.topic) return;
    if (hasArgumentHelp(cmd)) {
        for (cmd.args.positionals) |positional| {
            try manArgument(writer, positional);
            try writer.writeByte('\n');
        }
    }
    var it = parse.visible(current);
    while (it.next()) |flag| {
        if (flag.hidden or flag.deprecated != null or depth > 1 and isInherited(current, flag)) {
            continue;
        }
        try writer.writeAll(".TP\n\\fB");
        var buffer: [128]u8 = undefined;
        try manText(writer, spelling(flag, &buffer));
        try writer.writeAll("\\fR\n");
        try manText(writer, flag.help);
        try writer.writeByte('\n');
    }
    if (cmd.exit_statuses.len > 0) {
        try writer.writeAll(".PP\nExit status:");
        for (cmd.exit_statuses) |status| try manExitStatus(writer, status);
        try writer.writeByte('\n');
    }
    for (cmd.subcommands) |*sub| {
        if (sub.hidden or depth >= max_depth) continue;
        path[depth] = sub;
        try man(writer, path, depth + 1);
    }
}

// -- One man page per command ----------------------------------------------------------

/// Writes `<app>-<command>-....1` into `dir` for every command of the tree, the root as
/// `<app>.1`. Each page has a synopsis, the command's flags (inherited ones included),
/// its subcommands, and SEE ALSO links up and down the tree. Every page but a topic's gets
/// `options`.
pub fn writeManTree(
    io: std.Io,
    dir: std.Io.Dir,
    root: *const Command,
    options: Options,
) !void {
    var path: [max_depth]*const Command = undefined;
    path[0] = root;
    try writeManPages(io, dir, &path, 1, options);
}

fn writeManPages(
    io: std.Io,
    dir: std.Io.Dir,
    path: *[max_depth]*const Command,
    depth: usize,
    options: Options,
) !void {
    const current = path[0..depth];
    var name_buffer: [256]u8 = undefined;
    var name: Writer = .fixed(&name_buffer);
    try pageName(&name, current);
    try name.writeAll(".1");
    var file_buffer: [4096]u8 = undefined;
    const file = try dir.createFile(io, name.buffered(), .{});
    defer file.close(io);
    var file_writer = file.writer(io, &file_buffer);
    try manPageWith(&file_writer.interface, current, options);
    try file_writer.interface.flush();
    const cmd = current[depth - 1];
    for (cmd.subcommands) |*sub| {
        if (sub.hidden or depth >= max_depth) continue;
        path[depth] = sub;
        try writeManPages(io, dir, path, depth + 1, options);
    }
}

/// `app-config-set`: the page name of the last command of `path`.
fn pageName(writer: *Writer, path: []const *const Command) Writer.Error!void {
    for (path, 0..) |cmd, i| {
        if (i > 0) try writer.writeByte('-');
        try writer.writeAll(cmd.name);
    }
}

/// The man page of the last command of `path`.
pub fn manPage(writer: *Writer, path: []const *const Command) Writer.Error!void {
    return manPageWith(writer, path, .{});
}

fn manPageWith(writer: *Writer, path: []const *const Command, options: Options) Writer.Error!void {
    const cmd = path[path.len - 1];
    try writer.writeAll(".TH \"");
    var upper_buffer: [256]u8 = undefined;
    var upper: Writer = .fixed(&upper_buffer);
    pageName(&upper, path) catch {};
    for (upper.buffered()) |c| try writer.writeByte(std.ascii.toUpper(c));
    try writer.writeAll("\" 1\n.SH NAME\n");
    var name_buffer: [256]u8 = undefined;
    var name: Writer = .fixed(&name_buffer);
    pageName(&name, path) catch {};
    try manText(writer, name.buffered());
    if (cmd.summary.len > 0) {
        try writer.writeAll(" \\- ");
        try manText(writer, cmd.summary);
    }
    if (!cmd.topic) {
        try writer.writeAll("\n.SH SYNOPSIS\n.nf\n");
        var usage_buffer: [1024]u8 = undefined;
        var usage: Writer = .fixed(&usage_buffer);
        // A usage that does not fit is cut short rather than failing the page.
        help.writeUsage(&usage, path) catch {};
        var lines = std.mem.splitScalar(u8, usage.buffered(), '\n');
        _ = lines.next(); // "Usage:"
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try manText(writer, std.mem.trimStart(u8, line, " "));
            try writer.writeByte('\n');
        }
        try writer.writeAll(".fi");
    }
    if (cmd.about().len > 0) {
        try writer.writeAll("\n.SH DESCRIPTION\n");
        if (cmd.topic) try writer.writeAll(".nf\n");
        try manText(writer, std.mem.trimEnd(u8, cmd.about(), "\n"));
        if (cmd.topic) try writer.writeAll("\n.fi");
    }
    if (!cmd.topic and hasArgumentHelp(cmd)) {
        try writer.writeAll("\n.SH ARGUMENTS");
        for (cmd.args.positionals) |positional| {
            try writer.writeByte('\n');
            try manArgument(writer, positional);
        }
    }
    var any_flag = false;
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (cmd.topic or flag.hidden or flag.deprecated != null) continue;
        if (!any_flag) try writer.writeAll("\n.SH OPTIONS");
        any_flag = true;
        try writer.writeAll("\n.TP\n\\fB");
        var buffer: [128]u8 = undefined;
        try manText(writer, spelling(flag, &buffer));
        try writer.writeAll("\\fR\n");
        try manText(writer, flag.help);
        if (flag.env) |env| {
            try writer.writeAll(" (env ");
            try manText(writer, env);
            try writer.writeByte(')');
        }
    }
    var any_sub = false;
    for (cmd.subcommands) |sub| {
        if (sub.hidden) continue;
        if (!any_sub) try writer.writeAll("\n.SH COMMANDS");
        any_sub = true;
        try writer.writeAll("\n.TP\n\\fB");
        try manText(writer, sub.name);
        try writer.writeAll("\\fR\n");
        try manText(writer, sub.summary);
    }
    // The variables the options read, as `ENVIRONMENT` sections list them.
    var any_env = false;
    var vars = parse.visible(path);
    while (vars.next()) |flag| {
        if (cmd.topic or flag.hidden or flag.deprecated != null) continue;
        const env = flag.env orelse continue;
        if (!any_env) try writer.writeAll("\n.SH ENVIRONMENT");
        any_env = true;
        try writer.writeAll("\n.TP\n\\fB");
        try manText(writer, env);
        try writer.writeAll("\\fR\n");
        try manText(writer, flag.help);
    }
    if (!cmd.topic and options.exit_statuses.len + cmd.exit_statuses.len > 0) {
        try writer.writeByte('\n');
        try manExitStatuses(writer, options.exit_statuses, cmd.exit_statuses);
    }
    if (cmd.examples.len > 0) {
        try writer.writeAll("\n.SH EXAMPLES\n.nf\n");
        try manText(writer, std.mem.trimEnd(u8, cmd.examples, "\n"));
        try writer.writeAll("\n.fi");
    }
    // Parent first, then children, as `name(1)` references.
    var any_link = false;
    if (path.len > 1) {
        try writer.writeAll("\n.SH SEE ALSO\n\\fB");
        any_link = true;
        var parent: Writer = .fixed(&name_buffer);
        pageName(&parent, path[0 .. path.len - 1]) catch {};
        try manText(writer, parent.buffered());
        try writer.writeAll("\\fR(1)");
    }
    for (cmd.subcommands) |*sub| {
        if (sub.hidden) continue;
        try writer.writeAll(if (any_link) ",\n\\fB" else "\n.SH SEE ALSO\n\\fB");
        any_link = true;
        var child: Writer = .fixed(&name_buffer);
        pageName(&child, path) catch {};
        child.print("-{s}", .{sub.name}) catch {};
        try manText(writer, child.buffered());
        try writer.writeAll("\\fR(1)");
    }
    try writer.writeByte('\n');
}

/// The EXIT STATUS section, without a newline at either end: `statuses`, in their order,
/// with a command's `own` meaning in place of the app's for the same code, and then the
/// rest of `own`.
fn manExitStatuses(
    writer: *Writer,
    statuses: []const ExitStatus,
    own: []const ExitStatus,
) Writer.Error!void {
    try writer.writeAll(".SH EXIT STATUS");
    for (statuses) |status| try manExitStatus(writer, find(own, status.code) orelse status);
    for (own) |status| if (find(statuses, status.code) == null) {
        try manExitStatus(writer, status);
    };
}

fn manExitStatus(writer: *Writer, status: ExitStatus) Writer.Error!void {
    try writer.print("\n.TP\n\\fB{d}\\fR\n", .{status.code});
    try manText(writer, status.meaning);
}

fn find(statuses: []const ExitStatus, code: u8) ?ExitStatus {
    for (statuses) |status| if (status.code == code) return status;
    return null;
}

// -- HTML ------------------------------------------------------------------------------

fn htmlHeader(
    writer: *Writer,
    root: *const Command,
    path: *[max_depth]*const Command,
    stylesheet: ?[]const u8,
) Writer.Error!void {
    try writer.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>
    );
    try htmlText(writer, root.name);
    try writer.writeAll("</title>\n");
    if (stylesheet) |href| {
        try writer.writeAll("<link rel=\"stylesheet\" href=\"");
        try htmlText(writer, href);
        try writer.writeAll("\">\n");
    } else try writer.writeAll(
        \\<style>
        \\body {
        \\  font: 16px/1.5 system-ui, sans-serif; margin: 0 auto; max-width: 52rem; padding: 1rem;
        \\}
        \\pre, code { font-family: ui-monospace, monospace; }
        \\pre { background: #f4f4f4; padding: .75rem; overflow-x: auto; }
        \\table { border-collapse: collapse; width: 100%; }
        \\td, th {
        \\  border-bottom: 1px solid #ddd; padding: .25rem .5rem; text-align: left;
        \\  vertical-align: top;
        \\}
        \\section { margin-top: 2.5rem; }
        \\@media (prefers-color-scheme: dark) {
        \\  body { background: #111; color: #ddd; }
        \\  pre { background: #222; }
        \\  a { color: #8ab4f8; }
        \\  td, th { border-color: #333; }
        \\}
        \\</style>
        \\
    );
    try writer.writeAll(
        \\</head>
        \\<body>
        \\<nav>
        \\<ul>
        \\
    );
    try htmlToc(writer, path, 1);
    try writer.writeAll("</ul>\n</nav>\n<main>\n");
}

fn htmlToc(writer: *Writer, path: *[max_depth]*const Command, depth: usize) Writer.Error!void {
    const current = path[0..depth];
    try writer.writeAll("<li><a href=\"#");
    try anchor(writer, current);
    try writer.writeAll("\">");
    try htmlText(writer, current[depth - 1].name);
    try writer.writeAll("</a>");
    var any = false;
    for (current[depth - 1].subcommands) |*sub| {
        if (sub.hidden or depth >= max_depth) continue;
        if (!any) try writer.writeAll("\n<ul>\n");
        any = true;
        path[depth] = sub;
        try htmlToc(writer, path, depth + 1);
    }
    if (any) try writer.writeAll("</ul>\n");
    try writer.writeAll("</li>\n");
}

fn html(writer: *Writer, path: *[max_depth]*const Command, depth: usize) Writer.Error!void {
    const current = path[0..depth];
    const cmd = current[depth - 1];
    try writer.writeAll("<section id=\"");
    try anchor(writer, current);
    try writer.writeAll(if (depth == 1) "\">\n<h1>" else "\">\n<h2>");
    try htmlPath(writer, current);
    try writer.writeAll(if (depth == 1) "</h1>\n" else "</h2>\n");
    if (cmd.topic) {
        try writer.writeAll("<pre>");
        try htmlText(writer, std.mem.trimEnd(u8, cmd.about(), "\n"));
        try writer.writeAll("</pre>\n</section>\n");
    } else {
        if (cmd.about().len > 0) {
            try writer.writeAll("<p>");
            try htmlText(writer, std.mem.trimEnd(u8, cmd.about(), "\n"));
            try writer.writeAll("</p>\n");
        }
        var usage_buffer: [1024]u8 = undefined;
        var usage: Writer = .fixed(&usage_buffer);
        // A usage that does not fit is cut short rather than failing the page.
        help.writeUsage(&usage, current) catch {};
        try writer.writeAll("<pre>");
        try htmlText(writer, std.mem.trimEnd(u8, usage.buffered(), "\n"));
        try writer.writeAll("</pre>\n");
        if (cmd.aliases.len > 0) {
            try writer.writeAll("<p>Aliases:");
            for (cmd.aliases) |alias| {
                try writer.writeAll(" <code>");
                try htmlText(writer, alias);
                try writer.writeAll("</code>");
            }
            try writer.writeAll("</p>\n");
        }
        try htmlArguments(writer, cmd);
        try htmlFlags(writer, current);
        if (cmd.examples.len > 0) {
            try writer.writeAll("<h3>Examples</h3>\n<pre>");
            try htmlText(writer, std.mem.trimEnd(u8, cmd.examples, "\n"));
            try writer.writeAll("</pre>\n");
        }
        var any = false;
        for (cmd.subcommands) |*sub| {
            if (sub.hidden or depth >= max_depth) continue;
            if (!any) {
                try writer.writeAll("<table>\n<tr><th>Command</th><th>Description</th></tr>\n");
            }
            any = true;
            path[depth] = sub;
            try writer.writeAll("<tr><td><a href=\"#");
            try anchor(writer, path[0 .. depth + 1]);
            try writer.writeAll("\"><code>");
            try htmlText(writer, sub.name);
            try writer.writeAll("</code></a></td><td>");
            try htmlText(writer, sub.summary);
            try writer.writeAll("</td></tr>\n");
        }
        if (any) try writer.writeAll("</table>\n");
        try writer.writeAll("</section>\n");
    }
    for (cmd.subcommands) |*sub| {
        if (sub.hidden or depth >= max_depth) continue;
        path[depth] = sub;
        try html(writer, path, depth + 1);
    }
}

fn htmlArguments(writer: *Writer, cmd: *const Command) Writer.Error!void {
    if (!hasArgumentHelp(cmd)) return;
    try writer.writeAll("<table>\n<tr><th>Argument</th><th>Description</th></tr>\n");
    for (cmd.args.positionals) |positional| {
        try writer.writeAll("<tr><td><code>");
        try htmlText(writer, positional.name);
        try writer.writeAll("</code></td><td>");
        try htmlText(writer, positional.help);
        if (positional.required) {
            try writer.writeAll(if (positional.help.len > 0) " (required)" else "(required)");
        }
        try writer.writeAll("</td></tr>\n");
    }
    try writer.writeAll("</table>\n");
}

fn htmlFlags(writer: *Writer, path: []const *const Command) Writer.Error!void {
    var any = false;
    var buffer: [128]u8 = undefined;
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (flag.hidden or flag.deprecated != null) continue;
        if (!any) try writer.writeAll(
            "<table>\n<tr><th>Flag</th><th>Default</th><th>Description</th></tr>\n",
        );
        any = true;
        try writer.writeAll("<tr><td><code>");
        try htmlText(writer, spelling(flag, &buffer));
        try writer.writeAll("</code></td><td>");
        if (flag.write_default != null) {
            var default_writer: Writer = .fixed(&buffer);
            // A default that does not fit is cut short rather than failing the document.
            flag.writeDefault(&default_writer) catch {};
            try writer.writeAll("<code>");
            try htmlText(writer, default_writer.buffered());
            try writer.writeAll("</code>");
        }
        try writer.writeAll("</td><td>");
        try htmlText(writer, flag.help);
        if (flag.env) |env| {
            try writer.writeAll(" (env <code>");
            try htmlText(writer, env);
            try writer.writeAll("</code>)");
        }
        if (flag.required) try writer.writeAll(" (required)");
        try writer.writeAll("</td></tr>\n");
    }
    if (any) try writer.writeAll("</table>\n");
}

/// `app config set`, escaped.
fn htmlPath(writer: *Writer, path: []const *const Command) Writer.Error!void {
    for (path, 0..) |cmd, i| {
        if (i > 0) try writer.writeByte(' ');
        try htmlText(writer, cmd.name);
    }
}

/// `app-config-set`, an id for the last command of `path`.
fn anchor(writer: *Writer, path: []const *const Command) Writer.Error!void {
    for (path, 0..) |cmd, i| {
        if (i > 0) try writer.writeByte('-');
        try htmlText(writer, cmd.name);
    }
}

fn htmlText(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '&' => try writer.writeAll("&amp;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(c),
    };
}

/// The flag's spelling without help's alignment padding: `--raw`, `-v, --verbose`.
fn spelling(flag: *const Flag, buffer: []u8) []const u8 {
    var writer: Writer = .fixed(buffer);
    // A spelling that does not fit is cut short rather than failing the document.
    flag.writeSpelling(&writer) catch {};
    return std.mem.trimStart(u8, writer.buffered(), " ");
}

/// Whether `flag` belongs to an ancestor, and so was already documented there.
fn isInherited(path: []const *const Command, flag: *const Flag) bool {
    for (path[0 .. path.len - 1]) |ancestor| {
        for (ancestor.persistent_flags) |*candidate| {
            if (candidate == flag) return true;
        }
    }
    return false;
}

/// `.TP`, the positional's name in italics, then its help: one entry of an argument list.
fn manArgument(writer: *Writer, positional: Command.Positional) Writer.Error!void {
    try writer.writeAll(".TP\n\\fI");
    try manText(writer, positional.name);
    try writer.writeAll("\\fR\n");
    try manText(writer, positional.help);
    if (positional.required) {
        try writer.writeAll(if (positional.help.len > 0) " (required)" else "(required)");
    }
}

/// Escapes text for troff: backslashes, hyphens, and a leading `.` or `'`.
fn manText(writer: *Writer, text: []const u8) Writer.Error!void {
    var line_start = true;
    for (text) |c| {
        if (line_start and (c == '.' or c == '\'')) try writer.writeAll("\\&");
        switch (c) {
            '\\' => try writer.writeAll("\\e"),
            '-' => try writer.writeAll("\\-"),
            else => try writer.writeByte(c),
        }
        line_start = c == '\n';
    }
}

const testing = std.testing;

fn noop(_: *Context) !void {}

const test_root = spec.command(.{
    .name = "app",
    .summary = "An app",
    .persistent_flags = flags: {
        const T = struct {
            verbose: bool = false,
        };
        break :flags sets.flags(
            T,
            field.Set(.{field.Spec(T){ .fields = .{ .verbose = .{ .help = "More output" } } }}),
            .{ .fields = .{ .verbose = .{ .short = 'v' } } },
        );
    },
    .subcommands = .{
        spec.command(.{
            .name = "get",
            .summary = "Print a value",
            .args = .{ .min = 1, .max = 1, .usage = "<key>" },
            .flags = flags: {
                const T = struct {
                    raw: bool = false,
                };
                break :flags sets.flags(
                    T,
                    field.Set(
                        .{field.Spec(T){ .fields = .{ .raw = .{ .help = "No decoration" } } }},
                    ),
                    .{},
                );
            },
            .run = noop,
        }),
        spec.command(.{ .name = "hidden", .hidden = true, .run = noop }),
    },
});

test "markdown" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &test_root, .markdown, .{});
    try testing.expectEqualStrings(
        \\# app
        \\
        \\An app
        \\
        \\```
        \\Usage:
        \\  app <command>
        \\```
        \\
        \\| Flag | Default | Description |
        \\|---|---|---|
        \\| `-v, --verbose` |  | More output |
        \\
        \\| Command | Description |
        \\|---|---|
        \\| `get` | Print a value |
        \\
        \\## app get
        \\
        \\Print a value
        \\
        \\```
        \\Usage:
        \\  app get [flags] <key>
        \\```
        \\
        \\| Flag | Default | Description |
        \\|---|---|---|
        \\| `--raw` |  | No decoration |
        \\| `-v, --verbose` |  | More output |
        \\
        \\
    , out.written());
}

test "man" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &test_root, .man, .{});
    try testing.expectEqualStrings(
        \\.TH APP 1
        \\.SH NAME
        \\app \- An app
        \\.SH DESCRIPTION
        \\An app
        \\.SH COMMANDS
        \\.SS "app"
        \\An app
        \\.TP
        \\\fB\-v, \-\-verbose\fR
        \\More output
        \\.SS "app get"
        \\Print a value
        \\.TP
        \\\fB\-\-raw\fR
        \\No decoration
        \\
    , out.written());
}

const deep_root = spec.command(.{
    .name = "app",
    .summary = "Deep",
    .subcommands = .{spec.command(.{
        .name = "config",
        .summary = "Configuration",
        .subcommands = .{
            spec.command(.{
                .name = "set",
                .summary = "Set a value",
                .aliases = &.{ "put", "s" },
                .examples = "app config set a 1\napp config put b 2\n",
                .args = .{ .min = 2, .max = 2, .usage = "<key> <value>" },
                .flags = flags: {
                    const T = struct {
                        file: []const u8,
                        mode: enum { merge, replace } = .merge,
                        token: ?[]const u8 = null,
                        trace: bool = false,
                    };
                    break :flags sets.flags(
                        T,
                        field.Set(
                            .{
                                field.Spec(T){ .fields = .{
                                    .file = .{ .help = "File to edit" },
                                    .mode = .{ .help = "Merge or replace (a|b)" },
                                    .token = .{ .help = "Access token" },
                                    .trace = .{ .deprecated = "no longer used" },
                                } },
                            },
                        ),
                        .{
                            .fields = .{
                                .file = .{ .short = 'f' },
                                .token = .{ .env = "APP_TOKEN" },
                            },
                        },
                    );
                },
                .run = noop,
            }),
            spec.command(.{ .name = "dump", .hidden = true, .run = noop }),
        },
    })},
});

test "markdown: nested commands, aliases, examples, and every flag column" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &deep_root, .markdown, .{});
    try testing.expectEqualStrings(
        \\# app
        \\
        \\Deep
        \\
        \\```
        \\Usage:
        \\  app <command>
        \\```
        \\
        \\| Command | Description |
        \\|---|---|
        \\| `config` | Configuration |
        \\
        \\## app config
        \\
        \\Configuration
        \\
        \\```
        \\Usage:
        \\  app config <command>
        \\```
        \\
        \\| Command | Description |
        \\|---|---|
        \\| `set` | Set a value |
        \\
        \\## app config set
        \\
        \\Set a value
        \\
        \\```
        \\Usage:
        \\  app config set [flags] <key> <value>
        \\```
        \\
        \\Aliases: `put` `s`
        \\
        \\| Flag | Default | Description |
        \\|---|---|---|
        \\| `-f, --file <string>` |  | File to edit (required) |
        \\| `--mode <merge\|replace>` | `merge` | Merge or replace (a\|b) |
        \\| `--token <string>` |  | Access token (env `APP_TOKEN`) |
        \\
        \\Examples:
        \\
        \\```
        \\app config set a 1
        \\app config put b 2
        \\```
        \\
        \\
    , out.written());
}

test "man: nested commands and escaping" {
    const root = comptime spec.command(.{
        .name = "app",
        .summary = "Paths like C:\\dir",
        .description = ".hidden line\n'quoted line\nnot .at start",
        .subcommands = .{spec.command(.{
            .name = "sub",
            .summary = "Sub",
            .subcommands = .{spec.command(.{
                .name = "leaf",
                .summary = "Leaf",
                .flags = flags: {
                    const T = struct {
                        dry_run: bool = false,
                    };
                    break :flags sets.flags(
                        T,
                        field.Set(
                            .{field.Spec(T){
                                .fields = .{ .dry_run = .{ .help = ".starts with a dot" } },
                            }},
                        ),
                        .{},
                    );
                },
                .run = noop,
            })},
        })},
    });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &root, .man, .{});
    try testing.expectEqualStrings(
        \\.TH APP 1
        \\.SH NAME
        \\app \- Paths like C:\edir
        \\.SH DESCRIPTION
        \\\&.hidden line
        \\\&'quoted line
        \\not .at start
        \\.SH COMMANDS
        \\.SS "app"
        \\\&.hidden line
        \\\&'quoted line
        \\not .at start
        \\.SS "app sub"
        \\Sub
        \\.SS "app sub leaf"
        \\Leaf
        \\.TP
        \\\fB\-\-dry\-run\fR
        \\\&.starts with a dot
        \\
    , out.written());
}

test "markdown prose escapes angle brackets but code spans do not" {
    const root = comptime spec.command(.{
        .name = "app",
        .summary = "Reads <PREFIX>_KEY",
        .flags = flags: {
            const T = struct {
                prefix: []const u8 = "",
            };
            break :flags sets.flags(
                T,
                field.Set(
                    .{field.Spec(T){ .fields = .{ .prefix = .{ .help = "Read <PREFIX>_A" } } }},
                ),
                .{ .fields = .{ .prefix = .{ .value_name = "PREFIX" } } },
            );
        },
        .run = noop,
    });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &root, .markdown, .{});
    try testing.expect(std.mem.indexOf(u8, out.written(), "Reads &lt;PREFIX&gt;_KEY\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "| Read &lt;PREFIX&gt;_A |") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "`--prefix <PREFIX>`") != null);
}

const topic_root = spec.command(.{
    .name = "app",
    .summary = "An app",
    .subcommands = .{
        spec.command(.{
            .name = "get",
            .summary = "Print <a> value",
            .flags = flags: {
                const T = struct {
                    raw: bool = false,
                };
                break :flags sets.flags(
                    T,
                    field.Set(
                        .{field.Spec(T){
                            .fields = .{ .raw = .{ .help = "No \"decoration\" & more" } },
                        }},
                    ),
                    .{},
                );
            },
            .examples = "app get a",
            .run = noop,
        }),
        spec.command(.{
            .name = "environment",
            .summary = "Variables",
            .description = "APP_HOME  data\n",
            .topic = true,
        }),
    },
});

test "a man page per command" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try manPage(&out.writer, &.{ &topic_root, &topic_root.subcommands[0] });
    try testing.expectEqualStrings(
        \\.TH "APP-GET" 1
        \\.SH NAME
        \\app\-get \- Print <a> value
        \\.SH SYNOPSIS
        \\.nf
        \\app get [flags]
        \\.fi
        \\.SH DESCRIPTION
        \\Print <a> value
        \\.SH OPTIONS
        \\.TP
        \\\fB\-\-raw\fR
        \\No "decoration" & more
        \\.SH EXAMPLES
        \\.nf
        \\app get a
        \\.fi
        \\.SH SEE ALSO
        \\\fBapp\fR(1)
        \\
    , out.written());

    out.clearRetainingCapacity();
    try manPage(&out.writer, &.{&topic_root});
    try testing.expect(std.mem.indexOf(u8, out.written(), ".SH SEE ALSO\n\\fBapp\\-get\\fR(1),\n" ++
        "\\fBapp\\-environment\\fR(1)\n") != null);
}

test "a man page lists the variables its options read" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const set = &deep_root.subcommands[0].subcommands[0];
    try manPage(&out.writer, &.{ &deep_root, &deep_root.subcommands[0], set });
    try testing.expect(std.mem.indexOf(u8, out.written(), "Access token (env APP_TOKEN)\n" ++
        ".SH ENVIRONMENT\n.TP\n\\fBAPP_TOKEN\\fR\nAccess token\n.SH EXAMPLES") != null);
}

test "writeManTree writes one file per command" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManTree(testing.io, tmp.dir, &topic_root, .{});
    for ([_][]const u8{ "app.1", "app-get.1", "app-environment.1" }) |name| {
        const page = try tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
        defer testing.allocator.free(page);
        try testing.expect(std.mem.startsWith(u8, page, ".TH \""));
    }
}

test "html: escaped, with a table of contents and one section per command" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &topic_root, .html, .{});
    const page = out.written();
    try testing.expect(std.mem.startsWith(u8, page, "<!doctype html>\n"));
    try testing.expect(std.mem.endsWith(u8, page, "</main>\n</body>\n</html>\n"));
    try testing.expect(std.mem.indexOf(u8, page, "<li><a href=\"#app-get\">get</a></li>") != null);
    const section = "<section id=\"app-get\">\n<h2>app get</h2>";
    try testing.expect(std.mem.indexOf(u8, page, section) != null);
    try testing.expect(std.mem.indexOf(u8, page, "<p>Print &lt;a&gt; value</p>") != null);
    try testing.expect(std.mem.indexOf(u8, page, "No &quot;decoration&quot; &amp; more") != null);
    try testing.expect(std.mem.indexOf(u8, page, "<pre>APP_HOME  data</pre>") != null);
}

test "html: a style sheet replaces the inline styles" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &topic_root, .html, .{ .stylesheet = "../a&b.css" });
    const page = out.written();
    const link = "</title>\n<link rel=\"stylesheet\" href=\"../a&amp;b.css\">\n</head>\n<body>\n";
    try testing.expect(std.mem.indexOf(u8, page, link) != null);
    try testing.expect(std.mem.indexOf(u8, page, "<style>") == null);
}

test "markdown: a topic is its text" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &topic_root, .markdown, .{});
    try testing.expect(std.mem.endsWith(
        u8,
        out.written(),
        "## app environment\n\n```\nAPP_HOME  data\n```\n\n",
    ));
}

const arguments_root = spec.command(.{
    .name = "app",
    .flags = flags: {
        const T = struct {
            token: []const u8 = "hunter2",
        };
        break :flags sets.flags(
            T,
            field.Set(
                .{
                    field.Spec(T){ .fields = .{
                        .token = .{ .secret = true, .help = "API token" },
                    } },
                },
            ),
            .{},
        );
    },
    .args = args: {
        const T = struct {
            source: []const u8,
            target: ?[]const u8 = null,
        };
        break :args sets.args(
            T,
            field.Set(.{field.Spec(T){ .fields = .{ .source = .{ .help = "File to copy" } } }}),
            .{},
        );
    },
    .run = noop,
});

fn document(format: Format) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, &arguments_root, format, .{});
    return out.toOwnedSlice();
}

test "every format lists typed positionals and redacts a secret's default" {
    inline for (.{ Format.markdown, Format.html, Format.man, Format.json }) |format| {
        const page = try document(format);
        defer testing.allocator.free(page);
        try testing.expect(std.mem.indexOf(u8, page, "hunter2") == null);
        if (format != .man) try testing.expect(std.mem.indexOf(u8, page, "redacted") != null);
    }
    const markdown_page = try document(.markdown);
    defer testing.allocator.free(markdown_page);
    const table =
        \\| Argument | Description |
        \\|---|---|
        \\| `source` | File to copy (required) |
        \\| `target` |  |
        \\
    ;
    try testing.expect(std.mem.indexOf(u8, markdown_page, table) != null);
    try testing.expect(std.mem.indexOf(u8, markdown_page, "| `<redacted>` |") != null);

    const html_page = try document(.html);
    defer testing.allocator.free(html_page);
    const row = "<tr><td><code>source</code></td><td>File to copy (required)</td></tr>";
    try testing.expect(std.mem.indexOf(u8, html_page, row) != null);
    try testing.expect(std.mem.indexOf(u8, html_page, "<code>&lt;redacted&gt;</code>") != null);

    const man_page = try document(.man);
    defer testing.allocator.free(man_page);
    const entry = ".TP\n\\fIsource\\fR\nFile to copy (required)\n";
    try testing.expect(std.mem.indexOf(u8, man_page, entry) != null);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try manPage(&out.writer, &.{&arguments_root});
    const section = "\n.SH ARGUMENTS\n.TP\n\\fIsource\\fR\nFile to copy (required)\n.TP\n" ++
        "\\fItarget\\fR\n\n.SH OPTIONS";
    try testing.expect(std.mem.indexOf(u8, out.written(), section) != null);
}

test "an exit status section in every format but JSON, only when given" {
    const statuses = [_]ExitStatus{
        .{ .code = 0, .meaning = "Success" },
        .{ .code = 3, .meaning = "Disk <full>" },
    };
    const Expected = struct { Format, []const u8 };
    for ([_]Expected{
        .{ .markdown, "## Exit status\n\n| Status | Meaning |\n|---|---|\n| `0` | Success |\n" ++
            "| `3` | Disk &lt;full&gt; |\n\n" },
        .{ .man, "\n.SH EXIT STATUS\n.TP\n\\fB0\\fR\nSuccess\n.TP\n\\fB3\\fR\nDisk <full>\n" },
        .{ .html, "<tr><td><code>3</code></td><td>Disk &lt;full&gt;</td></tr>\n</table>\n" ++
            "</section>\n</main>\n" },
    }) |case| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try write(&out.writer, &topic_root, case[0], .{ .exit_statuses = &statuses });
        try testing.expect(std.mem.indexOf(u8, out.written(), case[1]) != null);
        var plain: Writer.Allocating = .init(testing.allocator);
        defer plain.deinit();
        try write(&plain.writer, &topic_root, case[0], .{});
        try testing.expect(std.mem.indexOf(u8, plain.written(), "xit status") == null);
        try testing.expect(std.mem.indexOf(u8, plain.written(), "EXIT STATUS") == null);
    }
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &topic_root, .json, .{ .exit_statuses = &statuses });
    try testing.expect(std.mem.indexOf(u8, out.written(), "Disk") == null);

    var page: Writer.Allocating = .init(testing.allocator);
    defer page.deinit();
    try manPageWith(&page.writer, &.{&deep_root}, .{ .exit_statuses = statuses[0..1] });
    try testing.expect(std.mem.indexOf(u8, page.written(), "\n.SH EXIT STATUS\n.TP\n" ++
        "\\fB0\\fR\nSuccess\n.SH ") != null);
}

const statuses_root = spec.command(.{
    .name = "app",
    .subcommands = .{spec.command(.{
        .name = "sync",
        .exit_statuses = &.{
            .{ .code = 1, .meaning = "The sync failed" },
            .{ .code = 4, .meaning = "Partly synced" },
        },
        .run = noop,
    })},
});

test "a command's own exit statuses: in its section, and merged into its man page" {
    const app_statuses = [_]ExitStatus{
        .{ .code = 0, .meaning = "Success" },
        .{ .code = 1, .meaning = "Failure" },
    };
    var single: Writer.Allocating = .init(testing.allocator);
    defer single.deinit();
    try write(&single.writer, &statuses_root, .man, .{});
    try testing.expect(std.mem.indexOf(u8, single.written(), ".SS \"app sync\"\n" ++
        ".PP\nExit status:\n.TP\n\\fB1\\fR\nThe sync failed\n.TP\n\\fB4\\fR\n" ++
        "Partly synced\n") != null);
    var md: Writer.Allocating = .init(testing.allocator);
    defer md.deinit();
    try write(&md.writer, &statuses_root, .markdown, .{});
    try testing.expect(std.mem.indexOf(u8, md.written(), "Exit status:\n\n| Status | " ++
        "Meaning |\n|---|---|\n| `1` | The sync failed |\n| `4` | Partly synced |\n") != null);
    var page: Writer.Allocating = .init(testing.allocator);
    defer page.deinit();
    const path = [_]*const Command{ &statuses_root, &statuses_root.subcommands[0] };
    try manPageWith(&page.writer, &path, .{ .exit_statuses = &app_statuses });
    try testing.expect(std.mem.indexOf(u8, page.written(), "\n.SH EXIT STATUS\n.TP\n" ++
        "\\fB0\\fR\nSuccess\n.TP\n\\fB1\\fR\nThe sync failed\n.TP\n\\fB4\\fR\n" ++
        "Partly synced\n") != null);
}

const cli_testing = @import("testing.zig");

const mounted_root = spec.command(.{
    .name = "app",
    .summary = "An app",
    .subcommands = .{ command, spec.command(.{ .name = "get", .run = noop }) },
});

test "command documents the tree it is mounted in, with the app's exit statuses" {
    const app: App = .{
        .root = &mounted_root,
        .color_flag = true,
        .exit_statuses = &.{
            .{ .code = 3, .meaning = "Nothing to do" },
            .{ .code = 1, .meaning = "Deploy failed" },
        },
    };
    const r = try cli_testing.run(app, &.{ "docs", "-f", "man" }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("", r.err);
    // `completion` and `--color` come from `App`, not from `mounted_root`.
    try testing.expect(std.mem.indexOf(u8, r.out, ".SS \"app completion\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "\\fB\\-\\-color") != null);
    const section = ".SH EXIT STATUS\n.TP\n\\fB0\\fR\nSuccess\n.TP\n\\fB1\\fR\nDeploy failed\n" ++
        ".TP\n\\fB2\\fR\nUsage error: an unknown command or flag, or a bad value\n.TP\n" ++
        "\\fB3\\fR\nNothing to do\n.TP\n\\fB130\\fR\nInterrupted (Ctrl\\-C)\n";
    try testing.expect(std.mem.endsWith(u8, r.out, section));

    const plugged: App = .{ .root = &mounted_root, .plugins = "app-" };
    const markdown_page = try cli_testing.run(plugged, &.{"docs"}, .{});
    defer markdown_page.deinit();
    try testing.expect(std.mem.indexOf(u8, markdown_page.out, "| `126` |") != null);

    const misused = try cli_testing.run(app, &.{ "docs", "--dir", "x" }, .{});
    defer misused.deinit();
    try misused.expect(2, "", "app: --dir applies to --format man\n" ++
        "Run 'app docs --help' for usage.\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const pages = try std.fs.path.join(testing.allocator, &.{ dir, "man1" });
    defer testing.allocator.free(pages);
    const tree = try cli_testing.run(app, &.{ "docs", "-f", "man", "-d", pages }, .{});
    defer tree.deinit();
    try tree.expect(0, "", "");
    const get = try tmp.dir.readFileAlloc(
        testing.io,
        "man1/app-get.1",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(get);
    try testing.expect(std.mem.indexOf(u8, get, "\n.SH EXIT STATUS\n") != null);
}
