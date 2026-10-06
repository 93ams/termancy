//! A bounded YAML subset for configuration files.
//!
//! ## Why a subset, and what makes that acceptable
//!
//! `[measured]` there was no YAML support at all: the only two occurrences of the
//! string in the tree were **tests asserting that YAML is rejected**. A full YAML
//! parser is anchors, aliases, tags, merge keys, block scalars, flow collections,
//! multi-document streams and a type-resolution table - an enormous surface, and a
//! large one to get subtly wrong.
//!
//! So this covers what a configuration file actually uses, and **fails loudly on
//! everything else**. That is the property worth insisting on: a parser that
//! silently mis-reads `&anchor` as the string `"&anchor"` is worse than one that
//! refuses, because the first produces a program that starts with the wrong
//! settings and the second produces an error message.
//!
//! ## Supported
//!
//!   * block mappings and nested mappings, by indentation;
//!   * block sequences (`- item`), including a mapping as an item;
//!   * plain, single-quoted and double-quoted scalars;
//!   * flow sequences of scalars (`[a, b, c]`);
//!   * `#` comments, blank lines, and a single leading `---`.
//!
//! ## Refused, with `error.UnsupportedFeature`
//!
//! Anchors and aliases (`&`, `*`), tags (`!!str`), block scalars (`|`, `>`, and
//! their `-`/`+` chomping forms), merge keys (`<<`), complex keys (`? `), and a
//! second document (`---` after content). Each names itself in the error rather
//! than being quietly treated as text.
//!
//! ## Tabs
//!
//! A tab used for indentation is an error, because YAML forbids it and because the
//! two obvious wrong answers - treat it as one space, or as eight - differ from
//! each other and from what the user's editor showed them.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    /// A construct this subset does not implement. Deliberately distinct from
    /// `Malformed` so a caller can tell "I do not support this file" from "this
    /// file is broken".
    UnsupportedFeature,
    /// Structurally invalid: bad indentation, a line with no place to go, an
    /// unterminated quote, a duplicate key.
    Malformed,
    OutOfMemory,
};

pub const Entry = struct { key: []const u8, value: Value };

/// A parsed node. Scalars keep their **raw text**; typing happens in `decode`,
/// which is what lets one representation serve JSON, TOML and YAML.
pub const Value = union(enum) {
    scalar: []const u8,
    sequence: []const Value,
    mapping: []const Entry,
};

/// A parsed document. Owns every byte reachable from `root`.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Looks up a dotted path, e.g. `tls.enabled`. Indices are not addressable:
    /// nothing in this tree has needed to reach into a sequence by number.
    pub fn get(self: *const Document, path: []const u8) ?Value {
        assert(path.len > 0);
        var current = self.root;
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |part| {
            const entries = switch (current) {
                .mapping => |e| e,
                else => return null,
            };
            var found: ?Value = null;
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, part)) {
                    found = entry.value;
                    break;
                }
            }
            current = found orelse return null;
        }
        return current;
    }

    /// The scalar at `path`, or null if it is absent or not a scalar.
    pub fn scalar(self: *const Document, path: []const u8) ?[]const u8 {
        const value = self.get(path) orelse return null;
        return switch (value) {
            .scalar => |s| s,
            else => null,
        };
    }
};

/// One logical line, normalised so the block parser never has to look at a dash.
const Line = struct {
    indent: usize,
    text: []const u8,
};

/// Parses `text`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Document {
    var document = Document{ .arena = std.heap.ArenaAllocator.init(allocator), .root = undefined };
    errdefer document.arena.deinit();
    const scratch = document.arena.allocator();

    var parser = Parser{ .scratch = scratch, .lines = .empty };
    try parser.normalise(text);
    if (parser.lines.items.len == 0) return error.Malformed;

    document.root = try parser.parseBlockAt(parser.lines.items[0].indent);

    // Anything left over is a line with no place to go, which is how a
    // misalignment is caught instead of being silently dropped.
    if (parser.index != parser.lines.items.len) return error.Malformed;
    return document;
}

const Parser = struct {
    scratch: std.mem.Allocator,
    lines: std.ArrayListUnmanaged(Line),
    index: usize = 0,

    /// Splits into logical lines and rewrites every sequence item as a bare `-`
    /// followed by its content at `indent + 2`.
    ///
    /// That rewrite is the whole trick. `- name: a` with `port: 1` beneath it is a
    /// sequence whose single item is a *mapping*, and handling that inline means
    /// special-casing it in the sequence loop, in the mapping loop and in the
    /// scalar path. Normalised, the item becomes a nested block like any other, and
    /// `parseBlockAt` needs no special case at all.
    fn normalise(self: *Parser, text: []const u8) Error!void {
        var raw = std.mem.splitScalar(u8, text, '\n');
        var seen_content = false;
        var seen_document_marker = false;

        while (raw.next()) |raw_line| {
            const without_cr = std.mem.trimEnd(u8, raw_line, "\r");
            const stripped = stripComment(without_cr) orelse continue;

            const indent = countIndent(stripped) orelse return error.UnsupportedFeature;
            const content = stripped[indent..];
            if (content.len == 0) continue;

            if (std.mem.eql(u8, content, "---")) {
                // One leading marker is fine; a second one means a second document.
                if (!seen_content and !seen_document_marker) {
                    seen_document_marker = true;
                    continue;
                }
                return error.UnsupportedFeature;
            }
            seen_content = true;

            if (std.mem.startsWith(u8, content, "<<:")) return error.UnsupportedFeature;
            if (content[0] == '?') return error.UnsupportedFeature;
            // A line that opens a flow collection as a whole is a flow mapping or a
            // flow sequence in value position. Neither is supported, and letting it
            // through would have `{a: 1}` parsed as the key `{a`.
            if (content[0] == '{') return error.UnsupportedFeature;

            if (content[0] == '-' and (content.len == 1 or content[1] == ' ')) {
                // One `-` per nesting level. `- - 1` is a sequence whose first item
                // is a sequence, so the inner dash has to be rewritten too - leaving
                // `- 1` as a content line would make the inner block start with a
                // dash the parser no longer recognises.
                var level_indent = indent;
                var rest = content;
                while (rest.len > 0 and rest[0] == '-' and (rest.len == 1 or rest[1] == ' ')) {
                    try self.lines.append(self.scratch, .{ .indent = level_indent, .text = "-" });
                    level_indent += 2;
                    rest = std.mem.trimStart(u8, rest[1..], " ");
                }
                if (rest.len > 0) {
                    try self.lines.append(self.scratch, .{ .indent = level_indent, .text = rest });
                }
                continue;
            }

            try self.lines.append(self.scratch, .{ .indent = indent, .text = content });
        }
    }

    /// Parses the block beginning at `self.index`, which must be indented exactly
    /// `indent`.
    fn parseBlockAt(self: *Parser, indent: usize) Error!Value {
        if (self.index >= self.lines.items.len) return .{ .scalar = "" };
        const first = self.lines.items[self.index];

        if (first.text[0] == '-' and std.mem.eql(u8, first.text, "-")) {
            return self.parseSequence(indent);
        }
        if (splitKey(first.text)) |_| return self.parseMapping(indent);
        return self.parseScalarLine(indent);
    }

    fn parseSequence(self: *Parser, indent: usize) Error!Value {
        assert(indent <= std.math.maxInt(u16));

        var items = std.ArrayListUnmanaged(Value).empty;

        while (self.index < self.lines.items.len) {
            const line = self.lines.items[self.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.Malformed;
            if (!std.mem.eql(u8, line.text, "-")) break;

            self.index += 1;
            if (self.index < self.lines.items.len) {
                const next = self.lines.items[self.index];
                if (next.indent > indent) {
                    try items.append(self.scratch, try self.parseBlockAt(next.indent));
                    continue;
                }
            }
            // A dash with nothing indented under it is an explicit null item.
            try items.append(self.scratch, .{ .scalar = "" });
        }

        return .{ .sequence = try items.toOwnedSlice(self.scratch) };
    }

    fn parseMapping(self: *Parser, indent: usize) Error!Value {
        var entries = std.ArrayListUnmanaged(Entry).empty;

        while (self.index < self.lines.items.len) {
            const line = self.lines.items[self.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.Malformed;
            if (std.mem.eql(u8, line.text, "-")) break;

            const split = splitKey(line.text) orelse break;
            self.index += 1;

            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.key, split.key)) return error.Malformed;
            }

            const value: Value = if (split.rest.len > 0)
                try self.parseInlineValue(split.rest)
            else if (self.index < self.lines.items.len and
                self.lines.items[self.index].indent > indent)
                try self.parseBlockAt(self.lines.items[self.index].indent)
            else
                .{ .scalar = "" };

            try entries.append(self.scratch, .{ .key = split.key, .value = value });
        }

        return .{ .mapping = try entries.toOwnedSlice(self.scratch) };
    }

    /// A line that is a bare value: a scalar, or a nested block introduced by a
    /// `-` that `parseBlockAt` has already routed elsewhere.
    fn parseScalarLine(self: *Parser, indent: usize) Error!Value {
        const line = self.lines.items[self.index];
        if (line.indent != indent) return error.Malformed;
        self.index += 1;

        const value = try self.parseInlineValue(line.text);

        // A scalar cannot have children.
        if (self.index < self.lines.items.len and
            self.lines.items[self.index].indent > indent) return error.Malformed;
        return value;
    }

    fn parseInlineValue(self: *Parser, text: []const u8) Error!Value {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return .{ .scalar = "" };

        if (trimmed[0] == '[') return self.parseFlowSequence(trimmed);
        return .{ .scalar = try self.parseScalar(trimmed) };
    }

    fn parseFlowSequence(self: *Parser, text: []const u8) Error!Value {
        assert(text[0] == '[');

        const close = findFlowEnd(text) orelse return error.Malformed;
        const body = text[1..close];

        var items = std.ArrayListUnmanaged(Value).empty;
        var parts = std.mem.splitScalar(u8, body, ',');
        while (parts.next()) |part| {
            const element = std.mem.trim(u8, part, " ");
            if (element.len == 0) continue;
            // Nested flow collections are not supported; saying so beats guessing.
            if (element[0] == '[' or element[0] == '{') return error.UnsupportedFeature;
            try items.append(self.scratch, .{ .scalar = try self.parseScalar(element) });
        }
        return .{ .sequence = try items.toOwnedSlice(self.scratch) };
    }

    /// Strips quotes and rejects every construct this subset does not implement.
    fn parseScalar(self: *Parser, text: []const u8) Error![]const u8 {
        assert(text.len > 0);

        switch (text[0]) {
            '\'' => {
                const close = std.mem.indexOfScalar(u8, text[1..], '\'') orelse
                    return error.Malformed;
                return text[1 .. 1 + close];
            },
            '"' => return self.parseDoubleQuoted(text),
            '&', '*' => return error.UnsupportedFeature,
            '!', '%', '@', '`' => return error.UnsupportedFeature,
            '|', '>' => return error.UnsupportedFeature,
            '?' => return error.UnsupportedFeature,
            '{' => return error.UnsupportedFeature,
            else => {},
        }

        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return error.Malformed;
        // A bare value that ends in `:` looks like a key with no value, which means
        // the line was mis-split rather than being a scalar.
        if (trimmed[trimmed.len - 1] == ':') return error.Malformed;
        return trimmed;
    }

    fn parseDoubleQuoted(self: *Parser, text: []const u8) Error![]const u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 1;

        while (i < text.len) {
            const byte = text[i];
            if (byte == '\\' and i + 1 < text.len) {
                const escaped = text[i + 1];
                switch (escaped) {
                    'n' => try out.append(self.scratch, '\n'),
                    't' => try out.append(self.scratch, '\t'),
                    'r' => try out.append(self.scratch, '\r'),
                    '0' => try out.append(self.scratch, 0),
                    '"' => try out.append(self.scratch, '"'),
                    '\\' => try out.append(self.scratch, '\\'),
                    else => return error.UnsupportedFeature,
                }
                i += 2;
                continue;
            }
            if (byte == '"') return out.toOwnedSlice(self.scratch);
            try out.append(self.scratch, byte);
            i += 1;
        }
        return error.Malformed;
    }
};

/// Splits `key: value` at the first `:` that is followed by a space or ends the
/// line, returning a quoted-and-unquoted key.
fn splitKey(text: []const u8) ?struct { key: []const u8, rest: []const u8 } {
    if (text.len == 0) return null;
    // A leading dash is a sequence item, not a key.
    if (text[0] == '-') return null;

    var i: usize = 0;
    var quote: ?u8 = null;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (quote) |q| {
            if (byte == q) quote = null;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte != ':') continue;
        // `a:b` is a scalar; `a: b` and `a:` are keys.
        if (i + 1 < text.len and text[i + 1] != ' ') continue;

        const raw_key = std.mem.trim(u8, text[0..i], " ");
        if (raw_key.len == 0) return null;
        if (raw_key[0] == '\'' or raw_key[0] == '"') {
            if (raw_key.len < 2) return null;
            if (raw_key[raw_key.len - 1] != raw_key[0]) return null;
            return .{
                .key = raw_key[1 .. raw_key.len - 1],
                .rest = std.mem.trim(u8, text[i + 1 ..], " "),
            };
        }
        return .{ .key = raw_key, .rest = std.mem.trim(u8, text[i + 1 ..], " ") };
    }
    return null;
}

/// Removes a trailing `#` comment, leaving `#` inside quotes alone. Returns null
/// when the line is blank or entirely a comment.
fn stripComment(line: []const u8) ?[]const u8 {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const byte = line[i];
        if (quote) |q| {
            if (byte == q) quote = null;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '#') {
            // `#` only starts a comment after whitespace or at the start; `a#b` is
            // a plain scalar containing a hash, which is common in passwords.
            if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') {
                const trimmed = std.mem.trimEnd(u8, line[0..i], " ");
                return if (trimmed.len == 0) null else trimmed;
            }
        }
    }
    const trimmed = std.mem.trimEnd(u8, line, " ");
    return if (trimmed.len == 0) null else trimmed;
}

/// Counts leading spaces, or null when a tab was used for indentation.
fn countIndent(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ' ') continue;
        if (line[i] == '\t') return null;
        break;
    }
    return i;
}

/// The index of the `]` that closes a flow sequence opened at `text[0]`.
fn findFlowEnd(text: []const u8) ?usize {
    var quote: ?u8 = null;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (quote) |q| {
            if (byte == q) quote = null;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == ']') return i;
    }
    return null;
}

const testing = std.testing;

test "a flat mapping parses into key and value" {
    var doc = try parse(testing.allocator,
        \\host: localhost
        \\port: 8080
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("localhost", doc.scalar("host").?);
    try testing.expectEqualStrings("8080", doc.scalar("port").?);
    try testing.expectEqual(@as(?[]const u8, null), doc.scalar("absent"));
}

test "comments and blank lines are ignored, and a hash inside a value is not one" {
    var doc = try parse(testing.allocator,
        \\# leading comment
        \\
        \\host: localhost   # trailing comment
        \\password: a#b
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("localhost", doc.scalar("host").?);
    // `a#b` is a scalar containing a hash, which is what a password looks like.
    try testing.expectEqualStrings("a#b", doc.scalar("password").?);
}

test "a hash inside quotes is not a comment either" {
    var doc = try parse(testing.allocator, "greeting: \"hello # world\"\n");
    defer doc.deinit();
    try testing.expectEqualStrings("hello # world", doc.scalar("greeting").?);
}

test "nesting is by indentation" {
    var doc = try parse(testing.allocator,
        \\server:
        \\  host: localhost
        \\  tls:
        \\    enabled: true
        \\    cert: /etc/cert.pem
        \\name: outer
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("localhost", doc.scalar("server.host").?);
    try testing.expectEqualStrings("true", doc.scalar("server.tls.enabled").?);
    try testing.expectEqualStrings("/etc/cert.pem", doc.scalar("server.tls.cert").?);
    // A key at the outer indent belongs to the outer mapping, not the inner one.
    try testing.expectEqualStrings("outer", doc.scalar("name").?);
}

test "a sequence of scalars parses in order" {
    var doc = try parse(testing.allocator,
        \\hosts:
        \\  - alpha
        \\  - beta
        \\  - gamma
        \\
    );
    defer doc.deinit();

    const value = doc.get("hosts").?;
    try testing.expectEqual(@as(usize, 3), value.sequence.len);
    try testing.expectEqualStrings("alpha", value.sequence[0].scalar);
    try testing.expectEqualStrings("gamma", value.sequence[2].scalar);
}

test "a sequence of mappings is the case the normalisation exists for" {
    // `- name: a` with a continuation line is a sequence whose item is a mapping.
    // Handling that inline would need a special case in three places.
    var doc = try parse(testing.allocator,
        \\servers:
        \\  - name: alpha
        \\    port: 1
        \\  - name: beta
        \\    port: 2
        \\
    );
    defer doc.deinit();

    const servers = doc.get("servers").?;
    try testing.expectEqual(@as(usize, 2), servers.sequence.len);

    const first = servers.sequence[0].mapping;
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqualStrings("name", first[0].key);
    try testing.expectEqualStrings("alpha", first[0].value.scalar);
    try testing.expectEqualStrings("port", first[1].key);
    try testing.expectEqualStrings("1", first[1].value.scalar);
}

test "a nested sequence of sequences" {
    var doc = try parse(testing.allocator,
        \\matrix:
        \\  - - 1
        \\    - 2
        \\  - - 3
        \\
    );
    defer doc.deinit();

    const matrix = doc.get("matrix").?;
    try testing.expectEqual(@as(usize, 2), matrix.sequence.len);
    try testing.expectEqual(@as(usize, 2), matrix.sequence[0].sequence.len);
    try testing.expectEqualStrings("1", matrix.sequence[0].sequence[0].scalar);
    try testing.expectEqualStrings("3", matrix.sequence[1].sequence[0].scalar);
}

test "quoting is honoured, and single quotes are literal" {
    var doc = try parse(testing.allocator,
        \\plain: value
        \\single: 'has: a colon and "quotes"'
        \\double: "line\nbreak"
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("value", doc.scalar("plain").?);
    try testing.expectEqualStrings("has: a colon and \"quotes\"", doc.scalar("single").?);
    // The escape is decoded, so the value really does contain a newline.
    try testing.expectEqualStrings("line\nbreak", doc.scalar("double").?);
}

test "a quoted key is unwrapped" {
    var doc = try parse(testing.allocator, "\"odd: key\": value\n");
    defer doc.deinit();
    try testing.expectEqualStrings("value", doc.scalar("odd: key").?);
}

test "a flow sequence of scalars parses" {
    var doc = try parse(testing.allocator, "hosts: [alpha, beta, gamma]\n");
    defer doc.deinit();

    const hosts = doc.get("hosts").?;
    try testing.expectEqual(@as(usize, 3), hosts.sequence.len);
    try testing.expectEqualStrings("beta", hosts.sequence[1].scalar);
}

test "a colon without a space is a scalar, not a key" {
    // `http://example.com` and `12:30` are values, and splitting them at the colon
    // is the classic way a hand-rolled YAML reader corrupts a URL.
    var doc = try parse(testing.allocator,
        \\url: http://example.com/path
        \\time: 12:30
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("http://example.com/path", doc.scalar("url").?);
    try testing.expectEqualStrings("12:30", doc.scalar("time").?);
}

test "a leading document marker is accepted, a second one is refused" {
    var doc = try parse(testing.allocator,
        \\---
        \\host: localhost
        \\
    );
    defer doc.deinit();
    try testing.expectEqualStrings("localhost", doc.scalar("host").?);

    try testing.expectError(error.UnsupportedFeature, parse(testing.allocator,
        \\host: a
        \\---
        \\host: b
        \\
    ));
}

test "every unsupported construct is refused rather than read as text" {
    // The property that matters: a program that starts with the wrong settings is
    // worse than an error message.
    const refused = [_][]const u8{
        "base: &anchor value\n",
        "copy: *anchor\n",
        "typed: !!str 5\n",
        "block: |\n  text\n",
        "folded: >\n  text\n",
        "merged:\n  <<: other\n",
        "hosts: [[1, 2]]\n",
        "{a: 1}\n",
    };
    for (refused) |text| {
        try testing.expectError(error.UnsupportedFeature, parse(testing.allocator, text));
    }
}

test "a tab used for indentation is refused" {
    // YAML forbids it, and the two plausible readings - one space, or eight -
    // differ from each other and from what the editor showed.
    try testing.expectError(error.UnsupportedFeature, parse(
        testing.allocator,
        "server:\n\thost: localhost\n",
    ));
}

test "structural problems are Malformed, not UnsupportedFeature" {
    // The two are different answers to different questions: "I do not implement
    // this" versus "this file is broken".
    try testing.expectError(error.Malformed, parse(testing.allocator, "key: \"unterminated\n"));
    try testing.expectError(error.Malformed, parse(testing.allocator, "key: [unterminated\n"));
    try testing.expectError(error.Malformed, parse(testing.allocator, "a: 1\na: 2\n"));
    // A line indented deeper than anything that could own it has nowhere to go.
    try testing.expectError(error.Malformed, parse(testing.allocator, "a: 1\n    b: 2\n"));
}

test "an empty document is refused rather than reported as an empty mapping" {
    try testing.expectError(error.Malformed, parse(testing.allocator, ""));
    try testing.expectError(error.Malformed, parse(testing.allocator, "\n\n# just a comment\n"));
}

test "a dash with nothing under it is an explicit null item" {
    var doc = try parse(testing.allocator,
        \\items:
        \\  - one
        \\  -
        \\  - three
        \\
    );
    defer doc.deinit();

    const items = doc.get("items").?;
    try testing.expectEqual(@as(usize, 3), items.sequence.len);
    try testing.expectEqualStrings("", items.sequence[1].scalar);
}

test "a key with no value is an empty scalar, so a caller can tell it is unset" {
    var doc = try parse(testing.allocator,
        \\empty:
        \\next: value
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("", doc.scalar("empty").?);
    try testing.expectEqualStrings("value", doc.scalar("next").?);
}

test "the document owns every byte, so one deinit is enough" {
    // Run under the testing allocator, which reports a leak.
    var doc = try parse(testing.allocator,
        \\a: one
        \\b: "two\n"
        \\c: 'three'
        \\d:
        \\  - x
        \\  - y
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("one", doc.scalar("a").?);
    try testing.expectEqualStrings("two\n", doc.scalar("b").?);
    try testing.expectEqualStrings("three", doc.scalar("c").?);
    try testing.expectEqual(@as(usize, 2), doc.get("d").?.sequence.len);
}

test "a realistic configuration file parses" {
    var doc = try parse(testing.allocator,
        \\# snek configuration
        \\---
        \\service:
        \\  name: cfg
        \\  workers: 4
        \\  debug: false
        \\tls:
        \\  enabled: true
        \\  cert: "/etc/snek/cert.pem"
        \\  protocols: [tls1.2, tls1.3]
        \\hosts:
        \\  - name: alpha
        \\    port: 7000
        \\  - name: beta
        \\    port: 7001
        \\
    );
    defer doc.deinit();

    try testing.expectEqualStrings("cfg", doc.scalar("service.name").?);
    try testing.expectEqualStrings("4", doc.scalar("service.workers").?);
    try testing.expectEqualStrings("false", doc.scalar("service.debug").?);
    try testing.expectEqualStrings("/etc/snek/cert.pem", doc.scalar("tls.cert").?);
    try testing.expectEqual(@as(usize, 2), doc.get("tls.protocols").?.sequence.len);
    try testing.expectEqual(@as(usize, 2), doc.get("hosts").?.sequence.len);
    try testing.expectEqualStrings("beta", doc.get("hosts").?.sequence[1].mapping[0].value.scalar);
}
