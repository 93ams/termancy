//! `platform` - the operating system, as a command-line program needs it, grouped by
//! concern: `system`, `security`, `observability`, `distribution`. Every file is also
//! re-exported under a flat name (`platform.dirs`, `platform.log`, ...).
//!
//! The module imports only `std`. Nothing here starts a thread, opens a socket, or writes a
//! file unless the caller calls a function that says it does.

const std = @import("std");

/// Directories, processes, signals, files, daemons: the OS as a program uses it.
pub const system = @import("system/root.zig");
pub const dirs = system.dirs;
pub const exe = system.exe;
pub const env = system.env;
pub const process = system.process;
pub const signal = system.signal;
pub const files = system.files;
pub const daemon = system.daemon;
pub const proctitle = system.proctitle;
pub const dynlib = system.dynlib;

/// Secure memory, path sandboxing, OAuth, WebAuthn.
pub const security = @import("security/root.zig");
pub const secure = security.secure;
pub const sandbox = security.sandbox;
pub const oauth = security.oauth;
pub const webauthn = security.webauthn;
pub const ctap = security.ctap;
pub const windows_hello = security.windows_hello;
pub const mnemonic = security.mnemonic;

/// SSH keys, signatures, and a server for terminal programs.
pub const ssh = @import("ssh/root.zig");

/// A terminal in the browser: a page and a WebSocket server for terminal programs.
pub const web = @import("web/root.zig");

/// Logging, crash reports, phase timing, trace context, opt-in telemetry.
pub const observability = @import("observability/root.zig");
pub const log = observability.log;
pub const crash = observability.crash;
pub const profiler = observability.profiler;
pub const trace = observability.trace;
pub const telemetry = observability.telemetry;

/// Semantic versions, self-update, package manifests.
pub const distribution = @import("distribution/root.zig");
pub const version = distribution.version;
pub const update = distribution.update;
pub const manifests = distribution.manifests;
pub const remote = distribution.remote;

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(system);
    std.testing.refAllDecls(security);
    std.testing.refAllDecls(observability);
    std.testing.refAllDecls(distribution);
    std.testing.refAllDecls(ssh);
    std.testing.refAllDecls(web);
    _ = @import("fuzz.zig");
}
