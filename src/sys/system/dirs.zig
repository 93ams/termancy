//! Where an application keeps its files: configuration, cache, data, state, and runtime
//! directories for an app name, following each operating system's convention.
//!
//! - Linux and the BSDs, after the XDG Base Directory specification: `$XDG_CONFIG_HOME`
//!   (`~/.config`), `$XDG_CACHE_HOME` (`~/.cache`), `$XDG_DATA_HOME` (`~/.local/share`),
//!   `$XDG_STATE_HOME` (`~/.local/state`), `$XDG_RUNTIME_DIR` (no default).
//! - macOS: `~/Library/Application Support` for config and data (state in a `state`
//!   subdirectory), `~/Library/Caches` for cache, `$TMPDIR` when absolute (else `/tmp`) for
//!   runtime.
//! - Windows: `%APPDATA%` for config; `%LOCALAPPDATA%` for cache, data, and state, each in
//!   its own subdirectory; `%TEMP%` (then `%TMP%`) for runtime.
//!
//! The app name is appended to the base directory (`~/.config/<app>`); on macOS and Windows,
//! where one base directory serves several kinds, a subdirectory keeps them apart
//! (`%LOCALAPPDATA%\<app>\cache`).
//!
//! Two directories are not per application, so they take no app name: `binDir`, where a
//! user's own executables go (`$XDG_BIN_HOME`, else `~/.local/bin` on XDG systems and
//! macOS; `%LOCALAPPDATA%\Programs` on Windows), and `tempDir`, for short-lived files.
//!
//! On macOS an explicitly set, absolute `XDG_*_HOME` variable wins over the Apple location,
//! which is what command-line users who set those variables expect. On every OS, XDG
//! variables holding relative paths are ignored, as the XDG specification requires.
//!
//! Windows fallbacks, when a variable is unset: `%APPDATA%` -> `%USERPROFILE%\AppData\Roaming`,
//! `%LOCALAPPDATA%` -> `%USERPROFILE%\AppData\Local`, `%TEMP%` -> `%TMP%` ->
//! `%LOCALAPPDATA%\Temp`, and `%PROGRAMDATA%` -> `C:\ProgramData`. A Windows home directory
//! comes only from `%USERPROFILE%`.
//!
//! Every function is pure: it reads only the environment map and the OS tag it is given,
//! and never touches the file system, so every OS is tested on any host. Pass `native` for
//! the running system. Nothing is created; call `std.Io.Dir.createDirPath` on the result.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// The operating system whose conventions to follow.
pub const Os = std.Target.Os.Tag;

/// The running operating system.
pub const native: Os = builtin.os.tag;

/// A kind of per-application directory.
pub const Kind = enum {
    /// User-edited settings.
    config,
    /// Regenerable files; may be deleted at any time.
    cache,
    /// Files the application creates and keeps: databases, downloads.
    data,
    /// Files worth keeping across restarts but not worth backing up: history, logs.
    state,
    /// Sockets, PID files, and other files that live only as long as the session.
    runtime,
};

/// Why a directory could not be determined.
pub const Error = error{
    /// No home directory: `HOME` (or `USERPROFILE` on Windows) is unset or relative.
    HomeNotFound,
    /// `XDG_RUNTIME_DIR` is unset; the XDG specification defines no default.
    RuntimeDirNotSet,
} || Allocator.Error;

/// The directory of `kind` for `app`, such as `/home/ann/.config/termancy`. Caller owns it.
pub fn path(
    gpa: Allocator,
    environ: *const Environ.Map,
    os: Os,
    kind: Kind,
    app: []const u8,
) Error![]u8 {
    assert(isAppName(app));
    const parts = try locate(environ, os, kind);
    return joinParts(gpa, os, &.{ parts.base, parts.middle, app, parts.suffix });
}

/// `path` for the running operating system.
pub fn nativePath(
    gpa: Allocator,
    environ: *const Environ.Map,
    kind: Kind,
    app: []const u8,
) Error![]u8 {
    return path(gpa, environ, native, kind, app);
}

/// The directory for the user's own executables, shared by every application (so no app
/// name is appended): `$XDG_BIN_HOME` when set and absolute, else `~/.local/bin`, on XDG
/// systems and macOS; `%LOCALAPPDATA%\Programs` on Windows (falling back to
/// `%USERPROFILE%\AppData\Local\Programs`). It is not necessarily on `PATH`. Caller
/// owns it.
pub fn binDir(gpa: Allocator, environ: *const Environ.Map, os: Os) Error![]u8 {
    if (family(os) == .windows) {
        const local = try localAppData(environ);
        return joinParts(gpa, os, &.{ local.base, local.middle, "Programs" });
    }
    if (nonEmpty(environ.get("XDG_BIN_HOME"))) |dir| {
        if (isAbsolute(os, dir)) return joinParts(gpa, os, &.{dir});
    }
    return joinParts(gpa, os, &.{ try homeDir(environ, os), ".local/bin" });
}

/// A directory for short-lived files, without the app name: `$XDG_RUNTIME_DIR` (private to
/// the user) when set and absolute, else `$TMPDIR`, else `/tmp`; on Windows `%TEMP%`, then
/// `%TMP%`, then `%LOCALAPPDATA%\Temp`. Caller owns it.
pub fn tempDir(gpa: Allocator, environ: *const Environ.Map, os: Os) Error![]u8 {
    if (family(os) == .windows) {
        const parts = try windows(environ, .runtime);
        return joinParts(gpa, os, &.{ parts.base, parts.middle });
    }
    if (xdgVar(environ, os, .runtime)) |dir| return joinParts(gpa, os, &.{dir});
    if (nonEmpty(environ.get("TMPDIR"))) |dir| {
        if (isAbsolute(os, dir)) return joinParts(gpa, os, &.{dir});
    }
    return gpa.dupe(u8, "/tmp");
}

/// The ordered directories a configuration loader should search for `app`, most specific
/// first: the user's configuration directory, then the system-wide ones (each entry of
/// `$XDG_CONFIG_DIRS`, default `/etc/xdg`; `/Library/Application Support` on macOS;
/// `%PROGRAMDATA%` on Windows). Free with `SearchPath.deinit`.
pub fn configSearchPath(
    gpa: Allocator,
    environ: *const Environ.Map,
    os: Os,
    app: []const u8,
) Error!SearchPath {
    assert(isAppName(app));
    var list: std.ArrayList([]u8) = .empty;
    errdefer list.deinit(gpa);
    errdefer freeAll(gpa, list.items);

    try appendOwned(gpa, &list, try path(gpa, environ, os, .config, app));
    switch (family(os)) {
        .xdg => {
            const dirs = nonEmpty(environ.get("XDG_CONFIG_DIRS")) orelse "/etc/xdg";
            var it = std.mem.tokenizeScalar(u8, dirs, ':');
            while (it.next()) |dir| {
                if (!isAbsolute(os, dir)) continue;
                try appendOwned(gpa, &list, try joinParts(gpa, os, &.{ dir, app }));
            }
        },
        .macos => {
            const system = "/Library/Application Support";
            try appendOwned(gpa, &list, try joinParts(gpa, os, &.{ system, app }));
        },
        .windows => {
            const program_data = windowsVar(environ, "PROGRAMDATA") orelse "C:\\ProgramData";
            try appendOwned(gpa, &list, try joinParts(gpa, os, &.{ program_data, app }));
        },
    }
    return .{ .dirs = try list.toOwnedSlice(gpa) };
}

/// An ordered list of directories, owned by the caller.
pub const SearchPath = struct {
    /// Most specific first.
    dirs: []const []u8,

    /// Frees every directory and the list.
    pub fn deinit(sp: SearchPath, gpa: Allocator) void {
        freeAll(gpa, sp.dirs);
        gpa.free(sp.dirs);
    }
};

/// Joins path components with the separator of `os`, skipping empty components. A joint
/// that already has a separator keeps it (so `/` survives under Windows rules); duplicate
/// separators at a joint and trailing separators are removed. Caller owns the result.
pub fn join(gpa: Allocator, os: Os, parts: []const []const u8) Allocator.Error![]u8 {
    return joinParts(gpa, os, parts);
}

/// The path separator of `os`.
pub fn separator(os: Os) u8 {
    return if (os == .windows) '\\' else '/';
}

/// Whether Windows reads the path component `name` as something other than the file it
/// names: a device (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`, ignoring case,
/// also with an extension, as `nul.txt`), or a name ending in a dot or a space, which
/// Windows drops. Callers handle `.` and `..` themselves.
pub fn isWindowsReserved(name: []const u8) bool {
    if (name.len == 0) return false;
    const last = name[name.len - 1];
    if (last == '.' or last == ' ') return true;
    const stem_end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const stem = std.mem.trimEnd(u8, name[0..stem_end], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    if (stem.len != 4 or stem[3] < '1' or stem[3] > '9') return false;
    return std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT");
}

/// Whether `p` is absolute under the rules of `os`: a leading `/` on POSIX; a drive
/// (`C:\`) or UNC prefix (`\\server`) on Windows.
pub fn isAbsolute(os: Os, p: []const u8) bool {
    if (os != .windows) return p.len > 0 and p[0] == '/';
    if (p.len >= 2 and isSep(os, p[0]) and isSep(os, p[1])) return true;
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and isSep(os, p[2]);
}

const Family = enum { xdg, macos, windows };

fn family(os: Os) Family {
    if (os == .windows) return .windows;
    if (os.isDarwin()) return .macos;
    return .xdg;
}

/// A directory as up to three components around the app name: `base/middle/app/suffix`.
const Parts = struct {
    base: []const u8,
    middle: []const u8 = "",
    suffix: []const u8 = "",
};

fn locate(environ: *const Environ.Map, os: Os, kind: Kind) error{
    HomeNotFound,
    RuntimeDirNotSet,
}!Parts {
    return switch (family(os)) {
        .xdg => xdg(environ, os, kind),
        .macos => macos(environ, os, kind),
        .windows => windows(environ, kind),
    };
}

fn xdg(environ: *const Environ.Map, os: Os, kind: Kind) error{
    HomeNotFound,
    RuntimeDirNotSet,
}!Parts {
    if (xdgVar(environ, os, kind)) |dir| return .{ .base = dir };
    if (kind == .runtime) return error.RuntimeDirNotSet;
    const home = try homeDir(environ, os);
    return .{
        .base = home,
        .middle = switch (kind) {
            .config => ".config",
            .cache => ".cache",
            .data => ".local/share",
            .state => ".local/state",
            .runtime => unreachable, // Returned above.
        },
    };
}

fn macos(environ: *const Environ.Map, os: Os, kind: Kind) error{HomeNotFound}!Parts {
    if (xdgVar(environ, os, kind)) |dir| return .{ .base = dir };
    if (kind == .runtime) {
        const tmp = nonEmpty(environ.get("TMPDIR")) orelse "/tmp";
        return .{ .base = if (isAbsolute(os, tmp)) tmp else "/tmp" };
    }
    const home = try homeDir(environ, os);
    return switch (kind) {
        .config, .data => .{ .base = home, .middle = "Library/Application Support" },
        .cache => .{ .base = home, .middle = "Library/Caches" },
        .state => .{
            .base = home,
            .middle = "Library/Application Support",
            .suffix = "state",
        },
        .runtime => unreachable, // Returned above.
    };
}

fn windows(environ: *const Environ.Map, kind: Kind) error{HomeNotFound}!Parts {
    switch (kind) {
        .config => {
            if (windowsVar(environ, "APPDATA")) |dir| return .{ .base = dir };
            return .{ .base = try homeDir(environ, .windows), .middle = "AppData\\Roaming" };
        },
        .runtime => {
            if (windowsVar(environ, "TEMP")) |dir| return .{ .base = dir };
            if (windowsVar(environ, "TMP")) |dir| return .{ .base = dir };
            const local = try localAppData(environ);
            const middle = if (local.middle.len == 0) "Temp" else "AppData\\Local\\Temp";
            return .{ .base = local.base, .middle = middle };
        },
        .cache, .data, .state => {
            var local = try localAppData(environ);
            local.suffix = @tagName(kind);
            return local;
        },
    }
}

fn localAppData(environ: *const Environ.Map) error{HomeNotFound}!Parts {
    if (windowsVar(environ, "LOCALAPPDATA")) |dir| return .{ .base = dir };
    return .{ .base = try homeDir(environ, .windows), .middle = "AppData\\Local" };
}

fn xdgVar(environ: *const Environ.Map, os: Os, kind: Kind) ?[]const u8 {
    const name = switch (kind) {
        .config => "XDG_CONFIG_HOME",
        .cache => "XDG_CACHE_HOME",
        .data => "XDG_DATA_HOME",
        .state => "XDG_STATE_HOME",
        .runtime => "XDG_RUNTIME_DIR",
    };
    const value = nonEmpty(environ.get(name)) orelse return null;
    return if (isAbsolute(os, value)) value else null;
}

fn windowsVar(environ: *const Environ.Map, name: []const u8) ?[]const u8 {
    const value = nonEmpty(environ.get(name)) orelse return null;
    return if (isAbsolute(.windows, value)) value else null;
}

/// The home directory of `os`: `HOME` on POSIX, `USERPROFILE` on Windows. Either must be
/// absolute.
fn homeDir(environ: *const Environ.Map, os: Os) error{HomeNotFound}![]const u8 {
    if (os != .windows) {
        const home = nonEmpty(environ.get("HOME")) orelse return error.HomeNotFound;
        return if (isAbsolute(os, home)) home else error.HomeNotFound;
    }
    return windowsVar(environ, "USERPROFILE") orelse error.HomeNotFound;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn isSep(os: Os, c: u8) bool {
    return c == '/' or (os == .windows and c == '\\');
}

fn isAppName(app: []const u8) bool {
    if (app.len == 0) return false;
    for (app) |c| if (c == '/' or c == '\\' or c == 0) return false;
    return true;
}

fn joinParts(gpa: Allocator, os: Os, parts: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts) |part| {
        if (part.len == 0) continue;
        var rest = part;
        if (out.items.len > 0) {
            if (isSep(os, out.items[out.items.len - 1])) {
                while (rest.len > 0 and isSep(os, rest[0])) rest = rest[1..];
            } else if (!isSep(os, rest[0])) {
                try out.append(gpa, separator(os));
            }
        }
        try out.appendSlice(gpa, rest);
    }
    while (out.items.len > 1 and isSep(os, out.items[out.items.len - 1])) {
        if (out.items.len == 3 and out.items[1] == ':') break; // `C:\`
        out.items.len -= 1;
    }
    return out.toOwnedSlice(gpa);
}

fn appendOwned(gpa: Allocator, list: *std.ArrayList([]u8), item: []u8) Allocator.Error!void {
    errdefer gpa.free(item);
    try list.append(gpa, item);
}

fn freeAll(gpa: Allocator, items: []const []u8) void {
    for (items) |item| gpa.free(item);
}

const testing = std.testing;

fn testEnviron(pairs: []const [2][]const u8) !Environ.Map {
    var map: Environ.Map = .init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

fn expectPath(
    expected: []const u8,
    environ: *const Environ.Map,
    os: Os,
    kind: Kind,
) !void {
    const actual = try path(testing.allocator, environ, os, kind, "termancy");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "xdg defaults under HOME" {
    var env = try testEnviron(&.{.{ "HOME", "/home/ann" }});
    defer env.deinit();
    try expectPath("/home/ann/.config/termancy", &env, .linux, .config);
    try expectPath("/home/ann/.cache/termancy", &env, .linux, .cache);
    try expectPath("/home/ann/.local/share/termancy", &env, .freebsd, .data);
    try expectPath("/home/ann/.local/state/termancy", &env, .linux, .state);
    try testing.expectError(
        error.RuntimeDirNotSet,
        path(testing.allocator, &env, .linux, .runtime, "termancy"),
    );
}

test "xdg variables win; relative ones are ignored" {
    var env = try testEnviron(&.{
        .{ "HOME", "/home/ann/" },
        .{ "XDG_CONFIG_HOME", "/cfg/" },
        .{ "XDG_CACHE_HOME", "relative/cache" },
        .{ "XDG_DATA_HOME", "" },
        .{ "XDG_STATE_HOME", "/st" },
        .{ "XDG_RUNTIME_DIR", "/run/user/1000" },
    });
    defer env.deinit();
    try expectPath("/cfg/termancy", &env, .linux, .config);
    try expectPath("/home/ann/.cache/termancy", &env, .linux, .cache);
    try expectPath("/home/ann/.local/share/termancy", &env, .linux, .data);
    try expectPath("/st/termancy", &env, .linux, .state);
    try expectPath("/run/user/1000/termancy", &env, .linux, .runtime);
}

test "missing or relative HOME is an error" {
    var empty = try testEnviron(&.{});
    defer empty.deinit();
    const gpa = testing.allocator;
    try testing.expectError(error.HomeNotFound, path(gpa, &empty, .linux, .config, "a"));
    try testing.expectError(error.HomeNotFound, path(gpa, &empty, .macos, .cache, "a"));
    try testing.expectError(error.HomeNotFound, path(gpa, &empty, .windows, .data, "a"));
    var relative = try testEnviron(&.{.{ "HOME", "home" }});
    defer relative.deinit();
    try testing.expectError(
        error.HomeNotFound,
        path(testing.allocator, &relative, .linux, .config, "a"),
    );
}

test "macos uses Library, TMPDIR, and honors explicit XDG" {
    var env = try testEnviron(&.{ .{ "HOME", "/Users/ann" }, .{ "TMPDIR", "/var/folders/x/T/" } });
    defer env.deinit();
    try expectPath("/Users/ann/Library/Application Support/termancy", &env, .macos, .config);
    try expectPath("/Users/ann/Library/Application Support/termancy", &env, .macos, .data);
    try expectPath("/Users/ann/Library/Caches/termancy", &env, .macos, .cache);
    try expectPath("/Users/ann/Library/Application Support/termancy/state", &env, .macos, .state);
    try expectPath("/var/folders/x/T/termancy", &env, .macos, .runtime);

    var xdg_env = try testEnviron(&.{ .{ "HOME", "/Users/ann" }, .{ "XDG_CONFIG_HOME", "/x" } });
    defer xdg_env.deinit();
    try expectPath("/x/termancy", &xdg_env, .macos, .config);
    try expectPath("/tmp/termancy", &xdg_env, .macos, .runtime);

    // A relative TMPDIR would name a directory under whatever the working directory is.
    var relative_env = try testEnviron(&.{ .{ "HOME", "/Users/ann" }, .{ "TMPDIR", "tmp" } });
    defer relative_env.deinit();
    try expectPath("/tmp/termancy", &relative_env, .macos, .runtime);
}

test "windows known folders" {
    var env = try testEnviron(&.{
        .{ "APPDATA", "C:\\Users\\ann\\AppData\\Roaming" },
        .{ "LOCALAPPDATA", "C:\\Users\\ann\\AppData\\Local\\" },
        .{ "TEMP", "C:\\Temp" },
    });
    defer env.deinit();
    try expectPath("C:\\Users\\ann\\AppData\\Roaming\\termancy", &env, .windows, .config);
    try expectPath("C:\\Users\\ann\\AppData\\Local\\termancy\\data", &env, .windows, .data);
    try expectPath("C:\\Users\\ann\\AppData\\Local\\termancy\\cache", &env, .windows, .cache);
    try expectPath("C:\\Users\\ann\\AppData\\Local\\termancy\\state", &env, .windows, .state);
    try expectPath("C:\\Temp\\termancy", &env, .windows, .runtime);
}

test "windows fallbacks from USERPROFILE" {
    var env = try testEnviron(&.{.{ "USERPROFILE", "C:\\Users\\ann" }});
    defer env.deinit();
    try expectPath("C:\\Users\\ann\\AppData\\Roaming\\termancy", &env, .windows, .config);
    try expectPath("C:\\Users\\ann\\AppData\\Local\\termancy\\cache", &env, .windows, .cache);
    try expectPath("C:\\Users\\ann\\AppData\\Local\\Temp\\termancy", &env, .windows, .runtime);

    var tmp = try testEnviron(&.{ .{ "TMP", "D:\\t" }, .{ "LOCALAPPDATA", "relative" } });
    defer tmp.deinit();
    try expectPath("D:\\t\\termancy", &tmp, .windows, .runtime);
    const result = path(testing.allocator, &tmp, .windows, .data, "a");
    try testing.expectError(error.HomeNotFound, result);
}

test "config search path, most specific first" {
    var env = try testEnviron(&.{
        .{ "HOME", "/home/ann" },
        .{ "XDG_CONFIG_DIRS", "/etc/xdg-a::relative:/opt/xdg/" },
    });
    defer env.deinit();
    const sp = try configSearchPath(testing.allocator, &env, .linux, "termancy");
    defer sp.deinit(testing.allocator);
    try testing.expectEqual(3, sp.dirs.len);
    try testing.expectEqualStrings("/home/ann/.config/termancy", sp.dirs[0]);
    try testing.expectEqualStrings("/etc/xdg-a/termancy", sp.dirs[1]);
    try testing.expectEqualStrings("/opt/xdg/termancy", sp.dirs[2]);
}

test "config search path defaults per OS" {
    var env = try testEnviron(&.{
        .{ "HOME", "/home/ann" },
        .{ "USERPROFILE", "C:\\Users\\ann" },
    });
    defer env.deinit();
    const expected = [_]struct { os: Os, last: []const u8 }{
        .{ .os = .linux, .last = "/etc/xdg/termancy" },
        .{ .os = .macos, .last = "/Library/Application Support/termancy" },
        .{ .os = .windows, .last = "C:\\ProgramData\\termancy" },
    };
    for (expected) |case| {
        const sp = try configSearchPath(testing.allocator, &env, case.os, "termancy");
        defer sp.deinit(testing.allocator);
        try testing.expectEqual(2, sp.dirs.len);
        try testing.expectEqualStrings(case.last, sp.dirs[1]);
    }
}

test "config search path does not leak on failure" {
    var env = try testEnviron(&.{.{ "HOME", "/home/ann" }});
    defer env.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, e: *const Environ.Map) !void {
            const sp = try configSearchPath(gpa, e, .linux, "termancy");
            sp.deinit(gpa);
        }
    }.run, .{&env});
}

test "bin directory: XDG_BIN_HOME, ~/.local/bin, LOCALAPPDATA\\Programs" {
    const gpa = testing.allocator;
    var env = try testEnviron(&.{
        .{ "HOME", "/home/ann" },
        .{ "XDG_BIN_HOME", "relative/bin" },
        .{ "LOCALAPPDATA", "C:\\Users\\ann\\AppData\\Local" },
    });
    defer env.deinit();
    const cases = [_]struct { Os, []const u8 }{
        .{ .linux, "/home/ann/.local/bin" },
        .{ .macos, "/home/ann/.local/bin" },
        .{ .windows, "C:\\Users\\ann\\AppData\\Local\\Programs" },
    };
    for (cases) |case| {
        const dir = try binDir(gpa, &env, case[0]);
        defer gpa.free(dir);
        try testing.expectEqualStrings(case[1], dir);
    }
    try env.put("XDG_BIN_HOME", "/opt/bin/");
    const xdg_dir = try binDir(gpa, &env, .linux);
    defer gpa.free(xdg_dir);
    try testing.expectEqualStrings("/opt/bin", xdg_dir);

    var profile = try testEnviron(&.{.{ "USERPROFILE", "C:\\Users\\bo" }});
    defer profile.deinit();
    const fallback = try binDir(gpa, &profile, .windows);
    defer gpa.free(fallback);
    try testing.expectEqualStrings("C:\\Users\\bo\\AppData\\Local\\Programs", fallback);
    try testing.expectError(error.HomeNotFound, binDir(gpa, &profile, .linux));
}

test "temp directory per OS" {
    const gpa = testing.allocator;
    var env = try testEnviron(&.{ .{ "TMPDIR", "/var/tmp/" }, .{ "TEMP", "C:\\Temp" } });
    defer env.deinit();
    const cases = [_]struct { Os, []const u8 }{
        .{ .linux, "/var/tmp" },
        .{ .macos, "/var/tmp" },
        .{ .windows, "C:\\Temp" },
    };
    for (cases) |case| {
        const dir = try tempDir(gpa, &env, case[0]);
        defer gpa.free(dir);
        try testing.expectEqualStrings(case[1], dir);
    }
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    const runtime = try tempDir(gpa, &env, .linux);
    defer gpa.free(runtime);
    try testing.expectEqualStrings("/run/user/1000", runtime);
    var empty = try testEnviron(&.{});
    defer empty.deinit();
    const fallback = try tempDir(gpa, &empty, .freebsd);
    defer gpa.free(fallback);
    try testing.expectEqualStrings("/tmp", fallback);
}

test isWindowsReserved {
    for ([_][]const u8{ "CON", "nul", "Aux.txt", "com1", "LPT9.log", "nul .txt", "a.", "a " }) |name| {
        try std.testing.expect(isWindowsReserved(name));
    }
    for ([_][]const u8{ "console", "nullable.txt", "com0", "COM10", "lpt", "a.b", "session.json", "" }) |name| {
        try std.testing.expect(!isWindowsReserved(name));
    }
}

test "join and isAbsolute" {
    const joined = try join(testing.allocator, .windows, &.{ "C:\\a\\", "\\b", "", "c/" });
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("C:\\a\\b\\c", joined);
    const root = try join(testing.allocator, .linux, &.{ "/", "etc" });
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/etc", root);
    try testing.expect(isAbsolute(.windows, "\\\\server\\share"));
    try testing.expect(isAbsolute(.windows, "c:/x"));
    try testing.expect(!isAbsolute(.windows, "/x"));
    try testing.expect(!isAbsolute(.linux, "C:\\x"));
    try testing.expectEqual('/', separator(.macos));
}
