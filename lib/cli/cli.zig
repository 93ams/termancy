const std = @import("std");
const zcfg = @import("cfg");
const zutil = @import("util");

// Each sub-folder has its own `root.zig`, and those are imported here so every
// folder's surface is part of the module graph and gets compiled. The individual
// leaf re-exports below are kept under their long-standing flat names
// (`cli.tea`, `cli.style`, ...), because the test suite and `app/cli` use them.
//
// These were lost when this file was reverted. The list is mirrored from
// `app/cli/lib/root.zig`, which is the authoritative surface: it reads
// `framework.<name>` for each of these, so a name missing here breaks the module
// root rather than only the leaf.
pub const render = @import("render/root.zig");
pub const interact = @import("interact/root.zig");
pub const secrets = @import("secrets/root.zig");
pub const platform = @import("platform/root.zig");

pub const tea = render.tea;
pub const style = render.style;
pub const color = render.color;
pub const layout = render.layout;
pub const pager = render.pager;
pub const progress = render.progress;
pub const graphics = render.graphics;
pub const decstbm = render.decstbm;
pub const virtual_terminal = render.virtual_terminal;
pub const spatial_focus = render.spatial_focus;
pub const vte = render.vte;

pub const prompt = interact.prompt;
pub const widgets = interact.widgets;
pub const rope = interact.rope;
pub const supervisor = interact.supervisor;
pub const tty_stream = interact.tty_stream;
pub const raw_terminal = interact.raw_terminal;

pub const daemon = platform.daemon;
pub const sys = platform.sys;
pub const oauth = platform.oauth;
pub const openapi = platform.openapi;
pub const panic = platform.panic;
pub const proctitle = platform.proctitle;
pub const profiler = platform.profiler;
pub const sandbox = platform.sandbox;
pub const telemetry = platform.telemetry;
pub const trace_parent = platform.trace_parent;
pub const updater = platform.updater;
pub const wasm_bridge = platform.wasm_bridge;
pub const headless = platform.headless;
pub const dist_specs = platform.dist_specs;
pub const fido2 = platform.fido2;
pub const dynlib_reloader = platform.dynlib_reloader;

pub const security = secrets.security;
pub const secret_val = secrets.secret_val;
pub const secure_heap = secrets.secure_heap;
pub const encrypted_config = secrets.encrypted_config;

// Configuration, and the remaining single-file modules.
pub const zconfig = zcfg;
/// JSON object merge. Reached through the configuration module, which owns it.
pub const mergeJson = zcfg.mergeJson;
// `version.zig` used to live here: a background thread that fetched a version string and
// cached it in `/tmp/<app>_version_cache.txt`, printing an ANSI notice on exit. Every line
// of it used an API Zig 0.16 removed, nothing called it, and `App.updateCommand` replaced
// its purpose with a real release registry, checksum and signature verification, and an
// atomic replacement - while `platform/state.zig` replaced its cache. It is deleted rather
// than ported: a non-compiling module whose documented home is `/tmp` is a trap, not a
// feature waiting to be finished.
pub const alias = @import("alias.zig");
pub const i18n = @import("i18n.zig");
pub const policy = @import("policy.zig");
pub const repl = @import("repl.zig");

pub const comptime_config = zcfg.comptime_config;
pub const config_lineage = zcfg.config_lineage;
pub const config_diff = zcfg.config_diff;
pub const config_dryrun = zcfg.config_dryrun;
pub const schema_migration = zcfg.schema_migration;
pub const profiles = zcfg.profiles;
pub const toml_mutator = zcfg.toml_mutator;
pub const remote_config = zcfg.remote_config;
pub const ota_flags = zcfg.ota_flags;
pub const systemd_exporter = platform.systemd_exporter;
/// The single process-wide decision about whether escapes may be emitted.
pub const capability = render.capability;
/// Standard application directories, resolved per platform and per XDG variable.
pub const xdg = platform.xdg;
/// Reading and writing state, caches and tokens in the standard directories.
pub const state = platform.state;
/// The path of the running executable, which std.process.Init no longer carries.
pub const self_exe = platform.self_exe;
/// The crash reporter: a panic banner, a stack trace and a JSON report.
pub const crash = platform.crash;
/// Running a child process, captured or streamed.
pub const process = platform.process;
/// Graceful shutdown: conventional signals, as a poll-able flag.
pub const signal = platform.signal;
/// Leveled logging, as readable text or machine-readable JSON.
pub const log = platform.log;
/// A line editor with echo suppression, for text and password entry.
pub const text_input = interact.text_input;
/// Check, verify and replace the running executable. The transport is the caller's.
pub const update = platform.update;
/// Detaching the process so it outlives the terminal that started it.
pub const detach = platform.detach;
/// A single-line spinner for a step whose total is unknown.
pub const spinner = render.spinner;

// Utilities. These live in `lib/util` and are re-exported under their flat names
// because the framework's own module root lists them as `cli.<name>`.
pub const vfs = zutil.vfs;
pub const tasks = zutil.tasks;
pub const cancellation = zutil.cancellation;
pub const mmap = zutil.mmap;
pub const linter = zutil.linter;
pub const dag = zutil.dag;
pub const cas = zutil.cas;
pub const btree_store = zutil.btree_store;
pub const object_pipe = zutil.object_pipe;
pub const footprint = zutil.footprint;
pub const dry_run = zutil.dry_run;

/// Structured output formats understood by `App.execute`'s result renderer.
///
/// `text` is the human-readable table; `json` and `yaml` are the machine-readable
/// spellings of the same value, chosen by the global `--output` flag.
pub const OutputFormat = enum { text, json, yaml };

/// The framework's declared failure modes.
///
/// A named set rather than `anyerror`, so a command author can see what the
/// framework itself raises, and so the exit-code mapping in `App.getExitCode` can be
/// exhaustive instead of guessing at an arbitrary error's meaning.
///
/// **File scope, not a member of the `App` closure.** It was declared inside `App`,
/// which made it unreachable as `cli.AppError` - and `lib/cli/root.zig` re-exported
/// exactly that name, so the library's declared surface did not compile. The set does
/// not depend on `StateT` or on `config`, so it never had a reason to be per-`App`;
/// `App.Error` remains as an alias, which is what the existing command signatures and
/// the suite already write.
///
/// `Count` is the number of codes such a set can carry, and it must be present for
/// a set used in this position.
pub const AppError = error{
    UnknownCommand,
    CommandNotExecutable,
    MissingRequiredFlag,
    MissingRequiredPositionalArgument,
    MissingFlagValue,
    UnknownFlag,
    ConflictingFlags,
    DependentFlagMissing,
    InvalidFlagValue,
    ValidationFailed,
    TooManyPositionalArguments,
    UnknownField,
    ConfirmationRequired,
    InvalidFormat,
    PromptCancelled,
    UserCancelled,
    HandledError,
    WindowsConsoleError,
    /// The command tree consumed more names than the chain can record.
    ///
    /// A bound rather than an overflow: the recorder used to index a fixed array
    /// unchecked, so a deep enough tree wrote past its end.
    CommandNestingTooDeep,
    Count,
};

/// Parses a log-level name.
///
/// Case-insensitive, and accepts the abbreviations people actually type (`warn`, `err`).
/// Returns null for anything unrecognised rather than substituting a default: a caller
/// that asked for `--log-level verbose` should be told its request was not understood,
/// not silently given `info`.
pub fn parseLogLevel(name: []const u8) ?std.log.Level {
    const Level = std.log.Level;
    if (std.ascii.eqlIgnoreCase(name, "err") or std.ascii.eqlIgnoreCase(name, "error")) return Level.err;
    if (std.ascii.eqlIgnoreCase(name, "warn") or std.ascii.eqlIgnoreCase(name, "warning")) return Level.warn;
    if (std.ascii.eqlIgnoreCase(name, "info")) return Level.info;
    if (std.ascii.eqlIgnoreCase(name, "debug")) return Level.debug;
    return null;
}

/// The `--log-level` a command line asked for, if any.
///
/// Read from the raw args rather than from parsed flags, because the log level has to be
/// known *before* dispatch: a command that fails to parse still wants its failure logged
/// at the level the user asked for. Accepts both `--log-level debug` and
/// `--log-level=debug`, since both spellings are in use in the wild and the second is what
/// a shell completion usually produces.
pub fn extractLogLevel(args: []const []const u8) ?std.log.Level {
    for (args, 0..) |arg, i| {
        if (std.mem.startsWith(u8, arg, "--log-level=")) {
            return parseLogLevel(arg["--log-level=".len..]);
        } else if (std.mem.eql(u8, arg, "--log-level") and i + 1 < args.len) {
            return parseLogLevel(args[i + 1]);
        }
    }
    return null;
}

/// Renders a parsed flag struct for debugging.
///
/// Secret-valued fields are redacted: this output goes to logs and terminals, which is the
/// one place a token must not land. The redaction is driven by the field's metadata rather
/// than by a name heuristic, so it cannot drift from what the flags actually declare - and
/// absent metadata means "not secret", which is the safe default because it fails closed
/// only for fields that *claimed* to be secret.
pub fn formatFlags(writer: anytype, flags: anytype) !void {
    const T = @TypeOf(flags);
    try writer.writeAll("{\n");
    inline for (std.meta.fields(T)) |field| {
        if (comptime (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) continue;
        const val = @field(flags, field.name);

        var is_secret = false;
        if (comptime @hasDecl(T, "meta")) {
            if (comptime @hasField(@TypeOf(T.meta), field.name)) {
                const fmeta = @field(T.meta, field.name);
                if (comptime @hasField(@TypeOf(fmeta), "secret")) is_secret = fmeta.secret;
            }
        }

        try writer.print("  {s}: ", .{field.name});
        if (is_secret) {
            if (field.type == []const u8) {
                try security.redact(writer, val);
            } else {
                try writer.writeAll("********");
            }
        } else if (field.type == []const u8) {
            try writer.print("{s}", .{val});
        } else {
            try writer.print("{any}", .{val});
        }
        try writer.writeAll(",\n");
    }
    try writer.writeAll("}\n");
}

/// External subcommands, discovered on `PATH`.
///
/// A command that is not registered natively is looked for as `<prefix>-<name>` and, if
/// found, executed with the remaining arguments. This is how `git lfs` reaches a binary
/// the `git` authors never shipped, and it is off by default: it means any executable on
/// the path can extend the command line, which is a decision an app makes deliberately
/// rather than inherits.
pub const Plugins = struct {
    enabled: bool = false,
    /// The name prefix. Empty means the token itself is the program: `app foo` runs
    /// `foo`, which is convenient and the reason it is not the default.
    prefix: []const u8 = "",
};

/// Configuration for the CLI framework itself (buffer sizes, etc).
pub const ExitMap = struct {
    name: []const u8,
    code: u8,
};

/// Defaults read from a file, and how to read them.
///
/// ## Where this sits in the resolution order
///
/// A field is resolved as CLI flag > environment > **file** > the struct's own
/// default. The file is therefore consulted only for a field the command line did
/// not mention and the environment did not supply, which is the only order in which
/// "the file supplies defaults" means anything.
///
/// ## Keys
///
/// A field's key is its own name, or `meta.<field>.config` when the file uses a
/// different spelling. `prefix` is prepended, so `ConfigFile{ .path = "cli.toml",
/// .prefix = "cli" }` reads `cli.port` for a field named `port` - which lets one
/// file serve several binaries.
pub const ConfigFile = struct {
    /// The file to read. Empty means there is no file layer at all, so an app that
    /// wants none pays nothing.
    path: []const u8 = "",
    /// Dotted prefix for every key, without the trailing dot.
    prefix: []const u8 = "",
    /// How the text becomes key -> scalar text.
    ///
    /// `null` selects the built-in dispatcher: `.json`, `.yaml`/`.yml` and `.toml`
    /// go through `cfg.format`, and anything else (a `.env`, an extension-less
    /// file) is read as `KEY = value` through `cfg.dotenv`.
    loader: ?Loader = null,

    /// A parser, not a file reader.
    ///
    /// The framework reads the bytes - so the caller never has to open anything or
    /// worry about a missing file - and hands them here. Every allocation the loader
    /// makes should come from `arena`; the framework destroys the arena once the
    /// command has run, so a loader that allocates from it needs no cleanup path of
    /// its own.
    pub const Loader = *const fn (
        arena: std.mem.Allocator,
        path: []const u8,
        text: []const u8,
    ) anyerror!std.StringHashMapUnmanaged([]const u8);
};

/// The built-in file reader: dispatch on the extension, else `KEY = value`.
///
/// The returned map borrows memory from a child arena of `arena`, so it stays valid
/// for exactly as long as `arena` does and needs no `deinit` of its own. That is
/// why `cfg.format.Flat` and `cfg.dotenv.Document` are deliberately not deinited
/// here: their arenas are children of this one, and freeing a child arena whose
/// parent is about to be destroyed would only be a no-op.
fn defaultConfigFileLoader(
    arena: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
) anyerror!std.StringHashMapUnmanaged([]const u8) {
    if (zcfg.format.detect(path)) |format| {
        const flat = try zcfg.format.load(arena, text, format);
        return flat.values;
    }

    const document = try zcfg.dotenv.parse(arena, text, .{});
    var values: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (document.entries()) |entry| {
        try values.put(arena, entry.key, entry.value);
        // A dotenv file is conventionally `UPPER_CASE`, and a flag is spelled
        // `lower_case`, so the lowercase spelling is recorded too. Both resolve, and a
        // file that already uses the flag's own spelling is unaffected.
        var has_upper = false;
        for (entry.key) |ch| {
            if (std.ascii.isUpper(ch)) has_upper = true;
        }
        if (has_upper) {
            const lowered = try arena.alloc(u8, entry.key.len);
            for (entry.key, 0..) |ch, i| lowered[i] = std.ascii.toLower(ch);
            try values.put(arena, lowered, entry.value);
        }
    }
    return values;
}

/// Global flags merged into every command's flag struct by `App.Flags`.
///
/// File scope, not a member of the `App` closure: nothing here depends on `StateT`
/// or on the framework configuration, and `lib/cli/root.zig` re-exports this name -
/// which it could not do while the declaration lived inside `App` (the re-export was
/// one of nine that named something that did not exist).
pub const GlobalFlags = struct {
    output: OutputFormat = .text,
    interactive: bool = false,
    /// Explicit consent for a `requires_confirmation` command.
    ///
    /// Global rather than per-command because the safeguard must accept it on *any*
    /// command that declares `requires_confirmation`, and that struct is written by
    /// whoever writes the command - so requiring them to also remember a `yes: bool`
    /// field is exactly the kind of thing that gets forgotten, and the failure lands
    /// on a user who cannot proceed. Measured: without this, `--yes` was
    /// `UnknownFlag` and the safeguard could never be satisfied.
    yes: bool = false,
};

/// The framework configuration, passed as `App(StateT, config)`.
///
/// Every field here has a default, so `App(State, .{})` and `App(State, Config{})` are
/// both valid. A config literal is `anytype`, so it may also carry the framework's
/// *optional* hooks - each is probed with `@hasField` and simply absent otherwise:
///
/// * `type_parsers = .{ parseFoo }` - global parsers, matched by return type.
/// * `middlewares = .{ mw1, mw2 }` - an onion around every command body.
/// * `help_renderer = MyHelp` - a namespace with `pub fn render(ctx, cmd)`, replacing
///   the built-in help for commands that do not declare their own.
pub const Config = struct {
    in_buffer_size: usize = 4096,
    out_buffer_size: usize = 8192,
    err_buffer_size: usize = 4096,
    exit_map: []const ExitMap = &.{},

    /// What the built-in `--version` / `-V` prints, after the command's own name.
    ///
    /// Empty - the default - disables the built-in entirely, so an application that
    /// already declares its own `version` flag keeps that flag's meaning rather
    /// than having it shadowed by the framework.
    version: []const u8 = "",

    /// Defaults read from a file. See `ConfigFile`; disabled unless a path is set.
    config_file: ConfigFile = .{},

    /// Install SIGINT/SIGTERM handlers before dispatching.
    ///
    /// Off by default, and deliberately: an installed handler *claims* the signal
    /// (see `platform/signal.zig`), so a command that never polls for it would stop
    /// responding to Ctrl+C. An app opts in when its commands poll `ctx.shutdown()`.
    install_signal_handlers: bool = false,

    /// External subcommands discovered on `PATH`. Off by default; see `Plugins`.
    plugins: Plugins = .{},
};

pub fn App(comptime StateT: type, comptime config: anytype) type {
    return struct {
        const Self = @This();

        fn OnionBuilder(comptime mws: anytype, comptime index: usize, comptime CmdT: type, comptime FlagsT: type) type {
            return struct {
                pub fn exec(c: Ctx, command_value: CmdT, f: FlagsT) !void {
                    if (comptime index >= mws.len) {
                        if (@typeInfo(@TypeOf(command_value.run)) == .optional) {
                            if (command_value.run) |run_fn| {
                                const result = try run_fn(c, f);
                                if (@TypeOf(result) != void) try formatOutput(c, result);
                            }
                        } else {
                            const result = try command_value.run(c, f);
                            if (@TypeOf(result) != void) try formatOutput(c, result);
                        }
                    } else {
                        const NextPayload = struct {
                            cx: Ctx,
                            cmd: CmdT,
                            fl: FlagsT,
                            pub fn call(self: @This()) !void {
                                try OnionBuilder(mws, index + 1, CmdT, FlagsT).exec(self.cx, self.cmd, self.fl);
                            }
                        };
                        try mws[index](c, NextPayload{ .cx = c, .cmd = command_value, .fl = f });
                    }
                }
            };
        }

        pub const Ctx = struct {
            allocator: std.mem.Allocator,
            in: *std.Io.Reader,
            out: *std.Io.Writer,
            err: *std.Io.Writer,
            state: *StateT,
            env_map: *std.process.Environ.Map,
            /// The platform I/O handle.
            ///
            /// Added so a command can do file and randomness work (`Dir.createFile`,
            /// `Io.random`) without reaching for a global. Carried on the context because
            /// that is the one value every command already receives.
            io: std.Io,
            is_tty: bool = false,
            color_enabled: bool = false,
            output_format: OutputFormat = .text,

            /// Whether this invocation is a dry run: report what would happen, change
            /// nothing.
            ///
            /// Set from a `dry_run` field on the command's flags, or by declaring
            /// `meta.dry_run = true` (which adds `--dry-run` for a command that does not
            /// have one). It lives on the context so that business logic several layers
            /// below the command - a function that only receives `Ctx` - can honour it
            /// without every intermediate layer forwarding a boolean by hand.
            dry_run: bool = false,

            // No methods here, deliberately. A declaration inside `Ctx` that names
            // `Ctx` (which a `self: Ctx` method does) stops Zig from treating the
            // `Ctx` of two `App` instantiations as the same structurally-equal type -
            // and existing commands and tests do mix instantiations, because at HEAD
            // the types were interchangeable. The shutdown helpers are therefore on
            // `App`: `App.shutdownSignal()`.
        };

        /// The shutdown signal the process has received, if any.
        ///
        /// This is the framework's end of `platform/signal.zig`, and it is the reason a
        /// command can clean up after Ctrl+C at all: the handler installed by
        /// `Config.install_signal_handlers` records a signal and claims it, and a
        /// long-running command polls here and returns when it is set. Cleanup then
        /// happens on the normal path - an ordinary `defer` - rather than inside a
        /// signal handler, which cannot safely call anything a cleanup wants to.
        ///
        /// A pure read: `received()` does not clear, so polling twice is safe and the
        /// value does not vanish under a second caller.
        pub fn shutdownSignal() ?platform.signal.Signal {
            return platform.signal.received();
        }

        /// Whether a shutdown has been requested. Shorthand for the call site whose only
        /// question is "should I stop".
        pub fn isShuttingDown() bool {
            return shutdownSignal() != null;
        }

        /// Installs the shutdown-signal handlers, clearing any previously recorded signal.
        ///
        /// `Config.install_signal_handlers` makes `App.run` call this before dispatching.
        /// It is public for two reasons: a caller that owns its own bootstrap can install
        /// the same handlers, and - more importantly - the call is then compiled and
        /// testable, rather than living only inside the one branch the shipped
        /// configuration never takes.
        pub fn installSignalHandlers() usize {
            platform.signal.reset();
            return platform.signal.install();
        }

        /// Whether a field carries a `.deprecated` note.
        ///
        /// Absent metadata means "not deprecated", so an undeclared flag never warns.
        fn isDeprecatedFlag(comptime OrigFlagsT: type, comptime name: []const u8) bool {
            if (!@hasDecl(OrigFlagsT, "meta")) return false;
            const mb = OrigFlagsT.meta;
            if (!@hasField(@TypeOf(mb), name)) return false;
            const fm = @field(mb, name);
            return @hasField(@TypeOf(fm), "deprecated");
        }

        /// Whether a field is declared `.count = true` in its metadata.
        ///
        /// Absent metadata means "not a count flag", which is the safe default: a field
        /// without metadata keeps setting its value rather than silently accumulating.
        fn isCountFlag(comptime OrigFlagsT: type, comptime name: []const u8) bool {
            if (!@hasDecl(OrigFlagsT, "meta")) return false;
            const mb = OrigFlagsT.meta;
            if (!@hasField(@TypeOf(mb), name)) return false;
            const fm = @field(mb, name);
            if (!@hasField(@TypeOf(fm), "count")) return false;
            return fm.count;
        }

        fn isPositionalField(comptime name: []const u8) bool {
            return std.mem.eql(u8, name, "positionals") or std.mem.eql(u8, name, "Positional");
        }

        /// A lifecycle hook: `pre_run`, `post_run`, or the interactive shell.
        ///
        /// `anyerror` rather than `Error`, because these are supplied by *user*
        /// middleware whose error set the framework cannot know. The declared `Error` set
        /// is what the framework itself raises; a hook is a boundary, and narrowing it
        /// here would force every caller to coerce into a set that has nothing to do with
        /// their failures.
        pub const HookFn = *const fn (ctx: Ctx) Error!void;

        pub const ExecutionChain = struct {
            pre_runs: []?HookFn,
            post_runs: []?HookFn,
            interactive_shell: ?*const fn (ctx: Ctx) anyerror!void = null,
            count: usize = 0,
            subcmd_indices: [32]usize = [_]usize{0} ** 32,
            subcmd_count: usize = 0,

            /// The exit status of an external subcommand that ran in place of this one,
            /// or null when dispatch stayed inside the framework.
            ///
            /// Carried on the chain because the alternative is `std.process.exit` from
            /// inside the dispatcher, which would make the library own a decision only the
            /// entry point can make. `App.run` reads it and exits with it, so a wrapper
            /// script sees the plugin's status rather than the framework's.
            external_status: ?u8 = null,

            pub fn init(allocator: std.mem.Allocator, max_depth: usize) !@This() {
                const pre = try allocator.alloc(?HookFn, max_depth + 1);
                @memset(pre, null);
                const post = try allocator.alloc(?HookFn, max_depth + 1);
                @memset(post, null);
                return .{ .pre_runs = pre, .post_runs = post };
            }

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.pre_runs);
                allocator.free(self.post_runs);
            }

            /// Records a structural index consumed while routing.
            ///
            /// Checked, not assumed: the array is fixed at `subcmd_indices.len`, and
            /// the caller used to write `subcmd_indices[subcmd_count]` directly, so a
            /// command tree or an argv that consumed more names than that wrote past
            /// the end of the chain instead of reporting anything. `error.CommandNestingTooDeep`
            /// is the honest answer, and it is a real error rather than a panic because
            /// the input that produces it is a user's command line.
            pub fn recordSubcmdIndex(self: *@This(), index: usize) Error!void {
                if (self.subcmd_count >= self.subcmd_indices.len) return error.CommandNestingTooDeep;
                self.subcmd_indices[self.subcmd_count] = index;
                self.subcmd_count += 1;
            }
        };

        /// The framework's declared failure modes.
        ///
        /// An alias of the file-scope `AppError`, which is the same set and the one
        /// `cli.AppError` resolves to. Kept because every command signature in this
        /// tree and the whole suite spell it `App.Error`.
        pub const Error = AppError;

        /// Maps a failure to a process exit status.
        ///
        /// `config.exit_map` wins, so a caller can give a domain error a meaningful status
        /// without the framework knowing what it means. Everything else falls to a POSIX
        /// default chosen to match what a shell script would test for:
        ///
        /// | code | meaning |
        /// |---|---|
        /// | 0 | success (never returned here, but the baseline) |
        /// | 1 | an ordinary failure |
        /// | 2 | the command line itself was wrong |
        /// | 126 | found but not executable |
        /// | 127 | command not found |
        /// | 130 | interrupted (128 + SIGINT) |
        ///
        /// **This is the only mapping.** `failWith` used to consult `exit_map` and then
        /// hardcode `1`, so the table above was documented and tested while the shipped
        /// binaries returned `1` for every failure - measured: `snek nope` exited
        /// `1`, not `127`. Every exit in the framework now goes through here.
        pub fn getExitCode(err: anyerror) u8 {
            // A caller-supplied mapping first: it is the only way to give a domain error a
            // specific status, and it is deliberate rather than a fallback. Compared by
            // name, because `config` is comptime data and a name is what can live in it.
            //
            // Guarded, because a config literal that declares no `exit_map` is legal -
            // `App(State, .{})` is what most tests use, and reading the field there is a
            // compile error rather than an empty list.
            if (comptime @hasField(@TypeOf(config), "exit_map")) {
                inline for (config.exit_map) |entry| {
                    if (comptime entry.name.len > 0) {
                        if (std.mem.eql(u8, @errorName(err), entry.name)) return entry.code;
                    }
                }
            }

            return switch (err) {
                error.UnknownCommand => 127,
                error.CommandNotExecutable => 126,
                error.UserCancelled, error.PromptCancelled => 130,
                // `HandledError` is raised after the command printed its own diagnostic,
                // and in practice it is always a bad value on the command line - so it is
                // a usage failure. It used to fall to `else => 1` *and* be treated as a
                // success by the entry point, which meant `--output bogus` printed an
                // error and exited 0.
                error.HandledError,
                error.MissingRequiredFlag,
                error.MissingRequiredPositionalArgument,
                error.MissingFlagValue,
                error.UnknownFlag,
                error.ConflictingFlags,
                error.DependentFlagMissing,
                error.InvalidFlagValue,
                error.ValidationFailed,
                error.CommandNestingTooDeep,
                error.TooManyPositionalArguments,
                error.UnknownField,
                error.InvalidFormat,
                => 2,
                else => 1,
            };
        }

        /// What the entry point should do about a failed command.
        ///
        /// `code` is the process status and `report` says whether the framework still
        /// owes the user a message. Three failures are already reported by the time they
        /// reach the entry point - a command that returned `HandledError` printed its own
        /// diagnostic, and a cancelled prompt is a deliberate "no" rather than a fault -
        /// so those exit with their status and print nothing more.
        ///
        /// Extracted from `App.run` because that function *terminates the process* and so
        /// cannot be tested: the decision is a pure function over an error, and this is
        /// the only part of the exit path a unit test can reach. Measured while writing
        /// it: the shipped binary returned `1` for an unknown command (127), `2` was
        /// never produced, and `--output bogus` exited `0` while printing an error.
        pub const FailureDisposition = struct { code: u8, report: bool };

        pub fn failureDisposition(err: anyerror) FailureDisposition {
            return switch (err) {
                error.HandledError,
                error.UserCancelled,
                error.PromptCancelled,
                => .{ .code = getExitCode(err), .report = false },
                else => .{ .code = getExitCode(err), .report = true },
            };
        }

        /// Defines a CLI command structure for simple commands without subcommands.
        pub fn Flags(comptime FlagsT: type) type {
            return MergeFlags(FlagsT, GlobalFlags);
        }

        pub fn Command(comptime FlagsT: type, comptime subcmds: anytype) type {
            return CommandWithReturn(FlagsT, void, subcmds);
        }

        /// A command with no subcommands.
        ///
        /// Distinct from `Command(FlagsT, .{})` only in intent, which is worth the four
        /// characters: a leaf is the common case and `.{},` at every call site reads as
        /// noise. Kept as its own name because the test suite and several commands use it.
        pub fn LeafCommand(comptime FlagsT: type) type {
            return CommandWithReturn(FlagsT, void, .{});
        }

        pub fn CommandWithReturn(comptime FlagsT: type, comptime ReturnT: type, comptime subcmds: anytype) type {
            const FlagsType = MergeFlags(FlagsT, GlobalFlags);
            return struct {
                // Fails the build on a declaration that would silently do nothing:
                // a duplicated short flag, a name the framework already owns, or a
                // `.count = true` on a field that cannot accumulate. Checked when the
                // command *type* is built, so it fires whether or not anything runs it.
                comptime {
                    zutil.linter.ComptimeLinter.lintFlags(FlagsT);
                }

                pub const OrigFlagsT = FlagsT;
                pub const subcommands = subcmds;
                name: []const u8,
                description: []const u8 = "",
                aliases: []const []const u8 = &[_][]const u8{},

                run: ?*const fn (ctx: Ctx, flags: FlagsType) anyerror!ReturnT = null,
                is_repl: bool = false,
                pre_run: ?HookFn = null,
                post_run: ?HookFn = null,

                /// Routable but not advertised.
                ///
                /// A hidden command still matches during routing; it is left out of
                /// `--help`, the generated documentation, the completion list and the
                /// typo suggestions. That is the whole point: an internal or
                /// not-yet-announced command should be reachable without being
                /// discoverable.
                hidden: bool = false,

                /// A deprecation note. Non-empty means the command still works, warns
                /// when it is used, and is not advertised.
                ///
                /// The same lifecycle a deprecated flag has, one level up: the warning is
                /// the migration path, and refusing the command would break every script
                /// that has not migrated yet - which is the opposite of what a
                /// deprecation is for.
                deprecated: []const u8 = "",

                /// An environment variable that gates this command.
                ///
                /// Non-empty means the command does not exist unless the variable is set
                /// to something other than `""`, `0` or `false`. A gated command is
                /// unroutable, unadvertised and unsuggested when the gate is closed - the
                /// point of an experimental command is that it is invisible until it is
                /// switched on.
                feature: []const u8 = "",

                /// Called when the command body fails, before the error propagates.
                ///
                /// For the cross-cutting reaction a command needs but the framework
                /// cannot guess: a log line, a metric, a partial rollback. It cannot
                /// change the outcome - returning `void` rather than an error keeps
                /// "handle this" and "replace this" distinct, and an app that wants to
                /// swallow or replace errors writes a middleware.
                on_error: ?OnErrorFn = null,

                /// Sets of flag names that may not be given together.
                ///
                /// Declared once for the command rather than twice on the flags, which
                /// is what `meta.<field>.conflicts_with` requires - and which cannot
                /// express "at most one of these three" without being written on every
                /// member. Names are flag names, in either spelling.
                mutually_exclusive: []const []const []const u8 = &.{},
            };
        }

        /// The framework's hook for a failed command. See `on_error`.
        pub const OnErrorFn = *const fn (ctx: Ctx, err: anyerror) void;

        /// The command-line spelling of a field: `dry_run` is typed `--dry-run`.
        ///
        /// GNU convention, and it costs nothing to accept both - the matcher treats `-`
        /// and `_` as the same character, so an existing script written either way keeps
        /// working. Rendering goes through this helper so help, errors, suggestions and
        /// completions cannot disagree about the spelling.
        fn writeFlagSpelling(writer: anytype, name: []const u8) !void {
            for (name) |ch| {
                try writer.writeByte(if (ch == '_') '-' else ch);
            }
        }

        /// Whether `key` names the field `field_name`, in either spelling.
        ///
        /// Length is compared first because that rejects almost everything for one
        /// integer compare, and the dash/underscore equivalence is applied to both
        /// sides so `--dry-run` and `--dry_run` are the same flag while `--dryrun` is
        /// not. Takes runtime arguments because it is used both against a declared
        /// field name (comptime) and against a name read out of a metadata list.
        fn flagNamesEqual(field_name: []const u8, key: []const u8) bool {
            if (std.mem.eql(u8, field_name, key)) return true;
            if (field_name.len != key.len) return false;
            for (field_name, key) |a, b| {
                const normalized_a = if (a == '_') '-' else a;
                const normalized_b = if (b == '_') '-' else b;
                if (normalized_a != normalized_b) return false;
            }
            return true;
        }

        /// Whether a field collects every occurrence of its flag instead of replacing
        /// its value.
        ///
        /// The rule is the element type: a slice of `u8` is a *string* - the historical
        /// and still the common case - and any other slice is a collection. So
        /// `[]const []const u8` is a list of strings (`-H a -H b`) and `[]const u16` is
        /// a list of ports.
        fn isRepeatableField(comptime T: type) bool {
            const info = @typeInfo(T);
            if (info != .pointer) return false;
            if (info.pointer.size != .slice) return false;
            return info.pointer.child != u8;
        }

        /// The element type a repeatable field collects.
        fn repeatableElement(comptime T: type) type {
            return @typeInfo(T).pointer.child;
        }

        /// The positional-argument slot appended to a `command`-registered command's
        /// parsed flags.
        ///
        /// A slot of its own rather than a field on the user's flags: `--force` and
        /// `<component>` are different kinds of input, and keeping them in one struct
        /// is what made `flags.positionals.component` the only way to reach an
        /// argument.
        fn PositionalSlot(comptime ArgsT: type) type {
            return struct { positionals: ArgsT };
        }

        /// The flags type the framework parses for a `command`-registered command.
        fn ParsedFlags(comptime FlagsT: type, comptime ArgsT: type) type {
            return MergeFlags(MergeFlags(FlagsT, GlobalFlags), PositionalSlot(ArgsT));
        }

        /// `ParsedFlags` plus the generated `--dry-run` slot.
        fn MergedWithDryRunAndPositionals(comptime FlagsT: type, comptime ArgsT: type) type {
            const DryRunSlot = struct { dry_run: bool = false };
            return MergeFlags(
                MergeFlags(MergeFlags(FlagsT, GlobalFlags), DryRunSlot),
                PositionalSlot(ArgsT),
            );
        }

        /// Where the flags and positional arguments sit in a run function's parameters.
        const RunShape = enum { ctx_only, ctx_flags, ctx_args, ctx_flags_args, ctx_args_flags };

        /// Builds the adapter that turns a user's run function into the one shape the
        /// dispatcher calls: `fn (Ctx, ParsedFlags) anyerror!Payload`.
        ///
        /// The three jobs are: decide which parameters the function wants, convert the
        /// parsed flags into whatever flags type it declared, and produce the payload
        /// type. All of it is comptime, so the call the framework makes is the call the
        /// author wrote.
        fn RunAdapter(
            comptime run_fn: anytype,
            comptime FlagsT: type,
            comptime ArgsT: type,
            comptime ParsedT: type,
        ) type {
            const fn_info = @typeInfo(@TypeOf(run_fn)).@"fn";
            const params = fn_info.params;
            const RT = fn_info.return_type.?;
            const PayloadT = if (@typeInfo(RT) == .error_union) @typeInfo(RT).error_union.payload else RT;
            const UserFlagsT = MergeFlags(FlagsT, GlobalFlags);

            if (comptime params.len == 0 or params.len > 3) {
                @compileError("a command's run function takes 1 to 3 parameters: (ctx), " ++
                    "(ctx, flags), (ctx, args), (ctx, flags, args) or (ctx, args, flags)");
            }
            inline for (params) |param| {
                if (comptime param.type == null) {
                    @compileError("a command's run function cannot take an `anytype` parameter: " ++
                        "the framework has to know what to pass");
                }
            }

            // The args type only counts as "the args parameter" when it is
            // distinguishable from the flags type. Two empty structs are not, and
            // guessing there would silently swap two parameters that look the same.
            const args_distinguishable = comptime ArgsT != UserFlagsT and ArgsT != FlagsT;

            const shape: RunShape = comptime blk: {
                if (params.len == 1) break :blk .ctx_only;
                if (params.len == 2) {
                    if (args_distinguishable and params[1].type.? == ArgsT) break :blk .ctx_args;
                    break :blk .ctx_flags;
                }
                if (args_distinguishable and params[1].type.? == ArgsT) break :blk .ctx_args_flags;
                break :blk .ctx_flags_args;
            };

            const FlagsParamT = comptime switch (shape) {
                .ctx_only, .ctx_args => struct {},
                .ctx_flags, .ctx_flags_args => params[1].type.?,
                .ctx_args_flags => params[2].type.?,
            };

            if (comptime shape != .ctx_only and shape != .ctx_args) {
                if (comptime FlagsParamT != FlagsT and FlagsParamT != UserFlagsT) {
                    @compileError("a command's flags parameter must be `App.Flags(" ++ @typeName(FlagsT) ++
                        ")` or `" ++ @typeName(FlagsT) ++ "`, found `" ++ @typeName(FlagsParamT) ++ "`");
                }
            }

            return struct {
                /// Copies the parsed flags into the type the author declared.
                ///
                /// A field-by-field copy rather than a pointer cast: the parsed type
                /// also carries the global flags and the positional slot, so it is a
                /// different struct and the copy is what keeps the author's parameter
                /// exactly the type they wrote.
                fn toFlags(comptime T: type, parsed: ParsedT) T {
                    var out: T = undefined;
                    inline for (std.meta.fields(T)) |field| {
                        @field(out, field.name) = @field(parsed, field.name);
                    }
                    return out;
                }

                pub fn call(ctx: Ctx, parsed: ParsedT) anyerror!PayloadT {
                    const args: ArgsT = parsed.positionals;
                    if (comptime shape == .ctx_only) return run_fn(ctx);
                    if (comptime shape == .ctx_args) return run_fn(ctx, args);
                    if (comptime shape == .ctx_flags) return run_fn(ctx, toFlags(FlagsParamT, parsed));
                    if (comptime shape == .ctx_flags_args) {
                        return run_fn(ctx, toFlags(FlagsParamT, parsed), args);
                    }
                    return run_fn(ctx, args, toFlags(FlagsParamT, parsed));
                }
            };
        }

        /// The command type `command` builds for a metadata object and a run function.
        fn CommandOf(comptime meta: anytype, comptime run_fn: anytype) type {
            const MT = @TypeOf(meta);
            const FlagsT = if (@hasField(MT, "flags")) meta.flags else struct {};

            // A flags type that already declares a positional slot keeps it.
            //
            // That is the older spelling (`positionals: struct { ... } = .{}` inside the
            // flags), and a command adopting `.args` should not have to rewrite a flags
            // struct that a library function shares. `.args` is the ergonomic form and
            // wins when a command declares both - which is a mistake, so it is refused
            // rather than silently resolved.
            const own_slot = @hasField(FlagsT, "positionals") or @hasField(FlagsT, "Positional");
            const SlotT = if (@hasField(FlagsT, "positionals"))
                @TypeOf(@as(FlagsT, undefined).positionals)
            else if (@hasField(FlagsT, "Positional"))
                @TypeOf(@as(FlagsT, undefined).Positional)
            else
                struct {};

            if (comptime own_slot and @hasField(MT, "args")) {
                @compileError("a `command`-registered command declares positional arguments once: " ++
                    "either `.args` in its metadata or a `positionals` field in its flags, not both");
            }

            const ArgsT = if (@hasField(MT, "args")) meta.args else SlotT;
            const subcmds = if (@hasField(MT, "subcommands")) meta.subcommands else .{};

            // `meta.dry_run` adds `--dry-run` to a command that does not declare one, so
            // opting into the standard dry-run state costs one word rather than a flag
            // on every command - and a command that already declares its own `dry_run`
            // field keeps it, because a merge would be a duplicate field.
            const needs_dry_run_slot = @hasField(MT, "dry_run") and
                meta.dry_run and
                !@hasField(FlagsT, "dry_run");

            const ParsedT = if (own_slot)
                MergeFlags(FlagsT, GlobalFlags)
            else if (needs_dry_run_slot)
                MergedWithDryRunAndPositionals(FlagsT, ArgsT)
            else
                MergeFlags(MergeFlags(FlagsT, GlobalFlags), PositionalSlot(ArgsT));

            // `App.command(meta, null)` registers a command with no body: a routing
            // node, or the `is_repl` marker whose shell the framework drives. The type
            // is still built, so `--help` and the routing work; only `run` is `null`,
            // which is what the dispatcher already understands.
            const has_body = @TypeOf(run_fn) != @TypeOf(null);

            const NoBody = struct {
                pub fn call(ctx: Ctx, parsed: ParsedT) anyerror!void {
                    _ = ctx;
                    _ = parsed;
                }
            };

            const Adapter = if (has_body) RunAdapter(run_fn, FlagsT, ArgsT, ParsedT) else NoBody;
            const RunReturnT = if (has_body)
                @typeInfo(@TypeOf(run_fn)).@"fn".return_type.?
            else
                void;
            const ReturnT = if (@typeInfo(RunReturnT) == .error_union)
                @typeInfo(RunReturnT).error_union.payload
            else
                RunReturnT;

            return struct {
                // The same compile-time flag check `CommandWithReturn` runs: a bad
                // declaration fails the build when the command type is built. The group
                // check is here rather than there because the groups live in the
                // metadata, which is comptime data this type function can read.
                comptime {
                    zutil.linter.ComptimeLinter.lintFlags(FlagsT);
                    if (@hasField(MT, "mutually_exclusive")) {
                        zutil.linter.ComptimeLinter.lintMutexGroups(FlagsT, meta.mutually_exclusive);
                    }
                }

                pub const OrigFlagsT = FlagsT;
                pub const subcommands = subcmds;
                /// The positional-argument struct, named so the framework can tell a
                /// command that takes arguments from one that does not. (`ArgsT`
                /// itself is taken by the enclosing scope's name.)
                pub const PositionalArgsT = ArgsT;
                pub const command_meta = meta;
                /// An optional help override: a namespace with `pub fn render(ctx, cmd)`.
                pub const help_renderer = if (@hasField(MT, "help")) meta.help else null;

                name: []const u8 = meta.name,
                description: []const u8 =
                    if (@hasField(MT, "description")) meta.description else "",
                aliases: []const []const u8 =
                    if (@hasField(MT, "aliases")) meta.aliases else &.{},
                hidden: bool = if (@hasField(MT, "hidden")) meta.hidden else false,
                deprecated: []const u8 =
                    if (@hasField(MT, "deprecated")) meta.deprecated else "",
                feature: []const u8 = if (@hasField(MT, "feature")) meta.feature else "",
                on_error: ?OnErrorFn = if (@hasField(MT, "on_error")) meta.on_error else null,
                is_repl: bool = if (@hasField(MT, "is_repl")) meta.is_repl else false,
                requires_confirmation: bool =
                    if (@hasField(MT, "requires_confirmation")) meta.requires_confirmation else false,
                mutually_exclusive: []const []const []const u8 =
                    if (@hasField(MT, "mutually_exclusive")) meta.mutually_exclusive else &.{},
                pre_run: ?HookFn = if (@hasField(MT, "pre_run")) meta.pre_run else null,
                post_run: ?HookFn = if (@hasField(MT, "post_run")) meta.post_run else null,

                run: ?*const fn (ctx: Ctx, flags: ParsedT) anyerror!ReturnT =
                    if (has_body) Adapter.call else null,
            };
        }

        /// Metadata for the built-in `update` command.
        ///
        /// ## Why the target path is the caller's business
        ///
        /// Replacing a binary needs to know *which* binary. `std.process.Init` in Zig
        /// 0.16 carries the environment, the arguments, an arena, an allocator, an `Io`
        /// and the preopened directories - and no executable path, and there is no
        /// `std.process.selfExePath` to fall back on. So discovery is a seam rather than
        /// an assumption: `resolve_target` when an app can find itself (a package
        /// manager's wrapper usually can, from a variable it set), or a literal
        /// `target_path` for tests and scripts.
        pub const UpdateMeta = struct {
            /// GitHub `owner/repo`: the release registry to read.
            owner: []const u8,
            repo: []const u8,
            /// The release asset for this platform, e.g. `snek-windows-x86_64.exe`. Its
            /// name is also what the checksum file is searched for.
            asset: []const u8,
            /// The version this binary was built as, compared against the release tag.
            current_version: []const u8,
            /// The command's name. Default `update`.
            name: []const u8 = "update",
            /// Its one-line description.
            description: []const u8 = "Update this binary from its release registry",
            /// When set, the release must carry a `<asset>.sig` that verifies over the
            /// downloaded bytes with this key. The checksum is still required: it catches
            /// a truncated download, and the signature catches a hostile one.
            public_key: ?[32]u8 = null,
            /// The file to replace, when it is known at compile time.
            target_path: []const u8 = "",
            /// How to find the file to replace, when it is not. Called once per run.
            resolve_target: ?*const fn (allocator: std.mem.Allocator, io: std.Io) anyerror![]u8 = null,
            /// How to build the transport, called once per run. `null` means real HTTP
            /// through `std.http.Client`.
            ///
            /// A *factory* rather than a value because the metadata is comptime: a
            /// `Fetcher` holds a context pointer, and pointing it at runtime state (a
            /// stub in a test, a client carrying a proxy from the environment, an
            /// authenticated session) is exactly what cannot be written as comptime data.
            fetcher_factory: ?*const fn () update.Fetcher = null,
        };

        /// The default transport: one HTTPS GET through `std.http.Client`.
        ///
        /// Public so an application can wrap it - a mirror, a proxy, an authenticated
        /// registry - instead of reimplementing it, and so the update command's tests can
        /// substitute a stub. `opaque_ctx` is a `*std.Io` the caller owns; it must outlive
        /// the fetch.
        pub fn httpFetch(opaque_ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) anyerror![]u8 {
            const io_ptr: *const std.Io = @ptrCast(@alignCast(opaque_ctx orelse return error.MissingIo));
            var client = std.http.Client{ .allocator = allocator, .io = io_ptr.* };
            defer client.deinit();

            var response = std.Io.Writer.Allocating.init(allocator);
            defer allocator.free(response.writer.buffer);

            const result = try client.fetch(.{
                .location = .{ .url = url },
                .method = .GET,
                .response_writer = &response.writer,
            });
            if (result.status != .ok) return error.ReleaseRegistryUnavailable;
            // Copied out: `install` frees what a fetcher returns, and the allocating
            // writer's buffer is this function's to free.
            return allocator.dupe(u8, response.writer.buffer[0..response.writer.end]);
        }

        /// Registers the built-in `update` command.
        ///
        /// ```zig
        /// const meta = .{
        ///     .owner = "93ams",
        ///     .repo = "snek",
        ///     .asset = "snek-windows-x86_64.exe",
        ///     .current_version = "0.1.0",
        ///     .resolve_target = myExePath,
        /// };
        /// const update = App.updateCommand(meta);
        /// ```
        ///
        /// The body reports before it changes anything: it prints the available version,
        /// installs nothing under `--check`, and replaces the binary only after `--yes`
        /// (or an interactive yes). A refusal is `error.ConfirmationRequired`, so it goes
        /// through the same status mapping as every other failure.
        /// Returns a command *value*, like `App.command` does, so it can be placed in a
        /// `subcommands` tuple directly. (The first version returned a type, which the
        /// compiler rejected the moment it was used as a subcommand - a tuple of commands
        /// holds values, and `@hasField` on a `type` is what gave the mistake away.)
        pub fn updateCommand(comptime update_meta: UpdateMeta) UpdateCommandFor(update_meta) {
            return .{};
        }

        /// The type `updateCommand` instantiates, split out so its flags type is visible
        /// in the command metadata as well as to the runner.
        fn UpdateCommandFor(comptime update_meta: UpdateMeta) type {
            const UpdateFlags = struct {
                check: bool = false,

                pub const meta = .{
                    .check = .{ .help = "Report whether an update exists without installing it" },
                };
            };

            const Runner = struct {
                fn run(ctx: Ctx, flags: MergeFlags(UpdateFlags, GlobalFlags)) !void {
                    return runUpdate(update_meta, ctx, flags);
                }
            };

            return CommandOf(.{
                .name = update_meta.name,
                .description = update_meta.description,
                .flags = UpdateFlags,
            }, Runner.run);
        }

        /// The `update` command's body. See `UpdateMeta` and `updateCommand`.
        fn runUpdate(comptime update_meta: UpdateMeta, ctx: anytype, flags: anytype) !void {
            std.debug.assert(update_meta.owner.len > 0);
            std.debug.assert(update_meta.repo.len > 0);
            std.debug.assert(update_meta.asset.len > 0);

            const alloc = ctx.allocator;
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const current = update.Version.parse(update_meta.current_version) catch |err| {
                try ctx.err.print(
                    "Error: this binary's version '{s}' is not a version ({s}).\n",
                    .{ update_meta.current_version, @errorName(err) },
                );
                return err;
            };

            // A local copy of the handle, so the fetcher's context points at something
            // with a stable address for the whole run.
            var io_holder: std.Io = ctx.io;
            const fetcher = if (update_meta.fetcher_factory) |make| make() else update.Fetcher{
                .ctx = @ptrCast(&io_holder),
                .fetch = httpFetch,
            };

            const release = update.fetchLatestRelease(arena, fetcher, update_meta.owner, update_meta.repo, update_meta.asset) catch |err| {
                try ctx.err.print(
                    "Error: cannot read the release registry for {s}/{s}: {s}\n",
                    .{ update_meta.owner, update_meta.repo, @errorName(err) },
                );
                return err;
            };

            if (!release.version.isNewerThan(current)) {
                try ctx.out.print("Already up to date ({s}).\n", .{update_meta.current_version});
                return;
            }
            try ctx.out.print("Update available: {s} -> {d}.{d}.{d}{s}\n", .{
                update_meta.current_version,
                release.version.major,
                release.version.minor,
                release.version.patch,
                release.version.prerelease,
            });

            // `--check` stops here: reporting is its whole point, and a check that could
            // still write would not be a check.
            if (flags.check) return;

            if (!flags.yes) {
                if (!ctx.is_tty) {
                    try ctx.err.print(
                        "Error: refusing to replace a running binary without --yes.\n",
                        .{},
                    );
                    return error.ConfirmationRequired;
                }
                const confirmed = prompt.confirm(ctx, "Replace this binary now?", .{ .default = false }) catch |err| {
                    return err;
                };
                if (!confirmed) {
                    try ctx.out.writeAll("Aborted; nothing was replaced.\n");
                    return error.UserCancelled;
                }
            }

            // Where to install it: a compile-time path wins, otherwise the app's resolver.
            const target: []const u8 = if (update_meta.target_path.len > 0)
                update_meta.target_path
            else if (update_meta.resolve_target) |resolve|
                try resolve(alloc, ctx.io)
            else {
                try ctx.err.print(
                    "Error: this command does not know which binary to replace; " ++
                        "set `target_path` or `resolve_target` in its metadata.\n",
                    .{},
                );
                return error.NoUpdateTarget;
            };
            const owns_target = update_meta.target_path.len == 0 and update_meta.resolve_target != null;
            defer if (owns_target) alloc.free(target);

            // The checksum lives beside the asset - the convention `checksumAssetName`
            // documents - and is verified before anything is written.
            const checksum_url = try std.fmt.allocPrint(arena, "{s}.sha256", .{release.asset.url});
            const checksum_body = fetcher.get(arena, checksum_url) catch |err| {
                try ctx.err.print("Error: cannot fetch {s}: {s}\n", .{ checksum_url, @errorName(err) });
                return err;
            };
            const expected_sha256 = update.parseChecksumFile(checksum_body, update_meta.asset) catch |err| {
                try ctx.err.print(
                    "Error: the checksum file has no usable entry for '{s}' ({s}).\n",
                    .{ update_meta.asset, @errorName(err) },
                );
                return err;
            };

            var signature: ?[]const u8 = null;
            if (update_meta.public_key != null) {
                const signature_url = try std.fmt.allocPrint(arena, "{s}.sig", .{release.asset.url});
                signature = fetcher.get(arena, signature_url) catch |err| {
                    try ctx.err.print("Error: cannot fetch {s}: {s}\n", .{ signature_url, @errorName(err) });
                    return err;
                };
            }

            const request: update.Request = .{
                .current_version = current,
                .new_version = release.version,
                .url = release.asset.url,
                .expected_sha256 = expected_sha256,
                .target_path = target,
                .fetcher = fetcher,
                .signature = signature,
                .public_key = update_meta.public_key,
            };
            const outcome = update.install(alloc, ctx.io, request) catch |err| {
                try ctx.err.print("Error: cannot install the update: {s}\n", .{@errorName(err)});
                return err;
            };

            switch (outcome) {
                .up_to_date => try ctx.out.print("Already up to date ({s}).\n", .{update_meta.current_version}),
                .installed => try ctx.out.print(
                    "Updated {s} to {d}.{d}.{d}{s}; restart to use it.\n",
                    .{
                        target,
                        release.version.major,
                        release.version.minor,
                        release.version.patch,
                        release.version.prerelease,
                    },
                ),
            }
        }

        /// Registers a command: its metadata in one object, its body in another.
        ///
        /// ```zig
        /// const AddFlags = struct { force: bool = false };
        /// const AddArgs = struct { component: []const u8 = "" };
        ///
        /// const meta = .{
        ///     .name = "add",
        ///     .description = "Add a component",
        ///     .flags = AddFlags,
        ///     .args = AddArgs,
        /// };
        ///
        /// pub const cmd = App.command(meta, addRun);
        ///
        /// // Any of these shapes, chosen by the author, detected at comptime:
        /// fn addRun(ctx: App.Ctx, flags: App.Flags(AddFlags), args: AddArgs) !void {}
        /// fn addRun(ctx: App.Ctx, args: AddArgs, flags: App.Flags(AddFlags)) !void {}
        /// ```
        ///
        /// `flags`, `args`, `aliases`, `hidden`, `subcommands`, `is_repl`,
        /// `requires_confirmation`, `mutually_exclusive`, `pre_run`, `post_run` and
        /// `help` are the metadata this reads, all optional except `name`; `flags` and
        /// `args` are *types*, so they are written as types and not as values.
        pub fn command(comptime meta: anytype, comptime run_fn: anytype) CommandOf(meta, run_fn) {
            return .{};
        }

        /// Executes a given command tree with the provided arguments.
        fn GetFlagsType(comptime CmdType: type) type {
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

        fn determinesIfFlagTakesValue(comptime OrigFlagsT: type, comptime FlagsType: type, arg: []const u8) bool {
            if (std.mem.startsWith(u8, arg, "--")) {
                const name = arg[2..];
                var key = name;
                if (std.mem.indexOf(u8, name, "=")) |eq_idx| {
                    key = name[0..eq_idx];
                }
                inline for (std.meta.fields(FlagsType)) |field| {
                    // The same dash/underscore equivalence `assignFlag` uses. Without
                    // it routing decides `--dry-run` takes no value, skips one token,
                    // and then reads the value as a subcommand or a positional.
                    // Not `comptime`: the key is runtime data, and the branch is a
                    // runtime check inside a comptime-unrolled loop.
                    if (flagNamesEqual(field.name, key)) {
                        return field.type != bool and !(@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool);
                    }
                }
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                // A short cluster: the value is either attached (`-tvalue`, so the next
                // argument is not consumed) or the next token (`-t value`, when the
                // value-taking flag is the last character). Reading only the *last*
                // character got `-ttok` wrong in both directions - it claimed the next
                // argument was the value and mis-routed the command.
                if (@hasDecl(OrigFlagsT, "meta")) {
                    const meta_block = OrigFlagsT.meta;
                    for (arg[1..], 0..) |char, char_idx| {
                        inline for (std.meta.fields(FlagsType)) |field| {
                            if (comptime !isPositionalField(field.name)) {
                                if (comptime @hasField(@TypeOf(meta_block), field.name)) {
                                    const field_meta = @field(meta_block, field.name);
                                    if (comptime @hasField(@TypeOf(field_meta), "short")) {
                                        if (char == field_meta.short) {
                                            const takes_value = field.type != bool and
                                                !(@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool);
                                            if (takes_value) {
                                                // Not the last character: the rest of the
                                                // cluster is the value, so nothing more
                                                // is consumed from argv.
                                                return takes_value and char_idx + 1 == arg[1..].len;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return false;
        }

        /// Erases the comptime CmdType into a generic runtime function pointer
        fn makeShellFn(comptime cmd: anytype) *const fn (ctx: Ctx) anyerror!void {
            const Wrapper = struct {
                fn launch(ctx: Ctx) !void {
                    return runShell(cmd, ctx);
                }
            };
            return Wrapper.launch;
        }

        /// Runs a command tree and terminates with its status.
        ///
        /// The second entry point, for a caller that owns its own `Ctx` instead of taking
        /// `std.process.Init` from `App.run` - a test harness or an embedding host.
        ///
        /// Both writers are flushed before the process ends. `std.process.exit` does not
        /// run `defer`, so without this a command's buffered output is discarded: this
        /// function used to exit `0` immediately after `execute` returned, which silently
        /// dropped whatever the command had written into a buffered `File.Writer`.
        pub fn executeAndExit(
            comptime cmd: anytype,
            ctx: anytype,
            args: []const []const u8,
            chain: anytype,
        ) noreturn {
            execute(cmd, ctx, args, chain) catch |err| failWith(err, ctx);
            ctx.out.flush() catch {};
            ctx.err.flush() catch {};
            std.process.exit(0);
        }

        /// Prints a failure and terminates with the mapped exit status.
        ///
        /// **`noreturn`, and the only place a command failure reaches `std.process.exit`.** The
        /// status is `getExitCode`'s - which is `config.exit_map` first, so a caller gives a
        /// domain error a meaningful status without the framework knowing what it means, then
        /// the POSIX table.
        ///
        /// It used to consult `exit_map` and otherwise hardcode `1`, which made the table
        /// above a claim about behaviour that the binaries did not have; both entry points
        /// now share one mapping. The message keeps the `Error: <name>` shape.
        ///
        /// It exists because the two entry points had drifted: `executeAndExit` mapped and exited,
        /// while `App.run` caught the error, printed `Command failed: <name>` and then returned
        /// normally - so *every* failing command run through the real entry point exited `0`. That
        /// is the "silent success" class this framework's own comments say the routing work existed
        /// to remove, and it was measured here by `git cat-file -e <absent>` reporting success
        /// while printing its own error. Callers that need to flush buffered writers before the
        /// process ends must do so first, because `std.process.exit` does not run `defer`.
        pub fn failWith(err: anyerror, ctx: anytype) noreturn {
            const disposition = failureDisposition(err);
            if (disposition.report) {
                ctx.err.print("Error: {s}\n", .{@errorName(err)}) catch {};
            }
            std.process.exit(disposition.code);
        }

        pub fn execute(
            comptime cmd: anytype,
            ctx: anytype,
            args: []const []const u8,
            chain: anytype,
        ) !void {
            // Whether `args[0]` is this command's own name is a **caller's choice**, and
            // both conventions are live in this repo, so it is detected rather than
            // assumed:
            //
            // * argv-style callers include it - the suite's `RejectRun` harness passes
            //   `{ "proot", "nosuch" }`, and a real shell passes `argv[0]`.
            // * argument-style callers omit it - the suite's `testExecute` passes
            //   `{ "auth", "login" }` straight into a root named `mycli`.
            //
            // Assuming either one breaks the other: starting at 1 unconditionally made
            // `testExecute` skip `auth` and route on `login`; starting at 0 made
            // `RejectRun` reject the command's own name. Comparing the token against the
            // command's declared name distinguishes them, and a name that genuinely
            // collides with the first argument is a case the user asked for by naming a
            // subcommand after the program.
            var arg_start: usize = 0;
            if (args.len > 0 and std.mem.eql(u8, args[0], cmd.name)) {
                // Skipped *and recorded*: recording is what lets the full `args` slice
                // survive recursion, because `parseFlags` walks the whole slice and would
                // otherwise take the name for a positional. That in turn is what keeps a
                // leaf's first positional (`config inspect port`) from being sliced away.
                try chain.recordSubcmdIndex(0);
                arg_start = 1;
            }
            return executeFrom(cmd, ctx, args, chain, arg_start);
        }

        /// Calls a command's body, or does nothing when it has none.
        ///
        /// `run` is optional on commands this framework builds (a routing node has no body)
        /// but a hand-written command may declare it required, so both shapes are handled -
        /// measured: a hand-written struct with `run: *const fn …` reached here and failed
        /// with "expected optional type" when only the optional shape was handled.
        fn runBodyOrNothing(comptime CmdType: type, cmd: CmdType, ctx: anytype, flags: anytype) !void {
            if (comptime @hasField(CmdType, "run")) {
                if (comptime @typeInfo(@TypeOf(@as(CmdType, undefined).run)) == .optional) {
                    if (cmd.run) |run_fn| {
                        const result = try run_fn(ctx, flags);
                        if (@TypeOf(result) != void) try formatOutput(ctx, result);
                    }
                } else {
                    const result = try cmd.run(ctx, flags);
                    if (@TypeOf(result) != void) try formatOutput(ctx, result);
                }
            }
        }

        /// Whether this command has a body to run.
        ///
        /// A command built by this framework has `run: ?*const fn …` (optional, `null` for
        /// a pure routing node); a hand-written one may declare it required. Both are
        /// "has a body", and a command with neither is not executable.
        fn hasRunBody(comptime CmdType: type) bool {
            if (comptime !@hasField(CmdType, "run")) return false;
            const RT = @TypeOf(@as(CmdType, undefined).run);
            if (comptime @typeInfo(RT) == .optional) {
                // `?*const fn …` is the framework's shape; `null` still means "no body",
                // but the field type itself is a body slot, so this reports true and the
                // `null` check happens at the call site where the value is known.
                return true;
            }
            return @typeInfo(RT) == .pointer;
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
        fn hasSubcommands(comptime CmdType: type) bool {
            return @hasDecl(CmdType, "subcommands") or @hasField(CmdType, "subcommands");
        }

        /// The number of subcommands actually present, which for a leaf is zero.
        fn subcommandCount(comptime CmdType: type) usize {
            if (comptime !hasSubcommands(CmdType)) return 0;
            return std.meta.fields(SubcommandsType(CmdType)).len;
        }

        /// Whether this command actually has anything to route to.
        fn hasAnySubcommands(comptime CmdType: type) bool {
            return subcommandCount(CmdType) > 0;
        }

        fn getSubcommands(cmd: anytype) SubcommandsType(@TypeOf(cmd)) {
            const CT = @TypeOf(cmd);
            if (comptime @hasDecl(CT, "subcommands")) return CT.subcommands;
            if (comptime @hasField(CT, "subcommands")) return cmd.subcommands;
            return .{};
        }

        fn SubcommandsType(comptime CmdType: type) type {
            if (comptime @hasDecl(CmdType, "subcommands")) return @TypeOf(CmdType.subcommands);
            if (comptime @hasField(CmdType, "subcommands")) return @TypeOf(@as(CmdType, undefined).subcommands);
            return @TypeOf(.{});
        }

        /// Whether this process is running under a CI system.
        ///
        /// Delegates to the capability module, which is where the policy lives: CI is
        /// one of the inputs to whether colour, cursor movement and prompts are allowed,
        /// so a single implementation keeps the framework's answer and the app's
        /// consistent.
        pub fn isCiEnvironment(env_map: *std.process.Environ.Map) bool {
            return render.capability.isCi(env_map);
        }

        /// Whether a subcommand is routable but must not be advertised.
        ///
        /// Checked on the type rather than the value because `inline for` over a tuple
        /// yields values whose type is what carries the field; a hand-written command
        /// without the field is simply not hidden.
        fn isHidden(comptime SubT: type, sub: SubT) bool {
            if (comptime !@hasField(SubT, "hidden")) return false;
            return sub.hidden;
        }

        /// Whether an environment variable named `name` opens a feature gate.
        ///
        /// Presence is what counts, with `""`, `0` and `false` read as "off" - the three
        /// spellings people use to disable something in a shell. An empty name means
        /// "not gated", so a command without the field is always open.
        fn featureIsOpen(ctx: anytype, name: []const u8) bool {
            if (name.len == 0) return true;
            const value = ctx.env_map.get(name) orelse return false;
            if (value.len == 0) return false;
            if (std.mem.eql(u8, value, "0")) return false;
            if (std.ascii.eqlIgnoreCase(value, "false")) return false;
            return true;
        }

        /// Whether a command's own feature gate is open.
        fn commandIsAvailable(ctx: anytype, comptime CmdT: type, cmd: CmdT) bool {
            if (comptime !@hasField(CmdT, "feature")) return true;
            return featureIsOpen(ctx, cmd.feature);
        }

        /// Whether a flag's feature gate is open. A flag without one is always available.
        fn fieldIsAvailable(ctx: anytype, comptime OrigFlagsT: type, comptime name: []const u8) bool {
            if (comptime hasMetaField(OrigFlagsT, name) and
                @hasField(@TypeOf(@field(OrigFlagsT.meta, name)), "feature"))
            {
                return featureIsOpen(ctx, @field(OrigFlagsT.meta, name).feature);
            }
            return true;
        }

        /// Whether a command is deprecated. Deprecated commands still route and warn; they
        /// are simply not advertised, which is the same lifecycle a deprecated flag has.
        fn isDeprecatedCommand(comptime CmdT: type, cmd: CmdT) bool {
            if (comptime !@hasField(CmdT, "deprecated")) return false;
            return cmd.deprecated.len > 0;
        }

        /// Whether a command should be listed in help, completions or suggestions.
        ///
        /// The single place the three rules meet, so they cannot drift: hidden commands,
        /// deprecated commands and commands whose feature gate is closed are all absent
        /// from every advertisement, while remaining routable where that makes sense.
        fn isAdvertisable(ctx: anytype, comptime CmdT: type, cmd: CmdT) bool {
            if (isHidden(CmdT, cmd)) return false;
            if (isDeprecatedCommand(CmdT, cmd)) return false;
            return commandIsAvailable(ctx, CmdT, cmd);
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
        fn declaresPositionals(comptime CmdType: type) bool {
            if (comptime @hasDecl(CmdType, "PositionalArgsT")) {
                return std.meta.fields(CmdType.PositionalArgsT).len > 0;
            }
            const FT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else GetFlagsType(CmdType);
            if (FT == void) return false;
            return @hasField(FT, "positionals") or @hasField(FT, "Positional");
        }

        /// The flag nearest to a misspelled one, or null when nothing is close enough.
        ///
        /// The same distance rule the router uses for subcommands, over long names only:
        /// a one-character key is a short flag, and guessing at one of those would
        /// invent a match for almost any input. The key is normalised to underscores
        /// first, so a typo in a dashed spelling is measured against the field's real
        /// name rather than being charged for the dash as well.
        fn nearestFlag(comptime OrigFlagsT: type, comptime FlagsType: type, ctx: anytype, key: []const u8) ?[]const u8 {
            if (key.len == 0 or key.len > 128) return null;

            var normalized_buf: [128]u8 = undefined;
            const normalized = normalized_buf[0..key.len];
            for (key, 0..) |ch, idx| normalized[idx] = if (ch == '-') '_' else ch;

            var best: ?[]const u8 = null;
            var best_dist: usize = std.math.maxInt(usize);
            const threshold: usize = if (key.len <= 3) 1 else 3;

            inline for (std.meta.fields(FlagsType)) |field| {
                if (comptime !(field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) {
                    if (comptime !isPositionalField(field.name)) {
                        // A deprecated flag still works but is not advertised, so it is
                        // not suggested either: pointing a user at the flag they are
                        // migrating off is worse than saying nothing. A gate-closed flag
                        // does not exist at all, so naming it would leak the experiment.
                        // Nested positive `if`s rather than `continue`, which Zig rejects
                        // beside comptime control flow.
                        if (comptime !isDeprecatedFlag(OrigFlagsT, field.name)) {
                            if (fieldIsAvailable(ctx, OrigFlagsT, field.name)) {
                                const distance = editDistance(normalized, field.name);
                                if (distance < best_dist) {
                                    best_dist = distance;
                                    best = field.name;
                                }
                            }
                        }
                    }
                }
            }
            return if (best_dist <= threshold) best else null;
        }

        /// Levenshtein edit distance.
        ///
        /// `std.mem.levenshteinDistance` does not exist in this std, and the algorithm is
        /// short enough that a dependency would be larger than the code. Two rolling rows
        /// rather than a full matrix: command names are short, and the allocation-free
        /// version keeps this usable inside a `comptime`-driven loop.
        fn editDistance(a: []const u8, b: []const u8) usize {
            var prev: [64]usize = undefined;
            var cur: [64]usize = undefined;
            const n = @min(b.len, 63);
            for (0..n + 1) |j| prev[j] = j;

            for (a, 0..) |ca, i| {
                cur[0] = i + 1;
                for (1..n + 1) |j| {
                    const cost: usize = if (ca == b[j - 1]) 0 else 1;
                    cur[j] = @min(@min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
                }
                prev = cur;
            }
            return prev[n];
        }

        /// The nearest subcommand name to `arg`, or null when nothing is close enough.
        ///
        /// The threshold scales with the input length so short names are not matched
        /// loosely: `up` should not suggest `update` for any typo, but `exportt` should
        /// suggest `export`. Aliases are considered too, since a user typing a misspelled
        /// alias wants the alias corrected rather than nothing.
        fn nearestSubcommand(comptime CmdType: type, ctx: anytype, arg: []const u8) ?[]const u8 {
            if (comptime !hasSubcommands(CmdType)) return null;

            var best: ?[]const u8 = null;
            var best_dist: usize = std.math.maxInt(usize);
            const threshold: usize = if (arg.len <= 3) 1 else 3;

            // Bound once: `getSubcommands` returns a value whose type is what the loop
            // iterates, and rebuilding it per iteration makes the tuple arrive as `type`.
            const subcmds = getSubcommands(@as(CmdType, undefined));

            inline for (subcmds) |subcmd| {
                // A suggestion is an advertisement, so it follows the same rule as the
                // help list and the completion list: a hidden, deprecated or gate-closed
                // command is not offered as a correction.
                if (isAdvertisable(ctx, @TypeOf(subcmd), subcmd)) {
                    const d = editDistance(arg, subcmd.name);
                    if (d < best_dist) {
                        best_dist = d;
                        best = subcmd.name;
                    }
                    if (@hasField(@TypeOf(subcmd), "aliases")) {
                        inline for (subcmd.aliases) |alias_name| {
                            const ad = editDistance(arg, alias_name);
                            if (ad < best_dist) {
                                best_dist = ad;
                                best = subcmd.name;
                            }
                        }
                    }
                }
            }
            return if (best_dist <= threshold) best else null;
        }

        /// Routes from `arg_start`, then runs the matching command's body.
        ///
        /// ## Why this is separate from `execute`, and why `arg_start` exists
        ///
        /// `args[0]` is the command's **own name**. The earlier routing loop started at 0
        /// and recursed with the *full* `args` slice, which produced two defects:
        ///
        /// 1. A command with a body never rejected an unknown subcommand. `proot nosuch`
        ///    scanned the whole tail, found no match, fell through, and ran `proot`'s body
        ///    - **exit 0 for a command that does not exist**. That is the "silent success"
        ///    this whole function exists to remove.
        /// 2. `proot nosuch child` *did* find `child`, because routing looked at every
        ///    token rather than the next one, so an unknown token in front of a valid one
        ///    was silently ignored.
        ///
        /// The name is therefore **skipped and recorded**: skipped so it is never
        /// re-examined as a possible subcommand (which is how attempt 2 rejected
        /// `config`), and recorded in `chain.subcmd_indices` so `parseFlags` skips it too
        /// (which is how attempt 3 lost the positional `port`).
        ///
        /// ## Why the tail is passed to the child, not a copy
        ///
        /// Attempt 3 sliced `args` when recursing, which made the leaf lose its first
        /// positional - `config inspect port` printed every field. `subcmd_indices` is
        /// what makes the full slice safe: every name consumed during routing is marked,
        /// and `parseFlags` skips exactly those positions.
        fn executeFrom(
            comptime cmd: anytype,
            ctx: anytype,
            args: []const []const u8,
            chain: anytype,
            arg_start: usize,
        ) !void {
            const CmdType = @TypeOf(cmd);

            // 1. Update the deepest contextual REPL pointer
            if (@hasDecl(CmdType, "subcommands")) {
                chain.interactive_shell = makeShellFn(cmd);
            } else if (@hasField(CmdType, "is_repl") and cmd.is_repl) {
                chain.interactive_shell = makeShellFn(cmd);
            }

            const cmd_info = @typeInfo(CmdType);
            if (cmd_info != .@"struct") {
                @compileError("Command must be a struct");
            }

            // Hooks are collected root-first as the routing descends, and both arrays
            // are bounded by the caller's `max_depth` - so the depth is checked rather
            // than indexed blind.
            //
            // Hooks are collected root-first as the routing descends, and both arrays
            // are bounded by the caller's `max_depth` - so the depth is checked rather
            // than indexed blind.
            if (chain.count >= chain.pre_runs.len or chain.count >= chain.post_runs.len) {
                return error.CommandNestingTooDeep;
            }

            // Assigned directly rather than through a helper, and only when the hook's
            // own type is *this* instantiation's: a command built by a different `App`
            // carries a `pre_run` whose `Ctx` is that instantiation's, and an assignment
            // that type-checks for one does not compile for the other.
            if (comptime @hasField(CmdType, "pre_run")) {
                if (comptime @TypeOf(cmd.pre_run) == ?HookFn) {
                    if (cmd.pre_run) |hook| chain.pre_runs[chain.count] = hook;
                } else if (comptime @TypeOf(cmd.pre_run) == HookFn) {
                    chain.pre_runs[chain.count] = cmd.pre_run;
                }
            }
            if (comptime @hasField(CmdType, "post_run")) {
                if (comptime @TypeOf(cmd.post_run) == ?HookFn) {
                    if (cmd.post_run) |hook| chain.post_runs[chain.count] = hook;
                } else if (comptime @TypeOf(cmd.post_run) == HookFn) {
                    chain.post_runs[chain.count] = cmd.post_run;
                }
            }
            chain.count += 1;

            // 2. Intercept the generators and the completion protocol.
            //
            // Handled before routing because these are not commands in the tree - they
            // are requests to *describe* it - and before the command's own flags are
            // parsed, because they are answered from the tree alone.
            //
            // Keyed on `arg_start`, not `args[0]`. The two are different under the
            // argv-style convention `execute` documents and detects, and reading
            // `args[0]` there meant `prog __complete` was routed as a command named
            // `prog` and failed with `UnknownCommand`.
            const first = if (arg_start < args.len) args[arg_start..] else args[args.len..];

            if (first.len > 0 and std.mem.eql(u8, first[0], "__complete")) {
                return try executeAutocomplete(cmd, ctx, first[1..]);
            }

            // Each output is a fixed template keyed on `cmd.name`. No allocation: a
            // completion script is a few lines of shell, and building it in a buffer
            // would add a failure mode to a path with no inputs to validate.
            if (first.len >= 2 and std.mem.eql(u8, first[0], "generate-completions")) {
                const shell = first[1];
                const prog = cmd.name;
                if (std.mem.eql(u8, shell, "bash")) {
                    try emitBashCompletions(ctx.out, prog);
                } else if (std.mem.eql(u8, shell, "zsh")) {
                    try emitZshCompletions(ctx.out, prog);
                } else if (std.mem.eql(u8, shell, "fish")) {
                    try emitFishCompletions(ctx.out, prog);
                } else if (std.mem.eql(u8, shell, "powershell") or std.mem.eql(u8, shell, "pwsh")) {
                    try emitPowershellCompletions(ctx.out, prog);
                } else {
                    try ctx.err.print("Error: Unknown shell '{s}'. Expected bash, zsh, fish or powershell.\n", .{shell});
                    return error.UnknownField;
                }
                return;
            }

            if (first.len >= 2 and std.mem.eql(u8, first[0], "generate-docs")) {
                const fmt = first[1];
                if (std.mem.eql(u8, fmt, "markdown") or std.mem.eql(u8, fmt, "md")) {
                    try writeMarkdownDocs(cmd, ctx.out, "");
                } else if (std.mem.eql(u8, fmt, "man")) {
                    try writeManPage(cmd, ctx.out);
                } else if (std.mem.eql(u8, fmt, "html")) {
                    try writeHtmlDocs(cmd, ctx.out);
                } else {
                    try ctx.err.print("Error: Unknown format '{s}'. Expected markdown, man or html.\n", .{fmt});
                    return error.UnknownField;
                }
                return;
            }
            // 2. Route Subcommands (if any)
            // `subcommands` may be a decl (hand-written commands) or a field (what
            // `CommandWithReturn` emits), so both shapes are probed - the same pair the
            // existing `hasSubcommands`/`SubcommandsType` helpers use.
            //
            // Scans from `arg_start`, which is 0 for a root invocation and
            // `cursor + 1` for a recursion - so the token that selected this command is
            // never re-examined here or in `parseFlags`.
            var cursor: usize = arg_start;
            route: while (cursor < args.len) {
                const arg = args[cursor];

                if (std.mem.startsWith(u8, arg, "-")) {
                    const _FlagsType = GetFlagsType(CmdType);
                    const _OrigFlagsT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else _FlagsType;
                    const consumes_value = determinesIfFlagTakesValue(_OrigFlagsT, _FlagsType, arg);
                    if (consumes_value and std.mem.indexOf(u8, arg, "=") == null) {
                        cursor += 2;
                    } else {
                        cursor += 1;
                    }
                    continue;
                }
                // `hasSubcommands` probes BOTH shapes. Checking `@hasDecl` alone silently
                // skipped every field-shaped command - which is what `CommandWithReturn`
                // emits and what a hand-written `.{ .name = …, .subcommands = .{…} }` root
                // uses. Measured: `RootCmd` has one subcommand and routing reported "not a
                // known subcommand" for it, because the guard was false and the `inline for`
                // below never ran.
                if (comptime hasSubcommands(CmdType)) {
                    inline for (getSubcommands(cmd)) |subcmd| {
                        // A feature-gated subcommand is not routable while its gate is
                        // closed: it is not "hidden", it does not exist yet. A deprecated
                        // one *is* routable - that is the migration path - and warns below.
                        // The gate reads the environment, so this is a runtime test.
                        if (commandIsAvailable(ctx, @TypeOf(subcmd), subcmd)) {
                            const name_matches = std.mem.eql(u8, subcmd.name, arg);
                            var alias_matches = false;
                            if (!name_matches and @hasField(@TypeOf(subcmd), "aliases")) {
                                for (subcmd.aliases) |alias_name| {
                                    if (std.mem.eql(u8, alias_name, arg)) alias_matches = true;
                                }
                            }
                            if (name_matches or alias_matches) {
                                // The comptime guard is what lets a hand-written command
                                // without the field reach here: `isDeprecatedCommand`
                                // returns false for it, but the *body* below reads the
                                // field, and a runtime `if` would still analyze it.
                                if (comptime @hasField(@TypeOf(subcmd), "deprecated")) {
                                    if (isDeprecatedCommand(@TypeOf(subcmd), subcmd)) {
                                        try ctx.err.print("Warning: Command '{s}' is deprecated: {s}\n", .{
                                            subcmd.name, subcmd.deprecated,
                                        });
                                    }
                                }
                                // Recorded so `parseFlags` skips it, then the recursion starts
                                // one past it.
                                try chain.recordSubcmdIndex(cursor);
                                return try executeFrom(subcmd, ctx, args, chain, cursor + 1);
                            }
                        }
                    }
                }

                // The token is not a flag and not a known subcommand.
                //
                // Rejected outright when there is nowhere for it to go: either this
                // command has no body, or it has one but declares no positionals. A
                // command that declares positionals keeps the token and lets `parseFlags`
                // place it - which is the `config inspect port` case, and the reason this
                // check cannot simply be "no body".

                if (comptime !hasRunBody(CmdType) or !declaresPositionals(CmdType)) {
                    // An unregistered token may name an external subcommand: `app foo`
                    // runs `<prefix>-foo` from `PATH` when the app opted in, with the rest
                    // of the command line passed through untouched. Runs before the error,
                    // because to the user a plugin and a built-in are the same command.
                    if (comptime @hasField(@TypeOf(config), "plugins")) {
                        if (config.plugins.enabled) {
                            if (try runExternalPlugin(ctx, chain, config.plugins.prefix, arg, args[cursor + 1 ..])) {
                                return;
                            }
                        }
                    }

                    try ctx.err.print("Error: Unknown command '{s}'.\n", .{arg});
                    if (comptime hasSubcommands(CmdType)) {
                        if (nearestSubcommand(CmdType, ctx, arg)) |suggestion| {
                            try ctx.err.print("Did you mean '{s}'?\n", .{suggestion});
                        }
                    }
                    return error.UnknownCommand;
                }

                break :route;
            }

            // 1. Intercept help and the built-in version, after routing.
            //
            // Routing runs first so `prog sub --help` describes `sub` - the command the
            // user is actually asking about - rather than the root.
            //
            // Scanned from `arg_start` for the same reason the generators are: under the
            // argv-style convention the program's own name must not be examined.
            for (first) |arg| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    try renderHelp(cmd, ctx);
                    return;
                }
            }

            // The built-in version is opt-in. An app with no `Config.version` keeps
            // whatever `version` flag it declared for itself, which is why this is
            // checked rather than always on.
            if (comptime @hasField(@TypeOf(config), "version")) {
                if (config.version.len > 0) {
                    for (first) |arg| {
                        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                            try ctx.out.print("{s} {s}\n", .{ cmd.name, config.version });
                            return;
                        }
                    }
                }
            }

            // 2b. A REPL command invoked with nothing to do drops into its shell.
            //
            // This is the "run it and you are in a session" behaviour a REPL is for, and
            // it is opt-in: only a command that declares `is_repl` does it, and only on a
            // terminal. Piped or in CI, the same invocation prints usage instead, so a
            // script that runs a binary with no arguments does not block on a prompt that
            // no one can answer.
            if (comptime @hasField(CmdType, "is_repl") and cmd.is_repl) {
                if (first.len == 0 and ctx.is_tty) {
                    if (chain.interactive_shell) |shell_fn| {
                        try shell_fn(ctx);
                    } else {
                        try runShell(cmd, ctx);
                    }
                    return;
                }
            }

            // 3. Check if this command is executable
            if (comptime !@hasField(CmdType, "run") or @TypeOf(cmd.run) == @TypeOf(null)) {
                if (first.len == 0) {
                    try renderHelp(cmd, ctx);
                    return;
                }
                return error.CommandNotExecutable;
            } else {
                comptime var run_info = @typeInfo(@TypeOf(cmd.run));
                const is_optional = run_info == .optional;
                if (is_optional) {
                    if (cmd.run == null) {
                        if (first.len == 0) {
                            try renderHelp(cmd, ctx);
                            return;
                        }
                        return error.CommandNotExecutable;
                    }
                    run_info = @typeInfo(run_info.optional.child);
                }

                if (run_info == .pointer) {
                    run_info = @typeInfo(run_info.pointer.child);
                }

                if (run_info != .@"fn") {
                    @compileError("run must be a function pointer");
                }

                const FlagsType = run_info.@"fn".params[1].type.?;

                // One arena per leaf invocation.
                //
                // Repeated flags, a variadic positional list and the config file's keys
                // are all allocations whose lifetime is exactly "this command
                // invocation", and they used to be made with `ctx.allocator` and never
                // freed - invisible in a real process, a leak under `std.testing.allocator`.
                // The framework owns them here so a command does not have to.
                var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
                defer arena_state.deinit();
                const arena = arena_state.allocator();

                const pos_buf = try arena.alloc([]const u8, args.len);
                var pos_count: usize = 0;

                const OrigFlagsT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else FlagsType;
                const file_values = try loadConfigDefaults(arena, ctx);
                const groups: []const []const []const u8 =
                    if (@hasField(CmdType, "mutually_exclusive")) cmd.mutually_exclusive else &.{};
                const flags = try parseFlags(
                    OrigFlagsT,
                    FlagsType,
                    args,
                    pos_buf,
                    &pos_count,
                    ctx,
                    chain,
                    arena,
                    file_values,
                    groups,
                );

                var new_ctx = ctx;
                if (@hasField(FlagsType, "output")) {
                    new_ctx.output_format = flags.output;
                }

                // Dry run travels on the context, so business logic that only receives a
                // `Ctx` can honour "report, do not mutate" without every layer between the
                // command and the decision forwarding a boolean by hand. A field named
                // `dry_run` of any other type is not a dry-run flag and is left alone.
                if (@hasField(FlagsType, "dry_run") and @TypeOf(@field(flags, "dry_run")) == bool) {
                    new_ctx.dry_run = @field(flags, "dry_run");
                }

                // Secret values go into the log module's scrubber, so a token that the
                // command later logs - deliberately or in an error path - is masked on the
                // way out. This is the framework's only chance to see the value: it is
                // parsed here and never again.
                registerSecrets(OrigFlagsT, flags);

                if (@hasField(FlagsType, "interactive") and flags.interactive) {
                    if (chain.interactive_shell) |shell_fn| {
                        try shell_fn(new_ctx);
                    } else {
                        try runShell(cmd, new_ctx);
                    }
                }

                // Execute Pre-Runs (Root -> Leaf).
                //
                // These were collected and never called: `pre_runs` had no call site
                // anywhere in the framework, so a command's `pre_run` hook was dead code
                // that looked supported. They run after flags are parsed - so a hook can
                // read state the command will see - and before the body, which is the
                // only order that makes a "before execute" hook mean anything.
                var pre_index: usize = 0;
                while (pre_index < chain.count) : (pre_index += 1) {
                    if (chain.pre_runs[pre_index]) |pre| try pre(new_ctx);
                }

                // `run` is optional on commands this framework builds (a pure routing
                // node has no body) but a hand-written command may declare it required.
                // Both shapes are valid, so the check is on the field's own type rather
                // than on the declaration this file happens to emit - measured: a
                // hand-written struct with `run: *const fn ... App.Error!void` reached
                // here and failed with "expected optional type".
                // Confirmation safeguard. A command may declare `requires_confirmation`,
                // and then it will not run without an explicit `--yes`/`-y` unless a human
                // is there to answer. This is a *safety* gate, so the failure is closed:
                // a non-interactive caller that did not say yes is refused rather than
                // assumed to have meant it.
                if (comptime @hasField(CmdType, "requires_confirmation") and cmd.requires_confirmation) {
                    var confirmed = false;
                    for (args) |a| {
                        if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) confirmed = true;
                    }
                    if (!confirmed) {
                        if (!ctx.is_tty) {
                            try ctx.err.print("Error: '{s}' requires confirmation. Re-run with --yes.\n", .{cmd.name});
                            return error.ConfirmationRequired;
                        }
                        // Interactive: ask, and treat anything but an explicit yes as no.
                        try ctx.out.print("Run '{s}'? [y/N] ", .{cmd.name});
                        if (ctx.in.takeDelimiter('\n') catch null) |answer| {
                            const trimmed = std.mem.trim(u8, answer, " \r\n\t");
                            if (trimmed.len == 0 or (trimmed[0] != 'y' and trimmed[0] != 'Y')) {
                                try ctx.err.writeAll("Aborted.\n");
                                return error.UserCancelled;
                            }
                        } else {
                            return error.UserCancelled;
                        }
                    }
                }

                // Route through the configured middleware chain when there is one.
                //
                // `OnionBuilder` existed with no caller, which is why the middleware test
                // reported zero invocations: the chain was built and never entered. The
                // onion order is enter-outermost-first, run the command, exit-innermost-
                // first, which is what nesting `exec` one level deeper per middleware
                // produces.
                //
                // The command's own `on_error` hook wraps the whole thing - middleware
                // included - because a failure inside a middleware is still this command
                // failing, and a command-level hook that skipped it would be a hook the
                // author cannot rely on. A middleware is the place for an *app-wide*
                // reaction, since it sees every command.
                invokeBody(CmdType, cmd, new_ctx, flags) catch |err| {
                    if (comptime @hasField(CmdType, "on_error")) {
                        if (cmd.on_error) |hook| hook(new_ctx, err);
                    }
                    return err;
                };

                // Execute Post-Runs (Leaf -> Root).
                //
                // `new_ctx`, not `ctx`: `--output json` reaches the command as
                // `output_format`, and a post-run that rendered a summary was reading
                // the un-enriched context and formatting it as text.
                var i: usize = chain.count;
                while (i > 0) {
                    i -= 1;
                    if (chain.post_runs[i]) |post| try post(new_ctx);
                }
            }
        }

        /// Runs a command's body through the configured onion, or directly when there is
        /// no middleware.
        ///
        /// Split out of `executeFrom` so the `on_error` hook can wrap it with one `catch`.
        ///
        /// `@hasField` rather than a default on `config.middlewares`: it is optional
        /// configuration, and a `const` there would force every `App(...)` instantiation
        /// to spell it out.
        fn invokeBody(comptime CmdType: type, cmd: CmdType, new_ctx: anytype, flags: anytype) !void {
            if (comptime @hasField(@TypeOf(config), "middlewares")) {
                if (comptime config.middlewares.len > 0) {
                    try OnionBuilder(config.middlewares, 0, CmdType, @TypeOf(flags)).exec(new_ctx, cmd, flags);
                } else {
                    try runBodyOrNothing(CmdType, cmd, new_ctx, flags);
                }
            } else {
                try runBodyOrNothing(CmdType, cmd, new_ctx, flags);
            }
        }

        /// A value as it may appear in a message: masked when the field is a secret.
        ///
        /// Error messages are the one place a redaction rule is easy to forget, because a
        /// value that failed to *parse* feels harmless - but `--token` with a typo is
        /// exactly a secret arriving somewhere it will be shown, copied and pasted into a
        /// bug report. `comptime`, so a non-secret field pays nothing for the check.
        fn maskIfSecret(comptime is_secret: bool, value: []const u8) []const u8 {
            return if (is_secret) log.redaction_mask else value;
        }

        /// Hands every secret-tagged string flag to the log module's scrubber.
        ///
        /// A field is a secret because its metadata says so, which is the same declaration
        /// `formatFlags` redacts on and the same one that keeps it out of `--help`'s
        /// default column. Registering the value here means an application that logs
        /// through `cli.log` cannot leak a token by accident, and does not have to thread
        /// a redaction list of its own through every call site.
        fn registerSecrets(comptime OrigFlagsT: type, flags: anytype) void {
            if (comptime !@hasDecl(OrigFlagsT, "meta")) return;
            const FlagsT = @TypeOf(flags);
            inline for (std.meta.fields(FlagsT)) |field| {
                if (comptime !isFrameworkField(field.name) and !isPositionalField(field.name)) {
                    if (comptime field.type == []const u8 or field.type == []u8) {
                        if (comptime isSecretFlag(OrigFlagsT, field.name)) {
                            log.registerSecret(@field(flags, field.name));
                        }
                    }
                    // A secret inside the positional slot is reachable through the slot's
                    // own metadata, which is where `app/cfg` documents its arguments.
                    if (comptime isPositionalField(field.name)) {
                        const SlotT = field.type;
                        inline for (std.meta.fields(SlotT)) |p_field| {
                            if (comptime p_field.type == []const u8) {
                                if (comptime isSecretPositional(OrigFlagsT, field.name, p_field.name)) {
                                    log.registerSecret(@field(@field(flags, field.name), p_field.name));
                                }
                            }
                        }
                    }
                }
            }
        }

        /// Whether a flag's metadata declares it secret.
        fn isSecretFlag(comptime OrigFlagsT: type, comptime name: []const u8) bool {
            if (!@hasDecl(OrigFlagsT, "meta")) return false;
            if (!@hasField(@TypeOf(OrigFlagsT.meta), name)) return false;
            const entry = @field(OrigFlagsT.meta, name);
            if (!@hasField(@TypeOf(entry), "secret")) return false;
            return entry.secret;
        }

        /// Whether a positional argument's metadata declares it secret, in either
        /// spelling of the slot.
        fn isSecretPositional(comptime OrigFlagsT: type, comptime slot_name: []const u8, comptime name: []const u8) bool {
            if (!@hasDecl(OrigFlagsT, "meta")) return false;
            if (!@hasField(@TypeOf(OrigFlagsT.meta), slot_name)) return false;
            const slot = @field(OrigFlagsT.meta, slot_name);
            if (!@hasField(@TypeOf(slot), name)) return false;
            const entry = @field(slot, name);
            if (!@hasField(@TypeOf(entry), "secret")) return false;
            return entry.secret;
        }

        /// Runs `<prefix>-<name>` from `PATH`, passing the remaining arguments through.
        ///
        /// Returns false when no such executable exists, so the caller can report the
        /// ordinary unknown-command error and suggest the nearest built-in.
        ///
        /// ## Why the child inherits the streams
        ///
        /// A plugin is an extension of the command line, not a subroutine: its output must
        /// reach the user's terminal directly, or colour, progress and its own prompts are
        /// broken by being captured and replayed. So stdin, stdout and stderr are
        /// inherited rather than piped, and the framework writes nothing itself.
        ///
        /// ## Why the status travels on the chain
        ///
        /// The child's exit status is the user's answer, so it must survive to
        /// `std.process.exit`. Exiting from here would put that decision in the library
        /// instead of the entry point - and would skip the flushes `App.run` does first.
        ///
        /// ## Why the name is checked
        ///
        /// `foo/bar`, `..\evil` and `-rf` are refused before any lookup: a command line is
        /// untrusted input, and passing it to a PATH search unchanged is how a "run the
        /// plugin" feature becomes "run any program the attacker names".
        fn runExternalPlugin(
            ctx: anytype,
            chain: anytype,
            prefix: []const u8,
            name: []const u8,
            rest: []const []const u8,
        ) !bool {
            std.debug.assert(rest.len <= 1024);
            if (name.len == 0 or name.len > 128) return false;
            if (name[0] == '-') return false;
            for (name) |ch| {
                // A path separator would let the token name a file anywhere; a dot would
                // let it name `../x` or a Windows alternate-data stream.
                if (ch == '/' or ch == '\\' or ch == '.' or ch == ':') return false;
            }

            const exe = if (prefix.len == 0)
                try ctx.allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ prefix, name });
            defer ctx.allocator.free(exe);

            var argv: std.ArrayListUnmanaged([]const u8) = .empty;
            defer argv.deinit(ctx.allocator);
            try argv.append(ctx.allocator, exe);
            for (rest) |extra| try argv.append(ctx.allocator, extra);

            var child = std.process.spawn(ctx.io, .{
                .argv = argv.items,
                // PATH resolution and the standard extensions, so a plugin is found the
                // way a shell would find it.
                .expand_arg0 = .expand,
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            }) catch |err| switch (err) {
                // No such plugin: not an error here, because the caller has a better
                // message for it (the unknown-command one, with suggestions).
                error.FileNotFound => return false,
                else => {
                    try ctx.err.print("Error: cannot run '{s}': {s}\n", .{ exe, @errorName(err) });
                    return err;
                },
            };

            const term = try child.wait(ctx.io);
            chain.external_status = switch (term) {
                .exited => |code| code,
                // The convention a shell reports: 128 + the signal number.
                .signal => |sig| 128 +% @as(u8, @truncate(@intFromEnum(sig))),
                .stopped, .unknown => 1,
            };
            return true;
        }

        /// The config file's flat key -> text map, or null when there is no file layer.
        ///
        /// A *missing* file is not an error: the layer exists to supply defaults, and an
        /// app that runs before the file is created should not fail. A file that exists
        /// and cannot be read or parsed **is** an error, because silently ignoring it
        /// would leave a user with settings that are visibly present and invisibly
        /// ignored.
        fn loadConfigDefaults(allocator: std.mem.Allocator, ctx: anytype) !?std.StringHashMapUnmanaged([]const u8) {
            if (comptime @hasField(@TypeOf(config), "config_file")) {
                if (config.config_file.path.len == 0) return null;

                const text = std.Io.Dir.cwd().readFileAlloc(
                    ctx.io,
                    config.config_file.path,
                    allocator,
                    .limited(1 << 20),
                ) catch |err| switch (err) {
                    error.FileNotFound => return null,
                    else => {
                        try ctx.err.print(
                            "Error: cannot read config file '{s}': {s}\n",
                            .{ config.config_file.path, @errorName(err) },
                        );
                        return err;
                    },
                };

                // The loader may be declared as `?ConfigFile.Loader` (the `ConfigFile`
                // shape) or as a bare function - a config literal written inline is an
                // anonymous struct whose field types are inferred from the expression.
                const loader: ConfigFile.Loader = if (comptime @hasField(
                    @TypeOf(config.config_file),
                    "loader",
                )) blk: {
                    const configured = config.config_file.loader;
                    if (comptime @typeInfo(@TypeOf(configured)) == .optional) {
                        break :blk configured orelse defaultConfigFileLoader;
                    } else {
                        break :blk configured;
                    }
                } else defaultConfigFileLoader;

                return loader(allocator, config.config_file.path, text) catch |err| {
                    try ctx.err.print(
                        "Error: cannot parse config file '{s}': {s}\n",
                        .{ config.config_file.path, @errorName(err) },
                    );
                    return err;
                };
            } else {
                return null;
            }
        }

        /// Renders help: the command's override, else the app's, else the built-in.
        ///
        /// The override is a *type* with `pub fn render(ctx, cmd)`, not a function
        /// pointer, because `cmd` is a different type per command tree and a function
        /// pointer cannot be generic over it. Both levels are opt-in, so the built-in
        /// stays the default and a caller that wants a different layout writes one
        /// namespace and names it once.
        fn renderHelp(comptime cmd: anytype, ctx: anytype) !void {
            const CmdType = @TypeOf(cmd);
            if (comptime @hasDecl(CmdType, "help_renderer") and @TypeOf(CmdType.help_renderer) != @TypeOf(null)) {
                return CmdType.help_renderer.render(ctx, cmd);
            }
            if (comptime @hasField(@TypeOf(config), "help_renderer")) {
                return config.help_renderer.render(ctx, cmd);
            }
            return printHelp(cmd, ctx);
        }

        fn parseFlags(
            comptime OrigFlagsT: type,
            comptime FlagsType: type,
            args: []const []const u8,
            pos_buf: [][]const u8,
            pos_count: *usize,
            ctx: anytype,
            chain: anytype,
            alloc: std.mem.Allocator,
            file_values: ?std.StringHashMapUnmanaged([]const u8),
            mutex_groups: []const []const []const u8,
        ) !FlagsType {
            var parsed_flags: FlagsType = undefined;
            // `provided` is "the user typed this flag". It is deliberately narrow:
            // `conflicts_with`/`requires` are defined over what the command line asked
            // for, so a value that arrived from the environment cannot conflict with
            // anything.
            var provided = [_]bool{false} ** std.meta.fields(FlagsType).len;
            // `resolved` is "this field already has a value from somewhere", which is
            // what the resolution order needs: CLI > environment > file > default.
            var resolved = [_]bool{false} ** std.meta.fields(FlagsType).len;

            // Values collected for repeatable fields, keyed by field index. Raw text,
            // because each field's element type is only known inside the `inline for`
            // that fills it - so the strings are collected here and typed at the end.
            var repeat_values: [std.meta.fields(FlagsType).len]std.ArrayListUnmanaged([]const u8) =
                [_]std.ArrayListUnmanaged([]const u8){.empty} ** std.meta.fields(FlagsType).len;
            defer {
                for (&repeat_values) |*list| list.deinit(alloc);
            }

            // 1. Initialize defaults and validation checks
            inline for (std.meta.fields(FlagsType)) |field| {
                if (comptime (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) {
                    continue;
                }
                if (comptime isPositionalField(field.name)) {
                    continue;
                }

                if (field.default_value_ptr) |def| {
                    @field(parsed_flags, field.name) = @as(*align(1) const field.type, @ptrCast(def)).*;
                } else {
                    if (@typeInfo(field.type) == .optional) {
                        @field(parsed_flags, field.name) = null;
                    } else if (field.type == bool) {
                        @field(parsed_flags, field.name) = false;
                    }
                }
            }

            const has_pos_lower = @hasField(FlagsType, "positionals");
            const has_pos_upper = @hasField(FlagsType, "Positional");
            if (comptime has_pos_lower or has_pos_upper) {
                const pos_field_name = if (has_pos_lower) "positionals" else "Positional";
                const PosType = @TypeOf(@field(parsed_flags, pos_field_name));

                inline for (std.meta.fields(PosType)) |p_field| {
                    if (p_field.default_value_ptr) |def| {
                        @field(@field(parsed_flags, pos_field_name), p_field.name) = @as(*align(1) const p_field.type, @ptrCast(def)).*;
                    } else {
                        if (@typeInfo(p_field.type) == .optional) {
                            @field(@field(parsed_flags, pos_field_name), p_field.name) = null;
                        }
                    }
                }
            }

            // 2. Parse arguments
            var i: usize = 0;
            // Set by a bare `--`, after which every remaining token is a positional.
            //
            // This is how a caller passes something that looks like a flag as a *value* -
            // `-- --not-a-flag` - and without it there is no way to express that at all.
            var end_of_options = false;
            args_loop: while (i < args.len) : (i += 1) {
                for (chain.subcmd_indices[0..chain.subcmd_count]) |subcmd_idx| {
                    if (i == subcmd_idx) continue :args_loop;
                }
                const arg = args[i];

                if (!end_of_options and std.mem.eql(u8, arg, "--")) {
                    end_of_options = true;
                    continue;
                }
                if (end_of_options) {
                    if (pos_count.* < pos_buf.len) {
                        pos_buf[pos_count.*] = arg;
                        pos_count.* += 1;
                    }
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
                    // Long flag
                    const name = arg[2..];
                    var key = name;
                    var val: ?[]const u8 = null;
                    if (std.mem.indexOf(u8, name, "=")) |eq_idx| {
                        key = name[0..eq_idx];
                        val = name[eq_idx + 1 ..];
                    }

                    // A long flag carries its own value when `=` was used, so nothing
                    // more is consumed from argv; the result is deliberately unused.
                    _ = try assignFlag(OrigFlagsT, FlagsType, &parsed_flags, &provided, &resolved, &repeat_values, key, val, args, &i, ctx, alloc);
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.mem.startsWith(u8, arg, "--")) {
                    // Short flags, grouped: `-fa` is `-f -a`, and `-tvalue` is
                    // `-t value`.
                    //
                    // The attached form is what getopt does and what people type; the
                    // rest of the cluster is handed to `assignFlag` as the value, and if
                    // it *takes* one the cluster ends there - so `-tf` is never read as
                    // `-t -f`, which is the only reading that could silently do the wrong
                    // thing.
                    for (arg[1..], 0..) |char, char_idx| {
                        const short_key = [_]u8{char};
                        const attached = arg[2 + char_idx ..];
                        const attached_value: ?[]const u8 = if (attached.len > 0)
                            (if (attached[0] == '=') attached[1..] else attached)
                        else
                            null;

                        const took_value = try assignFlag(
                            OrigFlagsT,
                            FlagsType,
                            &parsed_flags,
                            &provided,
                            &resolved,
                            &repeat_values,
                            &short_key,
                            attached_value,
                            args,
                            &i,
                            ctx,
                            alloc,
                        );
                        if (took_value and attached.len > 0) break;
                    }
                } else {
                    if (pos_count.* < pos_buf.len) {
                        pos_buf[pos_count.*] = arg;
                        pos_count.* += 1;
                    } else {
                        try ctx.err.print("Error: Too many positional arguments.\n", .{});
                        return error.TooManyPositionalArguments;
                    }
                }
            }

            // 3. Resolution below the command line: environment first, then file.
            //
            // Both run *before* "required but missing" is reported, which is what lets
            // an `.env` mapping satisfy a flag that has no default. That order was
            // wrong: the missing-required bail-out came first, so a required flag could
            // never be filled from the environment however its metadata was written.
            //
            // The order here is the documented one - CLI flag > environment > file >
            // the struct's own default - and it is enforced by `resolved`, which the
            // command line sets in `assignFlag` and each layer below only consults.
            inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                if (comptime isFrameworkField(field.name)) {
                    // framework-internal field
                } else if (comptime isPositionalField(field.name)) {
                    // positionals carry no flag metadata
                } else {
                    try resolveFieldFromLayers(
                        OrigFlagsT,
                        FlagsType,
                        field,
                        idx,
                        &parsed_flags,
                        &repeat_values,
                        &resolved,
                        file_values,
                        ctx,
                        alloc,
                    );
                }
            }

            // 3.1 Command-level mutual exclusion.
            //
            // Checked against `provided`, like `conflicts_with`, so a value supplied by
            // the environment or a file cannot trip a group it never asked for. Names
            // are matched in either spelling, so a group may be written with the dashes
            // the user types.
            for (mutex_groups) |group| {
                var first_given: ?[]const u8 = null;
                for (group) |group_name| {
                    inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                        if (comptime (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) {
                            // framework-internal field
                        } else if (comptime isPositionalField(field.name)) {
                            // positionals are not flags
                        } else if (provided[idx] and flagNamesEqual(field.name, group_name)) {
                            if (first_given) |taken| {
                                try ctx.err.print(
                                    "Error: Flag '--{s}' cannot be used with '--{s}'.\n",
                                    .{ group_name, taken },
                                );
                                return error.ConflictingFlags;
                            }
                            first_given = group_name;
                        }
                    }
                }
            }

            // 3. Post-parsing Validation
            if (@hasDecl(OrigFlagsT, "meta")) {
                const meta_block = OrigFlagsT.meta;
                inline for (std.meta.fields(FlagsType)) |field| {
                    if (@hasField(@TypeOf(meta_block), field.name)) {
                        const field_meta = @field(meta_block, field.name);
                        if (@hasField(@TypeOf(field_meta), "validate")) {
                            const validator_fn = field_meta.validate;
                            const current_value = @field(parsed_flags, field.name);

                            validator_fn(current_value) catch |err| {
                                try ctx.err.print("Validation failed for '--{s}'.\n", .{field.name});
                                return err;
                            };
                        }
                    }
                }
            }
            // 3. Post-parsing Validation (Missing Defaults)
            //
            // `resolved`, not `provided`: a field the environment or the config file
            // supplied is not missing, and the prompt below is for a field nothing has
            // answered yet.
            inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                if (comptime (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) continue;
                if (comptime isPositionalField(field.name)) continue;

                if (!resolved[idx]) {
                    if (field.default_value_ptr == null and @typeInfo(field.type) != .optional and field.type != bool) {
                        if (ctx.is_tty) {
                            try ctx.out.print("? {s} [--{s}]: ", .{ field.name, field.name });
                            if (ctx.in.takeDelimiter('\n') catch null) |read_str| {
                                const input_str = std.mem.trim(u8, read_str, " \r\n\t");
                                if (input_str.len == 0) {
                                    try ctx.err.print("\nError: Missing required flag '--{s}'.\n", .{field.name});
                                    return error.MissingRequiredFlag;
                                }
                                const parsed_missing_val =
                                    if (comptime @hasDecl(OrigFlagsT, "parse") and @hasField(@TypeOf(OrigFlagsT.parse), field.name)) blk: {
                                        const custom_parser = @field(OrigFlagsT.parse, field.name);
                                        break :blk custom_parser(input_str) catch |err| {
                                            try ctx.err.print("\nError: Invalid format for flag '--{s}'.\n", .{field.name});
                                            return err;
                                        };
                                    } else if (comptime getGlobalParserIndex(field.type)) |parser_idx| blk: {
                                        const global_parser = @field(config.type_parsers, std.meta.fields(@TypeOf(config.type_parsers))[parser_idx].name);
                                        break :blk global_parser(input_str) catch |err| {
                                            try ctx.err.print("\nError: Invalid format for flag '--{s}'.\n", .{field.name});
                                            return err;
                                        };
                                    } else blk: {
                                        break :blk parseValue(field.type, input_str) catch |err| {
                                            try ctx.err.print("\nError: Invalid value '{s}' for flag '--{s}'.\n", .{ maskIfSecret(isSecretFlag(OrigFlagsT, field.name), input_str), field.name });
                                            return err;
                                        };
                                    };
                                @field(parsed_flags, field.name) = parsed_missing_val;
                                provided[idx] = true;
                                resolved[idx] = true;
                            } else {
                                return error.UserCancelled;
                            }
                        } else {
                            const stderr = ctx.err;
                            try stderr.print("Error: Missing required flag '--{s}'.\n", .{field.name});
                            return error.MissingRequiredFlag;
                        }
                    }
                }
            }

            if (comptime has_pos_lower or has_pos_upper) {
                const pos_field_name = if (has_pos_lower) "positionals" else "Positional";
                const PosType = @TypeOf(@field(parsed_flags, pos_field_name));
                const pos_fields = std.meta.fields(PosType);

                inline for (pos_fields, 0..) |p_field, p_i| {
                    if (pos_count.* <= p_i) {
                        if (p_field.default_value_ptr == null and @typeInfo(p_field.type) != .optional) {
                            if (ctx.is_tty) {
                                try ctx.out.print("? {s} (positional): ", .{p_field.name});
                                if (ctx.in.takeDelimiter('\n') catch null) |read_str| {
                                    const input_str = std.mem.trim(u8, read_str, " \r\n\t");
                                    if (input_str.len == 0) {
                                        try ctx.err.print("\nError: Missing required positional argument '{s}'.\n", .{p_field.name});
                                        return error.MissingRequiredPositionalArgument;
                                    }
                                    const parsed_pos_val =
                                        if (comptime @hasDecl(OrigFlagsT, "parse") and @hasField(@TypeOf(OrigFlagsT.parse), p_field.name)) blk: {
                                            const custom_parser = @field(OrigFlagsT.parse, p_field.name);
                                            break :blk custom_parser(input_str) catch |err| {
                                                try ctx.err.print("\nError: Invalid format for positional argument '{s}'.\n", .{p_field.name});
                                                return err;
                                            };
                                        } else if (comptime getGlobalParserIndex(p_field.type)) |parser_idx| blk: {
                                            const global_parser = @field(config.type_parsers, std.meta.fields(@TypeOf(config.type_parsers))[parser_idx].name);
                                            break :blk global_parser(input_str) catch |err| {
                                                try ctx.err.print("\nError: Invalid format for positional argument '{s}'.\n", .{p_field.name});
                                                return err;
                                            };
                                        } else blk: {
                                            break :blk parseValue(p_field.type, input_str) catch |err| {
                                                try ctx.err.print("\nError: Invalid value '{s}' for positional argument '{s}'.\n", .{ maskIfSecret(isSecretPositional(OrigFlagsT, pos_field_name, p_field.name), input_str), p_field.name });
                                                return err;
                                            };
                                        };
                                    @field(@field(parsed_flags, pos_field_name), p_field.name) = parsed_pos_val;
                                    // `pos_count` is **not** incremented here.
                                    //
                                    // It counts positionals that came from argv, and the
                                    // pass below reads `pos_buf[0..pos_count]`. Counting a
                                    // prompted value made that pass read a slot nothing had
                                    // written - and `pos_buf` is sized by argv, so with no
                                    // arguments at all the read was past its end. The value
                                    // is already assigned above and the fill pass leaves
                                    // fields at or beyond `pos_count` alone.
                                } else {
                                    return error.UserCancelled;
                                }
                            } else {
                                try ctx.err.print("Error: Missing required positional argument '{s}'.\n", .{p_field.name});
                                return error.MissingRequiredPositionalArgument;
                            }
                        }
                    }
                }
            }

            // 3.5. Environment-variable binding, mutual exclusion and co-requisites.
            //
            // Env binding applies only where the command line said nothing: an explicit flag
            // must beat the environment, or a user could not override the shell they are in.
            // This runs after the args loop, so "said nothing" is exactly `!provided[idx]`.
            //
            // conflicts_with/requires are checked against what the command line *provided*,
            // not against resulting values: a flag set from the environment was never asked
            // for by the user and so cannot conflict with anything.
            //
            // The guards are nested positive `if (comptime …)` rather than `continue` with a
            // comptime condition. A comptime `continue` is rejected with "comptime control
            // flow inside runtime block" - measured four times in this file - so the shape
            // that works is to nest, and to leave only genuinely runtime conditions as
            // early `continue`.
            if (comptime @hasDecl(OrigFlagsT, "meta")) {
                const meta_block = OrigFlagsT.meta;
                inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                    if (comptime field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_') {
                        // framework-internal field
                    } else if (comptime isPositionalField(field.name)) {
                        // positionals carry no flag metadata
                    } else if (comptime @hasField(@TypeOf(meta_block), field.name)) {
                        const field_meta = @field(meta_block, field.name);

                        // Environment and file resolution happen above, in step 3: they
                        // must precede the missing-required check, so they cannot live
                        // here. What remains here is the pair of rules defined over what
                        // the *command line* asked for.

                        // -- conflicts_with / requires, only for flags actually provided
                        if (provided[idx]) {
                            if (comptime @hasField(@TypeOf(field_meta), "conflicts_with")) {
                                inline for (field_meta.conflicts_with) |other_name| {
                                    inline for (std.meta.fields(FlagsType), 0..) |other, other_idx| {
                                        if (comptime std.mem.eql(u8, other.name, other_name)) {
                                            if (provided[other_idx]) {
                                                try ctx.err.print("Error: Flag '--{s}' conflicts with '--{s}'.\n", .{ field.name, other.name });
                                                return error.ConflictingFlags;
                                            }
                                        }
                                    }
                                }
                            }
                            if (comptime @hasField(@TypeOf(field_meta), "requires")) {
                                inline for (field_meta.requires) |other_name| {
                                    inline for (std.meta.fields(FlagsType), 0..) |other, other_idx| {
                                        if (comptime std.mem.eql(u8, other.name, other_name)) {
                                            if (!provided[other_idx]) {
                                                try ctx.err.print("Error: Flag '--{s}' requires '--{s}'.\n", .{ field.name, other.name });
                                                return error.DependentFlagMissing;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // 4. Advanced Comptime Validation
            if (@hasDecl(OrigFlagsT, "validation")) {
                const rules = OrigFlagsT.validation;
                inline for (std.meta.fields(FlagsType)) |field| {
                    if (@hasField(@TypeOf(rules), field.name)) {
                        const rule = @field(rules, field.name);
                        const val = @field(parsed_flags, field.name);

                        if (@hasField(@TypeOf(rule), "min")) {
                            if (val < rule.min) {
                                try ctx.err.print("Error: Flag '--{s}' value {} is less than minimum {}.\n", .{ field.name, val, rule.min });
                                return error.ValidationFailed;
                            }
                        }
                        if (@hasField(@TypeOf(rule), "max")) {
                            if (val > rule.max) {
                                try ctx.err.print("Error: Flag '--{s}' value {} is greater than maximum {}.\n", .{ field.name, val, rule.max });
                                return error.ValidationFailed;
                            }
                        }
                        if (@hasField(@TypeOf(rule), "len_min")) {
                            if (val.len < rule.len_min) {
                                try ctx.err.print("Error: Flag '--{s}' length {} is less than minimum {}.\n", .{ field.name, val.len, rule.len_min });
                                return error.ValidationFailed;
                            }
                        }
                        if (@hasField(@TypeOf(rule), "len_max")) {
                            if (val.len > rule.len_max) {
                                try ctx.err.print("Error: Flag '--{s}' length {} is greater than maximum {}.\n", .{ field.name, val.len, rule.len_max });
                                return error.ValidationFailed;
                            }
                        }
                        if (@hasField(@TypeOf(rule), "in")) {
                            // Coerced to a slice explicitly: `rule.in` is a comptime
                            // pointer-to-array, and iterating it directly is a compile
                            // error. This block had never been instantiated before the
                            // declaration lookup was fixed, so nothing had ever compiled
                            // it.
                            const allowed_values: []const []const u8 = rule.in;
                            var found = false;
                            for (allowed_values) |allowed| {
                                if (std.mem.eql(u8, val, allowed)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                try ctx.err.print("Error: Flag '--{s}' value '{s}' is not in allowed list.\n", .{ field.name, val });
                                return error.ValidationFailed;
                            }
                        }
                    }
                }
            }

            if (comptime has_pos_lower or has_pos_upper) {
                const pos_field_name = if (has_pos_lower) "positionals" else "Positional";
                const PosType = @TypeOf(@field(parsed_flags, pos_field_name));
                const pos_fields = std.meta.fields(PosType);

                const is_variadic = pos_fields.len > 0 and pos_fields[pos_fields.len - 1].type == []const []const u8;

                if (!is_variadic and pos_count.* > pos_fields.len) {
                    try ctx.err.print("Error: Too many positional arguments.\n", .{});
                    return error.TooManyPositionalArguments;
                }

                inline for (pos_fields, 0..) |p_field, p_i| {
                    if (is_variadic and p_i == pos_fields.len - 1) {
                        if (pos_count.* >= p_i) {
                            // `alloc`, not `ctx.allocator`: this slice is the command's
                            // for exactly as long as it runs, and the arena the caller
                            // created owns it. The previous shape allocated it from the
                            // process allocator and never freed it - a leak that no test
                            // caught because no test used a variadic positional.
                            var var_list: std.ArrayListUnmanaged([]const u8) = .empty;
                            for (pos_buf[p_i..pos_count.*]) |v_arg| {
                                try var_list.append(alloc, v_arg);
                            }
                            @field(@field(parsed_flags, pos_field_name), p_field.name) =
                                try var_list.toOwnedSlice(alloc);
                        } else {
                            @field(@field(parsed_flags, pos_field_name), p_field.name) = &.{};
                        }
                    } else {
                        if (p_i < pos_count.*) {
                            const arg = pos_buf[p_i];
                            const parsed_pos_val =
                                if (comptime @hasDecl(OrigFlagsT, "parse") and @hasField(@TypeOf(OrigFlagsT.parse), p_field.name)) blk: {
                                    const custom_parser = @field(OrigFlagsT.parse, p_field.name);
                                    break :blk custom_parser(arg) catch |err| {
                                        try ctx.err.print("Error: Invalid format for positional argument '{s}'.\n", .{p_field.name});
                                        return err;
                                    };
                                } else if (comptime getGlobalParserIndex(p_field.type)) |parser_idx| blk: {
                                    const global_parser = @field(config.type_parsers, std.meta.fields(@TypeOf(config.type_parsers))[parser_idx].name);
                                    break :blk global_parser(arg) catch |err| {
                                        try ctx.err.print("Error: Invalid format for positional argument '{s}'.\n", .{p_field.name});
                                        return err;
                                    };
                                } else blk: {
                                    break :blk parseValue(p_field.type, arg) catch |err| {
                                        try ctx.err.print("Error: Invalid value '{s}' for positional argument '{s}'.\n", .{ maskIfSecret(isSecretPositional(OrigFlagsT, pos_field_name, p_field.name), arg), p_field.name });
                                        return err;
                                    };
                                };
                            @field(@field(parsed_flags, pos_field_name), p_field.name) = parsed_pos_val;
                        }
                    }
                }
            }

            // 5. Repeatable fields: type the collected text now, once per field.
            //
            // Collected raw during the args loop, because a field's element type is
            // only known inside an `inline for` over the fields; parsed here so every
            // element goes through the same custom-parser chain a scalar flag uses.
            inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                if (comptime isRepeatableField(field.type)) {
                    if (repeat_values[idx].items.len > 0) {
                        const ElementT = repeatableElement(field.type);
                        const collected = try alloc.alloc(ElementT, repeat_values[idx].items.len);
                        for (repeat_values[idx].items, 0..) |raw_value, element_idx| {
                            collected[element_idx] = parseTextAs(OrigFlagsT, ElementT, field.name, raw_value) catch {
                                try ctx.err.print("Error: Invalid value '{s}' for flag '--{s}'.\n", .{ maskIfSecret(isSecretFlag(OrigFlagsT, field.name), raw_value), field.name });
                                return error.InvalidFlagValue;
                            };
                        }
                        @field(parsed_flags, field.name) = collected;
                    } else if (field.default_value_ptr == null) {
                        // Never given, and no default: an empty list rather than an
                        // undefined value the command would read as garbage.
                        @field(parsed_flags, field.name) = &.{};
                    }
                }
            }

            return parsed_flags;
        }

        /// Parses one piece of text as `T`, through the chain every path shares:
        /// the field's own `parse` declaration, then a configured global parser, then
        /// the built-in coercions.
        ///
        /// The custom parser is looked up on `OrigFlagsT` - the type the author
        /// declared - and not on the parsed flags type. That one is synthesized by
        /// `MergeFlags`, which copies fields and **no declarations**, so a `parse` decl
        /// was invisible from here and every custom parser silently fell through to
        /// `parseValue`.
        fn parseTextAs(
            comptime OrigFlagsT: type,
            comptime T: type,
            comptime name: []const u8,
            text: []const u8,
        ) !T {
            if (comptime @hasDecl(OrigFlagsT, "parse") and @hasField(@TypeOf(OrigFlagsT.parse), name)) {
                const custom_parser = @field(OrigFlagsT.parse, name);
                return custom_parser(text);
            }
            if (comptime getGlobalParserIndex(T)) |parser_idx| {
                const global_parser = @field(config.type_parsers, std.meta.fields(@TypeOf(config.type_parsers))[parser_idx].name);
                return global_parser(text);
            }
            return parseValue(T, text);
        }

        /// Splits one piece of text into the elements of a repeatable field.
        ///
        /// A comma-separated list because that is the only shape one environment
        /// variable can carry; empty pieces are skipped so `A=,b` means one element.
        fn appendRepeatedText(
            list: *std.ArrayListUnmanaged([]const u8),
            text: []const u8,
            alloc: std.mem.Allocator,
        ) !void {
            var it = std.mem.splitScalar(u8, text, ',');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len == 0) continue;
                try list.append(alloc, trimmed);
            }
        }

        /// Applies one textual value from a lower-precedence source to a field.
        ///
        /// Shared by the environment and config-file layers, which differ only in where
        /// the text came from and therefore in what the error should say.
        fn applyTextValue(
            comptime OrigFlagsT: type,
            comptime FlagsType: type,
            comptime field: std.builtin.Type.StructField,
            parsed_flags: *FlagsType,
            repeat_values: []std.ArrayListUnmanaged([]const u8),
            idx: usize,
            text: []const u8,
            source: []const u8,
            ctx: anytype,
            alloc: std.mem.Allocator,
        ) !void {
            if (comptime isRepeatableField(field.type)) {
                try appendRepeatedText(&repeat_values[idx], text, alloc);
                return;
            }
            @field(parsed_flags, field.name) = parseTextAs(OrigFlagsT, field.type, field.name, text) catch |err| {
                try ctx.err.print("Error: Invalid value '{s}' from {s} for '--{s}'.\n", .{ maskIfSecret(isSecretFlag(OrigFlagsT, field.name), text), source, field.name });
                return err;
            };
        }

        /// Whether a field carries any metadata of its own.
        fn hasMetaField(comptime OrigFlagsT: type, comptime name: []const u8) bool {
            return @hasDecl(OrigFlagsT, "meta") and @hasField(@TypeOf(OrigFlagsT.meta), name);
        }

        /// Applies the environment and config-file layers to one field, in that order.
        ///
        /// A field needs **no** metadata to be settable from a file: the key is the
        /// field's own name unless `meta.<field>.config` renames it, so a config file
        /// can supply defaults for any flag rather than only the annotated ones. The
        /// environment does need metadata, because the variable's name has to come from
        /// somewhere.
        fn resolveFieldFromLayers(
            comptime OrigFlagsT: type,
            comptime FlagsType: type,
            comptime field: std.builtin.Type.StructField,
            idx: usize,
            parsed_flags: *FlagsType,
            repeat_values: []std.ArrayListUnmanaged([]const u8),
            resolved: []bool,
            file_values: ?std.StringHashMapUnmanaged([]const u8),
            ctx: anytype,
            alloc: std.mem.Allocator,
        ) !void {
            if (comptime !isTextSourceable(OrigFlagsT, field.type, field.name)) {
                // A field whose type has no textual spelling cannot come from a text
                // source. That is fine for the file layer - the file simply has no key
                // that means anything - but an `env` binding is a *declared* intent, and
                // silently doing nothing with it would be the same class of bug as the
                // undeclared parser this file already fixed.
                if (comptime hasMetaField(OrigFlagsT, field.name) and
                    @hasField(@TypeOf(@field(OrigFlagsT.meta, field.name)), "env"))
                {
                    @compileError("flag '" ++ field.name ++ "' declares an `env` binding, but its type has no textual spelling: add a `parse` declaration for it");
                }
                return;
            }

            // A flag behind a closed feature gate does not exist, so neither the
            // environment nor a config file may set it - otherwise an experimental flag
            // would be silently live for anyone whose environment happened to carry the
            // variable the layer looks for.
            if (!fieldIsAvailable(ctx, OrigFlagsT, field.name)) return;

            if (comptime hasMetaField(OrigFlagsT, field.name)) {
                const field_meta = @field(OrigFlagsT.meta, field.name);
                if (comptime @hasField(@TypeOf(field_meta), "env")) {
                    if (!resolved[idx] and field_meta.env.len > 0) {
                        if (ctx.env_map.get(field_meta.env)) |env_text| {
                            var source_buf: [128]u8 = undefined;
                            const source = std.fmt.bufPrint(&source_buf, "${s}", .{field_meta.env}) catch "$ENV";
                            try applyTextValue(
                                OrigFlagsT,
                                FlagsType,
                                field,
                                parsed_flags,
                                repeat_values,
                                idx,
                                env_text,
                                source,
                                ctx,
                                alloc,
                            );
                            resolved[idx] = true;
                        }
                    }
                }
            }

            if (file_values) |values| {
                if (!resolved[idx]) {
                    // `config` is `anytype`, so a config literal without a file layer is
                    // the common case and the file's settings are only read when there
                    // is one.
                    if (comptime @hasField(@TypeOf(config), "config_file")) {
                        if (config.config_file.path.len > 0) {
                            // `prefix` is optional too: a config literal that names only
                            // a path reads unprefixed keys.
                            const prefix: []const u8 = if (comptime @hasField(
                                @TypeOf(config.config_file),
                                "prefix",
                            )) config.config_file.prefix else "";
                            var key_buf: [256]u8 = undefined;
                            if (configKeyFor(field.name, OrigFlagsT, prefix, &key_buf)) |key| {
                                if (values.get(key)) |file_text| {
                                    try applyTextValue(
                                        OrigFlagsT,
                                        FlagsType,
                                        field,
                                        parsed_flags,
                                        repeat_values,
                                        idx,
                                        file_text,
                                        "the config file",
                                        ctx,
                                        alloc,
                                    );
                                    resolved[idx] = true;
                                }
                            }
                        }
                    }
                }
            }
        }

        /// The key a field is looked up under in a config file.
        ///
        /// Its own name, or `meta.<field>.config` when the file spells it differently,
        /// with the configured prefix in front. Null means "the key does not fit the
        /// caller's buffer", which is a no-value answer rather than a truncation that
        /// might silently match a shorter key.
        fn configKeyFor(
            comptime name: []const u8,
            comptime OrigFlagsT: type,
            prefix: []const u8,
            buf: []u8,
        ) ?[]const u8 {
            const key = if (comptime hasMetaField(OrigFlagsT, name) and
                @hasField(@TypeOf(@field(OrigFlagsT.meta, name)), "config"))
                @field(OrigFlagsT.meta, name).config
            else
                name;
            if (prefix.len == 0) {
                if (key.len > buf.len) return null;
                @memcpy(buf[0..key.len], key);
                return buf[0..key.len];
            }
            return std.fmt.bufPrint(buf, "{s}.{s}", .{ prefix, key }) catch null;
        }

        /// Whether a field declares a per-field custom parser.
        fn hasCustomParser(comptime OrigFlagsT: type, comptime name: []const u8) bool {
            return @hasDecl(OrigFlagsT, "parse") and @hasField(@TypeOf(OrigFlagsT.parse), name);
        }

        /// Whether a value of `T` can be produced from one piece of text.
        ///
        /// The environment and config-file layers are *text* sources, so a field whose
        /// type has no textual spelling simply has no value there - a struct-typed flag
        /// is set by its own flags, not by a file key. This is what keeps the two layers
        /// from instantiating a coercion that does not exist for every field of every
        /// command, whether or not that command has a file.
        fn isTextParsable(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .int, .float, .bool, .@"enum" => true,
                .pointer => |ptr| ptr.size == .slice and
                    (ptr.child == u8 or isTextParsable(ptr.child)),
                .optional => |opt| isTextParsable(opt.child),
                else => false,
            };
        }

        /// Whether a text source can supply a value for this field: a custom parser, a
        /// configured global parser, or the built-in coercions.
        fn isTextSourceable(comptime OrigFlagsT: type, comptime T: type, comptime name: []const u8) bool {
            if (comptime hasCustomParser(OrigFlagsT, name)) return true;
            if (comptime getGlobalParserIndex(T) != null) return true;
            return isTextParsable(T);
        }

        fn getGlobalParserIndex(comptime T: type) ?usize {
            if (!@hasField(@TypeOf(config), "type_parsers")) return null;

            const parsers = config.type_parsers;
            const TupleType = @TypeOf(parsers);
            const fields = std.meta.fields(TupleType);

            inline for (fields, 0..) |f, i| {
                const func = @field(parsers, f.name);
                const fn_info = @typeInfo(@TypeOf(func)).@"fn";
                const RetT = fn_info.return_type.?;

                var is_match = false;
                if (RetT == T) {
                    is_match = true;
                } else if (@typeInfo(RetT) == .error_union and @typeInfo(RetT).error_union.payload == T) {
                    is_match = true;
                }

                if (is_match) return i;
            }

            return null;
        }

        /// Assigns one occurrence of one flag.
        ///
        /// Returns whether this occurrence took a value, which is what lets a short
        /// cluster stop being parsed as flags once one of them has: `-tvalue` is
        /// `-t value`, not `-t -v -a -l -u -e`.
        fn assignFlag(
            comptime OrigFlagsT: type,
            comptime FlagsType: type,
            parsed_flags: *FlagsType,
            provided: []bool,
            resolved: []bool,
            repeat_values: []std.ArrayListUnmanaged([]const u8),
            key: []const u8,
            val: ?[]const u8,
            args: []const []const u8,
            i: *usize,
            ctx: anytype,
            alloc: std.mem.Allocator,
        ) !bool {
            const stderr = ctx.err;
            var found = false;
            var took_value = false;

            inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                if (comptime (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) continue;
                if (comptime isPositionalField(field.name)) continue;

                // A flag behind a closed feature gate does not exist, so it is not
                // matched and the caller gets the ordinary `UnknownFlag` - which is what
                // "hidden unless the variable is set" has to mean at the parser, or the
                // flag is discoverable by trying it. The `available` local also has to
                // gate the `--no-` and short-flag paths below, which set `is_match`
                // themselves.
                const available = fieldIsAvailable(ctx, OrigFlagsT, field.name);
                var is_match = available and flagNamesEqual(field.name, key);

                // `--no-<flag>` clears a boolean.
                //
                // Only booleans: "no" is a claim about truth, and offering it for a value
                // flag would have to invent a meaning for `--no-token`. The prefix is
                // matched before the short-flag branch because `no-foo` is never a short
                // flag, and after the exact match so a field genuinely named `no_foo` still
                // wins for its own name.
                var is_negation = false;
                if (!is_match and std.mem.startsWith(u8, key, "no-") and key.len > 3) {
                    if (flagNamesEqual(field.name, key[3..])) {
                        const is_bool = field.type == bool or
                            (@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool);
                        if (is_bool) {
                            is_match = true;
                            is_negation = true;
                        }
                    }
                }

                if (!is_match and key.len == 1) {
                    if (@hasDecl(OrigFlagsT, "meta")) {
                        const meta_block = OrigFlagsT.meta;
                        if (@hasField(@TypeOf(meta_block), field.name)) {
                            const field_meta = @field(meta_block, field.name);
                            if (@hasField(@TypeOf(field_meta), "short")) {
                                if (key[0] == field_meta.short) {
                                    is_match = true;
                                }
                            }
                        }
                    }
                }

                // `available` is re-checked here because the `--no-<flag>` and short-flag
                // branches above set `is_match` on their own: without this, a gated flag
                // would be reachable through `-x` or `--no-x` while `--x` was refused.
                if (is_match and available) {
                    found = true;
                    provided[idx] = true;
                    resolved[idx] = true;

                    // A deprecated flag warns but still works. Refusing it would break
                    // every script that has not migrated yet, which is the opposite of what
                    // a deprecation is for - the warning is the migration path.
                    if (comptime isDeprecatedFlag(OrigFlagsT, field.name)) {
                        const note = @field(OrigFlagsT.meta, field.name).deprecated;
                        try stderr.print("Warning: Flag '--{s}' is deprecated: {s}\n", .{ field.name, note });
                    }

                    // A `.count = true` flag accumulates instead of setting.
                    //
                    // This is what makes `-vvv` mean "three" rather than "true": the short
                    // branch calls this once per character, so incrementing here is the
                    // whole implementation. The field is a number and its declared default
                    // is the starting point, which is why a `u8 = 0` counts from zero
                    // without any reset step.
                    //
                    // No `continue`: it would have to cross the runtime `if (is_match)`
                    // above, and Zig rejects a comptime `continue` under a runtime block
                    // ("comptime control flow inside runtime block", measured twice). The
                    // `else if` chain already makes this branch exclusive, and the enclosing
                    // `inline for` advances to the next field either way.
                    if (comptime isCountFlag(OrigFlagsT, field.name)) {
                        @field(parsed_flags, field.name) += 1;
                    } else if (field.type == bool) {
                        @field(parsed_flags, field.name) = !is_negation;
                    } else if (@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool) {
                        @field(parsed_flags, field.name) = !is_negation;
                    } else {
                        var actual_val = val;
                        if (actual_val == null) {
                            if (i.* + 1 < args.len) {
                                i.* += 1;
                                actual_val = args[i.*];
                            } else {
                                try stderr.print("Error: Flag '--{s}' requires a value.\n", .{field.name});
                                return error.MissingFlagValue;
                            }
                        }
                        took_value = true;

                        // A repeatable field collects every occurrence instead of
                        // replacing its value. The text is stored raw and typed once at
                        // the end of `parseFlags`, where the element type is known.
                        if (comptime isRepeatableField(field.type)) {
                            try repeat_values[idx].append(alloc, actual_val.?);
                        } else {
                            const parsed_value = parseTextAs(OrigFlagsT, field.type, field.name, actual_val.?) catch |err| {
                                if (err == error.InvalidCharacter or err == error.InvalidEnumValue) {
                                    try stderr.print("Error: Invalid value '{s}' for flag '--{s}'.\n", .{ maskIfSecret(isSecretFlag(OrigFlagsT, field.name), actual_val.?), field.name });
                                    return error.HandledError;
                                }
                                if (comptime @hasDecl(OrigFlagsT, "parse") and @hasField(@TypeOf(OrigFlagsT.parse), field.name)) {
                                    try stderr.print("Error: Invalid format for flag '--{s}'.\n", .{field.name});
                                }
                                return err;
                            };
                            @field(parsed_flags, field.name) = parsed_value;
                        }
                    }
                }
            }
            if (!found) {
                try stderr.print("Error: Unknown flag '{s}'.\n", .{key});
                // The same courtesy the router extends to a mistyped subcommand. A flag
                // was the one place a typo produced no hint at all.
                if (nearestFlag(OrigFlagsT, FlagsType, ctx, key)) |suggestion| {
                    try stderr.writeAll("Did you mean '--");
                    try writeFlagSpelling(stderr, suggestion);
                    try stderr.writeAll("'?\n");
                }
                return error.UnknownFlag;
            }
            return took_value;
        }

        fn parseValue(comptime T: type, val: []const u8) !T {
            switch (@typeInfo(T)) {
                .int => {
                    return std.fmt.parseInt(T, val, 10);
                },
                .float => {
                    return std.fmt.parseFloat(T, val);
                },
                .bool => {
                    // A boolean has no `parseValue` arm before this one, which made a
                    // `bool` flag impossible to set from the environment or a config
                    // file - the two places the value arrives as text. Accepts the
                    // spellings people write, and refuses anything else rather than
                    // inventing a truth value for `maybe`.
                    if (std.ascii.eqlIgnoreCase(val, "true") or std.mem.eql(u8, val, "1")) return true;
                    if (std.ascii.eqlIgnoreCase(val, "false") or std.mem.eql(u8, val, "0")) return false;
                    if (std.ascii.eqlIgnoreCase(val, "yes")) return true;
                    if (std.ascii.eqlIgnoreCase(val, "no")) return false;
                    return error.InvalidBool;
                },
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) {
                        return val; // Zero-copy string slice
                    }
                    @compileError("Unsupported pointer type for flag");
                },
                .@"enum" => {
                    return std.meta.stringToEnum(T, val) orelse return error.InvalidEnumValue;
                },
                .optional => |opt| {
                    // Wrapped in the optional rather than returned bare: `parseValue`
                    // returns `!T` for the wrapper type here, and a bare `!opt.child`
                    // cannot coerce into it. `opt.child` is a *value*, so the cast is
                    // written through `T` rather than naming the child type.
                    const inner = try parseValue(opt.child, val);
                    return @as(T, inner);
                },
                else => {
                    @compileError("Unsupported type for CLI argument: " ++ @typeName(T));
                },
            }
        }

        /// Emits the bash completion script.
        ///
        /// Fragments rather than a format string: a shell script is mostly `${…}` and
        /// `$(…)`, both of which `Writer.print` parses as format syntax. Getting the escaping
        /// wrong yields "N unused arguments in <the entire template>", which names the whole
        /// script instead of the offending character - measured four times before switching
        /// approach.
        fn emitBashCompletions(writer: anytype, prog: []const u8) !void {
            try writer.writeAll("_");
            try writer.writeAll(prog);
            try writer.writeAll("_completions() {\n  local cur=\"${COMP_WORDS[COMP_CWORD]}\"\n  local opts=\"$(");
            try writer.writeAll(prog);
            try writer.writeAll(" __complete \"${COMP_WORDS[@]:1}\")\"\n  COMPREPLY=( $(compgen -W \"$opts\" -- \"$cur\") )\n}\ncomplete -F _");
            try writer.writeAll(prog);
            try writer.writeAll("_completions ");
            try writer.writeAll(prog);
            try writer.writeAll("\n");
        }

        /// Emits the zsh completion script.
        fn emitZshCompletions(writer: anytype, prog: []const u8) !void {
            try writer.writeAll("#compdef ");
            try writer.writeAll(prog);
            try writer.writeAll("\n_");
            try writer.writeAll(prog);
            try writer.writeAll("() {\n  local matches=($(");
            try writer.writeAll(prog);
            try writer.writeAll(" __complete \"${words[@]:1}\"))\n  compadd -a matches\n}\ncompdef _");
            try writer.writeAll(prog);
            try writer.writeAll(" ");
            try writer.writeAll(prog);
            try writer.writeAll("\n");
        }

        /// Emits the fish completion script.
        fn emitFishCompletions(writer: anytype, prog: []const u8) !void {
            try writer.writeAll("function __fish_");
            try writer.writeAll(prog);
            try writer.writeAll("_complete\n  ");
            try writer.writeAll(prog);
            try writer.writeAll(" __complete (commandline -opc)[2..-1]\nend\ncomplete -c ");
            try writer.writeAll(prog);
            try writer.writeAll(" -f -a '(__fish_");
            try writer.writeAll(prog);
            try writer.writeAll("_complete)'\n");
        }

        /// Emits the PowerShell completion script.
        ///
        /// Written with `writeAll` fragments rather than one format string. A PowerShell
        /// script is mostly `$` and `{}`, and `Writer.print` treats both specially - so a
        /// format string needs `$$` and `{{`, and getting one wrong yields "unused argument
        /// in <the whole template>", which is a poor error for a poor approach. Fragments
        /// have no escaping to get wrong.
        fn emitPowershellCompletions(writer: anytype, prog: []const u8) !void {
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
        fn writeManPage(comptime cmd: anytype, writer: anytype) !void {
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
        fn writeCommandMarkers(comptime CmdT: type, cmd: CmdT, writer: anytype) !void {
            if (comptime @hasField(CmdT, "deprecated")) {
                if (cmd.deprecated.len > 0) try writer.print(" (deprecated: {s})", .{cmd.deprecated});
            }
            if (comptime @hasField(CmdT, "feature")) {
                if (cmd.feature.len > 0) try writer.print(" (experimental: set {s})", .{cmd.feature});
            }
        }

        /// The same, for a flag.
        fn writeFlagMarkers(comptime OrigFlagsT: type, comptime name: []const u8, writer: anytype) !void {
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
        fn writeHtmlEscaped(writer: anytype, text: []const u8) !void {
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
        fn isAdvertisableHtml(comptime CmdT: type, cmd: CmdT) bool {
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
        fn writeHtmlCommand(comptime cmd: anytype, writer: anytype, level: usize) !void {
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
                                try writer.writeAll(log.redaction_mask);
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
        fn writeManSubtree(comptime cmd: anytype, writer: anytype) !void {
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
        const ManLevel = enum { top, nested };

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
        fn writeManSections(comptime cmd: anytype, writer: anytype, comptime level: ManLevel) !void {
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
                                try writer.print("(default: {s})\n", .{log.redaction_mask});
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
        fn isFrameworkField(comptime name: []const u8) bool {
            return name.len >= 2 and name[0] == '_' and name[1] == '_';
        }

        /// Whether a flag needs a value on the command line.
        fn fieldTakesValue(comptime T: type) bool {
            if (T == bool) return false;
            if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == bool) return false;
            return true;
        }

        /// Whether a field carries a documented short form.
        fn hasShortFlag(comptime OrigFlagsT: type, comptime name: []const u8) bool {
            if (!@hasDecl(OrigFlagsT, "meta")) return false;
            if (!@hasField(@TypeOf(OrigFlagsT.meta), name)) return false;
            return @hasField(@TypeOf(@field(OrigFlagsT.meta, name)), "short");
        }

        /// The type of a command's positional-argument struct, however it declared one.
        fn PositionalType(comptime CmdType: type) type {
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
        fn positionalHelp(comptime ArgsT: type, comptime OrigFlagsT: type, comptime name: []const u8) ?[]const u8 {
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
            // (`meta.positionals.description`), which is what every `app/cfg` command
            // does. It is only unambiguous when there is one positional argument, so
            // that is the only case it is used for.
            if (comptime std.meta.fields(ArgsT).len == 1) {
                if (@hasField(@TypeOf(slot_meta), "help")) return slot_meta.help;
                if (@hasField(@TypeOf(slot_meta), "description")) return slot_meta.description;
            }
            return null;
        }

        /// The width of the "Commands:" left column, including the two-space indent so
        /// a row's own accounting and the column agree.
        fn commandColumnWidth(comptime cmd: anytype) usize {
            const CmdType = @TypeOf(cmd);
            comptime var width: usize = 0;
            if (comptime hasSubcommands(CmdType)) {
                inline for (getSubcommands(cmd)) |sub| {
                    if (comptime !isHidden(@TypeOf(sub), sub)) {
                        var w: usize = 2 + sub.name.len;
                        if (comptime @hasField(@TypeOf(sub), "aliases")) {
                            for (sub.aliases) |alias_name| w += alias_name.len + 2;
                            if (sub.aliases.len > 0) w += 1;
                        }
                        width = @max(width, w);
                    }
                }
            }
            return width;
        }

        /// The width of the "Flags:" left column, including the two-space indent.
        fn flagColumnWidth(comptime OrigFlagsT: type, comptime FlagsType: type) usize {
            comptime var width: usize = 0;
            inline for (std.meta.fields(FlagsType)) |field| {
                if (comptime !isFrameworkField(field.name) and
                    !isPositionalField(field.name) and
                    !isDeprecatedFlag(OrigFlagsT, field.name))
                {
                    var w: usize = 2 + field.name.len;
                    if (comptime hasShortFlag(OrigFlagsT, field.name)) w += 4;
                    if (comptime fieldTakesValue(field.type)) w += 8;
                    width = @max(width, w);
                }
            }
            return width;
        }

        /// The width of the "Arguments:" left column, including the two-space indent.
        fn argumentColumnWidth(comptime ArgsT: type) usize {
            comptime var width: usize = 0;
            inline for (std.meta.fields(ArgsT)) |p_field| {
                width = @max(width, 2 + p_field.name.len);
            }
            return width;
        }

        /// Pads to the column (plus a two-space gutter), then the description.
        ///
        /// The pad is clamped rather than assumed: a width miscalculation should give a
        /// narrow column, not an integer underflow.
        fn writeHelpRow(writer: anytype, used: usize, column: usize, text: []const u8) !void {
            const target = column + 2;
            var pad = if (target > used) target - used else 0;
            while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
            try writer.writeAll(text);
            try writer.writeByte('\n');
        }

        /// The "Commands:" section, with aliases, without hidden commands, and with the
        /// same feature/deprecation filtering the router uses.
        fn printCommandList(comptime cmd: anytype, ctx: anytype, writer: anytype) !void {
            const CmdType = @TypeOf(cmd);
            if (comptime hasAnySubcommands(CmdType)) {
                const column = comptime commandColumnWidth(cmd);
                try writer.writeAll("\nCommands:\n");
                inline for (getSubcommands(cmd)) |sub| {
                    // `isAdvertisable` is the one place hidden, deprecated and
                    // gate-closed commands are filtered, so `--help` and the completion
                    // list cannot disagree about what exists.
                    if (isAdvertisable(ctx, @TypeOf(sub), sub)) {
                        try writer.writeAll("  ");
                        try writer.writeAll(sub.name);
                        var used: usize = 2 + sub.name.len;
                        if (@hasField(@TypeOf(sub), "aliases")) {
                            for (sub.aliases, 0..) |alias_name, alias_idx| {
                                try writer.writeAll(if (alias_idx == 0) " (" else ", ");
                                try writer.writeAll(alias_name);
                                used += alias_name.len + 2;
                            }
                            if (sub.aliases.len > 0) {
                                try writer.writeAll(")");
                                used += 1;
                            }
                        }
                        try writeHelpRow(writer, used, column, sub.description);
                    }
                }
            }
        }

        /// The "Arguments:" section. Positional arguments were never printed at all,
        /// so the only way to learn that `<component>` existed was to run without it and
        /// be told it was missing.
        fn printArgumentList(comptime cmd: anytype, writer: anytype, orig_flags: type) !void {
            const ArgsT = PositionalType(@TypeOf(cmd));
            const fields = std.meta.fields(ArgsT);
            if (comptime fields.len == 0) return;

            const column = comptime argumentColumnWidth(ArgsT);
            try writer.writeAll("\nArguments:\n");
            inline for (fields) |p_field| {
                try writer.writeAll("  ");
                try writer.writeAll(p_field.name);
                const used: usize = 2 + p_field.name.len;

                var row_buf: [512]u8 = undefined;
                var row_len: usize = 0;
                if (comptime positionalHelp(ArgsT, orig_flags, p_field.name)) |text| {
                    if (text.len <= row_buf.len) {
                        @memcpy(row_buf[0..text.len], text);
                        row_len = text.len;
                    }
                }
                const required = comptime p_field.default_value_ptr == null and
                    @typeInfo(p_field.type) != .optional;
                if (required) {
                    row_len += (std.fmt.bufPrint(row_buf[row_len..], "{s}[required]", .{
                        if (row_len == 0) "" else "  ",
                    }) catch row_buf[row_len..row_len]).len;
                }
                try writeHelpRow(writer, used, column, row_buf[0..row_len]);
            }
        }

        /// The "Flags:" section: aligned, with defaults, and without deprecated flags.
        ///
        /// Deprecated flags still parse; they are simply not advertised, which is what a
        /// deprecation is for. Hidden commands' flags are not a concept - a hidden
        /// command's help is reachable by running it.
        fn printFlagList(ctx: anytype, writer: anytype, orig_flags: type, flags_type: type) !void {
            const column = comptime flagColumnWidth(orig_flags, flags_type);
            var any_flags = false;
            inline for (std.meta.fields(flags_type)) |field| {
                if (comptime !isFrameworkField(field.name) and
                    !isPositionalField(field.name) and
                    !isDeprecatedFlag(orig_flags, field.name))
                {
                    if (fieldIsAvailable(ctx, orig_flags, field.name)) any_flags = true;
                }
            }
            if (!any_flags) return;

            try writer.writeAll("\nFlags:\n");
            inline for (std.meta.fields(flags_type)) |field| {
                if (comptime !isFrameworkField(field.name) and
                    !isPositionalField(field.name) and
                    !isDeprecatedFlag(orig_flags, field.name))
                {
                    // A flag behind a closed gate is not listed: its whole purpose is to
                    // be invisible until the variable is set. Nested rather than an early
                    // `continue`, which Zig rejects next to comptime control flow.
                    if (fieldIsAvailable(ctx, orig_flags, field.name)) {
                        try writer.writeAll("  --");
                        try writeFlagSpelling(writer, field.name);
                        var used: usize = 2 + field.name.len;

                        if (comptime hasShortFlag(orig_flags, field.name)) {
                            const short = @field(orig_flags.meta, field.name).short;
                            try writer.print(", -{c}", .{short});
                            used += 4;
                        }
                        if (comptime fieldTakesValue(field.type)) {
                            try writer.writeAll(" <value>");
                            used += 8;
                        }

                        // The row's text: the documented help, then the type and the default
                        // so a reader does not have to open the source to learn either.
                        var row_buf: [512]u8 = undefined;
                        var row_len: usize = 0;
                        const help_text: ?[]const u8 =
                            if (comptime hasFieldHelp(orig_flags, field.name))
                                @field(orig_flags.meta, field.name).help
                            else
                                null;
                        if (help_text) |text| {
                            if (text.len <= row_buf.len) {
                                @memcpy(row_buf[0..text.len], text);
                                row_len = text.len;
                            }
                        }
                        row_len += (std.fmt.bufPrint(row_buf[row_len..], "{s}({s})", .{
                            if (row_len == 0) "" else "  ",
                            @typeName(field.type),
                        }) catch row_buf[row_len..row_len]).len;
                        if (comptime field.default_value_ptr == null and
                            @typeInfo(field.type) != .optional and field.type != bool)
                        {
                            row_len += (std.fmt.bufPrint(row_buf[row_len..], " [required]", .{}) catch row_buf[row_len..row_len]).len;
                        } else if (comptime isSecretFlag(orig_flags, field.name)) {
                            // A secret's own default is a secret: printing it in `--help`
                            // would publish the value the metadata exists to protect.
                            row_len += (std.fmt.bufPrint(row_buf[row_len..], " [default: {s}]", .{log.redaction_mask}) catch row_buf[row_len..row_len]).len;
                        } else if (field.default_value_ptr) |def| {
                            const default_value = @as(*align(1) const field.type, @ptrCast(def)).*;
                            const printed = if (comptime isRepeatableField(field.type))
                                row_buf[row_len..row_len]
                            else if (comptime field.type == []const u8)
                                std.fmt.bufPrint(row_buf[row_len..], " [default: {s}]", .{default_value}) catch row_buf[row_len..row_len]
                            else
                                std.fmt.bufPrint(row_buf[row_len..], " [default: {any}]", .{default_value}) catch row_buf[row_len..row_len];
                            row_len += printed.len;
                        }

                        try writeHelpRow(writer, used, column, row_buf[0..row_len]);
                    }
                }
            }
        }

        /// Whether a field's metadata carries `help`.
        fn hasFieldHelp(comptime OrigFlagsT: type, comptime name: []const u8) bool {
            if (!@hasDecl(OrigFlagsT, "meta")) return false;
            if (!@hasField(@TypeOf(OrigFlagsT.meta), name)) return false;
            return @hasField(@TypeOf(@field(OrigFlagsT.meta, name)), "help");
        }

        /// The built-in help page: usage, description, commands, arguments, flags.
        fn printHelp(comptime cmd: anytype, ctx: anytype) !void {
            const out = ctx.out;
            const CmdType = @TypeOf(cmd);

            try out.print("Usage: {s}", .{cmd.name});
            if (comptime hasAnySubcommands(CmdType)) try out.writeAll(" [command]");
            if (comptime declaresPositionals(CmdType)) try out.writeAll(" [args]");
            try out.writeAll("\n");

            if (@hasField(CmdType, "description") and cmd.description.len > 0) {
                try out.print("\n{s}\n", .{cmd.description});
            }

            try printCommandList(cmd, ctx, out);

            const RunFlagsType = GetFlagsType(CmdType);
            const orig_flags = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else RunFlagsType;
            try printArgumentList(cmd, out, orig_flags);
            if (RunFlagsType != void) try printFlagList(ctx, out, orig_flags, RunFlagsType);
        }

        fn formatOutput(ctx: anytype, result: anytype) !void {
            const T = @TypeOf(result);
            if (T == void) return;

            switch (ctx.output_format) {
                .json => {
                    try std.json.fmt(result, .{}).format(ctx.out);
                    try ctx.out.print("\n", .{});
                },
                // The same value, spelled for a YAML reader. Chosen by the same global
                // `--output` flag, so a script can pick its parser without the command
                // knowing which one it is.
                .yaml => try writeYaml(ctx.out, result, 0),
                .text => switch (@typeInfo(T)) {
                    .@"struct" => |info| {
                        _ = info;
                        try ctx.out.print("\n╭─{s}─┬─{s}─╮\n", .{ "─" ** 20, "─" ** 40 });
                        try ctx.out.print("│ {s:20.20} │ {s:40.40} │\n", .{ "Field", "Value" });
                        try ctx.out.print("├─{s}─┼─{s}─┤\n", .{ "─" ** 20, "─" ** 40 });

                        inline for (std.meta.fields(T)) |field| {
                            const field_val = @field(result, field.name);
                            if (@typeInfo(field.type) == .pointer and field.type != []const u8 and field.type != []u8) {
                                try ctx.out.print("│ {s:20.20} │ {any} │\n", .{ field.name, field_val });
                            } else if (field.type == []const u8 or field.type == []u8) {
                                try ctx.out.print("│ {s:20.20} │ {s:40.40} │\n", .{ field.name, field_val });
                            } else {
                                try ctx.out.print("│ {s:20.20} │ {any} │\n", .{ field.name, field_val });
                            }
                        }
                        try ctx.out.print("╰─{s}─┴─{s}─╯\n", .{ "─" ** 20, "─" ** 40 });
                    },
                    else => {
                        if (T == []const u8 or T == []u8) {
                            try ctx.out.print("{s}\n", .{result});
                        } else {
                            try ctx.out.print("{any}\n", .{result});
                        }
                    },
                },
            }
        }

        /// Writes `indent` levels of two-space indentation.
        fn writeYamlPad(writer: anytype, indent: usize) !void {
            var level: usize = 0;
            while (level < indent) : (level += 1) try writer.writeAll("  ");
        }

        /// Whether a value renders as a YAML *block* (its own lines) rather than inline.
        ///
        /// A string is a scalar even though it is a slice; a slice of anything else, an
        /// array, a struct with fields, and an optional wrapping one of those are blocks.
        fn yamlIsBlock(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .@"struct" => |info| !info.is_tuple and info.fields.len > 0,
                .pointer => |ptr| ptr.size == .slice and ptr.child != u8,
                .array => |arr| arr.child != u8,
                .optional => |opt| yamlIsBlock(opt.child),
                else => false,
            };
        }

        /// Renders one value as YAML.
        ///
        /// A *subset*: block mappings and sequences, scalars, and null. No anchors, no flow
        /// style, no tags, no multi-document streams. A command's result is a struct or a
        /// list of them, so the general emitter would be a parser's worth of code for
        /// output nothing reads - and anything outside the subset still renders, through
        /// `{any}`, rather than failing.
        fn writeYaml(writer: anytype, value: anytype, indent: usize) !void {
            const T = @TypeOf(value);

            if (comptime yamlIsBlock(T)) {
                switch (@typeInfo(T)) {
                    .@"struct" => |info| {
                        inline for (info.fields) |field| {
                            try writeYamlPad(writer, indent);
                            try writer.print("{s}:", .{field.name});
                            const field_value = @field(value, field.name);
                            if (comptime yamlIsBlock(field.type)) {
                                try writer.writeByte('\n');
                                try writeYaml(writer, field_value, indent + 1);
                            } else {
                                try writer.writeByte(' ');
                                try writeYamlScalar(writer, field_value);
                                try writer.writeByte('\n');
                            }
                        }
                    },
                    .pointer, .array => {
                        for (value) |item| {
                            try writeYamlPad(writer, indent);
                            try writer.writeAll("- ");
                            if (comptime yamlIsBlock(@TypeOf(item))) {
                                try writer.writeByte('\n');
                                try writeYaml(writer, item, indent + 1);
                            } else {
                                try writeYamlScalar(writer, item);
                                try writer.writeByte('\n');
                            }
                        }
                    },
                    .optional => {
                        if (value) |inner| {
                            try writeYaml(writer, inner, indent);
                        } else {
                            try writeYamlPad(writer, indent);
                            try writer.writeAll("null\n");
                        }
                    },
                    else => unreachable,
                }
                return;
            }

            try writeYamlPad(writer, indent);
            try writeYamlScalar(writer, value);
            try writer.writeByte('\n');
        }

        /// One scalar, on the line the caller has already indented.
        fn writeYamlScalar(writer: anytype, value: anytype) !void {
            switch (@typeInfo(@TypeOf(value))) {
                .int, .float => try writer.print("{d}", .{value}),
                .bool => try writer.writeAll(if (value) "true" else "false"),
                // Quoted rather than bare: an enum tag is safe either way, and quoting keeps
                // one rule for every string-shaped value.
                .@"enum" => try writeYamlQuoted(writer, @tagName(value)),
                .optional => {
                    if (value) |inner| {
                        try writeYamlScalar(writer, inner);
                    } else {
                        try writer.writeAll("null");
                    }
                },
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) {
                        try writeYamlQuoted(writer, value);
                    } else {
                        try writer.print("{any}", .{value});
                    }
                },
                .@"union" => |info| {
                    // A tagged union reads as its variant, and as `tag: payload` when the
                    // variant carries one - which is the shape a "one of these" result has.
                    if (info.tag) |_| {
                        const tag = @tagName(value);
                        const Payload = @TypeOf(@field(value, tag));
                        if (comptime Payload == void) {
                            try writer.writeAll(tag);
                        } else {
                            try writer.print("{s}: ", .{tag});
                            try writeYamlScalar(writer, @field(value, tag));
                        }
                    }
                },
                .void => try writer.writeAll("null"),
                else => try writer.print("{any}", .{value}),
            }
        }

        /// A double-quoted YAML string.
        ///
        /// Always quoted, so a value that happens to read as `null`, a number or a date is
        /// still a string when it comes back - and the escapes are the ones YAML's
        /// double-quoted style defines.
        fn writeYamlQuoted(writer: anytype, text: []const u8) !void {
            try writer.writeByte('"');
            for (text) |ch| {
                switch (ch) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => {
                        if (ch < 0x20) {
                            try writer.print("\\x{x:0>2}", .{ch});
                        } else {
                            try writer.writeByte(ch);
                        }
                    },
                }
            }
            try writer.writeByte('"');
        }

        fn tokenizeReplInput(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList([]const u8) {
            var args_list = std.ArrayList([]const u8).empty;
            var in_quotes = false;
            var start: usize = 0;
            var j: usize = 0;
            while (j < input.len) : (j += 1) {
                const c = input[j];
                if (c == '"' and (j == 0 or input[j - 1] != '\\')) {
                    in_quotes = !in_quotes;
                } else if (c == ' ' and !in_quotes) {
                    if (j > start) {
                        var token = input[start..j];
                        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
                            token = token[1 .. token.len - 1];
                        }
                        try args_list.append(allocator, token);
                    }
                    start = j + 1;
                }
            }
            if (j > start) {
                var token = input[start..j];
                if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
                    token = token[1 .. token.len - 1];
                }
                try args_list.append(allocator, token);
            }
            return args_list;
        }

        fn executeReplCommand(comptime root_cmd: anytype, ctx: anytype, input: []const u8) anyerror!void {
            const trimmed = std.mem.trim(u8, input, " \r\n\t");
            if (trimmed.len == 0) return;
            if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) return error.UserCancelled;

            var args_list = try tokenizeReplInput(ctx.allocator, trimmed);
            defer args_list.deinit(ctx.allocator);

            var chain = try ExecutionChain.init(ctx.allocator, args_list.items.len);
            defer chain.deinit(ctx.allocator);

            execute(root_cmd, ctx, args_list.items, &chain) catch |err| {
                if (err != error.HandledError and err != error.UserCancelled) {
                    try ctx.err.print("Command failed: {s}\n", .{@errorName(err)});
                }
            };
        }

        fn handleReplAutocomplete(comptime root_cmd: anytype, ctx: anytype, input: []const u8) !void {
            const trimmed = std.mem.trimStart(u8, input, " \r\n\t");
            if (trimmed.len == 0) return;

            var args_list = try tokenizeReplInput(ctx.allocator, trimmed);
            defer args_list.deinit(ctx.allocator);

            // Check if the last character is a space, meaning we are completing a new empty token
            if (input.len > 0 and input[input.len - 1] == ' ') {
                try args_list.append(ctx.allocator, "");
            }

            // Call the autocomplete engine
            try executeAutocomplete(root_cmd, ctx, args_list.items);
        }

        /// An in-memory harness for driving a command tree without a sub-process.
        ///
        /// Output and errors are captured into growable buffers, so a test can assert on
        /// what a command printed without spawning anything. That matters more than speed:
        /// a sub-process cannot report the *error* it returned, only an exit status, and
        /// this framework's interesting behaviour is which error it raises and what it
        /// wrote before raising it.
        ///
        /// `out_buf` and `err_buf` are public and read directly (`harness.err_buf.items`)
        /// rather than through an accessor, because the buffer *is* the artefact under
        /// test and an accessor would only add a layer between the assertion and it.
        pub const TestHarness = struct {
            allocator: std.mem.Allocator,
            out_buf: std.ArrayListUnmanaged(u8),
            err_buf: std.ArrayListUnmanaged(u8),
            in_buf: std.ArrayListUnmanaged(u8),
            env_map: std.process.Environ.Map,
            is_tty: bool = false,
            pub fn init(allocator: std.mem.Allocator) TestHarness {
                return .{
                    .allocator = allocator,
                    .out_buf = .empty,
                    .err_buf = .empty,
                    .in_buf = .empty,
                    .env_map = std.process.Environ.Map.init(allocator),
                };
            }

            pub fn deinit(self: *TestHarness) void {
                self.out_buf.deinit(self.allocator);
                self.err_buf.deinit(self.allocator);
                self.in_buf.deinit(self.allocator);
                self.env_map.deinit();
            }

            /// Everything written to stdout so far.
            pub fn stdout(self: *const TestHarness) []const u8 {
                return self.out_buf.items;
            }

            /// Runs `root_cmd` against `args`.
            ///
            /// The buffers are captured rather than declared per test, so a test can run
            /// several commands in sequence and inspect the accumulated output - which is
            /// what makes "did the second call print anything" answerable.
            pub fn run(
                self: *TestHarness,
                app_state: anytype,
                comptime root_cmd: anytype,
                args: []const []const u8,
            ) !void {
                // `Allocating` wraps the array list and grows it, so the buffer is
                // reused across calls instead of being reallocated per `run`.
                var out_writer = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.out_buf);
                defer self.out_buf = out_writer.toArrayList();
                var err_writer = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.err_buf);
                defer self.err_buf = err_writer.toArrayList();

                var in_reader = std.Io.Reader.fixed(self.in_buf.items);

                const ctx = Ctx{
                    .allocator = self.allocator,
                    .in = &in_reader,
                    .out = &out_writer.writer,
                    .err = &err_writer.writer,
                    .state = app_state,
                    .env_map = &self.env_map,
                    // `std.testing.io` rather than `undefined`: a command under test is
                    // allowed to touch the filesystem (a config file, a fixture), and
                    // `undefined` made that undefined behaviour instead of I/O. A test
                    // that wants to prove a command does *no* platform I/O asserts on
                    // the filesystem itself, not on a poisoned handle.
                    .io = std.testing.io,
                    .is_tty = self.is_tty,
                };

                var chain = try ExecutionChain.init(self.allocator, args.len + 1);
                defer chain.deinit(self.allocator);

                try execute(root_cmd, ctx, args, &chain);
            }
        };

        pub fn runShell(comptime root_cmd: anytype, ctx: anytype) !void {
            const builtin = @import("builtin");

            try ctx.out.print("Entering interactive shell for {s}...\n", .{root_cmd.name});
            try ctx.out.print("Type 'exit' or 'quit' to close.\n", .{});

            // --- 1. Cross-Platform Raw Mode Setup ---
            if (builtin.os.tag != .windows) {
                // POSIX (Linux / macOS)
                const STDIN = std.posix.STDIN_FILENO;
                const original_termios = try std.posix.tcgetattr(STDIN);

                var raw = original_termios;
                raw.lflag.ICANON = false;
                raw.lflag.ECHO = false;
                try std.posix.tcsetattr(STDIN, .FLUSH, raw);
                defer std.posix.tcsetattr(STDIN, .FLUSH, original_termios) catch {};
            } else {
                // WINDOWS Console API
                const win = std.os.windows;

                const kernel32 = struct {
                    pub extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) ?win.HANDLE;
                    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: win.HANDLE, lpMode: *win.DWORD) c_int;
                    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: win.HANDLE, dwMode: win.DWORD) c_int;
                };
                const STD_INPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -10));

                const ENABLE_PROCESSED_INPUT = 0x0001;
                const ENABLE_LINE_INPUT = 0x0002;
                const ENABLE_ECHO_INPUT = 0x0004;
                const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;

                const stdin_handle = kernel32.GetStdHandle(STD_INPUT_HANDLE) orelse return error.WindowsConsoleError;
                if (stdin_handle == win.INVALID_HANDLE_VALUE) return error.WindowsConsoleError;

                var original_mode: win.DWORD = 0;
                if (kernel32.GetConsoleMode(stdin_handle, &original_mode) == 0) {
                    return error.WindowsConsoleError;
                }

                var raw_mode = original_mode;
                // Disable line buffering, echoing, and Ctrl+C processing (handle manually)
                raw_mode &= ~@as(win.DWORD, ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
                // Enable ANSI arrow keys/virtual terminal sequences
                raw_mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;

                if (kernel32.SetConsoleMode(stdin_handle, raw_mode) == 0) {
                    return error.WindowsConsoleError;
                }
                defer _ = kernel32.SetConsoleMode(stdin_handle, original_mode);
            }

            // --- 2. The Unified Keystroke Loop ---
            try ctx.out.print("{s}> ", .{root_cmd.name});

            var line_buf = std.ArrayList(u8).empty;
            defer line_buf.deinit(ctx.allocator);

            while (true) {
                var char: [1]u8 = undefined;
                const bytes_read = try ctx.in.readSliceShort(&char);
                if (bytes_read == 0) break;

                switch (char[0]) {
                    0x03, 0x04 => break, // Ctrl+C or Ctrl+D (EOF)
                    '\n', '\r' => {
                        try ctx.out.writeAll("\n");
                        executeReplCommand(root_cmd, ctx, line_buf.items) catch |err| {
                            if (err == error.UserCancelled) break;
                        };
                        line_buf.clearRetainingCapacity();
                        try ctx.out.print("{s}> ", .{root_cmd.name});
                    },
                    127, '\x08' => { // Backspace
                        if (line_buf.items.len > 0) {
                            _ = line_buf.pop();
                            try ctx.out.writeAll("\x08 \x08");
                        }
                    },
                    0x09 => { // TAB
                        var out_buf = std.ArrayList(u8).empty;
                        defer out_buf.deinit(ctx.allocator);

                        var new_ctx = ctx;
                        var aw = std.Io.Writer.Allocating.fromArrayList(ctx.allocator, &out_buf);
                        new_ctx.out = &aw.writer; // Hijack output

                        try handleReplAutocomplete(root_cmd, new_ctx, line_buf.items);

                        if (out_buf.items.len > 0) {
                            try ctx.out.print("\n{s}\n", .{out_buf.items});
                        }
                        try ctx.out.print("{s}> {s}", .{ root_cmd.name, line_buf.items });
                    },
                    else => |c| {
                        // Ignore ANSI escape sequence prefixes (like arrow keys) for now, or handle them
                        if (c >= 32 and c <= 126) {
                            try line_buf.append(ctx.allocator, c);
                            try ctx.out.print("{c}", .{c});
                        }
                    },
                }
            }
        }

        pub fn run(app_state: *StateT, comptime root_cmd: anytype, init: std.process.Init) !void {
            const io = init.io;
            const arena = init.arena.allocator();
            const args = try init.minimal.args.toSlice(arena);

            // The arena is the right owner: the filtered slice lives exactly as long as
            // the command dispatch does, and the arena is freed at process exit.
            var filtered_args: std.ArrayListUnmanaged([]const u8) = .empty;
            var i: usize = 1;
            while (i < args.len) {
                try filtered_args.append(arena, args[i]);
                i += 1;
            }

            // In Zig 0.16 `std.Io` has no stdio fields; stdio is reached through
            // `std.Io.File`, and a `File.Reader`/`File.Writer` borrows a buffer the CALLER
            // owns. So the buffers are locals here and the context borrows their
            // interfaces - which is why `Ctx.in/out/err` are `*Io.Reader`/`*Io.Writer`
            // rather than the `File.*` wrappers.
            //
            // These must outlive `ctx`, so they are declared before it and deliberately
            // not scoped tighter. Sizes come from `config`, which is the parameter this
            // `App` was instantiated with - a caller that wants larger buffers for big
            // exports says so once at the type level.
            var in_buffer: [config.in_buffer_size]u8 = undefined;
            var out_buffer: [config.out_buffer_size]u8 = undefined;
            var err_buffer: [config.err_buffer_size]u8 = undefined;

            var in_file_reader: std.Io.File.Reader = .init(.stdin(), io, &in_buffer);
            var out_file_writer: std.Io.File.Writer = .init(.stdout(), io, &out_buffer);
            var err_file_writer: std.Io.File.Writer = .init(.stderr(), io, &err_buffer);

            // Both streams are probed, not just stdin.
            //
            // `is_tty` was one bit taken from **stdin**, and `color_enabled` was
            // declared on `Ctx` and never set or read anywhere. So `prog > file`
            // still emitted colour, because stdin was the terminal the user was
            // typing at - which is precisely the case a colour gate exists to
            // catch, and neither field could catch it.
            //
            // Best-effort: a redirected or closed stream is not an error worth
            // failing startup over, so it degrades to "not a terminal".
            const stdin_is_tty = std.Io.File.stdin().isTty(io) catch false;
            const stdout_is_tty = std.Io.File.stdout().isTty(io) catch false;

            const caps = render.capability.decide(init.environ_map, stdout_is_tty, stdin_is_tty);
            // Installed once, before any command runs, and read by every renderer
            // afterwards. This is the only place the environment is consulted for
            // it, so `NO_COLOR` and a piped stdout cannot disagree with each other.
            render.capability.set(caps);

            const ctx = Ctx{
                .allocator = init.gpa,
                .in = &in_file_reader.interface,
                .out = &out_file_writer.interface,
                .err = &err_file_writer.interface,
                .state = app_state,
                .env_map = init.environ_map,
                .io = io,
                .is_tty = caps.interactive,
                .color_enabled = caps.color,
                .output_format = .text,
            };

            var chain = try ExecutionChain.init(ctx.allocator, filtered_args.items.len);
            defer chain.deinit(ctx.allocator);

            // Signal integration, opt-in.
            //
            // `platform/signal.zig` has always been able to record a shutdown signal,
            // and nothing installed it: the module had no caller anywhere in the tree.
            // Installing claims the signal (the default handler no longer kills the
            // process), which is why this is a `Config` decision rather than always on -
            // a command that never polls `ctx.shutdown()` would otherwise stop responding
            // to Ctrl+C. With it on, a command polls, cleans up on the normal path, and
            // the process still reports the conventional status below.
            if (comptime @hasField(@TypeOf(config), "install_signal_handlers")) {
                if (config.install_signal_handlers) {
                    _ = installSignalHandlers();
                }
            }

            // **A failed command must exit non-zero.** Buffered writers hold output until flushed,
            // so both are flushed *before* the status is decided - `std.process.exit` does not run
            // `defer`, and a command's own error message is still in the buffer at this point.
            //
            // `failureDisposition` decides both the status and whether the framework still owes a
            // message: `HandledError` means the command already printed its own diagnostic, and a
            // cancelled prompt is a deliberate "no" - neither is a success, and neither needs
            // another line of output.
            var interrupted: ?platform.signal.Signal = null;
            execute(root_cmd, ctx, filtered_args.items, &chain) catch |err| {
                ctx.out.flush() catch {};
                ctx.err.flush() catch {};
                failWith(err, ctx);
            };
            interrupted = platform.signal.received();

            ctx.out.flush() catch {};
            ctx.err.flush() catch {};

            // An external subcommand's status is the user's answer, so it is passed
            // through unchanged: a wrapper script must not have to guess whether the
            // plugin failed or the framework did. Zero falls through to a normal exit.
            if (chain.external_status) |code| {
                if (code != 0) std.process.exit(code);
            }

            // A shutdown request that a command observed and cleaned up after is still a
            // shutdown request, and a shell script testing `$?` must see it as one. The
            // status is the conventional `128 + signal`, which is what a program killed by
            // that signal reports, so `if ! prog; then` behaves the same either way.
            if (interrupted) |shutdown_signal| {
                std.process.exit(128 +% @intFromEnum(shutdown_signal));
            }
        }

        pub fn executeAutocomplete(
            comptime cmd: anytype,
            ctx: anytype,
            args: []const []const u8,
        ) !void {
            const CmdType = @TypeOf(cmd);

            // Simple autocompletion logic
            if (args.len == 0 or (args.len == 1 and args[0].len == 0)) {
                if (comptime hasSubcommands(CmdType)) {
                    inline for (getSubcommands(cmd)) |sub| {
                        // A completion list is an advertisement, so it follows the same
                        // rule as help: no hidden, deprecated or gate-closed commands.
                        if (isAdvertisable(ctx, @TypeOf(sub), sub)) {
                            try ctx.out.print("{s}\n", .{sub.name});
                            if (@hasField(@TypeOf(sub), "aliases")) {
                                for (sub.aliases) |alias_name| {
                                    try ctx.out.print("{s}\n", .{alias_name});
                                }
                            }
                        }
                    }
                }
                return;
            }

            if (comptime hasSubcommands(CmdType)) {
                inline for (getSubcommands(cmd)) |sub| {
                    if (commandIsAvailable(ctx, @TypeOf(sub), sub)) {
                        var matches = std.mem.eql(u8, args[0], sub.name);
                        if (!matches and @hasField(@TypeOf(sub), "aliases")) {
                            for (sub.aliases) |alias_name| {
                                if (std.mem.eql(u8, alias_name, args[0])) matches = true;
                            }
                        }
                        if (matches) return try executeAutocomplete(sub, ctx, args[1..]);
                    }
                }
            }

            const FlagsType = GetFlagsType(CmdType);
            const OrigFlagsT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else FlagsType;
            if (FlagsType != void) {
                if (args.len > 0 and std.mem.startsWith(u8, args[args.len - 1], "-")) {
                    inline for (std.meta.fields(FlagsType)) |field| {
                        if (comptime !(field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) {
                            if (comptime !isPositionalField(field.name)) {
                                if (fieldIsAvailable(ctx, OrigFlagsT, field.name)) {
                                    try ctx.out.writeAll("--");
                                    try writeFlagSpelling(ctx.out, field.name);
                                    try ctx.out.writeAll("\n");
                                }
                            }
                        }
                    }
                } else if (args.len >= 2 and std.mem.startsWith(u8, args[args.len - 2], "-")) {
                    // They are completing a flag value (e.g. `--role `)
                    const flag_name = args[args.len - 2];
                    const clean_name = if (std.mem.startsWith(u8, flag_name, "--")) flag_name[2..] else if (std.mem.startsWith(u8, flag_name, "-")) flag_name[1..] else flag_name;

                    if (@hasDecl(OrigFlagsT, "completion")) {
                        const completions = OrigFlagsT.completion;
                        inline for (std.meta.fields(FlagsType)) |field| {
                            if (flagNamesEqual(field.name, clean_name)) {
                                if (@hasField(@TypeOf(completions), field.name)) {
                                    const comp_fn = @field(completions, field.name);
                                    const results = comp_fn(ctx, args);
                                    for (results) |res| {
                                        try ctx.out.print("{s}\n", .{res});
                                    }
                                    return;
                                }
                            }
                        }
                    }

                    // Also suggest enum variants automatically!
                    inline for (std.meta.fields(FlagsType)) |field| {
                        if (flagNamesEqual(field.name, clean_name)) {
                            if (@typeInfo(field.type) == .@"enum") {
                                inline for (std.meta.fields(field.type)) |enum_field| {
                                    try ctx.out.print("{s}\n", .{enum_field.name});
                                }
                            }
                        }
                    }
                }
            }
        }
        /// Renders the command tree as markdown.
        ///
        /// The root is an `#` heading and each subcommand gets its own section, so the
        /// output reads as a document rather than one long table. Hidden commands are
        /// omitted from the listing *and* from the recursion: documentation is the most
        /// public surface a hidden command could leak onto.
        pub fn writeMarkdownDocs(comptime cmd: anytype, writer: anytype, prefix: []const u8) !void {
            const CmdType = @TypeOf(cmd);

            if (prefix.len == 0) {
                try writer.print("# {s}\n\n", .{cmd.name});
            } else {
                try writer.print("## {s}{s}\n\n", .{ prefix, cmd.name });
            }
            if (@hasField(CmdType, "description") and cmd.description.len > 0) {
                try writer.print("{s}\n\n", .{cmd.description});
            }

            const FlagsType = GetFlagsType(CmdType);
            const orig_flags = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else FlagsType;
            if (FlagsType != void) {
                var any_flags = false;
                inline for (std.meta.fields(FlagsType)) |field| {
                    if (comptime !isFrameworkField(field.name) and !isPositionalField(field.name)) {
                        any_flags = true;
                    }
                }
                if (any_flags) {
                    try writer.writeAll("### Flags\n\n| Flag | Type | Default |\n|---|---|---|\n");
                    inline for (std.meta.fields(FlagsType)) |field| {
                        if (comptime !isFrameworkField(field.name) and !isPositionalField(field.name)) {
                            try writer.writeAll("| --");
                            try writeFlagSpelling(writer, field.name);
                            // A gate-closed flag is documented here with the variable that
                            // opens it: the reference describes the whole surface.
                            try writeFlagMarkers(orig_flags, field.name, writer);
                            if (comptime isSecretFlag(orig_flags, field.name)) {
                                try writer.print(" | {s} | {s} |\n", .{ @typeName(field.type), log.redaction_mask });
                            } else if (field.default_value_ptr) |ptr| {
                                const typed_ptr: *const field.type = @ptrCast(@alignCast(ptr));
                                if (comptime field.type == []const u8) {
                                    try writer.print(" | {s} | {s} |\n", .{ @typeName(field.type), typed_ptr.* });
                                } else {
                                    try writer.print(" | {s} | {any} |\n", .{ @typeName(field.type), typed_ptr.* });
                                }
                            } else {
                                try writer.print(" | {s} | Required |\n", .{@typeName(field.type)});
                            }
                        }
                    }
                    try writer.writeAll("\n");
                }

                // Positional arguments, which this generator omitted entirely even
                // though `printHelp`'s shape made it obvious they existed.
                const ArgsT = PositionalType(CmdType);
                if (comptime std.meta.fields(ArgsT).len > 0) {
                    try writer.writeAll("### Arguments\n\n| Argument | Type |\n|---|---|\n");
                    inline for (std.meta.fields(ArgsT)) |p_field| {
                        try writer.print("| {s} | {s} |\n", .{ p_field.name, @typeName(p_field.type) });
                    }
                    try writer.writeAll("\n");
                }
            }

            if (comptime hasAnySubcommands(CmdType)) {
                const subs = getSubcommands(cmd);
                try writer.writeAll("## Subcommands\n\n");
                inline for (subs) |sub| {
                    if (comptime !isHidden(@TypeOf(sub), sub)) {
                        try writer.print("- **{s}** - {s}", .{ sub.name, sub.description });
                        if (@hasField(@TypeOf(sub), "aliases")) {
                            for (sub.aliases, 0..) |alias_name, alias_idx| {
                                try writer.writeAll(if (alias_idx == 0) " (alias: " else ", ");
                                try writer.writeAll(alias_name);
                            }
                            if (sub.aliases.len > 0) try writer.writeAll(")");
                        }
                        try writeCommandMarkers(@TypeOf(sub), sub, writer);
                        try writer.writeAll("\n");
                    }
                }
                try writer.writeAll("\n");

                var next_prefix_buf: [128]u8 = undefined;
                const next_prefix = try std.fmt.bufPrint(&next_prefix_buf, "{s}{s} ", .{ prefix, cmd.name });
                inline for (subs) |sub| {
                    if (comptime !isHidden(@TypeOf(sub), sub)) {
                        try writeMarkdownDocs(sub, writer, next_prefix);
                    }
                }
            }
        }

        pub fn MergeFlags(comptime A: type, comptime B: type) type {
            const fields_a = std.meta.fields(A);
            const fields_b = std.meta.fields(B);
            const total_len = fields_a.len + fields_b.len;

            var names: [total_len][]const u8 = undefined;
            var types: [total_len]type = undefined;
            var attrs: [total_len]std.builtin.Type.StructField.Attributes = undefined;

            inline for (fields_a, 0..) |field, i| {
                names[i] = field.name;
                types[i] = field.type;
                attrs[i] = .{ .@"comptime" = field.is_comptime, .@"align" = field.alignment, .default_value_ptr = field.default_value_ptr };
            }
            inline for (fields_b, 0..) |field, i| {
                names[fields_a.len + i] = field.name;
                types[fields_a.len + i] = field.type;
                attrs[fields_a.len + i] = .{ .@"comptime" = field.is_comptime, .@"align" = field.alignment, .default_value_ptr = field.default_value_ptr };
            }

            const final_names = names;
            const final_types = types;
            const final_attrs = attrs;

            return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
        }
    };
}

// -- Generated output ---------------------------------------------------------
//
// These are file-scope so the interceptors above can `print` them without allocating. The
// `{{`/`}}` are escaped braces: `print` treats the string as a format spec, and a shell
// script is full of `{}`.
