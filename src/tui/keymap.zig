//! Key bindings declared once, used twice: to match keys in `update` and to write the
//! help line in `view`, so the two never disagree.
//!
//! ```zig
//! const Action = enum { up, down, quit };
//! const keys: tui.Keymap(Action) = .{ .bindings = &.{
//!     .{ .keys = &.{ "up", "k" }, .action = .up, .help = "up" },
//!     .{ .keys = &.{ "down", "j" }, .action = .down, .help = "down" },
//!     .{ .keys = &.{ "q", "esc" }, .action = .quit, .help = "quit" },
//! } };
//!
//! // in update:
//! if (keys.match(key)) |action| switch (action) { ... }
//! // in view:
//! try keys.writeHelp(w, .{});   // ↑/k up • ↓/j down • q/esc quit
//! ```
//!
//! Key names are those `input.Key.parse` reads, so bindings can come from a configuration
//! file; `check` reports a name that is not a key.

const std = @import("std");
const Writer = std.Io.Writer;
const input = @import("term").input;
const Style = @import("term").Style;
const display = @import("term").width;

/// Bindings from keys to values of `Action`.
pub fn Keymap(comptime Action: type) type {
    return struct {
        bindings: []const Binding,

        const Self = @This();

        /// Keys that trigger one action.
        pub const Binding = struct {
            /// Key names, as `input.Key.parse` reads them.
            keys: []const []const u8,
            action: Action,
            /// What the action does, for the help line; empty leaves it out of help.
            help: []const u8 = "",
            /// How help shows the keys; by default their names joined by `/`, with
            /// arrows for the arrow keys.
            label: ?[]const u8 = null,
            /// A disabled binding matches nothing and is left out of help.
            enabled: bool = true,
            /// The column of the full help (`writeFullHelp`) the binding is listed in.
            column: u8 = 0,
        };

        /// The action of the first enabled binding that has `key`.
        pub fn match(keymap: Self, key: input.Key) ?Action {
            for (keymap.bindings) |binding| {
                if (!binding.enabled) continue;
                for (binding.keys) |name| {
                    const bound = input.Key.parse(name) catch continue;
                    if (bound.eql(key)) return binding.action;
                }
            }
            return null;
        }

        /// The first key name that `input.Key.parse` rejects.
        pub const CheckError = error{InvalidKey};

        /// Fails when a binding names something that is not a key; `bad` (when given)
        /// receives the name.
        pub fn check(keymap: Self, bad: ?*[]const u8) CheckError!void {
            for (keymap.bindings) |binding| {
                for (binding.keys) |name| {
                    _ = input.Key.parse(name) catch {
                        if (bad) |out| out.* = name;
                        return error.InvalidKey;
                    };
                }
            }
        }

        /// Writes every enabled binding that has help, in columns by `Binding.column` (as
        /// Bubble Tea's full help): each column the keys, aligned, then what they do.
        pub fn writeFullHelp(keymap: Self, w: *Writer, options: FullHelpOptions) Writer.Error!void {
            var columns: usize = 0;
            for (keymap.bindings) |b| if (b.enabled and b.help.len > 0) {
                columns = @max(columns, @as(usize, b.column) + 1);
            };
            if (columns == 0) return;
            // Each column's key and help widths, and its number of rows.
            var key_widths: [16]usize = @splat(0);
            var help_widths: [16]usize = @splat(0);
            var heights: [16]usize = @splat(0);
            const shown = @min(columns, key_widths.len);
            for (keymap.bindings) |b| {
                if (!b.enabled or b.help.len == 0 or b.column >= shown) continue;
                var label_buffer: [64]u8 = undefined;
                const label = b.label orelse labelOf(&label_buffer, b.keys);
                key_widths[b.column] = @max(key_widths[b.column], display.of(label));
                help_widths[b.column] = @max(help_widths[b.column], display.of(b.help));
                heights[b.column] += 1;
            }
            var rows: usize = 0;
            for (heights[0..shown]) |h| rows = @max(rows, h);
            for (0..rows) |row| {
                if (row > 0) try w.writeByte('\n');
                // Spaces wait until something follows them, so rows end without them.
                var pad: usize = 0;
                for (0..shown) |column| {
                    // The binding at this row of this column, if any.
                    var seen: usize = 0;
                    const found: ?Binding = for (keymap.bindings) |b| {
                        if (!b.enabled or b.help.len == 0 or b.column != column) continue;
                        if (seen == row) break b;
                        seen += 1;
                    } else null;
                    if (column > 0) pad += options.gap;
                    const b = found orelse {
                        pad += key_widths[column] + 1 + help_widths[column];
                        continue;
                    };
                    var label_buffer: [64]u8 = undefined;
                    const label = b.label orelse labelOf(&label_buffer, b.keys);
                    try w.splatByteAll(' ', pad);
                    try options.key_style.paint(w, label);
                    try w.splatByteAll(' ', key_widths[column] - display.of(label) + 1);
                    try options.help_style.paint(w, b.help);
                    pad = help_widths[column] - display.of(b.help);
                }
            }
        }

        /// Writes the enabled bindings that have help, as `keys help` joined by
        /// `options.separator`. With `options.width`, stops before a binding that would
        /// not fit and writes `…` instead, when that fits.
        pub fn writeHelp(keymap: Self, w: *Writer, options: HelpOptions) Writer.Error!void {
            var used: usize = 0;
            var first = true;
            for (keymap.bindings) |binding| {
                if (!binding.enabled or binding.help.len == 0) continue;
                var label_buffer: [64]u8 = undefined;
                const label = binding.label orelse labelOf(&label_buffer, binding.keys);
                const separator = if (first) "" else options.separator;
                const cost = display.of(separator) + display.of(label) + 1 +
                    display.of(binding.help);
                if (options.width) |limit| {
                    if (used + cost > limit) {
                        const more = if (first) "…" else " …";
                        if (used + display.of(more) <= limit) {
                            try options.separator_style.paint(w, more);
                        }
                        return;
                    }
                }
                try options.separator_style.paint(w, separator);
                try options.key_style.paint(w, label);
                try w.writeByte(' ');
                try options.help_style.paint(w, binding.help);
                used += cost;
                first = false;
            }
        }
    };
}

/// How `Keymap.writeFullHelp` lays its columns out.
pub const FullHelpOptions = struct {
    key_style: Style = .{},
    help_style: Style = .{ .dim = true },
    /// Spaces between columns.
    gap: usize = 4,
};

/// How `Keymap.writeHelp` writes the help line.
pub const HelpOptions = struct {
    separator: []const u8 = " • ",
    key_style: Style = .{},
    help_style: Style = .{ .dim = true },
    separator_style: Style = .{ .dim = true },
    /// Columns the line may take.
    width: ?usize = null,
};

/// The keys' names joined by `/`, arrows for the arrow keys. A label that does not fit
/// in `buffer` is cut short.
fn labelOf(buffer: []u8, keys: []const []const u8) []const u8 {
    var w: Writer = .fixed(buffer);
    for (keys, 0..) |name, i| {
        if (i > 0) w.writeByte('/') catch break;
        w.writeAll(symbolOf(name)) catch break;
    }
    return w.buffered();
}

fn symbolOf(name: []const u8) []const u8 {
    const symbols = [_]struct { []const u8, []const u8 }{
        .{ "up", "↑" },
        .{ "down", "↓" },
        .{ "left", "←" },
        .{ "right", "→" },
    };
    for (symbols) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    return name;
}

const testing = std.testing;

const TestAction = enum { up, down, quit, hidden };
const example: Keymap(TestAction) = .{ .bindings = &.{
    .{ .keys = &.{ "up", "k" }, .action = .up, .help = "up" },
    .{ .keys = &.{ "down", "j" }, .action = .down, .help = "down" },
    .{ .keys = &.{"ctrl+x"}, .action = .hidden },
    .{ .keys = &.{ "q", "esc" }, .action = .quit, .help = "quit" },
} };

fn expectHelp(expected: []const u8, keymap: Keymap(TestAction), options: HelpOptions) !void {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try keymap.writeHelp(&w, options);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Keymap.match" {
    try testing.expectEqual(.up, example.match(try .parse("k")));
    try testing.expectEqual(.up, example.match(try .parse("up")));
    try testing.expectEqual(.quit, example.match(try .parse("esc")));
    try testing.expectEqual(.hidden, example.match(try .parse("ctrl+x")));
    try testing.expectEqual(null, example.match(try .parse("x")));
    try testing.expectEqual(null, example.match(try .parse("ctrl+k")));
    var disabled = example.bindings[0..2].*;
    disabled[0].enabled = false;
    const some: Keymap(TestAction) = .{ .bindings = &disabled };
    try testing.expectEqual(null, some.match(try .parse("k")));
}

test "Keymap.writeHelp" {
    const plain: HelpOptions = .{ .help_style = .{}, .separator_style = .{} };
    try expectHelp("↑/k up • ↓/j down • q/esc quit", example, plain);
    var narrow = plain;
    narrow.width = 20;
    try expectHelp("↑/k up • ↓/j down …", example, narrow);
    narrow.width = 16;
    try expectHelp("↑/k up …", example, narrow);
    narrow.width = 3;
    try expectHelp("…", example, narrow);
    try expectHelp("", .{ .bindings = &.{} }, .{});
    const labeled: Keymap(TestAction) = .{ .bindings = &.{
        .{ .keys = &.{ "up", "down" }, .action = .up, .help = "move", .label = "↑↓" },
    } };
    try expectHelp("↑↓ \x1b[2mmove\x1b[0m", labeled, .{});
}

test "Keymap.writeFullHelp" {
    const columns: Keymap(TestAction) = .{ .bindings = &.{
        .{ .keys = &.{ "up", "k" }, .action = .up, .help = "up" },
        .{ .keys = &.{ "down", "j" }, .action = .down, .help = "down" },
        .{ .keys = &.{"q"}, .action = .quit, .help = "quit", .column = 1 },
        .{ .keys = &.{"ctrl+x"}, .action = .hidden },
    } };
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try columns.writeFullHelp(&w, .{ .help_style = .{} });
    try testing.expectEqualStrings("↑/k up      q quit\n↓/j down", w.buffered());
}

test "Keymap.check" {
    try example.check(null);
    const bad: Keymap(TestAction) = .{ .bindings = &.{
        .{ .keys = &.{ "up", "ctrl+nope" }, .action = .up },
    } };
    var name: []const u8 = "";
    try testing.expectError(error.InvalidKey, bad.check(&name));
    try testing.expectEqualStrings("ctrl+nope", name);
}
