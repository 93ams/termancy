//! Images: pixels in memory, PNG written and read, animated GIFs written, and JPEGs read
//! (`decode` reads any of them), with no dependency (deflate is the standard library's).
//! What `termancy record` and `freeze` write their pictures with, and what the terminal
//! image protocols (`graphics`) read.
//!
//! ```zig
//! var img: term.image.Image = try .init(gpa, 320, 200);
//! defer img.deinit(gpa);
//! img.fill(.{ .r = 30, .g = 30, .b = 46 });
//! try term.image.writePng(gpa, w, &img);
//! ```
//!
//! GIFs are written as an animation of frames, each with its own palette (median cut,
//! when a frame has more than 256 colors), and only the rectangle that changed since the
//! frame before, the rest transparent: a terminal recording that changes a few cells a
//! frame stays small.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const flate = std.compress.flate;

/// A pixel. Alpha is 255 for opaque.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Whether the two are the same color and alpha.
    pub fn eql(a: Rgba, b: Rgba) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    fn key(c: Rgba) u32 {
        return @as(u32, c.r) << 24 | @as(u32, c.g) << 16 | @as(u32, c.b) << 8 | c.a;
    }
};

/// An RGBA image, row by row from the top left.
pub const Image = struct {
    width: usize,
    height: usize,
    pixels: []Rgba,

    /// A transparent image of the size. Free with `deinit`.
    pub fn init(gpa: Allocator, width: usize, height: usize) Allocator.Error!Image {
        const pixels = try gpa.alloc(Rgba, width * height);
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    /// Frees the pixels.
    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.pixels);
        img.* = undefined;
    }

    /// A copy, with pixels of its own.
    pub fn clone(img: *const Image, gpa: Allocator) Allocator.Error!Image {
        return .{
            .width = img.width,
            .height = img.height,
            .pixels = try gpa.dupe(Rgba, img.pixels),
        };
    }

    /// The pixel at column `x`, row `y`.
    pub fn at(img: *const Image, x: usize, y: usize) *Rgba {
        return &img.pixels[y * img.width + x];
    }

    /// Sets every pixel to `color`.
    pub fn fill(img: *Image, color: Rgba) void {
        @memset(img.pixels, color);
    }

    /// Fills a rectangle, cut to the image.
    pub fn fillRect(img: *Image, x: isize, y: isize, w: usize, h: usize, color: Rgba) void {
        const x0: usize = @intCast(std.math.clamp(x, 0, @as(isize, @intCast(img.width))));
        const y0: usize = @intCast(std.math.clamp(y, 0, @as(isize, @intCast(img.height))));
        const x1: usize = @intCast(std.math.clamp(
            x + @as(isize, @intCast(w)),
            0,
            @as(isize, @intCast(img.width)),
        ));
        const y1: usize = @intCast(std.math.clamp(
            y + @as(isize, @intCast(h)),
            0,
            @as(isize, @intCast(img.height)),
        ));
        for (y0..y1) |row| @memset(img.pixels[row * img.width + x0 .. row * img.width + x1], color);
    }

    /// Paints `color` through a coverage mask (0 to 255 a pixel), its top left at `x`, `y`.
    pub fn blendMask(
        img: *Image,
        x: isize,
        y: isize,
        mask_width: usize,
        mask_height: usize,
        mask: []const u8,
        color: Rgba,
    ) void {
        for (0..mask_height) |my| {
            const py = y + @as(isize, @intCast(my));
            if (py < 0 or py >= @as(isize, @intCast(img.height))) continue;
            for (0..mask_width) |mx| {
                const coverage = mask[my * mask_width + mx];
                if (coverage == 0) continue;
                const px = x + @as(isize, @intCast(mx));
                if (px < 0 or px >= @as(isize, @intCast(img.width))) continue;
                const target = img.at(@intCast(px), @intCast(py));
                const alpha = @as(u32, coverage) * color.a / 255;
                target.* = blend(target.*, color, alpha);
            }
        }
    }

    /// Composites `top` over this image at `x`, `y`, by its alpha.
    pub fn draw(img: *Image, top: *const Image, x: isize, y: isize) void {
        for (0..top.height) |ty| {
            const py = y + @as(isize, @intCast(ty));
            if (py < 0 or py >= @as(isize, @intCast(img.height))) continue;
            for (0..top.width) |tx| {
                const px = x + @as(isize, @intCast(tx));
                if (px < 0 or px >= @as(isize, @intCast(img.width))) continue;
                const c = top.at(tx, ty).*;
                const target = img.at(@intCast(px), @intCast(py));
                target.* = blend(target.*, c, c.a);
            }
        }
    }
};

/// An image as palette indices.
pub const Indexed = struct {
    width: usize,
    height: usize,
    palette: []Rgba,
    pixels: []u8,

    /// Frees the palette and pixels.
    pub fn deinit(ix: *Indexed, gpa: Allocator) void {
        gpa.free(ix.palette);
        gpa.free(ix.pixels);
        ix.* = undefined;
    }
};

/// `img` in at most `max_colors` (2 to 256) colors, alpha dropped: its own colors when few
/// enough, else a median-cut palette and each pixel's nearest.
pub fn quantize(gpa: Allocator, img: *const Image, max_colors: usize) Allocator.Error!Indexed {
    std.debug.assert(max_colors >= 2 and max_colors <= 256);
    var quantizer: Quantizer = .{ .gpa = gpa };
    defer quantizer.deinit();
    for (img.pixels) |p| try quantizer.add(opaque_(p));
    try quantizer.build(max_colors);
    const pixels = try gpa.alloc(u8, img.pixels.len);
    errdefer gpa.free(pixels);
    for (img.pixels, pixels) |p, *slot| slot.* = @intCast(try quantizer.index(opaque_(p)));
    return .{
        .width = img.width,
        .height = img.height,
        .palette = try gpa.dupe(Rgba, quantizer.palette.items),
        .pixels = pixels,
    };
}

/// `img` scaled to `width` by `height`: each new pixel the average of the area it covers
/// (alpha weighted), so shrinking keeps detail as a blur rather than dropping it.
pub fn resize(
    gpa: Allocator,
    img: *const Image,
    width: usize,
    height: usize,
) Allocator.Error!Image {
    std.debug.assert(width > 0 and height > 0);
    var out: Image = try .init(gpa, width, height);
    if (img.width == 0 or img.height == 0) return out;
    for (0..height) |y| {
        const sy0 = y * img.height / height;
        const sy1 = @max(sy0 + 1, (y + 1) * img.height / height);
        for (0..width) |x| {
            const sx0 = x * img.width / width;
            const sx1 = @max(sx0 + 1, (x + 1) * img.width / width);
            var sum: [4]u64 = .{ 0, 0, 0, 0 };
            var n: u64 = 0;
            for (sy0..sy1) |sy| for (sx0..sx1) |sx| {
                const c = img.at(sx, sy).*;
                sum[0] += @as(u64, c.r) * c.a;
                sum[1] += @as(u64, c.g) * c.a;
                sum[2] += @as(u64, c.b) * c.a;
                sum[3] += c.a;
                n += 1;
            };
            out.at(x, y).* = if (sum[3] == 0) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else .{
                .r = @intCast(sum[0] / sum[3]),
                .g = @intCast(sum[1] / sum[3]),
                .b = @intCast(sum[2] / sum[3]),
                .a = @intCast(sum[3] / n),
            };
        }
    }
    return out;
}

/// `top` at `alpha` (0 to 255) over `bottom`, in sRGB as terminals blend glyphs.
pub fn blend(bottom: Rgba, top: Rgba, alpha: u32) Rgba {
    if (alpha >= 255) return .{ .r = top.r, .g = top.g, .b = top.b, .a = 255 };
    if (alpha == 0) return bottom;
    const inv = 255 - alpha;
    const out_a = alpha + @as(u32, bottom.a) * inv / 255;
    return .{
        .r = @intCast((@as(u32, top.r) * alpha + @as(u32, bottom.r) * inv) / 255),
        .g = @intCast((@as(u32, top.g) * alpha + @as(u32, bottom.g) * inv) / 255),
        .b = @intCast((@as(u32, top.b) * alpha + @as(u32, bottom.b) * inv) / 255),
        .a = @intCast(@min(out_a, 255)),
    };
}

// PNG.

const png_signature = "\x89PNG\r\n\x1a\n";

/// Writes `img` as a PNG: 8-bit RGBA (RGB when every pixel is opaque).
pub fn writePng(
    gpa: Allocator,
    w: *Writer,
    img: *const Image,
) (Writer.Error || Allocator.Error)!void {
    const opaque_image = for (img.pixels) |p| {
        if (p.a != 255) break false;
    } else true;
    const channels: usize = if (opaque_image) 3 else 4;
    try w.writeAll(png_signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(img.width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(img.height), .big);
    ihdr[8] = 8;
    ihdr[9] = if (opaque_image) 2 else 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(w, "IHDR", &ihdr);
    // Scanlines with the "up" filter (good for screenshots), deflated.
    const stride = img.width * channels;
    const raw = try gpa.alloc(u8, (stride + 1) * img.height);
    defer gpa.free(raw);
    for (0..img.height) |y| {
        const line = raw[y * (stride + 1) ..][0 .. stride + 1];
        line[0] = 2;
        for (0..img.width) |x| {
            const p = img.at(x, y).*;
            const above: Rgba = if (y > 0)
                img.at(x, y - 1).*
            else
                .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            line[1 + x * channels] = p.r -% above.r;
            line[2 + x * channels] = p.g -% above.g;
            line[3 + x * channels] = p.b -% above.b;
            if (channels == 4) line[4 + x * channels] = p.a -% above.a;
        }
    }
    const compressed = try deflate(gpa, raw, .zlib);
    defer gpa.free(compressed);
    try writeChunk(w, "IDAT", compressed);
    try writeChunk(w, "IEND", "");
}

fn deflate(
    gpa: Allocator,
    data: []const u8,
    container: flate.Container,
) (Writer.Error || Allocator.Error)![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    try out.ensureUnusedCapacity(64);
    compressor.* = try .init(&out.writer, window, container, .default);
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return out.toOwnedSlice();
}

fn writeChunk(w: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try w.writeAll(&length);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try w.writeAll(&sum);
}

/// What decoding PNG or GIF can fail with.
pub const DecodeError = error{ InvalidImage, UnsupportedImage } || Allocator.Error;

/// The most pixels a decoder produces (all of a GIF's frames together): 8192 by 8192.
/// Larger images are `error.UnsupportedImage`, so a small file cannot claim gigabytes.
pub const max_pixels = 1 << 26;

/// Reads a PNG: 1, 2, 4, 8, and 16-bit grayscale, RGB, palette, and alpha; interlaced too.
pub fn readPng(gpa: Allocator, data: []const u8) DecodeError!Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], png_signature)) return error.InvalidImage;
    var at: usize = 8;
    var width: usize = 0;
    var height: usize = 0;
    var depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var palette: [256]Rgba = @splat(.{ .r = 0, .g = 0, .b = 0 });
    var transparent: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (at + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[at..][0..4], .big);
        const kind = data[at + 4 ..][0..4];
        if (at + 12 + len > data.len) return error.InvalidImage;
        const body = data[at + 8 ..][0..len];
        at += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.InvalidImage;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            depth = body[8];
            color_type = body[9];
            interlace = body[12];
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            for (0..@min(len / 3, 256)) |i| palette[i] = .{
                .r = body[3 * i],
                .g = body[3 * i + 1],
                .b = body[3 * i + 2],
            };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (color_type == 3) {
                for (body[0..@min(len, 256)], 0..) |alpha, i| palette[i].a = alpha;
            } else if (color_type == 0 and len >= 2) {
                const v = std.mem.readInt(u16, body[0..2], .big);
                transparent = .{ v, v, v };
            } else if (color_type == 2 and len >= 6) {
                transparent = .{
                    std.mem.readInt(u16, body[0..2], .big),
                    std.mem.readInt(u16, body[2..4], .big),
                    std.mem.readInt(u16, body[4..6], .big),
                };
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (width == 0 or height == 0 or width > 1 << 15 or height > 1 << 15) return error.InvalidImage;
    if (width * height > max_pixels) return error.UnsupportedImage;
    const channels: usize = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.InvalidImage,
    };
    switch (depth) {
        1, 2, 4, 8, 16 => {},
        else => return error.InvalidImage,
    }
    const bits_per_pixel = channels * depth;
    // Inflate.
    var input: std.Io.Reader = .fixed(idat.items);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var decompress: flate.Decompress = .init(&input, .zlib, window);
    // No more than the image's rows (and twice that for interlacing's passes) inflate.
    const row_bytes = 1 + (width * bits_per_pixel + 7) / 8;
    const raw = decompress.reader.allocRemaining(
        gpa,
        .limited(2 * height * row_bytes + 64),
    ) catch return error.InvalidImage;
    defer gpa.free(raw);
    var img: Image = try .init(gpa, width, height);
    errdefer img.deinit(gpa);
    const passes: []const [4]u8 = if (interlace == 1)
        &.{
            .{ 0, 0, 8, 8 },
            .{ 4, 0, 8, 8 },
            .{ 0, 4, 4, 8 },
            .{ 2, 0, 4, 4 },
            .{ 0, 2, 2, 4 },
            .{ 1, 0, 2, 2 },
            .{ 0, 1, 1, 2 },
        }
    else
        &.{.{ 0, 0, 1, 1 }};
    var offset: usize = 0;
    for (passes) |pass| {
        if (pass[0] >= width or pass[1] >= height) continue;
        const pw = (width - pass[0] + pass[2] - 1) / pass[2];
        const ph = (height - pass[1] + pass[3] - 1) / pass[3];
        const stride = (pw * bits_per_pixel + 7) / 8;
        const bpp = @max(1, bits_per_pixel / 8);
        const previous = try gpa.alloc(u8, stride);
        defer gpa.free(previous);
        @memset(previous, 0);
        for (0..ph) |py| {
            if (offset + 1 + stride > raw.len) return error.InvalidImage;
            const filter = raw[offset];
            const line = raw[offset + 1 ..][0..stride];
            offset += 1 + stride;
            try unfilter(filter, line, previous, bpp);
            @memcpy(previous, line);
            for (0..pw) |px| {
                const x = pass[0] + px * pass[2];
                const y = pass[1] + py * pass[3];
                img.at(x, y).* = pixelAt(line, px, depth, color_type, &palette, transparent);
            }
        }
    }
    return img;
}

fn unfilter(filter: u8, line: []u8, previous: []const u8, bpp: usize) DecodeError!void {
    for (line, 0..) |*byte, i| {
        const left: u8 = if (i >= bpp) line[i - bpp] else 0;
        const up = previous[i];
        const up_left: u8 = if (i >= bpp) previous[i - bpp] else 0;
        byte.* = switch (filter) {
            0 => byte.*,
            1 => byte.* +% left,
            2 => byte.* +% up,
            3 => byte.* +% @as(u8, @intCast((@as(u16, left) + up) / 2)),
            4 => byte.* +% paeth(left, up, up_left),
            else => return error.InvalidImage,
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn sample(line: []const u8, index: usize, depth: u8) u16 {
    return switch (depth) {
        8 => line[index],
        16 => std.mem.readInt(u16, line[2 * index ..][0..2], .big),
        else => blk: {
            const bit = index * depth;
            const byte = line[bit / 8];
            const shift: u3 = @intCast(8 - depth - bit % 8);
            const mask: u8 = (@as(u8, 1) << @intCast(depth)) - 1;
            break :blk (byte >> shift) & mask;
        },
    };
}

fn to8(value: u16, depth: u8) u8 {
    return switch (depth) {
        16 => @intCast(value >> 8),
        8 => @intCast(value),
        else => @intCast(value * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

fn pixelAt(
    line: []const u8,
    x: usize,
    depth: u8,
    color_type: u8,
    palette: *const [256]Rgba,
    transparent: ?[3]u16,
) Rgba {
    switch (color_type) {
        3 => return palette[sample(line, x, depth) & 0xff],
        0 => {
            const v = sample(line, x, depth);
            const g = to8(v, depth);
            const a: u8 = if (transparent) |t| (if (t[0] == v) 0 else 255) else 255;
            return .{ .r = g, .g = g, .b = g, .a = a };
        },
        4 => {
            const g = to8(sample(line, 2 * x, depth), depth);
            return .{ .r = g, .g = g, .b = g, .a = to8(sample(line, 2 * x + 1, depth), depth) };
        },
        2 => {
            const r = sample(line, 3 * x, depth);
            const g = sample(line, 3 * x + 1, depth);
            const b = sample(line, 3 * x + 2, depth);
            const hidden = if (transparent) |t| t[0] == r and t[1] == g and t[2] == b else false;
            return .{
                .r = to8(r, depth),
                .g = to8(g, depth),
                .b = to8(b, depth),
                .a = if (hidden) 0 else 255,
            };
        },
        else => return .{
            .r = to8(sample(line, 4 * x, depth), depth),
            .g = to8(sample(line, 4 * x + 1, depth), depth),
            .b = to8(sample(line, 4 * x + 2, depth), depth),
            .a = to8(sample(line, 4 * x + 3, depth), depth),
        },
    }
}

// GIF.

/// Writes frames as an animated GIF that loops (unless `loop` is false). Frames are added
/// one at a time; each is compared with the one before it.
pub const GifEncoder = struct {
    gpa: Allocator,
    w: *Writer,
    width: usize,
    height: usize,
    previous: ?Image = null,
    /// Time added to the last frame while the next ones are the same.
    pending_delay: u32 = 0,
    pending: ?Image = null,

    pub fn init(
        gpa: Allocator,
        w: *Writer,
        width: usize,
        height: usize,
        loop: bool,
    ) Writer.Error!GifEncoder {
        try w.writeAll("GIF89a");
        try writeU16(w, @intCast(width));
        try writeU16(w, @intCast(height));
        // No global palette; background 0; aspect 0.
        try w.writeAll(&.{ 0x00, 0, 0 });
        if (loop) try w.writeAll("\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00");
        return .{ .gpa = gpa, .w = w, .width = width, .height = height };
    }

    /// Adds a frame shown for `delay_cs` hundredths of a second. A frame the same as the
    /// one before it only adds its time to that one.
    pub fn add(
        e: *GifEncoder,
        frame: *const Image,
        delay_cs: u32,
    ) (Writer.Error || Allocator.Error)!void {
        std.debug.assert(frame.width == e.width and frame.height == e.height);
        if (e.pending) |*p| {
            if (std.mem.eql(
                u8,
                std.mem.sliceAsBytes(p.pixels),
                std.mem.sliceAsBytes(frame.pixels),
            )) {
                e.pending_delay += delay_cs;
                return;
            }
            try e.emit();
        }
        e.pending = try frame.clone(e.gpa);
        e.pending_delay = delay_cs;
    }

    /// Writes the last frame and the trailer, and frees what is held.
    pub fn finish(e: *GifEncoder) (Writer.Error || Allocator.Error)!void {
        if (e.pending != null) try e.emit();
        if (e.previous) |*p| p.deinit(e.gpa);
        e.previous = null;
        try e.w.writeByte(0x3b);
    }

    fn emit(e: *GifEncoder) (Writer.Error || Allocator.Error)!void {
        var frame = e.pending.?;
        e.pending = null;
        defer {
            if (e.previous) |*p| p.deinit(e.gpa);
            e.previous = frame;
        }
        // The rectangle that changed.
        var x0: usize = 0;
        var y0: usize = 0;
        var x1: usize = e.width;
        var y1: usize = e.height;
        if (e.previous) |*prev| {
            x0 = e.width;
            y0 = e.height;
            x1 = 0;
            y1 = 0;
            for (0..e.height) |y| for (0..e.width) |x| {
                if (!prev.at(x, y).eql(frame.at(x, y).*)) {
                    x0 = @min(x0, x);
                    y0 = @min(y0, y);
                    x1 = @max(x1, x + 1);
                    y1 = @max(y1, y + 1);
                }
            };
            if (x1 == 0) {
                // Nothing changed after all (frames are merged before): a pixel suffices.
                x0 = 0;
                y0 = 0;
                x1 = 1;
                y1 = 1;
            }
        }
        const fw = x1 - x0;
        const fh = y1 - y0;
        // Colors: unchanged pixels become transparent (index 0 when there is a previous).
        const use_transparency = e.previous != null;
        var quantizer: Quantizer = .{ .gpa = e.gpa };
        defer quantizer.deinit();
        for (y0..y1) |y| for (x0..x1) |x| {
            const p = frame.at(x, y).*;
            if (use_transparency and e.previous.?.at(x, y).eql(p)) continue;
            try quantizer.add(opaque_(p));
        };
        const max_colors: usize = if (use_transparency) 255 else 256;
        try quantizer.build(max_colors);
        const offset: usize = @intFromBool(use_transparency);
        const palette_size = quantizer.palette.items.len + offset;
        var bits: u4 = 1;
        while ((@as(usize, 1) << bits) < palette_size) bits += 1;
        // Graphic control: delay, transparency, disposal "leave in place".
        const w = e.w;
        try w.writeAll(&.{ 0x21, 0xf9, 0x04, (1 << 2) | @as(u8, @intFromBool(use_transparency)) });
        try writeU16(w, @intCast(@min(e.pending_delay, 65535)));
        try w.writeAll(&.{ 0, 0 });
        // Image descriptor with a local palette.
        try w.writeByte(0x2c);
        try writeU16(w, @intCast(x0));
        try writeU16(w, @intCast(y0));
        try writeU16(w, @intCast(fw));
        try writeU16(w, @intCast(fh));
        try w.writeByte(0x80 | @as(u8, bits - 1));
        if (use_transparency) try w.writeAll(&.{ 0, 0, 0 });
        for (quantizer.palette.items) |c| try w.writeAll(&.{ c.r, c.g, c.b });
        for (palette_size..(@as(usize, 1) << bits)) |_| try w.writeAll(&.{ 0, 0, 0 });
        // Indices, LZW-coded.
        const indices = try e.gpa.alloc(u8, fw * fh);
        defer e.gpa.free(indices);
        for (y0..y1) |y| for (x0..x1) |x| {
            const p = frame.at(x, y).*;
            const slot = &indices[(y - y0) * fw + (x - x0)];
            if (use_transparency and e.previous.?.at(x, y).eql(p)) {
                slot.* = 0;
            } else {
                slot.* = @intCast(try quantizer.index(opaque_(p)) + offset);
            }
        };
        const min_code: u4 = @max(2, bits);
        try w.writeByte(min_code);
        try lzw(e.gpa, w, indices, min_code);
        try w.writeByte(0);
    }
};

fn opaque_(c: Rgba) Rgba {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
}

fn writeU16(w: *Writer, value: u16) Writer.Error!void {
    try w.writeInt(u16, value, .little);
}

/// Colors to a palette: the colors themselves when few enough, else median cut.
const Quantizer = struct {
    gpa: Allocator,
    counts: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    palette: std.ArrayList(Rgba) = .empty,
    lookup: std.AutoHashMapUnmanaged(u32, u8) = .empty,

    fn deinit(q: *Quantizer) void {
        q.counts.deinit(q.gpa);
        q.palette.deinit(q.gpa);
        q.lookup.deinit(q.gpa);
    }

    fn add(q: *Quantizer, c: Rgba) Allocator.Error!void {
        const got = try q.counts.getOrPut(q.gpa, c.key());
        if (!got.found_existing) got.value_ptr.* = 0;
        got.value_ptr.* += 1;
    }

    const Entry = struct { color: Rgba, count: u32 };

    fn build(q: *Quantizer, max: usize) Allocator.Error!void {
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(q.gpa);
        var it = q.counts.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            try entries.append(q.gpa, .{
                .color = .{
                    .r = @truncate(k >> 24),
                    .g = @truncate(k >> 16),
                    .b = @truncate(k >> 8),
                },
                .count = kv.value_ptr.*,
            });
        }
        if (entries.items.len == 0) {
            try q.palette.append(q.gpa, .{ .r = 0, .g = 0, .b = 0 });
            return;
        }
        if (entries.items.len <= max) {
            for (entries.items, 0..) |entry, i| {
                try q.palette.append(q.gpa, entry.color);
                try q.lookup.put(q.gpa, entry.color.key(), @intCast(i));
            }
            return;
        }
        // Median cut: split the box with the widest channel range at its weighted median,
        // until there are `max` boxes; each box's color is its weighted mean.
        var boxes: std.ArrayList([]Entry) = .empty;
        defer boxes.deinit(q.gpa);
        try boxes.append(q.gpa, entries.items);
        while (boxes.items.len < max) {
            var best: ?usize = null;
            var best_range: u32 = 0;
            for (boxes.items, 0..) |box, i| {
                if (box.len < 2) continue;
                const r = rangeOf(box);
                const score = @as(u32, r.range) * @as(u32, @intCast(@min(box.len, 1 << 16)));
                if (best == null or score > best_range) {
                    best = i;
                    best_range = score;
                }
            }
            const i = best orelse break;
            const box = boxes.items[i];
            const channel = rangeOf(box).channel;
            std.mem.sort(Entry, box, channel, struct {
                fn less(ch: u2, a: Entry, b: Entry) bool {
                    return channelOf(a.color, ch) < channelOf(b.color, ch);
                }
            }.less);
            var total: u64 = 0;
            for (box) |e| total += e.count;
            var running: u64 = 0;
            var split: usize = 1;
            for (box, 0..) |e, k| {
                running += e.count;
                if (running * 2 >= total) {
                    split = @max(1, @min(k + 1, box.len - 1));
                    break;
                }
            }
            boxes.items[i] = box[0..split];
            try boxes.append(q.gpa, box[split..]);
        }
        for (boxes.items) |box| {
            var r: u64 = 0;
            var g: u64 = 0;
            var b: u64 = 0;
            var n: u64 = 0;
            for (box) |e| {
                r += @as(u64, e.color.r) * e.count;
                g += @as(u64, e.color.g) * e.count;
                b += @as(u64, e.color.b) * e.count;
                n += e.count;
            }
            try q.palette.append(q.gpa, .{
                .r = @intCast(r / n),
                .g = @intCast(g / n),
                .b = @intCast(b / n),
            });
        }
    }

    fn rangeOf(box: []const Entry) struct { channel: u2, range: u8 } {
        var lo: [3]u8 = .{ 255, 255, 255 };
        var hi: [3]u8 = .{ 0, 0, 0 };
        for (box) |e| for (0..3) |ch| {
            const v = channelOf(e.color, @intCast(ch));
            lo[ch] = @min(lo[ch], v);
            hi[ch] = @max(hi[ch], v);
        };
        var channel: u2 = 0;
        for (1..3) |ch| if (hi[ch] - lo[ch] > hi[channel] - lo[channel]) {
            channel = @intCast(ch);
        };
        return .{ .channel = channel, .range = hi[channel] - lo[channel] };
    }

    fn channelOf(c: Rgba, ch: u2) u8 {
        return switch (ch) {
            0 => c.r,
            1 => c.g,
            else => c.b,
        };
    }

    /// The palette index nearest `c`.
    fn index(q: *Quantizer, c: Rgba) Allocator.Error!usize {
        const got = try q.lookup.getOrPut(q.gpa, c.key());
        if (got.found_existing) return got.value_ptr.*;
        var best: usize = 0;
        var best_distance: u32 = std.math.maxInt(u32);
        for (q.palette.items, 0..) |p, i| {
            const dr = @as(i32, p.r) - c.r;
            const dg = @as(i32, p.g) - c.g;
            const db = @as(i32, p.b) - c.b;
            const d: u32 = @intCast(2 * dr * dr + 4 * dg * dg + 3 * db * db);
            if (d < best_distance) {
                best = i;
                best_distance = d;
            }
        }
        got.value_ptr.* = @intCast(best);
        return best;
    }
};

/// GIF's LZW: variable-width codes from `min_code + 1` bits, a clear code when the table
/// is full, packed least significant bit first into sub-blocks of up to 255 bytes.
fn lzw(
    gpa: Allocator,
    w: *Writer,
    data: []const u8,
    min_code: u4,
) (Writer.Error || Allocator.Error)!void {
    const clear: u16 = @as(u16, 1) << min_code;
    const end = clear + 1;
    var table: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer table.deinit(gpa);
    var bits: BitPacker = .{ .w = w };
    var width: u5 = @as(u5, min_code) + 1;
    var next: u16 = end + 1;
    try bits.put(clear, width);
    if (data.len == 0) {
        try bits.put(end, width);
        return bits.finish();
    }
    var prefix: u16 = data[0];
    for (data[1..]) |byte| {
        const key = @as(u32, prefix) << 8 | byte;
        if (table.get(key)) |code| {
            prefix = code;
            continue;
        }
        try bits.put(prefix, width);
        if (next < 4096) {
            try table.put(gpa, key, next);
            if (next == (@as(u16, 1) << @intCast(width)) and width < 12) width += 1;
            next += 1;
        } else {
            try bits.put(clear, width);
            table.clearRetainingCapacity();
            width = @as(u5, min_code) + 1;
            next = end + 1;
        }
        prefix = byte;
    }
    try bits.put(prefix, width);
    try bits.put(end, width);
    try bits.finish();
}

const BitPacker = struct {
    w: *Writer,
    buffer: u32 = 0,
    count: u5 = 0,
    block: [255]u8 = undefined,
    block_len: u8 = 0,

    fn put(b: *BitPacker, code: u16, width: u5) Writer.Error!void {
        b.buffer |= @as(u32, code) << b.count;
        b.count += width;
        while (b.count >= 8) {
            try b.byte(@truncate(b.buffer));
            b.buffer >>= 8;
            b.count -= 8;
        }
    }

    fn byte(b: *BitPacker, value: u8) Writer.Error!void {
        b.block[b.block_len] = value;
        b.block_len += 1;
        if (b.block_len == 255) try b.flushBlock();
    }

    fn flushBlock(b: *BitPacker) Writer.Error!void {
        if (b.block_len == 0) return;
        try b.w.writeByte(b.block_len);
        try b.w.writeAll(b.block[0..b.block_len]);
        b.block_len = 0;
    }

    fn finish(b: *BitPacker) Writer.Error!void {
        if (b.count > 0) try b.byte(@truncate(b.buffer));
        b.count = 0;
        try b.flushBlock();
    }
};

/// Reads a GIF's frames, composited, for tests and for showing GIFs in the terminal.
pub fn readGif(gpa: Allocator, data: []const u8) DecodeError![]Image {
    if (data.len < 13 or !std.mem.eql(u8, data[0..3], "GIF")) return error.InvalidImage;
    const width = std.mem.readInt(u16, data[6..8], .little);
    const height = std.mem.readInt(u16, data[8..10], .little);
    const packed_global = data[10];
    var at: usize = 13;
    var global: [256]Rgba = @splat(.{ .r = 0, .g = 0, .b = 0 });
    if (packed_global & 0x80 != 0) {
        const n = @as(usize, 2) << @intCast(packed_global & 7);
        if (at + 3 * n > data.len) return error.InvalidImage;
        for (0..n) |i| global[i] = .{
            .r = data[at + 3 * i],
            .g = data[at + 3 * i + 1],
            .b = data[at + 3 * i + 2],
        };
        at += 3 * n;
    }
    var frames: std.ArrayList(Image) = .empty;
    errdefer {
        for (frames.items) |*f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    if (@as(usize, width) * height > max_pixels) return error.UnsupportedImage;
    var canvas: Image = try .init(gpa, width, height);
    defer canvas.deinit(gpa);
    // Each frame's copy of the canvas, or its own pixels if more (off the screen).
    var budget: usize = 0;
    var transparent: ?u8 = null;
    while (at < data.len) {
        switch (data[at]) {
            0x3b => break,
            0x21 => {
                if (at + 2 > data.len) return error.InvalidImage;
                const label = data[at + 1];
                at += 2;
                if (label == 0xf9 and at + 5 <= data.len and data[at] == 4) {
                    transparent = if (data[at + 1] & 1 != 0) data[at + 4] else null;
                }
                while (at < data.len and data[at] != 0) at += 1 + @as(usize, data[at]);
                at += 1;
            },
            0x2c => {
                if (at + 10 > data.len) return error.InvalidImage;
                const fx = std.mem.readInt(u16, data[at + 1 ..][0..2], .little);
                const fy = std.mem.readInt(u16, data[at + 3 ..][0..2], .little);
                const fw = std.mem.readInt(u16, data[at + 5 ..][0..2], .little);
                const fh = std.mem.readInt(u16, data[at + 7 ..][0..2], .little);
                const flags = data[at + 9];
                at += 10;
                if (@as(usize, fw) * fh > max_pixels) return error.UnsupportedImage;
                // Frames past `max_pixels` in all are dropped.
                budget += @max(canvas.pixels.len, @as(usize, fw) * fh);
                if (budget > max_pixels) break;
                var palette = global;
                if (flags & 0x80 != 0) {
                    const n = @as(usize, 2) << @intCast(flags & 7);
                    if (at + 3 * n > data.len) return error.InvalidImage;
                    for (0..n) |i| palette[i] = .{
                        .r = data[at + 3 * i],
                        .g = data[at + 3 * i + 1],
                        .b = data[at + 3 * i + 2],
                    };
                    at += 3 * n;
                }
                if (at >= data.len) return error.InvalidImage;
                // At most 8 (codes are bytes); larger overflowed the code table.
                if (data[at] > 8) return error.InvalidImage;
                const min_code: u4 = @intCast(data[at]);
                at += 1;
                var stream: std.ArrayList(u8) = .empty;
                defer stream.deinit(gpa);
                while (at < data.len and data[at] != 0) {
                    const n: usize = data[at];
                    if (at + 1 + n > data.len) return error.InvalidImage;
                    try stream.appendSlice(gpa, data[at + 1 ..][0..n]);
                    at += 1 + n;
                }
                at += 1;
                const indices = try unlzw(gpa, stream.items, min_code, @as(usize, fw) * fh);
                defer gpa.free(indices);
                for (0..fh) |y| for (0..fw) |x| {
                    const i = indices[y * fw + x];
                    if (transparent != null and i == transparent.?) continue;
                    if (fx + x < width and fy + y < height) {
                        canvas.at(fx + x, fy + y).* = palette[i];
                    }
                };
                try frames.append(gpa, try canvas.clone(gpa));
            },
            else => return error.InvalidImage,
        }
    }
    return frames.toOwnedSlice(gpa);
}

fn unlzw(gpa: Allocator, stream: []const u8, min_code: u4, count: usize) DecodeError![]u8 {
    const out = try gpa.alloc(u8, count);
    errdefer gpa.free(out);
    @memset(out, 0);
    const clear: u16 = @as(u16, 1) << min_code;
    const end = clear + 1;
    var prefixes: [4096]u16 = undefined;
    var suffixes: [4096]u8 = undefined;
    var lengths: [4096]u16 = undefined;
    for (0..clear) |i| {
        suffixes[i] = @intCast(i);
        lengths[i] = 1;
        prefixes[i] = 0;
    }
    var width: u5 = @as(u5, min_code) + 1;
    var next: u16 = end + 1;
    var previous: ?u16 = null;
    var bit: usize = 0;
    var written: usize = 0;
    while (bit + width <= stream.len * 8 and written < count) {
        var code: u16 = 0;
        for (0..width) |k| {
            const b = bit + k;
            if (stream[b / 8] >> @intCast(b % 8) & 1 != 0) code |= @as(u16, 1) << @intCast(k);
        }
        bit += width;
        if (code == clear) {
            width = @as(u5, min_code) + 1;
            next = end + 1;
            previous = null;
            continue;
        }
        if (code == end) break;
        var entry = code;
        var first_of: u8 = 0;
        if (code >= next) {
            // Only the code about to be defined may be used before it is.
            if (code > next) return error.InvalidImage;
            const prev = previous orelse return error.InvalidImage;
            var c = prev;
            while (lengths[c] > 1) c = prefixes[c];
            first_of = suffixes[c];
            entry = prev;
        }
        // Write the string for `entry` (and the extra byte for a code not yet known).
        const len = lengths[entry];
        if (written + len > count) break;
        var c = entry;
        var k: usize = len;
        while (k > 0) {
            k -= 1;
            out[written + k] = suffixes[c];
            c = prefixes[c];
        }
        written += len;
        if (code >= next and written < count) {
            out[written] = first_of;
            written += 1;
        }
        if (previous) |prev| if (next < 4096) {
            prefixes[next] = prev;
            suffixes[next] = out[written - (if (code >= next) len + 1 else len)];
            lengths[next] = lengths[prev] + 1;
            next += 1;
            if (next == (@as(u16, 1) << @intCast(width)) and width < 12) width += 1;
        };
        previous = code;
    }
    return out;
}

/// Reads any image this module reads, told apart by its first bytes: PNG, JPEG, or a GIF
/// (its first frame).
pub fn decode(gpa: Allocator, data: []const u8) DecodeError!Image {
    if (std.mem.startsWith(u8, data, "GIF8")) {
        const frames = try readGif(gpa, data);
        defer gpa.free(frames);
        if (frames.len == 0) return error.InvalidImage;
        for (frames[1..]) |*f| f.deinit(gpa);
        return frames[0];
    }
    if (std.mem.startsWith(u8, data, "\xff\xd8\xff")) return readJpeg(gpa, data);
    return readPng(gpa, data);
}

/// Reads a JPEG: baseline, extended (8-bit), and progressive Huffman-coded DCT; grayscale,
/// YCbCr, RGB, and Adobe CMYK and YCCK; any sampling factors; restart intervals; turned as
/// its EXIF orientation says. Not read (`error.UnsupportedImage`): arithmetic coding,
/// lossless and hierarchical JPEG, 12-bit samples, and a height left to a DNL marker.
pub fn readJpeg(gpa: Allocator, data: []const u8) DecodeError!Image {
    if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) return error.InvalidImage;
    var jpeg: Jpeg = .{ .gpa = gpa, .data = data };
    defer jpeg.deinit();
    try jpeg.read();
    return jpeg.output();
}

/// Where each coefficient of a block, in the order coded (zigzag), goes in the block.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

const Huffman = struct {
    /// For codes of at most 8 bits, by the next 8 bits: the length << 8 | the symbol;
    /// 0 when the code is longer.
    fast: [256]u16 = @splat(0),
    /// By length: the last code, the first, and the index of the first's symbol.
    max_code: [17]i32 = @splat(-1),
    min_code: [17]i32 = @splat(0),
    first: [17]u16 = @splat(0),
    symbols: [256]u8 = undefined,
    defined: bool = false,

    fn init(counts: *const [16]u8, symbols: []const u8) DecodeError!Huffman {
        var h: Huffman = .{ .defined = true };
        @memcpy(h.symbols[0..symbols.len], symbols);
        var code: u32 = 0;
        var k: u16 = 0;
        for (counts, 1..) |count, len| {
            h.first[len] = k;
            h.min_code[len] = @intCast(code);
            code += count;
            k += count;
            if (code > @as(u32, 1) << @intCast(len)) return error.InvalidImage;
            if (count > 0) h.max_code[len] = @intCast(code - 1);
            if (len <= 8) for (0..count) |i| {
                const c = (code - count + i) << @intCast(8 - len);
                const value: u16 = @intCast(len << 8 | symbols[k - count + i]);
                @memset(h.fast[c..][0 .. @as(usize, 1) << @intCast(8 - len)], value);
            };
            code <<= 1;
        }
        return h;
    }
};

/// The entropy-coded bits of a scan: 0xff 0x00 is 0xff, and a marker ends them (the bits
/// after it read as zeros).
const Bits = struct {
    data: []const u8,
    at: usize,
    /// The next bits, from the top.
    buffer: u64 = 0,
    count: u7 = 0,
    marker: bool = false,

    fn fill(b: *Bits) void {
        while (b.count <= 56) {
            var byte: u8 = 0;
            if (!b.marker and b.at < b.data.len) {
                byte = b.data[b.at];
                if (byte != 0xff) {
                    b.at += 1;
                } else if (b.at + 1 < b.data.len and b.data[b.at + 1] == 0) {
                    b.at += 2;
                } else {
                    b.marker = true;
                    byte = 0;
                }
            }
            b.buffer |= @as(u64, byte) << @intCast(56 - b.count);
            b.count += 8;
        }
    }

    fn take(b: *Bits, n: u5) u16 {
        if (n == 0) return 0;
        b.fill();
        const v: u16 = @intCast(b.buffer >> @intCast(64 - @as(u7, n)));
        b.buffer <<= n;
        b.count -= n;
        return v;
    }

    /// `n` bits as a signed value (JPEG's EXTEND).
    fn signed(b: *Bits, n: u5) i32 {
        if (n == 0) return 0;
        const v: i32 = b.take(n);
        return if (v < @as(i32, 1) << (n - 1)) v - (@as(i32, 1) << n) + 1 else v;
    }

    fn symbol(b: *Bits, h: *const Huffman) DecodeError!u8 {
        b.fill();
        const fast = h.fast[@intCast(b.buffer >> 56)];
        if (fast != 0) {
            b.buffer <<= @intCast(fast >> 8);
            b.count -= @intCast(fast >> 8);
            return @truncate(fast);
        }
        for (9..17) |len| {
            const code: i32 = @intCast(b.buffer >> @intCast(64 - len));
            if (code <= h.max_code[len] and code >= h.min_code[len]) {
                b.buffer <<= @intCast(len);
                b.count -= @intCast(len);
                return h.symbols[@intCast(h.first[len] + code - h.min_code[len])];
            }
        }
        return error.InvalidImage;
    }

    /// Skips the restart marker that ends an interval, and starts the bits after it.
    fn restart(b: *Bits) void {
        b.buffer = 0;
        b.count = 0;
        b.marker = false;
        while (b.at + 1 < b.data.len) : (b.at += 1) {
            if (b.data[b.at] != 0xff or b.data[b.at + 1] == 0 or b.data[b.at + 1] == 0xff)
                continue;
            if (b.data[b.at + 1] >= 0xd0 and b.data[b.at + 1] <= 0xd7) b.at += 2;
            return;
        }
    }
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    quant: u8,
    /// Blocks across and down, every MCU's included.
    blocks_w: usize = 0,
    blocks_h: usize = 0,
    coefs: []i16 = &.{},
    dc: i32 = 0,
    dc_table: u8 = 0,
    ac_table: u8 = 0,

    fn block(c: *const Component, bx: usize, by: usize) *[64]i16 {
        return c.coefs[(by * c.blocks_w + bx) * 64 ..][0..64];
    }
};

const Jpeg = struct {
    gpa: Allocator,
    data: []const u8,
    quant: [4][64]u16 = undefined,
    quant_set: [4]bool = @splat(false),
    dc: [4]Huffman = @splat(.{}),
    ac: [4]Huffman = @splat(.{}),
    components: [4]Component = undefined,
    count: usize = 0,
    width: usize = 0,
    height: usize = 0,
    h_max: u8 = 1,
    v_max: u8 = 1,
    mcus_x: usize = 0,
    mcus_y: usize = 0,
    progressive: bool = false,
    restart_interval: usize = 0,
    eobrun: u32 = 0,
    scans: usize = 0,
    adobe: ?u8 = null,
    orientation: u8 = 1,

    fn deinit(j: *Jpeg) void {
        for (j.components[0..j.count]) |c| j.gpa.free(c.coefs);
    }

    fn read(j: *Jpeg) DecodeError!void {
        const data = j.data;
        var at: usize = 2;
        while (true) {
            while (at < data.len and data[at] != 0xff) at += 1;
            while (at < data.len and data[at] == 0xff) at += 1;
            if (at >= data.len) break;
            const marker = data[at];
            at += 1;
            switch (marker) {
                0xd9 => break,
                0x01, 0xd0...0xd8 => continue,
                else => {},
            }
            if (at + 2 > data.len) return error.InvalidImage;
            const len = std.mem.readInt(u16, data[at..][0..2], .big);
            if (len < 2 or at + len > data.len) return error.InvalidImage;
            const body = data[at + 2 .. at + len];
            at += len;
            switch (marker) {
                0xc0, 0xc1, 0xc2 => try j.frame(body, marker == 0xc2),
                0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => return error.UnsupportedImage,
                0xc4 => try j.huffman(body),
                0xdb => try j.quantization(body),
                0xdd => {
                    if (body.len < 2) return error.InvalidImage;
                    j.restart_interval = std.mem.readInt(u16, body[0..2], .big);
                },
                0xda => at = try j.scan(body, at),
                0xe1 => j.exif(body),
                0xee => if (body.len >= 12 and std.mem.startsWith(u8, body, "Adobe")) {
                    j.adobe = body[11];
                },
                else => {},
            }
        }
        if (j.scans == 0) return error.InvalidImage;
    }

    fn frame(j: *Jpeg, body: []const u8, progressive: bool) DecodeError!void {
        if (j.count != 0 or body.len < 6) return error.InvalidImage;
        if (body[0] != 8) return error.UnsupportedImage;
        j.height = std.mem.readInt(u16, body[1..3], .big);
        j.width = std.mem.readInt(u16, body[3..5], .big);
        if (j.height == 0) return error.UnsupportedImage; // set by a DNL marker
        if (j.width == 0 or j.width > 1 << 15 or j.height > 1 << 15) return error.InvalidImage;
        const count = body[5];
        if (count == 2 or count > 4) return error.UnsupportedImage;
        if (count == 0 or body.len < 6 + 3 * @as(usize, count)) return error.InvalidImage;
        j.progressive = progressive;
        var components: [4]Component = undefined;
        for (components[0..count], 0..) |*c, i| {
            const spec = body[6 + 3 * i ..][0..3];
            c.* = .{ .id = spec[0], .h = spec[1] >> 4, .v = spec[1] & 15, .quant = spec[2] };
            if (c.h == 0 or c.h > 4 or c.v == 0 or c.v > 4 or c.quant > 3)
                return error.InvalidImage;
            j.h_max = @max(j.h_max, c.h);
            j.v_max = @max(j.v_max, c.v);
        }
        j.mcus_x = (j.width + 8 * @as(usize, j.h_max) - 1) / (8 * @as(usize, j.h_max));
        j.mcus_y = (j.height + 8 * @as(usize, j.v_max) - 1) / (8 * @as(usize, j.v_max));
        // Each block takes at least a bit: a file too short for its size is not one.
        var least: usize = 0;
        for (components[0..count]) |c| least += j.blocksAcross(c) * j.blocksDown(c);
        if (j.data.len * 8 < least) return error.InvalidImage;
        for (components[0..count]) |*c| {
            c.blocks_w = j.mcus_x * c.h;
            c.blocks_h = j.mcus_y * c.v;
            c.coefs = try j.gpa.alloc(i16, c.blocks_w * c.blocks_h * 64);
            @memset(c.coefs, 0);
            j.components[j.count] = c.*;
            j.count += 1;
        }
    }

    /// The blocks across a component that cover the image (an MCU's padding not counted).
    fn blocksAcross(j: *const Jpeg, c: Component) usize {
        return ((j.width * c.h + j.h_max - 1) / j.h_max + 7) / 8;
    }

    fn blocksDown(j: *const Jpeg, c: Component) usize {
        return ((j.height * c.v + j.v_max - 1) / j.v_max + 7) / 8;
    }

    fn huffman(j: *Jpeg, body: []const u8) DecodeError!void {
        var rest = body;
        while (rest.len > 0) {
            if (rest.len < 17) return error.InvalidImage;
            const class = rest[0] >> 4;
            const index = rest[0] & 15;
            if (class > 1 or index > 3) return error.InvalidImage;
            const counts = rest[1..17];
            var total: usize = 0;
            for (counts) |n| total += n;
            if (total > 256 or rest.len < 17 + total) return error.InvalidImage;
            const table: Huffman = try .init(counts, rest[17..][0..total]);
            if (class == 0) j.dc[index] = table else j.ac[index] = table;
            rest = rest[17 + total ..];
        }
    }

    fn quantization(j: *Jpeg, body: []const u8) DecodeError!void {
        var rest = body;
        while (rest.len > 0) {
            const wide = rest[0] >> 4 != 0;
            const index = rest[0] & 15;
            const size: usize = if (wide) 128 else 64;
            if (index > 3 or rest.len < 1 + size) return error.InvalidImage;
            for (0..64) |k| j.quant[index][zigzag[k]] = if (wide)
                std.mem.readInt(u16, rest[1 + 2 * k ..][0..2], .big)
            else
                rest[1 + k];
            j.quant_set[index] = true;
            rest = rest[1 + size ..];
        }
    }

    /// The orientation tag of an APP1 Exif segment's first directory.
    fn exif(j: *Jpeg, body: []const u8) void {
        if (body.len < 14 or !std.mem.startsWith(u8, body, "Exif\x00\x00")) return;
        const tiff = body[6..];
        const endian: std.builtin.Endian = switch (tiff[0]) {
            'I' => .little,
            'M' => .big,
            else => return,
        };
        const ifd = std.mem.readInt(u32, tiff[4..8], endian);
        if (ifd > tiff.len or tiff.len - ifd < 2) return;
        const entries = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
        for (0..entries) |i| {
            const at = ifd + 2 + 12 * i;
            if (at + 12 > tiff.len) return;
            if (std.mem.readInt(u16, tiff[at..][0..2], endian) != 0x0112) continue;
            const value = std.mem.readInt(u16, tiff[at + 8 ..][0..2], endian);
            if (value >= 1 and value <= 8) j.orientation = @intCast(value);
            return;
        }
    }

    /// Decodes a scan's coefficients; returns where its entropy-coded data ends.
    fn scan(j: *Jpeg, body: []const u8, start: usize) DecodeError!usize {
        if (j.count == 0 or body.len < 1) return error.InvalidImage;
        const n = body[0];
        if (n == 0 or n > 4 or body.len < 4 + 2 * @as(usize, n)) return error.InvalidImage;
        var in_scan: [4]*Component = undefined;
        for (in_scan[0..n], 0..) |*slot, i| {
            const id = body[1 + 2 * i];
            const tables = body[2 + 2 * i];
            const c = for (j.components[0..j.count]) |*c| {
                if (c.id == id) break c;
            } else return error.InvalidImage;
            c.dc_table = tables >> 4;
            c.ac_table = tables & 15;
            if (c.dc_table > 3 or c.ac_table > 3) return error.InvalidImage;
            slot.* = c;
        }
        const tail = body[1 + 2 * @as(usize, n) ..];
        const ss = tail[0];
        const se = tail[1];
        const ah: u5 = @intCast(tail[2] >> 4);
        const al: u5 = @intCast(tail[2] & 15);
        if (j.progressive) {
            if (ss > se or se > 63 or (ss == 0 and se != 0) or (ss > 0 and n != 1) or
                ah > 13 or al > 13) return error.InvalidImage;
        } else if (ss != 0 or se != 63) return error.InvalidImage;
        for (in_scan[0..n]) |c| {
            if (ss == 0 and ah == 0 and !j.dc[c.dc_table].defined) return error.InvalidImage;
            if (se > 0 and !j.ac[c.ac_table].defined) return error.InvalidImage;
            c.dc = 0;
        }
        j.scans += 1;
        j.eobrun = 0;
        var bits: Bits = .{ .data = j.data, .at = start };
        const scan_: Scan = .{ .ss = ss, .se = se, .ah = ah, .al = al };
        var mcus: usize = 0;
        if (n == 1) {
            // One component: an MCU is a block, and only blocks that show are coded.
            const c = in_scan[0];
            for (0..j.blocksDown(c.*)) |by| for (0..j.blocksAcross(c.*)) |bx| {
                j.restartIf(&bits, &mcus, in_scan[0..1]);
                try j.decodeBlock(&bits, c, c.block(bx, by), scan_);
            };
        } else {
            for (0..j.mcus_y) |my| for (0..j.mcus_x) |mx| {
                j.restartIf(&bits, &mcus, in_scan[0..n]);
                for (in_scan[0..n]) |c| for (0..c.v) |v| for (0..c.h) |h| {
                    const b = c.block(mx * c.h + h, my * c.v + v);
                    try j.decodeBlock(&bits, c, b, scan_);
                };
            };
        }
        // Past the data to the next marker that is not a restart.
        var at = bits.at;
        while (at + 1 < j.data.len) : (at += 1) {
            if (j.data[at] != 0xff) continue;
            const next = j.data[at + 1];
            if (next != 0 and next != 0xff and (next < 0xd0 or next > 0xd7)) break;
        }
        return at;
    }

    fn restartIf(j: *Jpeg, bits: *Bits, mcus: *usize, in_scan: []const *Component) void {
        if (j.restart_interval != 0 and mcus.* > 0 and mcus.* % j.restart_interval == 0) {
            bits.restart();
            for (in_scan) |c| c.dc = 0;
            j.eobrun = 0;
        }
        mcus.* += 1;
    }

    const Scan = struct { ss: u8, se: u8, ah: u5, al: u5 };

    fn decodeBlock(
        j: *Jpeg,
        bits: *Bits,
        c: *Component,
        b: *[64]i16,
        s: Scan,
    ) DecodeError!void {
        if (s.ss == 0) {
            if (s.ah == 0) {
                const size = try bits.symbol(&j.dc[c.dc_table]);
                if (size > 16) return error.InvalidImage;
                c.dc +%= bits.signed(@intCast(size));
                b[0] = @truncate(c.dc *% (@as(i32, 1) << s.al));
            } else if (bits.take(1) != 0) {
                b[0] |= @as(i16, 1) << @intCast(s.al);
            }
            if (s.se == 0) return;
        }
        const ac = &j.ac[c.ac_table];
        if (s.ah == 0 or !j.progressive) {
            if (j.eobrun > 0) {
                j.eobrun -= 1;
                return;
            }
            var k: usize = @max(1, s.ss);
            while (k <= s.se) {
                const rs = try bits.symbol(ac);
                const r = rs >> 4;
                const size: u5 = @intCast(rs & 15);
                if (size == 0) {
                    if (r < 15) {
                        if (j.progressive) j.eobrun = (@as(u32, 1) << @intCast(r)) - 1 +
                            bits.take(@intCast(r));
                        return;
                    }
                    k += 16;
                    continue;
                }
                k += r;
                if (k > s.se) return error.InvalidImage;
                b[zigzag[k]] = @truncate(bits.signed(size) *% (@as(i32, 1) << s.al));
                k += 1;
            }
            return;
        }
        // A refining AC scan: one more bit of each coefficient already nonzero, and new
        // coefficients of ±1 (at this bit) among the zeros.
        const p1 = @as(i16, 1) << @intCast(s.al);
        const m1 = @as(i16, -1) *% p1;
        var k: usize = s.ss;
        if (j.eobrun == 0) {
            while (k <= s.se) : (k += 1) {
                const rs = try bits.symbol(ac);
                var r: i32 = rs >> 4;
                var value: i16 = 0;
                if (rs & 15 != 0) {
                    value = if (bits.take(1) != 0) p1 else m1;
                } else if (r < 15) {
                    j.eobrun = (@as(u32, 1) << @intCast(r)) + bits.take(@intCast(r));
                    break;
                }
                while (k <= s.se) : (k += 1) {
                    const coef = &b[zigzag[k]];
                    if (coef.* != 0) {
                        refine(bits, coef, p1, m1);
                    } else {
                        if (r == 0) break;
                        r -= 1;
                    }
                }
                if (value != 0 and k <= s.se) b[zigzag[k]] = value;
            }
        }
        if (j.eobrun > 0) {
            while (k <= s.se) : (k += 1) {
                const coef = &b[zigzag[k]];
                if (coef.* != 0) refine(bits, coef, p1, m1);
            }
            j.eobrun -= 1;
        }
    }

    fn refine(bits: *Bits, coef: *i16, p1: i16, m1: i16) void {
        if (bits.take(1) != 0 and coef.* & p1 == 0) {
            coef.* +%= if (coef.* >= 0) p1 else m1;
        }
    }

    /// The image: each component's blocks transformed back to samples, chroma upsampled
    /// (bilinear, centered, as libjpeg's "fancy" upsampling), converted to RGB, and turned.
    fn output(j: *Jpeg) DecodeError!Image {
        var planes: [4][]u8 = undefined;
        var made: usize = 0;
        defer for (planes[0..made]) |p| j.gpa.free(p);
        for (j.components[0..j.count], 0..) |*c, i| {
            if (!j.quant_set[c.quant]) return error.InvalidImage;
            const stride = c.blocks_w * 8;
            planes[i] = try j.gpa.alloc(u8, stride * c.blocks_h * 8);
            made += 1;
            for (0..c.blocks_h) |by| for (0..c.blocks_w) |bx| {
                const out = planes[i][(by * stride + bx) * 8 ..];
                idct(c.block(bx, by), &j.quant[c.quant], out, stride);
            };
        }
        const turned = j.orientation >= 5;
        var img: Image = try .init(
            j.gpa,
            if (turned) j.height else j.width,
            if (turned) j.width else j.height,
        );
        errdefer img.deinit(j.gpa);
        const cs = j.components;
        const rgb = j.count == 3 and if (j.adobe) |transform|
            transform == 0
        else
            cs[0].id == 'R' and cs[1].id == 'G' and cs[2].id == 'B';
        var s: [4]u8 = undefined;
        for (0..j.height) |y| for (0..j.width) |x| {
            for (j.components[0..j.count], 0..) |*c, i| s[i] = j.sampleAt(c, planes[i], x, y);
            const p: Rgba = switch (j.count) {
                1 => .{ .r = s[0], .g = s[0], .b = s[0] },
                3 => if (rgb) .{ .r = s[0], .g = s[1], .b = s[2] } else ycc(s[0], s[1], s[2]),
                else => cmyk: {
                    // Adobe writes CMYK inverted; YCCK is that CMY as YCbCr.
                    var cmy: Rgba = .{ .r = s[0], .g = s[1], .b = s[2] };
                    if (j.adobe != null and j.adobe.? == 2) {
                        const t = ycc(s[0], s[1], s[2]);
                        cmy = .{ .r = 255 - t.r, .g = 255 - t.g, .b = 255 - t.b };
                    }
                    break :cmyk .{
                        .r = mul255(cmy.r, s[3]),
                        .g = mul255(cmy.g, s[3]),
                        .b = mul255(cmy.b, s[3]),
                    };
                },
            };
            const w = j.width;
            const h = j.height;
            const dx, const dy = switch (j.orientation) {
                2 => .{ w - 1 - x, y },
                3 => .{ w - 1 - x, h - 1 - y },
                4 => .{ x, h - 1 - y },
                5 => .{ y, x },
                6 => .{ h - 1 - y, x },
                7 => .{ h - 1 - y, w - 1 - x },
                8 => .{ y, w - 1 - x },
                else => .{ x, y },
            };
            img.at(dx, dy).* = p;
        };
        return img;
    }

    fn sampleAt(j: *const Jpeg, c: *const Component, plane: []const u8, x: usize, y: usize) u8 {
        const stride = c.blocks_w * 8;
        if (c.h == j.h_max and c.v == j.v_max) return plane[y * stride + x];
        // libjpeg interpolates only halved chroma; other factors it repeats.
        if (j.h_max > 2 * c.h or j.v_max > 2 * c.v or j.h_max % c.h != 0 or j.v_max % c.v != 0)
            return plane[y * c.v / j.v_max * stride + x * c.h / j.h_max];
        const cw = (j.width * c.h + j.h_max - 1) / j.h_max;
        const ch = (j.height * c.v + j.v_max - 1) / j.v_max;
        const fx = (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(c.h)) /
            @as(f32, @floatFromInt(j.h_max)) - 0.5;
        const fy = (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(c.v)) /
            @as(f32, @floatFromInt(j.v_max)) - 0.5;
        const x0: usize = @intFromFloat(@max(0, @floor(fx)));
        const y0: usize = @intFromFloat(@max(0, @floor(fy)));
        const x1 = @min(x0 + 1, cw - 1);
        const y1 = @min(y0 + 1, ch - 1);
        const tx = std.math.clamp(fx - @as(f32, @floatFromInt(x0)), 0, 1);
        const ty = std.math.clamp(fy - @as(f32, @floatFromInt(y0)), 0, 1);
        const a: f32 = @floatFromInt(plane[y0 * stride + x0]);
        const b: f32 = @floatFromInt(plane[y0 * stride + x1]);
        const cc: f32 = @floatFromInt(plane[y1 * stride + x0]);
        const d: f32 = @floatFromInt(plane[y1 * stride + x1]);
        const top = a + (b - a) * tx;
        const bottom = cc + (d - cc) * tx;
        return clamp8(top + (bottom - top) * ty);
    }
};

/// By u, over x: cos((2x + 1)uπ/16), scaled by C(u)/2, for the inverse DCT.
const idct_table: [8]@Vector(8, f32) = table: {
    @setEvalBranchQuota(10000);
    var t: [8]@Vector(8, f32) = undefined;
    for (0..8) |u| for (0..8) |x| {
        const scale: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        const angle = @as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0;
        t[u][x] = @floatCast(scale / 2.0 * @cos(angle));
    };
    break :table t;
};

/// Dequantizes block `b` and transforms it back into 8 by 8 samples at `out`.
fn idct(b: *const [64]i16, quant: *const [64]u16, out: []u8, stride: usize) void {
    // Rows first, each a vector over x; then the columns, a vector over x for each y.
    var rows: [8]@Vector(8, f32) = @splat(@splat(0));
    for (0..8) |v| for (0..8) |u| {
        const k = v * 8 + u;
        if (b[k] == 0) continue;
        const value = @as(f32, @floatFromInt(b[k])) * @as(f32, @floatFromInt(quant[k]));
        rows[v] += @as(@Vector(8, f32), @splat(value)) * idct_table[u];
    };
    inline for (0..8) |y| {
        var line: @Vector(8, f32) = @splat(128);
        for (0..8) |v| line += rows[v] * @as(@Vector(8, f32), @splat(idct_table[v][y]));
        inline for (0..8) |x| out[y * stride + x] = clamp8(line[x]);
    }
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

fn mul255(a: u8, b: u8) u8 {
    return @intCast((@as(u32, a) * b + 127) / 255);
}

fn ycc(y: u8, cb: u8, cr: u8) Rgba {
    const fy: f32 = @floatFromInt(y);
    const fb = @as(f32, @floatFromInt(cb)) - 128;
    const fr = @as(f32, @floatFromInt(cr)) - 128;
    return .{
        .r = clamp8(fy + 1.402 * fr),
        .g = clamp8(fy - 0.344136 * fb - 0.714136 * fr),
        .b = clamp8(fy + 1.772 * fb),
    };
}

const testing = std.testing;

fn testImage(gpa: Allocator, seed: u8) !Image {
    const img: Image = try .init(gpa, 37, 21);
    for (img.pixels, 0..) |*p, i| p.* = .{
        .r = @truncate(i *% 7 +% seed),
        .g = @truncate(i / 37 * 11),
        .b = @truncate(seed *% 3),
        .a = 255,
    };
    return img;
}

test "PNG round trips, opaque and with alpha" {
    const gpa = testing.allocator;
    var img = try testImage(gpa, 1);
    defer img.deinit(gpa);
    for (0..2) |pass| {
        if (pass == 1) img.pixels[5].a = 128;
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        try writePng(gpa, &out.writer, &img);
        var back = try readPng(gpa, out.written());
        defer back.deinit(gpa);
        try testing.expectEqual(img.width, back.width);
        for (img.pixels, back.pixels) |a, b| try testing.expect(a.eql(b));
    }
    try testing.expectError(error.InvalidImage, readPng(gpa, "not a png"));
}

test "GIF frames: few colors exactly, many approximately, unchanged frames merged" {
    const gpa = testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var encoder: GifEncoder = try .init(gpa, &out.writer, 37, 21, true);
    var a: Image = try .init(gpa, 37, 21);
    defer a.deinit(gpa);
    a.fill(.{ .r = 30, .g = 30, .b = 46 });
    a.fillRect(3, 3, 10, 5, .{ .r = 255, .g = 135, .b = 0 });
    try encoder.add(&a, 10);
    try encoder.add(&a, 10); // merged into the first
    var b = try a.clone(gpa);
    defer b.deinit(gpa);
    b.fillRect(20, 10, 4, 4, .{ .r = 0, .g = 200, .b = 100 });
    try encoder.add(&b, 10);
    var c = try testImage(gpa, 9); // ~777 colors: quantized
    defer c.deinit(gpa);
    try encoder.add(&c, 10);
    try encoder.finish();
    const frames = try readGif(gpa, out.written());
    defer {
        for (frames) |*f| f.deinit(gpa);
        gpa.free(frames);
    }
    try testing.expectEqual(3, frames.len);
    for (a.pixels, frames[0].pixels) |x, y| try testing.expect(x.eql(y));
    for (b.pixels, frames[1].pixels) |x, y| try testing.expect(x.eql(y));
    var error_sum: u64 = 0;
    for (c.pixels, frames[2].pixels) |x, y| {
        error_sum += @abs(@as(i32, x.r) - y.r) + @abs(@as(i32, x.g) - y.g) +
            @abs(@as(i32, x.b) - y.b);
    }
    try testing.expect(error_sum / c.pixels.len < 12);
}

test "LZW round trips across table resets" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(4);
    const data = try gpa.alloc(u8, 20000);
    defer gpa.free(data);
    for (data, 0..) |*d, i| d.* = if (i % 3 == 0) prng.random().int(u8) else @truncate(i / 50);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try lzw(gpa, &out.writer, data, 8);
    // Undo the sub-blocks.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    var at: usize = 0;
    const bytes = out.written();
    while (at < bytes.len and bytes[at] != 0) {
        const n: usize = bytes[at];
        try stream.appendSlice(gpa, bytes[at + 1 ..][0..n]);
        at += 1 + n;
    }
    const back = try unlzw(gpa, stream.items, 8, data.len);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, data, back);
}

test "GIF: frames larger than the screen count toward max_pixels" {
    const gpa = testing.allocator;
    // A 1 by 1 screen, a 1 by 1 frame, then one of 8192 by 8192 in 12 bytes: decoded too.
    const frames = try readGif(gpa, "GIF89a\x01\x00\x01\x00\x00\x00\x00" ++
        "\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x00" ++
        "\x2c\x00\x00\x00\x00\x00\x20\x00\x20\x00\x02\x00;");
    defer {
        for (frames) |*f| f.deinit(gpa);
        gpa.free(frames);
    }
    try testing.expectEqual(1, frames.len);
}

/// Decodes testdata/jpeg/`name`.jpg and compares it with the pixels libjpeg-turbo decodes
/// (make.py there): within 3 of each channel, and 0.25 on average.
fn expectJpeg(comptime name: []const u8, width: usize, height: usize) !void {
    const gpa = testing.allocator;
    const reference = @embedFile("testdata/jpeg/" ++ name ++ ".rgb");
    var img = try decode(gpa, @embedFile("testdata/jpeg/" ++ name ++ ".jpg"));
    defer img.deinit(gpa);
    try testing.expectEqual(width, img.width);
    try testing.expectEqual(height, img.height);
    var sum: usize = 0;
    for (img.pixels, 0..) |p, i| for ([3]u8{ p.r, p.g, p.b }, 0..) |v, c| {
        const d = @abs(@as(i32, v) - reference[3 * i + c]);
        try testing.expect(d <= 3);
        sum += d;
    };
    try testing.expect(sum * 4 <= 3 * img.pixels.len);
}

test "JPEG matches libjpeg-turbo's pixels" {
    try expectJpeg("rgb_16x16_420", 16, 16);
    try expectJpeg("rgb_33x17_444", 33, 17);
    try expectJpeg("rgb_33x17_422", 33, 17);
    try expectJpeg("rgb_33x17_420", 33, 17);
    try expectJpeg("rgb_33x17_411", 33, 17);
    try expectJpeg("rgb_33x17_440", 33, 17);
    try expectJpeg("gray_33x17", 33, 17);
    try expectJpeg("prog_33x17_420", 33, 17);
    try expectJpeg("rst_33x17_420", 33, 17);
    try expectJpeg("prog_rst_33x17_444", 33, 17);
    try expectJpeg("cmyk_16x16", 16, 16);
    try expectJpeg("exif6_16x8", 8, 16); // turned a quarter clockwise
}

test "JPEG: extended is baseline's; lossless, 12-bit, and garbage are refused" {
    const gpa = testing.allocator;
    const original = @embedFile("testdata/jpeg/rgb_33x17_444.jpg");
    var data = original.*;
    const sof = std.mem.indexOf(u8, &data, "\xff\xc0").?;
    data[sof + 1] = 0xc1;
    var a = try readJpeg(gpa, original);
    defer a.deinit(gpa);
    var b = try readJpeg(gpa, &data);
    defer b.deinit(gpa);
    try testing.expectEqualSlices(Rgba, a.pixels, b.pixels);
    data[sof + 1] = 0xc3;
    try testing.expectError(error.UnsupportedImage, readJpeg(gpa, &data));
    data[sof + 1] = 0xc0;
    data[sof + 4] = 12;
    try testing.expectError(error.UnsupportedImage, readJpeg(gpa, &data));
    try testing.expectError(error.InvalidImage, readJpeg(gpa, "\xff\xd8\xff\xd9"));
    // 32768 by 32768 in a few bytes: refused before anything that size is allocated.
    try testing.expectError(error.InvalidImage, readJpeg(
        gpa,
        "\xff\xd8\xff\xc0\x00\x0b\x08\x80\x00\x80\x00\x01\x01\x11\x00\xff\xd9",
    ));
}

test "JPEG: cut short or corrupted, an error or an image, never a crash" {
    const gpa = testing.allocator;
    inline for (.{ "prog_rst_33x17_444", "rst_33x17_420" }) |name| {
        const original = @embedFile("testdata/jpeg/" ++ name ++ ".jpg");
        for (0..original.len) |n| {
            if (readJpeg(gpa, original[0..n])) |img| {
                var copy = img;
                copy.deinit(gpa);
            } else |_| {}
        }
        var data = original.*;
        var prng: std.Random.DefaultPrng = .init(7);
        for (0..data.len) |i| {
            const saved = data[i];
            data[i] = prng.random().int(u8);
            if (readJpeg(gpa, &data)) |img| {
                var copy = img;
                copy.deinit(gpa);
            } else |_| {}
            data[i] = saved;
        }
    }
}
