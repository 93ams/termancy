//! A path-allowance policy for generated files: a list of root directories, and a check
//! that a path stays inside one of them.
//!
//! ```zig
//! const policy: sandbox.Policy = .{ .roots = &.{"src"} };
//! try policy.check(io, .cwd(), "src/commands/deploy.zig"); // ok
//! try policy.check(io, .cwd(), "src/../build.zig");        // error.Traversal
//! ```
//!
//! `check` works in two passes:
//!
//! 1. **Lexical** (`checkLexical`): `.` and `..` are resolved on the text, then the result
//!    must lie inside a root. Relative paths and relative roots are relative to the same
//!    directory; an absolute path is only allowed under an absolute root, and the reverse,
//!    so nothing depends on the current directory. A `..` that climbs above an absolute
//!    path's root is an error.
//! 2. **On disk**: the path and every root are canonicalized with `realpath` (as far as
//!    they exist; the missing rest is appended as written), so a symbolic link inside a
//!    root that points outside it is caught.
//!
//! Windows semantics (`Style.windows`): `/` and `\` both separate, comparison ignores ASCII
//! case, `C:\` and `\\server\share\` are absolute prefixes. Paths Windows would read
//! differently from how they are written are refused: drive-relative (`C:x`), rooted
//! without a drive (`\x`), device paths (`\\?\`, `\\.\`), alternate data streams (`a:b`),
//! reserved characters, and components ending in a dot or a space.
//!
//! The check and the write are separate system calls, so a link created between them is
//! not seen; this policy guards against mistakes and hostile input, not against a hostile
//! process racing the writer.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;

/// The longest path this module handles, in bytes. Longer paths are refused.
pub const max_path_bytes = 4096;

/// Which operating system's path rules apply.
pub const Style = enum {
    posix,
    windows,

    /// The rules of the target operating system.
    pub const native: Style = if (builtin.os.tag == .windows) .windows else .posix;
};

/// Why `checkLexical` refused a path.
pub const LexicalError = error{
    /// The path is empty.
    EmptyPath,
    /// The path is longer than `max_path_bytes`.
    NameTooLong,
    /// A NUL byte; on Windows also `<>:"|?*`, control characters, or a component ending
    /// in a dot or a space.
    InvalidCharacter,
    /// A Windows form whose meaning depends on process state or bypasses normalization:
    /// `C:x`, `\x`, `\\?\...`, `\\.\...`.
    UnsupportedPath,
    /// `..` leads outside every root (or above the root of an absolute path).
    Traversal,
    /// The path names no location inside a root.
    OutsideRoots,
};

/// Why `check` refused a path.
pub const Error = LexicalError || error{
    /// The text stays inside a root, but a symbolic link on the way leads outside.
    SymlinkEscape,
    /// The file system could not canonicalize the path or a root.
    Unresolvable,
};

/// Roots that generated files may be written under.
pub const Policy = struct {
    /// Directories, relative or absolute. Each covers itself and everything below it.
    roots: []const []const u8,
    /// The path rules for the lexical pass. The on-disk pass always uses `.native`.
    style: Style = .native,

    /// The lexical pass alone: no file system access.
    pub fn checkLexical(policy: Policy, path: []const u8) LexicalError!void {
        var path_buf: [max_path_bytes]u8 = undefined;
        const normal = try normalizeInto(policy.style, path, &path_buf);
        for (policy.roots) |root| {
            var root_buf: [max_path_bytes]u8 = undefined;
            const normal_root = try normalizeInto(policy.style, root, &root_buf);
            if (contains(policy.style, normal_root, normal)) return;
        }
        return if (hasDotDot(policy.style, path)) error.Traversal else error.OutsideRoots;
    }

    /// Both passes. Relative paths and roots are resolved against `dir`.
    pub fn check(policy: Policy, io: Io, dir: Io.Dir, path: []const u8) Error!void {
        try policy.checkLexical(path);
        var path_buf: [max_path_bytes]u8 = undefined;
        const real = try realish(io, dir, path, &path_buf);
        for (policy.roots) |root| {
            var root_buf: [max_path_bytes]u8 = undefined;
            const real_root = try realish(io, dir, root, &root_buf);
            if (contains(.native, real_root, real)) return;
        }
        return error.SymlinkEscape;
    }
};

/// Resolves `.` and `..` in `path` on the text and writes the result to `out` with `/`
/// separators: `a/./b/../c` → `a/c`, `C:\x\..\y` → `c:/y`. An empty relative result is
/// `.`. A leading `..` of a relative path is kept.
pub fn normalize(style: Style, path: []const u8, out: []u8) LexicalError![]u8 {
    const result = try normalizeInto(style, path, out);
    if (result.len > 0) return result;
    if (out.len == 0) return error.NameTooLong;
    out[0] = '.';
    return out[0..1];
}

/// `normalize`, except that an empty relative result stays empty.
fn normalizeInto(style: Style, path: []const u8, out: []u8) LexicalError![]u8 {
    if (path.len == 0) return error.EmptyPath;
    if (path.len > max_path_bytes) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidCharacter;
    var w: Builder = .{ .out = out, .prefix_len = 0 };
    const consumed = try writePrefix(style, path, &w);
    const absolute = w.len > 0;
    w.prefix_len = w.len;
    var it = std.mem.tokenizeAny(u8, path[consumed..], separators(style));
    while (it.next()) |component| try w.push(style, absolute, component);
    return out[0..w.len];
}

/// The component stack of `normalizeInto`, kept as text in `out`.
const Builder = struct {
    out: []u8,
    len: usize = 0,
    prefix_len: usize,

    fn append(w: *Builder, bytes: []const u8) LexicalError!void {
        if (w.len + bytes.len > w.out.len) return error.NameTooLong;
        @memcpy(w.out[w.len..][0..bytes.len], bytes);
        w.len += bytes.len;
    }

    fn push(w: *Builder, style: Style, absolute: bool, component: []const u8) LexicalError!void {
        assert(component.len > 0);
        if (std.mem.eql(u8, component, ".")) return;
        if (std.mem.eql(u8, component, "..")) {
            if (w.len > w.prefix_len and !std.mem.eql(u8, w.lastComponent(), "..")) {
                w.len = w.prefix_len + (std.mem.lastIndexOfScalar(u8, w.body(), '/') orelse 0);
                return;
            }
            if (absolute) return error.Traversal;
        } else if (style == .windows) {
            try checkWindowsComponent(component);
        }
        if (w.len > w.prefix_len) try w.append("/");
        try w.append(component);
    }

    fn body(w: *const Builder) []const u8 {
        return w.out[w.prefix_len..w.len];
    }

    fn lastComponent(w: *const Builder) []const u8 {
        const b = w.body();
        const start = if (std.mem.lastIndexOfScalar(u8, b, '/')) |i| i + 1 else 0;
        return b[start..];
    }
};

/// Writes the canonical prefix of `path` (nothing, `/`, `c:/`, or `//server/share/`) and
/// returns how many input bytes it spans.
fn writePrefix(style: Style, path: []const u8, w: *Builder) LexicalError!usize {
    assert(path.len > 0);
    if (style == .posix) {
        if (path[0] != '/') return 0;
        try w.append("/");
        return 1;
    }
    if (path.len >= 2 and isWindowsSeparator(path[0]) and isWindowsSeparator(path[1])) {
        return writeUnc(path, w);
    }
    if (isWindowsSeparator(path[0])) return error.UnsupportedPath;
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) {
        if (path.len == 2 or !isWindowsSeparator(path[2])) return error.UnsupportedPath;
        try w.append(&.{ std.ascii.toLower(path[0]), ':', '/' });
        return 3;
    }
    return 0;
}

/// `\\server\share`: the server and share are part of the prefix, compared ignoring case.
fn writeUnc(path: []const u8, w: *Builder) LexicalError!usize {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    const server = it.next() orelse return error.UnsupportedPath;
    const share = it.next() orelse return error.UnsupportedPath;
    if (std.mem.eql(u8, server, "?") or std.mem.eql(u8, server, ".")) {
        return error.UnsupportedPath;
    }
    try checkWindowsComponent(server);
    try checkWindowsComponent(share);
    for ([_][]const u8{ "//", server, "/", share, "/" }) |part| try w.append(part);
    return @intFromPtr(share.ptr) - @intFromPtr(path.ptr) + share.len;
}

fn checkWindowsComponent(component: []const u8) LexicalError!void {
    for (component) |c| {
        if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"|?*", c) != null) {
            return error.InvalidCharacter;
        }
    }
    const last = component[component.len - 1];
    if (last == '.' or last == ' ') return error.InvalidCharacter;
}

fn isWindowsSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn separators(style: Style) []const u8 {
    return if (style == .windows) "/\\" else "/";
}

fn hasDotDot(style: Style, path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, separators(style));
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

/// Whether normalized `path` is `root` or lies below it. Both must be relative, or both
/// absolute; on Windows the comparison ignores ASCII case.
fn contains(style: Style, root: []const u8, path: []const u8) bool {
    if (isAbsoluteNormal(root) != isAbsoluteNormal(path)) return false;
    if (root.len == 0) return !startsWithDotDot(path);
    if (path.len < root.len) return false;
    const head = path[0..root.len];
    const same = switch (style) {
        .posix => std.mem.eql(u8, head, root),
        .windows => std.ascii.eqlIgnoreCase(head, root),
    };
    if (!same) return false;
    return path.len == root.len or root[root.len - 1] == '/' or path[root.len] == '/';
}

fn isAbsoluteNormal(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 2 and path[1] == ':';
}

fn startsWithDotDot(path: []const u8) bool {
    return std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../");
}

/// The canonical absolute form of `path` relative to `dir`: `realpath` of the longest
/// prefix that exists, with the missing components appended, normalized with `.native`.
fn realish(io: Io, dir: Io.Dir, path: []const u8, out: *[max_path_bytes]u8) Error![]u8 {
    var existing = path;
    var missing_start = path.len;
    var real_buf: [max_path_bytes]u8 = undefined;
    const real_len = while (true) {
        const probe = if (existing.len == 0) "." else existing;
        if (dir.realPathFile(io, probe, &real_buf)) |n| break n else |err| switch (err) {
            error.FileNotFound => {
                if (existing.len == 0) return error.Unresolvable;
                const parent = std.fs.path.dirname(existing) orelse "";
                // A missing file system root has no parent to fall back on.
                if (parent.len == 0 and std.fs.path.isAbsolute(existing)) {
                    return error.Unresolvable;
                }
                missing_start = parent.len;
                existing = parent;
            },
            error.NameTooLong => return error.NameTooLong,
            else => return error.Unresolvable,
        }
    };
    const missing = path[missing_start..];
    // `..` after a component that does not exist would fail in the kernel anyway; refuse
    // it rather than guess what it would have meant.
    if (hasDotDot(.native, missing)) return error.Traversal;
    var joined_buf: [max_path_bytes]u8 = undefined;
    const real = real_buf[0..real_len];
    const joined = std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{ real, missing }) catch
        return error.NameTooLong;
    return normalizeInto(.native, joined, out);
}

// Tests ---------------------------------------------------------------------------------

fn expectNormal(style: Style, path: []const u8, expected: []const u8) !void {
    var buf: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try normalize(style, path, &buf));
}

test normalize {
    try expectNormal(.posix, "a/./b/../c", "a/c");
    try expectNormal(.posix, "a//b/", "a/b");
    try expectNormal(.posix, "./", ".");
    try expectNormal(.posix, "a/..", ".");
    try expectNormal(.posix, "../a/../../b", "../../b");
    try expectNormal(.posix, "/x/../y", "/y");
    try expectNormal(.posix, "a\\b", "a\\b");
    try expectNormal(.windows, "a\\b/c", "a/b/c");
    try expectNormal(.windows, "C:\\Proj\\..\\Src", "c:/Src");
    try expectNormal(.windows, "C:/", "c:/");
    try expectNormal(.windows, "\\\\Server\\Share\\a\\..\\b", "//Server/Share/b");
}

test "normalize refuses what it cannot read safely" {
    var buf: [max_path_bytes]u8 = undefined;
    const e = std.testing.expectError;
    try e(error.EmptyPath, normalize(.posix, "", &buf));
    try e(error.InvalidCharacter, normalize(.posix, "a\x00b", &buf));
    try e(error.Traversal, normalize(.posix, "/..", &buf));
    try e(error.Traversal, normalize(.windows, "C:\\..\\x", &buf));
    try e(error.UnsupportedPath, normalize(.windows, "C:x", &buf));
    try e(error.UnsupportedPath, normalize(.windows, "\\x", &buf));
    try e(error.UnsupportedPath, normalize(.windows, "\\\\?\\C:\\x", &buf));
    try e(error.UnsupportedPath, normalize(.windows, "\\\\.\\pipe\\x", &buf));
    try e(error.InvalidCharacter, normalize(.windows, "file.txt:stream", &buf));
    try e(error.InvalidCharacter, normalize(.windows, "dir./x", &buf));
    try e(error.InvalidCharacter, normalize(.windows, "dir /x", &buf));
    try e(error.InvalidCharacter, normalize(.windows, "a?b", &buf));
    var small: [2]u8 = undefined;
    try e(error.NameTooLong, normalize(.posix, "abc", &small));
}

test "checkLexical on POSIX" {
    const policy: Policy = .{ .roots = &.{ "src", "/srv/app/" }, .style = .posix };
    try policy.checkLexical("src/a.zig");
    try policy.checkLexical("./src/x/../b.zig");
    try policy.checkLexical("src");
    try policy.checkLexical("/srv/app/x");
    try policy.checkLexical("/srv/app");
    const e = std.testing.expectError;
    try e(error.Traversal, policy.checkLexical("src/../build.zig"));
    try e(error.Traversal, policy.checkLexical("../src/a.zig"));
    try e(error.Traversal, policy.checkLexical("/srv/app/../other"));
    try e(error.OutsideRoots, policy.checkLexical("srcx/a.zig"));
    try e(error.OutsideRoots, policy.checkLexical("/srv/application"));
    try e(error.OutsideRoots, policy.checkLexical("/etc/passwd"));
    try e(error.OutsideRoots, policy.checkLexical("/src/a.zig"));
    try e(error.OutsideRoots, policy.checkLexical("src\\..\\..\\x"));
}

test "checkLexical with the current directory as the root" {
    const policy: Policy = .{ .roots = &.{"."}, .style = .posix };
    try policy.checkLexical("a/b");
    try policy.checkLexical("a/../b");
    try std.testing.expectError(error.Traversal, policy.checkLexical("a/../../b"));
    try std.testing.expectError(error.OutsideRoots, policy.checkLexical("/tmp/x"));
}

test "checkLexical on Windows" {
    const policy: Policy = .{ .roots = &.{ "src", "C:\\Proj" }, .style = .windows };
    try policy.checkLexical("src\\a.zig");
    try policy.checkLexical("SRC/sub\\a.zig");
    try policy.checkLexical("c:/proj/x");
    try policy.checkLexical("C:\\PROJ\\x\\..\\y");
    const e = std.testing.expectError;
    try e(error.Traversal, policy.checkLexical("src\\..\\..\\x"));
    try e(error.Traversal, policy.checkLexical("src/..\\build.zig"));
    try e(error.Traversal, policy.checkLexical("C:\\Proj\\..\\Windows"));
    try e(error.OutsideRoots, policy.checkLexical("D:\\Proj\\x"));
    try e(error.OutsideRoots, policy.checkLexical("C:\\Project\\x"));
    try e(error.OutsideRoots, policy.checkLexical("\\\\host\\share\\src\\x"));
    try e(error.UnsupportedPath, policy.checkLexical("C:src\\x"));
    try e(error.InvalidCharacter, policy.checkLexical("src\\a.zig:hidden"));
}

test "check follows symbolic links" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/sub");
    try tmp.dir.createDirPath(io, "outside");
    var abs_buf: [max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPathFile(io, "outside", &abs_buf);
    tmp.dir.symLink(io, abs_buf[0..abs_len], "root/escape", .{ .is_directory = true }) catch |err|
        switch (err) {
            // Windows makes links only with a privilege or in Developer Mode.
            error.AccessDenied, error.PermissionDenied => if (builtin.os.tag == .windows)
                return error.SkipZigTest
            else
                return err,
            else => return err,
        };
    try tmp.dir.symLink(io, "sub", "root/inner", .{ .is_directory = true });

    const policy: Policy = .{ .roots = &.{ "root", "not-yet" } };
    try policy.check(io, tmp.dir, "root/sub/new.zig");
    try policy.check(io, tmp.dir, "root/new/deeper/file.zig");
    try policy.check(io, tmp.dir, "root/inner/new.zig");
    try policy.check(io, tmp.dir, "not-yet/a/b.zig");
    const e = std.testing.expectError;
    try e(error.SymlinkEscape, policy.check(io, tmp.dir, "root/escape/new.zig"));
    try e(error.SymlinkEscape, policy.check(io, tmp.dir, "root/escape"));
    try e(error.Traversal, policy.check(io, tmp.dir, "root/../outside/x"));
    try e(error.OutsideRoots, policy.check(io, tmp.dir, "outside/x"));

    // An absolute root admits the same files, written either way.
    var root_buf: [max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, "root", &root_buf);
    const abs_policy: Policy = .{ .roots = &.{root_buf[0..root_len]} };
    var file_buf: [max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}/sub/x.zig", .{root_buf[0..root_len]});
    try abs_policy.check(io, tmp.dir, file);
    const escape = try std.fmt.bufPrint(&file_buf, "{s}/escape/x", .{root_buf[0..root_len]});
    try e(error.SymlinkEscape, abs_policy.check(io, tmp.dir, escape));
}
