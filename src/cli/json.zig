//! The command tree as JSON, for tools rather than people: `docs.write(..., .json)`.
//!
//! The document is the root command; every command object has the same keys:
//!
//! ```text
//! name, path, summary, description, examples, aliases, deprecated (string|null),
//! runnable, topic, args {min, max (null: unlimited), usage, positionals [...]}, flags [...],
//! constraints {exclusive, together, one_required}, subcommands [...]
//! ```
//!
//! and every flag object:
//!
//! ```text
//! name, short (string|null), help, kind (bool|count|value), type, label, choices,
//! default (string|null), env (string|null), required, repeatable, persistent, inherited,
//! deprecated (string|null), aliases, minimum (number|null), maximum (number|null)
//! ```
//!
//! Hidden commands and hidden flags are left out. A command lists every flag it accepts:
//! its own, then those inherited from ancestors' `persistent_flags` (`inherited: true`).
//!
//! ## Mapping onto LLM tool schemas
//!
//! Each command with `runnable: true` is one tool. Name it by `path` with spaces replaced
//! (`app config get` -> `app_config_get`); describe it with `description`, else `summary`.
//! Its parameters form one JSON Schema object:
//!
//! - each flag is a property named `name`, described by `help`:
//!   - `kind: bool` -> `{"type": "boolean"}`;
//!   - `kind: count` -> `{"type": "integer", "minimum": 0}` (pass `--name` that many times);
//!   - `kind: value` -> `{"type": <type>}`, plus `"enum": choices` when `choices` is not
//!     empty and `minimum`/`maximum` when not null; with `repeatable: true` it is
//!     `{"type": "array", "items": <that>}`;
//! - `type` is already a JSON Schema type: `boolean`, `integer`, `number`, or `string`
//!   (custom types such as durations are strings in the type's own syntax, see `label`);
//! - `required: true` flags go in the schema's `required` list; `default` is the default
//!   as typed on the command line;
//! - typed positionals (`args.positionals`: name, type, choices, required, repeatable)
//!   become one property each, in order; otherwise
//! - positional arguments become one property `args`:
//!   `{"type": "array", "items": {"type": "string"}, "minItems": min, "maxItems": max}`
//!   (no `maxItems` when `max` is null; leave `args` out when `max` is 0), described by
//!   `usage`; required when `min > 0`;
//! - `constraints` cannot be said in a plain tool schema; put them in the description.
//!
//! A call then becomes the argument list `path[1..]`, `--name value` per flag (one per list
//! element; bare `--name` for a true boolean, `--no-name` for false), `--`, and `args`.

const std = @import("std");
const sets = @import("sets.zig");
const field_ = @import("field");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const parse = @import("parse.zig");

const max_depth = parse.max_depth;

/// Writes the tree under `root` as one indented JSON document and a final newline.
pub fn write(writer: *Writer, root: *const Command) Writer.Error!void {
    var json: Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    var path: [max_depth]*const Command = undefined;
    path[0] = root;
    try command(&json, &path, 1);
    try writer.writeByte('\n');
}

fn command(json: *Stringify, path: *[max_depth]*const Command, depth: usize) Writer.Error!void {
    assert(depth >= 1 and depth <= max_depth);
    const current = path[0..depth];
    const cmd = current[depth - 1];
    try json.beginObject();
    try field(json, "name", cmd.name);
    try json.objectField("path");
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    for (current, 0..) |c, i| {
        if (i > 0) try json.writer.writeByte(' ');
        try Stringify.encodeJsonStringChars(c.name, json.options, json.writer);
    }
    try json.writer.writeByte('"');
    json.endWriteRaw();
    try field(json, "summary", cmd.summary);
    try field(json, "description", cmd.description);
    try field(json, "examples", cmd.examples);
    try field(json, "aliases", cmd.aliases);
    try field(json, "deprecated", cmd.deprecated);
    try field(json, "runnable", cmd.run != null);
    try field(json, "topic", cmd.topic);
    try json.objectField("args");
    try json.beginObject();
    try field(json, "min", cmd.args.min);
    try field(json, "max", cmd.args.max);
    try field(json, "usage", cmd.args.usage);
    try json.objectField("positionals");
    try json.beginArray();
    for (cmd.args.positionals) |positional| {
        try json.beginObject();
        try field(json, "name", positional.name);
        try field(json, "type", switch (positional.value_type) {
            .bool => "boolean",
            .int => "integer",
            .float => "number",
            .string, .@"enum", .custom => "string",
        });
        try field(json, "choices", positional.choices);
        try field(json, "required", positional.required);
        try field(json, "repeatable", positional.repeatable);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try flags(json, current);
    try json.objectField("constraints");
    try json.beginObject();
    try field(json, "exclusive", cmd.constraints.exclusive);
    try field(json, "together", cmd.constraints.together);
    try field(json, "one_required", cmd.constraints.one_required);
    try json.endObject();
    try json.objectField("subcommands");
    try json.beginArray();
    for (cmd.subcommands) |*sub| {
        if (sub.hidden or depth >= max_depth) continue;
        path[depth] = sub;
        try command(json, path, depth + 1);
    }
    try json.endArray();
    try json.endObject();
}

fn flags(json: *Stringify, path: []const *const Command) Writer.Error!void {
    try json.objectField("flags");
    try json.beginArray();
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (flag.hidden or isShadowed(path, flag)) continue;
        try flagObject(json, path, flag);
    }
    try json.endArray();
}

fn flagObject(json: *Stringify, path: []const *const Command, flag: *const Flag) Writer.Error!void {
    try json.beginObject();
    try field(json, "name", flag.name);
    try json.objectField("short");
    if (flag.short) |short| try json.write(&[1]u8{short}) else try json.write(null);
    try field(json, "help", flag.help);
    try field(json, "kind", @tagName(flag.kind));
    try field(json, "type", schemaType(flag));
    try field(json, "label", flag.value_name);
    try field(json, "choices", flag.choices);
    try json.objectField("default");
    if (flag.write_default != null) {
        var buffer: [256]u8 = undefined;
        var default_writer: Writer = .fixed(&buffer);
        // A default that does not fit is cut short rather than failing the document.
        flag.writeDefault(&default_writer) catch {};
        try json.write(default_writer.buffered());
    } else {
        try json.write(null);
    }
    try field(json, "env", flag.env);
    try field(json, "required", flag.required);
    try field(json, "repeatable", flag.repeatable and flag.kind == .value);
    try field(json, "persistent", isPersistent(path, flag));
    try field(json, "inherited", isInherited(path, flag));
    try field(json, "deprecated", flag.deprecated);
    try field(json, "aliases", flag.aliases);
    try field(json, "minimum", if (flag.minimum()) |b| b.number else null);
    try field(json, "maximum", if (flag.maximum()) |b| b.number else null);
    try json.endObject();
}

fn field(json: *Stringify, name: []const u8, value: anytype) Writer.Error!void {
    try json.objectField(name);
    try json.write(value);
}

/// The JSON Schema type of one value of `flag`.
fn schemaType(flag: *const Flag) []const u8 {
    return switch (flag.kind) {
        .bool => "boolean",
        .count => "integer",
        .value => switch (flag.value_type) {
            .bool => "boolean",
            .int => "integer",
            .float => "number",
            .string, .@"enum", .custom => "string",
        },
    };
}

/// Whether a nearer flag of the same name hides `flag`; the visible iterator yields
/// nearer flags first.
fn isShadowed(path: []const *const Command, flag: *const Flag) bool {
    var it = parse.visible(path);
    while (it.next()) |candidate| {
        if (candidate == flag) return false;
        if (std.mem.eql(u8, candidate.name, flag.name)) return true;
    }
    unreachable; // `flag` came from the same iterator.
}

/// Whether `flag` is one of the persistent flags of a command on `path`.
fn isPersistent(path: []const *const Command, flag: *const Flag) bool {
    for (path) |cmd| {
        for (cmd.persistent_flags) |*candidate| if (candidate == flag) return true;
    }
    return false;
}

/// Whether `flag` belongs to an ancestor of the last command of `path`.
fn isInherited(path: []const *const Command, flag: *const Flag) bool {
    for (path[0 .. path.len - 1]) |ancestor| {
        for (ancestor.persistent_flags) |*candidate| if (candidate == flag) return true;
    }
    return false;
}

const testing = std.testing;
const spec = @import("spec.zig");
const Context = @import("Context.zig");

fn noop(_: *Context) !void {}

const Global = struct {
    verbose: u8 = 0,
};
const global_flags = sets.flags(Global, field_.Set(.{field_.Spec(Global){ .fields = .{
    .verbose = .{ .help = "More output" },
} }}), .{ .fields = .{
    .verbose = .{ .short = 'v', .count = true },
} });

const SetFlags = struct {
    file: []const u8,
    mode: enum { merge, replace } = .merge,
    tag: []const []const u8 = &.{},
    ratio: f32 = 0.5,
    dry_run: bool = false,
    secret: bool = false,
};
const set_flags = sets.flags(SetFlags, field_.Set(.{field_.Spec(SetFlags){ .fields = .{
    .file = .{ .help = "File to \"edit\"" },
    .tag = .{ .deprecated = "use labels" },
} }}), .{ .fields = .{
    .file = .{ .short = 'f', .env = "APP_FILE" },
    .secret = .{ .hidden = true },
}, .exclusive = &.{&.{ .dry_run, .ratio }} });

const test_root = spec.command(.{
    .name = "app",
    .summary = "An app",
    .persistent_flags = global_flags,
    .subcommands = .{
        spec.command(.{
            .name = "set",
            .summary = "Set a value",
            .description = "Sets one value.\n",
            .aliases = &.{"put"},
            .examples = "app set a 1",
            .deprecated = "use put",
            .args = .{ .min = 2, .max = null, .usage = "<key> <value>..." },
            .flags = set_flags,
            .run = noop,
        }),
        spec.command(.{ .name = "hidden", .hidden = true, .run = noop }),
    },
});

test write {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &test_root);
    try testing.expectEqualStrings(
        \\{
        \\  "name": "app",
        \\  "path": "app",
        \\  "summary": "An app",
        \\  "description": "",
        \\  "examples": "",
        \\  "aliases": [],
        \\  "deprecated": null,
        \\  "runnable": false,
        \\  "topic": false,
        \\  "args": {
        \\    "min": 0,
        \\    "max": 0,
        \\    "usage": "",
        \\    "positionals": []
        \\  },
        \\  "flags": [
        \\    {
        \\      "name": "verbose",
        \\      "short": "v",
        \\      "help": "More output",
        \\      "kind": "count",
        \\      "type": "integer",
        \\      "label": "",
        \\      "choices": [],
        \\      "default": null,
        \\      "env": null,
        \\      "required": false,
        \\      "repeatable": false,
        \\      "persistent": true,
        \\      "inherited": false,
        \\      "deprecated": null,
        \\      "aliases": [],
        \\      "minimum": null,
        \\      "maximum": null
        \\    }
        \\  ],
        \\  "constraints": {
        \\    "exclusive": [],
        \\    "together": [],
        \\    "one_required": []
        \\  },
        \\  "subcommands": [
        \\    {
        \\      "name": "set",
        \\      "path": "app set",
        \\      "summary": "Set a value",
        \\      "description": "Sets one value.\n",
        \\      "examples": "app set a 1",
        \\      "aliases": [
        \\        "put"
        \\      ],
        \\      "deprecated": "use put",
        \\      "runnable": true,
        \\      "topic": false,
        \\      "args": {
        \\        "min": 2,
        \\        "max": null,
        \\        "usage": "<key> <value>...",
        \\        "positionals": []
        \\      },
        \\      "flags": [
        \\        {
        \\          "name": "file",
        \\          "short": "f",
        \\          "help": "File to \"edit\"",
        \\          "kind": "value",
        \\          "type": "string",
        \\          "label": "string",
        \\          "choices": [],
        \\          "default": null,
        \\          "env": "APP_FILE",
        \\          "required": true,
        \\          "repeatable": false,
        \\          "persistent": false,
        \\          "inherited": false,
        \\          "deprecated": null,
        \\          "aliases": [],
        \\          "minimum": null,
        \\          "maximum": null
        \\        },
        \\        {
        \\          "name": "mode",
        \\          "short": null,
        \\          "help": "",
        \\          "kind": "value",
        \\          "type": "string",
        \\          "label": "merge|replace",
        \\          "choices": [
        \\            "merge",
        \\            "replace"
        \\          ],
        \\          "default": "merge",
        \\          "env": null,
        \\          "required": false,
        \\          "repeatable": false,
        \\          "persistent": false,
        \\          "inherited": false,
        \\          "deprecated": null,
        \\          "aliases": [],
        \\          "minimum": null,
        \\          "maximum": null
        \\        },
        \\        {
        \\          "name": "tag",
        \\          "short": null,
        \\          "help": "",
        \\          "kind": "value",
        \\          "type": "string",
        \\          "label": "string",
        \\          "choices": [],
        \\          "default": null,
        \\          "env": null,
        \\          "required": false,
        \\          "repeatable": true,
        \\          "persistent": false,
        \\          "inherited": false,
        \\          "deprecated": "use labels",
        \\          "aliases": [],
        \\          "minimum": null,
        \\          "maximum": null
        \\        },
        \\        {
        \\          "name": "ratio",
        \\          "short": null,
        \\          "help": "",
        \\          "kind": "value",
        \\          "type": "number",
        \\          "label": "number",
        \\          "choices": [],
        \\          "default": "0.5",
        \\          "env": null,
        \\          "required": false,
        \\          "repeatable": false,
        \\          "persistent": false,
        \\          "inherited": false,
        \\          "deprecated": null,
        \\          "aliases": [],
        \\          "minimum": null,
        \\          "maximum": null
        \\        },
        \\        {
        \\          "name": "dry-run",
        \\          "short": null,
        \\          "help": "",
        \\          "kind": "bool",
        \\          "type": "boolean",
        \\          "label": "",
        \\          "choices": [],
        \\          "default": null,
        \\          "env": null,
        \\          "required": false,
        \\          "repeatable": false,
        \\          "persistent": false,
        \\          "inherited": false,
        \\          "deprecated": null,
        \\          "aliases": [],
        \\          "minimum": null,
        \\          "maximum": null
        \\        },
        \\        {
        \\          "name": "verbose",
        \\          "short": "v",
        \\          "help": "More output",
        \\          "kind": "count",
        \\          "type": "integer",
        \\          "label": "",
        \\          "choices": [],
        \\          "default": null,
        \\          "env": null,
        \\          "required": false,
        \\          "repeatable": false,
        \\          "persistent": true,
        \\          "inherited": true,
        \\          "deprecated": null,
        \\          "aliases": [],
        \\          "minimum": null,
        \\          "maximum": null
        \\        }
        \\      ],
        \\      "constraints": {
        \\        "exclusive": [
        \\          [
        \\            "dry-run",
        \\            "ratio"
        \\          ]
        \\        ],
        \\        "together": [],
        \\        "one_required": []
        \\      },
        \\      "subcommands": []
        \\    }
        \\  ]
        \\}
        \\
    , out.written());
}

test "a nearer flag shadows an inherited one of the same name" {
    const root = comptime spec.command(.{
        .name = "app",
        .persistent_flags = struct { level: u8 = 1 },
        .subcommands = .{spec.command(.{
            .name = "run",
            .flags = struct { level: []const u8 = "high" },
            .run = noop,
        })},
    });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &root);
    const text = out.written();
    try testing.expectEqual(2, std.mem.count(u8, text, "\"name\": \"level\""));
    try testing.expect(std.mem.indexOf(u8, text, "\"default\": \"high\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"inherited\": true") == null);
}

test schemaType {
    const flags_list = comptime sets.flags(struct {
        a: bool = false,
        b: u8 = 0,
        c: i32 = 0,
        d: f64 = 0,
        e: []const u8 = "",
        f: enum { x } = .x,
        g: []const bool = &.{},
    }, field_.none, .{ .fields = .{ .b = .{ .count = true } } }).list;
    const expected = [_][]const u8{
        "boolean", "integer", "integer", "number", "string", "string", "boolean",
    };
    for (flags_list, expected) |*flag, want| try testing.expectEqualStrings(want, schemaType(flag));
}

const TypedArgs = struct {
    mode: enum { fast, safe },
    files: []const []const u8 = &.{},
};

const typed_root = spec.command(.{ .name = "app", .args = TypedArgs, .run = noop });

test "typed positionals are described" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &typed_root);
    const expected =
        \\    "positionals": [
        \\      {
        \\        "name": "mode",
        \\        "type": "string",
        \\        "choices": [
        \\          "fast",
        \\          "safe"
        \\        ],
        \\        "required": true,
        \\        "repeatable": false
        \\      },
        \\      {
        \\        "name": "files",
        \\        "type": "string",
        \\        "choices": [],
        \\        "required": false,
        \\        "repeatable": true
        \\      }
        \\    ]
    ;
    try testing.expect(std.mem.indexOf(u8, out.written(), expected) != null);
}
