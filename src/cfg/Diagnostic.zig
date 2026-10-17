//! Where and why a parse failed. Codecs fill one in when they return `error.SyntaxError`.
//!
//! Decoding fills one in too, naming the key path instead of a position;
//! `Config.decode` then adds the file and position that set the key, where it knows them.
//!
//! `message` is a string literal, or for ZON the compiler's text in the arena given to
//! `parse`; `key` is borrowed from the arena of the tree being decoded. So a `Diagnostic`
//! owns no memory and needs no `deinit`, but must not outlive those arenas.

const std = @import("std");
const assert = std.debug.assert;

const Diagnostic = @This();

/// One-based line; zero when no position applies.
line: u32 = 0,
/// One-based column, in bytes.
column: u32 = 0,
message: []const u8 = "",
/// The dotted key path a decode error is about; empty for parse errors.
key: []const u8 = "",
/// The file the position is in, when known.
file: []const u8 = "",

/// Records `message` at byte `offset` of `source`, when `diag` is non-null.
pub fn report(diag: ?*Diagnostic, source: []const u8, offset: usize, message: []const u8) void {
    const d = diag orelse return;
    assert(message.len > 0);
    const end = @min(offset, source.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..end], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    d.* = .{
        .line = line,
        .column = @intCast(end - line_start + 1),
        .message = message,
    };
}

/// Writes `file:line:column: key: message`, leaving out what is not known.
pub fn format(d: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (d.file.len > 0) try writer.print("{s}:", .{d.file});
    if (d.line > 0) {
        try writer.print("{d}:{d}:", .{ d.line, d.column });
    }
    if (d.file.len > 0 or d.line > 0) try writer.writeByte(' ');
    if (d.key.len > 0) try writer.print("{s}: ", .{d.key});
    try writer.writeAll(d.message);
}

/// Writes the line of `source` the diagnostic points at, numbered, with a caret under its
/// column, as compilers do:
///
/// ```
///   3 | port = 70000
///     |        ^
/// ```
///
/// Writes nothing without a position, or when `source` has no such line. The caret lines
/// up under tabs and characters of one column; wide characters before it shift it left.
pub fn writeSnippet(
    d: Diagnostic,
    writer: *std.Io.Writer,
    source: []const u8,
) std.Io.Writer.Error!void {
    if (d.line == 0) return;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 1;
    const text = while (lines.next()) |line| : (number += 1) {
        if (number == d.line) break std.mem.trimEnd(u8, line, "\r");
    } else return;
    var digits: [10]u8 = undefined;
    const label = std.fmt.bufPrint(&digits, "{d}", .{d.line}) catch unreachable;
    try writer.print("  {s} | {s}\n  ", .{ label, text });
    try writer.splatByteAll(' ', label.len);
    try writer.writeAll(" | ");
    const before = @min(d.column -| 1, text.len);
    for (text[0..before]) |c| {
        if (c & 0xc0 == 0x80) continue; // a UTF-8 continuation byte: one column per character
        try writer.writeByte(if (c == '\t') '\t' else ' ');
    }
    try writer.writeAll("^\n");
}

test report {
    var diag: Diagnostic = .{};
    report(&diag, "a = 1\nb = ?\n", 10, "unexpected character");
    try std.testing.expectEqual(2, diag.line);
    try std.testing.expectEqual(5, diag.column);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{diag});
    try std.testing.expectEqualStrings("2:5: unexpected character", writer.buffered());
}

test format {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const all: Diagnostic = .{
        .file = "app.toml",
        .line = 3,
        .column = 8,
        .key = "port",
        .message = "too big",
    };
    try writer.print("{f}|", .{all});
    try writer.print("{f}|", .{Diagnostic{ .key = "port", .message = "too big" }});
    try writer.print("{f}|", .{Diagnostic{ .message = "too big" }});
    try writer.print("{f}", .{Diagnostic{ .file = "a.env", .message = "unreadable" }});
    try std.testing.expectEqualStrings(
        "app.toml:3:8: port: too big|port: too big|too big|a.env: unreadable",
        writer.buffered(),
    );
}

test writeSnippet {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const d: Diagnostic = .{ .line = 2, .column = 8, .message = "x" };
    try d.writeSnippet(&writer, "a = 1\nport = 70000\r\n");
    try std.testing.expectEqualStrings("  2 | port = 70000\n    |        ^\n", writer.buffered());
    writer.end = 0;
    try (Diagnostic{ .line = 9, .column = 1 }).writeSnippet(&writer, "a\n");
    try (Diagnostic{ .key = "k" }).writeSnippet(&writer, "a\n");
    try std.testing.expectEqualStrings("", writer.buffered());
}

test "report ignores a null diagnostic" {
    report(null, "", 0, "nothing");
}
