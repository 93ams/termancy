//! A key-value store kept in the user's data directory, to show what an app gets around its
//! commands:
//!
//! - `kv shell`: the commands as an interactive shell (`cli.repl`). At a terminal, lines
//!   are edited with the `shell` component: history on up and down, and tab completion
//!   from the same tree the shell scripts complete from, keys included. Piped, it runs a
//!   script;
//! - completion of values from the data (`kv get <tab>` offers the stored keys), and
//!   `kv completion install` to set it up;
//! - plugins: any `kv-<name>` program on `PATH` runs as `kv <name>`, as git runs `git-*`;
//! - `kv docs`: the reference as Markdown, man, HTML, or JSON for tools and LLMs;
//! - long help through the pager, `-o json` for `list`, a confirmation for `del`;
//! - `sys`: the data directory (`$XDG_DATA_HOME/kv`, `~/Library/Application Support/kv`,
//!   `%LOCALAPPDATA%\kv`), and a private store whose writes are atomic.
//!
//!     zig build examples
//!     zig-out/bin/kv set greeting hello
//!     zig-out/bin/kv shell
//!     printf 'set a 1\nget a\nlist\n' | zig-out/bin/kv shell
//!     zig-out/bin/kv docs --format man | man -l -

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const sys = @import("sys");
const components = @import("components");

const Global = struct {
    store: ?[]const u8 = null,
    pub const meta = .{
        .store = .{ .env = "KV_STORE", .help = "Where the keys are kept (default: the data dir)" },
    };
};

const Store = sys.files.Store;

/// The store's directory: `--store`, else the platform's data directory for `kv`.
fn storePath(ctx: *cli.Context) ![]const u8 {
    const global = try ctx.flags(Global);
    if (global.store) |dir| return dir;
    return sys.dirs.nativePath(ctx.arena, ctx.environ, .data, "kv") catch |err|
        ctx.fail("no data directory ({t}); pass --store", .{err});
}

fn openStore(ctx: *cli.Context) !Store {
    const dir = try storePath(ctx);
    return Store.open(ctx.io, .cwd(), dir) catch |err| ctx.fail("{s}: {t}", .{ dir, err });
}

const Entry = struct { key: []const u8, value: []const u8 };

/// Every entry, sorted by key.
fn entries(ctx: *cli.Context) ![]Entry {
    const store = try openStore(ctx);
    defer store.close(ctx.io);
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, try storePath(ctx), .{ .iterate = true });
    defer dir.close(ctx.io);
    var found: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file or !Store.isValidName(entry.name)) continue;
        const limit: std.Io.Limit = .limited(1 << 20);
        const value = try store.read(ctx.io, ctx.arena, entry.name, limit) orelse continue;
        try found.append(ctx.arena, .{ .key = try ctx.arena.dupe(u8, entry.name), .value = value });
    }
    std.mem.sortUnstable(Entry, found.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);
    return found.items;
}

/// The stored keys, for completion: `kv get <tab>`.
fn completeKey(ctx: *cli.Context, prefix: []const u8) ![]const cli.Candidate {
    var out: std.ArrayList(cli.Candidate) = .empty;
    for (entries(ctx) catch return &.{}) |entry| {
        if (!std.mem.startsWith(u8, entry.key, prefix)) continue;
        try out.append(ctx.arena, .{ .value = entry.key, .description = entry.value });
    }
    return out.items;
}

const SetArgs = struct {
    key: []const u8,
    value: []const u8,
    pub const meta = .{ .key = .{ .complete = completeKey } };
};

fn set(ctx: *cli.Context, args: SetArgs) !void {
    if (!Store.isValidName(args.key)) return ctx.usageError("\"{s}\" cannot be a key", .{args.key});
    const store = try openStore(ctx);
    defer store.close(ctx.io);
    try store.write(ctx.io, args.key, args.value);
}

const GetArgs = struct {
    key: []const u8,
    pub const meta = .{ .key = .{ .complete = completeKey } };
};

fn get(ctx: *cli.Context, args: GetArgs) !void {
    if (!Store.isValidName(args.key)) return ctx.usageError("\"{s}\" cannot be a key", .{args.key});
    const store = try openStore(ctx);
    defer store.close(ctx.io);
    const value = try store.read(ctx.io, ctx.arena, args.key, .limited(1 << 20)) orelse
        return ctx.fail("no key \"{s}\"", .{args.key});
    try ctx.out.print("{s}\n", .{value});
}

const DelArgs = struct {
    keys: []const []const u8,
    pub const meta = .{ .keys = .{ .name = "key", .complete = completeKey } };
};

fn del(ctx: *cli.Context, args: DelArgs) !void {
    const store = try openStore(ctx);
    defer store.close(ctx.io);
    for (args.keys) |key| {
        store.delete(ctx.io, key) catch |err| return ctx.fail("{s}: {t}", .{ key, err });
    }
}

fn list(ctx: *cli.Context) !void {
    try ctx.render(@as([]const Entry, try entries(ctx)));
}

/// The line editor, at a terminal: the `shell` component run once per line.
const Editor = struct {
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    terminal: tui.Terminal,
    /// The last line read, owned.
    line: []u8 = &.{},

    fn readLine(repl: *cli.repl.Repl) anyerror!?[]const u8 {
        const editor: *Editor = @ptrCast(@alignCast(repl.app.data.?));
        var editing: components.shell.Shell = .{
            .input = .{ .gpa = editor.gpa, .prompt = "kv> " },
            .history = repl.history.items,
            .completer = .{ .context = repl, .function = complete },
        };
        const capability = editor.terminal.capabilityIn(editor.environ);
        const options: tui.Options = .{ .capability = capability };
        defer editing.deinit();
        var program: tui.Program(components.shell.Shell) =
            .init(editor.gpa, &editing, editor.terminal.writer(), options);
        defer program.deinit();
        const outcome = try program.run(&editor.terminal);
        if (outcome.interrupted or editing.status != .submitted) return null;
        editor.gpa.free(editor.line);
        editor.line = try editor.gpa.dupe(u8, editing.value());
        return editor.line;
    }

    fn complete(
        context: *anyopaque,
        arena: std.mem.Allocator,
        line: []const u8,
    ) ![]const []const u8 {
        const repl: *cli.repl.Repl = @ptrCast(@alignCast(context));
        return repl.complete(arena, line);
    }
};

fn shell(ctx: *cli.Context) !void {
    var buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(ctx.io, &buffer);
    const env: cli.App.Environment = .{
        .io = ctx.io,
        .gpa = ctx.gpa,
        .environ = ctx.environ,
        .out = ctx.out,
        .err = ctx.err,
        .in = ctx.in orelse &stdin.interface,
        .interactive = ctx.interactive,
        .terminal = ctx.terminal,
    };
    var shell_app = app;
    var options: cli.repl.Options = .{ .prompt = "kv> " };
    // A real terminal gets the line editor; a script piped in is read line by line.
    var editor: ?Editor = null;
    if (ctx.terminal != null) {
        var terminal_buffer: [4096]u8 = undefined;
        if (tui.Terminal.open(ctx.io, &terminal_buffer)) |terminal| {
            editor = .{ .gpa = ctx.gpa, .environ = ctx.environ, .terminal = terminal };
            shell_app.data = &editor.?;
            options.read_line = Editor.readLine;
        } else |_| {}
    }
    defer if (editor) |*e| {
        e.terminal.close();
        e.gpa.free(e.line);
    };
    const status = cli.repl.run(shell_app, env, options);
    if (status != 0) return ctx.exit(status);
}

const DocsFlags = struct {
    format: cli.docs.Format = .markdown,
    pub const meta = .{ .format = .{ .short = 'f', .help = "What to write" } };
};

fn docs(ctx: *cli.Context, flags: DocsFlags) !void {
    try cli.docs.write(ctx.out, &root, flags.format, .{});
}

pub const root = cli.command(.{
    .name = "kv",
    .summary = "Keep small values under names",
    .persistent_flags = Global,
    .subcommands = .{
        cli.command(.{ .name = "set", .summary = "Store a value", .args = SetArgs, .run = set }),
        cli.command(.{ .name = "get", .summary = "Print a value", .args = GetArgs, .run = get }),
        cli.command(.{
            .name = "del",
            .aliases = &.{"rm"},
            .summary = "Delete keys",
            .args = DelArgs,
            .confirm = "Delete these keys?",
            .run = del,
        }),
        cli.command(.{
            .name = "list",
            .aliases = &.{"ls"},
            .summary = "List the keys and values",
            .output = true,
            .run = list,
        }),
        cli.command(.{
            .name = "shell",
            .summary = "Run kv commands from an interactive shell",
            .description =
            \\Read command lines and run each as kv would, without the leading "kv". Up and
            \\down walk the history, tab completes commands, flags, and keys. "exit", "quit",
            \\or ctrl+d ends the shell. A script can be piped in.
            ,
            .group = "Tools",
            .run = shell,
        }),
        cli.command(.{
            .name = "docs",
            .summary = "Print the reference documentation",
            .group = "Tools",
            .flags = DocsFlags,
            .run = docs,
        }),
    },
});

const app: cli.App = .{
    .root = &root,
    .version = "1.0.0",
    .plugins = "kv-",
    .pager = true,
};

pub fn main(init: std.process.Init) u8 {
    return app.run(init);
}

const testing = std.testing;

fn expectRun(
    args: []const []const u8,
    options: cli.testing.Options,
    status: u8,
    out: []const u8,
) !void {
    const result = try cli.testing.run(app, args, options);
    defer result.deinit();
    testing.expectEqual(status, result.status) catch |err| {
        std.debug.print("{s}", .{result.err});
        return err;
    };
    try testing.expectEqualStrings(out, result.out);
}

test "set, get, list, complete, and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const env: []const [2][]const u8 = &.{.{ "KV_STORE", dir }};
    try expectRun(&.{ "set", "greeting", "hello" }, .{ .env = env }, 0, "");
    try expectRun(&.{ "set", "name", "ada" }, .{ .env = env }, 0, "");
    try expectRun(&.{ "get", "name" }, .{ .env = env }, 0, "ada\n");
    try expectRun(&.{ "get", "nope" }, .{ .env = env }, 1, "");
    try expectRun(&.{ "set", "../x", "1" }, .{ .env = env }, 2, ""); // stays in the store
    try expectRun(&.{"ls"}, .{ .env = env }, 0,
        \\KEY       VALUE
        \\greeting  hello
        \\name      ada
        \\
    );
    try expectRun(&.{ "__complete", "get", "gr" }, .{ .env = env }, 0, "greeting\thello\n");
    try expectRun(&.{ "del", "name" }, .{ .env = env }, 1, ""); // not confirmed
    try expectRun(&.{ "del", "name", "-y" }, .{ .env = env }, 0, "");
    try expectRun(&.{ "list", "-o", "json" }, .{ .env = env }, 0,
        \\[
        \\  {
        \\    "key": "greeting",
        \\    "value": "hello"
        \\  }
        \\]
        \\
    );
}

test "a script through the shell" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try expectRun(&.{"shell"}, .{
        .env = &.{.{ "KV_STORE", dir }},
        .stdin = "set a 1\nget a\nget b\nquit\nget a\n",
    }, 1, "1\n");
}

test "the reference, in every format" {
    inline for (@typeInfo(cli.docs.Format).@"enum".field_names) |format| {
        const result = try cli.testing.run(app, &.{ "docs", "--format", format }, .{});
        defer result.deinit();
        try testing.expectEqual(0, result.status);
        const summary = "Keep small values under names";
        try testing.expect(std.mem.indexOf(u8, result.out, summary) != null);
    }
}

test "a kv-<name> program on PATH runs as kv <name>" {
    const windows = @import("builtin").os.tag == .windows;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = if (windows) "kv-hello.cmd" else "kv-hello",
        .data = if (windows)
            "@echo hello from a plugin: %*\r\n"
        else
            "#!/bin/sh\necho \"hello from a plugin: $*\"\n",
        .flags = .{ .permissions = .executable_file },
    });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = if (windows)
        try testing.allocator.dupe(u8, dir)
    else
        try std.fmt.allocPrint(testing.allocator, "{s}:/bin:/usr/bin", .{dir});
    defer testing.allocator.free(path);
    const help = try cli.testing.run(app, &.{"--help"}, .{ .env = &.{.{ "PATH", path }} });
    defer help.deinit();
    try testing.expect(std.mem.indexOf(u8, help.out, "Plugins:") != null);
}
