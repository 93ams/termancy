//! Coverage-guided fuzz tests of `term`'s parsers of untrusted input: terminal output (the
//! escape-sequence `Parser` and the `vt` screen it drives), terminal input (`input.Decoder`),
//! Markdown, PNG and GIF, TrueType fonts, syntax highlighting, and regular expressions (a
//! tape's `Wait /pattern/`).
//!
//! `zig build fuzz --fuzz` (or `--fuzz=100K` for a bounded run) explores them from the seeds
//! below; a plain `zig build fuzz` (and `zig build unit`) replays the seeds and each target's
//! `*_regressions`, so a crash the fuzzer finds becomes a test by adding its input there.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const vt = @import("vt.zig");
const input = @import("input.zig");
const markdown = @import("markdown.zig");
const image = @import("image.zig");
const TrueType = @import("TrueType.zig");
const highlight = @import("highlight.zig");
const Regex = @import("Regex.zig");

/// The longest input a target reads (regressions included: longer ones are cut).
const max_input = 1 << 13;

/// `docs` as fuzzer inputs: each a 4-byte little-endian length, then the bytes, which is
/// how `std.testing.Smith.slice` reads them.
fn inputs(arena: Allocator, docs: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, docs.len);
    for (docs, out) |doc, *entry| {
        const bytes = try arena.alloc(u8, 4 + doc.len);
        std.mem.writeInt(u32, bytes[0..4], @intCast(doc.len), .little);
        @memcpy(bytes[4..], doc);
        entry.* = bytes;
    }
    return out;
}

/// The bytes a target reads, in `testing.allocator`: exactly as long as the input, so that
/// reading past its end is caught.
fn take(smith: *testing.Smith) Allocator.Error![]u8 {
    const buffer = try testing.allocator.alloc(u8, max_input);
    errdefer testing.allocator.free(buffer);
    const len = smith.slice(buffer);
    return testing.allocator.realloc(buffer, len);
}

fn fuzzWith(
    comptime testOne: fn (void, *testing.Smith) anyerror!void,
    docs: []const []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.fuzz({}, testOne, .{ .corpus = try inputs(arena_state.allocator(), docs) });
}

// The escape-sequence parser.

/// A digest of every action, to compare two parses.
const Digest = struct {
    hash: std.hash.Wyhash = .init(0),
    actions: usize = 0,

    fn add(d: *Digest, tag: u8, bytes: []const u8) void {
        d.actions += 1;
        d.hash.update(&.{tag});
        d.hash.update(std.mem.asBytes(&bytes.len));
        d.hash.update(bytes);
    }
    fn addParams(d: *Digest, params: []const Parser.Param) void {
        for (params) |p| {
            const value: u16 = p.value orelse 0;
            d.hash.update(std.mem.asBytes(&value));
            d.hash.update(&.{@intFromBool(p.value == null) | @as(u8, @intFromBool(p.more)) << 1});
        }
    }

    pub fn print(d: *Digest, cp: u21) void {
        std.debug.assert(cp <= 0x10ffff);
        d.add('p', std.mem.asBytes(&cp));
    }
    pub fn execute(d: *Digest, byte: u8) void {
        d.add('x', &.{byte});
    }
    pub fn csi(d: *Digest, seq: Parser.Csi) void {
        std.debug.assert(seq.params.len <= Parser.max_params);
        d.add('c', &.{ seq.private, seq.final });
        d.hash.update(seq.intermediates);
        d.addParams(seq.params);
    }
    pub fn esc(d: *Digest, seq: Parser.Esc) void {
        d.add('e', &.{seq.final});
        d.hash.update(seq.intermediates);
    }
    pub fn osc(d: *Digest, data: []const u8) void {
        std.debug.assert(data.len <= Parser.max_string);
        d.add('o', data);
    }
    pub fn dcs(d: *Digest, seq: Parser.Dcs) void {
        d.add('d', &.{ seq.private, seq.final });
        d.hash.update(seq.intermediates);
        d.addParams(seq.params);
        d.hash.update(seq.data);
    }
    pub fn apc(d: *Digest, data: []const u8) void {
        d.add('a', data);
    }
};

/// Parsing in two pieces gives the actions parsing at once does, and no more actions
/// than bytes; the `vt` screen takes the same bytes without crashing.
fn fuzzParser(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    var whole: Digest = .{};
    var p: Parser = .{};
    p.feed(bytes, &whole);
    try testing.expect(whole.actions <= bytes.len);
    const cut = if (bytes.len == 0) 0 else bytes[0] % (bytes.len + 1);
    var split: Digest = .{};
    var q: Parser = .{};
    q.feed(bytes[0..cut], &split);
    q.feed(bytes[cut..], &split);
    try testing.expectEqual(whole.actions, split.actions);
    try testing.expectEqual(whole.hash.final(), split.hash.final());

    var screen: vt.Screen = try .initOptions(
        testing.allocator,
        .{ .width = 12, .height = 4 },
        .{ .scrollback = 3 },
    );
    defer screen.deinit();
    screen.write(bytes[0..cut]);
    try screen.resize(.{ .width = 5, .height = 7 });
    screen.write(bytes[cut..]);
    testing.allocator.free(try screen.takeResponses());
    testing.allocator.free(try screen.textAlloc(testing.allocator));
}

test "fuzz: escape-sequence parser and vt screen" {
    try fuzzWith(fuzzParser, &[_][]const u8{
        "hi\xe4\xb8\xad\r\n\x1b[1;31mred\x1b[0m\x1b[38:2::255:0:0mx",
        "\x1b[?1049h\x1b[2J\x1b[H\x1b[5;10r\x1b[3L\x1b[2M\x1b[4@\x1b[3P\x1b[?25l\x1b[1 q",
        "\x1b]0;title\x07\x1b]8;;https://e.com\x1b\\link\x1b]8;;\x1b\\\x1b]52;c;aGk=\x07",
        "\x1bP1$r0m\x1b\\\x1b_Ga=T;AAAA\x1b\\\x1b^pm\x1b\\\x1bXsos\x1b\\",
        "\x1b(0lqk\x1b(B\x1b7\x1b8\x1bD\x1bM\x1bE\x1bc\x1b[6n\x1b[c\x1b[?u\x1b]11;?\x07",
        "a\xcc\x81\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xff\xe4\xb8x\tb\x08\x0b",
    } ++ parser_regressions);
}

/// Inputs that once broke the parser or the screen.
const parser_regressions = [_][]const u8{};

// Terminal input.

/// Every byte decodes to at most one event, and a flushed decoder holds nothing but an
/// unfinished paste.
fn fuzzInput(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    var d: input.Decoder = .init(testing.allocator);
    defer d.deinit();
    const cut = if (bytes.len == 0) 0 else bytes[0] % (bytes.len + 1);
    var events: usize = 0;
    try d.feed(bytes[0..cut]);
    while (d.next()) |_| events += 1;
    try d.feed(bytes[cut..]);
    while (d.next()) |_| events += 1;
    while (d.flush()) |_| events += 1;
    try testing.expect(events <= bytes.len);
    try testing.expect(!d.hasPending() or d.pasting);
}

test "fuzz: input decoder" {
    try fuzzWith(fuzzInput, &[_][]const u8{
        "abc\x1b[A\x1bOB\x1b[1;5C\x1b[3~\x1b[15;2~\x7f\x1b\x7f\x01",
        "\x1b[<0;10;5M\x1b[<0;10;5m\x1b[M !!\x1b[<64;1;1M",
        "\x1b[200~pasted \x1b[A text\x1b[201~\x1b[I\x1b[O",
        "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\\x1b[?2026;2$y\x1b[?5u\x1b[?62;22c",
        "\x1b[97;5u\x1b[13;2:3u\x1b[57399u\xc3\xa9\xf0\x9f\x90\x8d\xe4\xb8",
    } ++ input_regressions);
}

/// Inputs that once broke the decoder.
const input_regressions = [_][]const u8{};

// Markdown.

fn fuzzMarkdown(_: void, smith: *testing.Smith) anyerror!void {
    const source = try take(smith);
    defer testing.allocator.free(source);
    testing.allocator.free(try markdown.renderAlloc(testing.allocator, source, .{}));
    // Narrow, with links and line breaks kept: the paths the default leaves alone.
    testing.allocator.free(try markdown.renderAlloc(testing.allocator, source, .{
        .width = 6,
        .hyperlinks = true,
        .base_url = "https://e.com/a/",
        .preserve_newlines = true,
    }));
}

test "fuzz: markdown" {
    try fuzzWith(fuzzMarkdown, &[_][]const u8{
        \\# Title
        \\
        \\Some *em* and **strong** and `code` and [a link](https://e.com "t") :smile:
        \\> quote
        \\> > nested
        \\
        \\- one
        \\  - two
        \\1. three
        \\- [x] done
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\| a | b |
        \\|:--|--:|
        \\| 1 | 2 |
        \\
        \\***
        \\![img](x.png) <https://auto.link> [ref][r] footnote[^1]
        \\
        \\[r]: https://e.com
        \\[^1]: note
        ,
        "Setext\n===\n\n    indented code\n\n<div>html</div>\n\n\\*escaped\\* ~~del~~ &amp;",
    } ++ markdown_regressions);
}

/// Inputs that once broke the renderer.
const markdown_regressions = [_][]const u8{
    // Quotes and lists nested thousands deep overflowed the stack.
    repeat("> ", 4000),
    repeat("- ", 4000),
    repeat("> - ", 2000),
};

fn repeat(comptime piece: []const u8, comptime n: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(10 * n * piece.len);
        var out: [n * piece.len]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * piece.len ..][0..piece.len], piece);
        const final = out;
        return &final;
    }
}

// Images.

/// A decoded image has as many pixels as its size says.
fn fuzzImage(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    if (image.readPng(testing.allocator, bytes)) |decoded| {
        var img = decoded;
        defer img.deinit(testing.allocator);
        try testing.expectEqual(img.width * img.height, img.pixels.len);
    } else |err| switch (err) {
        error.InvalidImage, error.UnsupportedImage, error.OutOfMemory => {},
    }
    if (image.readGif(testing.allocator, bytes)) |frames| {
        defer {
            for (frames) |*frame| frame.deinit(testing.allocator);
            testing.allocator.free(frames);
        }
        for (frames) |frame| try testing.expectEqual(frame.width * frame.height, frame.pixels.len);
    } else |err| switch (err) {
        error.InvalidImage, error.UnsupportedImage, error.OutOfMemory => {},
    }
    if (image.readJpeg(testing.allocator, bytes)) |decoded| {
        var img = decoded;
        defer img.deinit(testing.allocator);
        try testing.expectEqual(img.width * img.height, img.pixels.len);
    } else |err| switch (err) {
        error.InvalidImage, error.UnsupportedImage, error.OutOfMemory => {},
    }
}

test "fuzz: png, gif, and jpeg" {
    const gpa = testing.allocator;
    // Seeds from the encoders: an opaque image (RGB), one with alpha (RGBA), an animation.
    var img: image.Image = try .init(gpa, 3, 2);
    defer img.deinit(gpa);
    for (img.pixels, 0..) |*p, i| p.* = .{ .r = @intCast(i * 40), .g = 7, .b = 200, .a = 255 };
    var rgb: std.Io.Writer.Allocating = .init(gpa);
    defer rgb.deinit();
    try image.writePng(gpa, &rgb.writer, &img);
    var gif: std.Io.Writer.Allocating = .init(gpa);
    defer gif.deinit();
    var encoder: image.GifEncoder = try .init(gpa, &gif.writer, 3, 2, true);
    try encoder.add(&img, 10);
    img.pixels[0].r = 255;
    try encoder.add(&img, 10);
    try encoder.finish();
    img.pixels[1].a = 128;
    var rgba: std.Io.Writer.Allocating = .init(gpa);
    defer rgba.deinit();
    try image.writePng(gpa, &rgba.writer, &img);
    const seeds = [_][]const u8{
        rgb.written(),
        rgba.written(),
        gif.written(),
        @embedFile("testdata/jpeg/rgb_33x17_420.jpg"),
        @embedFile("testdata/jpeg/prog_rst_33x17_444.jpg"),
        @embedFile("testdata/jpeg/cmyk_16x16.jpg"),
    };
    try fuzzWith(fuzzImage, &(seeds ++ image_regressions));
}

/// Inputs that once broke a decoder.
const image_regressions = [_][]const u8{
    // A GIF's LZW minimum code size above 8 overflowed the code table.
    "GIF89a\x01\x00\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x09\x01\x00\x00;",
    // Sizes of gigapixels were allocated (and filled) for files of a few bytes.
    "GIF89a\xff\xff\xff\xff\x00\x00\x00;",
    "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x80\x00\x00\x00\x80\x00\x08\x06\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00IEND\x00\x00\x00\x00",
    // A code past the next one to be defined was taken for it.
    "GIF89a\x02\x00\x08\x00\x00\x00\x00,\x00\x00\x00\x00\x02\x00\x08\x00\x00\x02\x02\xf8\x7f\x00;",
};

// TrueType.

/// A font is read lazily: every glyph lookup, outline, and raster of a font that loads is
/// an error at worst.
fn fuzzFont(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    const font = TrueType.init(bytes, 0) catch return;
    for ([_]u21{ 'A', 'B', 0xe9, 0x4e2d, 0x1f40d, 0 }) |cp| {
        const glyph = font.glyphIndex(cp);
        _ = font.advance(glyph);
        var mask = font.rasterize(testing.allocator, glyph, 12, .{
            .skew = 0.2,
            .embolden = 1,
        }) catch continue;
        defer mask.deinit(testing.allocator);
        try testing.expectEqual(mask.width * mask.height, mask.pixels.len);
    }
    for (0..4) |glyph| {
        var mask = font.rasterize(testing.allocator, @intCast(glyph), 9, .{}) catch continue;
        mask.deinit(testing.allocator);
    }
}

test "fuzz: truetype" {
    try fuzzWith(fuzzFont, &[_][]const u8{&tiny_font} ++ font_regressions);
}

/// Inputs that once broke the font reader.
const font_regressions = [_][]const u8{};

/// A font of three glyphs, for the fuzzer to start from: glyph 0 is empty, 1 a square
/// with a curved side (for 'A' and 'B'), 2 a composite of 1 scaled and moved (for 'é').
const tiny_font = font: {
    const glyf = glyph_square ++ glyph_composite;
    const loca = be16(0) ++ be16(0) ++ be16(glyph_square.len / 2) ++ be16(glyf.len / 2);
    const tables = .{
        .{ "cmap", cmap },
        .{ "glyf", glyf },
        .{ "head", head },
        .{ "hhea", hhea },
        .{ "hmtx", be16(500) ++ be16(0) ++ be16(600) ++ be16(10) ++ be16(600) ++ be16(10) },
        .{ "loca", loca },
        .{ "maxp", be32(0x00005000) ++ be16(3) },
    };
    var directory: []const u8 = be32(0x00010000) ++ be16(tables.len) ++ zeros(6);
    var body: []const u8 = "";
    const start = 12 + 16 * tables.len;
    for (tables) |t| {
        directory = directory ++ t[0] ++ be32(0) ++ be32(start + body.len) ++ be32(t[1].len);
        body = body ++ t[1] ++ zeros((4 - t[1].len % 4) % 4);
    }
    break :font (directory ++ body)[0..].*;
};

const head = be32(0x00010000) ++ be32(0) ++ be32(0) ++ be32(0x5f0f3cf5) ++ be16(0) ++
    be16(1000) ++ zeros(16) ++ zeros(8) ++ be16(0) ++ be16(8) ++ be16(2) ++
    be16(0) ++ be16(0);
const hhea = be32(0x00010000) ++ be16(800) ++ be16(@bitCast(@as(i16, -200))) ++ be16(0) ++
    zeros(22) ++ be16(0) ++ be16(3);
/// Format 4: 'A' and 'B' to glyph 1, 'é' to glyph 2.
const cmap = be16(0) ++ be16(1) ++ be16(3) ++ be16(1) ++ be32(12) ++ format4;
const format4 = be16(4) ++ be16(14 + 8 * 3 + 2) ++ be16(0) ++ be16(6) ++ be16(4) ++
    be16(1) ++ be16(2) ++
    be16('B') ++ be16(0xe9) ++ be16(0xffff) ++ be16(0) ++
    be16('A') ++ be16(0xe9) ++ be16(0xffff) ++
    be16(1 -% @as(u16, 'A')) ++ be16(2 -% @as(u16, 0xe9)) ++ be16(1) ++
    zeros(6);
/// One contour: three on-curve corners and an off-curve point, x and y as 16-bit deltas.
const glyph_square = be16(1) ++ zeros(8) ++ be16(3) ++ be16(0) ++
    "\x01\x01\x00\x01" ++
    be16(100) ++ be16(400) ++ be16(@bitCast(@as(i16, -200))) ++ be16(@bitCast(@as(i16, -300))) ++
    be16(0) ++ be16(0) ++ be16(600) ++ be16(@bitCast(@as(i16, -600)));
/// Glyph 1 at half size, moved by (10, 20) as words.
const glyph_composite = be16(0xffff) ++ zeros(8) ++ be16(1 | 2 | 8) ++ be16(1) ++
    be16(10) ++ be16(20) ++ be16(0x2000);

fn zeros(comptime n: usize) *const [n]u8 {
    comptime {
        const out: [n]u8 = @splat(0);
        return &out;
    }
}

fn be16(comptime v: u16) *const [2]u8 {
    comptime {
        var out: [2]u8 = undefined;
        std.mem.writeInt(u16, &out, v, .big);
        const final = out;
        return &final;
    }
}

fn be32(comptime v: u32) *const [4]u8 {
    comptime {
        var out: [4]u8 = undefined;
        std.mem.writeInt(u32, &out, v, .big);
        const final = out;
        return &final;
    }
}

test "the tiny font loads and draws" {
    const font = try TrueType.init(&tiny_font, 0);
    try testing.expectEqual(1, font.glyphIndex('A'));
    try testing.expectEqual(2, font.glyphIndex(0xe9));
    try testing.expectEqual(0, font.glyphIndex('C'));
    var mask = try font.rasterize(testing.allocator, 2, 32, .{});
    defer mask.deinit(testing.allocator);
    try testing.expect(mask.pixels.len > 0);
}

// Syntax highlighting.

/// The tokens of any language put back together are the source.
fn fuzzHighlight(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    if (bytes.len == 0) return;
    const lang = &highlight.languages[bytes[0] % highlight.languages.len];
    const source = bytes[1..];
    var lexer: highlight.Lexer = .{ .source = source, .language = lang };
    var at: usize = 0;
    while (lexer.next()) |token| {
        try testing.expect(token.text.len > 0);
        try testing.expectEqualStrings(source[at..][0..token.text.len], token.text);
        at += token.text.len;
    }
    try testing.expectEqual(source.len, at);
}

test "fuzz: highlight" {
    const samples = [_][]const u8{
        "const x = @import(\"std\"); // c\n\\\\ line\nfn f() !void { return 0x1f; }\n",
        "def f(a):\n    '''doc'''\n    return a + 1  # c\n",
        "echo \"$HOME\" '${x}' | grep -v x && exit 1\n",
        "{\"a\": [1, 2.5e3, true, null], \"b\": \"\\u00e9\"}\n",
        "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n",
        "<a href=\"x\">t</a><!-- c -->\n# h\n```\ncode\n```\n[s]\nk = v ; c\n",
        "SELECT * FROM t WHERE a = 'x' /* c */;\n",
    };
    var docs: [samples.len * 4 + highlight_regressions.len][]const u8 = undefined;
    @memcpy(docs[samples.len * 4 ..], &highlight_regressions);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // Each sample under a few languages: the first byte picks the language.
    for (docs[0 .. samples.len * 4], 0..) |*doc, i| {
        const sample = samples[i / 4];
        const lang: u8 = @intCast((i * 7 + i / 4) % highlight.languages.len);
        doc.* = try std.mem.concat(arena_state.allocator(), u8, &.{ &.{lang}, sample });
    }
    try fuzzWith(fuzzHighlight, &docs);
}

/// Inputs that once broke a lexer.
const highlight_regressions = [_][]const u8{};

// Regular expressions.

/// The first byte is the pattern's length, then the pattern, then the text: a match lies
/// within the text, and a whole match is a match.
fn fuzzRegex(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = try take(smith);
    defer testing.allocator.free(bytes);
    if (bytes.len == 0) return;
    const split = @min(bytes.len, 1 + @as(usize, bytes[0]));
    var re = Regex.compile(testing.allocator, bytes[1..split]) catch |err| switch (err) {
        error.InvalidPattern => return,
        error.OutOfMemory => return err,
    };
    defer re.deinit(testing.allocator);
    const text = bytes[split..];
    if (re.search(text)) |m| try testing.expect(m.start <= m.end and m.end <= text.len);
    if (re.matchesWhole(text)) try testing.expect(re.isMatch(text));
}

test "fuzz: regex" {
    try fuzzWith(fuzzRegex, &[_][]const u8{
        "\x11ready in [0-9]+msready in 42ms",
        "\x13^(?:a|b)*?c{2,3}\\b$abbacc",
        "\x10[^\\d\\s]+\\w{1,}.$x\xc3\xa9 1",
    } ++ regex_regressions);
}

/// Inputs that once broke the compiler or the matcher.
const regex_regressions = [_][]const u8{
    // A class decoded a UTF-8 sequence the end of the text cut short.
    "\x03[a]\xe4\xb8",
};
