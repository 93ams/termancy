//! An application: a command tree plus what the runner needs to execute it.
//!
//! ```zig
//! pub fn main(init: std.process.Init) u8 {
//!     const app: cli.App = .{ .root = &root, .version = "1.2.0" };
//!     return app.run(init);
//! }
//! ```
//!
//! `run` reads the process arguments and environment and writes to the real standard
//! streams; `execute` takes all of those as parameters, which is how tests drive an app.
//!
//! Exit statuses: 0 success, 1 a handler failed, 2 a usage error. `exit_status` can map
//! specific handler errors to other statuses, and `exit_statuses` document them.

const std = @import("std");
const sets = @import("sets.zig");
const field_ = @import("field");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const Context = @import("Context.zig");
const parse = @import("parse.zig");
const help = @import("help.zig");
const complete = @import("complete.zig");
const shell = @import("shell.zig");
const terminal = @import("terminal.zig");
const plugin = @import("plugins.zig");
const Messages = @import("Messages.zig");
const interrupt = @import("interrupt.zig");
const prompt = @import("prompt.zig");
const paging = @import("pager.zig");
const repl = @import("repl.zig");
const i18n = @import("i18n.zig");
const flow = @import("flow.zig");
const Theme = @import("Theme.zig");
const Level = @import("term").capability.Color;
const ansi = @import("term").ansi;

const App = @This();

/// The command ran.
pub const exit_success: u8 = 0;
/// A handler failed.
pub const exit_failure: u8 = 1;
/// The command line was wrong.
pub const exit_usage: u8 = 2;
/// The configuration was wrong (`Context.configError`): `EX_CONFIG` from `sysexits.h`.
pub const exit_config: u8 = 78;
/// A write to standard output failed, almost always because the reader went away
/// (`app | head`). 128 + SIGPIPE, the status a process killed by that signal reports.
pub const exit_broken_pipe: u8 = 141;

root: *const Command,
/// Printed by `--version` as `<name> <version>`. Without it there is no `--version`.
version: ?[]const u8 = null,
/// The name used in messages and completion scripts. Defaults to the root's name.
name: ?[]const u8 = null,
/// Handed to handlers as `ctx.data(*T)`.
data: ?*anyopaque = null,
/// Maps a handler's error to an exit status. Errors it returns null for are reported by
/// name with status 1.
exit_status: ?*const fn (err: anyerror) ?u8 = null,
/// What the app's own statuses (from `exit_status` or `ctx.exit`) mean, for the "Exit
/// status" section `docs.command` writes after the runner's own 0, 1, 2, 126 (with
/// `plugins`), and 130. Meanings are translated as `ctx.tr` translates.
exit_statuses: []const @import("docs.zig").ExitStatus = &.{},
/// Offer `help [command...]` on the root, unless the root has its own `help`.
help_command: bool = true,
/// Mount `complete.command` (`completion <shell>`) on the root, unless the root has its own
/// `completion`. Turn this off to mount it elsewhere in the tree. The hidden `__complete`
/// the scripts call is answered at the root either way.
completion_command: bool = true,
/// Accept `-q`/`--quiet` on every command: it suppresses warnings (`Context.warn` and
/// deprecation notices), never errors. A user flag named `quiet` or using `-q` wins.
quiet_flag: bool = true,
/// Accept `--color auto|always|never` on every command: `always` and `never` override what
/// `NO_COLOR`, `FORCE_COLOR`, and the terminal say, for help, the runner's messages, and
/// `ctx.color`/`ctx.err_color`. A flag named `color` on the root wins.
color_flag: bool = false,
/// Expand an argument `@file` (before any `--`) into the words of `file`, split as a shell
/// would without expansions (`#` starts a comment). For command lines too long for the
/// system, and argument lists kept in files. Words read from a file are not expanded again.
response_files: bool = false,
/// Accept an unambiguous prefix of a subcommand (`app conf` for `app config`). Off by
/// default: adding a subcommand can make a prefix that scripts rely on ambiguous.
prefix_matching: bool = false,
/// Replacements for parts of every help page: header, usage, footer.
help_sections: help.Sections = .{},
/// Run `<plugins><name>` from `PATH` for a first argument `name` that is not a command, as
/// git runs `git-<name>`: `"app-"` makes `app deploy` run `app-deploy`. Root help lists the
/// plugins found and completion offers them. See `plugins.zig`.
plugins: ?[]const u8 = null,
/// Every sentence the library shows the user; replace it to translate them. See
/// `Messages.zig`.
messages: *const Messages = &Messages.english,
/// Run the command as a task and cancel it on Ctrl-C: its next `std.Io` call returns
/// `error.Canceled`, `cleanup` hooks run, and the exit status is 130. Without it, Ctrl-C
/// has its default effect, ending the process at once. See `interrupt.zig`.
cancel_on_interrupt: bool = false,
/// Asks for a required flag with a `.prompt` that was not given, when the run is
/// interactive. See `prompt.zig`.
prompter: prompt.Prompter = prompt.line,
/// Translations to choose from by the user's locale (`App.locale`, else `LC_ALL`,
/// `LC_MESSAGES`, `LANG`): of the library's sentences, help, and the app's own text
/// (`ctx.tr`). Empty: English, and the environment is not read. See `i18n.zig`.
translations: []const i18n.Translation = &.{},
/// The locale to use instead of the environment's, such as from a `--lang` flag or a
/// setting.
locale: ?[]const u8 = null,
/// Whether a feature named by a command's or flag's `.feature` is on. Default: the
/// environment variable of that name is set to a true value (`1`, `true`, `yes`, `on`).
feature_enabled: ?*const fn (name: []const u8, environ: *const std.process.Environ.Map) bool = null,
/// The user's own commands, as git's `alias.<name>`: `.{ "co", "checkout -b" }` makes
/// `app co x` run `app checkout -b x`. The expansion is split as a shell would, without
/// expansions. A command of the same name wins. Usually read from a configuration file.
aliases: []const [2][]const u8 = &.{},
/// Values for flags given neither on the command line nor in their variable: usually a
/// configuration file, `.from(&config, .{})` for a `cfg.Config`. See `cli.Defaults` and
/// `defaults.zig`.
defaults: ?parse.Defaults = null,
/// Code around every command, outermost first: timing, logging, errors, authentication.
/// See `Context.Middleware`.
middleware: []const Context.Middleware = &.{},
/// How `cli.Flow` asks its questions; null for plain lines (see `flow.zig`).
asker: ?flow.Asker = null,
/// Show help taller than the terminal through `$PAGER` (else `less -FRX`), as git does.
/// Only when standard output is a terminal. See `pager.zig`.
pager: bool = false,
/// How help and the runner's messages look on a stream that takes color. See `Theme.zig`.
theme: *const Theme = &.default,

/// Everything an execution reads and writes. `run` builds one from the process.
pub const Environment = struct {
    io: Io,
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,
    /// The columns help wraps to.
    width: u16 = help.default_width,
    /// How many colors standard output takes, for help and `ctx.color`.
    color: Level = .none,
    /// How many colors standard error takes, for messages and `ctx.err_color`.
    err_color: Level = .none,
    /// Standard input, for prompts; prompts happen only when this is set and `interactive`.
    in: ?*Io.Reader = null,
    /// Standard input and standard error are terminals and the run is not under CI (see
    /// `terminal.interactive`): missing flags may be asked for.
    interactive: bool = false,
    /// The terminal standard input is, for a prompter that changes its modes.
    terminal: ?Io.File = null,
    /// The rows of the terminal standard output is; null when it is not one. Help taller
    /// than this goes through the pager, with `App.pager`.
    rows: ?u16 = null,
};

/// Runs the application as the process: arguments from `init`, output to the standard
/// streams. Returns the exit status, for `main` to return.
pub fn run(app: App, init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return app.oom();
    const args = arena.alloc([]const u8, argv.len -| 1) catch return app.oom();
    for (args, argv[@min(1, argv.len)..]) |*arg, os_arg| arg.* = os_arg;
    // Windows: a console on its default code page would garble UTF-8 both ways.
    const code_pages = terminal.useUtf8();
    defer terminal.restoreCodePages(code_pages);

    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out = Io.File.stdout().writer(init.io, &out_buffer);
    var err_file = Io.File.stderr().writer(init.io, &err_buffer);
    var err: LineFlushed = .{ .inner = &err_file.interface };
    var in_buffer: [1024]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(init.io, &in_buffer);
    const interactive = terminal.interactive(
        init.environ_map,
        Io.File.stdin().isTty(init.io) catch false,
        Io.File.stderr().isTty(init.io) catch false,
    );
    const columns = terminal.width(init.io, Io.File.stdout());
    const out_tty = Io.File.stdout().isTty(init.io) catch false;
    const err_tty = Io.File.stderr().isTty(init.io) catch false;
    const status = app.execute(.{
        .io = init.io,
        .gpa = init.gpa,
        .environ = init.environ_map,
        .out = &out.interface,
        .err = &err.interface,
        .width = terminal.helpWidth(columns, init.environ_map, help.default_width),
        .color = terminal.colorLevel(init.environ_map, out_tty),
        .err_color = terminal.colorLevel(init.environ_map, err_tty),
        .in = &in.interface,
        .interactive = interactive,
        .terminal = if (interactive) Io.File.stdin() else null,
        .rows = if (columns != null) terminal.height(init.io, Io.File.stdout()) else null,
    }, args);
    // A closed stdout (`app | head`) is not worth a second error.
    out.interface.flush() catch {};
    err.interface.flush() catch {};
    return status;
}

/// Standard error as `run` gives it to handlers: a write that holds a line break reaches the
/// stream at once, so messages show as they happen without a `flush`, while the bytes of
/// one line still go out together.
const LineFlushed = struct {
    inner: *Io.Writer,
    interface: Io.Writer = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = &.{} },

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const lf: *LineFlushed = @fieldParentPtr("interface", w);
        const n = try lf.inner.writeSplat(data, splat);
        for (data) |bytes| {
            if (std.mem.indexOfScalar(u8, bytes, '\n') != null) return lf.flushed(n);
        }
        return n;
    }

    fn flushed(lf: *LineFlushed, n: usize) Io.Writer.Error!usize {
        try lf.inner.flush();
        return n;
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        const lf: *LineFlushed = @fieldParentPtr("interface", w);
        try lf.inner.flush();
    }
};

fn oom(app: App) u8 {
    std.debug.print("{s}\n", .{app.messages.out_of_memory});
    return exit_failure;
}

/// The application's name for messages.
pub fn displayName(app: App) []const u8 {
    return app.name orelse app.root.name;
}

/// Executes one invocation: `args` excludes the program name. Never returns an error; every
/// failure becomes a message on `env.err` and a non-zero status.
pub fn execute(app: App, env: Environment, args: []const []const u8) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const translation = app.translationFor(env.environ);
    var localized = app;
    if (translation) |t| if (t.messages) |m| {
        localized.messages = m;
    };
    return localized.executeIn(arena, env, args, translation) catch |err| switch (err) {
        error.OutOfMemory => {
            const name = app.displayName();
            app.theme.writePrefix(env.err, env.err_color, name, .@"error") catch {};
            env.err.print("{s}\n", .{app.messages.out_of_memory}) catch {};
            return exit_failure;
        },
        error.WriteFailed => exit_failure,
    };
}

/// Executes one command line, for embedding an app in a REPL or a host without a process:
/// `line` is split into words as a POSIX shell would, without expansions (see `shell.zig`),
/// then executed as by `execute`. A line that cannot be split, such as one with an
/// unterminated quote, is a usage error (status 2). An empty line runs the root.
pub fn executeLine(app: App, env: Environment, line: []const u8) u8 {
    return app.executeLineIn(env, &.{}, line);
}

/// `executeLine` inside a group: `path` (subcommand names below the root) goes before the
/// words of `line`, so `migrate` runs `db migrate`. A line starting with `help` asks for
/// help on the commands of the group (`help db migrate`).
pub fn executeLineIn(app: App, env: Environment, path: []const []const u8, line: []const u8) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const words = shell.tokenize(arena, line) catch |err| {
        app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error") catch {};
        env.err.print("{s}\n", .{app.shellMessage(err)}) catch {};
        return if (err == error.OutOfMemory) exit_failure else exit_usage;
    };
    if (path.len == 0) return app.execute(env, words);
    const help_first = app.help_command and words.len > 0 and std.mem.eql(u8, words[0], "help");
    const args = std.mem.concat(arena, []const u8, if (help_first)
        &.{ words[0..1], path, words[1..] }
    else
        &.{ path, words }) catch return app.oom();
    return app.execute(env, args);
}

const InternalError = Allocator.Error || Io.Writer.Error;

/// The translation for the user's locale, or null for English.
pub fn translationFor(app: App, environ: *const std.process.Environ.Map) ?*const i18n.Translation {
    if (app.translations.len == 0) return null;
    const locale: i18n.Locale = if (app.locale) |tag| .parse(tag) else i18n.detect(environ) orelse
        return null;
    return i18n.select(app.translations, locale);
}

fn executeIn(
    app: App,
    arena: Allocator,
    detected: Environment,
    args: []const []const u8,
    translation: ?*const i18n.Translation,
) InternalError!u8 {
    var env = detected;
    const root = try app.effectiveRoot(arena, env.environ);
    const aliased = app.expandAlias(arena, root, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadAlias => {
            try app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error");
            try env.err.print("{s}: {s}\n", .{ args[0], app.messages.unterminated_quote });
            return exit_usage;
        },
    };
    const expanded = aliased orelse args;
    var effective = if (app.response_files)
        app.expandResponseFiles(arena, env, expanded) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => |e| return e,
            error.ResponseFile => return exit_usage,
        }
    else
        expanded;
    if (args.len > 0 and root.findSubcommand(args[0]) == null) {
        const directives = std.mem.eql(u8, args[0], "__complete2");
        if (directives or std.mem.eql(u8, args[0], "__complete")) {
            try complete.candidates(env.out, root, args[1..], .{
                .help_command = app.help_command,
                .quiet = app.quiet_flag,
                .messages = app.messages,
                .translation = translation,
                .directives = directives,
                .prefix_matching = app.prefix_matching,
                .runtime = .{
                    .io = env.io,
                    .gpa = env.gpa,
                    .arena = arena,
                    .environ = env.environ,
                    .app_name = app.displayName(),
                    .user_data = app.data,
                    .parse = .{
                        .environ = env.environ,
                        .version = app.version != null,
                        .quiet = app.quiet_flag,
                        .messages = app.messages,
                    },
                },
            });
            if (app.plugins) |prefix| if (args.len == 2) {
                const names = plugin.list(arena, env.io, env.environ, prefix) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return exit_success;
                };
                for (names) |name| {
                    if (root.findSubcommand(name) != null) continue;
                    if (std.mem.startsWith(u8, name, args[1])) try env.out.print("{s}\n", .{name});
                }
            };
            return exit_success;
        }
        const is_help = app.help_command and std.mem.eql(u8, args[0], "help");
        if (is_help and args.len > 1 and std.mem.eql(u8, args[1], "--search")) {
            return app.searchHelp(arena, env, root, args[2..], translation);
        }
        if (is_help) {
            // `help a b` is `a b --help`.
            const rewritten = try arena.alloc([]const u8, args.len);
            @memcpy(rewritten[0 .. args.len - 1], args[1..]);
            rewritten[args.len - 1] = "--help";
            effective = rewritten;
        }
    }

    if (app.plugins) |prefix| {
        if (try app.runPlugin(arena, env, root, prefix, effective)) |status| return status;
    }

    var usage: parse.Usage = .{};
    const result = parse.parse(arena, root, effective, .{
        .environ = env.environ,
        .version = app.version != null,
        .quiet = app.quiet_flag,
        .prefix_matching = app.prefix_matching,
        .messages = app.messages,
        .translation = translation,
        .promptable = env.interactive and env.in != null,
        .defaults = app.defaults,
    }, &usage) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UsageError => return app.reportUsage(arena, env, root, effective, usage),
    };
    if (colorChoice(result.occurrences)) |choice| switch (choice) {
        .auto => {},
        .always => {
            env.color = env.color.max(.basic);
            env.err_color = env.err_color.max(.basic);
        },
        .never => {
            env.color = .none;
            env.err_color = .none;
        },
    };
    if (!result.quiet) {
        for (result.warnings) |warning| {
            try app.theme.writePrefix(env.err, env.err_color, app.displayName(), .warning);
            try Messages.render(env.err, app.messages.warning, &.{warning});
            try env.err.writeByte('\n');
        }
    }

    var occurrences = result.occurrences;
    if (result.missing.len > 0 and !result.help and !result.version) {
        var asked: std.ArrayList(parse.Occurrence) = .empty;
        try asked.appendSlice(arena, result.occurrences);
        for (result.missing) |flag| {
            const value = try app.ask(arena, env, flag, null) orelse {
                usage = .{ .message = try Messages.allocRender(
                    arena,
                    app.messages.required_flag,
                    &.{flag.name},
                ) };
                return app.reportUsage(arena, env, root, effective, usage);
            };
            try asked.append(arena, .{ .flag = flag, .value = value, .source = .argv });
        }
        occurrences = asked.items;
    }
    var positionals = result.positionals;
    const leaf = result.leaf();
    // The parser let these through only to be asked for: each has a `.prompt`.
    if (positionals.len < leaf.args.min and leaf.run != null and !result.help and !result.version) {
        var answered: std.ArrayList([]const u8) = .empty;
        try answered.appendSlice(arena, positionals);
        for (leaf.args.positionals[positionals.len..leaf.args.min]) |*positional| {
            const stand_in: Flag = .{
                .name = positional.name,
                .field = positional.name,
                .kind = .value,
                .value_name = positional.value_name,
                .choices = positional.choices,
                .prompt = positional.prompt,
                .check = positional.check orelse anyText,
            };
            const value = try app.ask(arena, env, &stand_in, positional) orelse {
                const m = app.messages;
                const template = if (leaf.args.min == 1)
                    m.too_few_argument
                else
                    m.too_few_arguments;
                usage = .{ .message = try Messages.allocRender(arena, template, &.{
                    try parse.pathString(arena, result.path),
                    try std.fmt.allocPrint(arena, "{d}", .{leaf.args.min}),
                    try std.fmt.allocPrint(arena, "{d}", .{answered.items.len}),
                }) };
                return app.reportUsage(arena, env, root, effective, usage);
            };
            try answered.append(arena, value);
        }
        positionals = answered.items;
    }

    const help_options: help.Options = .{
        .help_command = app.help_command,
        .version = app.version != null,
        .quiet = app.quiet_flag,
        .width = env.width,
        .color = env.color,
        .theme = app.theme,
        .sections = app.help_sections,
        .messages = app.messages,
        .translation = translation,
        .plugins = if (app.plugins != null and result.path.len == 1)
            try app.pluginNames(arena, env, root)
        else
            &.{},
    };
    if (result.version) {
        try env.out.print("{s} {s}\n", .{ app.displayName(), app.version.? });
        return exit_success;
    }
    // Only the command's own name (`app db`): nothing else was asked of it.
    const bare = effective.len + 1 == result.path.len;
    if (bare and leaf.repl and leaf.run == null and env.interactive and env.in != null) {
        return app.shellIn(arena, env, result.path);
    }
    if (result.help or leaf.run == null) {
        const rows = if (app.pager) env.rows orelse 0 else 0;
        if (rows == 0) {
            try help.write(env.out, result.path, help_options);
            return exit_success;
        }
        var page: Io.Writer.Allocating = .init(arena);
        help.write(&page.writer, result.path, help_options) catch return error.OutOfMemory;
        const text = page.written();
        if (std.mem.count(u8, text, "\n") >= rows) {
            try env.out.flush();
            if (try paging.page(env.io, arena, env.environ, text)) return exit_success;
        }
        try env.out.writeAll(text);
        return exit_success;
    }

    var ctx: Context = .{
        .io = env.io,
        .gpa = env.gpa,
        .arena = arena,
        .environ = env.environ,
        .out = env.out,
        .err = env.err,
        .args = positionals,
        .passthrough = result.passthrough,
        .path = result.path,
        .occurrences = occurrences,
        .app_name = app.displayName(),
        .user_data = app.data,
        .quiet = result.quiet,
        .messages = app.messages,
        .translation = translation,
        .dry_run = std.mem.eql(u8, builtinValue(occurrences, "dry_run") orelse "", "true"),
        .yes = std.mem.eql(u8, builtinValue(occurrences, "yes") orelse "", "true"),
        .output = if (builtinValue(occurrences, "output")) |name|
            std.meta.stringToEnum(Context.OutputFormat, name) orelse .text
        else
            .text,
        .log_level = logLevel(occurrences, result.quiet),
        .middleware = app.middleware,
        .in = env.in,
        .interactive = env.interactive and env.in != null,
        .terminal = env.terminal,
        .asker = app.asker,
        .color = env.color,
        .err_color = env.err_color,
        .theme = app.theme,
        .exit_statuses = app.exit_statuses,
        .plugins = app.plugins != null,
    };
    if (result.leaf().confirm) |question| {
        ctx.confirm("{s}", .{i18n.textIn(translation, question)}) catch |err| switch (err) {
            error.CommandFailed => return exit_failure,
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.WriteFailed,
        };
    }
    app.runCommand(&ctx) catch |err| {
        if (err == error.Exit) return ctx.exit_status;
        if (err == error.Canceled) return exit_interrupted;
        return app.reportFailure(env, &ctx, err);
    };
    return exit_success;
}

/// Asks for `flag`, or for `positional` (with `flag` its stand-in), until an answer is
/// valid, three times at most. Null when there is no answer.
fn ask(
    app: App,
    arena: Allocator,
    env: Environment,
    flag: *const Flag,
    positional: ?*const Command.Positional,
) InternalError!?[]const u8 {
    var problem: ?[]const u8 = null;
    for (0..3) |_| {
        const answer = app.prompter(.{
            .io = env.io,
            .arena = arena,
            .in = env.in.?,
            .out = env.err,
            .terminal = env.terminal,
            .label = i18n.textIn(app.translationFor(env.environ), flag.prompt.?),
            .flag = flag,
            .positional = positional,
            .problem = problem,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return null;
        };
        if (positional != null) {
            if (flag.check(answer)) return answer;
            problem = try Messages.allocRender(
                arena,
                app.messages.invalid_positional,
                &.{ answer, flag.name, flag.value_name },
            );
            continue;
        }
        var usage: parse.Usage = .{};
        const options: parse.Options = .{
            .messages = app.messages,
            .translation = app.translationFor(env.environ),
        };
        parse.checkValue(arena, flag, answer, options, &usage) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            problem = usage.message;
            continue;
        };
        return answer;
    }
    return null;
}

/// A shell on the subcommands of the last command of `path` (`Command.repl`), prompting
/// with the path: `app db> `.
fn shellIn(
    app: App,
    arena: Allocator,
    env: Environment,
    path: []const *const Command,
) InternalError!u8 {
    const names = try arena.alloc([]const u8, path.len);
    for (names, path) |*name, cmd| name.* = cmd.name;
    names[0] = app.displayName();
    const prompt_text = try std.fmt.allocPrint(arena, "{s}> ", .{
        try std.mem.join(arena, " ", names),
    });
    try env.out.flush();
    return repl.run(app, env, .{ .prompt = prompt_text, .path = names[1..] });
}

fn anyText(_: []const u8) bool {
    return true;
}

/// 128 + SIGINT, as shells report a program stopped by Ctrl-C.
pub const exit_interrupted: u8 = 130;

fn runCommand(app: App, ctx: *Context) anyerror!void {
    if (!app.cancel_on_interrupt or !interrupt.supported) return runWithCleanup(ctx);
    interrupt.install();
    defer interrupt.uninstall();
    const Task = struct {
        ctx: *Context,
        done: std.atomic.Value(u32) = .init(0),

        fn run(task: *@This()) anyerror!void {
            defer {
                task.done.store(1, .release);
                task.ctx.io.futexWake(u32, &task.done.raw, 1);
            }
            return runWithCleanup(task.ctx);
        }
    };
    var task: Task = .{ .ctx = ctx };
    var future = ctx.io.concurrent(Task.run, .{&task}) catch return runWithCleanup(ctx);
    const poll: Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(50),
        .clock = .awake,
    } };
    while (task.done.load(.acquire) == 0) {
        if (interrupt.interrupted()) {
            const result = future.cancel(ctx.io);
            // A handler that caught `error.Canceled` and returned was still interrupted.
            result catch |err| if (err != error.Canceled) return err;
            return error.Canceled;
        }
        ctx.io.futexWaitTimeout(u32, &task.done.raw, 0, poll) catch {};
    }
    return future.await(ctx.io);
}

/// The handlers, then every `cleanup` hook on the path, leaf first, whatever happened.
fn runWithCleanup(ctx: *Context) anyerror!void {
    const chain: Context.Next = .{ .ctx = ctx, .rest = ctx.middleware, .handlers = runHandlers };
    const result = chain.run();
    var failure: ?anyerror = null;
    var i = ctx.path.len;
    while (i > 0) {
        i -= 1;
        const hook = ctx.path[i].cleanup orelse continue;
        hook(ctx) catch |err| {
            if (failure == null) failure = err;
        };
    }
    try result;
    if (failure) |err| return err;
}

/// Runs the plugin `args[0]` names, when there is one: its status, or null to carry on.
fn runPlugin(
    app: App,
    arena: Allocator,
    env: Environment,
    root: *const Command,
    prefix: []const u8,
    args: []const []const u8,
) InternalError!?u8 {
    if (args.len == 0 or root.findSubcommand(args[0]) != null) return null;
    const name = args[0];
    const found = plugin.find(arena, env.io, env.environ, prefix, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return null,
    };
    const path = found orelse return null;
    // The plugin writes to the same streams; what this process buffered goes first.
    try env.out.flush();
    try env.err.flush();
    return plugin.run(env.io, path, args[1..], env.environ, arena) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error");
        try env.err.print("{s}: {s}\n", .{ path, @errorName(err) });
        return exit_cannot_run;
    };
}

/// The plugins root help lists: those on `PATH` the tree does not shadow.
fn pluginNames(
    app: App,
    arena: Allocator,
    env: Environment,
    root: *const Command,
) Allocator.Error![]const []const u8 {
    const names = plugin.list(arena, env.io, env.environ, app.plugins.?) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return &.{};
    };
    var shown: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        if (root.findSubcommand(name) == null) try shown.append(arena, name);
    }
    return shown.items;
}

/// A plugin was found but could not be started, as sh(1) reports it.
pub const exit_cannot_run: u8 = 126;

/// `args` with each `@file` before `--` replaced by the words of `file`. A file that cannot
/// be read or split is reported, and is `error.ResponseFile`.
fn expandResponseFiles(
    app: App,
    arena: Allocator,
    env: Environment,
    args: []const []const u8,
) (Allocator.Error || error{ResponseFile} || Io.Writer.Error)![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            try out.appendSlice(arena, args[i..]);
            break;
        }
        if (arg.len < 2 or arg[0] != '@') {
            try out.append(arena, arg);
            continue;
        }
        const file = arg[1..];
        const limit: Io.Limit = .limited(max_response_file);
        const text = Io.Dir.cwd().readFileAlloc(env.io, file, arena, limit) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error");
            try env.err.print("{s}: {s}\n", .{ arg, @errorName(err) });
            return error.ResponseFile;
        };
        const words = shell.tokenize(arena, text) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error");
            const reason = app.shellMessage(err);
            try Messages.render(env.err, app.messages.response_file, &.{ arg, reason });
            try env.err.writeByte('\n');
            return error.ResponseFile;
        };
        try out.appendSlice(arena, words);
    }
    return out.items;
}

/// The largest response file read, in bytes.
const max_response_file = 1 << 20;

/// Runs the hooks and the handler in order; stops at the first error.
fn runHandlers(ctx: *Context) anyerror!void {
    const path = ctx.path;
    const leaf = path[path.len - 1];
    // Checks across each command's flags and positionals, every problem at once.
    for (path) |cmd| if (cmd.check) |check| try check(ctx);
    for (path) |cmd| if (cmd.persistent_pre_run) |hook| try hook(ctx);
    if (leaf.pre_run) |hook| try hook(ctx);
    try leaf.run.?(ctx);
    if (leaf.post_run) |hook| try hook(ctx);
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i].persistent_post_run) |hook| try hook(ctx);
    }
}

fn reportUsage(
    app: App,
    arena: Allocator,
    env: Environment,
    root: *const Command,
    args: []const []const u8,
    usage: parse.Usage,
) InternalError!u8 {
    assert(usage.message.len > 0);
    // Name the deepest command the arguments reach, for the pointer to its help.
    var path: std.ArrayList(*const Command) = .empty;
    try path.append(arena, root);
    for (args) |arg| {
        const sub = path.getLast().findSubcommand(arg) orelse continue;
        try path.append(arena, sub);
    }
    const path_text = try parse.pathString(arena, path.items);
    if (wantsJson(args)) {
        const run_help = try Messages.allocRender(arena, app.messages.run_help, &.{path_text});
        var json: std.json.Stringify = .{ .writer = env.err };
        try json.write(.{
            .@"error" = usage.message,
            .hint = if (usage.hint.len > 0)
                try std.mem.concat(arena, u8, &.{ usage.hint, " ", run_help })
            else
                run_help,
        });
        try env.err.writeByte('\n');
        return exit_usage;
    }
    try app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error");
    try env.err.print("{s}\n", .{usage.message});
    const hint = app.theme.hint.lowered(env.err_color);
    if (usage.hint.len > 0) {
        try Theme.paint(env.err, env.err_color, hint, usage.hint);
        try env.err.writeByte('\n');
    }
    if (env.err_color != .none) try hint.writeSgr(env.err);
    try Messages.render(env.err, app.messages.run_help, &.{path_text});
    if (env.err_color != .none and hint.hasSgr()) try env.err.writeAll(ansi.reset);
    try env.err.writeByte('\n');
    return exit_usage;
}

/// Whether `args` ask for `-o json` or `-o jsonl` (the last `-o` wins), read without
/// parsing them: a usage error stops the parser before it may reach the flag.
fn wantsJson(args: []const []const u8) bool {
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        const value = if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) blk: {
            i += 1;
            if (i == args.len) break;
            break :blk args[i];
        } else if (std.mem.startsWith(u8, arg, "--output="))
            arg["--output=".len..]
        else if (std.mem.startsWith(u8, arg, "-o"))
            std.mem.trimStart(u8, arg[2..], "=")
        else
            continue;
        json = std.mem.eql(u8, value, "json") or std.mem.eql(u8, value, "jsonl");
    }
    return json;
}

fn shellMessage(app: App, err: shell.Error) []const u8 {
    return switch (err) {
        error.UnterminatedQuote => app.messages.unterminated_quote,
        error.TrailingBackslash => app.messages.trailing_backslash,
        error.OutOfMemory => app.messages.out_of_memory,
    };
}

fn reportFailure(app: App, env: Environment, ctx: *Context, err: anyerror) u8 {
    if (err == error.CommandFailed) return exit_failure;
    // Nothing useful can be said on a closed pipe, and the reader has what it wanted.
    if (err == error.WriteFailed) return exit_broken_pipe;
    if (err == error.UsageFailed) return exit_usage;
    if (err == error.ConfigFailed) return exit_config;
    if (app.exit_status) |map| {
        if (map(err)) |status| return status;
    }
    if (ctx.output == .json or ctx.output == .jsonl) {
        ctx.writeJsonError(@errorName(err), null);
    } else {
        app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error") catch {};
        env.err.print("{s}\n", .{@errorName(err)}) catch {};
    }
    return exit_failure;
}

/// The root as executed: `app.root`, plus `complete.command` when `completion_command` is
/// on and the root has no `completion` of its own.
/// The tree as this run sees it: without the commands and flags of features that are off,
/// and with `completion` mounted.
fn effectiveRoot(
    app: App,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
) Allocator.Error!*const Command {
    var tree = app.root;
    if (hasFeatures(app.root)) tree = try app.withoutDisabled(arena, app.root, environ);
    if (app.color_flag and !hasFlag(tree, "color")) {
        const colored = try arena.create(Command);
        colored.* = tree.*;
        colored.persistent_flags = try std.mem.concat(arena, Flag, &.{
            tree.persistent_flags,
            &.{spec.color_flag},
        });
        tree = colored;
    }
    if (!app.completion_command or tree.findSubcommand("completion") != null) return tree;
    const subcommands = try arena.alloc(Command, tree.subcommands.len + 1);
    @memcpy(subcommands[0..tree.subcommands.len], tree.subcommands);
    subcommands[tree.subcommands.len] = complete.command;
    const root = try arena.create(Command);
    root.* = tree.*;
    root.subcommands = subcommands;
    return root;
}

fn hasFlag(cmd: *const Command, name: []const u8) bool {
    for (cmd.flags) |flag| if (std.mem.eql(u8, flag.name, name)) return true;
    for (cmd.persistent_flags) |flag| if (std.mem.eql(u8, flag.name, name)) return true;
    return false;
}

fn hasFeatures(cmd: *const Command) bool {
    if (cmd.feature != null) return true;
    for (cmd.flags) |flag| if (flag.feature != null) return true;
    for (cmd.persistent_flags) |flag| if (flag.feature != null) return true;
    for (cmd.subcommands) |*sub| if (hasFeatures(sub)) return true;
    return false;
}

fn featureOn(app: App, name: ?[]const u8, environ: *const std.process.Environ.Map) bool {
    const feature = name orelse return true;
    if (app.feature_enabled) |enabled| return enabled(feature, environ);
    const value = environ.get(feature) orelse return false;
    return Flag.parseBool(value) orelse false;
}

/// A copy of `cmd` without what belongs to features that are off.
fn withoutDisabled(
    app: App,
    arena: Allocator,
    cmd: *const Command,
    environ: *const std.process.Environ.Map,
) Allocator.Error!*const Command {
    const kept = try arena.create(Command);
    kept.* = cmd.*;
    kept.flags = try app.enabledFlags(arena, cmd.flags, environ);
    kept.persistent_flags = try app.enabledFlags(arena, cmd.persistent_flags, environ);
    var subcommands: std.ArrayList(Command) = .empty;
    for (cmd.subcommands) |*sub| {
        if (!app.featureOn(sub.feature, environ)) continue;
        try subcommands.append(arena, (try app.withoutDisabled(arena, sub, environ)).*);
    }
    kept.subcommands = subcommands.items;
    return kept;
}

fn enabledFlags(
    app: App,
    arena: Allocator,
    flags: []const Flag,
    environ: *const std.process.Environ.Map,
) Allocator.Error![]const Flag {
    var kept: std.ArrayList(Flag) = .empty;
    for (flags) |flag| if (app.featureOn(flag.feature, environ)) try kept.append(arena, flag);
    return kept.items;
}

/// `args` with a user alias in the first word expanded; an error for an alias whose
/// expansion cannot be split.
fn expandAlias(
    app: App,
    arena: Allocator,
    root: *const Command,
    args: []const []const u8,
) error{ OutOfMemory, BadAlias }!?[]const []const u8 {
    if (args.len == 0 or root.findSubcommand(args[0]) != null) return null;
    for (app.aliases) |alias| {
        if (!std.mem.eql(u8, alias[0], args[0])) continue;
        const words = shell.tokenize(arena, alias[1]) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadAlias,
        };
        const out = try arena.alloc([]const u8, words.len + args.len - 1);
        @memcpy(out[0..words.len], words);
        @memcpy(out[words.len..], args[1..]);
        return out;
    }
    return null;
}

/// `help --search <words...>`: the commands that mention the words.
fn searchHelp(
    app: App,
    arena: Allocator,
    env: Environment,
    root: *const Command,
    words: []const []const u8,
    translation: ?*const i18n.Translation,
) InternalError!u8 {
    const name = app.displayName();
    if (words.len == 0) {
        try app.theme.writePrefix(env.err, env.err_color, name, .@"error");
        try Messages.render(env.err, app.messages.needs_argument, &.{"--search"});
        try env.err.writeByte('\n');
        return exit_usage;
    }
    const term = try std.mem.join(arena, " ", words);
    const count = try help.search(arena, env.out, root, term, .{
        .messages = app.messages,
        .translation = translation,
    });
    if (count > 0) return exit_success;
    try app.theme.writePrefix(env.err, env.err_color, name, .@"error");
    try Messages.render(env.err, app.messages.search_none, &.{term});
    try env.err.writeByte('\n');
    return exit_failure;
}

/// What `--log-level`, `-v` (each a step down from `warn`), and `-q` ask for.
fn logLevel(occurrences: []const parse.Occurrence, quiet: bool) Context.LogLevel {
    if (builtinValue(occurrences, "log_level")) |name| {
        if (std.meta.stringToEnum(Context.LogLevel, name)) |level| return level;
    }
    var steps: u8 = 0;
    for (occurrences) |occurrence| {
        if (std.mem.eql(u8, occurrence.flag.field, "verbose")) steps +|= 1;
    }
    if (steps > 0) return @fromBackingInt(@intCast(@backingInt(Context.LogLevel.warn) -| steps));
    return if (quiet) .@"error" else .warn;
}

/// The value of the built-in flag whose field is `field` (`yes`, `dry_run`, `output`).
/// The value of the `--color` `color_flag` added, when given.
fn colorChoice(occurrences: []const parse.Occurrence) ?spec.ColorChoice {
    var found: ?spec.ColorChoice = null;
    for (occurrences) |occurrence| {
        if (occurrence.flag.help.ptr != Messages.english.color_flag.ptr) continue;
        found = std.meta.stringToEnum(spec.ColorChoice, occurrence.value) orelse found;
    }
    return found;
}

fn builtinValue(occurrences: []const parse.Occurrence, field: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (occurrences) |occurrence| {
        if (std.mem.eql(u8, occurrence.flag.field, field)) found = occurrence.value;
    }
    return found;
}

const testing = std.testing;
const spec = @import("spec.zig");
const cli_testing = @import("testing.zig");

const Recorder = struct {
    events: std.ArrayList([]const u8) = .empty,
    fn record(ctx: *Context, event: []const u8) !void {
        const self = ctx.data(*Recorder);
        try self.events.append(testing.allocator, event);
    }
};

fn rootPre(ctx: *Context) !void {
    try Recorder.record(ctx, "root-pre");
}
fn rootPost(ctx: *Context) !void {
    try Recorder.record(ctx, "root-post");
}
fn leafPre(ctx: *Context) !void {
    try Recorder.record(ctx, "leaf-pre");
}
fn leafPost(ctx: *Context) !void {
    try Recorder.record(ctx, "leaf-post");
}

const GreetFlags = struct {
    name: []const u8 = "world",
    shout: bool = false,
};
const greet_flags = sets.flags(GreetFlags, field_.none, .{ .fields = .{
    .name = .{ .short = 'n' },
} });

fn greet(ctx: *Context, flags: GreetFlags) !void {
    try Recorder.record(ctx, "run");
    try ctx.out.print("hello, {s}{s}\n", .{ flags.name, if (flags.shout) "!" else "" });
}

fn failing(ctx: *Context) !void {
    return ctx.fail("cannot do {s}", .{"that"});
}

fn warns(ctx: *Context) !void {
    ctx.warn("careful", .{});
    try ctx.out.writeAll("done\n");
}

fn misused(ctx: *Context) !void {
    return ctx.usageError("bad {s}", .{"input"});
}

fn exits(ctx: *Context) !void {
    try ctx.out.writeAll("partial\n");
    return ctx.exit(130);
}

fn closedPipe(_: *Context) !void {
    return error.WriteFailed;
}

fn raw(_: *Context) !void {
    return error.DiskFull;
}

const test_root = spec.command(.{
    .name = "app",
    .summary = "Test app",
    .persistent_pre_run = rootPre,
    .persistent_post_run = rootPost,
    .subcommands = .{
        spec.command(.{
            .name = "greet",
            .summary = "Say hello",
            .flags = greet_flags,
            .pre_run = leafPre,
            .post_run = leafPost,
            .run = greet,
        }),
        spec.command(.{ .name = "fail", .run = failing }),
        spec.command(.{ .name = "raw", .run = raw }),
        spec.command(.{ .name = "misused", .run = misused }),
        spec.command(.{ .name = "warns", .run = warns }),
        spec.command(.{ .name = "pipe", .run = closedPipe }),
        spec.command(.{ .name = "exits", .run = exits }),
        spec.command(.{ .name = "old", .deprecated = "use warns", .run = warns }),
        spec.command(.{
            .name = "group",
            .subcommands = .{spec.command(.{ .name = "inner", .run = failing })},
        }),
    },
});

test "hooks run in order around the handler" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder };
    const r = try cli_testing.run(app, &.{ "greet", "-n", "zig", "--shout" }, .{});
    defer r.deinit();
    try testing.expectEqual(0, r.status);
    try testing.expectEqualStrings("hello, zig!\n", r.out);
    const expected = [_][]const u8{ "root-pre", "leaf-pre", "run", "leaf-post", "root-post" };
    try testing.expectEqual(expected.len, recorder.events.items.len);
    for (expected, recorder.events.items) |e, got| try testing.expectEqualStrings(e, got);
}

test "exit statuses and messages" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder };

    const failed = try cli_testing.run(app, &.{"fail"}, .{});
    defer failed.deinit();
    try testing.expectEqual(1, failed.status);
    try testing.expectEqualStrings("app: cannot do that\n", failed.err);

    const raw_error = try cli_testing.run(app, &.{"raw"}, .{});
    defer raw_error.deinit();
    try testing.expectEqual(1, raw_error.status);
    try testing.expectEqualStrings("app: DiskFull\n", raw_error.err);

    const usage = try cli_testing.run(app, &.{ "greet", "--nmae", "x" }, .{});
    defer usage.deinit();
    try testing.expectEqual(2, usage.status);
    try testing.expectEqualStrings(
        "app: unknown flag: --nmae\nDid you mean --name?\nRun 'app greet --help' for usage.\n",
        usage.err,
    );
}

fn mapDiskFull(err: anyerror) ?u8 {
    return if (err == error.DiskFull) 74 else null;
}

test "exit_status maps errors" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder, .exit_status = mapDiskFull };
    const r = try cli_testing.run(app, &.{"raw"}, .{});
    defer r.deinit();
    try testing.expectEqual(74, r.status);
}

test "help, version, groups, and the help command" {
    const app: App = .{ .root = &test_root, .version = "1.0.0" };

    const version = try cli_testing.run(app, &.{"--version"}, .{});
    defer version.deinit();
    try testing.expectEqualStrings("app 1.0.0\n", version.out);

    const bare = try cli_testing.run(app, &.{}, .{});
    defer bare.deinit();
    try testing.expectEqual(0, bare.status);
    try testing.expect(std.mem.startsWith(u8, bare.out, "Test app\n\nUsage:\n  app <command>\n"));

    const group = try cli_testing.run(app, &.{"group"}, .{});
    defer group.deinit();
    try testing.expect(std.mem.indexOf(u8, group.out, "  app group <command>\n") != null);

    const help_command = try cli_testing.run(app, &.{ "help", "greet" }, .{});
    defer help_command.deinit();
    const flag_help = try cli_testing.run(app, &.{ "greet", "--help" }, .{});
    defer flag_help.deinit();
    try testing.expectEqualStrings(flag_help.out, help_command.out);
    try testing.expect(std.mem.startsWith(u8, help_command.out, "Say hello\n"));
}

test "completion built-ins" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    // `completion` is mounted as a real command, so the root's hooks run for it too.
    const app: App = .{ .root = &test_root, .data = &recorder };

    const candidates = try cli_testing.run(app, &.{ "__complete", "gr" }, .{});
    defer candidates.deinit();
    try testing.expectEqualStrings("greet\tSay hello\ngroup\t\n", candidates.out);

    const bash = try cli_testing.run(app, &.{ "completion", "bash" }, .{});
    defer bash.deinit();
    try testing.expectEqual(0, bash.status);
    try testing.expect(
        std.mem.indexOf(u8, bash.out, "complete -o default -F _app_complete app") != null,
    );

    const bad = try cli_testing.run(app, &.{ "completion", "tcsh" }, .{});
    defer bad.deinit();
    try testing.expectEqual(2, bad.status);
}

fn ownCompletion(ctx: *Context) !void {
    try ctx.out.writeAll("mine\n");
}

test "a root's own completion command is kept" {
    const root = comptime spec.command(.{
        .name = "app",
        .subcommands = .{spec.command(.{ .name = "completion", .run = ownCompletion })},
    });
    const app: App = .{ .root = &root };
    const r = try cli_testing.run(app, &.{"completion"}, .{});
    defer r.deinit();
    try testing.expectEqual(0, r.status);
    try testing.expectEqualStrings("mine\n", r.out);
}

test "help_command off, help for unknown commands, no version" {
    const off: App = .{ .root = &test_root, .help_command = false };
    const help_word = try cli_testing.run(off, &.{"help"}, .{});
    defer help_word.deinit();
    try testing.expectEqual(2, help_word.status);
    try testing.expectEqualStrings(
        "app: unknown command \"help\" for \"app\"\nRun 'app --help' for usage.\n",
        help_word.err,
    );
    const listing = try cli_testing.run(off, &.{}, .{});
    defer listing.deinit();
    try testing.expect(std.mem.indexOf(u8, listing.out, "Additional Commands") == null);

    const app: App = .{ .root = &test_root };
    const unknown = try cli_testing.run(app, &.{ "help", "greeet" }, .{});
    defer unknown.deinit();
    try testing.expectEqual(2, unknown.status);
    try testing.expectEqualStrings(
        "app: unknown command \"greeet\" for \"app\"\nDid you mean \"greet\"?\n" ++
            "Run 'app --help' for usage.\n",
        unknown.err,
    );
    const nested = try cli_testing.run(app, &.{ "help", "group", "inner" }, .{});
    defer nested.deinit();
    try testing.expectEqual(0, nested.status);
    try testing.expect(std.mem.startsWith(u8, nested.out, "Usage:\n  app group inner [flags]\n"));

    const version = try cli_testing.run(app, &.{"--version"}, .{});
    defer version.deinit();
    try testing.expectEqual(2, version.status);
    try testing.expectEqualStrings(
        "app: unknown flag: --version\nRun 'app --help' for usage.\n",
        version.err,
    );
}

const LegacyFlags = struct {
    legacy: bool = false,
};
const legacy_flags = sets.flags(LegacyFlags, field_.Set(.{field_.Spec(LegacyFlags){ .fields = .{
    .legacy = .{ .deprecated = "drop it" },
} }}), .{});

test "deprecated flags and commands warn on stderr and still run" {
    const root = comptime spec.command(.{
        .name = "app",
        .subcommands = .{spec.command(.{
            .name = "old",
            .deprecated = "use new",
            .flags = legacy_flags,
            .run = struct {
                fn run(ctx: *Context, flags: LegacyFlags) !void {
                    try ctx.out.print("legacy={}\n", .{flags.legacy});
                }
            }.run,
        })},
    });
    const app: App = .{ .root = &root, .name = "tool" };
    const r = try cli_testing.run(app, &.{ "old", "--legacy" }, .{});
    defer r.deinit();
    try testing.expectEqual(0, r.status);
    try testing.expectEqualStrings("legacy=true\n", r.out);
    try testing.expectEqualStrings(
        "tool: warning: command \"old\" is deprecated: use new\n" ++
            "tool: warning: flag --legacy is deprecated: drop it\n",
        r.err,
    );
}

test "post hooks do not run when the handler fails" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const root = comptime spec.command(.{
        .name = "app",
        .persistent_pre_run = rootPre,
        .persistent_post_run = rootPost,
        .subcommands = .{spec.command(.{
            .name = "x",
            .pre_run = leafPre,
            .post_run = leafPost,
            .run = raw,
        })},
    });
    const app: App = .{ .root = &root, .data = &recorder };
    const r = try cli_testing.run(app, &.{"x"}, .{});
    defer r.deinit();
    try testing.expectEqual(1, r.status);
    const expected = [_][]const u8{ "root-pre", "leaf-pre" };
    try testing.expectEqual(expected.len, recorder.events.items.len);
    for (expected, recorder.events.items) |e, got| try testing.expectEqualStrings(e, got);
}

test executeLine {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder };
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const env: Environment = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .environ = &environ,
        .out = &out.writer,
        .err = &err.writer,
    };
    try testing.expectEqual(0, app.executeLine(env, "greet -n 'big zig' --shout # loud"));
    try testing.expectEqualStrings("hello, big zig!\n", out.written());
    try testing.expectEqual(2, app.executeLine(env, "greet -n \"open"));
    try testing.expectEqualStrings("app: unterminated quote\n", err.written());
}

fn mapNothing(_: anyerror) ?u8 {
    return null;
}

test "exit_status returning null falls back to 1 and the error name" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder, .exit_status = mapNothing };
    const r = try cli_testing.run(app, &.{"raw"}, .{});
    defer r.deinit();
    try testing.expectEqual(1, r.status);
    try testing.expectEqualStrings("app: DiskFull\n", r.err);
    // `ctx.fail` is never passed to the map, and prints nothing more.
    const failed = try cli_testing.run(app, &.{"fail"}, .{});
    defer failed.deinit();
    try testing.expectEqual(1, failed.status);
    try testing.expectEqualStrings("app: cannot do that\n", failed.err);
}

test "ctx.usage exits 2 and points at help" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder };
    const r = try cli_testing.run(app, &.{"misused"}, .{});
    defer r.deinit();
    try testing.expectEqual(2, r.status);
    try testing.expectEqualStrings("app: bad input\nRun 'app misused --help' for usage.\n", r.err);
}

test "-q and --quiet suppress warnings but not output or errors" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder };

    const loud = try cli_testing.run(app, &.{"warns"}, .{});
    defer loud.deinit();
    try testing.expectEqualStrings("app: warning: careful\n", loud.err);

    const quiet = try cli_testing.run(app, &.{ "warns", "-q" }, .{});
    defer quiet.deinit();
    try testing.expectEqualStrings("", quiet.err);
    try testing.expectEqualStrings("done\n", quiet.out);

    const deprecated = try cli_testing.run(app, &.{ "--quiet", "old" }, .{});
    defer deprecated.deinit();
    try testing.expectEqualStrings("", deprecated.err);

    const failed = try cli_testing.run(app, &.{ "-q", "fail" }, .{});
    defer failed.deinit();
    try testing.expectEqualStrings("app: cannot do that\n", failed.err);

    const help_text = try cli_testing.run(app, &.{ "warns", "--help" }, .{});
    defer help_text.deinit();
    try testing.expect(std.mem.indexOf(u8, help_text.out, "-q, --quiet") != null);

    const off: App = .{ .root = &test_root, .data = &recorder, .quiet_flag = false };
    const rejected = try cli_testing.run(off, &.{ "warns", "-q" }, .{});
    defer rejected.deinit();
    try testing.expectEqual(2, rejected.status);
}

test "--color overrides the detected color, only with color_flag" {
    const gpa = testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var recorder: Recorder = .{};
    defer recorder.events.deinit(gpa);
    const app: App = .{ .root = &test_root, .data = &recorder, .color_flag = true };
    const Case = struct { []const []const u8, Level, bool };
    for ([_]Case{
        .{ &.{ "fail", "--color", "always" }, .none, true },
        .{ &.{ "--color=never", "fail" }, .basic, false },
        .{ &.{ "fail", "--color", "auto" }, .basic, true },
        .{ &.{"fail"}, .none, false },
    }) |case| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: Io.Writer.Allocating = .init(gpa);
        defer err.deinit();
        const env: Environment = .{
            .io = testing.io,
            .gpa = gpa,
            .environ = &environ,
            .out = &out.writer,
            .err = &err.writer,
            .color = case[1],
            .err_color = case[1],
        };
        try testing.expectEqual(exit_failure, app.execute(env, case[0]));
        const colored = std.mem.indexOfScalar(u8, err.written(), 0x1b) != null;
        try testing.expectEqual(case[2], colored);
    }
    const help_text = try cli_testing.run(app, &.{"--help"}, .{});
    defer help_text.deinit();
    try testing.expect(std.mem.indexOf(u8, help_text.out, "--color <when>") != null);
    const values = try cli_testing.run(app, &.{ "__complete", "greet", "--color", "" }, .{});
    defer values.deinit();
    try testing.expectEqualStrings("auto\nalways\nnever\n", values.out);
    const bad = try cli_testing.run(app, &.{ "greet", "--color", "pink" }, .{});
    defer bad.deinit();
    try testing.expectEqual(exit_usage, bad.status);
    const off: App = .{ .root = &test_root, .data = &recorder };
    const unknown = try cli_testing.run(off, &.{ "greet", "--color", "never" }, .{});
    defer unknown.deinit();
    try testing.expectEqual(exit_usage, unknown.status);
}

test "a failed write ends quietly with the broken-pipe status" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder };
    const r = try cli_testing.run(app, &.{"pipe"}, .{});
    defer r.deinit();
    try testing.expectEqual(exit_broken_pipe, r.status);
    try testing.expectEqualStrings("", r.err);
}

test "ctx.exit ends with that status and keeps the output" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const app: App = .{ .root = &test_root, .data = &recorder };
    const r = try cli_testing.run(app, &.{"exits"}, .{});
    defer r.deinit();
    try testing.expectEqual(130, r.status);
    try testing.expectEqualStrings("partial\n", r.out);
    try testing.expectEqualStrings("", r.err);
}

const RangeFlags = struct {
    low: u32 = 0,
    high: u32 = 10,
    tags: []const []const u8 = &.{},
};

fn ordered(flags: RangeFlags, w: *std.Io.Writer) !void {
    if (flags.low > flags.high) {
        return field_.fail(
            w,
            "--low ({0}) must not exceed --high ({1})",
            .{ flags.low, flags.high },
        );
    }
}

const range_flags = sets.flags(RangeFlags, field_.Set(.{field_.Spec(RangeFlags){
    .fields = .{
        .high = .{ .checks = &.{.max(100)} },
        .tags = .{ .checks = &.{.maxLen(1)}, .each = &.{.minLen(2)} },
    },
    .checks = &.{.from(ordered)},
}}), .{ .fields = .{ .tags = .{ .name = "tag" } } });

fn printRange(ctx: *Context, flags: RangeFlags) !void {
    try ctx.out.print("{d}..{d}\n", .{ flags.low, flags.high });
}

const range_root = spec.command(.{ .name = "app", .flags = range_flags, .run = printRange });

test "checks across a flags struct's fields run before the handler, every failure at once" {
    const app: App = .{ .root = &range_root };
    const ok = try cli_testing.run(app, &.{ "--low", "2" }, .{});
    defer ok.deinit();
    try ok.expect(0, "2..10\n", "");
    const bad = try cli_testing.run(app, &.{ "--low", "20" }, .{});
    defer bad.deinit();
    try bad.expect(2, "", "app: --low (20) must not exceed --high (10)\n" ++
        "Run 'app --help' for usage.\n");
    // A value's own check fails as it is parsed; a list's, once it is whole.
    const high = try cli_testing.run(app, &.{ "--high", "200" }, .{});
    defer high.deinit();
    try high.expect(2, "", "app: invalid value \"200\" for flag --high: must be at most 100\n" ++
        "Run 'app --help' for usage.\n");
    const tags = try cli_testing.run(app, &.{ "--tag", "ab", "--tag", "cd", "--low", "20" }, .{});
    defer tags.deinit();
    try tags.expect(2, "", "app: --tag: must be at most 1 long\n" ++
        "app: --low (20) must not exceed --high (10)\n" ++
        "Run 'app --help' for usage.\n");
}

const EchoFlags = struct {
    loud: bool = false,
};

fn echo(ctx: *Context, flags: EchoFlags) !void {
    try ctx.out.print("{s}", .{if (flags.loud) "loud " else ""});
    for (ctx.args) |arg| try ctx.out.print("[{s}]", .{arg});
    try ctx.out.writeAll(" |");
    for (ctx.passthrough) |arg| try ctx.out.print(" {s}", .{arg});
    try ctx.out.writeByte('\n');
}

const words_root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{
            .name = "echo",
            .flags = EchoFlags,
            .args = .{ .max = null },
            .run = echo,
        }),
        spec.command(.{
            .name = "exec",
            .flags = EchoFlags,
            .args = .{ .max = 1, .passthrough = true },
            .run = echo,
        }),
        spec.command(.{
            .name = "wrap",
            .flags = EchoFlags,
            .args = .{ .max = null, .interspersed = false },
            .run = echo,
        }),
        spec.command(.{ .name = "explain", .run = noop }),
        spec.command(.{ .name = "export", .aliases = &.{"ex"}, .run = noop }),
    },
});

fn noop(_: *Context) !void {}

fn expectRun(
    app: App,
    args: []const []const u8,
    status: u8,
    out: []const u8,
    err: []const u8,
) !void {
    const result = try cli_testing.run(app, args, .{});
    defer result.deinit();
    try result.expect(status, out, err);
}

test "passthrough arguments and commands that are not interspersed" {
    const app: App = .{ .root = &words_root };
    try expectRun(app, &.{ "echo", "a", "--loud", "--", "--b" }, 0, "loud [a][--b] |\n", "");
    const exec_args = [_][]const u8{ "exec", "x", "--", "cmd", "--loud", "--" };
    try expectRun(app, &exec_args, 0, "[x] | cmd --loud --\n", "");
    const wrap_args = [_][]const u8{ "wrap", "--loud", "cmd", "--loud", "-x" };
    try expectRun(app, &wrap_args, 0, "loud [cmd][--loud][-x] |\n", "");
}

test "prefix matching, when asked for" {
    const off: App = .{ .root = &words_root };
    try expectRun(off, &.{"ech"}, 2, "", "app: unknown command \"ech\" for \"app\"\n" ++
        "Did you mean \"echo\"?\nRun 'app --help' for usage.\n");
    const on: App = .{ .root = &words_root, .prefix_matching = true };
    try expectRun(on, &.{ "ech", "a" }, 0, "[a] |\n", "");
    try expectRun(on, &.{"expl"}, 0, "", "");
    try expectRun(on, &.{"ex"}, 0, "", ""); // An alias, exactly.
    try expectRun(on, &.{"exp"}, 2, "", "app: ambiguous command \"exp\" for \"app\": " ++
        "could be explain or export\nRun 'app --help' for usage.\n");
}

test "response files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "args.txt",
        .data = "--loud 'two words' # a comment\nthree\n",
    });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const at = try std.fmt.allocPrint(testing.allocator, "@{s}/args.txt", .{dir});
    defer testing.allocator.free(at);
    const missing = try std.fmt.allocPrint(testing.allocator, "@{s}/missing.txt", .{dir});
    defer testing.allocator.free(missing);

    const on: App = .{ .root = &words_root, .response_files = true };
    try expectRun(on, &.{ "echo", at, "four" }, 0, "loud [two words][three][four] |\n", "");
    const literal = try std.fmt.allocPrint(testing.allocator, "[{s}] |\n", .{at});
    defer testing.allocator.free(literal);
    try expectRun(on, &.{ "echo", "--", at }, 0, literal, "");
    try expectRun(on, &.{ "echo", "@" }, 0, "[@] |\n", "");
    const failed = try cli_testing.run(on, &.{ "echo", missing }, .{});
    defer failed.deinit();
    try testing.expectEqual(2, failed.status);
    try testing.expect(std.mem.endsWith(u8, failed.err, "missing.txt: FileNotFound\n"));

    const off: App = .{ .root = &words_root };
    try expectRun(off, &.{ "echo", "@x" }, 0, "[@x] |\n", "");
}

const CopyArgs = struct {
    mode: enum { fast, safe },
    count: u8 = 1,
    files: []const []const u8 = &.{},
};
const copy_args = sets.args(
    CopyArgs,
    field_.none,
    .{ .fields = .{ .files = .{ .name = "file" } } },
);

fn copy(ctx: *Context, flags: EchoFlags, args: CopyArgs) !void {
    try ctx.out.print("{t} x{d}{s}", .{ args.mode, args.count, if (flags.loud) " loud" else "" });
    for (args.files) |file| try ctx.out.print(" {s}", .{file});
    try ctx.out.writeByte('\n');
}

fn copyArgsOnly(ctx: *Context, args: CopyArgs) !void {
    try ctx.out.print("{t}\n", .{args.mode});
}

const typed_root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{ .name = "copy", .flags = EchoFlags, .args = copy_args, .run = copy }),
        spec.command(.{ .name = "mode", .args = copy_args, .run = copyArgsOnly }),
    },
});

test "typed positionals" {
    const copy_command = typed_root.subcommands[0];
    try testing.expectEqualStrings("<mode> [count] [file...]", copy_command.args.usage);
    try testing.expectEqual(1, copy_command.args.min);
    try testing.expectEqual(null, copy_command.args.max);

    const app: App = .{ .root = &typed_root };
    try expectRun(app, &.{ "copy", "safe" }, 0, "safe x1\n", "");
    try expectRun(app, &.{ "copy", "fast", "3", "a", "--loud", "b" }, 0, "fast x3 loud a b\n", "");
    try expectRun(app, &.{ "mode", "fast" }, 0, "fast\n", "");
    try expectRun(app, &.{ "copy", "slow" }, 2, "", "app: invalid value \"slow\" for <mode>: " ++
        "expected fast|safe\nRun 'app copy --help' for usage.\n");
    try expectRun(app, &.{"copy"}, 2, "", "app: \"app copy\" requires at least 1 argument, " ++
        "received 0\nRun 'app copy --help' for usage.\n");
    try expectRun(app, &.{ "__complete", "copy", "" }, 0, "fast\nsafe\n", "");
    try expectRun(app, &.{ "__complete", "copy", "fast", "" }, 0, "", "");
}

test "plugins run from PATH, show in root help, and complete" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const windows = builtin.os.tag == .windows;
    const script = if (windows)
        "@if \"%~1\"==\"a\" if \"%~2\"==\"--flag\" exit /b 7\r\n@exit /b 1\r\n"
    else
        "#!/bin/sh\n[ \"$1\" = a ] && [ \"$2\" = --flag ] && exit 7\nexit 1\n";
    const permissions: Io.File.Permissions = .executable_file;
    const name = if (windows) "app-hello.cmd" else "app-hello";
    const file = try tmp.dir.createFile(testing.io, name, .{ .permissions = permissions });
    try file.writeStreamingAll(testing.io, script);
    file.close(testing.io);
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    const app: App = .{ .root = &words_root, .plugins = "app-" };
    // cmd.exe, which runs a batch file, does not start without `SystemRoot`.
    const root = if (windows) testing.environ.getAlloc(testing.allocator, "SystemRoot") catch
        return error.SkipZigTest else "";
    defer if (windows) testing.allocator.free(root);
    const env: []const [2][]const u8 = if (windows)
        &.{ .{ "PATH", dir }, .{ "SystemRoot", root } }
    else
        &.{.{ "PATH", dir }};
    const ran = try cli_testing.run(app, &.{ "hello", "a", "--flag" }, .{ .env = env });
    defer ran.deinit();
    try ran.expect(7, "", "");

    const help_text = try cli_testing.run(app, &.{"--help"}, .{ .env = env });
    defer help_text.deinit();
    try testing.expect(std.mem.indexOf(u8, help_text.out, "\nPlugins:\n  hello\n\n") != null);

    const completed = try cli_testing.run(app, &.{ "__complete", "h" }, .{ .env = env });
    defer completed.deinit();
    try completed.expect(0, "help\tHelp about any command\nhello\n", "");

    // Not found: the usual unknown-command error.
    const missing = try cli_testing.run(app, &.{"nope"}, .{ .env = env });
    defer missing.deinit();
    try testing.expectEqual(2, missing.status);
}

const german: Messages = .{
    .unknown_command = "unbekannter Befehl \"{0}\" für \"{1}\"",
    .run_help = "Hilfe: '{0} --help'",
    .did_you_mean = "Meinten Sie \"{0}\"?",
    .heading_usage = "Aufruf",
    .heading_flags = "Optionen",
    .help_flag = "Hilfe zu {0}",
};

test "a replaced message table" {
    const app: App = .{ .root = &words_root, .messages = &german };
    try expectRun(app, &.{"ech"}, 2, "", "app: unbekannter Befehl \"ech\" für \"app\"\n" ++
        "Meinten Sie \"echo\"?\nHilfe: 'app --help'\n");
    const text = try cli_testing.run(app, &.{ "echo", "--help" }, .{});
    defer text.deinit();
    try testing.expect(std.mem.startsWith(u8, text.out, "Aufruf:\n  app echo [flags] [args...]\n"));
    try testing.expect(std.mem.indexOf(u8, text.out, "\nOptionen:\n") != null);
    try testing.expect(std.mem.indexOf(u8, text.out, "Hilfe zu echo\n") != null);
}

fn sleepy(ctx: *Context) !void {
    try Recorder.record(ctx, "run");
    interrupt.request(); // As Ctrl-C would, once the command is running.
    try ctx.io.sleep(.fromSeconds(30), .awake);
    try Recorder.record(ctx, "not reached");
}

fn tidy(ctx: *Context) !void {
    try Recorder.record(ctx, "cleanup");
}

fn failing2(ctx: *Context) !void {
    try Recorder.record(ctx, "run");
    return ctx.fail("broke", .{});
}

const cleanup_root = spec.command(.{
    .name = "app",
    .cleanup = tidy,
    .subcommands = .{
        spec.command(.{ .name = "sleep", .run = sleepy }),
        spec.command(.{ .name = "fail", .run = failing2 }),
    },
});

test "cleanup hooks run after a failure, and after Ctrl-C cancels the command" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);

    const plain: App = .{ .root = &cleanup_root, .data = &recorder };
    try expectRun(plain, &.{"fail"}, 1, "", "app: broke\n");
    try testing.expectEqual(2, recorder.events.items.len);
    try testing.expectEqualStrings("cleanup", recorder.events.items[1]);

    if (!interrupt.supported) return;
    recorder.events.clearRetainingCapacity();
    const cancelling: App = .{
        .root = &cleanup_root,
        .data = &recorder,
        .cancel_on_interrupt = true,
    };
    const start: Io.Timestamp = .now(testing.io, .awake);
    try expectRun(cancelling, &.{"sleep"}, 130, "", "");
    try testing.expect(start.untilNow(testing.io, .awake).toMilliseconds() < 5000);
    try testing.expectEqual(2, recorder.events.items.len);
    try testing.expectEqualStrings("run", recorder.events.items[0]);
    try testing.expectEqualStrings("cleanup", recorder.events.items[1]);
}

const LoginFlags = struct {
    user: []const u8,
    port: u16,
    mode: enum { fast, safe } = .fast,
};
const login_flags = sets.flags(LoginFlags, field_.Set(.{field_.Spec(LoginFlags){ .fields = .{
    .port = .{ .checks = &.{.min(1)} },
} }}), .{ .fields = .{
    .user = .{ .prompt = "User" },
    .port = .{ .prompt = "Port" },
} });

fn login(ctx: *Context, flags: LoginFlags) !void {
    try ctx.out.print("{s}@{d}\n", .{ flags.user, flags.port });
}

const login_root = spec.command(.{ .name = "app", .flags = login_flags, .run = login });

test "missing flags are asked for in an interactive run" {
    const app: App = .{ .root = &login_root };
    // Not interactive: the usual usage error.
    try expectRun(app, &.{}, 2, "", "app: required flag --user is not set\n" ++
        "Run 'app --help' for usage.\n");

    const asked = try cli_testing.run(app, &.{"--port=8"}, .{ .stdin = "ann\n" });
    defer asked.deinit();
    try asked.expect(0, "ann@8\n", "User: ");

    // An invalid answer is refused with the reason, and asked again.
    const again = try cli_testing.run(app, &.{}, .{ .stdin = "ann\nx\n0\n9\n" });
    defer again.deinit();
    try again.expect(0, "ann@9\n", "User: Port: invalid value \"x\" for flag --port: " ++
        "expected int\nPort: invalid value \"0\" for flag --port: must be at least 1\nPort: ");

    // No answer: the usage error after all.
    const ended = try cli_testing.run(app, &.{}, .{ .stdin = "ann\n" });
    defer ended.deinit();
    try ended.expect(2, "", "User: Port: app: required flag --port is not set\n" ++
        "Run 'app --help' for usage.\n");
}

const RenameArgs = struct {
    mode: enum { fast, safe },
    count: u8,
    rest: []const []const u8 = &.{},
};
const rename_args = sets.args(
    RenameArgs,
    field_.none,
    .{ .fields = .{ .mode = .{ .prompt = "Mode" }, .count = .{ .prompt = "Count" } } },
);

fn rename(ctx: *Context, args: RenameArgs) !void {
    try ctx.out.print("{t} {d} {d}\n", .{ args.mode, args.count, args.rest.len });
}

const PartlyArgs = struct {
    first: []const u8,
    second: []const u8,
};
const partly_args = sets.args(
    PartlyArgs,
    field_.none,
    .{ .fields = .{ .second = .{ .prompt = "Second" } } },
);

fn partly(ctx: *Context, args: PartlyArgs) !void {
    try ctx.out.print("{s} {s}\n", .{ args.first, args.second });
}

const asking_root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{ .name = "rename", .args = rename_args, .run = rename }),
        spec.command(.{ .name = "partly", .args = partly_args, .run = partly }),
    },
});

test "missing positionals with a .prompt are asked for in an interactive run" {
    const app: App = .{ .root = &asking_root };
    try expectRun(app, &.{"rename"}, 2, "", "app: \"app rename\" requires at least 2 " ++
        "arguments, received 0\nRun 'app rename --help' for usage.\n");

    const both = try cli_testing.run(app, &.{"rename"}, .{ .stdin = "fast\n3\n" });
    defer both.deinit();
    try both.expect(0, "fast 3 0\n", "Mode [fast/safe]: Count: ");

    // Only the missing one, re-asked until valid.
    const one = try cli_testing.run(app, &.{ "rename", "safe" }, .{ .stdin = "x\n7\n" });
    defer one.deinit();
    try one.expect(0, "safe 7 0\n", "Count: invalid value \"x\" for <count>: expected int\n" ++
        "Count: ");

    const ended = try cli_testing.run(app, &.{"rename"}, .{ .stdin = "safe\n" });
    defer ended.deinit();
    try ended.expect(2, "", "Mode [fast/safe]: Count: app: \"app rename\" requires at least " ++
        "2 arguments, received 1\nRun 'app rename --help' for usage.\n");

    // `first` has no prompt, so nothing is asked: the usual error.
    const partial = try cli_testing.run(app, &.{"partly"}, .{ .stdin = "a\nb\n" });
    defer partial.deinit();
    try partial.expect(2, "", "app: \"app partly\" requires at least 2 arguments, " ++
        "received 0\nRun 'app partly --help' for usage.\n");
    const second = try cli_testing.run(app, &.{ "partly", "a" }, .{ .stdin = "b\n" });
    defer second.deinit();
    try second.expect(0, "a b\n", "Second: ");
}

fn reportOk(ctx: *Context) !void {
    try ctx.out.writeAll("ok\n");
}

const shell_root = spec.command(.{
    .name = "app",
    .repl = true,
    .subcommands = .{
        spec.command(.{ .name = "status", .summary = "Show the status", .run = reportOk }),
        spec.command(.{
            .name = "db",
            .repl = true,
            .subcommands = .{spec.command(.{ .name = "ping", .run = reportOk })},
        }),
    },
});

test "a bare command with .repl starts a shell when interactive, else shows help" {
    const app: App = .{ .root = &shell_root };
    const help_text = try cli_testing.run(app, &.{}, .{});
    defer help_text.deinit();
    try testing.expect(std.mem.indexOf(u8, help_text.out, "Show the status") != null);

    const root_shell = try cli_testing.run(app, &.{}, .{ .stdin = "status\ndb ping\nexit\n" });
    defer root_shell.deinit();
    try root_shell.expect(0, "ok\nok\n", "app> app> app> ");

    // Inside a group, lines run under it, and `help` is about its commands.
    const group = try cli_testing.run(app, &.{"db"}, .{ .stdin = "ping\nhelp ping\nnope\n" });
    defer group.deinit();
    try testing.expectEqual(exit_usage, group.status);
    try testing.expect(std.mem.startsWith(u8, group.out, "ok\nUsage:\n  app db ping"));
    try testing.expect(std.mem.indexOf(u8, group.err, "unknown command \"nope\" for \"app db\"") !=
        null);

    // Anything besides the command's name, and the help, as before.
    const flagged = try cli_testing.run(app, &.{ "db", "--help" }, .{ .stdin = "ping\n" });
    defer flagged.deinit();
    try testing.expect(std.mem.startsWith(u8, flagged.out, "Usage:\n  app db <command>"));
    try testing.expectEqualStrings("", flagged.err);
}

test "help taller than the terminal goes through the pager" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const paged = try std.fs.path.join(gpa, &.{ dir, "paged" });
    defer gpa.free(paged);
    // A pager that copies its input to `paged`; on Windows `findstr "^"` does it exactly.
    const command = if (builtin.os.tag == .windows) command: {
        try tmp.dir.writeFile(io, .{
            .sub_path = "pager.cmd",
            .data = "@echo off\r\n\"%SystemRoot%\\System32\\findstr.exe\" \"^\" > \"%~1\"\r\n",
        });
        break :command try std.fmt.allocPrint(gpa, "{s}\\pager.cmd {s}", .{ dir, paged });
    } else try std.fmt.allocPrint(gpa, "sh -c 'cat >\"$0\"' {s}", .{paged});
    defer gpa.free(command);
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PAGER", command);
    if (builtin.os.tag == .windows) {
        // cmd.exe, which runs a batch file, does not start without `SystemRoot`.
        const root = testing.environ.getAlloc(gpa, "SystemRoot") catch return error.SkipZigTest;
        defer gpa.free(root);
        try environ.put("SystemRoot", root);
    }
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    const app: App = .{ .root = &test_root, .pager = true };
    const env: Environment = .{
        .io = io,
        .gpa = gpa,
        .environ = &environ,
        .out = &out.writer,
        .err = &err.writer,
        .rows = 3,
    };
    try testing.expectEqual(exit_success, app.execute(env, &.{"--help"}));
    try testing.expectEqualStrings("", out.written());
    const text = try tmp.dir.readFileAlloc(io, "paged", gpa, .unlimited);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Usage:\n  app <command>") != null);
    // Help that fits, or no terminal: written as usual.
    var tall = env;
    tall.rows = 500;
    try testing.expectEqual(exit_success, app.execute(tall, &.{"--help"}));
    try testing.expectEqualStrings(text, out.written());
}

const I18nFlags = struct {
    count: u32 = 1,
};
fn below100(count: u32, w: *std.Io.Writer) !void {
    if (count >= 100) return field_.fail(w, "{0} at once is over {1}", .{ count, 99 });
}
const i18n_flags = sets.flags(I18nFlags, field_.Set(.{field_.Spec(I18nFlags){ .fields = .{
    .count = .{ .help = "How many files", .checks = &.{.from(below100)} },
} }}), .{ .fields = .{
    .count = .{ .short = 'n' },
} });

fn i18nClean(ctx: *Context, flags: I18nFlags) !void {
    const line = try ctx.plural(
        flags.count,
        "Deleted {0} file",
        "Deleted {0} files",
        .{flags.count},
    );
    try ctx.out.print("{s}\n", .{line});
}

const i18n_root = spec.command(.{
    .name = "app",
    .summary = "Tidy things",
    .subcommands = &.{spec.command(.{
        .name = "clean",
        .summary = "Remove old files",
        .flags = i18n_flags,
        .run = i18nClean,
    })},
});

const i18n_german: i18n.Translation = .{
    .locale = "de",
    .messages = &i18n.messages.german,
    .strings = &.{
        .{ "Tidy things", "Räumt auf" },
        .{ "Remove old files", "Alte Dateien entfernen" },
        .{ "How many files", "Wie viele Dateien" },
        .{ "Deleted {0} files", "{0} Datei gelöscht|{0} Dateien gelöscht" },
        .{ "{0} at once is over {1}", "{0} auf einmal sind mehr als {1}" },
    },
};

const PutArgs = struct { files: []const []const u8 = &.{} };
const put_args = sets.args(PutArgs, field_.Set(.{field_.Spec(PutArgs){ .fields = .{
    .files = .{ .each = &.{.minLen(2)} },
} }}), .{ .fields = .{ .files = .{ .name = "file" } } });

fn put(_: *Context, _: PutArgs) !void {}

test "which value of a list failed, in the user's language" {
    const root = comptime spec.command(.{ .name = "app", .args = put_args, .run = put });
    const app: App = .{ .root = &root, .translations = &.{i18n_german} };
    try expectRun(app, &.{ "ab", "c" }, 2, "", "app: <file> (value 2): must be at least 2 long\n" ++
        "Run 'app --help' for usage.\n");
    const de = try cli_testing.run(app, &.{ "ab", "c" }, .{ .env = &.{.{ "LANG", "de" }} });
    defer de.deinit();
    try testing.expect(std.mem.startsWith(
        u8,
        de.err,
        "app: <file> (Wert 2): muss mindestens 2 lang sein\n",
    ));
}

test "translations: help, the library's sentences, and the app's own, by locale" {
    const app: App = .{ .root = &i18n_root, .translations = &.{i18n_german} };
    const help_de = try cli_testing.run(app, &.{ "clean", "--help" }, .{
        .env = &.{.{ "LANG", "de_DE.UTF-8" }},
    });
    defer help_de.deinit();
    try testing.expectEqualStrings(
        \\Alte Dateien entfernen
        \\
        \\Aufruf:
        \\  app clean [Optionen]
        \\
        \\Optionen:
        \\  -n, --count <int>   Wie viele Dateien (Standard: 1)
        \\  -h, --help          Hilfe zu clean
        \\  -q, --quiet         Warnungen unterdrücken
        \\
    , help_de.out);
    const two = try cli_testing.run(app, &.{ "clean", "-n", "2" }, .{
        .env = &.{.{ "LC_ALL", "de" }},
    });
    defer two.deinit();
    try two.expect(0, "2 Dateien gelöscht\n", "");
    const one = try cli_testing.run(
        app,
        &.{ "clean", "-n", "1" },
        .{ .env = &.{.{ "LANG", "de" }} },
    );
    defer one.deinit();
    try one.expect(0, "1 Datei gelöscht\n", "");
    const unknown = try cli_testing.run(app, &.{"clan"}, .{ .env = &.{.{ "LANG", "de" }} });
    defer unknown.deinit();
    try testing.expect(std.mem.startsWith(u8, unknown.err, "app: unbekannter Befehl \"clan\""));
    // A check's own words too, by their template, with the arguments filled in.
    const many = try cli_testing.run(app, &.{ "clean", "-n", "100" }, .{
        .env = &.{.{ "LANG", "de" }},
    });
    defer many.deinit();
    try testing.expect(std.mem.indexOf(u8, many.err, "100 auf einmal sind mehr als 99") != null);
    // No translation for the locale, or none set: English.
    const french = try cli_testing.run(
        app,
        &.{ "clean", "-n", "2" },
        .{ .env = &.{.{ "LANG", "fr" }} },
    );
    defer french.deinit();
    try french.expect(0, "Deleted 2 files\n", "");
    var forced = app;
    forced.locale = "de_CH";
    const swiss = try cli_testing.run(forced, &.{ "clean", "-n", "1" }, .{});
    defer swiss.deinit();
    try swiss.expect(0, "1 Datei gelöscht\n", "");
}

const ToolFlags = struct {
    name: []const u8 = "anon",
    key: ?[]const u8 = null,
    cert: ?[]const u8 = null,
    beta: bool = false,
};
const tool_flags = sets.flags(ToolFlags, field_.Set(.{field_.Spec(ToolFlags){ .fields = .{
    .name = .{ .checks = &.{ .minLen(2), .maxLen(5) } },
} }}), .{ .fields = .{
    .key = .{ .requires = &.{.cert} },
    .beta = .{ .feature = "APP_BETA" },
} });

const Row = struct { name: []const u8, size: u32 };

fn toolWipe(ctx: *Context, flags: ToolFlags) !void {
    if (ctx.dry_run) return ctx.out.print("would wipe {s}\n", .{flags.name});
    try ctx.out.print("wiped {s}\n", .{flags.name});
}

fn toolList(ctx: *Context) !void {
    try ctx.render(@as([]const Row, &.{
        .{ .name = "a", .size = 1 },
        .{ .name = "bb", .size = 22 },
    }));
}

fn toolSecret(ctx: *Context) !void {
    try ctx.out.writeAll("secret\n");
}

const tool_root = spec.command(.{
    .name = "tool",
    .subcommands = &.{
        spec.command(.{
            .name = "wipe",
            .summary = "Wipe it",
            .flags = tool_flags,
            .confirm = "Wipe everything?",
            .dry_run = true,
            .run = toolWipe,
        }),
        spec.command(.{ .name = "list", .summary = "List", .output = true, .run = toolList }),
        spec.command(.{
            .name = "secret",
            .summary = "Hidden until on",
            .feature = "APP_SECRET",
            .run = toolSecret,
        }),
    },
});

test "confirm: --yes, an answer at a terminal, and refusal without one" {
    const app: App = .{ .root = &tool_root };
    const refused = try cli_testing.run(app, &.{"wipe"}, .{});
    defer refused.deinit();
    try refused.expect(1, "", "tool: \"tool wipe\" asks for confirmation; run it at a " ++
        "terminal or pass --yes\n");
    const yes = try cli_testing.run(app, &.{ "wipe", "-y" }, .{});
    defer yes.deinit();
    try yes.expect(0, "wiped anon\n", "");
    const answered = try cli_testing.run(app, &.{"wipe"}, .{ .stdin = "YES\n" });
    defer answered.deinit();
    try answered.expect(0, "wiped anon\n", "Wipe everything? [y/N] ");
    const declined = try cli_testing.run(app, &.{"wipe"}, .{ .stdin = "\n" });
    defer declined.deinit();
    try declined.expect(1, "", "Wipe everything? [y/N] tool: not confirmed; nothing was done\n");
    const dry = try cli_testing.run(app, &.{ "wipe", "--dry-run", "--yes" }, .{});
    defer dry.deinit();
    try dry.expect(0, "would wipe anon\n", "");
}

fn toolPrune(ctx: *Context) !void {
    try ctx.confirm("Prune {d} of {s}?", .{ ctx.args.len, "them" });
    try ctx.out.writeAll("pruned\n");
}

const prune_root = spec.command(.{
    .name = "tool",
    .subcommands = &.{spec.command(.{
        .name = "prune",
        .confirm = true,
        .args = .{ .max = null },
        .run = toolPrune,
    })},
});

test "ctx.confirm: a question made at run time, under the rules of .confirm" {
    const app: App = .{ .root = &prune_root };
    const refused = try cli_testing.run(app, &.{ "prune", "a" }, .{});
    defer refused.deinit();
    try refused.expect(1, "", "tool: \"tool prune\" asks for confirmation; run it at a " ++
        "terminal or pass --yes\n");
    const yes = try cli_testing.run(app, &.{ "prune", "--yes", "a" }, .{});
    defer yes.deinit();
    try yes.expect(0, "pruned\n", "");
    const answered = try cli_testing.run(app, &.{ "prune", "a", "b" }, .{ .stdin = "y\n" });
    defer answered.deinit();
    try answered.expect(0, "pruned\n", "Prune 2 of them? [y/N] ");
    const declined = try cli_testing.run(app, &.{ "prune", "a" }, .{ .stdin = "no\n" });
    defer declined.deinit();
    try declined.expect(1, "", "Prune 1 of them? [y/N] tool: not confirmed; nothing was done\n");
}

test "output: a table for people, JSON and YAML for programs" {
    const app: App = .{ .root = &tool_root };
    const table = try cli_testing.run(app, &.{"list"}, .{});
    defer table.deinit();
    try table.expect(0, "NAME  SIZE\na     1\nbb    22\n", "");
    const json = try cli_testing.run(app, &.{ "list", "-o", "json" }, .{});
    defer json.deinit();
    try testing.expect(std.mem.startsWith(u8, json.out, "[\n  {\n    \"name\": \"a\""));
    const yaml = try cli_testing.run(app, &.{ "list", "-o", "yaml" }, .{});
    defer yaml.deinit();
    try yaml.expect(0, "- name: a\n  size: 1\n- name: bb\n  size: 22\n", "");
    const bad = try cli_testing.run(app, &.{ "list", "-o", "xml" }, .{});
    defer bad.deinit();
    try testing.expectEqual(exit_usage, bad.status);
}

test "lengths and requires" {
    const app: App = .{ .root = &tool_root };
    const short = try cli_testing.run(app, &.{ "wipe", "-y", "--name", "a" }, .{});
    defer short.deinit();
    try testing.expect(std.mem.startsWith(u8, short.err, "tool: invalid value \"a\" for flag " ++
        "--name: must be at least 2 characters"));
    const long = try cli_testing.run(app, &.{ "wipe", "-y", "--name", "ééééé" }, .{});
    defer long.deinit();
    try testing.expectEqual(0, long.status);
    const lonely = try cli_testing.run(app, &.{ "wipe", "-y", "--key", "k" }, .{});
    defer lonely.deinit();
    try testing.expect(std.mem.startsWith(u8, lonely.err, "tool: flag --key requires --cert\n"));
    const paired = try cli_testing.run(app, &.{ "wipe", "-y", "--key", "k", "--cert", "c" }, .{});
    defer paired.deinit();
    try testing.expectEqual(0, paired.status);
}

test "features: off, a command and a flag do not exist; on, they do" {
    const app: App = .{ .root = &tool_root };
    const off = try cli_testing.run(app, &.{"secret"}, .{});
    defer off.deinit();
    try testing.expectEqual(exit_usage, off.status);
    const help_off = try cli_testing.run(app, &.{"--help"}, .{});
    defer help_off.deinit();
    try testing.expect(std.mem.indexOf(u8, help_off.out, "secret") == null);
    const on = try cli_testing.run(app, &.{"secret"}, .{ .env = &.{.{ "APP_SECRET", "1" }} });
    defer on.deinit();
    try on.expect(0, "secret\n", "");
    const flag_off = try cli_testing.run(app, &.{ "wipe", "-y", "--beta" }, .{});
    defer flag_off.deinit();
    try testing.expectEqual(exit_usage, flag_off.status);
    const flag_on = try cli_testing.run(app, &.{ "wipe", "-y", "--beta" }, .{
        .env = &.{.{ "APP_BETA", "yes" }},
    });
    defer flag_on.deinit();
    try testing.expectEqual(0, flag_on.status);
}

test "user aliases expand, and a command of the same name wins" {
    const app: App = .{ .root = &tool_root, .aliases = &.{
        .{ "w", "wipe --yes --name 'ab'" },
        .{ "list", "wipe" },
        .{ "bad", "wipe 'open" },
    } };
    const w = try cli_testing.run(app, &.{ "w", "--dry-run" }, .{});
    defer w.deinit();
    try w.expect(0, "would wipe ab\n", "");
    const list = try cli_testing.run(app, &.{"list"}, .{});
    defer list.deinit();
    try testing.expect(std.mem.startsWith(u8, list.out, "NAME"));
    const bad = try cli_testing.run(app, &.{"bad"}, .{});
    defer bad.deinit();
    try testing.expectEqual(exit_usage, bad.status);
}

fn fileDefaults(_: ?*anyopaque, path: []const *const Command, flag: *const Flag) ?[]const u8 {
    if (!std.mem.eql(u8, path[path.len - 1].name, "wipe")) return null;
    if (std.mem.eql(u8, flag.name, "name")) return "cfgd";
    if (std.mem.eql(u8, flag.name, "yes")) return "true";
    return null;
}

test "defaults come after the command line and the environment" {
    const app: App = .{
        .root = &tool_root,
        .defaults = .{ .lookup = fileDefaults, .name = "tool.toml" },
    };
    const from_file = try cli_testing.run(app, &.{"wipe"}, .{});
    defer from_file.deinit();
    try from_file.expect(0, "wiped cfgd\n", "");
    const given = try cli_testing.run(app, &.{ "wipe", "--name", "argv" }, .{});
    defer given.deinit();
    try given.expect(0, "wiped argv\n", "");
    const bad: App = .{
        .root = &tool_root,
        .defaults = .{ .lookup = struct {
            fn lookup(_: ?*anyopaque, _: []const *const Command, flag: *const Flag) ?[]const u8 {
                return if (std.mem.eql(u8, flag.name, "name")) "x" else null;
            }
        }.lookup, .name = "tool.toml" },
    };
    const short = try cli_testing.run(bad, &.{ "wipe", "-y" }, .{});
    defer short.deinit();
    try testing.expect(std.mem.startsWith(u8, short.err, "tool: invalid value \"x\" for flag " ++
        "--name (from tool.toml): must be at least 2 characters"));
}

/// A configuration as `parse.Defaults.from` sees one: anything with `flagText`.
const FakeConfig = struct {
    pairs: []const [2][]const u8,

    pub fn flagText(fake: *const FakeConfig, key: []const u8) ?[]const u8 {
        for (fake.pairs) |pair| if (std.mem.eql(u8, pair[0], key)) return pair[1];
        return null;
    }
};

const FailingConfig = struct {
    pub fn flagText(_: *FailingConfig, _: []const u8) error{Broken}!?[]const u8 {
        return error.Broken;
    }
};

const ServeFlags = struct {
    port: u16 = 80,
    host: []const u8 = "localhost",
    tag: []const []const u8 = &.{},
};
const serve_flags = sets.flags(ServeFlags, field_.none, .{ .fields = .{
    .port = .{ .env = "PORT" },
    .tag = .{ .split = ',' },
} });

const VerboseFlags = struct { verbose: bool = false };

fn serveConfigured(ctx: *Context, flags: ServeFlags) !void {
    const verbose = (try ctx.flags(VerboseFlags)).verbose;
    try ctx.out.print("{s}:{d} verbose={} tags={d}\n", .{
        flags.host, flags.port, verbose, flags.tag.len,
    });
}

const configured_root = spec.command(.{
    .name = "tool",
    .persistent_flags = VerboseFlags,
    .subcommands = .{
        spec.command(.{ .name = "serve", .flags = serve_flags, .run = serveConfigured }),
    },
});

test "parse.Defaults.from reads <prefix>.<command path>.<flag>, below argv and env" {
    const config: FakeConfig = .{ .pairs = &.{
        .{ "tool.serve.port", "9000" },
        .{ "tool.verbose", "yes" },
        .{ "tool.serve.host", "example.org" },
        .{ "tool.serve.tag", "a,b,c" },
        .{ "serve.port", "1" },
    } };
    const app: App = .{
        .root = &configured_root,
        .defaults = .from(&config, .{ .prefix = "tool", .name = "tool.toml" }),
    };
    try expectRun(app, &.{"serve"}, 0, "example.org:9000 verbose=true tags=3\n", "");
    const env = try cli_testing.run(app, &.{"serve"}, .{ .env = &.{.{ "PORT", "7" }} });
    defer env.deinit();
    try env.expect(0, "example.org:7 verbose=true tags=3\n", "");
    const given = [_][]const u8{ "serve", "--port", "8", "--host", "h" };
    try expectRun(app, &given, 0, "h:8 verbose=true tags=3\n", "");

    const unprefixed: App = .{ .root = &configured_root, .defaults = .from(&config, .{}) };
    try expectRun(unprefixed, &.{"serve"}, 0, "localhost:1 verbose=false tags=0\n", "");

    const bad: FakeConfig = .{ .pairs = &.{.{ "serve.port", "lots" }} };
    const refused: App = .{ .root = &configured_root, .defaults = .from(&bad, .{}) };
    const r = try cli_testing.run(refused, &.{"serve"}, .{});
    defer r.deinit();
    try testing.expect(std.mem.startsWith(u8, r.err, "tool: invalid value \"lots\" for flag " ++
        "--port (from config)"));

    // A source whose lookup fails supplies nothing.
    var unreadable: FailingConfig = .{};
    const broken: App = .{ .root = &configured_root, .defaults = .from(&unreadable, .{}) };
    try expectRun(broken, &.{"serve"}, 0, "localhost:80 verbose=false tags=0\n", "");
}

var middleware_log: [4][]const u8 = undefined;
var middleware_count: usize = 0;

fn outer(ctx: *Context, next: Context.Next) anyerror!void {
    middleware_log[middleware_count] = "outer in";
    middleware_count += 1;
    next.run() catch |err| {
        try ctx.err.print("handled {t}\n", .{err});
        return;
    };
    middleware_log[middleware_count] = "outer out";
    middleware_count += 1;
}

fn inner(_: *Context, next: Context.Next) anyerror!void {
    middleware_log[middleware_count] = "inner";
    middleware_count += 1;
    try next.run();
}

test "middleware wraps the handlers, outermost first, and can handle their errors" {
    middleware_count = 0;
    const app: App = .{ .root = &tool_root, .middleware = &.{ outer, inner } };
    const wrapped = try cli_testing.run(app, &.{"secret"}, .{ .env = &.{.{ "APP_SECRET", "1" }} });
    defer wrapped.deinit();
    try wrapped.expect(0, "secret\n", "");
    try testing.expectEqual(3, middleware_count);
    try testing.expectEqualStrings("outer in", middleware_log[0]);
    try testing.expectEqualStrings("inner", middleware_log[1]);
    try testing.expectEqualStrings("outer out", middleware_log[2]);
    middleware_count = 0;
    var recorder: Recorder = .{};
    defer recorder.events.deinit(testing.allocator);
    const guarded: App = .{ .root = &test_root, .data = &recorder, .middleware = &.{outer} };
    const failed = try cli_testing.run(guarded, &.{"fail"}, .{});
    defer failed.deinit();
    try testing.expectEqual(0, failed.status);
    try testing.expect(std.mem.indexOf(u8, failed.err, "handled ") != null);
}

fn logEveryLevel(ctx: *Context) !void {
    inline for (.{ .trace, .debug, .info, .warn, .@"error" }) |level| {
        ctx.log(level, "at {s}", .{@tagName(level)});
    }
}

const logging_root = spec.command(.{
    .name = "tool",
    .logging = true,
    .subcommands = &.{spec.command(.{ .name = "go", .summary = "Log", .run = logEveryLevel })},
});

test "logging: -v steps down from warn, --log-level sets it, -q leaves errors" {
    const app: App = .{ .root = &logging_root };
    const cases = [_]struct { args: []const []const u8, err: []const u8 }{
        .{ .args = &.{"go"}, .err = "tool: warn: at warn\ntool: error: at error\n" },
        .{ .args = &.{ "go", "-q" }, .err = "tool: error: at error\n" },
        .{ .args = &.{ "-v", "go" }, .err = "tool: info: at info\ntool: warn: at warn\n" ++
            "tool: error: at error\n" },
        .{ .args = &.{ "go", "-vvvv" }, .err = "tool: trace: at trace\ntool: debug: at debug\n" ++
            "tool: info: at info\ntool: warn: at warn\ntool: error: at error\n" },
        .{ .args = &.{ "go", "-vv", "--log-level", "error" }, .err = "tool: error: at error\n" },
    };
    for (cases) |case| {
        const r = try cli_testing.run(app, case.args, .{});
        defer r.deinit();
        try r.expect(0, "", case.err);
    }
    const bad = try cli_testing.run(app, &.{ "go", "--log-level", "loud" }, .{});
    defer bad.deinit();
    try testing.expectEqual(exit_usage, bad.status);
    const help_page = try cli_testing.run(app, &.{ "go", "--help" }, .{});
    defer help_page.deinit();
    try testing.expect(std.mem.indexOf(u8, help_page.out, "-v, --verbose") != null);
    try testing.expect(std.mem.indexOf(u8, help_page.out, "--log-level <level>") != null);
}

const BreakFlags = struct {
    how: enum { fail, usage, err } = .fail,
};

fn breakIt(ctx: *Context, flags: BreakFlags) !void {
    switch (flags.how) {
        .fail => return ctx.fail("could not reach {s}", .{"db"}),
        .usage => return ctx.usageError("bad \"name\"", .{}),
        .err => return error.DiskFull,
    }
}

const break_root = spec.command(.{
    .name = "tool",
    .subcommands = &.{spec.command(.{
        .name = "break",
        .flags = BreakFlags,
        .output = true,
        .run = breakIt,
    })},
});

test "errors under -o json are JSON on standard error" {
    const app: App = .{ .root = &break_root };
    const cases = [_]struct { how: []const u8, status: u8, text: []const u8, json: []const u8 }{
        .{
            .how = "fail",
            .status = 1,
            .text = "tool: could not reach db\n",
            .json = "{\"error\":\"could not reach db\"}\n",
        },
        .{
            .how = "usage",
            .status = 2,
            .text = "tool: bad \"name\"\nRun 'tool break --help' for usage.\n",
            .json = "{\"error\":\"bad \\\"name\\\"\",\"hint\":\"Run 'tool break --help' for " ++
                "usage.\"}\n",
        },
        .{
            .how = "err",
            .status = 1,
            .text = "tool: DiskFull\n",
            .json = "{\"error\":\"DiskFull\"}\n",
        },
    };
    for (cases) |case| {
        const text = try cli_testing.run(app, &.{ "break", "--how", case.how }, .{});
        defer text.deinit();
        try text.expect(case.status, "", case.text);
        const json = try cli_testing.run(app, &.{ "break", "--how", case.how, "-o", "json" }, .{});
        defer json.deinit();
        try json.expect(case.status, "", case.json);
    }
}

test "usage errors the parser finds are JSON when the arguments ask for -o json" {
    const app: App = .{ .root = &break_root };
    // `-o json` comes after the problem, so the parser never reads it.
    const unknown = try cli_testing.run(app, &.{ "break", "--bogus", "-o", "json" }, .{});
    defer unknown.deinit();
    try unknown.expect(2, "", "{\"error\":\"unknown flag: --bogus\"," ++
        "\"hint\":\"Run 'tool break --help' for usage.\"}\n");
    const near = try cli_testing.run(app, &.{ "break", "--hwo", "x", "--output=jsonl" }, .{});
    defer near.deinit();
    try near.expect(2, "", "{\"error\":\"unknown flag: --hwo\"," ++
        "\"hint\":\"Did you mean --how? Run 'tool break --help' for usage.\"}\n");
    // The last -o wins, and nothing after -- is a flag.
    for ([_][]const []const u8{
        &.{ "break", "--bogus", "-ojson", "-o", "text" },
        &.{ "break", "--bogus", "--", "-o", "json" },
    }) |args| {
        const text = try cli_testing.run(app, args, .{});
        defer text.deinit();
        try text.expect(2, "", "tool: unknown flag: --bogus\nRun 'tool break --help' for usage.\n");
    }
}

test "help --search lists the commands that mention the words" {
    const app: App = .{ .root = &tool_root };
    const found = try cli_testing.run(app, &.{ "help", "--search", "WIPE" }, .{});
    defer found.deinit();
    try found.expect(0, "  tool wipe   Wipe it\n", "");
    // Flags count: `--cert` is a flag of wipe.
    const by_flag = try cli_testing.run(app, &.{ "help", "--search", "cert" }, .{});
    defer by_flag.deinit();
    try by_flag.expect(0, "  tool wipe   Wipe it\n", "");
    const none = try cli_testing.run(app, &.{ "help", "--search", "fly", "away" }, .{});
    defer none.deinit();
    try none.expect(1, "", "tool: no command mentions \"fly away\"\n");
    const empty = try cli_testing.run(app, &.{ "help", "--search" }, .{});
    defer empty.deinit();
    try empty.expect(2, "", "tool: flag needs an argument: --search\n");
}

test "standard error from run shows each line as it is written" {
    var shown: [64]u8 = undefined;
    var sink: Io.Writer = .fixed(&shown);
    // The file writer `run` wraps: a buffer of its own, emptied into `sink` when flushed.
    var buffer: [16]u8 = undefined;
    var file: Io.Writer = .{ .vtable = &.{ .drain = Forward.drain }, .buffer = &buffer };
    Forward.to = &sink;
    var err: LineFlushed = .{ .inner = &file };
    try err.interface.print("{s}: {d}", .{ "half", 1 });
    try std.testing.expectEqualStrings("", sink.buffered());
    try err.interface.writeAll(" line\nnext");
    try std.testing.expectEqualStrings("half: 1 line\nnext", sink.buffered());
    try err.interface.writeAll(" part");
    try err.interface.flush();
    try std.testing.expectEqualStrings("half: 1 line\nnext part", sink.buffered());
}

const Forward = struct {
    var to: *Io.Writer = undefined;

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        try to.writeAll(w.buffered());
        w.end = 0;
        return to.writeSplat(data, splat);
    }
};

const StorageFlags = struct {
    storage: union(enum) {
        disk: struct { path: []const u8 = "/var" },
        s3: struct { bucket: []const u8 },
        memory,
    } = .memory,
};

fn printStorage(ctx: *Context, flags: StorageFlags) !void {
    switch (flags.storage) {
        .disk => |d| try ctx.out.print("disk {s}\n", .{d.path}),
        .s3 => |s| try ctx.out.print("s3 {s}\n", .{s.bucket}),
        .memory => try ctx.out.writeAll("memory\n"),
    }
}

const storage_root = spec.command(.{ .name = "app", .flags = StorageFlags, .run = printStorage });

test "a choice: named, picked by a variant's flag, and refused when they disagree" {
    const app: App = .{ .root = &storage_root };
    try expectRun(app, &.{}, 0, "memory\n", "");
    try expectRun(app, &.{ "--storage", "disk" }, 0, "disk /var\n", "");
    try expectRun(app, &.{"--storage-s3-bucket=b"}, 0, "s3 b\n", "");
    try expectRun(app, &.{ "--storage-s3-bucket", "b", "--storage", "s3" }, 0, "s3 b\n", "");
    try expectRun(app, &.{ "--storage", "disk", "--storage-s3-bucket", "b" }, 2, "", "app: flag --storage-s3-bucket is for --storage s3, but --storage is disk\n" ++
        "Run 'app --help' for usage.\n");
    // A variant's required flag is required once the variant is picked.
    try expectRun(app, &.{ "--storage", "s3" }, 2, "", "app: required flag --storage-s3-bucket is not set\n" ++
        "Run 'app --help' for usage.\n");
}
