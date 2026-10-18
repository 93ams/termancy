//! Facts about the environment a program runs in: continuous integration, the
//! `DO_NOT_TRACK` opt-out, elevated privileges, the host name, the user name, and the shell.
//!
//! The environment-variable questions are pure functions of an environment map (and an OS
//! tag where the variables differ), so they are tested without touching the process.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Environ = std.process.Environ;
const dirs = @import("dirs.zig");

/// The operating system whose conventions to follow.
pub const Os = dirs.Os;

/// The running operating system.
pub const native = dirs.native;

/// A continuous-integration service, as recognized from the variables it sets.
pub const Ci = enum {
    github_actions,
    gitlab,
    buildkite,
    circleci,
    travis,
    jenkins,
    azure_pipelines,
    teamcity,
    bitbucket,
    appveyor,
    drone,
    codebuild,
    /// `CI` is set to a true value, but no known service was recognized.
    generic,
};

/// The variable each service sets, in detection order. Exposed so a caller can list them.
pub const ci_markers = [_]struct { name: []const u8, ci: Ci }{
    .{ .name = "GITHUB_ACTIONS", .ci = .github_actions },
    .{ .name = "GITLAB_CI", .ci = .gitlab },
    .{ .name = "BUILDKITE", .ci = .buildkite },
    .{ .name = "CIRCLECI", .ci = .circleci },
    .{ .name = "TRAVIS", .ci = .travis },
    .{ .name = "JENKINS_URL", .ci = .jenkins },
    .{ .name = "TF_BUILD", .ci = .azure_pipelines },
    .{ .name = "TEAMCITY_VERSION", .ci = .teamcity },
    .{ .name = "BITBUCKET_BUILD_NUMBER", .ci = .bitbucket },
    .{ .name = "APPVEYOR", .ci = .appveyor },
    .{ .name = "DRONE", .ci = .drone },
    .{ .name = "CODEBUILD_BUILD_ID", .ci = .codebuild },
};

/// The CI service running this program, or `null` outside CI. `CI` set to a false value
/// (`0`, `false`, `no`, `off`) is an explicit "not CI" and wins over every marker, so a user
/// can ask for interactive behavior inside a CI shell.
pub fn ci(environ: *const Environ.Map) ?Ci {
    const ci_var = environ.get("CI");
    if (ci_var) |value| if (value.len > 0 and !isTruthy(value)) return null;
    for (ci_markers) |marker| {
        const value = environ.get(marker.name) orelse continue;
        if (value.len > 0 and isTruthy(value)) return marker.ci;
    }
    if (ci_var) |value| if (isTruthy(value)) return .generic;
    return null;
}

/// Whether this program runs under continuous integration. See `ci`.
pub fn isCi(environ: *const Environ.Map) bool {
    return ci(environ) != null;
}

/// Whether the user opted out of telemetry with `DO_NOT_TRACK` (any true value; see
/// <https://consoledonottrack.com>).
pub fn doNotTrack(environ: *const Environ.Map) bool {
    const value = environ.get("DO_NOT_TRACK") orelse return false;
    return isTruthy(value);
}

/// Whether `value` reads as true: non-empty and not `0`, `false`, `no`, or `off` (in any
/// letter case).
pub fn isTruthy(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return false;
    for ([_][]const u8{ "0", "false", "no", "off" }) |falsy| {
        if (std.ascii.eqlIgnoreCase(trimmed, falsy)) return false;
    }
    return true;
}

/// The user's login name as the environment reports it: `USER`, then `LOGNAME` on POSIX;
/// `USERNAME` on Windows. Not a security boundary: any of these can be set by anyone.
pub fn username(environ: *const Environ.Map, os: Os) ?[]const u8 {
    const names: []const []const u8 = if (os == .windows) &.{"USERNAME"} else &.{
        "USER", "LOGNAME",
    };
    for (names) |name| {
        const value = environ.get(name) orelse continue;
        if (value.len > 0) return value;
    }
    return null;
}

/// The user's shell as the environment reports it: `SHELL` on POSIX, `COMSPEC` (normally
/// `cmd.exe`) on Windows.
pub fn shell(environ: *const Environ.Map, os: Os) ?[]const u8 {
    const value = environ.get(if (os == .windows) "COMSPEC" else "SHELL") orelse return null;
    return if (value.len == 0) null else value;
}

/// Whether the process runs with elevated privileges: effective user ID 0 on POSIX; an
/// elevated token (UAC "Run as administrator") on Windows. `false` when the question
/// cannot be answered.
pub fn isElevated() bool {
    if (comptime native == .windows) return isElevatedWindows();
    if (comptime native == .wasi) return false;
    return std.posix.system.geteuid() == 0;
}

fn isElevatedWindows() bool {
    const windows = std.os.windows;
    const token_query = 0x0008;
    const token_elevation = 20;
    var token: windows.HANDLE = undefined;
    if (!win32.OpenProcessToken(windows.GetCurrentProcess(), token_query, &token).toBool()) {
        return false;
    }
    defer windows.CloseHandle(token);
    var elevated: windows.DWORD = 0;
    var size: windows.DWORD = 0;
    const len: windows.DWORD = @sizeOf(windows.DWORD);
    const ok = win32.GetTokenInformation(token, token_elevation, &elevated, len, &size);
    return ok.toBool() and elevated != 0;
}

/// The longest host name `hostname` returns.
pub const max_hostname_bytes = if (native == .windows) 256 * 3 else std.posix.HOST_NAME_MAX;

/// Errors from `hostname`.
pub const HostnameError = error{ PermissionDenied, Unexpected };

/// The machine's host name, written into `buffer`: `gethostname` (or `uname`) on POSIX,
/// the DNS host name (`GetComputerNameExW`) on Windows.
pub fn hostname(buffer: *[max_hostname_bytes]u8) HostnameError![]u8 {
    if (comptime native == .windows) return hostnameWindows(buffer);
    return std.posix.gethostname(buffer);
}

fn hostnameWindows(buffer: *[max_hostname_bytes]u8) HostnameError![]u8 {
    const computer_name_dns_hostname = 1;
    var wide: [256]u16 = undefined;
    var len: std.os.windows.DWORD = wide.len;
    if (!win32.GetComputerNameExW(computer_name_dns_hostname, &wide, &len).toBool()) {
        return error.Unexpected;
    }
    assert(len < wide.len);
    // Three WTF-8 bytes per WTF-16 unit at most, which `max_hostname_bytes` allows.
    const n = std.unicode.wtf16LeToWtf8(buffer, wide[0..len]);
    return buffer[0..n];
}

const win32 = struct {
    const windows = std.os.windows;
    extern "advapi32" fn OpenProcessToken(
        process: windows.HANDLE,
        access: windows.DWORD,
        token: *windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetTokenInformation(
        token: windows.HANDLE,
        class: c_int,
        info: *anyopaque,
        info_len: windows.DWORD,
        return_len: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetComputerNameExW(
        format: c_int,
        buffer: [*]u16,
        size: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
};

const testing = std.testing;

fn testEnviron(pairs: []const [2][]const u8) !Environ.Map {
    var map: Environ.Map = .init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "ci recognizes each service" {
    for (ci_markers) |marker| {
        var env = try testEnviron(&.{.{ marker.name, "true" }});
        defer env.deinit();
        try testing.expectEqual(marker.ci, ci(&env).?);
    }
}

test "ci: generic, absent, and explicitly disabled" {
    var none = try testEnviron(&.{});
    defer none.deinit();
    try testing.expectEqual(null, ci(&none));
    try testing.expect(!isCi(&none));

    var generic = try testEnviron(&.{.{ "CI", "1" }});
    defer generic.deinit();
    try testing.expectEqual(.generic, ci(&generic).?);

    var github = try testEnviron(&.{ .{ "CI", "true" }, .{ "GITHUB_ACTIONS", "true" } });
    defer github.deinit();
    try testing.expectEqual(.github_actions, ci(&github).?);

    var disabled = try testEnviron(&.{ .{ "CI", "false" }, .{ "GITLAB_CI", "true" } });
    defer disabled.deinit();
    try testing.expectEqual(null, ci(&disabled));

    var empty_marker = try testEnviron(&.{.{ "BUILDKITE", "" }});
    defer empty_marker.deinit();
    try testing.expectEqual(null, ci(&empty_marker));
}

test "doNotTrack and isTruthy" {
    var env = try testEnviron(&.{.{ "DO_NOT_TRACK", "1" }});
    defer env.deinit();
    try testing.expect(doNotTrack(&env));
    try env.put("DO_NOT_TRACK", "0");
    try testing.expect(!doNotTrack(&env));
    var none = try testEnviron(&.{});
    defer none.deinit();
    try testing.expect(!doNotTrack(&none));
    try testing.expect(isTruthy("yes"));
    try testing.expect(isTruthy(" TRUE "));
    try testing.expect(!isTruthy("Off"));
    try testing.expect(!isTruthy(" "));
}

test "username and shell per OS" {
    var env = try testEnviron(&.{
        .{ "LOGNAME", "ann" },
        .{ "USERNAME", "Ann" },
        .{ "SHELL", "/bin/zsh" },
        .{ "COMSPEC", "C:\\Windows\\system32\\cmd.exe" },
    });
    defer env.deinit();
    try testing.expectEqualStrings("ann", username(&env, .linux).?);
    try env.put("USER", "root");
    try testing.expectEqualStrings("root", username(&env, .macos).?);
    try testing.expectEqualStrings("Ann", username(&env, .windows).?);
    try testing.expectEqualStrings("/bin/zsh", shell(&env, .linux).?);
    try testing.expectEqualStrings("C:\\Windows\\system32\\cmd.exe", shell(&env, .windows).?);
    var none = try testEnviron(&.{.{ "SHELL", "" }});
    defer none.deinit();
    try testing.expectEqual(null, shell(&none, .linux));
    try testing.expectEqual(null, username(&none, .linux));
}

test "hostname is non-empty" {
    var buffer: [max_hostname_bytes]u8 = undefined;
    const name = try hostname(&buffer);
    try testing.expect(name.len > 0);
}

test "isElevated agrees with the effective user" {
    const elevated = isElevated();
    if (native != .windows and native != .wasi) {
        try testing.expectEqual(std.posix.system.geteuid() == 0, elevated);
    }
}
