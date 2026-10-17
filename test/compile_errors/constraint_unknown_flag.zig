//! Must not compile: a constraint naming a flag the command does not have.

const cli = @import("cli");

const bad = cli.command(.{
    .name = "app",
    .flags = struct { json: bool = false, yaml: bool = false },
    .exclusive = &.{&.{ "json", "yml" }},
});

comptime {
    _ = bad;
}
