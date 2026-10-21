//! A table: a header row and data rows in aligned columns, with an optional border, and a
//! highlighted row to choose.
//!
//! ```zig
//! const table: Table = .{
//!     .columns = &.{ .{ .title = "Name" }, .{ .title = "Age", .@"align" = .end } },
//!     .rows = &.{ &.{ "Ada", "36" }, &.{ "Grace", "85" } },
//!     .selectable = false,
//! };
//! try table.view(w);
//! // ╭───────┬─────╮
//! // │ Name  │ Age │
//! // ├───────┼─────┤
//! // │ Ada   │  36 │
//! // │ Grace │  85 │
//! // ╰───────┴─────╯
//! ```
//!
//! Column widths are display widths (`tui.width`): a column is as wide as its widest cell
//! or title, or exactly `Column.width`, cutting longer cells with "…". After a resize, the
//! widest columns narrow until the table fits the terminal's width. Rows with fewer
//! cells than columns are padded with empty cells; extra cells are not shown, nor are
//! columns past `max_columns`.
//!
//! Keys, when `selectable`: up/down (k/j), pgup/pgdown, home/end (g/G) move; enter chooses
//! the highlighted row; esc, q, or ctrl+q cancels. At most `height` rows are shown,
//! scrolling with the highlight; without a `height`, as many as fit the terminal
//! (`reserved` rows left to the rest of the view). Embedded in a larger model, a table
//! takes keys through `handleKey`, which only moves, so quitting stays the parent's choice.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;

pub const Status = enum { active, submitted, canceled };

/// The most columns a table lays out.
pub const max_columns = 64;

const Table = @This();

columns: []const Column,
rows: []const []const []const u8,
/// The highlighted row.
cursor: usize = 0,
/// The first row shown.
offset: usize = 0,
/// The most data rows shown; null fits them to the terminal's height (from the last
/// resize) less `reserved`, or shows them all before a resize.
height: ?usize = null,
/// Rows of the terminal the rest of the view takes, when the table fits it.
reserved: usize = 0,
/// The terminal's size, from the last resize.
screen_height: ?usize = null,
screen_width: ?usize = null,
/// Whether a row is highlighted and can be chosen.
selectable: bool = true,
border: ?Border = .rounded,
/// The screen row this is drawn from, for mouse clicks.
top: usize = 0,
status: Status = .active,
styles: Styles = .{},

pub const Column = struct {
    title: []const u8,
    /// Columns of text; null fits the widest cell.
    width: ?usize = null,
    @"align": tui.layout.Position = .start,
};

pub const Styles = struct {
    header: tui.Style = .{ .fg = .{ .indexed = 99 }, .bold = true },
    cell: tui.Style = .{},
    /// The highlighted row: bold as well as colored, so it shows under `NO_COLOR`.
    selected: tui.Style = .{ .fg = .{ .indexed = 212 }, .bold = true },
    border: tui.Style = .{ .fg = .{ .indexed = 238 } },
};

/// The glyphs of a table's lines. Each must be one column wide.
pub const Border = struct {
    horizontal: []const u8,
    vertical: []const u8,
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    /// Where a column line meets the top, bottom, left, and right edges.
    top: []const u8,
    bottom: []const u8,
    left: []const u8,
    right: []const u8,
    /// Where a column line crosses the line under the header.
    cross: []const u8,

    pub const normal: Border = lines("─", "│", "┌┐└┘", "┬┴├┤┼");
    pub const rounded: Border = lines("─", "│", "╭╮╰╯", "┬┴├┤┼");
    pub const thick: Border = lines("━", "┃", "┏┓┗┛", "┳┻┣┫╋");
    pub const double: Border = lines("═", "║", "╔╗╚╝", "╦╩╠╣╬");
    pub const ascii: Border = lines("-", "|", "++++", "+++++");
    pub const hidden: Border = lines(" ", " ", "    ", "     ");

    /// A border from its edges, four corners, and five junctions (as UTF-8 strings of
    /// that many characters, in field order).
    fn lines(
        comptime horizontal: []const u8,
        comptime vertical: []const u8,
        comptime corners: []const u8,
        comptime junctions: []const u8,
    ) Border {
        const c = split(4, corners);
        const j = split(5, junctions);
        return .{
            .horizontal = horizontal,
            .vertical = vertical,
            .top_left = c[0],
            .top_right = c[1],
            .bottom_left = c[2],
            .bottom_right = c[3],
            .top = j[0],
            .bottom = j[1],
            .left = j[2],
            .right = j[3],
            .cross = j[4],
        };
    }

    fn split(comptime n: usize, comptime text: []const u8) [n][]const u8 {
        var out: [n][]const u8 = undefined;
        const utf8 = std.unicode.Utf8View.initComptime(text);
        var it = utf8.iterator();
        for (&out) |*glyph| glyph.* = it.nextCodepointSlice().?;
        return out;
    }
};

/// As a program of its own: the keys `handleKey` takes, and enter chooses the row and
/// esc cancels, both quitting. Inside a larger model, forward keys to `handleKey`
/// instead and decide there what enter and esc do.
pub fn update(table: *Table, msg: tui.Msg) tui.Cmd {
    const key = switch (msg) {
        .key => |key| key,
        .mouse => |mouse| return table.handleMouse(mouse),
        .resize => |size| {
            table.screen_height = size.height;
            table.screen_width = size.width;
            table.moveTo(table.cursor);
            return .none;
        },
        else => return .none,
    };
    if (key.matches("esc") or key.matches("q") or key.matches("ctrl+q")) {
        table.status = .canceled;
        return .quit;
    }
    if (table.selectable and key.matches("enter") and table.rows.len > 0) {
        table.status = .submitted;
        return .quit;
    }
    _ = table.handleKey(key);
    return .none;
}

/// Moves the highlight on up/down (k/j), pgup/pgdown, and home/end (g/G); whether
/// `key` was one of them. Never quits. A table that is not selectable takes none.
pub fn handleKey(table: *Table, key: tui.input.Key) bool {
    if (!table.selectable) return false;
    const page: isize = @intCast(@max(table.shown() orelse table.rows.len, 1));
    if (key.matches("up") or key.matches("k")) {
        table.moveBy(-1);
    } else if (key.matches("down") or key.matches("j")) {
        table.moveBy(1);
    } else if (key.matches("pgup")) {
        table.moveBy(-page);
    } else if (key.matches("pgdown")) {
        table.moveBy(page);
    } else if (key.matches("home") or key.matches("g")) {
        table.moveTo(0);
    } else if (key.matches("end") or key.matches("G")) {
        table.moveTo(table.rows.len -| 1);
    } else return false;
    return true;
}

/// Moves the highlight by `delta` rows, stopping at either end.
pub fn moveBy(table: *Table, delta: isize) void {
    const target = @as(isize, @intCast(table.cursor)) + delta;
    table.moveTo(@intCast(@max(0, target)));
}

/// Highlights row `index` (clamped) and scrolls it into view.
pub fn moveTo(table: *Table, index: usize) void {
    table.cursor = @min(index, table.rows.len -| 1);
    const height = table.shown() orelse return;
    if (table.cursor < table.offset) table.offset = table.cursor;
    if (table.cursor >= table.offset + height) table.offset = table.cursor + 1 - height;
}

/// The most data rows shown: `height`, or as many as fit the terminal; null for all.
pub fn shown(table: *const Table) ?usize {
    if (table.height) |height| return @max(height, 1);
    const screen = table.screen_height orelse return null;
    // The header, and with a border, the rules above, under, and below.
    const chrome: usize = if (table.border != null) 4 else 1;
    return @max(screen -| table.reserved -| chrome, 1);
}

/// The highlighted (or chosen) row; null when there are none.
pub fn selected(table: *const Table) ?[]const []const u8 {
    if (table.rows.len == 0) return null;
    return table.rows[table.cursor];
}

/// The width of each column, at most `max_columns` of them, narrowed to fit
/// `screen_width`.
pub fn widths(table: *const Table, buffer: *[max_columns]usize) []usize {
    const count = @min(table.columns.len, max_columns);
    for (table.columns[0..count], buffer[0..count], 0..) |column, *width, i| {
        if (column.width) |fixed| {
            width.* = fixed;
            continue;
        }
        width.* = tui.width.of(column.title);
        for (table.rows) |row| {
            if (i < row.len) width.* = @max(width.*, tui.width.of(row[i]));
        }
    }
    const columns = buffer[0..count];
    const limit = table.screen_width orelse return columns;
    // Beside the cells: with a border, a space each side and a line between and around
    // them all; without, two spaces between.
    const around = if (table.border != null) 3 * count + 1 else 2 * (count -| 1);
    var total: usize = around;
    for (columns) |width| total += width;
    while (total > limit) : (total -= 1) {
        const widest = std.mem.indexOfMax(usize, columns);
        if (columns[widest] <= 1) break;
        columns[widest] -= 1;
    }
    return columns;
}

/// The wheel moves the cursor; a left click on a row chooses it. The table starts on
/// screen row `top`.
fn handleMouse(table: *Table, mouse: tui.input.Mouse) tui.Cmd {
    if (!table.selectable) return .none;
    switch (mouse.button) {
        .wheel_up => table.moveBy(-1),
        .wheel_down => table.moveBy(1),
        .left => if (mouse.action == .press) {
            // Above the rows: a top rule, the header, and a rule under it with a border.
            const above: usize = if (table.border != null) 3 else 1;
            if (mouse.y < table.top + above) return .none;
            const index = table.offset + (mouse.y - table.top - above);
            const end = if (table.shown()) |height| table.offset + height else table.rows.len;
            if (index >= @min(end, table.rows.len)) return .none;
            table.moveTo(index);
            table.status = .submitted;
            return .quit;
        },
        else => {},
    }
    return .none;
}

pub fn view(table: *const Table, w: *Writer) Writer.Error!void {
    var buffer: [max_columns]usize = undefined;
    const columns = table.widths(&buffer);
    if (columns.len == 0) return;
    const end = if (table.shown()) |height|
        @min(table.offset + height, table.rows.len)
    else
        table.rows.len;
    const start = @min(table.offset, end);
    if (table.border != null) {
        try table.rule(w, columns, .top);
        try w.writeByte('\n');
    }
    try table.writeHeader(w, columns);
    if (table.border != null) {
        try w.writeByte('\n');
        try table.rule(w, columns, .middle);
    }
    for (table.rows[start..end], start..) |row, i| {
        try w.writeByte('\n');
        const highlighted = table.selectable and i == table.cursor;
        const style = if (highlighted) table.styles.selected else table.styles.cell;
        try table.writeRow(w, columns, row, style);
    }
    if (table.border != null) {
        try w.writeByte('\n');
        try table.rule(w, columns, .bottom);
    }
}

fn writeHeader(table: *const Table, w: *Writer, columns: []const usize) Writer.Error!void {
    var titles: [max_columns][]const u8 = undefined;
    for (titles[0..columns.len], table.columns[0..columns.len]) |*title, column| {
        title.* = column.title;
    }
    try table.writeRow(w, columns, titles[0..columns.len], table.styles.header);
}

fn writeRow(
    table: *const Table,
    w: *Writer,
    columns: []const usize,
    cells: []const []const u8,
    style: tui.Style,
) Writer.Error!void {
    // Inside a border, cells have a space on each side; without one, two spaces
    // separate them.
    const pad: []const u8 = if (table.border != null) " " else "";
    for (columns, 0..) |width, i| {
        if (table.border) |border| {
            try table.styles.border.paint(w, border.vertical);
        } else if (i > 0) {
            try w.writeAll("  ");
        }
        const cell = if (i < cells.len) cells[i] else "";
        try style.writeSgr(w);
        try w.writeAll(pad);
        try writeCell(w, cell, width, table.columns[i].@"align");
        try w.writeAll(pad);
        if (style.hasSgr()) try w.writeAll(tui.ansi.reset);
    }
    if (table.border) |border| try table.styles.border.paint(w, border.vertical);
}

const Edge = enum { top, middle, bottom };

fn rule(table: *const Table, w: *Writer, columns: []const usize, edge: Edge) Writer.Error!void {
    const b = table.border.?;
    const glyphs: [3][]const u8 = switch (edge) {
        .top => .{ b.top_left, b.top, b.top_right },
        .middle => .{ b.left, b.cross, b.right },
        .bottom => .{ b.bottom_left, b.bottom, b.bottom_right },
    };
    try table.styles.border.writeSgr(w);
    try w.writeAll(glyphs[0]);
    for (columns, 0..) |width, i| {
        if (i > 0) try w.writeAll(glyphs[1]);
        try w.splatBytesAll(b.horizontal, width + 2);
    }
    try w.writeAll(glyphs[2]);
    if (table.styles.border.hasSgr()) try w.writeAll(tui.ansi.reset);
}

/// Writes `cell` in exactly `width` columns: aligned when it fits, cut with "…" when not.
pub fn writeCell(
    w: *Writer,
    cell: []const u8,
    width: usize,
    position: tui.layout.Position,
) Writer.Error!void {
    const cell_width = tui.width.of(cell);
    if (cell_width <= width) return tui.layout.writePadded(w, cell, width, position);
    try tui.width.truncate(w, cell, width, "…");
    try w.splatByteAll(' ', width - cutWidth(cell, width));
}

/// The width `tui.width.truncate` leaves when it cuts `text` to `width` with "…": as many
/// whole clusters as fit before the ellipsis, plus the ellipsis.
fn cutWidth(text: []const u8, width: usize) usize {
    if (width == 0) return 0;
    var used: usize = 0;
    var it: tui.width.Iterator = .init(text);
    while (it.next()) |cluster| {
        if (used + cluster.width > width - 1) break;
        used += cluster.width;
    }
    return used + 1;
}

const testing = std.testing;

const people = [_][]const []const u8{
    &.{ "Ada", "36", "London" },
    &.{ "Grace", "85" },
    &.{ "Linus", "54", "Helsinki" },
};
const person_columns = [_]Table.Column{
    .{ .title = "Name" },
    .{ .title = "Age", .@"align" = .end },
    .{ .title = "City" },
};

fn expectView(table: Table, expected: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try table.view(&out.writer);
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try tui.ansi.strip(&plain.writer, out.written());
    try testing.expectEqualStrings(expected, plain.written());
}

test "a bordered table, aligned and padded" {
    try expectView(.{ .columns = &person_columns, .rows = &people, .selectable = false },
        \\╭───────┬─────┬──────────╮
        \\│ Name  │ Age │ City     │
        \\├───────┼─────┼──────────┤
        \\│ Ada   │  36 │ London   │
        \\│ Grace │  85 │          │
        \\│ Linus │  54 │ Helsinki │
        \\╰───────┴─────┴──────────╯
    );
}

test "fixed widths cut cells; no border" {
    const columns = [_]Table.Column{ .{ .title = "Name", .width = 4 }, .{ .title = "Age" } };
    try expectView(
        .{ .columns = &columns, .rows = &people, .border = null, .selectable = false },
        "Name  Age\nAda   36 \nGra…  85 \nLin…  54 ",
    );
}

test "the ascii border and wide characters" {
    const columns = [_]Table.Column{.{ .title = "名前" }};
    const rows = [_][]const []const u8{&.{"x"}};
    try expectView(.{ .columns = &columns, .rows = &rows, .border = .ascii },
        \\+------+
        \\| 名前 |
        \\+------+
        \\| x    |
        \\+------+
    );
}

test "the highlighted row is styled" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const columns = [_]Table.Column{.{ .title = "A" }};
    const rows = [_][]const []const u8{ &.{"1"}, &.{"2"} };
    const table: Table = .{
        .columns = &columns,
        .rows = &rows,
        .border = null,
        .cursor = 1,
        .styles = .{ .header = .{}, .selected = .{ .reverse = true } },
    };
    try table.view(&out.writer);
    try testing.expectEqualStrings("A\n1\n\x1b[7m2\x1b[0m", out.written());
}

test "keys move the highlight and choose a row" {
    var d: tui.testing.Driver(Table) = try .init(testing.allocator, .{
        .columns = &person_columns,
        .rows = &people,
        .height = 2,
        .border = null,
    }, .{});
    defer d.deinit();
    try d.expectFrame("Name   Age  City    \nAda     36  London  \nGrace   85          ");
    try d.press("down");
    try d.press("j");
    try d.expectFrame("Name   Age  City    \nGrace   85          \nLinus   54  Helsinki");
    try d.press("home");
    try testing.expectEqual(0, d.model().offset);
    try d.press("pgdown");
    try testing.expectEqual(2, d.model().cursor);
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqualStrings("Linus", d.model().selected().?[0]);
}

test "without a height, the rows fit the terminal" {
    var d: tui.testing.Driver(Table) = try .init(testing.allocator, .{
        .columns = &person_columns,
        .rows = &people,
        .border = null,
        .reserved = 1,
    }, .{ .program = .{ .size = .{ .width = 30, .height = 4 } } });
    defer d.deinit();
    // Four rows less one reserved and one for the header.
    try testing.expectEqual(2, d.model().shown().?);
    try d.press("end");
    try d.expectFrame("Name   Age  City    \nGrace   85          \nLinus   54  Helsinki");
    try d.resize(.{ .width = 30, .height = 10 });
    try testing.expectEqual(8, d.model().shown().?);
}

test "the widest columns narrow to fit the terminal; q cancels" {
    var d: tui.testing.Driver(Table) = try .init(testing.allocator, .{
        .columns = &person_columns,
        .rows = &people,
        .border = null,
        .height = 1,
    }, .{ .program = .{ .size = .{ .width = 16, .height = 10 } } });
    defer d.deinit();
    try d.expectFrame("Name  Age  City \nAda    36  Lond…");
    try d.press("q");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "esc cancels; a table that is not selectable ignores the rest" {
    var d: tui.testing.Driver(Table) = try .init(testing.allocator, .{
        .columns = &person_columns,
        .rows = &people,
        .selectable = false,
    }, .{});
    defer d.deinit();
    try d.press("down");
    try d.press("enter");
    try testing.expect(!d.done());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "handleKey moves and never quits; the parent keeps enter and esc" {
    var table: Table = .{ .columns = &person_columns, .rows = &people, .height = 2 };
    try testing.expect(table.handleKey(.{ .code = .down }));
    try testing.expect(table.handleKey(.{ .code = .end }));
    try testing.expectEqual(2, table.cursor);
    try testing.expectEqual(1, table.offset);
    try testing.expect(!table.handleKey(.{ .code = .escape }));
    try testing.expect(!table.handleKey(.{ .code = .enter }));
    try testing.expectEqual(Status.active, table.status);
    table.selectable = false;
    try testing.expect(!table.handleKey(.{ .code = .up }));
}

test "a table without columns draws nothing" {
    try expectView(.{ .columns = &.{}, .rows = &people }, "");
}

test writeCell {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeCell(&w, "abc", 5, .center);
    try w.writeAll("|");
    try writeCell(&w, "abcdef", 4, .end);
    try w.writeAll("|");
    try writeCell(&w, "中文字", 4, .start);
    try writeCell(&w, "x", 0, .start);
    try testing.expectEqualStrings(" abc |abc…|中… ", w.buffered());
}

test "the mouse: the wheel moves, a click chooses a row" {
    var d: tui.testing.Driver(Table) = undefined;
    const table: Table = .{ .columns = &person_columns, .rows = &people, .border = null };
    d = try .init(testing.allocator, table, .{});
    defer d.deinit();
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .wheel_down, .action = .press } });
    try testing.expectEqual(1, d.model().cursor);
    // Row 0 is the header; nothing happens there.
    try d.send(.{ .mouse = .{ .x = 0, .y = 0, .button = .left, .action = .press } });
    try testing.expect(!d.done());
    try d.send(.{ .mouse = .{ .x = 0, .y = 3, .button = .left, .action = .press } });
    try testing.expect(d.done());
    try testing.expectEqualStrings("Linus", d.model().selected().?[0]);
}
