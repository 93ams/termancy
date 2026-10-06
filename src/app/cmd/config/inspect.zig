//! `config inspect` - explain where a configuration field's value came from.
//!
//! With a path, reports that field. With none, reports every scalar field, which is
//! the case the library could not serve: `config_lineage.inspect` needs a path the
//! caller already knows.

const std = @import("std");
const cfg = @import("cfg");
const ops = @import("../../lib/ops/root.zig");

/// Flags for `config inspect`.
pub const InspectFlags = struct {
    /// The positional field path to inspect. Empty means "every field".
    ///
    /// **It must be nested under `positionals`.** The framework looks for a field
    /// named `positionals` (or `Positional`) and, finding none, **silently discards
    /// every positional argument** - `cli.zig:773` computes `has_pos_lower` and falls
    /// back to a `Positional` field that need not exist. A top-level `path: []const u8`
    /// therefore parsed and always stayed `""`, so `config inspect port` printed the
    /// whole config and `config inspect <typo>` printed it too, instead of reporting
    /// "no such configuration field". Measured before the fix: both invocations
    /// printed all four fields and exited 0.
    positionals: struct {
        path: []const u8 = "",
    } = .{},

    pub const meta = .{
        .positionals = .{ .description = "Field path, e.g. network.port. Omit to inspect every field." },
    };
};

/// Reports on `ConfigT`, reading `env_map` to establish provenance.
///
/// Reports the **default** values and does not load anything from disk. That is
/// deliberate: this answers "where does this value come from", and loading a file to
/// answer it would make `config inspect` fail on a machine with no config file -
/// exactly when a user most wants to know what the defaults are.
/// Reports on `ConfigT`, resolving values the same way the loader does.
///
/// ## Why it loads rather than rendering defaults
///
/// This used to render `ConfigT{}` - the built-in defaults - while the provenance
/// ledger reported the *source* by reading the environment directly. The two halves
/// disagreed, and the output was actively misleading: with `PORT=7777` set it printed
///
/// ```text
/// Value: 8080 | Type: u16 | Source: ENV (PORT)
/// ```
///
/// which reads as "the environment gave you 8080". The provenance was right and the
/// value was wrong. Loading first makes both halves describe the same config.
///
/// It does not read a *file*: `load` is defaults + environment, so this still works on
/// a machine with no config file, which is when a user most wants to know the defaults.
pub fn run(
    allocator: std.mem.Allocator,
    writer: anytype,
    env_map: *std.process.Environ.Map,
    comptime ConfigT: type,
    path: []const u8,
) !void {
    var led = try ops.inspect.buildEnvLineage(allocator, ConfigT, env_map);
    defer led.deinit();

    // Loaded so the reported value is the effective one, not the default. `deinit`
    // rather than `destroy`: `load` owns every string it returns.
    const resolved = try cfg.loader.load(allocator, ConfigT, env_map);
    defer cfg.loader.deinit(allocator, ConfigT, resolved);

    if (path.len == 0) {
        // One buffer per reportable field, on this frame. The count is a comptime
        // constant, so a config that outgrows the array is a compile error rather
        // than a truncated report.
        var bufs: [ops.inspect.fieldCount(ConfigT)][256]u8 = undefined;
        var list: std.ArrayListUnmanaged(ops.inspect.Rendered) = .empty;
        defer list.deinit(allocator);
        try list.ensureTotalCapacity(allocator, ops.inspect.fieldCount(ConfigT));
        _ = try ops.inspect.collect(ConfigT, resolved.*, &list, &bufs);
        _ = try ops.inspect.reportAll(led, writer, list.items);
        return;
    }

    // One field. A path that names nothing is reported as such rather than silently
    // printing nothing, because "no output" reads like success.
    var buf: [256]u8 = undefined;
    if (ops.inspect.renderAtPath(ConfigT, resolved.*, path, &buf)) |found| {
        try ops.inspect.reportField(led, writer, path, found.text, found.type_name);
    } else {
        try writer.print("no such configuration field: {s}\n", .{path});
    }
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
    token: ?[]const u8 = null,
    network: Network = .{},

    pub const meta = .{
        .name = .{ .env = "APP_NAME" },
        .token = .{ .env = "APP_TOKEN", .secret = true },
    };
};

test "no path reports every scalar field" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, &env, Fixture, "");

    // `collect` renders paths, and `reportAll` writes them through the ledger, which
    // prints `Value: ... | Type: ... | Source: ...`. The path is the renderer's own
    // output, so assert on the values and their sources.
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Source:") != null);
}

test "one path reports that field and its environment origin" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("APP_NAME", "from-env");

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, &env, Fixture, "name");

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "ENV") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "APP_NAME") != null);
}

test "a secret field reports by length and never by value" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("APP_TOKEN", "tok_secret_value");

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, &env, Fixture, "token");

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "SECRET") != null);
    // Redaction returning the value would pass the check above and fail this one.
    try std.testing.expect(std.mem.indexOf(u8, out, "tok_secret_value") == null);
}

test "an unknown path says so instead of printing nothing" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(std.testing.allocator, &w, &env, Fixture, "nope");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "no such configuration field") != null);
}

test "the positional is declared where the framework looks for it" {
    // Regression guard, and the reason the tests above did not catch the original
    // bug: they call `run` directly, so they never exercise flag *parsing*. The
    // framework reads positionals from a field named `positionals` (or `Positional`)
    // and silently discards them when neither exists (`cli.zig:773`), so a top-level
    // `path: []const u8` parsed to `""` forever. `config inspect port` printed the
    // whole config, and `config inspect <typo>` printed it too - both exiting 0,
    // which is what made it invisible.
    //
    // `parseFlags` is private, so this asserts the structural precondition instead:
    // the field the framework needs must exist. If someone "tidies" `path` back to
    // the top level, this fails at compile time rather than shipping a silent no-op.
    try std.testing.expect(@hasField(InspectFlags, "positionals"));
    try std.testing.expect(@hasField(@FieldType(InspectFlags, "positionals"), "path"));
    // Parenthesised: `InspectFlags{}.positionals.path` inside a call argument is a
    // parse ambiguity ("expected ',' after argument"), because the struct literal
    // swallows the closing brace.
    try std.testing.expectEqualStrings("", (InspectFlags{}).positionals.path);

    // And the wrong shape must not come back: a top-level `path` is the bug.
    try std.testing.expect(!@hasField(InspectFlags, "path"));
}
