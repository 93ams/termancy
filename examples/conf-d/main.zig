//! A `conf.d` loader: every file in a directory, in name order, merged into one tree; a
//! later file overrides an earlier one key by key, and files may be in different formats.
//! Prints each setting with the file it came from.
//!
//!     zig build examples
//!     zig-out/bin/conf-d examples/conf-d/conf.d

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");

const Args = struct { dir: []const u8 };

fn show(ctx: *cli.Context, args: Args) !void {
    var config: cfg.Config = .init(ctx.gpa);
    defer config.deinit();
    var diag: cfg.Diagnostic = .{};
    const loaded = config.loadDir(ctx.io, .cwd(), args.dir, &diag) catch |err| switch (err) {
        error.SyntaxError => return ctx.fail("{s}: {f}", .{ args.dir, diag }),
        else => return ctx.fail("{s}: {t}", .{ args.dir, err }),
    };
    try ctx.out.print("{d} files\n", .{loaded});
    for (try config.keys()) |key| {
        const value = (try config.get(key)).?;
        const origin = (try config.explain(key)).?;
        try ctx.out.print("{s} = {f}  # {s}\n", .{
            key, value, std.fs.path.basename(origin.source),
        });
    }
}

pub const root = cli.command(.{
    .name = "conf-d",
    .summary = "Merge a conf.d directory and show where each setting came from",
    .args = Args,
    .run = show,
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root };
    return app.run(init);
}

test "a missing directory fails cleanly" {
    const app: cli.App = .{ .root = &root };
    const result = try cli.testing.run(app, &.{"no-such-dir"}, .{});
    defer result.deinit();
    try result.expect(1, "", "conf-d: no-such-dir: FileNotFound\n");
}
