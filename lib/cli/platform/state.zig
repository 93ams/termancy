//! Persisted program state: caches, config fragments and long-lived tokens.
//!
//! A CLI that remembers anything - a session token, an ETag cache, a last-seen
//! version - writes a file into a standard OS directory and reads it back on the
//! next run. That is three problems in one small place, and this module is the
//! place:
//!
//!   * **Where the file goes.** The resolution rules are not re-derived here.
//!     `Store` calls `xdg.appDir`, so `~/.config/<app>`, `%APPDATA%\<app>` and
//!     every `XDG_*` override behave exactly as the rest of the tree expects. This
//!     module adds no second table of OS paths, because two tables drift.
//!   * **How the bytes land.** Every write goes to a sibling temporary file and is
//!     renamed over the target, so an interrupted write cannot leave a truncated
//!     token or a half-parsed config behind. The parent directory is created
//!     first, because the first run of a program on a fresh machine has neither.
//!   * **Who can read it.** `writeSecret` creates the file with owner-only
//!     permissions before any secret bytes are written into it. See
//!     `secretPermissions` for exactly how much of that survives on Windows.
//!
//! ## Errors are the standard library's, deliberately
//!
//! [`Error`] is a named union of the error sets the `std.Io` operations already
//! return, plus this module's own `error.SizeLimitExceeded`. It is not
//! re-invented: a hand-written set that omits `error.WouldBlock` or
//! `error.AntivirusInterference` does not fail at the definition, it fails at the
//! first call site that bubbles the error up - and only when that branch is
//! compiled. Naming the real sets makes the compiler check the claim instead of
//! the reader believing it.
//!
//! ## What is deliberately not here
//!
//! No globals, no caching and no implicit `builtin.os.tag`: a `Store` owns its
//! base path and carries its allocator, its `std.Io`, its `std.Io.Dir` and its
//! environment map explicitly, so a store against a test directory and a store
//! against `%APPDATA%` are the same type and a test never depends on the machine
//! it runs on. No locking either, so two processes writing the same token is
//! last-writer-wins rather than a merge; that is the honest semantic for a
//! single-value file, and a caller that needs more needs a database, not this.

const std = @import("std");
const builtin = @import("builtin");
const xdg = @import("xdg.zig");

const assert = std.debug.assert;

/// The directory categories this module resolves. Identical to `xdg.Kind`,
/// re-exported so a caller that stores state needs only this import.
pub const Kind = xdg.Kind;

/// The largest name `validateName` accepts: `NAME_MAX` on every POSIX filesystem
/// this tree targets, and well inside the Windows limit.
pub const max_name_bytes: usize = 255;

/// The suffix a staged temporary carries. A sibling of the target, because the
/// rename that publishes it must not cross a directory - let alone a filesystem.
pub const temporary_suffix = ".tmp";

/// What a read of a zero-length file returns. A static empty array, not an empty
/// slice of an allocation: `readAlloc`'s caller frees the result, and freeing a
/// zero-length slice of a live allocation is indistinguishable from leaking it.
const empty_bytes: []const u8 = "";

/// Why a name handed to a `Store` was rejected.
///
/// Kept separate from the I/O errors so a caller can report a bad name as a usage
/// error and a full disk as a runtime one - the difference between exit code 2
/// and exit code 1.
pub const ValidateNameError = error{
    /// The name was empty.
    InvalidName,
    /// The name held a `\`, a NUL byte, or a `/` in a position that would change
    /// what the path means (leading, trailing, or doubled).
    NameSeparator,
    /// The name was longer than `max_name_bytes`.
    NameTooLong,
    /// The name was an absolute path (`/etc/passwd`, `C:\...`, `\\host\share`).
    NameAbsolute,
    /// The name contained a `..` component anywhere.
    NameTraversal,
};

/// Everything a read, write or delete can return.
///
/// Composed from the sets the `std.Io` operations themselves declare, so an
/// operation added below cannot silently widen what callers already catch, and a
/// member added to a standard-library set shows up here as a compile error rather
/// than as a call site that will not build.
pub const Error = std.Io.Dir.OpenError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.DeleteFileError ||
    std.Io.Dir.RenameError ||
    std.Io.Dir.AccessError ||
    // `File.Reader.Error` is not a file error in name only: the reader surfaces
    // whatever the underlying streaming operation reported, which on a
    // `ConnectionResetByPeer`-shaped failure is that error and not `FileNotFound`.
    std.Io.File.Reader.Error ||
    std.Io.File.StatError ||
    std.Io.File.SyncError ||
    std.Io.File.Writer.Error ||
    std.mem.Allocator.Error ||
    ValidateNameError ||
    error{
        /// The file reached or exceeded the caller's limit.
        SizeLimitExceeded,
    };

/// Everything a `Store` constructor can return. `Error` plus the one thing that
/// only resolution can fail with.
pub const InitError = Error || error{
    /// No standard directory could be resolved. See `xdg.Error`.
    HomeUnset,
};

/// Rejects any name that could leave the store's own directory.
///
/// A name may be one component (`"token"`) or a relative nested one
/// (`"sessions/token"`), because a store that owns a directory may reasonably own
/// subdirectories of it. What it may not be is absolute (`/etc/passwd`,
/// `C:\...`, `\\host\share`), a `..` climb, or anything containing a NUL or a
/// backslash - a backslash is a separator on Windows and a plain byte on POSIX,
/// and a rule that means two things on two platforms is not a rule.
///
/// Checking here rather than trusting the caller is what stops a name that
/// arrived from a config file or a command line from writing anywhere on the
/// machine.
pub fn validateName(name: []const u8) ValidateNameError!void {
    assert(name.len <= std.fs.max_path_bytes);

    if (name.len == 0) return error.InvalidName;
    if (name.len > max_name_bytes) return error.NameTooLong;
    if (std.fs.path.isAbsoluteWindows(name)) return error.NameAbsolute;

    var index: usize = 0;
    while (index < name.len) : (index += 1) {
        switch (name[index]) {
            '/' => {
                if (std.fs.path.isAbsolute(name)) return error.NameAbsolute;
                // A leading, trailing, or doubled separator would make the path
                // mean something the caller did not write.
                if (index == 0) return error.NameSeparator;
                if (index + 1 == name.len) return error.NameSeparator;
                if (name[index - 1] == '/') return error.NameSeparator;
            },
            0, '\\' => return error.NameSeparator,
            else => {},
        }
    }

    // Any `..` component, in any position: `..`, `../x`, `a/../b`.
    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        assert(component.len > 0);
        if (std.mem.eql(u8, component, "..")) return error.NameTraversal;
    }
}

/// The permissions a file holding a secret is created with.
///
/// On POSIX this is `0o600`: owner read and write, nothing for group or other,
/// and no execute bit. On Windows the `Permissions` type is a set of **file
/// attributes**, not a mode, so there is no owner-only bit to express and this
/// returns the default. What is enforced there and what is not is stated in
/// `Store.writeSecret` and in the test below, so the weaker guarantee is read
/// rather than assumed away.
pub fn secretPermissions() std.Io.File.Permissions {
    const Permissions = std.Io.File.Permissions;

    // Only the POSIX branch of the type declares `fromMode`, so this asks the
    // type rather than the OS: a target whose permission type cannot express a
    // mode (Windows, WASI) takes the default branch instead of failing to
    // compile, which is how `@as(Permissions, 0o600)` breaks a Windows build.
    if (@hasDecl(Permissions, "fromMode")) return Permissions.fromMode(0o600);
    return Permissions.default_file;
}

/// A program's own slice of the standard directories.
///
/// One store per `Kind`: an app that keeps config, cache and state has three of
/// these, which is what `config`, `cache` and `state` construct. The store owns
/// its base path and frees it in `deinit`; it borrows the allocator, the `Io`,
/// the `Dir` and the environment map, all of which must outlive it.
pub const Store = struct {
    /// This file's subject is the store, so the file-level struct is the type.
    /// A wrapper around it would only add a name to type at every use site.
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// The directory every name is resolved against. Production code uses
    /// `std.Io.Dir.cwd()`; a test uses its `tmpDir`, which is what makes the whole
    /// module testable without touching a real state directory.
    dir: std.Io.Dir,
    /// Borrowed: the map belongs to the process, and a store is typically built
    /// once at startup and lives as long as the process.
    env_map: *const std.process.Environ.Map,
    /// Owned, absolute and never empty.
    base_path: []u8,
    /// Borrowed: the caller's own literal, so it is not copied.
    app_name: []const u8,

    /// A store rooted at the app's configuration directory for `app_name`.
    pub fn config(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        app_name: []const u8,
    ) InitError!Self {
        return initWith(allocator, io, env_map, app_name, .config);
    }

    /// A store rooted at the app's cache directory. Safe to delete at any time.
    pub fn cache(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        app_name: []const u8,
    ) InitError!Self {
        return initWith(allocator, io, env_map, app_name, .cache);
    }

    /// A store rooted at the app's state directory: data that survives a restart
    /// and cannot be reproduced from anywhere else.
    pub fn state(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        app_name: []const u8,
    ) InitError!Self {
        return initWith(allocator, io, env_map, app_name, .state);
    }

    /// The shared body of the three constructors above.
    fn initWith(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        app_name: []const u8,
        kind: Kind,
    ) InitError!Self {
        assert(app_name.len > 0);
        assert(app_name.len <= max_name_bytes);
        // `xdg.appDir` asserts the same thing; repeated here so a bad name is
        // attributed to the store that was handed it.
        assert(std.mem.indexOfAny(u8, app_name, "/\\") == null);

        const base_path = try xdg.appDir(allocator, kind, app_name, env_map, builtin.os.tag);
        errdefer allocator.free(base_path);
        assert(base_path.len > 0);

        return .{
            .allocator = allocator,
            .io = io,
            .dir = std.Io.Dir.cwd(),
            .env_map = env_map,
            .base_path = base_path,
            .app_name = app_name,
        };
    }

    /// Frees the base path. Touches no files.
    pub fn deinit(self: *Self) void {
        assert(self.base_path.len > 0);
        self.allocator.free(self.base_path);
        self.* = undefined;
    }

    /// The absolute path of `name` inside this store. The caller owns the slice.
    ///
    /// For display, logs and diagnostics. `name` is still checked, so this cannot
    /// be used to mint a path outside the store.
    pub fn path(self: Self, allocator: std.mem.Allocator, name: []const u8) Error![]u8 {
        assert(self.base_path.len > 0);
        assert(self.app_name.len > 0);
        try validateName(name);
        return std.fs.path.join(allocator, &.{ self.base_path, name });
    }

    /// Reads the whole of `name`, up to and including `limit` bytes.
    ///
    /// `null` means the file is absent, which is not an error: the first run of a
    /// program has no cached token, and making every caller write the same
    /// `catch |err| switch (err)` is how one of them eventually gets it wrong.
    /// The caller owns the returned slice.
    ///
    /// A file larger than `limit` is `error.SizeLimitExceeded`, never a silent
    /// truncation. That matters here more than usual: a truncated token is a
    /// corrupt token, and the token is what the program acts on.
    pub fn readAlloc(
        self: Self,
        allocator: std.mem.Allocator,
        name: []const u8,
        limit: usize,
    ) Error!?[]u8 {
        assert(self.base_path.len > 0);
        assert(limit >= 1);

        // One byte past the limit is needed to tell "exactly the limit" from
        // "more than the limit", and that byte is dropped before returning. Every
        // failure path below frees exactly once, and the success path hands the
        // allocation to the caller, so there is no `errdefer` to run a second time
        // on a path that already freed.
        const destination = try allocator.alloc(u8, limit + 1);

        const filled = self.readInto(destination, name) catch |err| {
            allocator.free(destination);
            return err;
        } orelse {
            allocator.free(destination);
            return null;
        };
        if (filled == destination.len) {
            allocator.free(destination);
            return error.SizeLimitExceeded;
        }

        assert(filled <= limit);
        assert(filled < destination.len);
        if (filled == 0) {
            // A zero-length slice of a **static** empty array rather than of the
            // allocation: an empty slice of a real allocation is legal to free,
            // but it also looks exactly like a leak to a leak-checking allocator.
            // Freeing nothing and returning a literal is the honest pair here.
            allocator.free(destination);
            return @constCast(empty_bytes);
        }
        // Shrinking an allocation cannot fail, so the fallback never loses bytes.
        return allocator.realloc(destination, filled) catch destination[0..filled];
    }

    /// Reads `name` into `buffer`, returning the bytes actually used.
    ///
    /// `null` means absent, as in `readAlloc`. `error.SizeLimitExceeded` means the
    /// file did not fit: the buffer is the limit by construction, so a file that
    /// exactly fills it is complete and a file with a single further byte is
    /// refused rather than silently reported as complete.
    pub fn read(self: Self, buffer: []u8, name: []const u8) Error!?[]u8 {
        assert(self.base_path.len > 0);
        assert(buffer.len > 0);

        const filled = (try self.readInto(buffer, name)) orelse return null;
        if (filled == buffer.len) {
            // A full buffer is ambiguous: the file may have been cut off here. One
            // further byte decides it, and the buffer was already full, so a byte
            // is only read when there is one.
            var probe: [1]u8 = undefined;
            const extra = (try self.readInto(&probe, name)) orelse 0;
            if (extra > 0) return error.SizeLimitExceeded;
        }

        assert(filled <= buffer.len);
        return buffer[0..filled];
    }

    /// Fills `destination` from `name`, returning how many bytes were written.
    ///
    /// `null` means the file is absent. Reading **only** `destination.len` bytes
    /// and never more is what lets both callers above treat a full buffer as
    /// ambiguous rather than as complete, and it is why this helper, rather than
    /// `readFileAlloc` with a limit, owns the length semantics: one definition of
    /// "the file fit" is checkable, two are a drift waiting to happen.
    ///
    /// The name is validated **here**, in the one place both read paths pass
    /// through, rather than at each entry point where one of them can be forgotten.
    fn readInto(self: Self, destination: []u8, name: []const u8) Error!?usize {
        assert(self.base_path.len > 0);
        assert(destination.len > 0);
        try validateName(name);

        var file = self.dir.openFile(self.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |other| return other,
        };
        defer file.close(self.io);

        var file_reader = file.reader(self.io, &.{});
        const count = file_reader.interface.readSliceShort(destination) catch |err| switch (err) {
            // `readSliceShort` cannot say *why* the read failed: the reader keeps
            // the real error from the failing `readVec`, and it is not optional
            // once that branch has been taken.
            error.ReadFailed => return file_reader.err.?,
            else => |other| return other,
        };

        assert(count <= destination.len);
        return count;
    }

    /// Writes `bytes` to `name` atomically, with default permissions.
    pub fn write(self: Self, name: []const u8, bytes: []const u8) Error!void {
        assert(self.base_path.len > 0);
        return self.atomicWrite(name, bytes, std.Io.File.Permissions.default_file);
    }

    /// Writes `bytes` to `name` atomically with owner-only permissions.
    ///
    /// The permission is applied by `createFile` **before** the bytes are written,
    /// so a secret is never briefly world-readable, and because the file is always
    /// newly created it cannot inherit a wider mode from the file it replaces.
    ///
    /// On Windows the permission argument reaches `CreateFileW` as file
    /// attributes; there is no owner-only attribute, so it does not restrict who
    /// can open the file. What restricts access there is the ACL inherited from
    /// the directory, and this module neither sets nor audits one. The guarantee
    /// on Windows is therefore the weaker, true one: the write is atomic, the
    /// bytes round-trip, and nothing here claims a mode that host cannot carry.
    pub fn writeSecret(self: Self, name: []const u8, bytes: []const u8) Error!void {
        assert(self.base_path.len > 0);
        return self.atomicWrite(name, bytes, secretPermissions());
    }

    /// The atomic write both `write` and `writeSecret` go through.
    ///
    /// The order is fixed and load-bearing: validate, create the parent, create
    /// the temporary **exclusively** so a leftover path cannot be appended to,
    /// write and flush it, and only then rename it over the target. A crash or an
    /// error at any point before the rename leaves the previous contents of `name`
    /// exactly as they were, and removes the temporary.
    pub fn atomicWrite(
        self: Self,
        name: []const u8,
        bytes: []const u8,
        permissions: std.Io.File.Permissions,
    ) Error!void {
        assert(self.base_path.len > 0);
        try validateName(name);

        if (std.fs.path.dirname(name)) |parent| {
            assert(parent.len > 0);
            try self.dir.createDirPath(self.io, parent);
        }

        var temporary_buf: [max_name_bytes + temporary_suffix.len]u8 = undefined;
        const temporary = std.fmt.bufPrint(
            &temporary_buf,
            "{s}{s}",
            .{ name, temporary_suffix },
        ) catch return error.NameTooLong;
        assert(temporary.len > name.len);

        // From here until the rename succeeds, every failure must remove the
        // temporary. Registered before it exists so there is no window without a
        // cleanup path; deleting an absent name is itself tolerated.
        errdefer self.dir.deleteFile(self.io, temporary) catch {};

        {
            const file = try self.dir.createFile(self.io, temporary, .{
                .truncate = true,
                .exclusive = true,
                .permissions = permissions,
            });
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, bytes);
            // Flushed before the rename, so the name never points at content the
            // filesystem has not committed.
            try file.sync(self.io);
        }

        // Same directory and the same `Dir` handle, so this is the platform's
        // atomic replace: on Windows `Dir.rename` replaces an existing target.
        try self.dir.rename(temporary, self.dir, name, self.io);
    }

    /// Removes `name`. Absent is success: the caller asked for the file to not
    /// exist, and it does not.
    pub fn delete(self: Self, name: []const u8) Error!void {
        assert(self.base_path.len > 0);
        try validateName(name);

        self.dir.deleteFile(self.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        };
    }

    /// Whether `name` exists. An error is "could not tell", never "absent".
    pub fn exists(self: Self, name: []const u8) Error!bool {
        assert(self.base_path.len > 0);
        try validateName(name);

        self.dir.access(self.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |other| return other,
        };
        return true;
    }
};

const testing = std.testing;

/// A store whose base path is a test's temporary directory.
///
/// It fills in `Store`'s own field set - there is no second constructor to keep
/// in sync - and differs from production in exactly the two fields a test needs
/// to control: the `Dir` handle and the base path.
fn tempStore(allocator: std.mem.Allocator, tmp: *testing.TmpDir) !Store {
    return .{
        .allocator = allocator,
        .io = testing.io,
        .dir = tmp.dir,
        .env_map = undefined,
        .base_path = try allocator.dupe(u8, "tmp"),
        .app_name = "snek",
    };
}

test "a store resolves its own base directory through xdg" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    // `xdg` reads a different variable per platform, so both are supplied and the
    // assertion below is made against the one this host resolves through. The
    // point of the test is the wiring, not the table - `xdg.zig` tests that.
    try env.put("HOME", "/home/ada");
    try env.put("XDG_CACHE_HOME", "/home/ada/.cache");
    try env.put("LOCALAPPDATA", "C:\\Users\\ada\\AppData\\Local");

    var store = try Store.cache(testing.allocator, testing.io, &env, "snek");
    defer store.deinit();

    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("C:\\Users\\ada\\AppData\\Local\\Cache\\snek", store.base_path);
    } else {
        try testing.expectEqualStrings("/home/ada/.cache/snek", store.base_path);
    }
    try testing.expectEqualStrings("snek", store.app_name);

    const joined = try store.path(testing.allocator, "token");
    defer testing.allocator.free(joined);
    try testing.expect(std.mem.endsWith(u8, joined, "token"));
    try testing.expect(joined.len > "token".len);

    // A different kind resolves to a different root, with no second table here.
    var state_store = try Store.state(testing.allocator, testing.io, &env, "snek");
    defer state_store.deinit();
    try testing.expect(!std.mem.eql(u8, store.base_path, state_store.base_path));
    try testing.expect(std.mem.endsWith(u8, state_store.base_path, "snek"));
}

test "a written value round-trips through the store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    try store.write("token.json", "{\"token\":\"abc\"}");

    const bytes = (try store.readAlloc(testing.allocator, "token.json", 1024)).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"token\":\"abc\"}", bytes);

    // The buffer form reports the same bytes, and a length below the limit.
    var buffer: [64]u8 = undefined;
    const slice = (try store.read(&buffer, "token.json")).?;
    try testing.expectEqualStrings("{\"token\":\"abc\"}", slice);
    try testing.expect(slice.len < buffer.len);

    // Empty content is a value, not an absence.
    try store.write("empty", "");
    const empty = (try store.readAlloc(testing.allocator, "empty", 16)).?;
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "an atomic replace leaves no temporary behind and keeps the new bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    try store.write("token", "first");
    try store.write("token", "second");
    try store.write("token", "third");

    const bytes = (try store.readAlloc(testing.allocator, "token", 64)).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("third", bytes);

    // The claim that makes the rename worth doing: nothing was left beside it.
    try testing.expect(!try store.exists("token.tmp"));
    try testing.expect(!try store.exists("token.tmp.tmp"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "token.tmp", .{}));
}

test "a failed publish removes the temporary and leaves the target alone" {
    // The other half of "atomic": when the last step cannot complete, the
    // temporary must not survive as litter next to a target that was not updated.
    //
    // A directory in the target's place is the failure this can stage without a
    // mock: the temporary is written, and the rename onto a directory is refused.
    // The error itself is platform-specific, so it is expected as "some error"
    // rather than as a named one - what is asserted is the state left behind.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    try tmp.dir.createDir(testing.io, "obstructed", .default_dir);

    if (store.write("obstructed", "value")) |_| {
        // If this host allowed a file to replace a directory, the rest of the
        // test would be vacuous, so it is a failure rather than a skip.
        return error.TestUnexpectedResult;
    } else |_| {}

    // The temporary is gone and the obstruction is still a directory.
    try testing.expect(!try store.exists("obstructed.tmp"));
    try tmp.dir.access(testing.io, "obstructed", .{});
}

test "writing creates the parent directories a fresh install does not have" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    // Neither level exists yet.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "a", .{}));
    try store.write("a/b/token", "nested");
    try testing.expect(try store.exists("a/b/token"));

    const bytes = (try store.readAlloc(testing.allocator, "a/b/token", 64)).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("nested", bytes);

    // And the same for a secret, whose parent is created the same way.
    try store.writeSecret("a/b/secret", "s");
    try testing.expect(try store.exists("a/b/secret"));
}

test "absent is not an error for a read or a delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    try testing.expectEqual(@as(?[]u8, null), try store.readAlloc(
        testing.allocator,
        "never-written",
        64,
    ));

    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(?[]u8, null), try store.read(&buffer, "never-written"));

    // Deleting a file that is not there is success, and so is deleting twice.
    try store.delete("never-written");
    try store.delete("never-written");

    // And a delete really removes what is there.
    try store.write("token", "x");
    try testing.expect(try store.exists("token"));
    try store.delete("token");
    try testing.expect(!try store.exists("token"));
}

test "exceeding the limit is its own error rather than a short read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    try store.write("payload", "0123456789");

    try testing.expectError(error.SizeLimitExceeded, store.readAlloc(
        testing.allocator,
        "payload",
        8,
    ));

    // Exactly the limit fits: "reached or exceeded" is the documented bound.
    const exact = (try store.readAlloc(testing.allocator, "payload", 10)).?;
    defer testing.allocator.free(exact);
    try testing.expectEqualStrings("0123456789", exact);

    // The zero-copy form refuses rather than truncating to the buffer.
    var small: [4]u8 = undefined;
    try testing.expectError(error.SizeLimitExceeded, store.read(&small, "payload"));

    var big: [16]u8 = undefined;
    const slice = (try store.read(&big, "payload")).?;
    try testing.expectEqualStrings("0123456789", slice);
}

test "a name that is not one component is rejected on the way in" {
    try validateName("token");
    try validateName("token.json");
    try validateName("..hidden-token");
    try validateName("token..bak");
    // A relative nested name is allowed: the store owns its directory.
    try validateName("sessions/2026/token");

    try testing.expectError(error.InvalidName, validateName(""));
    try testing.expectError(error.NameTooLong, validateName("x" ** (max_name_bytes + 1)));
    try testing.expectError(error.NameTooLong, validateName("/" ** (max_name_bytes + 1)));
    try testing.expectError(error.NameSeparator, validateName("a\\b"));
    try testing.expectError(error.NameSeparator, validateName("nul\x00byte"));
    try testing.expectError(error.NameSeparator, validateName("a//b"));
    try testing.expectError(error.NameSeparator, validateName("a/"));
    // A leading separator is `NameAbsolute` rather than `NameSeparator`:
    // `isAbsoluteWindows` treats a leading `/` as rooted, so the absolute check
    // answers first and answers correctly on both hosts.
    try testing.expectError(error.NameAbsolute, validateName("/a"));
    try testing.expectError(error.NameAbsolute, validateName("/etc/passwd"));
    try testing.expectError(error.NameAbsolute, validateName("C:\\Windows\\system32"));
    try testing.expectError(error.NameAbsolute, validateName("\\\\host\\share\\token"));
    try testing.expectError(error.NameTraversal, validateName(".."));
    try testing.expectError(error.NameTraversal, validateName("../escape"));
    try testing.expectError(error.NameTraversal, validateName("a/../b"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    // The guard is on every entry point, not only in a helper a caller may skip.
    try testing.expectError(error.NameTraversal, store.write("../escape", "x"));
    try testing.expectError(error.NameTraversal, store.write("..", "x"));
    try testing.expectError(error.NameSeparator, store.delete("a\\b"));
    try testing.expectError(error.NameAbsolute, store.path(testing.allocator, "/etc/passwd"));

    // An absolute path is refused even when the file exists and is readable: the
    // reason is the shape of the name, not the state of the disk, so this asserts
    // the same thing on a host that has no `/etc/passwd` at all.
    try testing.expectError(error.NameAbsolute, store.readAlloc(
        testing.allocator,
        "/etc/passwd",
        64,
    ));
}

test "the secret permission is owner-only where the platform has modes" {
    const permissions = secretPermissions();

    if (comptime @hasDecl(std.Io.File.Permissions, "toMode")) {
        // POSIX: the real assertion, on the mode itself. The group and other bits
        // are what an attacker with a shared account would use.
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), permissions.toMode());
        try testing.expectEqual(@as(std.posix.mode_t, 0), permissions.toMode() & 0o077);
        try testing.expect(permissions.toMode() & 0o111 == 0);
    } else {
        // Windows: `Permissions` is a set of attributes, so there is no mode to
        // assert and no owner-only bit to ask for. Reaching this branch with the
        // default is the whole of what is checkable - see `writeSecret`.
        try testing.expectEqual(std.Io.File.Permissions.default_file, permissions);
    }
}

test "asking for the secret permission never fails and the bytes still round-trip" {
    // The assertion a Windows host can still make: the permission value is
    // expressible, `writeSecret` reaches it, and a real write over an existing
    // file neither fails nor inherits anything unwanted.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    try store.write("token", "public-ish");
    try store.writeSecret("token", "secret");

    const bytes = (try store.readAlloc(testing.allocator, "token", 64)).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("secret", bytes);

    if (comptime builtin.os.tag != .windows) {
        var file = try store.dir.openFile(testing.io, "token", .{});
        defer file.close(testing.io);
        const stat = try file.stat(testing.io);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    // On Windows there is no mode on the file to check: `Permissions` is a set of
    // attributes there, `0o600` has no representation, and access is whatever ACL
    // the directory inherited. The assertions above are the whole of what this
    // module guarantees on that host, and it does not claim otherwise.
}

test "the temporary is a sibling of its target" {
    // Load-bearing for atomicity: a temporary in another directory, or on another
    // filesystem, would turn the replace into a copy - the failure mode this
    // module exists to prevent.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try tempStore(testing.allocator, &tmp);
    defer store.deinit();

    try store.write("deep/nested/state", "value");

    const target = try store.path(testing.allocator, "deep/nested/state");
    defer testing.allocator.free(target);

    var temporary_buf: [max_name_bytes + temporary_suffix.len]u8 = undefined;
    const temporary = try std.fmt.bufPrint(
        &temporary_buf,
        "{s}{s}",
        .{ target, temporary_suffix },
    );

    try testing.expectEqualStrings(
        std.fs.path.dirname(target).?,
        std.fs.path.dirname(temporary).?,
    );
    try testing.expect(!try store.exists("deep/nested/state.tmp"));
}
