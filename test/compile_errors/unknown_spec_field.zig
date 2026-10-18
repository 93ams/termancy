//! Must not compile: a spec field `cli.command` does not know.

const cli = @import("cli");

const bad = cli.command(.{ .name = "app", .sumary = "typo" });

comptime {
    _ = bad;
}
