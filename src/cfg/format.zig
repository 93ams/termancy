//! The supported file formats, and dispatch to their codecs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Diagnostic = @import("Diagnostic.zig");
const json = @import("json.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const dotenv = @import("dotenv.zig");
const zon = @import("zon.zig");
const ini = @import("ini.zig");

/// The length of the UTF-8 byte order mark `source` starts with, 0 or 3. Every parser
/// starts after it, as editors on Windows often write one; spans keep counting from the
/// start of `source`, so in-place edits keep it.
pub fn bomLength(source: []const u8) usize {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0;
}

/// What `Format.parse` can fail with.
pub const ParseError = error{SyntaxError} || Allocator.Error;
/// What `Format.write` can fail with.
pub const WriteError = std.Io.Writer.Error || error{Unrepresentable};

/// A configuration format, with `parse` and `write` for each.
pub const Format = enum {
    json,
    toml,
    yaml,
    dotenv,
    zon,
    /// JSON with `//` and `/* */` comments and trailing commas; written as plain JSON.
    jsonc,
    ini,

    /// Extensions tried, in order, when searching for a file of this format.
    pub fn extensions(format: Format) []const []const u8 {
        return switch (format) {
            .json => &.{".json"},
            .toml => &.{".toml"},
            .yaml => &.{ ".yaml", ".yml" },
            .dotenv => &.{".env"},
            .zon => &.{".zon"},
            .jsonc => &.{ ".jsonc", ".json5" },
            .ini => &.{ ".ini", ".cfg", ".conf" },
        };
    }

    /// The format a file name implies: by extension, or `.env` / `.env.*` for dotenv.
    pub fn fromPath(file_path: []const u8) ?Format {
        const base = std.fs.path.basename(file_path);
        if (std.mem.eql(u8, base, ".env") or std.mem.startsWith(u8, base, ".env.")) return .dotenv;
        const ext = std.fs.path.extension(base);
        for (std.enums.values(Format)) |format| {
            for (format.extensions()) |e| {
                if (std.ascii.eqlIgnoreCase(e, ext)) return format;
            }
        }
        return null;
    }

    /// The format a name means: `json`, `toml`, `yaml`/`yml`, `env`/`dotenv`, `zon`.
    pub fn fromName(name: []const u8) ?Format {
        if (std.ascii.eqlIgnoreCase(name, "yml")) return .yaml;
        if (std.ascii.eqlIgnoreCase(name, "env")) return .dotenv;
        for (std.enums.values(Format)) |format| {
            if (std.ascii.eqlIgnoreCase(name, @tagName(format))) return format;
        }
        return null;
    }

    /// Parses `source`. All memory comes from `arena`.
    pub fn parse(
        format: Format,
        arena: Allocator,
        source: []const u8,
        diag: ?*Diagnostic,
    ) ParseError!Value {
        return switch (format) {
            .json => json.parse(arena, source, diag),
            .toml => toml.parse(arena, source, diag),
            .yaml => yaml.parse(arena, source, diag),
            .dotenv => dotenv.parse(arena, source, diag),
            .zon => zon.parse(arena, source, diag),
            .jsonc => json.parseWithComments(arena, source, diag),
            .ini => ini.parse(arena, source, diag),
        };
    }

    /// Writes `value` with the format's default options.
    pub fn write(format: Format, writer: *std.Io.Writer, value: Value) WriteError!void {
        return switch (format) {
            .json => json.write(writer, value, .{}),
            .toml => toml.write(writer, value, .{}),
            .yaml => yaml.write(writer, value, .{}),
            .dotenv => dotenv.write(writer, value, .{}),
            .zon => zon.write(writer, value, .{}),
            .jsonc => json.write(writer, value, .{}),
            .ini => ini.write(writer, value),
        };
    }
};

const testing = std.testing;

test "Format.fromPath" {
    try testing.expectEqual(Format.toml, Format.fromPath("/etc/app/config.toml").?);
    try testing.expectEqual(Format.yaml, Format.fromPath("a.YML").?);
    try testing.expectEqual(Format.dotenv, Format.fromPath("dir/.env").?);
    try testing.expectEqual(Format.dotenv, Format.fromPath(".env.local").?);
    try testing.expectEqual(Format.dotenv, Format.fromPath("prod.env").?);
    try testing.expectEqual(Format.zon, Format.fromPath("build.zig.zon").?);
    try testing.expectEqual(null, Format.fromPath("config"));
}

test "Format.fromName" {
    try testing.expectEqual(Format.yaml, Format.fromName("yml").?);
    try testing.expectEqual(Format.dotenv, Format.fromName("env").?);
    try testing.expectEqual(Format.json, Format.fromName("JSON").?);
    try testing.expectEqual(Format.zon, Format.fromName("zon").?);
    try testing.expectEqual(Format.ini, Format.fromName("ini").?);
    try testing.expectEqual(null, Format.fromName("xml"));
    try testing.expectEqual(Format.jsonc, Format.fromPath("settings.jsonc").?);
    try testing.expectEqual(Format.ini, Format.fromPath("app.conf").?);
}

test "every format reads what it writes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree: Value = .empty_table;
    try tree.put(a, "server.host", .{ .string = "example.com" });
    try tree.put(a, "server.port", .{ .string = "8080" });
    try tree.put(a, "name", .{ .string = "with \"quotes\" and $dollar" });
    for (std.enums.values(Format)) |format| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try format.write(&out.writer, tree);
        const back = try format.parse(a, out.written(), null);
        try testing.expect(tree.eql(back));
    }
}

test "one document in JSON, YAML, and TOML reads as one tree" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json_text =
        \\{"name": "demo", "port": 8080, "ratio": 0.5, "debug": false,
        \\ "tags": ["a", "b"], "server": {"host": "h", "tls": {"on": true}},
        \\ "upstreams": [{"url": "x"}, {"url": "y"}]}
    ;
    const yaml_text =
        \\name: demo
        \\port: 8080
        \\ratio: 0.5
        \\debug: false
        \\tags: [a, b]
        \\server:
        \\  host: h
        \\  tls: {on: true}
        \\upstreams:
        \\  - url: x
        \\  - url: "y"
        \\
    ;
    const toml_text =
        \\name = "demo"
        \\port = 8080
        \\ratio = 0.5
        \\debug = false
        \\tags = ["a", "b"]
        \\upstreams = [{ url = "x" }, { url = "y" }]
        \\
        \\[server]
        \\host = "h"
        \\tls.on = true
        \\
    ;
    const from_json = try Format.json.parse(a, json_text, null);
    try std.testing.expect(from_json.eql(try Format.yaml.parse(a, yaml_text, null)));
    try std.testing.expect(from_json.eql(try Format.toml.parse(a, toml_text, null)));
}

test "Format.fromPath edge cases" {
    try testing.expectEqual(Format.toml, Format.fromPath("CONFIG.TOML").?);
    try testing.expectEqual(Format.yaml, Format.fromPath("x.Yaml").?);
    try testing.expectEqual(Format.json, Format.fromPath("dir.d/settings.JSON").?);
    try testing.expectEqual(Format.dotenv, Format.fromPath("prod.ENV").?);
    try testing.expectEqual(Format.dotenv, Format.fromPath("/srv/.env.production").?);
    // No extension, an unknown one, a trailing dot, or one only in a directory name.
    try testing.expectEqual(null, Format.fromPath("Makefile"));
    try testing.expectEqual(null, Format.fromPath("config.toml.bak"));
    try testing.expectEqual(null, Format.fromPath("config."));
    try testing.expectEqual(null, Format.fromPath("conf.d/app"));
    try testing.expectEqual(null, Format.fromPath(""));
    // A dotfile has no extension, and `.envrc` is not `.env.*`.
    try testing.expectEqual(null, Format.fromPath(".toml"));
    try testing.expectEqual(null, Format.fromPath(".envrc"));
}

test "Format.fromName accepts every spelling" {
    try testing.expectEqual(Format.yaml, Format.fromName("YAML").?);
    try testing.expectEqual(Format.yaml, Format.fromName("Yml").?);
    try testing.expectEqual(Format.dotenv, Format.fromName("dotenv").?);
    try testing.expectEqual(Format.dotenv, Format.fromName("ENV").?);
    try testing.expectEqual(Format.toml, Format.fromName("toml").?);
    try testing.expectEqual(null, Format.fromName(""));
    try testing.expectEqual(null, Format.fromName(".json"));
}

test "every format's extensions map back to it" {
    for (std.enums.values(Format)) |format| {
        for (format.extensions()) |ext| {
            const name = try std.mem.concat(testing.allocator, u8, &.{ "file", ext });
            defer testing.allocator.free(name);
            try testing.expectEqual(format, Format.fromPath(name).?);
        }
    }
}

test "parse dispatch reports syntax errors with a position" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bad = [_]struct { Format, []const u8 }{
        .{ .json, "{\n  \"a\": ,\n}" },
        .{ .toml, "a = 1\nb = = 2\n" },
        .{ .yaml, "a: 1\nb: [\n" },
        .{ .dotenv, "A=1\nB='x\n" },
        .{ .zon, ".{\n    .a = ,\n}" },
    };
    for (bad) |case| {
        var diag: Diagnostic = .{};
        try testing.expectError(
            error.SyntaxError,
            case[0].parse(arena.allocator(), case[1], &diag),
        );
        try testing.expect(diag.line >= 1 and diag.column >= 1);
        try testing.expect(diag.message.len > 0);
    }
}

test "write dispatch rejects what a format cannot spell" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.Unrepresentable, Format.toml.write(&out.writer, .{ .int = 1 }));
    try testing.expectError(error.Unrepresentable, Format.dotenv.write(&out.writer, .null));
    var empty_key: Value = .empty_table;
    try empty_key.table.put(testing.allocator, "", .null);
    defer empty_key.table.deinit(testing.allocator);
    try testing.expectError(error.Unrepresentable, Format.zon.write(&out.writer, empty_key));
    const inf: Value = .{ .float = std.math.inf(f64) };
    try testing.expectError(error.Unrepresentable, Format.json.write(&out.writer, inf));
    out.clearRetainingCapacity();
    try Format.yaml.write(&out.writer, inf);
    try testing.expectEqualStrings(".inf\n", out.written());
}

test "every format reads past a byte order mark" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { Format, []const u8 }{
        .{ .json, "{\"a\": 1}" },
        .{ .jsonc, "{\"a\": 1, // c\n}" },
        .{ .toml, "a = 1\n" },
        .{ .yaml, "a: 1\n" },
        .{ .dotenv, "A=1\n" },
        .{ .ini, "a=1\n" },
        .{ .zon, ".{ .a = 1 }" },
    };
    for (cases) |case| {
        const source = try std.mem.concat(a, u8, &.{ "\xEF\xBB\xBF", case[1] });
        const tree = try case[0].parse(a, source, null);
        const value = tree.lookup("a") orelse return error.TestExpectedKey;
        try testing.expectEqualStrings("1", try std.fmt.allocPrint(a, "{f}", .{value}));
    }
    var reader: std.Io.Reader = .fixed("\xEF\xBB\xBF{\"a\": 1}");
    try testing.expectEqual(1, (try json.parseReader(a, &reader, null)).lookup("a").?.int);
}
