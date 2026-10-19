//! `termancy ui file`: browse directories and choose a file; prints its path.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const FilePicker = @import("../tui/registry/filepicker.zig").FilePicker;

pub const Flags = struct {
    all: bool = false,
    ext: []const []const u8 = &.{},
};
const flags_flags = cli.flags(Flags, field.Set(.{field.Spec(Flags){ .fields = .{
    .all = .{ .help = "Show files and directories whose names start with ." },
    .ext = .{ .help = "List only files ending in this (repeatable), such as .toml" },
} }}), .{ .fields = .{
    .all = .{ .short = 'a' },
} });

pub const command = cli.command(.{
    .name = "file",
    .summary = "Choose a file",
    .description =
    \\Browse from [dir] (default: the current directory) and print the absolute path of the
    \\file chosen. Directories come first.
    \\
    \\Keys: up/down or j/k move; enter, right, or l open a directory or choose a file;
    \\left, h, or backspace go up; . shows or hides dotfiles. esc or q cancels (status
    \\1), Ctrl-C interrupts (status 130).
    ,
    .flags = flags_flags,
    .args = .{ .max = 1, .usage = "[dir]" },
    .examples =
    \\$EDITOR "$(termancy ui file --ext .md)"
    \\termancy ui file --all ~/.config
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const dir = if (ctx.args.len > 0) ctx.args[0] else ".";
    const options: FilePicker.Options = .{ .extensions = flags.ext, .show_hidden = flags.all };
    var model: FilePicker = FilePicker.init(ctx.gpa, ctx.io, dir, options) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => ctx.fail("{s}: no such directory", .{dir}),
            else => |e| ctx.fail("{s}: {s}", .{ dir, @errorName(e) }),
        };
    };
    defer model.deinit();
    const interrupted = try term.run(ctx, FilePicker, &model, term.suspend_options);
    if (interrupted) return term.exitInterrupted(ctx);
    const chosen = model.chosen orelse return error.CommandFailed;
    try ctx.out.print("{s}\n", .{chosen});
}
