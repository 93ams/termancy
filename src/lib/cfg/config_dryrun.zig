//! Override parsing and a pass/fail matrix for a configuration dry run.
//!
//! This file **is** the type: the file's own scope is the `ConfigDryRun` struct,
//! so a consumer writes `const ConfigDryRun = @import("config_dryrun.zig");`. See
//! the file-layout rule in `.agents/AGENTS.md`.
//!
//! `ValidationResult` stays a declaration inside, because it is what
//! `renderMatrix` takes and the two are one subject. Note what this module does
//! **not** do: it contains no validation. `parseOverride` splits `key=value` and
//! `renderMatrix` prints verdicts the caller already computed, which is recorded
//! as scaffolding in `src/lib/framework/ROADMAP.md` section 5.4.

const std = @import("std");

const Self = @This();

/// One field's verdict, supplied by the caller.
pub const ValidationResult = struct {
    key: []const u8,
    value: []const u8,
    is_valid: bool,
    error_msg: []const u8 = "",
};

/// Splits `key=value` into its two trimmed halves, or null when malformed.
///
/// The returned slices borrow from `override_arg`.
pub fn parseOverride(override_arg: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const eq_idx = std.mem.indexOfScalar(u8, override_arg, '=') orelse return null;
    const key = std.mem.trim(u8, override_arg[0..eq_idx], " ");
    const val = std.mem.trim(u8, override_arg[eq_idx + 1 ..], " ");
    if (key.len == 0) return null;
    return .{ .key = key, .value = val };
}

/// Prints a PASS/FAIL line per result.
pub fn renderMatrix(writer: anytype, results: []const ValidationResult) !void {
    try writer.writeAll("\n\x1b[1m=== Dry-Run Configuration Validation Matrix ===\x1b[0m\n");
    for (results) |res| {
        if (res.is_valid) {
            try writer.print("\x1b[32m[PASS]\x1b[0m {s} = {s}\n", .{ res.key, res.value });
        } else {
            try writer.print("\x1b[31m[FAIL]\x1b[0m {s} = {s} -> {s}\n", .{ res.key, res.value, res.error_msg });
        }
    }
}

test "parseOverride splits and trims, and rejects malformed input" {
    const ok = Self.parseOverride("network.port=8080").?;
    try std.testing.expectEqualStrings("network.port", ok.key);
    try std.testing.expectEqualStrings("8080", ok.value);

    const spaced = Self.parseOverride("  a.b  =  c  ").?;
    try std.testing.expectEqualStrings("a.b", spaced.key);
    try std.testing.expectEqualStrings("c", spaced.value);

    try std.testing.expect(Self.parseOverride("no-equals") == null);
    try std.testing.expect(Self.parseOverride("=novalue") == null);
}

test "renderMatrix marks each verdict" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const results = [_]Self.ValidationResult{
        .{ .key = "a", .value = "1", .is_valid = true },
        .{ .key = "b", .value = "2", .is_valid = false, .error_msg = "bad" },
    };
    try Self.renderMatrix(&w, &results);

    const out = w.buffered();
    // The verdict markers are wrapped in ANSI colour, so `"[PASS] a = 1"` does
    // not appear literally - assert on the text around them instead.
    try std.testing.expect(std.mem.indexOf(u8, out, "[PASS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[FAIL]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b = 2 -> bad") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Validation Matrix") != null);
}
