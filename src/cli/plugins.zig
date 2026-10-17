//! External subcommands, as git has them: with `App.plugins = "app-"`, `app deploy ...`
//! runs the program `app-deploy` found on `PATH` when the tree has no `deploy`, with the
//! remaining arguments and the same standard streams and environment, and exits with its
//! status. Root help lists the plugins found under "Plugins", and completion offers them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const native_os = builtin.os.tag;
const path_separator = if (native_os == .windows) ';' else ':';

/// What a name may look like: a plugin name never holds a path separator or starts with
/// `-` or `.`, so `app ../x` or `app -x` cannot run something outside `PATH`.
fn isName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or name[0] == '.') return false;
    return std.mem.indexOfAny(u8, name, "/\\:\x00") == null;
}

/// The full path of the plugin `name`, or null when `PATH` has none.
pub fn find(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    prefix: []const u8,
    name: []const u8,
) (Allocator.Error || Io.Cancelable)!?[]const u8 {
    if (!isName(name)) return null;
    const path = environ.get("PATH") orelse return null;
    var dirs = std.mem.tokenizeScalar(u8, path, path_separator);
    while (dirs.next()) |dir| {
        for (extensions) |ext| {
            const candidate = try std.fmt.allocPrint(arena, "{s}{c}{s}{s}{s}", .{
                dir, std.fs.path.sep, prefix, name, ext,
            });
            if (try isProgram(io, candidate)) return candidate;
        }
    }
    return null;
}

/// The names of the plugins on `PATH`, sorted and without duplicates.
pub fn list(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    prefix: []const u8,
) (Allocator.Error || Io.Cancelable)![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const path = environ.get("PATH") orelse return names.items;
    var dirs = std.mem.tokenizeScalar(u8, path, path_separator);
    while (dirs.next()) |dir_path| {
        const cwd = Io.Dir.cwd();
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            const name = stripExtension(entry.name[prefix.len..]) orelse continue;
            if (!isName(name)) continue;
            const full = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{
                dir_path, std.fs.path.sep, entry.name,
            });
            if (!try isProgram(io, full)) continue;
            try names.append(arena, try arena.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var unique: usize = 0;
    for (names.items) |name| {
        if (unique > 0 and std.mem.eql(u8, names.items[unique - 1], name)) continue;
        names.items[unique] = name;
        unique += 1;
    }
    return names.items[0..unique];
}

/// Runs the plugin at `path` with `args` and the parent's standard streams, and returns the
/// status a shell would report: its exit code, or 128 + the signal that ended it.
pub fn run(
    io: Io,
    path: []const u8,
    args: []const []const u8,
    environ: *const std.process.Environ.Map,
    arena: Allocator,
) (std.process.SpawnError || std.process.Child.WaitError || Allocator.Error)!u8 {
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = path;
    @memcpy(argv[1..], args);
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = environ });
    errdefer child.kill(io);
    return switch (try child.wait(io)) {
        .exited => |code| code,
        .signal, .stopped => |sig| if (@TypeOf(sig) == void)
            1
        else
            128 +| (std.math.cast(u8, @backingInt(sig)) orelse 127),
        .unknown => 1,
    };
}

/// The endings tried after the name: none on POSIX, the usual program extensions on
/// Windows.
const extensions: []const []const u8 = if (native_os == .windows)
    &.{ ".exe", ".cmd", ".bat" }
else
    &.{""};

/// `name` without the program extension `extensions` allows, or null when it has none of
/// them on Windows.
fn stripExtension(name: []const u8) ?[]const u8 {
    if (native_os != .windows) return name;
    for (extensions) |ext| {
        if (name.len > ext.len and std.ascii.endsWithIgnoreCase(name, ext)) {
            return name[0 .. name.len - ext.len];
        }
    }
    return null;
}

fn isProgram(io: Io, candidate: []const u8) Io.Cancelable!bool {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, candidate, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    if (stat.kind != .file) return false;
    if (native_os == .windows) return true;
    cwd.access(io, candidate, .{ .execute = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return true;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const testing = std.testing;

test isName {
    try testing.expect(isName("deploy"));
    try testing.expect(isName("my-tool"));
    try testing.expect(!isName(""));
    try testing.expect(!isName("-x"));
    try testing.expect(!isName(".."));
    try testing.expect(!isName("a/b"));
    try testing.expect(!isName("a\\b"));
}
