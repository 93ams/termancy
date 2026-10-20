//! Every sentence `cli` shows the user, in one table an app can replace: `App.messages`.
//! English is the default. A template marks its arguments `{0}`, `{1}`, ...; `{{` is a
//! literal `{`. A translation may reorder arguments and leave some out.
//!
//! ```zig
//! const german: cli.Messages = .{
//!     .unknown_command = "unbekannter Befehl \"{0}\" für \"{1}\"",
//!     .heading_usage = "Aufruf",
//!     // ... anything not given stays English.
//! };
//! const app: cli.App = .{ .root = &root, .messages = &german };
//! ```

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const Messages = @This();

/// The default table.
pub const english: Messages = .{};

// -- Parsing ---------------------------------------------------------------------------

too_deep: []const u8 = "command nesting is too deep",
/// {0} the word, {1} the command path.
unknown_command: []const u8 = "unknown command \"{0}\" for \"{1}\"",
/// {0} the prefix, {1} the command path, {2} and {3} two matches.
ambiguous_command: []const u8 = "ambiguous command \"{0}\" for \"{1}\": could be {2} or {3}",
/// {0} a command or value.
did_you_mean: []const u8 = "Did you mean \"{0}\"?",
/// {0} a flag name.
did_you_mean_flag: []const u8 = "Did you mean --{0}?",
/// {0} the flag as spelled.
no_value_allowed: []const u8 = "flag {0} does not take a value",
/// {0} the flag name.
unknown_flag: []const u8 = "unknown flag: --{0}",
/// {0} the letter, {1} the bundle.
unknown_short: []const u8 = "unknown shorthand flag: '{0}' in -{1}",
/// {0} the flag as spelled.
needs_argument: []const u8 = "flag needs an argument: {0}",
/// {0} the value, {1} the flag (`--port`, or `--port (from $PORT)`).
expected_bool: []const u8 = "invalid value \"{0}\" for flag {1}: expected true or false",
/// {0} the value, {1} the flag.
expected_count: []const u8 = "invalid value \"{0}\" for flag {1}: expected a count",
/// {0} the value, {1} the flag, {2} the choices, comma-separated.
expected_one_of: []const u8 = "invalid value \"{0}\" for flag {1}: expected one of {2}",
/// {0} the value, {1} the flag, {2} the type's label.
expected_type: []const u8 = "invalid value \"{0}\" for flag {1}: expected {2}",
/// {0} the value, {1} the flag, {2} the bound.
at_least: []const u8 = "invalid value \"{0}\" for flag {1}: must be at least {2}",
/// {0} the value, {1} the flag, {2} the bound.
at_most: []const u8 = "invalid value \"{0}\" for flag {1}: must be at most {2}",
/// {0} the value, {1} the flag, {2} the bound.
too_short: []const u8 = "invalid value \"{0}\" for flag {1}: must be at least {2} characters",
/// {0} the value, {1} the flag, {2} the bound.
too_long: []const u8 = "invalid value \"{0}\" for flag {1}: must be at most {2} characters",
/// {0} the value, {1} the flag, {2} the pattern (`*.pem`).
must_match: []const u8 = "invalid value \"{0}\" for flag {1}: must match {2}",
/// {0} the value, {1} the flag, {2} what a check of the app's own says is wrong.
invalid_value: []const u8 = "invalid value \"{0}\" for flag {1}: {2}",
/// A check on a whole value, found before the command runs. {0} the flag or argument,
/// {1} the bound.
value_at_least: []const u8 = "{0}: must be at least {1}",
/// {0} the flag or argument, {1} the bound.
value_at_most: []const u8 = "{0}: must be at most {1}",
/// {0} the flag or argument, {1} the length.
value_too_short: []const u8 = "{0}: must be at least {1} long",
/// {0} the flag or argument, {1} the length.
value_too_long: []const u8 = "{0}: must be at most {1} long",
/// {0} the flag or argument, {1} the choices, comma-separated.
value_one_of: []const u8 = "{0}: must be one of {1}",
/// {0} the flag or argument, {1} the pattern.
value_must_match: []const u8 = "{0}: must match {1}",
/// {0} a flag's environment variable, for `{1}` in the messages above.
from_env: []const u8 = "(from ${0})",
/// {0} where `App.defaults` reads, such as a file name, for `{1}` in the messages above.
from_config: []const u8 = "(from {0})",
/// {0} the flag given, {1} the flag it needs.
requires_flag: []const u8 = "flag --{0} requires --{1}",
/// {0} the flag name, {1} the command path.
not_valid_for: []const u8 = "flag --{0} is not valid for \"{1}\"",
/// {0} a flag of a choice's variant, {1} the choice's flag, {2} the variant, {3} the
/// variant given.
wrong_variant: []const u8 = "flag --{0} is for --{1} {2}, but --{1} is {3}",
/// {0} the flag name.
required_flag: []const u8 = "required flag --{0} is not set",
/// {0} the flag name, {1} its environment variable.
required_flag_env: []const u8 = "required flag --{0} is not set (nor ${1})",
/// {0} and {1} flag names.
exclusive_flags: []const u8 = "flags --{0} and --{1} cannot be used together",
/// {0} the flags, comma-separated.
together_flags: []const u8 = "flags {0} must be used together",
/// {0} the flags, comma-separated.
one_required_flag: []const u8 = "one of the flags {0} is required",
/// {0} the command path, {1} the minimum (1), {2} the count received.
too_few_argument: []const u8 = "\"{0}\" requires at least {1} argument, received {2}",
/// {0} the command path, {1} the minimum (not 1), {2} the count received.
too_few_arguments: []const u8 = "\"{0}\" requires at least {1} arguments, received {2}",
/// {0} the extra argument, {1} the command path.
unexpected_argument: []const u8 = "unexpected argument \"{0}\" for \"{1}\"",
/// {0} the word, {1} the positional's name, {2} the type's label.
invalid_positional: []const u8 = "invalid value \"{0}\" for <{1}>: expected {2}",
/// {0} the command name, {1} the notice.
deprecated_command: []const u8 = "command \"{0}\" is deprecated: {1}",
/// {0} the flag name, {1} the notice.
deprecated_flag: []const u8 = "flag --{0} is deprecated: {1}",

// -- Running ---------------------------------------------------------------------------

/// {0} the command path.
run_help: []const u8 = "Run '{0} --help' for usage.",
/// {0} the warning.
warning: []const u8 = "warning: {0}",
out_of_memory: []const u8 = "out of memory",
unterminated_quote: []const u8 = "unterminated quote",
trailing_backslash: []const u8 = "line ends with a backslash",
/// {0} the response file argument (`@args.txt`), {1} the reason.
response_file: []const u8 = "{0}: {1}",
show_help: []const u8 = "Show help",
/// {0} the question (`Command.confirm`).
confirm_prompt: []const u8 = "{0} [y/N] ",
/// The words that answer the question yes, separated by `|`, compared ignoring case.
confirm_yes: []const u8 = "y|yes",
/// {0} the command path.
confirm_needed: []const u8 = "\"{0}\" asks for confirmation; run it at a terminal or pass --yes",
confirm_declined: []const u8 = "not confirmed; nothing was done",
/// {0} a flow step's title, {1} the error.
flow_failed: []const u8 = "✗ {0}: {1}",
/// {0} a flow step's title.
flow_skipped: []const u8 = "- {0}: skipped",
/// {0} a flow step's title.
flow_dry_run: []const u8 = "~ {0}: not run (dry run)",
/// {0} a flow step's title.
flow_undone: []const u8 = "↩ {0}: undone",
/// {0} a flow step's title, {1} the error.
flow_undo_failed: []const u8 = "✗ {0}: undo failed: {1}",
/// {0} the question, {1} the flag that answers it.
flow_unanswered: []const u8 = "{0}: no answer; pass --{1}",
flow_canceled: []const u8 = "canceled; nothing more was done",
/// {0} an answer a flow's question refused, {1} what it takes (`int`, `list of int`).
flow_rejected: []const u8 = "invalid answer \"{0}\": expected {1}",

// -- Help ------------------------------------------------------------------------------

heading_usage: []const u8 = "Usage",
heading_aliases: []const u8 = "Aliases",
heading_commands: []const u8 = "Commands",
heading_additional: []const u8 = "Additional Commands",
heading_plugins: []const u8 = "Plugins",
heading_topics: []const u8 = "Help Topics",
heading_arguments: []const u8 = "Arguments",
heading_flags: []const u8 = "Flags",
heading_global_flags: []const u8 = "Global Flags",
heading_examples: []const u8 = "Examples",
usage_flags: []const u8 = "[flags]",
usage_command: []const u8 = "<command>",
usage_args: []const u8 = "[args...]",
/// {0} the command name.
help_flag: []const u8 = "Help for {0}",
help_command: []const u8 = "Help about any command",
/// {0} the words searched for (`help --search`).
search_none: []const u8 = "no command mentions \"{0}\"",
quiet_flag: []const u8 = "Suppress warnings",
yes_flag: []const u8 = "Answer yes to the confirmation",
dry_run_flag: []const u8 = "Show what would change, without changing anything",
output_flag: []const u8 = "Output format",
verbose_flag: []const u8 = "Log more: -v info, -vv debug, -vvv trace",
log_level_flag: []const u8 = "The least severe log messages to show",
color_flag: []const u8 = "When to use color",
version_flag: []const u8 = "Print the version",
/// {0} the command path.
more_information: []const u8 = "Use \"{0} <command> --help\" for more information about a command.",
/// {0} the default.
default_value: []const u8 = "(default {0})",
/// {0} the variable.
env_variable: []const u8 = "[env: {0}]",
/// {0} where else a flag's value can be set, such as `$PORT, port in app.toml`.
also_set: []const u8 = "(also {0})",
required: []const u8 = "(required)",
/// {0} and {1} the bounds.
range: []const u8 = "({0} to {1})",
/// {0} the bound.
minimum: []const u8 = "(at least {0})",
/// {0} the bound.
maximum: []const u8 = "(at most {0})",

// -- Exit statuses, in documentation (`docs.exitStatuses`) -----------------------------

status_success: []const u8 = "Success",
status_failure: []const u8 = "The command failed",
status_usage: []const u8 = "Usage error: an unknown command or flag, or a bad value",
status_cannot_run: []const u8 = "A plugin was found but could not be started",
status_interrupted: []const u8 = "Interrupted (Ctrl-C)",

/// Writes `template` with `{n}` replaced by `args[n]`; a reference past the end of `args`
/// is written as is. The same as a check's reason (`field.render`).
pub const render = @import("field").render;

/// `render` into a new string in `arena`.
pub fn allocRender(
    arena: Allocator,
    template: []const u8,
    args: []const []const u8,
) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    render(&out.writer, template, args) catch return error.OutOfMemory;
    return out.written();
}

const testing = std.testing;

test render {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(&out.writer, "{1} before {0}, {{literal}}, {9}, {x}", &.{ "a", "b" });
    try testing.expectEqualStrings("b before a, {literal}}, {9}, {x}", out.written());
}

test "every English template renders its own arguments" {
    // A template naming an argument its callers never pass would print `{n}` to users.
    inline for (@typeInfo(Messages).@"struct".field_names) |name| {
        const template = @field(english, name);
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try render(&out.writer, template, &.{ "a", "b", "c", "d" });
        try testing.expect(std.mem.indexOf(u8, out.written(), "{") == null);
    }
}
