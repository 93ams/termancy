//! Command-line parsing: argv -> the command path, flag occurrences, and positionals.
//!
//! One pass, GNU style: flags and positionals may be interleaved, `--` ends flags, and
//! flags may appear before the subcommand they belong to as long as they are visible at that
//! point (a parent's persistent flags). After the pass, every flag must be visible from the
//! final command, environment fallbacks are applied, and requirements are checked.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const text = @import("text.zig");
const Messages = @import("Messages.zig");

/// Deeper command trees than this are rejected rather than recorded unbounded.
pub const max_depth = 32;

/// Where an occurrence came from: the command line, a variable, or `App.defaults`.
pub const Source = enum { argv, env, config };

/// Where flags absent from the command line and the environment get their values next:
/// a configuration file, usually, read by `cfg` (see `App.defaults`).
pub const Defaults = struct {
    context: ?*anyopaque = null,
    /// The value for `flag` of the command `path`, as it would be written on the command
    /// line (`"true"` for a switch, a number for a counter), or null. The text must outlive
    /// the run.
    lookup: *const fn (
        context: ?*anyopaque,
        path: []const *const Command,
        flag: *const Flag,
    ) ?[]const u8,
    /// How messages name where a bad value came from, such as the file's name.
    name: []const u8 = "config",

    /// Defaults from a configuration such as a `cfg.Config`; see `defaults.zig`.
    pub const from = @import("defaults.zig").from;
};

/// One value given for a flag.
pub const Occurrence = struct {
    flag: *const Flag,
    /// `"true"`/`"false"` for booleans, `""` for counters (the count, when the source is
    /// `env`), the text otherwise.
    value: []const u8,
    source: Source,
};

/// A parsed command line.
pub const Result = struct {
    /// Root first, the command to run last.
    path: []const *const Command,
    occurrences: []const Occurrence,
    positionals: []const []const u8,
    /// The words after `--` for a command with `args.passthrough`.
    passthrough: []const []const u8 = &.{},
    /// `-h` or `--help` was given; nothing was validated.
    help: bool = false,
    /// `--version` or `-V` was given on the root; nothing was validated.
    version: bool = false,
    /// Notices for deprecated commands and flags that were used.
    warnings: []const []const u8 = &.{},
    /// `-q`/`--quiet` was given: the caller should not print warnings.
    quiet: bool = false,
    /// Required flags left for the caller to ask for (`Options.promptable`).
    missing: []const *const Flag = &.{},

    /// The command to run.
    pub fn leaf(result: Result) *const Command {
        return result.path[result.path.len - 1];
    }
};

/// What went wrong, for the user. Both strings live in the parse arena.
pub const Usage = struct {
    message: []const u8 = "",
    /// A "did you mean" line, or empty.
    hint: []const u8 = "",
};

/// What `parse` can fail with; `Usage` says why.
pub const Error = error{UsageError} || Allocator.Error;

/// What `parse` accepts, and where it reads values from besides the command line.
pub const Options = struct {
    environ: ?*const std.process.Environ.Map = null,
    /// Recognize `--version` on the root, and `-V` when no flag there takes it.
    version: bool = false,
    /// Recognize `-q`/`--quiet` on every command (a user flag of the same name wins).
    quiet: bool = false,
    /// The words before the cursor, for completion: skip the checks that only a complete
    /// command line can pass (required flags, constraints, the number of positionals).
    partial: bool = false,
    /// Accept an unambiguous prefix of a subcommand's name (`cfg exp` for `cfg explain`).
    prefix_matching: bool = false,
    /// The sentences of usage errors and warnings.
    messages: *const Messages = &Messages.english,
    /// A required flag with a `prompt` may be missing: it goes to `Result.missing` for the
    /// caller to ask for; so may required positionals that all have one (the caller compares
    /// `Result.positionals` with `args.min`). Set when the run is interactive.
    promptable: bool = false,
    /// Values for flags given neither on the command line nor in the environment.
    defaults: ?Defaults = null,
};

/// Parses `args` (without the program name) against `root`. All memory comes from `arena`.
pub fn parse(
    arena: Allocator,
    root: *const Command,
    args: []const []const u8,
    options: Options,
    usage: *Usage,
) Error!Result {
    var parser: Parser = .{ .arena = arena, .args = args, .usage = usage, .options = options };
    try parser.path.append(arena, root);
    try parser.scan();
    var result: Result = .{
        .path = parser.path.items,
        .occurrences = parser.occurrences.items,
        .positionals = parser.positionals.items,
        .passthrough = parser.passthrough.items,
        .help = parser.help,
        .version = parser.version,
        .quiet = parser.quiet,
    };
    if (result.help or result.version) return result;
    try parser.checkVisible();
    try parser.applyEnv();
    try parser.applyDefaults();
    try parser.checkValues();
    if (!options.partial) {
        try parser.checkRequired();
        try parser.checkConstraints();
        try parser.checkPositionals();
    }
    try parser.collectWarnings();
    result.occurrences = parser.occurrences.items;
    result.warnings = parser.warnings.items;
    result.missing = parser.missing.items;
    return result;
}

/// Checks `value` as a value of `flag` would be on the command line: its type, choices,
/// and bounds. For values from elsewhere, such as a prompt.
pub fn checkValue(
    arena: Allocator,
    flag: *const Flag,
    value: []const u8,
    options: Options,
    usage: *Usage,
) Error!void {
    var parser: Parser = .{ .arena = arena, .args = &.{}, .usage = usage, .options = options };
    try parser.checkOne(.{ .flag = flag, .value = value, .source = .argv }, value);
}

const Parser = struct {
    arena: Allocator,
    args: []const []const u8,
    usage: *Usage,
    options: Options,
    index: usize = 0,
    path: std.ArrayList(*const Command) = .empty,
    occurrences: std.ArrayList(Occurrence) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,
    passthrough: std.ArrayList([]const u8) = .empty,
    /// After `--`, or after the first positional of a command that is not interspersed:
    /// every word is a positional.
    flags_ended: bool = false,
    warnings: std.ArrayList([]const u8) = .empty,
    missing: std.ArrayList(*const Flag) = .empty,
    quiet: bool = false,
    help: bool = false,
    version: bool = false,

    fn leaf(p: *const Parser) *const Command {
        return p.path.items[p.path.items.len - 1];
    }

    /// Records `template` (a `Messages` field) with `args` as the usage error.
    fn fail(p: *Parser, template: []const u8, args: []const []const u8) Error {
        p.usage.message = try Messages.allocRender(p.arena, template, args);
        return error.UsageError;
    }

    fn hint(p: *Parser, template: []const u8, args: []const []const u8) Allocator.Error!void {
        p.usage.hint = try Messages.allocRender(p.arena, template, args);
    }

    fn messages(p: *const Parser) *const Messages {
        return p.options.messages;
    }

    /// `--port`, or `--port (from $PORT)` for a value from the environment.
    fn flagLabel(p: *Parser, occurrence: Occurrence) Allocator.Error![]const u8 {
        const name = try std.fmt.allocPrint(p.arena, "--{s}", .{occurrence.flag.name});
        const from = switch (occurrence.source) {
            .argv => return name,
            .env => try Messages.allocRender(p.arena, p.messages().from_env, &.{
                occurrence.flag.env.?,
            }),
            .config => try Messages.allocRender(p.arena, p.messages().from_config, &.{
                p.options.defaults.?.name,
            }),
        };
        return std.fmt.allocPrint(p.arena, "{s} {s}", .{ name, from });
    }

    fn number(p: *Parser, value: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.arena, "{d}", .{value});
    }

    fn scan(p: *Parser) Error!void {
        while (p.index < p.args.len) {
            const arg = p.args[p.index];
            p.index += 1;
            if (p.flags_ended) {
                try p.positionals.append(p.arena, arg);
            } else if (std.mem.eql(u8, arg, "--")) {
                if (p.leaf().args.passthrough) {
                    try p.passthrough.appendSlice(p.arena, p.args[p.index..]);
                    return;
                }
                p.flags_ended = true;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try p.long(arg[2..]);
            } else if (arg.len > 1 and arg[0] == '-') {
                try p.shorts(arg[1..]);
            } else {
                try p.positional(arg);
            }
        }
    }

    fn positional(p: *Parser, arg: []const u8) Error!void {
        const current = p.leaf();
        if (p.positionals.items.len == 0 and current.subcommands.len > 0) {
            const found = current.findSubcommand(arg) orelse
                if (p.options.prefix_matching) try p.prefixMatch(current, arg) else null;
            if (found) |sub| {
                if (p.path.items.len >= max_depth) {
                    return p.fail(p.messages().too_deep, &.{});
                }
                try p.path.append(p.arena, sub);
                return;
            }
            if (current.run == null or current.args.max == 0) {
                try p.suggestCommand(current, arg);
                return p.fail(p.messages().unknown_command, &.{ arg, try p.pathText() });
            }
        }
        try p.positionals.append(p.arena, arg);
        if (!current.args.interspersed) p.flags_ended = true;
    }

    /// The one advertised (not hidden or deprecated) subcommand whose name or alias starts
    /// with `prefix`; an error when several do.
    fn prefixMatch(p: *Parser, current: *const Command, prefix: []const u8) Error!?*const Command {
        var found: ?*const Command = null;
        for (current.subcommands) |*sub| {
            if (sub.hidden or sub.deprecated != null) continue;
            const matches = std.mem.startsWith(u8, sub.name, prefix) or for (sub.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, prefix)) break true;
            } else false;
            if (!matches) continue;
            if (found) |other| return p.fail(
                p.messages().ambiguous_command,
                &.{ prefix, try p.pathText(), other.name, sub.name },
            );
            found = sub;
        }
        return found;
    }

    fn suggestCommand(p: *Parser, current: *const Command, arg: []const u8) Allocator.Error!void {
        var names: std.ArrayList([]const u8) = .empty;
        for (current.subcommands) |sub| {
            // Hidden and deprecated commands run when typed, but are not suggested.
            if (sub.hidden or sub.deprecated != null) continue;
            try names.append(p.arena, sub.name);
            try names.appendSlice(p.arena, sub.aliases);
        }
        if (text.suggest(arg, names.items)) |name| try p.hint(p.messages().did_you_mean, &.{name});
    }

    fn long(p: *Parser, body: []const u8) Error!void {
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const name = body[0 .. eq orelse body.len];
        const inline_value: ?[]const u8 = if (eq) |i| body[i + 1 ..] else null;
        if (p.findLong(name)) |flag| return p.record(flag, "--", name, inline_value, false);
        if (std.mem.startsWith(u8, name, "no-")) {
            if (p.findLong(name[3..])) |flag| {
                if (flag.kind == .bool) {
                    if (inline_value != null) {
                        const spelled = try std.fmt.allocPrint(p.arena, "--{s}", .{name});
                        return p.fail(p.messages().no_value_allowed, &.{spelled});
                    }
                    return p.add(flag, "false");
                }
            }
        }
        if (std.mem.eql(u8, name, "help")) {
            p.help = true;
            return;
        }
        if (std.mem.eql(u8, name, "quiet") and p.options.quiet) {
            if (inline_value != null) return p.fail(p.messages().no_value_allowed, &.{"--quiet"});
            p.quiet = true;
            return;
        }
        if (std.mem.eql(u8, name, "version") and p.options.version and p.path.items.len == 1) {
            p.version = true;
            return;
        }
        try p.suggestFlag(name);
        return p.fail(p.messages().unknown_flag, &.{name});
    }

    fn shorts(p: *Parser, body: []const u8) Error!void {
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const c = body[i];
            const flag = p.findShort(c) orelse {
                if (c == 'h') {
                    p.help = true;
                    continue;
                }
                if (c == 'q' and p.options.quiet) {
                    p.quiet = true;
                    continue;
                }
                // `-V` is `--version`, as `-h` is `--help`: unless a flag takes the letter.
                if (c == 'V' and p.options.version and p.path.items.len == 1) {
                    p.version = true;
                    continue;
                }
                return p.fail(p.messages().unknown_short, &.{ body[i .. i + 1], p.bundle(body) });
            };
            if (flag.takesValue()) {
                // `-p80` and `-p=80` hold the value; `-p=` holds an empty one.
                const rest = body[i + 1 ..];
                const value: ?[]const u8 = if (rest.len > 0 and rest[0] == '=')
                    rest[1..]
                else if (rest.len > 0)
                    rest
                else
                    null;
                return p.record(flag, "-", body[i .. i + 1], value, true);
            }
            try p.record(flag, "-", body[i .. i + 1], null, true);
        }
    }

    /// A bundle of shorts as a message may echo it: cut after a secret flag that takes a
    /// value, since the rest of the bundle is that value (`-xt<redacted>`).
    fn bundle(p: *Parser, body: []const u8) []const u8 {
        for (body, 0..) |c, i| {
            const flag = p.findShort(c) orelse continue;
            if (!flag.takesValue()) continue;
            if (!flag.secret or i + 1 == body.len) return body;
            return std.mem.concat(p.arena, u8, &.{ body[0 .. i + 1], Flag.redacted }) catch
                body[0 .. i + 1];
        }
        return body;
    }

    /// Records one occurrence of `flag`, consuming the next argument as its value if needed.
    fn record(
        p: *Parser,
        flag: *const Flag,
        dashes: []const u8,
        spelled: []const u8,
        inline_value: ?[]const u8,
        short: bool,
    ) Error!void {
        switch (flag.kind) {
            .bool => {
                const value = inline_value orelse "true";
                if (Flag.parseBool(value) == null) {
                    const label = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ dashes, spelled });
                    return p.fail(p.messages().expected_bool, &.{ flag.shownValue(value), label });
                }
                const normalized = if (Flag.parseBool(value).?) "true" else "false";
                try p.add(flag, normalized);
            },
            .count => {
                if (inline_value != null and !short) {
                    const label = try std.fmt.allocPrint(p.arena, "--{s}", .{spelled});
                    return p.fail(p.messages().no_value_allowed, &.{label});
                }
                try p.add(flag, "");
            },
            .value => {
                const value = inline_value orelse blk: {
                    if (p.index >= p.args.len) {
                        const label = try std.mem.concat(p.arena, u8, &.{ dashes, spelled });
                        return p.fail(p.messages().needs_argument, &.{label});
                    }
                    p.index += 1;
                    break :blk p.args[p.index - 1];
                };
                try p.add(flag, value);
            },
        }
    }

    fn add(p: *Parser, flag: *const Flag, value: []const u8) Allocator.Error!void {
        try p.occurrences.append(p.arena, .{ .flag = flag, .value = value, .source = .argv });
    }

    fn findLong(p: *const Parser, name: []const u8) ?*const Flag {
        var it = visible(p.path.items);
        while (it.next()) |flag| {
            if (flag.matches(name)) return flag;
        }
        return null;
    }

    fn findShort(p: *const Parser, c: u8) ?*const Flag {
        var it = visible(p.path.items);
        while (it.next()) |flag| {
            if (flag.short == c) return flag;
        }
        return null;
    }

    fn suggestFlag(p: *Parser, name: []const u8) Allocator.Error!void {
        var names: std.ArrayList([]const u8) = .empty;
        var it = visible(p.path.items);
        while (it.next()) |flag| {
            if (!flag.hidden and flag.deprecated == null) try names.append(p.arena, flag.name);
        }
        if (text.suggest(name, names.items)) |found| {
            try p.hint(p.messages().did_you_mean_flag, &.{found});
        }
    }

    /// A flag given before a subcommand may belong to a parent that does not pass it down.
    fn checkVisible(p: *Parser) Error!void {
        for (p.occurrences.items) |occurrence| {
            if (isVisible(p.path.items, occurrence.flag)) continue;
            return p.fail(p.messages().not_valid_for, &.{ occurrence.flag.name, try p.pathText() });
        }
    }

    /// Adds an occurrence for each flag absent from the command line whose variable is
    /// set. A boolean's value is normalized; a counter's is the count.
    fn applyEnv(p: *Parser) Error!void {
        const environ = p.options.environ orelse return;
        var it = visible(p.path.items);
        while (it.next()) |flag| {
            const name = flag.env orelse continue;
            if (p.given(flag)) continue;
            const value = environ.get(name) orelse continue;
            if (value.len == 0) continue;
            try p.addFallback(flag, value, .env);
        }
    }

    /// Adds an occurrence for each flag still absent that `Options.defaults` has a value
    /// for.
    fn applyDefaults(p: *Parser) Error!void {
        const defaults = p.options.defaults orelse return;
        var it = visible(p.path.items);
        while (it.next()) |flag| {
            if (p.given(flag)) continue;
            const value = defaults.lookup(defaults.context, p.path.items, flag) orelse continue;
            try p.addFallback(flag, value, .config);
        }
    }

    /// Records `value` for `flag` from the environment or a configuration file: a
    /// boolean's value normalized, a counter's checked to be a count.
    fn addFallback(p: *Parser, flag: *const Flag, value: []const u8, source: Source) Error!void {
        const occurrence: Occurrence = .{ .flag = flag, .value = value, .source = source };
        const normalized = switch (flag.kind) {
            .value => value,
            .count => if (envCount(value) != null) value else {
                const label = try p.flagLabel(occurrence);
                return p.fail(p.messages().expected_count, &.{ flag.shownValue(value), label });
            },
            .bool => if (Flag.parseBool(value)) |b| (if (b) "true" else "false") else {
                const label = try p.flagLabel(occurrence);
                return p.fail(p.messages().expected_bool, &.{ flag.shownValue(value), label });
            },
        };
        try p.occurrences.append(p.arena, .{ .flag = flag, .value = normalized, .source = source });
    }

    fn checkValues(p: *Parser) Error!void {
        for (p.occurrences.items) |occurrence| {
            const flag = occurrence.flag;
            if (flag.kind != .value) continue;
            if (flag.split) |separator| {
                var parts = std.mem.splitScalar(u8, occurrence.value, separator);
                while (parts.next()) |part| try p.checkOne(occurrence, part);
            } else {
                try p.checkOne(occurrence, occurrence.value);
            }
        }
    }

    /// A secret's value is never echoed: messages show `Flag.redacted`, and no "did you
    /// mean" hint hints at what was typed.
    fn checkOne(p: *Parser, occurrence: Occurrence, value: []const u8) Error!void {
        const flag = occurrence.flag;
        if (flag.check(value) and inChoices(flag, value)) return p.checkBounds(occurrence, value);
        const label = try p.flagLabel(occurrence);
        const shown = flag.shownValue(value);
        if (flag.choices.len > 0) {
            const close = if (flag.secret) null else text.suggest(value, flag.choices);
            if (close) |choice| try p.hint(p.messages().did_you_mean, &.{choice});
            const choices = try std.mem.join(p.arena, ", ", flag.choices);
            return p.fail(p.messages().expected_one_of, &.{ shown, label, choices });
        }
        return p.fail(p.messages().expected_type, &.{ shown, label, flag.value_name });
    }

    /// `.min` and `.max`, on a value that already parsed as the flag's number type;
    /// `.min_len` and `.max_len` on a string.
    fn checkBounds(p: *Parser, occurrence: Occurrence, value: []const u8) Error!void {
        const flag = occurrence.flag;
        const shown = flag.shownValue(value);
        if (flag.min_len != null or flag.max_len != null) {
            const length = std.unicode.utf8CountCodepoints(value) catch value.len;
            if (flag.min_len) |min| if (length < min) return p.fail(
                p.messages().too_short,
                &.{ shown, try p.flagLabel(occurrence), try p.number(min) },
            );
            if (flag.max_len) |max| if (length > max) return p.fail(
                p.messages().too_long,
                &.{ shown, try p.flagLabel(occurrence), try p.number(max) },
            );
        }
        if (flag.min == null and flag.max == null) return;
        const amount = numberOf(value) orelse return;
        if (flag.min) |min| if (amount < min) return p.fail(
            p.messages().at_least,
            &.{ shown, try p.flagLabel(occurrence), try p.number(min) },
        );
        if (flag.max) |max| if (amount > max) return p.fail(
            p.messages().at_most,
            &.{ shown, try p.flagLabel(occurrence), try p.number(max) },
        );
    }

    fn checkRequired(p: *Parser) Error!void {
        var it = visible(p.path.items);
        while (it.next()) |flag| {
            if (flag.required and !p.given(flag)) {
                if (flag.prompt != null and p.options.promptable) {
                    try p.missing.append(p.arena, flag);
                    continue;
                }
                if (flag.env) |env| {
                    return p.fail(p.messages().required_flag_env, &.{ flag.name, env });
                }
                return p.fail(p.messages().required_flag, &.{flag.name});
            }
        }
    }

    fn checkConstraints(p: *Parser) Error!void {
        for (p.occurrences.items) |occurrence| {
            for (occurrence.flag.requires) |name| {
                if (!p.givenName(name)) {
                    return p.fail(p.messages().requires_flag, &.{ occurrence.flag.name, name });
                }
            }
        }
        for (p.path.items) |cmd| {
            for (cmd.constraints.exclusive) |group| {
                var first: ?[]const u8 = null;
                for (group) |name| {
                    if (!p.givenName(name)) continue;
                    if (first) |other| {
                        return p.fail(p.messages().exclusive_flags, &.{ other, name });
                    }
                    first = name;
                }
            }
            for (cmd.constraints.together) |group| {
                var count: usize = 0;
                for (group) |name| count += @intFromBool(p.givenName(name));
                if (count == 0 or count == group.len) continue;
                const names = try joinFlags(p.arena, group);
                return p.fail(p.messages().together_flags, &.{names});
            }
            for (cmd.constraints.one_required) |group| {
                const any = for (group) |name| {
                    if (p.givenName(name)) break true;
                } else false;
                if (!any) return p.fail(
                    p.messages().one_required_flag,
                    &.{try joinFlags(p.arena, group)},
                );
            }
        }
    }

    fn checkPositionals(p: *Parser) Error!void {
        const current = p.leaf();
        const count = p.positionals.items.len;
        // A group with no handler shows its help; there is nothing to count against.
        if (current.run == null) return;
        if (count < current.args.min) {
            // An interactive run asks for them instead (`App`), when each has a `.prompt`.
            if (p.options.promptable and current.args.promptsFrom(count)) return;
            const m = p.messages();
            const template = if (current.args.min == 1) m.too_few_argument else m.too_few_arguments;
            return p.fail(
                template,
                &.{ try p.pathText(), try p.number(current.args.min), try p.number(count) },
            );
        }
        if (current.args.max) |max| {
            if (count > max) return p.fail(
                p.messages().unexpected_argument,
                &.{ p.positionals.items[max], try p.pathText() },
            );
        }
    }

    fn collectWarnings(p: *Parser) Allocator.Error!void {
        for (p.path.items) |cmd| {
            const notice = cmd.deprecated orelse continue;
            try p.warnings.append(p.arena, try Messages.allocRender(
                p.arena,
                p.messages().deprecated_command,
                &.{ cmd.name, notice },
            ));
        }
        for (p.occurrences.items, 0..) |occurrence, i| {
            const notice = occurrence.flag.deprecated orelse continue;
            const first = for (p.occurrences.items[0..i]) |earlier| {
                if (earlier.flag == occurrence.flag) break false;
            } else true;
            if (!first) continue;
            try p.warnings.append(p.arena, try Messages.allocRender(
                p.arena,
                p.messages().deprecated_flag,
                &.{ occurrence.flag.name, notice },
            ));
        }
    }

    fn given(p: *const Parser, flag: *const Flag) bool {
        for (p.occurrences.items) |occurrence| {
            if (occurrence.flag == flag) return true;
        }
        return false;
    }

    fn givenName(p: *const Parser, name: []const u8) bool {
        for (p.occurrences.items) |occurrence| {
            if (std.mem.eql(u8, occurrence.flag.name, name)) return true;
        }
        return false;
    }

    fn pathText(p: *Parser) Allocator.Error![]const u8 {
        return pathString(p.arena, p.path.items);
    }
};

/// Whether `value` is one of a string flag's `.one_of` values. Enums are checked by their
/// own parser, so other kinds always pass.
fn inChoices(flag: *const Flag, value: []const u8) bool {
    if (flag.value_type != .string or flag.choices.len == 0) return true;
    for (flag.choices) |choice| if (std.mem.eql(u8, choice, value)) return true;
    return false;
}

/// A flag value as a number, for bounds: integers in any base the flag accepts, or floats.
fn numberOf(value: []const u8) ?f64 {
    if (std.fmt.parseInt(i128, value, 0)) |int| return @floatFromInt(int) else |_| {}
    return std.fmt.parseFloat(f64, value) catch null;
}

/// The count a counter flag's environment variable holds, or null when it is not one.
pub fn envCount(value: []const u8) ?usize {
    return std.fmt.parseInt(usize, value, 10) catch null;
}

/// `app config get`.
pub fn pathString(arena: Allocator, path: []const *const Command) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path, 0..) |cmd, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, cmd.name);
    }
    return out.items;
}

fn joinFlags(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |name, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, "--");
        try out.appendSlice(arena, name);
    }
    return out.items;
}

/// Iterates the flags visible from the end of `path`: the last command's own flags, then
/// the persistent flags of every command on the path, nearest first. A nearer flag shadows
/// a farther one with the same name.
pub const VisibleIterator = struct {
    path: []const *const Command,
    level: usize,
    own: bool = true,
    index: usize = 0,

    /// The next visible flag, or null.
    pub fn next(it: *VisibleIterator) ?*const Flag {
        while (true) {
            const cmd = it.path[it.level];
            const list = if (it.own) cmd.flags else cmd.persistent_flags;
            if (it.index < list.len) {
                it.index += 1;
                return &list[it.index - 1];
            }
            it.index = 0;
            if (it.own) {
                it.own = false;
            } else if (it.level == 0) {
                return null;
            } else {
                it.level -= 1;
            }
        }
    }
};

/// The flags visible from the last command of `path`; see `VisibleIterator`.
pub fn visible(path: []const *const Command) VisibleIterator {
    assert(path.len > 0);
    return .{ .path = path, .level = path.len - 1 };
}

/// Whether `flag` (by identity) is visible from the last command of `path`.
pub fn isVisible(path: []const *const Command, flag: *const Flag) bool {
    var it = visible(path);
    while (it.next()) |candidate| {
        if (candidate == flag) return true;
    }
    return false;
}

const testing = std.testing;
const spec = @import("spec.zig");
const Context = @import("Context.zig");

fn noop(_: *Context) !void {}

const Global = struct {
    verbose: u8 = 0,
    config: ?[]const u8 = null,
    pub const meta = .{
        .verbose = .{ .short = 'v', .count = true },
        .config = .{ .short = 'c', .env = "APP_CONFIG" },
    };
};

const ServeFlags = struct {
    port: u16 = 8080,
    mode: enum { dev, prod } = .dev,
    tag: []const []const u8 = &.{},
    force: bool = false,
    json: bool = false,
    yaml: bool = false,
    old: bool = false,
    pub const meta = .{
        .port = .{ .short = 'p', .env = "PORT" },
        .tag = .{ .short = 't', .split = ',' },
        .force = .{ .short = 'f' },
        .old = .{ .deprecated = "use --force" },
    };
};

const test_root = spec.command(.{
    .name = "app",
    .persistent_flags = Global,
    .subcommands = .{
        spec.command(.{
            .name = "serve",
            .aliases = &.{"s"},
            .flags = ServeFlags,
            .args = .{ .max = 1 },
            .exclusive = &.{&.{ "json", "yaml" }},
            .run = noop,
        }),
        spec.command(.{
            .name = "get",
            .flags = struct { key: []const u8 },
            .args = .{ .min = 1, .max = 2 },
            .run = noop,
        }),
    },
});

fn parseTest(arena: Allocator, args: []const []const u8, usage: *Usage) Error!Result {
    return parse(arena, &test_root, args, .{ .version = true }, usage);
}

fn values(result: Result, name: []const u8, buffer: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (result.occurrences) |occurrence| {
        if (!std.mem.eql(u8, occurrence.flag.name, name)) continue;
        buffer[n] = occurrence.value;
        n += 1;
    }
    return buffer[0..n];
}

test "subcommands, aliases, and every flag spelling" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const result = try parseTest(arena.allocator(), &.{
        "-vv", "s",   "--port=1",   "-p", "2", "-p3", "--mode", "prod", "-ft",
        "a,b", "dir", "--no-force", "-v",
    }, &usage);
    try testing.expectEqualStrings("serve", result.leaf().name);
    var buffer: [8][]const u8 = undefined;
    try testing.expectEqual(3, values(result, "verbose", &buffer).len);
    const ports = values(result, "port", &buffer);
    try testing.expectEqualStrings("3", ports[2]);
    try testing.expectEqualStrings("prod", values(result, "mode", &buffer)[0]);
    try testing.expectEqualStrings("a,b", values(result, "tag", &buffer)[0]);
    const force = values(result, "force", &buffer);
    try testing.expectEqualStrings("false", force[1]);
    try testing.expectEqual(1, result.positionals.len);
    try testing.expectEqualStrings("dir", result.positionals[0]);
}

test "double dash ends flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const result = try parseTest(
        arena.allocator(),
        &.{ "get", "--key", "k", "--", "--not-a-flag" },
        &usage,
    );
    try testing.expectEqualStrings("--not-a-flag", result.positionals[0]);
}

test "environment fallback" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PORT", "9000");
    try environ.put("APP_CONFIG", "c.toml");
    var usage: Usage = .{};
    const result = try parse(
        arena.allocator(),
        &test_root,
        &.{ "serve", "-c", "x.toml" },
        .{ .environ = &environ },
        &usage,
    );
    var buffer: [8][]const u8 = undefined;
    try testing.expectEqualStrings("9000", values(result, "port", &buffer)[0]);
    const config = values(result, "config", &buffer);
    try testing.expectEqual(1, config.len);
    try testing.expectEqualStrings("x.toml", config[0]);

    try environ.put("PORT", "web");
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &test_root, &.{"serve"}, .{ .environ = &environ }, &usage),
    );
    try testing.expectEqualStrings(
        "invalid value \"web\" for flag --port (from $PORT): expected int",
        usage.message,
    );
}

test "help and version short-circuit validation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const help = try parseTest(arena.allocator(), &.{ "get", "-h" }, &usage);
    try testing.expect(help.help);
    try testing.expectEqualStrings("get", help.leaf().name);
    const version = try parseTest(arena.allocator(), &.{"--version"}, &usage);
    try testing.expect(version.version);
    try testing.expectError(
        error.UsageError,
        parseTest(arena.allocator(), &.{ "get", "--version" }, &usage),
    );
}

test "deprecated flags warn once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const result = try parseTest(arena.allocator(), &.{ "serve", "--old", "--old" }, &usage);
    try testing.expectEqual(1, result.warnings.len);
    try testing.expectEqualStrings("flag --old is deprecated: use --force", result.warnings[0]);
}

test "usage errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { args: []const []const u8, message: []const u8, hint: []const u8 = "" };
    const cases = [_]Case{
        .{
            .args = &.{"serv"},
            .message = "unknown command \"serv\" for \"app\"",
            .hint = "Did you mean \"serve\"?",
        },
        .{
            .args = &.{ "serve", "--prot", "1" },
            .message = "unknown flag: --prot",
            .hint = "Did you mean --port?",
        },
        .{ .args = &.{ "serve", "-x" }, .message = "unknown shorthand flag: 'x' in -x" },
        .{ .args = &.{ "serve", "--port" }, .message = "flag needs an argument: --port" },
        .{
            .args = &.{ "serve", "--port", "http" },
            .message = "invalid value \"http\" for flag --port: expected int",
        },
        .{
            .args = &.{ "serve", "--mode", "qa" },
            .message = "invalid value \"qa\" for flag --mode: expected one of dev, prod",
        },
        .{
            .args = &.{ "serve", "--force=maybe" },
            .message = "invalid value \"maybe\" for flag --force: expected true or false",
        },
        .{
            .args = &.{ "serve", "--no-force=1" },
            .message = "flag --no-force does not take a value",
        },
        .{
            .args = &.{ "serve", "--json", "--yaml" },
            .message = "flags --json and --yaml cannot be used together",
        },
        .{
            .args = &.{ "serve", "a", "b" },
            .message = "unexpected argument \"b\" for \"app serve\"",
        },
        .{ .args = &.{ "get", "k" }, .message = "required flag --key is not set" },
        .{
            .args = &.{ "get", "--key", "k" },
            .message = "\"app get\" requires at least 1 argument, received 0",
        },
        .{ .args = &.{ "--port", "1", "serve" }, .message = "unknown flag: --port" },
        .{
            .args = &.{ "serve", "--verbose=2" },
            .message = "flag --verbose does not take a value",
        },
    };
    for (cases) |case| {
        var usage: Usage = .{};
        try testing.expectError(error.UsageError, parseTest(arena.allocator(), case.args, &usage));
        try testing.expectEqualStrings(case.message, usage.message);
        try testing.expectEqualStrings(case.hint, usage.hint);
    }
}

test "visible flags, nearest first" {
    const path = [_]*const Command{ &test_root, &test_root.subcommands[0] };
    var it = visible(&path);
    try testing.expectEqualStrings("port", it.next().?.name);
    var last: *const Flag = undefined;
    while (it.next()) |flag| last = flag;
    try testing.expectEqualStrings("config", last.name);
}

const constraint_root = spec.command(.{
    .name = "app",
    .flags = struct {
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
        file: ?[]const u8 = null,
        url: ?[]const u8 = null,
    },
    .together = &.{&.{ "user", "password" }},
    .one_required = &.{&.{ "file", "url" }},
    .run = noop,
});

test "together and one_required constraints" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { args: []const []const u8, message: []const u8 = "" };
    const together = "flags --user, --password must be used together";
    const one = "one of the flags --file, --url is required";
    const cases = [_]Case{
        .{ .args = &.{"--file=f"} },
        .{ .args = &.{"--url=u"} },
        .{ .args = &.{ "--file=f", "--url=u", "--user=a", "--password=b" } },
        .{ .args = &.{ "--file=f", "--user=a" }, .message = together },
        .{ .args = &.{ "--password=b", "--url=u" }, .message = together },
        .{ .args = &.{}, .message = one },
        .{ .args = &.{ "--user=a", "--password=b" }, .message = one },
    };
    for (cases) |case| {
        var usage: Usage = .{};
        const result = parse(arena.allocator(), &constraint_root, case.args, .{}, &usage);
        if (case.message.len == 0) {
            _ = try result;
        } else {
            try testing.expectError(error.UsageError, result);
            try testing.expectEqualStrings(case.message, usage.message);
        }
    }
}

test "split values from the environment are checked element by element" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = comptime spec.command(.{
        .name = "app",
        .flags = struct {
            id: []const u16 = &.{},
            pub const meta = .{ .id = .{ .split = ',', .env = "IDS" } };
        },
        .run = noop,
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("IDS", "1,2,x");
    var usage: Usage = .{};
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &root, &.{}, .{ .environ = &environ }, &usage),
    );
    try testing.expectEqualStrings(
        "invalid value \"x\" for flag --id (from $IDS): expected int",
        usage.message,
    );
    try environ.put("IDS", "1,2");
    const result = try parse(arena.allocator(), &root, &.{}, .{ .environ = &environ }, &usage);
    try testing.expectEqual(1, result.occurrences.len);
    try testing.expectEqual(Source.env, result.occurrences[0].source);
    try testing.expectEqualStrings("1,2", result.occurrences[0].value);
}

const shape_root = spec.command(.{
    .name = "app",
    .persistent_flags = struct {
        debug: bool = false,
        pub const meta = .{ .debug = .{ .short = 'd' } };
    },
    .flags = struct { local: bool = false },
    .args = .{ .max = null },
    .run = noop,
    .subcommands = .{
        spec.command(.{
            .name = "list",
            .aliases = &.{"ls"},
            .deprecated = "use show",
            .flags = struct {
                host: bool = false,
                offset: i32 = 0,
                name: []const u8 = "",
                pub const meta = .{
                    .host = .{ .short = 'h' },
                    .offset = .{ .short = 'o' },
                };
            },
            .args = .{ .max = null },
            .run = noop,
        }),
        spec.command(.{ .name = "internal", .hidden = true, .run = noop }),
    },
});

fn parseShape(arena: Allocator, args: []const []const u8, usage: *Usage) Error!Result {
    return parse(arena, &shape_root, args, .{}, usage);
}

test "a deprecated command warns" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const result = try parseShape(arena.allocator(), &.{"ls"}, &usage);
    try testing.expectEqual(1, result.warnings.len);
    try testing.expectEqualStrings("command \"list\" is deprecated: use show", result.warnings[0]);
}

test "a user flag may take -h; --help still asks for help" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const short = try parseShape(arena.allocator(), &.{ "list", "-h" }, &usage);
    try testing.expect(!short.help);
    var buffer: [4][]const u8 = undefined;
    try testing.expectEqualStrings("true", values(short, "host", &buffer)[0]);
    const long_help = try parseShape(arena.allocator(), &.{ "list", "--help" }, &usage);
    try testing.expect(long_help.help);
    // On the root, where no flag takes 'h', -h is help.
    const root_help = try parseShape(arena.allocator(), &.{"-h"}, &usage);
    try testing.expect(root_help.help);
}

test "negative numbers and empty inline values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    var buffer: [4][]const u8 = undefined;
    const long_form = try parseShape(arena.allocator(), &.{ "list", "--offset", "-5" }, &usage);
    try testing.expectEqualStrings("-5", values(long_form, "offset", &buffer)[0]);
    const short_form = try parseShape(arena.allocator(), &.{ "list", "-o", "-5" }, &usage);
    try testing.expectEqualStrings("-5", values(short_form, "offset", &buffer)[0]);
    const attached = try parseShape(arena.allocator(), &.{ "list", "-o-5" }, &usage);
    try testing.expectEqualStrings("-5", values(attached, "offset", &buffer)[0]);

    const empty = try parseShape(arena.allocator(), &.{ "list", "--name=" }, &usage);
    try testing.expectEqualStrings("", values(empty, "name", &buffer)[0]);
    try testing.expectError(
        error.UsageError,
        parseShape(arena.allocator(), &.{ "list", "--offset=" }, &usage),
    );
    try testing.expectEqualStrings(
        "invalid value \"\" for flag --offset: expected int",
        usage.message,
    );
    try testing.expectError(
        error.UsageError,
        parseShape(arena.allocator(), &.{ "list", "--host=" }, &usage),
    );
    try testing.expectEqualStrings(
        "invalid value \"\" for flag --host: expected true or false",
        usage.message,
    );
}

test "suggestions skip hidden commands and include aliases" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = comptime spec.command(.{
        .name = "app",
        .subcommands = .{
            spec.command(.{ .name = "internal", .hidden = true, .run = noop }),
            spec.command(.{ .name = "remove", .aliases = &.{"rm"}, .run = noop }),
        },
    });
    var usage: Usage = .{};
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &root, &.{"internl"}, .{}, &usage),
    );
    try testing.expectEqualStrings("", usage.hint);
    usage = .{};
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &root, &.{"rn"}, .{}, &usage),
    );
    try testing.expectEqualStrings("Did you mean \"rm\"?", usage.hint);
    // A hidden command is still callable.
    const hidden = try parse(arena.allocator(), &root, &.{"internal"}, .{}, &usage);
    try testing.expectEqualStrings("internal", hidden.leaf().name);
}

test "persistent flags before and after the subcommand; local ones only after" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    var buffer: [4][]const u8 = undefined;
    const before = try parseShape(arena.allocator(), &.{ "-d", "list" }, &usage);
    try testing.expectEqualStrings("list", before.leaf().name);
    try testing.expectEqual(1, values(before, "debug", &buffer).len);
    const after = try parseShape(arena.allocator(), &.{ "list", "--debug" }, &usage);
    try testing.expectEqual(1, values(after, "debug", &buffer).len);

    try testing.expectError(
        error.UsageError,
        parseShape(arena.allocator(), &.{ "--local", "list" }, &usage),
    );
    try testing.expectEqualStrings("flag --local is not valid for \"app list\"", usage.message);
}

test "after -- and after a positional, command names are positionals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const dashed = try parseShape(arena.allocator(), &.{ "--", "list", "-d" }, &usage);
    try testing.expectEqualStrings("app", dashed.leaf().name);
    try testing.expectEqual(2, dashed.positionals.len);
    try testing.expectEqualStrings("list", dashed.positionals[0]);
    try testing.expectEqualStrings("-d", dashed.positionals[1]);
    try testing.expectEqual(0, dashed.occurrences.len);

    // The root runs and takes arguments, so an unknown word is its positional, and a
    // command name after it is one too.
    const mixed = try parseShape(arena.allocator(), &.{ "file", "list" }, &usage);
    try testing.expectEqualStrings("app", mixed.leaf().name);
    try testing.expectEqual(2, mixed.positionals.len);
    try testing.expectEqualStrings("list", mixed.positionals[1]);
}

/// A chain of `depth` commands, each the only subcommand of the one before.
fn chain(comptime depth: usize) Command {
    if (depth == 1) return spec.command(.{ .name = "c", .run = noop });
    return spec.command(.{ .name = "c", .run = noop, .subcommands = .{chain(depth - 1)} });
}

test "max_depth" {
    @setEvalBranchQuota(100_000);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = comptime chain(max_depth + 1);
    const words: [max_depth + 1][]const u8 = @splat("c");
    var usage: Usage = .{};
    const deepest = try parse(arena.allocator(), &root, words[1..max_depth], .{}, &usage);
    try testing.expectEqual(max_depth, deepest.path.len);
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &root, words[1..], .{}, &usage),
    );
    try testing.expectEqualStrings("command nesting is too deep", usage.message);
}

test "-p= is an empty value, like --name=" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = comptime spec.command(.{
        .name = "app",
        .flags = struct {
            prefix: []const u8 = "x",
            pub const meta = .{ .prefix = .{ .short = 'p' } };
        },
        .args = .{ .max = 1 },
        .run = noop,
    });
    var usage: Usage = .{};
    var buffer: [4][]const u8 = undefined;
    const result = try parse(arena.allocator(), &root, &.{ "-p=", "arg" }, .{}, &usage);
    try testing.expectEqualStrings("", values(result, "prefix", &buffer)[0]);
    try testing.expectEqualStrings("arg", result.positionals[0]);
}

test "boolean and counter flags from the environment are validated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = comptime spec.command(.{
        .name = "app",
        .flags = struct {
            force: bool = false,
            verbose: u8 = 0,
            pub const meta = .{
                .force = .{ .env = "FORCE" },
                .verbose = .{ .count = true, .env = "VERBOSE" },
            };
        },
        .run = noop,
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var usage: Usage = .{};

    try environ.put("FORCE", "maybe");
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &root, &.{}, .{ .environ = &environ }, &usage),
    );
    try testing.expectEqualStrings(
        "invalid value \"maybe\" for flag --force (from $FORCE): expected true or false",
        usage.message,
    );

    try environ.put("FORCE", "yes");
    try environ.put("VERBOSE", "lots");
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &root, &.{}, .{ .environ = &environ }, &usage),
    );
    try testing.expectEqualStrings(
        "invalid value \"lots\" for flag --verbose (from $VERBOSE): expected a count",
        usage.message,
    );

    try environ.put("VERBOSE", "3");
    const result = try parse(arena.allocator(), &root, &.{}, .{ .environ = &environ }, &usage);
    var buffer: [4][]const u8 = undefined;
    try testing.expectEqualStrings("true", values(result, "force", &buffer)[0]);
    try testing.expectEqualStrings("3", values(result, "verbose", &buffer)[0]);
}

const Checked = struct {
    port: u16 = 8080,
    ratio: f64 = 0.5,
    level: []const u8 = "info",
    colour: bool = false,
    mode: enum { dev, prod } = .dev,
    pub const meta = .{
        .port = .{ .min = 1024, .max = 49151 },
        .ratio = .{ .min = 0, .max = 1.0 },
        .level = .{ .one_of = &[_][]const u8{ "debug", "info", "warn" } },
        .colour = .{ .name = "color", .aliases = &[_][]const u8{"colour"} },
    };
};

const checked_root = spec.command(.{ .name = "app", .flags = Checked, .run = noop });

fn expectUsage(args: []const []const u8, message: []const u8, hint: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const result = parse(arena.allocator(), &checked_root, args, .{}, &usage);
    try testing.expectError(error.UsageError, result);
    try testing.expectEqualStrings(message, usage.message);
    try testing.expectEqualStrings(hint, usage.hint);
}

test "bounds, one_of, aliases, and suggested values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const ok = try parse(arena.allocator(), &checked_root, &.{
        "--port", "2048", "--ratio", "1", "--level", "warn", "--colour",
    }, .{}, &usage);
    try testing.expectEqual(4, ok.occurrences.len);
    try testing.expectEqualStrings("color", ok.occurrences[3].flag.name);

    try expectUsage(
        &.{ "--port", "80" },
        "invalid value \"80\" for flag --port: must be at least 1024",
        "",
    );
    try expectUsage(
        &.{"--ratio=1.5"},
        "invalid value \"1.5\" for flag --ratio: must be at most 1",
        "",
    );
    try expectUsage(
        &.{ "--level", "wran" },
        "invalid value \"wran\" for flag --level: expected one of debug, info, warn",
        "Did you mean \"warn\"?",
    );
    try expectUsage(
        &.{ "--mode", "prd" },
        "invalid value \"prd\" for flag --mode: expected one of dev, prod",
        "Did you mean \"prod\"?",
    );
    // A value of the wrong type fails on its type, before its bounds.
    try expectUsage(&.{ "--port", "x" }, "invalid value \"x\" for flag --port: expected int", "");
}

const SecretFlags = struct {
    token: []const u8 = "",
    pin: u16 = 0,
    level: enum { low, high } = .low,
    code: []const u8 = "",
    force: bool = false,
    pub const meta = .{
        .token = .{ .short = 't', .secret = true, .env = "TOKEN", .min_len = 8 },
        .pin = .{ .secret = true, .max = 9999 },
        .level = .{ .secret = true },
        .code = .{ .secret = true, .one_of = &[_][]const u8{ "alpha", "bravo" } },
        .force = .{ .short = 'f' },
    };
};

const secret_root = spec.command(.{ .name = "app", .flags = SecretFlags, .run = noop });

test "a secret's value never appears in a usage error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("TOKEN", "s3cr3t");
    const Case = struct { args: []const []const u8, message: []const u8 };
    const cases = [_]Case{
        .{
            .args = &.{},
            .message = "invalid value \"<redacted>\" for flag --token (from $TOKEN): " ++
                "must be at least 8 characters",
        },
        .{
            .args = &.{ "--token=longenough", "--pin", "12345" },
            .message = "invalid value \"<redacted>\" for flag --pin: must be at most 9999",
        },
        .{
            .args = &.{ "--token=longenough", "--pin", "s3cr3t" },
            .message = "invalid value \"<redacted>\" for flag --pin: expected int",
        },
        .{
            .args = &.{ "--token=longenough", "--level", "s3cr3t" },
            .message = "invalid value \"<redacted>\" for flag --level: expected one of low, high",
        },
        .{
            .args = &.{ "--token=longenough", "--code", "alpah" },
            .message = "invalid value \"<redacted>\" for flag --code: " ++
                "expected one of alpha, bravo",
        },
        .{ .args = &.{"-xts3cr3t"}, .message = "unknown shorthand flag: 'x' in -xt<redacted>" },
        .{ .args = &.{"-fxts3cr3t"}, .message = "unknown shorthand flag: 'x' in -fxt<redacted>" },
    };
    for (cases) |case| {
        var usage: Usage = .{};
        const options: Options = .{ .environ = &environ };
        try testing.expectError(
            error.UsageError,
            parse(arena.allocator(), &secret_root, case.args, options, &usage),
        );
        try testing.expectEqualStrings(case.message, usage.message);
        // Not even a "did you mean" that would hint at what was typed.
        try testing.expectEqualStrings("", usage.hint);
    }
    // A flag that is not a secret still echoes its value.
    var usage: Usage = .{};
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &secret_root, &.{"-fx"}, .{}, &usage),
    );
    try testing.expectEqualStrings("unknown shorthand flag: 'x' in -fx", usage.message);
}

test "-V is --version on the root, unless a flag takes it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    try testing.expect((try parseTest(arena.allocator(), &.{"-V"}, &usage)).version);
    try testing.expect((try parseTest(arena.allocator(), &.{"-vV"}, &usage)).version);
    // Not below the root, and not without a version.
    try testing.expectError(
        error.UsageError,
        parseTest(arena.allocator(), &.{ "serve", "-V" }, &usage),
    );
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &test_root, &.{"-V"}, .{}, &usage),
    );
    const root = comptime spec.command(.{
        .name = "app",
        .flags = struct {
            verify: bool = false,
            pub const meta = .{ .verify = .{ .short = 'V' } };
        },
        .run = noop,
    });
    const taken = try parse(arena.allocator(), &root, &.{"-V"}, .{ .version = true }, &usage);
    try testing.expect(!taken.version);
    try testing.expectEqual(1, taken.occurrences.len);
}

const deprecated_root = spec.command(.{
    .name = "app",
    .flags = struct {
        colour: bool = false,
        color: bool = false,
        pub const meta = .{ .colour = .{ .deprecated = "use --color" } };
    },
    .subcommands = .{
        spec.command(.{ .name = "remove", .deprecated = "use delete", .run = noop }),
        spec.command(.{ .name = "delete", .run = noop }),
    },
});

test "deprecated commands and flags work when typed but are never suggested" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var usage: Usage = .{};
    const removed = try parse(arena.allocator(), &deprecated_root, &.{"remove"}, .{}, &usage);
    try testing.expectEqualStrings("remove", removed.leaf().name);
    try testing.expectEqual(1, removed.warnings.len);
    const flag = try parse(arena.allocator(), &deprecated_root, &.{"--colour"}, .{}, &usage);
    try testing.expectEqual(1, flag.warnings.len);

    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &deprecated_root, &.{"remov"}, .{}, &usage),
    );
    try testing.expectEqualStrings("", usage.hint);
    usage = .{};
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &deprecated_root, &.{"--colou"}, .{}, &usage),
    );
    try testing.expectEqualStrings("Did you mean --color?", usage.hint);
    // A prefix reaches only the advertised command.
    const options: Options = .{ .prefix_matching = true };
    const prefixed = try parse(arena.allocator(), &deprecated_root, &.{"de"}, options, &usage);
    try testing.expectEqualStrings("delete", prefixed.leaf().name);
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &deprecated_root, &.{"rem"}, options, &usage),
    );
}

test "edge cases of words, bundles, negations, and requirements" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buffer: [4][]const u8 = undefined;
    var usage: Usage = .{};

    // An unknown word before a valid subcommand is not skipped over to reach it.
    try testing.expectError(
        error.UsageError,
        parseTest(arena.allocator(), &.{ "nosuch", "serve" }, &usage),
    );
    try testing.expectEqualStrings("unknown command \"nosuch\" for \"app\"", usage.message);

    // A command with a handler and subcommands that takes no arguments rejects a stray word.
    const body = comptime spec.command(.{
        .name = "app",
        .run = noop,
        .subcommands = .{spec.command(.{ .name = "sub", .run = noop })},
    });
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &body, &.{"nosuch"}, .{}, &usage),
    );
    try testing.expectEqualStrings("unknown command \"nosuch\" for \"app\"", usage.message);

    // In a bundle, a switch is followed by a flag whose value is the rest of the bundle.
    const cluster = try parseTest(arena.allocator(), &.{ "serve", "-fta,b" }, &usage);
    try testing.expectEqualStrings("true", values(cluster, "force", &buffer)[0]);
    try testing.expectEqualStrings("a,b", values(cluster, "tag", &buffer)[0]);
    const tag_v = try parseTest(arena.allocator(), &.{ "serve", "-ftv" }, &usage);
    try testing.expectEqualStrings("v", values(tag_v, "tag", &buffer)[0]);
    try testing.expectEqual(0, values(tag_v, "verbose", &buffer).len);

    // `--no-` negates switches only.
    try testing.expectError(
        error.UsageError,
        parseTest(arena.allocator(), &.{ "serve", "--no-port" }, &usage),
    );
    try testing.expectEqualStrings("unknown flag: --no-port", usage.message);

    // A required flag with a variable: the variable satisfies it; an empty one does not.
    const required = comptime spec.command(.{
        .name = "app",
        .flags = struct {
            key: []const u8,
            pub const meta = .{ .key = .{ .env = "APP_KEY" } };
        },
        .run = noop,
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_KEY", "k");
    const options: Options = .{ .environ = &environ };
    const from_env = try parse(arena.allocator(), &required, &.{}, options, &usage);
    try testing.expectEqualStrings("k", values(from_env, "key", &buffer)[0]);
    const not_set = "required flag --key is not set (nor $APP_KEY)";
    try environ.put("APP_KEY", "");
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &required, &.{}, options, &usage),
    );
    try testing.expectEqualStrings(not_set, usage.message);
    _ = environ.orderedRemove("APP_KEY");
    try testing.expectError(
        error.UsageError,
        parse(arena.allocator(), &required, &.{}, options, &usage),
    );
    try testing.expectEqualStrings(not_set, usage.message);
}

const App = @import("App.zig");
const cli_testing = @import("testing.zig");

const GatedFlags = struct {
    fast: bool = false,
    pub const meta = .{ .fast = .{ .short = 'f', .env = "FAST", .feature = "APP_FAST" } };
};

fn gatedRun(ctx: *Context, flags: GatedFlags) !void {
    try ctx.out.print("fast={}\n", .{flags.fast});
}

fn gatedBeta(ctx: *Context) !void {
    try ctx.out.writeAll("beta\n");
}

const gated_root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{ .name = "go", .flags = GatedFlags, .run = gatedRun }),
        spec.command(.{ .name = "beta", .feature = "APP_BETA", .run = gatedBeta }),
    },
});

fn everythingTrue(_: ?*anyopaque, _: []const *const Command, _: *const Flag) ?[]const u8 {
    return "true";
}

test "a feature switched off by 0, false, or an empty value is unreachable every way" {
    const app: App = .{ .root = &gated_root, .defaults = .{ .lookup = everythingTrue } };
    for ([_][]const u8{ "0", "false", "" }) |off| {
        const beta = try cli_testing.run(app, &.{"beta"}, .{ .env = &.{.{ "APP_BETA", off }} });
        defer beta.deinit();
        try testing.expectEqual(App.exit_usage, beta.status);
        try testing.expect(std.mem.indexOf(u8, beta.err, "unknown command \"beta\"") != null);

        const env: []const [2][]const u8 = &.{ .{ "APP_FAST", off }, .{ "FAST", "1" } };
        const spellings = [_][]const []const u8{
            &.{ "go", "-f" }, &.{ "go", "--fast" }, &.{ "go", "--no-fast" },
        };
        for (spellings) |args| {
            const spelled = try cli_testing.run(app, args, .{ .env = env });
            defer spelled.deinit();
            try testing.expectEqual(App.exit_usage, spelled.status);
        }
        // Neither the variable nor the defaults reach the flag.
        const quiet = try cli_testing.run(app, &.{"go"}, .{ .env = env });
        defer quiet.deinit();
        try quiet.expect(0, "fast=false\n", "");
    }
    const on = try cli_testing.run(app, &.{"go"}, .{ .env = &.{.{ "APP_FAST", "1" }} });
    defer on.deinit();
    try on.expect(0, "fast=true\n", "");
}

test "an unknown word before a subcommand is a usage error from the app" {
    const app: App = .{ .root = &test_root };
    const run = try cli_testing.run(app, &.{ "nosuch", "serve" }, .{});
    defer run.deinit();
    try testing.expectEqual(App.exit_usage, run.status);
    const message = "app: unknown command \"nosuch\" for \"app\"";
    try testing.expect(std.mem.startsWith(u8, run.err, message));
}
