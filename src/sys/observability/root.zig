//! `observability` - what a program says about itself: logs, crash reports, phase timings,
//! trace context, and opt-in telemetry.
//!
//! Nothing here starts a thread, opens a socket, or writes a file unless the caller calls a
//! function that says it does.

const std = @import("std");

pub const log = @import("log.zig");
pub const crash = @import("crash.zig");
pub const profiler = @import("profiler.zig");
pub const trace = @import("trace.zig");
pub const telemetry = @import("telemetry.zig");

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(log);
    std.testing.refAllDecls(crash);
    std.testing.refAllDecls(profiler);
    std.testing.refAllDecls(trace);
    std.testing.refAllDecls(telemetry);
}
