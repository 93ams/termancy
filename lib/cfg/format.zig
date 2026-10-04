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
//! `error.UnsupportedFormat`. `toml_doc.zig` is a comment-preserving document model
//! whose `get` returns `?[]const u8`; it is not a nested typed tree, so there is
//! nothing here to flatten without typing it first. TOML is therefore readable
//! through `cfg.toml_doc` and not yet through this dispatcher - stated rather than
//! approximated, because a TOML reader that silently drops tables is worse than one
//! that says it cannot.

const std = @import("std");
const assert = std.debug.assert;
const binder = @import("binder.zig");
const yaml = @import("yaml.zig");

pub const Format = enum { json, toml, yaml };

pub const Error = error{
    UnknownFormat,
    /// A format this dispatcher cannot flatten yet. See the module comment.
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
        .toml => return error.UnsupportedFormat,
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

test "TOML is refused rather than silently dropping its tables" {
    try testing.expectError(error.UnsupportedFormat, load(
        testing.allocator,
        "[server]\nhost = \"localhost\"\n",
        .toml,
    ));
}

test "a YAML construct outside the subset surfaces as Malformed, not a wrong value" {
    // The subset refuses anchors; this asserts the refusal reaches the caller of
    // `load` rather than being swallowed into a partially filled map.
    try testing.expectError(error.Malformed, load(testing.allocator, "a: &x 1\n", .yaml));
}
