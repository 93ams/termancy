//! Running an application inside a test: in-memory output, a chosen environment, and the
//! exit status, with nothing read from or written to the real process.
//!
//! ```zig
//! test "serve uses PORT" {
//!     const app: cli.App = .{ .root = &root };
//!     const result = try cli.testing.run(app, &.{"serve"}, .{ .env = &.{.{ "PORT", "9" }} });
//!     defer result.deinit();
//!     try result.expect(0, "listening on 9\n", "");
//! }
//! ```
//!
//! Memory comes from `std.testing.allocator`, so a leak in a handler fails the test. Only
//! call this from tests.

const std = @import("std");
const sets = @import("sets.zig");
const field = @import("field");
const App = @import("App.zig");

/// How `run` runs the application.
pub const Options = struct {
    /// The whole environment the application sees, as name/value pairs.
    env: []const [2][]const u8 = &.{},
    /// Standard input. When set, the run is interactive, as at a terminal: required flags
    /// with a `.prompt` are asked for, the question going to standard error.
    stdin: ?[]const u8 = null,
    /// The working directory for the run, such as a `std.testing.tmpDir`'s: the process's
    /// own is changed to it and back, so relative paths in handlers resolve inside it.
    cwd: ?std.Io.Dir = null,
};

/// What a run printed and returned. Free it with `deinit`.
pub const Run = struct {
    status: u8,
    /// Everything written to standard output.
    out: []u8,
    /// Everything written to standard error.
    err: []u8,

    /// Frees what the run printed.
    pub fn deinit(r: Run) void {
        std.testing.allocator.free(r.out);
        std.testing.allocator.free(r.err);
    }

    /// Fails unless the run printed exactly `out` and `err` and exited with `status`.
    /// Standard error is compared first: when a run fails unexpectedly, the message there
    /// says why.
    pub fn expect(r: Run, status: u8, out: []const u8, err: []const u8) !void {
        try std.testing.expectEqualStrings(err, r.err);
        try std.testing.expectEqualStrings(out, r.out);
        try std.testing.expectEqual(status, r.status);
    }
};

/// Executes `app` with `args` (without the program name), as `App.execute` would with
/// real streams.
pub fn run(app: App, args: []const []const u8, options: Options) !Run {
    const gpa = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    for (options.env) |pair| try environ.put(pair[0], pair[1]);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var in: std.Io.Reader = .fixed(options.stdin orelse "");
    const io = std.testing.io;
    const saved = if (options.cwd) |dir| saved: {
        const here = try std.Io.Dir.cwd().openDir(io, ".", .{});
        errdefer here.close(io);
        try std.process.setCurrentDir(io, dir);
        break :saved here;
    } else null;
    defer if (saved) |here| {
        std.process.setCurrentDir(io, here) catch @panic("cli.testing: cannot change back");
        here.close(io);
    };
    const status = app.execute(.{
        .io = io,
        .gpa = gpa,
        .environ = &environ,
        .out = &out.writer,
        .err = &err.writer,
        .in = if (options.stdin != null) &in else null,
        .interactive = options.stdin != null,
    }, args);
    const out_text = try out.toOwnedSlice();
    errdefer gpa.free(out_text);
    return .{ .status = status, .out = out_text, .err = try err.toOwnedSlice() };
}

const spec = @import("spec.zig");
const Context = @import("Context.zig");

const ServeFlags = struct {
    port: u16 = 8080,
};
const serve_flags = sets.flags(ServeFlags, field.none, .{ .fields = .{
    .port = .{ .env = "PORT" },
} });

fn serve(ctx: *Context, flags: ServeFlags) !void {
    try ctx.out.print("listening on {d}\n", .{flags.port});
}

const root = spec.command(.{
    .name = "app",
    .subcommands = .{spec.command(.{ .name = "serve", .flags = serve_flags, .run = serve })},
});

test run {
    const app: App = .{ .root = &root };
    const result = try run(app, &.{"serve"}, .{ .env = &.{.{ "PORT", "9" }} });
    defer result.deinit();
    try result.expect(0, "listening on 9\n", "");

    const usage = try run(app, &.{ "serve", "--prot", "1" }, .{});
    defer usage.deinit();
    try std.testing.expectEqual(2, usage.status);
    try std.testing.expect(std.mem.indexOf(u8, usage.err, "--port") != null);
}

test "the environment is only what the options give" {
    const app: App = .{ .root = &root };
    const result = try run(app, &.{"serve"}, .{});
    defer result.deinit();
    try result.expect(0, "listening on 8080\n", "");
}

fn readHere(ctx: *Context) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "here.txt", ctx.arena, .limited(64));
    try ctx.out.writeAll(text);
}

test "cwd runs the application in a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "here.txt", .data = "inside\n" });
    const reader = comptime spec.command(.{ .name = "app", .run = readHere });
    const result = try run(.{ .root = &reader }, &.{}, .{ .cwd = tmp.dir });
    defer result.deinit();
    try result.expect(0, "inside\n", "");
    const back = std.Io.Dir.cwd().access(std.testing.io, "here.txt", .{});
    try std.testing.expectError(error.FileNotFound, back);
}
