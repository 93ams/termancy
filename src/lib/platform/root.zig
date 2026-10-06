//! `platform` - the operating system, as this application uses it.
//!
//! Files and paths, processes and signals, the crash reporter, telemetry, the updater, and the XDG locations for state. Everything here is per-OS or reaches outside the process; nothing here is terminal rendering.
//!
//! This file is the module's public surface. `lib.zig` is the folder's own
//! re-export list, and its declarations are inherited below so that a consumer writes
//! `platform.thing` rather than `platform.lib.thing` - which is how this folder was reached
//! before the module split.

const std = @import("std");

/// The folder's own re-exports.
pub const lib = @import("lib.zig");
pub const daemon = lib.daemon;
pub const dist_specs = lib.dist_specs;
pub const dynlib_reloader = lib.dynlib_reloader;
pub const fido2 = lib.fido2;
pub const headless = lib.headless;
pub const oauth = lib.oauth;
pub const openapi = lib.openapi;
pub const panic = lib.panic;
pub const crash = lib.crash;
pub const proctitle = lib.proctitle;
pub const sandbox = lib.sandbox;
pub const sys = lib.sys;
pub const xdg = lib.xdg;
pub const self_exe = lib.self_exe;
pub const state = lib.state;
pub const process = lib.process;
pub const signal = lib.signal;
pub const log = lib.log;
pub const detach = lib.detach;
pub const systemd_exporter = lib.systemd_exporter;
pub const telemetry = lib.telemetry;
pub const trace_parent = lib.trace_parent;
pub const profiler = lib.profiler;
pub const updater = lib.updater;
pub const update = lib.update;
pub const wasm_bridge = lib.wasm_bridge;

test {
    // Shallow by design: a `test` block is collected only when a declaration in the
    // namespace references it, so lib is named here and lib.zig names each of its own
    // sub-modules. A subdirectory missing from that list loses its tests silently
    // rather than failing the build - see ROADMAP.md M-2.
    std.testing.refAllDecls(lib);
}
