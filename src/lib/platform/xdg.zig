//! OS-agnostic resolution of the standard application directories.
//!
//! Every path a CLI writes has a conventional home, and the convention is not the
//! same on two platforms: `~/.config/<app>` on Linux, `%APPDATA%\<app>` on
//! Windows. On top of that the XDG Base Directory Specification lets the user
//! relocate any of them, and when they have, their choice wins over the default.
//!
//! ## Why the OS is a parameter rather than `builtin.os.tag`
//!
//! A function that reads `builtin.os.tag` cannot be tested for the platform it is
//! not running on, which is how "resolves `~/.config` on Linux" becomes a claim
//! nobody has ever executed. Taking `os_tag` explicitly - and joining with that
//! platform's separator rather than the host's - makes both branches testable from
//! either host, and makes the returned string depend only on the arguments.
//!
//! ## What is deliberately not here
//!
//! No caching and no global state: the caller owns the allocator and gets back an
//! owned slice. `[measured]` this tree previously had one hard-coded standard
//! directory, in `version.zig`, which wrote to `/tmp` on every platform including
//! the ones where that path does not exist.

const std = @import("std");
const assert = std.debug.assert;

/// The directory categories this module resolves.
///
/// `config`, `data`, `cache`, `state` and `runtime` are the XDG categories.
/// `bin` is here because installing an executable into a per-user directory is the
/// step immediately after resolving a per-user directory, and having the caller
/// re-derive it is how the two drift.
pub const Kind = enum { config, data, cache, state, runtime, bin };

pub const Error = error{
    /// The environment named neither the platform variable nor a home directory.
    /// Reported rather than substituted: guessing a home directory writes files
    /// somewhere the user did not ask for.
    HomeUnset,
    OutOfMemory,
};

/// Resolves `kind` for `os_tag`, using `env_map` for the overrides.
///
/// The returned slice is owned by the caller.
pub fn dir(
    allocator: std.mem.Allocator,
    kind: Kind,
    env_map: *const std.process.Environ.Map,
    os_tag: std.Target.Os.Tag,
) Error![]u8 {
    assert(@intFromEnum(kind) <= @intFromEnum(Kind.bin));
    if (os_tag == .windows) return windowsDir(allocator, kind, env_map);
    return posixDir(allocator, kind, env_map);
}

/// `dir`, with the application's own name appended as the last component.
///
/// This is the form a program actually wants: `configDir("myapp")` rather than
/// `dir(.config)` and a join the caller has to get right.
pub fn appDir(
    allocator: std.mem.Allocator,
    kind: Kind,
    app_name: []const u8,
    env_map: *const std.process.Environ.Map,
    os_tag: std.Target.Os.Tag,
) Error![]u8 {
    assert(app_name.len > 0);
    assert(std.mem.indexOfAny(u8, app_name, "/\\") == null);

    const base = try dir(allocator, kind, env_map, os_tag);
    defer allocator.free(base);
    return join(allocator, os_tag, &.{ base, app_name });
}

/// The XDG branch. Each category has a variable that wins and a path relative to
/// `HOME` that is used when the variable is unset or empty.
fn posixDir(
    allocator: std.mem.Allocator,
    kind: Kind,
    env_map: *const std.process.Environ.Map,
) Error![]u8 {
    return switch (kind) {
        .config => xdgOrHome(allocator, env_map, "XDG_CONFIG_HOME", ".config"),
        .data => xdgOrHome(allocator, env_map, "XDG_DATA_HOME", ".local/share"),
        .cache => xdgOrHome(allocator, env_map, "XDG_CACHE_HOME", ".cache"),
        .state => xdgOrHome(allocator, env_map, "XDG_STATE_HOME", ".local/state"),
        .bin => xdgOrHome(allocator, env_map, "XDG_BIN_HOME", ".local/bin"),
        // `XDG_RUNTIME_DIR` has no `HOME`-relative default in the specification -
        // it is where a session's sockets belong, and a home directory is the wrong
        // place for them. `/tmp` is the documented fallback; a caller that needs a
        // private runtime directory should set the variable.
        .runtime => xdgOrFallback(allocator, env_map, "XDG_RUNTIME_DIR", "/tmp"),
    };
}

/// `$VAR` when set and non-empty, else `$HOME/<relative>`, else `error.HomeUnset`.
fn xdgOrHome(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    var_name: []const u8,
    relative: []const u8,
) Error![]u8 {
    assert(var_name.len > 0);
    assert(relative.len > 0);

    if (env_map.get(var_name)) |value| {
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    const home = env_map.get("HOME") orelse return error.HomeUnset;
    if (home.len == 0) return error.HomeUnset;
    return join(allocator, .linux, &.{ home, relative });
}

/// `$VAR` when set and non-empty, else a fixed absolute fallback.
fn xdgOrFallback(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    var_name: []const u8,
    fallback: []const u8,
) Error![]u8 {
    assert(var_name.len > 0);
    assert(fallback.len > 0);

    if (env_map.get(var_name)) |value| {
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    return allocator.dupe(u8, fallback);
}

/// The Windows branch. `%APPDATA%` is the roaming profile, which is what a user's
/// configuration belongs in; everything machine-local goes under `%LOCALAPPDATA%`.
fn windowsDir(
    allocator: std.mem.Allocator,
    kind: Kind,
    env_map: *const std.process.Environ.Map,
) Error![]u8 {
    const var_name, const suffix = switch (kind) {
        .config => .{ "APPDATA", "" },
        .data => .{ "LOCALAPPDATA", "" },
        .cache => .{ "LOCALAPPDATA", "Cache" },
        .state => .{ "LOCALAPPDATA", "State" },
        .bin => .{ "LOCALAPPDATA", "Programs" },
        // A per-user runtime directory has no Windows equivalent; the machine's
        // temp directory is what a process-scoped runtime directory maps onto.
        .runtime => .{ "TEMP", "" },
    };
    assert(var_name.len > 0);

    const base = env_map.get(var_name) orelse return error.HomeUnset;
    if (base.len == 0) return error.HomeUnset;
    if (suffix.len == 0) return allocator.dupe(u8, base);
    return join(allocator, .windows, &.{ base, suffix });
}

/// Joins with the separator `os_tag` uses, not the host's.
///
/// `std.fs.path.join` would use the host separator, so a POSIX resolution checked
/// on Windows would come back with backslashes and quietly disagree with every
/// Linux user. The separator is part of the answer, so it is chosen from the same
/// argument that chose the branches.
fn join(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    parts: []const []const u8,
) Error![]u8 {
    assert(parts.len >= 1);
    const sep: u8 = if (os_tag == .windows) '\\' else '/';

    var total: usize = 0;
    for (parts, 0..) |part, i| {
        assert(part.len > 0);
        if (i != 0) total += 1;
        total += part.len;
    }

    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    var cursor: usize = 0;
    for (parts, 0..) |part, i| {
        if (i != 0) {
            out[cursor] = sep;
            cursor += 1;
        }
        @memcpy(out[cursor..][0..part.len], part);
        cursor += part.len;
    }
    assert(cursor == out.len);
    return out;
}

const testing = std.testing;

/// Builds the env map a test needs. `std.process.Environ.Map` is the type the
/// caller supplies at runtime, so the tests exercise the real lookup rather than a
/// stand-in that could accept names the real map would not.
fn envWith(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "config resolves to ~/.config on POSIX when XDG_CONFIG_HOME is unset" {
    var map = try envWith(testing.allocator, &.{.{ "HOME", "/home/ada" }});
    defer map.deinit();

    const path = try dir(testing.allocator, .config, &map, .linux);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/ada/.config", path);
}

test "XDG_CONFIG_HOME wins over HOME" {
    var map = try envWith(testing.allocator, &.{
        .{ "HOME", "/home/ada" },
        .{ "XDG_CONFIG_HOME", "/opt/cfg" },
    });
    defer map.deinit();

    const path = try dir(testing.allocator, .config, &map, .linux);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/opt/cfg", path);
}

test "an empty override is treated as unset rather than as a relative path" {
    // `XDG_CONFIG_HOME=` is a common thing to find in a sourced profile. Treating
    // it as a path would resolve every config file to a name with no directory.
    var map = try envWith(testing.allocator, &.{
        .{ "HOME", "/home/ada" },
        .{ "XDG_CONFIG_HOME", "" },
    });
    defer map.deinit();

    const path = try dir(testing.allocator, .config, &map, .linux);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/ada/.config", path);
}

test "the Windows branch uses APPDATA for config and LOCALAPPDATA for cache" {
    var map = try envWith(testing.allocator, &.{
        .{ "APPDATA", "C:\\Users\\ada\\AppData\\Roaming" },
        .{ "LOCALAPPDATA", "C:\\Users\\ada\\AppData\\Local" },
    });
    defer map.deinit();

    const config = try dir(testing.allocator, .config, &map, .windows);
    defer testing.allocator.free(config);
    try testing.expectEqualStrings("C:\\Users\\ada\\AppData\\Roaming", config);

    const cache = try dir(testing.allocator, .cache, &map, .windows);
    defer testing.allocator.free(cache);
    try testing.expectEqualStrings("C:\\Users\\ada\\AppData\\Local\\Cache", cache);
}

test "the separator follows the requested OS, not the host" {
    var map = try envWith(testing.allocator, &.{
        .{ "APPDATA", "C:\\Roaming" },
        .{ "HOME", "/home/ada" },
    });
    defer map.deinit();

    // Both of these run on whichever host is building; the assertion is about the
    // argument, so neither depends on where the test runs.
    const win = try appDir(testing.allocator, .config, "snek", &map, .windows);
    defer testing.allocator.free(win);
    try testing.expectEqualStrings("C:\\Roaming\\snek", win);

    const nix = try appDir(testing.allocator, .config, "snek", &map, .linux);
    defer testing.allocator.free(nix);
    try testing.expectEqualStrings("/home/ada/.config/snek", nix);
}

test "a missing home is reported, not guessed" {
    var map = try envWith(testing.allocator, &.{.{ "PATH", "/usr/bin" }});
    defer map.deinit();

    try testing.expectError(error.HomeUnset, dir(testing.allocator, .config, &map, .linux));
    try testing.expectError(error.HomeUnset, dir(testing.allocator, .data, &map, .linux));
    try testing.expectError(error.HomeUnset, dir(testing.allocator, .config, &map, .windows));
}

test "runtime falls back to /tmp and is relocated by its own variable" {
    var map = try envWith(testing.allocator, &.{.{ "HOME", "/home/ada" }});
    defer map.deinit();

    const fallback = try dir(testing.allocator, .runtime, &map, .linux);
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("/tmp", fallback);

    var with_xdg = try envWith(testing.allocator, &.{
        .{ "HOME", "/home/ada" },
        .{ "XDG_RUNTIME_DIR", "/run/user/1000" },
    });
    defer with_xdg.deinit();

    const runtime = try dir(testing.allocator, .runtime, &with_xdg, .linux);
    defer testing.allocator.free(runtime);
    try testing.expectEqualStrings("/run/user/1000", runtime);
}
