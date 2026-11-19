//! `termancy ui style`: print text in colors, with padding, a border, and alignment, as
//! gum's `style`.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const styles = @import("styles.zig");

pub const Flags = struct {
    trim: bool = false,
    strip_ansi: bool = true,
    style: styles.Styles = .{},
};

const flags_flags = cli.flags(Flags, field.Set(.{ field.Spec(Flags){ .fields = .{
    .trim = .{ .help = "Remove the whitespace around every line" },
    .strip_ansi = .{ .help = term.help.strip_ansi },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_STYLE_", .fields = .{
    .style = styles.top,
} });

pub const command = cli.command(.{
    .name = "style",
    .summary = "Print text with colors, padding, and a border",
    .description =
    \\Print the arguments (one per line), or standard input, laid out as a block in the
    \\given style: --width wraps longer lines at spaces, --align places shorter ones, and
    \\--trim first removes the whitespace around every line. Escape sequences in standard
    \\input are removed (--no-strip-ansi keeps them). Colors and attributes are written
    \\only when standard output shows them: not into a pipe or a file, and not under
    \\NO_COLOR (FORCE_COLOR overrides). Borders, padding, and alignment are always
    \\applied. Every flag can also come from a variable: TERMANCY_STYLE_FOREGROUND,
    \\TERMANCY_STYLE_TRIM.
    ,
    .flags = flags_flags,
    .args = .{ .max = null, .usage = "[text...]" },
    .examples =
    \\termancy ui style --border rounded --padding "0 2" --foreground 212 "Hello"
    \\echo done | termancy ui style --bold --foreground green
    \\printf '  indented\n    lines\n' | termancy ui style --trim --border normal
    \\termancy ui style --width 20 --align center "a line long enough to wrap"
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    var text = try term.inputText(ctx, flags.strip_ansi);
    if (flags.trim) text = try trimLines(ctx.arena, text);
    var block: std.Io.Writer.Allocating = .init(ctx.arena);
    try styleOf(flags).render(&block.writer, text);
    try term.writeStyled(ctx.out, block.written(), try term.stdoutColor(ctx));
    try ctx.out.writeByte('\n');
}

/// `text` with the whitespace around each line removed (`--trim`).
pub fn trimLines(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(arena, std.mem.trim(u8, line, &std.ascii.whitespace));
    return std.mem.join(arena, "\n", lines.items);
}

/// The style the flags describe.
pub fn styleOf(flags: Flags) tui.Style {
    return flags.style.over(.{});
}

const testing = std.testing;

test styleOf {
    const style = styleOf(.{ .style = .{
        .foreground = .red,
        .border = .rounded,
        .@"align" = .right,
        .bold = true,
        .faint = true,
    } });
    try testing.expectEqual(tui.Color.red, style.fg);
    try testing.expectEqualStrings("╭", style.border.?.top_left);
    try testing.expectEqual(tui.layout.Position.end, style.@"align");
    try testing.expect(style.bold and style.dim);
    try testing.expectEqual(null, styleOf(.{}).border);
}

test trimLines {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a\nb c\n\nd", try trimLines(a, "  a\t\n b c \r\n \n\td"));
    try testing.expectEqualStrings("", try trimLines(a, ""));
}
