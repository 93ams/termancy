//! `termancy ui join`: put blocks of text side by side or one above another, as gum's `join`,
//! lining up styled and wide text by its display width.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");

const Flags = struct {
    vertical: bool = false,
    horizontal: bool = false,
    @"align": Align = .left,
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .vertical = .{ .help = "One above another" },
    .horizontal = .{ .help = "Side by side (the default)" },
    .@"align" = .{ .help = "Where shorter blocks sit side by side (top, middle, bottom; " ++
        "left, center, right say the same), or narrower ones stacked (left, center, right)" },
} }}), .{ .env_prefix = "TERMANCY_JOIN_" });

const Align = enum { left, center, right, top, middle, bottom };

pub const command = cli.command(.{
    .name = "join",
    .summary = "Join blocks of text side by side or vertically",
    .description =
    \\Join the arguments, each a block of lines, side by side (or one above another with
    \\--vertical), padding each to line up, as gum's join. Side by side, --align places
    \\shorter blocks at the top (left, the default), middle (center), or bottom (right);
    \\stacked, it places narrower blocks left, center, or right. Escape sequences take no
    \\room, so blocks from termancy ui style join cleanly. Every flag can also come from a
    \\variable: TERMANCY_JOIN_ALIGN.
    ,
    .args = .{ .min = 1, .max = null, .usage = "<text>..." },
    .flags = flags_flags,
    .examples =
    \\termancy ui join "$(termancy ui style --border rounded A)" "$(termancy ui style --border rounded B)"
    \\termancy ui join --vertical --align center "Title" "a longer line"
    \\termancy ui join --align bottom "$(printf 'a\nb\nc')" " <- c"
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (flags.vertical and flags.horizontal) {
        return ctx.usageError("--vertical and --horizontal exclude each other", .{});
    }
    const position: tui.layout.Position = switch (flags.@"align") {
        .left, .top => .start,
        .center, .middle => .center,
        .right, .bottom => .end,
    };
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    if (flags.vertical) {
        try tui.layout.joinVertical(&out.writer, position, ctx.args);
    } else {
        try tui.layout.joinHorizontal(&out.writer, position, ctx.args);
    }
    try out.writer.writeByte('\n');
    try term.writeStyled(ctx.out, out.written(), try term.stdoutColor(ctx));
}
