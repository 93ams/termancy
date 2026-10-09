//! `framework` - the command framework: routing, flags, help, execution, the REPL.
//!
//! This is the surface a consumer builds an application from: `App(StateT, config)`
//! produces a typed command tree, and `App.run` owns the bootstrap. It is the one module
//! that depends on nearly every other, which is why `SPEC.md`'s layering
//! (REQ-LAYOUT-008) points one way: `framework` imports `render`, `platform`, `interact`,
//! `secrets`, `cfg` and `util`, and none of them imports `framework`.
//!
//! History: this was `src/lib/framework`, a single module holding the framework, the rendering
//! layer, the platform layer, the prompts and the secret handling together. `SPEC.md`
//! records the split; each of those is now its own module with its own root, and the
//! aliases below (`render`, `interact`, `secrets`, `platform`) are kept so a consumer
//! that reached them through this namespace still can.
//!
//! The re-export list is the module's public surface. `ROADMAP.md` M-2 records why
//! `refAllDecls` is shallow and why the declarations are named rather than globbed.

const std = @import("std");
const framework = @import("cli.zig");
pub const App = framework.App;
pub const Config = framework.Config;
pub const ConfigFile = framework.ConfigFile;
pub const ExitMap = framework.ExitMap;
pub const OutputFormat = framework.OutputFormat;
pub const AppError = framework.AppError;
pub const GlobalFlags = framework.GlobalFlags;
pub const Plugins = framework.Plugins;
pub const parseLogLevel = framework.parseLogLevel;
pub const extractLogLevel = framework.extractLogLevel;
pub const formatFlags = framework.formatFlags;
pub const render = framework.render;
pub const interact = framework.interact;
pub const secrets = framework.secrets;
pub const platform = framework.platform;
pub const tea = framework.tea;
pub const style = framework.style;
pub const cfg = framework.zconfig;
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
pub const state = framework.state;
pub const self_exe = framework.self_exe;
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

test {
    // Shallow by design: a `test` block is collected only when a declaration in the
    // namespace references it, so each namespace this module owns is named explicitly.
    std.testing.refAllDecls(framework);
    std.testing.refAllDecls(@import("alias.zig"));
    std.testing.refAllDecls(@import("docs.zig"));
    std.testing.refAllDecls(@import("i18n.zig"));
    std.testing.refAllDecls(@import("policy.zig"));
    std.testing.refAllDecls(@import("repl.zig"));
}
