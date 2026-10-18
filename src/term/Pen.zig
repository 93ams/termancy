//! The attributes text is drawn with, as SGR (`ESC [ ... m`) sets them: colors for the
//! text, background, and underline; bold, faint, italic, the underline's shape, blink,
//! reverse, invisible, strikethrough, and overline. What a terminal tracks between
//! sequences, so a `Pen` is how the emulator (`vt.Screen`), the renderer, and styled
//! wrapping know what is in effect, and how they write the shortest change to another.
//!
//! ```zig
//! var pen: term.Pen = .{};
//! pen.applyParams("1;38;5;208");
//! try pen.writeFrom(.{}, w, .truecolor); // "\x1b[1;38;5;208m"
//! ```

const std = @import("std");
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");
const capability = @import("capability.zig");
const Parser = @import("Parser.zig");
const Style = @import("Style.zig");

const Pen = @This();

const Color = ansi.Color;

fg: Color = .default,
bg: Color = .default,
underline_color: Color = .default,
underline: Underline = .none,
bold: bool = false,
dim: bool = false,
italic: bool = false,
blink: bool = false,
reverse: bool = false,
invisible: bool = false,
strikethrough: bool = false,
overline: bool = false,

/// The shape of an underline (`4:n`), or none.
pub const Underline = enum(u3) { none, single, double, curly, dotted, dashed };

/// Nothing set: the terminal's default colors, no attributes.
pub const default: Pen = .{};

/// Whether two pens draw alike.
pub fn eql(a: Pen, b: Pen) bool {
    return std.meta.eql(a, b);
}

/// The pen a `Style` paints with.
pub fn fromStyle(style: Style) Pen {
    return .{
        .fg = style.fg,
        .bg = style.bg,
        .underline_color = if (style.underline) style.underline_color else .default,
        .underline = if (style.underline)
            @fromBackingInt(@intCast(@backingInt(style.underline_style)))
        else
            .none,
        .bold = style.bold,
        .dim = style.dim,
        .italic = style.italic,
        .blink = style.blink,
        .reverse = style.reverse,
        .strikethrough = style.strikethrough,
    };
}

/// Applies the parameters of one SGR sequence, as a terminal does. Unknown parameters are
/// ignored; an empty list resets.
pub fn apply(pen: *Pen, params: []const Parser.Param) void {
    if (params.len == 0) {
        pen.* = .{};
        return;
    }
    var i: usize = 0;
    while (i < params.len) {
        const param = params[i];
        const code = param.value orelse 0;
        // The subparameters of a colon form (`4:3`, `38:2::r:g:b`) belong to it.
        var end = i + 1;
        while (end - 1 < params.len and params[end - 1].more and end < params.len) end += 1;
        const subs = params[i + 1 .. end];
        i = end;
        switch (code) {
            0 => pen.* = .{},
            1 => pen.bold = true,
            2 => pen.dim = true,
            3 => pen.italic = true,
            4 => pen.underline = if (param.more and subs.len > 0)
                switch (subs[0].value orelse 1) {
                    0 => .none,
                    1 => .single,
                    2 => .double,
                    3 => .curly,
                    4 => .dotted,
                    5 => .dashed,
                    else => .single,
                }
            else
                .single,
            5, 6 => pen.blink = true,
            7 => pen.reverse = true,
            8 => pen.invisible = true,
            9 => pen.strikethrough = true,
            21 => pen.underline = .double,
            22 => {
                pen.bold = false;
                pen.dim = false;
            },
            23 => pen.italic = false,
            24 => pen.underline = .none,
            25 => pen.blink = false,
            27 => pen.reverse = false,
            28 => pen.invisible = false,
            29 => pen.strikethrough = false,
            30...37 => pen.fg = .{ .basic = @intCast(code - 30) },
            39 => pen.fg = .default,
            40...47 => pen.bg = .{ .basic = @intCast(code - 40) },
            49 => pen.bg = .default,
            53 => pen.overline = true,
            55 => pen.overline = false,
            59 => pen.underline_color = .default,
            90...97 => pen.fg = .{ .basic = @intCast(code - 90 + 8) },
            100...107 => pen.bg = .{ .basic = @intCast(code - 100 + 8) },
            38, 48, 58 => {
                const color = if (param.more)
                    colonColor(subs)
                else
                    semicolonColor(params, &i);
                const target = switch (code) {
                    38 => &pen.fg,
                    48 => &pen.bg,
                    else => &pen.underline_color,
                };
                // Palette entries 0-15 are the ANSI colors, which is how `writeFrom` writes
                // an underline color in one of them.
                if (color) |c| target.* = switch (c) {
                    .indexed => |n| if (n < 16) .{ .basic = @intCast(n) } else c,
                    else => c,
                };
            },
            else => {},
        }
    }
}

/// `5:n` or `2:[colorspace:]r:g:b`, after a colon.
fn colonColor(subs: []const Parser.Param) ?Color {
    if (subs.len == 0) return null;
    switch (subs[0].value orelse 0) {
        5 => return .{ .indexed = channel(subs, 1) orelse return null },
        2 => {
            // With a color space id (`2::r:g:b` or `2:0:r:g:b`) the channels start later.
            const first: usize = if (subs.len >= 5) 2 else 1;
            return .{ .rgb = .{
                .r = channel(subs, first) orelse return null,
                .g = channel(subs, first + 1) orelse return null,
                .b = channel(subs, first + 2) orelse return null,
            } };
        },
        else => return null,
    }
}

/// `;5;n` or `;2;r;g;b`, which take the following parameters; moves `i` past them.
fn semicolonColor(params: []const Parser.Param, i: *usize) ?Color {
    const rest = params[i.*..];
    if (rest.len == 0) return null;
    switch (rest[0].value orelse 0) {
        5 => {
            i.* += @min(rest.len, 2);
            return .{ .indexed = channel(rest, 1) orelse return null };
        },
        2 => {
            i.* += @min(rest.len, 4);
            return .{ .rgb = .{
                .r = channel(rest, 1) orelse return null,
                .g = channel(rest, 2) orelse return null,
                .b = channel(rest, 3) orelse return null,
            } };
        },
        else => return null,
    }
}

fn channel(params: []const Parser.Param, i: usize) ?u8 {
    if (i >= params.len) return null;
    return std.math.cast(u8, params[i].value orelse 0);
}

/// Applies an SGR parameter list written out (`"1;38;5;208"`), as in the bytes between
/// `ESC [` and `m`.
pub fn applyParams(pen: *Pen, text: []const u8) void {
    var parser: Parser = .{};
    var sink: struct {
        pen: *Pen,
        pub fn csi(s: *@This(), seq: Parser.Csi) void {
            if (seq.final == 'm' and seq.private == 0) s.pen.apply(seq.params);
        }
    } = .{ .pen = pen };
    parser.feed("\x1b[", &sink);
    parser.feed(text, &sink);
    parser.feed("m", &sink);
}

/// Writes the shortest SGR sequence that turns `from` into `pen`, with colors lowered to
/// `level`: nothing when they draw alike, a reset and the new attributes when something
/// must be turned off, only what is added otherwise.
pub fn writeFrom(pen: Pen, from: Pen, w: *Writer, level: capability.Color) Writer.Error!void {
    const to = pen.lowered(level);
    const was = from.lowered(level);
    if (to.eql(was)) return;
    if (to.eql(.{})) return w.writeAll(ansi.reset);
    const must_reset = (was.bold and !to.bold) or (was.dim and !to.dim) or
        (was.italic and !to.italic) or (was.blink and !to.blink) or
        (was.reverse and !to.reverse) or (was.invisible and !to.invisible) or
        (was.strikethrough and !to.strikethrough) or (was.overline and !to.overline) or
        (was.underline != .none and to.underline == .none) or
        (was.fg != .default and to.fg == .default) or
        (was.bg != .default and to.bg == .default) or
        (was.underline_color != .default and to.underline_color == .default);
    const base: Pen = if (must_reset) .{} else was;
    var list: ParamList = .{ .w = w };
    if (must_reset) try list.add("0");
    if (to.bold and !base.bold) try list.add("1");
    if (to.dim and !base.dim) try list.add("2");
    if (to.italic and !base.italic) try list.add("3");
    if (to.underline != base.underline and to.underline != .none) {
        try list.add(switch (to.underline) {
            .single => "4",
            .double => "4:2",
            .curly => "4:3",
            .dotted => "4:4",
            .dashed => "4:5",
            .none => unreachable,
        });
    }
    if (to.blink and !base.blink) try list.add("5");
    if (to.reverse and !base.reverse) try list.add("7");
    if (to.invisible and !base.invisible) try list.add("8");
    if (to.strikethrough and !base.strikethrough) try list.add("9");
    if (to.overline and !base.overline) try list.add("53");
    inline for (.{
        .{ "fg", Color.Layer.fg },
        .{ "bg", Color.Layer.bg },
        .{ "underline_color", Color.Layer.underline },
    }) |pair| {
        const color = @field(to, pair[0]);
        if (color != .default and !std.meta.eql(color, @field(base, pair[0]))) {
            try list.separate();
            try color.writeParams(w, pair[1]);
        }
    }
    try list.end();
}

/// Writes the SGR sequence that sets `pen` from the terminal's defaults.
pub fn write(pen: Pen, w: *Writer, level: capability.Color) Writer.Error!void {
    try pen.writeFrom(.{}, w, level);
}

/// This pen with its colors lowered to what `level` can show (none at `.none`, and no
/// underline color below 256 colors).
pub fn lowered(pen: Pen, level: capability.Color) Pen {
    var copy = pen;
    copy.fg = pen.fg.downsample(level);
    copy.bg = pen.bg.downsample(level);
    copy.underline_color = switch (level) {
        .none, .basic => .default,
        else => pen.underline_color.downsample(level),
    };
    return copy;
}

/// Writes `ESC [`, parameters separated by `;`, and `m`, opening the sequence lazily.
const ParamList = struct {
    w: *Writer,
    open: bool = false,

    fn separate(list: *ParamList) Writer.Error!void {
        if (list.open) return list.w.writeByte(';');
        try list.w.writeAll(ansi.csi);
        list.open = true;
    }

    fn add(list: *ParamList, param: []const u8) Writer.Error!void {
        try list.separate();
        try list.w.writeAll(param);
    }

    fn end(list: *ParamList) Writer.Error!void {
        if (list.open) try list.w.writeByte('m');
    }
};

const testing = std.testing;

fn penOf(params: []const u8) Pen {
    var pen: Pen = .{};
    pen.applyParams(params);
    return pen;
}

test apply {
    try testing.expectEqual(Pen{ .bold = true, .fg = .red }, penOf("1;31"));
    try testing.expectEqual(Pen{ .fg = .{ .indexed = 208 } }, penOf("38;5;208"));
    try testing.expectEqual(Pen{ .bg = .hex(0x0a0b0c) }, penOf("48;2;10;11;12"));
    try testing.expectEqual(Pen{ .fg = .hex(0xff0000) }, penOf("38:2::255:0:0"));
    try testing.expectEqual(Pen{ .fg = .hex(0x00ff00) }, penOf("38:2:0:255:0"));
    try testing.expectEqual(Pen{ .underline = .curly, .underline_color = .red }, penOf(
        "4:3;58;5;1",
    ));
    try testing.expectEqual(Pen{ .bg = .bright_blue, .overline = true }, penOf("104;53"));
    try testing.expectEqual(Pen{}, penOf("1;3;0"));
    try testing.expectEqual(Pen{ .dim = false, .italic = true }, penOf("2;3;22"));
    try testing.expectEqual(Pen{}, penOf(""));
    // A color missing its channels changes nothing.
    try testing.expectEqual(Pen{}, penOf("38;2;1;1"));
    // An unknown color kind is skipped alone; the parameters after it are attributes.
    try testing.expectEqual(Pen{ .reverse = true, .bold = true }, penOf("38;7;1"));
    try testing.expectEqual(Pen{ .fg = .red }, penOf("38;5;1"));
}

fn expectTransition(expected: []const u8, from: Pen, to: Pen, level: capability.Color) !void {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try to.writeFrom(from, &w, level);
    try testing.expectEqualStrings(expected, w.buffered());
}

test writeFrom {
    try expectTransition("", .{ .bold = true }, .{ .bold = true }, .truecolor);
    try expectTransition("\x1b[0m", .{ .bold = true }, .{}, .truecolor);
    const bold_italic: Pen = .{ .bold = true, .italic = true };
    try expectTransition("\x1b[3m", .{ .bold = true }, bold_italic, .truecolor);
    try expectTransition("\x1b[0;3m", .{ .bold = true }, .{ .italic = true }, .truecolor);
    try expectTransition("\x1b[38;5;208m", .{}, .{ .fg = .hex(0xff8700) }, .ansi256);
    try expectTransition("\x1b[38;2;255;135;0m", .{}, .{ .fg = .hex(0xff8700) }, .truecolor);
    try expectTransition("\x1b[4:3;58;2;1;2;3m", .{}, .{
        .underline = .curly,
        .underline_color = .hex(0x010203),
    }, .truecolor);
    // Colors that lower to the same thing need no sequence.
    try expectTransition("", .{ .fg = .hex(0xff0000) }, .{ .fg = .hex(0xfe0000) }, .basic);
    try expectTransition("", .{ .fg = .red }, .{}, .none);
}

test "a written pen applied again is the same pen" {
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    for (0..500) |_| {
        const colors = [_]Color{ .default, .red, .bright_cyan, .{ .indexed = 99 }, .hex(0x123456) };
        const from: Pen = .{
            .bold = random.boolean(),
            .fg = colors[random.uintLessThan(usize, 5)],
        };
        const to: Pen = .{
            .fg = colors[random.uintLessThan(usize, 5)],
            .bg = colors[random.uintLessThan(usize, 5)],
            .underline_color = colors[random.uintLessThan(usize, 5)],
            .underline = @fromBackingInt(@intCast(random.uintLessThan(u3, 6))),
            .bold = random.boolean(),
            .dim = random.boolean(),
            .italic = random.boolean(),
            .blink = random.boolean(),
            .reverse = random.boolean(),
            .invisible = random.boolean(),
            .strikethrough = random.boolean(),
            .overline = random.boolean(),
        };
        var buffer: [256]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try to.writeFrom(from, &w, .truecolor);
        var pen = from;
        var parser: Parser = .{};
        var sink: struct {
            pen: *Pen,
            pub fn csi(s: *@This(), seq: Parser.Csi) void {
                s.pen.apply(seq.params);
            }
        } = .{ .pen = &pen };
        parser.feed(w.buffered(), &sink);
        try testing.expectEqual(to, pen);
    }
}
