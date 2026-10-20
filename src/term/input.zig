//! Terminal input: bytes in, events out. Keys (with modifiers), mouse (SGR and X10
//! encodings), bracketed paste, and focus changes, decoded from what xterm-compatible
//! terminals send: C0 controls, UTF-8, CSI and SS3 sequences, ESC-prefixed Alt keys,
//! xterm `modifyOtherKeys` (`CSI 27;m;code~`), and the kitty keyboard protocol's
//! `CSI code;m u` form. Also the terminal's replies to the queries in `ansi` (colors,
//! mode status, kitty keyboard flags, device attributes), as `report` events.
//!
//! A lone ESC is ambiguous: it is the Escape key, or the start of a sequence whose rest has
//! not arrived yet. `Decoder.next` waits; when no more bytes come within a short time, the
//! caller calls `Decoder.flush`, which decodes what is buffered as complete. The decoder
//! keeps no clock and starts no threads; `tui.Program` drives it.
//!
//! `encode` writes the canonical bytes for an event, so tests can type keys by name.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ansi = @import("ansi.zig");

/// Modifier keys held with a key or mouse event.
pub const Mods = packed struct(u4) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    /// From the xterm modifier parameter (1 + a bitmask; 1 means none).
    pub fn fromParam(param: u32) Mods {
        const bits: u32 = if (param > 0) param - 1 else 0;
        return @bitCast(@as(u4, @truncate(bits)));
    }

    /// The xterm modifier parameter.
    pub fn toParam(mods: Mods) u8 {
        return @as(u8, @as(u4, @bitCast(mods))) + 1;
    }

    /// Whether no modifier is held.
    pub fn isEmpty(mods: Mods) bool {
        return @as(u4, @bitCast(mods)) == 0;
    }
};

/// A key press.
pub const Key = struct {
    code: Code,
    mods: Mods = .{},

    /// Which key. Printable keys are `char`, including space; `A` is `char = 'A'` with no
    /// `shift`, since the character already says it.
    pub const Code = union(enum) {
        char: u21,
        /// F1 is `function = 1`; F1-F20 are recognized.
        function: u8,
        enter,
        tab,
        backspace,
        escape,
        insert,
        delete,
        up,
        down,
        left,
        right,
        home,
        end,
        page_up,
        page_down,
    };

    /// Whether two keys are the same key with the same modifiers.
    pub fn eql(a: Key, b: Key) bool {
        return std.meta.eql(a, b);
    }

    /// Whether this is the key `text` names (see `parse`), checked at compile time:
    /// `key.matches("ctrl+c")`.
    pub fn matches(key: Key, comptime text: []const u8) bool {
        const want = comptime parse(text) catch @compileError("not a key name: " ++ text);
        return key.eql(want);
    }

    /// The character this key types, if it types one: a `char` with neither Ctrl, Alt, nor
    /// Super held.
    pub fn printable(key: Key) ?u21 {
        if (key.mods.ctrl or key.mods.alt or key.mods.super) return null;
        return switch (key.code) {
            .char => |c| c,
            else => null,
        };
    }

    /// The text names no key.
    pub const ParseError = error{InvalidKey};

    /// Parses a key name: modifiers (`ctrl`, `alt`, `shift`, `super`) joined to the key
    /// by `+`, as in `ctrl+shift+up`. Keys: a single character, `space`, `enter`, `tab`,
    /// `backspace`, `esc`, `insert`, `delete`, `up`, `down`, `left`, `right`, `home`,
    /// `end`, `pgup`, `pgdown`, `f1`-`f20`. The inverse of `format`.
    pub fn parse(text: []const u8) ParseError!Key {
        var key: Key = .{ .code = .enter };
        var rest = text;
        while (std.mem.indexOfScalarPos(u8, rest, 1, '+')) |plus| {
            const name = rest[0..plus];
            if (std.mem.eql(u8, name, "ctrl")) {
                key.mods.ctrl = true;
            } else if (std.mem.eql(u8, name, "alt")) {
                key.mods.alt = true;
            } else if (std.mem.eql(u8, name, "shift")) {
                key.mods.shift = true;
            } else if (std.mem.eql(u8, name, "super")) {
                key.mods.super = true;
            } else return error.InvalidKey;
            rest = rest[plus + 1 ..];
        }
        key.code = try parseCode(rest);
        return key;
    }

    const named = [_]struct { []const u8, Code }{
        .{ "enter", .enter },           .{ "tab", .tab },
        .{ "backspace", .backspace },   .{ "esc", .escape },
        .{ "insert", .insert },         .{ "delete", .delete },
        .{ "up", .up },                 .{ "down", .down },
        .{ "left", .left },             .{ "right", .right },
        .{ "home", .home },             .{ "end", .end },
        .{ "pgup", .page_up },          .{ "pgdown", .page_down },
        .{ "space", .{ .char = ' ' } },
    };

    fn parseCode(name: []const u8) ParseError!Code {
        if (name.len == 0) return error.InvalidKey;
        for (named) |entry| {
            if (std.mem.eql(u8, entry[0], name)) return entry[1];
        }
        if (name.len >= 2 and name[0] == 'f') {
            const n = std.fmt.parseInt(u8, name[1..], 10) catch return error.InvalidKey;
            if (n < 1 or n > 20) return error.InvalidKey;
            return .{ .function = n };
        }
        const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return error.InvalidKey;
        if (len != name.len) return error.InvalidKey;
        const cp = std.unicode.utf8Decode(name) catch return error.InvalidKey;
        if (cp < 0x20 or cp == 0x7f) return error.InvalidKey;
        return .{ .char = cp };
    }

    /// Writes the key's name, as `parse` reads it: `ctrl+alt+x`, `shift+tab`, `f5`.
    pub fn format(key: Key, w: *Writer) Writer.Error!void {
        if (key.mods.ctrl) try w.writeAll("ctrl+");
        if (key.mods.alt) try w.writeAll("alt+");
        if (key.mods.shift) try w.writeAll("shift+");
        if (key.mods.super) try w.writeAll("super+");
        switch (key.code) {
            .char => |c| if (c == ' ') try w.writeAll("space") else try writeCodepoint(w, c),
            .function => |n| try w.print("f{d}", .{n}),
            else => for (named) |entry| {
                if (std.meta.eql(entry[1], key.code)) return w.writeAll(entry[0]);
            },
        }
    }
};

/// A mouse event. Coordinates are 0-based cells from the top left.
pub const Mouse = struct {
    x: u16,
    y: u16,
    button: Button,
    action: Action,
    mods: Mods = .{},

    /// Which button, or wheel direction, the event is about.
    pub const Button = enum {
        left,
        middle,
        right,
        /// Motion with no button held.
        none,
        wheel_up,
        wheel_down,
        wheel_left,
        wheel_right,
        back,
        forward,
    };

    /// Motion is reported while a button is held (drag); `.none` motion needs the
    /// any-event mouse mode, which `ansi.setMouse` does not turn on.
    pub const Action = enum { press, release, motion };
};

/// One decoded input event.
pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    /// Bracketed paste. Points into the decoder's buffer: valid until the next `feed`.
    paste: []const u8,
    focus_in,
    focus_out,
    /// The terminal's reply to a query.
    report: Report,
};

/// A terminal's reply to one of the queries in `ansi`.
pub const Report = union(enum) {
    /// The default foreground color (OSC 10), from `ansi.queryForeground`.
    foreground: ansi.Color.Rgb,
    /// The default background color (OSC 11), from `ansi.queryBackground`.
    background: ansi.Color.Rgb,
    /// Whether a DEC private mode is supported and set (DECRPM), from `ansi.queryMode`.
    mode: struct { mode: u16, status: ModeStatus },
    /// The kitty keyboard protocol's flags, from `ansi.queryKittyKeyboard`; only terminals
    /// with the protocol reply.
    kitty_keyboard: u8,
    /// The primary device attributes, from `ansi.queryDeviceAttributes`. Every terminal
    /// replies, and in order, so this marks the end of the replies to queries sent before it.
    device_attributes,
    /// Where the cursor is, counting from 0 (DECXCPR), from `ansi.queryCursorPosition`.
    cursor: struct { row: u16, column: u16 },

    /// What DECRPM says about a mode.
    pub const ModeStatus = enum(u3) {
        unknown = 0,
        set = 1,
        reset = 2,
        always_set = 3,
        always_reset = 4,

        /// The terminal knows the mode.
        pub fn supported(status: ModeStatus) bool {
            return status != .unknown;
        }
    };
};

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

/// A sequence longer than this without a final byte is garbage, not a sequence still
/// arriving; its ESC is dropped so decoding can move on.
const max_sequence = 64;

/// Buffers bytes and decodes them into events.
pub const Decoder = struct {
    gpa: Allocator,
    buffer: std.ArrayList(u8) = .empty,
    /// Bytes of `buffer` before this are decoded.
    start: usize = 0,
    /// Inside a bracketed paste: the bytes up to the end marker are its content.
    pasting: bool = false,

    /// An empty decoder; buffers grow with `gpa`.
    pub fn init(gpa: Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    /// Frees the buffer.
    pub fn deinit(d: *Decoder) void {
        d.buffer.deinit(d.gpa);
        d.* = undefined;
    }

    /// Adds bytes to decode. Invalidates the slice of a previous `paste` event.
    pub fn feed(d: *Decoder, bytes: []const u8) Allocator.Error!void {
        if (d.start > 0) {
            const rest = d.buffer.items[d.start..];
            std.mem.copyForwards(u8, d.buffer.items[0..rest.len], rest);
            d.buffer.shrinkRetainingCapacity(rest.len);
            d.start = 0;
        }
        try d.buffer.appendSlice(d.gpa, bytes);
    }

    /// The next complete event, or null when the buffer is empty or ends in an incomplete
    /// sequence (which may be completed by the next `feed`, or forced out by `flush`).
    pub fn next(d: *Decoder) ?Event {
        return d.decode(false);
    }

    /// Like `next`, but treats the end of the buffer as the end of input: a lone ESC is the
    /// Escape key, an unfinished sequence is decoded as the keys its bytes spell, and a
    /// partial UTF-8 character becomes U+FFFD. Call it until it returns null after a
    /// quiet period. An unfinished paste keeps waiting for its end marker.
    pub fn flush(d: *Decoder) ?Event {
        return d.decode(true);
    }

    /// Whether bytes are buffered that no event has consumed yet.
    pub fn hasPending(d: *const Decoder) bool {
        return d.start < d.buffer.items.len;
    }

    fn decode(d: *Decoder, final: bool) ?Event {
        while (d.start < d.buffer.items.len) {
            const rest = d.buffer.items[d.start..];
            if (d.pasting) {
                const end = std.mem.indexOf(u8, rest, paste_end) orelse return null;
                d.pasting = false;
                d.start += end + paste_end.len;
                return .{ .paste = rest[0..end] };
            }
            switch (decodeOne(rest, final, true)) {
                .incomplete => return null,
                .skip => |n| d.start += n,
                .paste => |n| {
                    d.start += n;
                    d.pasting = true;
                },
                .event => |e| {
                    d.start += e.len;
                    return e.event;
                },
            }
        }
        return null;
    }
};

const Decoded = union(enum) {
    /// More bytes are needed.
    incomplete,
    /// Bytes that mean nothing, consumed silently.
    skip: usize,
    /// The bracketed-paste start marker.
    paste: usize,
    event: struct { event: Event, len: usize },
};

fn keyEvent(code: Key.Code, mods: Mods, len: usize) Decoded {
    return .{ .event = .{ .event = .{ .key = .{ .code = code, .mods = mods } }, .len = len } };
}

fn decodeOne(bytes: []const u8, final: bool, allow_alt: bool) Decoded {
    assert(bytes.len > 0);
    const c = bytes[0];
    if (c == 0x1b) return decodeEscape(bytes, final, allow_alt);
    if (c < 0x80) return keyEvent(controlKey(c), controlMods(c), 1);
    const len = std.unicode.utf8ByteSequenceLength(c) catch
        return keyEvent(.{ .char = std.unicode.replacement_character }, .{}, 1);
    if (bytes.len < len) {
        if (!final) return .incomplete;
        return keyEvent(.{ .char = std.unicode.replacement_character }, .{}, 1);
    }
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch
        return keyEvent(.{ .char = std.unicode.replacement_character }, .{}, 1);
    return keyEvent(.{ .char = cp }, .{}, len);
}

/// The key a single ASCII byte stands for.
fn controlKey(c: u8) Key.Code {
    return switch (c) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        0x7f, 0x08 => .backspace,
        0x00 => .{ .char = ' ' },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => .{ .char = 'a' + c - 1 },
        0x1c...0x1f => .{ .char = '\\' + c - 0x1c },
        else => .{ .char = c },
    };
}

fn controlMods(c: u8) Mods {
    return switch (c) {
        '\r', '\n', '\t', 0x7f => .{},
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f => .{ .ctrl = true },
        else => .{},
    };
}

fn decodeEscape(bytes: []const u8, final: bool, allow_alt: bool) Decoded {
    if (bytes.len == 1) return if (final) keyEvent(.escape, .{}, 1) else .incomplete;
    switch (bytes[1]) {
        '[' => return decodeCsi(bytes, final),
        'O' => return decodeSs3(bytes, final),
        ']' => if (decodeOsc(bytes, final)) |decoded| return decoded,
        else => {},
    }
    if (!allow_alt) return keyEvent(.escape, .{}, 1);
    // ESC followed by a key is that key with Alt.
    return switch (decodeOne(bytes[1..], final, false)) {
        .incomplete => .incomplete,
        .event => |e| switch (e.event) {
            .key => |key| blk: {
                var alt = key;
                alt.mods.alt = true;
                break :blk .{ .event = .{ .event = .{ .key = alt }, .len = e.len + 1 } };
            },
            else => keyEvent(.escape, .{}, 1),
        },
        .skip, .paste => keyEvent(.escape, .{}, 1),
    };
}

fn decodeSs3(bytes: []const u8, final: bool) Decoded {
    if (bytes.len < 3) {
        return if (final) keyEvent(.{ .char = 'O' }, .{ .alt = true }, 2) else .incomplete;
    }
    const code: Key.Code = switch (bytes[2]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'M' => .enter,
        'P'...'S' => .{ .function = bytes[2] - 'P' + 1 },
        else => return .{ .skip = 3 },
    };
    return keyEvent(code, .{}, 3);
}

/// The longest OSC reply read; a longer one is not a reply to these queries.
const max_osc = 128;

/// An OSC reply (`ESC ] ... BEL` or `ESC ] ... ESC \`): a color report, or skipped. Null
/// when the bytes cannot be one, so `ESC ]` is Alt+]: the reply has not arrived whole by
/// `final`, or it runs past `max_osc`.
fn decodeOsc(bytes: []const u8, final: bool) ?Decoded {
    var i: usize = 2;
    const end: usize, const body_end: usize = while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 0x07) break .{ i + 1, i };
        if (bytes[i] == 0x1b) {
            if (i + 1 == bytes.len) {
                if (final) return null;
                return .incomplete;
            }
            if (bytes[i + 1] == '\\') break .{ i + 2, i };
            return null;
        }
        if (bytes[i] < 0x20 or i >= max_osc) return null;
    } else {
        if (final) return null;
        return .incomplete;
    };
    const body = bytes[2..body_end];
    const skip: Decoded = .{ .skip = end };
    const semicolon = std.mem.indexOfScalar(u8, body, ';') orelse return skip;
    const rgb = parseRgb(body[semicolon + 1 ..]) orelse return skip;
    const report: Report = if (std.mem.eql(u8, body[0..semicolon], "10"))
        .{ .foreground = rgb }
    else if (std.mem.eql(u8, body[0..semicolon], "11"))
        .{ .background = rgb }
    else
        return skip;
    return .{ .event = .{ .event = .{ .report = report }, .len = end } };
}

/// Parses X11's `rgb:r/g/b`, each channel 1 to 4 hex digits, scaled to 8 bits.
fn parseRgb(text: []const u8) ?ansi.Color.Rgb {
    if (!std.mem.startsWith(u8, text, "rgb:")) return null;
    var channels: [3]u8 = undefined;
    var it = std.mem.splitScalar(u8, text["rgb:".len..], '/');
    for (&channels) |*channel| {
        const digits = it.next() orelse return null;
        if (digits.len == 0 or digits.len > 4) return null;
        const value = std.fmt.parseInt(u16, digits, 16) catch return null;
        const max = (@as(u32, 1) << @intCast(4 * digits.len)) - 1;
        channel.* = @intCast((@as(u32, value) * 255 + max / 2) / max);
    }
    if (it.next() != null) return null;
    return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
}

/// The parts of a CSI sequence: `ESC [ <private> <params> <intermediate> <final>`.
const Csi = struct {
    private: u8 = 0,
    /// The last intermediate byte (`$` in DECRPM), or 0.
    intermediate: u8 = 0,
    params: [max_params]u32 = @splat(0),
    count: usize = 0,
    final: u8,
    len: usize,

    const max_params = 8;

    /// Parameter `i`, or `default` when absent or empty.
    fn param(csi: Csi, i: usize, default: u32) u32 {
        if (i >= csi.count or csi.params[i] == 0) return default;
        return csi.params[i];
    }
};

fn decodeCsi(bytes: []const u8, final: bool) Decoded {
    const csi = parseCsi(bytes) orelse {
        if (bytes.len > max_sequence) return .{ .skip = 1 };
        if (!final) return .incomplete;
        return keyEvent(.{ .char = '[' }, .{ .alt = true }, 2);
    };
    if (csi.private == '<') return decodeSgrMouse(csi);
    if (csi.private == '?') return decodeReport(csi);
    if (csi.private != 0) return .{ .skip = csi.len };
    const mods = Mods.fromParam(csi.param(1, 1));
    return switch (csi.final) {
        'A' => keyEvent(.up, mods, csi.len),
        'B' => keyEvent(.down, mods, csi.len),
        'C' => keyEvent(.right, mods, csi.len),
        'D' => keyEvent(.left, mods, csi.len),
        'H' => keyEvent(.home, mods, csi.len),
        'F' => keyEvent(.end, mods, csi.len),
        'P'...'S' => keyEvent(.{ .function = csi.final - 'P' + 1 }, mods, csi.len),
        'Z' => keyEvent(.tab, .{ .shift = true }, csi.len),
        'I' => .{ .event = .{ .event = .focus_in, .len = csi.len } },
        'O' => .{ .event = .{ .event = .focus_out, .len = csi.len } },
        '~' => decodeTilde(csi),
        'u' => decodeKitty(csi),
        'M' => if (csi.count == 0) decodeX10Mouse(bytes, final) else .{ .skip = csi.len },
        else => .{ .skip = csi.len },
    };
}

/// Parses a complete CSI sequence, or returns null when the final byte has not arrived.
fn parseCsi(bytes: []const u8) ?Csi {
    var csi: Csi = .{ .final = 0, .len = 0 };
    var i: usize = 2;
    if (i < bytes.len and bytes[i] >= '<' and bytes[i] <= '?') {
        csi.private = bytes[i];
        i += 1;
    }
    var in_subparam = false;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        switch (c) {
            '0'...'9' => if (!in_subparam) {
                if (csi.count == 0) csi.count = 1;
                const slot = &csi.params[csi.count - 1];
                slot.* = slot.* *| 10 +| (c - '0');
            },
            ':' => in_subparam = true,
            ';' => {
                in_subparam = false;
                if (csi.count == 0) csi.count = 1;
                if (csi.count < Csi.max_params) csi.count += 1;
            },
            0x20...0x2f => csi.intermediate = c,
            '<'...'?' => {},
            0x40...0x7e => {
                csi.final = c;
                csi.len = i + 1;
                return csi;
            },
            else => {
                // A control byte inside a sequence: the sequence was cut off. Treat what
                // came before as an unknown sequence.
                csi.final = 0;
                csi.len = i;
                return csi;
            },
        }
    }
    return null;
}

/// A reply in `CSI ? ...` form: DECRPM, kitty keyboard flags, device attributes, or the
/// cursor's position.
fn decodeReport(csi: Csi) Decoded {
    const report: Report = switch (csi.final) {
        'y' => if (csi.intermediate == '$' and csi.count == 2 and csi.params[1] <= 4) .{
            .mode = .{
                .mode = std.math.cast(u16, csi.params[0]) orelse return .{ .skip = csi.len },
                .status = @fromBackingInt(@intCast(csi.params[1])),
            },
        } else return .{ .skip = csi.len },
        'u' => .{ .kitty_keyboard = std.math.cast(u8, csi.param(0, 0)) orelse 0 },
        'c' => .device_attributes,
        // `CSI ? row ; column R`, or with a page after (xterm): the `?` keeps it apart from
        // a key such as Shift-F3 (`CSI 1 ; 2 R`).
        'R' => if (csi.count >= 2) .{ .cursor = .{
            .row = std.math.cast(u16, csi.params[0] -| 1) orelse return .{ .skip = csi.len },
            .column = std.math.cast(u16, csi.params[1] -| 1) orelse return .{ .skip = csi.len },
        } } else return .{ .skip = csi.len },
        else => return .{ .skip = csi.len },
    };
    return .{ .event = .{ .event = .{ .report = report }, .len = csi.len } };
}

fn decodeTilde(csi: Csi) Decoded {
    const mods = Mods.fromParam(csi.param(1, 1));
    const code: Key.Code = switch (csi.param(0, 0)) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11...15 => |n| .{ .function = @intCast(n - 10) },
        17...21 => |n| .{ .function = @intCast(n - 11) },
        23...26 => |n| .{ .function = @intCast(n - 12) },
        28, 29 => |n| .{ .function = @intCast(n - 13) },
        31...34 => |n| .{ .function = @intCast(n - 14) },
        200 => return .{ .paste = csi.len },
        27 => return codepointKey(csi.param(2, 0), Mods.fromParam(csi.param(1, 1)), csi.len),
        else => return .{ .skip = csi.len },
    };
    return keyEvent(code, mods, csi.len);
}

/// The kitty keyboard protocol: `CSI code ; mods u`. Release events are skipped.
fn decodeKitty(csi: Csi) Decoded {
    return codepointKey(csi.param(0, 0), Mods.fromParam(csi.param(1, 1)), csi.len);
}

fn codepointKey(code: u32, mods: Mods, len: usize) Decoded {
    const key: Key.Code = switch (code) {
        13 => .enter,
        9 => .tab,
        127, 8 => .backspace,
        27 => .escape,
        // Kitty's own functional keys live in the private use area (from U+E000); unnamed here.
        0x20...0x7e, 0xa0...0xd7ff, 0xf900...0x10ffff => .{ .char = @intCast(code) },
        else => return .{ .skip = len },
    };
    var normalized = mods;
    var final_key = key;
    if (key == .char and mods.shift and key.char >= 'a' and key.char <= 'z') {
        final_key = .{ .char = key.char - 'a' + 'A' };
        normalized.shift = false;
    }
    return keyEvent(final_key, normalized, len);
}

fn decodeSgrMouse(csi: Csi) Decoded {
    if (csi.final != 'M' and csi.final != 'm') return .{ .skip = csi.len };
    const b = csi.param(0, 0);
    var mouse = mouseFromButton(b);
    mouse.x = @intCast(@min(csi.param(1, 1) - 1, std.math.maxInt(u16)));
    mouse.y = @intCast(@min(csi.param(2, 1) - 1, std.math.maxInt(u16)));
    if (csi.final == 'm') mouse.action = .release;
    return .{ .event = .{ .event = .{ .mouse = mouse }, .len = csi.len } };
}

/// X10 encoding: `ESC [ M` and three bytes, each offset by 32.
fn decodeX10Mouse(bytes: []const u8, final: bool) Decoded {
    if (bytes.len < 6) return if (final) .{ .skip = bytes.len } else .incomplete;
    const b = bytes[3] -| 32;
    var mouse = mouseFromButton(b);
    mouse.x = bytes[4] -| 33;
    mouse.y = bytes[5] -| 33;
    if (b & 3 == 3 and b & (32 | 64) == 0) {
        mouse.action = .release;
        mouse.button = .none;
    }
    return .{ .event = .{ .event = .{ .mouse = mouse }, .len = 6 } };
}

fn mouseFromButton(b: u32) Mouse {
    const low = b & 3;
    const button: Mouse.Button = if (b & 64 != 0)
        switch (low) {
            0 => .wheel_up,
            1 => .wheel_down,
            2 => .wheel_left,
            else => .wheel_right,
        }
    else if (b & 128 != 0)
        switch (low) {
            0 => .back,
            1 => .forward,
            else => .none,
        }
    else switch (low) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };
    return .{
        .x = 0,
        .y = 0,
        .button = button,
        .action = if (b & 32 != 0) .motion else .press,
        .mods = .{ .shift = b & 4 != 0, .alt = b & 8 != 0, .ctrl = b & 16 != 0 },
    };
}

/// Writes the bytes a terminal sends for `event`, in a canonical encoding `Decoder`
/// reads back as the same event: plain bytes for unmodified keys, `CSI 1;m X` and
/// `CSI n;m ~` for modified special keys, the kitty `CSI code;m u` form for other modified
/// keys, SGR for the mouse.
pub fn encode(w: *Writer, event: Event) Writer.Error!void {
    switch (event) {
        .key => |key| try encodeKey(w, key),
        .mouse => |mouse| try encodeMouse(w, mouse),
        .paste => |text| try w.print(paste_start ++ "{s}" ++ paste_end, .{text}),
        .focus_in => try w.writeAll("\x1b[I"),
        .focus_out => try w.writeAll("\x1b[O"),
        .report => |report| try encodeReport(w, report),
    }
}

fn encodeReport(w: *Writer, report: Report) Writer.Error!void {
    switch (report) {
        .foreground, .background => |c| {
            const n: u8 = if (report == .foreground) 10 else 11;
            try w.print("\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                n, c.r, c.r, c.g, c.g, c.b, c.b,
            });
        },
        .mode => |m| try w.print("\x1b[?{d};{d}$y", .{ m.mode, @backingInt(m.status) }),
        .kitty_keyboard => |flags| try w.print("\x1b[?{d}u", .{flags}),
        .device_attributes => try w.writeAll("\x1b[?62;22c"),
        .cursor => |at| try w.print("\x1b[?{d};{d}R", .{ @as(u32, at.row) + 1, @as(u32, at.column) + 1 }),
    }
}

fn encodeKey(w: *Writer, key: Key) Writer.Error!void {
    const m = key.mods.toParam();
    const plain = key.mods.isEmpty();
    switch (key.code) {
        .up, .down, .right, .left, .home, .end => {
            const final: u8 = switch (key.code) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                .home => 'H',
                else => 'F',
            };
            if (plain) return w.print("\x1b[{c}", .{final});
            try w.print("\x1b[1;{d}{c}", .{ m, final });
        },
        .insert, .delete, .page_up, .page_down => {
            const n: u8 = switch (key.code) {
                .insert => 2,
                .delete => 3,
                .page_up => 5,
                else => 6,
            };
            if (plain) return w.print("\x1b[{d}~", .{n});
            try w.print("\x1b[{d};{d}~", .{ n, m });
        },
        .function => |n| try encodeFunction(w, n, key.mods),
        .enter, .tab, .backspace, .escape, .char => try encodeTextKey(w, key),
    }
}

fn encodeFunction(w: *Writer, n: u8, mods: Mods) Writer.Error!void {
    assert(n >= 1 and n <= 20);
    if (n <= 4) {
        if (mods.isEmpty()) return w.print("\x1bO{c}", .{'P' + n - 1});
        return w.print("\x1b[1;{d}{c}", .{ mods.toParam(), 'P' + n - 1 });
    }
    const codes = [_]u8{ 15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34 };
    const code = codes[n - 5];
    if (mods.isEmpty()) return w.print("\x1b[{d}~", .{code});
    try w.print("\x1b[{d};{d}~", .{ code, mods.toParam() });
}

fn encodeTextKey(w: *Writer, key: Key) Writer.Error!void {
    const code: u21 = switch (key.code) {
        .enter => '\r',
        .tab => '\t',
        .backspace => 0x7f,
        .escape => 0x1b,
        .char => |c| c,
        else => unreachable, // encodeKey routes only these here
    };
    if (key.mods.isEmpty()) {
        if (code < 0x20 and key.code == .char) return w.print("\x1b[{d}u", .{code});
        return writeCodepoint(w, code);
    }
    if (key.mods == Mods{ .shift = true } and key.code == .tab) return w.writeAll("\x1b[Z");
    const kitty_code: u21 = if (code == '\r') 13 else if (code == '\t') 9 else code;
    try w.print("\x1b[{d};{d}u", .{ kitty_code, key.mods.toParam() });
}

fn encodeMouse(w: *Writer, mouse: Mouse) Writer.Error!void {
    var b: u32 = switch (mouse.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => 3,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_left => 66,
        .wheel_right => 67,
        .back => 128,
        .forward => 129,
    };
    if (mouse.action == .motion) b |= 32;
    if (mouse.mods.shift) b |= 4;
    if (mouse.mods.alt) b |= 8;
    if (mouse.mods.ctrl) b |= 16;
    const final: u8 = if (mouse.action == .release) 'm' else 'M';
    try w.print("\x1b[<{d};{d};{d}{c}", .{
        b,
        @as(u32, mouse.x) + 1,
        @as(u32, mouse.y) + 1,
        final,
    });
}

fn writeCodepoint(w: *Writer, cp: u21) Writer.Error!void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch {
        return w.writeAll("\u{fffd}");
    };
    try w.writeAll(buffer[0..len]);
}

const testing = std.testing;

/// Decodes all of `bytes` (flushing at the end) into a list of keys formatted as names,
/// separated by spaces; other events are written in brackets.
fn expectDecoded(expected: []const u8, bytes: []const u8) !void {
    var decoder: Decoder = .init(testing.allocator);
    defer decoder.deinit();
    try decoder.feed(bytes);
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    var first = true;
    while (decoder.next() orelse decoder.flush()) |event| {
        if (!first) try w.writeByte(' ');
        first = false;
        try writeEvent(&w, event);
    }
    try testing.expectEqualStrings(expected, w.buffered());
}

fn writeEvent(w: *Writer, event: Event) !void {
    switch (event) {
        .key => |key| try key.format(w),
        .mouse => |m| {
            try w.print("[mouse {t} {t} {d},{d}", .{ m.button, m.action, m.x, m.y });
            if (m.mods.shift) try w.writeAll(" shift");
            if (m.mods.alt) try w.writeAll(" alt");
            if (m.mods.ctrl) try w.writeAll(" ctrl");
            try w.writeByte(']');
        },
        .paste => |text| try w.print("[paste {s}]", .{text}),
        .focus_in => try w.writeAll("[focus in]"),
        .focus_out => try w.writeAll("[focus out]"),
        .report => |r| switch (r) {
            .foreground, .background => |c| try w.print(
                "[{t} {x:0>2}{x:0>2}{x:0>2}]",
                .{ r, c.r, c.g, c.b },
            ),
            .mode => |m| try w.print("[mode {d} {t}]", .{ m.mode, m.status }),
            .kitty_keyboard => |flags| try w.print("[kitty {d}]", .{flags}),
            .device_attributes => try w.writeAll("[device attributes]"),
            .cursor => |at| try w.print("[cursor {d},{d}]", .{ at.row, at.column }),
        },
    }
}

test "decode: printable text and UTF-8" {
    try expectDecoded("a B space 1 ~", "aB 1~");
    try expectDecoded("é 中 😀", "é中😀");
    try expectDecoded("\u{fffd} a", "\xffa");
    try expectDecoded("\u{fffd} \u{fffd}", "\xe4\xb8"); // cut short, then flushed
}

test "decode: control keys" {
    try expectDecoded("enter enter tab backspace", "\r\n\t\x7f");
    try expectDecoded("ctrl+a ctrl+c ctrl+z ctrl+backspace", "\x01\x03\x1a\x08");
    try expectDecoded("ctrl+space ctrl+\\ ctrl+] ctrl+^ ctrl+_", "\x00\x1c\x1d\x1e\x1f");
}

test "decode: escape and alt" {
    try expectDecoded("esc", "\x1b");
    try expectDecoded("alt+a alt+B ctrl+alt+c alt+enter", "\x1ba\x1bB\x1b\x03\x1b\r");
    try expectDecoded("alt+esc", "\x1b\x1b");
    try expectDecoded("alt+é", "\x1bé");
    try expectDecoded("alt+up", "\x1b\x1b[A");
    try expectDecoded("alt+esc alt+a", "\x1b\x1b\x1ba"); // one ESC of Alt per key
}

test "decode: CSI and SS3 keys" {
    try expectDecoded("up down right left home end", "\x1b[A\x1b[B\x1b[C\x1b[D\x1b[H\x1b[F");
    try expectDecoded("up down home end", "\x1bOA\x1bOB\x1bOH\x1bOF");
    try expectDecoded("f1 f2 f3 f4 enter", "\x1bOP\x1bOQ\x1bOR\x1bOS\x1bOM");
    try expectDecoded(
        "home insert delete end pgup pgdown home end",
        "\x1b[1~\x1b[2~\x1b[3~\x1b[4~\x1b[5~\x1b[6~\x1b[7~\x1b[8~",
    );
    try expectDecoded(
        "f1 f5 f6 f10 f11 f12 f13 f16 f17 f20",
        "\x1b[11~\x1b[15~\x1b[17~\x1b[21~\x1b[23~\x1b[24~\x1b[25~\x1b[29~\x1b[31~\x1b[34~",
    );
    try expectDecoded("shift+tab", "\x1b[Z");
}

test "decode: modifiers" {
    try expectDecoded("shift+up ctrl+alt+left ctrl+right", "\x1b[1;2A\x1b[1;7D\x1b[1;5C");
    try expectDecoded("ctrl+alt+shift+super+home", "\x1b[1;16H");
    try expectDecoded("ctrl+delete alt+pgdown", "\x1b[3;5~\x1b[6;3~");
    try expectDecoded("ctrl+f1 shift+f5", "\x1b[1;5P\x1b[15;2~");
}

test "decode: kitty and modifyOtherKeys" {
    try expectDecoded(
        "ctrl+a ctrl+enter shift+tab alt+backspace esc",
        "\x1b[97;5u\x1b[13;5u\x1b[9;2u\x1b[127;3u\x1b[27u",
    );
    try expectDecoded("A ctrl+A", "\x1b[97;2u\x1b[97;6u");
    try expectDecoded("ctrl+i ctrl+m", "\x1b[27;5;105~\x1b[27;5;109~");
    try expectDecoded("ctrl+a", "\x1b[97:65;5:1u"); // subparameters are ignored
    try expectDecoded("x", "\x1b[57441;2ux"); // functional keys we do not name are skipped
}

test "decode: mouse" {
    try expectDecoded("[mouse left press 0,0]", "\x1b[<0;1;1M");
    try expectDecoded("[mouse left release 9,4]", "\x1b[<0;10;5m");
    try expectDecoded("[mouse right motion 2,3 ctrl]", "\x1b[<50;3;4M");
    try expectDecoded(
        "[mouse wheel_up press 0,0] [mouse wheel_down press 0,0 shift alt]",
        "\x1b[<64;1;1M\x1b[<77;1;1M",
    );
    try expectDecoded("[mouse back press 4,4]", "\x1b[<128;5;5M");
    try expectDecoded("[mouse none motion 1,1]", "\x1b[<35;2;2M");
    try expectDecoded("[mouse middle press 1,2] [mouse none release 0,0]", "\x1b[M!\"#\x1b[M#!!");
}

test "decode: paste and focus" {
    try expectDecoded("[paste hello\nworld] a", "\x1b[200~hello\nworld\x1b[201~a");
    try expectDecoded("[paste \x1b[A\x03]", "\x1b[200~\x1b[A\x03\x1b[201~");
    try expectDecoded("[paste ]", "\x1b[200~\x1b[201~");
    try expectDecoded("[focus in] [focus out]", "\x1b[I\x1b[O");
}

test "decode: unknown sequences are skipped" {
    try expectDecoded("a b", "a\x1b[?1;2Xb");
    try expectDecoded("a", "\x1b]2;title\x07a"); // an OSC that is not a color report
    try expectDecoded("a", "\x1b]11;?\x1b\\a"); // an echoed query
    try expectDecoded("a", "\x1b[99Xa");
    try expectDecoded("a", "\x1bOxa");
    try expectDecoded("x", "\x1b[201~x"); // a stray paste end
}

test "decode: replies to queries" {
    try expectDecoded("[background 1e1e2e]", "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\");
    try expectDecoded("[foreground ffffff]", "\x1b]10;rgb:ffff/ffff/ffff\x07");
    // One to four digits per channel, scaled to 8 bits.
    try expectDecoded("[background ff8800]", "\x1b]11;rgb:f/8/0\x07");
    try expectDecoded("[background 808080]", "\x1b]11;rgb:808/808/808\x07");
    try expectDecoded("[mode 2026 reset] [mode 2027 unknown]", "\x1b[?2026;2$y\x1b[?2027;0$y");
    try expectDecoded("[kitty 1] [device attributes]", "\x1b[?1u\x1b[?62;22c");
    // An OSC with no end is Alt+] once the input ends.
    try expectDecoded("alt+] 1", "\x1b]1");
}

test "Decoder: partial sequences wait for more bytes, or for flush" {
    var decoder: Decoder = .init(testing.allocator);
    defer decoder.deinit();
    try decoder.feed("\x1b");
    try testing.expectEqual(null, decoder.next());
    try testing.expect(decoder.hasPending());
    try decoder.feed("[1;");
    try testing.expectEqual(null, decoder.next());
    try decoder.feed("5A");
    try testing.expect(decoder.next().?.key.matches("ctrl+up"));
    try testing.expect(!decoder.hasPending());

    try decoder.feed("\xe4\xb8");
    try testing.expectEqual(null, decoder.next());
    try decoder.feed("\xad");
    try testing.expectEqual(@as(u21, '中'), decoder.next().?.key.code.char);

    try decoder.feed("\x1b[");
    try testing.expectEqual(null, decoder.next());
    try testing.expect(decoder.flush().?.key.matches("alt+["));
    try testing.expectEqual(null, decoder.flush());

    try decoder.feed("\x1bO");
    try testing.expect(decoder.flush().?.key.matches("alt+O"));
}

test "Decoder: a paste arriving in pieces, and an unfinished paste survives flush" {
    var decoder: Decoder = .init(testing.allocator);
    defer decoder.deinit();
    try decoder.feed("\x1b[200~abc");
    try testing.expectEqual(null, decoder.next());
    try testing.expectEqual(null, decoder.flush());
    try decoder.feed("def\x1b[20");
    try testing.expectEqual(null, decoder.next());
    try decoder.feed("1~");
    try testing.expectEqualStrings("abcdef", decoder.next().?.paste);
    try testing.expectEqual(null, decoder.next());
}

test "Decoder: an overlong sequence is garbage, not a wait" {
    var decoder: Decoder = .init(testing.allocator);
    defer decoder.deinit();
    try decoder.feed("\x1b[");
    for (0..max_sequence) |_| try decoder.feed("1");
    const event = decoder.next().?;
    try testing.expect(event.key.matches("["));
}

test "Key.parse and format round-trip" {
    const names = [_][]const u8{
        "a",     "A",          "ctrl+c", "alt+enter", "shift+tab", "ctrl+alt+shift+super+x",
        "space", "ctrl+space", "f1",     "f20",       "pgup",      "pgdown",
        "esc",   "backspace",  "delete", "insert",    "home",      "end",
        "up",    "down",       "left",   "right",
        "é",
        "+",     "ctrl++",
        "中",
    };
    for (names) |name| {
        var buffer: [64]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try (try Key.parse(name)).format(&w);
        try testing.expectEqualStrings(name, w.buffered());
    }
    try testing.expectError(error.InvalidKey, Key.parse(""));
    try testing.expectError(error.InvalidKey, Key.parse("ctrl+"));
    try testing.expectError(error.InvalidKey, Key.parse("hyper+a"));
    try testing.expectError(error.InvalidKey, Key.parse("f0"));
    try testing.expectError(error.InvalidKey, Key.parse("f21"));
    try testing.expectError(error.InvalidKey, Key.parse("ab"));
    try testing.expectError(error.InvalidKey, Key.parse("\x01"));
}

test "Key.printable" {
    try testing.expectEqual(@as(?u21, 'a'), (try Key.parse("a")).printable());
    try testing.expectEqual(@as(?u21, 'A'), (try Key.parse("shift+A")).printable());
    try testing.expectEqual(@as(?u21, null), (try Key.parse("ctrl+a")).printable());
    try testing.expectEqual(@as(?u21, null), (try Key.parse("enter")).printable());
}

fn expectEncoded(expected: []const u8, event: Event) !void {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try encode(&w, event);
    try testing.expectEqualStrings(expected, w.buffered());
}

test encode {
    try expectEncoded("a", .{ .key = try Key.parse("a") });
    try expectEncoded("\r", .{ .key = try Key.parse("enter") });
    try expectEncoded("\x1b[Z", .{ .key = try Key.parse("shift+tab") });
    try expectEncoded("\x1b[99;5u", .{ .key = try Key.parse("ctrl+c") });
    try expectEncoded("\x1b[1;3A", .{ .key = try Key.parse("alt+up") });
    try expectEncoded("\x1b[5~", .{ .key = try Key.parse("pgup") });
    try expectEncoded("\x1bOQ", .{ .key = try Key.parse("f2") });
    try expectEncoded("\x1b[24;2~", .{ .key = try Key.parse("shift+f12") });
    try expectEncoded("\x1b[<2;4;5m", .{
        .mouse = .{ .x = 3, .y = 4, .button = .right, .action = .release },
    });
    try expectEncoded("\x1b[200~hi\x1b[201~", .{ .paste = "hi" });
    try expectEncoded("\x1b[I", .focus_in);
}

const event_alphabet = [_][]const u8{
    "a",         "Z",         " ",
    "é",
    "中",
    "😀",
    "\r",        "\t",        "\x7f",
    "\x1b",      "\x1b[",     "\x1bO",
    "[",         "O",         "1",
    ";",         "~",         "<",
    "M",         "m",         "u",
    "\x1b[200~", "\x1b[201~", "\x00",
    "\x03",      "\xff",      "\xe4",
    "\x1b[1;5",  "\x1b[<0;1", "A",
};

test "fuzz: random bytes never crash and always drain" {
    var prng: std.Random.DefaultPrng = .init(0x1badb002);
    const random = prng.random();
    for (0..2000) |_| {
        var decoder: Decoder = .init(testing.allocator);
        defer decoder.deinit();
        for (0..random.uintLessThan(usize, 8)) |_| {
            var chunk: [16]u8 = undefined;
            const len = random.uintLessThan(usize, chunk.len);
            if (random.boolean()) {
                random.bytes(chunk[0..len]);
                try decoder.feed(chunk[0..len]);
            } else {
                try decoder.feed(event_alphabet[random.uintLessThan(usize, event_alphabet.len)]);
            }
            while (decoder.next()) |_| {}
        }
        while (decoder.flush()) |_| {}
        // Only an unfinished paste may be left over.
        if (decoder.hasPending()) try testing.expect(decoder.pasting);
    }
}

fn randomKey(random: std.Random) Key {
    const specials = [_]Key.Code{
        .enter, .tab,  .backspace, .escape, .insert, .delete,  .up,
        .down,  .left, .right,     .home,   .end,    .page_up, .page_down,
    };
    const code: Key.Code = switch (random.uintLessThan(u8, 4)) {
        0 => specials[random.uintLessThan(usize, specials.len)],
        1 => .{ .function = random.intRangeAtMost(u8, 1, 20) },
        2 => .{ .char = random.intRangeAtMost(u21, 0x20, 0x7e) },
        else => .{ .char = random.intRangeAtMost(u21, 0xa0, 0x2fff) },
    };
    var mods: Mods = @bitCast(random.int(u4));
    if (code == .char and mods.shift and code.char >= 'a' and code.char <= 'z') mods.shift = false;
    return .{ .code = code, .mods = mods };
}

fn randomEvent(random: std.Random) Event {
    return switch (random.uintLessThan(u8, 7)) {
        0, 1, 2 => .{ .key = randomKey(random) },
        3 => .{ .mouse = .{
            .x = random.int(u16) % 1000,
            .y = random.int(u16) % 1000,
            .button = random.enumValue(Mouse.Button),
            .action = random.enumValue(Mouse.Action),
            .mods = .{
                .shift = random.boolean(),
                .alt = random.boolean(),
                .ctrl = random.boolean(),
            },
        } },
        4 => .{ .paste = "pasted \x1b[A text" },
        5 => .{ .report = switch (random.uintLessThan(u8, 6)) {
            0 => .{ .foreground = .{
                .r = random.int(u8),
                .g = random.int(u8),
                .b = random.int(u8),
            } },
            1 => .{ .background = .{
                .r = random.int(u8),
                .g = random.int(u8),
                .b = random.int(u8),
            } },
            2 => .{ .mode = .{
                .mode = random.int(u16),
                .status = random.enumValue(Report.ModeStatus),
            } },
            3 => .{ .kitty_keyboard = random.int(u8) },
            4 => .{ .cursor = .{ .row = random.int(u16) % 999, .column = random.int(u16) % 999 } },
            else => .device_attributes,
        } },
        else => if (random.boolean()) .focus_in else .focus_out,
    };
}

test "fuzz: random events round-trip through encode and decode" {
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const random = prng.random();
    var decoder: Decoder = .init(testing.allocator);
    defer decoder.deinit();
    for (0..5000) |_| {
        const event = randomEvent(random);
        var buffer: [64]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try encode(&w, event);
        // Split the bytes at a random point to exercise partial sequences.
        const split = random.uintLessThan(usize, w.end + 1);
        try decoder.feed(w.buffered()[0..split]);
        var got = decoder.next();
        if (got == null) {
            try decoder.feed(w.buffered()[split..]);
            got = decoder.next() orelse decoder.flush();
        } else {
            try testing.expectEqual(w.end, split);
        }
        const decoded = got orelse return error.TestUnexpectedResult;
        switch (event) {
            .paste => |text| try testing.expectEqualStrings(text, decoded.paste),
            else => testing.expectEqualDeep(event, decoded) catch |err| {
                std.debug.print("bytes {any}\n", .{w.buffered()});
                return err;
            },
        }
        try testing.expectEqual(null, decoder.next());
        try testing.expect(!decoder.hasPending());
    }
}
