//! `termancy`: the entry point and the top-level command tree.
//!
//! Commands are grouped by what they act on. A group lives under `cmd/<group>/main.zig`
//! (`cfg`, `cli`, `tui`, `ui`); a command or group of its own, at `cmd/<name>.zig`.
//!
//! A panic prints a banner and writes a JSON crash report (no argv, no environment) into
//! termancy's state directory (`~/.local/state/termancy` on Linux), set at startup.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const sys = @import("sys");
const build_options = @import("build_options");

/// From `build.zig.zon`, the one place the version is written.
pub const version = build_options.version;

/// The version with the commit and date of the build, when `zig build` was given them.
pub const full_version = cli.version.string(.{
    .version = version,
    .commit = build_options.commit,
    .date = build_options.date,
});

pub const panic = sys.crash.Panic(.{
    .app_name = "termancy",
    .version = version,
    .issues_url = "https://github.com/93ams/termancy/issues",
});

pub const root = cli.command(.{
    .name = "termancy",
    .summary = "Configuration tooling, built with the termancy cli and cfg libraries",
    .description =
    \\termancy reads configuration from TOML, YAML, JSON, ZON, and dotenv files, layers it with
    \\environment variables and overrides, and lets you query, explain, edit, and convert
    \\it (termancy cfg). termancy cli and termancy tui generate new applications and components; termancy
    \\ui gives shell scripts interactive widgets. The other commands read Markdown, show
    \\images, record terminals, sign releases, manage SSH keys and passkeys, and update
    \\termancy.
    ,
    .subcommands = .{
        @import("cmd/cfg/main.zig").command,
        @import("cmd/cli/main.zig").command,
        @import("cmd/tui/main.zig").command,
        @import("cmd/ui/main.zig").command,
        @import("cmd/md.zig").command,
        @import("cmd/image.zig").command,
        @import("cmd/freeze.zig").command,
        @import("cmd/record.zig").command,
        @import("cmd/explain.zig").command,
        @import("cmd/serve.zig").command,
        @import("cmd/ssh.zig").command,
        @import("cmd/passkey.zig").command,
        @import("cmd/release.zig").command,
        @import("cmd/dirs.zig").command,
        @import("cmd/info.zig").command,
        @import("cmd/update.zig").command,
        version_command,
    },
});

pub fn main(init: std.process.Init) u8 {
    setCrashReportDir(init.arena.allocator(), init.environ_map);
    if (builtin.os.tag == .windows) removeUpdateLeftovers(init.io, init.arena.allocator());
    const app: cli.App = .{
        .root = &root,
        .version = full_version,
        // Mounted as `termancy cli completion` instead; see cmd/cli/main.zig.
        .completion_command = false,
        // `termancy <name>` runs `termancy-<name>` from PATH, as git runs `git-<name>`.
        .plugins = "termancy-",
        .pager = true,
        .color_flag = true,
    };
    return app.run(init);
}

/// Deletes the `termancy.exe.old` that `termancy update` leaves on Windows, which cannot
/// delete a running executable: the update's own process still runs the old one.
fn removeUpdateLeftovers(io: std.Io, arena: std.mem.Allocator) void {
    const path = sys.exe.pathAlloc(io, arena) catch return;
    sys.update.removeLeftovers(io, .cwd(), path) catch {};
}

/// Crash reports go to termancy's state directory; without a home directory, there are none.
fn setCrashReportDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) void {
    const dir = sys.dirs.nativePath(arena, environ, .state, "termancy") catch return;
    sys.crash.setReportDir(dir) catch {};
}

const version_command = cli.command(.{
    .name = "version",
    .summary = "Print version information",
    .run = runVersion,
});

fn runVersion(ctx: *cli.Context) !void {
    try ctx.out.print("termancy {s}\nzig {s}, {s}-{s}\n", .{
        full_version,
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    });
}

test {
    std.testing.refAllDecls(@import("cmd/cfg/main.zig"));
    std.testing.refAllDecls(@import("cmd/cli/main.zig"));
    std.testing.refAllDecls(@import("cmd/tui/main.zig"));
    std.testing.refAllDecls(@import("cmd/ui/main.zig"));
    std.testing.refAllDecls(@import("cmd/md.zig"));
    std.testing.refAllDecls(@import("cmd/image.zig"));
    std.testing.refAllDecls(@import("cmd/freeze.zig"));
    std.testing.refAllDecls(@import("cmd/record.zig"));
    std.testing.refAllDecls(@import("cmd/explain.zig"));
    std.testing.refAllDecls(@import("cmd/serve.zig"));
    std.testing.refAllDecls(@import("cmd/ssh.zig"));
    std.testing.refAllDecls(@import("cmd/passkey.zig"));
    std.testing.refAllDecls(@import("cmd/release.zig"));
    std.testing.refAllDecls(@import("cmd/dirs.zig"));
    std.testing.refAllDecls(@import("cmd/info.zig"));
    std.testing.refAllDecls(@import("cmd/update.zig"));
}
