//! `termancy ui table`: show CSV or TSV as a table, and choose a row.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field_ = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const styles = @import("styles.zig");
const Table = @import("../tui/registry/table.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Flags = struct {
    separator: []const u8 = ",",
    columns: []const []const u8 = &.{},
    widths: []const usize = &.{},
    height: usize = 0,
    print: bool = false,
    file: []const u8 = "",
    border: styles.Border = .rounded,
    show_help: bool = true,
    hide_count: bool = false,
    lazy_quotes: bool = false,
    fields_per_record: isize = 0,
    return_column: usize = 0,
    timeout: cfg.Duration = .zero,
    padding: styles.Spacing = .{},
    border_style: styles.Styles = .{},
    cell_style: styles.Styles = .{},
    header_style: styles.Styles = .{},
    selected_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field_.Set(.{ field_.Spec(Flags){ .fields = .{
    .separator = .{ .help = "The field separator: one character, or \\t (or tab) for TSV" },
    .columns = .{
        .help = "Column titles, comma-separated; then the first line is data, not titles",
    },
    .widths = .{ .help = "Column widths, comma-separated; 0 fits the column to its cells" },
    .height = .{
        .help = "The table's height in lines, header and border included; 0 fits the terminal",
    },
    .print = .{ .help = "Print the table to standard output instead of choosing a row" },
    .file = .{ .help = "Read the table from this file instead of standard input" },
    .border = .{ .help = "Border style: none, normal, rounded, thick, double, hidden, or ascii" },
    .show_help = .{ .help = term.help.show_help },
    .hide_count = .{ .help = "Leave the row count off the help line" },
    .lazy_quotes = .{
        .help = "Allow a quote in an unquoted field, and a lone quote in a quoted one",
    },
    .fields_per_record = .{
        .help = "The fields each line must have: 0 as many as the first, -1 any number",
    },
    .return_column = .{
        .help = "Print only this field of the chosen row (1 is the first); 0 prints the row",
    },
    .timeout = .{ .help = term.help.timeout },
    .padding = .{ .help = term.help.padding },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_TABLE_", .fields = .{
    .separator = .{ .short = 's' },
    .columns = .{ .short = 'c', .value_name = "titles", .split = ',' },
    .widths = .{ .short = 'w', .split = ',' },
    .print = .{ .short = 'p' },
    .file = .{ .short = 'f', .value_name = "path" },
    .border = .{ .short = 'b', .value_name = "style" },
    .fields_per_record = .{ .value_name = "n" },
    .return_column = .{ .short = 'r', .value_name = "n" },
    .border_style = styles.group("border"),
    .cell_style = styles.group("cell"),
    .header_style = styles.group("header"),
    .selected_style = styles.group("selected"),
} });

pub const command = cli.command(.{
    .name = "table",
    .summary = "Show CSV or TSV as a table and choose a row",
    .description =
    \\Read CSV (or, with --separator, any one-character-separated values) from standard
    \\input or --file: the first line holds the column titles unless --columns gives them.
    \\Fields may be quoted ("a, b"), with "" for a quote inside. Every line must have as
    \\many fields as the first (see --fields-per-record), and a stray quote is an error
    \\unless --lazy-quotes, as in gum.
    \\
    \\Interactively, up/down move, enter prints the chosen row as a line of the same
    \\format (or with --return-column, one of its fields), esc cancels (status 1), and
    \\Ctrl-C interrupts (status 130). --height counts the table's lines, header and
    \\border included; 0 fits the terminal. --timeout ends with status 124. With --print,
    \\the whole table is written to standard output instead, colored only where standard
    \\output shows colors.
    \\
    \\Style a part with --header.*, --cell.*, --selected.*, and --border.* (foreground,
    \\background, bold, and the rest of `ui style`'s flags). Every flag can also come
    \\from a variable: TERMANCY_TABLE_SEPARATOR, TERMANCY_TABLE_HEADER_FOREGROUND.
    ,
    .flags = flags_flags,
    .examples =
    \\termancy ui table < people.csv
    \\termancy ui table --file people.csv --return-column 1
    \\ps -eo pid,comm | tr -s ' ' | sed 's/^ //' | termancy ui table -s ' ' -r 1
    \\termancy ui table --print --border double --separator tab < data.tsv
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const separator = parseSeparator(flags.separator) orelse
        return ctx.usageError("invalid --separator \"{s}\" (use one character, or \\t)", .{
            flags.separator,
        });
    const source = if (flags.file.len > 0) flags.file else "standard input";
    const text = try read(ctx, flags.file);
    var csv: Csv = .{
        .separator = separator,
        .lazy_quotes = flags.lazy_quotes,
        .fields_per_record = flags.fields_per_record,
    };
    const records = csv.parse(ctx.arena, text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnterminatedQuote => ctx.fail("{s}: a quoted field never ends", .{source}),
        error.BareQuote => ctx.fail(
            "{s}: line {d}: a quote in an unquoted field (--lazy-quotes allows it)",
            .{ source, csv.line },
        ),
        error.Quote => ctx.fail(
            "{s}: line {d}: a quote in a quoted field must be doubled (--lazy-quotes allows it)",
            .{ source, csv.line },
        ),
        error.FieldCount => ctx.fail(
            "{s}: line {d}: expected {d} fields, found {d} (see --fields-per-record)",
            .{ source, csv.line, csv.wanted, csv.found },
        ),
    };
    if (records.len == 0) return ctx.fail("{s} holds no table", .{source});
    const titles = if (flags.columns.len > 0) flags.columns else records[0];
    for (records) |record| if (record.len > titles.len) {
        return ctx.fail("{s}: a row has {d} fields, more than the {d} columns", .{
            source, record.len, titles.len,
        });
    };
    var table = try build(ctx.arena, records, flags, ctx.theme);
    if (flags.print) {
        var block: Writer.Allocating = .init(ctx.arena);
        try table.view(&block.writer);
        try term.writeStyled(ctx.out, block.written(), try term.stdoutColor(ctx));
        try ctx.out.writeByte('\n');
        return;
    }
    var model = framed(ctx.gpa, table, flags);
    const options = term.timed(term.suspend_options, flags.timeout);
    if (try term.run(ctx, @TypeOf(model), &model, options)) return term.exitInterrupted(ctx);
    if (model.inner.status != .submitted) return error.CommandFailed;
    try writeChosen(ctx.out, &model.inner, flags.return_column, separator);
}

/// The text of `--file`, or of standard input.
fn read(ctx: *cli.Context, path: []const u8) ![]const u8 {
    if (path.len > 0) {
        return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err|
            switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.FileNotFound => ctx.fail("{s}: no such file", .{path}),
                else => |e| ctx.fail("{s}: {s}", .{ path, @errorName(e) }),
            };
    }
    return try term.readStdin(ctx) orelse
        ctx.usageError("no table: give CSV on standard input or with --file", .{});
}

/// The separator `--separator` names: one byte, or a tab for `\t` and `tab`.
pub fn parseSeparator(text: []const u8) ?u8 {
    if (std.mem.eql(u8, text, "\\t") or std.mem.eql(u8, text, "tab")) return '\t';
    if (text.len != 1 or text[0] == '"' or text[0] == '\n' or text[0] == '\r') return null;
    return text[0];
}

/// The table for `records` and the flags: titles from `--columns` or the first record,
/// styled as the flags say over `theme`.
pub fn build(
    arena: Allocator,
    records: []const []const []const u8,
    flags: Flags,
    theme: *const cli.Theme,
) Allocator.Error!Table {
    const titles = if (flags.columns.len > 0)
        flags.columns
    else if (records.len > 0)
        records[0]
    else
        &.{};
    const rows = if (flags.columns.len > 0 or records.len == 0) records else records[1..];
    const columns = try arena.alloc(Table.Column, titles.len);
    for (columns, titles, 0..) |*column, title, i| {
        const width = if (i < flags.widths.len) flags.widths[i] else 0;
        column.* = .{ .title = title, .width = if (width == 0) null else width };
    }
    const border: ?Table.Border = switch (flags.border) {
        .none => null,
        inline else => |tag| @field(Table.Border, @tagName(tag)),
    };
    // The header, and with a border, the rules above, under, and below it.
    const chrome: usize = if (border != null) 4 else 1;
    const help_rows: usize = if (flags.show_help) 2 else 0;
    var selected = theme.accent;
    selected.bold = true;
    return .{
        .columns = columns,
        .rows = rows,
        // --print shows every row; a height of 0 fits the terminal.
        .height = if (flags.print or flags.height == 0) null else flags.height -| chrome,
        .reserved = flags.padding.sides.top + flags.padding.sides.bottom + help_rows,
        .selectable = !flags.print,
        .border = border,
        .styles = .{
            .header = flags.header_style.over(theme.heading),
            .cell = flags.cell_style.over(.{}),
            .selected = flags.selected_style.over(selected),
            .border = flags.border_style.over(theme.note),
        },
    };
}

const hints = [_]term.Hint{
    .{ .keys = &.{ "up", "down" }, .action = .hint, .help = "navigate" },
    .{ .keys = &.{"enter"}, .action = .hint, .help = "select" },
    .{ .keys = &.{"esc"}, .action = .hint, .help = "quit" },
};

/// `table` with the help line and row count (unless `--no-show-help`, `--hide-count`)
/// and `--padding`.
pub fn framed(gpa: Allocator, table: Table, flags: Flags) term.Framed(Table) {
    return .{
        .inner = table,
        .gpa = gpa,
        .padding = flags.padding.sides,
        .hints = if (flags.show_help) &hints else &.{},
        .status = if (flags.hide_count) null else writeCount,
    };
}

/// gum's row count before the keys: ` 2/12 • `, as wide as the count of rows.
fn writeCount(table: *const Table, w: *Writer) Writer.Error!void {
    const total = table.rows.len;
    const at = @min(table.cursor + 1, total);
    const dim: tui.Style = .{ .dim = true };
    try dim.writeSgr(w);
    try w.splatByteAll(' ', std.fmt.count("{d}", .{total}) - std.fmt.count("{d}", .{at}));
    try w.print("{d}/{d} • ", .{ at, total });
    try w.writeAll(tui.ansi.reset);
}

/// Writes the chosen row, or its field `column` (1 is the first; 0, or one past the
/// columns, writes the row, as gum does), as a record.
pub fn writeChosen(
    w: *Writer,
    table: *const Table,
    column: usize,
    separator: u8,
) Writer.Error!void {
    const row = table.selected().?;
    if (column == 0 or column > table.columns.len) return writeRecord(w, row, separator);
    const cell = if (column <= row.len) row[column - 1] else "";
    try writeRecord(w, &.{cell}, separator);
}

/// A CSV reader as Go's `encoding/csv`, which gum uses: fields end at `separator`,
/// records at a line break (`\n` or `\r\n`). A field in double quotes may hold separators
/// and line breaks, with `""` standing for a quote. Blank lines are skipped, and so is a
/// byte-order mark at the start.
pub const Csv = struct {
    separator: u8 = ',',
    /// A quote may appear in an unquoted field, and a lone quote in a quoted one.
    lazy_quotes: bool = false,
    /// The fields each record must have: 0 as many as the first, below 0 any number.
    fields_per_record: isize = 0,
    /// After an error, the line it is on (counted from 1); for `FieldCount`, the
    /// record's first line, the fields it has, and the fields wanted.
    line: usize = 1,
    found: usize = 0,
    wanted: usize = 0,

    pub const Error = error{ OutOfMemory, BareQuote, Quote, UnterminatedQuote, FieldCount };

    /// The records in `input`.
    pub fn parse(csv: *Csv, arena: Allocator, input: []const u8) Error![]const []const []const u8 {
        const text = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) input[3..] else input;
        var records: std.ArrayList([]const []const u8) = .empty;
        var wanted: ?usize = std.math.cast(usize, csv.fields_per_record);
        if (wanted == 0) wanted = null;
        csv.line = 1;
        var i: usize = 0;
        while (i < text.len) {
            if (lineEnd(text, i)) |n| {
                i += n;
                csv.line += 1;
                continue;
            }
            const first_line = csv.line;
            var fields: std.ArrayList([]const u8) = .empty;
            while (true) {
                try fields.append(arena, try csv.field(arena, text, &i));
                if (i < text.len and text[i] == csv.separator) {
                    i += 1;
                } else break;
            }
            if (i < text.len) {
                i += lineEnd(text, i).?;
                csv.line += 1;
            }
            if (csv.fields_per_record == 0 and wanted == null) wanted = fields.items.len;
            if (wanted) |n| if (fields.items.len != n) {
                csv.line = first_line;
                csv.found = fields.items.len;
                csv.wanted = n;
                return error.FieldCount;
            };
            try records.append(arena, fields.items);
        }
        return records.items;
    }

    /// The field at `i.*`; leaves `i.*` on the separator or line break after it.
    fn field(csv: *Csv, arena: Allocator, text: []const u8, i: *usize) Error![]const u8 {
        const start = i.*;
        if (start >= text.len or text[start] != '"') {
            var end = start;
            while (end < text.len and text[end] != csv.separator and lineEnd(text, end) == null) {
                end += 1;
            }
            i.* = end;
            const value = text[start..end];
            if (!csv.lazy_quotes and std.mem.indexOfScalar(u8, value, '"') != null) {
                return error.BareQuote;
            }
            return value;
        }
        var value: std.ArrayList(u8) = .empty;
        var at = start + 1;
        while (true) {
            const quote = std.mem.indexOfScalarPos(u8, text, at, '"') orelse {
                if (!csv.lazy_quotes) return error.UnterminatedQuote;
                try csv.appendLines(arena, &value, text[at..]);
                i.* = text.len;
                return value.items;
            };
            try csv.appendLines(arena, &value, text[at..quote]);
            at = quote + 1;
            if (at < text.len and text[at] == '"') {
                try value.append(arena, '"');
                at += 1;
            } else if (at == text.len or text[at] == csv.separator or lineEnd(text, at) != null) {
                i.* = at;
                return value.items;
            } else if (csv.lazy_quotes) {
                try value.append(arena, '"');
            } else return error.Quote;
        }
    }

    /// Appends `text` to `value` with each `\r\n` as `\n`, counting its lines.
    fn appendLines(
        csv: *Csv,
        arena: Allocator,
        value: *std.ArrayList(u8),
        text: []const u8,
    ) Allocator.Error!void {
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |n| {
            try value.appendSlice(arena, std.mem.trimEnd(u8, rest[0..n], "\r"));
            try value.append(arena, '\n');
            csv.line += 1;
            rest = rest[n + 1 ..];
        }
        try value.appendSlice(arena, rest);
    }

    /// The length of the line break at `i`: `\n`, `\r\n`, or a `\r` that ends the text.
    fn lineEnd(text: []const u8, i: usize) ?usize {
        if (text[i] == '\n') return 1;
        if (text[i] != '\r') return null;
        if (i + 1 == text.len) return 1;
        return if (text[i + 1] == '\n') 2 else null;
    }
};

/// Writes `fields` as one record, quoting the fields that need it (as Go's `csv.Writer`
/// does), and a line break.
pub fn writeRecord(w: *Writer, fields: []const []const u8, separator: u8) Writer.Error!void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(separator);
        const special = [_]u8{ separator, '"', '\n', '\r' };
        const spaced = field.len > 0 and (field[0] == ' ' or field[0] == '\t');
        if (!spaced and std.mem.indexOfAny(u8, field, &special) == null) {
            try w.writeAll(field);
            continue;
        }
        try w.writeByte('"');
        for (field) |c| {
            if (c == '"') try w.writeByte('"');
            try w.writeByte(c);
        }
        try w.writeByte('"');
    }
    try w.writeByte('\n');
}

const testing = std.testing;

fn parse(arena: *std.heap.ArenaAllocator, text: []const u8, csv: Csv) ![]const []const []const u8 {
    var reader = csv;
    return reader.parse(arena.allocator(), text);
}

test "Csv: quotes, line breaks, blank lines, and a byte-order mark" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try parse(
        &arena,
        "\xef\xbb\xbfname,note\r\nAda,\"says \"\"hi\"\", twice\"\n\nBob,\"two\r\nlines\"\nC,\r",
        .{},
    );
    try testing.expectEqual(4, records.len);
    try testing.expectEqualStrings("name", records[0][0]);
    try testing.expectEqualStrings("says \"hi\", twice", records[1][1]);
    try testing.expectEqualStrings("two\nlines", records[2][1]);
    try testing.expectEqualStrings("", records[3][1]);
    const tsv = try parse(&arena, "a\tb c\n", .{ .separator = '\t' });
    try testing.expectEqualStrings("b c", tsv[0][1]);
}

test "Csv: stray quotes are errors, with the line, unless lazy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var csv: Csv = .{};
    try testing.expectError(error.BareQuote, csv.parse(arena.allocator(), "a\nb\"c\n"));
    try testing.expectEqual(2, csv.line);
    try testing.expectError(error.Quote, csv.parse(arena.allocator(), "\"a\n\"b\"c\n"));
    try testing.expectEqual(2, csv.line);
    try testing.expectError(error.UnterminatedQuote, csv.parse(arena.allocator(), "\"x"));
    const lazy = try parse(&arena, "b\"c,\"say \"hi\" now\",\"open", .{ .lazy_quotes = true });
    try testing.expectEqualStrings("b\"c", lazy[0][0]);
    try testing.expectEqualStrings("say \"hi\" now", lazy[0][1]);
    try testing.expectEqualStrings("open", lazy[0][2]);
}

test "Csv: fields per record" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var csv: Csv = .{};
    try testing.expectError(error.FieldCount, csv.parse(arena.allocator(), "a,b\n\n1\n"));
    try testing.expectEqual(3, csv.line);
    try testing.expectEqual(1, csv.found);
    try testing.expectEqual(2, csv.wanted);
    csv = .{ .fields_per_record = 1 };
    try testing.expectError(error.FieldCount, csv.parse(arena.allocator(), "a,b\n"));
    const ragged = try parse(&arena, "a,b\n1\n", .{ .fields_per_record = -1 });
    try testing.expectEqual(1, ragged[1].len);
}

test writeRecord {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeRecord(&w, &.{ "plain", "a,b", "say \"x\"" }, ',');
    try writeRecord(&w, &.{ "a,b", " c" }, '\t');
    try testing.expectEqualStrings("plain,\"a,b\",\"say \"\"x\"\"\"\na,b\t\" c\"\n", w.buffered());
}

test parseSeparator {
    try testing.expectEqual('\t', parseSeparator("\\t").?);
    try testing.expectEqual('\t', parseSeparator("tab").?);
    try testing.expectEqual(';', parseSeparator(";").?);
    try testing.expectEqual(null, parseSeparator(";;"));
    try testing.expectEqual(null, parseSeparator("\""));
}

fn buildOf(
    arena: *std.heap.ArenaAllocator,
    records: []const []const []const u8,
    flags: Flags,
) !Table {
    return build(arena.allocator(), records, flags, &cli.Theme.default);
}

test "build: titles from the first record or from --columns, widths, and height" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = [_][]const []const u8{ &.{ "a", "b" }, &.{ "1", "2" } };
    const from_data = try buildOf(&arena, &records, .{ .widths = &.{ 0, 4 }, .height = 6 });
    try testing.expectEqualStrings("b", from_data.columns[1].title);
    try testing.expectEqual(null, from_data.columns[0].width);
    try testing.expectEqual(4, from_data.columns[1].width.?);
    try testing.expectEqual(1, from_data.rows.len);
    // Six lines less the header and three rules.
    try testing.expectEqual(2, from_data.height.?);
    const named = try buildOf(&arena, &records, .{ .columns = &.{ "x", "y" } });
    try testing.expectEqual(2, named.rows.len);
    try testing.expectEqual(null, named.height);
    try testing.expectEqual(2, named.reserved); // the help line and the blank line above it
    const printed = try buildOf(&arena, &.{}, .{ .print = true, .border = .none, .height = 5 });
    try testing.expectEqual(0, printed.columns.len);
    try testing.expect(!printed.selectable and printed.border == null and printed.height == null);
}

test "the styles: the theme's, with the flags over them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = [_][]const []const u8{&.{"a"}};
    const table = try buildOf(&arena, &records, .{
        .header_style = .{ .foreground = .{ .indexed = 99 } },
        .cell_style = .{ .italic = true },
    });
    try testing.expectEqual(tui.Color{ .indexed = 99 }, table.styles.header.fg);
    try testing.expect(table.styles.header.bold and table.styles.cell.italic);
    try testing.expectEqual(cli.Theme.default.accent.fg, table.styles.selected.fg);
    try testing.expect(table.styles.selected.bold);
    try testing.expectEqual(cli.Theme.default.note, table.styles.border);
}

test "choosing a row: the help line with the count, and --return-column" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try parse(&arena, "n,v\nx,1\ny,2\n", .{});
    const flags: Flags = .{ .border = .ascii };
    const model = framed(testing.allocator, try buildOf(&arena, records, flags), flags);
    var d: tui.testing.Driver(term.Framed(Table)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("+---+---+\n| n | v |\n+---+---+\n| x | 1 |\n| y | 2 |\n+---+---+\n\n" ++
        "1/2 • ↑/↓ navigate • enter select • esc quit");
    try d.press("down");
    try d.expectFrame("+---+---+\n| n | v |\n+---+---+\n| x | 1 |\n| y | 2 |\n+---+---+\n\n" ++
        "2/2 • ↑/↓ navigate • enter select • esc quit");
    try d.press("enter");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeChosen(&out.writer, &d.model().inner, 0, ',');
    try writeChosen(&out.writer, &d.model().inner, 2, ',');
    try writeChosen(&out.writer, &d.model().inner, 3, ',');
    try testing.expectEqualStrings("y,2\n2\ny,2\n", out.written());
}

test "--hide-count, --no-show-help, and --height" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try parse(&arena, "n\n1\n2\n3\n", .{});
    const counted: Flags = .{ .border = .none, .hide_count = true, .height = 3 };
    const model = framed(testing.allocator, try buildOf(&arena, records, counted), counted);
    var d: tui.testing.Driver(term.Framed(Table)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("n\n1\n2\n\n↑/↓ navigate • enter select • esc quit");
    const bare: Flags = .{ .border = .none, .show_help = false };
    const plain = framed(testing.allocator, try buildOf(&arena, records, bare), bare);
    var e: tui.testing.Driver(term.Framed(Table)) = try .init(testing.allocator, plain, .{});
    defer e.deinit();
    try e.expectFrame("n\n1\n2\n3");
}

test "a narrow terminal: the rows fit its height, the help line with the count its width" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try parse(&arena, "n\n1\n2\n3\n", .{});
    const flags: Flags = .{ .border = .none };
    const model = framed(testing.allocator, try buildOf(&arena, records, flags), flags);
    var d: tui.testing.Driver(term.Framed(Table)) = try .init(testing.allocator, model, .{
        .program = .{ .size = .{ .width = 20, .height = 5 } },
    });
    defer d.deinit();
    // Five rows: the header, two of the three, and the help line under a blank one.
    try d.expectFrame("n\n1\n2\n\n1/3 • ↑/↓ navigate …");
}
