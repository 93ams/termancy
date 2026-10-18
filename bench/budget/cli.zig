//! The smallest `cli` application, for `zig build budget`: one command, one flag.

const std = @import("std");
const cli = @import("cli");

const Flags = struct {
    name: []const u8 = "world",
    pub const meta = .{ .name = .{ .short = 'n', .help = "Who to greet" } };
};

fn hello(ctx: *cli.Context, flags: Flags) !void {
    try ctx.out.print("hello, {s}\n", .{flags.name});
}

const root = cli.command(.{
    .name = "hello",
    .summary = "Says hello",
    .flags = Flags,
    .run = hello,
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root, .version = "0.1.0" };
    return app.run(init);
}
