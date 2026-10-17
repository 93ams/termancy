//! Images in the terminal, in whichever way it draws them: the kitty graphics protocol
//! (kitty, Ghostty, WezTerm), iTerm2's inline images (iTerm2, WezTerm, VS Code), sixels
//! (foot, mlterm, xterm -ti vt340, Windows Terminal), or, anywhere colors show, a mosaic
//! of half blocks: two pixels a cell, the top in the text color and the bottom in the
//! background.
//!
//! The environment usually tells (`detect`); where it does not, the terminal can be asked
//! (`detectByQuery`).
//!
//! ```zig
//! const protocol = term.graphics.detect(environ);
//! try term.graphics.write(gpa, w, &img, .{ .protocol = protocol, .columns = 40 });
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Io = std.Io;
const Environ = std.process.Environ;
const image = @import("image.zig");
const ansi = @import("ansi.zig");
const capability = @import("capability.zig");
const Terminal = @import("Terminal.zig");
const Image = image.Image;
const Rgba = image.Rgba;

/// How an image is drawn.
pub const Protocol = enum { kitty, iterm, sixel, mosaic };

/// The best protocol the terminal is known to understand, from its environment. Sixel
/// support cannot be told from the environment everywhere (xterm has it only when built
/// with it and set to a VT340); those terminals get the mosaic unless asked.
pub fn detect(environ: *const Environ.Map) Protocol {
    const term_name = environ.get("TERM") orelse "";
    const program = environ.get("TERM_PROGRAM") orelse "";
    if (environ.get("KITTY_WINDOW_ID") != null or std.mem.eql(u8, term_name, "xterm-kitty") or
        std.mem.eql(u8, term_name, "xterm-ghostty") or std.mem.eql(u8, program, "ghostty"))
        return .kitty;
    if (std.mem.eql(u8, program, "iTerm.app") or std.mem.eql(u8, program, "WezTerm") or
        std.mem.eql(u8, program, "vscode") or environ.get("LC_TERMINAL") != null)
        return .iterm;
    if (std.mem.startsWith(u8, term_name, "foot") or std.mem.startsWith(u8, term_name, "mlterm") or
        std.mem.indexOf(u8, term_name, "sixel") != null or environ.get("WT_SESSION") != null)
        return .sixel;
    return .mosaic;
}

/// What `detectByQuery` asks: kitty's graphics query (a 1 by 1 RGB image, checked and not
/// kept), then the primary device attributes (DA1), which every terminal answers, and
/// answers last.
pub const query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" ++ "\x1b[c";

/// What the terminal's replies to `query` say it draws images with: kitty when it
/// answered the graphics query OK, sixel when its device attributes list 4, else the
/// mosaic. Null until the device attributes have arrived. Other bytes (keys typed
/// meanwhile) are skipped.
pub fn fromReplies(replies: []const u8) ?Protocol {
    var kitty = false;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, replies, at, 0x1b)) |start| {
        const rest = replies[start..];
        at = start + 1;
        if (std.mem.startsWith(u8, rest, "\x1b_G")) {
            const end = std.mem.indexOf(u8, rest, "\x1b\\") orelse return null;
            if (std.mem.indexOf(u8, rest[0..end], ";OK") != null) kitty = true;
            at = start + end + 2;
        } else if (std.mem.startsWith(u8, rest, "\x1b[?")) {
            const end = std.mem.indexOfNone(u8, rest[3..], "0123456789;") orelse return null;
            if (rest[3 + end] != 'c') continue;
            if (kitty) return .kitty;
            var params = std.mem.splitScalar(u8, rest[3..][0..end], ';');
            while (params.next()) |param| if (std.mem.eql(u8, param, "4")) return .sixel;
            return .mosaic;
        }
    }
    return null;
}

/// Asks the terminal what it draws images with (`query`), in raw mode, and waits at most
/// `timeout` for the answer: for when `detect` finds nothing in the environment. Null when
/// no answer came in time, or the terminal could not be asked.
pub fn detectByQuery(terminal: *Terminal, timeout: Io.Duration) ?Protocol {
    const io = terminal.io;
    const was_raw = terminal.saved != null;
    terminal.enterRaw() catch return null;
    defer if (!was_raw) terminal.restore();
    const w = terminal.writer();
    w.writeAll(query) catch return null;
    w.flush() catch return null;
    const deadline = Io.Timestamp.now(io, .awake).addDuration(timeout);
    // shortcut: keys typed while waiting are dropped, not `unread`; fine for a one-shot.
    var replies: [512]u8 = undefined;
    var len: usize = 0;
    var data: [1][]u8 = undefined;
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(io);
    while (len < replies.len) {
        data[0] = replies[len..];
        if (builtin.os.tag == .windows) {
            // See `tui.Program.run`: a console cannot go through `Io.Batch` on Windows.
            if (!(terminal.waitInput(deadline) catch return null)) return null;
            len += terminal.input.readStreaming(io, &data) catch return null;
            if (fromReplies(replies[0..len])) |protocol| return protocol;
            continue;
        }
        batch.addAt(0, .{ .file_read_streaming = .{ .file = terminal.input, .data = &data } });
        const limit: Io.Timeout = .{ .deadline = .{ .raw = deadline, .clock = .awake } };
        // Without a way to wait on a read and a clock at once, a silent terminal would hang.
        batch.awaitConcurrent(io, limit) catch return null;
        while (batch.next()) |completion| {
            len += completion.result.file_read_streaming catch return null;
        }
        if (fromReplies(replies[0..len])) |protocol| return protocol;
    }
    return null;
}

/// The `Protocol` named `name` (`kitty`, `iterm`, `sixel`, `mosaic`), or null.
pub fn protocolNamed(name: []const u8) ?Protocol {
    return std.meta.stringToEnum(Protocol, name);
}

/// How an image is drawn.
pub const Options = struct {
    protocol: Protocol = .mosaic,
    /// The width to draw at, in cells; the image's own (at `cell_pixels`) when null.
    columns: ?usize = null,
    /// The height in cells; from `columns` and the image's shape when null.
    rows: ?usize = null,
    /// A cell's size in pixels, for turning cells into pixels (sixel scales the image to
    /// fill the cells; the others let the terminal scale).
    cell_pixels: [2]usize = .{ 10, 20 },
    /// The mosaic's colors.
    color: capability.Color = .truecolor,
};

/// The image's size in cells under `options`.
pub fn cells(img: *const Image, options: Options) [2]usize {
    const cw, const ch = options.cell_pixels;
    const columns = options.columns orelse @max(1, (img.width + cw - 1) / cw);
    const rows = options.rows orelse rows: {
        // Keep the image's shape: rows from columns, the cell's height to width ratio.
        const w: f64 = @floatFromInt(@max(1, img.width));
        const h: f64 = @floatFromInt(img.height);
        const per_column = h / w * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(ch));
        const scaled_rows = @round(per_column * @as(f64, @floatFromInt(columns)));
        break :rows @max(1, @as(usize, @intFromFloat(scaled_rows)));
    };
    return .{ columns, rows };
}

/// Draws `img` at the cursor, `columns` by `rows` cells; the cursor ends on the line
/// after it.
pub fn write(
    gpa: Allocator,
    w: *Writer,
    img: *const Image,
    options: Options,
) (Writer.Error || Allocator.Error)!void {
    const columns, const rows = cells(img, options);
    switch (options.protocol) {
        .kitty => try writeKitty(gpa, w, img, columns, rows),
        .iterm => try writeIterm(gpa, w, img, columns, rows),
        .sixel => {
            var scaled = try image.resize(
                gpa,
                img,
                columns * options.cell_pixels[0],
                rows * options.cell_pixels[1],
            );
            defer scaled.deinit(gpa);
            try writeSixel(gpa, w, &scaled);
        },
        .mosaic => {
            var scaled = try image.resize(gpa, img, columns, rows * 2);
            defer scaled.deinit(gpa);
            return writeMosaic(w, &scaled, options.color);
        },
    }
    try w.writeByte('\n');
}

/// The image as PNG, base64 encoded.
fn base64Png(gpa: Allocator, img: *const Image) (Writer.Error || Allocator.Error)![]u8 {
    var png: Writer.Allocating = .init(gpa);
    defer png.deinit();
    try image.writePng(gpa, &png.writer, img);
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, encoder.calcSize(png.written().len));
    _ = encoder.encode(out, png.written());
    return out;
}

/// The kitty graphics protocol: the PNG sent in chunks of 4096 bytes, placed at the cursor
/// over `columns` by `rows` cells, no reply asked for (`q=2`).
pub fn writeKitty(
    gpa: Allocator,
    w: *Writer,
    img: *const Image,
    columns: usize,
    rows: usize,
) (Writer.Error || Allocator.Error)!void {
    const data = try base64Png(gpa, img);
    defer gpa.free(data);
    var offset: usize = 0;
    var first = true;
    while (true) {
        const end = @min(data.len, offset + 4096);
        const more: u8 = if (end < data.len) 1 else 0;
        if (first) {
            try w.print("\x1b_Ga=T,f=100,q=2,c={d},r={d},m={d};", .{ columns, rows, more });
        } else {
            try w.print("\x1b_Gm={d};", .{more});
        }
        try w.writeAll(data[offset..end]);
        try w.writeAll("\x1b\\");
        first = false;
        offset = end;
        if (more == 0) break;
    }
}

/// iTerm2's inline images (OSC 1337 File), `columns` by `rows` cells.
pub fn writeIterm(
    gpa: Allocator,
    w: *Writer,
    img: *const Image,
    columns: usize,
    rows: usize,
) (Writer.Error || Allocator.Error)!void {
    const data = try base64Png(gpa, img);
    defer gpa.free(data);
    try w.print(
        "\x1b]1337;File=inline=1;width={d};height={d};preserveAspectRatio=0:",
        .{ columns, rows },
    );
    try w.writeAll(data);
    try w.writeAll("\x07");
}

/// Sixels, at the image's own size: at most 256 colors, six rows of pixels a line of
/// output, runs compressed. Pixels less than half opaque are left as they are.
pub fn writeSixel(
    gpa: Allocator,
    w: *Writer,
    img: *const Image,
) (Writer.Error || Allocator.Error)!void {
    var indexed = try image.quantize(gpa, img, 256);
    defer indexed.deinit(gpa);
    // P2 = 1: pixels not drawn keep what is behind them. Raster attributes: 1:1, the size.
    try w.print("\x1bP0;1;0q\"1;1;{d};{d}", .{ img.width, img.height });
    for (indexed.palette, 0..) |c, i| {
        try w.print("#{d};2;{d};{d};{d}", .{
            i,
            @as(u32, c.r) * 100 / 255,
            @as(u32, c.g) * 100 / 255,
            @as(u32, c.b) * 100 / 255,
        });
    }
    const used = try gpa.alloc(bool, indexed.palette.len);
    defer gpa.free(used);
    var band: usize = 0;
    while (band < img.height) : (band += 6) {
        @memset(used, false);
        const band_end = @min(img.height, band + 6);
        for (band..band_end) |y| for (0..img.width) |x| {
            if (img.at(x, y).a >= 128) used[indexed.pixels[y * img.width + x]] = true;
        };
        var first = true;
        for (used, 0..) |is_used, color| {
            if (!is_used) continue;
            if (!first) try w.writeByte('$');
            first = false;
            try w.print("#{d}", .{color});
            var run_char: u8 = 0;
            var run: usize = 0;
            for (0..img.width) |x| {
                var bits: u8 = 0;
                for (band..band_end) |y| {
                    const i = y * img.width + x;
                    if (indexed.pixels[i] == color and img.pixels[i].a >= 128) {
                        bits |= @as(u8, 1) << @intCast(y - band);
                    }
                }
                const char = '?' + bits;
                if (char == run_char) {
                    run += 1;
                } else {
                    try writeRun(w, run_char, run);
                    run_char = char;
                    run = 1;
                }
            }
            // A trailing run of nothing need not be sent.
            if (run_char != '?') try writeRun(w, run_char, run);
        }
        try w.writeByte('-');
    }
    try w.writeAll("\x1b\\");
}

fn writeRun(w: *Writer, char: u8, run: usize) Writer.Error!void {
    if (run == 0) return;
    if (run > 3) return w.print("!{d}{c}", .{ run, char });
    try w.splatByteAll(char, run);
}

/// Half blocks, one cell for each two pixels of a column: `▀` in the top pixel's color on
/// the bottom one's. Transparent pixels show the terminal's background.
pub fn writeMosaic(w: *Writer, img: *const Image, level: capability.Color) Writer.Error!void {
    var y: usize = 0;
    while (y < img.height) : (y += 2) {
        for (0..img.width) |x| {
            const top = img.at(x, y).*;
            const bottom: Rgba = if (y + 1 < img.height)
                img.at(x, y + 1).*
            else
                .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const top_shows = top.a >= 128;
            const bottom_shows = bottom.a >= 128;
            if (!top_shows and !bottom_shows) {
                try w.writeAll("\x1b[0m ");
                continue;
            }
            try w.writeAll("\x1b[0;");
            if (top_shows) {
                try colorOf(top).downsample(level).writeParams(w, .fg);
                if (bottom_shows) {
                    try w.writeByte(';');
                    try colorOf(bottom).downsample(level).writeParams(w, .bg);
                }
                try w.writeAll("m\u{2580}");
            } else {
                try colorOf(bottom).downsample(level).writeParams(w, .fg);
                try w.writeAll("m\u{2584}");
            }
        }
        try w.writeAll("\x1b[0m\n");
    }
}

fn colorOf(c: Rgba) ansi.Color {
    return .{ .rgb = .{ .r = c.r, .g = c.g, .b = c.b } };
}

const testing = std.testing;
const vt = @import("vt.zig");

fn checker(gpa: Allocator) !Image {
    var img: Image = try .init(gpa, 4, 4);
    for (0..4) |y| for (0..4) |x| {
        img.at(x, y).* = if ((x + y) % 2 == 0)
            .{ .r = 255, .g = 0, .b = 0 }
        else
            .{ .r = 0, .g = 0, .b = 255 };
    };
    return img;
}

test "mosaic: two pixels a cell, top as text, bottom as background" {
    var img = try checker(testing.allocator);
    defer img.deinit(testing.allocator);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeMosaic(&out.writer, &img, .truecolor);
    var screen: vt.Screen = try .init(testing.allocator, .{ .width = 8, .height = 4 });
    defer screen.deinit();
    var normalized: Writer.Allocating = .init(testing.allocator);
    defer normalized.deinit();
    for (out.written()) |c| {
        if (c == '\n')
            try normalized.writer.writeAll("\r\n")
        else
            try normalized.writer.writeByte(c);
    }
    screen.write(normalized.written());
    const cell = screen.cell(0, 0);
    try testing.expectEqualStrings("\u{2580}", cell.bytes());
    try testing.expectEqual(ansi.Color{ .rgb = .{ .r = 255, .g = 0, .b = 0 } }, cell.pen.fg);
    try testing.expectEqual(ansi.Color{ .rgb = .{ .r = 0, .g = 0, .b = 255 } }, cell.pen.bg);
    try testing.expectEqualStrings("\u{2580}", screen.cell(1, 3).bytes());
    try testing.expect(screen.cell(0, 4).isBlank());
}

test "sixel: palette, bands, runs" {
    var img: Image = try .init(testing.allocator, 8, 7);
    defer img.deinit(testing.allocator);
    img.fill(.{ .r = 255, .g = 255, .b = 255 });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeSixel(testing.allocator, &out.writer, &img);
    // One color: eight full columns of six, then the seventh row alone.
    try testing.expectEqualStrings(
        "\x1bP0;1;0q\"1;1;8;7#0;2;100;100;100#0!8~-#0!8@-\x1b\\",
        out.written(),
    );
}

test "kitty and iTerm2 frame the PNG" {
    var img = try checker(testing.allocator);
    defer img.deinit(testing.allocator);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeKitty(testing.allocator, &out.writer, &img, 2, 1);
    try testing.expect(std.mem.startsWith(
        u8,
        out.written(),
        "\x1b_Ga=T,f=100,q=2,c=2,r=1,m=0;iVBORw0KGgo",
    ));
    try testing.expect(std.mem.endsWith(u8, out.written(), "\x1b\\"));
    out.clearRetainingCapacity();
    try writeIterm(testing.allocator, &out.writer, &img, 2, 1);
    try testing.expect(std.mem.startsWith(
        u8,
        out.written(),
        "\x1b]1337;File=inline=1;width=2;height=1;",
    ));
}

test "detect and cells" {
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(Protocol.mosaic, detect(&env));
    try env.put("TERM", "xterm-kitty");
    try testing.expectEqual(Protocol.kitty, detect(&env));
    var img: Image = try .init(testing.allocator, 100, 100);
    defer img.deinit(testing.allocator);
    try testing.expectEqual([2]usize{ 10, 5 }, cells(&img, .{}));
    try testing.expectEqual([2]usize{ 20, 10 }, cells(&img, .{ .columns = 20 }));
}

test fromReplies {
    try testing.expectEqual(null, fromReplies(""));
    try testing.expectEqual(null, fromReplies("\x1b_Gi=31;OK\x1b\\\x1b[?62;4"));
    try testing.expectEqual(.kitty, fromReplies("\x1b_Gi=31;OK\x1b\\\x1b[?62;22c"));
    try testing.expectEqual(.sixel, fromReplies("x\x1b[?63;1;4;22c"));
    try testing.expectEqual(.mosaic, fromReplies("\x1b[?1;2c"));
    try testing.expectEqual(
        .mosaic,
        fromReplies("\x1b_Gi=31;EINVAL:bad\x1b\\\x1b[A\x1b[?62;44c"),
    );
}

test "the query, answered by a terminal without images" {
    var screen: vt.Screen = try .init(testing.allocator, .{ .width = 20, .height = 2 });
    defer screen.deinit();
    screen.write(query);
    const replies = try screen.takeResponses();
    defer testing.allocator.free(replies);
    try testing.expectEqual(.mosaic, fromReplies(replies));
    try testing.expect(screen.cell(0, 0).isBlank()); // the graphics query drew nothing
}
