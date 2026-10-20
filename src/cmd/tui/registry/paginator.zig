//! Which page of many you are on, as dots (`●○○`) or numbers (`2/7`), and the keys to
//! turn the page. Pair it with a list of items: `bounds` gives the slice on the page.
//!
//! ```zig
//! var pages: Paginator = .{ .per_page = 10 };
//! pages.setTotal(items.len);
//! _ = pages.update(msg); // left/right, h/l, pgup/pgdown
//! const range = pages.bounds(items.len);
//! for (items[range.start..range.end]) |item| ...;
//! try pages.view(w);
//! ```

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;

const Paginator = @This();

kind: Kind = .dots,
/// The page shown, from 0.
page: usize = 0,
per_page: usize = 10,
/// How many pages there are (at least one).
pages: usize = 1,
active_dot: []const u8 = "●",
inactive_dot: []const u8 = "○",
/// Turn pages with the keys in `update`.
keys: bool = true,
styles: Styles = .{},

pub const Kind = enum { dots, arabic };

pub const Styles = struct {
    active: tui.Style = .{},
    inactive: tui.Style = .{ .dim = true },
    arabic: tui.Style = .{},
};

/// Sets `pages` for `items` items, keeping the page on the last one at most.
pub fn setTotal(p: *Paginator, items: usize) void {
    const per = @max(p.per_page, 1);
    p.pages = @max(1, (items + per - 1) / per);
    p.page = @min(p.page, p.pages - 1);
}

/// The range of item indices on the page, of `items` in all.
pub fn bounds(p: *const Paginator, items: usize) struct { start: usize, end: usize } {
    const start = @min(p.page * p.per_page, items);
    return .{ .start = start, .end = @min(start + p.per_page, items) };
}

pub fn onFirstPage(p: *const Paginator) bool {
    return p.page == 0;
}

pub fn onLastPage(p: *const Paginator) bool {
    return p.page + 1 >= p.pages;
}

pub fn nextPage(p: *Paginator) void {
    if (!p.onLastPage()) p.page += 1;
}

pub fn previousPage(p: *Paginator) void {
    if (!p.onFirstPage()) p.page -= 1;
}

pub fn update(p: *Paginator, msg: tui.Msg) tui.Cmd {
    if (!p.keys or msg != .key) return .none;
    const key = msg.key;
    if (key.matches("right") or key.matches("l") or key.matches("pgdown")) p.nextPage();
    if (key.matches("left") or key.matches("h") or key.matches("pgup")) p.previousPage();
    return .none;
}

pub fn view(p: *const Paginator, w: *Writer) Writer.Error!void {
    switch (p.kind) {
        .arabic => {
            var buffer: [48]u8 = undefined;
            const pages = .{ p.page + 1, p.pages };
            const text = std.fmt.bufPrint(&buffer, "{d}/{d}", pages) catch "";
            try p.styles.arabic.paint(w, text);
        },
        .dots => for (0..p.pages) |i| {
            if (i == p.page) {
                try p.styles.active.paint(w, p.active_dot);
            } else {
                try p.styles.inactive.paint(w, p.inactive_dot);
            }
        },
    }
}

const testing = std.testing;

fn viewOf(p: *const Paginator) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try p.view(&out.writer);
    return out.toOwnedSlice();
}

test "pages of items, turned with keys" {
    var p: Paginator = .{ .per_page = 3, .styles = .{ .inactive = .{} } };
    p.setTotal(7);
    try testing.expectEqual(3, p.pages);
    const first = try viewOf(&p);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("●○○", first);
    _ = p.update(.{ .key = try .parse("right") });
    _ = p.update(.{ .key = try .parse("l") });
    _ = p.update(.{ .key = try .parse("l") });
    try testing.expectEqual(2, p.page);
    const range = p.bounds(7);
    try testing.expectEqual(6, range.start);
    try testing.expectEqual(7, range.end);
    p.kind = .arabic;
    const numbers = try viewOf(&p);
    defer testing.allocator.free(numbers);
    try testing.expectEqualStrings("3/3", numbers);
    p.setTotal(2);
    try testing.expectEqual(0, p.page);
}
