//! A node of the command tree. Plain data: normally built at compile time by
//! `cli.command`, and walked at run time by the parser, help, completion, and docs.

const std = @import("std");
const Flag = @import("Flag.zig");
const Context = @import("Context.zig");

const Command = @This();

/// One exit status and what it means, for the "Exit status" section of the docs.
pub const ExitStatus = struct { code: u8, meaning: []const u8 };

/// A handler or hook. Built by `cli.command` from a function with a typed signature.
///
/// The error set is open: the library cannot know an application's errors, and a closed set
/// would force every handler to catch and re-raise. `Context.fail` is the way to report a
/// failure the user should read.
pub const Handler = *const fn (ctx: *Context) anyerror!void;

/// One completion offered to the shell: a value, or a request that the shell complete
/// file names (`.files`, `value` an extension without the dot, or empty for any file) or
/// directory names (`.directories`).
pub const Candidate = struct {
    value: []const u8 = "",
    /// Shown beside the value by shells that show descriptions.
    description: []const u8 = "",
    kind: Kind = .value,

    /// A value to offer, or the shell's own completion of files or directories.
    pub const Kind = enum { value, files, directories };

    /// Files ending in `.<extension>` (and directories, to reach them). A completer's
    /// result must outlive the call: return a container-level constant
    /// (`const kinds = [_]cli.Candidate{ .files("toml") };` ... `return &kinds;`), or
    /// candidates allocated in `ctx.arena`, never the address of a local array.
    pub fn files(extension: []const u8) Candidate {
        return .{ .value = extension, .kind = .files };
    }

    /// Any file, completed by the shell.
    pub const any_file: Candidate = .{ .kind = .files };
    /// Directories only, completed by the shell.
    pub const directories: Candidate = .{ .kind = .directories };
};

/// Computes completions for a flag's value or a positional argument. `ctx` holds what was
/// parsed from the words before the cursor (flags, `ctx.args`, the command path), so a
/// completer can read `ctx.flags(T)`; `prefix` is the word being completed. Candidates not
/// starting with `prefix` are dropped by the caller, so returning all of them is fine.
/// Allocate in `ctx.arena`. An error, or no candidates, makes the shell complete file names.
pub const Completer = *const fn (ctx: *Context, prefix: []const u8) anyerror![]const Candidate;

/// How many positional arguments a command accepts.
pub const Args = struct {
    min: usize = 0,
    /// `null` for no limit.
    max: ?usize = 0,
    /// Shown in the usage line, such as `<key> [value]`.
    usage: []const u8 = "",
    /// Offers values for the positionals; `ctx.args.len` is the index of the one being
    /// completed.
    complete: ?Completer = null,
    /// Flags may follow positionals (`app run x --verbose`). When false, the first
    /// positional ends flag parsing and every later word is a positional, as POSIX
    /// specifies; for commands that wrap another command's arguments.
    interspersed: bool = true,
    /// Everything after `--` goes, untouched and uncounted by `min` and `max`, to
    /// `ctx.passthrough` instead of `ctx.args`: `app exec --env x -- cmd --its-flags`.
    passthrough: bool = false,
    /// One per typed positional (`.args` given as a struct), for documentation and
    /// prompts.
    positionals: []const Positional = &.{},

    /// Internal, for the parser. Whether every required positional from index `given` on
    /// has a `.prompt`, so an interactive run can ask for them instead of failing.
    pub fn promptsFrom(args: Args, given: usize) bool {
        if (given >= args.min or args.min > args.positionals.len) return false;
        for (args.positionals[given..args.min]) |positional| {
            if (positional.prompt == null) return false;
        }
        return true;
    }
};

/// A typed positional, as documentation describes it.
pub const Positional = struct {
    name: []const u8,
    /// What one value is; see `Flag.ValueType`.
    value_type: Flag.ValueType,
    /// The accepted values, for an enum.
    choices: []const []const u8 = &.{},
    required: bool,
    /// Takes every remaining word.
    repeatable: bool = false,
    /// What it is, from `.help` in the struct's `meta`; help and documentation list the
    /// positionals under "Arguments" when any has some.
    help: []const u8 = "",
    /// When the positional is required and missing in an interactive run, ask for it with
    /// this label instead of failing (`.prompt` in the struct's `meta`; see `App.prompter`).
    prompt: ?[]const u8 = null,
    /// The placeholder for one value in messages: `int`, `fast|safe`.
    value_name: []const u8 = "",
    /// Whether `text` is a valid value (one element, for a list); null accepts any text.
    check: ?*const fn (text: []const u8) bool = null,
};

/// Relationships between a command's flags, by long name.
pub const Constraints = struct {
    /// In each group, at most one flag may be given.
    exclusive: []const []const []const u8 = &.{},
    /// In each group, all flags or none must be given.
    together: []const []const []const u8 = &.{},
    /// In each group, at least one flag must be given.
    one_required: []const []const []const u8 = &.{},
};

name: []const u8,
/// One line, shown in command lists.
summary: []const u8 = "",
/// Paragraphs, shown at the top of the command's own help. Defaults to `summary`.
description: []const u8 = "",
aliases: []const []const u8 = &.{},
/// Verbatim text for the Examples section.
examples: []const u8 = "",
/// The heading the command is listed under in its parent's help.
group: []const u8 = "",
hidden: bool = false,
/// A help topic rather than a command: `app help <name>` (or `app <name>`) prints its
/// `description`, and help lists it under "Help Topics". It has no handler or flags.
topic: bool = false,
/// When set, running the command prints this notice first.
deprecated: ?[]const u8 = null,
/// Ask this question before running; `-y`/`--yes` answers it. Without a terminal to ask
/// on, the command refuses to run unless `--yes` is given. The spec's `.confirm = true`
/// adds `-y`/`--yes` and asks nothing first: the handler asks with `ctx.confirm`.
confirm: ?[]const u8 = null,
/// The statuses this command exits with beyond the app's (`App.exit_statuses`), or with a
/// meaning of its own for the same code; its man page lists them under EXIT STATUS.
exit_statuses: []const ExitStatus = &.{},
/// The command has a `--dry-run` flag; `ctx.dry_run` says whether it was given.
dry_run: bool = false,
/// The command has `-o`/`--output text|json|yaml`; `ctx.render` writes a value in it.
output: bool = false,
/// Run without arguments at an interactive terminal, a command without a handler starts a
/// shell (`repl.run`) on its subcommands instead of printing its help: `app` alone, or
/// `app db`, then lines such as `migrate --dry-run`. Anywhere else, the help as before.
repl: bool = false,
/// The command exists only when this feature is on (see `App.feature_enabled`): until then
/// it is not run, listed, completed, or suggested.
feature: ?[]const u8 = null,
flags: []const Flag = &.{},
/// Flags that apply to this command and every descendant.
persistent_flags: []const Flag = &.{},
args: Args = .{},
constraints: Constraints = .{},
subcommands: []const Command = &.{},
run: ?Handler = null,
pre_run: ?Handler = null,
post_run: ?Handler = null,
/// Runs before `pre_run` of this command and of every descendant, root first.
persistent_pre_run: ?Handler = null,
/// Runs after `post_run` of this command and of every descendant, leaf first.
persistent_post_run: ?Handler = null,
/// Runs after this command or any descendant ends, leaf first, however it ended: after
/// success, a failure, `ctx.exit`, or an interrupt (`App.cancel_on_interrupt`). For
/// releasing what a `persistent_pre_run` acquired. Its error is reported only when the
/// command itself succeeded.
cleanup: ?Handler = null,

/// Whether `name` is the command's name or one of its aliases.
pub fn matches(command: *const Command, name: []const u8) bool {
    if (std.mem.eql(u8, command.name, name)) return true;
    for (command.aliases) |alias| {
        if (std.mem.eql(u8, alias, name)) return true;
    }
    return false;
}

/// The subcommand called `name` (or aliased so).
pub fn findSubcommand(command: *const Command, name: []const u8) ?*const Command {
    for (command.subcommands) |*sub| {
        if (sub.matches(name)) return sub;
    }
    return null;
}

/// The command's own description, falling back to its summary.
pub fn about(command: *const Command) []const u8 {
    return if (command.description.len > 0) command.description else command.summary;
}

test findSubcommand {
    const root: Command = .{
        .name = "app",
        .subcommands = &.{
            .{ .name = "remove", .aliases = &.{"rm"} },
            .{ .name = "add" },
        },
    };
    try std.testing.expectEqualStrings("remove", root.findSubcommand("rm").?.name);
    try std.testing.expectEqualStrings("add", root.findSubcommand("add").?.name);
    try std.testing.expectEqual(null, root.findSubcommand("list"));
}

test "matches and about" {
    const cmd: Command = .{ .name = "remove", .summary = "Remove", .aliases = &.{ "rm", "del" } };
    try std.testing.expect(cmd.matches("remove"));
    try std.testing.expect(cmd.matches("del"));
    try std.testing.expect(!cmd.matches("rem"));
    try std.testing.expectEqualStrings("Remove", cmd.about());
    const described: Command = .{ .name = "x", .summary = "S", .description = "Long" };
    try std.testing.expectEqualStrings("Long", described.about());
}
