//! `lib/cli` - a dependency-free, app-agnostic CLI framework.
//!
//! This is the module root, and the library's **whole** public surface. It
//! imports only `std` and its own siblings; it knows nothing about any app in
//! this repository. `app/cli` is today's only consumer.
//!
//! ## Using it
//!
//! ```zig
//! const cli = @import("cli");
//!
//! const State = struct {};
//! const App = cli.App(State, cli.Config{});
//!
//! const HelloFlags = struct { name: []const u8 = "world" };
//! const HelloArgs = struct { times: u8 = 1 };
//!
//! const meta = .{
//!     .name = "hello",
//!     .description = "Say hello",
//!     .flags = HelloFlags,
//!     .args = HelloArgs,
//! };
//!
//! pub const HelloCmd = App.command(meta, hello);
//!
//! // The body's own parameters say which shape it is; the framework detects it.
//! // Also accepted: (ctx), (ctx, flags), (ctx, args) and (ctx, args, flags).
//! fn hello(ctx: App.Ctx, flags: App.Flags(HelloFlags), args: HelloArgs) !void {
//!     var i: u8 = 0;
//!     while (i < args.times) : (i += 1) try ctx.out.print("hello {s}\n", .{flags.name});
//! }
//! ```
//!
//! The metadata is registered as **one object** and the body as another, so a command's
//! identity, its types and its behaviour are three separable things. `--flags` and
//! `<arguments>` are separate types too: `flags.positionals.component` is no longer the
//! only way to reach an argument.
//!
//! ## What the framework does for you
//!
//! * **Parsing**: long and short flags, short-flag grouping (`-zxvf`) and attached
//!   short values (`-tvalue`), `--flag=value`, `--no-<bool>`, repeated flags collected
//!   into a slice (`-H a -H b`), positionals including a variadic tail, `--` to stop
//!   parsing, required and optional fields, `--`-added count flags (`-vvv`), and
//!   mutually exclusive groups.
//! * **Typing**: integers, floats, booleans, enums and strings out of the box, a
//!   `parse` declaration per field for anything else, `meta.<field>.validate` and a
//!   `validation` block for rules that are not about type.
//! * **Resolution**: CLI flag > environment (`meta.<field>.env`) > config file
//!   (`Config.config_file`, JSON/YAML/TOML or `KEY=value`) > the struct's default. A
//!   field needs no metadata to be settable from a file.
//! * **Routing**: nested subcommands at any depth, aliases, hidden commands, hooks
//!   (`pre_run`/`post_run`), middleware, and a `Ctx` that carries the allocator,
//!   writers, environment, `Io` and output format.
//! * **UX**: aligned `--help` with defaults, arguments, aliases and dashed spellings;
//!   a replaceable help renderer; a built-in `--version`/`-V`; typo suggestions for
//!   both commands and flags; completion scripts for bash, zsh, fish and PowerShell;
//!   and markdown or man-page documentation.
//! * **Execution**: POSIX exit statuses through `Config.exit_map`, all output through
//!   `Ctx` so commands are testable in memory, and opt-in signal handling with
//!   `App.shutdownSignal()` for a command that needs to clean up.
//!
//! `App(StateT, config)` is a comptime closure: it returns a struct whose
//! `command`/`Flags`/`Ctx`/`ExecutionChain`/`execute` are specialised to your
//! `StateT` and framework `config`. Everything the framework needs is reached
//! through that one type, which is why the declaration below is a function and
//! not a plain struct.
//!
//! ## Layout
//!
//! The framework entry point used to be this module's root, as the 1,900-line
//! file `cli.zig`. `root.zig` now owns the *surface* and `cli.zig` owns the
//! framework, which is the shape `src/zig/README.md` and `.agents/AGENTS.md`
//! prescribe for every library in this tree ("the entry point or surface for a
//! library must be `root.zig` or named after the module"). Both are kept
//! importable so the `@import("cli.zig")` path in the test suite and the
//! `@import("cli")` module name in `app/cli` are unchanged.
//!
//! The sibling modules are grouped by concern:
//!
//!   * `render/`   - turning data into terminal bytes: styling, tables, colour,
//!                   layout, graphics, progress, paging, the screen model and
//!                   the escape-sequence emitters.
//!   * `interact/` - reading the user: widgets, text buffers, raw mode, the TTY
//!                   handle, crash-time terminal restore, and `prompt`.
//!   * `secrets/`  - wiping, redacting, locked pages and encryption at rest.
//!   * `platform/` - the process and OS surface that is genuinely about running
//!                   a command-line program: daemons and pid files, process
//!                   titles, sandboxing, self-update, distribution specs, shell
//!                   integration and the crash reporter.
//!
//! **Configuration is not here.** It lives in `lib/cfg`, because none of it is
//! CLI-specific, and `lib/cli` re-exports it for its own consumers. The same is
//! true of the eleven application-agnostic primitives that used to sit in
//! `platform/` (mmap, cas, task graphs, a VFS, a cancelled-flag, ...): they are
//! in `lib/util` now. Both moves are recorded in `app/cli/lib/ROADMAP.md` U-0, and
//! the test for "does this belong in `lib/cli`" is whether a program that is
//! *not* a CLI would reasonably want it.
//!
//! What stays at the top level is deliberate: this file (the surface),
//! `cli.zig` (the framework), `test/cli_test.zig` (the suite), and the small
//! leaves nothing else depends on - `alias.zig`, `i18n.zig`, `version.zig` and
//! `repl.zig`. `repl.zig` stays because the live REPL implementation is still
//! inside `cli.zig`; moving the stub into a subdirectory would create a second
//! thing called "repl" in a new place. `app/cli/lib/ROADMAP.md` item S-5 merges
//! them, and S-1 records the plan for splitting `cli.zig` itself.

const std = @import("std");

/// The framework implementation. Kept reachable by name so the
/// `@import("cli.zig")` path keeps working, and so the completeness guard
/// below has something to compare the surface against.
pub const framework = @import("cli.zig");

// -- The framework's own surface ---------------------------------------------
//
// Re-exported explicitly rather than star-exported, so this file *is* the
// declared surface and the guard below can prove it stayed complete. Adding a
// `pub` declaration to `cli.zig` without adding it here is a test failure, not
// a silent narrowing of the library's API.

/// The framework closure: `App(StateT, config)` returns a struct whose members
/// are specialised to your state type. Everything else here is what you pass
/// *into* that closure.
pub const App = framework.App;

/// The framework's configuration: buffer sizes and the custom error/exit-code
/// map.
pub const Config = framework.Config;

/// Defaults read from a file, and how to read them: the layer between the
/// environment and a field's own default.
pub const ConfigFile = framework.ConfigFile;

/// One entry of `Config.exit_map`, mapping an error name to a process exit code.
pub const ExitMap = framework.ExitMap;

/// Structured output formats understood by `App.execute`'s result renderer.
pub const OutputFormat = framework.OutputFormat;

/// The shared error set every command may return. See `ROADMAP.md` item M-3
/// before changing it: two of its members are reflected out of `std`
/// signatures at comptime. `App.Error` is the same set.
pub const AppError = framework.AppError;

/// Global flags merged into every command's flag struct by `App.Flags`.
pub const GlobalFlags = framework.GlobalFlags;

/// External subcommands, discovered on `PATH`.
///
/// A command line that names an unregistered command runs `<prefix>-<name>` when an app
/// opts in with `Config{ .plugins = .{ .enabled = true, .prefix = "myapp" } }`. Off by
/// default, because it lets any executable on the path extend the command line.
pub const Plugins = framework.Plugins;

/// Parses a `--log-level` value.
pub const parseLogLevel = framework.parseLogLevel;

/// Finds and parses `--log-level` anywhere in an argument list.
pub const extractLogLevel = framework.extractLogLevel;

/// Renders a flag struct as indented text, honouring each field's
/// `meta.<field>.secret` flag to redact it.
pub const formatFlags = framework.formatFlags;

// -- What is deliberately *not* re-exported here ------------------------------
//
// `Command`, `CommandWithReturn`, `LeafCommand`, `Flags`, `MergeFlags`,
// `ExecutionChain` and `TestHarness` are members of the `App` closure, not of this
// module: each is specialised to the `StateT` and `config` an `App` was created
// with (`Flags` merges the global flags, `ExecutionChain` carries `Ctx`, a command's
// `run` takes `Ctx`). They are spelled `App.Command`, `App.Flags`, and so on.
//
// This file used to *claim* to re-export them - `pub const Command = framework.Command;`
// and six siblings - and none of those declarations existed, so `@import("cli").Command`
// did not compile. Nothing noticed, because Zig analyses a declaration only when
// something refers to it and no caller or test ever did: every consumer already writes
// `App.Command`. The guard at the bottom of this file now checks both directions, so a
// re-export that names something the framework does not have is a build failure rather
// than a broken promise.

// -- The sub-modules the framework composes ----------------------------------
//
// Reached through `@import("cli")` - for example
// `cli.prompt.multiSelectDynamic`. They live here so the module root lists the
// surface in one place.

// The sub-folder surfaces. Each folder has a `root.zig`; these are those entry
// points, as opposed to the individual leaf re-exports below.
pub const render = framework.render;
pub const interact = framework.interact;
pub const secrets = framework.secrets;
pub const platform = framework.platform;

pub const tea = framework.tea;
pub const style = framework.style;
pub const zconfig = framework.zconfig;
pub const mergeJson = framework.mergeJson;
pub const prompt = framework.prompt;
pub const i18n = framework.i18n;
pub const panic = framework.panic;
pub const progress = framework.progress;
pub const pager = framework.pager;
pub const widgets = framework.widgets;
pub const sys = framework.sys;
pub const security = framework.security;
pub const telemetry = framework.telemetry;
pub const trace_parent = framework.trace_parent;
pub const profiler = framework.profiler;
pub const vfs = framework.vfs;
pub const tasks = framework.tasks;
pub const daemon = framework.daemon;
pub const xdg = framework.xdg;
/// Reading and writing state, caches and tokens in the standard directories.
///
/// Atomic replace, parent-directory creation and owner-only permissions for secret
/// material, on top of `xdg`'s per-OS table - which is what an app uses for
/// `~/.config/app`, `~/.cache/app` and a stored auth token.
pub const state = framework.state;
/// The path of the running executable.
///
/// `std.process.Init` in Zig 0.16 carries the environment, the arguments, an arena, an
/// allocator, an `Io` and the preopened directories - and not the program's own path, and
/// there is no `std.process.selfExePath`. This is the replacement, and it is what an app
/// passes as `App.updateCommand`'s `resolve_target`.
pub const self_exe = framework.self_exe;
/// The crash reporter: a banner, a stack trace and a JSON report on panic.
///
/// Reachable as `cli.crash.Panic(.{ … })`, the spelling the module's own documentation
/// has always told consumers to use; before this re-export only `cli.platform.crash`
/// resolved, so the documented path did not compile.
pub const crash = framework.crash;
pub const process = framework.process;
pub const signal = framework.signal;
pub const log = framework.log;
pub const text_input = framework.text_input;
pub const update = framework.update;
pub const detach = framework.detach;
pub const spinner = framework.spinner;
pub const capability = framework.capability;
pub const cancellation = framework.cancellation;
pub const alias = framework.alias;
pub const oauth = framework.oauth;
pub const layout = framework.layout;
pub const color = framework.color;
pub const raw_terminal = framework.raw_terminal;
pub const graphics = framework.graphics;
pub const updater = framework.updater;
pub const headless = framework.headless;
pub const repl = framework.repl;
pub const vte = framework.vte;
pub const mmap = framework.mmap;
pub const tty_stream = framework.tty_stream;
pub const supervisor = framework.supervisor;
pub const sandbox = framework.sandbox;
pub const proctitle = framework.proctitle;
pub const linter = framework.linter;
pub const wasm_bridge = framework.wasm_bridge;
pub const dag = framework.dag;
pub const openapi = framework.openapi;
pub const decstbm = framework.decstbm;
pub const virtual_terminal = framework.virtual_terminal;
pub const spatial_focus = framework.spatial_focus;
pub const rope = framework.rope;
pub const cas = framework.cas;
pub const btree_store = framework.btree_store;
pub const object_pipe = framework.object_pipe;
pub const dry_run = framework.dry_run;
pub const fido2 = framework.fido2;
pub const policy = framework.policy;
pub const secure_heap = framework.secure_heap;
pub const dynlib_reloader = framework.dynlib_reloader;
pub const dist_specs = framework.dist_specs;
pub const footprint = framework.footprint;
pub const remote_config = framework.remote_config;
pub const ota_flags = framework.ota_flags;
pub const config_lineage = framework.config_lineage;
pub const profiles = framework.profiles;
pub const config_diff = framework.config_diff;
pub const schema_migration = framework.schema_migration;
pub const comptime_config = framework.comptime_config;
pub const encrypted_config = framework.encrypted_config;
pub const secret_val = framework.secret_val;
pub const toml_mutator = framework.toml_mutator;
pub const config_dryrun = framework.config_dryrun;
pub const systemd_exporter = framework.systemd_exporter;

/// The library's test suite: the framework and every sub-module.
///
/// This import is what makes the suite run, and it is load-bearing - see the
/// `test` block below. Before it existed, `cli_test.zig` was unreachable from
/// any module root and none of its tests had ever executed in this
/// repository, while the code they cover shipped in `snek`.
const suite = @import("test/cli_test.zig");

test {
    // `refAllDecls` is **shallow on purpose**: it references the declarations of
    // the namespace it is handed, and a test block is collected only when some
    // declaration in that namespace references it. Importing a file is not
    // enough, and reaching *through* one file into a third is not enough
    // either. Both namespaces below are therefore named explicitly, and
    // `ROADMAP.md` item M-2 records the rule so the next module does not have
    // to rediscover it.
    //
    // Measured, because the failure is silent: with the `suite` line removed,
    // this module reports the sub-modules' tests only - a drop of more than two
    // hundred - and `zig build test` still exits 0.
    std.testing.refAllDecls(framework);
    std.testing.refAllDecls(suite);
}

// Fails the build if `cli.zig` grows a `pub` declaration this file does not
// re-export, **or** if this file re-exports something `cli.zig` does not have.
//
// The re-export list above is hand-written, so it is exactly the kind of thing
// that drifts: someone adds `pub const Foo` to the framework, every test still
// passes, and `@import("cli").Foo` is suddenly missing for consumers. This
// turns that into a compile error naming the forgotten declaration.
//
// The second direction is not hypothetical. `AppError` and `Error` were
// re-exported here for a long time while `cli.zig` declared neither at file
// scope, so `@import("cli").AppError` did not compile - and nothing noticed,
// because Zig analyses a declaration only when something references it, and no
// test did. A dangling re-export is a broken public surface, so it is checked
// here too.
test "root.zig and cli.zig declare the same public surface" {
    // `@typeInfo(...).decls` is an array, so the loop is unrollable; the
    // `std.meta.declarations` slice variant is not.
    const framework_decls = @typeInfo(framework).@"struct".decls;
    const root_decls = @typeInfo(@This()).@"struct".decls;
    comptime var missing_names: []const u8 = "";
    comptime var dangling_names: []const u8 = "";

    inline for (framework_decls) |decl| {
        if (comptime !@hasDecl(@This(), decl.name)) {
            missing_names = missing_names ++ " " ++ decl.name;
        }
    }

    inline for (root_decls) |decl| {
        // `framework` is this file's own handle on the implementation, so it is the
        // one name that is expected to be absent from it.
        if (comptime !std.mem.eql(u8, decl.name, "framework")) {
            if (comptime !@hasDecl(framework, decl.name)) {
                dangling_names = dangling_names ++ " " ++ decl.name;
            }
        }
    }

    comptime {
        if (missing_names.len > 0) {
            @compileError("app/cli/lib/root.zig is missing re-exports for:" ++ missing_names);
        }
        if (dangling_names.len > 0) {
            @compileError("app/cli/lib/root.zig re-exports declarations cli.zig does not have:" ++ dangling_names);
        }
    }
}
