//! `termancy md`: read Markdown in the terminal, as glow: a file, standard input, a URL, a
//! GitHub or GitLab repository's README, or every Markdown file under a directory to pick
//! from. Rendered by `term.markdown` (glamour's style sheets, highlighted code); read in a
//! full-screen reader at a terminal, printed otherwise.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const sys = @import("sys");
const term = @import("ui/term.zig");
const registry = @import("tui/registry/root.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const markdown = tui.term.markdown;

const Flags = struct {
    style: []const u8 = "auto",
    width: ?u16 = null,
    pager: bool = false,
    print: bool = false,
    all: bool = false,
    hyperlinks: bool = true,
    preserve_newlines: bool = false,
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .style = .{ .help = "dark, light, auto, notty, ascii, dracula, " ++
        "tokyo-night, pink, or a JSON style sheet" },
    .width = .{ .help = "Columns to wrap to (default: the terminal's, at " ++
        "most 120)" },
    .pager = .{ .help = "Show it through $PAGER instead of the reader" },
    .print = .{ .help = "Print it, even at a terminal" },
    .all = .{ .help = "Also list hidden files and directories" },
    .hyperlinks = .{ .help = "Make links clickable where the terminal can" },
    .preserve_newlines = .{ .help = "Keep the line breaks inside paragraphs" },
} }}), .{ .fields = .{
    .style = .{ .short = 's', .env = "GLAMOUR_STYLE" },
    .width = .{ .short = 'w' },
    .pager = .{ .short = 'p' },
    .all = .{ .short = 'a' },
} });

pub const command = cli.command(.{
    .name = "md",
    .summary = "Read Markdown in the terminal: a file, a URL, a repository's README",
    .description =
    \\Render Markdown, as glow does. The source is a file, - for standard input, an
    \\http(s) URL, a repository (github.com/owner/repo or gitlab.com/owner/repo, for its
    \\README), or a directory (the current one by default), whose Markdown files are listed
    \\to choose from. At a terminal the document opens in a reader: j/k and the arrows
    \\scroll, g/G go to the ends, e edits the file in $EDITOR, r reloads it, c copies the
    \\source to the clipboard, esc goes back to the list, q quits. Elsewhere (or with
    \\--print) it is printed, without colors where they would not show.
    ,
    .args = .{ .max = 1, .usage = "[source]" },
    .flags = flags_flags,
    .examples =
    \\termancy md README.md
    \\termancy md github.com/ziglang/zig
    \\termancy md -s light -w 70 CHANGELOG.md
    \\curl -s https://example.com/notes.md | termancy md -
    \\termancy md docs/
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const source_arg = if (ctx.args.len > 0) ctx.args[0] else ".";
    const stdout = Io.File.stdout();
    const at_terminal = try stdout.isTty(ctx.io);
    const color = try term.stdoutColor(ctx);
    const columns = cli.terminal.width(ctx.io, stdout) orelse 80;
    var options: markdown.Options = .{
        // The terminal's width, at most 120 columns for readable lines, unless given.
        .width = flags.width orelse @min(columns, 120),
        .style = try styleSheet(ctx, flags.style, color),
        .hyperlinks = flags.hyperlinks and color != .none,
        .preserve_newlines = flags.preserve_newlines,
    };

    // A directory: pick a file from it (at a terminal), or list what it has.
    if (!std.mem.eql(u8, source_arg, "-") and !isRemote(source_arg)) {
        if (isDirectory(ctx.io, source_arg)) {
            const found = try findMarkdown(ctx.arena, ctx.io, source_arg, flags.all);
            if (found.len == 0) return ctx.fail("{s}: no Markdown files", .{source_arg});
            if (!at_terminal or flags.print) {
                for (found) |path| try ctx.out.print("{s}\n", .{path});
                return;
            }
            return browse(ctx, found, options);
        }
    }

    const document = try load(ctx, source_arg);
    if (document.base_url.len > 0) options.base_url = document.base_url;
    if (!at_terminal or flags.print or flags.pager) {
        var out: Writer.Allocating = .init(ctx.arena);
        try markdown.render(ctx.arena, &out.writer, document.text, options);
        if (flags.pager and at_terminal) {
            try ctx.out.flush();
            if (try cli.pager.page(ctx.io, ctx.arena, ctx.environ, out.written())) return;
        }
        return term.writeStyled(ctx.out, out.written(), color);
    }
    var reader: Reader = .init(ctx, document, options, false);
    defer reader.deinit();
    if (try term.run(ctx, Reader, &reader, .{ .alt_screen = true, .mouse = true })) {
        return term.exitInterrupted(ctx);
    }
}

const Document = struct {
    text: []u8,
    /// The file, for editing and reloading; empty for standard input and URLs.
    path: []const u8 = "",
    /// What relative links are resolved against (a URL's directory).
    base_url: []const u8 = "",
    title: []const u8,
};

/// Reads `source`: standard input, a URL or repository, or a file.
fn load(ctx: *cli.Context, source: []const u8) !Document {
    if (std.mem.eql(u8, source, "-")) {
        const text = try term.readStdin(ctx) orelse
            return ctx.usageError("- reads standard input, which is a terminal", .{});
        return .{ .text = @constCast(text), .title = "stdin" };
    }
    if (isRemote(source)) return fetch(ctx, source);
    const text = Io.Dir.cwd().readFileAlloc(
        ctx.io,
        source,
        ctx.arena,
        .limited(64 << 20),
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return ctx.fail("{s}: {s}", .{ source, readError(err) });
    };
    return .{ .text = text, .path = source, .title = std.fs.path.basename(source) };
}

fn readError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "a directory",
        error.FileTooBig, error.StreamTooLong => "too large",
        else => @errorName(err),
    };
}

/// Whether `source` names something to fetch: a URL, or a GitHub or GitLab repository.
fn isRemote(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "http://") or
        std.mem.startsWith(u8, source, "https://") or repository(source) != null;
}

const Repository = struct { host: enum { github, gitlab }, path: []const u8 };

/// `github.com/owner/repo` or `gitlab.com/owner/repo` (with or without a scheme).
fn repository(source: []const u8) ?Repository {
    var rest = source;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (std.mem.startsWith(u8, rest, scheme)) rest = rest[scheme.len..];
    }
    const hosts = .{ .{ "github.com/", .github }, .{ "gitlab.com/", .gitlab } };
    inline for (hosts) |host| {
        if (std.mem.startsWith(u8, rest, host[0])) {
            const path = std.mem.trimEnd(u8, rest[host[0].len..], "/");
            // owner/repo, and nothing more (a deeper path is a page, fetched as a URL).
            if (std.mem.count(u8, path, "/") == 1) return .{ .host = host[1], .path = path };
        }
    }
    return null;
}

fn fetch(ctx: *cli.Context, source: []const u8) !Document {
    var spinner: tui.term.live.Spinner = .{
        .title = try std.fmt.allocPrint(ctx.arena, "fetching {s}", .{source}),
    };
    const items = [_]tui.term.live.Item{.{ .spinner = &spinner }};
    var display = ctx.live(&items);
    display.start(ctx.io) catch {};
    // Gone before the document shows, or a failure is printed.
    defer display.clear() catch {};
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    var http: sys.remote.HttpFetcher = .{ .client = &client, .user_agent = "termancy-md" };
    const limit = 16 << 20;
    if (repository(source)) |repo| {
        // The README on the default branch, by its usual names.
        const names = [_][]const u8{
            "README.md",
            "readme.md",
            "Readme.md",
            "README.markdown",
            "README",
        };
        for (names) |name| {
            const url = switch (repo.host) {
                .github => try std.fmt.allocPrint(
                    ctx.arena,
                    "https://raw.githubusercontent.com/{s}/HEAD/{s}",
                    .{ repo.path, name },
                ),
                .gitlab => try std.fmt.allocPrint(
                    ctx.arena,
                    "https://gitlab.com/{s}/-/raw/HEAD/{s}",
                    .{ repo.path, name },
                ),
            };
            const response = http.fetch(ctx.arena, url, null, limit) catch |err| switch (err) {
                error.NotFound => continue,
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try display.clear();
                    return ctx.fail("{s}: {s}", .{ source, fetchError(err) });
                },
            };
            const base = switch (repo.host) {
                .github => try std.fmt.allocPrint(
                    ctx.arena,
                    "https://github.com/{s}/blob/HEAD/",
                    .{repo.path},
                ),
                .gitlab => try std.fmt.allocPrint(
                    ctx.arena,
                    "https://gitlab.com/{s}/-/blob/HEAD/",
                    .{repo.path},
                ),
            };
            return .{ .text = response.body.bytes, .base_url = base, .title = repo.path };
        }
        try display.clear();
        return ctx.fail("{s}: no README found", .{source});
    }
    const response = http.fetch(ctx.arena, source, null, limit) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try display.clear();
        return ctx.fail("{s}: {s}", .{ source, fetchError(err) });
    };
    const slash = std.mem.lastIndexOfScalar(u8, source, '/') orelse source.len;
    return .{
        .text = response.body.bytes,
        .base_url = source[0 .. slash + 1],
        .title = source[slash + 1 ..],
    };
}

fn fetchError(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "not found",
        error.TooLarge => "too large",
        else => "cannot be fetched",
    };
}

fn isDirectory(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// The Markdown files under `root`, sorted, as paths from it; hidden files and the usual
/// build and dependency directories left out unless `all`.
fn findMarkdown(arena: Allocator, io: Io, root: []const u8, all: bool) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    var found: std.ArrayList([]const u8) = .empty;
    const skipped = [_][]const u8{
        "node_modules",
        "zig-cache",
        ".zig-cache",
        "zig-out",
        "target",
        "vendor",
    };
    while (try walker.next(io)) |entry| {
        const hidden = entry.basename.len > 0 and entry.basename[0] == '.';
        if (hidden and !all) continue;
        switch (entry.kind) {
            .directory => {
                const skip = for (skipped) |name| {
                    if (std.mem.eql(u8, name, entry.basename)) break true;
                } else false;
                if (!skip or all) try walker.enter(io, entry);
            },
            .file, .sym_link => {
                const ext = std.fs.path.extension(entry.basename);
                const extensions = [_][]const u8{ ".md", ".markdown", ".mdown", ".mkd", ".mdx" };
                const is_markdown = for (extensions) |e| {
                    if (std.ascii.eqlIgnoreCase(ext, e)) break true;
                } else false;
                if (!is_markdown) continue;
                // The directory as given, then its separator (`/` for `.`, so drop `./`).
                const joined = try sys.files.join(arena, root, entry.path);
                const path = if (std.mem.eql(u8, root, ".")) joined[2..] else joined;
                try found.append(arena, path);
            },
            else => {},
        }
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return found.items;
}

/// The style sheet `--style` names; `auto` is dark or light by `COLORFGBG`, and notty
/// without color.
fn styleSheet(
    ctx: *cli.Context,
    name: []const u8,
    color: tui.capability.Color,
) !markdown.StyleSheet {
    if (std.mem.eql(u8, name, "auto")) {
        if (color == .none) return .notty;
        return if (@import("ui/format.zig").lightBackground(ctx.environ)) .light else .dark;
    }
    if (markdown.StyleSheet.named(name)) |sheet| return sheet;
    const json = Io.Dir.cwd().readFileAlloc(ctx.io, name, ctx.arena, .limited(1 << 20)) catch
        return ctx.usageError("no style named {s} (dark, light, auto, notty, ascii, dracula, " ++
            "tokyo-night, pink, or a JSON file)", .{name});
    return markdown.StyleSheet.parse(ctx.arena, json, .dark) catch
        ctx.usageError("{s}: not a style sheet", .{name});
}

/// The full-screen reader: the document, a status line, and the keys to edit and reload.
const Reader = struct {
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    document: Document,
    /// The source as read last; owned when reloaded.
    owned: ?[]u8 = null,
    doc: registry.Markdown,
    /// Back to the list on esc (opened from one), or quit.
    from_list: bool,
    /// Asked to go back to the list.
    back: bool = false,
    message: []const u8 = "",
    /// For reading the file again after an edit.
    reload_io: ?Io = null,

    fn init(
        ctx: *cli.Context,
        document: Document,
        options: markdown.Options,
        from_list: bool,
    ) Reader {
        return .{
            .gpa = ctx.gpa,
            .environ = ctx.environ,
            .document = document,
            .doc = .{
                .gpa = ctx.gpa,
                .source = document.text,
                .options = options,
                .title = document.title,
            },
            .from_list = from_list,
            .reload_io = ctx.io,
        };
    }

    pub fn deinit(r: *Reader) void {
        r.doc.deinit();
        if (r.owned) |bytes| r.gpa.free(bytes);
    }

    const edit_id = 1;

    pub fn update(r: *Reader, msg: tui.Msg) tui.Cmd {
        if (msg == .key) {
            const key = msg.key;
            r.message = "";
            if (key.matches("esc") and r.from_list) {
                r.back = true;
                return .quit;
            }
            if (key.matches("e")) {
                if (r.document.path.len == 0) {
                    r.message = "only a file can be edited";
                    return .none;
                }
                return .handoff(edit_id);
            }
            if (key.matches("r")) {
                r.reload();
                return .none;
            }
            if (key.matches("c")) {
                r.message = "copied";
                return .clipboard;
            }
        }
        return r.doc.update(msg);
    }

    pub fn handoff(r: *Reader, io: Io, id: u32) tui.Cmd {
        if (id != edit_id) return .none;
        _ = sys.process.editAt(r.gpa, io, r.environ, r.document.path, null) catch {
            r.message = "the editor did not start";
            return .none;
        };
        r.reload_io = io;
        r.reload();
        return .none;
    }

    fn reload(r: *Reader) void {
        const io = r.reload_io orelse return;
        if (r.document.path.len == 0) return;
        const text = Io.Dir.cwd().readFileAlloc(
            io,
            r.document.path,
            r.gpa,
            .limited(64 << 20),
        ) catch {
            r.message = "cannot read the file again";
            return;
        };
        if (r.owned) |old| r.gpa.free(old);
        r.owned = text;
        r.doc.source = text;
        r.doc.layout(r.doc.viewport.width orelse 80) catch {};
        r.message = "reloaded";
    }

    pub fn clipboard(r: *const Reader, w: *Writer) Writer.Error!void {
        try w.writeAll(r.doc.source);
    }

    pub fn view(r: *const Reader, w: *Writer) Writer.Error!void {
        try r.doc.view(w);
        if (r.message.len > 0) {
            try w.writeAll("  ");
            try (tui.Style{ .fg = .{ .indexed = 212 } }).paint(w, r.message);
        }
    }
};

/// The list of files to read, filtered as you type, and the reader for the chosen one.
fn browse(ctx: *cli.Context, paths: []const []const u8, options: markdown.Options) !void {
    var filter: registry.Filter = try .init(ctx.gpa, paths);
    defer filter.deinit();
    filter.header = "Markdown files";
    while (true) {
        filter.status = .active;
        if (try term.run(ctx, registry.Filter, &filter, .{ .alt_screen = true })) {
            return term.exitInterrupted(ctx);
        }
        if (filter.status != .submitted) return;
        const index = filter.current() orelse return;
        const document = try load(ctx, paths[index]);
        var reader: Reader = .init(ctx, document, options, true);
        defer reader.deinit();
        if (try term.run(ctx, Reader, &reader, .{ .alt_screen = true, .mouse = true })) {
            return term.exitInterrupted(ctx);
        }
        if (!reader.back) return;
    }
}

const testing = std.testing;

test repository {
    try testing.expectEqualStrings("ziglang/zig", repository("github.com/ziglang/zig").?.path);
    try testing.expectEqualStrings("a/b", repository("https://gitlab.com/a/b/").?.path);
    try testing.expectEqual(null, repository("github.com/a/b/blob/main/x.md"));
    try testing.expectEqual(null, repository("notes.md"));
}

fn termancy(args: []const []const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &@import("../main.zig").root, .completion_command = false };
    return cli.testing.run(app, args, .{});
}

test "a file prints rendered off a terminal, and a directory lists its Markdown" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.md", .data = "# A\n\n**hi**\n" });
    try tmp.dir.createDir(testing.io, "docs", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "docs/b.markdown", .data = "b" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "c" });
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}/a.md", .{dir});
    defer testing.allocator.free(file);
    const shown = try termancy(&.{ "md", "-s", "ascii", file });
    defer shown.deinit();
    try shown.expect(0, "\n  # A\n\n  hi\n", "");
    const listed = try termancy(&.{ "md", dir });
    defer listed.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/a.md\n{s}/docs/b.markdown\n",
        .{ dir, dir },
    );
    defer testing.allocator.free(expected);
    try listed.expect(0, expected, "");
    const missing = try termancy(&.{ "md", "no-such-file.md" });
    defer missing.deinit();
    try missing.expect(1, "", "termancy: no-such-file.md: no such file\n");
}

test "the reader scrolls, copies, and quits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var reader: Reader = .{
        .gpa = testing.allocator,
        .environ = &environ,
        .document = .{ .text = @constCast("# Doc\n\nbody"), .title = "doc.md" },
        .doc = .{
            .gpa = testing.allocator,
            .source = "# Doc\n\nbody",
            .options = .{ .style = .ascii },
            .title = "doc.md",
        },
        .from_list = true,
    };
    var d: tui.testing.Driver(Reader) = try .init(
        testing.allocator,
        reader,
        .{ .program = .{ .size = .{ .width = 40, .height = 8 } } },
    );
    defer d.deinit();
    _ = &reader;
    try d.expectFrameContains("# Doc");
    try d.press("c");
    try testing.expectEqualStrings("# Doc\n\nbody", d.screen.clipboard.items);
    try d.press("e");
    try d.expectFrameContains("only a file can be edited");
    try d.press("esc");
    try testing.expect(d.done() and d.model().back);
}
