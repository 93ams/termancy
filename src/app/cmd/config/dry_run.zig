//! `config dry-run` - validate overrides without applying them.
//!
//! Parses `--config-override path=value` (repeatable), checks each against
//! `ConfigT` via `app/cfg/lib/ops/dry_run.zig`, prints the matrix, and exits non-zero if
//! anything failed. It never writes and never invokes the command's run block.

const std = @import("std");
const ops = @import("../lib/ops/root.zig");

/// Flags for `config dry-run`.
pub const DryRunFlags = struct {
    /// Space-separated `path=value` overrides to check.
    ///
    /// A single string rather than a slice of them because the CLI framework renders
    /// a flag value as one `[]const u8` and rejects a slice-of-slices field outright
    /// (`cli.zig:1290`). Space-separating is the honest shape until the framework
    /// grows repeatable flags; the cost is that a value containing a space cannot be
    /// expressed, which `app/cfg/PLAN.md` records.
    overrides: []const u8 = "",

    pub const meta = .{
        .overrides = .{ .help = "Space-separated `path=value` pairs to check" },
    };
};

/// Checks `overrides` against `ConfigT`, printing the matrix.
///
/// Returns `error.ValidationFailed` when any override failed, so a caller decides
/// the exit status. This function does not exit on its own, because a server binary
/// and a test both call it.
pub fn run(
    allocator: std.mem.Allocator,
    writer: anytype,
    comptime ConfigT: type,
    overrides: []const []const u8,
) !void {
    const verdicts = try ops.dry_run.checkAll(ConfigT, allocator, overrides);
    defer allocator.free(verdicts);

    try ops.dry_run.render(writer, verdicts);

    if (!ops.dry_run.allPassed(verdicts)) return error.ValidationFailed;
}

// The command *type* for each of these is declared in `cmd/root.zig`. They are
// not declared here because `AppT.Command(...)` has to be instantiated where`AppT`
// is known, and a file that declares `pub const cmd` cannot be generic over`AppT`.

// -- Tests -----------------------------------------------------------------

const Network = struct {
    port: u16 = 8080,
};

const Fixture = struct {
    name: []const u8 = "svc",
    verbose: bool = false,
    network: Network = .{},
};

test "run prints the matrix and succeeds when everything checks out" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const overrides = [_][]const u8{ "name=hello", "network.port=9000" };
    try run(std.testing.allocator, &w, Fixture, &overrides);

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[PASS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name = hello") != null);
}

test "run fails, after printing, when an override does not check out" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const overrides = [_][]const u8{"network.port=nope"};
    try std.testing.expectError(error.ValidationFailed, run(std.testing.allocator, &w, Fixture, &overrides));

    // The matrix is still printed, so the user sees which one failed.
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[FAIL]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "network.port = nope") != null);
}

test "run reports every failing override rather than only the first" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const overrides = [_][]const u8{ "nope=1", "verbose=maybe", "name=ok" };
    try std.testing.expectError(error.ValidationFailed, run(std.testing.allocator, &w, Fixture, &overrides));

    const out = w.buffered();
    // Two failures and one pass, all present.
    var fails: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "[FAIL]")) |at| {
        fails += 1;
        idx = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fails);
    try std.testing.expect(std.mem.indexOf(u8, out, "[PASS]") != null);
}

test "no overrides is a vacuous pass, not an error" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, Fixture, &.{});
}
