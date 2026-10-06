//! Split-pane composition: two blocks of text side by side or stacked.
//!
//! This file **is** the type: the file's own scope is `Layout`, so a consumer
//! writes `const Layout = @import("layout.zig");`. See the file-layout rule in
//! `.agents/AGENTS.md`.
//!
//! `SplitDirection` and `SplitOptions` stay declarations inside, because they are
//! `split`'s parameters - one subject, not three.
//!
//! **Known defect, recorded not fixed:** the horizontal path measures the left
//! pane with `line.len` (raw bytes) rather than visual width, so any pane
//! containing ANSI colour or wide characters misaligns the divider. The same job
//! is done correctly by `style.joinHorizontal`, which uses `style.visualWidth`.
//! See `app/cli/lib/ROADMAP.md` section 5.5.

const std = @import("std");

const Self = @This();

/// Which axis to split along.
pub const SplitDirection = enum {
    horizontal,
    vertical,
};

/// How to split, and how much room to leave around the divider.
pub const SplitOptions = struct {
    direction: SplitDirection = .horizontal,
    divider: []const u8 = "│",
    /// null auto-calculates the width from the left pane's longest line.
    left_width: ?usize = null,
    padding: usize = 1,
};

/// Render two blocks of text side-by-side or stacked.
///
/// See the module header on the byte-vs-visual-width defect.
pub fn split(
    writer: anytype,
    pane_a: []const u8,
    pane_b: []const u8,
    options: SplitOptions,
) !void {
    switch (options.direction) {
        .vertical => {
            try writer.writeAll(pane_a);
            if (pane_a.len > 0 and pane_a[pane_a.len - 1] != '\n') {
                try writer.writeAll("\n");
            }
            if (options.divider.len > 0) {
                try writer.writeAll(options.divider);
                try writer.writeAll("\n");
            }
            try writer.writeAll(pane_b);
            if (pane_b.len > 0 and pane_b[pane_b.len - 1] != '\n') {
                try writer.writeAll("\n");
            }
        },
        .horizontal => {
            var lines_a = std.mem.splitScalar(u8, pane_a, '\n');
            var lines_b = std.mem.splitScalar(u8, pane_b, '\n');

            // Determine column width for pane A if not explicitly provided
            var col_a_width: usize = options.left_width orelse 0;
            if (options.left_width == null) {
                var tmp_it = std.mem.splitScalar(u8, pane_a, '\n');
                while (tmp_it.next()) |line| {
                    if (line.len > col_a_width) col_a_width = line.len;
                }
            }

            while (true) {
                const line_a = lines_a.next();
                const line_b = lines_b.next();

                if (line_a == null and line_b == null) break;

                const cur_a = line_a orelse "";
                const cur_b = line_b orelse "";

                try writer.writeAll(cur_a);
                if (cur_a.len < col_a_width) {
                    try writeSpaces(writer, col_a_width - cur_a.len);
                }

                // Padding before divider
                try writeSpaces(writer, options.padding);
                try writer.writeAll(options.divider);
                // Padding after divider
                try writeSpaces(writer, options.padding);

                try writer.writeAll(cur_b);
                try writer.writeAll("\n");
            }
        },
    }
}

fn writeSpaces(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

test "horizontal split pads the left pane to its widest line" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try Self.split(&w, "ab\ncdef", "R1\nR2", .{ .direction = .horizontal, .divider = "|", .padding = 1 });

    try std.testing.expectEqualStrings(
        "ab   | R1\ncdef | R2\n",
        w.buffered(),
    );
}

test "vertical split stacks with a divider line" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try Self.split(&w, "Top", "Bottom", .{ .direction = .vertical, .divider = "---" });

    try std.testing.expectEqualStrings("Top\n---\nBottom\n", w.buffered());
}

test "left_width overrides the auto-calculated column" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try Self.split(&w, "a", "R", .{ .direction = .horizontal, .divider = "|", .padding = 0, .left_width = 3 });

    try std.testing.expectEqualStrings("a  |R\n", w.buffered());
}
