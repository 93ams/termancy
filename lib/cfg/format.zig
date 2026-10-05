//! Reading a configuration file: which format is it, and what does it say.
//!
//! ## Why this flattens instead of decoding into a struct
//!
//! "Decode JSON, TOML and YAML into a Zig struct" can be built twice: a reflection
//! layer per format, or one typing path that every format feeds. The second is what
//! this does, and the typing path already exists - `cfg.binder` coerces text into
//! every field shape a config can have, with the provenance and ownership rules
//! already tested.
//!
//! So a file is read into a flat map of **dotted keys to scalar text**
//! (`server.tls.enabled` -> `"true"`), and that map is handed to the binder as a
//! `.file` layer. A second reflection implementation would have been a second place
//! for "does this text belong in this field" to be answered differently, and the
//! two answers would diverge the first time one of them learned about a new type.
//!
//! ## TOML
//!
//! Flattened through `toml_doc.zig`, the comment-preserving line model: a
//! `[table]` header supplies a prefix and each `key = value` assignment becomes one
//! entry, so `[server]\nport = 8080` is the same `server.port` -> `"8080"` a YAML
//! file would produce.
//!
//! What this reader will **not** do is guess. `toml_doc` stores anything it does not
//! recognise verbatim, and a construct this flattening cannot place - an array of
//! tables (`[[x]]`), an inline table (`a = { b = 1 }`) - is `error.Malformed` rather
//! than a silently dropped key. A TOML reader that loses a table is worse than one
//! that says it cannot read the file.

const std = @import("std");
const assert = std.debug.assert;
const binder = @import("binder.zig");
const yaml = @import("yaml.zig");
const toml_doc = @import("toml_doc.zig");

pub const Format = enum { json, toml, yaml };

pub const Error = error{
    UnknownFormat,
    /// Retained for callers that match on this set exhaustively. No format is
    /// refused today: TOML is flattened through `toml_doc`, so the dispatcher can
    /// read every extension `detect` recognises.
    UnsupportedFormat,
    Malformed,
    OutOfMemory,
};

/// Guesses the format from a filename's extension.
pub fn detect(path: []const u8) ?Format {
    assert(path.len > 0);
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return .json;
    if (std.ascii.eqlIgnoreCase(extension, ".toml")) return .toml;
    if (std.ascii.eqlIgnoreCase(extension, ".yaml")) return .yaml;
    if (std.ascii.eqlIgnoreCase(extension, ".yml")) return .yaml;
    return null;
}

/// Guesses the format from the content.
///
/// Only used when the filename said nothing, so it is deliberately shallow: a
/// first non-space character of `{` or `[` is JSON, and anything else is YAML. A
/// deeper guess would be a parser, and a guess that is wrong is worse than asking
/// the caller to be explicit.
pub fn sniff(text: []const u8) ?Format {
    for (text) |byte| {
        switch (byte) {
            ' ', '\t', '\r', '\n' => continue,
            '{', '[' => return .json,
            // `---` opens a YAML document; a bare `key:` is YAML by elimination.
            else => return .yaml,
        }
    }
    return null;
}

/// A parsed file, flattened to dotted keys, owned in one arena.
pub const Flat = struct {
    arena: std.heap.ArenaAllocator,
    values: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Flat) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Flat) usize {
        return self.values.count();
    }

    pub fn get(self: *const Flat, path: []const u8) ?[]const u8 {
        return self.values.get(path);
    }

    /// This file as the binder's `.file` layer, so one call binds a struct from a
    /// file:
    ///
    /// ```zig
    /// var flat = try format.load(allocator, text, .yaml);
    /// defer flat.deinit();
    /// var binding = try binder.bind(Config, allocator, &.{ flat.layer() });
    /// ```
    ///
    /// The pointer is to a map inside `self`, so the `Flat` must outlive the layer.
    pub fn layer(self: *const Flat) binder.Layer {
        return binder.Layer.map(.file, &self.values);
    }
};

/// Parses `text` as `format` and flattens it.
pub fn load(allocator: std.mem.Allocator, text: []const u8, format: Format) Error!Flat {
    var flat = Flat{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer flat.arena.deinit();
    const scratch = flat.arena.allocator();

    switch (format) {
        .json => try loadJson(scratch, &flat.values, text),
        .yaml => try loadYaml(scratch, &flat.values, text),
        .toml => try loadToml(scratch, &flat.values, text),
    }
    return flat;
}

fn loadJson(
    scratch: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged([]const u8),
    text: []const u8,
) Error!void {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, text, .{}) catch
        return error.Malformed;
    defer parsed.deinit();

    try flattenJson(scratch, out, "", parsed.value);
}

fn flattenJson(
    scratch: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged([]const u8),
    prefix: []const u8,
    value: std.json.Value,
) Error!void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try joinKey(scratch, prefix, entry.key_ptr.*);
                try flattenJson(scratch, out, key, entry.value_ptr.*);
            }
        },
        .array => |array| {
            for (array.items, 0..) |element, i| {
                const key = try joinKey(scratch, prefix, try std.fmt.allocPrint(scratch, "{d}", .{i}));
                try flattenJson(scratch, out, key, element);
            }
        },
        .string => |s| try out.put(scratch, try scratch.dupe(u8, prefix), s),
        .integer => |i| try putOwned(scratch, out, prefix, try std.fmt.allocPrint(scratch, "{d}", .{i})),
        .float => |f| try putOwned(scratch, out, prefix, try std.fmt.allocPrint(scratch, "{d}", .{f})),
        .bool => |b| try putOwned(scratch, out, prefix, if (b) "true" else "false"),
        // A JSON null has no text, and inventing "" would make it indistinguishable
        // from an empty string. An optional field simply gets no layer value, which
        // is what null means.
        .null => {},
        .number_string => |s| try out.put(scratch, try scratch.dupe(u8, prefix), s),
    }
}

fn loadYaml(
    scratch: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged([]const u8),
    text: []const u8,
) Error!void {
    const document = yaml.parse(scratch, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    // The arena below owns it; `yaml.Document.deinit` would free a sub-arena that
    // is already inside `scratch`, so it is deliberately not called.
    try flattenYaml(scratch, out, "", document.root);
}

fn flattenYaml(
    scratch: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged([]const u8),
    prefix: []const u8,
    value: yaml.Value,
) Error!void {
    switch (value) {
        .mapping => |entries| {
            for (entries) |entry| {
                const key = try joinKey(scratch, prefix, entry.key);
                try flattenYaml(scratch, out, key, entry.value);
            }
        },
        .sequence => |items| {
            for (items, 0..) |element, i| {
                const index = try std.fmt.allocPrint(scratch, "{d}", .{i});
                const key = try joinKey(scratch, prefix, index);
                try flattenYaml(scratch, out, key, element);
            }
        },
        .scalar => |s| try out.put(scratch, try scratch.dupe(u8, prefix), s),
    }
}

/// Flattens a TOML document: `[table]` headers prefix the keys that follow.
///
/// The last writer wins, which is what TOML means by a key defined twice, and the
/// dotted key a nested table produces (`[a.b]` then `c = 1` gives `a.b.c`) is the
/// same spelling the JSON and YAML arms emit.
fn loadToml(
    scratch: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged([]const u8),
    text: []const u8,
) Error!void {
    var document = toml_doc.parse(scratch, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    // The document's own arena is a child of `scratch`; `deinit` is still called so
    // the model does not depend on its caller's allocator being an arena.
    defer document.deinit();

    var table: []const u8 = "";
    for (document.lines.items) |line| {
        switch (line.kind) {
            .blank, .comment => {},
            .header => {
                // An array of tables is a list and has no flat spelling: an index
                // would have to be invented, and inventing one would make two
                // different files resolve alike. `toml_doc` classifies `[[x]]` with
                // the inner bracket retained, so a trailing `]` is the signal.
                if (std.mem.endsWith(u8, line.header_name, "]")) return error.Malformed;
                const name = std.mem.trim(u8, line.header_name, " \t");
                if (name.len == 0) return error.Malformed;
                table = try scratch.dupe(u8, name);
            },
            .assignment => {
                if (line.key.len == 0) return error.Malformed;
                const key = try joinKey(scratch, table, line.key);
                try out.put(scratch, key, try tomlScalar(scratch, line.value));
            },
            // `toml_doc` stores what it cannot classify verbatim. Refusing is the
            // documented contract: ignoring it would drop a setting silently.
            .other => return error.Malformed,
        }
    }
}

/// A TOML value as the scalar text the binder coerces.
///
/// A quoted string loses its quotes, and a basic string's escapes are decoded;
/// everything else keeps its text, because `8080` and `true` are exactly what the
/// coercions expect. A multi-line string and an inline table both reach here as text
/// this cannot place, and both are refused rather than passed on as a value no
/// coercion understands.
fn tomlScalar(scratch: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const text = std.mem.trim(u8, raw, " \t\r");
    if (text.len == 0) return error.Malformed;
    if (text[0] == '{') return error.Malformed;

    if (text[0] == '"' or text[0] == '\'') {
        const quote = text[0];
        if (text.len < 2 or text[text.len - 1] != quote) return error.Malformed;
        const inner = text[1 .. text.len - 1];
        // A literal string's escapes are not escapes - that is the whole difference
        // between TOML's `'...'` and `"..."`.
        if (quote == '\'') return scratch.dupe(u8, inner);
        return unescapeBasic(scratch, inner);
    }
    return scratch.dupe(u8, text);
}

/// Decodes TOML's basic-string escapes, refusing one it does not know.
///
/// Refusing rather than reproducing an unknown escape verbatim: `"\q"` has no
/// meaning in TOML, so a value that reaches a field unchanged would be this reader
/// inventing one.
fn unescapeBasic(scratch: std.mem.Allocator, inner: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(scratch);

    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        if (ch != '\\') {
            try out.append(scratch, ch);
            continue;
        }
        i += 1;
        if (i >= inner.len) return error.Malformed;
        switch (inner[i]) {
            'n' => try out.append(scratch, '\n'),
            't' => try out.append(scratch, '\t'),
            'r' => try out.append(scratch, '\r'),
            '"' => try out.append(scratch, '"'),
            '\\' => try out.append(scratch, '\\'),
            else => return error.Malformed,
        }
    }
    return out.toOwnedSlice(scratch);
}

fn putOwned(
    scratch: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged([]const u8),
    key: []const u8,
    value: []const u8,
) Error!void {
    try out.put(scratch, try scratch.dupe(u8, key), value);
}
/// Joins a dotted path, so a nested key is `server.tls.enabled` and an array
/// element is `hosts.0`.
fn joinKey(scratch: std.mem.Allocator, prefix: []const u8, segment: []const u8) Error![]const u8 {
    assert(segment.len > 0);
    if (prefix.len == 0) return scratch.dupe(u8, segment);
    return std.fmt.allocPrint(scratch, "{s}.{s}", .{ prefix, segment });
}

const testing = std.testing;
const binder_mod = binder;

/// The struct the end-to-end tests bind, declared once.
const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    debug: bool = false,
    tls: Tls = .{},

    const Tls = struct {
        enabled: bool = false,
        cert: ?[]const u8 = null,
    };
};

test "detect reads the extension, case-insensitively" {
    try testing.expectEqual(@as(?Format, .json), detect("config.json"));
    try testing.expectEqual(@as(?Format, .toml), detect("Config.TOML"));
    try testing.expectEqual(@as(?Format, .yaml), detect("a/b/config.yaml"));
    // `.yml` is the same format, and refusing it would be a needless surprise.
    try testing.expectEqual(@as(?Format, .yaml), detect("config.yml"));
    try testing.expectEqual(@as(?Format, null), detect("config.ini"));
    try testing.expectEqual(@as(?Format, null), detect("noextension"));
}

test "sniff distinguishes the one case that is unambiguous" {
    try testing.expectEqual(@as(?Format, .json), sniff("  \n {\"a\":1}"));
    try testing.expectEqual(@as(?Format, .json), sniff("[1, 2]"));
    try testing.expectEqual(@as(?Format, .yaml), sniff("---\na: 1\n"));
    try testing.expectEqual(@as(?Format, .yaml), sniff("a: 1"));
    // Nothing but whitespace says nothing.
    try testing.expectEqual(@as(?Format, null), sniff("   \n\n"));
}

test "a nested JSON document flattens to dotted keys" {
    var flat = try load(testing.allocator,
        \\{"server": {"host": "localhost", "tls": {"enabled": true, "cert": "/c.pem"}}}
    , .json);
    defer flat.deinit();

    try testing.expectEqualStrings("localhost", flat.get("server.host").?);
    try testing.expectEqualStrings("true", flat.get("server.tls.enabled").?);
    try testing.expectEqualStrings("/c.pem", flat.get("server.tls.cert").?);
}

test "a JSON array flattens to indexed keys, and numbers keep their text" {
    var flat = try load(testing.allocator,
        \\{"hosts": ["alpha", "beta"], "port": 8080, "rate": 1.5}
    , .json);
    defer flat.deinit();

    try testing.expectEqualStrings("alpha", flat.get("hosts.0").?);
    try testing.expectEqualStrings("beta", flat.get("hosts.1").?);
    try testing.expectEqualStrings("8080", flat.get("port").?);
    try testing.expectEqualStrings("1.5", flat.get("rate").?);
}

test "a JSON null produces no key, rather than an empty string" {
    // An empty string and an absent value are different, and an optional field has
    // to be able to tell them apart.
    var flat = try load(testing.allocator, "{\"a\": null, \"b\": \"\"}", .json);
    defer flat.deinit();

    try testing.expectEqual(@as(?[]const u8, null), flat.get("a"));
    try testing.expectEqualStrings("", flat.get("b").?);
}

test "malformed JSON is an error, not an empty document" {
    try testing.expectError(error.Malformed, load(testing.allocator, "{not json", .json));
    try testing.expectError(error.Malformed, load(testing.allocator, "", .json));
}

test "a nested YAML document flattens the same way" {
    var flat = try load(testing.allocator,
        \\server:
        \\  host: localhost
        \\  tls:
        \\    enabled: true
        \\    cert: /c.pem
        \\
    , .yaml);
    defer flat.deinit();

    try testing.expectEqualStrings("localhost", flat.get("server.host").?);
    try testing.expectEqualStrings("true", flat.get("server.tls.enabled").?);
    try testing.expectEqualStrings("/c.pem", flat.get("server.tls.cert").?);
}

test "a YAML sequence of mappings flattens to indexed dotted keys" {
    var flat = try load(testing.allocator,
        \\hosts:
        \\  - name: alpha
        \\    port: 1
        \\  - name: beta
        \\    port: 2
        \\
    , .yaml);
    defer flat.deinit();

    try testing.expectEqualStrings("alpha", flat.get("hosts.0.name").?);
    try testing.expectEqualStrings("1", flat.get("hosts.0.port").?);
    try testing.expectEqualStrings("beta", flat.get("hosts.1.name").?);
    try testing.expectEqualStrings("2", flat.get("hosts.1.port").?);
}

test "the same document in JSON and YAML flattens identically" {
    // The payoff of one typing path: the format stops mattering past this point.
    const json_text =
        \\{"server": {"host": "localhost", "tls": {"enabled": true}}}
    ;
    const yaml_text =
        \\server:
        \\  host: localhost
        \\  tls:
        \\    enabled: true
        \\
    ;

    var from_json = try load(testing.allocator, json_text, .json);
    defer from_json.deinit();
    var from_yaml = try load(testing.allocator, yaml_text, .yaml);
    defer from_yaml.deinit();

    try testing.expectEqualStrings(
        from_json.get("server.tls.enabled").?,
        from_yaml.get("server.tls.enabled").?,
    );
    try testing.expectEqualStrings(
        from_json.get("server.host").?,
        from_yaml.get("server.host").?,
    );
}

test "a file binds a struct through the binder, which is the whole point" {
    var flat = try load(testing.allocator,
        \\host: from-yaml
        \\port: 9000
        \\debug: true
        \\tls:
        \\  enabled: true
        \\  cert: /etc/cert.pem
        \\
    , .yaml);
    defer flat.deinit();

    var binding = try binder_mod.bind(Config, testing.allocator, &.{flat.layer()});
    defer binding.deinit();

    try testing.expectEqualStrings("from-yaml", binding.value.host);
    try testing.expectEqual(@as(u16, 9000), binding.value.port);
    try testing.expect(binding.value.debug);
    try testing.expect(binding.value.tls.enabled);
    try testing.expectEqualStrings("/etc/cert.pem", binding.value.tls.cert.?);

    // And the provenance says the file supplied it, which is what makes a
    // "where did this come from" report possible.
    try testing.expectEqual(binder_mod.Source.file, binding.sourceOf("port"));
    try testing.expectEqual(binder_mod.Source.file, binding.sourceOf("tls"));
}

test "a file layer loses to a flag layer put above it, as precedence requires" {
    var flat = try load(testing.allocator, "host: from-file\nport: 1\n", .yaml);
    defer flat.deinit();

    var flags = std.StringHashMapUnmanaged([]const u8){};
    defer flags.deinit(testing.allocator);
    try flags.put(testing.allocator, "host", "from-flag");

    var binding = try binder_mod.bind(Config, testing.allocator, &.{
        binder_mod.Layer.map(.flag, &flags),
        flat.layer(),
    });
    defer binding.deinit();

    try testing.expectEqualStrings("from-flag", binding.value.host);
    // The flag said nothing about the port, so the file still supplies it.
    try testing.expectEqual(@as(u16, 1), binding.value.port);
}

test "a TOML document flattens to the same dotted keys as JSON and YAML" {
    var flat = try load(testing.allocator,
        \\# the server
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[server.tls]
        \\enabled = true
        \\cert = "/c.pem"
        \\
    , .toml);
    defer flat.deinit();

    try testing.expectEqualStrings("localhost", flat.get("server.host").?);
    try testing.expectEqualStrings("8080", flat.get("server.port").?);
    try testing.expectEqualStrings("true", flat.get("server.tls.enabled").?);
    // A quoted string loses its quotes, or every coercion downstream would see them.
    try testing.expectEqualStrings("/c.pem", flat.get("server.tls.cert").?);
}

test "a TOML literal string keeps its backslashes and a basic string decodes them" {
    var flat = try load(testing.allocator,
        \\literal = 'C:\path\n'
        \\basic = "a\tb"
        \\
    , .toml);
    defer flat.deinit();

    try testing.expectEqualStrings("C:\\path\\n", flat.get("literal").?);
    try testing.expectEqualStrings("a\tb", flat.get("basic").?);
}

test "a TOML top-level key needs no table header" {
    var flat = try load(testing.allocator, "debug = true\nempty = \"\"\n", .toml);
    defer flat.deinit();

    try testing.expectEqualStrings("true", flat.get("debug").?);
    // An empty string is a value, not an absence - the same distinction the JSON
    // null test pins.
    try testing.expectEqualStrings("", flat.get("empty").?);
}

test "TOML constructs without a flat spelling are refused, not dropped" {
    // An array of tables is a list; flattening it would have to invent an index.
    try testing.expectError(error.Malformed, load(
        testing.allocator,
        "[[servers]]\nhost = \"a\"\n",
        .toml,
    ));
    // An inline table is a nested object on one line.
    try testing.expectError(error.Malformed, load(
        testing.allocator,
        "server = { host = \"a\" }\n",
        .toml,
    ));
    // And a parse failure is still a parse failure.
    try testing.expectError(error.Malformed, load(testing.allocator, "[server\nhost = 1\n", .toml));
}

test "a YAML construct outside the subset surfaces as Malformed, not a wrong value" {
    // The subset refuses anchors; this asserts the refusal reaches the caller of
    // `load` rather than being swallowed into a partially filled map.
    try testing.expectError(error.Malformed, load(testing.allocator, "a: &x 1\n", .yaml));
}
