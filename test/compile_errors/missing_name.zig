//! Must not compile: a command without `.name`.

const cli = @import("cli");

const bad = cli.command(.{ .summary = "nameless" });

comptime {
    _ = bad;
}
