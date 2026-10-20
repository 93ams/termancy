//! `termancy ui style`: print text in colors, with padding, a border, and alignment.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");

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

pub const Flags = struct {
    foreground: ?tui.Color = null,
    background: ?tui.Color = null,
    border: Border = .none,
    border_foreground: ?tui.Color = null,
    padding: Spacing = .{},
    margin: Spacing = .{},
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    @"align": Align = .left,
    width: ?usize = null,
    height: ?usize = null,
};

const color_help = " (0-255, #rrggbb, or a name such as red or bright-blue)";
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .foreground = .{ .help = "Text color" ++ color_help },
    .background = .{ .help = "Background color" ++ color_help },
    .border = .{ .help = "Border style: none, normal, rounded, thick, double, hidden, or ascii" },
    .border_foreground = .{ .help = "Border color" },
    .padding = .{ .help = "Space inside the border: \"1\", \"1 2\", or \"1 2 1 2\"" },
    .margin = .{ .help = "Space outside the border, as --padding" },
    .bold = .{ .help = "Bold text" },
    .faint = .{ .help = "Dim text" },
    .italic = .{ .help = "Italic text" },
    .underline = .{ .help = "Underlined text" },
    .strikethrough = .{ .help = "Struck-through text" },
    .@"align" = .{ .help = "Alignment of lines narrower than the block" },
    .width = .{ .help = "Columns, padding included; longer lines are wrapped" },
    .height = .{ .help = "The fewest rows, padding included" },
} }}), .{ .fields = .{
    .foreground = .{ .value_name = "color" },
    .background = .{ .value_name = "color" },
    .border = .{ .value_name = "style" },
    .border_foreground = .{ .value_name = "color" },
} });

pub const command = cli.command(.{
    .name = "style",
    .summary = "Print text with colors, padding, and a border",
    .description =
    \\Print the arguments (one per line), or standard input, laid out as a block in the
    \\given style. Colors and attributes are written only when standard output shows
    \\them: not into a pipe or a file, and not under NO_COLOR (FORCE_COLOR overrides).
    \\Borders, padding, and alignment are always applied.
    ,
    .flags = flags_flags,
    .args = .{ .max = null, .usage = "[text...]" },
    .examples =
    \\termancy ui style --border rounded --padding "0 2" --foreground 212 "Hello"
    \\echo done | termancy ui style --bold --foreground green
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const text = try textOf(ctx);
    var block: std.Io.Writer.Allocating = .init(ctx.arena);
    try styleOf(flags).render(&block.writer, text);
    try term.writeStyled(ctx.out, block.written(), try term.stdoutColor(ctx));
    try ctx.out.writeByte('\n');
}

/// The text to style: the arguments joined by line breaks, or standard input without its
/// final line break.
pub fn textOf(ctx: *cli.Context) ![]const u8 {
    if (ctx.args.len > 0) return std.mem.join(ctx.arena, "\n", ctx.args);
    const text = try term.readStdin(ctx) orelse
        return ctx.usageError("no text: give it as arguments or on standard input", .{});
    return std.mem.trimEnd(u8, text, "\n");
}

/// The style the flags describe.
pub fn styleOf(flags: Flags) tui.Style {
    return .{
        .fg = flags.foreground orelse .default,
        .bg = flags.background orelse .default,
        .border = switch (flags.border) {
            .none => null,
            inline else => |tag| @field(tui.Style.Border, @tagName(tag)),
        },
        .border_fg = flags.border_foreground orelse .default,
        .padding = flags.padding.sides,
        .margin = flags.margin.sides,
        .bold = flags.bold,
        .dim = flags.faint,
        .italic = flags.italic,
        .underline = flags.underline,
        .strikethrough = flags.strikethrough,
        .@"align" = switch (flags.@"align") {
            .left => .start,
            .center => .center,
            .right => .end,
        },
        .width = flags.width,
        .height = flags.height,
    };
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

test styleOf {
    const style = styleOf(.{
        .foreground = .red,
        .border = .rounded,
        .@"align" = .right,
        .bold = true,
        .faint = true,
    });
    try testing.expectEqual(tui.Color.red, style.fg);
    try testing.expectEqualStrings("╭", style.border.?.top_left);
    try testing.expectEqual(tui.layout.Position.end, style.@"align");
    try testing.expect(style.bold and style.dim);
    try testing.expectEqual(null, styleOf(.{}).border);
}
