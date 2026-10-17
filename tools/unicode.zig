//! Generates `src/term/unicode_tables.zig` from the Unicode Character Database: each
//! codepoint's grapheme break property, Extended_Pictographic, Indic conjunct break, and
//! display width, as a three-stage table. Run after downloading a new UCD release:
//!
//!     zig run tools/unicode.zig -- <ucd> 17.0.0 > src/term/unicode_tables.zig
//!     zig fmt src/term/unicode_tables.zig
//!
//! where `<ucd>` holds `auxiliary/GraphemeBreakProperty.txt`, `emoji/emoji-data.txt`,
//! `EastAsianWidth.txt`, `DerivedCoreProperties.txt`, and
//! `extracted/DerivedGeneralCategory.txt` (laid out as on unicode.org), and copy
//! `auxiliary/GraphemeBreakTest.txt` to `src/term/testdata/` for the tests.
//!
//! Widths, the way terminals draw them: 0 for controls, combining and enclosing marks,
//! format characters (but the soft hyphen), default-ignorable codepoints, and Hangul medial
//! and final jamo; 2 for East Asian Wide and Fullwidth, and emoji presented as emoji (but a
//! lone regional indicator); 1 for everything else, East Asian Ambiguous included.

const std = @import("std");
const Io = std.Io;

const count = 0x110000;

/// The grapheme break property values, in the order `term.width` numbers them.
const gcb_names = [_][]const u8{
    "Other",              "CR",      "LF",          "Control", "Extend", "ZWJ",
    "Regional_Indicator", "Prepend", "SpacingMark", "L",       "V",      "T",
    "LV",                 "LVT",
};

const incb_names = [_][]const u8{ "None", "Linker", "Consonant", "Extend" };

const Props = struct {
    gcb: u4 = 0,
    pictographic: bool = false,
    incb: u2 = 0,
    width: u2 = 1,

    fn pack(p: Props) u16 {
        return @as(u16, p.gcb) | @as(u16, @intFromBool(p.pictographic)) << 4 |
            @as(u16, p.incb) << 5 | @as(u16, p.width) << 7;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: zig run tools/unicode.zig -- <ucd directory> <version>\n", .{});
        std.process.exit(2);
    }
    var dir = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);
    const version = args[2];

    const props = try arena.alloc(Props, count);
    @memset(props, .{});
    const wide = try arena.alloc(bool, count);
    @memset(wide, false);
    const zero = try arena.alloc(bool, count);
    @memset(zero, false);

    // Grapheme break property.
    var lines = try fileLines(io, arena, dir, "auxiliary/GraphemeBreakProperty.txt");
    while (lines.next()) |line| {
        const entry = parseLine(line) orelse continue;
        const value = indexOf(&gcb_names, entry.fields[0]) orelse return error.UnknownValue;
        for (entry.first..entry.last + 1) |cp| props[cp].gcb = @intCast(value);
    }
    // Extended_Pictographic, and Emoji_Presentation, which makes a codepoint wide.
    lines = try fileLines(io, arena, dir, "emoji/emoji-data.txt");
    while (lines.next()) |line| {
        const entry = parseLine(line) orelse continue;
        const name = entry.fields[0];
        for (entry.first..entry.last + 1) |cp| {
            if (std.mem.eql(u8, name, "Extended_Pictographic")) props[cp].pictographic = true;
            if (std.mem.eql(u8, name, "Emoji_Presentation")) wide[cp] = true;
        }
    }
    // East Asian Wide and Fullwidth: the defaults of the `@missing` lines (wide for the
    // unassigned codepoints of the CJK blocks), then the listed codepoints.
    const eaw = try arena.alloc(bool, count);
    @memset(eaw, false);
    const eaw_text = try dir.readFileAlloc(io, "EastAsianWidth.txt", arena, .unlimited);
    for ([_]bool{ true, false }) |missing_pass| {
        lines = std.mem.splitScalar(u8, eaw_text, '\n');
        while (lines.next()) |raw| {
            const missing = std.mem.startsWith(u8, raw, "# @missing: ");
            if (missing != missing_pass) continue;
            const entry = parseLine(if (missing) raw["# @missing: ".len..] else raw) orelse
                continue;
            const value = entry.fields[0];
            const is_wide = std.mem.eql(u8, value, "W") or std.mem.eql(u8, value, "F");
            for (entry.first..entry.last + 1) |cp| eaw[cp] = is_wide;
        }
    }
    for (wide, eaw) |*w, e| w.* = w.* or e;
    // Indic conjunct break, and default-ignorable codepoints.
    lines = try fileLines(io, arena, dir, "DerivedCoreProperties.txt");
    while (lines.next()) |line| {
        const entry = parseLine(line) orelse continue;
        const name = entry.fields[0];
        if (std.mem.eql(u8, name, "InCB")) {
            if (entry.fields.len < 2) return error.MissingValue;
            const value = indexOf(&incb_names, entry.fields[1]) orelse return error.UnknownValue;
            for (entry.first..entry.last + 1) |cp| props[cp].incb = @intCast(value);
        } else if (std.mem.eql(u8, name, "Default_Ignorable_Code_Point")) {
            for (entry.first..entry.last + 1) |cp| zero[cp] = true;
        }
    }
    // General categories with no width.
    lines = try fileLines(io, arena, dir, "extracted/DerivedGeneralCategory.txt");
    while (lines.next()) |line| {
        const entry = parseLine(line) orelse continue;
        const gc = entry.fields[0];
        const none = std.mem.eql(u8, gc, "Mn") or std.mem.eql(u8, gc, "Me") or
            std.mem.eql(u8, gc, "Cf") or std.mem.eql(u8, gc, "Cc");
        if (none) for (entry.first..entry.last + 1) |cp| {
            zero[cp] = true;
        };
    }
    zero[0xad] = false; // the soft hyphen shows as a hyphen

    for (props, 0..) |*p, cp| {
        const jamo = p.gcb == indexOf(&gcb_names, "V").? or p.gcb == indexOf(&gcb_names, "T").?;
        // A regional indicator is narrow alone; a pair of them, a flag, is one wide cluster.
        const indicator = p.gcb == indexOf(&gcb_names, "Regional_Indicator").?;
        p.width = if (wide[cp] and !indicator) 2 else if (zero[cp] or jamo) 0 else 1;
    }

    // Three stages: blocks of 256 codepoints, deduplicated; each entry an index into the
    // distinct property values.
    var values: std.ArrayList(u16) = .empty;
    var value_index: std.AutoHashMapUnmanaged(u16, u8) = .empty;
    var blocks: std.ArrayList([256]u8) = .empty;
    var block_index: std.AutoHashMapUnmanaged([256]u8, u8) = .empty;
    var stage1: [count / 256]u8 = undefined;
    for (&stage1, 0..) |*slot, b| {
        var block: [256]u8 = undefined;
        for (&block, 0..) |*entry, i| {
            const packed_props = props[b * 256 + i].pack();
            const got = try value_index.getOrPut(arena, packed_props);
            if (!got.found_existing) {
                if (values.items.len == 256) return error.TooManyValues;
                got.value_ptr.* = @intCast(values.items.len);
                try values.append(arena, packed_props);
            }
            entry.* = got.value_ptr.*;
        }
        const got = try block_index.getOrPut(arena, block);
        if (!got.found_existing) {
            if (blocks.items.len == 256) return error.TooManyBlocks;
            got.value_ptr.* = @intCast(blocks.items.len);
            try blocks.append(arena, block);
        }
        slot.* = got.value_ptr.*;
    }

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const w = &stdout.interface;
    try w.print(
        \\//! Generated by `zig run tools/unicode.zig`; do not edit. From the Unicode Character
        \\//! Database {s} (© Unicode, Inc., under the Unicode License v3). See `width.zig`.
        \\
        \\/// The Unicode version these tables come from.
        \\pub const version = "{s}";
        \\
        \\/// The block of `stage2` that codepoint `cp` is in: `stage1[cp >> 8]`.
        \\pub const stage1 = [{d}]u8{{
        \\
    , .{ version, version, stage1.len });
    try writeBytes(w, &stage1);
    try w.print("}};\n\n/// Blocks of 256 entries, each an index into `values`.\n", .{});
    try w.print("pub const stage2 = [{d}]u8{{\n", .{blocks.items.len * 256});
    for (blocks.items) |*block| try writeBytes(w, block);
    try w.writeAll(
        \\};
        \\
        \\/// Packed properties: bits 0-3 the grapheme break property, 4 Extended_Pictographic,
        \\/// 5-6 the Indic conjunct break, 7-8 the width.
        \\
    );
    try w.print("pub const values = [{d}]u16{{\n", .{values.items.len});
    for (values.items, 0..) |value, i| {
        try w.print("{s}0x{x:0>3},", .{ if (i % 12 == 0) "    " else " ", value });
        if (i % 12 == 11 or i + 1 == values.items.len) try w.writeByte('\n');
    }
    try w.writeAll("};\n");
    try w.flush();
}

fn writeBytes(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    for (bytes, 0..) |byte, i| {
        try w.print("{s}{d},", .{ if (i % 16 == 0) "    " else " ", byte });
        if (i % 16 == 15 or i + 1 == bytes.len) try w.writeByte('\n');
    }
}

fn fileLines(
    io: Io,
    arena: std.mem.Allocator,
    dir: Io.Dir,
    path: []const u8,
) !std.mem.SplitIterator(u8, .scalar) {
    const text = try dir.readFileAlloc(io, path, arena, .unlimited);
    return std.mem.splitScalar(u8, text, '\n');
}

const Entry = struct {
    first: u21,
    last: u21,
    fields: []const []const u8,
};

var field_storage: [4][]const u8 = undefined;

/// `0041..005A ; Name ; Value # comment`, or null for a comment or blank line.
fn parseLine(line: []const u8) ?Entry {
    const data = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse
        line.len], " \t\r");
    if (data.len == 0) return null;
    var parts = std.mem.splitScalar(u8, data, ';');
    const range = std.mem.trim(u8, parts.next().?, " ");
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) field_storage[n] = std.mem.trim(u8, part, " ");
    const dots = std.mem.indexOf(u8, range, "..");
    const first = std.fmt.parseInt(u21, range[0 .. dots orelse range.len], 16) catch return null;
    const last = if (dots) |d|
        std.fmt.parseInt(u21, range[d + 2 ..], 16) catch return null
    else
        first;
    return .{ .first = first, .last = last, .fields = field_storage[0..n] };
}

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, i| if (std.mem.eql(u8, candidate, name)) return i;
    return null;
}
