//! Dry-run validation: does this override make sense against this config?
//!
//! The point is to answer that **before** anything is applied or written. A user
//! who types `config set network.port not-a-port` should learn that immediately,
//! and a dry-run pipeline should be able to report every problem at once rather than
//! dying on the first.
//!
//! ## What "valid" means here, precisely
//!
//! A check passes when **both** hold:
//!
//! 1. the path names a field that exists on `ConfigT` (dotted paths walk one level of
//!    nesting, so `network.port` is checked against `ConfigT.network.port`), and
//! 2. the value parses into that field's declared type.
//!
//! That is deliberately *structural*, not semantic. `src/lib/cfg`'s meta supports
//! `.help`, `.env` and `.secret`, but it does **not** have a `.validate` hook - the
//! format specification assumed one and `src/lib/framework/ROADMAP.md` P-2 records the gap. So
//! "is port 99999 within this deployment's range" cannot be answered here, and this
//! module does not pretend otherwise. Adding `.validate` is what turns this from a
//! shape check into a policy check.
//!
//! ## Why the walk is comptime
//!
//! `ConfigT` is comptime-known, so each candidate field name is bound by an `inline
//! for` and compared with `comptime std.mem.eql`. Comparing a runtime string against
//! `field.name` directly is a compile error ("unable to resolve comptime value"),
//! which is what forced this shape.

const std = @import("std");
const cfg = @import("cfg");
const dryrun = cfg.config_dryrun;
const fields = @import("fields.zig");

/// The outcome of checking one override.
pub const Verdict = struct {
    /// The path as the user wrote it.
    path: []const u8,
    /// The value as the user wrote it. Never a resolved value.
    value: []const u8,
    ok: bool,
    /// Why it failed. Empty when `ok`.
    problem: []const u8 = "",
};

/// Checks one `path=value` override against `ConfigT`.
pub fn checkOne(comptime ConfigT: type, override_arg: []const u8) Verdict {
    const parsed = dryrun.parseOverride(override_arg) orelse return .{
        .path = override_arg,
        .value = "",
        .ok = false,
        .problem = "expected `path=value`",
    };

    const entry = resolveField(ConfigT, parsed.key) orelse return .{
        .path = parsed.key,
        .value = parsed.value,
        .ok = false,
        .problem = "no such configuration field",
    };

    // The value must parse into the field's declared type. This is the check that
    // makes a dry run worth running: `port = not-a-port` fails here, naming the
    // field, rather than at load time.
    if (!entry.tryParse(parsed.value)) {
        return .{
            .path = parsed.key,
            .value = parsed.value,
            .ok = false,
            .problem = "not a valid value for this field's type",
        };
    }

    return .{ .path = parsed.key, .value = parsed.value, .ok = true };
}

/// Checks every override, one `Verdict` each.
///
/// Reports all of them rather than stopping at the first failure: a user who got
/// three keys wrong should see three problems, not three sequential runs.
pub fn checkAll(
    comptime ConfigT: type,
    allocator: std.mem.Allocator,
    overrides: []const []const u8,
) ![]Verdict {
    const out = try allocator.alloc(Verdict, overrides.len);
    for (overrides, 0..) |o, i| out[i] = checkOne(ConfigT, o);
    return out;
}

/// Renders verdicts through `src/lib/cfg`'s matrix renderer, which already emits the
/// `[PASS]` / `[FAIL]` form the format specification asked for.
pub fn render(writer: anytype, verdicts: []const Verdict) !void {
    var results: std.ArrayListUnmanaged(dryrun.ValidationResult) = .empty;
    defer results.deinit(std.heap.page_allocator);
    for (verdicts) |v| {
        try results.append(std.heap.page_allocator, .{
            .key = v.path,
            .value = v.value,
            .is_valid = v.ok,
            .error_msg = v.problem,
        });
    }
    try dryrun.renderMatrix(writer, results.items);
}

/// Splits a space-separated override list.
///
/// The CLI framework renders a flag's value as a single `[]const u8` and does not
/// support a slice-of-slices field (`cli.zig:1290` is an explicit
/// `@compileError("Unsupported pointer type for flag")`), so repeated
/// `--config-override` values cannot be expressed as a typed field yet. This accepts
/// the list as one space-delimited argument and is the honest shape until the
/// framework grows repeatable flags.
///
/// Values containing spaces are therefore not expressible; that limitation is real
/// and is recorded in `src/app/cmd/config/PLAN.md` rather than hidden.
pub fn splitOverrides(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |tok| try list.append(allocator, tok);
    return list.toOwnedSlice(allocator);
}

/// Whether every verdict passed. Callers use this to pick an exit status; this
/// module never exits on its own, because a server binary and a test both call it.
pub fn allPassed(verdicts: []const Verdict) bool {
    for (verdicts) |v| {
        if (!v.ok) return false;
    }
    return true;
}

// -- Field resolution ------------------------------------------------------

/// Resolves a dotted path to its field type, or null.
///
/// Delegates to `fields.build`, which does the reflection at comptime and hands back
/// a table the runtime path can be looked up in. Comparing a runtime path against
/// `field.name` directly does not compile - "unable to resolve comptime value" -
/// which is why the table exists.
pub fn resolveField(comptime ConfigT: type, path: []const u8) ?fields.Entry {
    return fields.find(comptime fields.build(ConfigT), path);
}
// -- Tests -----------------------------------------------------------------

const Network = struct {
    port: u16 = 8080,
    tls: bool = false,
};

const Fixture = struct {
    name: []const u8 = "svc",
    verbose: bool = false,
    timeout: cfg.DurationMs = .{ .ms = 1000 },
    limit: cfg.ByteSize = .{ .bytes = 1024 },
    maybe: ?u16 = null,
    network: Network = .{},

    pub const meta = .{};
};

test "a well-typed override passes" {
    try std.testing.expect(checkOne(Fixture, "name=hello").ok);
    try std.testing.expect(checkOne(Fixture, "verbose=yes").ok);
    try std.testing.expect(checkOne(Fixture, "timeout=2m").ok);
    try std.testing.expect(checkOne(Fixture, "limit=1MB").ok);
    try std.testing.expect(checkOne(Fixture, "maybe=7").ok);
}

test "a dotted path walks one level of nesting" {
    const v = checkOne(Fixture, "network.port=9999");
    try std.testing.expect(v.ok);
    try std.testing.expectEqualStrings("network.port", v.path);
}

test "a mistyped value fails and names the field" {
    const v = checkOne(Fixture, "network.port=not-a-port");
    try std.testing.expect(!v.ok);
    try std.testing.expectEqualStrings("network.port", v.path);
    try std.testing.expect(v.problem.len > 0);

    try std.testing.expect(!checkOne(Fixture, "verbose=maybe").ok);
    try std.testing.expect(!checkOne(Fixture, "timeout=2 fortnights").ok);
}

test "an unknown field fails, including a bad nested segment" {
    try std.testing.expect(!checkOne(Fixture, "nope=1").ok);
    try std.testing.expect(!checkOne(Fixture, "network.nope=1").ok);
    // Deeper than the supported one level is refused, not guessed at.
    try std.testing.expect(!checkOne(Fixture, "network.port.extra=1").ok);
}

test "a malformed override is reported as such, not as an unknown field" {
    const v = checkOne(Fixture, "no-equals-sign");
    try std.testing.expect(!v.ok);
    try std.testing.expect(std.mem.indexOf(u8, v.problem, "path=value") != null);
}

test "checkAll reports every override, not just the first failure" {
    const overrides = [_][]const u8{ "name=ok", "nope=1", "network.port=bad" };
    const verdicts = try checkAll(Fixture, std.testing.allocator, &overrides);
    defer std.testing.allocator.free(verdicts);

    try std.testing.expectEqual(@as(usize, 3), verdicts.len);
    try std.testing.expect(verdicts[0].ok);
    try std.testing.expect(!verdicts[1].ok);
    try std.testing.expect(!verdicts[2].ok);
    try std.testing.expect(!allPassed(verdicts));
}

test "render emits the pass/fail matrix for both verdicts" {
    const overrides = [_][]const u8{ "name=ok", "nope=1" };
    const verdicts = try checkAll(Fixture, std.testing.allocator, &overrides);
    defer std.testing.allocator.free(verdicts);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try render(&w, verdicts);
    const out = w.buffered();

    // The markers are ANSI-wrapped by the renderer, so assert on the text around
    // them rather than through them.
    try std.testing.expect(std.mem.indexOf(u8, out, "[PASS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[FAIL]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name = ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Validation Matrix") != null);
}

test "allPassed is true when every verdict is ok" {
    const overrides = [_][]const u8{ "name=a", "verbose=true" };
    const verdicts = try checkAll(Fixture, std.testing.allocator, &overrides);
    defer std.testing.allocator.free(verdicts);
    try std.testing.expect(allPassed(verdicts));
}

test "splitOverrides tokenises on whitespace and frees cleanly" {
    const raw = "  network.port=9999   name=hello ";
    const parts = try splitOverrides(std.testing.allocator, raw);
    defer std.testing.allocator.free(parts);
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("network.port=9999", parts[0]);
    try std.testing.expectEqualStrings("name=hello", parts[1]);

    const empty = try splitOverrides(std.testing.allocator, "   ");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
