//! The smallest `cfg` application, for `zig build budget`: defaults, a TOML document from
//! the first argument, the environment, and a typed result.

const std = @import("std");
const cfg = @import("cfg");

const Settings = struct {
    server: struct { host: []const u8 = "localhost", port: u16 = 8080 } = .{},
    debug: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var config: cfg.Config = .init(init.gpa);
    defer config.deinit();
    var args = init.minimal.args.iterate();
    _ = args.skip();
    var diag: cfg.Diagnostic = .{};
    if (args.next()) |toml| try config.loadSource("argument", toml, .toml, &diag);
    config.useEnv(init.environ_map);
    try config.automaticEnv("APP");
    const settings = try config.decode(Settings, .{}, &diag);
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("{s}:{d}\n", .{ settings.server.host, settings.server.port });
    try stdout.interface.flush();
}
