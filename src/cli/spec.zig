//! `command(spec)`: turns a declarative description into a `Command`, at compile time.
//!
//! ```zig
//! const serve = cli.command(.{
//!     .name = "serve",
//!     .summary = "Start the server",
//!     .flags = ServeFlags,
//!     .args = .{ .max = 1, .usage = "[dir]" },
//!     .run = runServe, // fn (ctx: *cli.Context, flags: ServeFlags) !void
//! });
//! ```
//!
//! `.args` is either `.{ .min, .max, .usage, ... }` (see `Command.Args`), with the words in
//! `ctx.args`, or a struct type with one field per positional, decoded like flags:
//!
//! ```zig
//! const SetArgs = struct { key: []const u8, value: ?[]const u8 = null };
//! fn runSet(ctx: *cli.Context, flags: SetFlags, args: SetArgs) !void { ... }
//! ```
//!
//! Fields without a default (or `?`) are required and come first; the last field may be a
//! list (`[]const T`) taking the remaining words. The usage line (`<key> [value]`), the
//! counts, and completion of enum fields follow from the struct; `meta` may give a field a
//! `.name` for usage, a `.help` for the "Arguments" section of help, a `.complete`
//! function, and a `.prompt` to ask for a missing required one with, as for flags. A
//! handler may take the arguments after the flags, or alone after the context;
//! `ctx.positionals(T)` decodes them anywhere.
//!
//! Every field of the flags struct becomes a flag, unless its meta says `.internal`. The
//! struct may refine its fields with `pub const meta`:
//!
//! | option        | effect                                                      |
//! |---------------|-------------------------------------------------------------|
//! | `.short`      | single-letter spelling, `'p'` for `-p`                      |
//! | `.help`       | text in help                                                |
//! | `.name`       | long name, instead of the field name in kebab case          |
//! | `.value_name` | placeholder in help, instead of one derived from the type   |
//! | `.env`        | environment variable used when the flag is absent           |
//! | `.count`      | on an integer field: count occurrences (`-vvv`)             |
//! | `.split`      | on a list field: also split each value on this byte         |
//! | `.hidden`     | accepted but not shown in help or completion                |
//! | `.deprecated` | accepted, with this notice printed when used                |
//! | `.aliases`    | other long names accepted, such as a name before a rename   |
//! | `.min`, `.max`| inclusive bounds on a numeric value                         |
//! | `.min_len`, `.max_len` | inclusive bounds on a string's length, in characters |
//! | `.requires`   | other flags (long names) that must be given with this one   |
//! | `.feature`    | the flag exists only while the feature is on (`App.feature_enabled`) |
//! | `.one_of`     | the values a string accepts, checked, completed, and in help |
//! | `.complete`   | `fn (*Context, prefix) ![]const Candidate`: values for completion |
//! | `.prompt`     | label to ask with when the required flag is missing interactively |
//! | `.secret`     | never shown: not echoed, redacted in help, docs, errors, and `cfg` |
//! | `.key`        | the configuration key `App.defaults` reads and `bindFlags` sets |
//! | `.internal`   | not a flag: the field is state only (a `cli.Flow`'s), keeping its default |
//!
//! The flags struct may also declare `pub fn validate(flags: T, ctx: *Context) !void` for
//! checks across fields; `ctx.flags(T)` calls it after decoding, and it reports problems
//! with `ctx.usageError`.
//!
//! Options this module does not know are ignored, so one struct can carry metadata for both
//! `cli` and `cfg`. Entries naming no field are a compile error.

const std = @import("std");
const assert = std.debug.assert;
const Command = @import("Command.zig");
const Context = @import("Context.zig");
const Flag = @import("Flag.zig");
const values = @import("values.zig");
const text = @import("text.zig");
const Messages = @import("Messages.zig");

const spec_fields = [_][]const u8{
    "name",          "summary",          "description",        "aliases",
    "examples",      "group",            "hidden",             "deprecated",
    "flags",         "persistent_flags", "args",               "exclusive",
    "together",      "one_required",     "subcommands",        "run",
    "pre_run",       "post_run",         "persistent_pre_run", "persistent_post_run",
    "topic",         "cleanup",          "confirm",            "dry_run",
    "output",        "feature",          "logging",            "repl",
    "exit_statuses",
};

/// The flags `.confirm`, `.dry_run`, `.output`, and `.logging` add, and `App.color_flag`.
const Builtins = struct {
    yes: bool = false,
    dry_run: bool = false,
    output: Output = .text,
    verbose: u8 = 0,
    log_level: ?LogLevel = null,
    color: ColorChoice = .auto,

    pub const meta = .{
        .yes = .{ .short = 'y', .help = Messages.english.yes_flag },
        .dry_run = .{ .help = Messages.english.dry_run_flag },
        .output = .{ .short = 'o', .help = Messages.english.output_flag },
        .verbose = .{ .short = 'v', .count = true, .help = Messages.english.verbose_flag },
        .log_level = .{ .help = Messages.english.log_level_flag, .value_name = "level" },
        .color = .{ .help = Messages.english.color_flag, .value_name = "when" },
    };
};

/// What `--log-level` chooses, least severe first; see `Context.log`.
pub const LogLevel = enum { trace, debug, info, warn, @"error" };

/// What `-o`/`--output` chooses; see `output.zig`.
pub const Output = enum { text, json, yaml, jsonl };

/// What `--color` chooses (`App.color_flag`): `auto` follows the environment and the
/// terminal; `always` and `never` override them.
pub const ColorChoice = enum { auto, always, never };

const builtin_flags = flagsOf(Builtins);

/// `--color`, which `App.color_flag` adds to the root.
pub const color_flag = builtin_flags[5];

/// Builds a `Command` from `spec`. Must be evaluated at compile time; the result is
/// usually stored in a `const`.
pub fn command(comptime spec: anytype) Command {
    comptime {
        const S = @TypeOf(spec);
        for (@typeInfo(S).@"struct".field_names) |field| {
            for (spec_fields) |known| {
                if (std.mem.eql(u8, field, known)) break;
            } else @compileError("cli.command: unknown spec field '" ++ field ++ "'");
        }
        if (!@hasField(S, "name")) @compileError("cli.command: a command needs a .name");

        var result: Command = .{ .name = spec.name };
        const plain = [_][]const u8{
            "summary", "description", "aliases",    "examples",
            "group",   "hidden",      "deprecated", "topic",
            "dry_run", "output",      "feature",    "repl",
        };
        for (plain) |field| {
            if (@hasField(S, field)) @field(result, field) = @field(spec, field);
        }
        if (@hasField(S, "exit_statuses")) {
            const given = spec.exit_statuses;
            var statuses: [given.len]Command.ExitStatus = undefined;
            for (&statuses, 0..) |*status, i| {
                status.* = .{ .code = given[i].code, .meaning = given[i].meaning };
            }
            const final = statuses;
            result.exit_statuses = &final;
        }
        // `.confirm = true` only adds `--yes`, below: the handler asks (`ctx.confirm`).
        if (@hasField(S, "confirm") and @TypeOf(spec.confirm) != bool) {
            result.confirm = spec.confirm;
        }
        if (@hasField(S, "args")) result.args = argsOf(spec.name, spec.args);
        const Positionals: ?type = if (@hasField(S, "args") and @TypeOf(spec.args) == type)
            spec.args
        else
            null;
        if (@hasField(S, "flags")) result.flags = flagsOf(spec.flags);
        for ([_]struct { []const u8, usize }{
            .{ "confirm", 0 },
            .{ "dry_run", 1 },
            .{ "output", 2 },
        }) |pair| {
            const wanted = @hasField(S, pair[0]) and switch (@TypeOf(@field(spec, pair[0]))) {
                bool => @field(spec, pair[0]),
                else => true,
            };
            if (wanted) result.flags = result.flags ++ .{builtin_flags[pair[1]]};
        }
        if (@hasField(S, "persistent_flags")) {
            result.persistent_flags = flagsOf(spec.persistent_flags);
        }
        // `-v` and `--log-level`, for this command and every one under it.
        if (@hasField(S, "logging") and spec.logging) {
            result.persistent_flags = result.persistent_flags ++ builtin_flags[3..5].*;
        }
        if (@hasField(S, "subcommands")) result.subcommands = listOf(spec.subcommands);
        for ([_][]const u8{
            "run",
            "pre_run",
            "post_run",
            "persistent_pre_run",
            "persistent_post_run",
            "cleanup",
        }) |hook| {
            if (@hasField(S, hook)) {
                @field(result, hook) = handler(spec.name, @field(spec, hook), Positionals);
            }
        }
        for ([_][]const u8{ "exclusive", "together", "one_required" }) |kind| {
            if (@hasField(S, kind)) {
                const groups: []const []const []const u8 = @field(spec, kind);
                for (groups) |group| for (group) |name| checkFlagName(result, name);
                @field(result.constraints, kind) = groups;
            }
        }
        checkDuplicates(result);
        const final = result;
        return final;
    }
}

/// Copies the fields of an anonymous struct literal into a `T`.
fn coerce(comptime T: type, comptime value: anytype) T {
    if (@TypeOf(value) == T) return value;
    var result: T = .{};
    for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) {
            @compileError("cli: unknown field '" ++ name ++ "' in " ++ @typeName(T));
        }
        @field(result, name) = @field(value, name);
    }
    return result;
}

/// `coerce` for `.args`, accepting `.complete` as a function or a pointer to one, or a
/// struct type of typed positionals.
fn argsOf(comptime name: []const u8, comptime args: anytype) Command.Args {
    if (@TypeOf(args) == type) return typedArgs(name, args);
    if (@TypeOf(args) == Command.Args) return args;
    var result: Command.Args = .{};
    for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
        if (std.mem.eql(u8, field, "complete")) {
            result.complete = completer("cli.command(\"" ++ name ++ "\")", args.complete);
        } else if (@hasField(Command.Args, field)) {
            @field(result, field) = @field(args, field);
        } else {
            @compileError("cli: unknown field '" ++ field ++ "' in " ++ @typeName(Command.Args));
        }
    }
    return result;
}

/// The `Args` of a struct of typed positionals.
fn typedArgs(comptime name: []const u8, comptime T: type) Command.Args {
    const where = "cli.command(\"" ++ name ++ "\"): ";
    if (@typeInfo(T) != .@"struct") @compileError(where ++ ".args must be a struct type");
    checkMeta(T);
    const info = @typeInfo(T).@"struct";
    var min: usize = 0;
    var max: ?usize = info.field_names.len;
    var usage: []const u8 = "";
    var optional_seen = false;
    var positionals: [info.field_names.len]Command.Positional = undefined;
    for (info.field_names, info.field_types, info.field_attrs, 0..) |field, Field, attrs, i| {
        const label = positionalName(T, field);
        const optional = @typeInfo(Field) == .optional or attrs.default_value_ptr != null;
        const list = values.isList(if (@typeInfo(Field) == .optional)
            @typeInfo(Field).optional.child
        else
            Field);
        _ = values.checker(values.Element(Field)); // Rejects unsupported types here.
        if (list and i + 1 != info.field_names.len) {
            @compileError(where ++ "only the last positional may be a list: " ++ field);
        }
        if (!optional and optional_seen) {
            @compileError(where ++ "required positional " ++ field ++ " follows an optional one");
        }
        if (optional) optional_seen = true else min += 1;
        if (list) max = null;
        const piece = if (list and optional)
            "[" ++ label ++ "...]"
        else if (list)
            "<" ++ label ++ ">..."
        else if (optional)
            "[" ++ label ++ "]"
        else
            "<" ++ label ++ ">";
        usage = usage ++ (if (i > 0) " " else "") ++ piece;
        positionals[i] = .{
            .name = label,
            .value_type = values.valueType(values.Element(Field)),
            .choices = values.choices(values.Element(Field)),
            .required = !optional,
            .repeatable = list,
            .help = option(T, field, "help", @as([]const u8, "")),
            .prompt = option(T, field, "prompt", @as(?[]const u8, null)),
            .value_name = values.label(values.Element(Field)),
            .check = values.checker(values.Element(Field)),
        };
    }
    const final = positionals;
    return .{
        .min = min,
        .max = max,
        .usage = usage,
        .complete = typedCompleter(T),
        .positionals = &final,
    };
}

/// The name a positional field shows in usage and messages.
pub fn positionalName(comptime T: type, comptime field: []const u8) []const u8 {
    return option(T, field, "name", text.kebab(field));
}

/// Completes each typed positional from its `.complete`, or from its enum's names.
fn typedCompleter(comptime T: type) ?Command.Completer {
    const info = @typeInfo(T).@"struct";
    const any = for (info.field_names, info.field_types) |field, Field| {
        if (hasOption(T, field, "complete") or values.choices(values.Element(Field)).len > 0) {
            break true;
        }
    } else false;
    if (!any) return null;
    return &struct {
        fn call(ctx: *Context, prefix: []const u8) anyerror![]const Command.Candidate {
            const index = ctx.args.len;
            inline for (info.field_names, info.field_types, 0..) |field, Field, i| {
                const last = i + 1 == info.field_names.len;
                if (index == i or (last and index > i and values.isList(Field))) {
                    if (comptime hasOption(T, field, "complete")) {
                        const function = comptime completer(
                            @typeName(T) ++ ".meta." ++ field,
                            @field(T.meta, field).complete,
                        );
                        return function(ctx, prefix);
                    }
                    const names = comptime values.choices(values.Element(Field));
                    const out = try ctx.arena.alloc(Command.Candidate, names.len);
                    for (out, names) |*candidate, choice| candidate.* = .{ .value = choice };
                    return out;
                }
            }
            return &.{};
        }
    }.call;
}

/// Checks a completer's signature and returns a pointer to it.
fn completer(comptime where: []const u8, comptime function: anytype) Command.Completer {
    const F = @TypeOf(function);
    const Fn = switch (@typeInfo(F)) {
        .@"fn" => F,
        .pointer => |pointer| pointer.child,
        else => @compileError(where ++ ": .complete must be a function"),
    };
    const info = @typeInfo(Fn).@"fn";
    const ok = info.param_types.len == 2 and info.param_types[0] == *Context and
        info.param_types[1] == []const u8;
    if (!ok) {
        @compileError(where ++
            ": .complete must be fn (*cli.Context, []const u8) ![]const cli.Candidate");
    }
    return &struct {
        fn call(ctx: *Context, prefix: []const u8) anyerror![]const Command.Candidate {
            return function(ctx, prefix);
        }
    }.call;
}

fn listOf(comptime list: anytype) []const Command {
    var out: [list.len]Command = undefined;
    for (0..list.len) |i| out[i] = list[i];
    const final = out;
    return &final;
}

/// Wraps `function` as a `Handler`: `fn (*Context) !void`, `fn (*Context, Flags) !void`,
/// or, with typed positionals `Positionals`, `fn (*Context, Positionals) !void` and
/// `fn (*Context, Flags, Positionals) !void`. Flags and positionals are decoded first.
fn handler(
    comptime name: []const u8,
    comptime function: anytype,
    comptime Positionals: ?type,
) Command.Handler {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    const where = "cli.command(\"" ++ name ++ "\"): ";
    if (info.param_types.len == 0 or info.param_types[0] != *Context) {
        @compileError(where ++ "a handler's first parameter must be *cli.Context");
    }
    for (info.param_types[1..]) |param| {
        if (param == null) {
            @compileError(where ++ "a handler's flags parameter needs a concrete type");
        }
    }
    return switch (info.param_types.len) {
        1 => &struct {
            fn call(ctx: *Context) anyerror!void {
                return function(ctx);
            }
        }.call,
        2 => if (Positionals != null and info.param_types[1] == Positionals) &struct {
            fn call(ctx: *Context) anyerror!void {
                return function(ctx, try ctx.positionals(Positionals.?));
            }
        }.call else &struct {
            const Flags = info.param_types[1].?;
            fn call(ctx: *Context) anyerror!void {
                return function(ctx, try ctx.flags(Flags));
            }
        }.call,
        3 => if (Positionals != null and info.param_types[2] == Positionals) &struct {
            const Flags = info.param_types[1].?;
            fn call(ctx: *Context) anyerror!void {
                const flags = try ctx.flags(Flags);
                return function(ctx, flags, try ctx.positionals(Positionals.?));
            }
        }.call else @compileError(where ++
            "a handler's third parameter must be the .args struct type"),
        else => @compileError(where ++
            "a handler takes (*cli.Context), (*cli.Context, Flags), or " ++
            "(*cli.Context, Flags, Args)"),
    };
}

/// The flags of a flags struct, one per field that is not `.internal`.
pub fn flagsOf(comptime T: type) []const Flag {
    comptime {
        if (@typeInfo(T) != .@"struct") {
            @compileError("cli: flags must be a struct, found " ++ @typeName(T));
        }
        @setEvalBranchQuota(1000 + 5000 * @typeInfo(T).@"struct".field_names.len);
        checkMeta(T);
        const info = @typeInfo(T).@"struct";
        var out: [info.field_names.len]Flag = undefined;
        var n: usize = 0;
        for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
            if (option(T, name, "internal", false)) continue;
            out[n] = flagOf(T, name, Field, attrs);
            n += 1;
        }
        const final = out[0..n].*;
        return &final;
    }
}

fn flagOf(
    comptime T: type,
    comptime field: []const u8,
    comptime Field: type,
    comptime attrs: std.builtin.Type.Struct.FieldAttributes,
) Flag {
    const Elem = values.Element(Field);
    const is_count = option(T, field, "count", false);
    if (is_count and @typeInfo(Field) != .int) {
        @compileError("cli: .count needs an integer field: " ++ field);
    }
    const kind: Flag.Kind = if (Elem == bool and !values.isList(Field))
        .bool
    else if (is_count)
        .count
    else
        .value;
    const default: ?*const Field = if (attrs.default_value_ptr) |p|
        @ptrCast(@alignCast(p))
    else
        null;
    const optional = @typeInfo(Field) == .optional;
    const list = values.isList(if (optional) @typeInfo(Field).optional.child else Field);
    const one_of = option(T, field, "one_of", @as([]const []const u8, &.{}));
    if (one_of.len > 0 and Elem != []const u8) {
        @compileError("cli: .one_of needs a string field: " ++ field);
    }
    const has_length = hasOption(T, field, "min_len") or hasOption(T, field, "max_len");
    if (has_length and Elem != []const u8) {
        @compileError("cli: .min_len and .max_len need a string field: " ++ field);
    }
    const numeric = @typeInfo(Elem) == .int or @typeInfo(Elem) == .float;
    const has_bounds = hasOption(T, field, "min") or hasOption(T, field, "max");
    if (has_bounds and (!numeric or kind != .value)) {
        @compileError("cli: .min and .max need a numeric field: " ++ field);
    }
    return .{
        .name = option(T, field, "name", text.kebab(field)),
        .aliases = option(T, field, "aliases", @as([]const []const u8, &.{})),
        .field = field,
        .kind = kind,
        .short = option(T, field, "short", @as(?u8, null)),
        .help = option(T, field, "help", @as([]const u8, "")),
        .value_name = if (kind == .value)
            option(T, field, "value_name", if (one_of.len > 0)
                joinChoices(one_of)
            else
                values.label(Elem))
        else
            "",
        .repeatable = list or kind == .count,
        .split = option(T, field, "split", @as(?u8, null)),
        .required = default == null and !optional and kind == .value and !list,
        .env = option(T, field, "env", @as(?[]const u8, null)),
        .hidden = option(T, field, "hidden", false),
        .deprecated = option(T, field, "deprecated", @as(?[]const u8, null)),
        .prompt = option(T, field, "prompt", @as(?[]const u8, null)),
        .secret = option(T, field, "secret", false),
        .key = option(T, field, "key", @as(?[]const u8, null)),
        .value_type = values.valueType(Elem),
        .choices = if (one_of.len > 0) one_of else values.choices(Elem),
        .min = if (hasOption(T, field, "min")) @as(f64, @field(T.meta, field).min) else null,
        .max = if (hasOption(T, field, "max")) @as(f64, @field(T.meta, field).max) else null,
        .min_len = option(T, field, "min_len", @as(?usize, null)),
        .max_len = option(T, field, "max_len", @as(?usize, null)),
        .requires = option(T, field, "requires", @as([]const []const u8, &.{})),
        .feature = option(T, field, "feature", @as(?[]const u8, null)),
        .complete = if (hasOption(T, field, "complete"))
            completer(@typeName(T) ++ ".meta." ++ field, @field(T.meta, field).complete)
        else
            null,
        .check = if (kind == .count) values.checker(bool) else values.checker(Elem),
        .write_default = if (default) |d| defaultWriter(Field, d.*) else null,
    };
}

fn defaultWriter(
    comptime Field: type,
    comptime value: Field,
) ?*const fn (*std.Io.Writer) std.Io.Writer.Error!void {
    if (!values.isInteresting(Field, value)) return null;
    if (@typeInfo(Field) == .int and value == 0) return null;
    return &struct {
        fn write(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try values.write(Field, value, writer);
        }
    }.write;
}

/// The value of `T.meta.<field>.<name>`, or `default`.
pub fn option(
    comptime T: type,
    comptime field: []const u8,
    comptime name: []const u8,
    comptime default: anytype,
) @TypeOf(default) {
    if (!@hasDecl(T, "meta")) return default;
    if (!@hasField(@TypeOf(T.meta), field)) return default;
    const entry = @field(T.meta, field);
    if (!@hasField(@TypeOf(entry), name)) return default;
    return @field(entry, name);
}

/// `a|b|c`, the label of a string flag with `.one_of`.
fn joinChoices(comptime choices: []const []const u8) []const u8 {
    var out: []const u8 = "";
    for (choices, 0..) |choice, i| out = out ++ (if (i == 0) "" else "|") ++ choice;
    return out;
}

/// Whether `T.meta.<field>` sets `name`.
fn hasOption(comptime T: type, comptime field: []const u8, comptime name: []const u8) bool {
    if (!@hasDecl(T, "meta")) return false;
    if (!@hasField(@TypeOf(T.meta), field)) return false;
    return @hasField(@TypeOf(@field(T.meta, field)), name);
}

/// The long name a field of `T` is spelled with.
pub fn longName(comptime T: type, comptime field: []const u8) []const u8 {
    return option(T, field, "name", text.kebab(field));
}

fn checkMeta(comptime T: type) void {
    if (!@hasDecl(T, "meta")) return;
    for (@typeInfo(@TypeOf(T.meta)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) {
            @compileError(@typeName(T) ++ ".meta names no field '" ++ name ++ "'");
        }
    }
}

fn checkFlagName(comptime cmd: Command, comptime name: []const u8) void {
    for (cmd.flags ++ cmd.persistent_flags) |flag| {
        if (std.mem.eql(u8, flag.name, name)) return;
    }
    @compileError(
        "cli.command(\"" ++ cmd.name ++ "\"): constraint names unknown flag '" ++ name ++ "'",
    );
}

fn checkDuplicates(comptime cmd: Command) void {
    const all = cmd.flags ++ cmd.persistent_flags;
    // The checks are quadratic in flags and subcommands, and each comparison of names
    // branches per byte; the default quota of 1000 runs out at about ten subcommands.
    const items = all.len + cmd.subcommands.len;
    @setEvalBranchQuota(1000 + 2000 * items * items);
    for (all, 0..) |a, i| {
        if (a.matches("help")) @compileError("cli: --help is reserved");
        for (all[i + 1 ..]) |b| {
            if (b.matches(a.name)) @compileError("cli: duplicate flag --" ++ a.name);
            for (a.aliases) |alias| {
                if (b.matches(alias)) @compileError("cli: duplicate flag --" ++ alias);
            }
            if (a.short != null and a.short == b.short) {
                @compileError("cli: duplicate short flag -" ++ .{a.short.?});
            }
        }
    }
    for (cmd.subcommands, 0..) |a, i| {
        for (cmd.subcommands[i + 1 ..]) |b| {
            if (b.matches(a.name)) @compileError("cli: duplicate subcommand " ++ a.name);
            for (a.aliases) |alias| {
                if (b.matches(alias)) @compileError("cli: duplicate subcommand " ++ alias);
            }
        }
    }
}

const testing = std.testing;

test flagsOf {
    const Flags = struct {
        port: u16 = 8080,
        host: []const u8,
        mode: enum { dev, prod } = .dev,
        tag: []const []const u8 = &.{},
        verbose: u8 = 0,
        force: bool = false,
        limit: ?u32 = null,

        pub const meta = .{
            .port = .{ .short = 'p', .help = "Port", .env = "PORT" },
            .verbose = .{ .short = 'v', .count = true },
            .tag = .{ .split = ',', .secret = true },
        };
    };
    const flags = comptime flagsOf(Flags);
    try testing.expectEqual(7, flags.len);
    try testing.expectEqualStrings("port", flags[0].name);
    try testing.expectEqual('p', flags[0].short.?);
    try testing.expectEqualStrings("PORT", flags[0].env.?);
    try testing.expect(!flags[0].required);
    try testing.expect(flags[1].required);
    try testing.expectEqualStrings("dev|prod", flags[2].value_name);
    try testing.expectEqual(2, flags[2].choices.len);
    try testing.expect(flags[3].repeatable);
    try testing.expectEqual(Flag.Kind.count, flags[4].kind);
    try testing.expectEqual(Flag.Kind.bool, flags[5].kind);
    try testing.expect(!flags[6].required);
    try testing.expect(flags[0].check("80"));
    try testing.expect(!flags[0].check("http"));

    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try flags[0].write_default.?(&writer);
    try testing.expectEqualStrings("8080", writer.buffered());
    try testing.expectEqual(null, flags[3].write_default);
    try testing.expectEqual(null, flags[5].write_default);
}

fn noop(_: *Context) !void {}

test command {
    const Flags = struct { json: bool = false, yaml: bool = false };
    const root = comptime command(.{
        .name = "app",
        .summary = "An app",
        .flags = Flags,
        .exclusive = &.{&.{ "json", "yaml" }},
        .subcommands = .{
            command(.{ .name = "a", .aliases = &.{"x"}, .run = noop }),
            command(.{ .name = "b", .run = noop }),
        },
    });
    try testing.expectEqualStrings("app", root.name);
    try testing.expectEqual(2, root.subcommands.len);
    try testing.expectEqualStrings("x", root.subcommands[0].aliases[0]);
    try testing.expect(root.subcommands[0].run != null);
    try testing.expectEqual(1, root.constraints.exclusive.len);
}

fn hookA(_: *Context) !void {}
fn hookB(_: *Context) !void {}

test "command copies every spec field" {
    const Flags = struct { all: bool = false };
    const Global = struct { quiet: bool = false };
    const cmd = comptime command(.{
        .name = "list",
        .summary = "List",
        .description = "Lists things.",
        .aliases = &.{"ls"},
        .examples = "app list",
        .group = "Query",
        .hidden = true,
        .deprecated = "use show",
        .flags = Flags,
        .persistent_flags = Global,
        .args = Command.Args{ .max = null, .usage = "[x...]" },
        .together = &.{&.{ "all", "quiet" }},
        .one_required = &.{&.{"all"}},
        .run = hookA,
        .pre_run = hookA,
        .post_run = hookB,
        .persistent_pre_run = hookA,
        .persistent_post_run = hookB,
    });
    try testing.expectEqualStrings("Lists things.", cmd.about());
    try testing.expectEqualStrings("Query", cmd.group);
    try testing.expect(cmd.hidden);
    try testing.expectEqualStrings("use show", cmd.deprecated.?);
    try testing.expectEqualStrings("all", cmd.flags[0].name);
    try testing.expectEqualStrings("quiet", cmd.persistent_flags[0].name);
    try testing.expectEqual(null, cmd.args.max);
    try testing.expectEqualStrings("[x...]", cmd.args.usage);
    try testing.expectEqual(1, cmd.constraints.together.len);
    try testing.expectEqual(1, cmd.constraints.one_required.len);
    const hooks = .{ "run", "pre_run", "post_run", "persistent_pre_run", "persistent_post_run" };
    inline for (hooks) |hook| try testing.expect(@field(cmd, hook) != null);
    try testing.expect(cmd.matches("ls"));

    const bare = comptime command(.{ .name = "bare", .summary = "Only a summary" });
    try testing.expectEqualStrings("Only a summary", bare.about());
    try testing.expectEqual(0, bare.args.max.?);
    try testing.expectEqual(null, bare.run);
}

test "meta overrides and derived flag properties" {
    const Flags = struct {
        dry_run: bool = true,
        out: []const u8 = "",
        ids: ?[]const u32 = null,
        level: u8 = 2,
        quiet: u8 = 0,
        ratio: f32,
        pub const meta = .{
            .dry_run = .{ .help = "Only print", .hidden = true },
            .out = .{ .name = "output", .value_name = "file" },
            .level = .{ .count = true },
            .quiet = .{ .count = true, .deprecated = "gone" },
            .ratio = .{ .cfg_only_option = 1 },
        };
    };
    const flags = comptime flagsOf(Flags);
    try testing.expectEqualStrings("dry-run", flags[0].name);
    try testing.expectEqualStrings("dry_run", flags[0].field);
    try testing.expect(flags[0].hidden);
    try testing.expectEqualStrings("", flags[0].value_name);
    try testing.expectEqualStrings("output", flags[1].name);
    try testing.expectEqualStrings("output", longName(Flags, "out"));
    try testing.expectEqualStrings("file", flags[1].value_name);
    try testing.expect(!flags[1].required);
    try testing.expectEqual(null, flags[1].write_default);
    try testing.expect(flags[2].repeatable);
    try testing.expect(!flags[2].required);
    try testing.expectEqualStrings("int", flags[2].value_name);
    try testing.expect(flags[2].check("7"));
    try testing.expect(!flags[2].check("-7"));
    try testing.expectEqual(Flag.Kind.count, flags[3].kind);
    try testing.expect(flags[3].repeatable);
    try testing.expectEqualStrings("gone", flags[4].deprecated.?);
    try testing.expectEqual(null, flags[4].write_default);
    try testing.expect(flags[5].required);
    try testing.expectEqualStrings("number", flags[5].value_name);

    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try flags[0].write_default.?(&writer);
    try writer.writeByte(' ');
    try flags[3].write_default.?(&writer);
    try testing.expectEqualStrings("true 2", writer.buffered());

    try testing.expectEqual(1, option(Flags, "ratio", "cfg_only_option", @as(u8, 7)));
    try testing.expectEqual(false, option(Flags, "quiet", "hidden", false));
    try testing.expectEqual(false, option(struct { a: bool }, "a", "hidden", false));
}

test "an .internal field is state, not a flag; .key names the configuration key" {
    const State = struct {
        jobs: u8 = 4,
        found: usize = 0,
        pub const meta = .{
            .jobs = .{ .key = "fetch.concurrency" },
            .found = .{ .internal = true },
        };
    };
    const flags = comptime flagsOf(State);
    try testing.expectEqual(1, flags.len);
    try testing.expectEqualStrings("jobs", flags[0].name);
    try testing.expectEqualStrings("fetch.concurrency", flags[0].key.?);
}

/// 48 fields named f0..f47, all `u8 = 0`.
fn ManyFlags() type {
    @setEvalBranchQuota(100_000);
    var names: [48][:0]const u8 = undefined;
    var types: [48]type = undefined;
    var attrs: [48]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (0..48) |i| {
        names[i] = std.fmt.comptimePrint("f{d}", .{i});
        types[i] = u8;
        attrs[i] = .{ .default_value_ptr = &@as(u8, 0) };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn manyCommands() [40]Command {
    @setEvalBranchQuota(100_000);
    var out: [40]Command = undefined;
    for (&out, 0..) |*cmd, i| cmd.* = command(.{
        .name = std.fmt.comptimePrint("command-{d}", .{i}),
        .run = noop,
    });
    return out;
}

// Built in their own evaluations, so their raised quotas do not leak into `command` below.
const many_flags = ManyFlags();
const many_commands = manyCommands();

test "large trees stay within the compile-time budget" {
    const big = comptime command(.{
        .name = "big",
        .flags = many_flags,
        .subcommands = many_commands,
    });
    try testing.expectEqual(40, big.subcommands.len);
    try testing.expectEqual(48, big.flags.len);

    // Subcommands declared inline are built in the same evaluation as their parent, which is
    // how real trees are written and where the default quota first ran out.
    const inline_tree = comptime command(.{
        .name = "inline",
        .subcommands = .{
            command(.{ .name = "command-0", .summary = "Command 0", .run = noop }),
            command(.{ .name = "command-1", .summary = "Command 1", .run = noop }),
            command(.{ .name = "command-2", .summary = "Command 2", .run = noop }),
            command(.{ .name = "command-3", .summary = "Command 3", .run = noop }),
            command(.{ .name = "command-4", .summary = "Command 4", .run = noop }),
            command(.{ .name = "command-5", .summary = "Command 5", .run = noop }),
            command(.{ .name = "command-6", .summary = "Command 6", .run = noop }),
            command(.{ .name = "command-7", .summary = "Command 7", .run = noop }),
            command(.{ .name = "command-8", .summary = "Command 8", .run = noop }),
            command(.{ .name = "command-9", .summary = "Command 9", .run = noop }),
            command(.{ .name = "command-10", .summary = "Command 10", .run = noop }),
            command(.{ .name = "command-11", .summary = "Command 11", .run = noop }),
            command(.{ .name = "command-12", .summary = "Command 12", .run = noop }),
            command(.{ .name = "command-13", .summary = "Command 13", .run = noop }),
            command(.{ .name = "command-14", .summary = "Command 14", .run = noop }),
            command(.{ .name = "command-15", .summary = "Command 15", .run = noop }),
        },
    });
    try testing.expectEqual(16, inline_tree.subcommands.len);
}
