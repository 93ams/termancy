//! JSON Schema (draft-07): `build` and `write` make one for a configuration struct, and
//! `validate` checks an untyped tree against one.
//!
//! Field types map to schema types, under the keys a settings type (`cfg.settings`) gives
//! them; defaults, the specs' help text (`description`), secrets (`writeOnly`),
//! deprecations (`deprecated`, from a later draft, and the `deprecationMessage` editors
//! show), and the built-in checks (`.min`, `.max`, `.minLen`, `.maxLen`, `.oneOf`, `.glob`)
//! are carried over; checks of your own are not. A choice is `oneOf` its variants' names
//! and one-key objects. A field with no default and a non-optional type is `required`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const decoding = @import("decode.zig");
const json = @import("json.zig");
const Diagnostic = @import("Diagnostic.zig");
const path = @import("path.zig");
const field = @import("field");
const settings_ = @import("settings.zig");

/// The JSON Schema draft the schemas follow.
pub const draft = "http://json-schema.org/draft-07/schema#";

/// Builds the schema for the settings type `X` (or a plain struct) as a tree in `arena`.
pub fn build(comptime X: type, arena: Allocator) decoding.EncodeError!Value {
    const Set = settings_.Of(X);
    var root = try node(Set.Type, Set.Specs, Set.root, arena);
    try root.table.put(arena, "$schema", .{ .string = draft });
    // Put `$schema` first, where readers expect it.
    const last = root.table.count() - 1;
    var reordered: Table = .empty;
    try reordered.put(arena, root.table.keys()[last], root.table.values()[last]);
    for (root.table.keys()[0..last], root.table.values()[0..last]) |k, v| {
        try reordered.put(arena, k, v);
    }
    return .{ .table = reordered };
}

/// Writes the schema for the settings type `X` (or a plain struct) as indented JSON.
pub fn write(
    comptime X: type,
    arena: Allocator,
    writer: *std.Io.Writer,
) (json.WriteError || Allocator.Error)!void {
    const tree = build(X, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unrepresentable => return error.Unrepresentable,
    };
    try json.write(writer, tree, .{});
}

fn node(
    comptime T: type,
    comptime S: type,
    comptime place: anytype,
    arena: Allocator,
) decoding.EncodeError!Value {
    var out: Table = .empty;
    if (T == Value) return .{ .table = out };
    if (comptime settings_.isChoice(T)) return choiceNode(T, S, place, arena);
    if (comptime decoding.hasParse(T)) {
        try out.put(arena, "type", .{ .string = "string" });
        try out.put(
            arena,
            "description",
            .{ .string = "text accepted by " ++ @typeName(T) ++ ".parse" },
        );
        return .{ .table = out };
    }
    switch (@typeInfo(T)) {
        .optional => |o| return node(o.child, S, place, arena),
        .bool => try out.put(arena, "type", .{ .string = "boolean" }),
        .int => {
            try out.put(arena, "type", .{ .string = "integer" });
            // Bounds an `i64` cannot hold are left out rather than failing the schema.
            if (std.math.minInt(T) >= std.math.minInt(i64)) {
                try out.put(arena, "minimum", try decoding.encode(arena, std.math.minInt(T)));
            }
            if (std.math.maxInt(T) <= std.math.maxInt(i64)) {
                try out.put(arena, "maximum", try decoding.encode(arena, std.math.maxInt(T)));
            }
        },
        .float => try out.put(arena, "type", .{ .string = "number" }),
        .@"enum" => |e| {
            try out.put(arena, "type", .{ .string = "string" });
            var names: Array = .empty;
            for (e.field_names) |name| try names.append(arena, .{ .string = name });
            try out.put(arena, "enum", .{ .array = names });
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("no schema for " ++ @typeName(T));
            if (p.child == u8) {
                try out.put(arena, "type", .{ .string = "string" });
            } else {
                try out.put(arena, "type", .{ .string = "array" });
                const item_place = comptime if (settings_.isTable(field.Unwrap(p.child)) and
                    @hasField(@TypeOf(place), "fields"))
                    settings_.Place(p.child){ .fields = place.fields }
                else
                    settings_.Place(p.child){};
                try out.put(arena, "items", try node(p.child, S, item_place, arena));
            }
        },
        .@"struct" => return object(T, S, place, arena),
        else => @compileError("no schema for " ++ @typeName(T)),
    }
    return .{ .table = out };
}

fn object(
    comptime T: type,
    comptime S: type,
    comptime place: anytype,
    arena: Allocator,
) decoding.EncodeError!Value {
    const info = @typeInfo(T).@"struct";
    const spec = comptime S.of(T);
    var properties: Table = .empty;
    var required: Array = .empty;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        const field_place = @field(place.fields, name);
        const field_spec = @field(spec.fields, name);
        const key = comptime settings_.keyOf(field_place, name);
        var property = try node(Field, S, field_place, arena);
        try describe(field_spec, arena, &property);
        if (attrs.default_value_ptr) |ptr| {
            const default = @as(*const Field, @ptrCast(@alignCast(ptr))).*;
            const encoded = try decoding.encodeAs(settings_.settings(Field, S, .{}), arena, default);
            if (encoded != .null) try property.table.put(arena, "default", encoded);
        } else if (@typeInfo(Field) != .optional and !settings_.isTable(Field)) {
            try required.append(arena, .{ .string = key });
        }
        try properties.put(arena, key, property);
    }
    var out: Table = .empty;
    try out.put(arena, "type", .{ .string = "object" });
    try out.put(arena, "properties", .{ .table = properties });
    if (required.items.len > 0) try out.put(arena, "required", .{ .array = required });
    return .{ .table = out };
}

/// A choice: the name of a variant, or an object with one key naming it.
fn choiceNode(
    comptime U: type,
    comptime S: type,
    comptime place: anytype,
    arena: Allocator,
) decoding.EncodeError!Value {
    const spec = comptime S.of(U);
    var alternatives: Array = .empty;
    var names: Array = .empty;
    inline for (comptime field.fieldNames(U), comptime field.fieldTypes(U)) |name, P| {
        const variant_place = @field(place.variants, name);
        const key = comptime settings_.keyOf(variant_place, name);
        try names.append(arena, .{ .string = key });
        if (P != void) {
            var payload = try node(P, S, variant_place, arena);
            try describe(@field(spec.fields, name), arena, &payload);
            var properties: Table = .empty;
            try properties.put(arena, key, payload);
            var wrapped: Table = .empty;
            try wrapped.put(arena, "type", .{ .string = "object" });
            try wrapped.put(arena, "properties", .{ .table = properties });
            var only: Array = .empty;
            try only.append(arena, .{ .string = key });
            try wrapped.put(arena, "required", .{ .array = only });
            try wrapped.put(arena, "additionalProperties", .{ .bool = false });
            try alternatives.append(arena, .{ .table = wrapped });
        }
    }
    var by_name: Table = .empty;
    try by_name.put(arena, "type", .{ .string = "string" });
    try by_name.put(arena, "enum", .{ .array = names });
    try alternatives.insert(arena, 0, .{ .table = by_name });
    var out: Table = .empty;
    try out.put(arena, "oneOf", .{ .array = alternatives });
    return .{ .table = out };
}

/// A field's spec in its schema: help, secrecy, deprecation, and built-in checks.
fn describe(comptime spec: anytype, arena: Allocator, property: *Value) decoding.EncodeError!void {
    if (spec.help.len > 0) try property.table.put(arena, "description", .{ .string = spec.help });
    if (spec.secret) try property.table.put(arena, "writeOnly", .{ .bool = true });
    if (spec.deprecated) |reason| {
        try property.table.put(arena, "deprecated", .{ .bool = true });
        try property.table.put(arena, "deprecationMessage", .{ .string = reason });
    }
    inline for (spec.checks) |c| if (c.about) |about| try constrain(about, arena, property);
    // `.each` bounds a list's elements: its `items`.
    if (spec.each.len > 0) if (property.table.getPtr("items")) |items| {
        inline for (spec.each) |c| if (c.about) |about| try constrain(about, arena, items);
    };
}

/// A bound as it is written: `1` rather than `1.0` when it is whole.
fn boundValue(bound: f64) Value {
    const whole = @floor(bound) == bound and @abs(bound) <= 1 << 53;
    return if (whole) .{ .int = @intFromFloat(bound) } else .{ .float = bound };
}

/// Adds a built-in check to a schema.
fn constrain(about: field.About, arena: Allocator, target: *Value) decoding.EncodeError!void {
    switch (about) {
        .min => |b| if (b.number) |n| try target.table.put(arena, "minimum", boundValue(n)),
        .max => |b| if (b.number) |n| try target.table.put(arena, "maximum", boundValue(n)),
        .min_len => |n| try target.table.put(arena, if (target.table.get("type") != null and
            std.mem.eql(u8, target.table.get("type").?.string, "array")) "minItems" else "minLength", .{ .int = @intCast(n) }),
        .max_len => |n| try target.table.put(arena, if (target.table.get("type") != null and
            std.mem.eql(u8, target.table.get("type").?.string, "array")) "maxItems" else "maxLength", .{ .int = @intCast(n) }),
        .one_of => |choices| try target.table.put(arena, "enum", try decoding.encode(arena, choices)),
        .glob => |pattern| try target.table.put(
            arena,
            "pattern",
            .{ .string = try globRegex(arena, pattern) },
        ),
    }
}

/// The regular expression a glob means: anchored, `*` as `.*`, `?` as `.`.
fn globRegex(arena: Allocator, glob: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '^');
    for (glob) |c| switch (c) {
        '*' => try out.appendSlice(arena, ".*"),
        '?' => try out.append(arena, '.'),
        '.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|', '\\' => {
            try out.append(arena, '\\');
            try out.append(arena, c);
        },
        else => try out.append(arena, c),
    };
    try out.append(arena, '$');
    return out.items;
}

/// The glob a regular expression written by `globRegex` came from, or null for any other
/// expression: `validate` checks only patterns it can read.
fn regexGlob(arena: Allocator, regex: []const u8) Allocator.Error!?[]const u8 {
    if (regex.len < 2 or regex[0] != '^' or regex[regex.len - 1] != '$') return null;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    const end = regex.len - 1;
    while (i < end) : (i += 1) {
        const c = regex[i];
        if (c == '\\') {
            i += 1;
            if (i >= end) return null;
            if (regex[i] == '*' or regex[i] == '?') return null; // A glob cannot spell them.
            try out.append(arena, regex[i]);
        } else if (c == '.') {
            if (i + 1 < end and regex[i + 1] == '*') {
                try out.append(arena, '*');
                i += 1;
            } else {
                try out.append(arena, '?');
            }
        } else if (std.mem.indexOfScalar(u8, "+()[]{}^$|*?", c) != null) {
            return null;
        } else {
            try out.append(arena, c);
        }
    }
    return out.items;
}

/// A JSON Schema that `value` (and documents shaped like it) conforms to: each table's
/// keys as `properties`, all `required`; each array's items as one `items` schema, the
/// types of mixed items joined; integers that also appear as floats as `number`. A
/// starting point for a schema to refine by hand.
pub fn infer(arena: Allocator, value: Value) Allocator.Error!Value {
    var root = try inferNode(arena, value);
    var out: Table = .empty;
    try out.put(arena, "$schema", .{ .string = draft });
    var it = root.table.iterator();
    while (it.next()) |entry| try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    root = .{ .table = out };
    return root;
}

fn inferNode(arena: Allocator, value: Value) Allocator.Error!Value {
    var out: Table = .empty;
    switch (value) {
        .table => |t| {
            try out.put(arena, "type", .{ .string = "object" });
            var properties: Table = .empty;
            var required: Array = .empty;
            var it = t.iterator();
            while (it.next()) |entry| {
                const property = try inferNode(arena, entry.value_ptr.*);
                try properties.put(arena, entry.key_ptr.*, property);
                try required.append(arena, .{ .string = entry.key_ptr.* });
            }
            try out.put(arena, "properties", .{ .table = properties });
            if (required.items.len > 0) try out.put(arena, "required", .{ .array = required });
        },
        .array => |a| {
            try out.put(arena, "type", .{ .string = "array" });
            if (a.items.len > 0) {
                var items = try inferNode(arena, a.items[0]);
                for (a.items[1..]) |item| {
                    items = try unite(arena, items, try inferNode(arena, item));
                }
                try out.put(arena, "items", items);
            }
        },
        else => try out.put(arena, "type", .{ .string = typeName(value) }),
    }
    return .{ .table = out };
}

fn typeName(value: Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .int => "integer",
        .float => "number",
        .string => "string",
        .array => "array",
        .table => "object",
    };
}

/// One schema that both `a` and `b`, from `inferNode`, accept.
fn unite(arena: Allocator, a: Value, b: Value) Allocator.Error!Value {
    const ta = a.table.get("type").?.string;
    const tb = b.table.get("type").?.string;
    if (std.mem.eql(u8, ta, tb)) {
        if (std.mem.eql(u8, ta, "object")) {
            // Keys in only one of the two become optional.
            var out = try a.clone(arena);
            const pa = a.table.get("properties").?.table;
            const pb = b.table.get("properties").?.table;
            var properties: Table = .empty;
            var required: Array = .empty;
            var it = pa.iterator();
            while (it.next()) |entry| {
                const other = pb.get(entry.key_ptr.*);
                const mine = entry.value_ptr.*;
                const merged = if (other) |o| try unite(arena, mine, o) else mine;
                try properties.put(arena, entry.key_ptr.*, merged);
                if (other != null) try required.append(arena, .{ .string = entry.key_ptr.* });
            }
            var rest = pb.iterator();
            while (rest.next()) |entry| {
                if (pa.contains(entry.key_ptr.*)) continue;
                try properties.put(arena, entry.key_ptr.*, entry.value_ptr.*);
            }
            try out.table.put(arena, "properties", .{ .table = properties });
            _ = out.table.orderedRemove("required");
            if (required.items.len > 0) {
                try out.table.put(arena, "required", .{ .array = required });
            }
            return out;
        }
        if (std.mem.eql(u8, ta, "array")) {
            var out = try a.clone(arena);
            const ia = a.table.get("items");
            const ib = b.table.get("items");
            if (ia != null and ib != null) {
                try out.table.put(arena, "items", try unite(arena, ia.?, ib.?));
            } else if (ib) |items| {
                try out.table.put(arena, "items", items);
            }
            return out;
        }
        return a;
    }
    // An integer is also a number.
    const numbers = (std.mem.eql(u8, ta, "integer") and std.mem.eql(u8, tb, "number")) or
        (std.mem.eql(u8, ta, "number") and std.mem.eql(u8, tb, "integer"));
    var out: Table = .empty;
    if (numbers) {
        try out.put(arena, "type", .{ .string = "number" });
    } else {
        var types: Array = .empty;
        try types.append(arena, .{ .string = ta });
        try types.append(arena, .{ .string = tb });
        try out.put(arena, "type", .{ .array = types });
    }
    return .{ .table = out };
}

/// How `validate` reads values.
pub const ValidateOptions = struct {
    /// Accept text where the schema wants a number or a boolean, when it reads as one:
    /// values from dotenv, INI, and the environment are always text.
    coerce: bool = true,
};

/// Checks `value` against `schema`, appending a `Diagnostic` (key and message) to
/// `problems`, in `arena`, for each place it does not conform. Returns whether it does.
///
/// Supported: `type` (one or a list), `properties`, `required`, `additionalProperties`
/// (`false` or a schema), `items`, `enum`, `const`, `minimum`, `maximum`,
/// `exclusiveMinimum`, `exclusiveMaximum`, `minLength`, `maxLength`, `minItems`,
/// `maxItems`, `pattern` (the anchored globs `build` writes; other expressions are not
/// checked), and `allOf`, `anyOf`, `oneOf`. Other keywords, `$ref` among them, are ignored.
pub fn validate(
    arena: Allocator,
    schema: Value,
    value: Value,
    options: ValidateOptions,
    problems: *std.ArrayList(Diagnostic),
) Allocator.Error!bool {
    const before = problems.items.len;
    var validator: Validator = .{ .arena = arena, .options = options, .problems = problems };
    try validator.check(schema, value, "");
    return problems.items.len == before;
}

const Validator = struct {
    arena: Allocator,
    options: ValidateOptions,
    problems: *std.ArrayList(Diagnostic),

    fn problem(
        v: *Validator,
        key: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        try v.problems.append(v.arena, .{
            .key = if (key.len == 0) "(root)" else key,
            .message = try std.fmt.allocPrint(v.arena, fmt, args),
        });
    }

    fn check(v: *Validator, schema: Value, value: Value, key: []const u8) Allocator.Error!void {
        if (schema == .bool) {
            if (!schema.bool) try v.problem(key, "no value is allowed here", .{});
            return;
        }
        if (schema != .table) return;
        const s = schema.table;
        if (s.get("type")) |types| {
            if (!try v.typeMatches(types, value)) {
                const expected: TypeList = .{ .types = types };
                try v.problem(key, "expected {f}, found {s}", .{ expected, kindOf(value) });
                return;
            }
        }
        if (s.get("enum")) |choices| if (choices == .array) {
            const found = for (choices.array.items) |choice| {
                if (sameValue(choice, value, v.options)) break true;
            } else false;
            const list: List = .{ .items = choices.array.items };
            if (!found) try v.problem(key, "must be one of {f}", .{list});
        };
        if (s.get("const")) |expected| {
            if (!sameValue(expected, value, v.options)) {
                try v.problem(key, "must be {f}", .{expected});
            }
        }
        if (v.number(value)) |n| try v.bounds(s, n, key);
        if (value == .string) try v.text(s, value.string, key);
        if (value == .array) try v.array(s, value.array.items, key);
        if (value == .table) try v.object(s, value.table, key);
        try v.combinations(s, value, key);
    }

    fn typeMatches(v: *Validator, types: Value, value: Value) Allocator.Error!bool {
        switch (types) {
            .string => |name| return v.isType(name, value),
            .array => |list| {
                for (list.items) |item| {
                    if (item == .string and v.isType(item.string, value)) return true;
                }
                return false;
            },
            else => return true,
        }
    }

    fn isType(v: *const Validator, name: []const u8, value: Value) bool {
        const coerce = v.options.coerce and value == .string;
        if (std.mem.eql(u8, name, "string")) return value == .string;
        if (std.mem.eql(u8, name, "object")) return value == .table;
        if (std.mem.eql(u8, name, "array")) return value == .array;
        if (std.mem.eql(u8, name, "null")) return value == .null;
        if (std.mem.eql(u8, name, "boolean")) {
            return value == .bool or (coerce and parseBool(value.string) != null);
        }
        if (std.mem.eql(u8, name, "integer")) {
            if (value == .int) return true;
            if (value == .float) return @floor(value.float) == value.float;
            return coerce and (std.fmt.parseInt(i64, value.string, 0) catch null) != null;
        }
        if (std.mem.eql(u8, name, "number")) {
            if (value == .int or value == .float) return true;
            return coerce and (std.fmt.parseFloat(f64, value.string) catch null) != null;
        }
        return true; // A type this validator does not know constrains nothing.
    }

    /// `value` as a number, when it is one (or, coercing, text that reads as one).
    fn number(v: *const Validator, value: Value) ?f64 {
        return switch (value) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            .string => |s| if (v.options.coerce) std.fmt.parseFloat(f64, s) catch null else null,
            else => null,
        };
    }

    fn bounds(v: *Validator, s: Table, n: f64, key: []const u8) Allocator.Error!void {
        if (s.get("minimum")) |m| if (v.number(m)) |min| if (n < min) {
            try v.problem(key, "must be at least {d}", .{min});
        };
        if (s.get("maximum")) |m| if (v.number(m)) |max| if (n > max) {
            try v.problem(key, "must be at most {d}", .{max});
        };
        if (s.get("exclusiveMinimum")) |m| if (v.number(m)) |min| if (n <= min) {
            try v.problem(key, "must be more than {d}", .{min});
        };
        if (s.get("exclusiveMaximum")) |m| if (v.number(m)) |max| if (n >= max) {
            try v.problem(key, "must be less than {d}", .{max});
        };
    }

    fn text(v: *Validator, s: Table, string: []const u8, key: []const u8) Allocator.Error!void {
        const counted = std.unicode.utf8CountCodepoints(string) catch string.len;
        const length: f64 = @floatFromInt(counted);
        if (s.get("minLength")) |m| if (v.number(m)) |min| if (length < min) {
            try v.problem(key, "must be at least {d} characters", .{min});
        };
        if (s.get("maxLength")) |m| if (v.number(m)) |max| if (length > max) {
            try v.problem(key, "must be at most {d} characters", .{max});
        };
        if (s.get("pattern")) |p| if (p == .string) {
            const pattern = try regexGlob(v.arena, p.string) orelse return;
            if (!decoding.glob(pattern, string)) try v.problem(key, "must match {s}", .{p.string});
        };
    }

    fn array(v: *Validator, s: Table, items: []const Value, key: []const u8) Allocator.Error!void {
        const count: f64 = @floatFromInt(items.len);
        if (s.get("minItems")) |m| if (v.number(m)) |min| if (count < min) {
            try v.problem(key, "must have at least {d} items", .{min});
        };
        if (s.get("maxItems")) |m| if (v.number(m)) |max| if (count > max) {
            try v.problem(key, "must have at most {d} items", .{max});
        };
        const item_schema = s.get("items") orelse return;
        for (items, 0..) |item, i| {
            const item_key = if (key.len == 0)
                try std.fmt.allocPrint(v.arena, "{d}", .{i})
            else
                try std.fmt.allocPrint(v.arena, "{s}.{d}", .{ key, i });
            try v.check(item_schema, item, item_key);
        }
    }

    fn object(v: *Validator, s: Table, table: Table, key: []const u8) Allocator.Error!void {
        if (s.get("required")) |required| if (required == .array) {
            for (required.array.items) |name| {
                if (name != .string or table.contains(name.string)) continue;
                const missing = try path.join(v.arena, key, name.string);
                try v.problem(missing, "required key is missing", .{});
            }
        };
        const declared = s.get("properties") orelse Value.empty_table;
        const properties: ?Table = if (declared == .table) declared.table else null;
        const additional = s.get("additionalProperties");
        var it = table.iterator();
        while (it.next()) |entry| {
            const child_key = try path.join(v.arena, key, entry.key_ptr.*);
            if (properties) |props| if (props.get(entry.key_ptr.*)) |child_schema| {
                try v.check(child_schema, entry.value_ptr.*, child_key);
                continue;
            };
            const extra = additional orelse continue;
            if (extra == .bool and !extra.bool) {
                const near = if (properties) |props|
                    path.suggest(entry.key_ptr.*, props.keys())
                else
                    null;
                if (near) |name| {
                    try v.problem(child_key, "unknown key; did you mean '{s}'?", .{name});
                } else {
                    try v.problem(child_key, "unknown key", .{});
                }
            } else {
                try v.check(extra, entry.value_ptr.*, child_key);
            }
        }
    }

    /// `allOf`, `anyOf`, `oneOf`: each alternative is checked on its own list of problems.
    fn combinations(v: *Validator, s: Table, value: Value, key: []const u8) Allocator.Error!void {
        if (s.get("allOf")) |all| if (all == .array) {
            for (all.array.items) |sub| try v.check(sub, value, key);
        };
        for ([_][]const u8{ "anyOf", "oneOf" }) |keyword| {
            const alternatives = s.get(keyword) orelse continue;
            if (alternatives != .array) continue;
            var passing: usize = 0;
            for (alternatives.array.items) |sub| {
                var scratch: std.ArrayList(Diagnostic) = .empty;
                var trial: Validator = .{
                    .arena = v.arena,
                    .options = v.options,
                    .problems = &scratch,
                };
                try trial.check(sub, value, key);
                if (scratch.items.len == 0) passing += 1;
            }
            const one = std.mem.eql(u8, keyword, "oneOf");
            if (passing == 0) {
                try v.problem(key, "matches none of the {s} alternatives", .{keyword});
            } else if (one and passing > 1) {
                try v.problem(key, "matches {d} of the oneOf alternatives, not one", .{passing});
            }
        }
    }
};

fn parseBool(text: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |t| {
        if (std.ascii.eqlIgnoreCase(text, t)) return true;
    }
    for ([_][]const u8{ "false", "no", "off", "0" }) |f| {
        if (std.ascii.eqlIgnoreCase(text, f)) return false;
    }
    return null;
}

/// Equality for `enum` and `const`, coercing text to the other side's scalar type.
fn sameValue(expected: Value, value: Value, options: ValidateOptions) bool {
    if (expected.eql(value)) return true;
    if (!options.coerce or value != .string) return false;
    return switch (expected) {
        .int => |i| (std.fmt.parseInt(i64, value.string, 0) catch return false) == i,
        .float => |f| (std.fmt.parseFloat(f64, value.string) catch return false) == f,
        .bool => |b| parseBool(value.string) == b,
        else => false,
    };
}

fn kindOf(value: Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "a boolean",
        .int => "an integer",
        .float => "a number",
        .string => "a string",
        .array => "an array",
        .table => "an object",
    };
}

/// A `type` keyword as prose: `integer`, or `string or null`.
const TypeList = struct {
    types: Value,
    pub fn format(t: TypeList, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (t.types) {
            .string => |s| try w.writeAll(s),
            .array => |a| for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(" or ");
                try w.print("{f}", .{item});
            },
            else => try w.writeAll("?"),
        }
    }
};

/// Values joined with `, `.
const List = struct {
    items: []const Value,
    pub fn format(l: List, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (l.items, 0..) |item, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{f}", .{item});
        }
    }
};

const testing = std.testing;

test "schema for a struct" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Plain = struct {
        port: u16 = 80,
        mode: enum { a, b },
        token: ?[]const u8 = null,
        tags: []const []const u8 = &.{},
    };
    const T = settings_.settings(Plain, field.Set(.{field.Spec(Plain){ .fields = .{
        .port = .{ .help = "Port" },
        .token = .{ .secret = true, .deprecated = "use a key file" },
    } }}), .{});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(T, arena.allocator(), &out.writer);
    try testing.expectEqualStrings(
        \\{
        \\  "$schema": "http://json-schema.org/draft-07/schema#",
        \\  "type": "object",
        \\  "properties": {
        \\    "port": {
        \\      "type": "integer",
        \\      "minimum": 0,
        \\      "maximum": 65535,
        \\      "description": "Port",
        \\      "default": 80
        \\    },
        \\    "mode": {
        \\      "type": "string",
        \\      "enum": [
        \\        "a",
        \\        "b"
        \\      ]
        \\    },
        \\    "token": {
        \\      "type": "string",
        \\      "writeOnly": true,
        \\      "deprecated": true,
        \\      "deprecationMessage": "use a key file"
        \\    },
        \\    "tags": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "default": []
        \\    }
        \\  },
        \\  "required": [
        \\    "mode"
        \\  ]
        \\}
        \\
    , out.written());
}

fn expectSchema(comptime T: type, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(T, arena.allocator(), &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "schema for nested and optional structs, slices of structs, and renames" {
    const Endpoint = struct { url: []const u8, weight: f32 = 1.0 };
    const Plain = struct {
        server: struct { host: []const u8 = "h" } = .{},
        tls: ?struct { cert: []const u8 } = null,
        endpoints: []const Endpoint,
        level: enum { low, high } = .low,
        tls_verify: bool = true,
    };
    const specs = field.Set(.{field.Spec(Plain){ .fields = .{ .tls_verify = .{ .help = "Verify peers" } } }});
    const T = settings_.settings(Plain, specs, .{ .fields = .{ .tls_verify = .{ .key = "tls-verify" } } });
    try expectSchema(T,
        \\{
        \\  "$schema": "http://json-schema.org/draft-07/schema#",
        \\  "type": "object",
        \\  "properties": {
        \\    "server": {
        \\      "type": "object",
        \\      "properties": {
        \\        "host": {
        \\          "type": "string",
        \\          "default": "h"
        \\        }
        \\      },
        \\      "default": {
        \\        "host": "h"
        \\      }
        \\    },
        \\    "tls": {
        \\      "type": "object",
        \\      "properties": {
        \\        "cert": {
        \\          "type": "string"
        \\        }
        \\      },
        \\      "required": [
        \\        "cert"
        \\      ]
        \\    },
        \\    "endpoints": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "url": {
        \\            "type": "string"
        \\          },
        \\          "weight": {
        \\            "type": "number",
        \\            "default": 1.0
        \\          }
        \\        },
        \\        "required": [
        \\          "url"
        \\        ]
        \\      }
        \\    },
        \\    "level": {
        \\      "type": "string",
        \\      "enum": [
        \\        "low",
        \\        "high"
        \\      ],
        \\      "default": "low"
        \\    },
        \\    "tls-verify": {
        \\      "type": "boolean",
        \\      "description": "Verify peers",
        \\      "default": true
        \\    }
        \\  },
        \\  "required": [
        \\    "endpoints"
        \\  ]
        \\}
        \\
    );
}

test "schema for parse-convention types, Value fields, and wide integers" {
    const Plain = struct {
        timeout: @import("scalar.zig").Duration = .{ .ns = std.time.ns_per_s },
        limit: ?@import("scalar.zig").ByteSize = null,
        extra: Value = .null,
        big: u64 = 0,
        huge: i128 = 0,
        signed: i8 = -1,
    };
    const T = settings_.settings(Plain, field.Set(.{field.Spec(Plain){ .fields = .{
        .extra = .{ .help = "Anything" },
    } }}), .{});
    try expectSchema(T,
        \\{
        \\  "$schema": "http://json-schema.org/draft-07/schema#",
        \\  "type": "object",
        \\  "properties": {
        \\    "timeout": {
        \\      "type": "string",
        \\      "description": "text accepted by scalar.Duration.parse",
        \\      "default": "1s"
        \\    },
        \\    "limit": {
        \\      "type": "string",
        \\      "description": "text accepted by scalar.ByteSize.parse"
        \\    },
        \\    "extra": {
        \\      "description": "Anything"
        \\    },
        \\    "big": {
        \\      "type": "integer",
        \\      "minimum": 0,
        \\      "default": 0
        \\    },
        \\    "huge": {
        \\      "type": "integer",
        \\      "default": 0
        \\    },
        \\    "signed": {
        \\      "type": "integer",
        \\      "minimum": -128,
        \\      "maximum": 127,
        \\      "default": -1
        \\    }
        \\  }
        \\}
        \\
    );
}

test "schema build puts $schema first and is a table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tree = try build(struct { a: u8 }, arena.allocator());
    try testing.expectEqualStrings("$schema", tree.table.keys()[0]);
    try testing.expectEqualStrings("a", tree.lookup("required.0").?.string);
}

test "validate: types, required, bounds, enum, and unknown keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try json.parse(a,
        \\{"type": "object", "additionalProperties": false, "required": ["port", "name"],
        \\ "properties": {
        \\   "port": {"type": "integer", "minimum": 1, "maximum": 65535},
        \\   "name": {"type": "string", "minLength": 2, "pattern": "^app\\-.*$"},
        \\   "mode": {"enum": ["fast", "safe"]},
        \\   "tags": {"type": "array", "maxItems": 2, "items": {"type": "string"}},
        \\   "ratio": {"type": ["number", "null"], "exclusiveMaximum": 1},
        \\   "on": {"type": "boolean"}
        \\ }}
    , null);
    var problems: std.ArrayList(Diagnostic) = .empty;
    const good = try json.parse(a,
        \\{"port": "8080", "name": "app-x", "on": "yes", "ratio": null}
    , null);
    try testing.expect(try validate(a, schema, good, .{}, &problems));

    const bad = try json.parse(a,
        \\{"port": 0, "name": "x", "mode": "slow", "tags": ["a", 2, "c"], "ratio": 1, "extra": 1,
        \\ "nmae": "app-y"}
    , null);
    try testing.expect(!try validate(a, schema, bad, .{}, &problems));
    const expected = [_][2][]const u8{
        .{ "port", "must be at least 1" },
        .{ "name", "must be at least 2 characters" },
        .{ "name", "must match ^app\\-.*$" },
        .{ "mode", "must be one of fast, safe" },
        .{ "tags", "must have at most 2 items" },
        .{ "tags.1", "expected string, found an integer" },
        .{ "ratio", "must be less than 1" },
        .{ "extra", "unknown key" },
        .{ "nmae", "unknown key; did you mean 'name'?" },
    };
    try testing.expectEqual(expected.len, problems.items.len);
    for (expected, problems.items) |want, got| {
        try testing.expectEqualStrings(want[0], got.key);
        try testing.expectEqualStrings(want[1], got.message);
    }

    problems.clearRetainingCapacity();
    const strict = try json.parse(a, "{\"port\": \"80\", \"name\": \"app-x\"}", null);
    try testing.expect(!try validate(a, schema, strict, .{ .coerce = false }, &problems));
    try testing.expectEqualStrings("expected integer, found a string", problems.items[0].message);
}

test "validate: missing keys, anyOf, oneOf" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try json.parse(a,
        \\{"required": ["a"], "properties": {"b": {"anyOf": [{"type": "integer"},
        \\ {"type": "boolean"}]}, "c": {"oneOf": [{"minimum": 0}, {"maximum": 10}]}}}
    , null);
    var problems: std.ArrayList(Diagnostic) = .empty;
    const value = try json.parse(a, "{\"b\": \"x\", \"c\": 5}", null);
    try testing.expect(!try validate(a, schema, value, .{ .coerce = false }, &problems));
    try testing.expectEqual(3, problems.items.len);
    try testing.expectEqualStrings("a", problems.items[0].key);
    const none = "matches none of the anyOf alternatives";
    try testing.expectEqualStrings(none, problems.items[1].message);
    const two = "matches 2 of the oneOf alternatives, not one";
    try testing.expectEqualStrings(two, problems.items[2].message);
}

test "a schema built from a struct validates what decode accepts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Plain = struct {
        port: u16 = 80,
        host: []const u8 = "x.example.com",
        ports: []const u16 = &.{},
    };
    const T = settings_.settings(Plain, field.Set(.{field.Spec(Plain){ .fields = .{
        .port = .{ .checks = &.{.min(1024)} },
        .host = .{ .checks = &.{.glob("*.example.com")} },
        .ports = .{ .each = &.{.max(9000)} },
    } }}), .{});
    const schema = try build(T, a);
    var problems: std.ArrayList(Diagnostic) = .empty;
    const value = try json.parse(a,
        \\{"port": 80, "host": "a.example.org", "ports": [1, 9001]}
    , null);
    try testing.expect(!try validate(a, schema, value, .{}, &problems));
    try testing.expectEqual(3, problems.items.len);
    try testing.expectEqualStrings("port", problems.items[0].key);
    try testing.expectEqualStrings("host", problems.items[1].key);
    try testing.expectEqualStrings("ports.1", problems.items[2].key);
}

test "infer a schema that the document validates against" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try json.parse(a,
        \\{"name": "x", "port": 80, "ratios": [1, 2.5],
        \\ "servers": [{"host": "a", "tls": true}, {"host": "b"}], "mixed": ["a", 1]}
    , null);
    const schema = try infer(a, doc);
    var problems: std.ArrayList(Diagnostic) = .empty;
    try testing.expect(try validate(a, schema, doc, .{ .coerce = false }, &problems));
    const ratios = schema.lookup("properties.ratios.items.type").?.string;
    try testing.expectEqualStrings("number", ratios);
    const server = schema.lookup("properties.servers.items").?;
    try testing.expectEqual(1, server.lookup("required").?.array.items.len);
    try testing.expectEqual(2, schema.lookup("properties.mixed.items.type").?.array.items.len);
    // A document of another shape does not conform.
    const other = try json.parse(a, "{\"name\": 1, \"port\": 80}", null);
    try testing.expect(!try validate(a, schema, other, .{ .coerce = false }, &problems));
}

test "schema for a choice: a variant's name, or an object naming it" {
    const T = struct {
        storage: union(enum) { disk: struct { path: []const u8 = "/var" }, memory } = .memory,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try build(T, a);
    var problems: std.ArrayList(Diagnostic) = .empty;
    const goods = [_][]const u8{
        "{\"storage\": \"memory\"}",
        "{\"storage\": {\"disk\": {\"path\": \"/x\"}}}",
    };
    for (goods) |good| {
        try testing.expect(try validate(a, schema, try json.parse(a, good, null), .{}, &problems));
    }
    const bad = try json.parse(a, "{\"storage\": \"tape\"}", null);
    try testing.expect(!try validate(a, schema, bad, .{}, &problems));
}
