//! `config export` - write the resolved configuration as environment variables.
//!
//! Renders either a `.env` file or a systemd unit. All the work happens in
//! `app/cfg/lib/ops/exporter.zig`; this file parses flags and calls it.
//!
//! ## Why `ConfigT` is a parameter here
//!
//! An export is defined over a *configuration type*, not over an app. `kvs` and
//! `scp` should export their own configs, and neither has a `cli.App`. Threading
//! `ConfigT` through means this file never needs one - the `AppT`-shaped entry point
//! in `cmd/root.zig` supplies it, and a server binary can call the same code.

const std = @import("std");
const cfg = @import("cfg");
const ops = @import("../lib/ops/root.zig");

/// Flags for `config export`.
pub const ExportFlags = struct {
    /// `dotenv` (default), `systemd`, `bash` or `json`.
    format: []const u8 = "dotenv",
    /// systemd only: the unit's name.
    service_name: []const u8 = "app",
    /// systemd only: the unit's description.
    description: []const u8 = "Exported configuration",
    /// systemd only: `ExecStart`.
    exec_path: []const u8 = "/usr/bin/app",
    /// Prepended to derived variable names. Ignored for fields that declare
    /// `.env`, whose names are absolute.
    prefix: []const u8 = "",

    pub const meta = .{
        .format = .{ .help = "dotenv | systemd | bash | json", .default_text = "dotenv" },
        .service_name = .{ .help = "systemd unit name" },
        .description = .{ .help = "systemd unit description" },
        .exec_path = .{ .help = "systemd ExecStart path" },
        .prefix = .{ .help = "Prefix for derived variable names" },
    };
};

/// Exports `ConfigT` to `writer` in the requested format.
///
/// This is the whole command body, factored so a test can drive it with any writer
/// and any config type without constructing a `cli.Ctx`.
pub fn run(
    allocator: std.mem.Allocator,
    writer: anytype,
    err_writer: anytype,
    env_map: *std.process.Environ.Map,
    comptime ConfigT: type,
    flags: ExportFlags,
) !void {
    const resolved = try cfg.loader.load(allocator, ConfigT, env_map);
    defer cfg.loader.deinit(allocator, ConfigT, resolved);

    var collector = ops.exporter.Collector.init(allocator);
    defer collector.deinit();
    try collector.collect(resolved.*, .{ .prefix = flags.prefix });

    if (std.mem.eql(u8, flags.format, "systemd")) {
        try ops.exporter.writeSystemdService(
            allocator,
            writer,
            collector.variables(),
            flags.service_name,
            flags.description,
            flags.exec_path,
        );
    } else if (std.mem.eql(u8, flags.format, "dotenv")) {
        try ops.exporter.writeDotEnv(allocator, writer, collector.variables());
    } else if (std.mem.eql(u8, flags.format, "bash")) {
        try ops.exporter.writeBash(allocator, writer, collector.variables());
    } else if (std.mem.eql(u8, flags.format, "json")) {
        try ops.exporter.writeJson(allocator, writer, collector.variables());
    } else {
        // A named error rather than a silent fallback to dotenv: writing the wrong
        // format into a file the user redirects is worse than refusing.
        try err_writer.print(
            "unknown export format '{s}'; expected dotenv, systemd, bash or json\n",
            .{flags.format},
        );
        return error.InvalidFormat;
    }

    // Secrets are counted and reported, never printed. A user exporting a config
    // that contains a secret should know it was withheld rather than assume their
    // key silently vanished.
    const withheld = collector.redactedCount();
    if (withheld > 0) {
        try err_writer.print("{d} secret value(s) withheld; the keys are present with empty values\n", .{withheld});
    }
}

// The command *type* for each of these is declared in `cmd/root.zig`. They are
// not declared here because `AppT.Command(...)` has to be instantiated where`AppT`
// is known, and a file that declares `pub const cmd` cannot be generic over`AppT`.

// -- Tests -----------------------------------------------------------------

const Fixture = struct {
    port: u16 = 4222,
    api_key: ?[]const u8 = null,

    pub const meta = .{
        .api_key = .{ .env = "API_KEY", .secret = true },
    };
};

test "run writes dotenv by default and withholds secrets" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [4096]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{ .format = "dotenv" });

    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "PORT=\"4222\"") != null);
    // The key is present with an empty value, and the cost is reported.
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "API_KEY=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "1 secret value(s) withheld") != null);
}

test "run writes a systemd unit when asked" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [4096]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{
        .format = "systemd",
        .service_name = "svc",
        .description = "d",
        .exec_path = "/bin/svc",
    });
    const text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "[Service]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ExecStart=/bin/svc") != null);
}

test "an unknown format is refused, not silently treated as dotenv" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [4096]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try std.testing.expectError(error.InvalidFormat, run(
        std.testing.allocator,
        &out,
        &err,
        &env,
        Fixture,
        .{ .format = "yaml" },
    ));
    // Nothing was written to the output, so a redirect produces an empty file
    // rather than a wrong one.
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "unknown export format") != null);
}

test "run writes a sourceable shell script for bash" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [2048]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{ .format = "bash" });
    const text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "export PORT='4222'") != null);
    // The secret contributes its name with an empty value, and no double quotes appear.
    try std.testing.expect(std.mem.indexOf(u8, text, "export API_KEY=''") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "=\"") == null);
}

test "run writes parseable json" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [2048]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{ .format = "json" });
    // Parsed rather than string-matched: that is what proves the escaping is right.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("4222", parsed.value.object.get("PORT").?.string);
    try std.testing.expectEqualStrings("", parsed.value.object.get("API_KEY").?.string);
}

test "the format list in the error names every supported format" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try std.testing.expectError(error.InvalidFormat, run(
        std.testing.allocator,
        &out,
        &err,
        &env,
        Fixture,
        .{ .format = "yaml" },
    ));
    const msg = err.buffered();
    for ([_][]const u8{ "dotenv", "systemd", "bash", "json" }) |f| {
        try std.testing.expect(std.mem.indexOf(u8, msg, f) != null);
    }
}
