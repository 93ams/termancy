//! `app/cli/lib/platform` - the OS and process surface a command-line program needs.
//!
//! Everything here is about *running* a CLI: daemons and pid files, process
//! titles, sandboxing, self-update, distribution specs, shell/service
//! integration, crash reporting and tracing.
//!
//! What is deliberately **not** here any more, and where it went:
//!
//!   * configuration (`config`, `profiles`, `schema_migration`, ...) -> `lib/cfg`
//!   * application-agnostic primitives (`mmap`, `cas`, `tasks`, `dag`, `vfs`,
//!     `dry_run`, `object_pipe`, `cancellation`, `linter`, `footprint`,
//!     `btree_store`) -> `lib/util`
//!   * the shared W3C trace context -> `lib/util/trace.zig`, which
//!     `telemetry.zig` here is now a thin adapter over
//!
//! See `app/cli/lib/ROADMAP.md` U-0. `app/cli/lib/cli.zig` re-exports each file below
//! under its historical flat name (`cli.sys`, `cli.panic`, ...).

const std = @import("std");

/// Pid files and the daemonisation helpers.
pub const daemon = @import("daemon.zig");
/// Homebrew/Scoop/Arch packaging templates.
pub const dist_specs = @import("dist_specs.zig");
/// Hot-reloading a dynamic library.
pub const dynlib_reloader = @import("dynlib_reloader.zig");
/// FIDO2 prompt scaffolding. Does no WebAuthn; see ROADMAP section 5.4.
pub const fido2 = @import("fido2.zig");
/// A headless terminal buffer for golden-output assertions.
pub const headless = @import("headless.zig");
/// The RFC 8628 device-authorization flow.
pub const oauth = @import("oauth.zig");
/// Comptime OpenAPI description generation from a command tree.
pub const openapi = @import("openapi.zig");
/// Panic rendering and crash reporting.
pub const panic = @import("panic.zig");
/// Process title and argv scrubbing.
pub const proctitle = @import("proctitle.zig");
/// Path-allowance policy for generated code. Fails open; see ROADMAP 5.4.
pub const sandbox = @import("sandbox.zig");
/// Elevation checks, desktop notifications, `$EDITOR` launching.
pub const sys = @import("sys.zig");
/// Standard application directories, resolved per platform and per XDG variable.
pub const xdg = @import("xdg.zig");
/// Running a child process, captured or streamed.
pub const process = @import("process.zig");
/// `.env` and systemd unit export. Now owned by `lib/util`; re-exported here under
/// its historical name so `cli.systemd_exporter` keeps resolving.
pub const systemd_exporter = @import("util").systemd_exporter;
/// Telemetry opt-out (`DO_NOT_TRACK`, `CI`). Free functions, not a type.
pub const telemetry = @import("telemetry.zig");
/// The framework's `traceparent` header type. The codec is `lib/util/trace.zig`.
pub const trace_parent = @import("trace_parent.zig");
/// A coarse parse/execute phase timer.
pub const profiler = @import("profiler.zig");
/// Self-update. Recreates the binary without preserving its mode; see ROADMAP 5.4.
pub const updater = @import("updater.zig");
/// A string-in/string-out bridge for a wasm host.
pub const wasm_bridge = @import("wasm_bridge.zig");

test {
    // Shallow by design; every namespace is named. See `app/cli/lib/ROADMAP.md` M-2.
    std.testing.refAllDecls(daemon);
    std.testing.refAllDecls(dist_specs);
    std.testing.refAllDecls(dynlib_reloader);
    std.testing.refAllDecls(fido2);
    std.testing.refAllDecls(headless);
    std.testing.refAllDecls(oauth);
    std.testing.refAllDecls(openapi);
    std.testing.refAllDecls(panic);
    std.testing.refAllDecls(proctitle);
    std.testing.refAllDecls(sandbox);
    std.testing.refAllDecls(sys);
    std.testing.refAllDecls(xdg);
    std.testing.refAllDecls(process);
    std.testing.refAllDecls(systemd_exporter);
    std.testing.refAllDecls(telemetry);
    std.testing.refAllDecls(trace_parent);
    std.testing.refAllDecls(profiler);
    std.testing.refAllDecls(updater);
    std.testing.refAllDecls(wasm_bridge);
}
