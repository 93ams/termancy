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
//!
//! const HelloCmd = App.Command(HelloFlags, .{}){
//!     .name = "hello",
//!     .description = "Say hello",
//!     .run = struct {
//!         fn run(ctx: App.Ctx, flags: App.Flags(HelloFlags)) !void {
//!             try ctx.out.print("hello {s}\n", .{flags.name});
//!         }
//!     }.run,
//! };
//! ```
//!
//! `App(StateT, config)` is a comptime closure: it returns a struct whose
//! `Command`/`Flags`/`Ctx`/`ExecutionChain`/`execute` are specialised to your
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

/// One entry of `Config.exit_map`, mapping an error name to a process exit code.
pub const ExitMap = framework.ExitMap;

/// Structured output formats understood by `App.execute`'s result renderer.
pub const OutputFormat = framework.OutputFormat;

/// The shared error set every command may return. See `ROADMAP.md` item M-3
/// before changing it: two of its members are reflected out of `std`
/// signatures at comptime.
pub const AppError = framework.AppError;

/// Historical alias of `AppError`.
pub const Error = framework.Error;

/// Global flags merged into every command's flag struct.
pub const GlobalFlags = framework.GlobalFlags;

/// Defines a leaf command type. Shorthand for `Command(T, .{})`.
pub const LeafCommand = framework.LeafCommand;

/// Defines a command type, optionally with subcommands.
pub const Command = framework.Command;

/// Like `Command`, but the command's `run` returns a value that the framework
/// renders according to `OutputFormat`.
pub const CommandWithReturn = framework.CommandWithReturn;

/// The flags type a command's `run` receives: your flags merged with
/// `GlobalFlags`.
pub const Flags = framework.Flags;

/// Merges two flag structs into one. The primitive behind `Flags`.
pub const MergeFlags = framework.MergeFlags;

/// Per-invocation state threaded through routing, pre/post runs and the shell.
pub const ExecutionChain = framework.ExecutionChain;

/// In-memory harness for driving a command tree from a unit test.
pub const TestHarness = framework.TestHarness;

/// Parses a `--log-level` value.
pub const parseLogLevel = framework.parseLogLevel;

/// Finds and parses `--log-level` anywhere in an argument list.
pub const extractLogLevel = framework.extractLogLevel;

/// Renders a flag struct as indented text, honouring each field's
/// `meta.<field>.secret` flag to redact it.
pub const formatFlags = framework.formatFlags;

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
pub const version = framework.version;
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
pub const process = framework.process;
pub const signal = framework.signal;
pub const log = framework.log;
pub const text_input = framework.text_input;
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

/// The library's test suite: 91 tests over the framework and every sub-module.
///
/// This import is what makes the suite run, and it is load-bearing - see the
/// `test` block below. Before it existed, `cli_test.zig` was unreachable from
/// any module root and none of its 91 tests had ever executed in this
/// repository, while the code they cover shipped in `tigershark`.
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
    // this module reports 1 test instead of 92 and `zig build test-lib` still
    // exits 0.
    std.testing.refAllDecls(framework);
    std.testing.refAllDecls(suite);
}

// Fails the build if `cli.zig` grows a `pub` declaration this file does not
// re-export.
//
// The re-export list above is hand-written, so it is exactly the kind of thing
// that drifts: someone adds `pub const Foo` to the framework, every test still
// passes, and `@import("cli").Foo` is suddenly missing for consumers. This
// turns that into a compile error naming the forgotten declaration.
test "root.zig re-exports every public declaration of cli.zig" {
    // `@typeInfo(...).decls` is an array, so the loop is unrollable; the
    // `std.meta.declarations` slice variant is not.
    const decls = @typeInfo(framework).@"struct".decls;
    comptime var missing_names: []const u8 = "";

    inline for (decls) |decl| {
        if (comptime !@hasDecl(@This(), decl.name)) {
            missing_names = missing_names ++ " " ++ decl.name;
        }
    }

    comptime {
        if (missing_names.len > 0) {
            @compileError("app/cli/lib/root.zig is missing re-exports for:" ++ missing_names);
        }
    }
}
