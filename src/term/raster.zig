//! A terminal screen drawn as pixels, as vhs and freeze draw them: every cell of a
//! `vt.Screen` in its colors, its text in a TrueType font (bold and italic from the font's
//! own faces, or drawn from the regular one), box drawing and block characters drawn
//! exactly so lines join, underlines and strikethrough, the cursor, and around it all a
//! window: padding, a title bar with its three buttons, rounded corners, a margin, and a
//! drop shadow.
//!
//! ```zig
//! var painter: term.raster.Painter = try .init(gpa, fonts, .{ .font_size = 22 });
//! defer painter.deinit();
//! var img = try painter.paint(&screen);
//! defer img.deinit(gpa);
//! var framed = try term.raster.decorate(gpa, &img, .{ .window_bar = .colorful });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const Image = image.Image;
const Rgba = image.Rgba;
const TrueType = @import("TrueType.zig");
const vt = @import("vt.zig");
const ansi = @import("ansi.zig");
const width = @import("width.zig");

/// The faces text is drawn in. Bold and italic are drawn from `regular` when missing;
/// `fallbacks` are tried, in order, for characters `regular` lacks (CJK, symbols).
pub const Fonts = struct {
    regular: TrueType,
    bold: ?TrueType = null,
    italic: ?TrueType = null,
    bold_italic: ?TrueType = null,
    fallbacks: []const TrueType = &.{},
};

/// How cells are drawn as pixels.
pub const Options = struct {
    /// Pixels per em.
    font_size: f32 = 22,
    /// Line height as a multiple of the font's own.
    line_height: f32 = 1.0,
    /// Extra pixels between cells.
    letter_spacing: f32 = 0,
    /// Draw the cursor where the screen has it, when it shows.
    cursor: bool = true,
    /// Keep rows down to the last that shows anything only (freeze); off, every row.
    trim: bool = false,
};

const GlyphKey = struct { font: u8, glyph: u16, bold: bool, italic: bool };

/// Draws screens with a set of fonts, caching glyphs.
pub const Painter = struct {
    gpa: Allocator,
    fonts: Fonts,
    options: Options,
    cell_width: usize,
    cell_height: usize,
    baseline: usize,
    cache: std.AutoHashMapUnmanaged(GlyphKey, TrueType.Mask) = .empty,

    /// A painter for `fonts`. Free with `deinit`.
    pub fn init(gpa: Allocator, fonts: Fonts, options: Options) Painter {
        const f = &fonts.regular;
        const s = f.scale(options.font_size);
        const advance: f32 = @floatFromInt(f.advance(f.glyphIndex('M')));
        const ascent = @as(f32, @floatFromInt(f.ascent)) * s;
        const descent = @as(f32, @floatFromInt(-@as(i32, f.descent))) * s;
        const gap = @as(f32, @floatFromInt(f.line_gap)) * s;
        const line = (ascent + descent + gap) * options.line_height;
        const cell_height: usize = @intFromFloat(@max(1, @round(line)));
        const extra = @as(f32, @floatFromInt(cell_height)) - (ascent + descent);
        return .{
            .gpa = gpa,
            .fonts = fonts,
            .options = options,
            .cell_width = @intFromFloat(@max(1, @round(advance * s + options.letter_spacing))),
            .cell_height = cell_height,
            .baseline = @intFromFloat(@round(ascent + extra / 2)),
        };
    }

    /// Frees the glyph cache.
    pub fn deinit(p: *Painter) void {
        var it = p.cache.valueIterator();
        while (it.next()) |mask| mask.deinit(p.gpa);
        p.cache.deinit(p.gpa);
    }

    /// The image size for a screen of `columns` by `rows`.
    pub fn size(p: *const Painter, columns: usize, rows: usize) [2]usize {
        return .{ columns * p.cell_width, rows * p.cell_height };
    }

    /// The rows `paint` draws for `screen`.
    pub fn rowsOf(p: *const Painter, screen: *vt.Screen) usize {
        if (!p.options.trim) return screen.size.height;
        var rows: usize = 1;
        for (0..screen.size.height) |r| if (!screen.rowIsBlank(r)) {
            rows = r + 1;
        };
        return rows;
    }

    /// Draws `screen` into a new image (the caller frees it).
    pub fn paint(p: *Painter, screen: *vt.Screen) Allocator.Error!Image {
        const rows = p.rowsOf(screen);
        const dims = p.size(screen.size.width, rows);
        var img: Image = try .init(p.gpa, dims[0], dims[1]);
        errdefer img.deinit(p.gpa);
        try p.paintInto(&img, screen, 0, 0);
        return img;
    }

    /// Draws `screen` with its top left at `x`, `y` of `img`.
    pub fn paintInto(
        p: *Painter,
        img: *Image,
        screen: *vt.Screen,
        x: usize,
        y: usize,
    ) Allocator.Error!void {
        const rows = p.rowsOf(screen);
        const background = rgba(screen.background);
        img.fillRect(
            @intCast(x),
            @intCast(y),
            screen.size.width * p.cell_width,
            rows * p.cell_height,
            background,
        );
        for (0..rows) |r| {
            for (0..screen.size.width) |c| {
                const cell = screen.cell(r, c);
                if (cell.tail) continue;
                const colors = screen.colorsOf(cell);
                const span: usize = if (cell.wide) 2 else 1;
                const cx = x + c * p.cell_width;
                const cy = y + r * p.cell_height;
                if (!std.meta.eql(colors.bg, screen.background)) {
                    img.fillRect(
                        @intCast(cx),
                        @intCast(cy),
                        span * p.cell_width,
                        p.cell_height,
                        rgba(colors.bg),
                    );
                }
                if (cell.len == 0 or cell.pen.invisible) continue;
                const fg = rgba(colors.fg);
                try p.drawCluster(
                    img,
                    cell.bytes(),
                    cx,
                    cy,
                    span,
                    fg,
                    cell.pen.bold,
                    cell.pen.italic,
                );
                if (cell.pen.underline != .none) {
                    p.underline(img, cx, cy, span, fg, cell.pen.underline);
                }
                if (cell.pen.strikethrough) {
                    const thickness = @max(1, p.cell_height / 16);
                    img.fillRect(
                        @intCast(cx),
                        @intCast(cy + p.cell_height / 2),
                        span * p.cell_width,
                        thickness,
                        fg,
                    );
                }
                if (cell.pen.overline) img.fillRect(
                    @intCast(cx),
                    @intCast(cy),
                    span * p.cell_width,
                    @max(1, p.cell_height / 16),
                    fg,
                );
            }
        }
        if (p.options.cursor and screen.cursor_visible and screen.row < rows) {
            const cx = x + screen.column * p.cell_width;
            const cy = y + screen.row * p.cell_height;
            const color = rgba(screen.foreground);
            switch (screen.cursor_shape) {
                .block => {
                    // Reverse the cell, as terminals do.
                    img.fillRect(@intCast(cx), @intCast(cy), p.cell_width, p.cell_height, color);
                    const cell = screen.cell(screen.row, screen.column);
                    if (cell.len > 0 and !cell.tail) {
                        try p.drawCluster(
                            img,
                            cell.bytes(),
                            cx,
                            cy,
                            if (cell.wide) 2 else 1,
                            background,
                            cell.pen.bold,
                            cell.pen.italic,
                        );
                    }
                },
                .underline => img.fillRect(
                    @intCast(cx),
                    @intCast(cy + p.cell_height - @max(2, p.cell_height / 10)),
                    p.cell_width,
                    @max(2, p.cell_height / 10),
                    color,
                ),
                .bar => img.fillRect(
                    @intCast(cx),
                    @intCast(cy),
                    @max(2, p.cell_width / 8),
                    p.cell_height,
                    color,
                ),
            }
        }
    }

    fn underline(
        p: *Painter,
        img: *Image,
        cx: usize,
        cy: usize,
        span: usize,
        color: Rgba,
        shape: @import("Pen.zig").Underline,
    ) void {
        const thickness = @max(1, p.cell_height / 16);
        const y = cy + @min(p.cell_height - thickness, p.baseline + thickness * 2);
        const w = span * p.cell_width;
        switch (shape) {
            .double => {
                img.fillRect(@intCast(cx), @intCast(y - thickness), w, thickness, color);
                img.fillRect(@intCast(cx), @intCast(y + thickness), w, thickness, color);
            },
            .dotted, .dashed => {
                const step: usize = if (shape == .dotted) thickness * 2 else p.cell_width / 2;
                var x: usize = 0;
                while (x < w) : (x += step * 2) img.fillRect(
                    @intCast(cx + x),
                    @intCast(y),
                    @min(step, w - x),
                    thickness,
                    color,
                );
            },
            .curly => {
                for (0..w) |x| {
                    const phase = @as(f32, @floatFromInt(x)) /
                        @as(f32, @floatFromInt(p.cell_width)) * 2 * std.math.pi;
                    const amplitude: f32 = @floatFromInt(thickness);
                    const dy: isize = @intFromFloat(@round(@sin(phase) * amplitude));
                    img.fillRect(
                        @intCast(cx + x),
                        @as(isize, @intCast(y)) + dy,
                        1,
                        thickness,
                        color,
                    );
                }
            },
            else => img.fillRect(@intCast(cx), @intCast(y), w, thickness, color),
        }
    }

    /// Draws one grapheme cluster in a cell (two for a wide one).
    fn drawCluster(
        p: *Painter,
        img: *Image,
        bytes: []const u8,
        cx: usize,
        cy: usize,
        span: usize,
        color: Rgba,
        bold: bool,
        italic: bool,
    ) Allocator.Error!void {
        const view = std.unicode.Utf8View.init(bytes) catch return;
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse return;
        if (p.drawBox(img, cp, cx, cy, span, color, bold)) return;
        // The face for the style, and a font that has the character.
        const chosen = p.faceFor(cp, bold, italic);
        const mask = try p.glyph(
            chosen.index,
            chosen.font,
            cp,
            chosen.fake_bold,
            chosen.fake_italic,
        ) orelse return;
        // Centered in the cells it takes (a wide glyph across two).
        const s = chosen.font.scale(p.options.font_size);
        const advance_units = chosen.font.advance(chosen.font.glyphIndex(cp));
        const advance = @as(f32, @floatFromInt(advance_units)) * s;
        const room: f32 = @floatFromInt(span * p.cell_width);
        const dx: isize = @intFromFloat(@round((room - advance) / 2));
        const gx = @as(isize, @intCast(cx)) + dx + mask.left;
        const gy = @as(isize, @intCast(cy + p.baseline)) + mask.top;
        img.blendMask(gx, gy, mask.width, mask.height, mask.pixels, color);
        // Combining marks after the base, drawn over it.
        while (it.nextCodepoint()) |mark| {
            if (width.ofCodepoint(mark) != 0) continue;
            const m = try p.glyph(
                chosen.index,
                chosen.font,
                mark,
                chosen.fake_bold,
                chosen.fake_italic,
            ) orelse continue;
            img.blendMask(
                @as(isize, @intCast(cx)) + dx + m.left,
                gy - mask.top + m.top,
                m.width,
                m.height,
                m.pixels,
                color,
            );
        }
    }

    const Choice = struct { font: *const TrueType, index: u8, fake_bold: bool, fake_italic: bool };

    fn faceFor(p: *const Painter, cp: u21, bold: bool, italic: bool) Choice {
        const f = &p.fonts;
        const styled: ?*const TrueType = if (bold and italic)
            (if (f.bold_italic) |*x| x else null)
        else if (bold)
            (if (f.bold) |*x| x else null)
        else if (italic)
            (if (f.italic) |*x| x else null)
        else
            null;
        if (styled) |font| if (font.has(cp)) return .{
            .font = font,
            .index = if (bold and italic) 3 else if (bold) 1 else 2,
            .fake_bold = false,
            .fake_italic = false,
        };
        if (f.regular.has(cp) or f.fallbacks.len == 0) {
            return .{
                .font = &f.regular,
                .index = 0,
                .fake_bold = bold and styled == null,
                .fake_italic = italic and styled == null,
            };
        }
        for (f.fallbacks, 0..) |*font, i| if (font.has(cp)) {
            return .{
                .font = font,
                .index = @intCast(4 + @min(i, 250)),
                .fake_bold = bold,
                .fake_italic = italic,
            };
        };
        return .{ .font = &f.regular, .index = 0, .fake_bold = bold, .fake_italic = italic };
    }

    fn glyph(
        p: *Painter,
        index: u8,
        font: *const TrueType,
        cp: u21,
        bold: bool,
        italic: bool,
    ) Allocator.Error!?*const TrueType.Mask {
        const id = font.glyphIndex(cp);
        const key: GlyphKey = .{ .font = index, .glyph = id, .bold = bold, .italic = italic };
        const got = try p.cache.getOrPut(p.gpa, key);
        if (!got.found_existing) {
            got.value_ptr.* = font.rasterize(p.gpa, id, p.options.font_size, .{
                .skew = if (italic) 0.2 else 0,
                .embolden = if (bold) @max(1, p.options.font_size / 20) else 0,
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    _ = p.cache.remove(key);
                    return error.OutOfMemory;
                },
                else => .{
                    .width = 0,
                    .height = 0,
                    .left = 0,
                    .top = 0,
                    .pixels = try p.gpa.alloc(u8, 0),
                },
            };
        }
        if (got.value_ptr.pixels.len == 0) return null;
        return got.value_ptr;
    }

    /// Draws box-drawing and block characters as rectangles, so lines meet at cell edges as
    /// a terminal draws them. Returns whether `cp` was one.
    fn drawBox(
        p: *Painter,
        img: *Image,
        cp: u21,
        cx: usize,
        cy: usize,
        span: usize,
        color: Rgba,
        bold: bool,
    ) bool {
        const w = p.cell_width * span;
        const h = p.cell_height;
        const x: isize = @intCast(cx);
        const y: isize = @intCast(cy);
        const light = @max(1, @as(usize, @intFromFloat(@round(p.options.font_size / 14))));
        const heavy = light * 2;
        // Blocks.
        switch (cp) {
            0x2588 => img.fillRect(x, y, w, h, color), // █
            0x2580 => img.fillRect(x, y, w, h / 2, color), // ▀
            0x2590 => img.fillRect(x + @as(isize, @intCast(w - w / 2)), y, w / 2, h, color), // ▐
            0x2581...0x2587 => {
                const eighths = cp - 0x2580;
                const bar = h * eighths / 8;
                img.fillRect(x, y + @as(isize, @intCast(h - bar)), w, bar, color);
            },
            0x2589...0x258f => {
                const eighths = 8 - (cp - 0x2588);
                img.fillRect(x, y, w * eighths / 8, h, color);
            },
            0x2591, 0x2592, 0x2593 => {
                const alpha: u32 = switch (cp) {
                    0x2591 => 64,
                    0x2592 => 128,
                    else => 192,
                };
                var shade = color;
                shade.a = @intCast(alpha);
                for (0..h) |dy| for (0..w) |dx| {
                    const target = img.at(
                        @intCast(x + @as(isize, @intCast(dx))),
                        @intCast(y + @as(isize, @intCast(dy))),
                    );
                    target.* = image.blend(target.*, shade, alpha);
                };
            },
            0x2596...0x259f => {
                // Quadrants: bits for top left, top right, bottom left, bottom right.
                const quads = [_]u4{
                    0b0010,
                    0b0001,
                    0b1000,
                    0b1011,
                    0b1001,
                    0b1110,
                    0b1101,
                    0b0100,
                    0b0110,
                    0b0111,
                };
                const q = quads[cp - 0x2596];
                const hw = w / 2;
                const hh = h / 2;
                if (q & 0b1000 != 0) img.fillRect(x, y, hw, hh, color);
                if (q & 0b0100 != 0) img.fillRect(
                    x + @as(isize, @intCast(hw)),
                    y,
                    w - hw,
                    hh,
                    color,
                );
                if (q & 0b0010 != 0) img.fillRect(
                    x,
                    y + @as(isize, @intCast(hh)),
                    hw,
                    h - hh,
                    color,
                );
                if (q & 0b0001 != 0) img.fillRect(
                    x + @as(isize, @intCast(hw)),
                    y + @as(isize, @intCast(hh)),
                    w - hw,
                    h - hh,
                    color,
                );
            },
            else => {},
        }
        if (cp >= 0x2580 and cp <= 0x259f) return true;
        if (cp < 0x2500 or cp > 0x257f) return false;
        if (cp >= 0x256d and cp <= 0x2570) {
            p.drawArc(img, cp, cx, cy, w, h, if (bold) heavy else light, color);
            return true;
        }
        // Lines: which arms (up, right, down, left) each glyph has, and how heavy.
        const arms = boxArms(cp) orelse return false;
        const stroke_light = if (bold) heavy else light;
        const mx = x + @as(isize, @intCast(w / 2));
        const my = y + @as(isize, @intCast(h / 2));
        inline for (.{ .up, .right, .down, .left }, 0..) |dir, k| {
            const weight = (arms >> (2 * k)) & 3;
            if (weight != 0) {
                const t: usize = switch (weight) {
                    1 => stroke_light,
                    2 => heavy,
                    else => stroke_light,
                };
                const half: isize = @intCast(t / 2);
                const double = weight == 3;
                const gap: isize = @intCast(t + 1);
                switch (dir) {
                    .up, .down => {
                        const top = if (dir == .up) y else my - half;
                        const len: usize = if (dir == .up)
                            @intCast(my - y + half + @as(isize, @intCast(t % 2)))
                        else
                            h - @as(usize, @intCast(my - half - y));
                        if (double) {
                            img.fillRect(mx - gap, top, t, len, color);
                            img.fillRect(mx + gap - half, top, t, len, color);
                        } else img.fillRect(mx - half, top, t, len, color);
                    },
                    .left, .right => {
                        const left = if (dir == .left) x else mx - half;
                        const len: usize = if (dir == .left)
                            @intCast(mx - x + half + @as(isize, @intCast(t % 2)))
                        else
                            w - @as(usize, @intCast(mx - half - x));
                        if (double) {
                            img.fillRect(left, my - gap, len, t, color);
                            img.fillRect(left, my + gap - half, len, t, color);
                        } else img.fillRect(left, my - half, len, t, color);
                    },
                    else => unreachable,
                }
            }
        }
        return true;
    }

    /// A rounded corner (`╭╮╯╰`): straight from the cell's edges to an arc of a quarter
    /// circle around the corner, anti-aliased, meeting the straight lines of the cells
    /// beside it.
    fn drawArc(
        p: *Painter,
        img: *Image,
        cp: u21,
        cx: usize,
        cy: usize,
        w: usize,
        h: usize,
        thickness: usize,
        color: Rgba,
    ) void {
        _ = p;
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const t: f32 = @floatFromInt(thickness);
        // The line centers, as the straight glyphs place them.
        const mx: f32 = @as(f32, @floatFromInt(w / 2 - thickness / 2)) + t / 2;
        const my: f32 = @as(f32, @floatFromInt(h / 2 - thickness / 2)) + t / 2;
        const r = @min(fw - mx, mx, fh - my, my);
        // Which way the arms go: right/left, down/up.
        const right = cp == 0x256d or cp == 0x2570;
        const down = cp == 0x256d or cp == 0x256e;
        const ccx = if (right) mx + r else mx - r;
        const ccy = if (down) my + r else my - r;
        for (0..h) |py| for (0..w) |px| {
            const x = @as(f32, @floatFromInt(px)) + 0.5;
            const y = @as(f32, @floatFromInt(py)) + 0.5;
            var coverage: f32 = 0;
            const in_x = if (right) x >= ccx else x <= ccx;
            const in_y = if (down) y >= ccy else y <= ccy;
            if (in_x and in_y) {
                // Past the arc: the straight parts.
                coverage = 0;
            }
            const beyond_x = if (right) x > ccx else x < ccx;
            const beyond_y = if (down) y > ccy else y < ccy;
            if (beyond_y and !beyond_x) {
                // The vertical arm, from the arc to the edge.
                coverage = std.math.clamp(t / 2 - @abs(x - mx) + 0.5, 0, 1);
            } else if (beyond_x and !beyond_y) {
                coverage = std.math.clamp(t / 2 - @abs(y - my) + 0.5, 0, 1);
            } else if (!beyond_x and !beyond_y) {
                const dx = x - ccx;
                const dy = y - ccy;
                const d = @sqrt(dx * dx + dy * dy);
                coverage = std.math.clamp(t / 2 - @abs(d - r) + 0.5, 0, 1);
            }
            if (coverage <= 0) continue;
            const target = img.at(cx + px, cy + py);
            target.* = image.blend(
                target.*,
                color,
                @intFromFloat(coverage * @as(f32, @floatFromInt(color.a))),
            );
        };
    }
};

/// The arms of a box-drawing character, two bits each (0 none, 1 light, 2 heavy, 3
/// double) for up, right, down, left; null for the ones drawn from the font (dashes,
/// diagonals) or as arcs (rounded corners).
fn boxArms(cp: u21) ?u8 {
    const U = 0;
    const R = 2;
    const D = 4;
    const L = 6;
    const l: u8 = 1;
    const h: u8 = 2;
    const d: u8 = 3;
    return switch (cp) {
        0x2500 => l << L | l << R, // ─
        0x2501 => h << L | h << R, // ━
        0x2502 => l << U | l << D, // │
        0x2503 => h << U | h << D, // ┃
        0x250c => l << R | l << D, // ┌
        0x2510 => l << L | l << D, // ┐
        0x2514 => l << R | l << U, // └
        0x2518 => l << L | l << U, // ┘
        0x250f => h << R | h << D,
        0x2513 => h << L | h << D,
        0x2517 => h << R | h << U,
        0x251b => h << L | h << U,
        0x251c => l << U | l << D | l << R, // ├
        0x2524 => l << U | l << D | l << L, // ┤
        0x252c => l << L | l << R | l << D, // ┬
        0x2534 => l << L | l << R | l << U, // ┴
        0x253c => l << L | l << R | l << U | l << D, // ┼
        0x2523 => h << U | h << D | h << R,
        0x252b => h << U | h << D | h << L,
        0x2533 => h << L | h << R | h << D,
        0x253b => h << L | h << R | h << U,
        0x254b => h << L | h << R | h << U | h << D,
        0x2550 => d << L | d << R, // ═
        0x2551 => d << U | d << D, // ║
        0x2554 => d << R | d << D, // ╔
        0x2557 => d << L | d << D, // ╗
        0x255a => d << R | d << U, // ╚
        0x255d => d << L | d << U, // ╝
        0x2560 => d << U | d << D | d << R,
        0x2563 => d << U | d << D | d << L,
        0x2566 => d << L | d << R | d << D,
        0x2569 => d << L | d << R | d << U,
        0x256c => d << L | d << R | d << U | d << D,
        0x2574 => l << L,
        0x2575 => l << U,
        0x2576 => l << R,
        0x2577 => l << D,
        0x2578 => h << L,
        0x2579 => h << U,
        0x257a => h << R,
        0x257b => h << D,
        else => null,
    };
}

fn rgba(c: ansi.Color.Rgb) Rgba {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

/// The buttons a window bar shows, and where.
pub const WindowBar = enum { none, colorful, colorful_right, rings, rings_right };

/// What goes around the screen.
pub const Decoration = struct {
    /// Pixels between the screen and the window's edge.
    padding: usize = 20,
    window_bar: WindowBar = .none,
    window_bar_size: usize = 30,
    /// The window's (and the bar's) color; the screen's background when null.
    window_color: ?Rgba = null,
    /// Text in the bar's middle, in this color (drawn with `title_font`).
    title: []const u8 = "",
    title_font: ?*const TrueType = null,
    title_color: Rgba = .{ .r = 150, .g = 150, .b = 150 },
    title_size: f32 = 14,
    border_radius: usize = 0,
    border_width: usize = 0,
    border_color: Rgba = .{ .r = 80, .g = 80, .b = 90 },
    /// Pixels around the window, in `margin_fill` (transparent by default).
    margin: usize = 0,
    margin_fill: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    /// A drop shadow: its blur radius and offset, in pixels; 0 blur for none.
    shadow_blur: usize = 0,
    shadow_x: isize = 0,
    shadow_y: isize = 0,
    shadow_color: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 140 },
};

/// `content` in a window, as `decoration` says; a new image the caller frees.
pub fn decorate(gpa: Allocator, content: *const Image, d: Decoration) Allocator.Error!Image {
    const bar: usize = if (d.window_bar == .none) 0 else d.window_bar_size;
    const window_w = content.width + 2 * d.padding + 2 * d.border_width;
    const window_h = content.height + 2 * d.padding + bar + 2 * d.border_width;
    const total_w = window_w + 2 * d.margin;
    const total_h = window_h + 2 * d.margin;
    var out: Image = try .init(gpa, total_w, total_h);
    errdefer out.deinit(gpa);
    out.fill(d.margin_fill);
    const window_color = d.window_color orelse content.at(0, 0).*;
    var window: Image = try .init(gpa, window_w, window_h);
    defer window.deinit(gpa);
    window.fill(if (d.border_width > 0) d.border_color else window_color);
    window.fillRect(
        @intCast(d.border_width),
        @intCast(d.border_width),
        window_w - 2 * d.border_width,
        window_h - 2 * d.border_width,
        window_color,
    );
    window.draw(
        content,
        @intCast(d.border_width + d.padding),
        @intCast(d.border_width + d.padding + bar),
    );
    if (bar > 0) drawBar(&window, d, bar);
    if (d.border_radius > 0) roundCorners(&window, d.border_radius);
    if (d.shadow_blur > 0) {
        var shadow: Image = try .init(gpa, window_w, window_h);
        defer shadow.deinit(gpa);
        for (shadow.pixels, window.pixels) |*s, w| s.* = .{
            .r = d.shadow_color.r,
            .g = d.shadow_color.g,
            .b = d.shadow_color.b,
            .a = @intCast(@as(u32, w.a) * d.shadow_color.a / 255),
        };
        try boxBlur(gpa, &shadow, d.shadow_blur);
        out.draw(
            &shadow,
            @as(isize, @intCast(d.margin)) + d.shadow_x,
            @as(isize, @intCast(d.margin)) + d.shadow_y,
        );
    }
    out.draw(&window, @intCast(d.margin), @intCast(d.margin));
    return out;
}

fn drawBar(window: *Image, d: Decoration, bar: usize) void {
    const radius: f32 = @as(f32, @floatFromInt(bar)) / 5;
    const colors = [3]Rgba{
        .{ .r = 0xff, .g = 0x5f, .b = 0x57 },
        .{ .r = 0xfe, .g = 0xbc, .b = 0x2e },
        .{ .r = 0x28, .g = 0xc8, .b = 0x40 },
    };
    const rings = d.window_bar == .rings or d.window_bar == .rings_right;
    const right = d.window_bar == .colorful_right or d.window_bar == .rings_right;
    const cy = @as(f32, @floatFromInt(d.border_width + bar / 2));
    const spacing = radius * 3.2;
    for (0..3) |i| {
        const k: f32 = @floatFromInt(i);
        const cx = if (right)
            @as(f32, @floatFromInt(window.width - d.border_width)) - paddingF(d) -
                radius - k * spacing
        else
            @as(f32, @floatFromInt(d.border_width)) + paddingF(d) + radius + k * spacing;
        drawDisc(window, cx, cy, radius, colors[i], if (rings) radius * 0.7 else 0);
    }
    if (d.title.len > 0) if (d.title_font) |font| {
        // The title, centered in the bar, cut short (with an ellipsis) where it would reach
        // the buttons.
        const s = font.scale(d.title_size);
        const view = std.unicode.Utf8View.init(d.title) catch return;
        const reserved = 2 * (paddingF(d) + 2 * radius + 2 * spacing + radius);
        const room = @as(f32, @floatFromInt(window.width)) - reserved;
        const ellipsis = @as(f32, @floatFromInt(font.advance(font.glyphIndex(0x2026)))) * s;
        var text_width: f32 = 0;
        var fits_until: usize = d.title.len;
        var it = view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const cp = std.unicode.utf8Decode(slice) catch continue;
            const next = text_width +
                @as(f32, @floatFromInt(font.advance(font.glyphIndex(cp)))) * s;
            if (next + ellipsis > room and fits_until == d.title.len) {
                fits_until = it.i - slice.len;
            }
            text_width = next;
        }
        var cut = text_width > room;
        if (cut) {
            if (fits_until == 0) return;
            text_width = 0;
            it = (std.unicode.Utf8View.init(d.title[0..fits_until]) catch return).iterator();
            while (it.nextCodepoint()) |cp| {
                text_width += @as(f32, @floatFromInt(font.advance(font.glyphIndex(cp)))) * s;
            }
            text_width += ellipsis;
        }
        var x = (@as(f32, @floatFromInt(window.width)) - text_width) / 2;
        const baseline = cy + d.title_size * 0.35;
        const shown = d.title[0..if (cut) fits_until else d.title.len];
        it = (std.unicode.Utf8View.init(shown) catch return).iterator();
        while (true) {
            const cp = it.nextCodepoint() orelse if (cut) cut_blk: {
                cut = false;
                break :cut_blk 0x2026;
            } else break;
            const g = font.glyphIndex(cp);
            var mask = font.rasterize(std.heap.page_allocator, g, d.title_size, .{}) catch continue;
            defer mask.deinit(std.heap.page_allocator);
            window.blendMask(
                @as(isize, @intFromFloat(x)) + mask.left,
                @as(isize, @intFromFloat(baseline)) + mask.top,
                mask.width,
                mask.height,
                mask.pixels,
                d.title_color,
            );
            x += @as(f32, @floatFromInt(font.advance(g))) * s;
        }
    };
}

fn drawDisc(img: *Image, cx: f32, cy: f32, r: f32, color: Rgba, hole: f32) void {
    const x0: usize = @intFromFloat(@max(0, cx - r - 1));
    const y0: usize = @intFromFloat(@max(0, cy - r - 1));
    const x1: usize = @min(img.width, @as(usize, @intFromFloat(cx + r + 2)));
    const y1: usize = @min(img.height, @as(usize, @intFromFloat(cy + r + 2)));
    for (y0..y1) |y| for (x0..x1) |x| {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
        const dist = @sqrt(dx * dx + dy * dy);
        var coverage = std.math.clamp(r - dist + 0.5, 0, 1);
        if (hole > 0) coverage = @min(coverage, std.math.clamp(dist - hole + 0.5, 0, 1));
        if (coverage <= 0) continue;
        const target = img.at(x, y);
        target.* = image.blend(target.*, color, @intFromFloat(coverage * 255));
    };
}

/// Makes the corners outside a quarter circle of `radius` transparent, anti-aliased.
fn roundCorners(img: *Image, radius: usize) void {
    const r: f32 = @floatFromInt(radius);
    for (0..@min(radius, img.height)) |dy| for (0..@min(radius, img.width)) |dx| {
        const fx = r - (@as(f32, @floatFromInt(dx)) + 0.5);
        const fy = r - (@as(f32, @floatFromInt(dy)) + 0.5);
        const coverage = std.math.clamp(r - @sqrt(fx * fx + fy * fy) + 0.5, 0, 1);
        const corners = [_][2]usize{
            .{ dx, dy },
            .{ img.width - 1 - dx, dy },
            .{ dx, img.height - 1 - dy },
            .{ img.width - 1 - dx, img.height - 1 - dy },
        };
        for (corners) |pt| {
            const p = img.at(pt[0], pt[1]);
            p.a = @intFromFloat(@as(f32, @floatFromInt(p.a)) * coverage);
        }
    };
}

/// Blurs the alpha of `img` with three box blurs (close to a Gaussian of `radius`).
fn boxBlur(gpa: Allocator, img: *Image, radius: usize) Allocator.Error!void {
    const n = img.width * img.height;
    const a = try gpa.alloc(u32, n);
    defer gpa.free(a);
    const b = try gpa.alloc(u32, n);
    defer gpa.free(b);
    for (a, img.pixels) |*v, p| v.* = p.a;
    const r = @max(1, radius / 3);
    for (0..3) |_| {
        blurPass(a, b, img.width, img.height, r, true);
        blurPass(b, a, img.width, img.height, r, false);
    }
    for (img.pixels, a) |*p, v| p.a = @intCast(@min(v, 255));
}

fn blurPass(src: []const u32, dst: []u32, w: usize, h: usize, r: usize, horizontal: bool) void {
    const lines = if (horizontal) h else w;
    const len = if (horizontal) w else h;
    for (0..lines) |line| {
        var sum: u64 = 0;
        const index = struct {
            fn f(hz: bool, ln: usize, i: usize, width_: usize) usize {
                return if (hz) ln * width_ + i else i * width_ + ln;
            }
        }.f;
        // A window of 2r+1 around each pixel, edges counted as transparent.
        for (0..@min(r + 1, len)) |i| sum += src[index(horizontal, line, i, w)];
        for (0..len) |i| {
            dst[index(horizontal, line, i, w)] = @intCast(sum / (2 * r + 1));
            if (i + r + 1 < len) sum += src[index(horizontal, line, i + r + 1, w)];
            if (i >= r) sum -= src[index(horizontal, line, i - r, w)];
        }
    }
}

/// Where the bar's buttons start in from the window's edge.
fn paddingF(d: Decoration) f32 {
    return @floatFromInt(@max(d.padding / 2, 10));
}

const testing = std.testing;

test "box drawing joins at the cell edges" {
    const bytes = systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const font = try TrueType.init(bytes, 0);
    var painter: Painter = .init(
        testing.allocator,
        .{ .regular = font },
        .{ .font_size = 16, .cursor = false },
    );
    defer painter.deinit();
    var screen: vt.Screen = try .init(testing.allocator, .{ .width = 3, .height = 1 });
    defer screen.deinit();
    screen.background = .{ .r = 0, .g = 0, .b = 0 };
    screen.foreground = .{ .r = 255, .g = 255, .b = 255 };
    screen.write("───");
    var img = try painter.paint(&screen);
    defer img.deinit(testing.allocator);
    // The middle row is lit across the whole width.
    const y = painter.cell_height / 2;
    for (0..img.width) |x| try testing.expect(img.at(x, y).r == 255);
    try testing.expect(img.at(0, 0).r == 0);
}

test "text is drawn, decoration frames it" {
    const bytes = systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const font = try TrueType.init(bytes, 0);
    var painter: Painter = .init(testing.allocator, .{ .regular = font }, .{});
    defer painter.deinit();
    var screen: vt.Screen = try .init(testing.allocator, .{ .width = 10, .height = 2 });
    defer screen.deinit();
    screen.write("\x1b[1;31mHi\x1b[0m \x1b[44m中\x1b[0m");
    var img = try painter.paint(&screen);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(10 * painter.cell_width, img.width);
    var red: usize = 0;
    for (img.pixels) |p| if (p.r > 150 and p.g < 80) {
        red += 1;
    };
    try testing.expect(red > 20);
    var framed = try decorate(testing.allocator, &img, .{
        .window_bar = .colorful,
        .border_radius = 8,
        .margin = 10,
        .shadow_blur = 6,
        .shadow_y = 4,
    });
    defer framed.deinit(testing.allocator);
    try testing.expectEqual(img.width + 40 + 20, framed.width);
    try testing.expect(framed.at(10, 10).a < 255); // a rounded corner
}

fn systemFont(gpa: Allocator) ?[]u8 {
    const candidates = [_][]const u8{
        "/mnt/c/Windows/Fonts/consola.ttf",
        "C:\\Windows\\Fonts\\consola.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            path,
            gpa,
            .limited(64 << 20),
        ) catch continue;
    }
    return null;
}
