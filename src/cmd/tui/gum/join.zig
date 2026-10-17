//! `snek tui join`: put blocks of text side by side or one above another, as gum's `join`,
//! lining up styled and wide text by its display width.

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const term = @import("term.zig");

const Flags = struct {
    vertical: bool = false,
    horizontal: bool = false,
    @"align": Align = .left,
    pub const meta = .{
        .vertical = .{ .help = "One above another" },
        .horizontal = .{ .help = "Side by side (the default)" },
        .@"align" = .{ .help = "Where narrower (or shorter) blocks sit" },
    };
};

const Align = enum { left, center, right, top, middle, bottom };

pub const command = cli.command(.{
    .name = "join",
    .summary = "Join blocks of text side by side or vertically",
    .description =
    \\Join the arguments, each a block of lines, side by side (or one above another with
    \\--vertical), padding each to line up. Escape sequences take no room, so blocks from
    \\snek tui style join cleanly.
    ,
    .args = .{ .min = 1, .max = null, .usage = "<text>..." },
    .flags = Flags,
    .examples =
    \\snek tui join "$(snek tui style --border rounded A)" "$(snek tui style --border rounded B)"
    \\snek tui join --vertical --align center "Title" "a longer line"
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
