//! `command(spec)`: turns a declarative description into a `Command`, at compile time.
//!
//! ```zig
//! const serve = cli.command(.{
//!     .name = "serve",
//!     .summary = "Start the server",
//!     .flags = cli.flags(ServeFlags, Specs, .{ .fields = .{ .port = .{ .short = 'p' } } }),
//!     .args = .{ .max = 1, .usage = "[dir]" },
//!     .run = runServe, // fn (ctx: *cli.Context, flags: ServeFlags) !void
//! });
//! ```
//!
//! `.flags` and `.persistent_flags` are a flag set (`cli.flags`, see `sets.zig`) or a plain
//! struct, every field a flag under its own name. What each field means comes from
//! `field` specs; how it is spelled, from the set's options.
//!
//! `.args` is either `.{ .min, .max, .usage, ... }` (see `Command.Args`), with the words in
//! `ctx.args`, or a positional set (`cli.args`) or plain struct, one field per positional,
//! decoded like flags:
//!
//! ```zig
//! const SetArgs = struct { key: []const u8, value: ?[]const u8 = null };
//! fn runSet(ctx: *cli.Context, flags: SetFlags, args: SetArgs) !void { ... }
//! ```
//!
//! Fields without a default (or `?`) are required and come first; the last field may be a
//! list (`[]const T`) taking the remaining words. The usage line (`<key> [value]`), the
//! counts, and completion of enum fields follow from the struct. A handler may take the
//! arguments after the flags, or alone after the context; `ctx.positionals(T)` decodes
//! them anywhere.
//!
//! A value given for a flag is checked as it is parsed, against its type and its field's
//! checks; checks across a struct's fields run before the command's hooks
//! (`Command.check`), and every failure is reported, not just the first.
//!
//! `.settings = .{ .field = .config, .load = load }` names a field of the flags struct
//! that holds settings read from configuration too: its flags are never required on the
//! command line (a file may set them), its checks are left to whatever `load` decodes
//! them with (`cfg`, say), and the handler gets what `load` returns in that field. `load`
//! is `fn (*cli.Context) !T`; the flags given are in `ctx.changedFlags()`, each with the
//! field's path under the settings as its `key`. `.sources` may say, for help, where else
//! each can be set: `.{ .{ "port", "$PORT, port in app.toml" } }`.

const std = @import("std");
const assert = std.debug.assert;
const Command = @import("Command.zig");
const Context = @import("Context.zig");
const Flag = @import("Flag.zig");
const values = @import("values.zig");
const text = @import("text.zig");
const Messages = @import("Messages.zig");
const i18n = @import("i18n.zig");
const sets = @import("sets.zig");
const field_ = @import("field");

const spec_fields = [_][]const u8{
    "name",               "summary",             "description",   "aliases",
    "examples",           "group",               "hidden",        "deprecated",
    "flags",              "persistent_flags",    "args",          "settings",
    "subcommands",        "run",                 "pre_run",       "post_run",
    "persistent_pre_run", "persistent_post_run", "topic",         "cleanup",
    "confirm",            "dry_run",             "output",        "feature",
    "logging",            "repl",                "exit_statuses",
};

/// The flags `.confirm`, `.dry_run`, `.output`, and `.logging` add, and `App.color_flag`.
const Builtins = struct {
    yes: bool = false,
    dry_run: bool = false,
    output: Output = .text,
    verbose: u8 = 0,
    log_level: ?LogLevel = null,
    color: ColorChoice = .auto,
};

const builtin_set = sets.flags(Builtins, field_.Set(.{field_.Spec(Builtins){ .fields = .{
    .yes = .{ .help = Messages.english.yes_flag },
    .dry_run = .{ .help = Messages.english.dry_run_flag },
    .output = .{ .help = Messages.english.output_flag },
    .verbose = .{ .help = Messages.english.verbose_flag },
    .log_level = .{ .help = Messages.english.log_level_flag },
    .color = .{ .help = Messages.english.color_flag },
} }}), .{ .fields = .{
    .yes = .{ .short = 'y' },
    .output = .{ .short = 'o' },
    .verbose = .{ .short = 'v', .count = true },
    .log_level = .{ .value_name = "level" },
    .color = .{ .value_name = "when" },
} });

/// What `--log-level` chooses, least severe first; see `Context.log`.
pub const LogLevel = enum { trace, debug, info, warn, @"error" };

/// What `-o`/`--output` chooses; see `output.zig`.
pub const Output = enum { text, json, yaml, jsonl };

/// What `--color` chooses (`App.color_flag`): `auto` follows the environment and the
/// terminal; `always` and `never` override them.
pub const ColorChoice = enum { auto, always, never };

const builtin_flags = builtin_set.list;

/// `--color`, which `App.color_flag` adds to the root.
pub const color_flag = builtin_flags[5];

/// Builds a `Command` from `spec`. Must be evaluated at compile time; the result is
/// usually stored in a `const`.
pub fn command(comptime spec: anytype) Command {
    comptime {
        const S = @TypeOf(spec);
        const named = @hasField(S, "name");
        const where = if (named) "cli.command(\"" ++ spec.name ++ "\"): " else "cli.command: ";
        for (@typeInfo(S).@"struct".field_names) |field| {
            for (spec_fields) |known| {
                if (std.mem.eql(u8, field, known)) break;
            } else @compileError(where ++ "unknown spec field '" ++ field ++ "'" ++
                didYouMean(field, spec_fields));
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
            sets.ArgSet(spec.args)
        else
            null;
        const settings: ?[]const u8 = if (@hasField(S, "settings")) blk: {
            if (!@hasField(S, "flags")) @compileError(where ++ ".settings needs .flags");
            break :blk @tagName(spec.settings.field);
        } else null;
        const Flags: ?type = if (@hasField(S, "flags")) sets.FlagSet(spec.flags) else null;
        const Persistent: ?type = if (@hasField(S, "persistent_flags"))
            sets.FlagSet(spec.persistent_flags)
        else
            null;
        if (Flags) |F| {
            result.flags = if (settings) |name| settled(F.list, name, sourcesOf(spec)) else F.list;
            result.constraints = F.constraints;
        }
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
        if (Persistent) |P| {
            result.persistent_flags = P.list;
            result.constraints = merge(result.constraints, P.constraints);
        }
        // `-v` and `--log-level`, for this command and every one under it.
        if (@hasField(S, "logging") and spec.logging) {
            result.persistent_flags = result.persistent_flags ++ builtin_flags[3..5].*;
        }
        if (@hasField(S, "subcommands")) result.subcommands = listOf(spec.subcommands);
        const load = if (@hasField(S, "settings")) spec.settings.load else {};
        for ([_][]const u8{
            "run",
            "pre_run",
            "post_run",
            "persistent_pre_run",
            "persistent_post_run",
            "cleanup",
        }) |hook| {
            if (@hasField(S, hook)) {
                @field(result, hook) = handler(
                    spec.name,
                    @field(spec, hook),
                    Positionals,
                    Flags,
                    settings,
                    load,
                );
            }
        }
        if (Flags != null or Persistent != null or Positionals != null) {
            result.check = checker(Flags, Persistent, Positionals, settings);
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
    if (@TypeOf(args) == type) return sets.ArgSet(args).command_args;
    if (@TypeOf(args) == Command.Args) return args;
    var result: Command.Args = .{};
    for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
        if (std.mem.eql(u8, field, "complete")) {
            result.complete = completer("cli.command(\"" ++ name ++ "\")", args.complete);
        } else if (@hasField(Command.Args, field)) {
            @field(result, field) = @field(args, field);
        } else {
            @compileError("cli.command(\"" ++ name ++ "\"): unknown field '" ++ field ++
                "' in " ++ @typeName(Command.Args) ++
                didYouMean(field, @typeInfo(Command.Args).@"struct".field_names));
        }
    }
    return result;
}

fn completer(comptime where: []const u8, comptime function: anytype) Command.Completer {
    return sets.completer(where, function);
}

fn listOf(comptime list: anytype) []const Command {
    var out: [list.len]Command = undefined;
    for (0..list.len) |i| out[i] = list[i];
    const final = out;
    return &final;
}

/// Wraps `function` as a `Handler`: `fn (*Context) !void`, `fn (*Context, Flags) !void`,
/// or, with typed positionals `Positionals`, `fn (*Context, Positionals) !void` and
/// `fn (*Context, Flags, Positionals) !void`. Flags and positionals are decoded first; the
/// command's own flags get their `.settings` from `load`.
fn handler(
    comptime name: []const u8,
    comptime function: anytype,
    comptime Positionals: ?type,
    comptime Flags: ?type,
    comptime settings: ?[]const u8,
    comptime load: anytype,
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
    const Args = if (Positionals) |P| P.Value else void;
    return switch (info.param_types.len) {
        1 => &struct {
            fn call(ctx: *Context) anyerror!void {
                return function(ctx);
            }
        }.call,
        2 => if (Positionals != null and info.param_types[1] == Args) &struct {
            fn call(ctx: *Context) anyerror!void {
                return function(ctx, try ctx.positionals(Args));
            }
        }.call else &struct {
            const Param = info.param_types[1].?;
            fn call(ctx: *Context) anyerror!void {
                return function(ctx, try decodeFlags(ctx, Param, Flags, settings, load));
            }
        }.call,
        3 => if (Positionals != null and info.param_types[2] == Args) &struct {
            const Param = info.param_types[1].?;
            fn call(ctx: *Context) anyerror!void {
                const flags = try decodeFlags(ctx, Param, Flags, settings, load);
                return function(ctx, flags, try ctx.positionals(Args));
            }
        }.call else @compileError(where ++
            "a handler's third parameter must be the .args struct type"),
        else => @compileError(where ++
            "a handler takes (*cli.Context), (*cli.Context, Flags), or " ++
            "(*cli.Context, Flags, Args)"),
    };
}

/// The flags struct `Param`, with the settings `load` reads when it is the command's own.
fn decodeFlags(
    ctx: *Context,
    comptime Param: type,
    comptime Flags: ?type,
    comptime settings: ?[]const u8,
    comptime load: anytype,
) !Param {
    var flags = try ctx.flags(Param);
    if (settings) |name| if (Flags) |F| if (F.Value == Param) {
        @field(flags, name) = try load(ctx);
    };
    return flags;
}

/// The command's check pass: decodes its flags and positionals and runs the checks that
/// need a whole value, reporting each failure; the settings' are left to `load`.
fn checker(
    comptime Flags: ?type,
    comptime Persistent: ?type,
    comptime Positionals: ?type,
    comptime settings: ?[]const u8,
) Command.Handler {
    return &struct {
        fn call(ctx: *Context) anyerror!void {
            var failures: usize = 0;
            if (Flags) |F| {
                failures += try checkFlags(F, ctx, if (settings) |name| &.{name} else &.{});
            }
            if (Persistent) |P| failures += try checkFlags(P, ctx, &.{});
            if (Positionals) |A| {
                const value = try ctx.positionals(A.Value);
                const report: Report = .{ .ctx = ctx, .arg_names = comptime argNames(A) };
                failures += try field_.validateExcept(
                    A.Value,
                    A.Specs,
                    .every,
                    value,
                    report,
                    &.{},
                );
            }
            if (failures > 0) return ctx.usageFailed();
        }
    }.call;
}

fn argNames(comptime A: type) []const [2][]const u8 {
    var out: []const [2][]const u8 = &.{};
    for (@typeInfo(A.Value).@"struct".field_names, A.command_args.positionals) |name, p| {
        out = out ++ .{[2][]const u8{ name, p.name }};
    }
    return out;
}

fn checkFlags(comptime F: type, ctx: *Context, comptime skip: []const []const u8) !usize {
    const T = F.Value;
    const value = try ctx.flags(T);
    var failures: usize = 0;
    // A choice's variant may need a flag only once it is picked.
    inline for (F.list) |flag| {
        if (comptime flag.choice != null and field_.isRequired(T, flag.field) and
            !skipped(skip, flag.field))
        {
            if (field_.getAt(T, flag.field, &value) != null and !wasGiven(ctx, &flag)) {
                failures += 1;
                const message = try Messages.allocRender(
                    ctx.arena,
                    ctx.messages.required_flag,
                    &.{flag.name},
                );
                ctx.invalid("{s}", .{message});
            }
        }
    }
    if (failures > 0) return failures;
    const report: Report = .{ .ctx = ctx, .flags = F.list, .groups = F.groups };
    // A value given was checked as it was parsed; defaults are the program's own.
    return field_.validateExcept(T, F.Specs, .whole, value, report, skip);
}

fn skipped(comptime skip: []const []const u8, comptime path: []const u8) bool {
    for (skip) |s| if (std.mem.startsWith(u8, path, s) and
        (path.len == s.len or path[s.len] == '.')) return true;
    return false;
}

fn wasGiven(ctx: *const Context, flag: *const Flag) bool {
    for (ctx.occurrences) |occurrence| {
        if (std.mem.eql(u8, occurrence.flag.field, flag.field) and
            std.mem.eql(u8, occurrence.flag.owner, flag.owner)) return true;
    }
    return false;
}

/// Names a failed check by what the user typed: `--public-port: must be at least 1`,
/// `--public-*: ...` for a group, `<src>: ...` for a positional, `--tag (2nd value): ...`.
const Report = struct {
    ctx: *Context,
    flags: []const Flag = &.{},
    groups: []const sets.Group = &.{},
    /// For positionals: each field's name and the name usage shows.
    arg_names: []const [2][]const u8 = &.{},

    pub fn fail(
        r: Report,
        at: []const field_.Segment,
        message: []const u8,
        about: ?field_.About,
    ) !void {
        var path_buffer: [256]u8 = undefined;
        var path: std.Io.Writer = .fixed(&path_buffer);
        var index: ?usize = null;
        for (at) |segment| switch (segment) {
            .field => |name| path.print(
                "{s}{s}",
                .{ if (path.end == 0) "" else ".", name },
            ) catch {},
            .index => |i| index = i,
        };
        // A check's own words, in the user's language when the app translates them.
        const said = try i18n.filledIn(r.ctx.translation, r.ctx.arena, message);
        if (path.end == 0) return r.ctx.invalid("{s}", .{said});
        var label_buffer: [256]u8 = undefined;
        var label = r.labelOf(path.buffered(), &label_buffer);
        if (index) |i| label = try std.fmt.allocPrint(
            r.ctx.arena,
            "{s} ({f} value)",
            .{ label, field_.ordinal(i + 1) },
        );
        const m = r.ctx.messages;
        const a = about orelse return r.ctx.invalid("{s}: {s}", .{ label, said });
        const arena = r.ctx.arena;
        const line = switch (a) {
            .min => |b| try Messages.allocRender(arena, m.value_at_least, &.{ label, b.text }),
            .max => |b| try Messages.allocRender(arena, m.value_at_most, &.{ label, b.text }),
            .min_len => |n| try Messages.allocRender(
                arena,
                m.value_too_short,
                &.{ label, try std.fmt.allocPrint(arena, "{d}", .{n}) },
            ),
            .max_len => |n| try Messages.allocRender(
                arena,
                m.value_too_long,
                &.{ label, try std.fmt.allocPrint(arena, "{d}", .{n}) },
            ),
            .one_of => |choices| try Messages.allocRender(
                arena,
                m.value_one_of,
                &.{ label, try std.mem.join(arena, ", ", choices) },
            ),
            .glob => |pattern| try Messages.allocRender(
                arena,
                m.value_must_match,
                &.{ label, pattern },
            ),
        };
        r.ctx.invalid("{s}", .{line});
    }

    fn labelOf(r: Report, path: []const u8, buffer: []u8) []const u8 {
        for (r.flags) |flag| if (std.mem.eql(u8, flag.field, path)) {
            return std.fmt.bufPrint(buffer, "--{s}", .{flag.name}) catch path;
        };
        for (r.groups) |group| if (std.mem.eql(u8, group.path, path)) {
            if (group.prefix.len == 0) return path;
            return std.fmt.bufPrint(buffer, "--{s}-*", .{group.prefix}) catch path;
        };
        for (r.arg_names) |pair| if (std.mem.eql(u8, pair[0], path)) {
            return std.fmt.bufPrint(buffer, "<{s}>", .{pair[1]}) catch path;
        };
        return path;
    }
};

/// The flags of a `.settings` field: never required on the command line, each with its
/// field's path below the settings as its configuration key, and where else it is set.
fn settled(
    comptime list: []const Flag,
    comptime name: []const u8,
    comptime sources: []const [2][]const u8,
) []const Flag {
    var out: [list.len]Flag = list[0..list.len].*;
    for (&out) |*flag| {
        if (!std.mem.startsWith(u8, flag.field, name ++ ".")) continue;
        flag.required = false;
        flag.key = flag.field[name.len + 1 ..];
        for (sources) |source| if (std.mem.eql(u8, source[0], flag.key.?)) {
            flag.also = source[1];
        };
    }
    const final = out;
    return &final;
}

fn sourcesOf(comptime spec: anytype) []const [2][]const u8 {
    if (!@hasField(@TypeOf(spec.settings), "sources")) return &.{};
    var out: []const [2][]const u8 = &.{};
    for (spec.settings.sources) |source| out = out ++ .{[2][]const u8{ source[0], source[1] }};
    return out;
}

fn merge(comptime a: Command.Constraints, comptime b: Command.Constraints) Command.Constraints {
    return .{
        .exclusive = a.exclusive ++ b.exclusive,
        .together = a.together ++ b.together,
        .one_required = a.one_required ++ b.one_required,
    };
}

/// The flags of a plain flags struct, for building a `Command` by hand; with specs and
/// options, `cli.flags(T, Specs, options).list`.
pub fn flagsOf(comptime T: type) []const Flag {
    return sets.FlagSet(T).list;
}

/// `; did you mean 'x'?` for the candidate `text.suggest` picks for `input`, or nothing.
fn didYouMean(comptime input: []const u8, comptime candidates: anytype) []const u8 {
    comptime {
        // Each comparison branches per pair of bytes; this only runs on the way to an error.
        @setEvalBranchQuota(1_000_000);
        var names: [candidates.len][]const u8 = undefined;
        for (&names, candidates) |*out, candidate| out.* = candidate;
        const best = text.suggest(input, &names) orelse return "";
        return "; did you mean '" ++ best ++ "'?";
    }
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
    };
    const Specs = field_.Set(.{field_.Spec(Flags){ .fields = .{
        .port = .{ .help = "Port" },
        .tag = .{ .secret = true },
    } }});
    const flags = comptime sets.flags(Flags, Specs, .{ .fields = .{
        .port = .{ .short = 'p', .env = "PORT" },
        .verbose = .{ .short = 'v', .count = true },
        .tag = .{ .split = ',' },
    } }).list;
    try testing.expectEqual(7, flags.len);
    try testing.expectEqualStrings("port", flags[0].name);
    try testing.expectEqualStrings("Port", flags[0].help);
    try testing.expectEqual('p', flags[0].short.?);
    try testing.expectEqualStrings("PORT", flags[0].env.?);
    try testing.expect(!flags[0].required);
    try testing.expect(flags[1].required);
    try testing.expectEqualStrings("dev|prod", flags[2].value_name);
    try testing.expectEqual(2, flags[2].choices.len);
    try testing.expect(flags[3].repeatable and flags[3].secret);
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
    // A plain struct: every field a flag under its own name.
    try testing.expectEqualStrings("verbose", flagsOf(Flags)[4].name);
    try testing.expectEqual(Flag.Kind.value, flagsOf(Flags)[4].kind);
}

fn noop(_: *Context) !void {}

test command {
    const Flags = struct { json: bool = false, yaml: bool = false };
    const root = comptime command(.{
        .name = "app",
        .summary = "An app",
        .flags = sets.flags(Flags, field_.none, .{ .exclusive = &.{&.{ .json, .yaml }} }),
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
    try testing.expect(root.check != null);
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
        .flags = sets.flags(Flags, field_.none, .{
            .together = &.{&.{.all}},
            .one_required = &.{&.{.all}},
        }),
        .persistent_flags = Global,
        .args = Command.Args{ .max = null, .usage = "[x...]" },
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
    try testing.expectEqual(null, bare.check);
}

test "options override names; specs give help and deprecation" {
    const Flags = struct {
        dry_run: bool = true,
        out: []const u8 = "",
        ids: ?[]const u32 = null,
        level: u8 = 2,
        quiet: u8 = 0,
        ratio: f32,
    };
    const Specs = field_.Set(.{field_.Spec(Flags){ .fields = .{
        .dry_run = .{ .help = "Only print" },
        .quiet = .{ .deprecated = "gone" },
    } }});
    const flags = comptime sets.flags(Flags, Specs, .{ .fields = .{
        .dry_run = .{ .hidden = true },
        .out = .{ .name = "output", .value_name = "file" },
        .level = .{ .count = true },
        .quiet = .{ .count = true },
    } }).list;
    try testing.expectEqualStrings("dry-run", flags[0].name);
    try testing.expectEqualStrings("dry_run", flags[0].field);
    try testing.expect(flags[0].hidden);
    try testing.expectEqualStrings("Only print", flags[0].help);
    try testing.expectEqualStrings("", flags[0].value_name);
    try testing.expectEqualStrings("output", flags[1].name);
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
}

test "an .internal field is state, not a flag; .settings give keys and never require" {
    const Config = struct { jobs: u8, region: []const u8 = "eu" };
    const State = struct {
        config: Config = .{ .jobs = 4 },
        found: usize = 0,
    };
    const set = sets.flags(State, field_.none, .{ .fields = .{
        .config = .{ .name = "" },
        .found = .{ .internal = true },
    } });
    try testing.expectEqual(2, set.list.len);
    const loadConfig = struct {
        fn load(_: *Context) !Config {
            return .{ .jobs = 1 };
        }
    }.load;
    const cmd = comptime command(.{
        .name = "app",
        .flags = set,
        .settings = .{
            .field = .config,
            .load = loadConfig,
            .sources = .{.{ "jobs", "$JOBS" }},
        },
        .run = noop,
    });
    try testing.expectEqualStrings("jobs", cmd.flags[0].name);
    try testing.expectEqualStrings("jobs", cmd.flags[0].key.?);
    try testing.expectEqualStrings("$JOBS", cmd.flags[0].also);
    try testing.expect(!cmd.flags[0].required);
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
