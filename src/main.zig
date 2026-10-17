//! `snek`: the entry point and the top-level command tree.
//!
//! Each command group lives under `cmd/<group>/main.zig` and is mounted here:
//! `snek cfg ...` for configuration, `snek cli ...` for command-line tooling, `snek
//! platform ...` for the operating system.
//!
//! A panic prints a banner and writes a JSON crash report (no argv, no environment) into
//! snek's state directory (`~/.local/state/snek` on Linux), set at startup.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const platform = @import("platform");
const build_options = @import("build_options");

pub const version = "0.1.0";

/// The version with the commit and date of the build, when `zig build` was given them.
pub const full_version = cli.version.string(.{
    .version = version,
    .commit = build_options.commit,
    .date = build_options.date,
});

pub const panic = platform.crash.Panic(.{
    .app_name = "snek",
    .version = version,
    .issues_url = "https://github.com/93ams/snek/issues",
});

pub const root = cli.command(.{
    .name = "snek",
    .summary = "Configuration tooling, built with the snek cli and cfg libraries",
    .description =
    \\snek reads configuration from TOML, YAML, JSON, ZON, and dotenv files, layers it with
    \\environment variables and overrides, and lets you query, explain, edit, and convert
    \\it (snek cfg). snek cli documents snek's own command-line interface and generates
    \\new ones; snek platform reports on the operating system and updates snek.
    ,
    .subcommands = .{
        @import("cmd/cfg/main.zig").command,
        @import("cmd/cli/main.zig").command,
        @import("cmd/platform/main.zig").command,
        @import("cmd/tui/main.zig").command,
        version_command,
    },
});

pub fn main(init: std.process.Init) u8 {
    setCrashReportDir(init.arena.allocator(), init.environ_map);
    const app: cli.App = .{
        .root = &root,
        .version = full_version,
        // Mounted as `snek cli completion` instead; see cmd/cli/main.zig.
        .completion_command = false,
        // `snek <name>` runs `snek-<name>` from PATH, as git runs `git-<name>`.
        .plugins = "snek-",
        .pager = true,
        .color_flag = true,
    };
    return app.run(init);
}

/// Crash reports go to snek's state directory; without a home directory, there are none.
fn setCrashReportDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) void {
    const dir = platform.dirs.nativePath(arena, environ, .state, "snek") catch return;
    platform.crash.setReportDir(dir) catch {};
}

const version_command = cli.command(.{
    .name = "version",
    .summary = "Print version information",
    .run = runVersion,
});

fn runVersion(ctx: *cli.Context) !void {
    try ctx.out.print("snek {s}\nzig {s}, {s}-{s}\n", .{
        full_version,
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    });
}

test {
    std.testing.refAllDecls(@import("cmd/cfg/main.zig"));
    std.testing.refAllDecls(@import("cmd/cli/main.zig"));
    std.testing.refAllDecls(@import("cmd/platform/main.zig"));
}
