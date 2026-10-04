//! A virtual filesystem: one interface over memory, disk and embedded assets.
//!
//! ## Why an interface, when each operation is one line
//!
//! `[measured]` what existed here was a comptime asset table with `get`,
//! `getAsset` and `extractAll`. There was no interface, no in-memory backend and
//! no read-only notion, so:
//!
//!   * a test that wanted to exercise a command's file handling had to write real
//!     files somewhere and clean them up, or not test it;
//!   * `--dry-run` could not refuse a write at a boundary, because there was no
//!     boundary - callers reached `std.Io.Dir.cwd()` directly;
//!   * "this backend cannot be written to" was expressible only as a comment.
//!
//! The interface is four operations - read, write, delete, exists - which is what
//! a command that loads and stores a file actually needs. Directory listing is
//! deliberately absent: it is the operation that makes an archive backend awkward,
//! and nothing in this tree has asked for it.
//!
//! ## Read-only is enforced here, not asked of the backend
//!
//! `read_only` is checked in `writeFile` and `deleteFile` **before** the vtable is
//! consulted, and the write slots are optional so a backend that cannot write says
//! so in its type. A convention that every implementor remember to return
//! `error.ReadOnly` is a convention that holds until the third implementor.
//!
//! ## The one ownership rule
//!
//! `readFile` returns a slice the **caller** owns, allocated from the allocator the
//! caller passed. Every backend copies, including the embedded one whose bytes are
//! comptime literals - so a caller can free unconditionally without knowing which
//! backend it was handed, which is the entire point of hiding the backend.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    FileNotFound,
    /// The backend, or this view of it, refuses writes.
    ReadOnly,
    AccessDenied,
    OutOfMemory,
    /// Anything the backend could not classify. Deliberately coarse: a caller
    /// acting on a filesystem error needs "this did not work", and the platform's
    /// errno vocabulary is not useful to expose.
    Unexpected,
};

/// Maps a platform error onto this module's vocabulary.
fn translate(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// A handle to a backend, plus the vtable that reaches it.
///
/// `ctx` points at the backend, which must outlive the `Vfs`. That is why
/// `interface()` takes a pointer: a backend copied into the handle would have its
/// state silently detached from the one the caller goes on mutating.
pub const Vfs = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    /// When set, writes fail at this layer regardless of the vtable.
    read_only: bool = false,

    pub const VTable = struct {
        read_file: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            path: []const u8,
        ) Error![]u8,
        exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
        /// Absent on a backend that cannot write. `writeFile` then reports
        /// `error.ReadOnly` rather than crashing on a null call.
        write_file: ?*const fn (ctx: *anyopaque, path: []const u8, data: []const u8) Error!void = null,
        delete_file: ?*const fn (ctx: *anyopaque, path: []const u8) Error!void = null,
    };

    /// Reads `path`. The caller owns the returned slice.
    pub fn readFile(self: Vfs, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
        assert(path.len > 0);
        return self.vtable.read_file(self.ctx, allocator, path);
    }

    /// Writes `data` to `path`, replacing anything already there.
    pub fn writeFile(self: Vfs, path: []const u8, data: []const u8) Error!void {
        assert(path.len > 0);
        if (self.read_only) return error.ReadOnly;
        const write = self.vtable.write_file orelse return error.ReadOnly;
        return write(self.ctx, path, data);
    }

    /// Removes `path`. A path that is not there is not an error, so a caller
    /// cleaning up does not have to check first.
    pub fn deleteFile(self: Vfs, path: []const u8) Error!void {
        assert(path.len > 0);
        if (self.read_only) return error.ReadOnly;
        const delete = self.vtable.delete_file orelse return error.ReadOnly;
        return delete(self.ctx, path);
    }

    /// Whether `path` is present. Total: a backend error reads as "not there",
    /// which is the answer to the question a caller is actually asking.
    pub fn exists(self: Vfs, path: []const u8) bool {
        assert(path.len > 0);
        return self.vtable.exists(self.ctx, path);
    }

    /// The same backend, refusing writes. What `--dry-run` hands to a command.
    pub fn asReadOnly(self: Vfs) Vfs {
        var copy = self;
        copy.read_only = true;
        return copy;
    }
};

/// An in-memory backend: the mock, and the target of a dry run.
///
/// Mutable on purpose. A read-only memory backend would be a fixture, and a
/// fixture cannot answer the question a dry run asks, which is what *would* have
/// been written.
pub const Memory = struct {
    files: std.StringHashMapUnmanaged([]u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.* = undefined;
    }

    /// Stores `data` at `path`, replacing any previous contents.
    ///
    /// Both the key and the value are copied, so the caller keeps ownership of what
    /// it passed - the same rule `readFile` follows in the other direction.
    pub fn put(self: *Memory, path: []const u8, data: []const u8) Error!void {
        assert(path.len > 0);

        const value = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(value);

        const entry = try self.files.getOrPut(self.allocator, path);
        if (entry.found_existing) {
            self.allocator.free(entry.value_ptr.*);
        } else {
            // The key has to be owned too: `path` may be a stack buffer that is
            // gone by the time anyone reads it back.
            entry.key_ptr.* = try self.allocator.dupe(u8, path);
        }
        entry.value_ptr.* = value;
    }

    pub fn interface(self: *Memory) Vfs {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Vfs.VTable{
        .read_file = readFileImpl,
        .exists = existsImpl,
        .write_file = writeFileImpl,
        .delete_file = deleteFileImpl,
    };

    fn readFileImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        const data = self.files.get(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, data);
    }

    fn existsImpl(ctx: *anyopaque, path: []const u8) bool {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        return self.files.contains(path);
    }

    fn writeFileImpl(ctx: *anyopaque, path: []const u8, data: []const u8) Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        return self.put(path, data);
    }

    fn deleteFileImpl(ctx: *anyopaque, path: []const u8) Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (self.files.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
    }
};

/// The real filesystem, rooted at a directory.
pub const Disk = struct {
    io: std.Io,
    dir: std.Io.Dir,

    /// A filesystem rooted at the process's working directory.
    pub fn cwd(io: std.Io) Disk {
        return .{ .io = io, .dir = std.Io.Dir.cwd() };
    }

    /// A filesystem rooted at an already-open directory.
    pub fn inDir(io: std.Io, dir: std.Io.Dir) Disk {
        return .{ .io = io, .dir = dir };
    }

    pub fn interface(self: *Disk) Vfs {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Creates a directory path.
    ///
    /// Deliberately **not** part of the `Vfs` interface: parent creation is policy,
    /// and a backend that silently created directories would turn a typo in a
    /// config path into a success.
    pub fn createDirPath(self: *Disk, path: []const u8) Error!void {
        self.dir.createDirPath(self.io, path) catch |err| return translate(err);
    }

    const max_read_bytes: u64 = 64 * 1024 * 1024;

    const vtable = Vfs.VTable{
        .read_file = readFileImpl,
        .exists = existsImpl,
        .write_file = writeFileImpl,
        .delete_file = deleteFileImpl,
    };

    fn readFileImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
        const self: *Disk = @ptrCast(@alignCast(ctx));
        return self.dir.readFileAlloc(
            self.io,
            path,
            allocator,
            // Bounded, because an unbounded read of a path a caller chose is how a
            // reader turns a mistake into an out-of-memory kill.
            std.Io.Limit.limited64(max_read_bytes),
        ) catch |err| translate(err);
    }

    fn existsImpl(ctx: *anyopaque, path: []const u8) bool {
        const self: *Disk = @ptrCast(@alignCast(ctx));
        self.dir.access(self.io, path, .{}) catch return false;
        return true;
    }

    fn writeFileImpl(ctx: *anyopaque, path: []const u8, data: []const u8) Error!void {
        const self: *Disk = @ptrCast(@alignCast(ctx));
        self.dir.writeFile(self.io, .{ .sub_path = path, .data = data }) catch |err| {
            return translate(err);
        };
    }

    fn deleteFileImpl(ctx: *anyopaque, path: []const u8) Error!void {
        const self: *Disk = @ptrCast(@alignCast(ctx));
        self.dir.deleteFile(self.io, path) catch |err| switch (err) {
            // Deleting something that is not there is what the caller wanted.
            error.FileNotFound => {},
            else => return translate(err),
        };
    }
};

/// One embedded asset.
pub const EmbeddedAsset = struct {
    path: []const u8,
    content: []const u8,
    mime: []const u8 = "application/octet-stream",
};

/// A comptime asset table, exposed as a read-only backend.
///
/// Kept as its own type rather than folded into `Memory`: the assets are comptime
/// and the table is not, so making this a `Memory` would mean copying every asset
/// onto the heap at startup to answer questions the compiler already answered.
pub const VirtualFileSystem = struct {
    assets: []const EmbeddedAsset,

    pub fn init(comptime assets: []const EmbeddedAsset) VirtualFileSystem {
        return .{ .assets = assets };
    }

    pub fn get(self: VirtualFileSystem, path: []const u8) ?[]const u8 {
        for (self.assets) |asset| {
            if (std.mem.eql(u8, asset.path, path)) {
                return asset.content;
            }
        }
        return null;
    }

    pub fn getAsset(self: VirtualFileSystem, path: []const u8) ?EmbeddedAsset {
        for (self.assets) |asset| {
            if (std.mem.eql(u8, asset.path, path)) {
                return asset;
            }
        }
        return null;
    }

    pub fn extractAll(self: VirtualFileSystem, io: std.Io, target_dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, target_dir);

        for (self.assets) |asset| {
            var full_path_buf: [512]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ target_dir, asset.path });
            if (std.fs.path.dirname(full_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }
            const file = try std.Io.Dir.cwd().createFile(io, full_path, .{ .truncate = true });
            defer file.close(io);
            try file.writePositionalAll(io, asset.content, 0);
        }
    }

    /// A read-only view over the asset table.
    pub fn interface(self: *const VirtualFileSystem) Vfs {
        return .{ .ctx = @constCast(self), .vtable = &vtable, .read_only = true };
    }

    const vtable = Vfs.VTable{
        .read_file = readFileImpl,
        .exists = existsImpl,
    };

    fn readFileImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
        const self: *const VirtualFileSystem = @ptrCast(@alignCast(ctx));
        // Copied even though these are comptime literals: a caller that had to ask
        // which backend it was handed before freeing would not have an interface.
        const content = self.get(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, content);
    }

    fn existsImpl(ctx: *anyopaque, path: []const u8) bool {
        const self: *const VirtualFileSystem = @ptrCast(@alignCast(ctx));
        return self.get(path) != null;
    }
};

/// Reads `path` through any backend and returns it uppercased.
///
/// The polymorphism test: written against `Vfs`, naming no backend. Without a
/// caller like this an "interface" can compile while only ever being used with one
/// implementation, which is an interface in name only.
pub fn readUppercased(vfs: Vfs, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    const data = try vfs.readFile(allocator, path);
    defer allocator.free(data);

    const out = try allocator.alloc(u8, data.len);
    errdefer allocator.free(out);
    for (data, 0..) |byte, i| out[i] = std.ascii.toUpper(byte);
    return out;
}

const testing = std.testing;

const test_assets = [_]EmbeddedAsset{
    .{ .path = "schema.json", .content = "{\"v\":1}", .mime = "application/json" },
    .{ .path = "notes.txt", .content = "hello" },
};

test "the memory backend round-trips a file" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();
    const vfs = memory.interface();

    try testing.expect(!vfs.exists("a.txt"));
    try vfs.writeFile("a.txt", "one");
    try testing.expect(vfs.exists("a.txt"));

    const read = try vfs.readFile(testing.allocator, "a.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("one", read);

    // A second write replaces rather than appends or leaks. The testing allocator
    // reports the leak if the old value was not freed.
    try vfs.writeFile("a.txt", "two");
    const replaced = try vfs.readFile(testing.allocator, "a.txt");
    defer testing.allocator.free(replaced);
    try testing.expectEqualStrings("two", replaced);

    try vfs.deleteFile("a.txt");
    try testing.expect(!vfs.exists("a.txt"));
}

test "reading a file that is not there is FileNotFound, not an empty slice" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    try testing.expectError(
        error.FileNotFound,
        memory.interface().readFile(testing.allocator, "absent"),
    );
}

test "deleting something absent is not an error" {
    // A caller tearing down does not want to check first, and "it is gone" is what
    // it asked for either way.
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();
    try memory.interface().deleteFile("never-existed");
}

test "the memory backend owns its keys, so a stack path is safe" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    // The key is built in a buffer that is overwritten before the read. A backend
    // that kept the caller's pointer would read the wrong file, or garbage.
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "key-{d}.txt", .{7});
    try memory.interface().writeFile(path, "value");

    @memset(&path_buf, 'x');

    const read = try memory.interface().readFile(testing.allocator, "key-7.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("value", read);
}

test "a read-only view refuses writes at the interface, not in the backend" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    var vfs = memory.interface();
    try vfs.writeFile("a.txt", "one");

    vfs.read_only = true;
    try testing.expectError(error.ReadOnly, vfs.writeFile("b.txt", "two"));
    try testing.expectError(error.ReadOnly, vfs.deleteFile("a.txt"));

    // Reads still work, and the refusal happened before the backend was reached -
    // so `b.txt` really was never written.
    try testing.expect(vfs.exists("a.txt"));
    try testing.expect(!vfs.exists("b.txt"));
    const read = try vfs.readFile(testing.allocator, "a.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("one", read);
}

test "asReadOnly returns a view without mutating the original" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();
    const vfs = memory.interface();

    const dry = vfs.asReadOnly();
    try testing.expectError(error.ReadOnly, dry.writeFile("a.txt", "one"));
    // The original handle is untouched, which is what makes a dry run safe to run
    // and then discard.
    try vfs.writeFile("a.txt", "one");
}

test "the embedded backend reads its assets and refuses every write" {
    const assets = VirtualFileSystem.init(&test_assets);
    const vfs = assets.interface();

    try testing.expect(vfs.exists("schema.json"));
    try testing.expect(!vfs.exists("absent.json"));

    const schema = try vfs.readFile(testing.allocator, "schema.json");
    defer testing.allocator.free(schema);
    try testing.expectEqualStrings("{\"v\":1}", schema);

    // Read-only from the type, not from a runtime check the backend remembered.
    try testing.expectError(error.ReadOnly, vfs.writeFile("schema.json", "replaced"));
    try testing.expectError(error.ReadOnly, vfs.deleteFile("schema.json"));

    // And the asset is untouched, so the refusal was real rather than cosmetic.
    try testing.expectEqualStrings("{\"v\":1}", assets.get("schema.json").?);
}

test "embedded reads are owned by the caller, like every other backend" {
    // Run under the testing allocator: handing back a comptime literal's pointer
    // would make the caller's `free` invalid, and this catches it.
    const assets = VirtualFileSystem.init(&test_assets);
    const data = try assets.interface().readFile(testing.allocator, "notes.txt");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hello", data);
}

test "one function reaches two different backends unchanged" {
    // The point of the interface. `readUppercased` names no backend.
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();
    try memory.interface().writeFile("greeting.txt", "hello");

    const assets = VirtualFileSystem.init(&test_assets);

    const from_memory = try readUppercased(memory.interface(), testing.allocator, "greeting.txt");
    defer testing.allocator.free(from_memory);
    try testing.expectEqualStrings("HELLO", from_memory);

    const from_embedded = try readUppercased(assets.interface(), testing.allocator, "notes.txt");
    defer testing.allocator.free(from_embedded);
    try testing.expectEqualStrings("HELLO", from_embedded);
}

test "the disk backend round-trips through the real filesystem" {
    const io = testing.io;

    // A directory of its own, under the build cache, so the test leaves nothing
    // behind that a later run would trip over.
    const dir_path = ".zig-cache/vfs-interface-test";
    var disk = Disk.cwd(io);
    try disk.createDirPath(dir_path);

    const vfs = disk.interface();
    const path = dir_path ++ "/round-trip.txt";
    defer vfs.deleteFile(path) catch {};

    try vfs.writeFile(path, "on disk");
    try testing.expect(vfs.exists(path));

    const read = try vfs.readFile(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("on disk", read);

    try vfs.deleteFile(path);
    try testing.expect(!vfs.exists(path));
}

test "a missing file on disk is FileNotFound, not an unclassified error" {
    var disk = Disk.cwd(testing.io);
    try testing.expectError(
        error.FileNotFound,
        disk.interface().readFile(testing.allocator, "no/such/file.txt"),
    );
}
