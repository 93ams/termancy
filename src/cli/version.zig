//! Build metadata for `--version`: a version, and optionally the commit and date the build
//! came from, passed in through `build.zig` options.
//!
//! ```zig
//! // build.zig
//! const options = b.addOptions();
//! options.addOption(?[]const u8, "commit", b.option([]const u8, "commit", "Git commit"));
//! options.addOption(?[]const u8, "date", b.option([]const u8, "date", "Build date"));
//! exe.root_module.addOptions("build_options", options);
//!
//! // main.zig
//! const build_options = @import("build_options");
//! const app: cli.App = .{ .root = &root, .version = cli.version.string(.{
//!     .version = "1.2.0",
//!     .commit = build_options.commit,
//!     .date = build_options.date,
//! }) };
//! ```
//!
//! Taking the commit and date as options rather than reading git and the clock keeps builds
//! reproducible: the same sources and options give the same binary.

const std = @import("std");

/// What a build knows about itself.
pub const Build = struct {
    version: []const u8,
    /// A commit hash; shortened to 12 characters.
    commit: ?[]const u8 = null,
    /// The build date, as given (`2026-10-12`).
    date: ?[]const u8 = null,
};

/// `1.2.0`, `1.2.0 (0123456789ab)`, or `1.2.0 (0123456789ab, 2026-10-12)`.
pub fn string(comptime build: Build) []const u8 {
    comptime {
        const commit: ?[]const u8 = if (build.commit) |c| c[0..@min(c.len, 12)] else null;
        if (commit == null and build.date == null) return build.version;
        var details: []const u8 = "";
        if (commit) |c| details = c;
        if (build.date) |d| details = details ++ (if (details.len > 0) ", " else "") ++ d;
        return build.version ++ " (" ++ details ++ ")";
    }
}

test string {
    try std.testing.expectEqualStrings("1.2.0", comptime string(.{ .version = "1.2.0" }));
    try std.testing.expectEqualStrings("1.2.0 (0123456789ab)", comptime string(.{
        .version = "1.2.0",
        .commit = "0123456789abcdef0123",
    }));
    try std.testing.expectEqualStrings("1.2.0 (abc, 2026-10-12)", comptime string(.{
        .version = "1.2.0",
        .commit = "abc",
        .date = "2026-10-12",
    }));
    try std.testing.expectEqualStrings("1.2.0 (2026-10-12)", comptime string(.{
        .version = "1.2.0",
        .date = "2026-10-12",
    }));
}
