//! `termancy cfg`: configuration commands, built on the `cfg` library.

const std = @import("std");
const cli = @import("cli");
const load = @import("load.zig");
const query = @import("query.zig");
const edit = @import("edit.zig");
const files = @import("files.zig");
const tools = @import("tools.zig");
const profile = @import("profile.zig");

pub const command = cli.command(.{
    .name = "cfg",
    .summary = "Query, explain, edit, and convert configuration",
    .description =
    \\Read configuration from TOML, YAML, JSON (with or without comments), ZON, dotenv,
    \\and INI files, layered with environment variables and --set overrides.
    \\
    \\Without --config, the first termancy.toml, termancy.yaml, termancy.yml, termancy.json, termancy.zon,
    \\termancy.env, termancy.jsonc, or termancy.ini found in ., $XDG_CONFIG_HOME/termancy, or
    \\~/.config/termancy is loaded.
    ,
    .aliases = &.{"config"},
    .persistent_flags = load.Global,
    .logging = true,
    .subcommands = .{
        query.get,
        query.keys,
        query.show,
        query.explain,
        query.env,
        profile.command,
        edit.set,
        edit.unset,
        tools.edit,
        files.convert,
        files.validate,
        files.fmt,
        files.redact,
        files.diff,
        files.encrypt,
        files.decrypt,
        tools.merge,
        tools.init,
        tools.schema_command,
    },
});

test {
    std.testing.refAllDecls(load);
    std.testing.refAllDecls(query);
    std.testing.refAllDecls(edit);
    std.testing.refAllDecls(files);
    std.testing.refAllDecls(tools);
    std.testing.refAllDecls(profile);
}
