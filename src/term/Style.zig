//! A visual style: colors, attributes, padding, margin, border, size, and alignment,
//! declared as a struct literal and applied with `render`:
//!
//! ```zig
//! const title: term.Style = .{ .fg = .hex(0xff8700), .bold = true, .padding = .symmetric(0, 1) };
//! try title.render(w, "Hello");
//! ```
//!
//! `render` lays text out as a rectangular block (every line the same width). `paint` only
//! wraps text in the colors and attributes, for spans inside a line. Colors are written at
//! full fidelity; `tui.Program` lowers them to the terminal's capability as frames go out, and
//! `renderFor` does it directly for other output.
//!
//! Width rules: `width` includes padding but not border or margin; text wider than the
//! content area is word-wrapped. `height` is a minimum and includes vertical padding.
//! `max_width` and `max_height` cut the finished block, border and margin included.
//! Colors and attributes are applied line by line, so they never bleed into the border,
//! margin, or the next line. Text containing its own SGR reset ends this style's colors
//! at that point; nest styles by rendering the inner text first and padding the outer.
//! Tabs become `tab_width` spaces before anything is measured.

const std = @import("std");
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");
const capability = @import("capability.zig");
const layout = @import("layout.zig");
const display = @import("width.zig");

const Style = @This();

/// See `ansi.Color`.
pub const Color = ansi.Color;
/// See `layout.Position`.
pub const Position = layout.Position;

fg: Color = .default,
bg: Color = .default,
bold: bool = false,
dim: bool = false,
italic: bool = false,
underline: bool = false,
/// How `underline` is drawn. Terminals that know only the single line draw that.
underline_style: Underline = .single,
/// The underline's color (SGR 58); `.default` follows the text. Dropped below 256 colors.
underline_color: Color = .default,
blink: bool = false,
reverse: bool = false,
strikethrough: bool = false,
padding: Sides = .{},
margin: Sides = .{},
border: ?Border = null,
border_fg: Color = .default,
border_bg: Color = .default,
/// Which sides of `border` are drawn.
border_sides: BorderSides = .{},
/// Colors for single sides of the border, over `border_fg`.
border_side_fg: SideColors = .{},
/// A gradient around the border, clockwise from the top left (two or more colors), over
/// `border_fg`; as Lip Gloss v2's border blend.
border_blend: []const Color = &.{},
/// Text set into the top border, as panels label themselves.
border_title: []const u8 = "",
border_title_align: Position = .start,
/// The margin's background; the terminal's own when `.default`.
margin_bg: Color = .default,
/// Columns, including padding; text is wrapped to fit. Null: as wide as the text.
width: ?usize = null,
/// A minimum number of rows, including padding.
height: ?usize = null,
/// At most this many columns, border and margin included: longer lines are cut.
max_width: ?usize = null,
/// At most this many rows: rows past it are dropped.
max_height: ?usize = null,
/// Horizontal alignment of lines narrower than the content area.
@"align": Position = .start,
/// Vertical alignment of the text when `height` leaves rows to spare.
valign: Position = .start,
/// Render on one line: newlines are dropped, and padding, margin, border, and sizes are
/// ignored (for styling a span inside a line).
@"inline": bool = false,
/// The spaces a tab becomes; null leaves tabs alone (they then take no columns).
tab_width: ?u8 = 4,
/// Rewrites the text before it is laid out (to upper case, say).
transform: ?*const fn (text: []const u8, w: *Writer) Writer.Error!void = null,
/// A hyperlink (OSC 8) around the text of every line.
hyperlink: []const u8 = "",

/// The shape of an underline (SGR `4:n`).
pub const Underline = enum(u3) {
    single = 1,
    double = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

/// Which sides of a border to draw.
pub const BorderSides = struct {
    top: bool = true,
    right: bool = true,
    bottom: bool = true,
    left: bool = true,

    /// Only the top and bottom.
    pub const horizontal: BorderSides = .{ .left = false, .right = false };
    /// Only the left and right.
    pub const vertical: BorderSides = .{ .top = false, .bottom = false };
};

/// A color per side; `.default` takes the border's own.
pub const SideColors = struct {
    top: Color = .default,
    right: Color = .default,
    bottom: Color = .default,
    left: Color = .default,
};

/// Space on each side, in columns (left, right) or rows (top, bottom).
pub const Sides = struct {
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    left: usize = 0,

    /// The same space on all four sides.
    pub fn all(n: usize) Sides {
        return .{ .top = n, .right = n, .bottom = n, .left = n };
    }

    /// `vertical` rows above and below, `horizontal` columns left and right.
    pub fn symmetric(vertical: usize, horizontal: usize) Sides {
        return .{ .top = vertical, .right = horizontal, .bottom = vertical, .left = horizontal };
    }
};

/// The glyphs of a box. Each must be one column wide.
pub const Border = struct {
    top: []const u8,
    bottom: []const u8,
    left: []const u8,
    right: []const u8,
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,

    /// Square corners.
    pub const normal: Border = box("─", "│", "┌", "┐", "└", "┘");
    /// Rounded corners.
    pub const rounded: Border = box("─", "│", "╭", "╮", "╰", "╯");
    /// Heavy lines.
    pub const thick: Border = box("━", "┃", "┏", "┓", "┗", "┛");
    /// Double lines.
    pub const double: Border = box("═", "║", "╔", "╗", "╚", "╝");
    /// For terminals without box drawing characters.
    pub const ascii: Border = box("-", "|", "+", "+", "+", "+");
    /// Invisible: keeps the space a border would take.
    pub const hidden: Border = box(" ", " ", " ", " ", " ", " ");
    /// Full blocks.
    pub const block: Border = box("█", "█", "█", "█", "█", "█");
    /// Half blocks outside the content: a thin frame that looks drawn around it.
    pub const outer_half_block: Border = .{
        .top = "▀",
        .bottom = "▄",
        .left = "▌",
        .right = "▐",
        .top_left = "▛",
        .top_right = "▜",
        .bottom_left = "▙",
        .bottom_right = "▟",
    };
    /// Half blocks inside the content's cells.
    pub const inner_half_block: Border = .{
        .top = "▄",
        .bottom = "▀",
        .left = "▐",
        .right = "▌",
        .top_left = "▗",
        .top_right = "▖",
        .bottom_left = "▝",
        .bottom_right = "▘",
    };
    /// Markdown table pipes: `|` sides, `-` rules, `|` corners.
    pub const markdown: Border = box("-", "|", "|", "|", "|", "|");

    fn box(
        horizontal: []const u8,
        vertical: []const u8,
        tl: []const u8,
        tr: []const u8,
        bl: []const u8,
        br: []const u8,
    ) Border {
        return .{
            .top = horizontal,
            .bottom = horizontal,
            .left = vertical,
            .right = vertical,
            .top_left = tl,
            .top_right = tr,
            .bottom_left = bl,
            .bottom_right = br,
        };
    }
};

/// Whether this style sets any color or attribute.
pub fn hasSgr(style: Style) bool {
    return style.fg != .default or style.bg != .default or style.bold or style.dim or
        style.italic or style.underline or style.blink or style.reverse or
        style.strikethrough;
}

/// Writes the SGR sequence that turns this style's colors and attributes on, or nothing
/// when it has none.
pub fn writeSgr(style: Style, w: *Writer) Writer.Error!void {
    if (!style.hasSgr()) return;
    const codes = [_]struct { bool, u8 }{
        .{ style.bold, '1' },          .{ style.dim, '2' },
        .{ style.italic, '3' },        .{ style.underline, '4' },
        .{ style.blink, '5' },         .{ style.reverse, '7' },
        .{ style.strikethrough, '9' },
    };
    try w.writeAll(ansi.csi);
    var first = true;
    for (codes) |code| {
        if (!code[0]) continue;
        if (!first) try w.writeByte(';');
        first = false;
        try w.writeByte(code[1]);
        if (code[1] == '4' and style.underline_style != .single) {
            try w.print(":{d}", .{@backingInt(style.underline_style)});
        }
    }
    const underline_color = if (style.underline) style.underline_color else .default;
    inline for (.{
        .{ style.fg, Color.Layer.fg },
        .{ style.bg, Color.Layer.bg },
        .{ underline_color, Color.Layer.underline },
    }) |pair| {
        if (pair[0] != .default) {
            if (!first) try w.writeByte(';');
            first = false;
            try pair[0].writeParams(w, pair[1]);
        }
    }
    try w.writeByte('m');
}

/// Writes `text` in this style's colors and attributes, followed by a reset, with no
/// layout: padding, border, size, and alignment are ignored.
pub fn paint(style: Style, w: *Writer, text: []const u8) Writer.Error!void {
    if (!style.hasSgr() or text.len == 0) return w.writeAll(text);
    try style.writeSgr(w);
    try w.writeAll(text);
    try w.writeAll(ansi.reset);
}

/// Writes `text` laid out as a block in this style. Lines are separated by `\n`; there is
/// no trailing newline.
pub fn render(style: Style, w: *Writer, text: []const u8) Writer.Error!void {
    if (style.@"inline") return style.renderInline(w, text);
    const box = style.measure(text);
    var out: Out = .{
        .w = w,
        .max_rows = style.max_height orelse std.math.maxInt(usize),
        .max_columns = style.max_width orelse std.math.maxInt(usize),
    };
    for (0..style.margin.top) |_| try style.marginRow(&out, box);
    if (style.border != null and style.border_sides.top) try style.borderRow(&out, box, .top);
    for (0..style.padding.top) |_| try style.contentRow(&out, box, "", 0);
    const above = style.valign.offset(box.text_rows, box.content_rows);
    for (0..above) |_| try style.contentRow(&out, box, "", 0);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var tabs: [tab_buffer]u8 = undefined;
        const line = style.expandTabs(raw, &tabs);
        if (style.width == null) {
            try style.contentRow(&out, box, line, display.of(line));
            continue;
        }
        var wrapper: display.Wrapper = .init(line, box.limit);
        while (wrapper.next()) |row| try style.contentRow(&out, box, row.bytes, row.width);
    }
    for (0..box.content_rows - box.text_rows - above) |_| {
        try style.contentRow(&out, box, "", 0);
    }
    for (0..style.padding.bottom) |_| try style.contentRow(&out, box, "", 0);
    if (style.border != null and style.border_sides.bottom) try style.borderRow(&out, box, .bottom);
    for (0..style.margin.bottom) |_| try style.marginRow(&out, box);
}

/// The longest line whose tabs are expanded; a longer one keeps them.
const tab_buffer = 4096;

/// `line` with each tab replaced by `tab_width` spaces, in `buffer` when it fits.
fn expandTabs(style: Style, line: []const u8, buffer: *[tab_buffer]u8) []const u8 {
    const tab_width = style.tab_width orelse return line;
    const tabs = std.mem.count(u8, line, "\t");
    if (tabs == 0) return line;
    if (line.len + tabs * tab_width > buffer.len) return line;
    var len: usize = 0;
    for (line) |c| {
        if (c == '\t') {
            @memset(buffer[len..][0..tab_width], ' ');
            len += tab_width;
        } else {
            buffer[len] = c;
            len += 1;
        }
    }
    return buffer[0..len];
}

fn renderInline(style: Style, w: *Writer, text: []const u8) Writer.Error!void {
    if (style.hyperlink.len > 0) try w.print(ansi.osc ++ "8;;{s}" ++ ansi.st, .{style.hyperlink});
    try style.writeSgr(w);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var budget = style.max_width orelse std.math.maxInt(usize);
    while (lines.next()) |raw| {
        var tabs: [tab_buffer]u8 = undefined;
        const line = style.expandTabs(raw, &tabs);
        const line_width = display.of(line);
        if (line_width <= budget) {
            try style.writeText(w, line);
            budget -= line_width;
        } else {
            try display.truncate(w, line, budget, "");
            budget = 0;
        }
    }
    if (style.hasSgr()) try w.writeAll(ansi.reset);
    if (style.hyperlink.len > 0) try w.writeAll(ansi.osc ++ "8;;" ++ ansi.st);
}

fn writeText(style: Style, w: *Writer, text: []const u8) Writer.Error!void {
    if (style.transform) |transform| return transform(text, w);
    try w.writeAll(text);
}

/// `render`, with colors lowered to what `level` can show.
pub fn renderFor(
    style: Style,
    w: *Writer,
    level: capability.Color,
    text: []const u8,
) Writer.Error!void {
    try style.lowered(level).render(w, text);
}

/// This style with its colors lowered to what `level` can show; attributes are kept.
pub fn lowered(style: Style, level: capability.Color) Style {
    var copy = style;
    copy.fg = style.fg.downsample(level);
    copy.bg = style.bg.downsample(level);
    copy.border_fg = style.border_fg.downsample(level);
    copy.border_bg = style.border_bg.downsample(level);
    copy.underline_color = switch (level) {
        .none, .basic => .default,
        else => style.underline_color.downsample(level),
    };
    return copy;
}

/// The size `render` would produce for `text`, in columns and rows.
pub fn size(style: Style, text: []const u8) layout.Size {
    if (style.@"inline") {
        var total: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var tabs: [tab_buffer]u8 = undefined;
            total += display.of(style.expandTabs(raw, &tabs));
        }
        return .{ .width = @min(total, style.max_width orelse total), .height = 1 };
    }
    const box = style.measure(text);
    const top: usize = @intFromBool(style.border != null and style.border_sides.top);
    const bottom: usize = @intFromBool(style.border != null and style.border_sides.bottom);
    const rows = style.margin.top + top + style.padding.top + box.content_rows +
        style.padding.bottom + bottom + style.margin.bottom;
    return .{
        .width = @min(box.outer, style.max_width orelse box.outer),
        .height = @min(rows, style.max_height orelse rows),
    };
}

const Box = struct {
    /// Columns text is wrapped to, when the style has a width.
    limit: usize,
    /// Columns for text.
    inner: usize,
    /// Rows the text takes after wrapping.
    text_rows: usize,
    /// Rows between the vertical padding: `text_rows` or more, to honor `height`.
    content_rows: usize,
    /// Columns of a whole line, margins included.
    outer: usize,
    /// Rows of the border's sides: the content rows and the padding.
    side_rows: usize,
};

fn measure(style: Style, text: []const u8) Box {
    const horizontal_padding = style.padding.left + style.padding.right;
    const limit = if (style.width) |w| @max(1, w -| horizontal_padding) else 0;
    var text_rows: usize = 0;
    var widest: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var tabs: [tab_buffer]u8 = undefined;
        const line = style.expandTabs(raw, &tabs);
        if (style.width == null) {
            text_rows += 1;
            widest = @max(widest, display.of(line));
            continue;
        }
        var wrapper: display.Wrapper = .init(line, limit);
        while (wrapper.next()) |row| {
            text_rows += 1;
            widest = @max(widest, row.width);
        }
    }
    // Only a character wider than the whole row makes `widest` exceed `limit`.
    var inner = @max(limit, widest);
    // The title widens a box too narrow for it.
    if (style.border != null and style.border_sides.top and style.border_title.len > 0) {
        inner = @max(inner, display.of(style.border_title) + 4 -| horizontal_padding);
    }
    const vertical_padding = style.padding.top + style.padding.bottom;
    const minimum = (style.height orelse 0) -| vertical_padding;
    const left: usize = @intFromBool(style.border != null and style.border_sides.left);
    const right: usize = @intFromBool(style.border != null and style.border_sides.right);
    const content_rows = @max(text_rows, minimum);
    return .{
        .limit = limit,
        .inner = inner,
        .text_rows = text_rows,
        .content_rows = content_rows,
        .outer = style.margin.left + left + horizontal_padding + inner + right + style.margin.right,
        .side_rows = content_rows + vertical_padding,
    };
}

/// Where rows go: the writer, which row is next, and the limits rows are cut to.
const Out = struct {
    w: *Writer,
    /// Rows written so far.
    row: usize = 0,
    max_rows: usize,
    max_columns: usize,
    /// Columns left on the current row.
    left: usize = 0,
    /// The row being written is past `max_rows`, and is dropped.
    dropped: bool = false,

    fn start(out: *Out) Writer.Error!void {
        out.dropped = out.row >= out.max_rows;
        if (!out.dropped and out.row > 0) try out.w.writeByte('\n');
        out.row += 1;
        out.left = out.max_columns;
    }

    fn spaces(out: *Out, n: usize) Writer.Error!void {
        if (out.dropped) return;
        const shown = @min(n, out.left);
        try out.w.splatByteAll(' ', shown);
        out.left -= shown;
    }

    /// Writes `text`, `columns` wide, cut to what is left of the row (a wide character
    /// the cut splits becomes a space, so the row keeps its width).
    fn text(out: *Out, bytes: []const u8, columns: usize) Writer.Error!void {
        if (out.dropped) return;
        if (columns <= out.left) {
            try out.w.writeAll(bytes);
            out.left -= columns;
            return;
        }
        var it: display.Iterator = .init(bytes);
        while (it.next()) |cluster| {
            if (cluster.escape) {
                try out.w.writeAll(cluster.bytes);
            } else if (cluster.width <= out.left) {
                try out.w.writeAll(cluster.bytes);
                out.left -= cluster.width;
            } else if (out.left > 0) {
                try out.w.splatByteAll(' ', out.left);
                out.left = 0;
            }
        }
    }

    fn raw(out: *Out, bytes: []const u8) Writer.Error!void {
        if (!out.dropped) try out.w.writeAll(bytes);
    }
};

fn marginRow(style: Style, out: *Out, box: Box) Writer.Error!void {
    try out.start();
    try style.marginSpaces(out, box.outer);
}

fn marginSpaces(style: Style, out: *Out, n: usize) Writer.Error!void {
    if (n == 0) return;
    if (style.margin_bg == .default) return out.spaces(n);
    const margin: Style = .{ .bg = style.margin_bg };
    try margin.writeSgr(out.w);
    try out.spaces(n);
    try out.raw(ansi.reset);
}

fn contentRow(
    style: Style,
    out: *Out,
    box: Box,
    line: []const u8,
    line_width: usize,
) Writer.Error!void {
    try out.start();
    const side = out.row - 1 - style.margin.top -
        @intFromBool(style.border != null and style.border_sides.top);
    try style.marginSpaces(out, style.margin.left);
    if (style.border) |border| if (style.border_sides.left) {
        try style.borderGlyph(out, border.left, .left, box, side);
    };
    if (!out.dropped) try style.writeSgr(out.w);
    const before = style.@"align".offset(line_width, box.inner);
    try out.spaces(style.padding.left + before);
    if (style.hyperlink.len > 0 and line.len > 0) {
        try out.raw(ansi.osc ++ "8;;");
        try out.raw(style.hyperlink);
        try out.raw(ansi.st);
    }
    if (style.transform != null and line_width <= out.left and !out.dropped) {
        try style.writeText(out.w, line);
        out.left -= line_width;
    } else {
        try out.text(line, line_width);
    }
    if (style.hyperlink.len > 0 and line.len > 0) try out.raw(ansi.osc ++ "8;;" ++ ansi.st);
    try out.spaces(box.inner -| (before + line_width) + style.padding.right);
    if (style.hasSgr()) try out.raw(ansi.reset);
    if (style.border) |border| if (style.border_sides.right) {
        try style.borderGlyph(out, border.right, .right, box, side);
    };
    try style.marginSpaces(out, style.margin.right);
}

const Edge = enum { top, right, bottom, left };

fn borderRow(style: Style, out: *Out, box: Box, edge: Edge) Writer.Error!void {
    const border = style.border.?;
    try out.start();
    try style.marginSpaces(out, style.margin.left);
    const corners = if (edge == .top)
        .{ border.top_left, border.top, border.top_right }
    else
        .{ border.bottom_left, border.bottom, border.bottom_right };
    const span = style.padding.left + box.inner + style.padding.right;
    const sides = style.border_sides;
    // Without a blend, the row is one color, opened once.
    const blended = style.border_blend.len > 1;
    const row_style: Style = .{ .fg = style.sideColor(edge), .bg = style.border_bg };
    if (!blended and !out.dropped) try row_style.writeSgr(out.w);
    var position: usize = 0;
    if (sides.left) {
        try style.rowGlyph(out, corners[0], edge, box, position, blended);
        position += 1;
    }
    // The title sits in the top border: a rule, a space, the title, a space, the rule.
    const title = if (edge == .top) style.border_title else "";
    const title_width = display.of(title);
    const fits = title.len > 0 and title_width + 4 <= span;
    const title_at = if (fits)
        1 + style.border_title_align.offset(title_width + 2, span - 2)
    else
        span;
    var column: usize = 0;
    while (column < span) {
        if (column == title_at) {
            try out.spaces(1);
            try out.text(title, title_width);
            try out.spaces(1);
            column += title_width + 2;
            position += title_width + 2;
            continue;
        }
        try style.rowGlyph(out, corners[1], edge, box, position, blended);
        column += 1;
        position += 1;
    }
    if (sides.right) try style.rowGlyph(out, corners[2], edge, box, position, blended);
    if (!blended and row_style.hasSgr()) try out.raw(ansi.reset);
    try style.marginSpaces(out, style.margin.right);
}

fn rowGlyph(
    style: Style,
    out: *Out,
    glyph: []const u8,
    edge: Edge,
    box: Box,
    at: usize,
    blended: bool,
) Writer.Error!void {
    if (blended) return style.borderGlyph(out, glyph, edge, box, at);
    try out.text(glyph, 1);
}

/// The color of a side of the border: its own, else `border_fg`.
fn sideColor(style: Style, edge: Edge) Color {
    const side_fg = switch (edge) {
        .top => style.border_side_fg.top,
        .right => style.border_side_fg.right,
        .bottom => style.border_side_fg.bottom,
        .left => style.border_side_fg.left,
    };
    return if (side_fg != .default) side_fg else style.border_fg;
}

/// Writes one border glyph in its color: the blend's at its place around the border (`at`
/// counts along the edge, from its start), else its side's, else `border_fg`.
fn borderGlyph(
    style: Style,
    out: *Out,
    glyph: []const u8,
    edge: Edge,
    box: Box,
    at: usize,
) Writer.Error!void {
    var fg = style.sideColor(edge);
    if (style.border_blend.len > 1) {
        // Clockwise from the top left: the top edge, the right side, the bottom edge back
        // to the left, the left side up.
        const across = box.outer - style.margin.left - style.margin.right;
        const down = box.side_rows;
        const perimeter = 2 * across + 2 * down;
        const index = switch (edge) {
            .top => at,
            .right => across + at,
            .bottom => across + down + (across - 1 - @min(at, across - 1)),
            .left => 2 * across + down + (down - 1 - @min(at, down - 1)),
        };
        const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(perimeter));
        fg = Color.around(style.border_blend, t);
    }
    const border_style: Style = .{ .fg = fg, .bg = style.border_bg };
    if (out.dropped) return;
    if (out.left == 0) return;
    try border_style.writeSgr(out.w);
    try out.text(glyph, 1);
    if (border_style.hasSgr()) try out.raw(ansi.reset);
}

/// Writes `text` with the clusters at `indices` (cluster positions, ascending) in
/// `matched` and the others in `unmatched`, as Lip Gloss's `StyleRunes`: for showing what
/// a filter matched.
pub fn paintRunes(
    w: *Writer,
    text: []const u8,
    indices: []const usize,
    matched: Style,
    unmatched: Style,
) Writer.Error!void {
    var it: display.Iterator = .init(text);
    var position: usize = 0;
    var next: usize = 0;
    var run_start: usize = 0;
    var run_matched: ?bool = null;
    while (it.next()) |cluster| {
        if (cluster.escape) continue;
        const start = it.index - cluster.bytes.len;
        while (next < indices.len and indices[next] < position) next += 1;
        const is_match = next < indices.len and indices[next] == position;
        if (run_matched) |m| if (m != is_match) {
            try (if (m) matched else unmatched).paint(w, text[run_start..start]);
            run_start = start;
        };
        run_matched = is_match;
        position += 1;
    }
    if (run_matched) |m| try (if (m) matched else unmatched).paint(w, text[run_start..]);
}

const testing = std.testing;

fn expectRender(expected: []const u8, style: Style, text: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try style.render(&w, text);
    try testing.expectEqualStrings(expected, w.buffered());
    const got = style.size(text);
    const shape = layout.size(w.buffered());
    try testing.expectEqual(shape.width, got.width);
    try testing.expectEqual(shape.height, got.height);
}

test "render: a plain style writes the text unchanged" {
    try expectRender("hello", .{}, "hello");
    try expectRender("", .{}, "");
}

test "render: colors and attributes, byte for byte" {
    try expectRender("\x1b[1;31mhi\x1b[0m", .{ .fg = .red, .bold = true }, "hi");
    try expectRender("\x1b[2;3;4;5;7;9mx\x1b[0m", .{
        .dim = true,
        .italic = true,
        .underline = true,
        .blink = true,
        .reverse = true,
        .strikethrough = true,
    }, "x");
    try expectRender("\x1b[38;2;255;135;0;48;5;17mx\x1b[0m", .{
        .fg = .hex(0xff8700),
        .bg = .{ .indexed = 17 },
    }, "x");
    try expectRender("\x1b[104mx\x1b[0m", .{ .bg = .bright_blue }, "x");
}

test "render: underline shapes and colors" {
    try expectRender("\x1b[4:3;58;5;1mx\x1b[0m", .{
        .underline = true,
        .underline_style = .curly,
        .underline_color = .red,
    }, "x");
    try expectRender("\x1b[4:2mx\x1b[0m", .{ .underline = true, .underline_style = .double }, "x");
    // Without `underline`, neither the shape nor the color is written.
    try expectRender("x", .{ .underline_style = .dotted, .underline_color = .red }, "x");
}

test "render: multi-line text becomes a rectangle, colored line by line" {
    try expectRender("ab \ncde", .{}, "ab\ncde");
    try expectRender("\x1b[32mab \x1b[0m\n\x1b[32mcde\x1b[0m", .{ .fg = .green }, "ab\ncde");
}

test "render: padding and margin" {
    try expectRender("     \n  x  \n     ", .{ .padding = .symmetric(1, 2) }, "x");
    try expectRender(" x  ", .{ .margin = .{ .left = 1, .right = 2 } }, "x");
    try expectRender("\x1b[41m x \x1b[0m", .{ .bg = .red, .padding = .symmetric(0, 1) }, "x");
    try expectRender("   \n x ", .{ .margin = .{ .top = 1, .left = 1, .right = 1 } }, "x");
}

test "render: borders" {
    try expectRender("╭──╮\n│hi│\n╰──╯", .{ .border = .rounded }, "hi");
    try expectRender(
        "+---+\n| a |\n+---+",
        .{ .border = .ascii, .padding = .symmetric(0, 1) },
        "a",
    );
    try expectRender(
        "\x1b[34m┌─┐\x1b[0m\n\x1b[34m│\x1b[0mx\x1b[34m│\x1b[0m\n\x1b[34m└─┘\x1b[0m",
        .{ .border = .normal, .border_fg = .blue },
        "x",
    );
    const thick: Style = .{ .border = .thick, .margin = .{ .left = 1 } };
    try expectRender(" ┏━┓\n ┃x┃\n ┗━┛", thick, "x");
    try expectRender("╔══╗\n║中║\n╚══╝", .{ .border = .double }, "中");
}

test "render: width wraps and aligns" {
    try expectRender("the  \nquick\nfox  ", .{ .width = 5 }, "the quick fox");
    try expectRender("  the\nquick\n  fox", .{ .width = 5, .@"align" = .end }, "the quick fox");
    try expectRender(" the \nquick\n fox ", .{ .width = 5, .@"align" = .center }, "the quick fox");
    try expectRender(" ab  ", .{ .width = 5, .padding = .{ .left = 1 } }, "ab");
    try expectRender("abc\nd  ", .{ .width = 3 }, "abcd");
    // Alignment without a width uses the widest line.
    try expectRender("  a\nbcd", .{ .@"align" = .end }, "a\nbcd");
}

test "render: height is a minimum, with vertical alignment" {
    try expectRender("x\n \n ", .{ .height = 3 }, "x");
    try expectRender(" \nx\n ", .{ .height = 3, .valign = .center }, "x");
    try expectRender(" \n \nx", .{ .height = 3, .valign = .end }, "x");
    try expectRender("a\nb", .{ .height = 1 }, "a\nb");
    try expectRender("  \n x\n  ", .{ .height = 3, .padding = .{ .top = 1, .left = 1 } }, "x");
}

test "render: escapes in the text do not count toward width" {
    try expectRender("\x1b[1mab\x1b[0m\nc ", .{}, "\x1b[1mab\x1b[0m\nc");
}

test "renderFor: colors lowered to the capability" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const style: Style = .{
        .fg = .hex(0xff8700),
        .bold = true,
        .border = .ascii,
        .border_fg = .hex(0x0000ff),
    };
    try style.renderFor(&w, .none, "x");
    try testing.expectEqualStrings("+-+\n|\x1b[1mx\x1b[0m|\n+-+", w.buffered());
    w = .fixed(&buffer);
    try style.renderFor(&w, .ansi256, "x");
    try testing.expectEqualStrings(
        "\x1b[38;5;21m+-+\x1b[0m\n\x1b[38;5;21m|\x1b[0m\x1b[1;38;5;208mx\x1b[0m" ++
            "\x1b[38;5;21m|\x1b[0m\n\x1b[38;5;21m+-+\x1b[0m",
        w.buffered(),
    );
}

test paint {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const style: Style = .{ .fg = .cyan, .underline = true, .width = 20, .border = .normal };
    try style.paint(&w, "span");
    try style.paint(&w, "");
    try (Style{}).paint(&w, "plain");
    try testing.expectEqualStrings("\x1b[4;36mspan\x1b[0mplain", w.buffered());
}

test "render: max width and height cut the finished block" {
    try expectRender("╭──\n│ab\n╰──", .{ .border = .rounded, .max_width = 3 }, "abcd");
    try expectRender("a\nb", .{ .max_height = 2 }, "a\nb\nc");
    try expectRender("中 ", .{ .max_width = 3 }, "中文");
}

test "render: tabs, inline, transform, hyperlink, margin color" {
    try expectRender("a    b", .{}, "a\tb");
    try expectRender("a\tb", .{ .tab_width = null }, "a\tb");
    const spanned: Style = .{ .@"inline" = true, .bold = true, .padding = .all(2) };
    try expectRender("\x1b[1mab\x1b[0m", spanned, "a\nb");
    const upper = struct {
        fn f(text: []const u8, w: *Writer) Writer.Error!void {
            for (text) |c| try w.writeByte(std.ascii.toUpper(c));
        }
    }.f;
    try expectRender("HI ", .{ .transform = upper, .width = 3 }, "hi");
    try expectRender("\x1b]8;;http://x\x1b\\go\x1b]8;;\x1b\\", .{ .hyperlink = "http://x" }, "go");
    const colored_margin: Style = .{ .margin = .symmetric(0, 1), .margin_bg = .blue };
    try expectRender("\x1b[44m \x1b[0mx\x1b[44m \x1b[0m", colored_margin, "x");
}

test "render: border sides, side colors, titles" {
    try expectRender("──\nab\n──", .{ .border = .normal, .border_sides = .horizontal }, "ab");
    try expectRender("│ab│", .{ .border = .normal, .border_sides = .vertical }, "ab");
    try expectRender("ab│\n──┘", .{
        .border = .normal,
        .border_sides = .{ .top = false, .left = false },
    }, "ab");
    try expectRender(
        "\x1b[31m┌─┐\x1b[0m\n│x│\n└─┘",
        .{ .border = .normal, .border_side_fg = .{ .top = .red } },
        "x",
    );
    try expectRender("╭─ Log ──╮\n│ abcdef │\n╰────────╯", .{
        .border = .rounded,
        .border_title = "Log",
        .padding = .symmetric(0, 1),
    }, "abcdef");
    try expectRender("╭── Log ───╮\n│ abcdefgh │\n╰──────────╯", .{
        .border = .rounded,
        .border_title = "Log",
        .border_title_align = .center,
        .padding = .symmetric(0, 1),
    }, "abcdefgh");
    // A box too narrow for its title widens to fit it.
    const titled: Style = .{ .border = .normal, .border_title = "Title" };
    try expectRender("┌─ Title ─┐\n│x        │\n└─────────┘", titled, "x");
}

test "render: a border blend goes around in color" {
    var buffer: [4096]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const style: Style = .{
        .border = .normal,
        .border_blend = &.{ .hex(0xff0000), .hex(0x0000ff) },
    };
    try style.render(&w, "abc");
    // Every glyph has its own color; the top left starts red.
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "\x1b[38;2;255;0;0m┌"));
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try ansi.strip(&plain.writer, w.buffered());
    try testing.expectEqualStrings("┌───┐\n│abc│\n└───┘", plain.written());
}

test paintRunes {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try paintRunes(&w, "hello", &.{ 0, 1, 4 }, .{ .bold = true }, .{});
    try testing.expectEqualStrings("\x1b[1mhe\x1b[0mll\x1b[1mo\x1b[0m", w.buffered());
}

test "size matches render for every combination" {
    const texts = [_][]const u8{ "", "a", "hello world", "a\nbb\nccc", "中文 text" };
    const styles = [_]Style{
        .{},
        .{ .padding = .all(1) },
        .{ .border = .rounded, .margin = .all(2) },
        .{ .width = 4, .height = 6, .valign = .end },
        .{ .width = 1, .border = .normal, .padding = .symmetric(1, 0) },
        .{ .border = .thick, .border_sides = .{ .left = false }, .max_width = 5 },
        .{ .border = .double, .border_title = "T", .max_height = 2 },
    };
    for (styles) |style| {
        for (texts) |text| {
            var buffer: [2048]u8 = undefined;
            var w: Writer = .fixed(&buffer);
            try style.render(&w, text);
            const shape = layout.size(w.buffered());
            const got = style.size(text);
            try testing.expectEqual(shape.height, got.height);
            try testing.expectEqual(shape.width, got.width);
            // Rectangular: every line is as wide as the widest.
            var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
            while (lines.next()) |line| try testing.expectEqual(got.width, display.of(line));
        }
    }
}
