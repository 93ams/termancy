//! Running a child process, the two ways a CLI actually needs it.
//!
//! There are exactly two shapes of "run a program" in an operator tool:
//!
//!   * **Capture** - run it, take its stdout and stderr, look at the exit status.
//!     This is `capture`.
//!   * **Stream** - run it and let it own the terminal, so a pager, an editor or a
//!     progress-aware child behaves exactly as it would from a shell. This is
//!     `stream`.
//!
//! ## Why this is thin
//!
//! `std.process.run` already does the hard part correctly: it reads stdout and
//! stderr **concurrently** through a `MultiReader`, so a child that writes more
//! than a pipe buffer to the stream nobody is reading cannot deadlock, and it
//! accepts a timeout and per-stream byte limits. Reimplementing that loop here
//! would be a second, worse copy of it. What this module adds is the part the
//! standard library deliberately leaves to the caller: a millisecond timeout, a
//! bounded output budget, and an exit status with the obvious predicates on it.
//!
//! ## Bounded by construction
//!
//! `max_output_bytes` is not optional. An unbounded capture is how a wrapper turns
//! `yes` into an out-of-memory kill, and this tree has already paid for that class
//! of bug once (`AGENTS.md` 5.2, "bound every loop and queue").

const std = @import("std");
const assert = std.debug.assert;

/// The error set of `capture`, which is `std.process.run`'s plus allocation.
///
/// Kept as the standard library's rather than translated into a narrower set: a
/// caller distinguishing "the program does not exist" (`FileNotFound`) from "it ran
/// and failed" needs the underlying error, and a wrapper that collapsed them into
/// one `SpawnFailed` would be hiding the more useful of the two.
pub const Error = std.process.RunError || error{OutOfMemory};

/// What a captured child produced.
pub const Output = struct {
    /// How the child ended.
    term: std.process.Child.Term,
    /// The child's standard output. Owned by the caller's allocator.
    stdout: []u8,
    /// The child's standard error. Owned by the caller's allocator.
    stderr: []u8,
    allocator: std.mem.Allocator,

    /// Frees both streams. Safe to call exactly once.
    pub fn deinit(self: *Output) void {
        assert(self.stdout.len <= std.math.maxInt(u32));
        assert(self.stderr.len <= std.math.maxInt(u32));

        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }

    /// `true` when the child exited normally with status 0.
    ///
    /// A signal or a stop is **not** success, which is the distinction a bare
    /// `term == .exited` test gets wrong.
    pub fn succeeded(self: Output) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    /// The exit status, or null when the child did not exit normally.
    pub fn exitCode(self: Output) ?u8 {
        return switch (self.term) {
            .exited => |code| code,
            else => null,
        };
    }

    /// Returns `error.ChildFailed` unless the child exited with status 0.
    ///
    /// The message the child printed is the caller's to render: this returns an
    /// error rather than printing, so a library never writes to a terminal it was
    /// not asked to write to.
    pub fn expectSuccess(self: Output) error{ChildFailed}!void {
        if (!self.succeeded()) return error.ChildFailed;
    }
};

/// Options for `capture`.
pub const CaptureOptions = struct {
    /// Working directory for the child. `.inherit` keeps the parent's.
    cwd: std.process.Child.Cwd = .inherit,
    /// Replaces the child's environment when set. Note that `argv[0]` is still
    /// resolved against the **parent's** `PATH`, so a replacement map that drops
    /// `PATH` does not stop the program from being found.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Kills the child and returns `error.Timeout` after this many milliseconds.
    /// `null` waits indefinitely.
    timeout_ms: ?u64 = null,
    /// The most bytes retained from **each** stream. Exceeding it returns
    /// `error.StreamTooLong` rather than truncating, because a truncated parse
    /// succeeds on garbage.
    max_output_bytes: u64 = 8 * 1024 * 1024,
};

/// Runs `argv` and collects its output.
///
/// `stdin` is closed for the child: a captured run is not an interactive one, and
/// leaving it inherited lets a child consume the parent's terminal input.
pub fn capture(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    options: CaptureOptions,
) Error!Output {
    assert(argv.len >= 1);
    assert(argv[0].len > 0);
    assert(options.max_output_bytes > 0);

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .timeout = timeoutFromMs(options.timeout_ms),
        .stdout_limit = std.Io.Limit.limited64(options.max_output_bytes),
        .stderr_limit = std.Io.Limit.limited64(options.max_output_bytes),
    });

    // Ownership of both slices transfers straight through; nothing is copied and
    // nothing is freed on the success path.
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .allocator = allocator,
    };
}

/// Runs `argv` with the parent's streams, so the child owns the terminal.
///
/// Use this for a pager or an editor. The returned `Term` is the child's, because
/// a streamed run exists to reproduce the child's exit status.
pub fn stream(
    io: std.Io,
    argv: []const []const u8,
    options: StreamOptions,
) (std.process.SpawnError || std.process.Child.WaitError)!std.process.Child.Term {
    assert(argv.len >= 1);
    assert(argv[0].len > 0);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        // All three inherited, which is also `SpawnOptions`' default. Stated
        // explicitly because the whole point of this function is where the
        // streams go, so leaving it implicit would hide the decision.
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = false,
    });
    defer child.kill(io);
    return child.wait(io);
}

/// Options for `stream`. A timeout is absent on purpose: an interactive child is
/// expected to run until the user is finished with it.
pub const StreamOptions = struct {
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
};

/// Translates a millisecond budget into the `Io.Timeout` the standard library
/// takes. Zig's timeout is a clock reading, not a count, so the conversion is the
/// only place milliseconds appear.
fn timeoutFromMs(ms: ?u64) std.Io.Timeout {
    const value = ms orelse return .none;
    // `Io.Duration.fromMilliseconds` is signed. A millisecond budget that does not
    // fit in an `i64` is roughly 292 million years, so saturating there is not a
    // behaviour anyone can observe - and it is strictly better than letting a
    // library panic on an absurd argument.
    const clamped: i64 = @intCast(@min(value, std.math.maxInt(i64)));
    return .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(clamped),
        .clock = .awake,
    } };
}

const testing = std.testing;

/// A program every supported host has, used so the tests exercise a real spawn
/// rather than a mock. `zig` itself is guaranteed present: the build that runs
/// these tests is the one it ships with.
const self_exe = "zig";

test "capture collects both streams and the exit status separately" {
    const io = testing.io;
    var out = try capture(testing.allocator, io, &.{ self_exe, "version" }, .{});
    defer out.deinit();

    try testing.expect(out.succeeded());
    try testing.expectEqual(@as(?u8, 0), out.exitCode());
    // `zig version` prints a semver and nothing else.
    try testing.expect(std.mem.indexOfScalar(u8, out.stdout, '.') != null);
    try testing.expectEqualStrings("", out.stderr);
}

test "a non-zero exit is not success, and expectSuccess says so" {
    const io = testing.io;
    // `zig build --nonexistent-flag` is a usage error: it exits non-zero and
    // explains itself on stderr. Using zig keeps this test independent of any
    // shell builtin that might behave differently per platform.
    var out = try capture(testing.allocator, io, &.{
        self_exe,
        "build",
        "--definitely-not-a-flag",
    }, .{});
    defer out.deinit();

    try testing.expect(!out.succeeded());
    try testing.expect(out.exitCode() != null);
    try testing.expect(out.exitCode().? != 0);
    try testing.expectError(error.ChildFailed, out.expectSuccess());
    // The diagnosis must survive capture; that is the point of keeping stderr.
    try testing.expect(out.stderr.len > 0 or out.stdout.len > 0);
}

test "a spawn failure surfaces as the standard library's error, not a lost one" {
    const io = testing.io;
    try testing.expectError(error.FileNotFound, capture(
        testing.allocator,
        io,
        &.{"snek-no-such-program-exists-anywhere"},
        .{},
    ));
}

test "an exceeding output budget is an error rather than a silent truncation" {
    const io = testing.io;
    // `zig version` is a handful of bytes, so a 4-byte budget must trip the limit.
    try testing.expectError(error.StreamTooLong, capture(
        testing.allocator,
        io,
        &.{ self_exe, "version" },
        .{ .max_output_bytes = 4 },
    ));
}

test "the millisecond conversion is exact, and null means no timeout" {
    try testing.expect(timeoutFromMs(null) == .none);

    const converted = timeoutFromMs(1500);
    try testing.expect(converted == .duration);
    try testing.expectEqual(
        std.Io.Duration.fromMilliseconds(1500),
        converted.duration.raw,
    );
    try testing.expectEqual(std.Io.Clock.awake, converted.duration.clock);
}
