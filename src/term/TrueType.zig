//! TrueType fonts: read a `.ttf` (or a face of a `.ttc` collection), find glyphs by
//! codepoint, and rasterize them into anti-aliased coverage masks. Enough to draw a
//! terminal screen as an image (`raster`), with no dependency: the outlines of the `glyf`
//! table (simple and composite glyphs), the `cmap` formats 4 and 12, horizontal metrics,
//! and a scanline rasterizer that accumulates signed area (as font-rs does), exact for
//! straight edges and with quadratic curves flattened finely. CFF outlines (`OTTO` fonts)
//! are not read; such a font reports `error.UnsupportedOutlines`.
//!
//! ```zig
//! var font: term.TrueType = try .init(bytes, 0);
//! const glyph = font.glyphIndex('A');
//! var mask = try font.rasterize(gpa, glyph, 20, .{});
//! defer mask.deinit(gpa);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const TrueType = @This();

data: []const u8,
units_per_em: u16,
/// Ascent, descent (negative), and line gap, in font units.
ascent: i16,
descent: i16,
line_gap: i16,
glyph_count: u16,
long_loca: bool,
glyf: []const u8,
loca: []const u8,
hmtx: []const u8,
hmetrics: u16,
/// The chosen `cmap` subtable.
cmap: []const u8,
cmap_format: u16,

/// What reading a font can fail with.
pub const Error = error{ InvalidFont, UnsupportedOutlines };

/// Reads the font in `data` (kept, not copied); `face` picks one of a collection's.
pub fn init(data: []const u8, face: u32) Error!TrueType {
    var offset: usize = 0;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "ttcf")) {
        const faces = read32(data, 8) catch return error.InvalidFont;
        if (face >= faces) return error.InvalidFont;
        offset = read32(data, 12 + 4 * face) catch return error.InvalidFont;
    }
    if (data.len < offset + 12) return error.InvalidFont;
    const tag = data[offset..][0..4];
    if (std.mem.eql(u8, tag, "OTTO")) return error.UnsupportedOutlines;
    const tables = read16(data, offset + 4) catch return error.InvalidFont;
    var head: ?[]const u8 = null;
    var hhea: ?[]const u8 = null;
    var maxp: ?[]const u8 = null;
    var font: TrueType = undefined;
    font.data = data;
    var have = struct {
        glyf: bool = false,
        loca: bool = false,
        hmtx: bool = false,
        cmap: bool = false,
    }{};
    var cmap_table: []const u8 = &.{};
    for (0..tables) |i| {
        const record = offset + 12 + 16 * i;
        if (record + 16 > data.len) return error.InvalidFont;
        const name = data[record..][0..4];
        const start = read32(data, record + 8) catch return error.InvalidFont;
        const len = read32(data, record + 12) catch return error.InvalidFont;
        if (@as(usize, start) + len > data.len) return error.InvalidFont;
        const table = data[start..][0..len];
        if (std.mem.eql(u8, name, "head")) head = table;
        if (std.mem.eql(u8, name, "hhea")) hhea = table;
        if (std.mem.eql(u8, name, "maxp")) maxp = table;
        if (std.mem.eql(u8, name, "glyf")) {
            font.glyf = table;
            have.glyf = true;
        }
        if (std.mem.eql(u8, name, "loca")) {
            font.loca = table;
            have.loca = true;
        }
        if (std.mem.eql(u8, name, "hmtx")) {
            font.hmtx = table;
            have.hmtx = true;
        }
        if (std.mem.eql(u8, name, "cmap")) {
            cmap_table = table;
            have.cmap = true;
        }
    }
    const h = head orelse return error.InvalidFont;
    const hh = hhea orelse return error.InvalidFont;
    const mp = maxp orelse return error.InvalidFont;
    if (!have.cmap or !have.hmtx) return error.InvalidFont;
    if (!have.glyf or !have.loca) return error.UnsupportedOutlines;
    font.units_per_em = read16(h, 18) catch return error.InvalidFont;
    font.long_loca = (read16(h, 50) catch return error.InvalidFont) != 0;
    font.ascent = @bitCast(read16(hh, 4) catch return error.InvalidFont);
    font.descent = @bitCast(read16(hh, 6) catch return error.InvalidFont);
    font.line_gap = @bitCast(read16(hh, 8) catch return error.InvalidFont);
    font.hmetrics = read16(hh, 34) catch return error.InvalidFont;
    font.glyph_count = read16(mp, 4) catch return error.InvalidFont;
    if (font.units_per_em == 0) return error.InvalidFont;
    try font.chooseCmap(cmap_table);
    return font;
}

/// Picks the Unicode subtable: format 12 (all of Unicode) before format 4 (the BMP).
fn chooseCmap(font: *TrueType, table: []const u8) Error!void {
    const count = read16(table, 2) catch return error.InvalidFont;
    var best: ?[]const u8 = null;
    var best_format: u16 = 0;
    for (0..count) |i| {
        const platform = read16(table, 4 + 8 * i) catch return error.InvalidFont;
        const encoding = read16(table, 6 + 8 * i) catch return error.InvalidFont;
        const offset = read32(table, 8 + 8 * i) catch return error.InvalidFont;
        const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
        if (!unicode or offset >= table.len) continue;
        const sub = table[offset..];
        const format = read16(sub, 0) catch continue;
        if (format == 12 and best_format != 12) {
            best = sub;
            best_format = 12;
        } else if (format == 4 and best_format == 0) {
            best = sub;
            best_format = 4;
        }
    }
    font.cmap = best orelse return error.InvalidFont;
    font.cmap_format = best_format;
}

/// The font's family name (`DejaVu Sans Mono`) and style (`Bold Oblique`), from a font
/// file's `name` table, written into `buffer`; for finding fonts without loading them
/// whole. `table` is the table's bytes.
pub const Names = struct { family: []const u8, style: []const u8 };

/// Reads the family and style names from a `name` table (the typographic ones, ids 16
/// and 17, when present; else 1 and 2), as UTF-8 in `buffer`.
pub fn readNames(table: []const u8, buffer: []u8) ?Names {
    const count = read16(table, 2) catch return null;
    const strings = read16(table, 4) catch return null;
    var family: ?[]const u8 = null;
    var style: ?[]const u8 = null;
    var family_rank: u8 = 0;
    var style_rank: u8 = 0;
    var used: usize = 0;
    for (0..count) |i| {
        const at = 6 + 12 * i;
        const platform = read16(table, at) catch return null;
        const encoding = read16(table, at + 2) catch return null;
        const language = read16(table, at + 4) catch return null;
        const id = read16(table, at + 6) catch return null;
        const len = read16(table, at + 8) catch return null;
        const offset = read16(table, at + 10) catch return null;
        if (id != 1 and id != 2 and id != 16 and id != 17) continue;
        const windows = platform == 3 and (encoding == 1 or encoding == 10);
        const mac = platform == 1 and encoding == 0;
        if (!windows and !mac) continue;
        // English first, typographic names over legacy ones, Windows over Mac.
        var rank: u8 = if (id >= 16) 4 else 2;
        if (windows) rank += 1;
        if (windows and language != 0x409) rank -= 1;
        const start = @as(usize, strings) + offset;
        if (start + len > table.len) continue;
        const raw = table[start..][0..len];
        const is_family = id == 1 or id == 16;
        if (is_family and rank <= family_rank) continue;
        if (!is_family and rank <= style_rank) continue;
        const text_start = used;
        if (windows) {
            // UTF-16 big-endian.
            var k: usize = 0;
            while (k + 1 < raw.len and used + 4 <= buffer.len) : (k += 2) {
                const unit = std.mem.readInt(u16, raw[k..][0..2], .big);
                used += std.unicode.utf8Encode(unit, buffer[used..]) catch 0;
            }
        } else {
            const n = @min(raw.len, buffer.len - used);
            @memcpy(buffer[used..][0..n], raw[0..n]);
            used += n;
        }
        if (is_family) {
            family = buffer[text_start..used];
            family_rank = rank;
        } else {
            style = buffer[text_start..used];
            style_rank = rank;
        }
    }
    return .{ .family = family orelse return null, .style = style orelse "Regular" };
}

/// The table directory of the font (or the collection's face `face`) in `header`: where
/// the table `tag` is, as an offset and a length in the file.
pub fn findTable(header: []const u8, face: u32, tag: *const [4]u8) ?[2]u32 {
    var offset: usize = 0;
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "ttcf")) {
        offset = read32(header, 12 + 4 * face) catch return null;
    }
    const tables = read16(header, offset + 4) catch return null;
    for (0..tables) |i| {
        const record = offset + 12 + 16 * i;
        if (record + 16 > header.len) return null;
        if (!std.mem.eql(u8, header[record..][0..4], tag)) continue;
        return .{
            read32(header, record + 8) catch return null,
            read32(header, record + 12) catch return null,
        };
    }
    return null;
}

/// The glyph for `cp`, or 0 (the missing-glyph box) when the font has none.
pub fn glyphIndex(font: *const TrueType, cp: u21) u16 {
    const t = font.cmap;
    if (font.cmap_format == 12) {
        const groups = read32(t, 12) catch return 0;
        var low: u32 = 0;
        var high: u32 = groups;
        while (low < high) {
            const mid = (low + high) / 2;
            const at = 16 + 12 * mid;
            const start = read32(t, at) catch return 0;
            const end = read32(t, at + 4) catch return 0;
            if (cp < start) {
                high = mid;
            } else if (cp > end) {
                low = mid + 1;
            } else {
                const first = read32(t, at + 8) catch return 0;
                return @truncate(first + (cp - start));
            }
        }
        return 0;
    }
    if (cp > 0xffff) return 0;
    const segments = (read16(t, 6) catch return 0) / 2;
    const ends = 14;
    const starts = ends + 2 * @as(usize, segments) + 2;
    const deltas = starts + 2 * @as(usize, segments);
    const ranges = deltas + 2 * @as(usize, segments);
    var low: usize = 0;
    var high: usize = segments;
    while (low < high) {
        const mid = (low + high) / 2;
        const end = read16(t, ends + 2 * mid) catch return 0;
        if (cp > end) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low >= segments) return 0;
    const start = read16(t, starts + 2 * low) catch return 0;
    if (cp < start) return 0;
    const delta = read16(t, deltas + 2 * low) catch return 0;
    const range = read16(t, ranges + 2 * low) catch return 0;
    if (range == 0) return @truncate(@as(u32, cp) +% delta);
    const at = ranges + 2 * low + range + 2 * (@as(usize, cp) - start);
    const glyph = read16(t, at) catch return 0;
    if (glyph == 0) return 0;
    return glyph +% delta;
}

/// Whether the font has a glyph for `cp`.
pub fn has(font: *const TrueType, cp: u21) bool {
    return font.glyphIndex(cp) != 0;
}

/// The horizontal advance of `glyph`, in font units.
pub fn advance(font: *const TrueType, glyph: u16) u16 {
    const index = @min(glyph, font.hmetrics -| 1);
    return read16(font.hmtx, 4 * @as(usize, index)) catch 0;
}

/// Font units to pixels at a size of `pixels` per em.
pub fn scale(font: *const TrueType, pixels: f32) f32 {
    return pixels / @as(f32, @floatFromInt(font.units_per_em));
}

/// A point of an outline, in font units, y up.
pub const Point = struct { x: f32, y: f32 };

/// An outline as line segments and quadratic curves, in font units.
pub const Outline = struct {
    segments: std.ArrayList(Segment) = .empty,

    /// A move, a line, or a quadratic curve.
    pub const Segment = union(enum) {
        line: [2]Point,
        quad: [3]Point,
    };

    /// Frees the segments.
    pub fn deinit(o: *Outline, gpa: Allocator) void {
        o.segments.deinit(gpa);
    }
};

/// The outline of `glyph`, composite glyphs resolved (to a depth of 8).
pub fn outline(
    font: *const TrueType,
    gpa: Allocator,
    glyph: u16,
) (Error || Allocator.Error)!Outline {
    var o: Outline = .{};
    errdefer o.deinit(gpa);
    try font.appendGlyph(gpa, &o, glyph, .{ 1, 0, 0, 1, 0, 0 }, 0);
    return o;
}

fn glyphData(font: *const TrueType, glyph: u16) Error![]const u8 {
    if (glyph >= font.glyph_count) return &.{};
    const i: usize = glyph;
    const start: usize, const end: usize = if (font.long_loca) .{
        read32(font.loca, 4 * i) catch return error.InvalidFont,
        read32(font.loca, 4 * i + 4) catch return error.InvalidFont,
    } else .{
        2 * @as(usize, read16(font.loca, 2 * i) catch return error.InvalidFont),
        2 * @as(usize, read16(font.loca, 2 * i + 2) catch return error.InvalidFont),
    };
    if (end <= start or end > font.glyf.len) return &.{};
    return font.glyf[start..end];
}

/// An affine transform: x' = a x + c y + e, y' = b x + d y + f.
const Transform = [6]f32;

fn apply(t: Transform, p: Point) Point {
    return .{ .x = t[0] * p.x + t[2] * p.y + t[4], .y = t[1] * p.x + t[3] * p.y + t[5] };
}

fn appendGlyph(
    font: *const TrueType,
    gpa: Allocator,
    o: *Outline,
    glyph: u16,
    transform: Transform,
    depth: u8,
) (Error || Allocator.Error)!void {
    if (depth > 8) return;
    const g = try font.glyphData(glyph);
    if (g.len < 10) return;
    const contours: i16 = @bitCast(read16(g, 0) catch return error.InvalidFont);
    if (contours < 0) return font.appendComposite(gpa, o, g, transform, depth);
    const n: usize = @intCast(contours);
    if (n == 0) return;
    const ends_at = 10;
    const point_count = (read16(g, ends_at + 2 * (n - 1)) catch return error.InvalidFont) + 1;
    const instructions = read16(g, ends_at + 2 * n) catch return error.InvalidFont;
    var at: usize = ends_at + 2 * n + 2 + instructions;
    // Flags, run-length encoded.
    const flags = try gpa.alloc(u8, point_count);
    defer gpa.free(flags);
    var i: usize = 0;
    while (i < point_count) {
        if (at >= g.len) return error.InvalidFont;
        const flag = g[at];
        at += 1;
        flags[i] = flag;
        i += 1;
        if (flag & 8 != 0) {
            if (at >= g.len) return error.InvalidFont;
            var repeat = g[at];
            at += 1;
            while (repeat > 0 and i < point_count) : (repeat -= 1) {
                flags[i] = flag;
                i += 1;
            }
        }
    }
    const points = try gpa.alloc(Point, point_count);
    defer gpa.free(points);
    // X coordinates, then Y: each a byte (with a sign flag) or a 16-bit delta, or the same.
    inline for (.{ .{ 2, 16 }, .{ 4, 32 } }, 0..) |bits, axis| {
        var value: i32 = 0;
        for (flags, points) |flag, *point| {
            if (flag & bits[0] != 0) {
                if (at >= g.len) return error.InvalidFont;
                const d: i32 = g[at];
                at += 1;
                value += if (flag & bits[1] != 0) d else -d;
            } else if (flag & bits[1] == 0) {
                const d: i16 = @bitCast(read16(g, at) catch return error.InvalidFont);
                at += 2;
                value += d;
            }
            if (axis == 0) point.x = @floatFromInt(value) else point.y = @floatFromInt(value);
        }
    }
    var start: usize = 0;
    for (0..n) |c| {
        const end = (read16(g, ends_at + 2 * c) catch return error.InvalidFont) + 1;
        if (end <= start or end > point_count) return error.InvalidFont;
        try appendContour(gpa, o, points[start..end], flags[start..end], transform);
        start = end;
    }
}

/// Turns one contour's points (on-curve when bit 0 of the flag is set) into segments:
/// two off-curve points in a row imply an on-curve point midway.
fn appendContour(
    gpa: Allocator,
    o: *Outline,
    points: []const Point,
    flags: []const u8,
    transform: Transform,
) Allocator.Error!void {
    const n = points.len;
    if (n < 2) return;
    // Start at an on-curve point, or the midpoint of the first two off-curve ones.
    var first: usize = 0;
    while (first < n and flags[first] & 1 == 0) first += 1;
    var start: Point = undefined;
    var offset: usize = undefined;
    if (first == n) {
        start = midpoint(points[0], points[1]);
        offset = 1;
    } else {
        start = points[first];
        offset = first + 1;
    }
    var current = start;
    var control: ?Point = null;
    for (0..n) |k| {
        const index = (offset + k) % n;
        const p = points[index];
        if (first == n and k == n - 1) {
            // Back around to the implied start.
        }
        if (flags[index] & 1 != 0) {
            if (control) |cp| {
                try o.segments.append(gpa, .{ .quad = .{
                    apply(transform, current),
                    apply(transform, cp),
                    apply(transform, p),
                } });
            } else {
                try o.segments.append(gpa, .{ .line = .{
                    apply(transform, current),
                    apply(transform, p),
                } });
            }
            current = p;
            control = null;
        } else {
            if (control) |cp| {
                const mid = midpoint(cp, p);
                try o.segments.append(gpa, .{ .quad = .{
                    apply(transform, current),
                    apply(transform, cp),
                    apply(transform, mid),
                } });
                current = mid;
            }
            control = p;
        }
    }
    // Close the contour.
    if (control) |cp| {
        try o.segments.append(gpa, .{ .quad = .{
            apply(transform, current),
            apply(transform, cp),
            apply(transform, start),
        } });
    } else if (current.x != start.x or current.y != start.y) {
        try o.segments.append(gpa, .{ .line = .{
            apply(transform, current),
            apply(transform, start),
        } });
    }
}

fn midpoint(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

fn appendComposite(
    font: *const TrueType,
    gpa: Allocator,
    o: *Outline,
    g: []const u8,
    transform: Transform,
    depth: u8,
) (Error || Allocator.Error)!void {
    var at: usize = 10;
    while (true) {
        const flags = read16(g, at) catch return error.InvalidFont;
        const component = read16(g, at + 2) catch return error.InvalidFont;
        at += 4;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & 1 != 0) {
            dx = @floatFromInt(@as(i16, @bitCast(read16(g, at) catch return error.InvalidFont)));
            dy = @floatFromInt(@as(
                i16,
                @bitCast(read16(g, at + 2) catch return error.InvalidFont),
            ));
            at += 4;
        } else {
            if (at + 2 > g.len) return error.InvalidFont;
            dx = @floatFromInt(@as(i8, @bitCast(g[at])));
            dy = @floatFromInt(@as(i8, @bitCast(g[at + 1])));
            at += 2;
        }
        // Point matching (flag 2 off) is not used by fonts that matter here; offsets only.
        var m: [4]f32 = .{ 1, 0, 0, 1 };
        if (flags & 8 != 0) {
            const s = f2dot14(read16(g, at) catch return error.InvalidFont);
            m = .{ s, 0, 0, s };
            at += 2;
        } else if (flags & 0x40 != 0) {
            m = .{
                f2dot14(read16(g, at) catch return error.InvalidFont),
                0,
                0,
                f2dot14(read16(g, at + 2) catch return error.InvalidFont),
            };
            at += 4;
        } else if (flags & 0x80 != 0) {
            m = .{
                f2dot14(read16(g, at) catch return error.InvalidFont),
                f2dot14(read16(g, at + 2) catch return error.InvalidFont),
                f2dot14(read16(g, at + 4) catch return error.InvalidFont),
                f2dot14(read16(g, at + 6) catch return error.InvalidFont),
            };
            at += 8;
        }
        const t = transform;
        // The component's transform, then the parent's.
        const combined: Transform = .{
            t[0] * m[0] + t[2] * m[1],
            t[1] * m[0] + t[3] * m[1],
            t[0] * m[2] + t[2] * m[3],
            t[1] * m[2] + t[3] * m[3],
            t[0] * dx + t[2] * dy + t[4],
            t[1] * dx + t[3] * dy + t[5],
        };
        try font.appendGlyph(gpa, o, component, combined, depth + 1);
        if (flags & 0x20 == 0) break;
    }
}

fn f2dot14(raw: u16) f32 {
    return @as(f32, @floatFromInt(@as(i16, @bitCast(raw)))) / 16384;
}

/// A glyph rendered: coverage from 0 to 255, row by row from the top.
pub const Mask = struct {
    width: usize,
    height: usize,
    /// Where the mask's top left goes, relative to the pen on the baseline, y down.
    left: i32,
    top: i32,
    pixels: []u8,

    /// Frees the pixels.
    pub fn deinit(m: *Mask, gpa: Allocator) void {
        gpa.free(m.pixels);
    }
};

/// How `rasterize` draws.
pub const RasterOptions = struct {
    /// Slant (as oblique, for an italic the font does not have): x shifts by this much per
    /// unit of height.
    skew: f32 = 0,
    /// Thicken strokes by this many pixels (for a bold the font does not have).
    embolden: f32 = 0,
};

/// Renders `glyph` at `pixels` per em.
pub fn rasterize(
    font: *const TrueType,
    gpa: Allocator,
    glyph: u16,
    pixels: f32,
    options: RasterOptions,
) (Error || Allocator.Error)!Mask {
    var o = try font.outline(gpa, glyph);
    defer o.deinit(gpa);
    const s = font.scale(pixels);
    var lines: std.ArrayList([2]Point) = .empty;
    defer lines.deinit(gpa);
    // Pixels, y down, slanted; curves flattened.
    for (o.segments.items) |segment| switch (segment) {
        .line => |l| try lines.append(gpa, .{
            toPixels(l[0], s, options.skew),
            toPixels(l[1], s, options.skew),
        }),
        .quad => |q| {
            const p0 = toPixels(q[0], s, options.skew);
            const p1 = toPixels(q[1], s, options.skew);
            const p2 = toPixels(q[2], s, options.skew);
            const dd = @abs(p0.x - 2 * p1.x + p2.x) + @abs(p0.y - 2 * p1.y + p2.y);
            const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(dd * 4)))));
            var previous = p0;
            for (1..steps + 1) |k| {
                const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
                const u = 1 - t;
                const p: Point = .{
                    .x = u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
                    .y = u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y,
                };
                try lines.append(gpa, .{ previous, p });
                previous = p;
            }
        },
    };
    if (lines.items.len == 0) return .{
        .width = 0,
        .height = 0,
        .left = 0,
        .top = 0,
        .pixels = try gpa.alloc(u8, 0),
    };
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (lines.items) |l| for (l) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    };
    const pad: f32 = @ceil(options.embolden) + 1;
    const left: i32 = @intFromFloat(@floor(min_x - pad));
    const top: i32 = @intFromFloat(@floor(min_y - pad));
    const width: usize = @intCast(@as(i32, @intFromFloat(@ceil(max_x + pad))) - left);
    const height: usize = @intCast(@as(i32, @intFromFloat(@ceil(max_y + pad))) - top);
    const accumulation = try gpa.alloc(f32, width * height + 1);
    defer gpa.free(accumulation);
    @memset(accumulation, 0);
    const ox: f32 = @floatFromInt(left);
    const oy: f32 = @floatFromInt(top);
    for (lines.items) |l| {
        drawLine(
            accumulation,
            width,
            height,
            .{ .x = l[0].x - ox, .y = l[0].y - oy },
            .{ .x = l[1].x - ox, .y = l[1].y - oy },
        );
    }
    const pixels_out = try gpa.alloc(u8, width * height);
    var sum: f32 = 0;
    for (pixels_out, accumulation[0 .. width * height]) |*px, a| {
        sum += a;
        px.* = @intFromFloat(@min(@abs(sum), 1) * 255 + 0.5);
    }
    var mask: Mask = .{
        .width = width,
        .height = height,
        .left = left,
        .top = top,
        .pixels = pixels_out,
    };
    if (options.embolden > 0) dilate(&mask, options.embolden);
    return mask;
}

fn toPixels(p: Point, s: f32, skew: f32) Point {
    const y = -p.y * s;
    return .{ .x = p.x * s - y * skew, .y = y };
}

/// Accumulates the signed area a line covers in each pixel, as font-rs does: a prefix sum
/// of the buffer, row by row, then gives each pixel's coverage.
fn drawLine(acc: []f32, width: usize, height: usize, p0: Point, p1: Point) void {
    if (p0.y == p1.y) return;
    const dir: f32 = if (p0.y < p1.y) 1 else -1;
    const a = if (p0.y < p1.y) p0 else p1;
    const b = if (p0.y < p1.y) p1 else p0;
    const dxdy = (b.x - a.x) / (b.y - a.y);
    var x = a.x;
    const y0: usize = @intFromFloat(@max(0, a.y));
    if (a.y < 0) x -= a.y * dxdy;
    const h: f32 = @floatFromInt(height);
    const y_end: usize = @intFromFloat(@min(h, @ceil(b.y)));
    const w: f32 = @floatFromInt(width);
    var y = y0;
    while (y < y_end) : (y += 1) {
        const row = y * width;
        const fy: f32 = @floatFromInt(y);
        const dy = @min(fy + 1, b.y) - @max(fy, a.y);
        const x_next = x + dxdy * dy;
        const d = dy * dir;
        const x_lo = @min(x, x_next);
        const x_hi = @max(x, x_next);
        if (x_hi <= 0) {
            acc[row] += d;
        } else if (x_lo >= w) {
            // Off the right edge: nothing visible.
        } else {
            const x0i = @max(@floor(x_lo), 0);
            const x0floor: usize = @intFromFloat(x0i);
            const x1ceil: usize = @intFromFloat(@min(@ceil(x_hi), w));
            if (x1ceil <= x0floor + 1) {
                const xmf = 0.5 * (x + x_next) - x0i;
                acc[row + x0floor] += d - d * xmf;
                acc[row + x0floor + 1] += d * xmf;
            } else {
                const s = 1 / (x_hi - x_lo);
                const x0f = x_lo - x0i;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x_hi - @ceil(x_hi) + 1;
                const am = 0.5 * s * x1f * x1f;
                acc[row + x0floor] += d * a0;
                if (x1ceil == x0floor + 2) {
                    acc[row + x0floor + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - x0f);
                    acc[row + x0floor + 1] += d * (a1 - a0);
                    var xi = x0floor + 2;
                    while (xi < x1ceil - 1) : (xi += 1) acc[row + xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1ceil - x0floor - 3)) * s;
                    acc[row + x1ceil - 1] += d * (1 - a2 - am);
                }
                acc[row + x1ceil] += d * am;
            }
        }
        x = x_next;
    }
}

/// Thickens a mask's strokes by `amount` pixels to the right (as terminals draw a bold the
/// font lacks).
fn dilate(mask: *Mask, amount: f32) void {
    const shift: usize = @max(1, @as(usize, @intFromFloat(@round(amount))));
    for (0..mask.height) |r| {
        const row = mask.pixels[r * mask.width ..][0..mask.width];
        var c = row.len;
        while (c > 0) {
            c -= 1;
            var best = row[c];
            for (1..shift + 1) |k| if (c >= k) {
                best = @max(best, row[c - k]);
            };
            row[c] = best;
        }
    }
}

fn read16(data: []const u8, at: usize) error{InvalidFont}!u16 {
    if (at + 2 > data.len) return error.InvalidFont;
    return std.mem.readInt(u16, data[at..][0..2], .big);
}

fn read32(data: []const u8, at: usize) error{InvalidFont}!u32 {
    if (at + 4 > data.len) return error.InvalidFont;
    return std.mem.readInt(u32, data[at..][0..4], .big);
}

const testing = std.testing;

test "a square accumulates full coverage inside and none outside" {
    const width = 6;
    const height = 6;
    var acc: [width * height + 1]f32 = @splat(0);
    const square = [_]Point{
        .{ .x = 1, .y = 1 },
        .{ .x = 5, .y = 1 },
        .{ .x = 5, .y = 5 },
        .{ .x = 1, .y = 5 },
    };
    for (0..4) |i| drawLine(&acc, width, height, square[i], square[(i + 1) % 4]);
    var sum: f32 = 0;
    var coverage: [width * height]f32 = undefined;
    for (&coverage, acc[0 .. width * height]) |*c, a| {
        sum += a;
        c.* = @abs(sum);
    }
    try testing.expectApproxEqAbs(1, coverage[2 * width + 2], 0.001);
    try testing.expectApproxEqAbs(0, coverage[0], 0.001);
    try testing.expectApproxEqAbs(0, coverage[2 * width + 5], 0.001);
}

test "a half-pixel edge covers half" {
    const width = 4;
    var acc: [width * 2 + 1]f32 = @splat(0);
    const box = [_]Point{
        .{ .x = 0.5, .y = 0 },
        .{ .x = 3, .y = 0 },
        .{ .x = 3, .y = 2 },
        .{ .x = 0.5, .y = 2 },
    };
    for (0..4) |i| drawLine(&acc, width, 2, box[i], box[(i + 1) % 4]);
    var sum: f32 = 0;
    var first: f32 = 0;
    for (acc[0..width], 0..) |a, i| {
        sum += a;
        if (i == 0) first = @abs(sum);
    }
    try testing.expectApproxEqAbs(0.5, first, 0.01);
}

/// A system monospace font to test with, when this machine has one.
fn systemFont(gpa: Allocator) ?[]u8 {
    const candidates = [_][]const u8{
        "/mnt/c/Windows/Fonts/consola.ttf",
        "C:\\Windows\\Fonts\\consola.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
    };
    for (candidates) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            path,
            gpa,
            .limited(64 << 20),
        ) catch continue;
        return bytes;
    }
    return null;
}

test "a real font: glyphs, metrics, and masks" {
    const bytes = systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const font = try TrueType.init(bytes, 0);
    const a = font.glyphIndex('A');
    try testing.expect(a != 0);
    try testing.expect(font.glyphIndex(0x10ffff) == 0);
    // Monospace: every letter advances alike.
    try testing.expectEqual(font.advance(a), font.advance(font.glyphIndex('i')));
    var mask = try font.rasterize(testing.allocator, a, 32, .{});
    defer mask.deinit(testing.allocator);
    try testing.expect(mask.width > 10 and mask.height > 15);
    var dark: usize = 0;
    var full: usize = 0;
    for (mask.pixels) |p| {
        if (p > 0) dark += 1;
        if (p == 255) full += 1;
    }
    try testing.expect(full > 20 and dark < mask.pixels.len);
    // A space has no outline.
    var space = try font.rasterize(testing.allocator, font.glyphIndex(' '), 32, .{});
    defer space.deinit(testing.allocator);
    try testing.expectEqual(0, space.pixels.len);
    // Composite glyphs (accented letters are often made of two).
    var e = try font.rasterize(
        testing.allocator,
        font.glyphIndex(0xe9),
        32,
        .{ .skew = 0.2, .embolden = 1 },
    );
    defer e.deinit(testing.allocator);
    try testing.expect(e.pixels.len > 0);
}

test "bad data is an error, not a crash" {
    try testing.expectError(error.InvalidFont, TrueType.init("", 0));
    try testing.expectError(error.InvalidFont, TrueType.init("\x00\x01\x00\x00\x00\x09", 0));
    try testing.expectError(
        error.UnsupportedOutlines,
        TrueType.init("OTTO\x00\x00\x00\x00\x00\x00\x00\x00", 0),
    );
    var prng: std.Random.DefaultPrng = .init(1);
    var junk: [512]u8 = undefined;
    for (0..200) |_| {
        prng.random().bytes(&junk);
        @memcpy(junk[0..4], "\x00\x01\x00\x00");
        junk[4] = 0;
        junk[5] = 4;
        _ = TrueType.init(&junk, 0) catch continue;
    }
}
