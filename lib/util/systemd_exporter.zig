//! Export a configuration as a `.env` file or a systemd unit.
//!
//! **This lives in `lib/util`, not `lib/cli`, because it mentions no terminal, no
//! flag and no command** - it takes a `std.Io.Writer` and a slice of key/value pairs.
//! It sat in `app/cli/lib/platform/` only because the CLI was once the only library with
//! a test root, the same reason already recorded for the other files that moved.
//! `lib/cli` re-exports it under its historical name, so no caller had to change.
//!
//! The move was forced by a real consumer: `app/cfg/lib/ops` must be callable from
//! `app/kvs` and `app/scp`, neither of which imports the CLI framework, and the
//! operations therefore have no `cli` module to import from.
//!
//! This file **is** the type: the file's own scope is `SystemdExporter`, so a
//! consumer writes `const SystemdExporter = @import("systemd_exporter.zig");`.
//! See the file-layout rule in `.agents/AGENTS.md`.
//!
//! `EnvVar` stays a declaration inside, because it is the thing being exported.
//!
//! **Known defect, recorded not fixed:** neither exporter escapes its input, so a
//! `"` or a newline in a value produces a malformed `.env` or unit file. A
//! diagnostic that writes a broken unit is worse than one that refuses. See
//! `app/cli/lib/ROADMAP.md` section 5.4.

const std = @import("std");

const Self = @This();

/// One exported environment variable.
pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

/// Writes `KEY="value"` lines. See the module header on escaping.
pub fn exportDotEnv(writer: anytype, env_vars: []const EnvVar) !void {
    try writer.writeAll("# Auto-generated Environment Configuration\n");
    for (env_vars) |v| {
        try writer.print("{s}=\"{s}\"\n", .{ v.key, v.value });
    }
}

/// Writes a systemd unit with the same variables in an `[Service]` block.
///
/// See the module header on escaping.
pub fn exportSystemdService(
    writer: anytype,
    service_name: []const u8,
    description: []const u8,
    bin_path: []const u8,
    env_vars: []const EnvVar,
) !void {
    try writer.print(
        \\[Unit]
        \\Description={s} ({s})
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s}
        \\Restart=always
        \\RestartSec=5s
        \\
    , .{ service_name, description, bin_path });

    for (env_vars) |v| {
        try writer.print("Environment=\"{s}={s}\"\n", .{ v.key, v.value });
    }

    try writer.print(
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{});
}

test "exportDotEnv writes one quoted line per variable" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const vars = [_]Self.EnvVar{
        .{ .key = "A", .value = "1" },
        .{ .key = "B", .value = "two" },
    };
    try Self.exportDotEnv(&w, &vars);

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "A=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B=\"two\"") != null);
}

test "exportSystemdService emits both sections and the variables" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const vars = [_]Self.EnvVar{.{ .key = "A", .value = "1" }};
    try Self.exportSystemdService(&w, "svc", "a service", "/usr/bin/svc", &vars);

    const out = w.buffered();
    // The template is `Description={s} ({s})` with `.{ service_name, description }`,
    // so the name comes first and the description is the parenthesised part.
    try std.testing.expect(std.mem.indexOf(u8, out, "Description=svc (a service)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ExecStart=/usr/bin/svc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Environment=\"A=1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Unit]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Service]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Install]") != null);
}
