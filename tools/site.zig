//! Generates the documentation site that `zig build site` installs to `zig-out/site`: the
//! front page, the guide (`docs/guide.md`), a page per library from its `//!` module docs,
//! the component gallery with a page per component, and the command reference, all on one
//! style sheet. Everything comes from the sources; nothing is written by hand here but the
//! frame around it.
//!
//!     site <out> <src> <registry> <components.json> <commands.html> <guide.md> [name=gif]...
//!
//! `components.json` is `snek tui list -o json`, `commands.html` is `snek cli docs -f html
//! --stylesheet style.css`, and each `name=gif` is a component's recording, copied to
//! `gifs/<name>.gif`. A component without one says how to record it.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;

const libraries = [_][]const u8{ "term", "cli", "cfg", "tui", "platform" };
const repository = "https://github.com/93ams/snek";

const Component = struct {
    name: []const u8,
    summary: []const u8,
    requires: []const []const u8,
    files: []const []const u8,
};

const Listing = struct { components: []const Component };

const Gif = struct { name: []const u8, path: []const u8 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 7) return error.Usage;
    const cwd = Io.Dir.cwd();
    var out = try cwd.createDirPathOpen(io, args[1], .{});
    defer out.close(io);
    const src = args[2];
    const registry = args[3];
    const json = try read(io, arena, args[4]);
    const listing = try std.json.parseFromSliceLeaky(Listing, arena, json, .{
        .ignore_unknown_fields = true,
    });
    var gifs: std.ArrayList(Gif) = .empty;
    for (args[7..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.Usage;
        try gifs.append(arena, .{ .name = arg[0..eq], .path = arg[eq + 1 ..] });
    }

    try out.writeFile(io, .{ .sub_path = "style.css", .data = stylesheet });
    try out.createDirPath(io, "lib");
    try out.createDirPath(io, "components");
    try out.createDirPath(io, "gifs");

    var page: Writer.Allocating = .init(arena);
    const w = &page.writer;

    // The front page.
    try header(w, "snek", "");
    try w.writeAll(
        \\<h1>snek</h1>
        \\<p>Zig libraries for command-line and terminal programs: commands and flags,
        \\layered configuration, terminal user interfaces, and the operating system around
        \\them, with a <code>snek</code> program that scaffolds, records, and inspects.</p>
        \\<ul>
        \\<li><a href="guide.html">Your first app in 10 minutes</a></li>
        \\<li><a href="components/index.html">Components</a>: copy them in with
        \\<code>snek tui add</code></li>
        \\<li><a href="commands.html">The snek command reference</a></li>
        \\</ul>
        \\<h2>Libraries</h2>
        \\<table>
        \\
    );
    for (libraries) |name| {
        const docs = moduleDocs(arena, try read(io, arena, try path(arena, src, name)));
        try w.print("<tr><td><a href=\"lib/{s}.html\"><code>{s}</code></a></td><td>", .{
            name, name,
        });
        try inline_(w, firstSentence(docs));
        try w.writeAll("</td></tr>\n");
    }
    try w.writeAll("</table>\n");
    try footer(w);
    try flush(io, out, "index.html", &page);

    // The guide.
    try header(w, "Your first app in 10 minutes", "");
    try markdown(w, try read(io, arena, args[6]));
    try footer(w);
    try flush(io, out, "guide.html", &page);

    // A page per library.
    for (libraries) |name| {
        const source = try read(io, arena, try path(arena, src, name));
        try header(w, name, "../");
        try w.print("<h1><code>{s}</code></h1>\n", .{name});
        try markdown(w, moduleDocs(arena, source));
        try declarations(w, source);
        try w.print("<p><a href=\"../api/{s}/index.html\">The full API reference</a></p>\n", .{
            name,
        });
        try footer(w);
        try flush(io, out, try std.fmt.allocPrint(arena, "lib/{s}.html", .{name}), &page);
    }

    // The gallery, and a page per component.
    try header(w, "Components", "../");
    try w.writeAll(
        \\<h1>Components</h1>
        \\<p>Each component is a source file that <code>snek tui add</code> copies into your
        \\project, with the components it requires, where it is yours to change.
        \\<code>snek tui demo &lt;name&gt;</code> runs one on sample data first.</p>
        \\<div class="gallery">
        \\
    );
    for (listing.components) |c| {
        try w.print("<article>\n<h2><a href=\"{s}.html\">{s}</a></h2>\n", .{ c.name, c.name });
        try recording(w, c.name, gifs.items, "../");
        try w.writeAll("<p>");
        try inline_(w, c.summary);
        try w.print("</p>\n<pre><code>snek tui add {s}</code></pre>\n</article>\n", .{c.name});
    }
    try w.writeAll("</div>\n");
    try footer(w);
    try flush(io, out, "components/index.html", &page);
    for (listing.components) |c| {
        try header(w, c.name, "../");
        try w.print("<h1>{s}</h1>\n<p>", .{c.name});
        try inline_(w, c.summary);
        try w.print("</p>\n<pre><code>snek tui add {s}</code></pre>\n", .{c.name});
        if (c.requires.len > 0) {
            try w.writeAll("<p>Also copies what it requires:");
            for (c.requires) |r| try w.print(" <a href=\"{s}.html\">{s}</a>", .{ r, r });
            try w.writeAll("</p>\n");
        }
        try recording(w, c.name, gifs.items, "../");
        for (c.files, 0..) |file, i| {
            const text = try read(io, arena, try std.fs.path.join(arena, &.{ registry, file }));
            if (i == 0) try markdown(w, moduleDocs(arena, text));
            try w.writeAll("<h2>");
            try escape(w, file);
            try w.writeAll("</h2>\n<pre><code>");
            try escape(w, text);
            try w.writeAll("</code></pre>\n");
        }
        try footer(w);
        try flush(io, out, try std.fmt.allocPrint(arena, "components/{s}.html", .{c.name}), &page);
    }
    for (gifs.items) |gif| {
        const sub_path = try std.fmt.allocPrint(arena, "gifs/{s}.gif", .{gif.name});
        try out.writeFile(io, .{ .sub_path = sub_path, .data = try read(io, arena, gif.path) });
    }

    // The command reference, framed like the other pages.
    const commands = try read(io, arena, args[5]);
    const body = "<body>\n";
    const at = (std.mem.indexOf(u8, commands, body) orelse return error.NoBody) + body.len;
    try w.writeAll(commands[0..at]);
    try nav(w, "");
    try w.writeAll(commands[at..]);
    try flush(io, out, "commands.html", &page);
}

fn read(io: Io, arena: Allocator, file: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(16 << 20));
}

fn path(arena: Allocator, src: []const u8, library: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ src, library, "root.zig" });
}

fn flush(io: Io, dir: Io.Dir, sub_path: []const u8, page: *Writer.Allocating) !void {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = page.written() });
    page.clearRetainingCapacity();
}

fn header(w: *Writer, title: []const u8, root: []const u8) Writer.Error!void {
    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>
    );
    try escape(w, title);
    try w.print(
        \\ - snek</title>
        \\<link rel="stylesheet" href="{s}style.css">
        \\</head>
        \\<body>
        \\
    , .{root});
    try nav(w, root);
    try w.writeAll("<main>\n");
}

fn nav(w: *Writer, root: []const u8) Writer.Error!void {
    try w.print(
        \\<header><a href="{0s}index.html"><b>snek</b></a>
        \\<a href="{0s}guide.html">Guide</a>
        \\<a href="{0s}components/index.html">Components</a>
        \\<a href="{0s}commands.html">Commands</a>
        \\<a href="{0s}api/cli/index.html">API</a></header>
        \\
    , .{root});
}

fn footer(w: *Writer) Writer.Error!void {
    try w.writeAll("</main>\n<footer>Generated from the sources by <code>zig build site</code>" ++
        " &middot; <a href=\"" ++ repository ++ "\">source</a></footer>\n</body>\n</html>\n");
}

/// The component's GIF, or how to record one.
fn recording(w: *Writer, name: []const u8, gifs: []const Gif, root: []const u8) !void {
    for (gifs) |gif| if (std.mem.eql(u8, gif.name, name)) {
        return w.print("<img src=\"{s}gifs/{s}.gif\" alt=\"snek tui demo {s}, recorded\" " ++
            "loading=\"lazy\">\n", .{ root, name, name });
    };
    try w.print("<p class=\"note\">No recording here. <code>zig build site-gifs</code> " ++
        "records one from <code>docs/tapes/{s}.tape</code> when there is one; " ++
        "<code>snek tui demo {s}</code> runs it, if it has a demo.</p>\n", .{ name, name });
}

/// The `//!` lines at the top of a Zig file, without the `//!`.
fn moduleDocs(arena: Allocator, source: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "//!")) break;
        var text = line[3..];
        if (std.mem.startsWith(u8, text, " ")) text = text[1..];
        out.appendSlice(arena, text) catch @panic("OOM");
        out.append(arena, '\n') catch @panic("OOM");
    }
    return out.items;
}

/// Up to the first period that ends a sentence, or the first paragraph.
fn firstSentence(text: []const u8) []const u8 {
    const paragraph = text[0 .. std.mem.indexOf(u8, text, "\n\n") orelse text.len];
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, paragraph, i, '.')) |dot| : (i = dot + 1) {
        if (dot + 1 == paragraph.len or paragraph[dot + 1] == ' ' or paragraph[dot + 1] == '\n') {
            return paragraph[0 .. dot + 1];
        }
    }
    return paragraph;
}

/// A table of the file's public declarations that have `///` docs, with their first
/// sentence.
fn declarations(w: *Writer, source: []const u8) Writer.Error!void {
    var doc_start: ?usize = null;
    var doc_end: usize = 0;
    var any = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var buffer: [1024]u8 = undefined;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "///")) {
            const start = @intFromPtr(line.ptr) - @intFromPtr(source.ptr);
            if (doc_start == null) doc_start = start;
            doc_end = start + line.len;
            continue;
        }
        defer doc_start = null;
        const first = doc_start orelse continue;
        if (line.len > 0 and line[0] == ' ') continue; // only top-level declarations
        const name = declName(trimmed) orelse continue;
        if (!any) try w.writeAll("<h2>Declarations</h2>\n<table>\n");
        any = true;
        // The doc comment without its slashes, as one paragraph.
        var text: Writer = .fixed(&buffer);
        var doc_lines = std.mem.splitScalar(u8, source[first..doc_end], '\n');
        while (doc_lines.next()) |doc| {
            const body = std.mem.trim(u8, std.mem.trimStart(u8, doc, " ")[3..], " ");
            text.print("{s} ", .{body}) catch break;
        }
        try w.print("<tr><td><code>{s}</code></td><td>", .{name});
        try inline_(w, firstSentence(std.mem.trimEnd(u8, text.buffered(), " ")));
        try w.writeAll("</td></tr>\n");
    }
    if (any) try w.writeAll("</table>\n");
}

fn declName(line: []const u8) ?[]const u8 {
    for ([_][]const u8{ "pub const ", "pub fn ", "pub var " }) |prefix| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
            end += 1;
        }
        if (end > 0) return rest[0..end];
    }
    return null;
}

// -- Markdown to HTML --------------------------------------------------------------------

/// Markdown as the module docs and the guide write it: headings, paragraphs, fenced and
/// indented code, tables, and bullet and numbered lists; inline code, `**strong**`,
/// `*emphasis*`, and `[links](url)`. Everything else is text, escaped.
/// shortcut: no nested lists, block quotes, or raw HTML; add them when a page needs them.
pub fn markdown(w: *Writer, text: []const u8) Writer.Error!void {
    var buffer: [4096][]const u8 = undefined;
    var lines: std.ArrayList([]const u8) = .initBuffer(&buffer);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| lines.appendBounded(std.mem.trimEnd(u8, line, "\r")) catch break;
    const all = lines.items;
    var i: usize = 0;
    while (i < all.len) {
        const line = all[i];
        if (std.mem.trim(u8, line, " ").len == 0) {
            i += 1;
        } else if (std.mem.startsWith(u8, line, "```")) {
            const lang = std.mem.trim(u8, line[3..], " ");
            if (lang.len > 0) {
                try w.writeAll("<pre><code class=\"language-");
                try escape(w, lang);
                try w.writeAll("\">");
            } else try w.writeAll("<pre><code>");
            i += 1;
            while (i < all.len and !std.mem.startsWith(u8, all[i], "```")) : (i += 1) {
                try escape(w, all[i]);
                try w.writeByte('\n');
            }
            i += 1;
            try w.writeAll("</code></pre>\n");
        } else if (std.mem.startsWith(u8, line, "    ")) {
            try w.writeAll("<pre><code>");
            while (i < all.len) : (i += 1) {
                const blank = std.mem.trim(u8, all[i], " ").len == 0;
                if (!blank and !std.mem.startsWith(u8, all[i], "    ")) break;
                // A blank line ends the block unless more code follows.
                if (blank and (i + 1 == all.len or !std.mem.startsWith(u8, all[i + 1], "    "))) {
                    break;
                }
                try escape(w, if (blank) "" else all[i][4..]);
                try w.writeByte('\n');
            }
            try w.writeAll("</code></pre>\n");
        } else if (heading(line)) |level| {
            const title = std.mem.trim(u8, line[level..], " #");
            try w.print("<h{d} id=\"", .{level});
            try slug(w, title);
            try w.writeAll("\">");
            try inline_(w, title);
            try w.print("</h{d}>\n", .{level});
            i += 1;
        } else if (line[0] == '|' and i + 1 < all.len and isSeparator(all[i + 1])) {
            try w.writeAll("<table>\n");
            try row(w, line, "th");
            i += 2;
            while (i < all.len and all[i].len > 0 and all[i][0] == '|') : (i += 1) {
                try row(w, all[i], "td");
            }
            try w.writeAll("</table>\n");
        } else if (listMarker(line)) |marker| {
            const ordered = std.ascii.isDigit(line[0]);
            try w.writeAll(if (ordered) "<ol>\n" else "<ul>\n");
            var item: ?usize = marker;
            while (item) |start| {
                try w.writeAll("<li>");
                var item_buffer: [2048]u8 = undefined;
                var item_text: std.ArrayList(u8) = .initBuffer(&item_buffer);
                item_text.appendSliceBounded(all[i][start..]) catch {};
                i += 1;
                // Continuation lines are indented.
                while (i < all.len and all[i].len > 0 and all[i][0] == ' ' and
                    listMarker(std.mem.trimStart(u8, all[i], " ")) == null)
                {
                    item_text.appendBounded(' ') catch {};
                    item_text.appendSliceBounded(std.mem.trim(u8, all[i], " ")) catch {};
                    i += 1;
                }
                try inline_(w, item_text.items);
                try w.writeAll("</li>\n");
                item = if (i < all.len) listMarker(all[i]) else null;
                if (item != null and std.ascii.isDigit(all[i][0]) != ordered) item = null;
            }
            try w.writeAll(if (ordered) "</ol>\n" else "</ul>\n");
        } else {
            try w.writeAll("<p>");
            var first = true;
            while (i < all.len) : (i += 1) {
                const l = all[i];
                if (std.mem.trim(u8, l, " ").len == 0 or std.mem.startsWith(u8, l, "```") or
                    heading(l) != null or listMarker(l) != null or
                    (l[0] == '|' and i + 1 < all.len and isSeparator(all[i + 1])))
                {
                    break;
                }
                if (!first) try w.writeByte('\n');
                first = false;
                try inline_(w, std.mem.trim(u8, l, " "));
            }
            try w.writeAll("</p>\n");
        }
    }
}

/// The level of a `#` heading line, or null.
fn heading(line: []const u8) ?usize {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6 or level == line.len or line[level] != ' ') return null;
    return level;
}

/// Where the text of a `- `, `* `, or `1. ` list item starts, or null.
fn listMarker(line: []const u8) ?usize {
    if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) return 2;
    var digits: usize = 0;
    while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
    if (digits > 0 and std.mem.startsWith(u8, line[digits..], ". ")) return digits + 2;
    return null;
}

fn isSeparator(line: []const u8) bool {
    if (line.len < 3 or line[0] != '|') return false;
    for (line) |c| if (std.mem.indexOfScalar(u8, "|-: ", c) == null) return false;
    return true;
}

/// A table row: cells split on `|` outside code spans, `\|` kept as a `|`.
fn row(w: *Writer, line: []const u8, tag: []const u8) Writer.Error!void {
    try w.writeAll("<tr>");
    const body = std.mem.trim(u8, std.mem.trim(u8, line, " "), "|");
    var start: usize = 0;
    var in_code = false;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i < body.len) {
            if (body[i] == '\\' and i + 1 < body.len and body[i + 1] == '|') {
                i += 1;
                continue;
            }
            if (body[i] == '`') in_code = !in_code;
            if (body[i] != '|' or in_code) continue;
        }
        try w.print("<{s}>", .{tag});
        try inline_(w, std.mem.trim(u8, body[start..i], " "));
        try w.print("</{s}>", .{tag});
        start = i + 1;
    }
    try w.writeAll("</tr>\n");
}

/// Inline Markdown: code spans, strong, emphasis, links; the rest escaped.
fn inline_(w: *Writer, text: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            var ticks: usize = 0;
            while (i + ticks < text.len and text[i + ticks] == '`') ticks += 1;
            const fence = text[i .. i + ticks];
            if (std.mem.indexOfPos(u8, text, i + ticks, fence)) |end| {
                try w.writeAll("<code>");
                try escape(w, std.mem.trim(u8, text[i + ticks .. end], " "));
                try w.writeAll("</code>");
                i = end + ticks;
                continue;
            }
            try escape(w, fence);
            i += ticks;
        } else if (c == '\\' and i + 1 < text.len and std.ascii.isPunctuation(text[i + 1])) {
            try escape(w, text[i + 1 .. i + 2]);
            i += 2;
        } else if (std.mem.startsWith(u8, text[i..], "**")) {
            const end = std.mem.indexOfPos(u8, text, i + 2, "**") orelse {
                try w.writeAll("**");
                i += 2;
                continue;
            };
            try w.writeAll("<strong>");
            try inline_(w, text[i + 2 .. end]);
            try w.writeAll("</strong>");
            i = end + 2;
        } else if (c == '*' and i + 1 < text.len and text[i + 1] != ' ' and
            std.mem.indexOfScalarPos(u8, text, i + 1, '*') != null)
        {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '*').?;
            try w.writeAll("<em>");
            try inline_(w, text[i + 1 .. end]);
            try w.writeAll("</em>");
            i = end + 1;
        } else if (c == '[' and link(text, i) != null) {
            const close, const end = link(text, i).?;
            try w.writeAll("<a href=\"");
            try escape(w, text[close + 2 .. end]);
            try w.writeAll("\">");
            try inline_(w, text[i + 1 .. close]);
            try w.writeAll("</a>");
            i = end + 1;
        } else {
            try escape(w, text[i .. i + 1]);
            i += 1;
        }
    }
}

/// The `]` and `)` of a `[text](url)` starting at `start`.
fn link(text: []const u8, start: usize) ?struct { usize, usize } {
    const close = std.mem.indexOfScalarPos(u8, text, start, ']') orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, text, close, ')') orelse return null;
    return .{ close, end };
}

fn escape(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// A heading's id: lowercase letters and digits, everything else one `-`.
fn slug(w: *Writer, text: []const u8) Writer.Error!void {
    var dash = false;
    var any = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and any) try w.writeByte('-');
            try w.writeByte(std.ascii.toLower(c));
            dash = false;
            any = true;
        } else dash = true;
    }
}

const stylesheet =
    \\:root {
    \\  --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e2e2e5; --code: #f5f5f7;
    \\  --link: #0b57d0; --accent: #ff8700;
    \\  color-scheme: light dark;
    \\}
    \\@media (prefers-color-scheme: dark) {
    \\  :root {
    \\    --bg: #121214; --fg: #e4e4e7; --muted: #a1a1aa; --line: #2e2e33; --code: #1c1c20;
    \\    --link: #8ab4f8;
    \\  }
    \\}
    \\* { box-sizing: border-box; }
    \\body {
    \\  margin: 0 auto; max-width: 56rem; padding: 0 1rem; background: var(--bg);
    \\  color: var(--fg); font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
    \\}
    \\header {
    \\  display: flex; flex-wrap: wrap; gap: .25rem 1rem; padding: .75rem 0;
    \\  border-bottom: 1px solid var(--line);
    \\}
    \\header b { color: var(--accent); }
    \\footer {
    \\  margin: 3rem 0 1rem; padding-top: .75rem; border-top: 1px solid var(--line);
    \\  color: var(--muted); font-size: .875rem;
    \\}
    \\a { color: var(--link); }
    \\h1, h2, h3 { line-height: 1.25; }
    \\code, pre { font-family: ui-monospace, "Cascadia Mono", Menlo, Consolas, monospace; }
    \\code { font-size: .9em; }
    \\pre {
    \\  background: var(--code); border: 1px solid var(--line); border-radius: 6px;
    \\  padding: .75rem; overflow-x: auto; line-height: 1.4;
    \\}
    \\table { border-collapse: collapse; width: 100%; display: block; overflow-x: auto; }
    \\td, th {
    \\  border-bottom: 1px solid var(--line); padding: .3rem .6rem; text-align: left;
    \\  vertical-align: top;
    \\}
    \\img { max-width: 100%; height: auto; border-radius: 6px; display: block; }
    \\section { margin-top: 2.5rem; }
    \\.note { color: var(--muted); font-style: italic; }
    \\.gallery {
    \\  display: grid; gap: 1rem; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr));
    \\}
    \\.gallery article {
    \\  border: 1px solid var(--line); border-radius: 8px; padding: 0 1rem; min-width: 0;
    \\}
    \\.gallery h2 { font-size: 1.15rem; }
    \\
;

const testing = std.testing;

fn render(text: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try markdown(&out.writer, text);
    return out.toOwnedSlice();
}

test "markdown: paragraphs, code, headings" {
    const html = try render(
        \\# A `b` & c
        \\
        \\One *two*
        \\**three** [four](x.html?a=1&b=2).
        \\
        \\```zig
        \\const a = 1 < 2;
        \\```
        \\
        \\    indented <code>
        \\
        \\    more
        \\after
    );
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        \\<h1 id="a-b-c">A <code>b</code> &amp; c</h1>
        \\<p>One <em>two</em>
        \\<strong>three</strong> <a href="x.html?a=1&amp;b=2">four</a>.</p>
        \\<pre><code class="language-zig">const a = 1 &lt; 2;
        \\</code></pre>
        \\<pre><code>indented &lt;code&gt;
        \\
        \\more
        \\</code></pre>
        \\<p>after</p>
        \\
    , html);
}

test "markdown: tables keep pipes inside code and escaped" {
    const html = try render(
        \\| name | |
        \\|---|---|
        \\| `a|b` | x \| y |
    );
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        \\<table>
        \\<tr><th>name</th><th></th></tr>
        \\<tr><td><code>a|b</code></td><td>x | y</td></tr>
        \\</table>
        \\
    , html);
}

test "markdown: lists with continuation lines" {
    const html = try render(
        \\- one
        \\  more
        \\- two
        \\
        \\1. first
        \\2. second
    );
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        \\<ul>
        \\<li>one more</li>
        \\<li>two</li>
        \\</ul>
        \\<ol>
        \\<li>first</li>
        \\<li>second</li>
        \\</ol>
        \\
    , html);
}

test "markdown: an unclosed span or bracket is text" {
    const html = try render("a `b and [c] d * e");
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>a `b and [c] d * e</p>\n", html);
}

test "moduleDocs and firstSentence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const docs = moduleDocs(arena.allocator(), "//! `x` - a thing. More, e.g.\n//!\n//!x\nconst");
    try testing.expectEqualStrings("`x` - a thing. More, e.g.\n\nx\n", docs);
    try testing.expectEqualStrings("`x` - a thing.", firstSentence(docs));
}

test declarations {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try declarations(&out.writer,
        \\/// The system. More.
        \\pub const system = @import("system/root.zig");
        \\pub const dirs = system.dirs;
        \\const hidden = 1;
        \\    /// Nested.
        \\    pub fn inner() void {}
    );
    try testing.expectEqualStrings(
        \\<h2>Declarations</h2>
        \\<table>
        \\<tr><td><code>system</code></td><td>The system.</td></tr>
        \\</table>
        \\
    , out.written());
}
