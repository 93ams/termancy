//! `snek tui image`: show a PNG, JPEG, or GIF in the terminal, the way the terminal draws images
//! best: the kitty graphics protocol, iTerm2's inline images, sixels, or a mosaic of half
//! blocks that works wherever colors do.

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const term = tui.term;
const explain = @import("../cli/explain.zig");
const graphics = term.graphics;

const Flags = struct {
    protocol: []const u8 = "auto",
    width: ?u16 = null,
    height: ?u16 = null,
    pub const meta = .{
        .protocol = .{ .short = 'p', .help = "auto, kitty, iterm, sixel, or mosaic" },
        .width = .{ .short = 'w', .help = "Columns to draw it in (default: its size, at most " ++
            "the terminal's)", .min = 1 },
        .height = .{
            .short = 'H',
            .help = "Rows to draw it in (default: from the width)",
            .min = 1,
        },
    };
};

pub const command = cli.command(.{
    .name = "image",
    .summary = "Show a PNG, JPEG, or GIF in the terminal",
    .description =
    \\Draw an image (PNG, JPEG, or a GIF's first frame; - for standard input) at the
    \\cursor. The way is the terminal's best: the kitty graphics protocol (kitty, Ghostty),
    \\iTerm2's inline images (iTerm2, WezTerm, VS Code), sixels (foot, mlterm, Windows
    \\Terminal), or else half blocks, two pixels a cell, in as many colors as show. When
    \\the environment does not say, auto asks the terminal (kitty's graphics query and the
    \\device attributes), waiting at most 200 ms.
    ,
    .args = .{ .min = 1, .max = 1, .usage = "<file>" },
    .flags = Flags,
    .examples =
    \\snek tui image logo.png
    \\snek tui image photo.jpg
    \\snek tui image -w 40 -p mosaic demo.gif
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const protocol = if (std.mem.eql(u8, flags.protocol, "auto"))
        autoProtocol(ctx)
    else
        graphics.protocolNamed(flags.protocol) orelse
            return ctx.usageError(
                "--protocol {s}: auto, kitty, iterm, sixel, or mosaic",
                .{flags.protocol},
            );
    const path = ctx.args[0];
    const data = if (std.mem.eql(u8, path, "-"))
        try explain.readStdin(ctx) orelse return ctx.usageError(
            "-: standard input is a terminal",
            .{},
        )
    else
        std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return ctx.fail("{s}: {s}", .{ path, @errorName(err) });
        };
    var img = term.image.decode(ctx.gpa, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail(
            "{s}: not a PNG, JPEG, or GIF this can read ({s})",
            .{ path, @errorName(err) },
        ),
    };
    defer img.deinit(ctx.gpa);

    var options: graphics.Options = .{
        .protocol = protocol,
        .columns = if (flags.width) |w| w else null,
        .rows = if (flags.height) |h| h else null,
        .color = ctx.color,
    };
    // Never wider than the terminal.
    if (term.Terminal.sizeOf(ctx.io, std.Io.File.stdout())) |size| {
        const natural = graphics.cells(&img, options)[0];
        if (flags.width == null and natural > size.width) options.columns = size.width;
    } else |_| {}
    if (protocol == .mosaic and ctx.color == .none) options.color = .ansi256;
    try graphics.write(ctx.gpa, ctx.out, &img, options);
}

/// The environment's answer, or, when it has none and standard output is a terminal, the
/// terminal's own.
fn autoProtocol(ctx: *cli.Context) graphics.Protocol {
    const found = graphics.detect(ctx.environ);
    if (found != .mosaic) return found;
    const name = ctx.environ.get("TERM") orelse "";
    // The Linux console would print the graphics query; neither draws images anyway.
    if (std.mem.eql(u8, name, "dumb") or std.mem.startsWith(u8, name, "linux")) return found;
    if (!(std.Io.File.stdout().isTty(ctx.io) catch false)) return found;
    var buffer: [256]u8 = undefined;
    var terminal = term.Terminal.open(ctx.io, &buffer) catch return found;
    defer terminal.close();
    return graphics.detectByQuery(&terminal, .fromMilliseconds(200)) orelse found;
}

const testing = std.testing;

test "a PNG as a mosaic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var img: term.image.Image = try .init(testing.allocator, 2, 2);
    defer img.deinit(testing.allocator);
    img.fill(.{ .r = 0, .g = 255, .b = 0 });
    var png: std.Io.Writer.Allocating = .init(testing.allocator);
    defer png.deinit();
    try term.image.writePng(testing.allocator, &png.writer, &img);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dot.png", .data = png.written() });
    const path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/dot.png",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(path);
    const app: cli.App = .{ .root = &@import("../../main.zig").root, .completion_command = false };
    const r = try cli.testing.run(app, &.{ "tui", "image", "-p", "mosaic", "-w", "2", path }, .{});
    defer r.deinit();
    try r.expect(0, "\x1b[0;38;5;46;48;5;46m\u{2580}\x1b[0;38;5;46;48;5;46m\u{2580}\x1b[0m\n", "");
}
