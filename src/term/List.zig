//! A list drawn as text, as Lip Gloss's `list`: items with a bullet, a number, a letter,
//! or a roman numeral, lists nested in lists, and styles for the marks and the items.
//! Items of several lines keep their lines under the first.
//!
//! ```zig
//! const list: term.List = .{ .items = &.{ .{ .text = "Glossier" }, .{ .text = "Claire's" } } };
//! try list.render(w);
//! ```

const std = @import("std");
const Writer = std.Io.Writer;
const display = @import("width.zig");
const Style = @import("Style.zig");

const List = @This();

items: []const Item,
enumerator: Enumerator = .bullet,
/// The marks' style.
enumerator_style: Style = .{},
/// The items' style (applied to each line).
item_style: Style = .{},
/// Columns a nested list starts to the right of where its parent's text starts.
indent: usize = 0,

/// An entry: text, or a list nested under the item before it.
pub const Item = union(enum) {
    text: []const u8,
    /// A list under the item before it.
    list: *const List,
};

/// How items are marked.
pub const Enumerator = union(enum) {
    /// `•`
    bullet,
    /// `-`
    dash,
    /// `*`
    asterisk,
    /// `1.`, `2.`, ...
    arabic,
    /// `a.`, `b.`, ... `aa.`
    alphabet,
    /// `I.`, `II.`, ...
    roman,
    /// No mark.
    none,
    /// The same mark for every item.
    custom: []const u8,

    /// Writes the mark of item `index` (0-based).
    pub fn write(e: Enumerator, w: *Writer, index: usize) Writer.Error!void {
        switch (e) {
            .bullet => try w.writeAll("•"),
            .dash => try w.writeAll("-"),
            .asterisk => try w.writeAll("*"),
            .arabic => try w.print("{d}.", .{index + 1}),
            .alphabet => {
                var letters: [8]u8 = undefined;
                var n = index;
                var len: usize = 0;
                while (true) {
                    letters[letters.len - 1 - len] = 'a' + @as(u8, @intCast(n % 26));
                    len += 1;
                    if (n < 26) break;
                    n = n / 26 - 1;
                }
                try w.writeAll(letters[letters.len - len ..]);
                try w.writeByte('.');
            },
            .roman => {
                try writeRoman(w, index + 1);
                try w.writeByte('.');
            },
            .none => {},
            .custom => |mark| try w.writeAll(mark),
        }
    }
};

fn writeRoman(w: *Writer, value: usize) Writer.Error!void {
    const numerals = [_]struct { usize, []const u8 }{
        .{ 1000, "M" }, .{ 900, "CM" }, .{ 500, "D" }, .{ 400, "CD" }, .{ 100, "C" },
        .{ 90, "XC" },  .{ 50, "L" },   .{ 40, "XL" }, .{ 10, "X" },   .{ 9, "IX" },
        .{ 5, "V" },    .{ 4, "IV" },   .{ 1, "I" },
    };
    var rest = value;
    for (numerals) |numeral| {
        while (rest >= numeral[0]) : (rest -= numeral[0]) try w.writeAll(numeral[1]);
    }
}

/// Writes the list, lines separated by `\n`.
pub fn render(l: List, w: *Writer) Writer.Error!void {
    var first = true;
    try l.renderAt(w, 0, &first);
}

fn renderAt(l: List, w: *Writer, depth: usize, first: *bool) Writer.Error!void {
    // Marks are right-aligned in a column as wide as the widest (`9.` and `10.`).
    var widest: usize = 0;
    var count: usize = 0;
    for (l.items) |item| if (item == .text) {
        var buffer: [32]u8 = undefined;
        var mark: Writer = .fixed(&buffer);
        l.enumerator.write(&mark, count) catch {};
        widest = @max(widest, display.of(mark.buffered()));
        count += 1;
    };
    var index: usize = 0;
    for (l.items) |item| switch (item) {
        .list => |child| {
            const under_text = depth + widest + @intFromBool(widest > 0);
            try child.renderAt(w, under_text + l.indent, first);
        },
        .text => |text| {
            var buffer: [32]u8 = undefined;
            var mark: Writer = .fixed(&buffer);
            l.enumerator.write(&mark, index) catch {};
            index += 1;
            var lines = std.mem.splitScalar(u8, text, '\n');
            var line_number: usize = 0;
            while (lines.next()) |line| : (line_number += 1) {
                if (!first.*) try w.writeByte('\n');
                first.* = false;
                try w.splatByteAll(' ', depth);
                if (line_number == 0) {
                    try w.splatByteAll(' ', widest - display.of(mark.buffered()));
                    try l.enumerator_style.paint(w, mark.buffered());
                } else {
                    try w.splatByteAll(' ', widest);
                }
                if (widest > 0) try w.writeByte(' ');
                try l.item_style.paint(w, line);
            }
        },
    };
}

/// `render` into memory the caller owns.
pub fn renderAlloc(l: List, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    l.render(&out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

fn expectList(expected: []const u8, list: List) !void {
    const text = try list.renderAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "bullets, nesting, and lines under the first" {
    const fruit: List = .{
        .items = &.{ .{ .text = "apple" }, .{ .text = "pear" } },
        .enumerator = .dash,
    };
    try expectList(
        \\• fruit
        \\  - apple
        \\  - pear
        \\• two
        \\  lines
    , .{ .items = &.{ .{ .text = "fruit" }, .{ .list = &fruit }, .{ .text = "two\nlines" } } });
}

test "numbers align on the right; letters and roman numerals" {
    var items: [10]Item = undefined;
    for (&items) |*item| item.* = .{ .text = "x" };
    const list: List = .{ .items = &items, .enumerator = .arabic };
    const numbered = try list.renderAlloc(testing.allocator);
    defer testing.allocator.free(numbered);
    try testing.expect(std.mem.startsWith(u8, numbered, " 1. x\n 2. x"));
    try testing.expect(std.mem.endsWith(u8, numbered, "10. x"));
    var buffer: [16]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try (Enumerator{ .alphabet = {} }).write(&w, 27);
    try w.writeByte(' ');
    try (Enumerator{ .roman = {} }).write(&w, 13);
    try testing.expectEqualStrings("ab. XIV.", w.buffered());
}
