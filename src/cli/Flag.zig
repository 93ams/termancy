//! One flag's descriptor. Plain data, normally produced at compile time from a field of a
//! flags struct (`cli.flags`) by `cli.command`; see `spec.zig`.

const std = @import("std");
const field_ = @import("field");
const Command = @import("Command.zig");

const Flag = @This();

/// How a flag takes its value.
pub const Kind = enum {
    /// `--force`, `--force=false`, `--no-force`.
    bool,
    /// `-vvv`: the number of occurrences.
    count,
    /// `--port 80`, `--port=80`, `-p80`.
    value,
};

/// What one value of a flag is, for machine-readable documentation (`docs.Format.json`).
pub const ValueType = enum {
    bool,
    int,
    float,
    string,
    /// One of `choices`.
    @"enum",
    /// A type following the `parse` convention, such as a duration.
    custom,
};

/// The long name, spelled on the command line as `--<name>`.
name: []const u8,
/// Other long names the flag accepts, such as its name before a rename. Not shown in help
/// or offered by completion.
aliases: []const []const u8 = &.{},
/// The field the flag decodes into: its dotted path in the flags struct, such as
/// `public.port` for `--public-port`, or `storage.s3.bucket` for a choice's variant.
field: []const u8,
/// The flags struct the field is in (its `@typeName`), so `Context.flags` finds the flags
/// of a struct among a command path's.
owner: []const u8 = "",
kind: Kind,
short: ?u8 = null,
help: []const u8 = "",
/// The placeholder in help: `<port>`. Empty for `bool` and `count`.
value_name: []const u8 = "",
/// May be given more than once, each occurrence adding a value.
repeatable: bool = false,
/// With `repeatable`, a single occurrence may also hold several values separated by this.
split: ?u8 = null,
required: bool = false,
/// The environment variable used when the flag is not on the command line.
env: ?[]const u8 = null,
hidden: bool = false,
/// When set, using the flag prints this notice.
deprecated: ?[]const u8 = null,
/// The type of each value. Meaningful for `value` flags; a counter's value is its count.
value_type: ValueType = .string,
/// The accepted values, for an enum or a string with `.one_of`; offered by completion and
/// shown in help.
choices: []const []const u8 = &.{},
/// What the field's built-in checks are (`field.Check`'s `about`), for help and docs:
/// bounds, lengths, patterns. For a list, its elements' (`.each`).
about: []const field_.About = &.{},
/// Runs the field's checks on one value as typed (one element, for a list): writes why it
/// is invalid to `w`, sets `about` when a built-in check failed, and returns
/// `error.Invalid`. Null when the field has no checks. Run on each value given, and on an
/// answer to a prompt; checks across fields wait for `Command.check`.
validate: ?*const fn (text: []const u8, w: *std.Io.Writer, about: *?field_.About) field_.Error!void = null,
/// For a flag of a choice's variant (`--storage-s3-bucket`): the flag naming the choice
/// (`storage`, its long name) and the variant (`s3`). Naming another variant there is an
/// error.
choice: ?[]const u8 = null,
variant: []const u8 = "",
/// Other flags (long names) that must be given when this one is (`.requires`).
requires: []const []const u8 = &.{},
/// The flag exists only when this feature is on (see `App.feature_enabled`).
feature: ?[]const u8 = null,
/// Offers values for completion, beyond `choices`.
complete: ?Command.Completer = null,
/// When the flag is required and missing in an interactive run, ask for it with this label
/// instead of failing (see `App.prompter`).
prompt: ?[]const u8 = null,
/// The value is a secret: a prompter should not echo it, and help, documentation, and
/// error messages show `redacted` in place of its default or a value given for it.
secret: bool = false,
/// Where else the value can be set, for help: `$PORT, port in app.toml` (a command's
/// `.settings` `.sources`).
also: []const u8 = "",
/// The configuration key of the flag, in full, for a flag of a command's `.settings`: the
/// field's path below the settings, which `cfg.Config.bindFlags` sets (and translates to
/// the key `cfg.settings` gives it) and `App.defaults` reads its default from.
key: ?[]const u8 = null,
/// Whether `text` is a valid value (for `value` flags, one element of it).
check: *const fn (text: []const u8) bool,
/// Writes the default value for help, or nothing when there is no interesting default.
write_default: ?*const fn (writer: *std.Io.Writer) std.Io.Writer.Error!void = null,

/// Shown in place of a secret flag's value or default; the text `cfg` redacts with too.
pub const redacted = "<redacted>";

/// `value`, or `redacted` when the flag is a secret: for text a user will read.
pub fn shownValue(flag: Flag, value: []const u8) []const u8 {
    return if (flag.secret) redacted else value;
}

/// Writes the flag's default for people to read: `redacted` for a secret. Nothing when
/// there is no interesting default.
pub fn writeDefault(flag: Flag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const write = flag.write_default orelse return;
    if (flag.secret) return writer.writeAll(redacted);
    try write(writer);
}

/// The lower bound of the field's `.min` check, if it has one.
pub fn minimum(flag: Flag) ?field_.Bound {
    for (flag.about) |a| if (a == .min) return a.min;
    return null;
}

/// The upper bound of the field's `.max` check, if it has one.
pub fn maximum(flag: Flag) ?field_.Bound {
    for (flag.about) |a| if (a == .max) return a.max;
    return null;
}

/// Whether `name` is the flag's long name or one of its aliases.
pub fn matches(flag: Flag, name: []const u8) bool {
    if (std.mem.eql(u8, flag.name, name)) return true;
    for (flag.aliases) |alias| if (std.mem.eql(u8, alias, name)) return true;
    return false;
}

/// Whether the flag consumes a value (`--port 80`), as opposed to a switch or counter.
pub fn takesValue(flag: Flag) bool {
    return flag.kind == .value;
}

/// Writes the flag's spelling for help: `-p, --port <u16>`.
pub fn writeSpelling(flag: Flag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (flag.short) |s| {
        try writer.print("-{c}, ", .{s});
    } else {
        try writer.writeAll("    ");
    }
    try writer.print("--{s}", .{flag.name});
    if (flag.takesValue()) try writer.print(" <{s}>", .{flag.value_name});
}

/// Parses the text of a boolean flag value.
pub fn parseBool(text: []const u8) ?bool {
    const truthy = [_][]const u8{ "true", "yes", "on", "1" };
    const falsy = [_][]const u8{ "false", "no", "off", "0" };
    for (truthy) |t| if (std.ascii.eqlIgnoreCase(text, t)) return true;
    for (falsy) |f| if (std.ascii.eqlIgnoreCase(text, f)) return false;
    return null;
}

fn checkBool(text: []const u8) bool {
    return parseBool(text) != null;
}

test writeSpelling {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const port: Flag = .{
        .name = "port",
        .field = "port",
        .kind = .value,
        .short = 'p',
        .value_name = "u16",
        .check = checkBool,
    };
    try port.writeSpelling(&writer);
    try std.testing.expectEqualStrings("-p, --port <u16>", writer.buffered());
}

test parseBool {
    try std.testing.expectEqual(true, parseBool("YES").?);
    try std.testing.expectEqual(false, parseBool("0").?);
    try std.testing.expectEqual(null, parseBool("maybe"));
}

test "writeSpelling without a short name or a value" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const force: Flag = .{ .name = "force", .field = "force", .kind = .bool, .check = checkBool };
    try force.writeSpelling(&writer);
    try std.testing.expectEqualStrings("    --force", writer.buffered());
    try std.testing.expect(!force.takesValue());
    try std.testing.expect(force.check("off"));
}
