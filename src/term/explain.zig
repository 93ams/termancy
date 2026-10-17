//! Terminal output in words, as sequin shows it: what each escape sequence and control
//! does (`ESC[1;31m` is "SGR: bold, red text"), for debugging what a program writes and
//! for test failures a person can read.
//!
//! ```zig
//! var it: term.explain.Iterator = .init(output);
//! while (it.next()) |item| switch (item) {
//!     .text => |text| ...,
//!     .control, .sequence => |raw| try term.explain.describe(w, raw),
//! };
//! ```

const std = @import("std");
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");
const Parser = @import("Parser.zig");
const Pen = @import("Pen.zig");

/// A piece of terminal output.
pub const Item = union(enum) {
    /// Printable text, up to the next control or escape.
    text: []const u8,
    /// One C0 control byte (`\n`, `\r`, BEL, ...), or CR LF together.
    control: []const u8,
    /// One escape sequence, ESC included.
    sequence: []const u8,
};

/// Splits output into text, controls, and escape sequences.
pub const Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    /// An iterator over `bytes`.
    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    /// The next item; null at the end.
    pub fn next(it: *Iterator) ?Item {
        const rest = it.bytes[it.index..];
        if (rest.len == 0) return null;
        if (rest[0] == 0x1b) {
            const len = ansi.sequenceLen(rest);
            it.index += len;
            return .{ .sequence = rest[0..len] };
        }
        if (isControl(rest[0])) {
            const len: usize = if (rest[0] == '\r' and rest.len > 1 and rest[1] == '\n') 2 else 1;
            it.index += len;
            return .{ .control = rest[0..len] };
        }
        var end: usize = 0;
        while (end < rest.len and rest[end] != 0x1b and !isControl(rest[end])) end += 1;
        it.index += end;
        return .{ .text = rest[0..end] };
    }

    fn isControl(byte: u8) bool {
        return byte < 0x20 or byte == 0x7f;
    }
};

/// Writes `raw` (a sequence or control) the way it is usually written down: `ESC[1;31m`,
/// `CR LF`, with other unprintable bytes as `\xNN`.
pub fn writeRaw(w: *Writer, raw: []const u8) Writer.Error!void {
    for (raw, 0..) |byte, i| {
        if (byte == 0x1b) {
            try w.writeAll("ESC");
        } else if (byte < 0x20 or byte == 0x7f) {
            if (raw.len > 1 and raw[0] != 0x1b) {
                if (i > 0) try w.writeByte(' ');
                try w.writeAll(controlName(byte));
            } else {
                try w.writeAll(controlName(byte));
            }
        } else if (byte >= 0x80) {
            try w.print("\\x{x:0>2}", .{byte});
        } else {
            try w.writeByte(byte);
        }
    }
}

fn controlName(byte: u8) []const u8 {
    const names = [_][]const u8{
        "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS",  "HT",  "LF",
        "VT",  "FF",  "CR",  "SO",  "SI",  "DLE", "DC1", "DC2", "DC3", "DC4", "NAK",
        "SYN", "ETB", "CAN", "EM",  "SUB", "ESC", "FS",  "GS",  "RS",  "US",
    };
    return if (byte < 0x20) names[byte] else "DEL";
}

/// Writes what the control or escape sequence `raw` does, in a few words.
pub fn describe(w: *Writer, raw: []const u8) Writer.Error!void {
    if (raw.len == 0) return;
    if (raw[0] != 0x1b) return describeControls(w, raw);
    if (raw.len == 1) return w.writeAll("escape (alone)");
    var describer: Describer = .{ .w = w };
    var parser: Parser = .{};
    parser.feed(raw, &describer);
    // A string sequence without its terminator never completes; describe what it opened.
    if (!describer.wrote) {
        switch (raw[1]) {
            ']' => try w.writeAll("OSC, unterminated"),
            'P' => try w.writeAll("DCS, unterminated"),
            '_' => try w.writeAll("APC, unterminated"),
            '[' => try w.writeAll("CSI, unterminated or malformed"),
            else => try w.writeAll("unknown escape"),
        }
    }
    if (describer.failed) return error.WriteFailed;
}

fn describeControls(w: *Writer, raw: []const u8) Writer.Error!void {
    for (raw, 0..) |byte, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(switch (byte) {
            0x07 => "bell",
            0x08 => "backspace",
            0x09 => "tab",
            0x0a => "line feed",
            0x0b => "vertical tab",
            0x0c => "form feed",
            0x0d => "carriage return",
            0x0e => "shift out: use the G1 character set",
            0x0f => "shift in: use the G0 character set",
            0x00 => "null",
            0x7f => "delete",
            else => "control character",
        });
    }
}

const Describer = struct {
    w: *Writer,
    wrote: bool = false,
    failed: bool = false,

    fn put(d: *Describer, comptime fmt: []const u8, args: anytype) void {
        d.wrote = true;
        d.w.print(fmt, args) catch {
            d.failed = true;
        };
    }

    pub fn execute(d: *Describer, byte: u8) void {
        d.put("{s} inside a sequence", .{controlName(byte)});
    }

    pub fn esc(d: *Describer, seq: Parser.Esc) void {
        if (seq.intermediates.len == 1) {
            const slot = seq.intermediates[0];
            if (slot == '(' or slot == ')' or slot == '*' or slot == '+') {
                const g = switch (slot) {
                    '(' => "G0",
                    ')' => "G1",
                    '*' => "G2",
                    else => "G3",
                };
                const set = switch (seq.final) {
                    '0' => "DEC line drawing",
                    'B' => "ASCII",
                    'A' => "British",
                    else => "another",
                };
                return d.put("character set {s}: {s}", .{ g, set });
            }
            if (slot == '#' and seq.final == '8') {
                return d.put("screen alignment test (DECALN)", .{});
            }
        }
        const text: []const u8 = switch (seq.final) {
            '7' => "save cursor (DECSC)",
            '8' => "restore cursor (DECRC)",
            'D' => "index: down a line, scrolling at the bottom (IND)",
            'E' => "next line (NEL)",
            'M' => "reverse index: up a line, scrolling at the top (RI)",
            'H' => "set a tab stop (HTS)",
            'c' => "full reset (RIS)",
            '=' => "application keypad (DECKPAM)",
            '>' => "normal keypad (DECKPNM)",
            '\\' => "string terminator (ST)",
            'N' => "single shift G2 (SS2)",
            'O' => "single shift G3 (SS3)",
            else => "unknown escape",
        };
        d.put("{s}", .{text});
    }

    pub fn csi(d: *Describer, seq: Parser.Csi) void {
        const n = seq.param(0, 1);
        if (seq.private == '?') return d.privateCsi(seq);
        if (seq.private == '>') return d.greaterCsi(seq);
        if (seq.private == '<' and seq.final == 'u') {
            return d.put("kitty keyboard: pop {d} flag set(s)", .{n});
        }
        if (seq.private == '=' and seq.final == 'u') {
            return d.put("kitty keyboard: set flags {d}", .{seq.param(0, 0)});
        }
        if (seq.private == '<' and (seq.final == 'M' or seq.final == 'm')) {
            return d.put("mouse report (SGR): button {d} at column {d}, row {d}, {s}", .{
                seq.param(0, 0),
                seq.param(1, 0),
                seq.param(2, 0),
                if (seq.final == 'M') "press" else "release",
            });
        }
        if (seq.intermediates.len > 0) return d.intermediateCsi(seq);
        switch (seq.final) {
            '@' => d.put("insert {d} blank character(s) (ICH)", .{n}),
            'A' => d.put("cursor up {d} (CUU)", .{n}),
            'B' => d.put("cursor down {d} (CUD)", .{n}),
            'C' => d.put("cursor forward {d} (CUF)", .{n}),
            'D' => d.put("cursor back {d} (CUB)", .{n}),
            'E' => d.put("cursor down {d}, to the first column (CNL)", .{n}),
            'F' => d.put("cursor up {d}, to the first column (CPL)", .{n}),
            'G', '`' => d.put("cursor to column {d} (CHA)", .{n}),
            'H', 'f' => d.put("cursor to row {d}, column {d} (CUP)", .{ n, seq.param(1, 1) }),
            'I' => d.put("forward {d} tab stop(s) (CHT)", .{n}),
            'J' => d.put("erase {s} of the screen (ED)", .{erasePart(seq.param(0, 0), true)}),
            'K' => d.put("erase {s} of the line (EL)", .{erasePart(seq.param(0, 0), false)}),
            'L' => d.put("insert {d} line(s) (IL)", .{n}),
            'M' => d.put("delete {d} line(s) (DL)", .{n}),
            'P' => d.put("delete {d} character(s) (DCH)", .{n}),
            'S' => d.put("scroll up {d} line(s) (SU)", .{n}),
            'T' => d.put("scroll down {d} line(s) (SD)", .{n}),
            'X' => d.put("erase {d} character(s) (ECH)", .{n}),
            'Z' => d.put("back {d} tab stop(s) (CBT)", .{n}),
            'a' => d.put("cursor forward {d} (HPR)", .{n}),
            'b' => d.put("repeat the last character {d} time(s) (REP)", .{n}),
            'c' => d.put("request device attributes (DA1)", .{}),
            'd' => d.put("cursor to row {d} (VPA)", .{n}),
            'e' => d.put("cursor down {d} (VPR)", .{n}),
            'g' => d.put("clear {s} (TBC)", .{
                if (seq.param(0, 0) == 3) "every tab stop" else "the tab stop here",
            }),
            'h', 'l' => d.modes(seq, false),
            'm' => d.sgr(seq.params),
            'n' => switch (seq.param(0, 0)) {
                5 => d.put("request status (DSR)", .{}),
                6 => d.put("request the cursor position (DSR CPR)", .{}),
                else => d.put("device status report {d}", .{seq.param(0, 0)}),
            },
            'R' => d.put("cursor position report: row {d}, column {d}", .{ n, seq.param(1, 1) }),
            'r' => if (seq.count() < 2)
                d.put("scroll region: the whole screen (DECSTBM)", .{})
            else
                d.put("scroll region: rows {d} to {d} (DECSTBM)", .{ n, seq.param(1, 0) }),
            's' => d.put("save cursor (SCOSC)", .{}),
            'u' => d.put("restore cursor (SCORC)", .{}),
            't' => d.put("window operation {d} (XTWINOPS)", .{seq.param(0, 0)}),
            '~' => d.put("key: {s}", .{tildeKey(seq.param(0, 0))}),
            else => d.put("unknown control sequence (final {c})", .{seq.final}),
        }
    }

    fn intermediateCsi(d: *Describer, seq: Parser.Csi) void {
        if (seq.is(0, " ", 'q')) {
            const shape = seq.param(0, 0);
            const name = switch (shape) {
                0, 1, 2 => "block",
                3, 4 => "underline",
                else => "bar",
            };
            const blink = if (shape == 0 or shape % 2 == 1) "blinking" else "steady";
            return d.put("cursor shape: {s} {s} (DECSCUSR)", .{ blink, name });
        }
        if (seq.is(0, "!", 'p')) return d.put("soft reset (DECSTR)", .{});
        if (seq.is(0, "$", 'p')) return d.put("request ANSI mode {d} (DECRQM)", .{seq.param(0, 0)});
        if (seq.is('?', "$", 'y') or seq.is(0, "$", 'y')) {
            return d.put("mode {d} report: {s}", .{ seq.param(0, 0), modeState(seq.param(1, 0)) });
        }
        d.put("unknown control sequence", .{});
    }

    fn greaterCsi(d: *Describer, seq: Parser.Csi) void {
        switch (seq.final) {
            'c' => d.put("request secondary device attributes (DA2)", .{}),
            'u' => d.put("kitty keyboard: push flags {d}", .{seq.param(0, 0)}),
            'q' => d.put("request the terminal's name and version (XTVERSION)", .{}),
            'm' => d.put("set key modifier options (XTMODKEYS)", .{}),
            else => d.put("unknown control sequence", .{}),
        }
    }

    fn privateCsi(d: *Describer, seq: Parser.Csi) void {
        switch (seq.final) {
            'h', 'l' => d.modes(seq, true),
            'u' => d.put("kitty keyboard: query flags", .{}),
            'c' => d.put("device attributes report", .{}),
            'p' => if (seq.is('?', "$", 'p'))
                d.put("request mode {d}, {s} (DECRQM)", .{
                    seq.param(0, 0),
                    privateModeName(seq.param(0, 0)),
                })
            else
                d.put("unknown control sequence", .{}),
            'y' => d.put("mode {d} report: {s}", .{ seq.param(0, 0), modeState(seq.param(1, 0)) }),
            'J' => d.put("selectively erase {s} of the screen", .{
                erasePart(seq.param(0, 0), true),
            }),
            'K' => d.put("selectively erase {s} of the line", .{erasePart(seq.param(0, 0), false)}),
            else => d.put("unknown private control sequence", .{}),
        }
    }

    fn modes(d: *Describer, seq: Parser.Csi, private: bool) void {
        const on = seq.final == 'h';
        d.put("{s}", .{if (on) "set: " else "reset: "});
        for (seq.params, 0..) |param, i| {
            const mode = param.value orelse 0;
            if (i > 0) d.put(", ", .{});
            if (private) {
                d.put("{s}", .{privateModeName(mode)});
            } else {
                d.put("{s}", .{switch (mode) {
                    4 => "insert mode (IRM)",
                    20 => "newline mode (LNM)",
                    else => "unknown mode",
                }});
            }
        }
    }

    fn sgr(d: *Describer, params: []const Parser.Param) void {
        d.put("SGR: ", .{});
        if (params.len == 0) return d.put("reset", .{});
        var i: usize = 0;
        var first = true;
        while (i < params.len) {
            const param = params[i];
            var end = i + 1;
            while (end < params.len and params[end - 1].more) end += 1;
            const code = param.value orelse 0;
            if (!first) d.put(", ", .{});
            first = false;
            switch (code) {
                38, 48, 58 => {
                    // Let `Pen` read the color, whichever form it takes.
                    var pen: Pen = .{};
                    var count: usize = end - i;
                    if (!param.more) count = @min(params.len - i, colorLength(params[i..]));
                    pen.apply(params[i..][0..count]);
                    const color = switch (code) {
                        38 => pen.fg,
                        48 => pen.bg,
                        else => pen.underline_color,
                    };
                    const layer = switch (code) {
                        38 => "text",
                        48 => "background",
                        else => "underline",
                    };
                    d.colorName(color, layer);
                    i += count;
                    continue;
                },
                else => d.put("{s}", .{sgrName(code, param, params[i + 1 .. end])}),
            }
            if (code >= 30 and code <= 37) d.put(" text", .{});
            if (code >= 90 and code <= 97) d.put(" text", .{});
            if (code >= 40 and code <= 47) d.put(" background", .{});
            if (code >= 100 and code <= 107) d.put(" background", .{});
            i = end;
        }
    }

    fn colorLength(params: []const Parser.Param) usize {
        if (params.len < 2) return params.len;
        return switch (params[1].value orelse 0) {
            5 => 3,
            2 => 5,
            else => 1,
        };
    }

    fn colorName(d: *Describer, c: ansi.Color, layer: []const u8) void {
        switch (c) {
            .default => d.put("default {s} color", .{layer}),
            .basic => |n| d.put("{s} {s}", .{ basicName(n), layer }),
            .indexed => |n| d.put("palette color {d} {s}", .{ n, layer }),
            .rgb => |rgb| d.put("#{x:0>2}{x:0>2}{x:0>2} {s}", .{ rgb.r, rgb.g, rgb.b, layer }),
        }
    }

    pub fn osc(d: *Describer, data: []const u8) void {
        const semicolon = std.mem.indexOfScalar(u8, data, ';') orelse data.len;
        const command = std.fmt.parseInt(u16, data[0..semicolon], 10) catch {
            return d.put("OSC: unknown ({s})", .{data[0..@min(data.len, 20)]});
        };
        const rest = if (semicolon < data.len) data[semicolon + 1 ..] else "";
        switch (command) {
            0 => d.put("OSC: set the window and icon title to \"{s}\"", .{rest}),
            1 => d.put("OSC: set the icon title to \"{s}\"", .{rest}),
            2 => d.put("OSC: set the window title to \"{s}\"", .{rest}),
            4 => d.put("OSC: {s} palette colors", .{
                if (std.mem.endsWith(u8, rest, "?")) "query" else "set",
            }),
            7 => d.put("OSC: the current directory is {s}", .{rest}),
            8 => {
                const at = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                const url = if (at < rest.len) rest[at + 1 ..] else "";
                if (url.len == 0) {
                    d.put("OSC: end of hyperlink", .{});
                } else {
                    d.put("OSC: hyperlink to {s}", .{url});
                }
            },
            9 => if (std.mem.startsWith(u8, rest, "4;"))
                d.put("OSC: taskbar progress {s}", .{rest[2..]})
            else
                d.put("OSC: notification \"{s}\"", .{rest}),
            10, 11, 12 => {
                const which = switch (command) {
                    10 => "text",
                    11 => "background",
                    else => "cursor",
                };
                if (std.mem.eql(u8, rest, "?")) {
                    d.put("OSC: query the {s} color", .{which});
                } else {
                    d.put("OSC: the {s} color is {s}", .{ which, rest });
                }
            },
            52 => {
                const at = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                const payload = if (at < rest.len) rest[at + 1 ..] else "";
                if (std.mem.eql(u8, payload, "?")) {
                    d.put("OSC: query the clipboard", .{});
                } else {
                    const len = std.base64.standard.Decoder.calcSizeForSlice(payload) catch 0;
                    d.put("OSC: copy {d} byte(s) to the clipboard", .{len});
                }
            },
            104 => d.put("OSC: reset the palette", .{}),
            110, 111, 112 => d.put("OSC: reset the {s} color", .{switch (command) {
                110 => "text",
                111 => "background",
                else => "cursor",
            }}),
            133 => d.put("OSC: shell integration: {s}", .{switch (if (rest.len > 0)
                rest[0]
            else
                ' ') {
                'A' => "prompt starts",
                'B' => "command line starts",
                'C' => "command runs",
                'D' => "command finished",
                else => "mark",
            }}),
            633 => d.put("OSC: VS Code shell integration ({s})", .{rest[0..@min(rest.len, 1)]}),
            777 => d.put("OSC: notification ({s})", .{rest}),
            1337 => d.put("OSC: iTerm2 {s}", .{
                if (std.mem.startsWith(u8, rest, "File=")) "inline image" else "command",
            }),
            else => d.put("OSC {d}", .{command}),
        }
    }

    pub fn dcs(d: *Describer, seq: Parser.Dcs) void {
        if (std.mem.eql(u8, seq.intermediates, "$") and seq.final == 'q') {
            return d.put("DCS: request setting \"{s}\" (DECRQSS)", .{seq.data});
        }
        if (std.mem.eql(u8, seq.intermediates, "+") and seq.final == 'q') {
            d.put("DCS: request terminfo capabilities (XTGETTCAP):", .{});
            var names = std.mem.splitScalar(u8, seq.data, ';');
            while (names.next()) |hex_name| {
                var buffer: [64]u8 = undefined;
                const name = std.fmt.hexToBytes(&buffer, hex_name) catch hex_name;
                d.put(" {s}", .{name});
            }
            return;
        }
        if (seq.intermediates.len == 0 and seq.final == 'q') {
            return d.put("DCS: sixel image ({d} byte(s))", .{seq.data.len});
        }
        if (seq.final == 't' and std.mem.startsWith(u8, seq.data, "mux;")) {
            return d.put("DCS: passed through tmux", .{});
        }
        d.put("DCS {s}{c}", .{ seq.intermediates, seq.final });
    }

    pub fn apc(d: *Describer, data: []const u8) void {
        if (data.len > 0 and data[0] == 'G') {
            const end = std.mem.indexOfScalar(u8, data, ';') orelse data.len;
            return d.put("APC: kitty graphics ({s})", .{data[1..end]});
        }
        d.put("APC ({d} byte(s))", .{data.len});
    }
};

fn erasePart(part: u16, screen: bool) []const u8 {
    return switch (part) {
        0 => "from the cursor to the end",
        1 => "from the start to the cursor",
        2 => "all",
        3 => if (screen) "the scrollback" else "all",
        else => "an unknown part",
    };
}

fn modeState(state: u16) []const u8 {
    return switch (state) {
        0 => "not recognized",
        1 => "set",
        2 => "reset",
        3 => "permanently set",
        4 => "permanently reset",
        else => "unknown",
    };
}

fn privateModeName(mode: u16) []const u8 {
    return switch (mode) {
        1 => "application cursor keys (DECCKM)",
        3 => "132 columns (DECCOLM)",
        5 => "reverse video (DECSCNM)",
        6 => "origin mode (DECOM)",
        7 => "autowrap (DECAWM)",
        12 => "cursor blinking",
        25 => "cursor visible (DECTCEM)",
        47, 1047 => "alternate screen",
        1048 => "saved cursor",
        1049 => "alternate screen, cursor saved",
        1000 => "mouse presses",
        1002 => "mouse drags",
        1003 => "all mouse motion",
        1004 => "focus events",
        1005 => "UTF-8 mouse coordinates",
        1006 => "SGR mouse coordinates",
        1015 => "urxvt mouse coordinates",
        1016 => "SGR mouse pixel coordinates",
        2004 => "bracketed paste",
        2026 => "synchronized output",
        2027 => "grapheme clusters",
        9001 => "win32 input",
        else => "unknown private mode",
    };
}

fn basicName(n: u4) []const u8 {
    const names = [16][]const u8{
        "black",        "red",            "green",        "yellow",
        "blue",         "magenta",        "cyan",         "white",
        "bright black", "bright red",     "bright green", "bright yellow",
        "bright blue",  "bright magenta", "bright cyan",  "bright white",
    };
    return names[n];
}

fn sgrName(code: u16, param: Parser.Param, subs: []const Parser.Param) []const u8 {
    return switch (code) {
        0 => "reset",
        1 => "bold",
        2 => "faint",
        3 => "italic",
        4 => if (param.more and subs.len > 0) switch (subs[0].value orelse 1) {
            0 => "no underline",
            2 => "double underline",
            3 => "curly underline",
            4 => "dotted underline",
            5 => "dashed underline",
            else => "underline",
        } else "underline",
        5 => "slow blink",
        6 => "rapid blink",
        7 => "reverse video",
        8 => "invisible",
        9 => "strikethrough",
        21 => "double underline",
        22 => "normal intensity",
        23 => "not italic",
        24 => "no underline",
        25 => "no blink",
        27 => "no reverse video",
        28 => "visible",
        29 => "no strikethrough",
        30...37 => basicName(@intCast(code - 30)),
        39 => "default text color",
        40...47 => basicName(@intCast(code - 40)),
        49 => "default background color",
        53 => "overline",
        55 => "no overline",
        59 => "default underline color",
        90...97 => basicName(@intCast(code - 90 + 8)),
        100...107 => basicName(@intCast(code - 100 + 8)),
        else => "unknown attribute",
    };
}

fn tildeKey(code: u16) []const u8 {
    return switch (code) {
        1, 7 => "home",
        2 => "insert",
        3 => "delete",
        4, 8 => "end",
        5 => "page up",
        6 => "page down",
        11...15 => "F1-F5",
        17...21 => "F6-F10",
        23, 24 => "F11-F12",
        200 => "paste starts",
        201 => "paste ends",
        else => "unknown",
    };
}

const testing = std.testing;

fn expectDescription(expected: []const u8, raw: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try describe(&w, raw);
    try testing.expectEqualStrings(expected, w.buffered());
}

test describe {
    try expectDescription("SGR: bold, red text", "\x1b[1;31m");
    try expectDescription("SGR: reset", "\x1b[m");
    try expectDescription(
        "SGR: palette color 208 text, #0a0b0c background",
        "\x1b[38;5;208;48;2;10;11;12m",
    );
    try expectDescription("SGR: curly underline, red underline", "\x1b[4:3;58:5:1m");
    try expectDescription("cursor to row 3, column 7 (CUP)", "\x1b[3;7H");
    try expectDescription("erase all of the screen (ED)", "\x1b[2J");
    try expectDescription(
        "set: alternate screen, cursor saved, bracketed paste",
        "\x1b[?1049;2004h",
    );
    try expectDescription("cursor shape: steady bar (DECSCUSR)", "\x1b[6 q");
    try expectDescription("OSC: hyperlink to https://x", "\x1b]8;;https://x\x1b\\");
    try expectDescription("OSC: set the window title to \"hi\"", "\x1b]2;hi\x07");
    try expectDescription(
        "DCS: request terminfo capabilities (XTGETTCAP): TN",
        "\x1bP+q544e\x1b\\",
    );
    try expectDescription("character set G0: DEC line drawing", "\x1b(0");
    try expectDescription("carriage return, line feed", "\r\n");
    try expectDescription("kitty keyboard: push flags 1", "\x1b[>1u");
    try expectDescription("OSC, unterminated", "\x1b]0;never");
}

test Iterator {
    var it: Iterator = .init("hi\x1b[1mthere\r\n\x07");
    const expected = [_]Item{
        .{ .text = "hi" },
        .{ .sequence = "\x1b[1m" },
        .{ .text = "there" },
        .{ .control = "\r\n" },
        .{ .control = "\x07" },
    };
    for (expected) |e| {
        const got = it.next().?;
        try testing.expectEqual(std.meta.activeTag(e), std.meta.activeTag(got));
        switch (e) {
            inline else => |bytes, tag| {
                try testing.expectEqualStrings(bytes, @field(got, @tagName(tag)));
            },
        }
    }
    try testing.expectEqual(null, it.next());
}

test writeRaw {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeRaw(&w, "\x1b[1m");
    try w.writeByte('|');
    try writeRaw(&w, "\r\n");
    try testing.expectEqualStrings("ESC[1m|CR LF", w.buffered());
}
