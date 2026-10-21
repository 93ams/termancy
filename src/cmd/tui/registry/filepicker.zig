//! Browse directories and choose a file.
//!
//! ```zig
//! var picker: FilePicker = try .init(gpa, io, ".", .{ .extensions = &.{ ".toml", ".yaml" } });
//! defer picker.deinit();
//! if (try tui.run(gpa, io, &picker, .{ .environ = environ }) != 0) return;
//! if (picker.status == .submitted) use(picker.chosen.?);
//! ```
//!
//! Directories come first, marked with `/`; a symbolic link shows where it points
//! (`name → target`). Keys: up/down and the other `list` keys move; enter chooses (a file,
//! or with `allow_directories` a directory) or else opens the directory; right or l opens
//! a directory; left, h, or backspace go to the parent (with the cursor on the directory
//! just left); `.` shows or hides dotfiles; esc or q quits as canceled. With `extensions`
//! set, only files ending in one of them are listed. A directory that cannot be read
//! leaves the listing as it was and says why.
//!
//! `show_permissions` and `show_size` add columns before the name, as gum's file picker
//! has them: `drwxr-xr-x   4.1kB src/`. The highlighted row is all in `styles.selected`;
//! the others are styled part by part.
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
/// The entries of `dir`, directories first; `labels` are their names as shown.
entries: std.ArrayList(Entry) = .empty,
labels: std.ArrayList([]const u8) = .empty,
/// Holds the names and labels of the current listing.
names: std.heap.ArenaAllocator,
list: List = .{ .items = &.{} },
/// List only files ending in one of these (such as ".zig"); empty lists every file.
extensions: []const []const u8 = &.{},
show_hidden: bool = false,
show_permissions: bool = false,
show_size: bool = false,
/// Columns the size takes, right-aligned.
size_width: usize = 8,
/// The most entries shown; fewer when the terminal is too short for them.
height: usize = 10,
/// What enter chooses: files, and directories (which it otherwise opens).
allow_files: bool = true,
allow_directories: bool = false,
/// Written above the directory, already styled.
header: []const u8 = "",
/// The home directory, shown as `~` at the start of the directory; empty for none.
home: []const u8 = "",
/// The chosen file's absolute path, once `status` is `submitted`.
chosen: ?[]u8 = null,
status: Status = .active,
/// Why the last move failed, until the next key.
message: []const u8 = "",
styles: Styles = .{},

pub const Entry = struct {
    name: []const u8,
    /// A directory, or a link to one: it opens.
    directory: bool,
    /// Where a symbolic link points; null for anything else.
    target: ?[]const u8 = null,
    /// As `ls -l` shows it; read only for `show_permissions` or `show_size`.
    permissions: [10]u8 = @splat('?'),
    size: u64 = 0,
};

/// What to list.
pub const Options = struct {
    /// Only files ending in one of these; empty lists every file.
    extensions: []const []const u8 = &.{},
    show_hidden: bool = false,
    show_permissions: bool = false,
    show_size: bool = false,
    allow_files: bool = true,
    allow_directories: bool = false,
};

pub const Styles = struct {
    path: tui.Style = .{ .fg = .{ .indexed = 240 } },
    message: tui.Style = .{ .fg = .{ .indexed = 203 } },
    /// The highlighted row after the cursor (`list.styles.cursor` draws the cursor).
    selected: tui.Style = .{ .fg = .{ .indexed = 212 }, .bold = true },
    directory: tui.Style = .{ .fg = .{ .indexed = 99 } },
    file: tui.Style = .{},
    symlink: tui.Style = .{ .fg = .{ .indexed = 36 } },
    permissions: tui.Style = .{ .fg = .{ .indexed = 244 } },
    size: tui.Style = .{ .fg = .{ .indexed = 240 } },
};

/// A picker listing `path` (relative to the working directory, or absolute).
pub fn init(gpa: Allocator, io: Io, path: []const u8, options: Options) !FilePicker {
    var picker: FilePicker = .{
        .gpa = gpa,
        .io = io,
        .names = .init(gpa),
        .extensions = options.extensions,
        .show_hidden = options.show_hidden,
        .show_permissions = options.show_permissions,
        .show_size = options.show_size,
        .allow_files = options.allow_files,
        .allow_directories = options.allow_directories,
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
            if (key.matches("enter")) return picker.choose();
            if (key.matches("right") or key.matches("l")) {
                try picker.open();
            } else if (key.matches("left") or key.matches("h") or key.matches("backspace")) {
                try picker.up();
            } else if (key.matches(".")) {
                picker.show_hidden = !picker.show_hidden;
                const keep = if (picker.currentEntry()) |entry| entry.name else null;
                try picker.load(keep);
            } else _ = picker.list.handleKey(key);
        },
        .resize => |size| {
            // The header, the directory, and a message take a row each.
            const header = if (picker.header.len > 0) std.mem.count(u8, picker.header, "\n") + 1 else 0;
            const room = @as(usize, size.height) -| (header + 2);
            picker.list.height = @max(1, @min(picker.height, room));
            picker.list.moveTo(picker.list.cursor);
            _ = picker.list.update(msg);
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

/// Chooses the highlighted entry if its kind may be chosen, or else opens it.
fn choose(picker: *FilePicker) !tui.Cmd {
    const entry = picker.currentEntry() orelse return .none;
    const allowed = if (entry.directory) picker.allow_directories else picker.allow_files;
    if (!allowed) {
        try picker.open();
        return .none;
    }
    picker.chosen = try std.fs.path.join(picker.gpa, &.{ picker.dir.items, entry.name });
    picker.status = .submitted;
    return .quit;
}

/// Lists the highlighted entry, if it is a directory.
fn open(picker: *FilePicker) !void {
    const entry = picker.currentEntry() orelse return;
    if (!entry.directory) return;
    const path = try std.fs.path.join(picker.gpa, &.{ picker.dir.items, entry.name });
    defer picker.gpa.free(path);
    try picker.enter(path, null);
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
        var item: Entry = .{ .name = try arena.dupe(u8, entry.name), .directory = directory };
        if (entry.kind == .sym_link) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (dir.readLink(picker.io, entry.name, &buffer)) |len| {
                item.target = try arena.dupe(u8, buffer[0..len]);
            } else |_| {}
        }
        if (picker.show_permissions or picker.show_size) {
            const lstat: Io.Dir.StatFileOptions = .{ .follow_symlinks = false };
            if (dir.statFile(picker.io, entry.name, lstat)) |stat| {
                item.permissions = permissionsOf(stat, entry.name);
                item.size = stat.size;
            } else |_| {}
        }
        try entries.append(picker.gpa, item);
    }
    std.mem.sortUnstable(Entry, entries.items, {}, before);
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer labels.deinit(picker.gpa);
    for (entries.items) |entry| {
        const slash: []const u8 = if (entry.directory) "/" else "";
        const label = if (entry.target) |target|
            try std.fmt.allocPrint(arena, "{s}{s} → {s}", .{ entry.name, slash, target })
        else if (entry.directory)
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

/// `ls -l`'s mode column: the kind, then read, write, and execute for the owner, the
/// group, and others; on Windows, what its attributes and `name` imply (`windowsBits`).
fn permissionsOf(stat: Io.File.Stat, name: []const u8) [10]u8 {
    var mode: [10]u8 = "-rwxrwxrwx".*;
    mode[0] = switch (stat.kind) {
        .directory => 'd',
        .sym_link => 'l',
        .named_pipe => 'p',
        .unix_domain_socket => 's',
        .character_device => 'c',
        .block_device => 'b',
        else => '-',
    };
    const Permissions = Io.File.Permissions;
    const bits: u32 = if (@hasDecl(Permissions, "toMode"))
        @intCast(stat.permissions.toMode() & 0o777)
    else if (@hasDecl(Permissions, "toAttributes"))
        // The attributes themselves; bit 0 is FILE_ATTRIBUTE_READONLY.
        windowsBits(@backingInt(stat.permissions) & 1 != 0, stat.kind == .directory, name)
    else
        0o666;
    for (mode[1..], 0..) |*c, i| {
        if (bits & (@as(u32, 0o400) >> @intCast(i)) == 0) c.* = '-';
    }
    return mode;
}

/// What Windows implies for every class: read, write unless read-only, and execute for
/// a directory or a program (`.exe`, `.bat`, `.cmd`, `.com`).
fn windowsBits(read_only: bool, directory: bool, name: []const u8) u32 {
    var bits: u32 = if (read_only) 0o444 else 0o666;
    const program = for ([_][]const u8{ ".exe", ".bat", ".cmd", ".com" }) |extension| {
        if (std.ascii.endsWithIgnoreCase(name, extension)) break true;
    } else false;
    if (directory or program) bits |= 0o111;
    return bits;
}

/// `bytes` as gum's file picker shows a size (go-humanize's, without the space): powers
/// of 1000, one decimal below ten: `6B`, `4.1kB`, `15MB`.
fn formatSize(buffer: *[16]u8, bytes: u64) []const u8 {
    if (bytes < 10) return std.fmt.bufPrint(buffer, "{d}B", .{bytes}) catch unreachable;
    const units = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB", "EB" };
    const value: f64 = @floatFromInt(bytes);
    const exponent: usize = @intFromFloat(@floor(@log10(value) / 3));
    const scale = std.math.pow(f64, 1000, @floatFromInt(exponent));
    const rounded = @floor(value / scale * 10 + 0.5) / 10;
    const unit = units[exponent];
    if (rounded < 10) return std.fmt.bufPrint(buffer, "{d:.1}{s}", .{ rounded, unit }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d:.0}{s}", .{ rounded, unit }) catch unreachable;
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

/// The header, the directory, the entries (or "(empty)"), and a message when a move
/// failed.
pub fn view(picker: *const FilePicker, w: *Writer) Writer.Error!void {
    if (picker.header.len > 0) {
        try w.writeAll(picker.header);
        try w.writeByte('\n');
    }
    try picker.writeDirectory(w);
    try w.writeByte('\n');
    if (picker.entries.items.len == 0) {
        try picker.styles.path.paint(w, "  (empty)");
    } else {
        const shown = picker.list.window();
        for (shown.start..shown.end) |i| {
            if (i > shown.start) try w.writeByte('\n');
            try picker.writeEntry(w, i);
        }
    }
    if (picker.message.len > 0) {
        try w.writeByte('\n');
        try picker.styles.message.paint(w, picker.message);
    }
}

/// The directory on one row: the home directory as `~`, and a path too long for the width
/// cut from the left.
fn writeDirectory(picker: *const FilePicker, w: *Writer) Writer.Error!void {
    const dir = picker.dir.items;
    const home = picker.home;
    const under_home = home.len > 0 and std.mem.startsWith(u8, dir, home) and
        (dir.len == home.len or std.fs.path.isSep(dir[home.len]));
    const rest = if (under_home) dir[home.len..] else dir;
    const tilde: []const u8 = if (under_home) "~" else "";
    const style = picker.styles.path;
    try style.writeSgr(w);
    const width = picker.list.width orelse std.math.maxInt(usize);
    if (tui.width.of(rest) + tilde.len <= width) {
        try w.print("{s}{s}", .{ tilde, rest });
    } else {
        try tui.width.truncateLeft(w, rest, width, "…");
    }
    if (style.hasSgr()) try w.writeAll(tui.ansi.reset);
}

/// Entry `index`: the cursor (or as much space), the permissions and size when shown,
/// and the name, cut to the width.
fn writeEntry(picker: *const FilePicker, w: *Writer, index: usize) Writer.Error!void {
    const entry = picker.entries.items[index];
    const list = &picker.list;
    const s = picker.styles;
    const is_cursor = index == list.cursor;
    const prefix = if (is_cursor) list.cursor_prefix else list.item_prefix;
    try (if (is_cursor) list.styles.cursor else list.styles.item).paint(w, prefix);
    // The cursor's row is all in `selected`, so its parts have no styles of their own.
    const none: tui.Style = .{};
    if (is_cursor) try s.selected.writeSgr(w);
    var used = tui.width.of(prefix);
    if (picker.show_permissions) {
        try (if (is_cursor) none else s.permissions).paint(w, &entry.permissions);
        used += entry.permissions.len;
    }
    if (picker.show_size) {
        var buffer: [16]u8 = undefined;
        const size = formatSize(&buffer, entry.size);
        try w.splatByteAll(' ', picker.size_width -| size.len);
        try (if (is_cursor) none else s.size).paint(w, size);
        used += @max(picker.size_width, size.len);
    }
    if (picker.show_permissions or picker.show_size) {
        try w.writeByte(' ');
        used += 1;
    }
    const name = if (is_cursor) none else if (entry.target != null)
        s.symlink
    else if (entry.directory) s.directory else s.file;
    try name.writeSgr(w);
    const label = picker.labels.items[index];
    if (list.width) |width| {
        try tui.width.truncate(w, label, width -| used, "…");
    } else try w.writeAll(label);
    if (name.hasSgr() or (is_cursor and s.selected.hasSgr())) try w.writeAll(tui.ansi.reset);
}

const testing = std.testing;
const plain: FilePicker.Styles = .{
    .path = .{},
    .message = .{},
    .selected = .{},
    .directory = .{},
    .symlink = .{},
    .permissions = .{},
    .size = .{},
};

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

test "permissions, sizes, and where a link points" {
    if (!@hasDecl(Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = &@as([1234]u8, @splat('x')) });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "seven b" });
    try tmp.dir.setFilePermissions(io, "a.txt", .fromMode(0o640), .{});
    try tmp.dir.setFilePermissions(io, "b", .fromMode(0o755), .{});
    try tmp.dir.symLink(io, "a.txt", "link", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const options: FilePicker.Options = .{ .show_permissions = true, .show_size = true };
    var d: tui.testing.Driver(FilePicker) = try .init(
        testing.allocator,
        try styledPickerWith(io, root, options),
        .{},
    );
    defer d.deinit();
    try d.expectFrameContains("> -rw-r-----   1.2kB a.txt\n");
    try d.expectFrameContains("\n  -rwxr-xr-x      7B b\n");
    try d.expectFrameContains("      5B link → a.txt");
    // Each part in its own style, but the highlighted row all in `selected`.
    d.model().styles = .{};
    try d.press("down");
    try d.press("up");
    const bytes = d.frameBytes();
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1;38;5;212m-rw-r-----   1.2kB a.txt\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;5;244m-rwxr-xr-x\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;5;36mlink → a.txt\x1b[0m") != null);
}

test "choosing a directory, or only directories" {
    var f: Fixture = try .init();
    defer f.deinit();
    const options: FilePicker.Options = .{ .allow_files = false, .allow_directories = true };
    var d: tui.testing.Driver(FilePicker) = try .init(
        testing.allocator,
        try styledPickerWith(testing.io, f.root, options),
        .{},
    );
    defer d.deinit();
    // right opens a directory and does nothing to a file; enter on a file neither.
    try d.press("right");
    try testing.expect(std.mem.endsWith(u8, d.model().dir.items, "src"));
    try d.press("down");
    try d.press("l");
    try d.press("enter");
    try testing.expect(!d.done());
    try testing.expectEqualStrings("main.zig", d.model().currentEntry().?.name);
    // enter chooses the directory instead of opening it.
    try d.press("left");
    try d.press("enter");
    try testing.expect(d.done());
    const expected = try std.fs.path.join(testing.allocator, &.{ f.root, "src" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, d.model().chosen.?);
}

test windowsBits {
    try testing.expectEqual(0o666, windowsBits(false, false, "notes.txt"));
    try testing.expectEqual(0o555, windowsBits(true, false, "SETUP.EXE"));
    try testing.expectEqual(0o777, windowsBits(false, true, "src"));
}

test "no more entries than the terminal has rows for" {
    var f: Fixture = try .init();
    defer f.deinit();
    var picker = try styledPicker(testing.io, f.root);
    picker.header = "Pick";
    var d: tui.testing.Driver(FilePicker) = try .init(testing.allocator, picker, .{
        .program = .{ .size = .{ .width = 40, .height = 5 } },
    });
    defer d.deinit();
    // Five rows: the header, the directory, two entries, and one for a message.
    try testing.expectEqual(2, d.model().list.height);
    try d.expectFrameContains("\n> src/\n  README.md");
    try d.resize(.{ .width = 40, .height = 30 });
    try testing.expectEqual(10, d.model().list.height);
}

test "the directory on one row: ~ for home, cut from the left" {
    var f: Fixture = try .init();
    defer f.deinit();
    var picker = try styledPicker(testing.io, f.root);
    picker.home = std.fs.path.dirname(f.root).?;
    var d: tui.testing.Driver(FilePicker) = try .init(testing.allocator, picker, .{
        .program = .{ .size = .{ .width = 12, .height = 10 } },
    });
    defer d.deinit();
    const tail = try std.fmt.allocPrint(testing.allocator, "~/{s}\n", .{std.fs.path.basename(f.root)});
    defer testing.allocator.free(tail);
    // tmp dirs' names are longer than 12 columns, so the ~ goes with the cut.
    try d.expectFrameContains("…");
    try d.resize(.{ .width = 80, .height = 10 });
    try d.expectFrameContains(tail);
}

test formatSize {
    var buffer: [16]u8 = undefined;
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0B" },          .{ 6, "6B" },           .{ 999, "999B" },
        .{ 1000, "1.0kB" },    .{ 1234, "1.2kB" },     .{ 4096, "4.1kB" },
        .{ 15_000, "15kB" },   .{ 999_999, "1000kB" }, .{ 1_500_000, "1.5MB" },
        .{ 3 << 40, "3.3TB" },
    };
    for (cases) |case| try testing.expectEqualStrings(case[1], formatSize(&buffer, case[0]));
}
