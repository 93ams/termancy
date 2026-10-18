//! `snek platform`: the operating system as snek sees it, built on the `platform` library:
//! where an application's files go, facts about the running system, self-update, and the
//! signing and manifests that publishing a release needs.

const std = @import("std");
const cli = @import("cli");
const dirs = @import("dirs.zig");
const info = @import("info.zig");
const update = @import("update.zig");
const release = @import("release.zig");
const ssh = @import("ssh.zig");
const webauthn = @import("webauthn.zig");

pub const command = cli.command(.{
    .name = "platform",
    .summary = "Directories, system information, self-update, releases, SSH keys, and WebAuthn",
    .subcommands = .{
        dirs.command,
        info.command,
        update.command,
        release.command,
        ssh.command,
        webauthn.command,
    },
});

/// The text form of `dirs` and `info`: `rows` as two columns, the names padded to the
/// longest.
pub fn writeRows(writer: *std.Io.Writer, rows: []const [2][]const u8) std.Io.Writer.Error!void {
    var width: usize = 0;
    for (rows) |row| width = @max(width, row[0].len);
    for (rows) |row| {
        try writer.writeAll(row[0]);
        try writer.splatByteAll(' ', width - row[0].len + 2);
        try writer.print("{s}\n", .{row[1]});
    }
}

test writeRows {
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeRows(&w, &.{ .{ "os", "linux" }, .{ "arch", "x86_64" } });
    try std.testing.expectEqualStrings("os    linux\narch  x86_64\n", w.buffered());
}

test {
    std.testing.refAllDecls(dirs);
    std.testing.refAllDecls(info);
    std.testing.refAllDecls(update);
    std.testing.refAllDecls(release);
    std.testing.refAllDecls(ssh);
    std.testing.refAllDecls(webauthn);
}
