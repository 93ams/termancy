//! A scrollable viewport over long text, with search. Meant for the full screen
//! (`tui.Options.alt_screen`): it fills the terminal's height, the last row a status line.
//!
//! ```zig
//! var pager: Pager = try .init(gpa, text);
//! defer pager.deinit();
//! _ = try tui.run(gpa, io, &pager, .{ .environ = environ, .program = .{ .alt_screen = true } });
//! ```
//!
//! Keys: j/k, down/up, and enter scroll a row; space/f/pgdown and b/pgup a screen; d/u half
//! a screen; g/home and G/end jump to either end. / starts a search: type, enter jumps to
//! the first row from the top of the screen down that contains the text (ignoring ASCII
//! case), esc abandons it; n and N jump to the next and previous match. Every match on
//! screen is highlighted. q quits; esc quits as canceled.
//!
//! Lines are word-wrapped to the terminal width (again on every resize), so each row is a
//! slice of the text; a match broken across two rows is not found. Tabs are not expanded.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Input = @import("input.zig").Input;

pub const Status = enum { active, submitted, canceled };

pub const Pager = struct {
    gpa: Allocator,
    /// The text shown; borrowed.
    text: []const u8,
    /// `text` wrapped to the width, one slice per screen row.
    rows: std.ArrayList([]const u8) = .empty,
    /// The first row on screen.
    offset: usize = 0,
    size: tui.Size = .{ .width = 80, .height = 24 },
    /// The search being typed, or the last one.
    search: Input,
    /// Whether keys go to `search`.
    searching: bool = false,
    /// Shown in the status line until the next key, such as "not found".
    message: []const u8 = "",
    status: Status = .active,
    styles: Styles = .{},

    pub const Styles = struct {
        /// Matches: reversed, so they show under `NO_COLOR`.
        match: tui.Style = .{ .fg = .{ .indexed = 212 }, .reverse = true },
        status: tui.Style = .{ .fg = .{ .indexed = 240 } },
        message: tui.Style = .{ .fg = .{ .indexed = 203 } },
    };

    /// A pager over `text`, wrapped for an 80-column terminal until the first resize.
    pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!Pager {
        var pager: Pager = .{
            .gpa = gpa,
            .text = text,
            .search = .{ .gpa = gpa, .prompt = "/" },
        };
        errdefer pager.deinit();
        try pager.wrap();
        return pager;
    }

    /// Frees the rows and the search.
    pub fn deinit(pager: *Pager) void {
        pager.rows.deinit(pager.gpa);
        pager.search.deinit();
        pager.* = undefined;
    }

    /// Shows `text` (borrowed) instead, keeping the position as far as it allows.
    pub fn setText(pager: *Pager, text: []const u8) Allocator.Error!void {
        pager.text = text;
        try pager.wrap();
    }

    /// Splits the text into rows at the current width.
    fn wrap(pager: *Pager) Allocator.Error!void {
        pager.rows.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, pager.text, '\n');
        while (lines.next()) |raw| {
            if (lines.index == null and raw.len == 0) break; // the text's final newline
            const line = std.mem.trimEnd(u8, raw, "\r");
            var wrapper: tui.width.Wrapper = .init(line, @max(pager.size.width, 1));
            while (wrapper.next()) |row| try pager.rows.append(pager.gpa, row.bytes);
        }
        pager.scrollTo(pager.offset);
    }

    /// Rows of text on screen: all but the status line.
    pub fn bodyHeight(pager: *const Pager) usize {
        return @max(pager.size.height, 2) - 1;
    }

    /// Puts row `row` at the top, as far as the end of the text allows.
    pub fn scrollTo(pager: *Pager, row: usize) void {
        pager.offset = @min(row, pager.rows.items.len -| pager.bodyHeight());
    }

    fn scrollBy(pager: *Pager, delta: isize) void {
        const target = @as(isize, @intCast(pager.offset)) + delta;
        pager.scrollTo(@intCast(@max(0, target)));
    }

    pub fn update(pager: *Pager, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .key => |key| {
                pager.message = "";
                if (pager.searching) {
                    pager.searchKey(key);
                    return .none;
                }
                return pager.viewKey(key);
            },
            .paste => |text| if (pager.searching) pager.search.insert(text) catch {},
            .resize => |size| {
                pager.size = size;
                pager.wrap() catch {};
            },
            .mouse => |mouse| switch (mouse.button) {
                .wheel_up => pager.scrollBy(-3),
                .wheel_down => pager.scrollBy(3),
                else => {},
            },
            else => {},
        }
        return .none;
    }

    fn viewKey(pager: *Pager, key: tui.input.Key) tui.Cmd {
        const page: isize = @intCast(pager.bodyHeight());
        if (key.matches("q")) {
            pager.status = .submitted;
            return .quit;
        } else if (key.matches("esc")) {
            pager.status = .canceled;
            return .quit;
        } else if (key.matches("j") or key.matches("down") or key.matches("enter")) {
            pager.scrollBy(1);
        } else if (key.matches("k") or key.matches("up")) {
            pager.scrollBy(-1);
        } else if (key.matches("space") or key.matches("f") or key.matches("pgdown")) {
            pager.scrollBy(page);
        } else if (key.matches("b") or key.matches("pgup")) {
            pager.scrollBy(-page);
        } else if (key.matches("d")) {
            pager.scrollBy(@divTrunc(page + 1, 2));
        } else if (key.matches("u")) {
            pager.scrollBy(-@divTrunc(page + 1, 2));
        } else if (key.matches("g") or key.matches("home")) {
            pager.scrollTo(0);
        } else if (key.matches("G") or key.matches("end")) {
            pager.scrollTo(pager.rows.items.len);
        } else if (key.matches("/")) {
            pager.searching = true;
            pager.search.setValue("") catch {};
        } else if (key.matches("n")) {
            pager.jump(pager.offset + 1, .forward);
        } else if (key.matches("N")) {
            pager.jump(pager.offset, .backward);
        }
        return .none;
    }

    fn searchKey(pager: *Pager, key: tui.input.Key) void {
        if (key.matches("enter")) {
            pager.searching = false;
            pager.jump(pager.offset, .forward);
        } else if (key.matches("esc")) {
            pager.searching = false;
            pager.search.setValue("") catch {};
        } else {
            _ = pager.search.handleKey(key);
        }
    }

    const Direction = enum { forward, backward };

    /// Scrolls to the first row with a match at or after `from` (forward), or the last one
    /// before it (backward); says so in the status line when there is none.
    fn jump(pager: *Pager, from: usize, direction: Direction) void {
        const pattern = pager.search.value();
        if (pattern.len == 0) return;
        const rows = pager.rows.items;
        const found: ?usize = switch (direction) {
            .forward => for (@min(from, rows.len)..rows.len) |i| {
                if (contains(rows[i], pattern)) break i;
            } else null,
            .backward => blk: {
                var i = @min(from, rows.len);
                while (i > 0) {
                    i -= 1;
                    if (contains(rows[i], pattern)) break :blk i;
                }
                break :blk null;
            },
        };
        if (found) |row| pager.offset = row else pager.message = "Pattern not found";
    }

    pub fn view(pager: *const Pager, w: *Writer) Writer.Error!void {
        const height = pager.bodyHeight();
        const rows = pager.rows.items;
        const pattern = if (pager.searching) "" else pager.search.value();
        for (0..height) |i| {
            const index = pager.offset + i;
            if (index < rows.len) try pager.writeRow(w, rows[index], pattern);
            try w.writeByte('\n');
        }
        try pager.writeStatus(w);
    }

    /// Writes `row` with every occurrence of `pattern` highlighted.
    fn writeRow(
        pager: *const Pager,
        w: *Writer,
        row: []const u8,
        pattern: []const u8,
    ) Writer.Error!void {
        var at: usize = 0;
        while (pattern.len > 0) {
            const found = std.ascii.findIgnoreCasePos(row, at, pattern) orelse break;
            try w.writeAll(row[at..found]);
            try pager.styles.match.paint(w, row[found..][0..pattern.len]);
            at = found + pattern.len;
        }
        try w.writeAll(row[at..]);
    }

    fn writeStatus(pager: *const Pager, w: *Writer) Writer.Error!void {
        if (pager.searching) return pager.search.view(w);
        if (pager.message.len > 0) return pager.styles.message.paint(w, pager.message);
        const total = pager.rows.items.len;
        const last = @min(pager.offset + pager.bodyHeight(), total);
        const percent = if (total == 0) 100 else last * 100 / total;
        try pager.styles.status.writeSgr(w);
        const first = @min(pager.offset + 1, total);
        try w.print("{d}-{d} of {d} ({d}%)", .{ first, last, total, percent });
        if (pager.styles.status.hasSgr()) try w.writeAll(tui.ansi.reset);
    }
};

fn contains(row: []const u8, pattern: []const u8) bool {
    return std.ascii.findIgnoreCase(row, pattern) != null;
}

const testing = std.testing;
const Driver = tui.testing.Driver(Pager);
const poem =
    \\one
    \\two
    \\three
    \\four
    \\five
    \\six
    \\
;

fn startPager(d: *Driver, text: []const u8, size: tui.Size) !void {
    const pager: Pager = try .init(testing.allocator, text);
    d.* = try .init(
        testing.allocator,
        pager,
        .{ .program = .{ .size = size, .alt_screen = true } },
    );
}

fn finish(d: *Driver) void {
    d.deinit();
}

test "scrolling by row, page, and to either end" {
    var d: Driver = undefined;
    try startPager(&d, poem, .{ .width = 20, .height = 4 });
    defer finish(&d);
    try d.expectFrame("one\ntwo\nthree\n1-3 of 6 (50%)");
    try d.press("j");
    try d.expectFrame("two\nthree\nfour\n2-4 of 6 (66%)");
    try d.press("space");
    try d.expectFrame("four\nfive\nsix\n4-6 of 6 (100%)");
    try d.press("j"); // already at the end
    try testing.expectEqual(3, d.model().offset);
    try d.press("b");
    try testing.expectEqual(0, d.model().offset);
    try d.press("G");
    try testing.expectEqual(3, d.model().offset);
    try d.press("u");
    try testing.expectEqual(1, d.model().offset);
    try d.press("g");
    try d.press("d");
    try testing.expectEqual(2, d.model().offset);
    try d.press("q");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
}

test "long lines wrap, and wrap again on resize" {
    var d: Driver = undefined;
    try startPager(&d, "alpha beta gamma\nx", .{ .width = 11, .height = 5 });
    defer finish(&d);
    try d.expectFrame("alpha beta\ngamma\nx\n\n1-3 of 3 (100%)");
    try d.resize(.{ .width = 6, .height = 5 });
    try d.expectFrame("alpha\nbeta\ngamma\nx\n1-4 of 4 (100%)");
}

test "search jumps to matches and highlights them" {
    var d: Driver = undefined;
    try startPager(&d, poem, .{ .width = 20, .height = 3 });
    defer finish(&d);
    try d.press("/");
    try d.typeText("F");
    try d.expectFrame("one\ntwo\n/F ");
    try d.press("enter");
    try d.expectFrame("four\nfive\n4-5 of 6 (83%)");
    try testing.expect(std.mem.indexOf(u8, d.frameBytes(), "\x1b[7;38;5;212mf\x1b[0mour") != null);
    try d.press("n");
    try testing.expectEqual(4, d.model().offset);
    try d.press("n");
    try d.expectFrame("five\nsix\nPattern not found");
    try d.press("N");
    try testing.expectEqual(3, d.model().offset);
    try d.press("g");
    try d.press("/");
    try d.typeText("zzz");
    try d.press("enter");
    try d.expectFrame("one\ntwo\nPattern not found");
    try d.press("/");
    try d.typeText("x");
    try d.press("esc"); // abandons the search, not the pager
    try testing.expect(!d.done());
    try testing.expectEqualStrings("", d.model().search.value());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "empty text" {
    var d: Driver = undefined;
    try startPager(&d, "", .{ .width = 10, .height = 2 });
    defer finish(&d);
    try d.expectFrame("\n0-0 of 0 (100%)");
}

test "the mouse wheel scrolls" {
    var d: Driver = undefined;
    try startPager(&d, poem, .{ .width = 20, .height = 4 });
    defer finish(&d);
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .wheel_down, .action = .press } });
    try testing.expectEqual(3, d.model().offset);
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .wheel_up, .action = .press } });
    try testing.expectEqual(0, d.model().offset);
}
