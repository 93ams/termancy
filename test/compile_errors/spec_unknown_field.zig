//! Must not compile: a spec for a field the struct does not have.

const cli = @import("cli");
const field = @import("field");

const Flags = struct { port: u16 = 0 };

const Specs = field.Set(.{field.Spec(Flags){ .fields = .{ .zzz = .{ .help = "Nothing" } } }});

comptime {
    _ = cli.flags(Flags, Specs, .{}).list;
}
