//! How help and the runner's own messages look when the stream they go to takes color: one
//! `term.Style` per kind of text. The default uses the terminal's 16 colors, so it follows
//! the user's palette, light or dark; replace any style (`App.theme`) for a brand of your
//! own, in any color, which is lowered to what the terminal shows.
//!
//! ```zig
//! const theme: cli.Theme = .{ .heading = .{ .fg = .hex(0xff5f87), .bold = true } };
//! const app: cli.App = .{ .root = &root, .theme = &theme };
//! ```
//!
//! Without color (a pipe, `NO_COLOR`, `TERM=dumb`), output is the same text unstyled.

const std = @import("std");
const Writer = std.Io.Writer;
const term = @import("term");
const Style = term.Style;
const Level = term.capability.Color;

const Theme = @This();

/// Section headings: `Usage:`, `Flags:`.
heading: Style = .{ .bold = true, .fg = .magenta },
/// The command path in a usage line.
program: Style = .{ .bold = true },
/// Subcommand names where commands are listed.
command: Style = .{ .fg = .cyan },
/// Flag names: `-p, --port`, and flags in example lines.
flag: Style = .{ .fg = .green },
/// Placeholders: `<int>`, `[flags]`, `<command>`.
placeholder: Style = .{ .dim = true },
/// What follows a flag's help: its default, range, variable, and `(required)`.
note: Style = .{ .dim = true },
/// Comment lines (`# ...`) among examples.
comment: Style = .{ .dim = true, .italic = true },
/// The app's name before an error.
@"error": Style = .{ .fg = .red, .bold = true },
/// The app's name before a warning.
warning: Style = .{ .fg = .yellow, .bold = true },
/// What follows an error: "Did you mean", "Run 'app --help' for usage.".
hint: Style = .{ .dim = true },

/// Colors, as described above.
pub const default: Theme = .{};

/// Bold headings and nothing else.
pub const bold: Theme = .{
    .heading = .{ .bold = true },
    .program = .{},
    .command = .{},
    .flag = .{},
    .placeholder = .{},
    .note = .{},
    .comment = .{},
    .@"error" = .{},
    .warning = .{},
    .hint = .{},
};

/// Writes `text` in `style` at `level`; as plain text at `.none`.
pub fn paint(w: *Writer, level: Level, style: Style, text: []const u8) Writer.Error!void {
    if (level == .none) return w.writeAll(text);
    try style.lowered(level).paint(w, text);
}

/// Which message a prefix starts.
pub const Kind = enum { @"error", warning, plain };

/// Writes `<name>: ` before a message, the name in the style for `kind`.
pub fn writePrefix(
    theme: *const Theme,
    w: *Writer,
    level: Level,
    name: []const u8,
    kind: Kind,
) Writer.Error!void {
    const style: Style = switch (kind) {
        .@"error" => theme.@"error",
        .warning => theme.warning,
        .plain => .{},
    };
    if (level == .none or !style.hasSgr()) return w.print("{s}: ", .{name});
    try style.lowered(level).writeSgr(w);
    try w.print("{s}:{s} ", .{ name, term.ansi.reset });
}

const testing = std.testing;

test paint {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try paint(&w, .none, default.heading, "Usage:");
    try paint(&w, .basic, default.heading, "Usage:");
    try testing.expectEqualStrings("Usage:\x1b[1;35mUsage:\x1b[0m", w.buffered());
}

test writePrefix {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try default.writePrefix(&w, .none, "app", .@"error");
    try default.writePrefix(&w, .basic, "app", .@"error");
    try bold.writePrefix(&w, .basic, "app", .warning);
    try testing.expectEqualStrings("app: \x1b[1;31mapp:\x1b[0m app: ", w.buffered());
}
