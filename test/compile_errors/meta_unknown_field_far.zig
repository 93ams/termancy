//! Must not compile: a `meta` entry naming no field, too far from any to suggest one,
//! seen through `cli.flagsOf` rather than a command.

const cli = @import("cli");

const Flags = struct {
    port: u16 = 0,
    pub const meta = .{ .zzz = .{ .short = 'p' } };
};

comptime {
    _ = cli.flagsOf(Flags);
}
