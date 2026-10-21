//! `termancy ui style`: print text in colors, with padding, a border, and alignment.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const styles = @import("styles.zig");

pub const Flags = struct { style: styles.Styles = .{} };

const flags_flags = cli.flags(Flags, field.Set(.{styles.spec}), .{ .fields = .{
    .style = styles.top,
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
