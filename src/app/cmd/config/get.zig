//! `config get <path>` - print one configuration value.
//!
//! The specification calls this `cfg get <key.path>` with a `--raw` flag. The library
//! half is `ops/query.get`, which resolves the path through the same comptime field
//! table `inspect` uses.
//!
//! ## `--raw` means undecorated, not unprotected
//!
//! A secret renders as `[SECRET len=N]` on every path, including `--raw`. A flag that
//! printed a secret would make every caller that passes it a leak, and `get` is the
//! command most likely to be piped into something else.

const std = @import("std");
const cfg = @import("cfg");
const ops = @import("../../lib/ops/root.zig");

/// Flags for `config get`.
pub const GetFlags = struct {
    /// The value to print, as a dotted path.
    positionals: struct {
        path: []const u8 = "",
    } = .{},

    /// Strip decoration: quotes from strings, and `null` becomes empty. A secret is
    /// still redacted.
    raw: bool = false,

    pub const meta = .{
        .positionals = .{ .description = "Dotted path, e.g. network.port" },
        .raw = .{ .help = "Print the bare value (quotes stripped; secrets stay redacted)" },
    };
};

/// Prints `path` from `ConfigT`, or reports that it names nothing.
///
/// Returns `error.UnknownField` for a missing path so the exit status is non-zero -
/// a script doing `cfg get port` must not silently continue with empty output.
pub fn run(
    allocator: std.mem.Allocator,
    writer: anytype,
    err_writer: anytype,
    env_map: *std.process.Environ.Map,
    comptime ConfigT: type,
    flags: GetFlags,
) !void {
    if (flags.positionals.path.len == 0) {
        try err_writer.writeAll("config get: a dotted path is required\n");
        return error.MissingRequiredPositionalArgument;
    }

    const resolved = try cfg.loader.load(allocator, ConfigT, env_map);
    defer cfg.loader.deinit(allocator, ConfigT, resolved);
    try runOn(writer, err_writer, ConfigT, resolved.*, flags);
}

/// The body of `run`, over an already-resolved config.
///
/// Split out so a test can supply values that `load` cannot produce - a secret with
/// content, for instance, which needs an environment variable and would otherwise make
/// the test depend on the ambient environment.
pub fn runOn(
    writer: anytype,
    err_writer: anytype,
    comptime ConfigT: type,
    config: ConfigT,
    flags: GetFlags,
) !void {
    var buf: [ops.fields.buf_len]u8 = undefined;
    if (ops.query.get(ConfigT, config, flags.positionals.path, &buf, flags.raw)) |got| {
        try writer.print("{s}\n", .{got.text});
        return;
    }

    try err_writer.print("no such configuration field: {s}\n", .{flags.positionals.path});
    return error.UnknownField;
}

// -- Tests -----------------------------------------------------------------

const Fixture = struct {
    port: u16 = 4222,
    name: []const u8 = "svc",
    token: ?[]const u8 = null,

    pub const meta = .{
        .token = .{ .env = "GET_TEST_TOKEN", .secret = true },
    };
};

test "a value prints bare on stdout" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [512]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{
        .positionals = .{ .path = "port" },
    });
    try std.testing.expectEqualStrings("4222\n", out.buffered());
}

test "raw strips the quotes a decorated string renders with" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [512]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{
        .positionals = .{ .path = "name" },
        .raw = true,
    });
    try std.testing.expectEqualStrings("svc\n", out.buffered());
}

test "a missing path fails rather than printing nothing" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [512]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try std.testing.expectError(error.UnknownField, run(std.testing.allocator, &out, &err, &env, Fixture, .{
        .positionals = .{ .path = "nosuch" },
    }));
    // Nothing on stdout, so a substitution does not receive a partial value.
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "no such configuration field") != null);
}

test "an empty path is refused" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try std.testing.expectError(error.MissingRequiredPositionalArgument, run(
        std.testing.allocator,
        &out,
        &err,
        &env,
        Fixture,
        .{},
    ));
}

test "a secret stays redacted even with raw" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [512]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    const secret_text = "tok_live_abcdef";
    try runOn(&out, &err, Fixture, Fixture{ .token = secret_text }, .{
        .positionals = .{ .path = "token" },
        .raw = true,
    });
    const printed = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, printed, "SECRET") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, secret_text) == null);
}

test "the positional is declared where the framework looks for it" {
    try std.testing.expect(@hasField(GetFlags, "positionals"));
    try std.testing.expect(@hasField(@FieldType(GetFlags, "positionals"), "path"));
}
