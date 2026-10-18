//! A parser for what terminals receive: text and escape sequences, byte by byte, as the
//! DEC VT500 state machine describes them (Paul Williams' diagram, as xterm, VTE, and
//! kitty implement it). It decodes UTF-8 and calls a handler for each action:
//!
//! | method | for |
//! |---|---|
//! | `print(cp: u21)` | a printable codepoint (U+FFFD for a malformed byte) |
//! | `execute(byte: u8)` | a C0 or C1 control: `\n`, `\r`, BEL, BS, ... |
//! | `csi(seq: Csi)` | `ESC [ ... final`: cursor movement, erasing, SGR, modes |
//! | `esc(seq: Esc)` | `ESC final`: save cursor, index, character sets |
//! | `osc(data: []const u8)` | `ESC ] ... ST`: titles, hyperlinks, colors, clipboard |
//! | `dcs(seq: Dcs)` | `ESC P ... ST`: device control strings |
//! | `apc(data: []const u8)` | `ESC _ ... ST` (and PM, SOS): kitty graphics |
//!
//! Each method is optional: a handler declares the ones it wants. The parser keeps no
//! clock and allocates nothing; a sequence split across `feed` calls is completed by the
//! next call. Strings (OSC, DCS, APC) longer than `max_string` are cut to that length.
//!
//! ```zig
//! var parser: term.Parser = .{};
//! parser.feed("\x1b[1;31mhi\x1b[0m", &handler);
//! ```

const std = @import("std");

const Parser = @This();

state: State = .ground,
/// The private marker of the sequence being read (`?` in `CSI ? 25 h`), or 0.
private: u8 = 0,
intermediates: [max_intermediates]u8 = undefined,
intermediate_len: u8 = 0,
params: [max_params]Param = undefined,
param_len: u8 = 0,
/// Digits seen for the parameter being read.
param_open: bool = false,
/// The sequence had more intermediates or parameters than fit: it is ignored.
overflow: bool = false,
/// The body of an OSC, DCS, APC, PM, or SOS string.
string: [max_string]u8 = undefined,
string_len: usize = 0,
/// Which string is being read.
string_kind: StringKind = .osc,
/// A DCS's final byte, once seen.
dcs_final: u8 = 0,
/// An ESC inside a string, which ends it if `\` follows.
string_escape: bool = false,
/// UTF-8 bytes of a codepoint being decoded.
utf8: [4]u8 = undefined,
utf8_len: u3 = 0,
utf8_need: u3 = 0,

/// The most parameters a sequence keeps; xterm's limit is 30.
pub const max_params = 32;
/// The most intermediate bytes a sequence keeps.
pub const max_intermediates = 2;
/// The longest string kept; the rest is dropped.
pub const max_string = 8192;

/// Where the parser is in a sequence (the states of the VT500 diagram).
pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_string,
    dcs_ignore,
    string,
};

const StringKind = enum { osc, dcs, apc, pm, sos };

/// One parameter: its value (null when empty, for the default), and whether a
/// subparameter (`:`) follows it, as in `38:2::255:0:0`.
pub const Param = struct {
    value: ?u16,
    more: bool = false,
};

/// A control sequence: `ESC [ private params intermediates final`.
pub const Csi = struct {
    private: u8,
    intermediates: []const u8,
    params: []const Param,
    final: u8,

    /// Parameter `i`, or `default` when it is missing or empty. Counts top-level
    /// parameters only, skipping subparameters.
    pub fn param(seq: Csi, i: usize, default: u16) u16 {
        var n: usize = 0;
        var at: usize = 0;
        while (at < seq.params.len) : (at += 1) {
            if (n == i) return seq.params[at].value orelse default;
            while (at < seq.params.len and seq.params[at].more) at += 1;
            n += 1;
        }
        return default;
    }

    /// How many top-level parameters there are.
    pub fn count(seq: Csi) usize {
        var n: usize = 0;
        for (seq.params) |p| {
            if (!p.more) n += 1;
        }
        return n;
    }

    /// Whether this is `CSI [private] ... final` with exactly these intermediates.
    pub fn is(seq: Csi, private: u8, intermediates: []const u8, final: u8) bool {
        return seq.private == private and seq.final == final and
            std.mem.eql(u8, seq.intermediates, intermediates);
    }
};

/// An escape sequence: `ESC intermediates final`.
pub const Esc = struct {
    intermediates: []const u8,
    final: u8,
};

/// A device control string: `ESC P private params intermediates final data ST`.
pub const Dcs = struct {
    private: u8,
    intermediates: []const u8,
    params: []const Param,
    final: u8,
    data: []const u8,
};

/// Parses `bytes`, calling `handler`'s methods (see the file header).
pub fn feed(p: *Parser, bytes: []const u8, handler: anytype) void {
    for (bytes) |byte| p.step(byte, handler);
}

/// Back to the ground state, dropping any sequence half read.
pub fn reset(p: *Parser) void {
    p.* = .{};
}

fn step(p: *Parser, byte: u8, handler: anytype) void {
    if (p.utf8_need > 0) return p.continueUtf8(byte, handler);
    // Anywhere: CAN and SUB abort a sequence, ESC starts one. In a string, ESC may be the
    // start of ST.
    if (p.state == .string or p.state == .dcs_string or p.state == .dcs_ignore) {
        return p.stringByte(byte, handler);
    }
    switch (byte) {
        0x18, 0x1a => {
            p.state = .ground;
            return call(handler, "execute", .{byte});
        },
        0x1b => return p.enter(.escape),
        else => {},
    }
    switch (p.state) {
        .ground => p.ground(byte, handler),
        .escape => p.escape(byte, handler),
        .escape_intermediate => p.escapeIntermediate(byte, handler),
        .csi_entry, .csi_param, .csi_intermediate, .csi_ignore => p.csiByte(byte, handler),
        .dcs_entry, .dcs_param, .dcs_intermediate => p.dcsHeader(byte),
        .string, .dcs_string, .dcs_ignore => unreachable,
    }
}

fn enter(p: *Parser, state: State) void {
    p.state = state;
    p.private = 0;
    p.intermediate_len = 0;
    p.param_len = 0;
    p.param_open = false;
    p.overflow = false;
    p.string_len = 0;
    p.string_escape = false;
}

fn ground(p: *Parser, byte: u8, handler: anytype) void {
    if (byte < 0x20 or byte == 0x7f) {
        if (byte != 0x7f) call(handler, "execute", .{byte});
        return;
    }
    if (byte < 0x80) return call(handler, "print", .{@as(u21, byte)});
    const len = std.unicode.utf8ByteSequenceLength(byte) catch {
        return call(handler, "print", .{@as(u21, 0xfffd)});
    };
    p.utf8[0] = byte;
    p.utf8_len = 1;
    p.utf8_need = len - 1;
}

fn continueUtf8(p: *Parser, byte: u8, handler: anytype) void {
    if (byte & 0xc0 != 0x80) {
        // Not a continuation: the codepoint was malformed; this byte starts afresh.
        p.utf8_need = 0;
        call(handler, "print", .{@as(u21, 0xfffd)});
        return p.step(byte, handler);
    }
    p.utf8[p.utf8_len] = byte;
    p.utf8_len += 1;
    p.utf8_need -= 1;
    if (p.utf8_need > 0) return;
    const cp = std.unicode.utf8Decode(p.utf8[0..p.utf8_len]) catch 0xfffd;
    call(handler, "print", .{cp});
}

fn escape(p: *Parser, byte: u8, handler: anytype) void {
    switch (byte) {
        0x00...0x17, 0x19, 0x1c...0x1f => call(handler, "execute", .{byte}),
        0x20...0x2f => {
            p.collect(byte);
            p.state = .escape_intermediate;
        },
        '[' => p.enter(.csi_entry),
        ']' => p.startString(.osc),
        'P' => p.enter(.dcs_entry),
        '_' => p.startString(.apc),
        '^' => p.startString(.pm),
        'X' => p.startString(.sos),
        0x7f => {},
        else => {
            p.state = .ground;
            call(handler, "esc", .{Esc{ .intermediates = &.{}, .final = byte }});
        },
    }
}

fn escapeIntermediate(p: *Parser, byte: u8, handler: anytype) void {
    switch (byte) {
        0x00...0x17, 0x19, 0x1c...0x1f => call(handler, "execute", .{byte}),
        0x20...0x2f => p.collect(byte),
        0x7f => {},
        else => {
            p.state = .ground;
            if (p.overflow) return;
            call(handler, "esc", .{Esc{
                .intermediates = p.intermediates[0..p.intermediate_len],
                .final = byte,
            }});
        },
    }
}

fn collect(p: *Parser, byte: u8) void {
    if (p.intermediate_len == max_intermediates) {
        p.overflow = true;
        return;
    }
    p.intermediates[p.intermediate_len] = byte;
    p.intermediate_len += 1;
}

/// Digits, `;`, and `:` of a parameter list.
fn paramByte(p: *Parser, byte: u8) void {
    switch (byte) {
        '0'...'9' => {
            if (!p.param_open) {
                if (p.param_len == max_params) {
                    p.overflow = true;
                    return;
                }
                p.params[p.param_len] = .{ .value = null };
                p.param_len += 1;
                p.param_open = true;
            }
            const param = &p.params[p.param_len - 1];
            const digit = byte - '0';
            const value: u32 = @as(u32, param.value orelse 0) * 10 + digit;
            param.value = @intCast(@min(value, std.math.maxInt(u16)));
        },
        ';', ':' => {
            if (!p.param_open) {
                if (p.param_len == max_params) {
                    p.overflow = true;
                    return;
                }
                p.params[p.param_len] = .{ .value = null };
                p.param_len += 1;
            }
            p.params[p.param_len - 1].more = byte == ':';
            p.param_open = false;
        },
        else => unreachable,
    }
}

/// The parameters as read; a trailing separator adds an empty last parameter.
fn finishParams(p: *Parser) []const Param {
    if (p.param_len > 0 and !p.param_open) {
        const last = p.params[p.param_len - 1];
        if ((last.value != null or last.more) and p.param_len < max_params) {
            p.params[p.param_len] = .{ .value = null };
            p.param_len += 1;
        }
    }
    return p.params[0..p.param_len];
}

fn csiByte(p: *Parser, byte: u8, handler: anytype) void {
    switch (byte) {
        0x00...0x17, 0x19, 0x1c...0x1f => return call(handler, "execute", .{byte}),
        0x7f => return,
        else => {},
    }
    if (p.state == .csi_ignore) {
        if (byte >= 0x40 and byte <= 0x7e) p.state = .ground;
        return;
    }
    switch (byte) {
        '0'...'9', ';', ':' => {
            if (p.state == .csi_intermediate) {
                p.state = .csi_ignore;
                return;
            }
            p.paramByte(byte);
            p.state = .csi_param;
        },
        '<', '=', '>', '?' => {
            if (p.state != .csi_entry) {
                p.state = .csi_ignore;
                return;
            }
            p.private = byte;
            p.state = .csi_param;
        },
        0x20...0x2f => {
            p.collect(byte);
            p.state = .csi_intermediate;
        },
        0x40...0x7e => {
            p.state = .ground;
            if (p.overflow) return;
            const params = p.finishParams();
            call(handler, "csi", .{Csi{
                .private = p.private,
                .intermediates = p.intermediates[0..p.intermediate_len],
                .params = params,
                .final = byte,
            }});
        },
        else => p.state = .csi_ignore,
    }
}

fn dcsHeader(p: *Parser, byte: u8) void {
    switch (byte) {
        0x00...0x17, 0x19, 0x1c...0x1f, 0x7f => {},
        '0'...'9', ';', ':' => {
            if (p.state == .dcs_intermediate) {
                p.state = .dcs_ignore;
                return;
            }
            p.paramByte(byte);
            p.state = .dcs_param;
        },
        '<', '=', '>', '?' => {
            if (p.state != .dcs_entry) {
                p.state = .dcs_ignore;
                return;
            }
            p.private = byte;
            p.state = .dcs_param;
        },
        0x20...0x2f => {
            p.collect(byte);
            p.state = .dcs_intermediate;
        },
        0x40...0x7e => {
            _ = p.finishParams();
            p.dcs_final = byte;
            p.string_kind = .dcs;
            p.string_len = 0;
            p.string_escape = false;
            p.state = if (p.overflow) .dcs_ignore else .dcs_string;
        },
        else => p.state = .dcs_ignore,
    }
}

fn startString(p: *Parser, kind: StringKind) void {
    p.enter(.string);
    p.string_kind = kind;
}

/// A byte inside an OSC, DCS, APC, PM, or SOS string: BEL (for OSC) or ST ends it.
fn stringByte(p: *Parser, byte: u8, handler: anytype) void {
    if (p.string_escape) {
        p.string_escape = false;
        if (byte == '\\') return p.endString(handler);
        // Any other ESC aborts the string and starts a new sequence.
        p.state = .ground;
        p.step(0x1b, handler);
        return p.step(byte, handler);
    }
    switch (byte) {
        0x1b => p.string_escape = true,
        0x07 => if (p.string_kind == .osc) p.endString(handler) else p.append(byte),
        0x18, 0x1a => p.state = .ground,
        else => p.append(byte),
    }
}

fn append(p: *Parser, byte: u8) void {
    if (p.state == .dcs_ignore) return;
    if (p.string_len == max_string) return;
    p.string[p.string_len] = byte;
    p.string_len += 1;
}

fn endString(p: *Parser, handler: anytype) void {
    const ignored = p.state == .dcs_ignore;
    p.state = .ground;
    if (ignored) return;
    const data = p.string[0..p.string_len];
    switch (p.string_kind) {
        .osc => call(handler, "osc", .{data}),
        .dcs => call(handler, "dcs", .{Dcs{
            .private = p.private,
            .intermediates = p.intermediates[0..p.intermediate_len],
            .params = p.params[0..p.param_len],
            .final = p.dcs_final,
            .data = data,
        }}),
        .apc, .pm, .sos => call(handler, "apc", .{data}),
    }
}

/// Calls `handler.<name>(args)` when the handler declares it.
inline fn call(handler: anytype, comptime name: []const u8, args: anytype) void {
    const H = @typeInfo(@TypeOf(handler)).pointer.child;
    if (@hasDecl(H, name)) @call(.auto, @field(H, name), .{handler} ++ args);
}

const testing = std.testing;

/// Records every action as text, for the tests.
const Recorder = struct {
    out: std.ArrayList(u8) = .empty,

    fn deinit(r: *Recorder) void {
        r.out.deinit(testing.allocator);
    }

    fn add(r: *Recorder, comptime fmt: []const u8, args: anytype) void {
        r.out.print(testing.allocator, fmt, args) catch unreachable;
    }

    pub fn print(r: *Recorder, cp: u21) void {
        r.add("{u}", .{cp});
    }
    pub fn execute(r: *Recorder, byte: u8) void {
        r.add("<x{x:0>2}>", .{byte});
    }
    pub fn csi(r: *Recorder, seq: Csi) void {
        r.add("<csi {s}{s}", .{ if (seq.private != 0) &[_]u8{seq.private} else "", "" });
        for (seq.params, 0..) |param, i| {
            if (i > 0 and !seq.params[i - 1].more) r.add(";", .{});
            if (param.value) |v| r.add("{d}", .{v});
            if (param.more) r.add(":", .{});
        }
        r.add(" {s}{c}>", .{ seq.intermediates, seq.final });
    }
    pub fn esc(r: *Recorder, seq: Esc) void {
        r.add("<esc {s}{c}>", .{ seq.intermediates, seq.final });
    }
    pub fn osc(r: *Recorder, data: []const u8) void {
        r.add("<osc {s}>", .{data});
    }
    pub fn dcs(r: *Recorder, seq: Dcs) void {
        r.add("<dcs {s}{c} {s}>", .{ seq.intermediates, seq.final, seq.data });
    }
    pub fn apc(r: *Recorder, data: []const u8) void {
        r.add("<apc {s}>", .{data});
    }
};

fn expectParse(expected: []const u8, input: []const u8) !void {
    var r: Recorder = .{};
    defer r.deinit();
    var p: Parser = .{};
    p.feed(input, &r);
    try testing.expectEqualStrings(expected, r.out.items);
    // The same bytes fed one at a time give the same actions.
    var r2: Recorder = .{};
    defer r2.deinit();
    var p2: Parser = .{};
    for (input) |byte| p2.feed(&.{byte}, &r2);
    try testing.expectEqualStrings(expected, r2.out.items);
}

test "text, UTF-8, and controls" {
    try expectParse("hi中<x0d><x0a>", "hi中\r\n");
    try expectParse("a\u{fffd}b", "a\xffb");
    try expectParse("\u{fffd}x", "\xe4\xb8x"); // a truncated codepoint
}

test "control sequences" {
    try expectParse("<csi 1;31 m>hi<csi  m>", "\x1b[1;31mhi\x1b[m");
    try expectParse("<csi ?25 h>", "\x1b[?25h");
    try expectParse("<csi 38:2::255:0:0 m>", "\x1b[38:2::255:0:0m");
    try expectParse("<csi 2  q>", "\x1b[2 q");
    try expectParse("<csi ;5 H>", "\x1b[;5H");
    try expectParse("<csi 1; H>", "\x1b[1;H");
    // A control inside a sequence is executed and the sequence goes on.
    try expectParse("<x0a><csi 2 J>", "\x1b[2\nJ");
    // CAN aborts it.
    try expectParse("<x18>J", "\x1b[2\x18J");
}

test "escapes, strings, and malformed sequences" {
    try expectParse("<esc 7><esc (0>", "\x1b7\x1b(0");
    try expectParse("<osc 0;title>", "\x1b]0;title\x07");
    try expectParse("<osc 8;;http://x>a<osc 8;;>", "\x1b]8;;http://x\x1b\\a\x1b]8;;\x1b\\");
    try expectParse("<dcs $q m>", "\x1bP$qm\x1b\\");
    try expectParse("<apc Ga=q;AAAA>", "\x1b_Ga=q;AAAA\x1b\\");
    // A private marker after parameters makes the sequence ignored, through its final.
    try expectParse("x", "\x1b[1?hx");
    // ESC inside a string that is not ST abandons the string.
    try expectParse("<csi 1 m>", "\x1b]0;t\x1b[1m");
}

test "Csi.param counts top-level parameters" {
    const params = [_]Param{
        .{ .value = 38, .more = true },
        .{ .value = 5, .more = true },
        .{ .value = 196 },
        .{ .value = null },
        .{ .value = 4 },
    };
    const seq: Csi = .{ .private = 0, .intermediates = &.{}, .params = &params, .final = 'm' };
    try testing.expectEqual(38, seq.param(0, 0));
    try testing.expectEqual(7, seq.param(1, 7));
    try testing.expectEqual(4, seq.param(2, 0));
    try testing.expectEqual(9, seq.param(3, 9));
    try testing.expectEqual(3, seq.count());
}

test "random bytes never trip the parser" {
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    var bytes: [4096]u8 = undefined;
    for (0..50) |_| {
        random.bytes(&bytes);
        // Weight toward the bytes that drive the state machine.
        for (&bytes) |*b| if (random.boolean()) {
            b.* = "\x1b[];?:0123456789P_\\\x07mH"[random.uintLessThan(usize, 22)];
        };
        var r: Recorder = .{};
        defer r.deinit();
        var p: Parser = .{};
        p.feed(&bytes, &r);
    }
}
