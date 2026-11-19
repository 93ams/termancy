//! `sys/system` - the operating system as a command-line program meets it: directories,
//! the executable, the environment, child processes, signals, files, daemons, the process
//! title, and shared libraries.
//!
//! Imports only `std` and `builtin`. Nothing here starts a thread or a timer, or touches the
//! file system, unless the function called says it does.

const std = @import("std");

/// Config, cache, data, state, runtime, bin, and temp directories per OS; the config
/// search path.
pub const dirs = @import("dirs.zig");
/// Run children captured (with a timeout) or streamed; `which`; the editor, also for a
/// string; opening URLs; PID liveness.
pub const process = @import("process.zig");
/// The path of the running executable.
pub const exe = @import("exe.zig");
/// CI detection, `DO_NOT_TRACK`, elevated privileges, host name, user name, shell.
pub const env = @import("env.zig");
/// Ctrl-C and termination requests (and opt-in hangup and quit) as a polled flag; exit
/// status 130.
pub const signal = @import("signal.zig");
/// Atomic writes, PID lock files with stale-lock recovery, a private state store.
pub const files = @import("files.zig");
/// PID files, `daemonize` on POSIX, `detach` on every OS, systemd units.
pub const daemon = @import("daemon.zig");
/// Scrubbing secret flag values from the arguments `ps` shows.
pub const proctitle = @import("proctitle.zig");
/// Loading shared libraries and hot-reloading them on request.
pub const dynlib = @import("dynlib.zig");
/// The local time zone: offset and abbreviation at an instant, from `TZ`, zoneinfo, or
/// Windows.
pub const timezone = @import("timezone.zig");

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(dirs);
    std.testing.refAllDecls(process);
    std.testing.refAllDecls(exe);
    std.testing.refAllDecls(env);
    std.testing.refAllDecls(signal);
    std.testing.refAllDecls(files);
    std.testing.refAllDecls(daemon);
    std.testing.refAllDecls(proctitle);
    std.testing.refAllDecls(dynlib);
    std.testing.refAllDecls(timezone);
}
