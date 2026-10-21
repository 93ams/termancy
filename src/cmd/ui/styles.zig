//! The style flags the gum-style commands share, as gum's `style.Styles`: one group per
//! part of a component, spelled with a dot (`--cursor.foreground 212`, `--header.bold`),
//! and the same fields at the top level for `ui style`.
//!
//! ```zig
//! const Flags = struct { cursor_style: styles.Styles = .{} };
//! const flags_flags = cli.flags(Flags, field.Set(.{styles.spec}), .{ .fields = .{
//!     .cursor_style = styles.group("cursor"),
//! } });
//! // in run: the theme's accent unless the flags say otherwise
//! list.styles.cursor = flags.cursor_style.over(ctx.theme.accent);
//! ```
//!
//! A field not given keeps the part's own default (`over`), so the defaults come from where
//! the group is used, from `cli.Theme`. As in gum, help shows a group's colors and hides
//! the rest, which still work.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");

/// Space around text: one number for all sides, two for vertical and horizontal, or four
/// for top, right, bottom, and left (as in CSS), separated by spaces or commas.
pub const Spacing = struct {
    sides: tui.Style.Sides = .{},

    pub fn parse(text: []const u8) error{InvalidSpacing}!Spacing {
        var numbers: [4]usize = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, text, " ,");
        while (it.next()) |part| : (count += 1) {
            if (count == numbers.len) return error.InvalidSpacing;
            numbers[count] = std.fmt.parseInt(usize, part, 10) catch return error.InvalidSpacing;
        }
        return switch (count) {
            1 => .{ .sides = .all(numbers[0]) },
            2 => .{ .sides = .symmetric(numbers[0], numbers[1]) },
            4 => .{ .sides = .{
                .top = numbers[0],
                .right = numbers[1],
                .bottom = numbers[2],
                .left = numbers[3],
            } },
            else => error.InvalidSpacing,
        };
    }

    /// The shortest text `parse` reads back as the same spacing.
    pub fn format(spacing: Spacing, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = spacing.sides;
        if (s.top == s.bottom and s.left == s.right) {
            if (s.top == s.left) return w.print("{d}", .{s.top});
            return w.print("{d} {d}", .{ s.top, s.left });
        }
        try w.print("{d} {d} {d} {d}", .{ s.top, s.right, s.bottom, s.left });
    }
};

pub const Border = enum { none, normal, rounded, thick, double, hidden, ascii };

pub const Align = enum { left, center, right };

/// The style of one part of a component; each field given replaces the part's default.
pub const Styles = struct {
    foreground: ?tui.Color = null,
    background: ?tui.Color = null,
    border: ?Border = null,
    border_foreground: ?tui.Color = null,
    border_background: ?tui.Color = null,
    @"align": ?Align = null,
    width: ?usize = null,
    height: ?usize = null,
    margin: ?Spacing = null,
    padding: ?Spacing = null,
    bold: ?bool = null,
    faint: ?bool = null,
    italic: ?bool = null,
    strikethrough: ?bool = null,
    underline: ?bool = null,

    /// `base` with the fields given here in place of its own. Colors and attributes apply
    /// wherever the part is drawn; border, padding, margin, size, and alignment only where
    /// it is a block of its own (a header, say), not a span in a line.
    pub fn over(s: Styles, base: tui.Style) tui.Style {
        var style = base;
        if (s.foreground) |color| style.fg = color;
        if (s.background) |color| style.bg = color;
        if (s.border) |border| style.border = switch (border) {
            .none => null,
            inline else => |tag| @field(tui.Style.Border, @tagName(tag)),
        };
        if (s.border_foreground) |color| style.border_fg = color;
        if (s.border_background) |color| style.border_bg = color;
        if (s.@"align") |a| style.@"align" = switch (a) {
            .left => .start,
            .center => .center,
            .right => .end,
        };
        if (s.width) |width| style.width = width;
        if (s.height) |height| style.height = height;
        if (s.margin) |margin| style.margin = margin.sides;
        if (s.padding) |padding| style.padding = padding.sides;
        if (s.bold) |on| style.bold = on;
        if (s.faint) |on| style.dim = on;
        if (s.italic) |on| style.italic = on;
        if (s.strikethrough) |on| style.strikethrough = on;
        if (s.underline) |on| style.underline = on;
        return style;
    }
};

/// `text` laid out in `style` (border, padding, and the rest), for a part a component
/// paints as one span, such as a header: given the result, it paints it unstyled.
pub fn render(
    arena: std.mem.Allocator,
    style: tui.Style,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (text.len == 0) return text;
    var out: std.Io.Writer.Allocating = .init(arena);
    style.render(&out.writer, text) catch return error.OutOfMemory;
    return out.written();
}

const color_help = " (0-255, #rrggbb, or a name such as red or bright-blue)";

/// What the fields mean; put it in the command's `field.Set`.
pub const spec: field.Spec(Styles) = .{ .fields = .{
    .foreground = .{ .help = "Text color" ++ color_help },
    .background = .{ .help = "Background color" ++ color_help },
    .border = .{ .help = "Border style: none, normal, rounded, thick, double, hidden, or ascii" },
    .border_foreground = .{ .help = "Border color" },
    .border_background = .{ .help = "Border background color" },
    .@"align" = .{ .help = "Alignment of lines narrower than the block" },
    .width = .{ .help = "Columns, padding included; longer lines are wrapped" },
    .height = .{ .help = "The fewest rows, padding included" },
    .margin = .{ .help = "Space outside the border, as --padding" },
    .padding = .{ .help = "Space inside the border: \"1\", \"1 2\", or \"1 2 1 2\"" },
    .bold = .{ .help = "Bold text" },
    .faint = .{ .help = "Dim text" },
    .italic = .{ .help = "Italic text" },
    .strikethrough = .{ .help = "Struck-through text" },
    .underline = .{ .help = "Underlined text" },
} };

/// The fields at the top level, all in help: `ui style --foreground 212`.
pub const top: cli.GroupPlace(Styles) = .{ .name = "", .fields = .{
    .border = .{ .value_name = "style" },
} };

/// A part's group, as gum spells it: `--<name>.foreground`, help showing only the colors.
pub fn group(comptime name: []const u8) cli.GroupPlace(Styles) {
    const hide: @FieldType(cli.GroupPlace(Styles), "fields") = .{
        .border = .{ .hidden = true, .value_name = "style" },
        .border_foreground = .{ .hidden = true },
        .border_background = .{ .hidden = true },
        .@"align" = .{ .hidden = true },
        .width = .{ .hidden = true },
        .height = .{ .hidden = true },
        .margin = .{ .hidden = true },
        .padding = .{ .hidden = true },
        .bold = .{ .hidden = true },
        .faint = .{ .hidden = true },
        .italic = .{ .hidden = true },
        .strikethrough = .{ .hidden = true },
        .underline = .{ .hidden = true },
    };
    return .{ .name = name, .separator = ".", .fields = hide };
}

/// `group`, all hidden, as gum hides `--item.*`.
pub fn hiddenGroup(comptime name: []const u8) cli.GroupPlace(Styles) {
    var place = group(name);
    place.hidden = true;
    return place;
}

const testing = std.testing;

test "Spacing.parse" {
    try testing.expectEqual(tui.Style.Sides.all(2), (try Spacing.parse("2")).sides);
    try testing.expectEqual(tui.Style.Sides.symmetric(1, 3), (try Spacing.parse("1 3")).sides);
    const four = (try Spacing.parse("1,2, 3 4")).sides;
    try testing.expectEqual(tui.Style.Sides{ .top = 1, .right = 2, .bottom = 3, .left = 4 }, four);
    try testing.expectError(error.InvalidSpacing, Spacing.parse(""));
    try testing.expectError(error.InvalidSpacing, Spacing.parse("1 2 3"));
    try testing.expectError(error.InvalidSpacing, Spacing.parse("1 2 3 4 5"));
    try testing.expectError(error.InvalidSpacing, Spacing.parse("x"));
}

test "Spacing.format" {
    var buffer: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f}|{f}|{f}", .{
        Spacing{},
        try Spacing.parse("1 2"),
        try Spacing.parse("1 2 3 4"),
    });
    try testing.expectEqualStrings("0|1 2|1 2 3 4", w.buffered());
}

test "Styles.over: what is given replaces the default" {
    const base: tui.Style = .{ .fg = .magenta, .bold = true, .italic = true };
    const style = (Styles{
        .background = .red,
        .border = .rounded,
        .@"align" = .right,
        .padding = .{ .sides = .symmetric(0, 1) },
        .bold = false,
        .faint = true,
    }).over(base);
    try testing.expectEqual(tui.Color.magenta, style.fg);
    try testing.expectEqual(tui.Color.red, style.bg);
    try testing.expectEqualStrings("╭", style.border.?.top_left);
    try testing.expectEqual(tui.layout.Position.end, style.@"align");
    try testing.expectEqual(tui.Style.Sides.symmetric(0, 1), style.padding);
    try testing.expect(!style.bold and style.dim and style.italic);
    try testing.expectEqual(base, (Styles{}).over(base));
    try testing.expectEqual(null, (Styles{ .border = .none }).over(.{ .border = .ascii }).border);
}

const Part = struct { cursor_style: Styles = .{}, item_style: Styles = .{} };

test "a group: dotted, variables under the command's prefix, colors shown" {
    const set = cli.flags(Part, field.Set(.{spec}), .{ .env_prefix = "APP_", .fields = .{
        .cursor_style = group("cursor"),
        .item_style = hiddenGroup("item"),
    } });
    const fg = set.list[0];
    try testing.expectEqualStrings("cursor.foreground", fg.name);
    try testing.expectEqualStrings("APP_CURSOR_FOREGROUND", fg.env.?);
    try testing.expectEqualStrings("color", fg.value_name);
    try testing.expect(!fg.hidden and !set.list[1].hidden);
    try testing.expectEqualStrings("cursor.border-foreground", set.list[3].name);
    try testing.expectEqualStrings("APP_CURSOR_BORDER_FOREGROUND", set.list[3].env.?);
    for (set.list[2..15]) |f| try testing.expect(f.hidden);
    for (set.list[15..]) |f| try testing.expect(f.hidden);
    try testing.expectEqualStrings("style", set.list[2].value_name);
}
