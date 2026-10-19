//! The smallest `cli` application, for `zig build budget`: one command, one flag.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");

const Flags = struct {
    name: []const u8 = "world",
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .name = .{ .help = "Who to greet" },
} }}), .{ .fields = .{
    .name = .{ .short = 'n' },
} });

fn hello(ctx: *cli.Context, flags: Flags) !void {
    try ctx.out.print("hello, {s}\n", .{flags.name});
}

const root = cli.command(.{
    .name = "hello",
    .summary = "Says hello",
    .flags = flags_flags,
    .run = hello,
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root, .version = "0.1.0" };
    return app.run(init);
}
