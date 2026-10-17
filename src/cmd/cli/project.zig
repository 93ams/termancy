//! The files of a generated project, as `snek cli add` changes them: edits are planned in
//! memory, checked, and only then written, every path confined to the project directory.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const platform = @import("platform");

pub const InsertError = error{
    /// The file has no line that is exactly the marker (after indentation).
    MarkerNotFound,
    /// The marker appears on more than one line.
    MarkerRepeated,
    /// The line to insert is already in the file.
    AlreadyPresent,
} || Allocator.Error;

/// Returns `source` with `entry` inserted on its own line just before the line holding
/// `marker`, at the marker's indentation.
pub fn insertAtMarker(
    arena: Allocator,
    source: []const u8,
    marker: []const u8,
    entry: []const u8,
) InsertError![]const u8 {
    assert(entry.len > 0 and std.mem.indexOfScalar(u8, entry, '\n') == null);
    var found: ?usize = null;
    var line_start: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| : (line_start += line.len + 1) {
        const content = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, content, entry)) return error.AlreadyPresent;
        if (!std.mem.eql(u8, content, marker)) continue;
        if (found != null) return error.MarkerRepeated;
        found = line_start;
    }
    const at = found orelse return error.MarkerNotFound;
    const indent_end = std.mem.indexOfNonePos(u8, source, at, " \t") orelse source.len;
    return std.mem.concat(arena, u8, &.{
        source[0..at],
        source[at..indent_end],
        entry,
        "\n",
        source[at..],
    });
}

pub const PathError = error{
    /// Absolute, empty, or with an empty, `.`, or `..` component.
    UnsafePath,
    /// An existing part of the path resolves (through a symbolic link) outside the project.
    OutsideProject,
};

/// Checks that `sub_path` stays inside `root`: lexically (relative, no `.` or `..`
/// components), and on disk, through `platform.sandbox`, where the path must resolve under
/// `root`'s real path, so a symbolic link cannot lead out.
pub fn checkInside(io: Io, root: Io.Dir, sub_path: []const u8) PathError!void {
    if (!isSafeRelative(sub_path)) return error.UnsafePath;
    const policy: platform.sandbox.Policy = .{ .roots = &.{"."} };
    policy.check(io, root, sub_path) catch |err| return switch (err) {
        error.SymlinkEscape, error.Unresolvable => error.OutsideProject,
        error.EmptyPath,
        error.NameTooLong,
        error.InvalidCharacter,
        error.UnsupportedPath,
        error.Traversal,
        error.OutsideRoots,
        => error.UnsafePath,
    };
}

/// Whether `path` is relative, `/`-separated, and free of empty, `.`, and `..` parts.
pub fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return false;
        }
        if (std.mem.indexOfAny(u8, part, "\\:") != null) return false;
    }
    return true;
}

/// One file of the plan.
pub const File = struct {
    path: []const u8,
    content: []const u8,
    /// Whether the file was on disk when the plan read it.
    existed: bool,
    changed: bool = false,
};

/// Files read from and to be written to one project directory.
pub const Plan = struct {
    io: Io,
    arena: Allocator,
    root: Io.Dir,
    files: std.ArrayList(File) = .empty,

    pub const max_file_size = 1 << 20;

    pub const ReadError = error{ FileNotFound, ReadFailed } || PathError || Allocator.Error;

    /// The file at `path`: as planned, else read from disk.
    pub fn get(plan: *Plan, path: []const u8) ReadError!*File {
        for (plan.files.items) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        try checkInside(plan.io, plan.root, path);
        const limit: Io.Limit = .limited(max_file_size);
        const content = plan.root.readFileAlloc(plan.io, path, plan.arena, limit) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ReadFailed,
            };
        };
        try plan.files.append(plan.arena, .{ .path = path, .content = content, .existed = true });
        return &plan.files.items[plan.files.items.len - 1];
    }

    /// Whether `path` exists, as planned or on disk.
    pub fn exists(plan: *Plan, path: []const u8) (PathError || Allocator.Error)!bool {
        for (plan.files.items) |file| {
            if (std.mem.eql(u8, file.path, path)) return true;
        }
        try checkInside(plan.io, plan.root, path);
        plan.root.access(plan.io, path, .{}) catch return false;
        return true;
    }

    /// Plans a new file. The caller has checked that `path` does not exist.
    pub fn create(plan: *Plan, path: []const u8, content: []const u8) Allocator.Error!void {
        try plan.files.append(plan.arena, .{
            .path = path,
            .content = content,
            .existed = false,
            .changed = true,
        });
    }

    /// Writes every new file, exclusively (an existing file is never overwritten), then
    /// every changed file, atomically, so a parent never lists a file that is not there yet.
    /// Reports each as `created <prefix><path>` or `updated <prefix><path>`.
    pub fn commit(plan: *Plan, report: *Io.Writer, prefix: []const u8) !void {
        for (plan.files.items) |file| {
            if (file.changed) try checkInside(plan.io, plan.root, file.path);
        }
        for ([_]bool{ false, true }) |existed| {
            for (plan.files.items) |file| {
                if (!file.changed or file.existed != existed) continue;
                try plan.write(file);
                const verb = if (existed) "updated" else "created";
                try report.print("{s} {s}{s}\n", .{ verb, prefix, file.path });
            }
        }
    }

    fn write(plan: *Plan, file: File) !void {
        const io = plan.io;
        if (std.fs.path.dirname(file.path)) |dir| try plan.root.createDirPath(io, dir);
        if (file.existed) {
            var atomic = try plan.root.createFileAtomic(io, file.path, .{ .replace = true });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, file.content);
            try atomic.replace(io);
        } else {
            const handle = try plan.root.createFile(io, file.path, .{ .exclusive = true });
            defer handle.close(io);
            try handle.writeStreamingAll(io, file.content);
        }
    }
};

const testing = std.testing;

test insertAtMarker {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\    .subcommands = .{
        \\        // snek:subcommands
        \\    },
        \\
    ;
    const once = try insertAtMarker(arena, source, "// snek:subcommands", "a,");
    const twice = try insertAtMarker(arena, once, "// snek:subcommands", "b,");
    try testing.expectEqualStrings(
        \\    .subcommands = .{
        \\        a,
        \\        b,
        \\        // snek:subcommands
        \\    },
        \\
    , twice);
    try testing.expectError(
        error.AlreadyPresent,
        insertAtMarker(arena, twice, "// snek:subcommands", "a,"),
    );
    try testing.expectError(error.MarkerNotFound, insertAtMarker(arena, "x\n", "// m", "a,"));
    try testing.expectError(
        error.MarkerRepeated,
        insertAtMarker(arena, "// m\n  // m\n", "// m", "a,"),
    );
    // A marker mentioned inside other text is not the marker.
    try testing.expectError(
        error.MarkerNotFound,
        insertAtMarker(arena, "//! see the // m line\n", "// m", "a,"),
    );
    const no_newline = try insertAtMarker(arena, "\t// m", "// m", "a,");
    try testing.expectEqualStrings("\ta,\n\t// m", no_newline);
}

test isSafeRelative {
    try testing.expect(isSafeRelative("src/cmd/a/b.zig"));
    try testing.expect(!isSafeRelative(""));
    try testing.expect(!isSafeRelative("/etc/passwd"));
    try testing.expect(!isSafeRelative("src/../../x"));
    try testing.expect(!isSafeRelative("src/./x"));
    try testing.expect(!isSafeRelative("src//x"));
    try testing.expect(!isSafeRelative("src\\x"));
    try testing.expect(!isSafeRelative("C:x"));
}

test checkInside {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/cmd");
    try checkInside(testing.io, tmp.dir, "src/cmd/new/file.zig");
    try testing.expectError(error.UnsafePath, checkInside(testing.io, tmp.dir, "../x"));
    tmp.dir.symLink(testing.io, "/", "src/escape", .{ .is_directory = true }) catch
        return; // No symbolic links here (Windows without privileges): nothing more to check.
    try testing.expectError(
        error.OutsideProject,
        checkInside(testing.io, tmp.dir, "src/escape/tmp/x.zig"),
    );
}
