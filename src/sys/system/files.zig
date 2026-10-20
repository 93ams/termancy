//! Files a program keeps for itself: atomic writes, advisory lock files, and a small
//! private state store.
//!
//! - `writeAtomic` writes to an unnamed or temporary file and renames it over the target,
//!   so readers see the old contents or the new, never a torn mix.
//! - `Lock` is a lock file created exclusively with the owner's PID inside. A lock whose
//!   PID is no longer running is stale and is broken on the next `acquire`, as is one
//!   left empty or unparsable for longer than `Lock.stale_grace`. Advisory: it binds only
//!   processes that use it.
//! - `Store` keeps named blobs in one directory, written atomically, readable only by the
//!   user on POSIX (directory `0700`, files `0600`). On Windows the files inherit the
//!   ACL of the directory, which under `%LOCALAPPDATA%` is already private to the user.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = @import("process.zig");
const dirs = @import("dirs.zig");

const Permissions = Io.File.Permissions;
const has_modes = @hasDecl(Permissions, "fromMode");

/// `0600` on POSIX: read and write for the owner only. The default elsewhere.
pub const private_file: Permissions = if (has_modes) .fromMode(0o600) else .default_file;

/// `0700` on POSIX: the owner only. The default elsewhere.
pub const private_dir: Permissions = if (has_modes) .fromMode(0o700) else .default_dir;

/// Options for `writeAtomic`.
pub const WriteOptions = struct {
    /// Permissions of the new file (subject to the umask on POSIX).
    permissions: Permissions = .default_file,
    /// Creates missing parent directories.
    make_path: bool = false,
    /// Flushes the data to the device before the rename, so a crash cannot leave an empty
    /// file under the target name.
    sync: bool = true,
};

/// Errors from `writeAtomic`.
pub const AtomicWriteError = Io.Dir.CreateFileAtomicError || Io.File.Writer.Error ||
    Io.File.SyncError || Io.File.Atomic.ReplaceError;

/// Replaces `sub_path` in `dir` with `bytes` atomically: the data goes to a temporary
/// file in the same directory, which is then renamed over the target. On failure the
/// target is untouched and the temporary file is removed.
pub fn writeAtomic(
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    bytes: []const u8,
    options: WriteOptions,
) AtomicWriteError!void {
    var atomic = try dir.createFileAtomic(io, sub_path, .{
        .permissions = options.permissions,
        .make_path = options.make_path,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    if (options.sync) try atomic.file.sync(io);
    try atomic.replace(io);
}

/// An advisory lock held through a lock file containing the owner's PID.
pub const Lock = struct {
    dir: Io.Dir,
    /// Borrowed from the caller; must outlive the lock.
    sub_path: []const u8,
    pid: process.Pid,

    /// Errors from `acquire`.
    pub const AcquireError = error{
        /// Another running process holds the lock (or its file is unreadable).
        Locked,
        /// `sub_path` is too long to derive the name used while breaking a stale lock.
        NameTooLong,
    } || Io.File.OpenError || Io.File.Writer.Error || Io.Dir.RenameError ||
        Io.Dir.DeleteFileError || Io.Dir.ReadFileError || Io.Dir.StatFileError;

    /// How long a lock file may stay empty or without a PID before it counts as abandoned
    /// (a crash between creating it and writing the PID). Measured from its modification
    /// time, so a writer that is merely slow is not robbed.
    pub const stale_grace: Io.Duration = .fromSeconds(5);

    /// Takes the lock at `sub_path` in `dir`, creating the file exclusively with this
    /// process's PID. If the file exists and names a process that is no longer running,
    /// the stale lock is broken once and creation retried. A file without a readable PID
    /// counts as held while it is younger than `stale_grace` (its writer may be between
    /// creating it and writing the PID) and as stale after that.
    pub fn acquire(io: Io, dir: Io.Dir, sub_path: []const u8) AcquireError!Lock {
        const pid = process.currentId();
        for (0..2) |_| {
            if (try create(io, dir, sub_path, pid)) return .{
                .dir = dir,
                .sub_path = sub_path,
                .pid = pid,
            };
            const holder = try owner(io, dir, sub_path);
            if (holder) |h| {
                if (h == pid or process.isAlive(h)) return error.Locked;
            } else if (!try isAbandoned(io, dir, sub_path)) {
                return error.Locked;
            }
            try breakStale(io, dir, sub_path, holder, pid);
        }
        return error.Locked;
    }

    /// Deletes the lock file if it still names this process. Best effort: a lock that was
    /// broken and taken by another process is left alone.
    pub fn release(lock: Lock, io: Io) void {
        const holder = owner(io, lock.dir, lock.sub_path) catch return;
        if (holder != lock.pid) return;
        lock.dir.deleteFile(io, lock.sub_path) catch {};
    }

    /// The PID recorded in the lock file at `sub_path`, or `null` when the file is missing,
    /// empty, or does not hold a PID.
    pub fn owner(io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.ReadFileError!?process.Pid {
        var buffer: [32]u8 = undefined;
        const text = dir.readFile(io, sub_path, &buffer) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        return parsePid(text);
    }
};

/// Creates the lock file exclusively. `false` when it already exists.
fn create(io: Io, dir: Io.Dir, sub_path: []const u8, pid: process.Pid) Lock.AcquireError!bool {
    var file = dir.createFile(io, sub_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => |e| return e,
    };
    defer file.close(io);
    var text: [16]u8 = undefined;
    const line = std.fmt.bufPrint(&text, "{d}\n", .{pid}) catch unreachable; // u32 fits.
    file.writeStreamingAll(io, line) catch |err| {
        dir.deleteFile(io, sub_path) catch {};
        return err;
    };
    return true;
}

/// Whether the PID-less lock file at `sub_path` is older than `Lock.stale_grace`. A file
/// that vanished meanwhile counts as abandoned: the retry then simply creates it.
fn isAbandoned(io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.StatFileError!bool {
    const stat = dir.statFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => |e| return e,
    };
    const age = stat.mtime.durationTo(Io.Clock.real.now(io));
    return age.nanoseconds >= Lock.stale_grace.nanoseconds;
}

/// Moves the stale file aside before deleting it, so that a lock freshly taken by another
/// process in the meantime is recognized (its PID differs, or it is a fresh PID-less file)
/// and put back, not deleted. `stale` is null for an abandoned file without a PID.
fn breakStale(
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    stale: ?process.Pid,
    pid: process.Pid,
) Lock.AcquireError!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const aside = std.fmt.bufPrint(&buffer, "{s}.stale-{d}", .{ sub_path, pid }) catch
        return error.NameTooLong;
    dir.rename(sub_path, dir, aside, io) catch |err| switch (err) {
        error.FileNotFound => return, // Someone else broke it first.
        else => |e| return e,
    };
    const moved = try Lock.owner(io, dir, aside);
    const same = if (stale) |s|
        moved != null and moved.? == s
    else
        moved == null and try isAbandoned(io, dir, aside);
    if (same) return dir.deleteFile(io, aside);
    // A live lock was moved: restore it unless yet another one has appeared.
    dir.renamePreserve(aside, dir, sub_path, io) catch {};
    return error.Locked;
}

fn parsePid(text: []const u8) ?process.Pid {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const pid = std.fmt.parseInt(process.Pid, trimmed, 10) catch return null;
    return if (pid == 0) null else pid;
}

/// Named blobs in one private directory, each written atomically.
pub const Store = struct {
    dir: Io.Dir,

    /// Errors from `open`.
    pub const OpenError = Io.Dir.CreateDirPathOpenError || Io.Dir.SetFilePermissionsError;

    /// Errors from `read`.
    pub const ReadError = error{InvalidName} || Io.Dir.ReadFileAllocError;

    /// Errors from `write`.
    pub const WriteError = error{InvalidName} || AtomicWriteError;

    /// Errors from `delete`.
    pub const DeleteError = error{InvalidName} || Io.Dir.DeleteFileError;

    /// Opens (creating as needed) the store at `sub_path` under `parent`. On POSIX the
    /// directory is set to `0700` even when it already existed.
    pub fn open(io: Io, parent: Io.Dir, sub_path: []const u8) OpenError!Store {
        const dir = try parent.createDirPathOpen(io, sub_path, .{ .permissions = private_dir });
        errdefer dir.close(io);
        // By path: a directory handle opened without iteration may not accept `fchmod`.
        if (has_modes) try parent.setFilePermissions(io, sub_path, private_dir, .{});
        return .{ .dir = dir };
    }

    /// Closes the directory.
    pub fn close(store: Store, io: Io) void {
        store.dir.close(io);
    }

    /// The blob `name`, or `null` if it was never written; `error.StreamTooLong` when it is
    /// longer than `limit` bytes (a blob of exactly `limit` bytes is read). Caller owns the
    /// result.
    pub fn read(
        store: Store,
        io: Io,
        gpa: Allocator,
        name: []const u8,
        limit: Io.Limit,
    ) ReadError!?[]u8 {
        if (!isValidName(name)) return error.InvalidName;
        // `readFileAlloc` fails when the limit is merely reached.
        const read_limit = inclusiveLimit(limit);
        return store.dir.readFileAlloc(io, name, gpa, read_limit) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| e,
        };
    }

    /// Replaces the blob `name` with `bytes`, atomically, readable by the owner only.
    pub fn write(store: Store, io: Io, name: []const u8, bytes: []const u8) WriteError!void {
        if (!isValidName(name)) return error.InvalidName;
        return writeAtomic(io, store.dir, name, bytes, .{ .permissions = private_file });
    }

    /// Removes the blob `name`; a missing blob is not an error.
    pub fn delete(store: Store, io: Io, name: []const u8) DeleteError!void {
        if (!isValidName(name)) return error.InvalidName;
        store.dir.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    /// Whether `name` can name a blob: non-empty, at most 255 bytes, not `.` or `..`,
    /// without `/`, `\`, `:`, or control characters, not a Windows device name (`CON`,
    /// `nul.txt`), and not ending in a dot or a space, so it names a file inside the store
    /// on every OS.
    pub fn isValidName(name: []const u8) bool {
        if (name.len == 0 or name.len > 255) return false;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
        for (name) |c| switch (c) {
            '/', '\\', ':', 0...0x1f, 0x7f => return false,
            else => {},
        };
        return !dirs.isWindowsReserved(name);
    }
};

/// `limit` as `readFileAlloc` takes it: that fails when the limit is reached, so a file of
/// exactly `limit` bytes needs one more.
pub fn inclusiveLimit(limit: Io.Limit) Io.Limit {
    const n = limit.toInt() orelse return limit;
    return .limited(n +| 1);
}

/// `base` and `name` joined for showing: with the separator `base` already uses, so a path
/// reads the way it was written (`./termancy.toml`, `C:\x\termancy.toml`). `\` only on Windows
/// and only when `base` has it and no `/`; `/` otherwise. On Windows, the separators
/// inside `name` follow too. An empty `base` gives `name`.
pub fn join(gpa: Allocator, base: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (base.len == 0) return gpa.dupe(u8, name);
    const windows = builtin.os.tag == .windows;
    const sep: u8 = if (windows and std.mem.indexOfScalar(u8, base, '\\') != null and
        std.mem.indexOfScalar(u8, base, '/') == null) '\\' else '/';
    const trimmed = if (base[base.len - 1] == sep) base[0 .. base.len - 1] else base;
    const out = try std.mem.concat(gpa, u8, &.{ trimmed, &.{sep}, name });
    if (windows) for (out[trimmed.len + 1 ..]) |*c| {
        if (c.* == '/' or c.* == '\\') c.* = sep;
    };
    return out;
}

const testing = std.testing;

test "join keeps the separator the base uses" {
    const cases = [_][3][]const u8{
        .{ ".", "termancy.toml", "./termancy.toml" },
        .{ "conf", "shared/base.yaml", "conf/shared/base.yaml" },
        .{ "dir/", "a.md", "dir/a.md" },
        .{ "", "a.md", "a.md" },
        .{ "C:\\x", "termancy.toml", if (builtin.os.tag == .windows) "C:\\x\\termancy.toml" else "C:\\x/termancy.toml" },
        .{ "C:\\x", "docs/b.md", if (builtin.os.tag == .windows) "C:\\x\\docs\\b.md" else "C:\\x/docs/b.md" },
    };
    for (cases) |case| {
        const joined = try join(testing.allocator, case[0], case[1]);
        defer testing.allocator.free(joined);
        try testing.expectEqualStrings(case[2], joined);
    }
}

/// Whether the test directory's file system records POSIX modes (drvfs and FAT do not).
fn honorsModes(dir: Io.Dir) !bool {
    if (!has_modes) return false;
    try dir.writeFile(testing.io, .{ .sub_path = "probe", .data = "" });
    defer dir.deleteFile(testing.io, "probe") catch {};
    try dir.setFilePermissions(testing.io, "probe", .fromMode(0o600), .{});
    const stat = try dir.statFile(testing.io, "probe", .{});
    return stat.permissions.toMode() & 0o777 == 0o600;
}

test "writeAtomic creates and replaces" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeAtomic(testing.io, tmp.dir, "a/b.txt", "one", .{ .make_path = true });
    try writeAtomic(testing.io, tmp.dir, "a/b.txt", "two!", .{ .sync = false });
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("two!", try tmp.dir.readFile(testing.io, "a/b.txt", &buffer));
    // Nothing but the target is left behind.
    var sub = try tmp.dir.openDir(testing.io, "a", .{ .iterate = true });
    defer sub.close(testing.io);
    var it = sub.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(1, count);
}

test "a failed writeAtomic leaves the target untouched and no temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    // A directory cannot be renamed over: the write succeeds, the rename fails.
    try tmp.dir.createDir(io, "target", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "target/keep", .data = "kept" });
    try testing.expect(std.meta.isError(writeAtomic(io, tmp.dir, "target", "new", .{})));
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("kept", try tmp.dir.readFile(io, "target/keep", &buffer));
    var it = tmp.dir.iterate();
    const only = (try it.next(io)).?;
    try testing.expectEqualStrings("target", only.name);
    try testing.expectEqual(.directory, only.kind);
    try testing.expectEqual(null, try it.next(io));
}

test "writeAtomic into a missing directory fails without make_path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.FileNotFound, writeAtomic(testing.io, tmp.dir, "x/y", "", .{}));
}

test "lock: acquire, contend, release" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try Lock.acquire(testing.io, tmp.dir, "app.lock");
    const holder = (try Lock.owner(testing.io, tmp.dir, "app.lock")).?;
    try testing.expectEqual(process.currentId(), holder);
    try testing.expectError(error.Locked, Lock.acquire(testing.io, tmp.dir, "app.lock"));
    lock.release(testing.io);
    try testing.expectEqual(null, try Lock.owner(testing.io, tmp.dir, "app.lock"));
    const again = try Lock.acquire(testing.io, tmp.dir, "app.lock");
    again.release(testing.io);
}

test "lock: a dead owner's lock is broken" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.lock", .data = "2000000000\n" });
    const lock = try Lock.acquire(testing.io, tmp.dir, "app.lock");
    defer lock.release(testing.io);
    try testing.expectEqual(lock.pid, (try Lock.owner(testing.io, tmp.dir, "app.lock")).?);
    // The stale file moved aside was deleted.
    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(1, count);
}

test "lock: an empty or unparsable file older than the grace period is stale" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const old: Io.Timestamp = Io.Clock.real.now(io).subDuration(.fromSeconds(60));
    for ([_][]const u8{ "", "pid?" }) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = "app.lock", .data = data });
        {
            // Through the file: `Dir.setTimestamps` is not implemented for Windows in 0.17.
            const file = try tmp.dir.openFile(io, "app.lock", .{ .mode = .read_write });
            defer file.close(io);
            try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = old } });
        }
        const lock = try Lock.acquire(io, tmp.dir, "app.lock");
        try testing.expectEqual(lock.pid, (try Lock.owner(io, tmp.dir, "app.lock")).?);
        lock.release(io);
    }
    var it = tmp.dir.iterate();
    try testing.expectEqual(null, try it.next(io));
}

test "lock: a live owner or a fresh unreadable file holds the lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.lock", .data = "" });
    try testing.expectError(error.Locked, Lock.acquire(testing.io, tmp.dir, "empty.lock"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "junk.lock", .data = "pid?" });
    try testing.expectError(error.Locked, Lock.acquire(testing.io, tmp.dir, "junk.lock"));
    if (builtin.os.tag != .windows) {
        // PID 1 (init) is always running.
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "init.lock", .data = "1" });
        try testing.expectError(error.Locked, Lock.acquire(testing.io, tmp.dir, "init.lock"));
    }
}

test "lock: releasing a lock taken over by another PID leaves it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try Lock.acquire(testing.io, tmp.dir, "app.lock");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.lock", .data = "1\n" });
    lock.release(testing.io);
    try testing.expectEqual(1, (try Lock.owner(testing.io, tmp.dir, "app.lock")).?);
}

test "parsePid" {
    try testing.expectEqual(42, parsePid(" 42\r\n").?);
    try testing.expectEqual(null, parsePid("0"));
    try testing.expectEqual(null, parsePid("-3"));
    try testing.expectEqual(null, parsePid(""));
}

test "store round trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    const store = try Store.open(testing.io, tmp.dir, "state/app");
    defer store.close(testing.io);
    try testing.expectEqual(null, try store.read(testing.io, gpa, "token", .unlimited));
    try store.write(testing.io, "token", "secret");
    try store.write(testing.io, "token", "secret-2");
    const data = (try store.read(testing.io, testing.allocator, "token", .unlimited)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("secret-2", data);
    try testing.expectError(
        error.StreamTooLong,
        store.read(testing.io, testing.allocator, "token", .limited(3)),
    );
    // The limit is inclusive: exactly `limit` bytes are read, one more is too long.
    const exact = (try store.read(testing.io, gpa, "token", .limited(data.len))).?;
    defer gpa.free(exact);
    try testing.expectEqualStrings("secret-2", exact);
    try testing.expectError(
        error.StreamTooLong,
        store.read(testing.io, gpa, "token", .limited(data.len - 1)),
    );
    try store.delete(testing.io, "token");
    try store.delete(testing.io, "token");
    try testing.expectEqual(null, try store.read(testing.io, gpa, "token", .unlimited));
}

test "store files are private on POSIX" {
    if (!has_modes) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    if (!try honorsModes(tmp.dir)) return error.SkipZigTest;
    const store = try Store.open(testing.io, tmp.dir, "s");
    defer store.close(testing.io);
    try store.write(testing.io, "blob", "x");
    const file = try store.dir.statFile(testing.io, "blob", .{});
    try testing.expectEqual(0o600, file.permissions.toMode() & 0o777);
    const dir = try tmp.dir.statFile(testing.io, "s", .{});
    try testing.expectEqual(0o700, dir.permissions.toMode() & 0o777);
}

test "store rejects names that would escape it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try Store.open(testing.io, tmp.dir, "s");
    defer store.close(testing.io);
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "c:x", "a\nb", "nul", "CON.json", "x." }) |name| {
        try testing.expect(!Store.isValidName(name));
        try testing.expectError(error.InvalidName, store.write(testing.io, name, ""));
        try testing.expectError(error.InvalidName, store.delete(testing.io, name));
    }
    try testing.expect(Store.isValidName("session.json"));
}
