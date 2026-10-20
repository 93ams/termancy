//! A virtual terminal: what a screen shows after a program's output, as xterm-compatible
//! terminals interpret it. Runs anything a real terminal runs (shells, editors, `tui`
//! programs) when its output is fed to `Screen.write`, which is how `tui.testing` checks
//! redraws, `termancy record` turns sessions into GIFs, and `termancy freeze` captures
//! command output.
//!
//! ```zig
//! var screen: term.vt.Screen = try .init(gpa, .{ .width = 80, .height = 24 });
//! defer screen.deinit();
//! screen.write("\x1b[1;31mhello\x1b[0m\r\n");
//! const text = try screen.textAlloc(gpa); // "hello"
//! ```
//!
//! Interpreted: printing with autowrap and the pending-wrap column, grapheme clusters
//! (combining marks, emoji sequences) and wide characters; C0 controls; cursor movement
//! (`CUU` ... `CUP`, `HPA`, `VPA`, `CHT`, `CBT`, tab stops); erasing (`ED`, `EL`, `ECH`);
//! inserting and deleting characters and lines (`ICH`, `DCH`, `IL`, `DL`, `REP`); scroll
//! regions and scrolling (`DECSTBM`, `SU`, `SD`, `IND`, `RI`, `NEL`); saving the cursor
//! (`DECSC`, `DECRC`, `SCOSC`, `SCORC`, mode 1048); every SGR attribute (`Pen`); the
//! alternate screen (modes 47, 1047, 1049); origin, autowrap, insert, and newline modes;
//! the DEC line-drawing character set; cursor visibility and shape (`DECSCUSR`); OSC
//! titles, hyperlinks (OSC 8), colors (OSC 4, 10, 11), and the clipboard (OSC 52); soft and
//! full resets; and a scrollback of the main screen's lines that scroll off the top.
//!
//! A real terminal answers some sequences (device attributes, cursor position, mode and
//! color queries, the kitty keyboard flags). Their answers collect in `responses`, for a
//! host that runs a program on a pseudo-terminal to send back as input.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ansi = @import("ansi.zig");
const width = @import("width.zig");
const Parser = @import("Parser.zig");
const Pen = @import("Pen.zig");
const Terminal = @import("Terminal.zig");

/// A size in cells.
pub const Size = Terminal.Size;

/// One cell of the grid.
pub const Cell = struct {
    /// The grapheme cluster drawn here; empty for a blank cell and for the right half of a
    /// wide character. Clusters longer than this keep their start.
    text: [max_cluster]u8 = undefined,
    len: u8 = 0,
    /// The right half of a wide character, which the cell before draws.
    tail: bool = false,
    /// The left half of a wide character.
    wide: bool = false,
    pen: Pen = .{},
    /// The hyperlink, as an index into `Screen.links` plus one; 0 for none.
    link: u16 = 0,

    /// The most bytes a cell's grapheme cluster keeps.
    pub const max_cluster = 24;

    /// The cluster's bytes.
    pub fn bytes(cell: *const Cell) []const u8 {
        return cell.text[0..cell.len];
    }

    /// Whether nothing is drawn here (a space, blank, or the tail of a wide character).
    pub fn isBlank(cell: *const Cell) bool {
        return cell.len == 0 or (cell.len == 1 and cell.text[0] == ' ');
    }
};

/// The shape of the cursor, as `DECSCUSR` sets it.
pub const CursorShape = enum { block, underline, bar };

/// A grid of cells: the main or the alternate screen.
pub const Grid = struct {
    cells: []Cell,
    /// Whether each row continues onto the next (it was filled and wrapped).
    wrapped: []bool,

    fn init(gpa: Allocator, size: Size) Allocator.Error!Grid {
        const cells = try gpa.alloc(Cell, @as(usize, size.width) * size.height);
        errdefer gpa.free(cells);
        const wrapped = try gpa.alloc(bool, size.height);
        @memset(cells, .{});
        @memset(wrapped, false);
        return .{ .cells = cells, .wrapped = wrapped };
    }

    fn deinit(grid: *Grid, gpa: Allocator) void {
        gpa.free(grid.cells);
        gpa.free(grid.wrapped);
    }
};

/// The cursor and what `DECSC` saves with it.
const Cursor = struct {
    row: usize = 0,
    column: usize = 0,
    pending_wrap: bool = false,
    pen: Pen = .{},
    origin: bool = false,
    charsets: [2]Charset = .{ .ascii, .ascii },
    shift: u1 = 0,
};

const Charset = enum { ascii, dec_special };

/// A line that scrolled off the top of the main screen.
pub const Line = struct {
    cells: []Cell,
    wrapped: bool,
};

/// How `Screen.init` sets up a screen.
pub const Options = struct {
    /// Lines kept after they scroll off the top of the main screen; 0 keeps none.
    scrollback: usize = 0,
};

/// A terminal emulator: what a terminal would show after the bytes written to it.
pub const Screen = struct {
    gpa: Allocator,
    size: Size,
    main: Grid,
    alt: Grid,
    on_alt: bool = false,
    /// The cursor position, 0-based.
    row: usize = 0,
    column: usize = 0,
    /// The cursor is past the last column; the next character wraps first.
    pending_wrap: bool = false,
    /// The colors and attributes characters are printed with.
    pen: Pen = .{},
    /// The hyperlink characters are printed with (see `Cell.link`).
    link: u16 = 0,
    /// `DECSC` slots for the main and the alternate screen.
    saved: [2]Cursor = .{ .{}, .{} },
    /// The scroll region, inclusive.
    top: usize = 0,
    bottom: usize,
    cursor_visible: bool = true,
    cursor_shape: CursorShape = .block,
    cursor_blink: bool = true,
    /// DEC private modes and ANSI modes that are not flags above.
    autowrap: bool = true,
    insert: bool = false,
    origin: bool = false,
    newline: bool = false,
    reverse_video: bool = false,
    application_cursor: bool = false,
    application_keypad: bool = false,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    mouse: Mouse = .off,
    mouse_sgr: bool = false,
    synchronized: bool = false,
    charsets: [2]Charset = .{ .ascii, .ascii },
    shift: u1 = 0,
    tabs: []bool,
    /// The window title (OSC 0 or 2).
    title: std.ArrayList(u8) = .empty,
    /// What OSC 52 last put on the clipboard, decoded.
    clipboard: std.ArrayList(u8) = .empty,
    /// The URLs of hyperlinks, in the order first seen.
    links: std.ArrayList([]u8) = .empty,
    /// The bytes the terminal sends back in answer to queries, until `takeResponses`.
    responses: std.ArrayList(u8) = .empty,
    /// How many times BEL rang.
    bells: usize = 0,
    /// The kitty keyboard protocol's flags, as a stack (`CSI > u` pushes, `CSI < u` pops).
    keyboard_flags: [8]u8 = @splat(0),
    keyboard_depth: u3 = 0,
    /// The colors OSC 10 and 11 report and that `.default` draws as.
    foreground: ansi.Color.Rgb = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 },
    background: ansi.Color.Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
    /// Draw bold text in the first 8 colors in their bright variants, as xterm and older
    /// terminals do.
    bold_is_bright: bool = false,
    /// Palette overrides from OSC 4.
    palette: [256]?ansi.Color.Rgb = @splat(null),
    scrollback: std.ArrayList(Line) = .empty,
    scrollback_limit: usize = 0,
    parser: Parser = .{},
    /// For joining a codepoint to the cluster printed before it.
    segmenter: width.Segmenter = .{},
    /// Where the last cluster was printed, while the next codepoint may join it.
    last_printed: ?struct { row: usize, column: usize } = null,

    /// What the program asked the mouse to report.
    pub const Mouse = enum { off, press, drag, motion };

    /// The largest grid `init` accepts, in cells.
    pub const max_cells = 1 << 22;

    /// A blank screen with the cursor at the top left.
    pub fn init(gpa: Allocator, size: Size) Allocator.Error!Screen {
        return initOptions(gpa, size, .{});
    }

    /// `init`, with options.
    pub fn initOptions(gpa: Allocator, size: Size, options: Options) Allocator.Error!Screen {
        assert(size.width > 0 and size.height > 0);
        var main: Grid = try .init(gpa, size);
        errdefer main.deinit(gpa);
        var alt: Grid = try .init(gpa, size);
        errdefer alt.deinit(gpa);
        const tabs = try gpa.alloc(bool, size.width);
        defaultTabs(tabs);
        return .{
            .gpa = gpa,
            .size = size,
            .main = main,
            .alt = alt,
            .bottom = size.height - 1,
            .tabs = tabs,
            .scrollback_limit = options.scrollback,
        };
    }

    fn defaultTabs(tabs: []bool) void {
        for (tabs, 0..) |*tab, i| tab.* = i % 8 == 0 and i > 0;
    }

    /// Frees everything.
    pub fn deinit(s: *Screen) void {
        s.main.deinit(s.gpa);
        s.alt.deinit(s.gpa);
        s.gpa.free(s.tabs);
        s.title.deinit(s.gpa);
        s.clipboard.deinit(s.gpa);
        for (s.links.items) |url| s.gpa.free(url);
        s.links.deinit(s.gpa);
        s.responses.deinit(s.gpa);
        for (s.scrollback.items) |line| s.gpa.free(line.cells);
        s.scrollback.deinit(s.gpa);
        s.* = undefined;
    }

    /// The grid on screen.
    pub fn grid(s: *Screen) *Grid {
        return if (s.on_alt) &s.alt else &s.main;
    }

    /// The cell at `row`, `column` of the grid on screen.
    pub fn cell(s: *Screen, row: usize, column: usize) *Cell {
        return &s.grid().cells[row * s.size.width + column];
    }

    /// The cells of `row`.
    pub fn rowCells(s: *Screen, row: usize) []Cell {
        const w = s.size.width;
        return s.grid().cells[row * w ..][0..w];
    }

    /// Changes the size, keeping the top left of each grid (no reflow) and the cursor on
    /// screen. The scroll region becomes the whole screen.
    pub fn resize(s: *Screen, size: Size) Allocator.Error!void {
        assert(size.width > 0 and size.height > 0);
        if (std.meta.eql(size, s.size)) return;
        var main: Grid = try .init(s.gpa, size);
        errdefer main.deinit(s.gpa);
        var alt: Grid = try .init(s.gpa, size);
        errdefer alt.deinit(s.gpa);
        const tabs = try s.gpa.alloc(bool, size.width);
        defaultTabs(tabs);
        for ([_]*Grid{ &s.main, &s.alt }, [_]*Grid{ &main, &alt }) |from, to| {
            for (0..@min(s.size.height, size.height)) |r| {
                for (0..@min(s.size.width, size.width)) |c| {
                    to.cells[r * size.width + c] = from.cells[r * s.size.width + c];
                }
                // A wide character cut at the new right edge loses its left half too.
                if (size.width < s.size.width) {
                    const edge = &to.cells[r * size.width + size.width - 1];
                    if (edge.wide) edge.* = .{ .pen = .{ .bg = edge.pen.bg } };
                }
                to.wrapped[r] = from.wrapped[r] and size.width == s.size.width;
            }
        }
        s.main.deinit(s.gpa);
        s.alt.deinit(s.gpa);
        s.gpa.free(s.tabs);
        s.main = main;
        s.alt = alt;
        s.tabs = tabs;
        s.size = size;
        s.top = 0;
        s.bottom = size.height - 1;
        s.row = @min(s.row, size.height - 1);
        s.column = @min(s.column, size.width - 1);
        s.pending_wrap = false;
        s.last_printed = null;
        for (&s.saved) |*saved| {
            saved.row = @min(saved.row, size.height - 1);
            saved.column = @min(saved.column, size.width - 1);
        }
    }

    /// Interprets `bytes` as output to the terminal.
    pub fn write(s: *Screen, bytes: []const u8) void {
        s.parser.feed(bytes, s);
    }

    /// The bytes the terminal would send back since the last call; the caller owns them.
    pub fn takeResponses(s: *Screen) Allocator.Error![]u8 {
        return s.responses.toOwnedSlice(s.gpa);
    }

    fn respond(s: *Screen, comptime fmt: []const u8, args: anytype) void {
        // Losing an answer to a full memory is better than losing the screen.
        s.responses.print(s.gpa, fmt, args) catch {};
    }

    // Parser actions.

    /// For `Parser`: a printable codepoint.
    pub fn print(s: *Screen, cp_in: u21) void {
        var cp = cp_in;
        const set = s.charsets[s.shift];
        if (set == .dec_special and cp >= 0x5f and cp <= 0x7e) cp = dec_special[cp - 0x5f];
        const props = width.properties(cp);
        const joins = s.last_printed != null and !s.segmenter.breaksBefore(props);
        if (!joins) {
            // `breaksBefore` has moved past `cp` either way; restart from it for a new
            // cluster.
            s.segmenter = .{};
            _ = s.segmenter.breaksBefore(props);
        }
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buffer) catch return;
        if (joins) return s.join(buffer[0..len], cp);
        if (props.width == 0) return; // a mark with nothing to mark
        s.printCluster(buffer[0..len], props.width);
    }

    /// Adds `bytes` to the cluster printed last, widening it for VS16.
    fn join(s: *Screen, bytes: []const u8, cp: u21) void {
        const at = s.last_printed.?;
        const target = s.cell(at.row, at.column);
        if (target.len + bytes.len <= Cell.max_cluster) {
            @memcpy(target.text[target.len..][0..bytes.len], bytes);
            target.len += @intCast(bytes.len);
        }
        if (cp == 0xfe0f and !target.wide and at.column + 1 < s.size.width) {
            target.wide = true;
            s.cell(at.row, at.column + 1).* = .{ .tail = true, .pen = target.pen };
            if (at.row == s.row and s.column == at.column + 1) {
                s.column += 1;
                if (s.column >= s.size.width) {
                    s.column = s.size.width - 1;
                    s.pending_wrap = true;
                }
            }
        }
    }

    fn printCluster(s: *Screen, bytes: []const u8, cluster_width: u2) void {
        const w = s.size.width;
        if (s.pending_wrap and s.autowrap) {
            s.grid().wrapped[s.row] = true;
            s.column = 0;
            s.lineFeed();
        }
        s.pending_wrap = false;
        if (cluster_width == 2 and s.column + 1 >= w) {
            if (!s.autowrap or w < 2) return;
            // A wide character does not fit in the last column: it wraps whole.
            s.clearCell(s.row, s.column);
            s.grid().wrapped[s.row] = true;
            s.column = 0;
            s.lineFeed();
        }
        if (s.insert) s.insertBlanks(cluster_width);
        s.splitWide(s.row, s.column);
        if (cluster_width == 2) s.splitWide(s.row, s.column + 1);
        const target = s.cell(s.row, s.column);
        target.* = .{ .pen = s.pen, .link = s.link, .wide = cluster_width == 2 };
        @memcpy(target.text[0..bytes.len], bytes);
        target.len = @intCast(bytes.len);
        if (cluster_width == 2) s.cell(s.row, s.column + 1).* = .{
            .tail = true,
            .pen = s.pen,
            .link = s.link,
        };
        s.last_printed = .{ .row = s.row, .column = s.column };
        s.column += cluster_width;
        if (s.column >= w) {
            s.column = w - 1;
            s.pending_wrap = true;
        }
    }

    /// Before overwriting `column`, clears the other half of a wide character there.
    fn splitWide(s: *Screen, row: usize, column: usize) void {
        const target = s.cell(row, column);
        if (target.tail and column > 0) s.clearCell(row, column - 1);
        if (target.wide and column + 1 < s.size.width) s.clearCell(row, column + 1);
    }

    /// Blanks the halves of wide characters an edit separated: a left half not followed
    /// by its right half, and a right half not preceded by its left.
    fn repairRow(s: *Screen, row: usize) void {
        const cells = s.rowCells(row);
        for (cells, 0..) |*c, i| {
            if (c.wide and (i + 1 == cells.len or !cells[i + 1].tail)) c.* = s.blank();
            if (c.tail and (i == 0 or !cells[i - 1].wide)) c.* = s.blank();
        }
    }

    fn clearCell(s: *Screen, row: usize, column: usize) void {
        s.cell(row, column).* = s.blank();
    }

    /// An erased cell: blank, in the current background (as xterm erases).
    fn blank(s: *const Screen) Cell {
        return .{ .pen = .{ .bg = s.pen.bg } };
    }

    /// For `Parser`: a control character.
    pub fn execute(s: *Screen, byte: u8) void {
        s.last_printed = null;
        switch (byte) {
            0x07 => s.bells += 1,
            0x08 => {
                if (s.pending_wrap) {
                    s.pending_wrap = false;
                } else {
                    s.column -|= 1;
                }
            },
            0x09 => s.tabForward(1),
            0x0a, 0x0b, 0x0c => {
                s.lineFeed();
                if (s.newline) s.column = 0;
                s.pending_wrap = false;
            },
            0x0d => {
                s.column = 0;
                s.pending_wrap = false;
            },
            0x0e => s.shift = 1,
            0x0f => s.shift = 0,
            else => {},
        }
    }

    /// Down a row, scrolling the region at its bottom.
    fn lineFeed(s: *Screen) void {
        if (s.row == s.bottom) {
            s.scrollUp(1);
        } else if (s.row + 1 < s.size.height) {
            s.row += 1;
        }
    }

    /// Up a row, scrolling the region down at its top.
    fn reverseIndex(s: *Screen) void {
        if (s.row == s.top) {
            s.scrollDown(1);
        } else if (s.row > 0) {
            s.row -= 1;
        }
    }

    /// Scrolls the region up `n` rows: its top rows go (to the scrollback, for a main
    /// screen whose region starts at the top), blank rows come in at its bottom.
    fn scrollUp(s: *Screen, n_in: usize) void {
        const n = @min(n_in, s.bottom - s.top + 1);
        if (!s.on_alt and s.top == 0) {
            for (0..n) |r| s.keepLine(r);
        }
        s.moveRows(s.top + n, s.top, s.bottom + 1 - s.top - n);
        s.blankRows(s.bottom + 1 - n, n);
    }

    fn scrollDown(s: *Screen, n_in: usize) void {
        const n = @min(n_in, s.bottom - s.top + 1);
        s.moveRows(s.top, s.top + n, s.bottom + 1 - s.top - n);
        s.blankRows(s.top, n);
    }

    fn keepLine(s: *Screen, row: usize) void {
        if (s.scrollback_limit == 0) return;
        const cells = s.gpa.dupe(Cell, s.rowCells(row)) catch return;
        if (s.scrollback.items.len == s.scrollback_limit) {
            s.gpa.free(s.scrollback.orderedRemove(0).cells);
        }
        s.scrollback.append(s.gpa, .{ .cells = cells, .wrapped = s.grid().wrapped[row] }) catch {
            s.gpa.free(cells);
        };
    }

    /// Moves `count` rows starting at `from` to start at `to`.
    fn moveRows(s: *Screen, from: usize, to: usize, count: usize) void {
        if (count == 0 or from == to) return;
        const w = s.size.width;
        const g = s.grid();
        const source = g.cells[from * w ..][0 .. count * w];
        const target = g.cells[to * w ..][0 .. count * w];
        if (to < from) {
            std.mem.copyForwards(Cell, target, source);
            std.mem.copyForwards(bool, g.wrapped[to..][0..count], g.wrapped[from..][0..count]);
        } else {
            std.mem.copyBackwards(Cell, target, source);
            std.mem.copyBackwards(bool, g.wrapped[to..][0..count], g.wrapped[from..][0..count]);
        }
    }

    fn blankRows(s: *Screen, from: usize, count: usize) void {
        const w = s.size.width;
        const g = s.grid();
        @memset(g.cells[from * w ..][0 .. count * w], s.blank());
        @memset(g.wrapped[from..][0..count], false);
    }

    fn tabForward(s: *Screen, n: usize) void {
        for (0..n) |_| {
            var c = s.column + 1;
            while (c < s.size.width and !s.tabs[c]) c += 1;
            s.column = @min(c, s.size.width - 1);
        }
        s.pending_wrap = false;
    }

    fn tabBackward(s: *Screen, n: usize) void {
        for (0..n) |_| {
            if (s.column == 0) break;
            var c = s.column - 1;
            while (c > 0 and !s.tabs[c]) c -= 1;
            s.column = c;
        }
        s.pending_wrap = false;
    }

    /// For `Parser`: `ESC final`.
    pub fn esc(s: *Screen, seq: Parser.Esc) void {
        s.last_printed = null;
        if (seq.intermediates.len == 1) {
            const slot: ?u1 = switch (seq.intermediates[0]) {
                '(' => 0,
                ')' => 1,
                else => null,
            };
            if (slot) |g| {
                s.charsets[g] = if (seq.final == '0') .dec_special else .ascii;
                return;
            }
            if (seq.intermediates[0] == '#' and seq.final == '8') return s.alignmentTest();
            return;
        }
        if (seq.intermediates.len != 0) return;
        switch (seq.final) {
            '7' => s.saveCursor(),
            '8' => s.restoreCursor(),
            'D' => {
                s.lineFeed();
                s.pending_wrap = false;
            },
            'E' => {
                s.lineFeed();
                s.column = 0;
                s.pending_wrap = false;
            },
            'M' => {
                s.reverseIndex();
                s.pending_wrap = false;
            },
            'H' => s.tabs[s.column] = true,
            'c' => s.fullReset(),
            '=' => s.application_keypad = true,
            '>' => s.application_keypad = false,
            else => {},
        }
    }

    fn alignmentTest(s: *Screen) void {
        for (s.grid().cells) |*c| {
            c.* = .{};
            c.text[0] = 'E';
            c.len = 1;
        }
        s.top = 0;
        s.bottom = s.size.height - 1;
        s.row = 0;
        s.column = 0;
    }

    fn saveCursor(s: *Screen) void {
        s.saved[@intFromBool(s.on_alt)] = .{
            .row = s.row,
            .column = s.column,
            .pending_wrap = s.pending_wrap,
            .pen = s.pen,
            .origin = s.origin,
            .charsets = s.charsets,
            .shift = s.shift,
        };
    }

    fn restoreCursor(s: *Screen) void {
        const saved = s.saved[@intFromBool(s.on_alt)];
        s.row = @min(saved.row, s.size.height - 1);
        s.column = @min(saved.column, s.size.width - 1);
        s.pending_wrap = saved.pending_wrap;
        s.pen = saved.pen;
        s.origin = saved.origin;
        s.charsets = saved.charsets;
        s.shift = saved.shift;
    }

    /// `RIS`: everything as `init` left it, the size, scrollback, and links aside.
    fn fullReset(s: *Screen) void {
        s.on_alt = false;
        for ([_]*Grid{ &s.main, &s.alt }) |g| {
            @memset(g.cells, .{});
            @memset(g.wrapped, false);
        }
        s.softReset();
        s.row = 0;
        s.column = 0;
        s.saved = .{ .{}, .{} };
        s.title.clearRetainingCapacity();
        s.reverse_video = false;
        s.application_keypad = false;
        s.bracketed_paste = false;
        s.focus_events = false;
        s.mouse = .off;
        s.mouse_sgr = false;
        s.keyboard_depth = 0;
        s.palette = @splat(null);
        defaultTabs(s.tabs);
    }

    /// `DECSTR`: modes and attributes to their defaults, the screen kept.
    fn softReset(s: *Screen) void {
        s.pen = .{};
        s.link = 0;
        s.top = 0;
        s.bottom = s.size.height - 1;
        s.cursor_visible = true;
        s.cursor_shape = .block;
        s.cursor_blink = true;
        s.autowrap = true;
        s.insert = false;
        s.origin = false;
        s.newline = false;
        s.application_cursor = false;
        s.charsets = .{ .ascii, .ascii };
        s.shift = 0;
        s.pending_wrap = false;
        s.synchronized = false;
    }

    /// For `Parser`: a control sequence.
    pub fn csi(s: *Screen, seq: Parser.Csi) void {
        s.last_printed = null;
        if (seq.private == '?') return s.privateCsi(seq);
        if (seq.private == '>') return s.greaterCsi(seq);
        if (seq.private == '<') {
            if (seq.final == 'u' and seq.intermediates.len == 0) {
                const n = seq.param(0, 1);
                s.keyboard_depth -|= @intCast(@min(n, 7));
            }
            return;
        }
        if (seq.private == '=') {
            if (seq.final == 'u') s.keyboard_flags[s.keyboard_depth] = @truncate(seq.param(0, 0));
            return;
        }
        if (seq.intermediates.len > 0) return s.intermediateCsi(seq);
        const n: usize = @max(seq.param(0, 1), 1);
        const last_row = s.size.height - 1;
        const last_column = s.size.width - 1;
        switch (seq.final) {
            '@' => s.insertBlanks(n),
            'A' => s.cursorUp(n),
            'B', 'e' => s.cursorDown(n),
            'C', 'a' => s.moveColumn(@min(s.column + n, last_column)),
            'D' => s.moveColumn(s.column -| n),
            'E' => {
                s.cursorDown(n);
                s.column = 0;
            },
            'F' => {
                s.cursorUp(n);
                s.column = 0;
            },
            'G', '`' => s.moveColumn(@min(n - 1, last_column)),
            'H', 'f' => s.cursorTo(seq.param(0, 1), seq.param(1, 1)),
            'I' => s.tabForward(n),
            'J' => s.eraseDisplay(seq.param(0, 0)),
            'K' => s.eraseLine(seq.param(0, 0)),
            'L' => s.insertLines(n),
            'M' => s.deleteLines(n),
            'P' => s.deleteChars(n),
            'S' => s.scrollUp(n),
            'T' => s.scrollDown(n),
            'X' => s.eraseChars(n),
            'Z' => s.tabBackward(n),
            'b' => s.repeat(n),
            'c' => if (seq.param(0, 0) == 0) s.respond("\x1b[?62;22c", .{}),
            'd' => {
                const row = @min(n - 1, last_row);
                s.row = if (s.origin) @min(s.top + n - 1, s.bottom) else row;
                s.pending_wrap = false;
            },
            'g' => switch (seq.param(0, 0)) {
                0 => s.tabs[s.column] = false,
                3 => @memset(s.tabs, false),
                else => {},
            },
            'h', 'l' => s.ansiModes(seq, seq.final == 'h'),
            'm' => s.pen.apply(seq.params),
            'n' => switch (seq.param(0, 0)) {
                5 => s.respond("\x1b[0n", .{}),
                6 => {
                    const row = if (s.origin) s.row -| s.top else s.row;
                    s.respond("\x1b[{d};{d}R", .{ row + 1, s.column + 1 });
                },
                else => {},
            },
            'r' => {
                const top = @max(seq.param(0, 1), 1) - 1;
                const given: usize = if (seq.count() > 1) seq.param(1, 0) else 0;
                const bottom = @min(given, s.size.height);
                const b = if (bottom == 0) last_row else bottom - 1;
                if (top < b) {
                    s.top = top;
                    s.bottom = b;
                    s.cursorTo(1, 1);
                }
            },
            's' => s.saveCursor(),
            'u' => if (seq.params.len == 0) s.restoreCursor(),
            't' => switch (seq.param(0, 0)) {
                18 => s.respond("\x1b[8;{d};{d}t", .{ s.size.height, s.size.width }),
                else => {},
            },
            else => {},
        }
    }

    fn intermediateCsi(s: *Screen, seq: Parser.Csi) void {
        if (seq.is(0, " ", 'q')) {
            const shape = seq.param(0, 1);
            s.cursor_shape = switch (shape) {
                0, 1, 2 => .block,
                3, 4 => .underline,
                else => .bar,
            };
            s.cursor_blink = shape == 0 or shape % 2 == 1;
        } else if (seq.is(0, "!", 'p')) {
            s.softReset();
        } else if (seq.is(0, "$", 'p')) {
            const mode = seq.param(0, 0);
            const state: u8 = switch (mode) {
                4 => if (s.insert) 1 else 2,
                20 => if (s.newline) 1 else 2,
                else => 0,
            };
            s.respond("\x1b[{d};{d}$y", .{ mode, state });
        }
    }

    fn greaterCsi(s: *Screen, seq: Parser.Csi) void {
        switch (seq.final) {
            'c' => s.respond("\x1b[>1;10;0c", .{}),
            'u' => {
                if (s.keyboard_depth < 7) s.keyboard_depth += 1;
                s.keyboard_flags[s.keyboard_depth] = @truncate(seq.param(0, 0));
            },
            else => {},
        }
    }

    fn privateCsi(s: *Screen, seq: Parser.Csi) void {
        switch (seq.final) {
            'h', 'l' => {
                const on = seq.final == 'h';
                for (seq.params) |param| s.privateMode(param.value orelse 0, on);
            },
            'u' => s.respond("\x1b[?{d}u", .{s.keyboard_flags[s.keyboard_depth]}),
            'p' => if (seq.is('?', "$", 'p')) {
                const mode = seq.param(0, 0);
                const state: u8 = if (s.privateModeState(mode)) |on| (if (on) 1 else 2) else 0;
                s.respond("\x1b[?{d};{d}$y", .{ mode, state });
            },
            'J' => s.eraseDisplay(seq.param(0, 0)),
            'K' => s.eraseLine(seq.param(0, 0)),
            else => {},
        }
    }

    /// Whether a DEC private mode is set, or null when the screen does not know it.
    pub fn privateModeState(s: *const Screen, mode: u16) ?bool {
        return switch (mode) {
            1 => s.application_cursor,
            5 => s.reverse_video,
            6 => s.origin,
            7 => s.autowrap,
            12 => s.cursor_blink,
            25 => s.cursor_visible,
            47, 1047, 1049 => s.on_alt,
            1000 => s.mouse == .press,
            1002 => s.mouse == .drag,
            1003 => s.mouse == .motion,
            1004 => s.focus_events,
            1006 => s.mouse_sgr,
            2004 => s.bracketed_paste,
            2026 => s.synchronized,
            else => null,
        };
    }

    fn privateMode(s: *Screen, mode: u16, on: bool) void {
        switch (mode) {
            1 => s.application_cursor = on,
            5 => s.reverse_video = on,
            6 => {
                s.origin = on;
                s.cursorTo(1, 1);
            },
            7 => s.autowrap = on,
            12 => s.cursor_blink = on,
            25 => s.cursor_visible = on,
            47, 1047 => s.switchScreen(on, false),
            1048 => if (on) s.saveCursor() else s.restoreCursor(),
            1049 => s.switchScreen(on, true),
            1000 => s.mouse = if (on) .press else .off,
            1002 => s.mouse = if (on) .drag else .off,
            1003 => s.mouse = if (on) .motion else .off,
            1004 => s.focus_events = on,
            1006 => s.mouse_sgr = on,
            2004 => s.bracketed_paste = on,
            2026 => s.synchronized = on,
            else => {},
        }
    }

    fn switchScreen(s: *Screen, on: bool, save: bool) void {
        if (on == s.on_alt) return;
        if (on) {
            if (save) s.saveCursor();
            s.on_alt = true;
            @memset(s.alt.cells, .{});
            @memset(s.alt.wrapped, false);
        } else {
            s.on_alt = false;
            if (save) s.restoreCursor();
        }
        s.pending_wrap = false;
    }

    fn ansiModes(s: *Screen, seq: Parser.Csi, on: bool) void {
        for (seq.params) |param| switch (param.value orelse 0) {
            4 => s.insert = on,
            20 => s.newline = on,
            else => {},
        };
    }

    fn cursorUp(s: *Screen, n: usize) void {
        const limit = if (s.row >= s.top) s.top else 0;
        s.row = @max(s.row -| n, limit);
        s.pending_wrap = false;
    }

    fn cursorDown(s: *Screen, n: usize) void {
        const limit = if (s.row <= s.bottom) s.bottom else s.size.height - 1;
        s.row = @min(s.row + n, limit);
        s.pending_wrap = false;
    }

    fn moveColumn(s: *Screen, column: usize) void {
        s.column = column;
        s.pending_wrap = false;
    }

    /// `CUP` with 1-based `row` and `column`, relative to the region in origin mode.
    fn cursorTo(s: *Screen, row: usize, column: usize) void {
        const r = @max(row, 1) - 1;
        const c = @max(column, 1) - 1;
        if (s.origin) {
            s.row = @min(s.top + r, s.bottom);
        } else {
            s.row = @min(r, s.size.height - 1);
        }
        s.column = @min(c, s.size.width - 1);
        s.pending_wrap = false;
    }

    fn eraseDisplay(s: *Screen, part: usize) void {
        const w = s.size.width;
        const cells = s.grid().cells;
        const at = s.row * w + s.column;
        switch (part) {
            0 => {
                @memset(cells[at..], s.blank());
                @memset(s.grid().wrapped[s.row..], false);
                s.repairRow(s.row);
            },
            1 => {
                @memset(cells[0 .. at + 1], s.blank());
                s.repairRow(s.row);
            },
            2 => {
                @memset(cells, s.blank());
                @memset(s.grid().wrapped, false);
            },
            3 => {
                for (s.scrollback.items) |line| s.gpa.free(line.cells);
                s.scrollback.clearRetainingCapacity();
            },
            else => {},
        }
    }

    fn eraseLine(s: *Screen, part: usize) void {
        const row = s.rowCells(s.row);
        switch (part) {
            0 => {
                @memset(row[s.column..], s.blank());
                s.grid().wrapped[s.row] = false;
            },
            1 => @memset(row[0 .. s.column + 1], s.blank()),
            2 => {
                @memset(row, s.blank());
                s.grid().wrapped[s.row] = false;
            },
            else => {},
        }
        s.repairRow(s.row);
    }

    fn eraseChars(s: *Screen, n: usize) void {
        const row = s.rowCells(s.row);
        const end = @min(s.column + n, s.size.width);
        @memset(row[s.column..end], s.blank());
        s.repairRow(s.row);
        s.pending_wrap = false;
    }

    fn insertBlanks(s: *Screen, n_in: usize) void {
        const row = s.rowCells(s.row);
        const n = @min(n_in, s.size.width - s.column);
        std.mem.copyBackwards(Cell, row[s.column + n ..], row[s.column .. row.len - n]);
        @memset(row[s.column..][0..n], s.blank());
        s.repairRow(s.row);
        s.pending_wrap = false;
    }

    fn deleteChars(s: *Screen, n_in: usize) void {
        const row = s.rowCells(s.row);
        const n = @min(n_in, s.size.width - s.column);
        std.mem.copyForwards(Cell, row[s.column .. row.len - n], row[s.column + n ..]);
        @memset(row[row.len - n ..], s.blank());
        s.repairRow(s.row);
        s.pending_wrap = false;
    }

    fn insertLines(s: *Screen, n_in: usize) void {
        if (s.row < s.top or s.row > s.bottom) return;
        const n = @min(n_in, s.bottom - s.row + 1);
        s.moveRows(s.row, s.row + n, s.bottom + 1 - s.row - n);
        s.blankRows(s.row, n);
        s.column = 0;
        s.pending_wrap = false;
    }

    fn deleteLines(s: *Screen, n_in: usize) void {
        if (s.row < s.top or s.row > s.bottom) return;
        const n = @min(n_in, s.bottom - s.row + 1);
        s.moveRows(s.row + n, s.row, s.bottom + 1 - s.row - n);
        s.blankRows(s.bottom + 1 - n, n);
        s.column = 0;
        s.pending_wrap = false;
    }

    /// `REP`: prints the character before the cursor `n` more times.
    fn repeat(s: *Screen, n: usize) void {
        if (s.column == 0 and !s.pending_wrap) return;
        const at = if (s.pending_wrap) s.column else s.column - 1;
        var source = s.cell(s.row, at).*;
        if (source.tail and at > 0) source = s.cell(s.row, at - 1).*;
        if (source.len == 0) return;
        const cluster_width: u2 = if (source.wide) 2 else 1;
        const saved_pen = s.pen;
        s.pen = source.pen;
        for (0..@min(n, @as(usize, s.size.width) * s.size.height)) |_| {
            s.printCluster(source.bytes(), cluster_width);
        }
        s.pen = saved_pen;
    }

    /// For `Parser`: an operating system command.
    pub fn osc(s: *Screen, data: []const u8) void {
        const semicolon = std.mem.indexOfScalar(u8, data, ';') orelse data.len;
        const command = std.fmt.parseInt(u16, data[0..semicolon], 10) catch return;
        const rest = if (semicolon < data.len) data[semicolon + 1 ..] else "";
        switch (command) {
            0, 2 => {
                s.title.clearRetainingCapacity();
                s.title.appendSlice(s.gpa, rest) catch {};
            },
            4 => s.paletteCommand(rest),
            8 => s.hyperlink(rest),
            10, 11 => {
                if (std.mem.eql(u8, rest, "?")) {
                    const rgb = if (command == 10) s.foreground else s.background;
                    s.respond("\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                        command, rgb.r, rgb.r, rgb.g, rgb.g, rgb.b, rgb.b,
                    });
                } else if (parseColor(rest)) |rgb| {
                    if (command == 10) s.foreground = rgb else s.background = rgb;
                }
            },
            52 => {
                const at = std.mem.indexOfScalar(u8, rest, ';') orelse return;
                const encoded = rest[at + 1 ..];
                if (std.mem.eql(u8, encoded, "?")) return;
                const decoder = std.base64.standard.Decoder;
                const len = decoder.calcSizeForSlice(encoded) catch return;
                s.clipboard.resize(s.gpa, len) catch return;
                decoder.decode(s.clipboard.items, encoded) catch {
                    s.clipboard.clearRetainingCapacity();
                };
            },
            104 => s.palette = @splat(null),
            else => {},
        }
    }

    fn paletteCommand(s: *Screen, rest: []const u8) void {
        var parts = std.mem.splitScalar(u8, rest, ';');
        while (parts.next()) |index_text| {
            const spec = parts.next() orelse return;
            const index = std.fmt.parseInt(u8, index_text, 10) catch return;
            if (std.mem.eql(u8, spec, "?")) {
                const rgb = s.paletteRgb(index);
                s.respond("\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                    index, rgb.r, rgb.r, rgb.g, rgb.g, rgb.b, rgb.b,
                });
            } else if (parseColor(spec)) |rgb| {
                s.palette[index] = rgb;
            }
        }
    }

    fn hyperlink(s: *Screen, rest: []const u8) void {
        const at = std.mem.indexOfScalar(u8, rest, ';') orelse return;
        const url = rest[at + 1 ..];
        if (url.len == 0) {
            s.link = 0;
            return;
        }
        for (s.links.items, 1..) |known, i| {
            if (std.mem.eql(u8, known, url)) {
                s.link = @intCast(i);
                return;
            }
        }
        if (s.links.items.len == std.math.maxInt(u16)) return;
        const copy = s.gpa.dupe(u8, url) catch return;
        s.links.append(s.gpa, copy) catch {
            s.gpa.free(copy);
            return;
        };
        s.link = @intCast(s.links.items.len);
    }

    /// The URL of a cell's hyperlink, or null.
    pub fn linkOf(s: *const Screen, c: *const Cell) ?[]const u8 {
        if (c.link == 0) return null;
        return s.links.items[c.link - 1];
    }

    /// The RGB value of palette entry `index`, as OSC 4 left it.
    pub fn paletteRgb(s: *const Screen, index: u8) ansi.Color.Rgb {
        return s.palette[index] orelse ansi.palette.rgbOf(index);
    }

    /// A cell's colors, as drawn.
    pub const Colors = struct { fg: ansi.Color.Rgb, bg: ansi.Color.Rgb };

    /// The colors a cell is drawn in, reverse video and `.default` resolved.
    pub fn colorsOf(s: *const Screen, c: *const Cell) Colors {
        var fg = s.resolve(c.pen.fg, s.foreground);
        var bg = s.resolve(c.pen.bg, s.background);
        if (s.bold_is_bright and c.pen.bold) if (c.pen.fg == .basic and c.pen.fg.basic < 8) {
            fg = s.paletteRgb(c.pen.fg.basic + 8);
        };
        if (c.pen.reverse != s.reverse_video) std.mem.swap(ansi.Color.Rgb, &fg, &bg);
        if (c.pen.dim) fg = fg.over(bg, 0.6);
        if (c.pen.invisible) fg = bg;
        return .{ .fg = fg, .bg = bg };
    }

    fn resolve(s: *const Screen, color: ansi.Color, default: ansi.Color.Rgb) ansi.Color.Rgb {
        return switch (color) {
            .default => default,
            .basic => |n| s.paletteRgb(n),
            .indexed => |n| s.paletteRgb(n),
            .rgb => |rgb| rgb,
        };
    }

    // Reading the screen.

    /// Whether `row` shows nothing.
    pub fn rowIsBlank(s: *Screen, row: usize) bool {
        for (s.rowCells(row)) |*c| if (!c.isBlank()) return false;
        return true;
    }

    /// Writes `row` as text, trailing blanks dropped.
    pub fn writeRow(s: *Screen, w: *Io.Writer, row: usize) Io.Writer.Error!void {
        try writeCells(w, s.rowCells(row));
    }

    fn writeCells(w: *Io.Writer, cells: []const Cell) Io.Writer.Error!void {
        var end = cells.len;
        while (end > 0 and cells[end - 1].isBlank()) end -= 1;
        for (cells[0..end]) |*c| {
            if (c.tail) continue;
            if (c.len == 0) try w.writeByte(' ') else try w.writeAll(c.bytes());
        }
    }

    /// Writes what the screen shows: each row without trailing spaces, without the blank
    /// rows at the bottom, rows separated by `\n`.
    pub fn writeText(s: *Screen, w: *Io.Writer) Io.Writer.Error!void {
        var last: usize = 0;
        for (0..s.size.height) |r| {
            if (!s.rowIsBlank(r)) last = r + 1;
        }
        for (0..last) |r| {
            if (r > 0) try w.writeByte('\n');
            try s.writeRow(w, r);
        }
    }

    /// `writeText` into memory the caller owns.
    pub fn textAlloc(s: *Screen, gpa: Allocator) Allocator.Error![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        s.writeText(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// The scrollback and the screen as text, oldest line first: lines that wrapped are
    /// joined back into one.
    pub fn writeHistory(s: *Screen, w: *Io.Writer) Io.Writer.Error!void {
        for (s.scrollback.items) |line| {
            try writeCells(w, line.cells);
            if (!line.wrapped) try w.writeByte('\n');
        }
        try s.writeText(w);
    }

    /// Writes the screen as text with its colors and attributes (and hyperlinks) as escape
    /// sequences, lowered to `level`: what a terminal would show, ready to print again.
    pub fn writeAnsi(
        s: *Screen,
        w: *Io.Writer,
        level: @import("capability.zig").Color,
    ) Io.Writer.Error!void {
        var last: usize = 0;
        for (0..s.size.height) |r| {
            if (!s.rowIsBlank(r)) last = r + 1;
        }
        var pen: Pen = .{};
        var link: u16 = 0;
        for (0..last) |r| {
            if (r > 0) {
                if (link != 0) try w.writeAll(ansi.osc ++ "8;;" ++ ansi.st);
                link = 0;
                try (Pen{}).writeFrom(pen, w, level);
                pen = .{};
                try w.writeByte('\n');
            }
            const cells = s.rowCells(r);
            var end = cells.len;
            while (end > 0 and cells[end - 1].isBlank() and cells[end - 1].pen.bg == .default) {
                end -= 1;
            }
            for (cells[0..end]) |*c| {
                if (c.tail) continue;
                try c.pen.writeFrom(pen, w, level);
                pen = c.pen;
                if (c.link != link) {
                    if (c.link == 0) {
                        try w.writeAll(ansi.osc ++ "8;;" ++ ansi.st);
                    } else {
                        try w.print(ansi.osc ++ "8;;{s}" ++ ansi.st, .{s.links.items[c.link - 1]});
                    }
                    link = c.link;
                }
                if (c.len == 0) try w.writeByte(' ') else try w.writeAll(c.bytes());
            }
        }
        if (link != 0) try w.writeAll(ansi.osc ++ "8;;" ++ ansi.st);
        try (Pen{}).writeFrom(pen, w, level);
    }

    /// Whether `needle` appears on the screen, in one row.
    pub fn contains(s: *Screen, needle: []const u8) bool {
        var buffer: [4096]u8 = undefined;
        for (0..s.size.height) |r| {
            var row: Io.Writer = .fixed(&buffer);
            s.writeRow(&row, r) catch {};
            if (std.mem.indexOf(u8, row.buffered(), needle) != null) return true;
        }
        return false;
    }

    /// How `writeSvg` draws.
    pub const SvgOptions = struct {
        font_size: u16 = 14,
        font_family: []const u8 = "ui-monospace, Menlo, Consolas, monospace",
        /// Space around the cells, in pixels.
        padding: u16 = 12,
        /// Draw the cursor where it is, when visible.
        cursor: bool = false,
        /// Keep every row, not only down to the last non-blank one.
        all_rows: bool = false,
    };

    /// Writes the screen as an SVG image: every cell with its colors and attributes, in a
    /// monospace grid, in the screen's `foreground` and `background`. Rows below the last
    /// non-blank one are left out unless `all_rows`.
    pub fn writeSvg(s: *Screen, w: *Io.Writer, options: SvgOptions) Io.Writer.Error!void {
        var rows: usize = if (options.all_rows) s.size.height else 1;
        if (!options.all_rows) for (0..s.size.height) |r| if (!s.rowIsBlank(r)) {
            rows = r + 1;
        };
        if (options.cursor and s.cursor_visible) rows = @max(rows, s.row + 1);
        const size: f32 = @floatFromInt(options.font_size);
        const cell_width = size * 0.6;
        const line_height = size * 1.25;
        const pad: f32 = @floatFromInt(options.padding);
        const columns: f32 = @floatFromInt(s.size.width);
        const total_width = columns * cell_width + 2 * pad;
        const total_height = @as(f32, @floatFromInt(rows)) * line_height + 2 * pad;
        try w.print(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d:.0}\" " ++
                "font-family=\"{s}\" font-size=\"{d}\">\n",
            .{ total_width, total_height, options.font_family, options.font_size },
        );
        try w.print("<rect width=\"100%\" height=\"100%\" fill=\"{f}\"/>\n", .{hex(s.background)});
        for (0..rows) |r| {
            const y = pad + @as(f32, @floatFromInt(r)) * line_height;
            var c: usize = 0;
            while (c < s.size.width) {
                const first = s.cell(r, c);
                // A run of cells with the same pen and link, drawn as one piece of text.
                var end = c + 1;
                while (end < s.size.width and s.cell(r, end).pen.eql(first.pen) and
                    s.cell(r, end).link == first.link) end += 1;
                const colors = s.colorsOf(first);
                const x = pad + @as(f32, @floatFromInt(c)) * cell_width;
                const run_width = @as(f32, @floatFromInt(end - c)) * cell_width;
                if (!std.meta.eql(colors.bg, s.background)) {
                    try w.print(
                        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" " ++
                            "fill=\"{f}\"/>\n",
                        .{ x, y, run_width, line_height, hex(colors.bg) },
                    );
                }
                var any = false;
                for (c..end) |i| if (s.cell(r, i).len > 0) {
                    any = true;
                };
                if (any and !first.pen.invisible) {
                    if (s.linkOf(first)) |url| {
                        try w.writeAll("<a href=\"");
                        try writeXml(w, url);
                        try w.writeAll("\">");
                    }
                    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"{f}\"", .{
                        x, y + size, hex(colors.fg),
                    });
                    if (first.pen.bold) try w.writeAll(" font-weight=\"bold\"");
                    if (first.pen.italic) try w.writeAll(" font-style=\"italic\"");
                    const lines = [_]struct { bool, []const u8 }{
                        .{ first.pen.underline != .none, "underline" },
                        .{ first.pen.strikethrough, "line-through" },
                        .{ first.pen.overline, "overline" },
                    };
                    var decorated = false;
                    for (lines) |line| if (line[0]) {
                        try w.writeAll(if (decorated) " " else " text-decoration=\"");
                        try w.writeAll(line[1]);
                        decorated = true;
                    };
                    if (decorated) try w.writeByte('"');
                    try w.print(" textLength=\"{d:.1}\" xml:space=\"preserve\">", .{run_width});
                    for (c..end) |i| {
                        const target = s.cell(r, i);
                        if (target.tail) continue;
                        if (target.len == 0) {
                            try w.writeByte(' ');
                            continue;
                        }
                        try writeXml(w, target.bytes());
                    }
                    try w.writeAll("</text>");
                    if (s.linkOf(first) != null) try w.writeAll("</a>");
                    try w.writeByte('\n');
                }
                c = end;
            }
        }
        if (options.cursor and s.cursor_visible) {
            const x = pad + @as(f32, @floatFromInt(s.column)) * cell_width;
            const y = pad + @as(f32, @floatFromInt(s.row)) * line_height;
            const shape: [2]f32 = switch (s.cursor_shape) {
                .block => .{ cell_width, line_height },
                .underline => .{ cell_width, line_height / 8 },
                .bar => .{ cell_width / 6, line_height },
            };
            const top = if (s.cursor_shape == .underline) y + line_height - shape[1] else y;
            try w.print(
                "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" " ++
                    "fill=\"{f}\" opacity=\"0.7\"/>\n",
                .{ x, top, shape[0], shape[1], hex(s.foreground) },
            );
        }
        try w.writeAll("</svg>\n");
    }

    const Hex = struct {
        rgb: ansi.Color.Rgb,
        pub fn format(h: Hex, w: *Io.Writer) Io.Writer.Error!void {
            try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ h.rgb.r, h.rgb.g, h.rgb.b });
        }
    };

    fn hex(rgb: ansi.Color.Rgb) Hex {
        return .{ .rgb = rgb };
    }
};

fn writeXml(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |byte| switch (byte) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(byte),
    };
}

/// An X11 color spec (`rgb:rr/gg/bb`, with 1 to 4 hex digits per channel) or `#rrggbb`.
pub fn parseColor(spec: []const u8) ?ansi.Color.Rgb {
    if (spec.len > 0 and spec[0] == '#') {
        const color = ansi.Color.parse(spec) catch return null;
        return color.rgb;
    }
    if (!std.mem.startsWith(u8, spec, "rgb:")) return null;
    var parts = std.mem.splitScalar(u8, spec[4..], '/');
    var channels: [3]u8 = undefined;
    for (&channels) |*c| {
        const digits = parts.next() orelse return null;
        if (digits.len == 0 or digits.len > 4) return null;
        const value = std.fmt.parseInt(u16, digits, 16) catch return null;
        // Scale to 8 bits: `f` is 0xff, `ffff` is 0xff.
        const max: u32 = (@as(u32, 1) << @intCast(4 * digits.len)) - 1;
        c.* = @intCast(@as(u32, value) * 255 / max);
    }
    if (parts.next() != null) return null;
    return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
}

/// What the DEC Special Graphics set draws for `_` through `~`.
const dec_special = [32]u21{
    ' ',
    '◆',
    '▒',
    '␉',
    '␌',
    '␍',
    '␊',
    '°',
    '±',
    '␤',
    '␋',
    '┘',
    '┐',
    '┌',
    '└',
    '┼',
    '⎺',
    '⎻',
    '─',
    '⎼',
    '⎽',
    '├',
    '┤',
    '┴',
    '┬',
    '│',
    '≤',
    '≥',
    'π',
    '≠',
    '£',
    '·',
};

const testing = std.testing;

fn expectText(screen: *Screen, expected: []const u8) !void {
    const text = try screen.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn screenOf(width_: u16, height: u16, bytes: []const u8) !Screen {
    var screen: Screen = try .init(testing.allocator, .{ .width = width_, .height = height });
    screen.write(bytes);
    return screen;
}

test "printing, autowrap, and the pending-wrap column" {
    var s = try screenOf(4, 4, "abcd");
    defer s.deinit();
    try testing.expect(s.pending_wrap);
    try testing.expectEqual(3, s.column);
    s.write("ef");
    try expectText(&s, "abcd\nef");
    try testing.expect(s.grid().wrapped[0]);
    s.write("\x1b[?7l\r\n\nwxyz12");
    try expectText(&s, "abcd\nef\n\nwxy2");
}

test "grapheme clusters and wide characters" {
    var s = try screenOf(7, 3, "e\u{301}中👨‍👩‍👧❤\u{fe0f}");
    defer s.deinit();
    try expectText(&s, "e\u{301}中👨‍👩‍👧❤\u{fe0f}");
    try testing.expect(s.cell(0, 1).wide and s.cell(0, 2).tail);
    try testing.expect(s.cell(0, 5).wide); // VS16 widened the heart
    try testing.expect(s.pending_wrap);
    // Overwriting half of a wide character clears the other half.
    s.write("\x1b[1;3Hx");
    try expectText(&s, "e\u{301} x👨‍👩‍👧❤\u{fe0f}");
    // A wide character that does not fit in the last column wraps whole.
    s.write("\x1b[2;7H中");
    try expectText(&s, "e\u{301} x👨‍👩‍👧❤\u{fe0f}\n\n中");
}

test "cursor movement, tabs, and origin mode" {
    var s = try screenOf(20, 5, "a\tb\x1b[3;5Hc\x1b[Ad\x1b[10Ge\x1b[Zf");
    defer s.deinit();
    try expectText(&s, "a       b\n     d  fe\n    c");
    s.write("\x1b[2;4r\x1b[?6h\x1b[Hg\x1b[9;1Hh\x1b[?6l");
    try expectText(&s, "a       b\ng    d  fe\n    c\nh");
}

test "erasing, with the background color" {
    var s = try screenOf(5, 3, "11111\r\n22222\r\n33333");
    defer s.deinit();
    s.write("\x1b[2;3H\x1b[41m\x1b[K");
    try expectText(&s, "11111\n22\n33333");
    try testing.expectEqual(ansi.Color.red, s.cell(1, 4).pen.bg);
    s.write("\x1b[1;2H\x1b[1K\x1b[3;1H\x1b[2X");
    try expectText(&s, "  111\n22\n  333");
    s.write("\x1b[2;1H\x1b[J");
    try expectText(&s, "  111");
    s.write("\x1b[2J");
    try expectText(&s, "");
}

test "inserting and deleting characters and lines" {
    var s = try screenOf(6, 4, "abcdef\r\n123456\r\nxyz\r\nlast");
    defer s.deinit();
    s.write("\x1b[1;2H\x1b[2@\x1b[2;2H\x1b[2P");
    try expectText(&s, "a  bcd\n1456\nxyz\nlast");
    s.write("\x1b[2;1H\x1b[L");
    try expectText(&s, "a  bcd\n\n1456\nxyz");
    s.write("\x1b[1;1H\x1b[2M");
    try expectText(&s, "1456\nxyz");
    s.write("\x1b[4h\x1b[1;1HZ\x1b[4l");
    try expectText(&s, "Z1456\nxyz");
    s.write("\x1b[3;1Hab\x1b[3b");
    try expectText(&s, "Z1456\nxyz\nabbbb");
}

test "scroll regions, scrolling, and the scrollback" {
    const size: Size = .{ .width = 4, .height = 3 };
    var s: Screen = try .initOptions(testing.allocator, size, .{ .scrollback = 10 });
    defer s.deinit();
    s.write("1\r\n2\r\n3\r\n4");
    try expectText(&s, "2\n3\n4");
    try testing.expectEqual(1, s.scrollback.items.len);
    s.write("\x1b[2;3r\x1b[3;1H\n5");
    try expectText(&s, "2\n4\n5");
    s.write("\x1b[2;1H\x1bM");
    try expectText(&s, "2\n\n4");
    s.write("\x1b[r\x1b[S");
    try expectText(&s, "\n4");
    var history: Io.Writer.Allocating = .init(testing.allocator);
    defer history.deinit();
    try s.writeHistory(&history.writer);
    try testing.expectEqualStrings("1\n2\n\n4", history.written());
}

test "the alternate screen and saved cursors" {
    var s = try screenOf(10, 3, "main\x1b[?1049h\x1b[Halt");
    defer s.deinit();
    try expectText(&s, "alt");
    s.write("\x1b[?1049l");
    try expectText(&s, "main");
    try testing.expectEqual(4, s.column);
    s.write("\x1b[1;31m\x1b7\x1b[0m\x1b[3;3H\x1b8x");
    try testing.expectEqual(ansi.Color.red, s.cell(0, 4).pen.fg);
}

test "line drawing and character sets" {
    var s = try screenOf(10, 1, "\x1b(0lqk\x1b(Bx\x0e");
    defer s.deinit();
    try expectText(&s, "┌─┐x");
    s.write("\x1b)0\x0eq\x0fq");
    try expectText(&s, "┌─┐x─q");
}

test "queries are answered in responses" {
    var s = try screenOf(10, 5, "\x1b[3;4H\x1b[6n\x1b[c\x1b[?2004$p\x1b[?2004h\x1b[?2004$p" ++
        "\x1b]11;?\x07\x1b[?u");
    defer s.deinit();
    const answers = try s.takeResponses();
    defer testing.allocator.free(answers);
    try testing.expectEqualStrings(
        "\x1b[3;4R\x1b[?62;22c\x1b[?2004;2$y\x1b[?2004;1$y" ++
            "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\\x1b[?0u",
        answers,
    );
}

test "a cursor restored above the region in origin mode reports row 1" {
    // Origin on, saved at row 0, then a region from row 5: the restore lands above it.
    var s = try screenOf(10, 12, "\x1b[?6h\x1b7\x1b[5;10r\x1b8\x1b[6n");
    defer s.deinit();
    const answers = try s.takeResponses();
    defer testing.allocator.free(answers);
    try testing.expectEqualStrings("\x1b[1;1R", answers);
}

test "titles, hyperlinks, the clipboard, and cursor shapes" {
    var s = try screenOf(10, 2, "\x1b]2;hello\x07\x1b]8;;https://x\x1b\\ab\x1b]8;;\x1b\\c" ++
        "\x1b]52;c;aGk=\x07\x1b[5 q");
    defer s.deinit();
    try testing.expectEqualStrings("hello", s.title.items);
    try testing.expectEqualStrings("https://x", s.linkOf(s.cell(0, 1)).?);
    try testing.expectEqual(null, s.linkOf(s.cell(0, 2)));
    try testing.expectEqualStrings("hi", s.clipboard.items);
    try testing.expectEqual(CursorShape.bar, s.cursor_shape);
    try testing.expect(s.cursor_blink);
}

test "writeAnsi reproduces the screen" {
    const input = "\x1b[1;31mred\x1b[0m plain \x1b[4munder\x1b[0m\r\n\x1b[44m  \x1b[0mx";
    var s = try screenOf(30, 3, input);
    defer s.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try s.writeAnsi(&out.writer, .truecolor);
    var again = try screenOf(30, 3, "");
    defer again.deinit();
    // Printed again on a fresh screen (with CR before each newline), it shows the same.
    const replay = try std.mem.replaceOwned(u8, testing.allocator, out.written(), "\n", "\r\n");
    defer testing.allocator.free(replay);
    again.write(replay);
    for (0..3) |r| for (0..30) |c| {
        try testing.expect(s.cell(r, c).pen.eql(again.cell(r, c).pen));
        try testing.expectEqualStrings(s.cell(r, c).bytes(), again.cell(r, c).bytes());
    };
}

test "resize keeps the top left and clamps the cursor" {
    var s = try screenOf(6, 3, "abcdef\r\n12中");
    defer s.deinit();
    try s.resize(.{ .width = 3, .height = 2 });
    try expectText(&s, "abc\n12");
    try testing.expectEqual(1, s.row);
}

test parseColor {
    const orange: ansi.Color.Rgb = .{ .r = 0xff, .g = 0x80, .b = 0 };
    try testing.expectEqual(orange, parseColor("rgb:ff/80/00").?);
    try testing.expectEqual(orange, parseColor("rgb:ffff/8080/0").?);
    const blue: ansi.Color.Rgb = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try testing.expectEqual(blue, parseColor("#123456").?);
    try testing.expectEqual(null, parseColor("blue"));
}

test "random output never breaks the screen" {
    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();
    var s = try screenOf(13, 7, "");
    defer s.deinit();
    const pieces = [_][]const u8{
        "a",
        "中",
        "e\u{301}",
        "\r",
        "\n",
        "\t",
        "\x08",
        "\x1b[H",
        "\x1b[5;9H",
        "\x1b[2J",
        "\x1b[K",
        "\x1b[3@",
        "\x1b[2P",
        "\x1b[L",
        "\x1b[2M",
        "\x1b[2;5r",
        "\x1b[r",
        "\x1bM",
        "\x1bD",
        "\x1b7",
        "\x1b8",
        "\x1b[?1049h",
        "\x1b[?1049l",
        "\x1b[4h",
        "\x1b[4l",
        "\x1b[?7l",
        "\x1b[?7h",
        "\x1b[3X",
        "\x1b[9b",
        "\x1b[?6h",
        "\x1b[?6l",
        "👍🏽",
        "\x1b(0q",
        "\x1b(B",
        "\x1b[31m",
    };
    for (0..5000) |i| {
        s.write(pieces[random.uintLessThan(usize, pieces.len)]);
        if (i % 500 == 0) {
            const size: Size = .{
                .width = random.intRangeAtMost(u16, 1, 20),
                .height = random.intRangeAtMost(u16, 1, 9),
            };
            try s.resize(size);
        }
        try testing.expect(s.row < s.size.height and s.column < s.size.width);
        try testing.expect(s.top <= s.bottom and s.bottom < s.size.height);
        // A wide cell is always followed by its tail.
        for (0..s.size.height) |r| {
            const cells = s.rowCells(r);
            for (cells, 0..) |c, col| if (c.wide) {
                try testing.expect(col + 1 < cells.len and cells[col + 1].tail);
            };
        }
    }
}
