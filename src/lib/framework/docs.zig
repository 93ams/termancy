//! Command documentation generation: Markdown, man pages and HTML.
//!
//! Split out of `cli.zig` (ROADMAP S-1/S-3/S-4). Everything here is a pure function of a
//! command *type* and a writer: no `Ctx`, no allocation, no I/O beyond writing. The three
//! generators walk the same command tree and differ only in framing, which is why they live
//! together and why they came out as one block.
//!
//! They are free functions rather than declarations inside the `App` closure because none of
//! them needs `StateT` - the closure's only reason to exist.

const std = @import("std");
const platform = @import("platform");

/// Executes a given command tree with the provided arguments.
pub fn GetFlagsType(comptime CmdType: type) type {
    if (@hasField(CmdType, "Flags")) {
        return @field(CmdType, "Flags");
    }
    if (@hasField(CmdType, "run") and @TypeOf(@field(@as(CmdType, undefined), "run")) != @TypeOf(null)) {
        comptime var run_info = @typeInfo(@TypeOf(@field(@as(CmdType, undefined), "run")));
        if (run_info == .optional) run_info = @typeInfo(run_info.optional.child);
        if (run_info == .pointer) run_info = @typeInfo(run_info.pointer.child);
        if (run_info == .@"fn") {
            return run_info.@"fn".params[1].type.?;
        }
    }
    return struct {};
}
/// Whether this command declares subcommands.
///
/// Probed as both a decl and a field because the two shapes are both live:
/// `CommandWithReturn` emits a decl, and a hand-written command may use either.
/// The existing `SubcommandsType`/`getSubcommands` helpers depend on these two.
///
/// "Declares the slot" is not "has any": a leaf built by `LeafCommand` carries
/// an *empty* tuple, which is a declared slot with nothing in it. Everything
/// that lists or advertises subcommands must use `hasAnySubcommands` instead,
/// or a leaf prints `Usage: x [command]`.
pub fn hasSubcommands(comptime CmdType: type) bool {
    return @hasDecl(CmdType, "subcommands") or @hasField(CmdType, "subcommands");
}
/// The number of subcommands actually present, which for a leaf is zero.
fn subcommandCount(comptime CmdType: type) usize {
    if (comptime !hasSubcommands(CmdType)) return 0;
    return std.meta.fields(SubcommandsType(CmdType)).len;
}
/// Whether this command actually has anything to route to.
pub fn hasAnySubcommands(comptime CmdType: type) bool {
    return subcommandCount(CmdType) > 0;
}
pub fn SubcommandsType(comptime CmdType: type) type {
    if (comptime @hasDecl(CmdType, "subcommands")) return @TypeOf(CmdType.subcommands);
    if (comptime @hasField(CmdType, "subcommands")) return @TypeOf(@as(CmdType, undefined).subcommands);
    return @TypeOf(.{});
}
pub fn emitPowershellCompletions(writer: anytype, prog: []const u8) !void {
    try writer.writeAll("Register-ArgumentCompleter -Native -CommandName ");
    try writer.writeAll(prog);
    try writer.writeAll(" -ScriptBlock {\n");
    try writer.writeAll("  param($wordToComplete, $commandAst, $cursorPosition)\n  ");
    try writer.writeAll(prog);
    try writer.writeAll(" __complete $commandAst.ToString().Split(' ')[1..99] |\n");
    try writer.writeAll("    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }\n}\n");
}

/// Renders the command tree as a man page.
///
/// `writeMarkdownDocs` already walks the same tree, so only the framing differs - the
/// section headers and the `.SH`/`.TP` macros a man reader expects.
/// Renders the command tree as a man page.
///
/// The same tree walk `writeMarkdownDocs` does, in man macros. It carries the
/// same three sections a reader expects - COMMANDS, ARGUMENTS and OPTIONS - and
/// it recurses: a man page that stopped at the immediate children would hide the
/// whole point of a nested CLI, and one with no OPTIONS section would document
/// the synopsis and nothing about how to use it.
pub fn writeManPage(comptime cmd: anytype, writer: anytype) !void {
    const CmdType = @TypeOf(cmd);
    if (@hasField(CmdType, "description") and cmd.description.len > 0) {
        try writer.print(".TH {s} 1\n.SH NAME\n{s} - {s}\n.SH SYNOPSIS\n.B {s}\n[command] [flags] [args]\n", .{
            cmd.name, cmd.name, cmd.description, cmd.name,
        });
    } else {
        // A command with no description gets no ` - ` separator rather than a
        // dangling one.
        try writer.print(".TH {s} 1\n.SH NAME\n{s}\n.SH SYNOPSIS\n.B {s}\n[command] [flags] [args]\n", .{
            cmd.name, cmd.name, cmd.name,
        });
    }
    try writeManSections(cmd, writer, .top);

    if (comptime hasAnySubcommands(CmdType)) {
        inline for (getSubcommands(cmd)) |sub| {
            if (comptime !isHidden(@TypeOf(sub), sub)) {
                try writer.print(".SS {s}\n", .{sub.name});
                try writeManSubtree(sub, writer);
            }
        }
    }
}

/// Writes a command's deprecation and feature notes, if it has any.
///
/// The documentation generators have no `Ctx`, so they cannot evaluate a feature
/// gate the way routing and `--help` do. They describe the whole surface instead
/// and say which parts are conditional - which is what a generated reference is
/// for, and why a deprecated command is listed here while `--help` omits it.
pub fn writeCommandMarkers(comptime CmdT: type, cmd: CmdT, writer: anytype) !void {
    if (comptime @hasField(CmdT, "deprecated")) {
        if (cmd.deprecated.len > 0) try writer.print(" (deprecated: {s})", .{cmd.deprecated});
    }
    if (comptime @hasField(CmdT, "feature")) {
        if (cmd.feature.len > 0) try writer.print(" (experimental: set {s})", .{cmd.feature});
    }
}

/// The same, for a flag.
pub fn writeFlagMarkers(comptime OrigFlagsT: type, comptime name: []const u8, writer: anytype) !void {
    if (comptime hasMetaField(OrigFlagsT, name) and
        @hasField(@TypeOf(@field(OrigFlagsT.meta, name)), "feature"))
    {
        const gate = @field(OrigFlagsT.meta, name).feature;
        if (gate.len > 0) try writer.print(" (experimental: set {s})", .{gate});
    }
}

/// Escapes the five characters that would otherwise be markup.
///
/// The output is a document and a command description is user-written text: an
/// unescaped `&` or `<` in a description turns the rest of the page into tag soup.
pub fn writeHtmlEscaped(writer: anytype, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(ch),
        }
    }
}

/// Whether a command appears in the HTML reference.
///
/// The generators have no `Ctx`, so they cannot evaluate a feature gate - they
/// document a gated command with the variable that opens it. Hiding is different: a
/// hidden command is private, and no generated document should name it.
pub fn isAdvertisableHtml(comptime CmdT: type, cmd: CmdT) bool {
    return !isHidden(CmdT, cmd);
}

/// Renders the command tree as a standalone HTML document.
///
/// One page for the whole tree rather than one per command: a single file can be
/// opened, searched and published without a server, which is what a CLI's
/// documentation usually needs. The styling is inline so the file is
/// self-contained.
pub fn writeHtmlDocs(comptime cmd: anytype, writer: anytype) !void {
    try writer.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>");
    try writeHtmlEscaped(writer, cmd.name);
    try writer.writeAll(
        \\</title>
        \\<style>
        \\  body { font-family: system-ui, sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
        \\  code { background: #f2f2f2; padding: 0.1rem 0.3rem; border-radius: 3px; }
        \\  table { border-collapse: collapse; margin: 0.5rem 0 1.5rem; }
        \\  th, td { border: 1px solid #ccc; padding: 0.25rem 0.6rem; text-align: left; }
        \\  section { margin-bottom: 2.5rem; }
        \\  p.desc { font-style: italic; }
        \\</style>
        \\</head>
        \\<body>
        \\
    );
    try writeHtmlCommand(cmd, writer, 1);
    try writer.writeAll("</body>\n</html>\n");
}

/// One command's section, then its subcommands', recursively.
///
/// Hidden commands are omitted; deprecated and feature-gated ones are documented
/// with their note, because a generated reference describes the whole surface
/// rather than only the part this process can reach.
pub fn writeHtmlCommand(comptime cmd: anytype, writer: anytype, level: usize) !void {
    const CmdType = @TypeOf(cmd);
    const heading: usize = @min(level, 6);

    try writer.writeAll("<section id=\"");
    try writeHtmlEscaped(writer, cmd.name);
    try writer.writeAll("\">\n<h");
    try writer.print("{d}>", .{heading});
    try writeHtmlEscaped(writer, cmd.name);
    try writer.print("</h{d}>\n", .{heading});

    if (@hasField(CmdType, "description") and cmd.description.len > 0) {
        try writer.writeAll("<p class=\"desc\">");
        try writeHtmlEscaped(writer, cmd.description);
        try writer.writeAll("</p>\n");
    }
    try writer.writeAll("<p><code>");
    try writeHtmlEscaped(writer, cmd.name);
    if (comptime hasAnySubcommands(CmdType)) try writer.writeAll(" [command]");
    if (comptime declaresPositionals(CmdType)) try writer.writeAll(" [args]");
    try writer.writeAll(" [flags]</code></p>\n");

    const ArgsT = PositionalType(CmdType);
    const runs_flags = GetFlagsType(CmdType);
    const orig_flags = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else runs_flags;

    if (comptime std.meta.fields(ArgsT).len > 0) {
        try writer.writeAll("<h4>Arguments</h4>\n<table>\n<tr><th>Argument</th><th>Required</th><th>Description</th></tr>\n");
        inline for (std.meta.fields(ArgsT)) |p_field| {
            try writer.writeAll("<tr><td><code>");
            try writeHtmlEscaped(writer, p_field.name);
            try writer.writeAll("</code></td><td>");
            const required = comptime p_field.default_value_ptr == null and
                @typeInfo(p_field.type) != .optional;
            try writer.writeAll(if (required) "yes" else "no");
            try writer.writeAll("</td><td>");
            if (comptime positionalHelp(ArgsT, orig_flags, p_field.name)) |text| {
                try writeHtmlEscaped(writer, text);
            }
            try writer.writeAll("</td></tr>\n");
        }
        try writer.writeAll("</table>\n");
    }

    if (runs_flags != void) {
        var any_options = false;
        inline for (std.meta.fields(runs_flags)) |field| {
            if (comptime !isFrameworkField(field.name) and !isPositionalField(field.name)) {
                any_options = true;
            }
        }
        if (any_options) {
            try writer.writeAll("<h4>Flags</h4>\n<table>\n<tr><th>Flag</th><th>Type</th><th>Default</th><th>Description</th></tr>\n");
            inline for (std.meta.fields(runs_flags)) |field| {
                if (comptime !isFrameworkField(field.name) and !isPositionalField(field.name)) {
                    try writer.writeAll("<tr><td><code>--");
                    try writeFlagSpelling(writer, field.name);
                    if (comptime hasShortFlag(orig_flags, field.name)) {
                        try writer.print(", -{c}", .{@field(orig_flags.meta, field.name).short});
                    }
                    try writer.writeAll("</code>");
                    try writeFlagMarkers(orig_flags, field.name, writer);
                    try writer.writeAll("</td><td><code>");
                    try writeHtmlEscaped(writer, @typeName(field.type));
                    try writer.writeAll("</code></td><td>");
                    if (comptime isSecretFlag(orig_flags, field.name)) {
                        // Same rule as `--help`: a secret's default is a secret.
                        try writer.writeAll(platform.log.redaction_mask);
                    } else if (field.default_value_ptr) |def| {
                        const default_value = @as(*align(1) const field.type, @ptrCast(def)).*;
                        if (comptime isRepeatableField(field.type)) {
                            try writer.writeAll("-");
                        } else if (comptime field.type == []const u8) {
                            try writeHtmlEscaped(writer, default_value);
                        } else {
                            var buf: [64]u8 = undefined;
                            const rendered = std.fmt.bufPrint(&buf, "{any}", .{default_value}) catch "-";
                            try writeHtmlEscaped(writer, rendered);
                        }
                    } else {
                        try writer.writeAll("required");
                    }
                    try writer.writeAll("</td><td>");
                    if (comptime hasFieldHelp(orig_flags, field.name)) {
                        try writeHtmlEscaped(writer, @field(orig_flags.meta, field.name).help);
                    }
                    try writer.writeAll("</td></tr>\n");
                }
            }
            try writer.writeAll("</table>\n");
        }
    }

    if (comptime hasAnySubcommands(CmdType)) {
        inline for (getSubcommands(cmd)) |sub| {
            if (isAdvertisableHtml(@TypeOf(sub), sub)) {
                try writer.writeAll("<p><a href=\"#");
                try writeHtmlEscaped(writer, sub.name);
                try writer.writeAll("\"><code>");
                try writeHtmlEscaped(writer, sub.name);
                try writer.writeAll("</code></a> - ");
                try writeHtmlEscaped(writer, sub.description);
                try writer.writeAll("</p>\n");
            }
        }
    }
    try writer.writeAll("</section>\n");

    if (comptime hasAnySubcommands(CmdType)) {
        inline for (getSubcommands(cmd)) |sub| {
            if (isAdvertisableHtml(@TypeOf(sub), sub)) {
                try writeHtmlCommand(sub, writer, level + 1);
            }
        }
    }
}

/// A subcommand's entry: its description, its sections, then its own children.
pub fn writeManSubtree(comptime cmd: anytype, writer: anytype) !void {
    const CmdType = @TypeOf(cmd);
    if (@hasField(CmdType, "description") and cmd.description.len > 0) {
        try writer.print("{s}\n", .{cmd.description});
    }
    try writeManSections(cmd, writer, .nested);

    if (comptime hasAnySubcommands(CmdType)) {
        inline for (getSubcommands(cmd)) |sub| {
            if (comptime !isHidden(@TypeOf(sub), sub)) {
                try writer.print(".SS {s}\n", .{sub.name});
                try writeManSubtree(sub, writer);
            }
        }
    }
}

/// Where a command sits in the page: `man` has exactly two useful levels, so a
/// subcommand's sections are labelled paragraphs rather than `.SH` headings -
/// a `.SH` inside a `.SS` would silently jump back to the top level.
pub const ManLevel = enum { top, nested };

fn writeManHeading(writer: anytype, comptime level: ManLevel, comptime title: []const u8) !void {
    if (comptime level == .top) {
        try writer.print(".SH {s}\n", .{title});
    } else {
        try writer.print(".PP\n{s}:\n", .{title});
    }
}

/// One command's COMMANDS, ARGUMENTS and OPTIONS sections.
///
/// Deprecated flags are omitted for the same reason `--help` omits them: they
/// work, and documenting them would present them as current.
pub fn writeManSections(comptime cmd: anytype, writer: anytype, comptime level: ManLevel) !void {
    const CmdType = @TypeOf(cmd);

    if (comptime hasAnySubcommands(CmdType)) {
        try writeManHeading(writer, level, "COMMANDS");
        inline for (getSubcommands(cmd)) |sub| {
            if (comptime !isHidden(@TypeOf(sub), sub)) {
                try writer.print(".TP\n.B {s}\n{s}", .{ sub.name, sub.description });
                try writeCommandMarkers(@TypeOf(sub), sub, writer);
                try writer.writeAll("\n");
                if (@hasField(@TypeOf(sub), "aliases")) {
                    for (sub.aliases, 0..) |alias_name, alias_idx| {
                        // Fragments, not a conditional format string: `print`
                        // needs its format at comptime and `alias_idx` is runtime.
                        try writer.writeAll(if (alias_idx == 0) "(alias: " else ", ");
                        try writer.print("{s}", .{alias_name});
                    }
                    if (sub.aliases.len > 0) try writer.writeAll(")\n");
                }
            }
        }
    }

    const ArgsT = PositionalType(CmdType);
    const runs_flags = GetFlagsType(CmdType);
    const orig_flags = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else runs_flags;

    if (comptime std.meta.fields(ArgsT).len > 0) {
        try writeManHeading(writer, level, "ARGUMENTS");
        inline for (std.meta.fields(ArgsT)) |p_field| {
            try writer.print(".TP\n.B {s}\n", .{p_field.name});
            if (comptime positionalHelp(ArgsT, orig_flags, p_field.name)) |text| {
                try writer.print("{s}\n", .{text});
            }
            if (comptime p_field.default_value_ptr == null and @typeInfo(p_field.type) != .optional) {
                try writer.writeAll("(required)\n");
            }
        }
    }

    if (runs_flags != void) {
        var any_options = false;
        inline for (std.meta.fields(runs_flags)) |field| {
            if (comptime !isFrameworkField(field.name) and
                !isPositionalField(field.name) and
                !isDeprecatedFlag(orig_flags, field.name))
            {
                any_options = true;
            }
        }

        if (any_options) {
            try writeManHeading(writer, level, "OPTIONS");
            inline for (std.meta.fields(runs_flags)) |field| {
                if (comptime !isFrameworkField(field.name) and
                    !isPositionalField(field.name) and
                    !isDeprecatedFlag(orig_flags, field.name))
                {
                    try writer.writeAll(".TP\n.B --");
                    try writeFlagSpelling(writer, field.name);
                    if (comptime hasShortFlag(orig_flags, field.name)) {
                        try writer.print(", -{c}", .{@field(orig_flags.meta, field.name).short});
                    }
                    try writer.writeAll("\n");
                    if (comptime hasFieldHelp(orig_flags, field.name)) {
                        try writer.print("{s}\n", .{@field(orig_flags.meta, field.name).help});
                    }
                    if (comptime isSecretFlag(orig_flags, field.name)) {
                        try writer.print("(default: {s})\n", .{platform.log.redaction_mask});
                    } else if (field.default_value_ptr) |def| {
                        const default_value = @as(*align(1) const field.type, @ptrCast(def)).*;
                        if (comptime !isRepeatableField(field.type) and field.type == []const u8) {
                            try writer.print("(default: {s})\n", .{default_value});
                        } else if (comptime !isRepeatableField(field.type)) {
                            try writer.print("(default: {any})\n", .{default_value});
                        }
                    } else if (comptime @typeInfo(field.type) != .optional and field.type != bool) {
                        try writer.writeAll("(required)\n");
                    }
                    try writeFlagMarkers(orig_flags, field.name, writer);
                    try writer.writeAll("\n");
                }
            }
        }
    }
}

/// Whether a field name is framework-internal rather than a user's flag.
/// Whether a flags field is the slot that holds positional arguments rather than a flag.
///
/// Duplicated from `cli.zig` deliberately: it is one `std.mem.eql` pair, and the alternative -
/// re-exporting it back and forth across a file boundary - would make both files harder to read
/// than the duplication costs.
pub fn isPositionalField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "positionals") or std.mem.eql(u8, name, "Positional");
}

pub fn isFrameworkField(comptime name: []const u8) bool {
    return name.len >= 2 and name[0] == '_' and name[1] == '_';
}
/// Whether a flag needs a value on the command line.
pub fn fieldTakesValue(comptime T: type) bool {
    if (T == bool) return false;
    if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == bool) return false;
    return true;
}
/// Whether a field carries a documented short form.
pub fn hasShortFlag(comptime OrigFlagsT: type, comptime name: []const u8) bool {
    if (!@hasDecl(OrigFlagsT, "meta")) return false;
    if (!@hasField(@TypeOf(OrigFlagsT.meta), name)) return false;
    return @hasField(@TypeOf(@field(OrigFlagsT.meta, name)), "short");
}
/// The type of a command's positional-argument struct, however it declared one.
pub fn PositionalType(comptime CmdType: type) type {
    if (@hasDecl(CmdType, "PositionalArgsT")) return CmdType.PositionalArgsT;
    const FT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else GetFlagsType(CmdType);
    if (@hasField(FT, "positionals")) return @TypeOf(@as(FT, undefined).positionals);
    if (@hasField(FT, "Positional")) return @TypeOf(@as(FT, undefined).Positional);
    return struct {};
}
/// The documented text for one positional argument, or null.
///
/// The args struct's own `meta` is consulted first - that is where a
/// `command`-registered command documents its arguments, next to the fields they
/// describe. The flags type's positional slot is the fallback, because that is
/// where the older `positionals: struct { ... }` spelling put it.
pub fn positionalHelp(comptime ArgsT: type, comptime OrigFlagsT: type, comptime name: []const u8) ?[]const u8 {
    if (@hasDecl(ArgsT, "meta")) {
        const args_meta = ArgsT.meta;
        if (@hasField(@TypeOf(args_meta), name)) {
            const entry = @field(args_meta, name);
            if (@hasField(@TypeOf(entry), "help")) return entry.help;
            if (@hasField(@TypeOf(entry), "description")) return entry.description;
        }
    }
    if (!@hasDecl(OrigFlagsT, "meta")) return null;
    const meta_block = OrigFlagsT.meta;
    const slot_name = if (@hasField(@TypeOf(meta_block), "positionals"))
        "positionals"
    else if (@hasField(@TypeOf(meta_block), "Positional"))
        "Positional"
    else
        return null;
    const slot_meta = @field(meta_block, slot_name);
    if (@hasField(@TypeOf(slot_meta), name)) {
        const entry = @field(slot_meta, name);
        if (@hasField(@TypeOf(entry), "help")) return entry.help;
        if (@hasField(@TypeOf(entry), "description")) return entry.description;
    }
    // The older spelling documents the slot as a whole rather than each field
    // (`meta.positionals.description`), which is what every `src/app/cmd/config` command
    // does. It is only unambiguous when there is one positional argument, so
    // that is the only case it is used for.
    if (comptime std.meta.fields(ArgsT).len == 1) {
        if (@hasField(@TypeOf(slot_meta), "help")) return slot_meta.help;
        if (@hasField(@TypeOf(slot_meta), "description")) return slot_meta.description;
    }
    return null;
}
/// Whether a field's metadata carries `help`.
pub fn hasFieldHelp(comptime OrigFlagsT: type, comptime name: []const u8) bool {
    if (!@hasDecl(OrigFlagsT, "meta")) return false;
    if (!@hasField(@TypeOf(OrigFlagsT.meta), name)) return false;
    return @hasField(@TypeOf(@field(OrigFlagsT.meta, name)), "help");
}

// --- Shared with `cli.zig` ---------------------------------------------------------------
//
// These four are used by both the generators here and the framework's own routing and help, so
// they cannot live only in one file. They are here rather than in `cli.zig` because they are
// pure functions of a command *type* - the property that let them leave the `App` closure at
// all - and `cli.zig` re-exports them for its own use.
pub fn getSubcommands(cmd: anytype) SubcommandsType(@TypeOf(cmd)) {
    const CT = @TypeOf(cmd);
    if (comptime @hasDecl(CT, "subcommands")) return CT.subcommands;
    if (comptime @hasField(CT, "subcommands")) return cmd.subcommands;
    return .{};
}
/// Whether a subcommand is routable but must not be advertised.
///
/// Checked on the type rather than the value because `inline for` over a tuple
/// yields values whose type is what carries the field; a hand-written command
/// without the field is simply not hidden.
pub fn isHidden(comptime SubT: type, sub: SubT) bool {
    if (comptime !@hasField(SubT, "hidden")) return false;
    return sub.hidden;
}
/// Whether the command's flags declare positional arguments.
///
/// Two spellings are accepted (`positionals` and `Positional`) because the
/// framework reads either; the rule this feeds is that a command with nowhere to
/// put an argument must reject one rather than silently drop it.
///
/// A `command`-registered command declares them in its metadata instead, and
/// they are parsed into the flags type the framework builds - so the marker on
/// the command type is what answers here.
pub fn declaresPositionals(comptime CmdType: type) bool {
    if (comptime @hasDecl(CmdType, "PositionalArgsT")) {
        return std.meta.fields(CmdType.PositionalArgsT).len > 0;
    }
    const FT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else GetFlagsType(CmdType);
    if (FT == void) return false;
    return @hasField(FT, "positionals") or @hasField(FT, "Positional");
}
/// Whether a field carries any metadata of its own.
pub fn hasMetaField(comptime OrigFlagsT: type, comptime name: []const u8) bool {
    return @hasDecl(OrigFlagsT, "meta") and @hasField(@TypeOf(OrigFlagsT.meta), name);
}

/// Whether a field carries a `.deprecated` note.
///
/// Absent metadata means "not deprecated", so an undeclared flag never warns.
pub fn isDeprecatedFlag(comptime OrigFlagsT: type, comptime name: []const u8) bool {
    if (!@hasDecl(OrigFlagsT, "meta")) return false;
    const mb = OrigFlagsT.meta;
    if (!@hasField(@TypeOf(mb), name)) return false;
    const fm = @field(mb, name);
    return @hasField(@TypeOf(fm), "deprecated");
}
/// The command-line spelling of a field: `dry_run` is typed `--dry-run`.
///
/// GNU convention, and it costs nothing to accept both - the matcher treats `-`
/// and `_` as the same character, so an existing script written either way keeps
/// working. Rendering goes through this helper so help, errors, suggestions and
/// completions cannot disagree about the spelling.
pub fn writeFlagSpelling(writer: anytype, name: []const u8) !void {
    for (name) |ch| {
        try writer.writeByte(if (ch == '_') '-' else ch);
    }
}

/// Whether a field collects every occurrence of its flag instead of replacing
/// its value.
///
/// The rule is the element type: a slice of `u8` is a *string* - the historical
/// and still the common case - and any other slice is a collection. So
/// `[]const []const u8` is a list of strings (`-H a -H b`) and `[]const u16` is
/// a list of ports.
pub fn isRepeatableField(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    if (info.pointer.size != .slice) return false;
    return info.pointer.child != u8;
}
/// Whether a flag's metadata declares it secret.
pub fn isSecretFlag(comptime OrigFlagsT: type, comptime name: []const u8) bool {
    if (!@hasDecl(OrigFlagsT, "meta")) return false;
    if (!@hasField(@TypeOf(OrigFlagsT.meta), name)) return false;
    const entry = @field(OrigFlagsT.meta, name);
    if (!@hasField(@TypeOf(entry), "secret")) return false;
    return entry.secret;
}
