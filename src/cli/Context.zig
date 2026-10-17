//! What a handler receives: I/O, allocators, the environment, output streams, the parsed
//! command line, and the application's own data.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const parse = @import("parse.zig");
const spec = @import("spec.zig");
const values = @import("values.zig");
const Messages = @import("Messages.zig");
const i18n = @import("i18n.zig");
const output_zig = @import("output.zig");
const flow = @import("flow.zig");
const Theme = @import("Theme.zig");
const term = @import("term");

const Context = @This();

io: Io,
/// For allocations that outlive the invocation or must be freed early.
gpa: Allocator,
/// Freed when the invocation ends; the usual choice inside a handler.
arena: Allocator,
environ: *const std.process.Environ.Map,
/// Standard output. Flushed by the runner after the handlers return.
out: *Io.Writer,
/// Standard error. Under `App.run`, each line shows as soon as it is written: no `flush`
/// is needed.
err: *Io.Writer,
/// Positional arguments.
args: []const []const u8,
/// The words after `--`, untouched, for a command with `args.passthrough`.
passthrough: []const []const u8 = &.{},
/// Root first, the running command last.
path: []const *const Command,
occurrences: []const parse.Occurrence,
/// The application's name, used to prefix messages.
app_name: []const u8,
/// Set by `App.data`; read with `data`.
user_data: ?*anyopaque = null,
/// `-q`/`--quiet` was given: `warn` prints nothing.
quiet: bool = false,
/// The status `exit` asked for.
exit_status: u8 = 0,
/// The sentences `usageError` and `warn` add to the message.
messages: *const Messages = &Messages.english,
/// The user's language, when the app has a translation for it (`App.translations`).
translation: ?*const i18n.Translation = null,
/// `--dry-run` was given (a command with `.dry_run = true`): change nothing, say what
/// would change.
dry_run: bool = false,
/// `-y`/`--yes` was given (a command with `.confirm`): `confirm` asks nothing.
yes: bool = false,
/// What `-o`/`--output` chose (a command with `.output = true`); see `render`.
output: OutputFormat = .text,
/// The least severe messages `log` writes: `--log-level`, else one step down from `warn`
/// per `-v` (a command under one with `.logging = true`), else `error` with `-q`.
log_level: LogLevel = .warn,
/// Wraps the handlers (`App.middleware`).
middleware: []const Middleware = &.{},
/// Standard input, for questions; null when there is none to read.
in: ?*Io.Reader = null,
/// Standard input and standard error are terminals: questions may be asked.
interactive: bool = false,
/// The terminal standard input is, for askers that change its modes (hidden answers).
terminal: ?Io.File = null,
/// How `cli.Flow` asks; null for plain lines when the run is interactive (`App.asker`).
asker: ?flow.Asker = null,
/// How many colors `out` takes: `.none` for a pipe or with `NO_COLOR`. Write styled output
/// with `style.renderFor(ctx.out, ctx.color, text)` or `paint`.
color: term.capability.Color = .none,
/// How many colors `err` takes.
err_color: term.capability.Color = .none,
/// The app's look (`App.theme`), for messages in the same style as the runner's.
theme: *const Theme = &.default,
/// `App.exit_statuses`, for `docs.exitStatuses`.
exit_statuses: []const @import("docs.zig").ExitStatus = &.{},
/// `App.plugins` is set: a plugin that cannot start exits 126.
plugins: bool = false,

/// What `-o`/`--output` chooses.
pub const OutputFormat = output_zig.Format;
/// How severe a `log` message is.
pub const LogLevel = @import("spec.zig").LogLevel;

/// Code around every command: it calls `next.run()` to go on (or does not, to stop),
/// and may act before and after, or on the error. `App.middleware` lists them, outermost
/// first.
pub const Middleware = *const fn (ctx: *Context, next: Next) anyerror!void;

/// The rest of the chain, ending in the command's hooks and handler.
pub const Next = struct {
    ctx: *Context,
    rest: []const Middleware,
    handlers: *const fn (ctx: *Context) anyerror!void,

    /// Runs the rest of the chain.
    pub fn run(next: Next) anyerror!void {
        if (next.rest.len == 0) return next.handlers(next.ctx);
        return next.rest[0](next.ctx, .{
            .ctx = next.ctx,
            .rest = next.rest[1..],
            .handlers = next.handlers,
        });
    }
};

/// Writes `value` to standard output in the format `-o`/`--output` chose: text for people,
/// JSON for programs (see `output.zig`). A struct's `pub const text_columns` picks, orders,
/// and names the columns of the text form; JSON and YAML keep every field.
pub fn render(ctx: *Context, value: anytype) output_zig.Error!void {
    try output_zig.write(ctx.arena, ctx.out, ctx.output, value);
}

/// Writes `text` to standard output in `style`, lowered to `ctx.color`; plain without
/// color.
pub fn paint(ctx: *Context, style: term.Style, text: []const u8) Io.Writer.Error!void {
    try Theme.paint(ctx.out, ctx.color, style, text);
}

/// Spinners, bars, and step lists on standard error (`term.live`): redrawn in place at a
/// terminal that shows color, a line per change elsewhere, nothing with `-q`. `items` must
/// outlive the result.
pub fn live(ctx: *Context, items: []const term.live.Item) term.live.Live {
    var display: term.live.Live = .detect(ctx.io, ctx.environ, .stderr(), ctx.err, items);
    // `err` is not always the process's standard error (tests); its own color decides.
    display.color = ctx.err_color;
    display.animate = display.animate and ctx.err_color != .none and !ctx.quiet;
    if (ctx.quiet) display.items = &.{};
    return display;
}

/// Returned by `fail`. The runner maps it to exit status 1 without printing anything more.
pub const Failure = error{CommandFailed};

/// Returned by `exit`. The runner ends with `ctx.exit_status` and prints nothing more.
pub const Exit = error{Exit};

/// Ends the invocation with `status`, for statuses beyond the runner's own (0 success,
/// 1 failure, 2 usage): 130 after an interrupt, a child process's status, 126/127 for a
/// command that cannot run. Anything the handler already wrote is flushed as usual. Post
/// hooks do not run, as for any failure.
pub fn exit(ctx: *Context, status: u8) Exit {
    ctx.exit_status = status;
    return error.Exit;
}

/// Returned by `usageError`. The runner maps it to exit status 2 without printing anything more.
pub const UsageFailure = error{UsageFailed};

/// The running command.
pub fn command(ctx: *const Context) *const Command {
    return ctx.path[ctx.path.len - 1];
}

/// The application data given to `App`, as `T` (a pointer type).
pub fn data(ctx: *const Context, comptime T: type) T {
    comptime assert(@typeInfo(T) == .pointer);
    return @ptrCast(@alignCast(ctx.user_data orelse @panic("cli: App.data was not set")));
}

/// Prints `<app>: <message>` to standard error and returns `error.CommandFailed`. Under
/// `-o json` or `-o jsonl`, prints `{"error": "<message>"}` instead.
pub fn fail(ctx: *Context, comptime fmt: []const u8, args: anytype) Failure {
    if (ctx.output == .json or ctx.output == .jsonl) {
        ctx.writeJsonError(std.fmt.allocPrint(ctx.arena, fmt, args) catch fmt, null);
    } else {
        ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error") catch {};
        ctx.err.print(fmt ++ "\n", args) catch {};
    }
    return error.CommandFailed;
}

/// `{"error": message, "hint": hint}` on one line of standard error, for programs reading
/// `-o json`.
pub fn writeJsonError(ctx: *Context, message: []const u8, hint: ?[]const u8) void {
    var json: std.json.Stringify = .{
        .writer = ctx.err,
        .options = .{ .emit_null_optional_fields = false },
    };
    json.write(.{ .@"error" = message, .hint = hint }) catch {};
    ctx.err.writeByte('\n') catch {};
}

/// Reports a usage error found by a handler, such as a malformed argument the parser could
/// not check: prints `<app>: <message>` and a pointer to the command's help, and returns
/// `error.UsageFailed`, which the runner maps to exit status 2. Under `-o json`, prints
/// `{"error": "<message>", "hint": "<pointer to help>"}` instead.
pub fn usageError(ctx: *Context, comptime fmt: []const u8, args: anytype) UsageFailure {
    var buffer: [512]u8 = undefined;
    var path: Io.Writer = .fixed(&buffer);
    for (ctx.path, 0..) |cmd, i| {
        path.print("{s}{s}", .{ if (i > 0) " " else "", cmd.name }) catch {};
    }
    if (ctx.output == .json or ctx.output == .jsonl) {
        var hint: Io.Writer.Allocating = .init(ctx.arena);
        Messages.render(&hint.writer, ctx.messages.run_help, &.{path.buffered()}) catch {};
        const message = std.fmt.allocPrint(ctx.arena, fmt, args) catch fmt;
        ctx.writeJsonError(message, hint.written());
        return error.UsageFailed;
    }
    ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error") catch {};
    ctx.err.print(fmt ++ "\n", args) catch {};
    var hint: Io.Writer.Allocating = .init(ctx.arena);
    Messages.render(&hint.writer, ctx.messages.run_help, &.{path.buffered()}) catch {};
    Theme.paint(ctx.err, ctx.err_color, ctx.theme.hint, hint.written()) catch {};
    ctx.err.writeByte('\n') catch {};
    return error.UsageFailed;
}

/// `english` in the user's language, or as is (see `i18n.zig`).
pub fn translate(ctx: *const Context, english: []const u8) []const u8 {
    return i18n.textIn(ctx.translation, english);
}

/// `template` in the user's language, with `{0}`, `{1}`, ... replaced by `args` (a tuple
/// of strings, integers, floats, or anything with a `format` method), in the arena:
/// `try ctx.tr("Deployed {0} to {1}", .{ name, env })`.
pub fn tr(ctx: *const Context, template: []const u8, args: anytype) Allocator.Error![]const u8 {
    return renderArgs(ctx.arena, ctx.translate(template), args);
}

/// `tr` for a count: `one` or `other` in English, or the translation's form of `other`
/// that fits `n` (its forms are separated by `|`; see `i18n.zig`). `n` is usually also in
/// `args`: `try ctx.plural(n, "Deleted {0} file", "Deleted {0} files", .{n})`.
pub fn plural(
    ctx: *const Context,
    n: u64,
    one: []const u8,
    other: []const u8,
    args: anytype,
) Allocator.Error![]const u8 {
    const template = if (ctx.translation) |t|
        t.plural(n, one, other)
    else if (n == 1) one else other;
    return renderArgs(ctx.arena, template, args);
}

fn renderArgs(arena: Allocator, template: []const u8, args: anytype) Allocator.Error![]const u8 {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    var texts: [info.field_names.len][]const u8 = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, T, i| {
        const value = @field(args, name);
        texts[i] = if (comptime isString(T))
            value
        else switch (@typeInfo(T)) {
            .int,
            .comptime_int,
            .float,
            .comptime_float,
            => try std.fmt.allocPrint(arena, "{d}", .{value}),
            else => try std.fmt.allocPrint(arena, "{f}", .{value}),
        };
    }
    return Messages.allocRender(arena, template, &texts);
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Whether `log` writes messages of `level`.
pub fn logs(ctx: *const Context, level: LogLevel) bool {
    return @backingInt(level) >= @backingInt(ctx.log_level);
}

/// Prints `<app>: <level>: <message>` to standard error when `level` is at least
/// `log_level`. For what `-v` should show; `warn` is for what the user must see.
pub fn log(ctx: *Context, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (!ctx.logs(level)) return;
    const kind: Theme.Kind = switch (level) {
        .@"error" => .@"error",
        .warn => .warning,
        else => .plain,
    };
    ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, kind) catch {};
    ctx.err.print("{t}: " ++ fmt ++ "\n", .{level} ++ args) catch {};
    // `App.run` shows lines at once; an `Environment.err` given to `execute` may buffer.
    ctx.err.flush() catch {};
}

/// Asks a question made at run time, as `.confirm` asks its fixed one before the handler
/// runs (`.confirm = true` adds `-y`/`--yes` without one): returns at once with `--yes`,
/// and when the answer is yes. Refuses without a terminal to ask at (or under CI), and on
/// any other answer, with a message and `error.CommandFailed`.
pub fn confirm(ctx: *Context, comptime fmt: []const u8, args: anytype) ConfirmError!void {
    if (ctx.yes) return;
    if (!ctx.interactive or ctx.in == null) {
        try ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error");
        const path_text = try parse.pathString(ctx.arena, ctx.path);
        try Messages.render(ctx.err, ctx.messages.confirm_needed, &.{path_text});
        try ctx.err.writeByte('\n');
        return error.CommandFailed;
    }
    const question = try std.fmt.allocPrint(ctx.arena, fmt, args);
    try Messages.render(ctx.err, ctx.messages.confirm_prompt, &.{question});
    try ctx.err.flush();
    const line = ctx.in.?.takeDelimiter('\n') catch null orelse "";
    const answer = std.mem.trim(u8, line, " \t\r");
    var yes = std.mem.splitScalar(u8, ctx.messages.confirm_yes, '|');
    while (yes.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, answer)) return;
    }
    try ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error");
    try ctx.err.print("{s}\n", .{ctx.messages.confirm_declined});
    return error.CommandFailed;
}

/// What `confirm` can fail with.
pub const ConfirmError = Failure || Io.Writer.Error || Allocator.Error;

/// Prints `<app>: warning: <message>` to standard error, unless `-q`/`--quiet` was given.
pub fn warn(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    if (ctx.quiet) return;
    var buffer: [1024]u8 = undefined;
    var message: Io.Writer = .fixed(&buffer);
    // A warning longer than the buffer is cut short rather than lost.
    message.print(fmt, args) catch {};
    ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .warning) catch {};
    Messages.render(ctx.err, ctx.messages.warning, &.{message.buffered()}) catch {};
    ctx.err.writeByte('\n') catch {};
    ctx.err.flush() catch {};
}

/// Decodes a flags struct from the parsed command line: each field from its flag's
/// occurrences, else from its default. Any struct whose flags are visible from the running
/// command may be decoded, so a subcommand can read its parent's persistent flags. When `T`
/// declares `pub fn validate(flags: T, ctx: *Context) !void`, it runs on the result.
pub fn flags(ctx: *Context, comptime T: type) FlagsError(T)!T {
    var result: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field, Field, attrs| {
        const name = comptime spec.longName(T, field);
        const is_count = comptime spec.option(T, field, "count", false);
        const split = comptime spec.option(T, field, "split", @as(?u8, null));
        if (ctx.lastValue(name) == null) {
            if (attrs.default_value_ptr) |ptr| {
                @field(result, field) = @as(*const Field, @ptrCast(@alignCast(ptr))).*;
            } else {
                @field(result, field) = comptime zero(Field);
            }
        } else if (is_count) {
            @field(result, field) = std.math.cast(Field, ctx.count(name)) orelse
                std.math.maxInt(Field);
        } else {
            @field(result, field) = try ctx.decodeField(Field, name, split);
        }
    }
    if (comptime @hasDecl(T, "validate")) try result.validate(ctx);
    return result;
}

/// What `flags(T)` can fail with: decoding errors, and whatever `T.validate` returns.
pub fn FlagsError(comptime T: type) type {
    const Decoding = values.Error || Allocator.Error;
    if (!@hasDecl(T, "validate")) return Decoding;
    const Validate = @TypeOf(T.validate);
    const info = @typeInfo(Validate).@"fn";
    const ok = info.param_types.len == 2 and info.param_types[1] == *Context and
        (info.param_types[0] == T or info.param_types[0] == *const T);
    if (!ok) @compileError(@typeName(T) ++ ".validate must be fn (" ++ @typeName(T) ++
        ", *cli.Context) !void");
    const Return = info.return_type orelse
        @compileError(@typeName(T) ++ ".validate must not be generic");
    return switch (@typeInfo(Return)) {
        .error_union => |u| Decoding || u.error_set,
        else => @compileError(@typeName(T) ++ ".validate must return !void"),
    };
}

/// Decodes typed positionals (see `.args` in `spec.zig`): field `i` from `ctx.args[i]`, a
/// trailing list from the rest, a missing optional field from its default. A word that is
/// not a valid value is a usage error (exit 2).
pub fn positionals(ctx: *Context, comptime T: type) (UsageFailure || Allocator.Error)!T {
    var result: T = undefined;
    const info = @typeInfo(T).@"struct";
    const fields = .{ info.field_names, info.field_types, info.field_attrs };
    inline for (fields[0], fields[1], fields[2], 0..) |field, Field, attrs, i| {
        const Base = switch (@typeInfo(Field)) {
            .optional => |o| o.child,
            else => Field,
        };
        if (comptime values.isList(Base)) {
            const Elem = values.Element(Base);
            const words = if (i < ctx.args.len) ctx.args[i..] else &.{};
            const list = try ctx.arena.alloc(Elem, words.len);
            for (list, words) |*item, word| {
                item.* = try ctx.positional(T, field, Elem, word);
            }
            @field(result, field) = if (words.len == 0 and attrs.default_value_ptr != null)
                @as(*const Field, @ptrCast(@alignCast(attrs.default_value_ptr.?))).*
            else
                list;
        } else if (i < ctx.args.len) {
            @field(result, field) = try ctx.positional(T, field, Base, ctx.args[i]);
        } else if (attrs.default_value_ptr) |ptr| {
            @field(result, field) = @as(*const Field, @ptrCast(@alignCast(ptr))).*;
        } else {
            @field(result, field) = comptime zero(Field);
        }
    }
    return result;
}

fn positional(
    ctx: *Context,
    comptime T: type,
    comptime field: []const u8,
    comptime Elem: type,
    word: []const u8,
) UsageFailure!Elem {
    return values.parse(Elem, word) catch {
        const name = comptime spec.positionalName(T, field);
        var buffer: [512]u8 = undefined;
        var message: Io.Writer = .fixed(&buffer);
        const label = comptime values.label(Elem);
        const template = ctx.messages.invalid_positional;
        Messages.render(&message, template, &.{ word, name, label }) catch {};
        return ctx.usageError("{s}", .{message.buffered()});
    };
}

/// The value a field without a default takes when its flag is absent. Required flags never
/// reach here: the parser has already rejected their absence.
fn zero(comptime Field: type) Field {
    return switch (@typeInfo(Field)) {
        .optional => null,
        .bool => false,
        .int => 0,
        .pointer => &.{},
        else => undefined,
    };
}

fn decodeField(
    ctx: *Context,
    comptime Field: type,
    name: []const u8,
    split: ?u8,
) (values.Error || Allocator.Error)!Field {
    const Base = switch (@typeInfo(Field)) {
        .optional => |o| o.child,
        else => Field,
    };
    if (comptime values.isList(Base)) {
        const Elem = values.Element(Base);
        var list: std.ArrayList(Elem) = .empty;
        for (ctx.occurrences) |occurrence| {
            if (!std.mem.eql(u8, occurrence.flag.name, name)) continue;
            if (split) |separator| {
                var parts = std.mem.splitScalar(u8, occurrence.value, separator);
                while (parts.next()) |part| {
                    try list.append(ctx.arena, try values.parse(Elem, part));
                }
            } else {
                try list.append(ctx.arena, try values.parse(Elem, occurrence.value));
            }
        }
        return list.items;
    }
    return try values.parse(Base, ctx.lastValue(name).?);
}

fn lastValue(ctx: *const Context, name: []const u8) ?[]const u8 {
    var i = ctx.occurrences.len;
    while (i > 0) {
        i -= 1;
        const occurrence = ctx.occurrences[i];
        if (std.mem.eql(u8, occurrence.flag.name, name)) return occurrence.value;
    }
    return null;
}

fn count(ctx: *const Context, name: []const u8) usize {
    var n: usize = 0;
    for (ctx.occurrences) |occurrence| {
        if (!std.mem.eql(u8, occurrence.flag.name, name)) continue;
        // The parser only accepts an environment count that `envCount` reads.
        n +|= if (occurrence.source == .env) parse.envCount(occurrence.value).? else 1;
    }
    return n;
}

/// Whether the flag `--<name>` was given on the command line or through its environment
/// variable.
pub fn isSet(ctx: *const Context, name: []const u8) bool {
    return ctx.lastValue(name) != null;
}

/// The values of the `.secret` flags this run was given, from the command line, the
/// environment, or a configuration file, each once and none empty: what a log scrubber
/// should mask. A list flag with `.split` yields each element as well as the whole value.
pub fn secretValues(ctx: *const Context) Allocator.Error![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (ctx.occurrences) |occurrence| {
        const flag = occurrence.flag;
        if (!flag.secret or flag.kind != .value) continue;
        try addSecret(ctx.arena, &found, occurrence.value);
        const separator = flag.split orelse continue;
        var parts = std.mem.splitScalar(u8, occurrence.value, separator);
        while (parts.next()) |part| try addSecret(ctx.arena, &found, part);
    }
    return found.items;
}

fn addSecret(
    arena: Allocator,
    found: *std.ArrayList([]const u8),
    value: []const u8,
) Allocator.Error!void {
    if (value.len == 0) return;
    for (found.items) |seen| if (std.mem.eql(u8, seen, value)) return;
    try found.append(arena, value);
}

/// A flag the user set, as text: the shape `cfg.Config.bindFlags` accepts.
pub const FlagRecord = struct {
    /// The flag's long name, without `--`.
    name: []const u8,
    value: []const u8,
    /// The configuration key the flag's meta names with `.key`, if any.
    key: ?[]const u8 = null,
};

/// Every flag the user set, one record per value, in command-line order. A counter is one
/// record holding the count; a list flag with `.split` yields one record per element.
pub fn changedFlags(ctx: *Context) Allocator.Error![]const FlagRecord {
    var records: std.ArrayList(FlagRecord) = .empty;
    for (ctx.occurrences, 0..) |occurrence, i| {
        const flag = occurrence.flag;
        switch (flag.kind) {
            .count => {
                const first = for (ctx.occurrences[0..i]) |earlier| {
                    if (earlier.flag == flag) break false;
                } else true;
                if (!first) continue;
                const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{ctx.count(flag.name)});
                try records.append(ctx.arena, .{
                    .name = flag.name,
                    .value = text,
                    .key = flag.key,
                });
            },
            .bool => try records.append(ctx.arena, .{
                .name = flag.name,
                .value = occurrence.value,
                .key = flag.key,
            }),
            .value => if (flag.split) |separator| {
                var parts = std.mem.splitScalar(u8, occurrence.value, separator);
                while (parts.next()) |part| {
                    try records.append(ctx.arena, .{
                        .name = flag.name,
                        .value = part,
                        .key = flag.key,
                    });
                }
            } else {
                try records.append(ctx.arena, .{
                    .name = flag.name,
                    .value = occurrence.value,
                    .key = flag.key,
                });
            },
        }
    }
    return records.items;
}

const testing = std.testing;

const TestFlags = struct {
    port: u16 = 8080,
    tag: []const []const u8 = &.{},
    verbose: u8 = 0,
    mode: enum { dev, prod } = .dev,
    limit: ?u32 = null,
    force: bool = false,
    pub const meta = .{
        .tag = .{ .split = ',' },
        .verbose = .{ .short = 'v', .count = true },
    };
};

const test_command = spec.command(.{ .name = "t", .flags = TestFlags, .run = noop });

fn noop(_: *Context) !void {}

fn testContext(
    arena: Allocator,
    args: []const []const u8,
    environ: *const std.process.Environ.Map,
) !Context {
    var usage: parse.Usage = .{};
    const result = try parse.parse(arena, &test_command, args, .{}, &usage);
    return .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = arena,
        .environ = environ,
        .out = undefined,
        .err = undefined,
        .args = result.positionals,
        .path = result.path,
        .occurrences = result.occurrences,
        .app_name = "t",
    };
}

test "flags decodes every kind of field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var ctx = try testContext(arena.allocator(), &.{
        "--port", "1",           "--tag",   "a,b", "--tag",   "c",
        "-vvv",   "--mode=prod", "--limit", "7",   "--force",
    }, &environ);
    const f = try ctx.flags(TestFlags);
    try testing.expectEqual(1, f.port);
    try testing.expectEqual(3, f.tag.len);
    try testing.expectEqualStrings("c", f.tag[2]);
    try testing.expectEqual(3, f.verbose);
    try testing.expectEqual(.prod, f.mode);
    try testing.expectEqual(7, f.limit.?);
    try testing.expect(f.force);
    try testing.expect(ctx.isSet("port"));
}

test "flags falls back to defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var ctx = try testContext(arena.allocator(), &.{}, &environ);
    const f = try ctx.flags(TestFlags);
    try testing.expectEqual(8080, f.port);
    try testing.expectEqual(0, f.tag.len);
    try testing.expectEqual(null, f.limit);
    try testing.expect(!ctx.isSet("port"));
}

test changedFlags {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var ctx = try testContext(
        arena.allocator(),
        &.{ "-vv", "--tag", "a,b", "--no-force" },
        &environ,
    );
    const records = try ctx.changedFlags();
    try testing.expectEqual(4, records.len);
    try testing.expectEqualStrings("verbose", records[0].name);
    try testing.expectEqualStrings("2", records[0].value);
    try testing.expectEqualStrings("b", records[2].value);
    try testing.expectEqualStrings("false", records[3].value);
}

test secretValues {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = comptime spec.command(.{
        .name = "t",
        .flags = struct {
            token: []const u8 = "",
            keys: []const []const u8 = &.{},
            password: []const u8 = "",
            empty: []const u8 = "",
            debug: bool = false,
            user: []const u8 = "",
            pub const meta = .{
                .token = .{ .secret = true },
                .keys = .{ .secret = true, .split = ',' },
                .password = .{ .secret = true, .env = "PASSWORD" },
                .empty = .{ .secret = true },
                .debug = .{ .secret = true },
            };
        },
        .run = noop,
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PASSWORD", "from-env");
    var usage: parse.Usage = .{};
    const result = try parse.parse(arena.allocator(), &root, &.{
        "--token", "t0k", "--keys", "a,b", "--token", "t0k", "--empty=", "--debug",
        "--user",  "me",
    }, .{ .environ = &environ }, &usage);
    const ctx: Context = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = arena.allocator(),
        .environ = &environ,
        .out = undefined,
        .err = undefined,
        .args = result.positionals,
        .path = result.path,
        .occurrences = result.occurrences,
        .app_name = "t",
    };
    const secrets = try ctx.secretValues();
    try testing.expectEqual(5, secrets.len);
    try testing.expectEqualStrings("t0k", secrets[0]);
    try testing.expectEqualStrings("a,b", secrets[1]);
    try testing.expectEqualStrings("a", secrets[2]);
    try testing.expectEqualStrings("b", secrets[3]);
    try testing.expectEqualStrings("from-env", secrets[4]);
}

test fail {
    var buffer: [64]u8 = undefined;
    var err: Io.Writer = .fixed(&buffer);
    var ctx: Context = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = testing.allocator,
        .environ = undefined,
        .out = undefined,
        .err = &err,
        .args = &.{},
        .path = &.{},
        .occurrences = &.{},
        .app_name = "app",
    };
    try testing.expectEqual(error.CommandFailed, ctx.fail("cannot open {s}", .{"x"}));
    try testing.expectEqualStrings("app: cannot open x\n", err.buffered());
}

const Global = struct {
    verbose: u8 = 0,
    profile: []const u8 = "default",
    pub const meta = .{
        .verbose = .{ .short = 'v', .count = true, .env = "VERBOSE" },
        .profile = .{ .env = "PROFILE" },
    };
};

/// A type following the `parse` convention.
const Size = struct {
    bytes: u64,
    pub fn parse(text: []const u8) !Size {
        const kilo = std.mem.endsWith(u8, text, "k");
        const digits = if (kilo) text[0 .. text.len - 1] else text;
        const n = try std.fmt.parseInt(u64, digits, 10);
        return .{ .bytes = if (kilo) n * 1024 else n };
    }
};

const ChildFlags = struct {
    size: Size = .{ .bytes = 0 },
    ratio: f64 = 1.0,
    ids: ?[]const u32 = null,
    level: u2 = 0,
    pub const meta = .{ .level = .{ .short = 'l', .count = true } };
};

const nested_root = spec.command(.{
    .name = "app",
    .persistent_flags = Global,
    .subcommands = .{spec.command(.{ .name = "child", .flags = ChildFlags, .run = noop })},
});

fn nestedContext(
    arena: Allocator,
    args: []const []const u8,
    environ: *const std.process.Environ.Map,
) !Context {
    var usage: parse.Usage = .{};
    const result = try parse.parse(arena, &nested_root, args, .{ .environ = environ }, &usage);
    return .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = arena,
        .environ = environ,
        .out = undefined,
        .err = undefined,
        .args = result.positionals,
        .path = result.path,
        .occurrences = result.occurrences,
        .app_name = "app",
    };
}

test "a child decodes its parent's persistent flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PROFILE", "prod");
    var ctx = try nestedContext(arena.allocator(), &.{ "-v", "child", "-v" }, &environ);
    try testing.expectEqualStrings("child", ctx.command().name);
    const global = try ctx.flags(Global);
    try testing.expectEqual(2, global.verbose);
    try testing.expectEqualStrings("prod", global.profile);
}

test "parse convention, floats, optional lists, and a saturating counter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var ctx = try nestedContext(arena.allocator(), &.{
        "child", "--size", "4k",   "--ratio", "0.25", "--ids", "1",
        "-llll", "--ids",  "0x10", "-ll",
    }, &environ);
    const f = try ctx.flags(ChildFlags);
    try testing.expectEqual(4096, f.size.bytes);
    try testing.expectEqual(0.25, f.ratio);
    try testing.expectEqualSlices(u32, &.{ 1, 16 }, f.ids.?);
    try testing.expectEqual(3, f.level);

    var none = try nestedContext(arena.allocator(), &.{"child"}, &environ);
    const defaults = try none.flags(ChildFlags);
    try testing.expectEqual(null, defaults.ids);
    try testing.expectEqual(0, defaults.size.bytes);
    try testing.expectEqual(1.0, defaults.ratio);

    try testing.expectError(
        error.UsageError,
        nestedContext(arena.allocator(), &.{ "child", "--size", "4m" }, &environ),
    );
}

test "counters and changedFlags from the environment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("VERBOSE", "2");
    try environ.put("PROFILE", "prod");
    var ctx = try nestedContext(arena.allocator(), &.{ "child", "--ratio=2" }, &environ);
    try testing.expectEqual(2, (try ctx.flags(Global)).verbose);
    try testing.expect(ctx.isSet("profile"));
    const records = try ctx.changedFlags();
    try testing.expectEqual(3, records.len);
    try testing.expectEqualStrings("ratio", records[0].name);
    try testing.expectEqualStrings("2", records[0].value);
    for (records[1..]) |record| {
        if (std.mem.eql(u8, record.name, "verbose")) {
            try testing.expectEqualStrings("2", record.value);
        } else {
            try testing.expectEqualStrings("profile", record.name);
            try testing.expectEqualStrings("prod", record.value);
        }
    }

    // `VERBOSE=0` is a count of zero, not one occurrence.
    try environ.put("VERBOSE", "0");
    var zero_ctx = try nestedContext(arena.allocator(), &.{"child"}, &environ);
    try testing.expectEqual(0, (try zero_ctx.flags(Global)).verbose);
}

test data {
    var value: u32 = 7;
    const ctx: Context = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = testing.allocator,
        .environ = undefined,
        .out = undefined,
        .err = undefined,
        .args = &.{},
        .path = &.{},
        .occurrences = &.{},
        .app_name = "app",
        .user_data = &value,
    };
    const pointer = ctx.data(*u32);
    try testing.expectEqual(&value, pointer);
    pointer.* += 1;
    try testing.expectEqual(8, value);
}

test warn {
    var buffer: [64]u8 = undefined;
    var err: Io.Writer = .fixed(&buffer);
    var ctx: Context = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = testing.allocator,
        .environ = undefined,
        .out = undefined,
        .err = &err,
        .args = &.{},
        .path = &.{},
        .occurrences = &.{},
        .app_name = "app",
    };
    ctx.warn("{d} left", .{3});
    try testing.expectEqualStrings("app: warning: 3 left\n", err.buffered());
}

const Keyed = struct {
    jobs: u8 = 4,
    found: usize = 7,
    pub const meta = .{
        .jobs = .{ .key = "fetch.concurrency" },
        .found = .{ .internal = true },
    };
};

fn runKeyed(ctx: *Context, given: Keyed) !void {
    const records = try ctx.changedFlags();
    try ctx.out.print("{d} {d} {s}={s}\n", .{
        given.jobs, given.found, records[0].key.?, records[0].value,
    });
}

test "an .internal field keeps its default, and changedFlags carries a flag's .key" {
    const App = @import("App.zig");
    const root = comptime spec.command(.{ .name = "t", .flags = Keyed, .run = runKeyed });
    const app: App = .{ .root = &root };
    const run = @import("testing.zig").run;
    const ok = try run(app, &.{ "--jobs", "2" }, .{});
    defer ok.deinit();
    try ok.expect(0, "2 7 fetch.concurrency=2\n", "");
    const hidden = try run(app, &.{ "--found", "1" }, .{});
    defer hidden.deinit();
    try testing.expectEqual(2, hidden.status);
}
