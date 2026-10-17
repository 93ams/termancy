//! The help for a keymap, as Bubble Tea's help: one line of the main keys, or (after `?`)
//! every key in columns. The bindings are declared once, in a `tui.Keymap`, for both
//! matching keys and showing them.
//!
//! ```zig
//! const keys: tui.Keymap(Action) = .{ .bindings = &.{
//!     .{ .keys = &.{"up"}, .action = .up, .help = "up" },
//!     .{ .keys = &.{"q"}, .action = .quit, .help = "quit", .column = 1 },
//! } };
//! var help: Help(Action) = .{ .keymap = keys };
//! _ = help.update(msg); // ? toggles the full help
//! try help.view(w);
//! ```

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;

pub fn Help(comptime Action: type) type {
    return struct {
        keymap: tui.Keymap(Action),
        /// Every binding in columns, instead of one line.
        full: bool = false,
        /// Columns the short line may take (it ends in `…` past them).
        width: ?usize = null,
        /// The key that toggles the full help; null for none.
        toggle_key: ?[]const u8 = "?",
        styles: Styles = .{},
        /// The terminal's width, for the short line when `width` is not set.
        width_from_terminal: ?usize = null,

        const Self = @This();

        pub const Styles = struct {
            key: tui.Style = .{},
            description: tui.Style = .{ .dim = true },
            separator: tui.Style = .{ .dim = true },
        };

        pub fn update(h: *Self, msg: tui.Msg) tui.Cmd {
            switch (msg) {
                .key => |key| if (h.toggle_key) |name| {
                    const toggle = tui.input.Key.parse(name) catch return .none;
                    if (key.eql(toggle)) h.full = !h.full;
                },
                .resize => |size| if (h.width == null) {
                    h.width_from_terminal = size.width;
                },
                else => {},
            }
            return .none;
        }

        pub fn view(h: *const Self, w: *Writer) Writer.Error!void {
            if (h.full) return h.keymap.writeFullHelp(w, .{
                .key_style = h.styles.key,
                .help_style = h.styles.description,
            });
            try h.keymap.writeHelp(w, .{
                .key_style = h.styles.key,
                .help_style = h.styles.description,
                .separator_style = h.styles.separator,
                .width = h.width orelse h.width_from_terminal,
            });
        }
    };
}

const testing = std.testing;

const TestAction = enum { up, down, quit };

test "short and full help, toggled with ?" {
    const plain: Help(TestAction).Styles = .{ .description = .{}, .separator = .{} };
    var help: Help(TestAction) = .{ .keymap = .{ .bindings = &.{
        .{ .keys = &.{"up"}, .action = .up, .help = "up" },
        .{ .keys = &.{"down"}, .action = .down, .help = "down" },
        .{ .keys = &.{"q"}, .action = .quit, .help = "quit", .column = 1 },
    } }, .styles = plain };
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try help.view(&w);
    try testing.expectEqualStrings("↑ up • ↓ down • q quit", w.buffered());
    _ = help.update(.{ .key = try .parse("?") });
    w = .fixed(&buffer);
    try help.view(&w);
    try testing.expectEqualStrings("↑ up      q quit\n↓ down", w.buffered());
}
