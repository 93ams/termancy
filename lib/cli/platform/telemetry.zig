//! Telemetry opt-out: the `DO_NOT_TRACK` and `CI` checks.
//!
//! `pub fn isOptedOut` is a genuine free function - it has no state and no
//! "self" - so this file is not a type and does not pretend to be one. It used to
//! wrap that one function in a `pub const Telemetry = struct { ... }`, which
//! meant consumers wrote `telemetry.Telemetry.isOptedOut(env)`; now they write
//! `telemetry.isOptedOut(env)`. See the file-layout rule in `.agents/AGENTS.md`.
//!
//! The `traceparent` header type and the phase timer that used to share this file
//! are now `trace_parent.zig` and `profiler.zig`, because a file with three
//! unrelated subjects is exactly what the "no wrapper struct" rule cannot
//! express. The W3C codec itself is `lib/util/trace.zig`, shared with the bus.

const std = @import("std");

/// True when the environment asks for telemetry to be disabled.
///
/// Honours `DO_NOT_TRACK=1` (the cross-project convention) and `CI` being set to
/// `true` or `1`, because a build pipeline should not emit telemetry by default.
pub fn isOptedOut(env_map: *std.process.Environ.Map) bool {
    if (env_map.get("DO_NOT_TRACK")) |val| {
        if (std.mem.eql(u8, val, "1")) return true;
    }
    if (env_map.get("CI")) |val| {
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
    }
    return false;
}

test "DO_NOT_TRACK and CI are both honoured" {
    // A fresh map per case: `std.process.Environ.Map` has `put`/`get` but no
    // `remove`, so a key cannot be unset once set.
    var empty = std.process.Environ.Map.init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expect(!isOptedOut(&empty));

    var do_not_track = std.process.Environ.Map.init(std.testing.allocator);
    defer do_not_track.deinit();
    try do_not_track.put("DO_NOT_TRACK", "1");
    try std.testing.expect(isOptedOut(&do_not_track));

    var ci_true = std.process.Environ.Map.init(std.testing.allocator);
    defer ci_true.deinit();
    try ci_true.put("CI", "true");
    try std.testing.expect(isOptedOut(&ci_true));

    var ci_zero = std.process.Environ.Map.init(std.testing.allocator);
    defer ci_zero.deinit();
    try ci_zero.put("CI", "0");
    try std.testing.expect(!isOptedOut(&ci_zero));

    // Only "1" counts for DO_NOT_TRACK; "true" is a different convention.
    var dnt_true = std.process.Environ.Map.init(std.testing.allocator);
    defer dnt_true.deinit();
    try dnt_true.put("DO_NOT_TRACK", "true");
    try std.testing.expect(!isOptedOut(&dnt_true));
}
