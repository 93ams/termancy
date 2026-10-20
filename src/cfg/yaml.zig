//! YAML <-> `Value`, for the configuration subset of YAML 1.2.
//!
//! Reading covers block mappings and sequences (including a sequence at its key's own
//! indentation), flow collections that may span lines, plain, single- and double-quoted
//! scalars (all of which may span lines and fold), literal (`|`) and folded (`>`) block
//! scalars with chomping and indentation indicators, comments, and the `---`/`...`
//! markers. A leading byte-order mark is skipped and `\r\n` line breaks are accepted.
//! With `ParseOptions.aliases`, anchors (`&name`) and aliases (`*name`) work too, an alias
//! copying its anchor's node, within a budget of copied nodes that stops a
//! "billion laughs" document.
//!
//! Plain scalars resolve with the core schema: `null`/`~`/empty, `true`/`false` in three
//! casings, decimal, `0x` and `0o` integers, and floats including `.inf`, `-.inf` and `.nan`.
//! Anything else, and every quoted or block scalar, is a string. A decimal integer too large
//! for an `i64` becomes a float, as in `json.zig`. An empty document is an empty table.
//!
//! Rejected with a positioned error, never misread: anchors and aliases unless enabled,
//! tags, merge keys, complex (`?`) keys, directives, a second document, tabs in
//! indentation, duplicate keys, and inconsistent indentation.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const writeFloat = @import("value.zig").writeFloat;
const Diagnostic = @import("Diagnostic.zig");
const bomLength = @import("format.zig").bomLength;

/// What parsing can fail with; the diagnostic says where.
pub const Error = error{SyntaxError} || Allocator.Error;

/// Nesting deeper than this is rejected, which bounds the parser's recursion.
pub const max_depth = 256;

/// Parses one YAML document. All memory comes from `arena`; the result shares nothing with
/// `source`.
pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diagnostic) Error!Value {
    return parseWith(arena, source, diag, .{});
}

/// What reading from a stream can fail with.
pub const ReadError = Error || error{ ReadFailed, StreamTooLong };

/// Parses one YAML document read from `reader` without holding all of its text: the text
/// is parsed a top-level entry at a time, cut before each line that starts a key at the
/// first column, and each piece's text is freed (it lives in `scratch`) once it is part of
/// the tree in `arena`. A piece that does not parse alone, such as a quoted value running
/// past the cut, is joined with the next, so a document reads as `parse` reads it. A
/// document that is not a mapping at the first column is held whole. More than
/// `max_bytes` is `error.StreamTooLong`.
pub fn parseReader(
    arena: Allocator,
    scratch: Allocator,
    reader: *std.Io.Reader,
    max_bytes: usize,
    diag: ?*Diagnostic,
) ReadError!Value {
    var root: Value = .empty_table;
    var piece: std.Io.Writer.Allocating = .init(scratch);
    defer piece.deinit();
    // The line the piece starts on, its lines so far, and whether one starts a key.
    var first_line: u32 = 1;
    var lines_in_piece: u32 = 0;
    var has_key = false;
    // After a piece fails, it is tried again only once it has doubled, so that a document
    // with an early error is not parsed over and over.
    var retry_at: usize = 0;
    var total: usize = 0;
    while (true) {
        const line_start = piece.written().len;
        const streamed = reader.streamDelimiterEnding(&piece.writer, '\n') catch |err|
            switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return error.OutOfMemory,
            };
        const at_end = if (reader.takeByte()) |_| false else |err| switch (err) {
            error.EndOfStream => true,
            error.ReadFailed => return error.ReadFailed,
        };
        total += streamed + 1;
        if (total > max_bytes + 1) return error.StreamTooLong;
        if (at_end and streamed == 0) break;
        piece.writer.writeByte('\n') catch return error.OutOfMemory;
        const line = piece.written()[line_start..];
        const key = startsKey(line);
        if (key and has_key and line_start >= retry_at) {
            const before = piece.written()[0..line_start];
            if (try parsePiece(arena, &root, before, first_line, false, null)) {
                // The new line starts the next piece.
                const rest = try scratch.dupe(u8, line);
                defer scratch.free(rest);
                piece.clearRetainingCapacity();
                piece.writer.writeAll(rest) catch return error.OutOfMemory;
                first_line += lines_in_piece;
                lines_in_piece = 0;
                retry_at = 0;
            } else {
                retry_at = 2 * line_start;
            }
        }
        lines_in_piece += 1;
        has_key = has_key or key;
        if (at_end) break;
    }
    const last = piece.written();
    if (last.len > 0 and !try parsePiece(arena, &root, last, first_line, true, diag)) {
        return error.SyntaxError;
    }
    return root;
}

/// Parses `text`, which starts on line `first_line` of the document (and is the rest of it
/// when `last`), and adds its keys to `root`. Returns false, with `diag` set, when it does
/// not parse or repeats a key.
fn parsePiece(
    arena: Allocator,
    root: *Value,
    text: []const u8,
    first_line: u32,
    last: bool,
    diag: ?*Diagnostic,
) Allocator.Error!bool {
    const parsed = parse(arena, text, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            if (diag) |d| d.line += first_line - 1;
            return false;
        },
    };
    if (parsed != .table) {
        // A document that is not a mapping is one piece, and the whole result: a piece
        // that is not one is joined with the next, and after mappings it does not parse.
        if (!last) return false;
        if (root.table.count() > 0) {
            if (diag) |d| d.* = .{ .line = first_line, .column = 1, .message = "expected a key" };
            return false;
        }
        root.* = parsed;
        return true;
    }
    var it = parsed.table.iterator();
    while (it.next()) |entry| {
        const slot = try root.table.getOrPut(arena, entry.key_ptr.*);
        if (slot.found_existing) {
            if (diag) |d| d.* = .{ .line = first_line, .column = 1, .message = "duplicate key" };
            return false;
        }
        slot.value_ptr.* = entry.value_ptr.*;
    }
    return true;
}

/// Whether `line` starts a key at the first column: a plain key and its `:`.
fn startsKey(line: []const u8) bool {
    if (line.len == 0) return false;
    switch (line[0]) {
        ' ', '\t', '\r', '\n', '#', '-', '[', ']', '{', '}', ',', '?' => return false,
        ':', '|', '>', '!', '&', '*', '%', '@', '`', '"', '\'', '.' => return false,
        else => {},
    }
    var i: usize = 1;
    while (i < line.len) : (i += 1) switch (line[i]) {
        // YAML separates with spaces and tabs only: `a:\x0c` is not a key.
        ':' => switch (if (i + 1 == line.len) '\n' else line[i + 1]) {
            ' ', '\t', '\r', '\n' => return true,
            else => {},
        },
        '#' => if (line[i - 1] == ' ' or line[i - 1] == '\t') return false,
        '\n' => return false,
        else => {},
    };
    return false;
}

/// A block mapping entry, `key: value`, as it sits in the source, for editing in place.
pub const Span = struct {
    /// The entry's key path: the keys and sequence indices leading to it, then its key.
    path: []const []const u8,
    /// The start of the key's line.
    start: usize,
    /// After the entry's last line with content (its value's, for a block value).
    end: usize,
    /// The key's column.
    indent: usize,
    /// The value, when it is one scalar or flow collection on the key's line; otherwise
    /// both are zero.
    value_start: usize = 0,
    value_end: usize = 0,
};

/// Parses `source` and returns every block mapping entry, in order. Fails as `parse` does.
pub fn spans(arena: Allocator, source: []const u8) Error![]const Span {
    var list: std.ArrayList(Span) = .empty;
    var parser: Parser = try .init(arena, source, null);
    parser.spans = &list;
    _ = try parser.document();
    return list.items;
}

/// What `parse` accepts.
pub const ParseOptions = struct {
    /// Accept anchors (`&name`) and aliases (`*name`).
    aliases: bool = false,
    /// The most nodes aliases may copy in all, beyond which the document is rejected.
    alias_budget: usize = 10_000,
};

/// Parses with options: anchors and aliases are off by default, since a document of a few
/// lines can alias its way to billions of nodes.
pub fn parseWith(
    arena: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
    options: ParseOptions,
) Error!Value {
    var parser: Parser = try .init(arena, source, diag);
    parser.options = options;
    parser.budget = options.alias_budget;
    return parser.document();
}

const Line = struct {
    start: usize,
    /// Exclusive, and before the line break and any `\r` that precedes it.
    end: usize,
};

const Marker = enum { document_start, document_end };

const Chomping = enum { strip, clip, keep };

/// A scalar read from the source, and the offset just past it.
const Scalar = struct { text: []const u8, end: usize };

/// A flow node, and the offset just past it.
const Flowed = struct { value: Value, end: usize };

const Key = struct {
    text: []const u8,
    quoted: bool,
    /// Just past the `:`.
    value: usize,
};

/// A recursive-descent parser over the source split into lines. Block structure is read
/// line by line; quoted scalars and flow collections are read by offset, since they may
/// span lines, and the current line then catches up with them.
const Parser = struct {
    arena: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
    lines: []const Line,
    /// The current line: the first one not yet consumed.
    line: usize = 0,
    depth: usize = 0,
    /// Where the last plain scalar ended, to explain an over-indented line after it.
    plain: ?struct { line: usize, min_indent: usize } = null,
    options: ParseOptions = .{},
    anchors: std.StringHashMapUnmanaged(Value) = .empty,
    /// Nodes aliases may still copy.
    budget: usize = 0,
    /// When set, every block mapping entry is recorded here (see `spans`).
    spans: ?*std.ArrayList(Span) = null,
    /// While recording: the path to the node being parsed.
    section: std.ArrayList([]const u8) = .empty,
    /// Where the last value read ended, when it was one scalar or flow collection on one
    /// line; null otherwise.
    value_end: ?usize = null,

    fn init(arena: Allocator, source: []const u8, diag: ?*Diagnostic) Allocator.Error!Parser {
        var lines: std.ArrayList(Line) = .empty;
        var start: usize = bomLength(source);
        // A final line break ends the last line rather than starting an empty one.
        while (true) {
            const newline = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
            const crlf = newline > start and source[newline - 1] == '\r';
            try lines.append(arena, .{ .start = start, .end = if (crlf) newline - 1 else newline });
            start = newline + 1;
            if (start >= source.len) break;
        }
        return .{ .arena = arena, .source = source, .diag = diag, .lines = lines.items };
    }

    fn fail(p: *const Parser, offset: usize, comptime message: []const u8) error{SyntaxError} {
        Diagnostic.report(p.diag, p.source, offset, message);
        return error.SyntaxError;
    }

    fn enter(p: *Parser, offset: usize) error{SyntaxError}!void {
        if (p.depth == max_depth) return p.fail(offset, "nesting is too deep");
        p.depth += 1;
    }

    fn leave(p: *Parser) void {
        assert(p.depth > 0);
        p.depth -= 1;
    }

    fn lineEnd(p: *const Parser) usize {
        return p.lines[p.line].end;
    }

    /// The column of `offset`, which must lie on the current line.
    fn column(p: *const Parser, offset: usize) usize {
        const line = p.lines[p.line];
        assert(offset >= line.start and offset <= line.end);
        return offset - line.start;
    }

    /// Skips spaces and tabs, without leaving the current line.
    fn skipSpace(p: *const Parser, offset: usize) usize {
        var i = offset;
        while (i < p.lineEnd() and isSpace(p.source[i])) i += 1;
        return i;
    }

    /// Whether the current line holds nothing but blanks and perhaps a comment from `offset`.
    fn restIsBlank(p: *const Parser, offset: usize) bool {
        return p.lineRestIsBlank(p.line, offset);
    }

    /// Whether line `index` holds nothing but blanks and perhaps a comment from `offset`.
    fn lineRestIsBlank(p: *const Parser, index: usize, offset: usize) bool {
        const line = p.lines[index];
        var i = offset;
        while (i < line.end and isSpace(p.source[i])) i += 1;
        if (i == line.end) return true;
        return p.source[i] == '#' and (i == line.start or isSpace(p.source[i - 1]));
    }

    /// Whether `offset` holds the indicator `c` followed by a blank, as block indicators
    /// (`-`, `?`) require.
    fn isIndicator(p: *const Parser, offset: usize, c: u8) bool {
        return p.source[offset] == c and separated(p.source, offset + 1);
    }

    /// The document marker on the current line, if any.
    fn marker(p: *const Parser) ?Marker {
        const line = p.lines[p.line];
        const text = p.source[line.start..line.end];
        if (text.len < 3 or (text.len > 3 and !isSpace(text[3]))) return null;
        if (std.mem.startsWith(u8, text, "---")) return .document_start;
        if (std.mem.startsWith(u8, text, "...")) return .document_end;
        return null;
    }

    /// Moves to the next line with content and returns the offset of that content, or null
    /// at the end of input. Rejects tabs in the indentation of that line.
    fn skipBlank(p: *Parser) error{SyntaxError}!?usize {
        while (p.line < p.lines.len) : (p.line += 1) {
            const line = p.lines[p.line];
            if (p.restIsBlank(line.start)) continue;
            const content = p.skipSpace(line.start);
            if (std.mem.findScalar(u8, p.source[line.start..content], '\t')) |tab| {
                return p.fail(line.start + tab, "tabs are not allowed in indentation");
            }
            return content;
        }
        return null;
    }

    /// Like `skipBlank`, but a document marker also ends the current block.
    fn peekContent(p: *Parser) error{SyntaxError}!?usize {
        const offset = try p.skipBlank() orelse return null;
        return if (p.marker() == null) offset else null;
    }

    /// The error for a line indented deeper than its block allows.
    fn overIndented(p: *const Parser, offset: usize) error{SyntaxError} {
        if (p.continuesPlain(offset)) {
            return p.fail(offset, "a plain scalar cannot continue on the next line; quote it");
        }
        return p.fail(offset, "inconsistent indentation");
    }

    /// Whether the content at `offset` is where a multi-line plain scalar would continue:
    /// the first content line after one, indented as its continuation must be.
    fn continuesPlain(p: *const Parser, offset: usize) bool {
        const plain = p.plain orelse return false;
        if (plain.line >= p.line or p.column(offset) < plain.min_indent) return false;
        for (plain.line + 1..p.line) |index| {
            if (!p.lineRestIsBlank(index, p.lines[index].start)) return false;
        }
        return true;
    }

    fn document(p: *Parser) Error!Value {
        const start = try p.skipBlank() orelse return .empty_table;
        if (p.source[start] == '%') return p.fail(start, "directives are not supported");
        var root: Value = .empty_table;
        if (p.marker() == .document_start and !p.restIsBlank(start + 3)) {
            root = try p.inlineValue(p.skipSpace(start + 3), 0);
        } else {
            if (p.marker() == .document_start) p.line += 1;
            if (try p.peekContent()) |offset| root = try p.blockNode(offset, 0);
        }
        try p.documentEnd();
        assert(p.depth == 0);
        return root;
    }

    /// Checks that nothing but an optional `...` follows the root node.
    fn documentEnd(p: *Parser) error{SyntaxError}!void {
        const offset = try p.skipBlank() orelse return;
        const end = p.marker() orelse
            return p.fail(offset, "unexpected content at this indentation");
        if (end == .document_start) return p.fail(offset, "multiple documents are not supported");
        if (!p.restIsBlank(offset + 3)) return p.fail(offset + 3, "unexpected text after '...'");
        p.line += 1;
        if (try p.skipBlank()) |next| {
            return p.fail(next, "multiple documents are not supported");
        }
    }

    /// Parses the block node whose first character is at `offset` on the current line. A
    /// block scalar's content must be indented at least `min_indent`.
    fn blockNode(p: *Parser, offset: usize, min_indent: usize) Error!Value {
        try p.enter(offset);
        defer p.leave();
        if (p.options.aliases and p.source[offset] == '&') return p.anchored(offset, min_indent);
        if (p.isIndicator(offset, '-')) return p.sequence(offset);
        try p.rejectIndicator(offset);
        if (try p.mappingKey(offset) != null) return p.mapping(offset);
        return p.inlineValue(offset, min_indent);
    }

    /// Rejects, by its first character, a node that uses a feature this subset leaves out
    /// or that no plain scalar may start with.
    fn rejectIndicator(p: *const Parser, offset: usize) error{SyntaxError}!void {
        switch (p.source[offset]) {
            '&' => if (!p.options.aliases) return p.fail(offset, "anchors ('&') are not supported"),
            '*' => if (!p.options.aliases) return p.fail(offset, "aliases ('*') are not supported"),
            '!' => return p.fail(offset, "tags ('!') are not supported"),
            '?' => if (separated(p.source, offset + 1)) {
                return p.fail(offset, "complex keys ('?') are not supported");
            },
            '%', '@', '`' => return p.fail(offset, "reserved indicator ('%', '@' or '`')"),
            ',', ']', '}' => return p.fail(offset, "unexpected flow indicator"),
            '#' => return p.fail(offset, "a comment needs a blank before its '#'"),
            else => {},
        }
    }

    /// The `key:` starting at `offset` on the current line, or null when there is none.
    fn mappingKey(p: *Parser, offset: usize) Error!?Key {
        switch (p.source[offset]) {
            '"', '\'' => {
                const scalar = try p.quoted(offset);
                if (scalar.end > p.lineEnd()) return null;
                const colon = p.skipSpace(scalar.end);
                if (colon == p.lineEnd() or !p.isIndicator(colon, ':')) return null;
                return .{ .text = scalar.text, .quoted = true, .value = colon + 1 };
            },
            '[', '{' => return null,
            else => {},
        }
        for (offset..p.lineEnd()) |i| switch (p.source[i]) {
            ':' => if (separated(p.source, i + 1)) {
                const text = std.mem.trimEnd(u8, p.source[offset..i], " \t");
                return .{ .text = try p.arena.dupe(u8, text), .quoted = false, .value = i + 1 };
            },
            '#' => if (i > offset and isSpace(p.source[i - 1])) return null,
            else => {},
        };
        return null;
    }

    /// Parses a block mapping whose first key is at `first`. Its keys share that column.
    fn mapping(p: *Parser, first: usize) Error!Value {
        const indent = p.column(first);
        var table: Table = .empty;
        var offset = first;
        while (true) {
            try p.rejectIndicator(offset);
            const key = try p.mappingKey(offset) orelse
                return p.fail(offset, "expected a mapping key");
            if (!key.quoted) {
                if (key.text.len == 0) return p.fail(offset, "empty keys are not supported");
                if (std.mem.eql(u8, key.text, "<<")) {
                    return p.fail(offset, "merge keys ('<<') are not supported");
                }
            }
            if (table.contains(key.text)) return p.fail(offset, "duplicate key");
            const key_line = p.line;
            if (p.spans != null) try p.section.append(p.arena, key.text);
            const value_start = p.skipSpace(key.value);
            p.value_end = null;
            const value = try p.mappingValue(key.value, indent);
            try table.putNoClobber(p.arena, key.text, value);
            if (p.spans) |list| {
                const inline_end = p.value_end;
                try list.append(p.arena, .{
                    .path = try p.arena.dupe([]const u8, p.section.items),
                    .start = p.lines[key_line].start,
                    .end = p.entryEnd(key_line),
                    .indent = indent,
                    .value_start = if (inline_end != null) value_start else 0,
                    .value_end = inline_end orelse 0,
                });
                _ = p.section.pop();
            }

            offset = try p.peekContent() orelse break;
            const col = p.column(offset);
            if (col < indent) break;
            if (col > indent) return p.overIndented(offset);
        }
        return .{ .table = table };
    }

    /// After the last line with content before the current line, and after `first`.
    fn entryEnd(p: *const Parser, first: usize) usize {
        var last = @min(p.line, p.lines.len) -| 1;
        while (last > first and p.lineRestIsBlank(last, p.lines[last].start)) last -= 1;
        const line = p.lines[last];
        // Past the line break, when there is one.
        const crlf = line.end < p.source.len and p.source[line.end] == '\r';
        return @min(line.end + 1 + @intFromBool(crlf), p.source.len);
    }

    /// Parses the value after the `:` at `offset - 1`, for a mapping at column `indent`.
    fn mappingValue(p: *Parser, offset: usize, indent: usize) Error!Value {
        const start = p.skipSpace(offset);
        if (!p.restIsBlank(start)) {
            if (p.isIndicator(start, '-')) {
                return p.fail(start, "a block sequence cannot start on the line of its key");
            }
            const value = try p.inlineValue(start, indent + 1);
            return value;
        }
        defer p.value_end = null; // A block value is not one span to replace.
        p.line += 1;
        const next = try p.peekContent() orelse return .null;
        const col = p.column(next);
        // A sequence may sit at its key's own indentation.
        if (col > indent or (col == indent and p.isIndicator(next, '-'))) {
            return p.blockNode(next, indent + 1);
        }
        return .null;
    }

    /// Parses a block sequence whose first `-` is at `first`. Its items share that column.
    fn sequence(p: *Parser, first: usize) Error!Value {
        const indent = p.column(first);
        var array: Array = .empty;
        var offset = first;
        while (true) {
            assert(p.isIndicator(offset, '-'));
            if (p.spans != null) {
                const index = try std.fmt.allocPrint(p.arena, "{d}", .{array.items.len});
                try p.section.append(p.arena, index);
            }
            try array.append(p.arena, try p.sequenceItem(offset + 1, indent));
            if (p.spans != null) _ = p.section.pop();

            offset = try p.peekContent() orelse break;
            const col = p.column(offset);
            if (col < indent) break;
            if (col > indent) return p.overIndented(offset);
            // A key of the mapping this sequence is the compact value of.
            if (!p.isIndicator(offset, '-')) break;
        }
        return .{ .array = array };
    }

    /// Parses the item after a `-` at column `indent`; `offset` is just past the `-`.
    fn sequenceItem(p: *Parser, offset: usize, indent: usize) Error!Value {
        const start = p.skipSpace(offset);
        if (!p.restIsBlank(start)) return p.blockNode(start, indent + 1);
        p.line += 1;
        const next = try p.peekContent() orelse return .null;
        if (p.column(next) > indent) return p.blockNode(next, indent + 1);
        return .null;
    }

    /// Parses a scalar or flow collection that starts at `offset` and ends its line (a later
    /// line, for one that spans lines). Block scalar content is indented at least
    /// `min_indent`.
    fn inlineValue(p: *Parser, offset: usize, min_indent: usize) Error!Value {
        try p.rejectIndicator(offset);
        switch (p.source[offset]) {
            '&' => return p.anchored(offset, min_indent),
            '*' => {
                const end = p.nameEnd(offset + 1);
                const value = try p.alias(offset, end);
                try p.finishLine(end);
                p.value_end = end;
                return value;
            },
            '|', '>' => return p.blockScalar(offset, min_indent),
            '"', '\'' => {
                const scalar = try p.quoted(offset);
                const one_line = p.lines[p.line].end >= scalar.end;
                try p.finishLine(scalar.end);
                p.value_end = if (one_line) scalar.end else null;
                return .{ .string = scalar.text };
            },
            '[', '{' => {
                const flowed = try p.flowValue(offset);
                const one_line = p.lines[p.line].end >= flowed.end;
                try p.finishLine(flowed.end);
                p.value_end = if (one_line) flowed.end else null;
                return flowed.value;
            },
            else => return p.plainScalar(offset, min_indent),
        }
    }

    /// A block plain scalar, which continues on following lines indented at least
    /// `min_indent`: lines join with a space, and each empty line between becomes a break.
    fn plainScalar(p: *Parser, offset: usize, min_indent: usize) Error!Value {
        const end = p.plainEnd(offset);
        const first = std.mem.trimEnd(u8, p.source[offset..end], " \t");
        const first_end = offset + first.len;
        if (end < p.lineEnd() and p.source[end] == '#') {
            // A comment ends the scalar.
            p.plain = .{ .line = p.line, .min_indent = min_indent };
            try p.finishLine(end);
            p.value_end = first_end;
            return p.resolvePlain(first, offset);
        }
        try p.finishLine(end);
        p.value_end = first_end;
        var joined: ?std.ArrayList(u8) = null;
        while (p.line < p.lines.len and p.marker() == null) {
            // Look past empty lines for a continuation.
            var next = p.line;
            var empties: usize = 0;
            while (next < p.lines.len) : (next += 1) {
                if (!p.lineRestIsBlank(next, p.lines[next].start)) break;
                const line = p.lines[next];
                // A comment line ends the scalar; an empty one may sit inside it.
                if (std.mem.trim(u8, p.source[line.start..line.end], " \t").len > 0) break;
                empties += 1;
            }
            if (next >= p.lines.len or p.lineRestIsBlank(next, p.lines[next].start)) break;
            const line = p.lines[next];
            const content = std.mem.indexOfNone(u8, p.source[line.start..line.end], " ").?;
            if (content < min_indent) break;
            const saved = p.line;
            p.line = next;
            if (p.marker() != null) {
                p.line = saved;
                break;
            }
            const start = line.start + content;
            if (p.source[start] == '\t') {
                return p.fail(start, "tabs are not allowed in indentation");
            }
            const piece_end = p.plainEnd(start);
            if (piece_end < p.lineEnd() and p.source[piece_end] == ':') {
                return p.fail(piece_end, "unexpected ':' in a plain scalar; quote it");
            }
            if (joined == null) {
                joined = .empty;
                try joined.?.appendSlice(p.arena, first);
            }
            if (empties == 0) {
                try joined.?.append(p.arena, ' ');
            } else {
                try joined.?.appendNTimes(p.arena, '\n', empties);
            }
            const piece = std.mem.trimEnd(u8, p.source[start..piece_end], " \t");
            try joined.?.appendSlice(p.arena, piece);
            try p.finishLine(piece_end);
        }
        const text = if (joined) |list| list.items else first;
        if (joined != null) {
            p.value_end = null;
            return .{ .string = text };
        }
        return p.resolvePlain(text, offset);
    }

    // -- Anchors and aliases ---------------------------------------------------------------

    /// The end of an anchor or alias name starting at `offset`.
    fn nameEnd(p: *const Parser, offset: usize) usize {
        var i = offset;
        while (i < p.source.len) : (i += 1) {
            const c = p.source[i];
            if (isBlank(c) or c == '\n' or c == '\r' or isFlowIndicator(c)) break;
        }
        return i;
    }

    /// Parses the node after `&name` at `offset` and records it under `name`. The node is
    /// on the same line, or, when the line ends, the block on the lines below.
    fn anchored(p: *Parser, offset: usize, min_indent: usize) Error!Value {
        const end = p.nameEnd(offset + 1);
        if (end == offset + 1) return p.fail(offset, "expected an anchor name");
        const name = p.source[offset + 1 .. end];
        const start = p.skipSpace(end);
        const value = if (!p.restIsBlank(start))
            try p.blockNode(start, min_indent)
        else blk: {
            p.line += 1;
            const next = try p.peekContent() orelse break :blk Value.null;
            const col = p.column(next);
            const indent = min_indent -| 1;
            if (col >= min_indent or (col == indent and p.isIndicator(next, '-'))) {
                break :blk try p.blockNode(next, min_indent);
            }
            break :blk Value.null;
        };
        try p.anchors.put(p.arena, name, value);
        p.value_end = null; // Replacing the value alone would drop the anchor.
        return value;
    }

    /// The node `*name` at `offset` (ending at `end`) refers to, copied.
    fn alias(p: *Parser, offset: usize, end: usize) Error!Value {
        if (end == offset + 1) return p.fail(offset, "expected an alias name");
        const value = p.anchors.get(p.source[offset + 1 .. end]) orelse
            return p.fail(offset, "alias to an unknown anchor");
        return p.copy(value, offset);
    }

    fn copy(p: *Parser, value: Value, offset: usize) Error!Value {
        if (p.budget == 0) return p.fail(offset, "aliases copy too many nodes");
        p.budget -= 1;
        switch (value) {
            .table => |t| {
                var out: Table = .empty;
                var it = t.iterator();
                while (it.next()) |entry| {
                    try out.put(p.arena, entry.key_ptr.*, try p.copy(entry.value_ptr.*, offset));
                }
                return .{ .table = out };
            },
            .array => |a| {
                var out: Array = .empty;
                for (a.items) |item| try out.append(p.arena, try p.copy(item, offset));
                return .{ .array = out };
            },
            else => return value,
        }
    }

    /// The end of the block plain scalar starting at `offset`: the end of the line, a `: `,
    /// or a ` #` comment.
    fn plainEnd(p: *const Parser, offset: usize) usize {
        var i = offset;
        while (i < p.lineEnd()) : (i += 1) {
            const c = p.source[i];
            if (c == ':' and separated(p.source, i + 1)) break;
            if (c == '#' and i > offset and isSpace(p.source[i - 1])) break;
        }
        return i;
    }

    /// Moves to the line holding `end`, checks that only blanks or a comment follow it, and
    /// moves past that line.
    fn finishLine(p: *Parser, end: usize) error{SyntaxError}!void {
        while (p.line + 1 < p.lines.len and p.lines[p.line + 1].start <= end) p.line += 1;
        const i = p.skipSpace(end);
        if (!p.restIsBlank(i)) {
            if (p.source[i] == ':') {
                return p.fail(i, "unexpected ':' after a value");
            }
            return p.fail(i, "unexpected text after a value");
        }
        p.line += 1;
    }

    fn resolvePlain(p: *const Parser, text: []const u8, offset: usize) Error!Value {
        const value = resolve(text) catch return p.fail(offset, "integer does not fit in 64 bits");
        return value orelse .{ .string = try p.arena.dupe(u8, text) };
    }

    /// Parses a literal (`|`) or folded (`>`) block scalar whose header is at `offset`.
    fn blockScalar(p: *Parser, offset: usize, min_indent: usize) Error!Value {
        const folded = p.source[offset] == '>';
        const header = try p.blockHeader(offset);
        const chomping = header.chomping;
        p.line += 1;
        // An indentation indicator counts from the parent node's indentation.
        const parent = min_indent -| 1;
        const indent = if (header.indent) |n|
            parent + n
        else if (p.blockIndent()) |n| @max(n, min_indent) else min_indent;

        var out: std.ArrayList(u8) = .empty;
        var empties: usize = 0; // Empty lines since the last content line.
        var seen = false; // Whether a content line has been read.
        var more_indented = false; // Whether the last content line was.
        while (p.line < p.lines.len and p.marker() == null) : (p.line += 1) {
            const line = p.lines[p.line];
            const text = p.source[line.start..line.end];
            const spaces = std.mem.findNone(u8, text, " ") orelse text.len;
            if (spaces == text.len and spaces <= indent) {
                empties += 1;
                continue;
            }
            if (spaces < indent) break;
            const content = text[indent..];
            assert(content.len > 0);
            const more = isSpace(content[0]);
            try joinLines(p.arena, &out, folded and !more and !more_indented, seen, empties);
            try out.appendSlice(p.arena, content);
            seen = true;
            empties = 0;
            more_indented = more;
        }
        switch (chomping) {
            .strip => {},
            .clip => if (seen) try out.append(p.arena, '\n'),
            .keep => @memset(try out.addManyAsSlice(p.arena, empties + @intFromBool(seen)), '\n'),
        }
        return .{ .string = out.items };
    }

    /// Reads the indicators after `|` or `>`.
    const BlockHeader = struct { chomping: Chomping, indent: ?usize };

    fn blockHeader(p: *const Parser, offset: usize) error{SyntaxError}!BlockHeader {
        var header: BlockHeader = .{ .chomping = .clip, .indent = null };
        var i = offset + 1;
        while (i < p.lineEnd()) : (i += 1) switch (p.source[i]) {
            '-', '+' => {
                if (header.chomping != .clip) return p.fail(i, "repeated chomping indicator");
                header.chomping = if (p.source[i] == '-') .strip else .keep;
            },
            '1'...'9' => {
                if (header.indent != null) return p.fail(i, "repeated indentation indicator");
                header.indent = p.source[i] - '0';
            },
            else => break,
        };
        if (!p.restIsBlank(i)) return p.fail(i, "unexpected text after a block scalar header");
        return header;
    }

    /// The indentation of the first non-empty line from the current one on, if any.
    fn blockIndent(p: *const Parser) ?usize {
        for (p.lines[p.line..]) |line| {
            if (std.mem.findNone(u8, p.source[line.start..line.end], " ")) |n| return n;
        }
        return null;
    }

    fn quoted(p: *Parser, offset: usize) Error!Scalar {
        return switch (p.source[offset]) {
            '"' => p.doubleQuoted(offset),
            '\'' => p.singleQuoted(offset),
            else => unreachable, // Callers dispatch on the opening quote.
        };
    }

    fn singleQuoted(p: *Parser, offset: usize) Error!Scalar {
        var out: std.ArrayList(u8) = .empty;
        var keep: usize = 0; // Output past this is blanks that a line fold drops.
        var i = offset + 1;
        while (i < p.source.len) {
            const c = p.source[i];
            if (c == '\'') {
                if (i + 1 == p.source.len or p.source[i + 1] != '\'') {
                    return .{ .text = out.items, .end = i + 1 };
                }
                try out.append(p.arena, '\'');
                i += 2;
            } else if (c == '\n') {
                i = try p.foldBreak(&out, keep, i);
            } else {
                try out.append(p.arena, c);
                i += 1;
                if (isBlank(c)) continue;
            }
            keep = out.items.len;
        }
        return p.fail(offset, "unterminated single-quoted string");
    }

    fn doubleQuoted(p: *Parser, offset: usize) Error!Scalar {
        var out: std.ArrayList(u8) = .empty;
        var keep: usize = 0; // Output past this is blanks that a line fold drops.
        var i = offset + 1;
        while (i < p.source.len) {
            const c = p.source[i];
            switch (c) {
                '"' => return .{ .text = out.items, .end = i + 1 },
                '\\' => i = try p.escape(&out, i),
                '\n' => i = try p.foldBreak(&out, keep, i),
                else => {
                    try out.append(p.arena, c);
                    i += 1;
                    if (isBlank(c)) continue;
                },
            }
            keep = out.items.len;
        }
        return p.fail(offset, "unterminated double-quoted string");
    }

    /// Folds the line break at `offset` inside a quoted scalar: the blanks around it are
    /// dropped, and it becomes a space, or a newline per empty line that follows it. Returns
    /// the offset of the next non-blank character.
    fn foldBreak(p: *Parser, out: *std.ArrayList(u8), keep: usize, offset: usize) Error!usize {
        assert(p.source[offset] == '\n');
        out.shrinkRetainingCapacity(keep);
        var breaks: usize = 0;
        var i = offset;
        while (i < p.source.len) : (i += 1) switch (p.source[i]) {
            '\n' => breaks += 1,
            ' ', '\t', '\r' => {},
            else => break,
        };
        if (breaks == 1) {
            try out.append(p.arena, ' ');
        } else {
            @memset(try out.addManyAsSlice(p.arena, breaks - 1), '\n');
        }
        return i;
    }

    /// Decodes the escape sequence at `offset` and returns the offset just past it.
    fn escape(p: *Parser, out: *std.ArrayList(u8), offset: usize) Error!usize {
        assert(p.source[offset] == '\\');
        if (offset + 1 == p.source.len) return p.fail(offset, "unterminated double-quoted string");
        const byte: u8 = switch (p.source[offset + 1]) {
            '0' => 0,
            'a' => 0x07,
            'b' => 0x08,
            't', '\t' => '\t',
            'n' => '\n',
            'v' => 0x0b,
            'f' => 0x0c,
            'r' => '\r',
            'e' => 0x1b,
            ' ', '"', '/', '\\' => p.source[offset + 1],
            'N' => return p.appendCodepoint(out, 0x85, offset, offset + 2),
            '_' => return p.appendCodepoint(out, 0xa0, offset, offset + 2),
            'L' => return p.appendCodepoint(out, 0x2028, offset, offset + 2),
            'P' => return p.appendCodepoint(out, 0x2029, offset, offset + 2),
            'x' => return p.unicodeEscape(out, offset, 2),
            'u' => return p.unicodeEscape(out, offset, 4),
            'U' => return p.unicodeEscape(out, offset, 8),
            '\r', '\n' => return p.escapedBreak(offset + 1),
            else => return p.fail(offset, "invalid escape sequence"),
        };
        try out.append(p.arena, byte);
        return offset + 2;
    }

    /// Skips an escaped line break at `offset` and the next line's leading blanks.
    fn escapedBreak(p: *const Parser, offset: usize) usize {
        var i = offset;
        if (p.source[i] == '\r') i += 1;
        if (i < p.source.len and p.source[i] == '\n') i += 1;
        while (i < p.source.len and isSpace(p.source[i])) i += 1;
        return i;
    }

    /// Decodes `\x`, `\u` or `\U` with `digits` hex digits; a `\u` high surrogate followed by
    /// a `\u` low surrogate decodes as one code point, as in JSON.
    fn unicodeEscape(
        p: *Parser,
        out: *std.ArrayList(u8),
        offset: usize,
        digits: usize,
    ) Error!usize {
        var code = hexValue(p.source, offset + 2, digits) orelse
            return p.fail(offset, "invalid escape sequence");
        var end = offset + 2 + digits;
        if (digits == 4 and code >= 0xd800 and code < 0xdc00 and
            std.mem.startsWith(u8, p.source[end..], "\\u"))
        {
            if (hexValue(p.source, end + 2, 4)) |low| if (low >= 0xdc00 and low < 0xe000) {
                code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                end += 6;
            };
        }
        return p.appendCodepoint(out, code, offset, end);
    }

    /// Appends `code` as UTF-8 and returns `end`.
    fn appendCodepoint(
        p: *Parser,
        out: *std.ArrayList(u8),
        code: u32,
        offset: usize,
        end: usize,
    ) Error!usize {
        if (code > 0x10ffff) return p.fail(offset, "invalid unicode escape");
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(code), &buffer) catch
            return p.fail(offset, "invalid unicode escape");
        try out.appendSlice(p.arena, buffer[0..len]);
        return end;
    }

    /// Parses the flow node at `offset`: a flow collection, quoted or plain scalar.
    fn flowValue(p: *Parser, offset: usize) Error!Flowed {
        try p.enter(offset);
        defer p.leave();
        switch (p.source[offset]) {
            '[' => return p.flowSequence(offset),
            '{' => return p.flowMapping(offset),
            '"', '\'' => {
                const scalar = try p.quoted(offset);
                return .{ .value = .{ .string = scalar.text }, .end = scalar.end };
            },
            '|', '>' => return p.fail(offset, "block scalars are not allowed in flow collections"),
            '*' => if (p.options.aliases) {
                const end = p.nameEnd(offset + 1);
                return .{ .value = try p.alias(offset, end), .end = end };
            },
            '&' => if (p.options.aliases) {
                const end = p.nameEnd(offset + 1);
                const name = p.source[offset + 1 .. end];
                const inner = try p.flowValue(try p.skipFlowSpace(end, offset));
                try p.anchors.put(p.arena, name, inner.value);
                return inner;
            },
            else => {},
        }
        if (p.isIndicator(offset, '-')) {
            return p.fail(offset, "block sequences are not allowed in flow collections");
        }
        try p.rejectIndicator(offset);
        const end = p.plainFlowEnd(offset);
        const text = std.mem.trimEnd(u8, p.source[offset..end], " \t");
        return .{ .value = try p.resolvePlain(text, offset), .end = end };
    }

    fn flowSequence(p: *Parser, open: usize) Error!Flowed {
        var array: Array = .empty;
        var i = try p.skipFlowSpace(open + 1, open);
        while (p.source[i] != ']') {
            if (p.source[i] == ',') return p.fail(i, "unexpected ','");
            const item = try p.flowValue(i);
            try array.append(p.arena, item.value);
            i = try p.skipFlowSpace(item.end, open);
            switch (p.source[i]) {
                ',' => i = try p.skipFlowSpace(i + 1, open),
                ']' => {},
                ':' => return p.fail(i, "mappings inside flow sequences are not supported"),
                else => return p.fail(i, "expected ',' or ']'"),
            }
        }
        return .{ .value = .{ .array = array }, .end = i + 1 };
    }

    fn flowMapping(p: *Parser, open: usize) Error!Flowed {
        var table: Table = .empty;
        var i = try p.skipFlowSpace(open + 1, open);
        while (p.source[i] != '}') {
            const key = try p.flowKey(i);
            if (table.contains(key.text)) return p.fail(i, "duplicate key");
            i = try p.skipFlowSpace(key.end, open);
            var value: Value = .null;
            if (p.source[i] == ':') {
                i = try p.skipFlowSpace(i + 1, open);
                if (p.source[i] != ',' and p.source[i] != '}') {
                    const item = try p.flowValue(i);
                    value = item.value;
                    i = try p.skipFlowSpace(item.end, open);
                }
            }
            try table.putNoClobber(p.arena, key.text, value);
            switch (p.source[i]) {
                ',' => i = try p.skipFlowSpace(i + 1, open),
                '}' => {},
                else => return p.fail(i, "expected ',' or '}'"),
            }
        }
        return .{ .value = .{ .table = table }, .end = i + 1 };
    }

    /// Parses a flow mapping key; keys are always strings.
    fn flowKey(p: *Parser, offset: usize) Error!Scalar {
        switch (p.source[offset]) {
            '"', '\'' => return p.quoted(offset),
            '[', '{' => return p.fail(offset, "flow collections cannot be mapping keys"),
            ',', ':' => return p.fail(offset, "expected a mapping key"),
            else => {},
        }
        try p.rejectIndicator(offset);
        const end = p.plainFlowEnd(offset);
        const text = std.mem.trimEnd(u8, p.source[offset..end], " \t");
        if (std.mem.eql(u8, text, "<<")) {
            return p.fail(offset, "merge keys ('<<') are not supported");
        }
        return .{ .text = try p.arena.dupe(u8, text), .end = end };
    }

    /// The end of the flow plain scalar at `offset`: a line break, a flow indicator, a `:`
    /// followed by a blank or flow indicator, or a ` #` comment.
    fn plainFlowEnd(p: *const Parser, offset: usize) usize {
        var i = offset;
        while (i < p.source.len) : (i += 1) switch (p.source[i]) {
            '\r', '\n', ',', '[', ']', '{', '}' => break,
            ':' => if (i + 1 == p.source.len or separated(p.source, i + 1) or
                isFlowIndicator(p.source[i + 1])) break,
            '#' => if (i > offset and isSpace(p.source[i - 1])) break,
            else => {},
        };
        return i;
    }

    /// Skips blanks, line breaks and comments inside the flow collection opened at `open`.
    fn skipFlowSpace(p: *const Parser, offset: usize, open: usize) error{SyntaxError}!usize {
        var i = offset;
        while (i < p.source.len) : (i += 1) switch (p.source[i]) {
            ' ', '\t', '\r', '\n' => {},
            '#' => {
                if (i > 0 and !separated(p.source, i - 1)) return i;
                i = std.mem.findScalarPos(u8, p.source, i, '\n') orelse break;
            },
            else => return i,
        };
        return p.fail(open, "unterminated flow collection");
    }
};

/// Appends the line breaks between two content lines of a block scalar, `empties` empty
/// lines apart. Folding turns a lone break into a space; literal style keeps every break.
fn joinLines(
    arena: Allocator,
    out: *std.ArrayList(u8),
    fold: bool,
    seen: bool,
    empties: usize,
) Allocator.Error!void {
    if (seen and fold and empties == 0) return out.append(arena, ' ');
    const breaks = empties + @intFromBool(seen and !fold);
    @memset(try out.addManyAsSlice(arena, breaks), '\n');
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// A blank inside a quoted scalar, which a line fold may drop.
fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn isFlowIndicator(c: u8) bool {
    return switch (c) {
        ',', '[', ']', '{', '}' => true,
        else => false,
    };
}

/// Whether `offset` is past the end, a blank or a line break.
fn separated(source: []const u8, offset: usize) bool {
    if (offset >= source.len) return true;
    return switch (source[offset]) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

/// The value of `digits` hex digits at `offset`, or null when there are not that many.
fn hexValue(source: []const u8, offset: usize, digits: usize) ?u32 {
    assert(digits <= 8);
    if (offset + digits > source.len) return null;
    var code: u32 = 0;
    for (source[offset..][0..digits]) |c| {
        code = code * 16 + (std.fmt.charToDigit(c, 16) catch return null);
    }
    return code;
}

/// Resolves a plain scalar with the YAML 1.2 core schema. Null means the scalar is a string;
/// `error.Overflow` means a hexadecimal or octal integer does not fit in an `i64`.
fn resolve(text: []const u8) error{Overflow}!?Value {
    if (text.len == 0 or oneOf(text, &.{ "~", "null", "Null", "NULL" })) return .null;
    if (oneOf(text, &.{ "true", "True", "TRUE" })) return .{ .bool = true };
    if (oneOf(text, &.{ "false", "False", "FALSE" })) return .{ .bool = false };
    if (std.mem.startsWith(u8, text, "0x")) return radixInt(text[2..], 16);
    if (std.mem.startsWith(u8, text, "0o")) return radixInt(text[2..], 8);
    const sign = text[0] == '-' or text[0] == '+';
    const unsigned = text[@intFromBool(sign)..];
    if (unsigned.len > 0 and digitCount(unsigned) == unsigned.len) {
        if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .int = i } else |_| {}
    }
    if (isFloat(unsigned)) {
        // `isFloat` has checked the syntax, which `parseFloat` accepts.
        return .{ .float = std.fmt.parseFloat(f64, text) catch unreachable };
    }
    if (oneOf(unsigned, &.{ ".inf", ".Inf", ".INF" })) {
        const inf = std.math.inf(f64);
        return .{ .float = if (text[0] == '-') -inf else inf };
    }
    if (oneOf(text, &.{ ".nan", ".NaN", ".NAN" })) return .{ .float = std.math.nan(f64) };
    return null;
}

fn radixInt(digits: []const u8, base: u8) error{Overflow}!?Value {
    if (digits.len == 0) return null;
    for (digits) |c| _ = std.fmt.charToDigit(c, base) catch return null;
    return .{ .int = std.fmt.parseInt(i64, digits, base) catch return error.Overflow };
}

/// Whether `text` (without a sign) matches the core schema's float:
/// `(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`.
fn isFloat(text: []const u8) bool {
    var i = digitCount(text);
    const whole = i;
    var fraction: usize = 0;
    if (i < text.len and text[i] == '.') {
        fraction = digitCount(text[i + 1 ..]);
        i += 1 + fraction;
    }
    if (whole == 0 and fraction == 0) return false;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '-' or text[i] == '+')) i += 1;
        const exponent = digitCount(text[i..]);
        if (exponent == 0) return false;
        i += exponent;
    }
    return i == text.len;
}

/// The number of leading decimal digits.
fn digitCount(text: []const u8) usize {
    return std.mem.findNone(u8, text, "0123456789") orelse text.len;
}

fn oneOf(text: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |option| {
        if (std.mem.eql(u8, text, option)) return true;
    }
    return false;
}

/// How `write` lays the YAML out.
pub const WriteOptions = struct {
    /// Spaces per nesting level; zero writes the whole value on one line in flow style.
    indent: u8 = 2,
};

/// What writing can fail with.
pub const WriteError = std.Io.Writer.Error;

/// Writes `value` as a YAML document followed by a newline. Non-empty tables and arrays use
/// block style; any other root is written as a bare scalar or flow collection. Every value
/// reads back equal, except that `nan` is never equal to itself.
pub fn write(writer: *std.Io.Writer, value: Value, options: WriteOptions) WriteError!void {
    if (options.indent == 0 or isInline(value)) {
        try writeFlow(writer, value);
        return writer.writeByte('\n');
    }
    try writeBlock(writer, value, options, 0, false);
}

/// Whether `value` is written on its parent's line: a scalar or an empty collection.
fn isInline(value: Value) bool {
    return switch (value) {
        .table => |t| t.count() == 0,
        .array => |a| a.items.len == 0,
        else => true,
    };
}

/// Writes a non-empty collection at `column`. When `continued`, its first line follows a
/// `- ` already written.
fn writeBlock(
    writer: *std.Io.Writer,
    value: Value,
    options: WriteOptions,
    column: usize,
    continued: bool,
) WriteError!void {
    assert(!isInline(value));
    switch (value) {
        .table => |t| {
            var it = t.iterator();
            var first = true;
            while (it.next()) |entry| : (first = false) {
                if (!first or !continued) try writer.splatByteAll(' ', column);
                try writeString(writer, entry.key_ptr.*);
                try writer.writeByte(':');
                try writeEntryValue(writer, entry.value_ptr.*, options, column + options.indent);
            }
        },
        .array => |a| for (a.items, 0..) |item, i| {
            if (i > 0 or !continued) try writer.splatByteAll(' ', column);
            try writer.writeAll("- ");
            if (isInline(item)) {
                try writeFlow(writer, item);
                try writer.writeByte('\n');
            } else {
                try writeBlock(writer, item, options, column + 2, true);
            }
        },
        else => unreachable, // `isInline` holds for every other value.
    }
}

/// Writes the rest of a `key:` line, and a nested collection below it at `column`.
fn writeEntryValue(
    writer: *std.Io.Writer,
    value: Value,
    options: WriteOptions,
    column: usize,
) WriteError!void {
    if (isInline(value)) {
        try writer.writeByte(' ');
        try writeFlow(writer, value);
        return writer.writeByte('\n');
    }
    try writer.writeByte('\n');
    try writeBlock(writer, value, options, column, false);
}

/// Writes `value` on one line: a scalar, or a flow collection.
/// Writes `value` on one line, as it appears after `key: `: a scalar, or a flow
/// collection.
pub fn writeValue(writer: *std.Io.Writer, value: Value) WriteError!void {
    return writeFlow(writer, value);
}

fn writeFlow(writer: *std.Io.Writer, value: Value) WriteError!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) return writer.writeAll(".nan");
            if (std.math.isInf(f)) return writer.writeAll(if (f > 0) ".inf" else "-.inf");
            try writeFloat(writer, f);
        },
        .string => |s| try writeString(writer, s),
        .array => |a| {
            try writer.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeFlow(writer, item);
            }
            try writer.writeByte(']');
        },
        .table => |t| {
            try writer.writeByte('{');
            var it = t.iterator();
            var first = true;
            while (it.next()) |entry| : (first = false) {
                if (!first) try writer.writeAll(", ");
                try writeString(writer, entry.key_ptr.*);
                try writer.writeAll(": ");
                try writeFlow(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
    }
}

/// Writes `s` as a scalar that reads back as the same string, in block or flow context:
/// plain when that is unambiguous, double-quoted with escapes otherwise.
pub fn writeString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (!needsQuotes(s)) return writer.writeAll(s);
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

/// Whether `s` written plain would read back as something else, or not parse.
fn needsQuotes(s: []const u8) bool {
    if (s.len == 0) return true;
    if (resolve(s) catch return true) |_| return true;
    if (std.mem.findScalar(u8, "-?:,[]{}#&*!|>'\"%@`", s[0]) != null) return true;
    if (isSpace(s[0]) or isSpace(s[s.len - 1])) return true;
    if (std.mem.startsWith(u8, s, "...") or std.mem.eql(u8, s, "<<")) return true;
    // A byte-order mark that starts the document is skipped by `parse`.
    if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) return true;
    for (s, 0..) |c, i| switch (c) {
        0...0x1f, 0x7f, ',', '[', ']', '{', '}' => return true,
        ':' => if (separated(s, i + 1)) return true,
        '#' => if (isSpace(s[i - 1])) return true, // `s[0]` is not '#'.
        else => {},
    };
    return false;
}

const testing = std.testing;

fn expectParseError(source: []const u8, line: u32, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), source, &diag));
    try testing.expectEqualStrings(message, diag.message);
    try testing.expectEqual(line, diag.line);
}

fn expectWrite(value: Value, options: WriteOptions, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, options);
    try testing.expectEqualStrings(expected, out.written());
}

/// Writes `value`, parses the output, and expects the same value back.
fn expectRoundTrip(arena: Allocator, value: Value, options: WriteOptions) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, options);
    const back = try parse(arena, out.written(), null);
    if (!value.eql(back)) {
        std.debug.print("round trip failed:\n{s}\n", .{out.written()});
        return error.TestExpectedEqual;
    }
}

test "block mappings nest by indentation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\  tls:
        \\    enabled: true
        \\name: termancy
        \\empty:
    , null);
    try testing.expectEqualStrings("localhost", v.lookup("server.host").?.string);
    try testing.expectEqual(8080, v.lookup("server.port").?.int);
    try testing.expectEqual(true, v.lookup("server.tls.enabled").?.bool);
    try testing.expectEqualStrings("termancy", v.lookup("name").?.string);
    try testing.expectEqual(Value.null, v.lookup("empty").?);
    try testing.expectEqualStrings("server", v.table.keys()[0]);
    try testing.expectEqualStrings("empty", v.table.keys()[2]);
}

test "block sequences and sequences of mappings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\ports:
        \\  - 80
        \\  - 443
        \\  -
        \\users:
        \\  - name: ann
        \\    admin: true
        \\  - name: bob
        \\    groups:
        \\      - dev
        \\  -
        \\    name: eve
    , null);
    try testing.expectEqual(3, v.lookup("ports").?.array.items.len);
    try testing.expectEqual(443, v.lookup("ports.1").?.int);
    try testing.expectEqual(Value.null, v.lookup("ports.2").?);
    try testing.expectEqualStrings("ann", v.lookup("users.0.name").?.string);
    try testing.expectEqual(true, v.lookup("users.0.admin").?.bool);
    try testing.expectEqualStrings("dev", v.lookup("users.1.groups.0").?.string);
    try testing.expectEqualStrings("eve", v.lookup("users.2.name").?.string);
}

test "a sequence may sit at its key's indentation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\list:
        \\- a
        \\- b
        \\next: 1
        \\items:
        \\- name: x
        \\  tags:
        \\  - t1
        \\  - t2
        \\  size: 2
    , null);
    try testing.expectEqualStrings("b", v.lookup("list.1").?.string);
    try testing.expectEqual(1, v.lookup("next").?.int);
    try testing.expectEqualStrings("t2", v.lookup("items.0.tags.1").?.string);
    try testing.expectEqual(2, v.lookup("items.0.size").?.int);
}

test "nested sequences" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\- - a
        \\  - b
        \\- - - c
        \\-
        \\  - d
    , null);
    try testing.expectEqualStrings("b", v.lookup("0.1").?.string);
    try testing.expectEqualStrings("c", v.lookup("1.0.0").?.string);
    try testing.expectEqualStrings("d", v.lookup("2.0").?.string);
}

test "plain scalars keep inner colons, hashes and spaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\url: http://example.com:8080/a#frag   # a comment
        \\words: hello   big world
        \\time: 12:30
        \\dash: -x
        \\it's: it's fine
    , null);
    try testing.expectEqualStrings("http://example.com:8080/a#frag", v.lookup("url").?.string);
    try testing.expectEqualStrings("hello   big world", v.lookup("words").?.string);
    try testing.expectEqualStrings("12:30", v.lookup("time").?.string);
    try testing.expectEqualStrings("-x", v.lookup("dash").?.string);
    try testing.expectEqualStrings("it's fine", v.table.get("it's").?.string);
}

test "core schema resolution" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\[null, Null, NULL, ~, true, True, FALSE, 0, -12, +7, 0x1F, 0o17, 1.5, -.5, 1e3,
        \\ 2.E-2, .inf, -.Inf, +.INF, .nan, yes, no, on, 0x, 0b1, 1_000, nULL, 1.2.3, ., -]
    , null);
    const items = v.array.items;
    for (items[0..4]) |item| try testing.expectEqual(Value.null, item);
    try testing.expectEqual(true, items[4].bool);
    try testing.expectEqual(true, items[5].bool);
    try testing.expectEqual(false, items[6].bool);
    const ints = [_]i64{ 0, -12, 7, 31, 15 };
    for (ints, items[7..12]) |e, item| try testing.expectEqual(e, item.int);
    const floats = [_]f64{ 1.5, -0.5, 1000, 0.02 };
    for (floats, items[12..16]) |e, item| try testing.expectEqual(e, item.float);
    try testing.expectEqual(std.math.inf(f64), items[16].float);
    try testing.expectEqual(-std.math.inf(f64), items[17].float);
    try testing.expectEqual(std.math.inf(f64), items[18].float);
    try testing.expect(std.math.isNan(items[19].float));
    for (items[20..]) |item| try testing.expect(item == .string);
    try testing.expectEqualStrings("yes", items[20].string);
}

test "integers out of range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = "a: 18446744073709551616\nb: -9223372036854775808";
    const v = try parse(arena.allocator(), source, null);
    try testing.expectEqual(18446744073709551616.0, v.lookup("a").?.float);
    try testing.expectEqual(std.math.minInt(i64), v.lookup("b").?.int);
    try expectParseError("a: 1\nb: 0x8000000000000000", 2, "integer does not fit in 64 bits");
}

test "quoted scalars are strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\a: 'it''s # not a comment'
        \\b: "true"
        \\c: ''
        \\"quoted key": 1
        \\'single: key': 2
        \\"": 3
    , null);
    try testing.expectEqualStrings("it's # not a comment", v.lookup("a").?.string);
    try testing.expectEqualStrings("true", v.lookup("b").?.string);
    try testing.expectEqualStrings("", v.lookup("c").?.string);
    try testing.expectEqual(1, v.table.get("quoted key").?.int);
    try testing.expectEqual(2, v.table.get("single: key").?.int);
    try testing.expectEqual(3, v.table.get("").?.int);
}

test "double-quoted escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\- "tab\there\nnl \"q\" \\ \/ \0"
        \\- "\x41\u00e9\U0001F600\ud83d\ude00"
        \\- "a\
        \\   b"
    , null);
    try testing.expectEqualStrings("tab\there\nnl \"q\" \\ / \x00", v.lookup("0").?.string);
    try testing.expectEqualStrings("Aé😀😀", v.lookup("1").?.string);
    try testing.expectEqualStrings("ab", v.lookup("2").?.string);
    try expectParseError("a: \"\\q\"", 1, "invalid escape sequence");
    try expectParseError("a: \"\\u12\"", 1, "invalid escape sequence");
    try expectParseError("a: \"\\ud800\"", 1, "invalid unicode escape");
}

test "quoted scalars fold across lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\a: "one
        \\   two
        \\
        \\   three"
        \\b: 'x
        \\  y'   # comment
        \\c: 1
    , null);
    try testing.expectEqualStrings("one two\nthree", v.lookup("a").?.string);
    try testing.expectEqualStrings("x y", v.lookup("b").?.string);
    try testing.expectEqual(1, v.lookup("c").?.int);
}

test "literal block scalars and chomping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\clip: |
        \\  line one
        \\    indented
        \\
        \\  # not a comment
        \\
        \\strip: |-
        \\  text
        \\
        \\keep: |+
        \\  text
        \\
        \\
        \\empty: |
        \\after: x
    , null);
    try testing.expectEqualStrings(
        "line one\n  indented\n\n# not a comment\n",
        v.lookup("clip").?.string,
    );
    try testing.expectEqualStrings("text", v.lookup("strip").?.string);
    try testing.expectEqualStrings("text\n\n\n", v.lookup("keep").?.string);
    try testing.expectEqualStrings("", v.lookup("empty").?.string);
    try testing.expectEqualStrings("x", v.lookup("after").?.string);
}

test "folded block scalars" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\a: >
        \\  one
        \\  two
        \\
        \\  three
        \\    more
        \\  four
        \\b: >-
        \\  x
        \\  y
    , null);
    try testing.expectEqualStrings("one two\nthree\n  more\nfour\n", v.lookup("a").?.string);
    try testing.expectEqualStrings("x y", v.lookup("b").?.string);
}

test "block scalars in sequences and at the root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\- |
        \\  a
        \\- k: |-
        \\    b
        \\  m: 1
    , null);
    try testing.expectEqualStrings("a\n", v.lookup("0").?.string);
    try testing.expectEqualStrings("b", v.lookup("1.k").?.string);
    try testing.expectEqual(1, v.lookup("1.m").?.int);
    const root = try parse(arena.allocator(), "--- |\nroot\ntext\n", null);
    try testing.expectEqualStrings("root\ntext\n", root.string);
    const kept = try parse(arena.allocator(), "a: >+\n\n  x\n\n", null);
    try testing.expectEqualStrings("\nx\n\n", kept.lookup("a").?.string);
}

test "block scalar headers" {
    try expectParseError("a: |-+\n  x", 1, "repeated chomping indicator");
    try expectParseError("a: |12\n  x", 1, "repeated indentation indicator");
    try expectParseError("a: |x\n  x", 1, "unexpected text after a block scalar header");
    try expectParseError("a: [1, |]", 1, "block scalars are not allowed in flow collections");
}

test "flow collections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\a: [1, two, [3, "4"], {}, [], ]
        \\b: {x: 1, "y": [a, b], z, w: , url: http://h:1/p}
        \\c: [
        \\  1,   # one
        \\  2
        \\]
        \\d: {"json":true,"n":null}
    , null);
    try testing.expectEqual(1, v.lookup("a.0").?.int);
    try testing.expectEqualStrings("two", v.lookup("a.1").?.string);
    try testing.expectEqualStrings("4", v.lookup("a.2.1").?.string);
    try testing.expectEqual(0, v.lookup("a.3").?.table.count());
    try testing.expectEqual(5, v.lookup("a").?.array.items.len);
    try testing.expectEqualStrings("b", v.lookup("b.y.1").?.string);
    try testing.expectEqual(Value.null, v.lookup("b.z").?);
    try testing.expectEqual(Value.null, v.lookup("b.w").?);
    try testing.expectEqualStrings("http://h:1/p", v.lookup("b.url").?.string);
    try testing.expectEqual(2, v.lookup("c.1").?.int);
    try testing.expectEqual(true, v.lookup("d.json").?.bool);
}

test "flow syntax errors" {
    try expectParseError("a: [1, 2", 1, "unterminated flow collection");
    try expectParseError("a: [1, 2\nb: 3", 2, "expected ',' or ']'");
    try expectParseError("a: [\"1\" 2]", 1, "expected ',' or ']'");
    try expectParseError("a: {x: \"1\" y}", 1, "expected ',' or '}'");
    try expectParseError("a: [1, , 2]", 1, "unexpected ','");
    try expectParseError("a: [x: 1]", 1, "mappings inside flow sequences are not supported");
    try expectParseError("a: {[x]: 1}", 1, "flow collections cannot be mapping keys");
    try expectParseError("a: [1] x", 1, "unexpected text after a value");
    try expectParseError("[a]: 1", 1, "unexpected ':' after a value");
}

test "comments, blank lines and document markers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\# leading comment
        \\
        \\--- # start
        \\a: 1 # trailing
        \\
        \\  # indented comment
        \\b: 2
        \\...
        \\# done
    , null);
    try testing.expectEqual(1, v.lookup("a").?.int);
    try testing.expectEqual(2, v.lookup("b").?.int);
    try testing.expectEqual(2, v.table.count());
}

test "an empty document is an empty table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "\n\n", "# only a comment\n", "---\n", "---\n...\n" }) |source| {
        const v = try parse(arena.allocator(), source, null);
        try testing.expectEqual(0, v.table.count());
    }
}

test "non-table roots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(42, (try parse(arena.allocator(), "42\n", null)).int);
    try testing.expectEqual(Value.null, try parse(arena.allocator(), "~", null));
    try testing.expectEqualStrings("hi", (try parse(arena.allocator(), "--- \"hi\"", null)).string);
    const list = try parse(arena.allocator(), "- 1\n- 2\n", null);
    try testing.expectEqual(2, list.array.items.len);
}

test "flow collections at the root, and a key indented under a scalar" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nested = try parse(a, "[[1, 2]]", null);
    try testing.expectEqual(2, nested.array.items[0].array.items[1].int);
    try testing.expectEqual(1, (try parse(a, "{a: 1}", null)).table.get("a").?.int);
    // `b: 2` would continue the plain scalar `1`, where a `: ` cannot be.
    try expectParseError("a: 1\n    b: 2", 2, "unexpected ':' in a plain scalar; quote it");
}

test "line breaks, byte-order mark and root indentation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = "\xEF\xBB\xBFa: 1\r\nb:\r\n  - x\r\nc: |\r\n  t\r\n";
    const v = try parse(arena.allocator(), source, null);
    try testing.expectEqual(1, v.lookup("a").?.int);
    try testing.expectEqualStrings("x", v.lookup("b.0").?.string);
    try testing.expectEqualStrings("t\n", v.lookup("c").?.string);
    const indented = try parse(arena.allocator(), "  a: 1\n  b: 2\n", null);
    try testing.expectEqual(2, indented.lookup("b").?.int);
}

test "anchors, aliases and tags are rejected" {
    try expectParseError("a: 1\nb: &x 2", 2, "anchors ('&') are not supported");
    try expectParseError("a: 1\nb: *x", 2, "aliases ('*') are not supported");
    try expectParseError("a: !!str 1", 1, "tags ('!') are not supported");
    try expectParseError("- &x a: 1", 1, "anchors ('&') are not supported");
    try expectParseError("a: [1, *x]", 1, "aliases ('*') are not supported");
    try expectParseError("a:\n  - !tag x", 2, "tags ('!') are not supported");
}

test "merge keys are rejected" {
    try expectParseError("a: 1\n<<: {b: 2}", 2, "merge keys ('<<') are not supported");
    try expectParseError("a: {<<: {b: 2}}", 1, "merge keys ('<<') are not supported");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "\"<<\": 1", null);
    try testing.expectEqual(1, v.table.get("<<").?.int);
}

test "complex keys are rejected" {
    try expectParseError("a: 1\n? b\n: c", 2, "complex keys ('?') are not supported");
    try expectParseError("a: {? b: c}", 1, "complex keys ('?') are not supported");
}

test "multiple documents are rejected" {
    try expectParseError("a: 1\n---\nb: 2", 2, "multiple documents are not supported");
    try expectParseError("---\na: 1\n---\n", 3, "multiple documents are not supported");
    try expectParseError("a: 1\n...\nb: 2", 3, "multiple documents are not supported");
    try expectParseError("%YAML 1.2\n---\na: 1", 1, "directives are not supported");
}

test "tabs in indentation are rejected" {
    try expectParseError("a:\n\tb: 1", 2, "tabs are not allowed in indentation");
    try expectParseError("a:\n  \tb: 1", 2, "tabs are not allowed in indentation");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "a:\tx\t# c\n\t\n", null);
    try testing.expectEqualStrings("x", v.lookup("a").?.string);
}

test "parseReader reads as parse does, a piece at a time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gpa = std.testing.allocator;
    const documents = [_][]const u8{
        "a: 1\nb:\n  c: [1,\n    2]\n  d: |\n    text\n# comment\ne: x\n",
        "---\n# A document.\nname: demo\nserver:\n  port: 1\n",
        // Cuts that land inside a value: the pieces are joined until they parse.
        "a: \"one\ntwo: 2\"\nb: [x,\n  c]\nd: 1",
        "- a\n- b\n",
        "",
        "plain\n",
        "a: 1\r\nb: 2\r\n",
    };
    for (documents) |document| {
        // A buffer smaller than the lines.
        var source: std.Io.Reader = .fixed(document);
        var small: [4]u8 = undefined;
        var limited = source.limited(.unlimited, &small);
        const streamed = try parseReader(a, gpa, &limited.interface, 1 << 20, null);
        try std.testing.expect(streamed.eql(try parse(a, document, null)));
    }
    var repeated: std.Io.Reader = .fixed("a: 1\nb: 2\na: 3\n");
    var diag: Diagnostic = .{};
    const twice = parseReader(a, gpa, &repeated, 1 << 20, &diag);
    try std.testing.expectError(error.SyntaxError, twice);
    try std.testing.expectEqual(3, diag.line);
    try std.testing.expectEqualStrings("duplicate key", diag.message);
    // An error is reported on its own line, though the pieces before it were let go.
    var broken: std.Io.Reader = .fixed("a: 1\nb: 2\nc: [\n");
    try std.testing.expectError(error.SyntaxError, parseReader(a, gpa, &broken, 1 << 20, &diag));
    var whole: Diagnostic = .{};
    _ = parse(a, "a: 1\nb: 2\nc: [\n", &whole) catch {};
    try std.testing.expectEqual(whole.line, diag.line);
    var long: std.Io.Reader = .fixed("a: 1\nb: 2\n");
    try std.testing.expectError(error.StreamTooLong, parseReader(a, gpa, &long, 5, null));
}

test "parse shares nothing with the source" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const document =
        \\plain: text here
        \\"quoted key": 'single ''q'' here'
        \\double: "esc\tape"
        \\folded: >
        \\  one
        \\  two
        \\literal: |
        \\  line
        \\list: [a, "b", {k: v}]
        \\multi: first
        \\  second
        \\
    ;
    const source = try std.testing.allocator.dupe(u8, document);
    const tree = try parse(a, source, null);
    @memset(source, 'X');
    std.testing.allocator.free(source);
    try std.testing.expect(tree.eql(try parse(a, document, null)));
}

test "duplicate keys are rejected" {
    try expectParseError("a: 1\nb: 2\na: 3", 3, "duplicate key");
    try expectParseError("a:\n  x: 1\n  'x': 2", 3, "duplicate key");
    try expectParseError("a: {x: 1, x: 2}", 1, "duplicate key");
}

test "inconsistent indentation is rejected" {
    try expectParseError("a:\n    b: 1\n  c: 2", 3, "inconsistent indentation");
    try expectParseError("a:\n  b:\n    c: 1\n   d: 2", 4, "inconsistent indentation");
    try expectParseError("- - a\n - b", 2, "inconsistent indentation");
    try expectParseError("  a: 1\nb: 2", 2, "unexpected content at this indentation");
    try expectParseError("a: 1\n- b", 2, "expected a mapping key");
    try expectParseError("a: one\n  b: two", 2, "unexpected ':' in a plain scalar; quote it");
}

test "plain scalars over several lines fold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try parse(a,
        \\a: one
        \\  two
        \\
        \\  three # a comment
        \\b: not - a
        \\    list
        \\c:
        \\  - item
        \\    continued
        \\  - next
        \\d: 1
        \\  2
    , null);
    try testing.expectEqualStrings("one two\nthree", tree.lookup("a").?.string);
    try testing.expectEqualStrings("not - a list", tree.lookup("b").?.string);
    try testing.expectEqualStrings("item continued", tree.lookup("c.0").?.string);
    try testing.expectEqualStrings("next", tree.lookup("c.1").?.string);
    // Several lines are text, even when the first alone would be a number.
    try testing.expectEqualStrings("1 2", tree.lookup("d").?.string);
}

test "explicit indentation indicators" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try parse(a, "a: |2\n     indented\n   less\nb: >-1\n  x\n  y\n", null);
    try testing.expectEqualStrings("   indented\n less\n", tree.lookup("a").?.string);
    try testing.expectEqualStrings(" x\n y", tree.lookup("b").?.string);
}

test "anchors and aliases, when enabled, within a budget" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\base: &defaults
        \\  port: 80
        \\  tags: [a, b]
        \\prod: *defaults
        \\name: &n app
        \\list: [*n, &x {k: v}, *x]
    ;
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(a, source, &diag));
    try testing.expectEqualStrings("anchors ('&') are not supported", diag.message);
    const tree = try parseWith(a, source, null, .{ .aliases = true });
    try testing.expectEqual(80, tree.lookup("prod.port").?.int);
    try testing.expectEqualStrings("b", tree.lookup("prod.tags.1").?.string);
    try testing.expectEqualStrings("app", tree.lookup("list.0").?.string);
    try testing.expectEqualStrings("v", tree.lookup("list.2.k").?.string);

    const unknown = parseWith(a, "a: *nope", &diag, .{ .aliases = true });
    try testing.expectError(error.SyntaxError, unknown);
    try testing.expectEqualStrings("alias to an unknown anchor", diag.message);
    const laughs =
        \\a: &a [x, x, x, x, x, x, x, x, x, x]
        \\b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]
        \\c: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]
        \\d: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]
        \\e: [*d, *d, *d, *d, *d, *d, *d, *d, *d, *d]
    ;
    try testing.expectError(error.SyntaxError, parseWith(a, laughs, &diag, .{ .aliases = true }));
    try testing.expectEqualStrings("aliases copy too many nodes", diag.message);
}

test "values that must start on their own line" {
    try expectParseError("a: b: c", 1, "unexpected ':' after a value");
    try expectParseError("a: - b", 1, "a block sequence cannot start on the line of its key");
    try expectParseError("a: 'x' y", 1, "unexpected text after a value");
    try expectParseError("a: @x", 1, "reserved indicator ('%', '@' or '`')");
    try expectParseError(": x", 1, "empty keys are not supported");
}

test "unterminated quoted scalars" {
    try expectParseError("a: 1\nb: \"x\n\ny", 2, "unterminated double-quoted string");
    try expectParseError("a: 'x", 1, "unterminated single-quoted string");
}

test "nesting is bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var flow: [2 * (max_depth + 2)]u8 = undefined;
    @memset(flow[0 .. max_depth + 2], '[');
    @memset(flow[max_depth + 2 ..], ']');
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), &flow, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);

    var block: [2 * (max_depth + 2) + 1]u8 = undefined;
    for (0..max_depth + 2) |i| block[2 * i ..][0..2].* = "- ".*;
    block[block.len - 1] = 'x';
    diag = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), &block, &diag));
    try testing.expectEqualStrings("nesting is too deep", diag.message);
}

test "write a representative document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\{name: termancy, version: 1.0, debug: false, port: 8080, none: null,
        \\ server: {host: "0.0.0.0", tags: [a, "b c"]},
        \\ users: [{name: ann, roles: [admin]}, {name: bob}],
        \\ matrix: [[1, 2], [3]], empty_t: {}, empty_a: [], msg: "line\nbreak"}
    , null);
    try expectWrite(v, .{},
        \\name: termancy
        \\version: 1.0
        \\debug: false
        \\port: 8080
        \\none: null
        \\server:
        \\  host: 0.0.0.0
        \\  tags:
        \\    - a
        \\    - b c
        \\users:
        \\  - name: ann
        \\    roles:
        \\      - admin
        \\  - name: bob
        \\matrix:
        \\  - - 1
        \\    - 2
        \\  - - 3
        \\empty_t: {}
        \\empty_a: []
        \\msg: "line\nbreak"
        \\
    );
    try expectWrite(v.lookup("users").?, .{ .indent = 4 },
        \\- name: ann
        \\  roles:
        \\      - admin
        \\- name: bob
        \\
    );
    try expectRoundTrip(arena.allocator(), v, .{});
    try expectRoundTrip(arena.allocator(), v, .{ .indent = 4 });
}

test "write flow style and scalar roots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "a: [1, {b: x}]\nc: 'y, z'", null);
    try expectWrite(v, .{ .indent = 0 }, "{a: [1, {b: x}], c: \"y, z\"}\n");
    try expectRoundTrip(arena.allocator(), v, .{ .indent = 0 });
    try expectWrite(.{ .int = -3 }, .{}, "-3\n");
    try expectWrite(.null, .{}, "null\n");
    try expectWrite(.empty_table, .{}, "{}\n");
    try expectWrite(.{ .string = "true" }, .{}, "\"true\"\n");
}

test "write special floats" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v: Value = .{ .array = .empty };
    const floats = [_]f64{ 1, -2.5, 1e300, 1e-7, -0.0, std.math.inf(f64), -std.math.inf(f64) };
    for (floats) |f| try v.array.append(a, .{ .float = f });
    try expectRoundTrip(a, v, .{});
    var special: Value = .{ .array = .empty };
    for ([_]f64{ floats[5], floats[6], std.math.nan(f64) }) |f| {
        try special.array.append(a, .{ .float = f });
    }
    try expectWrite(special, .{}, "- .inf\n- -.inf\n- .nan\n");
}

test "strings are quoted only when they must be" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tricky = [_][]const u8{
        "true",    "1",    "",    "a: b",   "- x",    "#c",      " lead",
        "trail ",  "null", "~",   "0x10",   "1e3",    ".nan",    "a #b",
        "x:",      "[a]",  "{a}", "a,b",    "*ref",   "&anc",    "!tag",
        "| bar",   "> f",  "'q'", "\"dq\"", "%p",     "@at",     "`b`",
        "...",     "---",  "<<",  "tab\t",  "nl\nnl", "\x01",    "\x7f",
        "-",       "?",    ":",   "a:b",    "plain",  "it's",    "\u{e9} \u{fc}",
        "C:\\dir", "a\\b", "x y", "a'b",    "1.2.3",  "0.0.0.0", "0xFFFFFFFFFFFFFFFFF",
    };
    var table: Value = .empty_table;
    var list: Value = .{ .array = .empty };
    for (tricky) |s| {
        try table.table.put(a, s, .{ .string = s });
        try list.array.append(a, .{ .string = s });
    }
    try expectRoundTrip(a, table, .{});
    try expectRoundTrip(a, table, .{ .indent = 0 });
    try expectRoundTrip(a, list, .{});
    try expectRoundTrip(a, list, .{ .indent = 0 });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for ([_][]const u8{ "plain", "a:b", "it's", "C:\\dir", "\x01" }) |s| {
        try writeString(&out.writer, s);
        try out.writer.writeByte(' ');
    }
    try testing.expectEqualStrings("plain a:b it's C:\\dir \"\\x01\" ", out.written());
}

test "parse what write wrote for nested structures" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v: Value = .empty_table;
    try v.put(a, "a.b.c", .{ .int = 1 });
    try v.put(a, "a.list", .{ .array = .empty });
    try v.put(a, "a.list.0", .empty_table);
    try v.put(a, "a.list.0.x", .{ .array = .empty });
    try v.put(a, "a.list.0.x.0", .{ .string = "deep" });
    try v.put(a, "a.list.1", .{ .array = .empty });
    try v.put(a, "a.list.1.0", .{ .array = .empty });
    try v.put(a, "a.list.1.0.0", .{ .bool = true });
    try v.put(a, "a.list.2", .{ .string = "multi\nline\n" });
    try expectRoundTrip(a, v, .{});
    try expectRoundTrip(a, v, .{ .indent = 1 });
    try expectRoundTrip(a, v, .{ .indent = 0 });
}

test "a leading byte-order mark in a string is kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bom = "\u{feff}x";
    var table: Value = .empty_table;
    try table.table.put(a, bom, .{ .int = 1 });
    try expectRoundTrip(a, table, .{});
    try expectRoundTrip(a, .{ .string = bom }, .{});
}

test "quoted scalars fold CRLF line breaks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "a: 'x\r\n  y'\r\nb: \"p\r\n\r\n  q\"\r\n", null);
    try testing.expectEqualStrings("x y", v.lookup("a").?.string);
    try testing.expectEqualStrings("p\nq", v.lookup("b").?.string);
}
