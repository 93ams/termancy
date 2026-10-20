//! A panic handler: restore the terminal, print a banner, optionally write a JSON report,
//! then hand over to `std.debug.defaultPanic` for the message, the stack trace, and abort.
//!
//! An application installs it in its root source file:
//!
//! ```zig
//! pub const panic = sys.crash.Panic(.{
//!     .app_name = "termancy",
//!     .version = "0.2.0",
//!     .issues_url = "https://github.com/93ams/termancy/issues",
//!     .report_dir = ".termancy/crashes", // or null, then `crash.setReportDir` at startup
//! });
//! ```
//!
//! `Panic` returns a `std.debug.FullPanic` namespace, which is what the compiler looks for
//! in `root.panic`. The configuration is comptime so a panic during startup is covered too;
//! the report directory can also be set at run time (`setReportDir`), for a per-user state
//! directory known only after startup.
//!
//! The report holds the message, app, version, OS, architecture, Zig version, and time. It
//! never holds argv or the environment, which carry paths, user names, and secrets.
//!
//! Hooks (`addHook`) run first, before anything is printed: an application with a terminal
//! UI registers `term.Terminal.restoreOnPanic`, which leaves raw mode and the alternate
//! screen, so the trace lands on a usable terminal. Register and remove hooks from one thread; the handler reads them as they are.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const log = @import("log.zig");

/// What the handler needs to know.
pub const Config = struct {
    app_name: []const u8,
    /// Printed and reported; empty when unknown.
    version: []const u8 = "",
    /// Printed in the banner when not empty.
    issues_url: []const u8 = "",
    /// Directory for reports, relative to the working directory or absolute. Null writes
    /// no report unless `setReportDir` was called.
    report_dir: ?[]const u8 = null,
};

/// A function run before the banner, such as restoring the terminal. It must not panic,
/// allocate, or block.
pub const Hook = *const fn () void;

/// How many hooks can be registered at once.
pub const max_hooks = 8;

var hooks: [max_hooks]Hook = undefined;
var hook_count: usize = 0;
var runtime_dir_buffer: [512]u8 = undefined;
var runtime_dir_len: usize = 0;
var entered: std.atomic.Value(bool) = .init(false);

/// Registers `hook`. Hooks run newest first, like `defer`.
pub fn addHook(hook: Hook) error{TooManyHooks}!void {
    if (hook_count == max_hooks) return error.TooManyHooks;
    hooks[hook_count] = hook;
    hook_count += 1;
}

/// Unregisters `hook`; does nothing if it is not registered.
pub fn removeHook(hook: Hook) void {
    var i: usize = hook_count;
    while (i > 0) {
        i -= 1;
        if (hooks[i] != hook) continue;
        std.mem.copyForwards(Hook, hooks[i .. hook_count - 1], hooks[i + 1 .. hook_count]);
        hook_count -= 1;
        return;
    }
}

/// Runs every hook, newest first. The panic handler calls this; so may a fatal-signal path.
pub fn runHooks() void {
    var i: usize = hook_count;
    while (i > 0) {
        i -= 1;
        hooks[i]();
    }
}

/// Sets the report directory at run time, overriding `Config.report_dir`. The path is
/// copied, so it need not outlive the call. An empty path turns reports off.
pub fn setReportDir(dir: []const u8) error{NameTooLong}!void {
    if (dir.len > runtime_dir_buffer.len) return error.NameTooLong;
    @memcpy(runtime_dir_buffer[0..dir.len], dir);
    runtime_dir_len = dir.len;
}

/// The directory reports go to: the run-time one when set, else the configured one.
pub fn reportDir(config: Config) ?[]const u8 {
    if (runtime_dir_len > 0) return runtime_dir_buffer[0..runtime_dir_len];
    const dir = config.report_dir orelse return null;
    return if (dir.len == 0) null else dir;
}

/// The content of a crash report. Built without panicking, so it is testable.
pub const Report = struct {
    message: []const u8,
    app: []const u8,
    version: []const u8,
    time: Io.Timestamp,
    os: []const u8 = @tagName(builtin.os.tag),
    arch: []const u8 = @tagName(builtin.cpu.arch),
    zig_version: []const u8 = builtin.zig_version_string,

    /// The report for `message` at `time`.
    pub fn init(config: Config, message: []const u8, time: Io.Timestamp) Report {
        return .{
            .message = message,
            .app = config.app_name,
            .version = config.version,
            .time = time,
        };
    }

    /// One JSON object and a newline.
    pub fn writeJson(report: Report, w: *Io.Writer) Io.Writer.Error!void {
        var json: std.json.Stringify = .{ .writer = w };
        try json.beginObject();
        inline for (.{ "message", "app", "version", "os", "arch", "zig_version" }) |key| {
            try json.objectField(key);
            try json.write(@field(report, key));
        }
        try json.objectField("time");
        try json.beginWriteRaw();
        try w.writeByte('"');
        try log.writeTimestamp(w, report.time);
        try w.writeByte('"');
        json.endWriteRaw();
        try json.endObject();
        try w.writeByte('\n');
    }
};

/// Writes the banner shown before the panic message and stack trace.
pub fn writeBanner(w: *Io.Writer, config: Config, message: []const u8) Io.Writer.Error!void {
    _ = message; // `defaultPanic` prints it right after, with the trace.
    try w.print("\n{s}", .{config.app_name});
    if (config.version.len > 0) try w.print(" {s}", .{config.version});
    try w.print(" crashed ({t}, {t}). This is a bug.\n", .{ builtin.os.tag, builtin.cpu.arch });
    if (config.issues_url.len > 0) {
        try w.print("Please report it at {s}\n", .{config.issues_url});
    }
}

/// `<dir>/<app>-crash-<unix seconds>-<nanoseconds into the second>.json`, written into
/// `buffer`; a `sequence` above zero is appended as `-<sequence>` before `.json`.
pub fn reportPath(
    buffer: []u8,
    dir: []const u8,
    app: []const u8,
    time: Io.Timestamp,
    sequence: u32,
) error{NoSpaceLeft}![]const u8 {
    assert(dir.len > 0);
    const nanos: u32 = @intCast(@mod(time.nanoseconds, std.time.ns_per_s));
    var w: Io.Writer = .fixed(buffer);
    w.print("{s}/{s}-crash-{d}-{d:0>9}", .{ dir, app, time.toSeconds(), nanos }) catch
        return error.NoSpaceLeft;
    if (sequence > 0) w.print("-{d}", .{sequence}) catch return error.NoSpaceLeft;
    w.writeAll(".json") catch return error.NoSpaceLeft;
    return w.buffered();
}

/// How many names `writeReportFile` tries before giving up with `error.PathAlreadyExists`.
pub const max_report_attempts = 16;

/// Errors from `writeReportFile`.
pub const WriteError = error{ NoSpaceLeft, PathAlreadyExists } ||
    Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.ReplaceError ||
    Io.File.Writer.Error;

/// Writes `report` atomically into `dir` (created if missing) and returns the path, which
/// lives in `path_buffer`. An existing report is not overwritten: when the name is taken
/// (two crashes in one nanosecond), a `-1`, `-2`, ... suffix is tried. The check precedes
/// the rename, as `File.Atomic.link` (no-replace rename) is unsupported on some file
/// systems, such as WSL's drvfs, where it fails with a panic in the standard library.
pub fn writeReportFile(
    io: Io,
    dir: []const u8,
    report: Report,
    path_buffer: []u8,
) WriteError![]const u8 {
    const path = for (0..max_report_attempts) |sequence| {
        const n: u32 = @intCast(sequence);
        const candidate = try reportPath(path_buffer, dir, report.app, report.time, n);
        Io.Dir.cwd().access(io, candidate, .{}) catch break candidate;
    } else return error.PathAlreadyExists;
    const options: Io.Dir.CreateFileAtomicOptions = .{ .make_path = true, .replace = true };
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, options);
    defer atomic.deinit(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buffer);
    // A `File.Writer` records the cause of every `WriteFailed` in `err`.
    report.writeJson(&file_writer.interface) catch return file_writer.err.?;
    file_writer.interface.flush() catch return file_writer.err.?;
    try atomic.replace(io);
    return path;
}

/// The panic namespace to declare as `pub const panic` in the root source file.
pub fn Panic(comptime config: Config) type {
    return std.debug.FullPanic(struct {
        fn call(message: []const u8, first_trace_addr: ?usize) noreturn {
            @branchHint(.cold);
            handle(config, message);
            std.debug.defaultPanic(message, first_trace_addr orelse @returnAddress());
        }
    }.call);
}

/// Everything the handler does before `defaultPanic`: hooks, banner, report. Runs once; a
/// panic inside it goes straight to `defaultPanic`.
fn handle(config: Config, message: []const u8) void {
    if (entered.swap(true, .acq_rel)) return;
    runHooks();
    const io = std.Options.debug_io;
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    writeBanner(w, config, message) catch return;
    const dir = reportDir(config) orelse return;
    const report: Report = .init(config, message, Io.Clock.real.now(io));
    var path_buffer: [1024]u8 = undefined;
    if (writeReportFile(io, dir, report, &path_buffer)) |path| {
        w.print("Crash report: {s}\n", .{path}) catch {};
    } else |err| {
        w.print("Could not write a crash report: {t}\n", .{err}) catch {};
    }
}

const testing = std.testing;

const test_config: Config = .{
    .app_name = "termancy",
    .version = "0.2.0",
    .issues_url = "https://example.invalid/issues",
};

test "report content has exactly the documented fields" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const report: Report = .init(test_config, "index out of \"bounds\"", .fromNanoseconds(0));
    try report.writeJson(&w);
    var expected_buffer: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buffer,
        "{{\"message\":\"index out of \\\"bounds\\\"\",\"app\":\"termancy\",\"version\":\"0.2.0\"," ++
            "\"os\":\"{t}\",\"arch\":\"{t}\",\"zig_version\":\"{s}\"," ++
            "\"time\":\"1970-01-01T00:00:00Z\"}}\n",
        .{ builtin.os.tag, builtin.cpu.arch, builtin.zig_version_string },
    );
    try testing.expectEqualStrings(expected, w.buffered());

    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, w.buffered(), .{});
    defer parsed.deinit();
    const keys = parsed.value.object.keys();
    const allowed = [_][]const u8{
        "message", "app", "version", "os", "arch", "zig_version", "time",
    };
    try testing.expectEqual(allowed.len, keys.len);
    for (keys, allowed) |key, want| try testing.expectEqualStrings(want, key);
}

test "report leaks no argv or environment" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try Report.init(test_config, "boom", .fromNanoseconds(0)).writeJson(&w);
    var environ = try testing.environ.createMap(testing.allocator);
    defer environ.deinit();
    for (environ.values()) |value| {
        // Paths are what an environment leaks; short values collide with ordinary words.
        if (value.len < 4 or std.mem.indexOfAny(u8, value, "/\\") == null) continue;
        try testing.expect(std.mem.indexOf(u8, w.buffered(), value) == null);
    }
    for ([_][]const u8{ "PATH", "HOME", "USER", "argv", "env" }) |word| {
        try testing.expect(std.mem.indexOf(u8, w.buffered(), word) == null);
    }
}

test "banner" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeBanner(&w, test_config, "boom");
    var expected_buffer: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer,
        \\
        \\termancy 0.2.0 crashed ({t}, {t}). This is a bug.
        \\Please report it at https://example.invalid/issues
        \\
    , .{ builtin.os.tag, builtin.cpu.arch });
    try testing.expectEqualStrings(expected, w.buffered());
}

var test_hook_trail: [4]u8 = undefined;
var test_hook_len: usize = 0;

fn testHookA() void {
    test_hook_trail[test_hook_len] = 'a';
    test_hook_len += 1;
}

fn testHookB() void {
    test_hook_trail[test_hook_len] = 'b';
    test_hook_len += 1;
}

test "hooks run newest first and can be removed" {
    defer hook_count = 0;
    test_hook_len = 0;
    try addHook(testHookA);
    try addHook(testHookB);
    runHooks();
    try testing.expectEqualStrings("ba", test_hook_trail[0..test_hook_len]);
    removeHook(testHookB);
    removeHook(testHookB); // Not registered: no effect.
    test_hook_len = 0;
    runHooks();
    try testing.expectEqualStrings("a", test_hook_trail[0..test_hook_len]);
    for (1..max_hooks) |_| try addHook(testHookA);
    try testing.expectError(error.TooManyHooks, addHook(testHookB));
}

test "report directory: configured, run-time override, off" {
    defer runtime_dir_len = 0;
    try testing.expectEqual(null, reportDir(test_config));
    var config = test_config;
    config.report_dir = "crashes";
    try testing.expectEqualStrings("crashes", reportDir(config).?);
    try setReportDir("/var/state/termancy");
    try testing.expectEqualStrings("/var/state/termancy", reportDir(config).?);
    var huge: [600]u8 = undefined;
    @memset(&huge, 'x');
    try testing.expectError(error.NameTooLong, setReportDir(&huge));
}

test "writeReportFile writes atomically into a new directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var dir_buffer: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/reports", .{&tmp.sub_path});
    const time: Io.Timestamp = .fromNanoseconds(1_791_799_200 * std.time.ns_per_s + 42);
    const report: Report = .init(test_config, "boom", time);
    var path_buffer: [512]u8 = undefined;
    const path = try writeReportFile(io, dir, report, &path_buffer);
    const name = "termancy-crash-1791799200-000000042.json";
    try testing.expect(std.mem.endsWith(u8, path, "/reports/" ++ name));
    var read_buffer: [1024]u8 = undefined;
    const content = try tmp.dir.readFile(io, "reports/" ++ name, &read_buffer);
    try testing.expect(std.mem.startsWith(u8, content, "{\"message\":\"boom\""));
    try testing.expect(std.mem.endsWith(u8, content, "\"time\":\"2026-10-12T10:00:00Z\"}\n"));

    // A second crash at the same instant gets its own file; the first is left alone.
    const second: Report = .init(test_config, "bang", time);
    const second_path = try writeReportFile(io, dir, second, &path_buffer);
    const second_name = "termancy-crash-1791799200-000000042-1.json";
    try testing.expect(std.mem.endsWith(u8, second_path, "/" ++ second_name));
    const first = try tmp.dir.readFile(io, "reports/" ++ name, &read_buffer);
    try testing.expect(std.mem.startsWith(u8, first, "{\"message\":\"boom\""));
}

test "report JSON escapes a Windows path" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const message = "cannot open C:\\Users\\ann\\x.toml";
    try Report.init(test_config, message, .fromNanoseconds(0)).writeJson(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "C:\\\\Users\\\\ann") != null);
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(message, parsed.value.object.get("message").?.string);
}

test "Panic is a complete panic namespace" {
    const P = Panic(test_config);
    // Referencing the declarations type-checks the handler without running it.
    const call: fn ([]const u8, ?usize) noreturn = P.call;
    _ = call;
    _ = &P.unwrapError;
}
