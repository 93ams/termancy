//! `config schema` - emit a JSON Schema for the configuration type.
//!
//! ## Why this is a command and not a flag
//!
//! `--schema` existed on the old single-command `config` and was **dropped** when
//! this folder was split into `ops/` + `cmd/` and the group grew real subcommands.
//! That was a lost capability, not a refactor: `cfg.loader.generateSchema` emits a
//! draft-07 schema (`writeOnly` for `.secret` fields) and, with the flag gone, had
//! **no caller left in the tree but its own test** - so the feature compiled, was
//! covered, and was unreachable.
//!
//! It is a subcommand rather than a flag because the group now dispatches on
//! subcommands: a flag on the bare group would be reached only as
//! `config --schema` (no subcommand), which is exactly the spelling that stopped
//! working. `config schema` also takes an optional output path, which the bare flag
//! could not.

const std = @import("std");
const cfg = @import("cfg");

/// Flags for `config schema`.
pub const SchemaFlags = struct {
    /// Optional positional output path. Empty means stdout.
    positionals: struct {
        output: []const u8 = "",
    } = .{},

    pub const meta = .{
        .positionals = .{ .description = "File to write the schema to (default: stdout)" },
    };
};

/// Writes the schema for `ConfigT` to `writer`.
pub fn run(writer: anytype, comptime ConfigT: type) !void {
    try cfg.loader.generateSchema(writer, ConfigT);
}

// The command *type* is declared in `cmd/root.zig`, where `AppT` is known - the same
// split the other commands in this folder use.

// -- Tests -----------------------------------------------------------------

const Fixture = struct {
    port: u16 = 8080,
    api_key: ?[]const u8 = null,

    pub const meta = .{
        .port = .{ .env = "PORT", .help = "Listen port" },
        .api_key = .{ .env = "API_KEY", .secret = true, .help = "Secret key" },
    };
};

test "the schema names every field and marks a secret writeOnly" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(&w, Fixture);
    const out = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "port") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "api_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "writeOnly") != null);
    // A schema describes the shape; it must never carry a value.
    try std.testing.expect(std.mem.indexOf(u8, out, "8080") == null);
}

test "the positional is declared where the framework looks for it" {
    // Same trap as `config inspect`: a top-level field would parse to "" forever
    // because the framework silently discards positionals without this shape.
    try std.testing.expect(@hasField(SchemaFlags, "positionals"));
    try std.testing.expectEqualStrings("", (SchemaFlags{}).positionals.output);
}
