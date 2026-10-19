//! `termancy ui table`: show CSV or TSV as a table, and choose a row.

const std = @import("std");
const cli = @import("cli");
const field_ = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const Table = @import("../tui/registry/table.zig").Table;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Border = enum { none, normal, rounded, thick, double, hidden, ascii };

pub const Flags = struct {
    separator: []const u8 = ",",
    columns: []const []const u8 = &.{},
    widths: []const usize = &.{},
    border: Border = .rounded,
    height: usize = 10,
    print: bool = false,
};
const flags_flags = cli.flags(Flags, field_.Set(.{field_.Spec(Flags){ .fields = .{
    .separator = .{ .help = "The field separator: one character, or \\t (or tab) for TSV" },
    .columns = .{ .help = "Column titles, comma-separated; then the first line is data, not titles" },
    .widths = .{ .help = "Column widths, comma-separated; 0 fits the column to its cells" },
    .border = .{ .help = "Border style: none, normal, rounded, thick, double, hidden, or ascii" },
    .height = .{ .help = "Rows shown at once" },
    .print = .{ .help = "Print the table to standard output instead" },
} }}), .{ .fields = .{
    .separator = .{ .short = 's' },
    .columns = .{ .short = 'c', .value_name = "titles", .split = ',' },
    .widths = .{ .short = 'w', .split = ',' },
    .border = .{ .value_name = "style" },
    .print = .{ .short = 'p' },
} });

pub const command = cli.command(.{
    .name = "table",
    .summary = "Show CSV or TSV as a table and choose a row",
    .description =
    \\Read CSV (or, with --separator, any one-character-separated values) from standard
    \\input: the first line holds the column titles unless --columns gives them. Fields
    \\may be quoted ("a, b"), with "" for a quote inside.
    \\
    \\Interactively, up/down move, enter prints the chosen row as a line of the same
    \\format, esc cancels (status 1), and Ctrl-C interrupts (status 130). With --print,
    \\the table is written to standard output instead, colored only where standard
    \\output shows colors.
    ,
    .flags = flags_flags,
    .examples =
    \\termancy ui table < people.csv
    \\ps -eo pid,comm | tr -s ' ' | sed 's/^ //' | termancy ui table -s ' ' | cut -d' ' -f1
    \\termancy ui table --print --separator tab < data.tsv
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const separator = parseSeparator(flags.separator) orelse
        return ctx.usageError("invalid --separator \"{s}\" (use one character, or \\t)", .{
            flags.separator,
        });
    const text = try term.readStdin(ctx) orelse
        return ctx.usageError("no table: give CSV on standard input", .{});
    const records = parse(ctx.arena, text, separator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedQuote => {
            return ctx.fail("standard input: a quoted field never ends", .{});
        },
    };
    if (records.len == 0) return ctx.fail("standard input holds no table", .{});
    var table = try build(ctx.arena, records, flags);
    if (flags.print) {
        var block: Writer.Allocating = .init(ctx.arena);
        try table.view(&block.writer);
        try term.writeStyled(ctx.out, block.written(), try term.stdoutColor(ctx));
        try ctx.out.writeByte('\n');
        return;
    }
    if (try term.run(ctx, Table, &table, term.suspend_options)) return term.exitInterrupted(ctx);
    if (table.status != .submitted) return error.CommandFailed;
    try writeRecord(ctx.out, table.selected().?, separator);
}

/// The separator `--separator` names: one byte, or a tab for `\t` and `tab`.
pub fn parseSeparator(text: []const u8) ?u8 {
    if (std.mem.eql(u8, text, "\\t") or std.mem.eql(u8, text, "tab")) return '\t';
    if (text.len != 1 or text[0] == '"' or text[0] == '\n') return null;
    return text[0];
}

/// The table for `records` and the flags: titles from `--columns` or the first record.
pub fn build(
    arena: Allocator,
    records: []const []const []const u8,
    flags: Flags,
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
    return .{
        .columns = columns,
        .rows = rows,
        .height = @max(flags.height, 1),
        .selectable = !flags.print,
        .border = switch (flags.border) {
            .none => null,
            inline else => |tag| @field(Table.Border, @tagName(tag)),
        },
    };
}

/// Splits `text` into records of fields: fields end at `separator`, records at a line
/// break (`\n` or `\r\n`). A field in double quotes may hold separators and line breaks,
/// with `""` standing for a quote. Blank lines are skipped.
pub fn parse(
    arena: Allocator,
    text: []const u8,
    separator: u8,
) error{ OutOfMemory, UnterminatedQuote }![]const []const []const u8 {
    var records: std.ArrayList([]const []const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        var fields: std.ArrayList([]const u8) = .empty;
        while (true) {
            try fields.append(arena, try parseField(arena, text, &i, separator));
            if (i < text.len and text[i] == separator) {
                i += 1;
            } else break;
        }
        if (i < text.len and text[i] == '\r') i += 1;
        if (i < text.len and text[i] == '\n') i += 1;
        const blank = fields.items.len == 1 and fields.items[0].len == 0;
        if (!blank) try records.append(arena, fields.items);
    }
    return records.items;
}

/// The field at `i.*`; leaves `i.*` on the separator or line break after it.
fn parseField(
    arena: Allocator,
    text: []const u8,
    i: *usize,
    separator: u8,
) error{ OutOfMemory, UnterminatedQuote }![]const u8 {
    const start = i.*;
    if (start >= text.len or text[start] != '"') {
        var end = start;
        while (end < text.len and text[end] != separator and text[end] != '\n') end += 1;
        i.* = end;
        return std.mem.trimEnd(u8, text[start..end], "\r");
    }
    var field: std.ArrayList(u8) = .empty;
    var at = start + 1;
    while (true) {
        const quote = std.mem.indexOfScalarPos(u8, text, at, '"') orelse
            return error.UnterminatedQuote;
        try field.appendSlice(arena, text[at..quote]);
        if (quote + 1 < text.len and text[quote + 1] == '"') {
            try field.append(arena, '"');
            at = quote + 2;
        } else {
            at = quote + 1;
            break;
        }
    }
    // Anything between the closing quote and the separator is kept, as text.
    while (at < text.len and text[at] != separator and text[at] != '\n') : (at += 1) {
        if (text[at] != '\r') try field.append(arena, text[at]);
    }
    i.* = at;
    return field.items;
}

/// Writes `fields` as one record, quoting the fields that need it, and a line break.
pub fn writeRecord(w: *Writer, fields: []const []const u8, separator: u8) Writer.Error!void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(separator);
        const special = [_]u8{ separator, '"', '\n', '\r' };
        if (std.mem.indexOfAny(u8, field, &special) == null) {
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

test parse {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try parse(
        arena.allocator(),
        "name,note\r\nAda,\"says \"\"hi\"\", twice\"\n\nBob,\"two\nlines\"\nC,",
        ',',
    );
    try testing.expectEqual(4, records.len);
    try testing.expectEqualStrings("note", records[0][1]);
    try testing.expectEqualStrings("says \"hi\", twice", records[1][1]);
    try testing.expectEqualStrings("two\nlines", records[2][1]);
    try testing.expectEqual(2, records[3].len);
    try testing.expectEqualStrings("", records[3][1]);
    try testing.expectError(error.UnterminatedQuote, parse(arena.allocator(), "\"x", ','));
    const tsv = try parse(arena.allocator(), "a\tb c\n", '\t');
    try testing.expectEqualStrings("b c", tsv[0][1]);
}

test writeRecord {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeRecord(&w, &.{ "plain", "a,b", "say \"x\"" }, ',');
    try writeRecord(&w, &.{ "a,b", "c" }, '\t');
    try testing.expectEqualStrings("plain,\"a,b\",\"say \"\"x\"\"\"\na,b\tc\n", w.buffered());
}

test parseSeparator {
    try testing.expectEqual('\t', parseSeparator("\\t").?);
    try testing.expectEqual('\t', parseSeparator("tab").?);
    try testing.expectEqual(';', parseSeparator(";").?);
    try testing.expectEqual(null, parseSeparator(";;"));
    try testing.expectEqual(null, parseSeparator("\""));
}

test "build: titles from the first record or from --columns, and widths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = [_][]const []const u8{ &.{ "a", "b" }, &.{ "1", "2" } };
    const from_data = try build(arena.allocator(), &records, .{ .widths = &.{ 0, 4 } });
    try testing.expectEqualStrings("b", from_data.columns[1].title);
    try testing.expectEqual(null, from_data.columns[0].width);
    try testing.expectEqual(4, from_data.columns[1].width.?);
    try testing.expectEqual(1, from_data.rows.len);
    const named = try build(arena.allocator(), &records, .{ .columns = &.{ "x", "y" } });
    try testing.expectEqual(2, named.rows.len);
    const empty = try build(arena.allocator(), &.{}, .{ .print = true, .border = .none });
    try testing.expectEqual(0, empty.columns.len);
    try testing.expect(!empty.selectable and empty.border == null);
}

test "choosing a row" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try parse(arena.allocator(), "n,v\nx,1\ny,2\n", ',');
    var d: tui.testing.Driver(Table) = undefined;
    const table = try build(arena.allocator(), records, .{ .border = .ascii });
    d = try .init(testing.allocator, table, .{});
    defer d.deinit();
    try d.expectFrame("+---+---+\n| n | v |\n+---+---+\n| x | 1 |\n| y | 2 |\n+---+---+");
    try d.press("down");
    try d.press("enter");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeRecord(&out.writer, d.model().selected().?, ',');
    try testing.expectEqualStrings("y,2\n", out.written());
}
