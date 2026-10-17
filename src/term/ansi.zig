//! Escape sequences as functions writing to a `*std.Io.Writer`: cursor movement, erasing,
//! terminal modes, scroll regions, SGR colors, OSC 8 hyperlinks, OSC 52 clipboard, and
//! window titles. Also the reverse direction: finding, stripping, and downsampling escapes
//! already in a string.
//!
//! Positions are 0-based here and converted to the terminal's 1-based form on output.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const capability = @import("capability.zig");

/// Control Sequence Introducer.
pub const csi = "\x1b[";
/// Operating System Command.
pub const osc = "\x1b]";
/// String Terminator, which ends OSC, DCS, and similar strings.
pub const st = "\x1b\\";
/// SGR reset: every attribute and color back to the default.
pub const reset = csi ++ "0m";

/// Moves the cursor up `n` rows; nothing for 0.
pub fn cursorUp(w: *Writer, n: usize) Writer.Error!void {
    if (n > 0) try w.print(csi ++ "{d}A", .{n});
}

/// Moves the cursor down `n` rows; nothing for 0.
pub fn cursorDown(w: *Writer, n: usize) Writer.Error!void {
    if (n > 0) try w.print(csi ++ "{d}B", .{n});
}

/// Moves the cursor right `n` columns; nothing for 0.
pub fn cursorForward(w: *Writer, n: usize) Writer.Error!void {
    if (n > 0) try w.print(csi ++ "{d}C", .{n});
}

/// Moves the cursor left `n` columns; nothing for 0.
pub fn cursorBack(w: *Writer, n: usize) Writer.Error!void {
    if (n > 0) try w.print(csi ++ "{d}D", .{n});
}

/// Moves the cursor to `column` of the current row.
pub fn cursorColumn(w: *Writer, column: usize) Writer.Error!void {
    try w.print(csi ++ "{d}G", .{column + 1});
}

/// Moves the cursor to `row`, `column`.
pub fn cursorTo(w: *Writer, row: usize, column: usize) Writer.Error!void {
    if (row == 0 and column == 0) return w.writeAll(csi ++ "H");
    try w.print(csi ++ "{d};{d}H", .{ row + 1, column + 1 });
}

/// Saves the cursor position (DECSC).
pub fn saveCursor(w: *Writer) Writer.Error!void {
    try w.writeAll("\x1b7");
}

/// Restores the position saved by `saveCursor` (DECRC).
pub fn restoreCursor(w: *Writer) Writer.Error!void {
    try w.writeAll("\x1b8");
}

/// Which part of the line or screen to erase, relative to the cursor (inclusive).
pub const Erase = enum(u2) { to_end = 0, to_start = 1, all = 2 };

/// Erases part of the current line (EL). The cursor does not move.
pub fn eraseLine(w: *Writer, part: Erase) Writer.Error!void {
    try eraseSequence(w, part, 'K');
}

/// Erases part of the screen (ED). The cursor does not move.
pub fn eraseScreen(w: *Writer, part: Erase) Writer.Error!void {
    try eraseSequence(w, part, 'J');
}

fn eraseSequence(w: *Writer, part: Erase, final: u8) Writer.Error!void {
    if (part == .to_end) return w.print(csi ++ "{c}", .{final});
    try w.print(csi ++ "{d}{c}", .{ @backingInt(part), final });
}

/// Restricts scrolling to rows `top` through `bottom`, inclusive (DECSTBM).
pub fn setScrollRegion(w: *Writer, top: usize, bottom: usize) Writer.Error!void {
    assert(top < bottom);
    try w.print(csi ++ "{d};{d}r", .{ top + 1, bottom + 1 });
}

/// Makes the whole screen scroll again.
pub fn resetScrollRegion(w: *Writer) Writer.Error!void {
    try w.writeAll(csi ++ "r");
}

/// Scrolls the scroll region up `n` rows (new blank rows at the bottom).
pub fn scrollUp(w: *Writer, n: usize) Writer.Error!void {
    if (n > 0) try w.print(csi ++ "{d}S", .{n});
}

/// Scrolls the scroll region down `n` rows (new blank rows at the top).
pub fn scrollDown(w: *Writer, n: usize) Writer.Error!void {
    if (n > 0) try w.print(csi ++ "{d}T", .{n});
}

/// DEC private modes, set with `setMode`.
pub const Mode = enum(u16) {
    cursor_visible = 25,
    mouse_press = 1000,
    mouse_drag = 1002,
    mouse_motion = 1003,
    focus_events = 1004,
    mouse_sgr = 1006,
    alt_screen = 1049,
    bracketed_paste = 2004,
    /// Synchronized output: the terminal holds the screen until the mode is reset, so a
    /// frame drawn in between appears at once. Terminals without it ignore the sequence.
    synchronized_output = 2026,
};

/// Turns a DEC private mode on or off.
pub fn setMode(w: *Writer, mode: Mode, on: bool) Writer.Error!void {
    try w.print(csi ++ "?{d}{c}", .{ @backingInt(mode), @as(u8, if (on) 'h' else 'l') });
}

/// Asks whether `mode` is supported and set (DECRQM); the reply is
/// `input.Report.mode`. Terminals that do not know DECRQM stay silent.
pub fn queryMode(w: *Writer, mode: Mode) Writer.Error!void {
    try w.print(csi ++ "?{d}$p", .{@backingInt(mode)});
}

/// Asks for the default foreground color (OSC 10); the reply is `input.Report.foreground`.
pub fn queryForeground(w: *Writer) Writer.Error!void {
    try w.writeAll(osc ++ "10;?" ++ st);
}

/// Asks for the default background color (OSC 11); the reply is `input.Report.background`.
pub fn queryBackground(w: *Writer) Writer.Error!void {
    try w.writeAll(osc ++ "11;?" ++ st);
}

/// Asks for the kitty keyboard protocol's flags; only terminals with the protocol reply
/// (`input.Report.kitty_keyboard`).
pub fn queryKittyKeyboard(w: *Writer) Writer.Error!void {
    try w.writeAll(csi ++ "?u");
}

/// Asks for the primary device attributes (DA1), which every terminal answers
/// (`input.Report.device_attributes`). Sent after other queries, its reply marks the end
/// of theirs.
pub fn queryDeviceAttributes(w: *Writer) Writer.Error!void {
    try w.writeAll(csi ++ "c");
}

/// Mouse reporting: presses, releases, wheel, and drags, in SGR encoding (which has no
/// coordinate limit and distinguishes releases).
/// Pushes (or pops) the kitty keyboard protocol's "disambiguate escape codes" flag:
/// modified keys arrive as `CSI code;mods u`, so ctrl+i is not tab and alt+[ is not the start
/// of a sequence. Terminals without the protocol ignore it.
pub fn setKittyKeyboard(w: *Writer, on: bool) Writer.Error!void {
    try w.writeAll(if (on) "\x1b[>1u" else "\x1b[<u");
}

/// Turns mouse reporting on (presses, drags, SGR encoding) or off.
pub fn setMouse(w: *Writer, on: bool) Writer.Error!void {
    if (on) {
        try w.writeAll(csi ++ "?1000h" ++ csi ++ "?1002h" ++ csi ++ "?1006h");
    } else {
        try w.writeAll(csi ++ "?1006l" ++ csi ++ "?1002l" ++ csi ++ "?1000l");
    }
}

/// Sets the window title (OSC 2).
pub fn setTitle(w: *Writer, title: []const u8) Writer.Error!void {
    try w.print(osc ++ "2;{s}" ++ st, .{title});
}

/// Writes `text` as a hyperlink to `url` (OSC 8). Terminals without hyperlinks show the
/// text alone.
pub fn hyperlink(w: *Writer, url: []const u8, text: []const u8) Writer.Error!void {
    try w.print(osc ++ "8;;{s}" ++ st ++ "{s}" ++ osc ++ "8;;" ++ st, .{ url, text });
}

/// Shows a desktop notification through the terminal: OSC 9 (iTerm2, WezTerm, Windows
/// Terminal, kitty) and OSC 777 (foot, rxvt, VTE-based terminals); a terminal knowing
/// neither ignores both. Control characters in the text are dropped.
pub fn notify(w: *Writer, title: []const u8, body: []const u8) Writer.Error!void {
    try w.writeAll(osc ++ "9;");
    try writePrintable(w, if (body.len > 0) body else title);
    try w.writeAll(st ++ osc ++ "777;notify;");
    try writePrintable(w, title);
    try w.writeByte(';');
    try writePrintable(w, body);
    try w.writeAll(st);
}

/// What a taskbar or tab shows of a long job (OSC 9;4: Windows Terminal, ConEmu, WezTerm,
/// Ghostty).
pub const Progress = union(enum) {
    /// Nothing; clears what was shown.
    none,
    /// A percentage, 0 to 100.
    normal: u8,
    @"error": u8,
    paused: u8,
    /// Busy, for how long unknown.
    indeterminate,
};

/// Sets the taskbar progress; `.none` clears it, as a program should before it ends.
pub fn setProgress(w: *Writer, progress: Progress) Writer.Error!void {
    const state: u8, const value: u8 = switch (progress) {
        .none => .{ 0, 0 },
        .normal => |p| .{ 1, @min(p, 100) },
        .@"error" => |p| .{ 2, @min(p, 100) },
        .indeterminate => .{ 3, 0 },
        .paused => |p| .{ 4, @min(p, 100) },
    };
    try w.print(osc ++ "9;4;{d};{d}" ++ st, .{ state, value });
}

fn writePrintable(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| if (c >= 0x20 and c != 0x7f) try w.writeByte(c);
}

/// Asks the terminal to put `text` on the system clipboard (OSC 52). Many terminals
/// disable this or limit its size; nothing reports whether it worked.
pub fn copyToClipboard(w: *Writer, text: []const u8) Writer.Error!void {
    const encoder = std.base64.standard.Encoder;
    try w.writeAll(osc ++ "52;c;");
    var chunk: [4 * 64]u8 = undefined;
    var rest = text;
    while (rest.len > 0) {
        const take = @min(rest.len, 3 * 64);
        try w.writeAll(encoder.encode(&chunk, rest[0..take]));
        rest = rest[take..];
    }
    try w.writeAll(st);
}

/// A color as an SGR parameter can express it.
pub const Color = union(enum) {
    /// The terminal's own foreground or background.
    default,
    /// One of the 16 ANSI colors: 0-7 normal, 8-15 bright.
    basic: u4,
    /// An entry of the xterm 256-color palette.
    indexed: u8,
    rgb: Rgb,

    /// A 24-bit color.
    pub const Rgb = struct {
        r: u8,
        g: u8,
        b: u8,

        /// Whether light text reads better on this color than dark text: its relative
        /// luminance (sRGB, as WCAG defines it) is below the middle gray's.
        pub fn isDark(rgb: Rgb) bool {
            return rgb.luminance() < 0.179;
        }

        /// Relative luminance, 0 for black to 1 for white.
        pub fn luminance(rgb: Rgb) f32 {
            const r = linear(rgb.r);
            const g = linear(rgb.g);
            const b = linear(rgb.b);
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }

        fn linear(channel: u8) f32 {
            const c = @as(f32, @floatFromInt(channel)) / 255;
            return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
        }

        fn gamma(value: f32) u8 {
            const c = std.math.clamp(value, 0, 1);
            const v = if (c <= 0.0031308)
                c * 12.92
            else
                1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }

        /// The WCAG contrast ratio of two colors, from 1 (none) to 21 (black on white);
        /// 4.5 is the usual minimum for text.
        pub fn contrast(a: Rgb, b: Rgb) f32 {
            const la = a.luminance() + 0.05;
            const lb = b.luminance() + 0.05;
            return @max(la, lb) / @min(la, lb);
        }

        /// A color in Oklab, the perceptual space blends and lightness changes are made in,
        /// so that a gradient looks even and lightening keeps the hue.
        pub const Oklab = struct { l: f32, a: f32, b: f32 };

        /// This color in Oklab.
        pub fn oklab(rgb: Rgb) Oklab {
            const r = linear(rgb.r);
            const g = linear(rgb.g);
            const b = linear(rgb.b);
            const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
            const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
            const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
            return .{
                .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            };
        }

        /// The sRGB color nearest to `lab`, clipped to the gamut.
        pub fn fromOklab(lab: Oklab) Rgb {
            const l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
            const m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
            const s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;
            const l = l_ * l_ * l_;
            const m = m_ * m_ * m_;
            const s = s_ * s_ * s_;
            return .{
                .r = gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                .g = gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                .b = gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            };
        }

        /// The color `t` of the way from `a` to `b` (0 is `a`, 1 is `b`), in Oklab.
        pub fn blend(a: Rgb, b: Rgb, t: f32) Rgb {
            const x = a.oklab();
            const y = b.oklab();
            const k = std.math.clamp(t, 0, 1);
            return fromOklab(.{
                .l = x.l + (y.l - x.l) * k,
                .a = x.a + (y.a - x.a) * k,
                .b = x.b + (y.b - x.b) * k,
            });
        }

        /// `rgb` drawn at `opacity` (0 to 1) over `background`, mixed in linear light as a
        /// screen mixes it.
        pub fn over(rgb: Rgb, background: Rgb, opacity: f32) Rgb {
            const k = std.math.clamp(opacity, 0, 1);
            return .{
                .r = gamma(linear(rgb.r) * k + linear(background.r) * (1 - k)),
                .g = gamma(linear(rgb.g) * k + linear(background.g) * (1 - k)),
                .b = gamma(linear(rgb.b) * k + linear(background.b) * (1 - k)),
            };
        }

        /// Lighter by `amount` (0 to 1) of Oklab lightness, hue and chroma kept.
        pub fn lighten(rgb: Rgb, amount: f32) Rgb {
            var lab = rgb.oklab();
            lab.l = std.math.clamp(lab.l + amount, 0, 1);
            return fromOklab(lab);
        }

        /// Darker by `amount` (0 to 1) of Oklab lightness.
        pub fn darken(rgb: Rgb, amount: f32) Rgb {
            return rgb.lighten(-amount);
        }

        /// The color opposite on the hue circle, at the same lightness and chroma.
        pub fn complementary(rgb: Rgb) Rgb {
            const lab = rgb.oklab();
            return fromOklab(.{ .l = lab.l, .a = -lab.a, .b = -lab.b });
        }
    };

    /// The RGB value this color shows: palette entries as xterm draws them, `.default` as
    /// `fallback` (the terminal's own color, which only the terminal knows).
    pub fn toRgb(color: Color, fallback: Rgb) Rgb {
        return switch (color) {
            .default => fallback,
            .basic => |n| palette.rgbOf(n),
            .indexed => |n| palette.rgbOf(n),
            .rgb => |rgb| rgb,
        };
    }

    /// `light` on a light background, `dark` on a dark one, as lipgloss's `LightDark`
    /// chooses: a program learns which from `Queries.background` (or `COLORFGBG`).
    pub fn lightDark(dark_background: bool, light: Color, dark: Color) Color {
        return if (dark_background) dark else light;
    }

    /// The color `t` (0 to 1) of the way along `stops` (at least one), blended in Oklab.
    pub fn along(stops: []const Color, t: f32) Color {
        assert(stops.len > 0);
        const no_color: Rgb = .{ .r = 0, .g = 0, .b = 0 };
        if (stops.len == 1) return .{ .rgb = stops[0].toRgb(no_color) };
        const position = std.math.clamp(t, 0, 1) * @as(f32, @floatFromInt(stops.len - 1));
        const segment: usize = @min(@as(usize, @intFromFloat(position)), stops.len - 2);
        const k = position - @as(f32, @floatFromInt(segment));
        const from = stops[segment].toRgb(no_color);
        return .{ .rgb = from.blend(stops[segment + 1].toRgb(no_color), k) };
    }

    /// The color `t` (0 to 1) of the way around a loop through `stops`, the last blending
    /// back into the first: for gradients around a border.
    pub fn around(stops: []const Color, t: f32) Color {
        assert(stops.len > 0);
        const no_color: Rgb = .{ .r = 0, .g = 0, .b = 0 };
        const n = stops.len;
        const position = (t - @floor(t)) * @as(f32, @floatFromInt(n));
        const segment: usize = @min(@as(usize, @intFromFloat(position)), n - 1);
        const k = position - @as(f32, @floatFromInt(segment));
        const from = stops[segment].toRgb(no_color);
        const to = stops[(segment + 1) % n].toRgb(no_color);
        return .{ .rgb = from.blend(to, k) };
    }

    /// Fills `out` with an even gradient through `stops` (at least one), blended in Oklab:
    /// the first entry is the first stop, the last the last. Palette colors are taken as
    /// xterm draws them; `.default` as black.
    pub fn gradient(out: []Color, stops: []const Color) void {
        assert(stops.len > 0);
        const no_color: Rgb = .{ .r = 0, .g = 0, .b = 0 };
        if (stops.len == 1 or out.len == 1) {
            for (out) |*c| c.* = .{ .rgb = stops[0].toRgb(no_color) };
            if (out.len == 1 and stops.len > 1) out[0] = .{ .rgb = stops[0].toRgb(no_color) };
            return;
        }
        const segments: f32 = @floatFromInt(stops.len - 1);
        const last: f32 = @floatFromInt(out.len - 1);
        for (out, 0..) |*c, i| {
            const position = @as(f32, @floatFromInt(i)) / last * segments;
            const segment: usize = @min(@as(usize, @intFromFloat(position)), stops.len - 2);
            const t = position - @as(f32, @floatFromInt(segment));
            const a = stops[segment].toRgb(no_color);
            const b = stops[segment + 1].toRgb(no_color);
            c.* = .{ .rgb = a.blend(b, t) };
        }
    }

    /// Fills `out` (`width` × `height`, row by row) with a gradient through `stops` along
    /// the direction `degrees` (0 left to right, 90 top to bottom), as lipgloss's `Blend2D`.
    pub fn gradient2d(
        out: []Color,
        width: usize,
        height: usize,
        degrees: f32,
        stops: []const Color,
    ) void {
        assert(out.len == width * height and stops.len > 0);
        const no_color: Rgb = .{ .r = 0, .g = 0, .b = 0 };
        const radians = degrees * std.math.pi / 180;
        const dx = @cos(radians);
        const dy = @sin(radians);
        // Project every cell on the direction, then spread the projections over 0..1.
        var low: f32 = std.math.inf(f32);
        var high: f32 = -std.math.inf(f32);
        const xs = [_]f32{ 0, @floatFromInt(width -| 1) };
        const ys = [_]f32{ 0, @floatFromInt(height -| 1) };
        for (xs) |x| for (ys) |y| {
            const p = x * dx + y * dy;
            low = @min(low, p);
            high = @max(high, p);
        };
        const span = if (high > low) high - low else 1;
        const segments: f32 = @floatFromInt(stops.len -| 1);
        for (0..height) |row| for (0..width) |column| {
            const p = @as(f32, @floatFromInt(column)) * dx + @as(f32, @floatFromInt(row)) * dy;
            const position = (p - low) / span * segments;
            const cell = &out[row * width + column];
            if (stops.len == 1) {
                cell.* = .{ .rgb = stops[0].toRgb(no_color) };
                continue;
            }
            const whole: usize = @intFromFloat(@max(position, 0));
            const segment = @min(whole, stops.len - 2);
            const t = position - @as(f32, @floatFromInt(segment));
            const from = stops[segment].toRgb(no_color);
            cell.* = .{ .rgb = from.blend(stops[segment + 1].toRgb(no_color), t) };
        };
    }

    /// ANSI color 0.
    pub const black: Color = .{ .basic = 0 };
    /// ANSI color 1.
    pub const red: Color = .{ .basic = 1 };
    /// ANSI color 2.
    pub const green: Color = .{ .basic = 2 };
    /// ANSI color 3.
    pub const yellow: Color = .{ .basic = 3 };
    /// ANSI color 4.
    pub const blue: Color = .{ .basic = 4 };
    /// ANSI color 5.
    pub const magenta: Color = .{ .basic = 5 };
    /// ANSI color 6.
    pub const cyan: Color = .{ .basic = 6 };
    /// ANSI color 7.
    pub const white: Color = .{ .basic = 7 };
    /// ANSI color 8.
    pub const bright_black: Color = .{ .basic = 8 };
    /// ANSI color 9.
    pub const bright_red: Color = .{ .basic = 9 };
    /// ANSI color 10.
    pub const bright_green: Color = .{ .basic = 10 };
    /// ANSI color 11.
    pub const bright_yellow: Color = .{ .basic = 11 };
    /// ANSI color 12.
    pub const bright_blue: Color = .{ .basic = 12 };
    /// ANSI color 13.
    pub const bright_magenta: Color = .{ .basic = 13 };
    /// ANSI color 14.
    pub const bright_cyan: Color = .{ .basic = 14 };
    /// ANSI color 15.
    pub const bright_white: Color = .{ .basic = 15 };

    const names = [16][]const u8{
        "black",        "red",            "green",        "yellow",
        "blue",         "magenta",        "cyan",         "white",
        "bright-black", "bright-red",     "bright-green", "bright-yellow",
        "bright-blue",  "bright-magenta", "bright-cyan",  "bright-white",
    };

    /// An RGB color from `0xrrggbb`.
    pub fn hex(value: u24) Color {
        return .{ .rgb = .{
            .r = @truncate(value >> 16),
            .g = @truncate(value >> 8),
            .b = @truncate(value),
        } };
    }

    /// The text names no color.
    pub const ParseError = error{InvalidColor};

    /// Parses `#rrggbb`, `#rgb`, a palette index `0`-`255`, a name (`red`, `bright-red`,
    /// `bright_red`), or `default`. The `parse` convention shared with `cli` and `cfg`.
    pub fn parse(text: []const u8) ParseError!Color {
        if (std.mem.eql(u8, text, "default")) return .default;
        if (text.len > 0 and text[0] == '#') return parseHex(text[1..]);
        if (std.fmt.parseInt(u8, text, 10)) |index| {
            return if (index < 16) .{ .basic = @intCast(index) } else .{ .indexed = index };
        } else |_| {}
        for (names, 0..) |name, i| {
            if (nameEql(name, text)) return .{ .basic = @intCast(i) };
        }
        return error.InvalidColor;
    }

    fn nameEql(name: []const u8, text: []const u8) bool {
        if (name.len != text.len) return false;
        for (name, text) |a, b| {
            const c = if (b == '_') '-' else std.ascii.toLower(b);
            if (a != c) return false;
        }
        return true;
    }

    fn parseHex(digits: []const u8) ParseError!Color {
        const value = std.fmt.parseInt(u24, digits, 16) catch return error.InvalidColor;
        return switch (digits.len) {
            6 => hex(value),
            3 => .{ .rgb = .{
                .r = @as(u8, @truncate(value >> 8 & 0xf)) * 17,
                .g = @as(u8, @truncate(value >> 4 & 0xf)) * 17,
                .b = @as(u8, @truncate(value & 0xf)) * 17,
            } },
            else => error.InvalidColor,
        };
    }

    /// The closest color `level` can show; `.default` when it shows none.
    pub fn downsample(color: Color, level: capability.Color) Color {
        return switch (level) {
            .none => .default,
            .truecolor => color,
            .ansi256 => switch (color) {
                .rgb => |rgb| .{ .indexed = palette.nearest256(rgb) },
                else => color,
            },
            .basic => switch (color) {
                .default, .basic => color,
                .indexed => |index| .{ .basic = palette.nearest16(palette.rgbOf(index)) },
                .rgb => |rgb| .{ .basic = palette.nearest16(rgb) },
            },
        };
    }

    /// Which SGR color a parameter sets: text, background, or underline (SGR 58, which
    /// has no codes of its own for the 16 ANSI colors, so it writes them as palette entries).
    pub const Layer = enum { fg, bg, underline };

    /// Writes the SGR parameters for `color` on `layer`, without the `ESC [` and `m`.
    pub fn writeParams(color: Color, w: *Writer, layer: Layer) Writer.Error!void {
        if (layer == .underline) return switch (color) {
            .default => w.writeAll("59"),
            .basic => |n| w.print("58;5;{d}", .{n}),
            .indexed => |n| w.print("58;5;{d}", .{n}),
            .rgb => |c| w.print("58;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
        };
        const base: u8 = if (layer == .fg) 30 else 40;
        switch (color) {
            .default => try w.print("{d}", .{base + 9}),
            .basic => |n| {
                const code = if (n < 8) base + n else base + 60 + (n - 8);
                try w.print("{d}", .{code});
            },
            .indexed => |n| try w.print("{d};5;{d}", .{ base + 8, n }),
            .rgb => |c| try w.print("{d};2;{d};{d};{d}", .{ base + 8, c.r, c.g, c.b }),
        }
    }
};

/// The xterm palette and nearest-color searches used by downsampling.
pub const palette = struct {
    /// The 16 ANSI colors as xterm draws them by default; terminals differ, so downsampling
    /// is a best guess.
    pub const basic = [16]Color.Rgb{
        .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 205, .g = 0, .b = 0 },
        .{ .r = 0, .g = 205, .b = 0 },     .{ .r = 205, .g = 205, .b = 0 },
        .{ .r = 0, .g = 0, .b = 238 },     .{ .r = 205, .g = 0, .b = 205 },
        .{ .r = 0, .g = 205, .b = 205 },   .{ .r = 229, .g = 229, .b = 229 },
        .{ .r = 127, .g = 127, .b = 127 }, .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },     .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 92, .g = 92, .b = 255 },   .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 0, .g = 255, .b = 255 },   .{ .r = 255, .g = 255, .b = 255 },
    };

    const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

    /// The RGB value of a 256-palette entry.
    pub fn rgbOf(index: u8) Color.Rgb {
        if (index < 16) return basic[index];
        if (index >= 232) {
            const v: u8 = 8 + 10 * (index - 232);
            return .{ .r = v, .g = v, .b = v };
        }
        const i = index - 16;
        return .{ .r = cube_levels[i / 36], .g = cube_levels[i / 6 % 6], .b = cube_levels[i % 6] };
    }

    /// The 256-palette entry closest to `rgb`, from the color cube or the gray ramp.
    pub fn nearest256(rgb: Color.Rgb) u8 {
        const r = cubeIndex(rgb.r);
        const g = cubeIndex(rgb.g);
        const b = cubeIndex(rgb.b);
        const cube: u8 = 16 + 36 * r + 6 * g + b;
        const average: u16 = (@as(u16, rgb.r) + rgb.g + rgb.b) / 3;
        const gray: u8 = if (average < 8) 232 else if (average > 238) 255 else @intCast(
            232 + (average - 8) / 10,
        );
        return if (distance(rgb, rgbOf(gray)) < distance(rgb, rgbOf(cube))) gray else cube;
    }

    fn cubeIndex(v: u8) u8 {
        if (v < 48) return 0;
        if (v < 115) return 1;
        return (v - 35) / 40;
    }

    /// The ANSI color closest to `rgb`.
    pub fn nearest16(rgb: Color.Rgb) u4 {
        var best: u4 = 0;
        var best_distance: u32 = std.math.maxInt(u32);
        for (basic, 0..) |candidate, i| {
            const d = distance(rgb, candidate);
            if (d < best_distance) {
                best = @intCast(i);
                best_distance = d;
            }
        }
        return best;
    }

    /// Squared distance weighted for the eye's sensitivity (2, 4, 3 for red, green, blue).
    fn distance(a: Color.Rgb, b: Color.Rgb) u32 {
        const dr = @as(i32, a.r) - b.r;
        const dg = @as(i32, a.g) - b.g;
        const db = @as(i32, a.b) - b.b;
        return @intCast(2 * dr * dr + 4 * dg * dg + 3 * db * db);
    }
};

/// The length of the escape sequence at the start of `bytes`, or 0 when `bytes` does not
/// start with ESC. Recognizes CSI, OSC and the other string sequences (ended by BEL or ST),
/// SS2/SS3, and two-byte escapes. An unterminated sequence extends to the end of `bytes`.
pub fn sequenceLen(bytes: []const u8) usize {
    if (bytes.len == 0 or bytes[0] != 0x1b) return 0;
    if (bytes.len == 1) return 1;
    return switch (bytes[1]) {
        '[' => csiLen(bytes),
        ']', 'P', 'X', '^', '_' => stringLen(bytes),
        'N', 'O' => @min(bytes.len, 3),
        else => 2,
    };
}

fn csiLen(bytes: []const u8) usize {
    for (bytes[2..], 2..) |c, i| {
        if (c >= 0x40 and c <= 0x7e) return i + 1;
        if (c < 0x20 or c > 0x7e) return i; // malformed: stop before the stray byte
    }
    return bytes.len;
}

fn stringLen(bytes: []const u8) usize {
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 0x07) return i + 1;
        if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') return i + 2;
    }
    return bytes.len;
}

/// Writes `text` without its escape sequences.
pub fn strip(w: *Writer, text: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const next = std.mem.indexOfScalarPos(u8, text, i, 0x1b) orelse text.len;
        try w.writeAll(text[i..next]);
        if (next == text.len) break;
        i = next + sequenceLen(text[next..]);
    }
}

/// Writes `text` with its SGR colors lowered to what `level` can show: RGB to the nearest
/// palette entry, palette entries to the nearest ANSI color, and, at `.none`, colors
/// dropped while bold, underline, and the other attributes stay. Other escapes pass through.
pub fn downsample(w: *Writer, text: []const u8, level: capability.Color) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const next = std.mem.indexOfScalarPos(u8, text, i, 0x1b) orelse text.len;
        try w.writeAll(text[i..next]);
        if (next == text.len) break;
        const len = sequenceLen(text[next..]);
        const sequence = text[next..][0..len];
        if (level == .truecolor or !isSgr(sequence)) {
            try w.writeAll(sequence);
        } else {
            try downsampleSgr(w, sequence[2 .. len - 1], level);
        }
        i = next + len;
    }
}

/// A writer that lowers the colors of everything written through it to what a stream can
/// show, as colorprofile's `Writer` does: write truecolor freely, and a 256-color
/// terminal gets the nearest palette entries, a pipe under `NO_COLOR` plain attributes,
/// and with `.plain` (no escapes allowed) the text alone. An escape sequence split across
/// writes is held until it is complete; `flush` writes out what is held.
///
/// ```zig
/// var lowering: term.ansi.Downsampler = .init(out, cap, &buffer);
/// const w = &lowering.interface;
/// try w.writeAll("\x1b[38;2;255;135;0mhi\x1b[0m");
/// try w.flush();
/// ```
pub const Downsampler = struct {
    out: *Writer,
    capability: capability.Capability,
    interface: Writer,
    /// The start of an escape sequence not yet complete.
    held: [max_held]u8 = undefined,
    held_len: usize = 0,

    /// The longest sequence held for its end; a longer one is written as it is.
    pub const max_held = 512;

    /// Writes through to `out`, lowered to `cap`; `buffer` holds writes until they are
    /// processed.
    pub fn init(out: *Writer, cap: capability.Capability, buffer: []u8) Downsampler {
        return .{
            .out = out,
            .capability = cap,
            .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain, .flush = flush } },
        };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const d: *Downsampler = @alignCast(@fieldParentPtr("interface", w));
        try d.process(w.buffer[0..w.end]);
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            try d.process(chunk);
            written += chunk.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try d.process(last);
        return written + last.len * splat;
    }

    fn flush(w: *Writer) Writer.Error!void {
        const d: *Downsampler = @alignCast(@fieldParentPtr("interface", w));
        try d.process(w.buffer[0..w.end]);
        w.end = 0;
        if (d.held_len > 0) {
            try d.out.writeAll(d.held[0..d.held_len]);
            d.held_len = 0;
        }
        try d.out.flush();
    }

    fn process(d: *Downsampler, bytes: []const u8) Writer.Error!void {
        var rest = bytes;
        while (d.held_len > 0 and rest.len > 0) {
            // Complete the held sequence a byte at a time; it ends where it is complete.
            d.held[d.held_len] = rest[0];
            d.held_len += 1;
            rest = rest[1..];
            if (complete(d.held[0..d.held_len])) {
                try d.emit(d.held[0..d.held_len]);
                d.held_len = 0;
            } else if (d.held_len == max_held) {
                try d.out.writeAll(d.held[0..d.held_len]);
                d.held_len = 0;
            }
        }
        while (rest.len > 0) {
            const next = std.mem.indexOfScalar(u8, rest, 0x1b) orelse rest.len;
            try d.emit(rest[0..next]);
            rest = rest[next..];
            if (rest.len == 0) break;
            const len = sequenceLen(rest);
            if (len == rest.len and !complete(rest)) {
                if (rest.len > max_held) {
                    try d.out.writeAll(rest);
                } else {
                    @memcpy(d.held[0..rest.len], rest);
                    d.held_len = rest.len;
                }
                return;
            }
            try d.emit(rest[0..len]);
            rest = rest[len..];
        }
    }

    fn emit(d: *Downsampler, text: []const u8) Writer.Error!void {
        const cap = d.capability;
        if (!cap.escapes and cap.color == .none) return strip(d.out, text);
        try downsample(d.out, text, cap.color);
    }

    /// Whether `sequence` (starting with ESC) has its end.
    fn complete(sequence: []const u8) bool {
        if (sequence.len < 2) return false;
        return switch (sequence[1]) {
            '[' => sequence.len > 2 and sequence[sequence.len - 1] >= 0x40 and
                sequence[sequence.len - 1] <= 0x7e,
            ']', 'P', 'X', '^', '_' => sequence[sequence.len - 1] == 0x07 or
                std.mem.endsWith(u8, sequence, st),
            'N', 'O' => sequence.len >= 3,
            else => true,
        };
    }
};

fn isSgr(sequence: []const u8) bool {
    if (sequence.len < 3 or sequence[1] != '[' or sequence[sequence.len - 1] != 'm') return false;
    for (sequence[2 .. sequence.len - 1]) |c| {
        if (!std.ascii.isDigit(c) and c != ';' and c != ':') return false;
    }
    return true;
}

/// Rewrites one SGR parameter list. A sequence left with no parameters is dropped, unless it
/// had none to begin with (a reset).
fn downsampleSgr(w: *Writer, params: []const u8, level: capability.Color) Writer.Error!void {
    if (params.len == 0) return w.writeAll(csi ++ "m");
    var buffer: [128]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |param| {
        switch (classify(param, &it)) {
            .drop => {},
            .other => appendParam(&out, param),
            .color => |c| {
                // Terminals limited to 16 colors or fewer rarely know underline colors.
                if (c.layer == .underline and (level == .none or level == .basic)) continue;
                const lowered = c.color.downsample(level);
                if (lowered == .default and c.color != .default) continue;
                if (out.end > 0) out.writeByte(';') catch {};
                lowered.writeParams(&out, c.layer) catch {};
            },
        }
    }
    if (out.end == 0) return;
    try w.print(csi ++ "{s}m", .{out.buffered()});
}

fn appendParam(out: *Writer, param: []const u8) void {
    // The buffer holds any realistic parameter list; a longer one loses its tail, which at
    // worst leaves an attribute unset.
    if (out.end > 0) out.writeByte(';') catch return;
    out.writeAll(param) catch {};
}

const Param = union(enum) {
    other,
    /// A color this level cannot show and that cannot be rewritten, or a malformed one.
    drop,
    color: struct { color: Color, layer: Color.Layer },
};

/// Classifies one SGR parameter, consuming the extra `5;n` or `2;r;g;b` parameters of an
/// extended color from `it`. Colon forms (`38:2::r:g:b`) are dropped rather than parsed;
/// only truecolor output keeps them, and it never gets here.
fn classify(param: []const u8, it: *std.mem.SplitIterator(u8, .scalar)) Param {
    if (std.mem.indexOfScalar(u8, param, ':') != null) {
        const extended = std.mem.startsWith(u8, param, "38:") or
            std.mem.startsWith(u8, param, "48:") or std.mem.startsWith(u8, param, "58:");
        return if (extended) .drop else .other;
    }
    const code = std.fmt.parseInt(u16, param, 10) catch return .other;
    const fg: Color.Layer = .fg;
    const bg: Color.Layer = .bg;
    return switch (code) {
        30...37 => .{ .color = .{ .color = .{ .basic = @intCast(code - 30) }, .layer = fg } },
        90...97 => .{ .color = .{ .color = .{ .basic = @intCast(code - 90 + 8) }, .layer = fg } },
        40...47 => .{ .color = .{ .color = .{ .basic = @intCast(code - 40) }, .layer = bg } },
        100...107 => .{ .color = .{
            .color = .{ .basic = @intCast(code - 100 + 8) },
            .layer = bg,
        } },
        39 => .{ .color = .{ .color = .default, .layer = fg } },
        49 => .{ .color = .{ .color = .default, .layer = bg } },
        59 => .{ .color = .{ .color = .default, .layer = .underline } },
        38, 48, 58 => .{ .color = .{
            .color = extendedColor(it) orelse return .drop,
            .layer = switch (code) {
                38 => fg,
                48 => bg,
                else => .underline,
            },
        } },
        else => .other,
    };
}

fn extendedColor(it: *std.mem.SplitIterator(u8, .scalar)) ?Color {
    const kind = it.next() orelse return null;
    if (std.mem.eql(u8, kind, "5")) {
        const index = std.fmt.parseInt(u8, it.next() orelse "", 10) catch return null;
        return .{ .indexed = index };
    }
    if (std.mem.eql(u8, kind, "2")) {
        var channels: [3]u8 = undefined;
        for (&channels) |*c| c.* = std.fmt.parseInt(u8, it.next() orelse "", 10) catch return null;
        return .{ .rgb = .{ .r = channels[0], .g = channels[1], .b = channels[2] } };
    }
    return null;
}

const testing = std.testing;

fn expectWritten(expected: []const u8, comptime f: anytype, args: anytype) !void {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try @call(.auto, f, .{&w} ++ args);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "cursor movement" {
    try expectWritten("\x1b[3A", cursorUp, .{3});
    try expectWritten("", cursorUp, .{0});
    try expectWritten("\x1b[1B", cursorDown, .{1});
    try expectWritten("", cursorDown, .{0});
    try expectWritten("\x1b[2C", cursorForward, .{2});
    try expectWritten("", cursorForward, .{0});
    try expectWritten("\x1b[4D", cursorBack, .{4});
    try expectWritten("", cursorBack, .{0});
    try expectWritten("\x1b[1G", cursorColumn, .{0});
    try expectWritten("\x1b[H", cursorTo, .{ 0, 0 });
    try expectWritten("\x1b[3;5H", cursorTo, .{ 2, 4 });
    try expectWritten("\x1b7", saveCursor, .{});
    try expectWritten("\x1b8", restoreCursor, .{});
}

test "erasing and scrolling" {
    try expectWritten("\x1b[K", eraseLine, .{.to_end});
    try expectWritten("\x1b[1K", eraseLine, .{.to_start});
    try expectWritten("\x1b[2K", eraseLine, .{.all});
    try expectWritten("\x1b[J", eraseScreen, .{.to_end});
    try expectWritten("\x1b[2J", eraseScreen, .{.all});
    try expectWritten("\x1b[2;10r", setScrollRegion, .{ 1, 9 });
    try expectWritten("\x1b[r", resetScrollRegion, .{});
    try expectWritten("\x1b[2S", scrollUp, .{2});
    try expectWritten("\x1b[1T", scrollDown, .{1});
    try expectWritten("", scrollUp, .{0});
}

test "modes" {
    try expectWritten("\x1b[?25l", setMode, .{ Mode.cursor_visible, false });
    try expectWritten("\x1b[?1049h", setMode, .{ Mode.alt_screen, true });
    try expectWritten("\x1b[?2004h", setMode, .{ Mode.bracketed_paste, true });
    try expectWritten("\x1b[?2026l", setMode, .{ Mode.synchronized_output, false });
    try expectWritten("\x1b[?1004h", setMode, .{ Mode.focus_events, true });
    try expectWritten("\x1b[?1000h\x1b[?1002h\x1b[?1006h", setMouse, .{true});
    try expectWritten("\x1b[?1006l\x1b[?1002l\x1b[?1000l", setMouse, .{false});
}

test "OSC sequences" {
    try expectWritten("\x1b]2;hi\x1b\\", setTitle, .{"hi"});
    try expectWritten(
        "\x1b]8;;https://x.y\x1b\\link\x1b]8;;\x1b\\",
        hyperlink,
        .{ "https://x.y", "link" },
    );
    try expectWritten("\x1b]52;c;aGVsbG8=\x1b\\", copyToClipboard, .{"hello"});
    try expectWritten("\x1b]52;c;\x1b\\", copyToClipboard, .{""});
}

test "copyToClipboard: long text is encoded in whole chunks" {
    const text: [400]u8 = @splat('a');
    var expected: [600]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&expected, &text);
    var buffer: [700]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try copyToClipboard(&w, &text);
    try testing.expectEqualStrings(encoded, w.buffered()[7 .. w.end - 2]);
}

fn writeColor(w: *Writer, color: Color, layer: Color.Layer) Writer.Error!void {
    try color.writeParams(w, layer);
}

test "Color.writeParams" {
    try expectWritten("31", writeColor, .{ Color.red, .fg });
    try expectWritten("41", writeColor, .{ Color.red, .bg });
    try expectWritten("91", writeColor, .{ Color.bright_red, .fg });
    try expectWritten("107", writeColor, .{ Color.bright_white, .bg });
    try expectWritten("39", writeColor, .{ Color.default, .fg });
    try expectWritten("49", writeColor, .{ Color.default, .bg });
    try expectWritten("38;5;208", writeColor, .{ Color{ .indexed = 208 }, .fg });
    try expectWritten("48;2;1;2;3", writeColor, .{ Color.hex(0x010203), .bg });
    try expectWritten("58;5;1", writeColor, .{ Color.red, .underline });
    try expectWritten("58;2;1;2;3", writeColor, .{ Color.hex(0x010203), .underline });
    try expectWritten("59", writeColor, .{ Color.default, .underline });
}

test "downsample: underline colors and styles" {
    const text = "\x1b[4:3;58;2;255;135;0mhi\x1b[59m";
    try expectWritten(text, downsample, .{ text, capability.Color.truecolor });
    try expectWritten("\x1b[4:3;58;5;208mhi\x1b[59m", downsample, .{
        text,
        capability.Color.ansi256,
    });
    // Below 256 colors the underline color goes, and the curly underline stays.
    try expectWritten("\x1b[4:3mhi", downsample, .{ text, capability.Color.basic });
    try expectWritten("\x1b[4:3mhi", downsample, .{ text, capability.Color.none });
}

test "notifications and progress" {
    try expectWritten(
        "\x1b]9;done\x1b\\\x1b]777;notify;Build;done\x1b\\",
        notify,
        .{ "Build", "done" },
    );
    try expectWritten("\x1b]9;Hi\x1b\\\x1b]777;notify;Hi;\x1b\\", notify, .{ "H\x1bi", "" });
    try expectWritten("\x1b]9;4;1;42\x1b\\", setProgress, .{Progress{ .normal = 42 }});
    try expectWritten("\x1b]9;4;3;0\x1b\\", setProgress, .{Progress.indeterminate});
    try expectWritten("\x1b]9;4;0;0\x1b\\", setProgress, .{Progress.none});
}

test "queries" {
    try expectWritten("\x1b[?2026$p", queryMode, .{Mode.synchronized_output});
    try expectWritten("\x1b]11;?\x1b\\", queryBackground, .{});
    try expectWritten("\x1b]10;?\x1b\\", queryForeground, .{});
    try expectWritten("\x1b[?u", queryKittyKeyboard, .{});
    try expectWritten("\x1b[c", queryDeviceAttributes, .{});
}

test "color math: blends, lightness, contrast, gradients" {
    const black: Color.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Color.Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const red: Color.Rgb = .{ .r = 255, .g = 0, .b = 0 };
    // Oklab round trips.
    for ([_]Color.Rgb{ black, white, red, .{ .r = 18, .g = 52, .b = 86 } }) |rgb| {
        try testing.expectEqual(rgb, Color.Rgb.fromOklab(rgb.oklab()));
    }
    try testing.expectEqual(black, black.blend(white, 0));
    try testing.expectEqual(white, black.blend(white, 1));
    // The middle of black and white is a gray at Oklab's middle lightness.
    const middle = black.blend(white, 0.5);
    try testing.expect(middle.r == middle.g and middle.g == middle.b);
    try testing.expectApproxEqAbs(0.5, middle.oklab().l, 0.01);
    try testing.expectApproxEqAbs(21, black.contrast(white), 0.01);
    try testing.expectApproxEqAbs(1, red.contrast(red), 0.001);
    try testing.expect(red.lighten(0.2).luminance() > red.luminance());
    try testing.expect(red.darken(0.2).luminance() < red.luminance());
    const opposite = red.complementary();
    try testing.expect(opposite.g > opposite.r and opposite.b > opposite.r);
    try testing.expectEqual(Color.Rgb{ .r = 188, .g = 188, .b = 188 }, white.over(black, 0.5));

    var row: [5]Color = undefined;
    Color.gradient(&row, &.{ .hex(0x000000), .hex(0xffffff) });
    try testing.expectEqual(Color.hex(0x000000), row[0]);
    try testing.expectEqual(Color.hex(0xffffff), row[4]);
    for (row[1..], row[0..4]) |next, prev| try testing.expect(next.rgb.r > prev.rgb.r);
    var one: [1]Color = undefined;
    Color.gradient(&one, &.{ .red, .blue });
    try testing.expectEqual(Color{ .rgb = palette.rgbOf(1) }, one[0]);

    var grid: [6]Color = undefined;
    Color.gradient2d(&grid, 3, 2, 90, &.{ .hex(0x000000), .hex(0xffffff) });
    // Top to bottom: each row is one color.
    try testing.expectEqual(grid[0], grid[2]);
    try testing.expectEqual(Color.hex(0xffffff), grid[5]);
    try testing.expectEqual(Color.lightDark(true, .black, .white), Color.white);
}

test "Color.Rgb.isDark" {
    try testing.expect((Color.Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }).isDark());
    try testing.expect(!(Color.Rgb{ .r = 0xfa, .g = 0xfa, .b = 0xfa }).isDark());
    try testing.expect((Color.Rgb{ .r = 0, .g = 0, .b = 0xff }).isDark());
    try testing.expect(!(Color.Rgb{ .r = 0xff, .g = 0xff, .b = 0 }).isDark());
}

test "Color.parse" {
    try testing.expectEqual(Color.hex(0xff8000), try Color.parse("#ff8000"));
    try testing.expectEqual(Color.hex(0xffaa00), try Color.parse("#fa0"));
    try testing.expectEqual(Color.red, try Color.parse("red"));
    try testing.expectEqual(Color.bright_blue, try Color.parse("bright_blue"));
    try testing.expectEqual(Color.bright_blue, try Color.parse("Bright-Blue"));
    try testing.expectEqual(Color.yellow, try Color.parse("3"));
    try testing.expectEqual(Color{ .indexed = 200 }, try Color.parse("200"));
    try testing.expectEqual(Color.default, try Color.parse("default"));
    try testing.expectError(error.InvalidColor, Color.parse("#12"));
    try testing.expectError(error.InvalidColor, Color.parse("#gggggg"));
    try testing.expectError(error.InvalidColor, Color.parse("purple"));
    try testing.expectError(error.InvalidColor, Color.parse("256"));
    try testing.expectError(error.InvalidColor, Color.parse(""));
}

test "Color.downsample" {
    const orange = Color.hex(0xff8700);
    try testing.expectEqual(orange, orange.downsample(.truecolor));
    try testing.expectEqual(Color{ .indexed = 208 }, orange.downsample(.ansi256));
    try testing.expectEqual(Color.yellow, orange.downsample(.basic));
    try testing.expectEqual(Color.default, orange.downsample(.none));
    try testing.expectEqual(Color{ .indexed = 232 }, Color.hex(0x080808).downsample(.ansi256));
    try testing.expectEqual(Color{ .indexed = 16 }, Color.hex(0x000000).downsample(.ansi256));
    try testing.expectEqual(Color{ .indexed = 231 }, Color.hex(0xffffff).downsample(.ansi256));
    try testing.expectEqual(Color{ .indexed = 244 }, Color.hex(0x808080).downsample(.ansi256));
    try testing.expectEqual(Color.red, (Color{ .indexed = 160 }).downsample(.basic));
    try testing.expectEqual(Color.blue, (Color{ .indexed = 4 }).downsample(.basic));
    try testing.expectEqual(Color.green, Color.green.downsample(.ansi256));
    try testing.expectEqual(Color.default, Color.green.downsample(.none));
}

test "palette.rgbOf covers the cube and the gray ramp" {
    try testing.expectEqual(Color.Rgb{ .r = 255, .g = 135, .b = 0 }, palette.rgbOf(208));
    try testing.expectEqual(Color.Rgb{ .r = 8, .g = 8, .b = 8 }, palette.rgbOf(232));
    try testing.expectEqual(Color.Rgb{ .r = 238, .g = 238, .b = 238 }, palette.rgbOf(255));
    for (16..256) |i| {
        const index: u8 = @intCast(i);
        try testing.expectEqual(index, palette.nearest256(palette.rgbOf(index)));
    }
}

test sequenceLen {
    try testing.expectEqual(0, sequenceLen("abc"));
    try testing.expectEqual(0, sequenceLen(""));
    try testing.expectEqual(1, sequenceLen("\x1b"));
    try testing.expectEqual(4, sequenceLen("\x1b[1mX"));
    try testing.expectEqual(3, sequenceLen("\x1b[Hx"));
    try testing.expectEqual(8, sequenceLen("\x1b[?1049hx"));
    try testing.expectEqual(6, sequenceLen("\x1b]2;t\x07x"));
    try testing.expectEqual(7, sequenceLen("\x1b]2;t\x1b\\x"));
    try testing.expectEqual(3, sequenceLen("\x1bOAx"));
    try testing.expectEqual(2, sequenceLen("\x1b7x"));
    try testing.expectEqual(4, sequenceLen("\x1b[12"));
    try testing.expectEqual(3, sequenceLen("\x1b[1\nx"));
    try testing.expectEqual(5, sequenceLen("\x1bPab\x07"));
}

test strip {
    try expectWritten(
        "hello world",
        strip,
        .{"\x1b[1mhello\x1b[0m \x1b]8;;u\x1b\\world\x1b]8;;\x1b\\"},
    );
    try expectWritten("plain", strip, .{"plain"});
    try expectWritten("a", strip, .{"a\x1b[3"});
}

test Downsampler {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buffer: [8]u8 = undefined;
    var d: Downsampler = .init(&out.writer, .{ .color = .ansi256, .escapes = true }, &buffer);
    // Split across writes, and longer than the buffer.
    for ([_][]const u8{ "a\x1b[38;2;", "255;135;0", "mhi\x1b", "[0m done" }) |part| {
        try d.interface.writeAll(part);
    }
    try d.interface.flush();
    try testing.expectEqualStrings("a\x1b[38;5;208mhi\x1b[0m done", out.written());

    out.clearRetainingCapacity();
    var plain: Downsampler = .init(&out.writer, .plain, &buffer);
    try plain.interface.writeAll("\x1b[1mbold\x1b[0m \x1b]8;;u\x07link\x1b]8;;\x07");
    try plain.interface.flush();
    try testing.expectEqualStrings("bold link", out.written());
}

test downsample {
    const text = "\x1b[1;38;2;255;135;0mhi\x1b[0m";
    try expectWritten(text, downsample, .{ text, capability.Color.truecolor });
    try expectWritten("\x1b[1;38;5;208mhi\x1b[0m", downsample, .{ text, capability.Color.ansi256 });
    try expectWritten("\x1b[1;33mhi\x1b[0m", downsample, .{ text, capability.Color.basic });
    try expectWritten("\x1b[1mhi\x1b[0m", downsample, .{ text, capability.Color.none });
    // A sequence of colors only disappears at `.none`; resets and other escapes stay.
    try expectWritten("xy\x1b[m\x1b[2K", downsample, .{
        "x\x1b[31;42my\x1b[m\x1b[2K",
        capability.Color.none,
    });
    try expectWritten("\x1b[91;44m", downsample, .{
        "\x1b[38;5;196;48;5;4m",
        capability.Color.basic,
    });
    try expectWritten("\x1b[39;49m", downsample, .{ "\x1b[39;49m", capability.Color.basic });
    try expectWritten("\x1b[1m", downsample, .{ "\x1b[1;38:2::1:2:3m", capability.Color.ansi256 });
    try expectWritten("\x1b[4m", downsample, .{ "\x1b[4;38;5m", capability.Color.none });
}
