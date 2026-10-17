//! Child processes: run one with its output captured or with the terminal handed over,
//! find a program on `PATH`, open a file (or a string, `editText`) in the user's editor or
//! a URL in their browser, and ask whether a process ID is still alive.
//!
//! Spawning goes through `std.process.spawn` and the caller's `std.Io`. Everything that
//! only inspects the environment (`which`'s search order, `editor`, `openArgv`) takes the
//! OS as a parameter, so each platform's rules are tested on any host.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const dirs = @import("dirs.zig");
const files = @import("files.zig");

/// The operating system whose conventions to follow.
pub const Os = dirs.Os;

/// The running operating system.
pub const native = dirs.native;

/// How a child ended.
pub const Term = std.process.Child.Term;

/// A process ID. Positive on every platform (`pid_t` on POSIX, `DWORD` on Windows).
pub const Pid = u32;

/// The exit status a shell would report for `term`: the code for a normal exit,
/// 128 + the signal number for a signal, and 1 when the platform reports nothing usable.
pub fn exitStatus(term: Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 +| (std.math.cast(u8, @backingInt(sig)) orelse 127),
        .unknown => 1,
    };
}

/// Options shared by `capture` and `stream`.
pub const Options = struct {
    /// The child's working directory; `null` inherits the parent's.
    cwd: ?[]const u8 = null,
    /// Replaces the child's environment. `argv[0]` is still resolved with the parent's PATH.
    environ: ?*const Environ.Map = null,
    /// `capture` fails with `error.StreamTooLong` when standard output exceeds this.
    stdout_limit: Io.Limit = .limited(16 * 1024 * 1024),
    /// `capture` fails with `error.StreamTooLong` when standard error exceeds this.
    stderr_limit: Io.Limit = .limited(1024 * 1024),
    /// `capture` kills the child and fails with `error.Timeout` when its output streams are
    /// still open this long after the start (monotonic clock). A child that closes both
    /// streams and keeps running is still waited for. `stream` ignores it.
    timeout: ?Io.Duration = null,
};

/// What a captured child wrote, and how it ended.
pub const Output = struct {
    term: Term,
    stdout: []u8,
    stderr: []u8,

    /// Frees both streams.
    pub fn deinit(output: Output, gpa: Allocator) void {
        gpa.free(output.stdout);
        gpa.free(output.stderr);
    }

    /// Whether the child exited with status 0.
    pub fn success(output: Output) bool {
        return output.term.success();
    }
};

/// Errors from `capture`. `error.Timeout` means `Options.timeout` passed and the child was
/// killed.
pub const CaptureError = std.process.RunError;

/// Errors from `stream`.
pub const StreamError = std.process.SpawnError || std.process.Child.WaitError;

/// Runs `argv` with standard input closed to `/dev/null` (`NUL`) and standard output and
/// error collected, then waits. A non-zero exit is not an error; inspect `Output.term`.
pub fn capture(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    options: Options,
) CaptureError!Output {
    assert(argv.len > 0);
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = cwdOf(options),
        .environ_map = options.environ,
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
        // A deadline, not a duration: `run` applies it to every read, and a duration would
        // restart with each chunk of output.
        .timeout = if (options.timeout) |duration| .{
            .deadline = .fromNow(io, .{ .raw = duration, .clock = .awake }),
        } else .none,
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

/// Runs `argv` with the parent's standard streams, so the child talks to the terminal
/// directly (an editor, a pager, a nested shell), then waits.
pub fn stream(io: Io, argv: []const []const u8, options: Options) StreamError!Term {
    assert(argv.len > 0);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwdOf(options),
        .environ_map = options.environ,
    });
    errdefer child.kill(io);
    return child.wait(io);
}

fn cwdOf(options: Options) std.process.Child.Cwd {
    return if (options.cwd) |dir| .{ .path = dir } else .inherit;
}

/// Errors from `which`.
pub const WhichError = Allocator.Error || Io.Cancelable;

/// The full path of the program `name`, found the way `os` would find it, or `null`.
/// Caller owns the result.
///
/// A `name` containing a path separator is checked as given. Otherwise each `PATH` entry
/// is tried in order; on Windows each entry is tried with every `PATHEXT` extension
/// (default `.COM;.EXE;.BAT;.CMD`), and with `name` alone first when it already ends in
/// one of them. Unlike `cmd.exe`, the current directory is never searched implicitly.
/// A candidate must be a regular file, and executable on POSIX.
pub fn which(
    gpa: Allocator,
    io: Io,
    environ: *const Environ.Map,
    os: Os,
    name: []const u8,
) WhichError!?[]u8 {
    assert(name.len > 0);
    if (hasSeparator(os, name)) return findCandidate(gpa, io, os, &.{name}, environ);
    const path_var = environ.get("PATH") orelse return null;
    var entries = std.mem.tokenizeScalar(u8, path_var, if (os == .windows) ';' else ':');
    while (entries.next()) |entry| {
        if (try findCandidate(gpa, io, os, &.{ entry, name }, environ)) |found| return found;
    }
    return null;
}

/// Tries `parts` joined, then (on Windows) with each `PATHEXT` extension appended.
fn findCandidate(
    gpa: Allocator,
    io: Io,
    os: Os,
    parts: []const []const u8,
    environ: *const Environ.Map,
) WhichError!?[]u8 {
    const base = try dirs.join(gpa, os, parts);
    var found = false;
    defer if (!found) gpa.free(base);
    if (os != .windows or hasPathExt(environ, parts[parts.len - 1])) {
        found = try isProgram(io, os, base);
        if (found) return base;
    }
    if (os != .windows) return null;
    var exts = std.mem.tokenizeScalar(u8, pathExt(environ), ';');
    while (exts.next()) |ext| {
        const candidate = try std.mem.concat(gpa, u8, &.{ base, ext });
        const ok = isProgram(io, os, candidate) catch |err| {
            gpa.free(candidate);
            return err;
        };
        if (ok) return candidate;
        gpa.free(candidate);
    }
    return null;
}

fn pathExt(environ: *const Environ.Map) []const u8 {
    const value = environ.get("PATHEXT") orelse return ".COM;.EXE;.BAT;.CMD";
    return if (value.len == 0) ".COM;.EXE;.BAT;.CMD" else value;
}

fn hasPathExt(environ: *const Environ.Map, name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    var exts = std.mem.tokenizeScalar(u8, pathExt(environ), ';');
    while (exts.next()) |ext| {
        if (std.ascii.eqlIgnoreCase(ext, name[dot..])) return true;
    }
    return false;
}

fn hasSeparator(os: Os, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return true;
    return os == .windows and std.mem.indexOfScalar(u8, name, '\\') != null;
}

fn isProgram(io: Io, os: Os, candidate: []const u8) Io.Cancelable!bool {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, candidate, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    if (stat.kind != .file) return false;
    if (os == .windows or native == .windows) return true;
    cwd.access(io, candidate, .{ .execute = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return true;
}

/// The user's editor command: `$VISUAL`, then `$EDITOR`, then `notepad` on Windows and
/// `vi` elsewhere. It may hold arguments (`code --wait`); `edit` splits it on whitespace.
pub fn editor(environ: *const Environ.Map, os: Os) []const u8 {
    for ([_][]const u8{ "VISUAL", "EDITOR" }) |name| {
        const value = environ.get(name) orelse continue;
        if (std.mem.trim(u8, value, " \t").len > 0) return value;
    }
    return if (os == .windows) "notepad" else "vi";
}

/// Errors from `edit`.
pub const EditError = StreamError || Allocator.Error;

/// Opens `file_path` in the user's editor (see `editor`) and waits for it to exit. The
/// editor command is split on spaces and tabs; quotes in it are not interpreted, except on
/// Windows, where it is split as a command line: a path with spaces goes in double quotes.
pub fn edit(
    gpa: Allocator,
    io: Io,
    environ: *const Environ.Map,
    file_path: []const u8,
) EditError!Term {
    return editAt(gpa, io, environ, file_path, null);
}

/// Options for `editText`.
pub const EditTextOptions = struct {
    /// Ends the temporary file's name, so the editor picks a syntax: `.md`, `.toml`. No
    /// path separators.
    suffix: []const u8 = ".txt",
    /// The directory for the temporary file; null means `dirs.tempDir`.
    dir: ?[]const u8 = null,
    /// `error.StreamTooLong` when the edited text is longer.
    limit: Io.Limit = .limited(16 * 1024 * 1024),
};

/// Errors from `editText`.
pub const EditTextError = EditError || dirs.Error || Io.File.OpenError ||
    Io.File.Writer.Error || Io.Dir.ReadFileAllocError || error{
    /// The editor exited unsuccessfully; the edit is abandoned, as `git commit` does.
    EditorFailed,
};

/// Lets the user edit `initial` in their editor (see `edit`) and returns the saved text,
/// which the caller owns. The text goes through a new file, readable only by the user on
/// POSIX, in `options.dir` or the temporary directory; it is deleted afterwards, also on
/// error.
pub fn editText(
    gpa: Allocator,
    io: Io,
    environ: *const Environ.Map,
    initial: []const u8,
    options: EditTextOptions,
) EditTextError![]u8 {
    assert(std.mem.indexOfAny(u8, options.suffix, "/\\") == null);
    const dir = if (options.dir) |d|
        try gpa.dupe(u8, d)
    else
        try dirs.tempDir(gpa, environ, native);
    defer gpa.free(dir);
    var tag: u64 = undefined;
    io.random(std.mem.asBytes(&tag));
    const name = try std.fmt.allocPrint(gpa, "edit-{x:0>16}{s}", .{ tag, options.suffix });
    defer gpa.free(name);
    const file_path = try dirs.join(gpa, native, &.{ dir, name });
    defer gpa.free(file_path);
    const cwd = Io.Dir.cwd();
    {
        const flags: Io.Dir.CreateFileOptions = .{
            .exclusive = true,
            .permissions = files.private_file,
        };
        const file = try cwd.createFile(io, file_path, flags);
        defer file.close(io);
        errdefer cwd.deleteFile(io, file_path) catch {};
        try file.writeStreamingAll(io, initial);
    }
    defer cwd.deleteFile(io, file_path) catch {};
    const term = try edit(gpa, io, environ, file_path);
    if (!term.success()) return error.EditorFailed;
    return cwd.readFileAlloc(io, file_path, gpa, files.inclusiveLimit(options.limit));
}

/// A place in a file: a line, and a column on it, both from 1.
pub const Position = struct {
    line: u32,
    column: ?u32 = null,
};

/// `edit`, with the cursor put at `at`, as x/editor does: each editor's own way of saying
/// so (`vim +12`, `code --goto file:12:3`, `nano +12,3`, `emacs +12:3`, `hx file:12:3`,
/// `subl file:12:3`, `zed file:12:3`, `kak +12:3`, `micro +12:3`, `notepad++ -n12`). An
/// editor it does not know gets the file alone.
pub fn editAt(
    gpa: Allocator,
    io: Io,
    environ: *const Environ.Map,
    file_path: []const u8,
    at: ?Position,
) EditError!Term {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const argv = try editArgv(arena_state.allocator(), editor(environ, native), file_path, at);
    return stream(io, argv, .{});
}

/// The arguments that open `file_path` at `at` with the editor command `command` (which
/// may hold arguments of its own, such as `code --wait`).
pub fn editArgv(
    arena: Allocator,
    command: []const u8,
    file_path: []const u8,
    at: ?Position,
) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    if (native == .windows) {
        // A command line's rules: `"C:\Program Files\Notepad++\notepad++.exe" -multiInst`.
        const command_w = std.unicode.wtf8ToWtf16LeAlloc(arena, command) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => &.{},
        };
        var words: std.process.Args.Iterator.Windows = try .init(arena, command_w);
        while (words.next()) |word| try argv.append(arena, try arena.dupe(u8, word));
    } else {
        var words = std.mem.tokenizeAny(u8, command, " \t");
        while (words.next()) |word| try argv.append(arena, word);
    }
    if (argv.items.len == 0) try argv.append(arena, if (native == .windows) "notepad" else "vi");
    const place = at orelse {
        try argv.append(arena, file_path);
        return argv.items;
    };
    const program = std.fs.path.stem(std.fs.path.basename(argv.items[0]));
    const line = place.line;
    const column = place.column;
    const Form = enum { plus_line, plus_colon, plus_comma, goto, suffix, notepad_pp, plain };
    const forms = [_]struct { []const u8, Form }{
        .{ "vi", .plus_line },        .{ "vim", .plus_line },          .{ "nvim", .plus_line },
        .{ "gvim", .plus_line },      .{ "mvim", .plus_line },         .{ "view", .plus_line },
        .{ "ed", .plus_line },        .{ "joe", .plus_line },          .{ "mcedit", .plus_line },
        .{ "emacs", .plus_colon },    .{ "emacsclient", .plus_colon }, .{ "kak", .plus_colon },
        .{ "micro", .plus_colon },    .{ "nano", .plus_comma },        .{ "pico", .plus_comma },
        .{ "code", .goto },           .{ "code-insiders", .goto },     .{ "codium", .goto },
        .{ "cursor", .goto },         .{ "windsurf", .goto },          .{ "subl", .suffix },
        .{ "sublime_text", .suffix }, .{ "hx", .suffix },              .{ "helix", .suffix },
        .{ "zed", .suffix },          .{ "atom", .suffix },            .{ "mate", .suffix },
        .{ "lapce", .suffix },        .{ "notepad++", .notepad_pp },
    };
    var form: Form = .plain;
    for (forms) |entry| if (std.mem.eql(u8, entry[0], program)) {
        form = entry[1];
    };
    switch (form) {
        .plus_line => {
            try argv.append(arena, try std.fmt.allocPrint(arena, "+{d}", .{line}));
            try argv.append(arena, file_path);
        },
        .plus_colon, .plus_comma => {
            const separator: u8 = if (form == .plus_colon) ':' else ',';
            const place_arg = if (column) |c|
                try std.fmt.allocPrint(arena, "+{d}{c}{d}", .{ line, separator, c })
            else
                try std.fmt.allocPrint(arena, "+{d}", .{line});
            try argv.append(arena, place_arg);
            try argv.append(arena, file_path);
        },
        .goto => {
            try argv.append(arena, "--goto");
            try argv.append(arena, try suffixed(arena, file_path, line, column));
        },
        .suffix => try argv.append(arena, try suffixed(arena, file_path, line, column)),
        .notepad_pp => {
            try argv.append(arena, try std.fmt.allocPrint(arena, "-n{d}", .{line}));
            if (column) |c| try argv.append(arena, try std.fmt.allocPrint(arena, "-c{d}", .{c}));
            try argv.append(arena, file_path);
        },
        .plain => try argv.append(arena, file_path),
    }
    return argv.items;
}

fn suffixed(
    arena: Allocator,
    path: []const u8,
    line: u32,
    column: ?u32,
) Allocator.Error![]const u8 {
    if (column) |c| return std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ path, line, c });
    return std.fmt.allocPrint(arena, "{s}:{d}", .{ path, line });
}

/// The command that opens a URL with the desktop's default handler: `xdg-open` on Linux
/// and the BSDs, `open` on macOS, `rundll32 url.dll,FileProtocolHandler` on Windows (which,
/// unlike `cmd /c start`, does not interpret `&` or `^` in the URL).
pub fn openArgv(os: Os, url: []const u8) OpenArgv {
    if (os == .windows) {
        return .{ .buffer = .{ "rundll32", "url.dll,FileProtocolHandler", url }, .len = 3 };
    }
    const opener = if (os.isDarwin()) "open" else "xdg-open";
    return .{ .buffer = .{ opener, url, "" }, .len = 2 };
}

/// A short argument vector, returned by value.
pub const OpenArgv = struct {
    buffer: [3][]const u8,
    len: u8,

    /// The arguments.
    pub fn slice(a: *const OpenArgv) []const []const u8 {
        return a.buffer[0..a.len];
    }
};

/// Errors from `openUrl`.
pub const OpenUrlError = StreamError || error{
    /// The URL is empty, starts with `-` (it would be read as an option), or holds a
    /// control character.
    InvalidUrl,
    /// The opener ran and exited unsuccessfully.
    OpenFailed,
};

/// Opens `url` in the user's browser (or the handler for its scheme) and waits for the
/// opener (not the browser) to exit. The opener's output is discarded.
pub fn openUrl(io: Io, url: []const u8) OpenUrlError!void {
    if (!isSafeUrl(url)) return error.InvalidUrl;
    const argv = openArgv(native, url);
    var child = try std.process.spawn(io, .{
        .argv = argv.slice(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);
    const term = try child.wait(io);
    if (!term.success()) return error.OpenFailed;
}

fn isSafeUrl(url: []const u8) bool {
    if (url.len == 0 or url[0] == '-') return false;
    for (url) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// The ID of the running process.
pub fn currentId() Pid {
    if (comptime native == .windows) return std.os.windows.GetCurrentProcessId();
    const pid = std.posix.system.getpid();
    assert(pid > 0);
    return @intCast(pid);
}

/// Whether a process with ID `pid` exists. On POSIX this is `kill(pid, 0)`, which also
/// reports processes owned by other users; on Windows, an open process handle whose exit
/// code is still `STILL_ACTIVE`. PIDs are reused, so `true` means "some process", not
/// necessarily the one that wrote a PID file.
pub fn isAlive(pid: Pid) bool {
    if (pid == 0) return false;
    if (comptime native == .windows) return isAliveWindows(pid);
    const raw = std.math.cast(std.posix.pid_t, pid) orelse return false;
    std.posix.kill(raw, @fromBackingInt(0)) catch |err| return switch (err) {
        error.PermissionDenied => true,
        error.ProcessNotFound, error.Unexpected => false,
    };
    return true;
}

fn isAliveWindows(pid: Pid) bool {
    const windows = std.os.windows;
    const query_limited_information = 0x1000;
    const still_active = 259;
    const handle = win32.OpenProcess(query_limited_information, .FALSE, pid) orelse
        return windows.GetLastError() == .ACCESS_DENIED;
    defer windows.CloseHandle(handle);
    var code: windows.DWORD = 0;
    if (!win32.GetExitCodeProcess(handle, &code).toBool()) return false;
    return code == still_active;
}

const win32 = struct {
    const windows = std.os.windows;
    extern "kernel32" fn OpenProcess(
        access: windows.DWORD,
        inherit: windows.BOOL,
        pid: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetExitCodeProcess(
        process: windows.HANDLE,
        code: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
};

const testing = std.testing;

test exitStatus {
    try testing.expectEqual(0, exitStatus(.{ .exited = 0 }));
    try testing.expectEqual(3, exitStatus(.{ .exited = 3 }));
    try testing.expectEqual(1, exitStatus(.{ .unknown = 7 }));
    if (native != .windows) {
        try testing.expectEqual(130, exitStatus(.{ .signal = .INT }));
        try testing.expectEqual(143, exitStatus(.{ .signal = .TERM }));
    }
}

test editArgv {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ?Position, []const u8 }{
        .{ "vim", .{ .line = 12, .column = 3 }, "vim +12 f.zig" },
        .{ "code --wait", .{ .line = 12, .column = 3 }, "code --wait --goto f.zig:12:3" },
        .{ "nano", .{ .line = 12, .column = 3 }, "nano +12,3 f.zig" },
        .{ "/usr/bin/emacs", .{ .line = 12 }, "/usr/bin/emacs +12 f.zig" },
        .{ "hx", .{ .line = 12 }, "hx f.zig:12" },
        .{ "notepad++.exe", .{ .line = 2, .column = 5 }, "notepad++.exe -n2 -c5 f.zig" },
        .{ "ed", null, "ed f.zig" },
        .{ "unknown-editor", .{ .line = 9 }, "unknown-editor f.zig" },
    };
    for (cases) |case| {
        const argv = try editArgv(a, case[0], "f.zig", case[1]);
        const joined = try std.mem.join(a, " ", argv);
        try testing.expectEqualStrings(case[2], joined);
    }
}

test "editArgv on Windows keeps a quoted path with spaces and its backslashes" {
    if (native != .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const command = "\"C:\\Users\\me\\AppData\\Local\\Programs\\Microsoft VS Code\\bin\\code\" --wait";
    const argv = try editArgv(a, command, "f.zig", .{ .line = 12, .column = 3 });
    try testing.expectEqual(4, argv.len);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\Programs\\Microsoft VS Code\\bin\\code", argv[0]);
    // The program's name still picks the form of the line argument.
    try testing.expectEqualStrings("--goto", argv[2]);
    try testing.expectEqualStrings("f.zig:12:3", argv[3]);
    const notepad = try editArgv(a, "C:\\Windows\\notepad.exe", "f.txt", null);
    try testing.expectEqualStrings("C:\\Windows\\notepad.exe", notepad[0]);
}

test "editor prefers VISUAL, then EDITOR, then a platform default" {
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings("vi", editor(&env, .linux));
    try testing.expectEqualStrings("notepad", editor(&env, .windows));
    try env.put("EDITOR", "nano");
    try testing.expectEqualStrings("nano", editor(&env, .linux));
    try env.put("VISUAL", "  ");
    try testing.expectEqualStrings("nano", editor(&env, .linux));
    try env.put("VISUAL", "code --wait");
    try testing.expectEqualStrings("code --wait", editor(&env, .macos));
}

test "openArgv per OS" {
    const url = "https://example.com/?a=1&b=2";
    const linux = openArgv(.linux, url);
    try testing.expectEqualStrings("xdg-open", linux.slice()[0]);
    try testing.expectEqual(2, linux.slice().len);
    const mac = openArgv(.macos, url);
    try testing.expectEqualStrings("open", mac.slice()[0]);
    const win = openArgv(.windows, url);
    try testing.expectEqual(3, win.slice().len);
    try testing.expectEqualStrings(url, win.slice()[2]);
}

test "openUrl rejects option-like and control-character URLs" {
    try testing.expectError(error.InvalidUrl, openUrl(testing.io, ""));
    try testing.expectError(error.InvalidUrl, openUrl(testing.io, "--help"));
    try testing.expectError(error.InvalidUrl, openUrl(testing.io, "https://x\n"));
}

test "currentId is alive; an impossible PID is not" {
    try testing.expect(currentId() > 0);
    try testing.expect(isAlive(currentId()));
    try testing.expect(!isAlive(0));
    try testing.expect(!isAlive(2_000_000_000));
}

/// A temporary directory with its absolute path, for tests that need real paths.
const TestDir = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init() !TestDir {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buffer);
        return .{ .tmp = tmp, .path = try testing.allocator.dupe(u8, buffer[0..len]) };
    }

    fn deinit(t: *TestDir) void {
        testing.allocator.free(t.path);
        t.tmp.cleanup();
    }

    fn file(t: *TestDir, name: []const u8, executable: bool) !void {
        const permissions: Io.File.Permissions = if (native == .windows or !executable)
            .default_file
        else
            .executable_file;
        try t.tmp.dir.writeFile(testing.io, .{
            .sub_path = name,
            .data = "",
            .flags = .{ .permissions = permissions },
        });
    }

    /// A batch file `name` holding `lines` (Windows), and the argv that runs it; the
    /// Windows stand-in for `/bin/sh -c`. Freed with `testing.allocator`.
    fn batch(t: *TestDir, name: []const u8, lines: []const u8) ![]const []const u8 {
        const data = try std.mem.concat(testing.allocator, u8, &.{ "@echo off\r\n", lines });
        defer testing.allocator.free(data);
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        const argv = try testing.allocator.alloc([]const u8, 1);
        argv[0] = try dirs.join(testing.allocator, native, &.{ t.path, name });
        return argv;
    }

    fn freeArgv(argv: []const []const u8) void {
        for (argv) |arg| testing.allocator.free(arg);
        testing.allocator.free(argv);
    }
};

test "which searches PATH in order and skips non-executables, on Windows" {
    if (native != .windows) return error.SkipZigTest;
    var a = try TestDir.init();
    defer a.deinit();
    var b = try TestDir.init();
    defer b.deinit();
    var c = try TestDir.init();
    defer c.deinit();
    // Without a PATHEXT extension a file is not a program.
    try a.file("tool.txt", true);
    try b.file("tool.EXE", true);
    try c.file("tool.EXE", true);
    try a.tmp.dir.createDir(testing.io, "sub.EXE", .default_dir);

    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const path_var = try std.mem.join(testing.allocator, ";", &.{ "", a.path, b.path, c.path });
    defer testing.allocator.free(path_var);
    try env.put("PATH", path_var);
    try env.put("PATHEXT", ".COM;.EXE");

    const found = (try which(testing.allocator, testing.io, &env, .windows, "tool")).?;
    defer testing.allocator.free(found);
    const expected = try dirs.join(testing.allocator, .windows, &.{ b.path, "tool.EXE" });
    defer testing.allocator.free(expected);
    try testing.expect(std.ascii.eqlIgnoreCase(expected, found));
    try testing.expectEqual(null, try which(testing.allocator, testing.io, &env, .windows, "nope"));
    try testing.expectEqual(null, try which(testing.allocator, testing.io, &env, .windows, "sub"));
    const direct = (try which(testing.allocator, testing.io, &env, .windows, expected)).?;
    defer testing.allocator.free(direct);
    try testing.expect(std.ascii.eqlIgnoreCase(expected, direct));
}

test "which searches PATH in order and skips non-executables" {
    if (native == .windows) return error.SkipZigTest;
    var a = try TestDir.init();
    defer a.deinit();
    var b = try TestDir.init();
    defer b.deinit();
    try a.file("tool", false);
    try b.file("tool", true);
    const a_tool = try dirs.join(testing.allocator, .linux, &.{ a.path, "tool" });
    defer testing.allocator.free(a_tool);
    try a.tmp.dir.createDir(testing.io, "sub", .default_dir);

    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const path_var = try std.mem.join(testing.allocator, ":", &.{ "", a.path, b.path });
    defer testing.allocator.free(path_var);
    try env.put("PATH", path_var);

    // Some file systems (drvfs under WSL, FAT) report every file as executable.
    const modes_enforced = !try isProgram(testing.io, .linux, a_tool);
    const found = (try which(testing.allocator, testing.io, &env, .linux, "tool")).?;
    defer testing.allocator.free(found);
    const winner = if (modes_enforced) b.path else a.path;
    const expected = try dirs.join(testing.allocator, .linux, &.{ winner, "tool" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, found);

    try testing.expectEqual(null, try which(testing.allocator, testing.io, &env, .linux, "nope"));
    try testing.expectEqual(null, try which(testing.allocator, testing.io, &env, .linux, "sub"));
    const truncated = expected[0 .. expected.len - 1];
    const missing = try which(testing.allocator, testing.io, &env, .linux, truncated);
    try testing.expectEqual(null, missing);
    const direct = (try which(testing.allocator, testing.io, &env, .linux, expected)).?;
    defer testing.allocator.free(direct);
    try testing.expectEqualStrings(expected, direct);
}

test "which applies PATHEXT under Windows rules" {
    var a = try TestDir.init();
    defer a.deinit();
    try a.file("tool.CMD", true);
    try a.file("run.bat", true);
    try a.file("app.EXE", true);

    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    // A trailing `/` (a separator under Windows rules too) keeps the joined candidates
    // valid on a POSIX host, where `\\` is an ordinary byte.
    const entry = try std.mem.concat(testing.allocator, u8, &.{ a.path, "/" });
    defer testing.allocator.free(entry);
    try env.put("PATH", entry);
    try env.put("PATHEXT", ".EXE;.CMD");

    const found = (try which(testing.allocator, testing.io, &env, .windows, "tool")).?;
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, "tool.CMD"));
    // Already carrying a listed extension: tried as is, not as `app.EXE.EXE`.
    const exact = (try which(testing.allocator, testing.io, &env, .windows, "app.EXE")).?;
    defer testing.allocator.free(exact);
    try testing.expect(std.mem.endsWith(u8, exact, "app.EXE"));
    // `.bat` is not in this PATHEXT.
    try testing.expectEqual(null, try which(testing.allocator, testing.io, &env, .windows, "run"));
    try testing.expectEqual(null, try which(testing.allocator, testing.io, &env, .windows, "none"));
}

test "which without PATH finds nothing" {
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(null, try which(testing.allocator, testing.io, &env, .linux, "sh"));
}

test "capture collects output and status" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    var dir = try TestDir.init();
    defer dir.deinit();
    // `set /p` with no input prints its prompt without a line break, as `printf` does.
    const argv: []const []const u8 = if (native == .windows)
        try dir.batch("run.cmd", "<nul set /p =out\r\n1>&2 <nul set /p =err\r\nexit /b 3\r\n")
    else
        try testing.allocator.dupe([]const u8, &.{ "/bin/sh", "-c", "printf out; printf err >&2; exit 3" });
    defer if (native == .windows) TestDir.freeArgv(argv) else testing.allocator.free(argv);
    const output = try capture(testing.allocator, testing.io, argv, .{});
    defer output.deinit(testing.allocator);
    try testing.expectEqualStrings("out", output.stdout);
    try testing.expectEqualStrings("err", output.stderr);
    try testing.expectEqual(3, exitStatus(output.term));
    try testing.expect(!output.success());
}

test "capture honors cwd, environment, and limits" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    var dir = try TestDir.init();
    defer dir.deinit();
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("SNEK_TEST", "yes");
    if (native == .windows) {
        // cmd.exe needs its own system directory to run a batch file at all.
        const root = testing.environ.getAlloc(testing.allocator, "SystemRoot") catch
            return error.SkipZigTest;
        defer testing.allocator.free(root);
        try env.put("SystemRoot", root);
        const show = try dir.batch("show.cmd", "<nul set /p =%SNEK_TEST% \r\ncd\r\n");
        defer TestDir.freeArgv(show);
        const output = try capture(testing.allocator, testing.io, show, .{
            .cwd = dir.path,
            .environ = &env,
        });
        defer output.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, output.stdout, "yes "));
        try testing.expect(std.mem.indexOf(u8, output.stdout, dir.path) != null);
        try testing.expect(output.success());
        const long = try dir.batch("long.cmd", "<nul set /p =0123456789\r\n");
        defer TestDir.freeArgv(long);
        try testing.expectError(error.StreamTooLong, capture(testing.allocator, testing.io, long, .{
            .stdout_limit = .limited(4),
        }));
        return;
    }
    const output = try capture(testing.allocator, testing.io, &.{
        "/bin/sh", "-c", "printf \"$SNEK_TEST \"; pwd",
    }, .{ .cwd = dir.path, .environ = &env });
    defer output.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, output.stdout, "yes "));
    try testing.expect(output.success());

    try testing.expectError(error.StreamTooLong, capture(testing.allocator, testing.io, &.{
        "/bin/sh", "-c", "printf 0123456789",
    }, .{ .stdout_limit = .limited(4) }));
}

test "stream waits and reports the status" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const argv: []const []const u8 = if (native == .windows)
        &.{ "cmd.exe", "/c", "exit 7" }
    else
        &.{ "/bin/sh", "-c", "exit 7" };
    const term = try stream(testing.io, argv, .{});
    try testing.expectEqual(7, exitStatus(term));
}

test "capture under cmd.exe" {
    if (native != .windows) return error.SkipZigTest;
    const argv: []const []const u8 = &.{ "cmd.exe", "/c", "echo hi" };
    const output = try capture(testing.allocator, testing.io, argv, .{});
    defer output.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, output.stdout, "hi"));
}

test "capture of a missing program is FileNotFound" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    const absolute = if (native == .windows) "C:\\snek-no-such\\program.exe" else "/snek-no-such/p";
    try testing.expectError(error.FileNotFound, capture(gpa, testing.io, &.{absolute}, .{}));
    const bare: []const []const u8 = &.{"snek-no-such-program-anywhere"};
    try testing.expectError(error.FileNotFound, capture(gpa, testing.io, bare, .{}));
}

test "capture kills a child that outlives its timeout" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const io = testing.io;
    // On Windows one program, not a batch file: killing cmd.exe would leave its child
    // holding the output pipe open. `ping` writes a line, then waits a second per echo.
    const slow: []const []const u8 = if (native == .windows)
        &.{ "ping.exe", "-n", "6", "127.0.0.1" }
    else
        &.{ "/bin/sh", "-c", "printf partial; exec sleep 5" };
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, capture(testing.allocator, io, slow, .{
        .timeout = .fromMilliseconds(200),
    }));
    const elapsed = start.durationTo(Io.Clock.awake.now(io));
    try testing.expect(elapsed.nanoseconds < 4 * std.time.ns_per_s);

    const fast: []const []const u8 = if (native == .windows)
        &.{ "cmd.exe", "/c", "echo ok" }
    else
        &.{ "/bin/sh", "-c", "printf ok" };
    const quick = try capture(testing.allocator, io, fast, .{ .timeout = .fromSeconds(30) });
    defer quick.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", std.mem.trimEnd(u8, quick.stdout, "\r\n"));
}

test "editText round-trips through the editor and leaves nothing behind" {
    if (!std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    var dir = try TestDir.init();
    defer dir.deinit();
    try dir.tmp.dir.createDir(testing.io, "work", .default_dir);
    const work = try dirs.join(gpa, native, &.{ dir.path, "work" });
    defer gpa.free(work);
    // `echo` keeps the space after the one it drops, and ends the line with CRLF.
    const editor_argv: []const []const u8 = if (native == .windows) try dir.batch(
        "editor.cmd",
        "if /i not \"%~x1\"==\".md\" exit /b 1\r\n>>\"%~1\" echo  edited\r\n",
    ) else blk: {
        try dir.tmp.dir.writeFile(testing.io, .{
            .sub_path = "editor.sh",
            .data = "case \"$1\" in *.md) printf ' edited' >> \"$1\";; *) exit 1;; esac\n",
        });
        const argv = try gpa.alloc([]const u8, 2);
        argv[0] = try gpa.dupe(u8, "/bin/sh");
        argv[1] = try dirs.join(gpa, native, &.{ dir.path, "editor.sh" });
        break :blk argv;
    };
    defer TestDir.freeArgv(editor_argv);
    const command = try std.mem.join(gpa, " ", editor_argv);
    defer gpa.free(command);
    var env: Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("EDITOR", command);

    const text = try editText(gpa, testing.io, &env, "draft", .{ .suffix = ".md", .dir = work });
    defer gpa.free(text);
    try testing.expectEqualStrings("draft edited", std.mem.trimEnd(u8, text, "\r\n"));
    // The script fails for any other suffix: the edit is abandoned.
    try testing.expectError(
        error.EditorFailed,
        editText(gpa, testing.io, &env, "draft", .{ .dir = work }),
    );
    var work_dir = try dir.tmp.dir.openDir(testing.io, "work", .{ .iterate = true });
    defer work_dir.close(testing.io);
    var it = work_dir.iterate();
    try testing.expectEqual(null, try it.next(testing.io));
}
