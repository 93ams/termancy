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
pub const version = @import("version.zig");
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
/// Running a child process, captured or streamed.
pub const process = platform.process;
/// Graceful shutdown: conventional signals, as a poll-able flag.
pub const signal = platform.signal;
/// Leveled logging, as readable text or machine-readable JSON.
pub const log = platform.log;
/// A line editor with echo suppression, for text and password entry.
pub const text_input = interact.text_input;
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

pub const OutputFormat = enum { text, json };

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

/// Configuration for the CLI framework itself (buffer sizes, etc).
pub const ExitMap = struct {
    name: []const u8,
    code: u8,
};

pub const Config = struct {
    in_buffer_size: usize = 4096,
    out_buffer_size: usize = 8192,
    err_buffer_size: usize = 4096,
    exit_map: []const ExitMap = &.{},
};

pub fn App(comptime StateT: type, comptime config: anytype) type {
    return struct {
        const Self = @This();

        fn OnionBuilder(comptime mws: anytype, comptime index: usize, comptime CmdT: type, comptime FlagsT: type) type {
            return struct {
                pub fn exec(c: Ctx, command: CmdT, f: FlagsT) !void {
                    if (comptime index >= mws.len) {
                        if (@typeInfo(@TypeOf(command.run)) == .optional) {
                            if (command.run) |run_fn| {
                                const result = try run_fn(c, f);
                                if (@TypeOf(result) != void) try formatOutput(c, result);
                            }
                        } else {
                            const result = try command.run(c, f);
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
                        try mws[index](c, NextPayload{ .cx = c, .cmd = command, .fl = f });
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
        };

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
        };

        /// The framework's declared failure modes.
        ///
        /// A named set rather than `anyerror`, so a command author can see what the
        /// framework itself raises, and so the exit-code mapping below can be exhaustive
        /// instead of guessing at an arbitrary error's meaning.
        ///
        /// `Count` is the number of codes such a set can carry, and it must be present for
        /// a set used in this position.
        pub const Error = error{
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
            Count,
        };

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
        pub fn getExitCode(err: anyerror) u8 {
            // A caller-supplied mapping first: it is the only way to give a domain error a
            // specific status, and it is deliberate rather than a fallback. Compared by
            // name, because `config` is comptime data and a name is what can live in it.
            inline for (config.exit_map) |entry| {
                if (comptime entry.name.len > 0) {
                    if (std.mem.eql(u8, @errorName(err), entry.name)) return entry.code;
                }
            }

            return switch (err) {
                error.UnknownCommand => 127,
                error.CommandNotExecutable => 126,
                error.UserCancelled, error.PromptCancelled => 130,
                error.MissingRequiredFlag,
                error.MissingRequiredPositionalArgument,
                error.MissingFlagValue,
                error.UnknownFlag,
                error.ConflictingFlags,
                error.DependentFlagMissing,
                error.InvalidFlagValue,
                error.ValidationFailed,
                error.TooManyPositionalArguments,
                error.UnknownField,
                error.InvalidFormat,
                => 2,
                else => 1,
            };
        }

        /// Defines a CLI command structure for simple commands without subcommands.
        pub fn Flags(comptime FlagsT: type) type {
            return MergeFlags(FlagsT, GlobalFlags);
        }
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
                pub const OrigFlagsT = FlagsT;
                pub const subcommands = subcmds;
                name: []const u8,
                description: []const u8 = "",
                aliases: []const []const u8 = &[_][]const u8{},

                run: ?*const fn (ctx: Ctx, flags: FlagsType) anyerror!ReturnT = null,
                is_repl: bool = false,
                pre_run: ?HookFn = null,
                post_run: ?HookFn = null,
            };
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
                    if (std.mem.eql(u8, field.name, key)) {
                        return field.type != bool and !(@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool);
                    }
                }
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                const last_char = arg[arg.len - 1];
                if (@hasDecl(OrigFlagsT, "meta")) {
                    const meta_block = OrigFlagsT.meta;
                    inline for (std.meta.fields(FlagsType)) |field| {
                        if (@hasField(@TypeOf(meta_block), field.name)) {
                            const field_meta = @field(meta_block, field.name);
                            if (@hasField(@TypeOf(field_meta), "short")) {
                                if (last_char == field_meta.short) {
                                    return field.type != bool and !(@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool);
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

        pub fn executeAndExit(
            comptime cmd: anytype,
            ctx: anytype,
            args: []const []const u8,
            chain: anytype,
        ) noreturn {
            execute(cmd, ctx, args, chain) catch |err| failWith(err, ctx);
            std.process.exit(0);
        }

        /// Prints a failure and terminates with the mapped exit status.
        ///
        /// **`noreturn`, and the only place a command failure reaches `std.process.exit`.** The
        /// mapping is `config.exit_map` first - so a caller gives a domain error a meaningful
        /// status without the framework knowing what it means - then a POSIX `1` for everything
        /// else, printed with the same `Error: <name>` shape `executeAndExit` uses.
        ///
        /// It exists because the two entry points had drifted: `executeAndExit` mapped and exited,
        /// while `App.run` caught the error, printed `Command failed: <name>` and then returned
        /// normally - so *every* failing command run through the real entry point exited `0`. That
        /// is the "silent success" class this framework's own comments say the routing work existed
        /// to remove, and it was measured here by `git cat-file -e <absent>` reporting success
        /// while printing its own error. Callers that need to flush buffered writers before the
        /// process ends must do so first, because `std.process.exit` does not run `defer`.
        pub fn failWith(err: anyerror, ctx: anytype) noreturn {
            const err_name = @errorName(err);
            for (config.exit_map) |m| {
                if (std.mem.eql(u8, m.name, err_name)) {
                    ctx.err.print("Error: {s}\n", .{err_name}) catch {};
                    std.process.exit(m.code);
                }
            }
            ctx.err.print("Error: {s}\n", .{err_name}) catch {};
            std.process.exit(1);
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
                chain.subcmd_indices[chain.subcmd_count] = 0;
                chain.subcmd_count += 1;
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
        /// `CommandWithReturn` emits a field, and a hand-written command may use either.
        /// The existing `SubcommandsType`/`getSubcommands` helpers depend on these two.
        fn hasSubcommands(comptime CmdType: type) bool {
            return @hasDecl(CmdType, "subcommands") or @hasField(CmdType, "subcommands");
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

        /// Whether the command's flags declare positional arguments.
        ///
        /// Two spellings are accepted (`positionals` and `Positional`) because the
        /// framework reads either; the rule this feeds is that a command with nowhere to
        /// put an argument must reject one rather than silently drop it.
        fn declaresPositionals(comptime CmdType: type) bool {
            const FT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else GetFlagsType(CmdType);
            if (FT == void) return false;
            return @hasField(FT, "positionals") or @hasField(FT, "Positional");
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
        fn nearestSubcommand(comptime CmdType: type, arg: []const u8) ?[]const u8 {
            if (comptime !hasSubcommands(CmdType)) return null;

            var best: ?[]const u8 = null;
            var best_dist: usize = std.math.maxInt(usize);
            const threshold: usize = if (arg.len <= 3) 1 else 3;

            // Bound once: `getSubcommands` returns a value whose type is what the loop
            // iterates, and rebuilding it per iteration makes the tuple arrive as `type`.
            const subcmds = getSubcommands(@as(CmdType, undefined));

            inline for (subcmds) |subcmd| {
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

            if (@hasField(CmdType, "pre_run") and @TypeOf(cmd.pre_run) != @TypeOf(null)) {
                chain.pre_runs[chain.count] = cmd.pre_run;
            }
            if (@hasField(CmdType, "post_run") and @TypeOf(cmd.post_run) != @TypeOf(null)) {
                chain.post_runs[chain.count] = cmd.post_run;
            }
            chain.count += 1;

            // 2. Intercept __complete (Autocompletion)
            if (args.len > 1 and std.mem.eql(u8, args[0], "generate-completions")) {
                if (std.mem.eql(u8, args[1], "zsh")) {
                    const zsh_script =
                        \\#compdef {s}
                        \\_{s}() {{
                        \\  local matches=($({s} __complete "${{words[@]:1}}"))
                        \\  compadd -a matches
                        \\}}
                        \\compdef _{s} {s}
                    ;
                    const c_name = if (@hasDecl(@TypeOf(cmd), "command")) @TypeOf(cmd).command.name else cmd.name;
                    try ctx.out.print(zsh_script, .{ c_name, c_name, c_name, c_name, c_name });
                    return;
                }
            }

            if (args.len > 0 and std.mem.eql(u8, args[0], "__complete")) {
                return try executeAutocomplete(cmd, ctx, args[1..]);
            }

            // 1b. Intercept the generators.
            //
            // Handled before routing because these are not commands in the tree - they are
            // requests to *describe* the tree. A user typing `generate-completions bash` on a
            // binary whose root has a `bash` subcommand means the generator, not that
            // subcommand; the name is namespaced for exactly that reason.
            //
            // Each output is a fixed template keyed on `cmd.name`. No allocation: a
            // completion script is a few lines of shell, and building it in a buffer would
            // add a failure mode to a path with no inputs to validate.
            if (args.len >= 2 and std.mem.eql(u8, args[0], "generate-completions")) {
                const shell = args[1];
                const prog = cmd.name;
                if (std.mem.eql(u8, shell, "bash")) {
                    try emitBashCompletions(ctx.out, prog);
                } else if (std.mem.eql(u8, shell, "fish")) {
                    try emitFishCompletions(ctx.out, prog);
                } else if (std.mem.eql(u8, shell, "powershell") or std.mem.eql(u8, shell, "pwsh")) {
                    try emitPowershellCompletions(ctx.out, prog);
                } else if (std.mem.eql(u8, shell, "zsh")) {
                    try emitZshCompletions(ctx.out, prog);
                } else {
                    try ctx.err.print("Error: Unknown shell '{s}'. Expected bash, zsh, fish or powershell.\n", .{shell});
                    return error.UnknownField;
                }
                return;
            }

            if (args.len >= 2 and std.mem.eql(u8, args[0], "generate-docs")) {
                const fmt = args[1];
                if (std.mem.eql(u8, fmt, "markdown") or std.mem.eql(u8, fmt, "md")) {
                    try writeMarkdownDocs(cmd, ctx.out, "");
                } else if (std.mem.eql(u8, fmt, "man")) {
                    try writeManPage(cmd, ctx.out);
                } else {
                    try ctx.err.print("Error: Unknown format '{s}'. Expected markdown or man.\n", .{fmt});
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
                        const name_matches = std.mem.eql(u8, subcmd.name, arg);
                        var alias_matches = false;
                        if (!name_matches and @hasField(@TypeOf(subcmd), "aliases")) {
                            for (subcmd.aliases) |alias_name| {
                                if (std.mem.eql(u8, alias_name, arg)) alias_matches = true;
                            }
                        }
                        if (name_matches or alias_matches) {
                            // Recorded so `parseFlags` skips it, then the recursion starts
                            // one past it.
                            chain.subcmd_indices[chain.subcmd_count] = cursor;
                            chain.subcmd_count += 1;
                            return try executeFrom(subcmd, ctx, args, chain, cursor + 1);
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
                    try ctx.err.print("Error: Unknown command '{s}'.\n", .{arg});
                    if (comptime hasSubcommands(CmdType)) {
                        if (nearestSubcommand(CmdType, arg)) |suggestion| {
                            try ctx.err.print("Did you mean '{s}'?\n", .{suggestion});
                        }
                    }
                    return error.UnknownCommand;
                }

                break :route;
            }

            // 1. Intercept Help anywhere in the arguments (after routing)
            for (args) |arg| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    try printHelp(cmd, ctx);
                    return;
                }
            }

            // 3. Check if this command is executable
            if (comptime !@hasField(CmdType, "run") or @TypeOf(cmd.run) == @TypeOf(null)) {
                if (args.len == 0) {
                    try printHelp(cmd, ctx);
                    return;
                }
                return error.CommandNotExecutable;
            } else {
                comptime var run_info = @typeInfo(@TypeOf(cmd.run));
                const is_optional = run_info == .optional;
                if (is_optional) {
                    if (cmd.run == null) {
                        if (args.len == 0) {
                            try printHelp(cmd, ctx);
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

                // Dynamic positional arguments allocation
                const pos_buf = try ctx.allocator.alloc([]const u8, args.len);
                defer ctx.allocator.free(pos_buf);
                var pos_count: usize = 0;

                const OrigFlagsT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else FlagsType;
                const flags = try parseFlags(OrigFlagsT, FlagsType, args, pos_buf, &pos_count, ctx, chain);

                var new_ctx = ctx;
                if (@hasField(FlagsType, "output")) {
                    new_ctx.output_format = flags.output;
                }

                if (@hasField(FlagsType, "interactive") and flags.interactive) {
                    if (chain.interactive_shell) |shell_fn| {
                        try shell_fn(new_ctx);
                    } else {
                        try runShell(cmd, new_ctx);
                    }
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
                // `@hasField` rather than a default: `config.middlewares` is optional
                // configuration, and a `const` there would force every `App(...)`
                // instantiation to spell it out.
                if (comptime @hasField(@TypeOf(config), "middlewares")) {
                    if (comptime config.middlewares.len > 0) {
                        try OnionBuilder(config.middlewares, 0, CmdType, @TypeOf(flags)).exec(new_ctx, cmd, flags);
                    } else {
                        try runBodyOrNothing(CmdType, cmd, new_ctx, flags);
                    }
                } else {
                    try runBodyOrNothing(CmdType, cmd, new_ctx, flags);
                }

                // Execute Post-Runs (Leaf -> Root)
                var i: usize = chain.count;
                while (i > 0) {
                    i -= 1;
                    if (chain.post_runs[i]) |post| try post(ctx);
                }
            }
        }

        fn parseFlags(
            comptime OrigFlagsT: type,
            comptime FlagsType: type,
            args: []const []const u8,
            pos_buf: [][]const u8,
            pos_count: *usize,
            ctx: anytype,
            chain: anytype,
        ) !FlagsType {
            var parsed_flags: FlagsType = undefined;
            var provided = [_]bool{false} ** std.meta.fields(FlagsType).len;

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

                    try assignFlag(OrigFlagsT, FlagsType, &parsed_flags, &provided, key, val, args, &i, ctx);
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.mem.startsWith(u8, arg, "--")) {
                    // Short flags
                    for (arg[1..], 0..) |char, char_idx| {
                        const short_key = [_]u8{char};
                        var next_val: ?[]const u8 = null;
                        if (char_idx == arg.len - 2) {
                            next_val = null; // Next argument could be the value
                        }

                        try assignFlag(OrigFlagsT, FlagsType, &parsed_flags, &provided, &short_key, next_val, args, &i, ctx);
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
            inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                if (comptime (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) continue;
                if (comptime isPositionalField(field.name)) continue;

                if (!provided[idx]) {
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
                                    if (comptime @hasDecl(FlagsType, "parse") and @hasField(@TypeOf(FlagsType.parse), field.name)) blk: {
                                        const custom_parser = @field(FlagsType.parse, field.name);
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
                                            try ctx.err.print("\nError: Invalid value '{s}' for flag '--{s}'.\n", .{ input_str, field.name });
                                            return err;
                                        };
                                    };
                                @field(parsed_flags, field.name) = parsed_missing_val;
                                provided[idx] = true;
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
                                        if (comptime @hasDecl(FlagsType, "parse") and @hasField(@TypeOf(FlagsType.parse), p_field.name)) blk: {
                                            const custom_parser = @field(FlagsType.parse, p_field.name);
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
                                                try ctx.err.print("\nError: Invalid value '{s}' for positional argument '{s}'.\n", .{ input_str, p_field.name });
                                                return err;
                                            };
                                        };
                                    @field(@field(parsed_flags, pos_field_name), p_field.name) = parsed_pos_val;
                                    pos_count.* += 1;
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

                        // -- environment binding
                        if (comptime @hasField(@TypeOf(field_meta), "env")) {
                            if (field_meta.env.len > 0 and !provided[idx]) {
                                if (ctx.env_map.get(field_meta.env)) |env_val| {
                                    const parsed_env = parseValue(field.type, env_val) catch |err| {
                                        try ctx.err.print("Error: Invalid value in ${s} for '--{s}'.\n", .{ field_meta.env, field.name });
                                        return err;
                                    };
                                    @field(parsed_flags, field.name) = parsed_env;
                                }
                            }
                        }

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
            if (@hasDecl(FlagsType, "validation")) {
                const rules = FlagsType.validation;
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
                            var found = false;
                            for (rule.in) |allowed| {
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
                            var var_list: std.ArrayListUnmanaged([]const u8) = .empty;
                            for (pos_buf[p_i..pos_count.*]) |v_arg| {
                                try var_list.append(ctx.allocator, v_arg);
                            }
                            @field(@field(parsed_flags, pos_field_name), p_field.name) =
                                try var_list.toOwnedSlice(ctx.allocator);
                        } else {
                            @field(@field(parsed_flags, pos_field_name), p_field.name) = &.{};
                        }
                    } else {
                        if (p_i < pos_count.*) {
                            const arg = pos_buf[p_i];
                            const parsed_pos_val =
                                if (comptime @hasDecl(FlagsType, "parse") and @hasField(@TypeOf(FlagsType.parse), p_field.name)) blk: {
                                    const custom_parser = @field(FlagsType.parse, p_field.name);
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
                                        try ctx.err.print("Error: Invalid value '{s}' for positional argument '{s}'.\n", .{ arg, p_field.name });
                                        return err;
                                    };
                                };
                            @field(@field(parsed_flags, pos_field_name), p_field.name) = parsed_pos_val;
                        }
                    }
                }
            }

            return parsed_flags;
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

        fn assignFlag(
            comptime OrigFlagsT: type,
            comptime FlagsType: type,
            parsed_flags: *FlagsType,
            provided: []bool,
            key: []const u8,
            val: ?[]const u8,
            args: []const []const u8,
            i: *usize,
            ctx: anytype,
        ) !void {
            const stderr = ctx.err;
            var found = false;

            inline for (std.meta.fields(FlagsType), 0..) |field, idx| {
                if (comptime (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) continue;
                if (comptime isPositionalField(field.name)) continue;

                var is_match = std.mem.eql(u8, key, field.name);

                // `--no-<flag>` clears a boolean.
                //
                // Only booleans: "no" is a claim about truth, and offering it for a value
                // flag would have to invent a meaning for `--no-token`. The prefix is
                // matched before the short-flag branch because `no-foo` is never a short
                // flag, and after the exact match so a field genuinely named `no_foo` still
                // wins for its own name.
                var is_negation = false;
                if (!is_match and std.mem.startsWith(u8, key, "no-") and key.len > 3) {
                    if (std.mem.eql(u8, key[3..], field.name)) {
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

                if (is_match) {
                    found = true;
                    provided[idx] = true;

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

                        const parsed_value =
                            if (comptime @hasDecl(FlagsType, "parse") and @hasField(@TypeOf(FlagsType.parse), field.name)) blk: {
                                const custom_parser = @field(FlagsType.parse, field.name);
                                break :blk custom_parser(actual_val.?) catch |err| {
                                    try stderr.print("Error: Invalid format for flag '--{s}'.\n", .{field.name});
                                    return err;
                                };
                            } else if (comptime getGlobalParserIndex(field.type)) |parser_idx| blk: {
                                const global_parser = @field(config.type_parsers, std.meta.fields(@TypeOf(config.type_parsers))[parser_idx].name);
                                break :blk global_parser(actual_val.?) catch |err| {
                                    try stderr.print("Error: Invalid format for flag '--{s}'.\n", .{field.name});
                                    return err;
                                };
                            } else blk: {
                                break :blk parseValue(field.type, actual_val.?) catch |err| {
                                    if (err == error.InvalidCharacter or err == error.InvalidEnumValue) {
                                        try stderr.print("Error: Invalid value '{s}' for flag '--{s}'.\n", .{ actual_val.?, field.name });
                                        return error.HandledError;
                                    }
                                    return err;
                                };
                            };
                        @field(parsed_flags, field.name) = parsed_value;
                    }
                }
            }
            if (!found) {
                try stderr.print("Error: Unknown flag '{s}'.\n", .{key});
                return error.UnknownFlag;
            }
        }

        fn parseValue(comptime T: type, val: []const u8) !T {
            switch (@typeInfo(T)) {
                .int => {
                    return std.fmt.parseInt(T, val, 10);
                },
                .float => {
                    return std.fmt.parseFloat(T, val);
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
        fn writeManPage(comptime cmd: anytype, writer: anytype) !void {
            try writer.print(".TH {s} 1\n.SH NAME\n{s} - {s}\n.SH SYNOPSIS\n.B {s}\n[command] [flags]\n", .{
                cmd.name, cmd.name, cmd.description, cmd.name,
            });
            if (comptime hasSubcommands(@TypeOf(cmd))) {
                const subs = getSubcommands(cmd);
                if (subs.len > 0) {
                    try writer.writeAll(".SH SUBCOMMANDS\n");
                    inline for (subs) |subcmd| {
                        try writer.print(".TP\n.B {s}\n{s}\n", .{ subcmd.name, subcmd.description });
                    }
                }
            }
        }

        fn printHelp(comptime cmd: anytype, ctx: anytype) !void {
            const stdout = ctx.out;

            try stdout.print("Usage: {s}", .{cmd.name});

            // `hasSubcommands` probes both the decl and the field shape. Checking
            // `@hasDecl` alone printed `[args]` for every framework-built command, because
            // `CommandWithReturn` emits `subcommands` as a field.
            if (comptime hasSubcommands(@TypeOf(cmd))) {
                try stdout.writeAll(" [command]\n");
            } else {
                try stdout.writeAll(" [args]\n");
            }

            if (@hasField(@TypeOf(cmd), "description") and cmd.description.len > 0) {
                try stdout.print("{s}\n", .{cmd.description});
            }
            try stdout.writeAll("\n");

            if (comptime hasSubcommands(@TypeOf(cmd))) {
                const subs = getSubcommands(cmd);
                if (subs.len > 0) {
                    try stdout.writeAll("Commands:\n");
                    inline for (subs) |subcmd| {
                        try stdout.print("  {s}\t{s}\n", .{ subcmd.name, subcmd.description });
                    }
                    try stdout.writeAll("\n");
                }
            }

            if (@hasField(@TypeOf(cmd), "run")) {
                comptime var fn_info_val = @typeInfo(@TypeOf(cmd.run));
                if (fn_info_val == .optional) {
                    fn_info_val = @typeInfo(fn_info_val.optional.child);
                }
                if (fn_info_val == .pointer) {
                    fn_info_val = @typeInfo(fn_info_val.pointer.child);
                }

                if (fn_info_val == .@"fn") {
                    const FlagsType = fn_info_val.@"fn".params[1].type.?;
                    const CmdType = @TypeOf(cmd);
                    const OrigFlagsT = if (@hasDecl(CmdType, "OrigFlagsT")) CmdType.OrigFlagsT else FlagsType;

                    comptime var has_flags = false;
                    inline for (std.meta.fields(FlagsType)) |field| {
                        if (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_') continue;
                        if (comptime isPositionalField(field.name)) continue;
                        // A deprecated flag is not advertised. It still works, and using
                        // it warns - but listing it in `--help` would present it as a
                        // current option, which is the one thing a deprecation exists to
                        // stop. Written as a nested comptime guard rather than
                        // `if (comptime …) continue`, which Zig rejects.
                        if (comptime !isDeprecatedFlag(OrigFlagsT, field.name)) {
                            has_flags = true;
                        }
                    }

                    if (has_flags) {
                        try stdout.writeAll("Flags:\n");
                        inline for (std.meta.fields(FlagsType)) |field| {
                            if (field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_') continue;
                            if (comptime isPositionalField(field.name)) continue;

                            if (comptime !isDeprecatedFlag(OrigFlagsT, field.name)) {
                                try stdout.print("  --{s}", .{field.name});

                                var help_text_str: ?[]const u8 = null;

                                if (@hasDecl(OrigFlagsT, "meta")) {
                                    const meta_block = OrigFlagsT.meta;
                                    if (@hasField(@TypeOf(meta_block), field.name)) {
                                        const field_meta = @field(meta_block, field.name);
                                        if (@hasField(@TypeOf(field_meta), "short")) {
                                            try stdout.print(", -{c}", .{field_meta.short});
                                        }
                                        if (@hasField(@TypeOf(field_meta), "help")) {
                                            help_text_str = field_meta.help;
                                        }
                                    }
                                }

                                try stdout.print("\t({s})", .{@typeName(field.type)});

                                if (field.default_value_ptr == null and @typeInfo(field.type) != .optional and field.type != bool) {
                                    try stdout.writeAll(" [required]");
                                }

                                if (help_text_str) |h| {
                                    try stdout.print("\t{s}", .{h});
                                }

                                try stdout.writeAll("\n");
                            }
                        }
                    }
                }
            }
        }

        fn formatOutput(ctx: anytype, result: anytype) !void {
            const T = @TypeOf(result);
            if (T == void) return;

            if (ctx.output_format == .json) {
                try std.json.fmt(result, .{}).format(ctx.out);
                try ctx.out.print("\n", .{});
            } else {
                switch (@typeInfo(T)) {
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
                }
            }
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
                state: anytype,
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
                    .state = state,
                    .env_map = &self.env_map,
                    // No fd backs this Ctx, so `io` is undefined: the assertion is that a
                    // command under test does no platform I/O. A harness that needed a
                    // real `Io` would be a sub-process, which is what this exists to avoid.
                    .io = undefined,
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

        pub fn run(state: *StateT, comptime root_cmd: anytype, init: std.process.Init) !void {
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
                .state = state,
                .env_map = init.environ_map,
                .io = io,
                .is_tty = stdin_is_tty,
                .color_enabled = caps.color,
                .output_format = .text,
            };

            var chain = try ExecutionChain.init(ctx.allocator, filtered_args.items.len);
            defer chain.deinit(ctx.allocator);

            // **A failed command must exit non-zero.** Buffered writers hold output until flushed,
            // so both are flushed *before* the status is decided - `std.process.exit` does not run
            // `defer`, and a command's own error message is still in the buffer at this point.
            //
            // `HandledError` and `UserCancelled` are excluded because they are the framework's own
            // control flow rather than a failure: a command that printed its own diagnostic and
            // returned `error.HandledError` has already decided what the user should see, and a
            // cancelled prompt is not an error. Everything else is a real failure.
            execute(root_cmd, ctx, filtered_args.items, &chain) catch |err| {
                if (err != error.HandledError and err != error.UserCancelled) {
                    ctx.out.flush() catch {};
                    ctx.err.flush() catch {};
                    failWith(err, ctx);
                }
            };

            ctx.out.flush() catch {};
            ctx.err.flush() catch {};
        }

        pub fn executeAutocomplete(
            comptime cmd: anytype,
            ctx: anytype,
            args: []const []const u8,
        ) !void {
            const CmdType = @TypeOf(cmd);

            // Simple autocompletion logic
            if (args.len == 0 or (args.len == 1 and args[0].len == 0)) {
                if (@hasDecl(CmdType, "subcommands")) {
                    inline for (@TypeOf(cmd).subcommands) |sub| {
                        if (!(@hasField(@TypeOf(sub), "hidden") and sub.hidden)) {
                            try ctx.out.print("{s}\n", .{sub.name});
                        }
                    }
                }
                return;
            }

            if (@hasDecl(CmdType, "subcommands")) {
                inline for (@TypeOf(cmd).subcommands) |sub| {
                    if (std.mem.eql(u8, args[0], sub.name)) {
                        return try executeAutocomplete(sub, ctx, args[1..]);
                    }
                }
            }

            const FlagsType = GetFlagsType(CmdType);
            if (FlagsType != void) {
                if (args.len > 0 and std.mem.startsWith(u8, args[args.len - 1], "-")) {
                    inline for (std.meta.fields(FlagsType)) |field| {
                        if (!(field.name.len >= 2 and field.name[0] == '_' and field.name[1] == '_')) {
                            try ctx.out.print("--{s}\n", .{field.name});
                        }
                    }
                } else if (args.len >= 2 and std.mem.startsWith(u8, args[args.len - 2], "-")) {
                    // They are completing a flag value (e.g. `--role `)
                    const flag_name = args[args.len - 2];
                    const clean_name = if (std.mem.startsWith(u8, flag_name, "--")) flag_name[2..] else if (std.mem.startsWith(u8, flag_name, "-")) flag_name[1..] else flag_name;

                    if (@hasDecl(FlagsType, "completion")) {
                        const completions = FlagsType.completion;
                        inline for (std.meta.fields(FlagsType)) |field| {
                            if (std.mem.eql(u8, field.name, clean_name)) {
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
                        if (std.mem.eql(u8, field.name, clean_name)) {
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
        /// The root is an `#` heading and each subcommand gets its own section, so the output
        /// reads as a document rather than one long table. `hasSubcommands` probes both the
        /// decl and the field shape - the same trap that made `printHelp` print `[args]` for
        /// every framework-built command.
        pub fn writeMarkdownDocs(comptime cmd: anytype, writer: anytype, prefix: []const u8) !void {
            const CmdType = @TypeOf(cmd);

            if (prefix.len == 0) {
                try writer.print("# {s}\n\n", .{cmd.name});
            } else {
                try writer.print("## {s}{s}\n\n", .{ prefix, cmd.name });
            }
            if (@hasField(CmdType, "description")) {
                try writer.print("{s}\n\n", .{cmd.description});
            }

            const FlagsType = GetFlagsType(CmdType);
            if (FlagsType != void) {
                var any_flags = false;
                inline for (std.meta.fields(FlagsType)) |field| {
                    if (comptime field.name.len < 2 or field.name[0] != '_' or field.name[1] != '_') {
                        if (comptime !isPositionalField(field.name)) any_flags = true;
                    }
                }
                if (any_flags) {
                    try writer.writeAll("### Flags\n\n| Flag | Type | Default |\n|---|---|---|\n");
                    inline for (std.meta.fields(FlagsType)) |field| {
                        if (comptime field.name.len < 2 or field.name[0] != '_' or field.name[1] != '_') {
                            if (comptime !isPositionalField(field.name)) {
                                if (field.default_value_ptr) |ptr| {
                                    const typed_ptr: *const field.type = @ptrCast(@alignCast(ptr));
                                    try writer.print("| --{s} | {s} | {any} |\n", .{ field.name, @typeName(field.type), typed_ptr.* });
                                } else {
                                    try writer.print("| --{s} | {s} | Required |\n", .{ field.name, @typeName(field.type) });
                                }
                            }
                        }
                    }
                    try writer.writeAll("\n");
                }
            }

            if (comptime hasSubcommands(CmdType)) {
                const subs = getSubcommands(cmd);
                if (subs.len > 0) {
                    try writer.writeAll("## Subcommands\n\n");
                    inline for (subs) |sub| {
                        try writer.print("- **{s}** - {s}\n", .{ sub.name, sub.description });
                    }
                    try writer.writeAll("\n");

                    var next_prefix_buf: [128]u8 = undefined;
                    const next_prefix = try std.fmt.bufPrint(&next_prefix_buf, "{s}{s} ", .{ prefix, cmd.name });
                    inline for (subs) |sub| {
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
