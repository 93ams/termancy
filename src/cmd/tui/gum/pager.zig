//! `snek tui pager`: scroll through a file or standard input.

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const platform = @import("platform");
const term = @import("term.zig");
const Pager = @import("../registry/pager.zig").Pager;

pub const command = cli.command(.{
    .name = "pager",
    .summary = "Scroll through text",
    .description =
    \\Show a file (or standard input) full screen, lines wrapped to the terminal's width.
    \\
    \\Keys: j/k or up/down scroll a line, space/b or pgdown/pgup a screen, d/u half a
    \\screen, g/G or home/end jump to either end; / searches (ignoring case), n and N go
    \\to the next and previous match. v opens the file in $VISUAL or $EDITOR and shows it
    \\again when the editor exits. q quits; esc quits with status 1; Ctrl-C with 130.
    ,
    .args = .{ .max = 1, .usage = "[file]" },
    .examples =
    \\snek tui pager README.md
    \\snek cfg show | snek tui pager
    ,
    .run = run,
});

fn run(ctx: *cli.Context) !void {
    const text = try read(ctx);
    var model: Viewer = .{
        .pager = try .init(ctx.gpa, text),
        .ctx = ctx,
        .path = if (ctx.args.len > 0) ctx.args[0] else null,
    };
    defer model.pager.deinit();
    const options: tui.Options = .{ .alt_screen = true };
    if (try term.run(ctx, Viewer, &model, options)) return term.exitInterrupted(ctx);
    if (model.pager.status != .submitted) return error.CommandFailed;
}

/// The pager, plus `v` to edit the file being shown.
const Viewer = struct {
    pager: Pager,
    ctx: *cli.Context,
    /// The file shown; null for standard input, which cannot be edited.
    path: ?[]const u8,

    pub fn update(viewer: *Viewer, msg: tui.Msg) tui.Cmd {
        if (msg == .key and msg.key.matches("v") and viewer.path != null and
            !viewer.pager.searching) return .handoff(0);
        return viewer.pager.update(msg);
    }

    /// Runs the editor on the terminal the program lent out, then reads the file again.
    pub fn handoff(viewer: *Viewer, io: std.Io, _: u32) tui.Cmd {
        const ctx = viewer.ctx;
        const path = viewer.path.?;
        if (platform.process.edit(ctx.gpa, io, ctx.environ, path)) |_| {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, ctx.arena, .unlimited) catch |err|
                return viewer.say(@errorName(err));
            viewer.pager.setText(text) catch return viewer.say("out of memory");
        } else |err| return viewer.say(@errorName(err));
        return .none;
    }

    fn say(viewer: *Viewer, message: []const u8) tui.Cmd {
        viewer.pager.message = message;
        return .none;
    }

    pub fn view(viewer: *const Viewer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try viewer.pager.view(w);
    }
};

/// The file named by the argument, or standard input.
fn read(ctx: *cli.Context) ![]const u8 {
    if (ctx.args.len > 0) {
        const path = ctx.args[0];
        return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err|
            switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.FileNotFound => ctx.fail("{s}: no such file", .{path}),
                else => |e| ctx.fail("{s}: {s}", .{ path, @errorName(e) }),
            };
    }
    return try term.readStdin(ctx) orelse
        ctx.usageError("no text: name a file or give the text on standard input", .{});
}
