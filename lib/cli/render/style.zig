//! Terminal styling, table layout and small text utilities.
//!
//! This file **is** the type: the file's own scope is `Style`, so a consumer
//! writes `const style = @import("style.zig");` and calls `style.new()`. See the
//! file-layout rule in `.agents/AGENTS.md`.
//!
//! ## Why the helper types stay as declarations inside
//!
//! `Color`, `RGB`, `Border`, `Alignment`, `Column` and `Table` are declared by
//! this file rather than split into their own. That is the point of the
//! file-as-type rule: `style.Color` and `style.Table` keep resolving, because a
//! declaration inside the file's scope is reached through the file either way.
//! Only `style.Style` changed spelling, and nothing referenced it.
//!
//! Splitting them into separate files was the alternative and was rejected: it
//! would have re-spelled every `style.Color`/`style.Table` use site across the
//! repository for no gain, since none of these is independently useful.
//!
//! The free functions here (`visualWidth`, `highlight`, `renderDiff`,
//! `hyperlink`, `joinHorizontal`) are genuinely free - no state, no `self` - and
//! sit at file scope alongside the type.

const std = @import("std");
const assert = std.debug.assert;
const capability = @import("capability.zig");

/// The file is the type. `Style` in this file's API means this struct.
const Self = @This();

/// Constructs a `Style`. Re-exported as a free function so `style.new()` works
/// whether a caller thinks of this file as a type or a namespace.
pub fn new() Self {
    return .{};
}

_bold: bool = false,
_italic: bool = false,
_underline: bool = false,
_faint: bool = false,

_fg: ?RGB = null,
_bg: ?RGB = null,

_border: Border = .none,
_padding: u8 = 0,

pub fn bold(self: Self, val: bool) Self {
    var copy = self;
    copy._bold = val;
    return copy;
}

pub fn italic(self: Self, val: bool) Self {
    var copy = self;
    copy._italic = val;
    return copy;
}

pub fn underline(self: Self, val: bool) Self {
    var copy = self;
    copy._underline = val;
    return copy;
}

pub fn faint(self: Self, val: bool) Self {
    var copy = self;
    copy._faint = val;
    return copy;
}

pub fn foreground(self: Self, c: RGB) Self {
    var copy = self;
    copy._fg = c;
    return copy;
}

pub fn background(self: Self, c: RGB) Self {
    var copy = self;
    copy._bg = c;
    return copy;
}

pub fn border(self: Self, b: Border) Self {
    var copy = self;
    copy._border = b;
    return copy;
}

pub fn padding(self: Self, p: u8) Self {
    var copy = self;
    copy._padding = p;
    return copy;
}

/// Renders the styled text directly to the writer without allocating strings.
///
/// When the process capability says colour is off - `NO_COLOR`, or stdout is not a
/// terminal - the text, padding and border are still written and every escape
/// sequence is dropped. The gate is read **once** rather than per escape: a
/// capability read twice could change between a start sequence and its reset,
/// leaving the terminal in the styled state for everything printed afterwards.
pub fn render(self: Self, writer: anytype, text: []const u8) !void {
    const styled = capability.get().color;

    if (styled) {
        if (self._bold) try writer.writeAll("\x1b[1m");
        if (self._italic) try writer.writeAll("\x1b[3m");
        if (self._underline) try writer.writeAll("\x1b[4m");
        if (self._faint) try writer.writeAll("\x1b[2m");

        if (self._fg) |c| try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        if (self._bg) |c| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
    }

    if (self._border == .rounded) try writer.writeAll("╭ ");

    for (0..self._padding) |_| try writer.writeAll(" ");

    try writer.writeAll(text);

    for (0..self._padding) |_| try writer.writeAll(" ");

    if (self._border == .rounded) try writer.writeAll(" ╮");

    if (styled) try writer.writeAll("\x1b[0m");
}

/// ANSI colour constructors.
pub const Color = struct {
    pub fn rgb(r: u8, g: u8, b: u8) RGB {
        return .{ .r = r, .g = g, .b = b };
    }
};

/// A 24-bit colour.
pub const RGB = struct { r: u8, g: u8, b: u8 };

/// Which border style a `Table` draws.
pub const Border = enum {
    none,
    rounded,
    normal,
    double,
};

/// Helper function to strip ANSI codes and calculate the visual width of a string.
pub fn visualWidth(str: []const u8) usize {
    var width: usize = 0;
    var in_escape = false;

    for (str) |c| {
        if (in_escape) {
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                in_escape = false;
            }
        } else {
            if (c == '\x1b') {
                in_escape = true;
            } else {
                if (c >= 32 and c != 127) {
                    width += 1;
                }
            }
        }
    }
    return width;
}

pub fn getMaxWidth(lines: []const []const u8) usize {
    var max: usize = 0;
    for (lines) |line| {
        const w = visualWidth(line);
        if (w > max) max = w;
    }
    return max;
}

/// Joins two text blocks horizontally without allocating memory.
/// left_lines and right_lines are arrays of lines.
pub fn joinHorizontal(writer: anytype, left_lines: []const []const u8, right_lines: []const []const u8, gap: usize) !void {
    const left_height = left_lines.len;
    const right_height = right_lines.len;
    const height = @max(left_height, right_height);

    const left_max_width = getMaxWidth(left_lines);

    for (0..height) |i| {
        // Render left line
        if (i < left_height) {
            try writer.writeAll(left_lines[i]);
        }

        // Pad left line up to max width
        const current_left_width = if (i < left_height) visualWidth(left_lines[i]) else 0;
        const padding_needed = left_max_width - current_left_width + gap;
        for (0..padding_needed) |_| {
            try writer.writeAll(" ");
        }

        // Render right line
        if (i < right_height) {
            try writer.writeAll(right_lines[i]);
        }

        if (i != height - 1) {
            try writer.writeAll("\n");
        }
    }
}

/// Renders an OSC 8 terminal hyperlink: \x1b]8;;<URL>\x1b\<TEXT>\x1b]8;;\x1b\
/// Emits OSC 8 hyperlink text.
///
/// Gated on `color` rather than emitted unconditionally: OSC 8 is a terminal
/// escape, so into a pipe or under `NO_COLOR` it is noise the reader has to
/// scroll past, and the link text alone is the useful half.
pub fn hyperlink(writer: anytype, url: []const u8, text: []const u8) !void {
    if (!capability.get().color) return writer.writeAll(text);
    try writer.print("\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ url, text });
}

/// Zero-dependency line-by-line terminal diff viewer.
pub fn renderDiff(writer: anytype, old_content: []const u8, new_content: []const u8) !void {
    const styled = capability.get().color;

    var old_lines = std.mem.splitScalar(u8, old_content, '\n');
    var new_lines = std.mem.splitScalar(u8, new_content, '\n');

    while (true) {
        const o = old_lines.next();
        const n = new_lines.next();

        if (o == null and n == null) break;

        if (o != null and n != null) {
            const old_l = std.mem.trim(u8, o.?, "\r");
            const new_l = std.mem.trim(u8, n.?, "\r");
            if (std.mem.eql(u8, old_l, new_l)) {
                try writer.print("  {s}\n", .{old_l});
            } else {
                try emitDiffLine(writer, styled, '-', old_l);
                try emitDiffLine(writer, styled, '+', new_l);
            }
        } else if (o != null) {
            try emitDiffLine(writer, styled, '-', std.mem.trim(u8, o.?, "\r"));
        } else if (n != null) {
            try emitDiffLine(writer, styled, '+', std.mem.trim(u8, n.?, "\r"));
        }
    }
}

/// One added or removed line. The `-`/`+` marker carries the meaning on its own,
/// which is why the uncoloured form is still unambiguous rather than merely plain.
fn emitDiffLine(writer: anytype, styled: bool, marker: u8, line: []const u8) !void {
    assert(marker == '-' or marker == '+');

    if (!styled) return writer.print("{c} {s}\n", .{ marker, line });

    const color_code: []const u8 = if (marker == '-') "31" else "32";
    try writer.print("\x1b[{s}m{c} {s}\x1b[0m\n", .{ color_code, marker, line });
}

/// How a column's cells are aligned within their width.
pub const Alignment = enum { left, center, right };

/// One table column.
pub const Column = struct {
    header: []const u8,
    alignment: Alignment = .left,
    max_width: ?usize = null,
};

/// A bordered text table.
pub const Table = struct {
    columns: []const Column,
    rows: []const []const []const u8,
    border: Border = .rounded,
    padding: usize = 1,

    pub fn render(self: Table, writer: anytype) !void {
        if (self.columns.len == 0) return;

        var col_widths: [32]usize = undefined;
        const num_cols = @min(self.columns.len, 32);

        for (0..num_cols) |c| {
            var max_w = visualWidth(self.columns[c].header);
            for (self.rows) |row| {
                if (c < row.len) {
                    const cell_w = visualWidth(row[c]);
                    if (cell_w > max_w) max_w = cell_w;
                }
            }
            if (self.columns[c].max_width) |mw| {
                if (max_w > mw) max_w = mw;
            }
            col_widths[c] = max_w;
        }

        const BorderChars = struct {
            tl: []const u8,
            tm: []const u8,
            tr: []const u8,
            ml: []const u8,
            mm: []const u8,
            mr: []const u8,
            bl: []const u8,
            bm: []const u8,
            br: []const u8,
            h: []const u8,
            v: []const u8,
        };

        const chars: ?BorderChars = switch (self.border) {
            .rounded => .{
                .tl = "╭",
                .tm = "┬",
                .tr = "╮",
                .ml = "├",
                .mm = "┼",
                .mr = "┤",
                .bl = "╰",
                .bm = "┴",
                .br = "╯",
                .h = "─",
                .v = "│",
            },
            .normal => .{
                .tl = "┌",
                .tm = "┬",
                .tr = "┐",
                .ml = "├",
                .mm = "┼",
                .mr = "┤",
                .bl = "└",
                .bm = "┴",
                .br = "┘",
                .h = "─",
                .v = "│",
            },
            .double => .{
                .tl = "╔",
                .tm = "╦",
                .tr = "╗",
                .ml = "╠",
                .mm = "╬",
                .mr = "╣",
                .bl = "╚",
                .bm = "╩",
                .br = "╝",
                .h = "═",
                .v = "║",
            },
            .none => null,
        };

        if (chars) |b| {
            try writer.writeAll(b.tl);
            for (0..num_cols) |c| {
                const total_cell_w = col_widths[c] + (self.padding * 2);
                for (0..total_cell_w) |_| try writer.writeAll(b.h);
                if (c + 1 < num_cols) try writer.writeAll(b.tm);
            }
            try writer.writeAll(b.tr);
            try writer.writeAll("\n");
        }

        if (chars) |b| try writer.writeAll(b.v);
        for (0..num_cols) |c| {
            for (0..self.padding) |_| try writer.writeAll(" ");
            const hdr = self.columns[c].header;
            const w = col_widths[c];
            try renderAligned(writer, hdr, w, self.columns[c].alignment);
            for (0..self.padding) |_| try writer.writeAll(" ");
            if (chars) |b| {
                try writer.writeAll(b.v);
            } else if (c + 1 < num_cols) {
                try writer.writeAll("  ");
            }
        }
        try writer.writeAll("\n");

        if (chars) |b| {
            try writer.writeAll(b.ml);
            for (0..num_cols) |c| {
                const total_cell_w = col_widths[c] + (self.padding * 2);
                for (0..total_cell_w) |_| try writer.writeAll(b.h);
                if (c + 1 < num_cols) try writer.writeAll(b.mm);
            }
            try writer.writeAll(b.mr);
            try writer.writeAll("\n");
        }

        for (self.rows) |row| {
            if (chars) |b| try writer.writeAll(b.v);
            for (0..num_cols) |c| {
                for (0..self.padding) |_| try writer.writeAll(" ");
                const text = if (c < row.len) row[c] else "";
                const w = col_widths[c];
                try renderAligned(writer, text, w, self.columns[c].alignment);
                for (0..self.padding) |_| try writer.writeAll(" ");
                if (chars) |b| {
                    try writer.writeAll(b.v);
                } else if (c + 1 < num_cols) {
                    try writer.writeAll("  ");
                }
            }
            try writer.writeAll("\n");
        }

        if (chars) |b| {
            try writer.writeAll(b.bl);
            for (0..num_cols) |c| {
                const total_cell_w = col_widths[c] + (self.padding * 2);
                for (0..total_cell_w) |_| try writer.writeAll(b.h);
                if (c + 1 < num_cols) try writer.writeAll(b.bm);
            }
            try writer.writeAll(b.br);
            try writer.writeAll("\n");
        }
    }
};

fn renderAligned(writer: anytype, text: []const u8, width: usize, align_mode: Alignment) !void {
    const v_w = visualWidth(text);
    if (v_w >= width) {
        if (v_w > width and width > 3) {
            try writer.writeAll(text[0 .. width - 3]);
            try writer.writeAll("...");
        } else {
            try writer.writeAll(text[0..@min(text.len, width)]);
        }
        return;
    }

    const pad = width - v_w;
    switch (align_mode) {
        .left => {
            try writer.writeAll(text);
            for (0..pad) |_| try writer.writeAll(" ");
        },
        .right => {
            for (0..pad) |_| try writer.writeAll(" ");
            try writer.writeAll(text);
        },
        .center => {
            const left_pad = pad / 2;
            const right_pad = pad - left_pad;
            for (0..left_pad) |_| try writer.writeAll(" ");
            try writer.writeAll(text);
            for (0..right_pad) |_| try writer.writeAll(" ");
        },
    }
}

/// Minimal, zero-allocation micro syntax highlighter for JSON, Zig/C keywords, and key-values.
///
/// A disabled highlighter is the identity function, and saying so once here is
/// both cheaper and clearer than guarding each of the five branches below.
pub fn highlight(writer: anytype, code: []const u8) !void {
    if (!capability.get().color) return writer.writeAll(code);

    var i: usize = 0;
    while (i < code.len) {
        const c = code[i];

        // Line comment: // or #
        if ((c == '/' and i + 1 < code.len and code[i + 1] == '/') or c == '#') {
            const start = i;
            while (i < code.len and code[i] != '\n') : (i += 1) {}
            try writer.print("\x1b[2m{s}\x1b[0m", .{code[start..i]});
            continue;
        }

        // Strings: "..." or '...'
        if (c == '"' or c == '\'') {
            const quote = c;
            const start = i;
            i += 1;
            while (i < code.len and (code[i] != quote or code[i - 1] == '\\')) : (i += 1) {}
            if (i < code.len) i += 1; // Include closing quote
            try writer.print("\x1b[32m{s}\x1b[0m", .{code[start..i]});
            continue;
        }

        // Numbers: 12345
        if (c >= '0' and c <= '9') {
            const start = i;
            while (i < code.len and ((code[i] >= '0' and code[i] <= '9') or code[i] == '.' or code[i] == 'x' or (code[i] >= 'a' and code[i] <= 'f') or (code[i] >= 'A' and code[i] <= 'F'))) : (i += 1) {}
            try writer.print("\x1b[33m{s}\x1b[0m", .{code[start..i]});
            continue;
        }

        // Identifiers / Keywords
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            const start = i;
            while (i < code.len and ((code[i] >= 'a' and code[i] <= 'z') or (code[i] >= 'A' and code[i] <= 'Z') or (code[i] >= '0' and code[i] <= '9') or code[i] == '_')) : (i += 1) {}
            const word = code[start..i];

            const keywords = [_][]const u8{
                "const", "var",    "fn",     "pub",       "return", "struct",   "enum",   "union",
                "true",  "false",  "null",   "undefined", "import", "if",       "else",   "while",
                "for",   "switch", "try",    "catch",     "defer",  "errdefer", "SELECT", "FROM",
                "WHERE", "INSERT", "UPDATE", "DELETE",
            };
            var is_kw = false;
            for (keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    is_kw = true;
                    break;
                }
            }

            if (is_kw) {
                try writer.print("\x1b[35m{s}\x1b[0m", .{word});
            } else {
                try writer.writeAll(word);
            }
            continue;
        }

        // Default: write character
        try writer.writeByte(c);
        i += 1;
    }
}

test "the file is the Style type, and new() is reachable both ways" {
    // `Self` is this file, so `Self{}` and the free `new()` must agree. This is
    // what the file-as-type rule buys: one spelling, no `.Style` suffix.
    const via_free = new();
    const via_default: Self = .{};
    try std.testing.expectEqual(via_default._bold, via_free._bold);

    // Builder methods return the same type and do not mutate the receiver.
    const base = new();
    const styled_bold = base.bold(true);
    try std.testing.expect(!base._bold);
    try std.testing.expect(styled_bold._bold);
}

test "helpers stay reachable through the file (Color, Table, Column)" {
    // The point of keeping these as declarations: `style.Color` and
    // `style.Table` must still resolve. Asserted here so a future split cannot
    // silently re-spell every call site.
    const rgb = Color.rgb(1, 2, 3);
    try std.testing.expectEqual(@as(u8, 1), rgb.r);

    const cols = [_]Column{.{ .header = "h" }};
    const table = Table{ .columns = &cols, .rows = &.{} };
    try std.testing.expectEqual(@as(usize, 1), table.columns.len);
}

test "render emits the attributes it was given" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try new().bold(true).render(&w, "x");
    // Bold on, reset off.
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "\x1b[1m"));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1b[0m"));
}

test "visualWidth ignores ANSI escapes" {
    try std.testing.expectEqual(@as(usize, 3), visualWidth("abc"));
    try std.testing.expectEqual(@as(usize, 3), visualWidth("\x1b[31mabc\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 0), visualWidth("\x1b[0m"));
}

test "Highlight colours keywords and passes other words through" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try highlight(&w, "const x");
    const out = w.buffered();
    // `const` is a keyword, so it is wrapped; `x` is not.
    try std.testing.expect(std.mem.indexOf(u8, out, "const") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[35m") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, " x"));
}

/// Runs `body` with colour forced off, restoring the process capability after.
///
/// The gate is process-wide, so a test that flips it must put it back or it leaks
/// into every test that runs afterwards - a failure that would look like a
/// rendering bug in an unrelated file.
fn withColorDisabled(body: anytype) !void {
    const saved = capability.get();
    defer capability.set(saved);

    capability.set(.{ .color = false, .cursor = saved.cursor, .interactive = saved.interactive });
    try body();
}

test "render drops every escape when colour is disabled, keeping the text" {
    try withColorDisabled(struct {
        fn run() !void {
            var buf: [128]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try new().bold(true).foreground(Color.rgb(1, 2, 3)).padding(1).render(&w, "hello");

            const out = w.buffered();
            try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null);
            // The text and the padding survive; only the styling is gone.
            try std.testing.expectEqualStrings(" hello ", out);
        }
    }.run);
}

test "render keeps the border when colour is disabled" {
    try withColorDisabled(struct {
        fn run() !void {
            var buf: [128]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try new().border(.rounded).render(&w, "hi");

            const out = w.buffered();
            try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null);
            // Box-drawing is structure, not colour, so it stays.
            try std.testing.expectEqualStrings("╭ hi ╮", out);
        }
    }.run);
}

test "highlight becomes the identity function when colour is disabled" {
    try withColorDisabled(struct {
        fn run() !void {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try highlight(&w, "const x = 42; // note");
            // Byte-for-byte the input, so the caller can rely on it not to
            // mangle what it is shown.
            try std.testing.expectEqualStrings("const x = 42; // note", w.buffered());
        }
    }.run);
}

test "renderDiff keeps the +/- markers when colour is disabled" {
    try withColorDisabled(struct {
        fn run() !void {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try renderDiff(&w, "a\nb", "a\nc");

            const out = w.buffered();
            try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null);
            // The marker carries the meaning, so the plain form is unambiguous.
            try std.testing.expectEqualStrings("  a\n- b\n+ c\n", out);
        }
    }.run);
}

test "hyperlink degrades to its text when colour is disabled" {
    try withColorDisabled(struct {
        fn run() !void {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try hyperlink(&w, "https://example.com", "example");
            try std.testing.expectEqualStrings("example", w.buffered());
        }
    }.run);
}
