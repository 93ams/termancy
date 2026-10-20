//! Markdown for the terminal, as glamour renders it: CommonMark's blocks (headings,
//! paragraphs, block quotes, ordered and bullet lists, code blocks, thematic breaks) and
//! GitHub's (tables, task lists, strikethrough, autolinks), with inline emphasis, code,
//! links, images, reference links, entities, and emoji shortcodes. Paragraphs are
//! word-wrapped to the width, nested blocks indented, code blocks highlighted
//! (`highlight`), and everything styled by a style sheet: `dark`, `light`, `dracula`,
//! `tokyo_night`, `pink`, `ascii`, `notty`, or glamour's JSON format (`StyleSheet.parse`).
//!
//! ```zig
//! try term.markdown.render(gpa, w, readme, .{ .width = 80, .style = .dark });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");
const display = @import("width.zig");
const Style = @import("Style.zig");
const Table = @import("Table.zig");
const highlight = @import("highlight.zig");

/// How Markdown is rendered.
pub const Options = struct {
    /// Columns text wraps to, margins included.
    width: usize = 80,
    style: StyleSheet = .dark,
    /// Links as OSC 8 hyperlinks (the URL then is not written out).
    hyperlinks: bool = false,
    /// What relative link and image URLs are resolved against.
    base_url: []const u8 = "",
    /// Turn `:shortcodes:` into emoji.
    emoji: bool = true,
    /// Keep the line breaks inside paragraphs instead of reflowing them.
    preserve_newlines: bool = false,
};

/// How each element looks: a style, and the text before and after it.
pub const Element = struct {
    style: Style = .{},
    prefix: []const u8 = "",
    suffix: []const u8 = "",
};

/// The look of every element, and the glyphs that draw structure.
pub const StyleSheet = struct {
    document: Element = .{},
    /// Columns of margin around the document.
    margin: usize = 2,
    paragraph: Element = .{},
    heading: Element = .{ .style = .{ .bold = true } },
    h1: Element = .{},
    h2: Element = .{},
    h3: Element = .{},
    h4: Element = .{},
    h5: Element = .{},
    h6: Element = .{},
    block_quote: Element = .{},
    /// What starts each line of a block quote.
    quote_bar: []const u8 = "│ ",
    item: Element = .{},
    bullet: []const u8 = "• ",
    enumeration: Element = .{},
    task_done: []const u8 = "[✓] ",
    task_open: []const u8 = "[ ] ",
    emph: Style = .{ .italic = true },
    strong: Style = .{ .bold = true },
    strikethrough: Style = .{ .strikethrough = true },
    code: Element = .{},
    code_block: Element = .{},
    /// The theme code blocks are highlighted in; null leaves them plain.
    code_theme: ?highlight.Theme = null,
    link: Style = .{},
    link_text: Style = .{},
    image: Style = .{},
    image_text: Style = .{},
    hr: Element = .{},
    rule: []const u8 = "─",
    table: Element = .{},
    table_border: Style.Border = .normal,
    html: Style = .{},

    /// For dark backgrounds: glamour's default.
    pub const dark: StyleSheet = .{
        .document = .{ .style = .{ .fg = .{ .indexed = 252 } } },
        .heading = .{ .style = .{ .fg = .{ .indexed = 39 }, .bold = true } },
        .h1 = .{
            .style = .{ .fg = .{ .indexed = 228 }, .bg = .{ .indexed = 63 }, .bold = true },
            .prefix = " ",
            .suffix = " ",
        },
        .h2 = .{ .prefix = "## " },
        .h3 = .{ .prefix = "### " },
        .h4 = .{ .prefix = "#### " },
        .h5 = .{ .prefix = "##### " },
        .h6 = .{ .style = .{ .fg = .{ .indexed = 35 }, .bold = false }, .prefix = "###### " },
        .block_quote = .{ .style = .{ .fg = .{ .indexed = 245 }, .italic = true } },
        .enumeration = .{ .style = .{ .fg = .{ .indexed = 252 } } },
        .code = .{
            .style = .{ .fg = .{ .indexed = 203 }, .bg = .{ .indexed = 236 } },
            .prefix = " ",
            .suffix = " ",
        },
        .code_block = .{ .style = .{ .fg = .{ .indexed = 244 } } },
        .code_theme = .charm,
        .link = .{ .fg = .{ .indexed = 30 }, .underline = true },
        .link_text = .{ .fg = .{ .indexed = 35 }, .bold = true },
        .image = .{ .fg = .{ .indexed = 212 }, .underline = true },
        .image_text = .{ .fg = .{ .indexed = 243 } },
        .hr = .{ .style = .{ .fg = .{ .indexed = 240 } } },
        .html = .{ .fg = .{ .indexed = 244 } },
    };

    /// For light backgrounds.
    pub const light: StyleSheet = .{
        .document = .{ .style = .{ .fg = .{ .indexed = 234 } } },
        .heading = .{ .style = .{ .fg = .{ .indexed = 27 }, .bold = true } },
        .h1 = .{
            .style = .{ .fg = .{ .indexed = 228 }, .bg = .{ .indexed = 63 }, .bold = true },
            .prefix = " ",
            .suffix = " ",
        },
        .h2 = .{ .prefix = "## " },
        .h3 = .{ .prefix = "### " },
        .h4 = .{ .prefix = "#### " },
        .h5 = .{ .prefix = "##### " },
        .h6 = .{ .prefix = "###### " },
        .block_quote = .{ .style = .{ .fg = .{ .indexed = 242 }, .italic = true } },
        .code = .{
            .style = .{ .fg = .{ .indexed = 203 }, .bg = .{ .indexed = 254 } },
            .prefix = " ",
            .suffix = " ",
        },
        .code_block = .{ .style = .{ .fg = .{ .indexed = 242 } } },
        .code_theme = .github,
        .link = .{ .fg = .{ .indexed = 36 }, .underline = true },
        .link_text = .{ .fg = .{ .indexed = 29 }, .bold = true },
        .image = .{ .fg = .{ .indexed = 205 }, .underline = true },
        .image_text = .{ .fg = .{ .indexed = 243 } },
        .hr = .{ .style = .{ .fg = .{ .indexed = 249 } } },
    };

    /// Dracula's colors.
    pub const dracula: StyleSheet = .{
        .document = .{ .style = .{ .fg = .hex(0xf8f8f2) } },
        .heading = .{ .style = .{ .fg = .hex(0xbd93f9), .bold = true } },
        .h1 = .{ .prefix = "# " },
        .h2 = .{ .prefix = "## " },
        .h3 = .{ .prefix = "### " },
        .h4 = .{ .prefix = "#### " },
        .h5 = .{ .prefix = "##### " },
        .h6 = .{ .prefix = "###### " },
        .block_quote = .{ .style = .{ .fg = .hex(0xf1fa8c), .italic = true } },
        .emph = .{ .fg = .hex(0xf1fa8c), .italic = true },
        .strong = .{ .fg = .hex(0xffb86c), .bold = true },
        .code = .{ .style = .{ .fg = .hex(0x50fa7b) } },
        .code_theme = .dracula,
        .link = .{ .fg = .hex(0x8be9fd), .underline = true },
        .link_text = .{ .fg = .hex(0xff79c6) },
        .image = .{ .fg = .hex(0x8be9fd), .underline = true },
        .image_text = .{ .fg = .hex(0xff79c6) },
        .hr = .{ .style = .{ .fg = .hex(0x6272a4) } },
        .bullet = "• ",
    };

    /// Tokyo Night's colors.
    pub const tokyo_night: StyleSheet = .{
        .document = .{ .style = .{ .fg = .hex(0xa9b1d6) } },
        .heading = .{ .style = .{ .fg = .hex(0xbb9af7), .bold = true } },
        .h1 = .{ .prefix = "# " },
        .h2 = .{ .prefix = "## " },
        .h3 = .{ .prefix = "### " },
        .h4 = .{ .prefix = "#### " },
        .h5 = .{ .prefix = "##### " },
        .h6 = .{ .prefix = "###### " },
        .block_quote = .{ .style = .{ .fg = .hex(0x565f89), .italic = true } },
        .code = .{ .style = .{ .fg = .hex(0x7aa2f7) } },
        .code_theme = .tokyo_night,
        .link = .{ .fg = .hex(0x7aa2f7), .underline = true },
        .link_text = .{ .fg = .hex(0x2ac3de) },
        .image = .{ .fg = .hex(0x7aa2f7), .underline = true },
        .image_text = .{ .fg = .hex(0x2ac3de) },
        .hr = .{ .style = .{ .fg = .hex(0x565f89) } },
    };

    /// Pink headings and accents.
    pub const pink: StyleSheet = .{
        .heading = .{ .style = .{ .fg = .{ .indexed = 212 }, .bold = true } },
        .h1 = .{ .style = .{ .underline = true }, .prefix = "" },
        .h2 = .{ .prefix = "▌ " },
        .h3 = .{ .prefix = "┃ " },
        .h4 = .{ .prefix = "│ " },
        .h5 = .{ .prefix = "┆ " },
        .h6 = .{ .prefix = "┊ " },
        .block_quote = .{ .style = .{ .italic = true } },
        .emph = .{ .fg = .{ .indexed = 212 }, .italic = true },
        .strong = .{ .fg = .{ .indexed = 212 }, .bold = true },
        .code = .{ .style = .{ .fg = .{ .indexed = 212 } } },
        .code_theme = .charm,
        .link = .{ .fg = .{ .indexed = 99 }, .underline = true },
        .link_text = .{ .bold = true },
        .hr = .{ .style = .{ .fg = .{ .indexed = 212 } } },
        .bullet = "‣ ",
    };

    /// No colors, ASCII only: for any terminal and for files.
    pub const ascii: StyleSheet = .{
        .h1 = .{ .prefix = "# " },
        .h2 = .{ .prefix = "## " },
        .h3 = .{ .prefix = "### " },
        .h4 = .{ .prefix = "#### " },
        .h5 = .{ .prefix = "##### " },
        .h6 = .{ .prefix = "###### " },
        .heading = .{},
        .emph = .{},
        .strong = .{},
        .strikethrough = .{},
        .code = .{ .prefix = "`", .suffix = "`" },
        .quote_bar = "| ",
        .bullet = "* ",
        .task_done = "[x] ",
        .rule = "-",
        .table_border = .ascii,
    };

    /// No colors, but bold and italic: what to use where colors are off.
    pub const notty: StyleSheet = .{
        .h1 = .{ .prefix = "# " },
        .h2 = .{ .prefix = "## " },
        .h3 = .{ .prefix = "### " },
        .h4 = .{ .prefix = "#### " },
        .h5 = .{ .prefix = "##### " },
        .h6 = .{ .prefix = "###### " },
        .code = .{ .prefix = "`", .suffix = "`" },
    };

    /// The style sheet named `name` (`dark`, `light`, `dracula`, `tokyo-night`, `pink`,
    /// `ascii`, `notty`), or null.
    pub fn named(name: []const u8) ?StyleSheet {
        const sheets = [_]struct { []const u8, StyleSheet }{
            .{ "dark", dark },               .{ "light", light },
            .{ "dracula", dracula },         .{ "tokyo-night", tokyo_night },
            .{ "tokyo_night", tokyo_night }, .{ "pink", pink },
            .{ "ascii", ascii },             .{ "notty", notty },
        };
        for (sheets) |s| if (std.ascii.eqlIgnoreCase(s[0], name)) return s[1];
        return null;
    }

    /// A style sheet from glamour's JSON format, over `base`: an object of elements
    /// (`document`, `heading`, `h1`..`h6`, `paragraph`, `block_quote`, `item`,
    /// `enumeration`, `emph`, `strong`, `strikethrough`, `code`, `code_block`, `link`,
    /// `link_text`, `image`, `image_text`, `hr`, `table`), each with `color`,
    /// `background_color`, `bold`, `italic`, `underline`, `faint`, `crossed_out`,
    /// `prefix`, and `suffix`; `document.margin`; `code_block.theme` (a highlight theme's
    /// name). Strings are copied into `arena`.
    pub fn parse(arena: Allocator, json: []const u8, base: StyleSheet) !StyleSheet {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
        if (parsed != .object) return error.InvalidStyleSheet;
        var sheet = base;
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (value != .object) continue;
            if (std.mem.eql(u8, name, "document")) {
                if (value.object.get("margin")) |m| if (m == .integer) {
                    sheet.margin = @intCast(@max(m.integer, 0));
                };
            }
            if (std.mem.eql(u8, name, "code_block")) {
                if (value.object.get("theme")) |t| if (t == .string) {
                    sheet.code_theme = highlight.Theme.named(t.string);
                };
            }
            inline for (.{
                "document", "paragraph", "heading",     "h1",   "h2",          "h3",   "h4",
                "h5",       "h6",        "block_quote", "item", "enumeration", "code", "code_block",
                "hr",       "table",
            }) |field| {
                if (std.mem.eql(u8, name, field)) {
                    @field(sheet, field) = try element(arena, value, @field(sheet, field));
                }
            }
            inline for (.{
                "emph",  "strong",     "strikethrough", "link", "link_text",
                "image", "image_text",
            }) |field| {
                if (std.mem.eql(u8, name, field)) {
                    const prior: Element = .{ .style = @field(sheet, field) };
                    @field(sheet, field) = (try element(arena, value, prior)).style;
                }
            }
        }
        return sheet;
    }

    fn element(arena: Allocator, value: std.json.Value, base: Element) !Element {
        var e = base;
        const object = value.object;
        if (object.get("color")) |c| if (c == .string) {
            e.style.fg = ansi.Color.parse(c.string) catch e.style.fg;
        };
        if (object.get("background_color")) |c| if (c == .string) {
            e.style.bg = ansi.Color.parse(c.string) catch e.style.bg;
        };
        inline for (.{
            .{ "bold", "bold" },                 .{ "italic", "italic" },
            .{ "underline", "underline" },       .{ "faint", "dim" },
            .{ "crossed_out", "strikethrough" }, .{ "blink", "blink" },
            .{ "inverse", "reverse" },
        }) |pair| {
            if (object.get(pair[0])) |b| if (b == .bool) {
                @field(e.style, pair[1]) = b.bool;
            };
        }
        if (object.get("prefix")) |p| if (p == .string) {
            e.prefix = try arena.dupe(u8, p.string);
        };
        if (object.get("suffix")) |p| if (p == .string) {
            e.suffix = try arena.dupe(u8, p.string);
        };
        return e;
    }
};

/// Writes `source` rendered. `gpa` holds the parsed document until the call returns.
pub fn render(
    gpa: Allocator,
    w: *Writer,
    source: []const u8,
    options: Options,
) (Writer.Error || Allocator.Error)!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parser: BlockParser = .{ .arena = arena };
    const normalized = try normalize(arena, source);
    parser.collectDefinitions(normalized);
    const blocks = try parser.parse(normalized);
    var r: Renderer = .{
        .arena = arena,
        .options = options,
        .sheet = options.style,
        .definitions = parser.definitions.items,
    };
    try r.renderBlocks(w, blocks, options.style.margin, true);
}

/// `render` into memory the caller owns.
pub fn renderAlloc(
    gpa: Allocator,
    source: []const u8,
    options: Options,
) (Writer.Error || Allocator.Error)![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render(gpa, &out.writer, source, options);
    return out.toOwnedSlice();
}

/// Tabs to four spaces and CR LF to LF, so the parser sees one kind of line. Other control
/// characters are dropped: a document's own escapes (an OSC 52 setting the clipboard, a
/// title) must not reach the terminal.
fn normalize(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, source.len);
    for (source, 0..) |c, i| switch (c) {
        '\t' => try out.appendSlice(arena, "    "),
        '\r' => {
            const crlf = i + 1 < source.len and source[i + 1] == '\n';
            if (!crlf) try out.append(arena, '\n');
        },
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {},
        else => try out.append(arena, c),
    };
    return out.items;
}

const Block = union(enum) {
    heading: struct { level: u3, text: []const u8 },
    paragraph: []const u8,
    code: struct { language: []const u8, text: []const u8 },
    quote: []const Block,
    list: struct { ordered: bool, start: usize, items: []const Item },
    rule,
    table: struct {
        header: []const []const u8,
        aligns: []const Align,
        rows: []const []const []const u8,
    },
    html: []const u8,
};

const Item = struct { blocks: []const Block, task: ?bool };
const Align = enum { left, center, right };
const Definition = struct { label: []const u8, url: []const u8 };

const BlockParser = struct {
    arena: Allocator,
    definitions: std.ArrayList(Definition) = .empty,
    /// Quotes and list items open inside each other; past `max_nesting`, their markers are
    /// text, so that nesting cannot exhaust the stack.
    depth: usize = 0,

    const max_nesting = 64;

    /// Finds `[label]: url` lines anywhere, for reference links.
    fn collectDefinitions(p: *BlockParser, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " ");
            if (line.len < 4 or line[0] != '[') continue;
            const close = std.mem.indexOf(u8, line, "]:") orelse continue;
            const label = line[1..close];
            var url = std.mem.trim(u8, line[close + 2 ..], " ");
            if (url.len == 0) continue;
            if (std.mem.indexOfScalar(u8, url, ' ')) |space| url = url[0..space];
            url = std.mem.trim(u8, url, "<>");
            p.definitions.append(p.arena, .{ .label = label, .url = url }) catch return;
        }
    }

    fn parse(p: *BlockParser, text: []const u8) Allocator.Error![]const Block {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try lines.append(p.arena, line);
        return p.parseLines(lines.items);
    }

    fn parseLines(p: *BlockParser, lines: []const []const u8) Allocator.Error![]const Block {
        p.depth += 1;
        defer p.depth -= 1;
        const nest = p.depth < max_nesting;
        var blocks: std.ArrayList(Block) = .empty;
        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];
            const trimmed = std.mem.trimStart(u8, line, " ");
            const indent = line.len - trimmed.len;
            if (trimmed.len == 0) {
                i += 1;
                continue;
            }
            // A reference definition takes no room.
            if (isDefinition(trimmed)) {
                i += 1;
                continue;
            }
            if (indent >= 4) {
                // Indented code: until a line indented less (blank lines kept inside).
                var end = i;
                var last = i;
                while (end < lines.len) : (end += 1) {
                    const l = lines[end];
                    if (std.mem.trim(u8, l, " ").len == 0) continue;
                    if (l.len - std.mem.trimStart(u8, l, " ").len < 4) break;
                    last = end;
                }
                var code: std.ArrayList(u8) = .empty;
                for (lines[i .. last + 1], 0..) |l, k| {
                    if (k > 0) try code.append(p.arena, '\n');
                    try code.appendSlice(p.arena, if (l.len >= 4) l[4..] else "");
                }
                try blocks.append(p.arena, .{ .code = .{ .language = "", .text = code.items } });
                i = last + 1;
                continue;
            }
            if (fence(trimmed)) |f| {
                var end = i + 1;
                var code: std.ArrayList(u8) = .empty;
                while (end < lines.len) : (end += 1) {
                    const l = std.mem.trimStart(u8, lines[end], " ");
                    if (std.mem.startsWith(u8, l, f.marker) and
                        std.mem.trim(u8, l[f.marker.len..], &.{f.marker[0]}).len == 0 and
                        std.mem.trim(u8, l, " ").len >= f.marker.len)
                    {
                        break;
                    }
                    if (end > i + 1) try code.append(p.arena, '\n');
                    // Strip as much indentation as the fence had.
                    const line_indent = lines[end].len - std.mem.trimStart(u8, lines[end], " ").len;
                    const strip = @min(indent, line_indent);
                    try code.appendSlice(p.arena, lines[end][strip..]);
                }
                try blocks.append(p.arena, .{
                    .code = .{ .language = f.info, .text = code.items },
                });
                i = end + 1;
                continue;
            }
            if (atxHeading(trimmed)) |h| {
                try blocks.append(p.arena, .{ .heading = .{ .level = h.level, .text = h.text } });
                i += 1;
                continue;
            }
            if (isRule(trimmed)) {
                try blocks.append(p.arena, .rule);
                i += 1;
                continue;
            }
            if (nest and trimmed[0] == '>') {
                var inner: std.ArrayList([]const u8) = .empty;
                while (i < lines.len) : (i += 1) {
                    const l = std.mem.trimStart(u8, lines[i], " ");
                    if (l.len > 0 and l[0] == '>') {
                        const rest = l[1..];
                        const unspaced = if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
                        try inner.append(p.arena, unspaced);
                    } else if (l.len > 0 and inner.items.len > 0 and
                        std.mem.trim(u8, inner.items[inner.items.len - 1], " ").len > 0 and
                        !startsBlock(l))
                    {
                        // A lazy continuation of the quoted paragraph.
                        try inner.append(p.arena, l);
                    } else break;
                }
                try blocks.append(p.arena, .{ .quote = try p.parseLines(inner.items) });
                continue;
            }
            if (if (nest) listMarker(trimmed) else null) |first| {
                const list = try p.parseList(lines, &i, indent, first);
                try blocks.append(p.arena, list);
                continue;
            }
            if (i + 1 < lines.len and isTableStart(line, lines[i + 1])) {
                try blocks.append(p.arena, try p.parseTable(lines, &i));
                continue;
            }
            if (trimmed[0] == '<' and htmlBlock(trimmed)) {
                var end = i;
                while (end < lines.len and std.mem.trim(u8, lines[end], " ").len > 0) end += 1;
                const html = try std.mem.join(p.arena, "\n", lines[i..end]);
                try blocks.append(p.arena, .{ .html = html });
                i = end;
                continue;
            }
            // A paragraph: lines until a blank line or another block; a setext underline
            // makes it a heading.
            var end = i + 1;
            var setext: ?u3 = null;
            while (end < lines.len) : (end += 1) {
                const l = std.mem.trimStart(u8, lines[end], " ");
                if (l.len == 0) break;
                if (setextLevel(l)) |level| {
                    setext = level;
                    break;
                }
                if (startsBlock(l)) break;
            }
            var joined: std.ArrayList(u8) = .empty;
            for (lines[i..end], 0..) |l, k| {
                if (k > 0) try joined.append(p.arena, '\n');
                try joined.appendSlice(p.arena, std.mem.trimStart(u8, l, " "));
            }
            if (setext) |level| {
                try blocks.append(p.arena, .{
                    .heading = .{ .level = level, .text = joined.items },
                });
                i = end + 1;
            } else {
                try blocks.append(p.arena, .{ .paragraph = joined.items });
                i = end;
            }
        }
        return blocks.items;
    }

    fn parseList(
        p: *BlockParser,
        lines: []const []const u8,
        index: *usize,
        indent: usize,
        first: Marker,
    ) Allocator.Error!Block {
        var items: std.ArrayList(Item) = .empty;
        var i = index.*;
        while (i < lines.len) {
            const line = lines[i];
            const trimmed = std.mem.trimStart(u8, line, " ");
            const here = line.len - trimmed.len;
            const marker = listMarker(trimmed) orelse break;
            if (here != indent or marker.ordered != first.ordered) break;
            // The item: its first line after the marker, then the lines indented past it,
            // and blank lines between them.
            const content_indent = here + marker.len;
            var item_lines: std.ArrayList([]const u8) = .empty;
            try item_lines.append(p.arena, trimmed[marker.len..]);
            var end = i + 1;
            while (end < lines.len) : (end += 1) {
                const l = lines[end];
                const t = std.mem.trimStart(u8, l, " ");
                if (t.len == 0) {
                    // A blank line belongs to the item when indented text follows.
                    var look = end + 1;
                    while (look < lines.len and std.mem.trim(u8, lines[look], " ").len == 0) {
                        look += 1;
                    }
                    if (look < lines.len and
                        lines[look].len - std.mem.trimStart(u8, lines[look], " ").len >=
                            content_indent)
                    {
                        try item_lines.append(p.arena, "");
                        continue;
                    }
                    break;
                }
                const l_indent = l.len - t.len;
                if (l_indent >= content_indent) {
                    try item_lines.append(p.arena, l[content_indent..]);
                } else if (listMarker(t) == null and !startsBlock(t) and
                    item_lines.items.len > 0 and
                    std.mem.trim(u8, item_lines.items[item_lines.items.len - 1], " ").len > 0)
                {
                    // A lazy continuation of the item's paragraph.
                    try item_lines.append(p.arena, t);
                } else break;
            }
            var task: ?bool = null;
            const head = item_lines.items[0];
            if (head.len >= 3 and head[0] == '[' and head[2] == ']') {
                const mark = item_lines.items[0][1];
                if (mark == ' ' or mark == 'x' or mark == 'X') {
                    task = mark != ' ';
                    item_lines.items[0] = std.mem.trimStart(u8, item_lines.items[0][3..], " ");
                }
            }
            const item_blocks = try p.parseLines(item_lines.items);
            try items.append(p.arena, .{ .blocks = item_blocks, .task = task });
            i = end;
            // Blank lines between items.
            while (i < lines.len and std.mem.trim(u8, lines[i], " ").len == 0) {
                var look = i;
                while (look < lines.len and std.mem.trim(u8, lines[look], " ").len == 0) look += 1;
                if (look < lines.len) {
                    const t = std.mem.trimStart(u8, lines[look], " ");
                    if (lines[look].len - t.len == indent and listMarker(t) != null) {
                        i = look;
                        break;
                    }
                }
                break;
            }
        }
        index.* = i;
        return .{
            .list = .{ .ordered = first.ordered, .start = first.start, .items = items.items },
        };
    }

    fn parseTable(p: *BlockParser, lines: []const []const u8, index: *usize) Allocator.Error!Block {
        const header = try p.cells(lines[index.*]);
        const delimiters = try p.cells(lines[index.* + 1]);
        const aligns = try p.arena.alloc(Align, delimiters.len);
        for (delimiters, aligns) |d, *a| {
            const left = d.len > 0 and d[0] == ':';
            const right = d.len > 0 and d[d.len - 1] == ':';
            a.* = if (left and right) .center else if (right) .right else .left;
        }
        var rows: std.ArrayList([]const []const u8) = .empty;
        var i = index.* + 2;
        while (i < lines.len) : (i += 1) {
            const l = std.mem.trim(u8, lines[i], " ");
            if (l.len == 0 or std.mem.indexOfScalar(u8, l, '|') == null) break;
            try rows.append(p.arena, try p.cells(lines[i]));
        }
        index.* = i;
        return .{ .table = .{ .header = header, .aligns = aligns, .rows = rows.items } };
    }

    /// The cells of a table row: split at `|` (not escaped, not in code), trimmed.
    fn cells(p: *BlockParser, line: []const u8) Allocator.Error![]const []const u8 {
        var row = std.mem.trim(u8, line, " ");
        if (row.len > 0 and row[0] == '|') row = row[1..];
        const escaped_end = row.len > 1 and row[row.len - 2] == '\\';
        if (row.len > 0 and row[row.len - 1] == '|' and !escaped_end) row = row[0 .. row.len - 1];
        var out: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        var in_code = false;
        var k: usize = 0;
        while (k < row.len) : (k += 1) {
            if (row[k] == '\\') {
                k += 1;
                continue;
            }
            if (row[k] == '`') in_code = !in_code;
            if (row[k] == '|' and !in_code) {
                try out.append(p.arena, std.mem.trim(u8, row[start..k], " "));
                start = k + 1;
            }
        }
        try out.append(p.arena, std.mem.trim(u8, row[start..], " "));
        return out.items;
    }
};

const Marker = struct { ordered: bool, start: usize, len: usize };

/// A list item's marker at the start of `line`: `-`, `*`, `+`, or digits and `.` or `)`,
/// followed by a space (or the end of the line).
fn listMarker(line: []const u8) ?Marker {
    if (line.len == 0) return null;
    if (line[0] == '-' or line[0] == '*' or line[0] == '+') {
        if (line.len == 1) return .{ .ordered = false, .start = 0, .len = 1 };
        if (line[1] != ' ') return null;
        if (isRule(line)) return null;
        return .{ .ordered = false, .start = 0, .len = 2 };
    }
    var n: usize = 0;
    while (n < line.len and n < 9 and std.ascii.isDigit(line[n])) n += 1;
    if (n == 0 or n >= line.len or (line[n] != '.' and line[n] != ')')) return null;
    if (n + 1 < line.len and line[n + 1] != ' ') return null;
    const start = std.fmt.parseInt(usize, line[0..n], 10) catch return null;
    return .{ .ordered = true, .start = start, .len = @min(n + 2, line.len) };
}

const Fence = struct { marker: []const u8, info: []const u8 };

fn fence(line: []const u8) ?Fence {
    if (line.len < 3) return null;
    const c = line[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < line.len and line[n] == c) n += 1;
    if (n < 3) return null;
    const info_all = std.mem.trim(u8, line[n..], " ");
    if (c == '`' and std.mem.indexOfScalar(u8, info_all, '`') != null) return null;
    const info = info_all[0 .. std.mem.indexOfAny(u8, info_all, " {") orelse info_all.len];
    return .{ .marker = line[0..n], .info = info };
}

const Heading = struct { level: u3, text: []const u8 };

fn atxHeading(line: []const u8) ?Heading {
    var n: usize = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < line.len and line[n] != ' ') return null;
    var text = std.mem.trim(u8, line[n..], " ");
    // A closing run of #s, separated by a space, is not part of the text.
    const closing = std.mem.trimEnd(u8, text, "#");
    if (closing.len < text.len and (closing.len == 0 or closing[closing.len - 1] == ' ')) {
        text = std.mem.trimEnd(u8, closing, " ");
    }
    return .{ .level = @intCast(n), .text = text };
}

fn setextLevel(line: []const u8) ?u3 {
    const t = std.mem.trim(u8, line, " ");
    if (t.len == 0) return null;
    for (t) |c| if (c != t[0]) return null;
    return switch (t[0]) {
        '=' => 1,
        '-' => 2,
        else => null,
    };
}

fn isRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " ");
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (t) |ch| {
        if (ch == c) {
            count += 1;
        } else if (ch != ' ') return false;
    }
    return count >= 3;
}

fn isDefinition(line: []const u8) bool {
    if (line.len < 4 or line[0] != '[') return false;
    const close = std.mem.indexOf(u8, line, "]:") orelse return false;
    return close > 1 and std.mem.indexOfScalar(u8, line[0..close], ']') == null;
}

fn htmlBlock(line: []const u8) bool {
    if (line.len < 3) return false;
    const c = line[1];
    return std.ascii.isAlphabetic(c) or c == '/' or c == '!';
}

/// Whether `line` interrupts a paragraph.
fn startsBlock(line: []const u8) bool {
    if (line.len == 0) return true;
    if (atxHeading(line) != null or isRule(line) or fence(line) != null) return true;
    if (line[0] == '>') return true;
    if (listMarker(line)) |m| {
        // Only a non-empty item interrupts, and an ordered one only when it starts at 1.
        return line.len > m.len and (!m.ordered or m.start == 1);
    }
    return false;
}

fn isTableStart(header: []const u8, delimiter: []const u8) bool {
    if (std.mem.indexOfScalar(u8, header, '|') == null) return false;
    const d = std.mem.trim(u8, delimiter, " |");
    if (d.len < 3) return false;
    var dashes = false;
    for (d) |c| switch (c) {
        '-' => dashes = true,
        ':', '|', ' ' => {},
        else => return false,
    };
    return dashes;
}

const Renderer = struct {
    arena: Allocator,
    options: Options,
    sheet: StyleSheet,
    definitions: []const Definition,

    fn renderBlocks(
        r: *Renderer,
        w: *Writer,
        blocks: []const Block,
        indent: usize,
        top: bool,
    ) (Writer.Error || Allocator.Error)!void {
        // A blank line before the document, between blocks, and at its end, as glamour.
        if (top) try w.writeByte('\n');
        for (blocks, 0..) |block, i| {
            if (i > 0) try w.writeAll("\n\n");
            try r.renderBlock(w, block, indent, "");
        }
        if (top and blocks.len > 0) try w.writeByte('\n');
    }

    /// Writes `block`, each line starting with `indent` spaces and `lead` (a quote bar).
    fn renderBlock(
        r: *Renderer,
        w: *Writer,
        block: Block,
        indent: usize,
        lead: []const u8,
    ) (Writer.Error || Allocator.Error)!void {
        const sheet = r.sheet;
        // The margin is kept on the right too.
        const room = r.options.width -| indent -| display.of(lead) -| sheet.margin;
        switch (block) {
            .paragraph => |text| {
                const inline_text = try r.inlineText(text, sheet.paragraph.style);
                try r.writeWrapped(w, inline_text, indent, lead, room);
            },
            .heading => |h| {
                const element = switch (h.level) {
                    1 => sheet.h1,
                    2 => sheet.h2,
                    3 => sheet.h3,
                    4 => sheet.h4,
                    5 => sheet.h5,
                    else => sheet.h6,
                };
                var style = sheet.heading.style;
                inherit(&style, element.style);
                // Prefix, text, and suffix each in the heading's style, so a span inside
                // the text (code, a link) does not end the heading's background.
                var text: Writer.Allocating = .init(r.arena);
                try style.paint(&text.writer, element.prefix);
                try r.writeInline(&text.writer, h.text, style);
                try style.paint(&text.writer, element.suffix);
                try r.writeWrapped(w, text.written(), indent, lead, room);
            },
            .code => |code| try r.renderCode(w, code.language, code.text, indent, lead),
            .quote => |inner| {
                var styled_lead: Writer.Allocating = .init(r.arena);
                try styled_lead.writer.writeAll(lead);
                try sheet.block_quote.style.paint(&styled_lead.writer, sheet.quote_bar);
                // Between the quote's blocks, the bar alone.
                var bar_only: Writer.Allocating = .init(r.arena);
                try bar_only.writer.writeAll(lead);
                const bar = std.mem.trimEnd(u8, sheet.quote_bar, " ");
                try sheet.block_quote.style.paint(&bar_only.writer, bar);
                for (inner, 0..) |child, i| {
                    if (i > 0) {
                        try w.writeByte('\n');
                        try writeLead(w, indent, bar_only.written());
                        try w.writeByte('\n');
                    }
                    try r.renderQuoted(w, child, indent, styled_lead.written());
                }
            },
            .list => |list| {
                for (list.items, 0..) |item, n| {
                    var mark: Writer.Allocating = .init(r.arena);
                    if (list.ordered) {
                        try mark.writer.print("{d}. ", .{list.start + n});
                    } else {
                        try mark.writer.writeAll(sheet.bullet);
                    }
                    if (item.task) |done| {
                        try mark.writer.writeAll(if (done) sheet.task_done else sheet.task_open);
                    }
                    const mark_width = display.of(mark.written());
                    var styled_mark: Writer.Allocating = .init(r.arena);
                    try sheet.enumeration.style.paint(&styled_mark.writer, mark.written());
                    for (item.blocks, 0..) |child, b| {
                        if (b > 0) try w.writeByte('\n');
                        // A paragraph after the first in an item is set apart by a blank line.
                        if (b > 0 and child != .list) try w.writeByte('\n');
                        var out: Writer.Allocating = .init(r.arena);
                        try r.renderBlock(&out.writer, child, 0, "");
                        // The marker on the first line, the rest under the item's text.
                        const rendered = std.mem.trimEnd(u8, out.written(), "\n");
                        var lines = std.mem.splitScalar(u8, rendered, '\n');
                        var first = true;
                        while (lines.next()) |line| {
                            if (!first) try w.writeByte('\n');
                            try writeLead(w, indent, lead);
                            if (first and b == 0) {
                                try w.writeAll(styled_mark.written());
                            } else {
                                try w.splatByteAll(' ', mark_width);
                            }
                            try w.writeAll(line);
                            first = false;
                        }
                    }
                    if (item.blocks.len == 0) {
                        try writeLead(w, indent, lead);
                        try w.writeAll(styled_mark.written());
                    }
                    if (n + 1 < list.items.len) try w.writeByte('\n');
                }
            },
            .rule => {
                try writeLead(w, indent, lead);
                var rule: Writer.Allocating = .init(r.arena);
                try rule.writer.splatBytesAll(sheet.rule, @max(room, 3));
                try sheet.hr.style.paint(w, rule.written());
            },
            .table => |t| try r.renderTable(w, t, indent, lead),
            .html => |html| {
                var lines = std.mem.splitScalar(u8, html, '\n');
                var first = true;
                while (lines.next()) |line| {
                    if (!first) try w.writeByte('\n');
                    first = false;
                    try writeLead(w, indent, lead);
                    try sheet.html.paint(w, line);
                }
            },
        }
    }

    fn renderQuoted(
        r: *Renderer,
        w: *Writer,
        block: Block,
        indent: usize,
        lead: []const u8,
    ) (Writer.Error || Allocator.Error)!void {
        // Quoted text takes the quote's style for its own.
        const saved = r.sheet;
        defer r.sheet = saved;
        inherit(&r.sheet.paragraph.style, saved.block_quote.style);
        try r.renderBlock(w, block, indent, lead);
    }

    fn renderCode(
        r: *Renderer,
        w: *Writer,
        language: []const u8,
        text: []const u8,
        indent: usize,
        lead: []const u8,
    ) (Writer.Error || Allocator.Error)!void {
        var highlighted: Writer.Allocating = .init(r.arena);
        const lang = if (language.len > 0) highlight.language(language) else null;
        if (r.sheet.code_theme) |theme| {
            if (lang) |l| {
                try highlight.write(&highlighted.writer, text, l, theme);
            } else {
                try r.sheet.code_block.style.paint(&highlighted.writer, text);
            }
        } else {
            try highlighted.writer.writeAll(text);
        }
        // Every line made whole, so its colors survive the indentation.
        var whole: Writer.Allocating = .init(r.arena);
        try display.wrapStyled(&whole.writer, highlighted.written(), null);
        var lines = std.mem.splitScalar(u8, whole.written(), '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.writeByte('\n');
            first = false;
            try writeLead(w, indent + 2, lead);
            try w.writeAll(line);
        }
    }

    fn renderTable(
        r: *Renderer,
        w: *Writer,
        t: anytype,
        indent: usize,
        lead: []const u8,
    ) (Writer.Error || Allocator.Error)!void {
        // Cells rendered inline first (emphasis, code, links).
        const columns = t.header.len;
        const header = try r.arena.alloc([]const u8, columns);
        for (header, t.header) |*cell, text| cell.* = try r.inlineText(text, .{ .bold = true });
        const rows = try r.arena.alloc([]const []const u8, t.rows.len);
        for (rows, t.rows) |*row, source| {
            const cells = try r.arena.alloc([]const u8, columns);
            for (cells, 0..) |*cell, c| cell.* = if (c < source.len)
                try r.inlineText(source[c], .{})
            else
                "";
            row.* = cells;
        }
        const Aligns = struct {
            var current: []const Align = &.{};
            fn style(_: ?usize, column: usize) Style {
                const a: Align = if (column < current.len) current[column] else .left;
                return .{
                    .padding = .symmetric(0, 1),
                    .@"align" = switch (a) {
                        .left => .start,
                        .center => .center,
                        .right => .end,
                    },
                };
            }
        };
        Aligns.current = t.aligns;
        const table: Table = .{
            .headers = header,
            .rows = rows,
            .border = r.sheet.table_border,
            .border_style = r.sheet.table.style,
            .lines = .{ .top = false, .bottom = false, .left = false, .right = false },
            .style = Aligns.style,
            .max_width = r.options.width -| indent -| display.of(lead) -| r.sheet.margin,
        };
        var out: Writer.Allocating = .init(r.arena);
        try table.render(r.arena, &out.writer);
        var lines = std.mem.splitScalar(u8, out.written(), '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.writeByte('\n');
            first = false;
            try writeLead(w, indent, lead);
            try w.writeAll(std.mem.trimEnd(u8, line, " "));
        }
    }

    /// Writes styled `text` word-wrapped to `room` columns, each row after `indent`
    /// spaces and `lead`.
    fn writeWrapped(
        r: *Renderer,
        w: *Writer,
        text: []const u8,
        indent: usize,
        lead: []const u8,
        room: usize,
    ) (Writer.Error || Allocator.Error)!void {
        var wrapped: Writer.Allocating = .init(r.arena);
        try display.wrapStyled(&wrapped.writer, text, @max(room, 10));
        var lines = std.mem.splitScalar(u8, wrapped.written(), '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.writeByte('\n');
            first = false;
            try writeLead(w, indent, lead);
            try w.writeAll(line);
        }
    }

    /// `text` with its inline markup rendered, in `base` style.
    fn inlineText(
        r: *Renderer,
        text: []const u8,
        base: Style,
    ) (Writer.Error || Allocator.Error)![]const u8 {
        var out: Writer.Allocating = .init(r.arena);
        try r.writeInline(&out.writer, text, base);
        return out.written();
    }

    /// Writes inline Markdown: emphasis, strong, strikethrough, code, links, images,
    /// autolinks, escapes, entities, emoji, and line breaks, in `base` (plus the
    /// document's own style).
    fn writeInline(
        r: *Renderer,
        w: *Writer,
        text: []const u8,
        base_in: Style,
    ) (Writer.Error || Allocator.Error)!void {
        var base = r.sheet.document.style;
        inherit(&base, base_in);
        try r.inlineSpan(w, text, base);
    }

    fn inlineSpan(
        r: *Renderer,
        w: *Writer,
        text: []const u8,
        style: Style,
    ) (Writer.Error || Allocator.Error)!void {
        const sheet = r.sheet;
        var plain_start: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            const rest = text[i..];
            var consumed: ?usize = null;
            switch (c) {
                '\\' => if (i + 1 < text.len) {
                    if (text[i + 1] == '\n') {
                        try flush(w, text[plain_start..i], style, r);
                        try w.writeByte('\n');
                        consumed = 2;
                    } else if (isPunct(text[i + 1])) {
                        try flush(w, text[plain_start..i], style, r);
                        try style.paint(w, text[i + 1 .. i + 2]);
                        consumed = 2;
                    }
                },
                '`' => {
                    var run: usize = 0;
                    while (run < rest.len and rest[run] == '`') run += 1;
                    if (std.mem.indexOf(u8, rest[run..], rest[0..run])) |end| {
                        try flush(w, text[plain_start..i], style, r);
                        var code = rest[run .. run + end];
                        const padded = code.len > 2 and code[0] == ' ' and
                            code[code.len - 1] == ' ';
                        if (padded) code = code[1 .. code.len - 1];
                        var code_style = style;
                        inherit(&code_style, sheet.code.style);
                        var shown: Writer.Allocating = .init(r.arena);
                        try shown.writer.print(
                            "{s}{s}{s}",
                            .{ sheet.code.prefix, code, sheet.code.suffix },
                        );
                        try code_style.paint(w, shown.written());
                        consumed = run + end + run;
                    } else consumed = null;
                },
                '*', '_', '~' => if (emphasis(rest, i == 0 or isSpaceOrPunct(text[i - 1]))) |em| {
                    try flush(w, text[plain_start..i], style, r);
                    var inner = style;
                    switch (em.kind) {
                        .emph => inherit(&inner, sheet.emph),
                        .strong => inherit(&inner, sheet.strong),
                        .both => {
                            inherit(&inner, sheet.strong);
                            inherit(&inner, sheet.emph);
                        },
                        .strike => inherit(&inner, sheet.strikethrough),
                    }
                    try r.inlineSpan(w, rest[em.open .. em.open + em.inner], inner);
                    consumed = em.open + em.inner + em.open;
                },
                '!' => if (rest.len > 1 and rest[1] == '[') {
                    if (link(rest[1..], r.definitions)) |l| {
                        try flush(w, text[plain_start..i], style, r);
                        try r.writeImage(w, l.text, l.url, style);
                        consumed = 1 + l.len;
                    }
                },
                '[' => if (link(rest, r.definitions)) |l| {
                    try flush(w, text[plain_start..i], style, r);
                    try r.writeLink(w, l.text, l.url, style);
                    consumed = l.len;
                },
                '<' => if (autolink(rest)) |url| {
                    try flush(w, text[plain_start..i], style, r);
                    try r.writeLink(w, "", url, style);
                    consumed = url.len + 2;
                } else if (std.mem.startsWith(u8, rest, "<br") and
                    std.mem.indexOfScalar(u8, rest, '>') != null)
                {
                    try flush(w, text[plain_start..i], style, r);
                    try w.writeByte('\n');
                    consumed = std.mem.indexOfScalar(u8, rest, '>').? + 1;
                },
                'h', 'w' => if ((i == 0 or isSpaceOrPunct(text[i - 1])) and bareUrl(rest) > 0) {
                    const len = bareUrl(rest);
                    try flush(w, text[plain_start..i], style, r);
                    try r.writeLink(w, "", rest[0..len], style);
                    consumed = len;
                },
                '&' => if (entity(rest)) |e| {
                    try flush(w, text[plain_start..i], style, r);
                    try style.paint(w, e.text);
                    consumed = e.len;
                },
                ':' => if (r.options.emoji) if (emojiAt(rest)) |e| {
                    try flush(w, text[plain_start..i], style, r);
                    try style.paint(w, e.glyph);
                    consumed = e.len;
                },
                '\n' => {
                    // Two spaces before a line break make a hard break; otherwise it is a
                    // space, unless line breaks are kept.
                    const hard = i >= 2 and text[i - 1] == ' ' and text[i - 2] == ' ';
                    try flush(w, std.mem.trimEnd(u8, text[plain_start..i], " "), style, r);
                    if (hard or r.options.preserve_newlines)
                        try w.writeByte('\n')
                    else
                        try style.paint(w, " ");
                    consumed = 1;
                },
                else => {},
            }
            if (consumed) |n| {
                i += n;
                plain_start = i;
            } else {
                i += 1;
            }
        }
        try flush(w, text[plain_start..], style, r);
    }

    fn writeLink(
        r: *Renderer,
        w: *Writer,
        text: []const u8,
        url_in: []const u8,
        style: Style,
    ) (Writer.Error || Allocator.Error)!void {
        const url = try r.resolve(url_in);
        var text_style = style;
        inherit(&text_style, r.sheet.link_text);
        var url_style = style;
        inherit(&url_style, r.sheet.link);
        if (r.options.hyperlinks) {
            try w.print(ansi.osc ++ "8;;{s}" ++ ansi.st, .{url});
            if (text.len > 0)
                try r.inlineSpan(w, text, text_style)
            else
                try url_style.paint(w, url);
            try w.writeAll(ansi.osc ++ "8;;" ++ ansi.st);
            return;
        }
        if (text.len > 0 and !std.mem.eql(u8, text, url)) {
            try r.inlineSpan(w, text, text_style);
            try style.paint(w, " ");
        }
        try url_style.paint(w, url);
    }

    fn writeImage(
        r: *Renderer,
        w: *Writer,
        alt: []const u8,
        url_in: []const u8,
        style: Style,
    ) (Writer.Error || Allocator.Error)!void {
        const url = try r.resolve(url_in);
        var text_style = style;
        inherit(&text_style, r.sheet.image_text);
        var url_style = style;
        inherit(&url_style, r.sheet.image);
        var label: Writer.Allocating = .init(r.arena);
        try label.writer.print("Image: {s} →", .{alt});
        try text_style.paint(w, label.written());
        try style.paint(w, " ");
        try url_style.paint(w, url);
    }

    /// `url` resolved against `base_url` when it is relative.
    fn resolve(r: *Renderer, url: []const u8) Allocator.Error![]const u8 {
        const base = r.options.base_url;
        if (base.len == 0 or url.len == 0 or url[0] == '#') return url;
        const absolute = std.mem.indexOf(u8, url, "://") != null or
            std.mem.startsWith(u8, url, "mailto:");
        if (absolute) return url;
        const sep = if (base[base.len - 1] == '/' or url[0] == '/') "" else "/";
        const joined = if (url[0] == '/' and base[base.len - 1] == '/') url[1..] else url;
        return std.fmt.allocPrint(r.arena, "{s}{s}{s}", .{ base, sep, joined });
    }
};

/// Writes plain text in `style`.
fn flush(w: *Writer, text: []const u8, style: Style, r: *Renderer) Writer.Error!void {
    _ = r;
    if (text.len == 0) return;
    try style.paint(w, text);
}

/// Adds `over`'s colors and attributes to `style`.
fn inherit(style: *Style, over: Style) void {
    if (over.fg != .default) style.fg = over.fg;
    if (over.bg != .default) style.bg = over.bg;
    inline for (.{
        "bold", "dim", "italic", "underline", "blink", "reverse", "strikethrough",
    }) |f| {
        if (@field(over, f)) @field(style, f) = true;
    }
}

fn writeLead(w: *Writer, indent: usize, lead: []const u8) Writer.Error!void {
    try w.splatByteAll(' ', indent);
    try w.writeAll(lead);
}

/// ASCII punctuation, as CommonMark counts it.
fn isPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

fn isSpaceOrPunct(c: u8) bool {
    return c == ' ' or c == '\n' or isPunct(c);
}

const Emphasis = struct {
    kind: enum { emph, strong, both, strike },
    /// Delimiter length, and the length of what is between the delimiters.
    open: usize,
    inner: usize,
};

/// Emphasis starting at `rest[0]`: a run of `*`, `_`, or `~~`, text that does not start or
/// end with a space, and the same run closing it. `_` does not open inside a word.
fn emphasis(rest: []const u8, word_start: bool) ?Emphasis {
    const c = rest[0];
    var run: usize = 0;
    while (run < rest.len and rest[run] == c) run += 1;
    if (c == '~' and run != 2) return null;
    if (c == '_' and !word_start) return null;
    const open: usize = @min(run, 3);
    if (open >= rest.len or rest[open] == ' ' or rest[open] == '\n') return null;
    var k: usize = open;
    while (k + open <= rest.len) : (k += 1) {
        if (rest[k] == '`') {
            // Skip code spans inside emphasis.
            const end = std.mem.indexOfScalarPos(u8, rest, k + 1, '`') orelse break;
            k = end;
            continue;
        }
        if (!std.mem.eql(u8, rest[k .. k + open], rest[0..open])) continue;
        if (rest[k - 1] == ' ' or rest[k - 1] == '\n') continue;
        // The closer is not part of a longer run.
        if (k + open < rest.len and rest[k + open] == c) {
            k += 1;
            while (k + open < rest.len and rest[k + open] == c) k += 1;
            continue;
        }
        if (c == '_' and k + open < rest.len and std.ascii.isAlphanumeric(rest[k + open])) continue;
        const kind: @FieldType(Emphasis, "kind") = if (c == '~') .strike else switch (open) {
            1 => .emph,
            2 => .strong,
            else => .both,
        };
        return .{ .kind = kind, .open = open, .inner = k - open };
    }
    return null;
}

const Link = struct { text: []const u8, url: []const u8, len: usize };

/// `[text](url "title")`, `[text][label]`, `[label][]`, or `[label]` with a definition.
fn link(rest: []const u8, definitions: []const Definition) ?Link {
    var depth: usize = 0;
    var close: ?usize = null;
    var k: usize = 0;
    while (k < rest.len) : (k += 1) {
        switch (rest[k]) {
            '\\' => k += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) {
                    close = k;
                    break;
                }
            },
            '\n' => if (k > 0 and rest[k - 1] == '\n') return null,
            else => {},
        }
    }
    const end = close orelse return null;
    const text = rest[1..end];
    const after = rest[end + 1 ..];
    if (after.len > 0 and after[0] == '(') {
        const paren = std.mem.indexOfScalar(u8, after, ')') orelse return null;
        var target = std.mem.trim(u8, after[1..paren], " ");
        if (std.mem.indexOfAny(u8, target, " \"")) |space| target = target[0..space];
        target = std.mem.trim(u8, target, "<>");
        return .{ .text = text, .url = target, .len = end + 1 + paren + 1 };
    }
    if (after.len > 0 and after[0] == '[') {
        const label_end = std.mem.indexOfScalar(u8, after, ']') orelse return null;
        const label = if (label_end == 1) text else after[1..label_end];
        const url = lookup(definitions, label) orelse return null;
        return .{ .text = text, .url = url, .len = end + 1 + label_end + 1 };
    }
    const url = lookup(definitions, text) orelse return null;
    return .{ .text = text, .url = url, .len = end + 1 };
}

fn lookup(definitions: []const Definition, label: []const u8) ?[]const u8 {
    for (definitions) |d| if (std.ascii.eqlIgnoreCase(d.label, label)) return d.url;
    return null;
}

/// The URL of `<scheme://...>` or `<user@host>` at the start of `rest`.
fn autolink(rest: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
    const inner = rest[1..end];
    if (std.mem.indexOfAny(u8, inner, " <\n") != null) return null;
    if (std.mem.indexOf(u8, inner, "://") != null) return inner;
    const email = std.mem.indexOfScalar(u8, inner, '@') != null and
        std.mem.indexOfScalar(u8, inner, '.') != null;
    if (email) return inner;
    return null;
}

/// The length of a bare URL (`https://...`, `http://...`, `www....`) at the start of
/// `rest`, without trailing punctuation; 0 when there is none.
fn bareUrl(rest: []const u8) usize {
    const schemes = [_][]const u8{ "https://", "http://", "www." };
    for (schemes) |scheme| {
        if (!std.mem.startsWith(u8, rest, scheme)) continue;
        var n = scheme.len;
        while (n < rest.len and !std.ascii.isWhitespace(rest[n]) and rest[n] != '<') n += 1;
        const trailing = ".,:;!?)'\"*_~";
        while (n > scheme.len and std.mem.indexOfScalar(u8, trailing, rest[n - 1]) != null) n -= 1;
        if (n > scheme.len) return n;
    }
    return 0;
}

const Entity = struct { text: []const u8, len: usize };

fn entity(rest: []const u8) ?Entity {
    const end = std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 10)], ';') orelse return null;
    const name = rest[1..end];
    const named = [_]struct { []const u8, []const u8 }{
        .{ "amp", "&" },  .{ "lt", "<" },   .{ "gt", ">" }, .{ "quot", "\"" },
        .{ "apos", "'" }, .{ "nbsp", " " },
        .{ "copy", "©" },
        .{ "reg", "®" },
        .{ "trade", "™" },
        .{ "hellip", "…" },
        .{ "mdash", "—" },
        .{ "ndash", "–" },
        .{ "larr", "←" },
        .{ "rarr", "→" },
        .{ "uarr", "↑" },
        .{ "darr", "↓" },
    };
    for (named) |pair| {
        if (std.mem.eql(u8, pair[0], name)) return .{ .text = pair[1], .len = end + 1 };
    }
    if (name.len > 1 and name[0] == '#') {
        const cp = if (name[1] == 'x' or name[1] == 'X')
            std.fmt.parseInt(u21, name[2..], 16) catch return null
        else
            std.fmt.parseInt(u21, name[1..], 10) catch return null;
        const Holder = struct {
            var buffer: [4]u8 = undefined;
        };
        const len = std.unicode.utf8Encode(cp, &Holder.buffer) catch return null;
        return .{ .text = Holder.buffer[0..len], .len = end + 1 };
    }
    return null;
}

/// The emoji for a shortcode's name (`rocket`, `+1`), or null.
pub fn emoji(name: []const u8) ?[]const u8 {
    for (emoji_table) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
    return null;
}

/// Writes `text` with its `:shortcodes:` replaced by emoji.
pub fn writeEmoji(w: *Writer, text: []const u8) Writer.Error!void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < text.len) {
        if (text[i] == ':') if (emojiAt(text[i..])) |e| {
            try w.writeAll(text[start..i]);
            try w.writeAll(e.glyph);
            i += e.len;
            start = i;
            continue;
        };
        i += 1;
    }
    try w.writeAll(text[start..]);
}

const Emoji = struct { glyph: []const u8, len: usize };

fn emojiAt(rest: []const u8) ?Emoji {
    const window = rest[0..@min(rest.len, 40)];
    const end = std.mem.indexOfScalarPos(u8, window, 1, ':') orelse return null;
    const name = rest[1..end];
    if (name.len == 0) return null;
    for (name) |c| {
        const allowed = std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-';
        if (!allowed) return null;
    }
    return .{ .glyph = emoji(name) orelse return null, .len = end + 1 };
}

/// The shortcodes most used in READMEs and changelogs.
const emoji_table = [_]struct { []const u8, []const u8 }{
    .{ "smile", "😄" },
    .{ "smiley", "😃" },
    .{ "grin", "😁" },
    .{ "joy", "😂" },
    .{ "wink", "😉" },
    .{ "heart", "❤️" },
    .{ "+1", "👍" },
    .{ "thumbsup", "👍" },
    .{ "-1", "👎" },
    .{ "thumbsdown", "👎" },
    .{ "tada", "🎉" },
    .{ "rocket", "🚀" },
    .{ "fire", "🔥" },
    .{ "star", "⭐" },
    .{ "sparkles", "✨" },
    .{ "zap", "⚡" },
    .{ "bug", "🐛" },
    .{ "warning", "⚠️" },
    .{ "x", "❌" },
    .{ "white_check_mark", "✅" },
    .{ "heavy_check_mark", "✔️" },
    .{ "check", "✔️" },
    .{ "question", "❓" },
    .{ "exclamation", "❗" },
    .{ "bulb", "💡" },
    .{ "memo", "📝" },
    .{ "book", "📖" },
    .{ "books", "📚" },
    .{ "wrench", "🔧" },
    .{ "hammer", "🔨" },
    .{ "gear", "⚙️" },
    .{ "lock", "🔒" },
    .{ "key", "🔑" },
    .{ "package", "📦" },
    .{ "art", "🎨" },
    .{ "lipstick", "💄" },
    .{ "construction", "🚧" },
    .{ "recycle", "♻️" },
    .{ "boom", "💥" },
    .{ "eyes", "👀" },
    .{ "wave", "👋" },
    .{ "pray", "🙏" },
    .{ "clap", "👏" },
    .{ "muscle", "💪" },
    .{ "coffee", "☕" },
    .{ "beer", "🍺" },
    .{ "pizza", "🍕" },
    .{ "snake", "🐍" },
    .{ "zzz", "💤" },
    .{ "100", "💯" },
    .{ "link", "🔗" },
    .{ "globe_with_meridians", "🌐" },
    .{ "computer", "💻" },
    .{ "chart_with_upwards_trend", "📈" },
    .{ "hourglass", "⌛" },
    .{ "alarm_clock", "⏰" },
    .{ "arrow_right", "➡️" },
    .{ "arrow_left", "⬅️" },
    .{ "arrow_up", "⬆️" },
    .{ "arrow_down", "⬇️" },
    .{ "info", "ℹ️" },
    .{ "no_entry", "⛔" },
    .{ "stop_sign", "🛑" },
    .{ "green_circle", "🟢" },
    .{ "red_circle", "🔴" },
    .{ "yellow_circle", "🟡" },
    .{ "white_circle", "⚪" },
    .{ "black_circle", "⚫" },
};

const testing = std.testing;

fn expectPlain(expected: []const u8, source: []const u8, options: Options) !void {
    const out = try renderAlloc(testing.allocator, source, options);
    defer testing.allocator.free(out);
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try ansi.strip(&plain.writer, out);
    if (!std.mem.eql(u8, expected, plain.written())) {
        std.debug.print("expected:\n{s}\nfound:\n{s}\n", .{ expected, plain.written() });
        return error.TestExpectedEqual;
    }
}

const plain_options: Options = .{ .style = .ascii, .width = 40 };

test "headings, paragraphs, rules" {
    try expectPlain(
        \\
        \\  # Title
        \\
        \\  Some text that goes on and on and
        \\  on, wrapped to the width.
        \\
        \\  ## Sub
        \\
        \\  ------------------------------------
        \\
    , "# Title\n\nSome text that goes on and on and on, wrapped\nto the width.\n\n" ++
        "Sub\n---\n\n***\n", plain_options);
}

test "emphasis, code, links, images, escapes, entities, emoji" {
    try expectPlain(
        \\
        \\  bold italic both strike `code`
        \\  site https://example.com/a
        \\  Image: logo → img.png * & © 🎉
        \\
    , "**bold** *italic* ***both*** ~~strike~~ `code`  \n[site](https://example.com/a)  \n" ++
        "![logo](img.png) \\* &amp; &copy; :tada:", plain_options);
    try expectPlain("\n  ref https://x.org\n", "[ref][r]\n\n[r]: https://x.org", plain_options);
    try expectPlain("\n  see https://a.b/c.\n", "see https://a.b/c.", plain_options);
    try expectPlain("\n  snake_case_word stays\n", "snake_case_word stays", plain_options);
}

test "a document's own escapes and control characters never reach the output" {
    const out = try renderAlloc(
        testing.allocator,
        "x\x1b]52;c;cHdu\x07y [l](http://a\x1b]2;T\x07b)",
        .{ .style = .ascii, .width = 40, .hyperlinks = true },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]52;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]2;") == null);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null);
}

test "lists, nested, tasks, and quotes" {
    try expectPlain(
        \\
        \\  * one
        \\  * two
        \\    1. a
        \\    2. b
        \\  * [x] done
        \\  * [ ] open
        \\
        \\  | quoted text over two lines
        \\  |
        \\  | second paragraph
        \\
    , "- one\n- two\n  1. a\n  2. b\n- [x] done\n- [ ] open\n\n" ++
        "> quoted text\nover two lines\n>\n> second paragraph", plain_options);
}

test "code blocks and tables" {
    try expectPlain(
        \\
        \\    const x = 1;
        \\    // done
        \\
        \\   Name | Port
        \\  ------+------
        \\   api  | 8080
        \\
    , "```zig\nconst x = 1;\n// done\n```\n\n" ++
        "| Name | Port |\n|------|-----:|\n| api | 8080 |", plain_options);
}

test "a table wider than the page shrinks to it, wrapping" {
    const out = try renderAlloc(testing.allocator, "| a | b |\n|---|---|\n| " ++
        "one two three four five six seven | x |", .{ .style = .ascii, .width = 24 });
    defer testing.allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| try testing.expect(display.of(line) <= 24);
}

test "colors, highlighting, hyperlinks, and a JSON style sheet" {
    const source = "# Hi\n\n```zig\nfn x() void {}\n```\n\n[a](https://b)";
    const out = try renderAlloc(testing.allocator, source, .{
        .style = .dark,
        .hyperlinks = true,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;https://b\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;0;170;255mfn") != null); // highlighted
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sheet = try StyleSheet.parse(arena.allocator(),
        \\{"document": {"margin": 0}, "h1": {"prefix": "> ", "color": "#ff0000", "bold": true}}
    , .ascii);
    try testing.expectEqual(0, sheet.margin);
    try testing.expectEqualStrings("> ", sheet.h1.prefix);
    try testing.expectEqual(ansi.Color.hex(0xff0000), sheet.h1.style.fg);
}
