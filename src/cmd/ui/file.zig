//! `termancy ui file`: browse directories and choose a file; prints its path.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const styles = @import("styles.zig");
const FilePicker = @import("../tui/registry/filepicker.zig");

pub const Flags = struct {
    cursor: []const u8 = ">",
    all: bool = false,
    permissions: bool = true,
    size: bool = true,
    file: bool = true,
    directory: bool = false,
    ext: []const []const u8 = &.{},
    header: []const u8 = "",
    height: usize = 10,
    timeout: cfg.Duration = .zero,
    show_help: bool = true,
    padding: styles.Spacing = .{},
    cursor_style: styles.Styles = .{},
    symlink_style: styles.Styles = .{},
    directory_style: styles.Styles = .{},
    file_style: styles.Styles = .{},
    permissions_style: styles.Styles = .{},
    selected_style: styles.Styles = .{},
    file_size_style: styles.Styles = .{},
    header_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field.Set(.{ field.Spec(Flags){ .fields = .{
    .cursor = .{ .help = "Written before the highlighted entry" },
    .all = .{ .help = "Show files and directories whose names start with ." },
    .permissions = .{ .help = "Show each entry's permissions" },
    .size = .{ .help = "Show each entry's size" },
    .file = .{ .help = "Let enter choose a file" },
    .directory = .{ .help = "Let enter choose a directory (right or l opens it)" },
    .ext = .{ .help = "List only files ending in this (repeatable), such as .toml" },
    .header = .{ .help = "Text above the directory" },
    .height = .{ .help = "Entries shown at once" },
    .timeout = .{ .help = term.help.timeout },
    .show_help = .{ .help = term.help.show_help },
    .padding = .{ .help = term.help.padding },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_FILE_", .fields = .{
    .cursor = .{ .short = 'c' },
    .all = .{ .short = 'a' },
    .permissions = .{ .short = 'p' },
    .size = .{ .short = 's' },
    .cursor_style = styles.group("cursor"),
    .symlink_style = styles.group("symlink"),
    .directory_style = styles.group("directory"),
    .file_style = styles.group("file"),
    .permissions_style = styles.group("permissions"),
    .selected_style = styles.group("selected"),
    .file_size_style = styles.group("file-size"),
    .header_style = styles.group("header"),
} });

pub const command = cli.command(.{
    .name = "file",
    .summary = "Choose a file",
    .description =
    \\Browse from [path] (else $TERMANCY_FILE_PATH, else the current directory) and print
    \\the absolute path of the file chosen. Directories come first; each entry shows its
    \\permissions and size (--no-permissions, --no-size hide them). With --directory,
    \\enter chooses a directory too; with --no-file, only a directory.
    \\
    \\Keys: up/down or j/k move; enter chooses, or opens a directory it cannot choose;
    \\right or l opens a directory; left, h, or backspace go up; . shows or hides
    \\dotfiles. esc or q cancels (status 1), Ctrl-C interrupts (status 130), --timeout
    \\ends with 124.
    \\
    \\Style a part with --cursor.*, --selected.* (the highlighted entry), --directory.*,
    \\--file.*, --symlink.*, --permissions.*, --file-size.* (--file-size.width sets its
    \\column), and --header.*. Every flag can come from a variable: TERMANCY_FILE_HEIGHT,
    \\TERMANCY_FILE_DIRECTORY=true.
    ,
    .flags = flags_flags,
    .args = .{ .max = 1, .usage = "[path]" },
    .examples =
    \\$EDITOR "$(termancy ui file --ext .md)"
    \\termancy ui file --all ~/.config
    \\cd "$(termancy ui file --directory --no-file --no-size)"
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (!flags.file and !flags.directory) {
        return ctx.usageError("--no-file needs --directory: there would be nothing to choose", .{});
    }
    const argument = if (ctx.args.len > 0) ctx.args[0] else "";
    const path = if (argument.len > 0) argument else ctx.environ.get("TERMANCY_FILE_PATH") orelse ".";
    var picker: FilePicker = FilePicker.init(ctx.gpa, ctx.io, path, .{
        .extensions = flags.ext,
        .show_hidden = flags.all,
        .show_permissions = flags.permissions,
        .show_size = flags.size,
        .allow_files = flags.file,
        .allow_directories = flags.directory,
    }) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => ctx.fail("{s}: no such directory", .{path}),
            else => |e| ctx.fail("{s}: {s}", .{ path, @errorName(e) }),
        };
    };
    look(ctx.arena, &picker, flags, ctx.theme) catch |err| {
        picker.deinit();
        return err;
    };
    var model: term.Framed(FilePicker) = .{
        .inner = picker,
        .gpa = ctx.gpa,
        .padding = flags.padding.sides,
        .hints = if (flags.show_help) &hints else &.{},
    };
    defer model.deinit();
    const options = term.timed(term.suspend_options, flags.timeout);
    if (try term.run(ctx, @TypeOf(model), &model, options)) return term.exitInterrupted(ctx);
    const chosen = model.inner.chosen orelse return error.CommandFailed;
    try ctx.out.print("{s}\n", .{chosen});
}

const hints = [_]term.Hint{
    .{ .keys = &.{ "up", "down" }, .action = .hint, .help = "navigate" },
    .{ .keys = &.{"right"}, .action = .hint, .help = "open" },
    .{ .keys = &.{"esc"}, .action = .hint, .help = "close" },
    .{ .keys = &.{"enter"}, .action = .hint, .help = "select" },
};

/// The picker's cursor, height, header, and styles: the theme's, with the flags over them.
fn look(
    arena: std.mem.Allocator,
    picker: *FilePicker,
    flags: Flags,
    theme: *const cli.Theme,
) !void {
    // A space after the cursor, as gum's, and as much before every other entry.
    const cursor = try std.fmt.allocPrint(arena, "{s} ", .{flags.cursor});
    const blank = try arena.alloc(u8, tui.width.of(cursor));
    @memset(blank, ' ');
    var selected = theme.accent;
    selected.bold = true;
    picker.list.height = @max(flags.height, 1);
    picker.list.cursor_prefix = cursor;
    picker.list.item_prefix = blank;
    picker.list.styles = .{ .cursor = flags.cursor_style.over(theme.accent), .item = .{} };
    picker.header = try styles.render(arena, flags.header_style.over(theme.heading), flags.header);
    picker.size_width = flags.file_size_style.width orelse 8;
    picker.styles = .{
        .path = theme.note,
        .selected = flags.selected_style.over(selected),
        .directory = flags.directory_style.over(theme.heading),
        .file = flags.file_style.over(.{}),
        .symlink = flags.symlink_style.over(theme.command),
        .permissions = flags.permissions_style.over(theme.note),
        .size = flags.file_size_style.over(theme.note),
    };
}

const testing = std.testing;

test "gum's columns, cursor, and header, framed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "123456" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const flags: Flags = .{ .header = "Pick", .cursor = "→", .permissions = false };
    var picker: FilePicker = try .init(testing.allocator, io, root, .{ .show_size = true });
    try look(arena.allocator(), &picker, flags, &cli.Theme.default);
    var d: tui.testing.Driver(term.Framed(FilePicker)) = try .init(testing.allocator, .{
        .inner = picker,
        .gpa = testing.allocator,
        .hints = &hints,
    }, .{});
    defer d.deinit();
    try d.expectFrameContains("Pick\n");
    // Directory sizes depend on the file system; a file's does not.
    try d.expectFrameContains("\n  " ++ "      6B notes.txt\n\n" ++
        "↑/↓ navigate • → open • esc close • enter select");
    try d.press("down");
    try d.expectFrameContains("\n→       6B notes.txt\n");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expect(std.mem.endsWith(u8, d.model().inner.chosen.?, "notes.txt"));
}
