//! Running a command tree as an interactive shell: read a line, run it as a command line
//! (`App.executeLine`), repeat until `exit`, `quit`, or the end of input.
//!
//! ```zig
//! const status = cli.repl.run(app, env, .{ .prompt = "app> " });
//! ```
//!
//! The default reader takes plain lines from `env.in`, so a script can be piped in. For
//! editing, history, and tab completion, give `read_line` a line editor (such as the `tui`
//! component `snek tui add shell` copies into a project): it gets the `Repl`, whose
//! `history` it can offer and whose `complete` answers the tab key from the same command
//! tree the shell scripts complete from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const App = @import("App.zig");
const shell = @import("shell.zig");

/// How the shell prompts and what it runs.
pub const Options = struct {
    /// Written before each line, to `env.err`, when the run is interactive.
    prompt: []const u8 = "> ",
    /// Reads the next line, without its line break; null at the end of input. The default
    /// reads one line from `env.in`.
    read_line: ?*const fn (repl: *Repl) anyerror!?[]const u8 = null,
    /// Lines that end the shell.
    exit_words: []const []const u8 = &.{ "exit", "quit" },
    /// The most lines kept in `history`.
    history_limit: usize = 1000,
    /// Subcommand names below the root that every line runs under, for a shell on a
    /// group: with `&.{"db"}`, the line `migrate` runs `db migrate` (see
    /// `App.executeLineIn`).
    path: []const []const u8 = &.{},
};

/// The running shell, as `read_line` sees it.
pub const Repl = struct {
    app: App,
    env: App.Environment,
    options: Options,
    /// Earlier lines, oldest first, without repeats of the line before.
    history: std.ArrayList([]const u8) = .empty,
    /// The status of the last line run.
    status: u8 = 0,

    /// The completions of the last word of `line` (empty after a space), as the shell
    /// scripts would get them: each a value without description. In `arena`.
    pub fn complete(repl: *Repl, arena: Allocator, line: []const u8) ![]const []const u8 {
        var words: std.ArrayList([]const u8) = .empty;
        try words.appendSlice(arena, shell.tokenize(arena, line) catch return &.{});
        // A line ending in a space is completing a new, empty word.
        if (line.len == 0 or line[line.len - 1] == ' ') try words.append(arena, "");
        var out: Io.Writer.Allocating = .init(arena);
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(arena, "__complete");
        try args.appendSlice(arena, repl.options.path);
        try args.appendSlice(arena, words.items);
        _ = repl.app.execute(.{
            .io = repl.env.io,
            .gpa = repl.env.gpa,
            .environ = repl.env.environ,
            .out = &out.writer,
            .err = &out.writer,
        }, args.items);
        var candidates: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, out.written(), '\n');
        while (lines.next()) |candidate_line| {
            if (candidate_line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, candidate_line, '\t');
            try candidates.append(arena, candidate_line[0 .. tab orelse candidate_line.len]);
        }
        return candidates.items;
    }

    fn remember(repl: *Repl, line: []const u8) Allocator.Error!void {
        const items = repl.history.items;
        if (items.len > 0 and std.mem.eql(u8, items[items.len - 1], line)) return;
        if (items.len >= repl.options.history_limit and items.len > 0) {
            repl.env.gpa.free(repl.history.orderedRemove(0));
        }
        try repl.history.append(repl.env.gpa, try repl.env.gpa.dupe(u8, line));
    }

    fn deinit(repl: *Repl) void {
        for (repl.history.items) |line| repl.env.gpa.free(line);
        repl.history.deinit(repl.env.gpa);
    }
};

/// Runs the shell until an exit word or the end of input, and returns the status of the
/// last line run (0 when none ran).
pub fn run(app: App, env: App.Environment, options: Options) u8 {
    var repl: Repl = .{ .app = app, .env = env, .options = options };
    defer repl.deinit();
    while (true) {
        const read = options.read_line orelse readLine;
        const line_or_null = read(&repl) catch |err| {
            app.theme.writePrefix(env.err, env.err_color, app.displayName(), .@"error") catch {};
            env.err.print("{s}\n", .{@errorName(err)}) catch {};
            return App.exit_failure;
        };
        const line = std.mem.trim(u8, line_or_null orelse break, " \t\r");
        if (line.len == 0) continue;
        if (isExit(options, line)) break;
        repl.remember(line) catch {};
        repl.status = app.executeLineIn(env, options.path, line);
        env.out.flush() catch {};
        env.err.flush() catch {};
    }
    return repl.status;
}

fn isExit(options: Options, line: []const u8) bool {
    for (options.exit_words) |word| if (std.mem.eql(u8, word, line)) return true;
    return false;
}

/// The default reader: the prompt (when interactive), then one line from `env.in`.
fn readLine(repl: *Repl) anyerror!?[]const u8 {
    const in = repl.env.in orelse return null;
    if (repl.env.interactive) {
        try repl.env.err.writeAll(repl.options.prompt);
        try repl.env.err.flush();
    }
    return in.takeDelimiter('\n');
}

const testing = std.testing;
const spec = @import("spec.zig");
const Context = @import("Context.zig");

const Count = struct {
    n: u8 = 1,
};

fn hello(ctx: *Context, flags: Count) !void {
    const name = if (ctx.args.len > 0) ctx.args[0] else "you";
    for (0..flags.n) |_| try ctx.out.print("hello {s}\n", .{name});
}

fn fail(ctx: *Context) !void {
    return ctx.fail("no", .{});
}

const root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{ .name = "hello", .flags = Count, .args = .{ .max = 1 }, .run = hello }),
        spec.command(.{ .name = "fail", .run = fail }),
    },
});

fn runScript(script: []const u8, out: *Io.Writer.Allocating, err: *Io.Writer.Allocating) u8 {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var in: Io.Reader = .fixed(script);
    const app: App = .{ .root = &root };
    return run(app, .{
        .io = testing.io,
        .gpa = testing.allocator,
        .environ = &environ,
        .out = &out.writer,
        .err = &err.writer,
        .in = &in,
    }, .{});
}

test "a piped script runs line by line and stops at exit" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const script = "hello\n\n  hello 'big world' --n 2  \nfail\nexit\nhello\n";
    const status = runScript(script, &out, &err);
    try testing.expectEqual(1, status);
    try testing.expectEqualStrings("hello you\nhello big world\nhello big world\n", out.written());
    try testing.expectEqualStrings("app: no\n", err.written());
}

test "the end of input ends the shell with the last status" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    try testing.expectEqual(2, runScript("hello --nope", &out, &err));
    try testing.expect(std.mem.startsWith(u8, err.written(), "app: unknown flag: --nope\n"));
}

test "complete answers from the command tree" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var sink: Io.Writer.Discarding = .init(&.{});
    var repl: Repl = .{
        .app = .{ .root = &root },
        .env = .{
            .io = testing.io,
            .gpa = testing.allocator,
            .environ = &environ,
            .out = &sink.writer,
            .err = &sink.writer,
        },
        .options = .{},
    };
    defer repl.deinit();
    const a = arena.allocator();
    const first = try repl.complete(a, "he");
    try testing.expectEqual(2, first.len);
    try testing.expectEqualStrings("hello", first[0]);
    try testing.expectEqualStrings("help", first[1]);
    const flags = try repl.complete(a, "hello --");
    try testing.expectEqualStrings("--n", flags[0]);
    try testing.expectEqual(0, (try repl.complete(a, "hello x ")).len);

    try repl.remember("a");
    try repl.remember("a");
    try repl.remember("b");
    try testing.expectEqual(2, repl.history.items.len);
}
