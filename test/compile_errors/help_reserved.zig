//! Must not compile: a flag called `--help`.

const cli = @import("cli");

const bad = cli.command(.{ .name = "app", .flags = struct { help: bool = false } });

comptime {
    _ = bad;
}
