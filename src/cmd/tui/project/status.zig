//! What `snek tui add` does with each file, and what `snek tui list` says of each
//! component, from three versions of a file: on disk, recorded in `tui.zon`, and in the
//! registry.

const std = @import("std");
const manifest = @import("manifest.zig");
const Hash = manifest.Hash;

/// What happens to one file of a component being added.
pub const Action = enum {
    /// Missing: written.
    create,
    /// As the registry last wrote it (or `--force`): replaced by the registry's version.
    update,
    /// Already the registry's version.
    unchanged,
    /// Edited since the registry wrote it: left alone.
    skip,

    /// The word `add` prints before the path.
    pub fn verb(action: Action) []const u8 {
        return switch (action) {
            .create => "created",
            .update => "updated",
            .unchanged => "unchanged",
            .skip => "skipped (modified; use --force)",
        };
    }
};

/// `disk` is null when the file is missing; `recorded` is null when `tui.zon` has no hash.
pub fn decide(disk: ?[]const u8, recorded: ?Hash, registry: []const u8, force: bool) Action {
    const content = disk orelse return .create;
    if (std.mem.eql(u8, content, registry)) return .unchanged;
    if (force) return .update;
    const ours = recorded orelse return .skip;
    return if (std.mem.eql(u8, &manifest.hash(content), &ours)) .update else .skip;
}

/// A component's state in a project.
pub const Status = struct {
    /// Listed in `tui.zon`.
    installed: bool = false,
    /// A file is missing or differs from what the registry wrote.
    modified: bool = false,
    /// The registry's version of a file differs from the one installed.
    outdated: bool = false,

    /// One word or two for the text listing.
    pub fn label(status: Status) []const u8 {
        if (!status.installed) return "-";
        if (status.modified and status.outdated) return "modified,outdated";
        if (status.modified) return "modified";
        if (status.outdated) return "outdated";
        return "installed";
    }
};

/// Adds one file of an installed component to `status`.
pub fn addFile(status: *Status, disk: ?[]const u8, recorded: ?Hash, registry: []const u8) void {
    const content = disk orelse {
        status.modified = true;
        return;
    };
    const expected = recorded orelse manifest.hash(registry);
    if (!std.mem.eql(u8, &manifest.hash(content), &expected)) status.modified = true;
    if (recorded) |r| {
        if (!std.mem.eql(u8, &r, &manifest.hash(registry))) status.outdated = true;
    }
}

const testing = std.testing;

test decide {
    const old = manifest.hash("old\n");
    try testing.expectEqual(.create, decide(null, null, "new\n", false));
    try testing.expectEqual(.create, decide(null, old, "new\n", false));
    try testing.expectEqual(.unchanged, decide("new\n", null, "new\n", false));
    try testing.expectEqual(.unchanged, decide("new\n", old, "new\n", true));
    try testing.expectEqual(.update, decide("old\n", old, "new\n", false));
    try testing.expectEqual(.skip, decide("edited\n", old, "new\n", false));
    try testing.expectEqual(.skip, decide("edited\n", null, "new\n", false));
    try testing.expectEqual(.update, decide("edited\n", old, "new\n", true));
    try testing.expectEqualStrings("skipped (modified; use --force)", Action.skip.verb());
}

test addFile {
    const old = manifest.hash("old\n");
    const new = manifest.hash("new\n");
    var current: Status = .{ .installed = true };
    addFile(&current, "new\n", new, "new\n");
    try testing.expectEqualStrings("installed", current.label());

    var outdated: Status = .{ .installed = true };
    addFile(&outdated, "old\n", old, "new\n");
    try testing.expectEqualStrings("outdated", outdated.label());

    var both: Status = .{ .installed = true };
    addFile(&both, "edited\n", old, "new\n");
    try testing.expectEqualStrings("modified,outdated", both.label());

    var missing: Status = .{ .installed = true };
    addFile(&missing, null, new, "new\n");
    try testing.expectEqualStrings("modified", missing.label());

    // Not recorded (skipped when first added): compared with the registry.
    var unrecorded: Status = .{ .installed = true };
    addFile(&unrecorded, "new\n", null, "new\n");
    try testing.expectEqualStrings("installed", unrecorded.label());
    addFile(&unrecorded, "edited\n", null, "new\n");
    try testing.expectEqualStrings("modified", unrecorded.label());

    const absent: Status = .{};
    try testing.expectEqualStrings("-", absent.label());
}
