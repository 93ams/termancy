//! A Markdown document to read, scrolling: rendered by `tui.term.markdown` (glamour's
//! style sheets, highlighted code, word wrap) at the terminal's width, and again on each
//! resize; scrolled with the viewport's keys. `glow`'s reader, as a component.
//!
//! ```zig
//! var doc: Markdown = .{ .gpa = gpa, .source = readme };
//! defer doc.deinit();
//! _ = try tui.run(gpa, io, &doc, .{ .environ = environ, .program = .{ .alt_screen = true } });
//! ```
//!
//! Keys: those of `viewport` (up/down, j/k, pgup/pgdown, space, ctrl+u/ctrl+d, g/G, the
//! wheel); q or esc quits. The last row is a status line: the scroll position, as glow's.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Viewport = @import("viewport.zig");

const Markdown = @This();

gpa: Allocator,
/// The Markdown; borrowed.
source: []const u8,
options: tui.term.markdown.Options = .{},
/// A line under the document, left of the scroll position (a file name).
title: []const u8 = "",
/// Show the status line.
status_line: bool = true,
/// Columns rendered to at most, however wide the terminal (readable lines).
max_width: usize = 120,
rendered: std.ArrayList(u8) = .empty,
viewport: Viewport = .{ .wrap = false },
styles: Styles = .{},

pub const Styles = struct {
    status: tui.Style = .{ .fg = .{ .indexed = 241 } },
    title: tui.Style = .{ .fg = .{ .indexed = 230 }, .bg = .{ .indexed = 62 } },
};

pub fn deinit(doc: *Markdown) void {
    doc.rendered.deinit(doc.gpa);
    doc.* = undefined;
}

/// Renders the source for `width` columns.
pub fn layout(doc: *Markdown, width: usize) Allocator.Error!void {
    var options = doc.options;
    options.width = @min(width, doc.max_width);
    doc.rendered.clearRetainingCapacity();
    var out: Writer.Allocating = .fromArrayList(doc.gpa, &doc.rendered);
    tui.term.markdown.render(doc.gpa, &out.writer, doc.source, options) catch {
        doc.rendered = out.toArrayList();
        return error.OutOfMemory;
    };
    doc.rendered = out.toArrayList();
    // A document opens at its top; a resize keeps the place, within range.
    const first = doc.viewport.content.len == 0;
    doc.viewport.setContent(doc.rendered.items);
    if (first) doc.viewport.offset = 0;
}

pub fn update(doc: *Markdown, msg: tui.Msg) tui.Cmd {
    switch (msg) {
        .resize => |size| {
            doc.viewport.height = @max(1, size.height -| @intFromBool(doc.status_line));
            doc.viewport.width = size.width;
            doc.layout(size.width) catch {};
        },
        .key => |key| {
            if (key.matches("q") or key.matches("esc")) return .quit;
            _ = doc.viewport.update(msg);
        },
        else => _ = doc.viewport.update(msg),
    }
    return .none;
}

pub fn view(doc: *const Markdown, w: *Writer) Writer.Error!void {
    try doc.viewport.view(w);
    if (!doc.status_line) return;
    try w.writeByte('\n');
    if (doc.title.len > 0) {
        try doc.styles.title.paint(w, " ");
        try doc.styles.title.paint(w, doc.title);
        try doc.styles.title.paint(w, " ");
        try w.writeByte(' ');
    }
    var buffer: [16]u8 = undefined;
    const percent = std.fmt.bufPrint(&buffer, "{d}%", .{doc.viewport.percent()}) catch "";
    try doc.styles.status.paint(w, percent);
}

const testing = std.testing;

/// Forty words, a paragraph several rows long.
const words = blk: {
    var text: []const u8 = "";
    for (0..40) |_| text = text ++ "word ";
    break :blk text;
};

test "renders at the terminal's width and scrolls" {
    var d: tui.testing.Driver(Markdown) = try .init(testing.allocator, .{
        .gpa = testing.allocator,
        .source = "# Title\n\n" ++ words ++ "\n\n- a\n- b\n- c\n- d",
        .options = .{ .style = .ascii },
        .styles = .{ .status = .{}, .title = .{} },
        .title = "README.md",
    }, .{ .program = .{ .size = .{ .width = 30, .height = 6 } } });
    defer d.deinit();
    try d.expectFrameContains("  # Title");
    try d.expectFrameContains(" README.md  0%");
    try d.press("G");
    try d.expectFrameContains("  * d");
    try d.expectFrameContains("100%");
    try d.press("q");
    try testing.expect(d.done());
}
