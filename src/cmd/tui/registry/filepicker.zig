//! Browse directories and choose a file.
//!
//! ```zig
//! var picker: FilePicker = try .init(gpa, io, ".", .{ .extensions = &.{ ".toml", ".yaml" } });
//! defer picker.deinit();
//! if (try tui.run(gpa, io, &picker, .{ .environ = environ }) != 0) return;
//! if (picker.status == .submitted) use(picker.chosen.?);
//! ```
//!
//! Directories come first, marked with `/`. Keys: up/down and the other `list` keys move;
//! enter, right, or l opens a directory or chooses a file; left, h, or backspace go to the
//! parent (with the cursor on the directory just left); `.` shows or hides dotfiles; esc
//! or q quits as canceled. With `extensions` set, only files ending in one of them are
//! listed. A directory that cannot be read leaves the listing as it was and says why.
//!
//! The picker reads directories with the `std.Io` it was given, when it starts and when
//! it moves; nothing else does I/O.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const List = @import("list.zig");

pub const Status = enum { active, submitted, canceled };

const FilePicker = @This();

gpa: Allocator,
io: Io,
/// The directory listed, absolute.
dir: std.ArrayList(u8) = .empty,
/// The entries of `dir`, directories first; `labels` are what the list shows.
entries: std.ArrayList(Entry) = .empty,
labels: std.ArrayList([]const u8) = .empty,
/// Holds the names and labels of the current listing.
names: std.heap.ArenaAllocator,
list: List = .{ .items = &.{} },
/// List only files ending in one of these (such as ".zig"); empty lists every file.
extensions: []const []const u8 = &.{},
show_hidden: bool = false,
/// The chosen file's absolute path, once `status` is `submitted`.
chosen: ?[]u8 = null,
status: Status = .active,
/// Why the last move failed, until the next key.
message: []const u8 = "",
styles: Styles = .{},

pub const Entry = struct { name: []const u8, directory: bool };

/// What to list.
pub const Options = struct {
    /// Only files ending in one of these; empty lists every file.
    extensions: []const []const u8 = &.{},
    show_hidden: bool = false,
};

pub const Styles = struct {
    path: tui.Style = .{ .fg = .{ .indexed = 240 } },
    message: tui.Style = .{ .fg = .{ .indexed = 203 } },
};

/// A picker listing `path` (relative to the working directory, or absolute).
pub fn init(gpa: Allocator, io: Io, path: []const u8, options: Options) !FilePicker {
    var picker: FilePicker = .{
        .gpa = gpa,
        .io = io,
        .names = .init(gpa),
        .extensions = options.extensions,
        .show_hidden = options.show_hidden,
    };
    errdefer picker.deinit();
    const real = try Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    defer gpa.free(real);
    try picker.dir.appendSlice(gpa, real);
    try picker.load(null);
    return picker;
}

pub fn deinit(picker: *FilePicker) void {
    picker.dir.deinit(picker.gpa);
    picker.entries.deinit(picker.gpa);
    picker.labels.deinit(picker.gpa);
    picker.names.deinit();
    if (picker.chosen) |path| picker.gpa.free(path);
    picker.* = undefined;
}

pub fn update(picker: *FilePicker, msg: tui.Msg) tui.Cmd {
    return picker.handle(msg) catch |err| {
        picker.message = @errorName(err);
        return .none;
    };
}

fn handle(picker: *FilePicker, msg: tui.Msg) !tui.Cmd {
    switch (msg) {
        .key => |key| {
            picker.message = "";
            if (key.matches("esc") or key.matches("q")) {
                picker.status = .canceled;
                return .quit;
            }
            if (key.matches("enter") or key.matches("right") or key.matches("l")) {
                return picker.open();
            }
            if (key.matches("left") or key.matches("h") or key.matches("backspace")) {
                try picker.up();
            } else if (key.matches(".")) {
                picker.show_hidden = !picker.show_hidden;
                const keep = if (picker.currentEntry()) |entry| entry.name else null;
                try picker.load(keep);
            } else _ = picker.list.handleKey(key);
        },
        else => _ = picker.list.update(msg),
    }
    return .none;
}

/// The highlighted entry, or null in an empty directory.
pub fn currentEntry(picker: *const FilePicker) ?Entry {
    if (picker.entries.items.len == 0) return null;
    return picker.entries.items[picker.list.cursor];
}

fn open(picker: *FilePicker) !tui.Cmd {
    const entry = picker.currentEntry() orelse return .none;
    const path = try std.fs.path.join(picker.gpa, &.{ picker.dir.items, entry.name });
    if (entry.directory) {
        defer picker.gpa.free(path);
        try picker.enter(path, null);
        return .none;
    }
    picker.chosen = path;
    picker.status = .submitted;
    return .quit;
}

fn up(picker: *FilePicker) !void {
    const parent = std.fs.path.dirname(picker.dir.items) orelse return;
    const left = try picker.gpa.dupe(u8, std.fs.path.basename(picker.dir.items));
    defer picker.gpa.free(left);
    const path = try picker.gpa.dupe(u8, parent);
    defer picker.gpa.free(path);
    try picker.enter(path, left);
}

/// Lists `path` instead, the cursor on `select` if given; on failure keeps the
/// current listing.
fn enter(picker: *FilePicker, path: []const u8, select: ?[]const u8) !void {
    const previous = try picker.dir.toOwnedSlice(picker.gpa);
    defer picker.gpa.free(previous);
    try picker.dir.appendSlice(picker.gpa, path);
    picker.load(select) catch |err| {
        picker.dir.clearRetainingCapacity();
        try picker.dir.appendSlice(picker.gpa, previous);
        return err;
    };
}

/// Reads `dir` into `entries`, sorted, the cursor on `select` or the first entry.
fn load(picker: *FilePicker, select: ?[]const u8) !void {
    var dir = try Io.Dir.openDirAbsolute(picker.io, picker.dir.items, .{ .iterate = true });
    defer dir.close(picker.io);
    var names: std.heap.ArenaAllocator = .init(picker.gpa);
    errdefer names.deinit();
    const arena = names.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(picker.gpa);
    var it = dir.iterate();
    while (try it.next(picker.io)) |entry| {
        if (!picker.show_hidden and entry.name[0] == '.') continue;
        const directory = entry.kind == .directory or
            (entry.kind == .sym_link and isDirectory(picker.io, dir, entry.name));
        if (!directory and !picker.wanted(entry.name)) continue;
        try entries.append(picker.gpa, .{
            .name = try arena.dupe(u8, entry.name),
            .directory = directory,
        });
    }
    std.mem.sortUnstable(Entry, entries.items, {}, before);
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer labels.deinit(picker.gpa);
    for (entries.items) |entry| {
        const label = if (entry.directory)
            try std.fmt.allocPrint(arena, "{s}/", .{entry.name})
        else
            entry.name;
        try labels.append(picker.gpa, label);
    }
    picker.entries.deinit(picker.gpa);
    picker.labels.deinit(picker.gpa);
    picker.names.deinit();
    picker.entries = entries;
    picker.labels = labels;
    picker.names = names;
    picker.list.cursor = 0;
    picker.list.offset = 0;
    picker.list.setItems(picker.labels.items);
    if (select) |name| for (entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) picker.list.moveTo(i);
    };
}

fn wanted(picker: *const FilePicker, name: []const u8) bool {
    if (picker.extensions.len == 0) return true;
    for (picker.extensions) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return true;
    }
    return false;
}

fn isDirectory(io: Io, dir: Io.Dir, name: []const u8) bool {
    var sub = dir.openDir(io, name, .{}) catch return false;
    sub.close(io);
    return true;
}

fn before(_: void, a: Entry, b: Entry) bool {
    if (a.directory != b.directory) return a.directory;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The directory, the entries (or "(empty)"), and a message when a move failed.
pub fn view(picker: *const FilePicker, w: *Writer) Writer.Error!void {
    try picker.styles.path.paint(w, picker.dir.items);
    try w.writeByte('\n');
    if (picker.entries.items.len == 0) {
        try picker.styles.path.paint(w, "  (empty)");
    } else {
        try picker.list.view(w);
    }
    if (picker.message.len > 0) {
        try w.writeByte('\n');
        try picker.styles.message.paint(w, picker.message);
    }
}

const testing = std.testing;
const plain: FilePicker.Styles = .{ .path = .{}, .message = .{} };

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "src/lib");
        try tmp.dir.createDirPath(io, ".git");
        for ([_][]const u8{ "build.zig", "README.md", ".env", "src/main.zig" }) |name| {
            try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
        }
        const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        defer testing.allocator.free(root);
        return .{ .tmp = tmp, .root = try testing.allocator.dupe(u8, root) };
    }

    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }
};

fn expectListing(d: *tui.testing.Driver(FilePicker), root: []const u8, rest: []const u8) !void {
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ root, rest });
    defer testing.allocator.free(expected);
    try d.expectFrame(expected);
}

fn styledPicker(io: Io, path: []const u8) !FilePicker {
    return styledPickerWith(io, path, .{});
}

fn styledPickerWith(io: Io, path: []const u8, options: FilePicker.Options) !FilePicker {
    var picker: FilePicker = try .init(testing.allocator, io, path, options);
    picker.styles = plain;
    picker.list.styles = .{ .cursor = .{}, .item = .{} };
    return picker;
}

test "directories first, into a directory and back out, then choosing a file" {
    var f: Fixture = try .init();
    defer f.deinit();
    var d: tui.testing.Driver(FilePicker) = try .init(
        testing.allocator,
        try styledPicker(testing.io, f.root),
        .{},
    );
    defer d.deinit();
    try expectListing(&d, f.root, "\n> src/\n  README.md\n  build.zig");
    try d.press("enter");
    try testing.expect(std.mem.endsWith(u8, d.model().dir.items, "src"));
    try d.press("down");
    try testing.expectEqualStrings("main.zig", d.model().currentEntry().?.name);
    try d.press("left");
    // Back in the root, on the directory just left.
    try expectListing(&d, f.root, "\n> src/\n  README.md\n  build.zig");
    try d.press("G");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(.submitted, d.model().status);
    const expected = try std.fs.path.join(testing.allocator, &.{ f.root, "build.zig" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, d.model().chosen.?);
}

test "dotfiles on request, and extensions filter files but not directories" {
    var f: Fixture = try .init();
    defer f.deinit();
    const picker = try styledPickerWith(testing.io, f.root, .{ .extensions = &.{".zig"} });
    var d: tui.testing.Driver(FilePicker) = try .init(testing.allocator, picker, .{});
    defer d.deinit();
    try expectListing(&d, f.root, "\n> src/\n  build.zig");
    try d.press(".");
    try expectListing(&d, f.root, "\n> .git/\n  src/\n  build.zig");
    try d.press(".");
    try expectListing(&d, f.root, "\n> src/\n  build.zig");
    try d.press("esc");
    try testing.expectEqual(.canceled, d.model().status);
    try testing.expectEqual(null, d.model().chosen);
}

test "an empty directory, and one that cannot be read" {
    var f: Fixture = try .init();
    defer f.deinit();
    const lib = try std.fs.path.join(testing.allocator, &.{ f.root, "src", "lib" });
    defer testing.allocator.free(lib);
    var d: tui.testing.Driver(FilePicker) = try .init(
        testing.allocator,
        try styledPicker(testing.io, lib),
        .{},
    );
    defer d.deinit();
    try expectListing(&d, lib, "\n  (empty)");
    try d.press("enter"); // nothing to open
    try testing.expect(!d.done());
    // A directory removed after it was listed fails to open; the listing stays.
    try d.press("left");
    try f.tmp.dir.deleteTree(testing.io, "src/lib");
    try d.press("enter");
    try testing.expect(std.mem.endsWith(u8, d.model().dir.items, "src"));
    try d.expectFrameContains("FileNotFound");
    try d.press("down");
    try testing.expectEqualStrings("", d.model().message);
}
