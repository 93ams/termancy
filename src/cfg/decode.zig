//! Typed access to a `Value` tree: `decode` fills a Zig type from a tree, `encode` turns a
//! Zig value into a tree.
//!
//! Decoding coerces, because environment variables and flags are always text: `"8080"`
//! decodes into a `u16`, `"a,b"` into a `[]const []const u8`, `"yes"` into a `bool`.
//!
//! A struct may refine its fields with a `pub const meta` declaration:
//!
//! ```zig
//! pub const meta = .{
//!     .password = .{ .secret = true },      // redacted when written
//!     .tls_cert = .{ .key = "certificate" }, // stored under a different key
//!     .port = .{ .help = "Port to listen on", .min = 1024, .max = 49151 },
//!     .level = .{ .one_of = &[_][]const u8{ "debug", "info" } },
//!     .host = .{ .pattern = "*.example.com" }, // `*` and `?` wildcards
//!     .plugins = .{ .merge = .append },      // lists accumulate across files
//!     .timeout = .{ .renamed_from = "request_timeout" }, // the old key still works
//!     .legacy = .{ .deprecated = "set by the server now" }, // read, with a warning
//!     .token = .{ .env = "API_TOKEN" },     // read from $API_TOKEN (`Config` binds it)
//! };
//! ```
//!
//! `.min` and `.max` bound numbers (each element, for a list); `.one_of` and `.pattern`
//! check strings. A struct may also declare `pub fn validate(self: T) ?[]const u8`, for
//! rules across fields: it returns what is wrong, or null.
//!
//! With `Options.errors`, decoding does not stop at the first problem: every one is
//! collected, so a configuration can be fixed in one pass.
//!
//! Options this module does not know are ignored, so one struct can carry metadata for
//! both `cfg` and `cli`. Entries that name no field are a compile error.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const Diagnostic = @import("Diagnostic.zig");
const path = @import("path.zig");

/// What decoding can fail with; the diagnostic names the key.
pub const Error = error{ InvalidValue, MissingField, UnknownField } || Allocator.Error;

/// How `decode` treats unknown keys, bounds, and warnings.
pub const Options = struct {
    /// Reject table keys that no struct field claims.
    strict: bool = false,
    /// Collect every problem here, in the decode arena, instead of stopping at the first.
    /// Decoding still fails, with the first problem's error and in `diag`.
    errors: ?*std.ArrayList(Diagnostic) = null,
    /// Notes on keys read under a name `meta` marks `.renamed_from`, in the decode arena:
    /// `key` is the old name, `message` says which to use instead. Also keys `meta` marks
    /// `.deprecated` that are set: `message` is "deprecated: " and the reason.
    warnings: ?*std.ArrayList(Diagnostic) = null,
};

/// Decodes `value` as a `T`. Slices and strings in the result are allocated in `arena` or
/// borrowed from the tree, so the result lives as long as both. On failure, `diag` names the
/// key and the problem.
pub fn decode(
    comptime T: type,
    arena: Allocator,
    value: Value,
    options: Options,
    diag: ?*Diagnostic,
) Error!T {
    var decoder: Decoder = .{ .arena = arena, .options = options, .diag = diag };
    const result = try decoder.any(T, value, "");
    if (decoder.first) |err| return err;
    return result;
}

const Decoder = struct {
    arena: Allocator,
    options: Options,
    diag: ?*Diagnostic,
    /// The first problem's error, when problems are being collected.
    first: ?Error = null,

    fn fail(d: *Decoder, key: []const u8, err: Error, message: []const u8) Error {
        const problem: Diagnostic = .{
            .key = if (key.len == 0) "(root)" else key,
            .message = message,
        };
        if (d.options.errors) |list| {
            try list.append(d.arena, problem);
            if (d.first == null) {
                d.first = err;
                if (d.diag) |diag| diag.* = problem;
            }
        } else if (d.diag) |diag| {
            diag.* = problem;
        }
        return err;
    }

    /// Whether to keep going after `err`: when collecting problems, any but running out of
    /// memory.
    fn recover(d: *const Decoder, err: Error) bool {
        return d.options.errors != null and err != error.OutOfMemory;
    }

    fn any(d: *Decoder, comptime T: type, value: Value, key: []const u8) Error!T {
        if (T == Value) return value;
        if (comptime hasParse(T)) return d.parsed(T, value, key);
        return switch (@typeInfo(T)) {
            .optional => |o| if (value == .null) null else try d.any(o.child, value, key),
            .bool => d.boolean(value, key),
            .int => d.int(T, value, key),
            .float => d.float(T, value, key),
            .@"enum" => d.enumeration(T, value, key),
            .pointer => |p| {
                if (p.size != .slice) @compileError("cfg cannot decode " ++ @typeName(T));
                if (p.child == u8) return d.string(value, key);
                return d.slice(p.child, value, key);
            },
            .@"struct" => d.structure(T, value, key),
            else => @compileError("cfg cannot decode " ++ @typeName(T)),
        };
    }

    fn boolean(d: *Decoder, value: Value, key: []const u8) Error!bool {
        const message = "expected a boolean";
        switch (value) {
            .bool => |b| return b,
            .string => |s| {
                const truthy = [_][]const u8{ "true", "yes", "on", "1" };
                const falsy = [_][]const u8{ "false", "no", "off", "0" };
                for (truthy) |t| if (std.ascii.eqlIgnoreCase(s, t)) return true;
                for (falsy) |f| if (std.ascii.eqlIgnoreCase(s, f)) return false;
                return d.fail(key, error.InvalidValue, message);
            },
            else => return d.fail(key, error.InvalidValue, message),
        }
    }

    fn int(d: *Decoder, comptime T: type, value: Value, key: []const u8) Error!T {
        const message = "expected an integer of type " ++ @typeName(T);
        const range = "integer out of range for " ++ @typeName(T);
        switch (value) {
            .int => |i| return std.math.cast(T, i) orelse d.fail(key, error.InvalidValue, range),
            .float => |f| {
                if (@floor(f) != f) return d.fail(key, error.InvalidValue, message);
                // `maxInt(T)` may round up to a power of two as an f64 (`2^63` for `i64`),
                // so the upper bound is exclusive: `max + 1` is that power of two either way.
                const max: f64 = @floatFromInt(std.math.maxInt(T));
                const min: f64 = @floatFromInt(std.math.minInt(T));
                if (f >= max + 1 or f < min) return d.fail(key, error.InvalidValue, range);
                return @intFromFloat(f);
            },
            .string => |s| return std.fmt.parseInt(T, std.mem.trim(u8, s, " "), 0) catch |err| {
                return d.fail(
                    key,
                    error.InvalidValue,
                    if (err == error.Overflow) range else message,
                );
            },
            else => return d.fail(key, error.InvalidValue, message),
        }
    }

    fn float(d: *Decoder, comptime T: type, value: Value, key: []const u8) Error!T {
        switch (value) {
            .int => |i| return @floatFromInt(i),
            .float => |f| return @floatCast(f),
            .string => |s| return std.fmt.parseFloat(T, std.mem.trim(u8, s, " ")) catch {
                return d.fail(key, error.InvalidValue, "expected a number");
            },
            else => return d.fail(key, error.InvalidValue, "expected a number"),
        }
    }

    fn enumeration(d: *Decoder, comptime T: type, value: Value, key: []const u8) Error!T {
        const message = "expected one of: " ++ comptime enumNames(T);
        if (value != .string) return d.fail(key, error.InvalidValue, message);
        inline for (@typeInfo(T).@"enum".field_names, 0..) |name, i| {
            if (namesMatch(name, value.string)) {
                return @fromBackingInt(@intCast(@typeInfo(T).@"enum".field_values[i]));
            }
        }
        return d.fail(key, error.InvalidValue, message);
    }

    fn string(d: *Decoder, value: Value, key: []const u8) Error![]const u8 {
        return switch (value) {
            .string => |s| s,
            .int, .float, .bool => std.fmt.allocPrint(d.arena, "{f}", .{value}),
            else => d.fail(key, error.InvalidValue, "expected a string"),
        };
    }

    fn parsed(d: *Decoder, comptime T: type, value: Value, key: []const u8) Error!T {
        const message = "invalid value for " ++ @typeName(T);
        const text = switch (value) {
            .string => |s| s,
            .int, .float => try std.fmt.allocPrint(d.arena, "{f}", .{value}),
            else => return d.fail(key, error.InvalidValue, message),
        };
        return T.parse(text) catch d.fail(key, error.InvalidValue, message);
    }

    fn slice(d: *Decoder, comptime Child: type, value: Value, key: []const u8) Error![]const Child {
        switch (value) {
            .array => |a| {
                const out = try d.arena.alloc(Child, a.items.len);
                for (a.items, out, 0..) |item, *slot, i| {
                    const item_key = if (key.len == 0)
                        try std.fmt.allocPrint(d.arena, "{d}", .{i})
                    else
                        try std.fmt.allocPrint(d.arena, "{s}.{d}", .{ key, i });
                    slot.* = d.any(Child, item, item_key) catch |err| {
                        if (!d.recover(err)) return err;
                        slot.* = undefined; // The decode fails; nothing reads it.
                        continue;
                    };
                }
                return out;
            },
            // ZON spells an empty tuple `.{}`, which reads as an empty table.
            .table => |t| if (t.count() == 0) return &.{} else {
                return d.fail(key, error.InvalidValue, "expected an array");
            },
            .string => |s| {
                // Text from the environment or a flag: a comma-separated list.
                if (std.mem.trim(u8, s, " ").len == 0) return &.{};
                const count = std.mem.countScalar(u8, s, ',') + 1;
                const out = try d.arena.alloc(Child, count);
                var it = std.mem.splitScalar(u8, s, ',');
                for (out) |*slot| {
                    const part = std.mem.trim(u8, it.next().?, " ");
                    slot.* = try d.any(Child, .{ .string = part }, key);
                }
                return out;
            },
            else => return d.fail(key, error.InvalidValue, "expected an array"),
        }
    }

    fn structure(d: *Decoder, comptime T: type, value: Value, key: []const u8) Error!T {
        comptime checkMeta(T);
        if (value != .table) return d.fail(key, error.InvalidValue, "expected a table");
        const info = @typeInfo(T).@"struct";
        var result: T = undefined;
        var failed = false;
        inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
            const field_key = comptime fieldKey(T, name);
            const child_key = try path.join(d.arena, key, field_key);
            if (try d.findOrRenamed(T, name, value.table, key, child_key)) |found| {
                const child = found.value;
                // Problems name the key the value is under, the old one when it was renamed.
                const at = found.key;
                if (comptime metaHas(T, name, "deprecated")) {
                    const reason: []const u8 = @field(T.meta, name).deprecated;
                    if (d.options.warnings) |list| try list.append(d.arena, .{
                        .key = at,
                        .message = try std.fmt.allocPrint(d.arena, "deprecated: {s}", .{reason}),
                    });
                }
                if (d.any(Field, child, at)) |decoded| {
                    @field(result, name) = decoded;
                    d.constrain(T, name, Field, decoded, at) catch |err| {
                        if (!d.recover(err)) return err;
                        failed = true;
                    };
                } else |err| {
                    if (!d.recover(err)) return err;
                    failed = true;
                    @field(result, name) = undefined; // The decode fails; nothing reads it.
                }
            } else if (comptime defaultOf(Field, attrs)) |default| {
                @field(result, name) = default;
            } else if (@typeInfo(Field) == .optional) {
                @field(result, name) = null;
            } else {
                const err = d.fail(child_key, error.MissingField, "required key is missing");
                if (!d.recover(err)) return err;
                failed = true;
                @field(result, name) = undefined;
            }
        }
        if (d.options.strict) d.rejectUnknown(T, value.table, key) catch |err| {
            if (!d.recover(err)) return err;
        };
        // Rules across fields need every field decoded.
        if (!failed and comptime @hasDecl(T, "validate")) {
            const message: ?[]const u8 = result.validate();
            if (message) |text| try d.failRecoverable(key, text);
        }
        return result;
    }

    /// The field's value and the key it is under: its own, or the key `meta` says it was
    /// renamed from, with a warning.
    fn findOrRenamed(
        d: *Decoder,
        comptime T: type,
        comptime name: []const u8,
        table: Table,
        key: []const u8,
        child_key: []const u8,
    ) Error!?struct { value: Value, key: []const u8 } {
        if (findKey(table, comptime fieldKey(T, name))) |child| {
            return .{ .value = child, .key = child_key };
        }
        if (comptime !metaHas(T, name, "renamed_from")) return null;
        const old: []const u8 = @field(T.meta, name).renamed_from;
        const found = (Value{ .table = table }).lookup(old) orelse return null;
        // `old` is a path below this table, not one key.
        const old_key = if (key.len == 0)
            old
        else
            try std.mem.concat(d.arena, u8, &.{ key, ".", old });
        if (d.options.warnings) |list| try list.append(d.arena, .{
            .key = old_key,
            .message = try std.fmt.allocPrint(d.arena, "renamed; use {s}", .{child_key}),
        });
        return .{ .value = found, .key = old_key };
    }

    /// `fail`, but returning normally when problems are being collected.
    fn failRecoverable(d: *Decoder, key: []const u8, message: []const u8) Error!void {
        const err = d.fail(key, error.InvalidValue, message);
        if (!d.recover(err)) return err;
    }

    /// Checks `meta`'s `.min`, `.max`, `.one_of`, and `.pattern` for the field `name`.
    fn constrain(
        d: *Decoder,
        comptime T: type,
        comptime name: []const u8,
        comptime Field: type,
        decoded: Field,
        key: []const u8,
    ) Error!void {
        switch (@typeInfo(Field)) {
            .optional => if (decoded) |inner| {
                return d.constrain(T, name, @typeInfo(Field).optional.child, inner, key);
            },
            .int, .float => {
                const number: f64 = if (@typeInfo(Field) == .int)
                    @floatFromInt(decoded)
                else
                    @floatCast(decoded);
                if (comptime metaHas(T, name, "min")) {
                    const min: f64 = @field(T.meta, name).min;
                    if (number < min) return d.fail(key, error.InvalidValue, try std.fmt.allocPrint(
                        d.arena,
                        "must be at least {d}",
                        .{min},
                    ));
                }
                if (comptime metaHas(T, name, "max")) {
                    const max: f64 = @field(T.meta, name).max;
                    if (number > max) return d.fail(key, error.InvalidValue, try std.fmt.allocPrint(
                        d.arena,
                        "must be at most {d}",
                        .{max},
                    ));
                }
            },
            .pointer => |p| if (p.size == .slice and p.child == u8) {
                if (comptime metaHas(T, name, "one_of")) {
                    const choices: []const []const u8 = @field(T.meta, name).one_of;
                    for (choices) |choice| {
                        if (std.mem.eql(u8, choice, decoded)) break;
                    } else return d.fail(key, error.InvalidValue, try std.fmt.allocPrint(
                        d.arena,
                        "must be one of {s}",
                        .{try std.mem.join(d.arena, ", ", choices)},
                    ));
                }
                if (comptime metaHas(T, name, "pattern")) {
                    const pattern: []const u8 = @field(T.meta, name).pattern;
                    if (!glob(pattern, decoded)) return d.fail(
                        key,
                        error.InvalidValue,
                        try std.fmt.allocPrint(d.arena, "must match {s}", .{pattern}),
                    );
                }
            } else if (p.size == .slice) {
                for (decoded, 0..) |item, i| {
                    const item_key = try std.fmt.allocPrint(d.arena, "{s}.{d}", .{ key, i });
                    try d.constrain(T, name, p.child, item, item_key);
                }
            },
            else => {},
        }
    }

    fn rejectUnknown(d: *Decoder, comptime T: type, table: Table, key: []const u8) Error!void {
        var it = table.iterator();
        outer: while (it.next()) |entry| {
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                if (namesMatch(comptime fieldKey(T, name), entry.key_ptr.*)) continue :outer;
                // A key the field was renamed from is known too, while it is still read.
                if (comptime metaHas(T, name, "renamed_from")) {
                    var segments = path.iterate(@field(T.meta, name).renamed_from);
                    const first = segments.next() catch null;
                    if (first != null and namesMatch(first.?.text, entry.key_ptr.*)) {
                        continue :outer;
                    }
                }
            }
            const unknown_key = try path.join(d.arena, key, entry.key_ptr.*);
            return d.fail(unknown_key, error.UnknownField, "unknown key");
        }
    }
};

/// What encoding can fail with: a value no tree can hold.
pub const EncodeError = error{Unrepresentable} || Allocator.Error;

/// Encodes a Zig value as a tree in `arena`. Optional fields that are `null` are left out
/// of tables, since most formats cannot spell null. Types with a `format` method and a
/// `parse` function encode as their text.
pub fn encode(arena: Allocator, value: anytype) EncodeError!Value {
    const T = @TypeOf(value);
    if (T == Value) return value.clone(arena);
    if (comptime hasParse(T) and std.meta.hasMethod(T, "format")) {
        return .{ .string = try std.fmt.allocPrint(arena, "{f}", .{value}) };
    }
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| encode(arena, v) else .null,
        .bool => .{ .bool = value },
        .int, .comptime_int => if (std.math.cast(i64, value)) |i|
            .{ .int = i }
        else
            error.Unrepresentable,
        .float, .comptime_float => .{ .float = value },
        .@"enum" => .{ .string = @tagName(value) },
        .enum_literal => .{ .string = @tagName(value) },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8)
                .{ .string = try arena.dupe(u8, value) }
            else
                encodeSlice(arena, value),
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8)
                    .{ .string = try arena.dupe(u8, value) }
                else
                    encodeSlice(arena, @as([]const a.child, value)),
                else => encode(arena, value.*),
            },
            else => @compileError("cfg cannot encode " ++ @typeName(T)),
        },
        .@"struct" => encodeStruct(arena, value),
        else => @compileError("cfg cannot encode " ++ @typeName(T)),
    };
}

fn encodeSlice(arena: Allocator, items: anytype) EncodeError!Value {
    var array: Array = try .initCapacity(arena, items.len);
    for (items) |item| array.appendAssumeCapacity(try encode(arena, item));
    return .{ .array = array };
}

fn encodeStruct(arena: Allocator, value: anytype) EncodeError!Value {
    const T = @TypeOf(value);
    comptime checkMeta(T);
    var table: Table = .empty;
    inline for (
        @typeInfo(T).@"struct".field_names,
        @typeInfo(T).@"struct".field_types,
    ) |name, Field| {
        const field = @field(value, name);
        const skip = @typeInfo(Field) == .optional and field == null;
        if (!skip) try table.put(arena, comptime fieldKey(T, name), try encode(arena, field));
    }
    return .{ .table = table };
}

/// The dotted key of every field of `T`, recursively, that `meta` marks `.secret = true`.
pub fn secretKeys(comptime T: type) []const []const u8 {
    return comptime blk: {
        var keys: []const []const u8 = &.{};
        collectSecrets(T, "", &keys);
        break :blk keys;
    };
}

fn collectSecrets(
    comptime T: type,
    comptime prefix: []const u8,
    comptime keys: *[]const []const u8,
) void {
    const Base = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (@typeInfo(Base) != .@"struct" or hasParse(Base) or Base == Value) return;
    for (
        @typeInfo(Base).@"struct".field_names,
        @typeInfo(Base).@"struct".field_types,
    ) |name, Field| {
        const key = (if (prefix.len == 0) "" else prefix ++ ".") ++ fieldKey(Base, name);
        if (metaOption(Base, name, "secret", false)) {
            keys.* = keys.* ++ .{key};
        } else {
            collectSecrets(Field, key, keys);
        }
    }
}

/// A key and the environment variable `meta` names for it with `.env`.
pub const EnvBinding = struct { key: []const u8, env: []const u8 };

/// The dotted key of every field of `T`, recursively, that `meta` gives an `.env` name,
/// with that name. `cli` reads the same option for a flag, so one struct can name the
/// variable for both.
pub fn envBindings(comptime T: type) []const EnvBinding {
    return comptime blk: {
        var bindings: []const EnvBinding = &.{};
        collectEnvBindings(T, "", &bindings);
        break :blk bindings;
    };
}

fn collectEnvBindings(
    comptime T: type,
    comptime prefix: []const u8,
    comptime bindings: *[]const EnvBinding,
) void {
    const Base = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (@typeInfo(Base) != .@"struct" or hasParse(Base) or Base == Value) return;
    for (
        @typeInfo(Base).@"struct".field_names,
        @typeInfo(Base).@"struct".field_types,
    ) |name, Field| {
        const key = (if (prefix.len == 0) "" else prefix ++ ".") ++ fieldKey(Base, name);
        const env = metaOption(Base, name, "env", @as(?[]const u8, null));
        if (env) |variable| {
            bindings.* = bindings.* ++ .{EnvBinding{ .key = key, .env = variable }};
        } else {
            collectEnvBindings(Field, key, bindings);
        }
    }
}

/// The keys whose `meta` sets `.merge = .append`, recursively.
pub fn appendKeys(comptime T: type) []const []const u8 {
    return comptime blk: {
        var keys: []const []const u8 = &.{};
        collectAppends(T, "", &keys);
        break :blk keys;
    };
}

fn collectAppends(
    comptime T: type,
    comptime prefix: []const u8,
    comptime keys: *[]const []const u8,
) void {
    const Base = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (@typeInfo(Base) != .@"struct" or hasParse(Base) or Base == Value) return;
    for (
        @typeInfo(Base).@"struct".field_names,
        @typeInfo(Base).@"struct".field_types,
    ) |name, Field| {
        const key = (if (prefix.len == 0) "" else prefix ++ ".") ++ fieldKey(Base, name);
        const merge = metaOption(Base, name, "merge", .replace);
        if (merge == .append) {
            keys.* = keys.* ++ .{key};
        } else {
            collectAppends(Field, key, keys);
        }
    }
}

/// Whether `T.meta.<field>` sets `option`.
pub fn metaHas(comptime T: type, comptime field: []const u8, comptime option: []const u8) bool {
    if (!@hasDecl(T, "meta")) return false;
    if (!@hasField(@TypeOf(T.meta), field)) return false;
    return @hasField(@TypeOf(@field(T.meta, field)), option);
}

/// Whether `text` matches `pattern`, where `*` matches any run of bytes and `?` one byte.
pub fn glob(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    // Where to resume after a mismatch: the last `*` and the text position it covers to.
    var star: ?usize = null;
    var star_text: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_text = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_text += 1;
            t = star_text;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Whether `T` follows the `parse` convention: a declaration `pub fn parse(text: []const u8)`
/// returning `T` or an error union of `T`. The signature is checked, not just the name, so
/// an unrelated method called `parse` does not count.
pub fn hasParse(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => {},
        else => return false,
    }
    if (!@hasDecl(T, "parse")) return false;
    const info = switch (@typeInfo(@TypeOf(T.parse))) {
        .@"fn" => |f| f,
        else => return false,
    };
    if (info.param_types.len != 1 or info.param_types[0] != []const u8) return false;
    const Return = info.return_type orelse return false;
    return Return == T or
        (@typeInfo(Return) == .error_union and @typeInfo(Return).error_union.payload == T);
}

/// The value of `option` in `T.meta.<field>`, or `default` when absent.
pub fn metaOption(
    comptime T: type,
    comptime field: []const u8,
    comptime option: []const u8,
    comptime default: anytype,
) @TypeOf(default) {
    if (!@hasDecl(T, "meta")) return default;
    if (!@hasField(@TypeOf(T.meta), field)) return default;
    const entry = @field(T.meta, field);
    if (!@hasField(@TypeOf(entry), option)) return default;
    return @field(entry, option);
}

fn checkMeta(comptime T: type) void {
    if (!@hasDecl(T, "meta")) return;
    for (@typeInfo(@TypeOf(T.meta)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) {
            @compileError(@typeName(T) ++ ".meta names no field '" ++ name ++ "'");
        }
    }
}

fn fieldKey(comptime T: type, comptime name: []const u8) []const u8 {
    return metaOption(T, name, "key", @as([]const u8, name));
}

fn defaultOf(comptime Field: type, comptime attrs: std.builtin.Type.Struct.FieldAttributes) ?Field {
    const ptr = attrs.default_value_ptr orelse return null;
    return @as(*const Field, @ptrCast(@alignCast(ptr))).*;
}

/// Finds `name` in `table` exactly, or else ignoring case and treating `-` and `_` alike, so
/// that `tls-cert`, `TLS_CERT`, and `tls_cert` all reach a field named `tls_cert`.
fn findKey(table: Table, name: []const u8) ?Value {
    if (table.get(name)) |v| return v;
    var it = table.iterator();
    while (it.next()) |entry| {
        if (namesMatch(name, entry.key_ptr.*)) return entry.value_ptr.*;
    }
    return null;
}

fn namesMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '-') '_' else std.ascii.toLower(x);
        const ny = if (y == '-') '_' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

fn enumNames(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (@typeInfo(T).@"enum".field_names, 0..) |name, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ name;
    }
    return out;
}

const testing = std.testing;
const json = @import("json.zig");
const zon = @import("zon.zig");
const scalar = @import("scalar.zig");

const Server = struct {
    host: []const u8 = "localhost",
    port: u16,
    mode: enum { dev, prod } = .dev,
    tags: []const []const u8 = &.{},
    timeout: scalar.Duration = .{ .ns = std.time.ns_per_s },
    tls: ?struct { cert: []const u8, key: []const u8 } = null,
    password: ?[]const u8 = null,
    tls_verify: bool = true,

    pub const meta = .{
        .password = .{ .secret = true, .help = "unused by cfg" },
        .tls_verify = .{ .short = 'k' },
    };
};

fn decodeJson(comptime T: type, arena: Allocator, source: []const u8, diag: ?*Diagnostic) !T {
    return decode(T, arena, try json.parse(arena, source, null), .{}, diag);
}

test "decode a struct with defaults, optionals, and nesting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try decodeJson(Server, arena.allocator(),
        \\{"port": 80, "mode": "prod", "tags": ["a", "b"], "timeout": "1m",
        \\ "tls": {"cert": "c.pem", "key": "k.pem"}, "TLS-VERIFY": "no"}
    , null);
    try testing.expectEqualStrings("localhost", s.host);
    try testing.expectEqual(80, s.port);
    try testing.expectEqual(.prod, s.mode);
    try testing.expectEqual(2, s.tags.len);
    try testing.expectEqualStrings("b", s.tags[1]);
    try testing.expectEqual(std.time.ns_per_min, s.timeout.ns);
    try testing.expectEqualStrings("c.pem", s.tls.?.cert);
    try testing.expectEqual(null, s.password);
    try testing.expectEqual(false, s.tls_verify);
}

test "decode coerces text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try decodeJson(Server, arena.allocator(),
        \\{"port": "0x50", "tags": "x, y,z", "host": 5}
    , null);
    try testing.expectEqual(80, s.port);
    try testing.expectEqual(3, s.tags.len);
    try testing.expectEqualStrings("y", s.tags[1]);
    try testing.expectEqualStrings("5", s.host);
}

test "decode errors name the key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, anyerror, []const u8, []const u8 }{
        .{ "{}", error.MissingField, "port", "required key is missing" },
        .{ "{\"port\": 70000}", error.InvalidValue, "port", "integer out of range for u16" },
        .{ "{\"port\": \"x\"}", error.InvalidValue, "port", "expected an integer of type u16" },
        .{
            "{\"port\": 1, \"mode\": \"qa\"}",
            error.InvalidValue,
            "mode",
            "expected one of: dev, prod",
        },
        .{
            "{\"port\": 1, \"tls\": {\"cert\": \"c\"}}",
            error.MissingField,
            "tls.key",
            "required key is missing",
        },
        .{ "{\"port\": 1, \"tags\": [1, {}]}", error.InvalidValue, "tags.1", "expected a string" },
        .{
            "{\"port\": 1, \"timeout\": \"soon\"}",
            error.InvalidValue,
            "timeout",
            "invalid value for scalar.Duration",
        },
        .{ "[]", error.InvalidValue, "(root)", "expected a table" },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try testing.expectError(case[1], decodeJson(Server, a, case[0], &diag));
        try testing.expectEqualStrings(case[2], diag.key);
        try testing.expectEqualStrings(case[3], diag.message);
    }
}

test "strict decoding rejects unknown keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try json.parse(a, "{\"port\": 1, \"prot\": 2}", null);
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.UnknownField,
        decode(Server, a, tree, .{ .strict = true }, &diag),
    );
    try testing.expectEqualStrings("prot", diag.key);
    _ = try decode(Server, a, tree, .{}, null);
}

test "decode booleans and floats from text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(true, try decode(bool, a, .{ .string = "YES" }, .{}, null));
    try testing.expectEqual(2.5, try decode(f32, a, .{ .string = "2.5" }, .{}, null));
    try testing.expectEqual(3, try decode(u8, a, .{ .float = 3.0 }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(u8, a, .{ .float = 3.5 }, .{}, null));
    try testing.expectEqual(null, try decode(?u8, a, .null, .{}, null));
}

test "a Value field passes through" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const T = struct { extra: Value };
    const t = try decodeJson(T, arena.allocator(), "{\"extra\": {\"x\": [1]}}", null);
    try testing.expectEqual(1, t.extra.lookup("x.0").?.int);
}

test "meta keys rename fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const T = struct {
        cert: []const u8,
        pub const meta = .{ .cert = .{ .key = "certificate" } };
    };
    const t = try decodeJson(T, arena.allocator(), "{\"certificate\": \"x\"}", null);
    try testing.expectEqualStrings("x", t.cert);
}

test "encode round-trips through decode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Server = .{
        .port = 443,
        .mode = .prod,
        .tags = &.{ "x", "y" },
        .timeout = .{ .ns = 90 * std.time.ns_per_s },
        .tls = .{ .cert = "c", .key = "k" },
    };
    const tree = try encode(a, original);
    try testing.expectEqualStrings("1m30s", tree.lookup("timeout").?.string);
    try testing.expectEqual(null, tree.lookup("password"));
    const back = try decode(Server, a, tree, .{ .strict = true }, null);
    try testing.expectEqual(443, back.port);
    try testing.expectEqualStrings("k", back.tls.?.key);
    try testing.expectEqual(original.timeout, back.timeout);
}

test "encode literals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("hi", (try encode(a, "hi")).string);
    try testing.expectEqual(5, (try encode(a, 5)).int);
    try testing.expectError(error.Unrepresentable, encode(a, @as(u64, std.math.maxInt(u64))));
    const list = try encode(a, &[_]u16{ 1, 2 });
    try testing.expectEqual(2, list.array.items[1].int);
}

test secretKeys {
    const Root = struct {
        server: Server,
        db: struct {
            url: []const u8,
            pub const meta = .{ .url = .{ .secret = true } };
        },
    };
    const keys = comptime secretKeys(Root);
    try testing.expectEqual(2, keys.len);
    try testing.expectEqualStrings("server.password", keys[0]);
    try testing.expectEqualStrings("db.url", keys[1]);
}

test "integers from floats at the edges of their range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `maxInt(i64)` rounds to 2^63 as an f64; 2^63 itself must be out of range, not a
    // safety panic in `@intFromFloat`.
    const two_63: f64 = 9223372036854775808.0;
    try testing.expectError(error.InvalidValue, decode(i64, a, .{ .float = two_63 }, .{}, null));
    try testing.expectError(
        error.InvalidValue,
        decode(u64, a, .{ .float = 2 * two_63 }, .{}, null),
    );
    try testing.expectEqual(1 << 62, try decode(i64, a, .{ .float = two_63 / 2 }, .{}, null));
    try testing.expectEqual(
        std.math.minInt(i64),
        try decode(i64, a, .{ .float = -two_63 }, .{}, null),
    );
    try testing.expectEqual(
        @as(u64, 1) << 63,
        try decode(u64, a, .{ .float = two_63 }, .{}, null),
    );
    try testing.expectEqual(255, try decode(u8, a, .{ .float = 255 }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(u8, a, .{ .float = 256 }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(u8, a, .{ .float = -1 }, .{}, null));
    try testing.expectEqual(-128, try decode(i8, a, .{ .float = -128 }, .{}, null));
    try testing.expectEqual(0, try decode(u8, a, .{ .float = -0.0 }, .{}, null));
    const odd = [_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), 0.5 };
    for (odd) |f| {
        try testing.expectError(error.InvalidValue, decode(i64, a, .{ .float = f }, .{}, null));
    }
}

test "integers from text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(42, try decode(u8, a, .{ .string = " 42 " }, .{}, null));
    try testing.expectEqual(-5, try decode(i8, a, .{ .string = "-5" }, .{}, null));
    try testing.expectEqual(8, try decode(u8, a, .{ .string = "0o10" }, .{}, null));
    try testing.expectEqual(5, try decode(u8, a, .{ .string = "0b101" }, .{}, null));
    // `std.fmt.parseInt` takes `_` separators, as TOML does.
    try testing.expectEqual(1000, try decode(u16, a, .{ .string = "1_000" }, .{}, null));
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, decode(u8, a, .{ .string = "256" }, .{}, &diag));
    try testing.expectEqualStrings("integer out of range for u8", diag.message);
    try testing.expectError(error.InvalidValue, decode(u8, a, .{ .string = "" }, .{}, &diag));
    try testing.expectEqualStrings("expected an integer of type u8", diag.message);
    try testing.expectError(error.InvalidValue, decode(u8, a, .{ .string = "1.0" }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(u8, a, .{ .bool = true }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(u8, a, .null, .{}, null));
    try testing.expectError(
        error.InvalidValue,
        decode(i64, a, .{ .string = "9223372036854775808" }, .{}, null),
    );
}

test "booleans accept text but not numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "true", "On", "1", "YES" }) |text| {
        try testing.expectEqual(true, try decode(bool, a, .{ .string = text }, .{}, null));
    }
    for ([_][]const u8{ "false", "OFF", "0", "No" }) |text| {
        try testing.expectEqual(false, try decode(bool, a, .{ .string = text }, .{}, null));
    }
    // Only text is coerced: a YAML or JSON `1` is a number, not a boolean.
    try testing.expectError(error.InvalidValue, decode(bool, a, .{ .int = 1 }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(bool, a, .{ .string = "" }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(bool, a, .{ .string = "y" }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(bool, a, .null, .{}, null));
}

test "floats from numbers and text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(3.0, try decode(f64, a, .{ .int = 3 }, .{}, null));
    try testing.expectEqual(-0.25, try decode(f32, a, .{ .string = " -0.25 " }, .{}, null));
    try testing.expect(std.math.isInf(try decode(f32, a, .{ .float = 1e300 }, .{}, null)));
    try testing.expect(std.math.isInf(try decode(f64, a, .{ .string = "inf" }, .{}, null)));
    try testing.expectError(error.InvalidValue, decode(f64, a, .{ .bool = false }, .{}, null));
    try testing.expectError(error.InvalidValue, decode(f64, a, .{ .string = "1,5" }, .{}, null));
}

test "enums match names loosely and only from text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Level = enum(u8) { debug = 10, info, very_loud = 99 };
    try testing.expectEqual(.info, try decode(Level, a, .{ .string = "INFO" }, .{}, null));
    try testing.expectEqual(
        .very_loud,
        try decode(Level, a, .{ .string = "very-loud" }, .{}, null),
    );
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, decode(Level, a, .{ .int = 10 }, .{}, &diag));
    try testing.expectEqualStrings("expected one of: debug, info, very_loud", diag.message);
    try testing.expectError(error.InvalidValue, decode(Level, a, .{ .string = "" }, .{}, null));
}

test "strings from scalars, not from containers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("true", try decode([]const u8, a, .{ .bool = true }, .{}, null));
    try testing.expectEqualStrings("-7", try decode([]const u8, a, .{ .int = -7 }, .{}, null));
    try testing.expectEqualStrings("2.5", try decode([]const u8, a, .{ .float = 2.5 }, .{}, null));
    try testing.expectError(error.InvalidValue, decode([]const u8, a, .null, .{}, null));
    try testing.expectError(error.InvalidValue, decode([]const u8, a, .empty_table, .{}, null));
    try testing.expectError(
        error.InvalidValue,
        decode([]const u8, a, .{ .array = .empty }, .{}, null),
    );
}

test "slices from arrays and comma-separated text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ports = try decode([]const u16, a, .{ .string = "80, 443,8080" }, .{}, null);
    try testing.expectEqualSlices(u16, &.{ 80, 443, 8080 }, ports);
    try testing.expectEqual(0, (try decode([]const u16, a, .{ .string = "  " }, .{}, null)).len);
    const parts = try decode([]const []const u8, a, .{ .string = "a,,b," }, .{}, null);
    try testing.expectEqual(4, parts.len);
    try testing.expectEqualStrings("", parts[1]);
    try testing.expectEqualStrings("", parts[3]);
    // An optional slice decodes from text as well, and from null.
    const maybe = try decode(?[]const u8, a, .{ .string = "x" }, .{}, null);
    try testing.expectEqualStrings("x", maybe.?);
    const list = try decode(?[]const []const u8, a, .{ .string = "x,y" }, .{}, null);
    try testing.expectEqualStrings("y", list.?[1]);
    try testing.expectEqual(null, try decode(?[]const []const u8, a, .null, .{}, null));
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.InvalidValue,
        decode([]const u16, a, .{ .string = "1,x" }, .{}, &diag),
    );
    try testing.expectError(error.InvalidValue, decode([]const u16, a, .{ .int = 1 }, .{}, &diag));
    try testing.expectEqualStrings("expected an array", diag.message);
    // Nested slices from nested arrays.
    const tree = try json.parse(a, "[[1, 2], [], [3]]", null);
    const nested = try decode([]const []const u8, a, try json.parse(a, "[\"a\"]", null), .{}, null);
    try testing.expectEqualStrings("a", nested[0]);
    const grid = try decode([]const []const i32, a, tree, .{}, null);
    try testing.expectEqual(3, grid.len);
    try testing.expectEqual(0, grid[1].len);
    try testing.expectEqual(3, grid[2][0]);
}

test "an empty table decodes as an empty slice, as ZON's .{} reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct { tags: []const []const u8 = &.{"x"}, ports: []const u16 };
    const tree = try zon.parse(a, ".{ .tags = .{}, .ports = .{} }", null);
    const t = try decode(T, a, tree, .{}, null);
    try testing.expectEqual(0, t.tags.len);
    try testing.expectEqual(0, t.ports.len);
    var diag: Diagnostic = .{};
    const full = try zon.parse(a, ".{ .ports = .{ .a = 1 } }", null);
    try testing.expectError(error.InvalidValue, decode(T, a, full, .{}, &diag));
    try testing.expectEqualStrings("ports", diag.key);
    try testing.expectEqualStrings("expected an array", diag.message);
}

test "an item of a root array is named by its index alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const tree = try json.parse(a, "[1, \"x\"]", null);
    try testing.expectError(error.InvalidValue, decode([]const u8, a, tree, .{}, &diag));
    try testing.expectEqualStrings("(root)", diag.key);
    try testing.expectError(error.InvalidValue, decode([]const u16, a, tree, .{}, &diag));
    // Was ".1", which is not a valid path.
    try testing.expectEqualStrings("1", diag.key);
    const nested = try json.parse(a, "{\"t\": [[0], [1, true]]}", null);
    const T = struct { t: []const []const u16 };
    try testing.expectError(error.InvalidValue, decode(T, a, nested, .{}, &diag));
    try testing.expectEqualStrings("t.1.1", diag.key);
}

test "parse-convention types from numbers and text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(
        1024,
        (try decode(scalar.ByteSize, a, .{ .int = 1024 }, .{}, null)).bytes,
    );
    try testing.expectEqual(
        1,
        (try decode(scalar.ByteSize, a, .{ .float = 1.5 }, .{}, null)).bytes,
    );
    try testing.expectEqual(0, (try decode(scalar.Duration, a, .{ .int = 0 }, .{}, null)).ns);
    // A bare number has no unit, which a duration needs.
    try testing.expectError(
        error.InvalidValue,
        decode(scalar.Duration, a, .{ .int = 5 }, .{}, null),
    );
    try testing.expectError(
        error.InvalidValue,
        decode(scalar.ByteSize, a, .{ .bool = true }, .{}, null),
    );
    try testing.expectError(
        error.InvalidValue,
        decode(scalar.ByteSize, a, .empty_table, .{}, null),
    );
    const d = try decode(?scalar.Duration, a, .{ .string = "2m" }, .{}, null);
    try testing.expectEqual(2 * std.time.ns_per_min, d.?.ns);
}

test "structs: required, optional, defaults, nesting, strictness" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Inner = struct { x: u8 = 1, y: ?u8 = null };
    const Outer = struct {
        inner: Inner = .{},
        maybe: ?Inner = null,
        list: []const Inner = &.{},
        renamed: bool = false,
        pub const meta = .{ .renamed = .{ .key = "is-renamed" } };
    };
    const empty = try decode(Outer, a, .empty_table, .{ .strict = true }, null);
    try testing.expectEqual(1, empty.inner.x);
    try testing.expectEqual(null, empty.maybe);
    try testing.expectEqual(0, empty.list.len);
    const full = try decode(Outer, a, try json.parse(a,
        \\{"inner": {"y": 3}, "maybe": {"x": 9}, "list": [{}, {"x": 2}], "IS_RENAMED": "on"}
    , null), .{ .strict = true }, null);
    try testing.expectEqual(3, full.inner.y.?);
    try testing.expectEqual(9, full.maybe.?.x);
    try testing.expectEqual(2, full.list[1].x);
    try testing.expect(full.renamed);
    const null_tree = try json.parse(a, "{\"maybe\": null}", null);
    const explicit_null = try decode(Outer, a, null_tree, .{}, null);
    try testing.expectEqual(null, explicit_null.maybe);

    var diag: Diagnostic = .{};
    const unknown = try json.parse(a, "{\"inner\": {\"z\": 1}}", null);
    try testing.expectError(
        error.UnknownField,
        decode(Outer, a, unknown, .{ .strict = true }, &diag),
    );
    try testing.expectEqualStrings("inner.z", diag.key);
    // The field's own name is unknown once `meta` renames it.
    const old_name = try json.parse(a, "{\"renamed\": true}", null);
    try testing.expectError(
        error.UnknownField,
        decode(Outer, a, old_name, .{ .strict = true }, &diag),
    );
    try testing.expectError(error.InvalidValue, decode(Outer, a, .{ .string = "x" }, .{}, &diag));
    try testing.expectEqualStrings("(root)", diag.key);
    const in_list = try json.parse(a, "{\"list\": [{\"x\": \"big\"}]}", null);
    try testing.expectError(error.InvalidValue, decode(Outer, a, in_list, .{}, &diag));
    try testing.expectEqualStrings("list.0.x", diag.key);
}

test "a key that needs quoting is quoted in diagnostics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct {
        port: u16,
        pub const meta = .{ .port = .{ .key = "http.port" } };
    };
    var diag: Diagnostic = .{};
    const tree = try json.parse(a, "{\"http.port\": \"x\"}", null);
    try testing.expectError(error.InvalidValue, decode(T, a, tree, .{}, &diag));
    try testing.expectEqualStrings("\"http.port\"", diag.key);
    try testing.expectEqual(
        80,
        (try decode(T, a, try json.parse(a, "{\"http.port\": 80}", null), .{}, null)).port,
    );
}

test "encode optionals, pointers, enums, and renamed fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The outer optional decides whether a field is written; an inner null encodes as null.
    const inner_null: ??u8 = @as(?u8, null);
    try testing.expectEqual(Value.null, try encode(a, inner_null));
    try testing.expectEqual(Value.null, try encode(a, @as(??u8, null)));
    try testing.expectEqual(4, (try encode(a, @as(??u8, 4))).int);
    const T = struct {
        a: ??u8 = @as(?u8, null),
        b: ?u8 = null,
        c: enum { x, y } = .y,
        d: f32 = 0.5,
        pub const meta = .{ .c = .{ .key = "kind" } };
    };
    const tree = try encode(a, T{});
    try testing.expectEqual(Value.null, tree.lookup("a").?);
    try testing.expectEqual(null, tree.lookup("b"));
    try testing.expectEqualStrings("y", tree.lookup("kind").?.string);
    try testing.expectEqual(0.5, tree.lookup("d").?.float);
    const t: T = .{};
    try testing.expectEqual(3, (try encode(a, &t)).table.count()); // Through a pointer.
    try testing.expectEqualStrings("lit", (try encode(a, .lit)).string);
    try testing.expectEqual(1.5, (try encode(a, 1.5)).float);
    try testing.expectError(error.Unrepresentable, encode(a, @as(i128, std.math.minInt(i128))));
    const list = try encode(a, @as([]const []const u8, &.{ "p", "q" }));
    try testing.expectEqualStrings("q", list.array.items[1].string);
    var original: Value = .empty_table;
    try original.put(a, "k", .{ .string = "v" });
    const copy = try encode(a, original);
    try original.put(a, "k", .{ .string = "changed" });
    try testing.expectEqualStrings("v", copy.lookup("k").?.string);
}

test hasParse {
    const WrongArgument = struct {
        pub fn parse(_: u8) @This() {
            return .{};
        }
    };
    const WrongReturn = struct {
        pub fn parse(_: []const u8) bool {
            return true;
        }
    };
    const NotAFunction = struct {
        pub const parse = 1;
    };
    const Plain = struct {
        pub fn parse(_: []const u8) @This() {
            return .{};
        }
    };
    try testing.expect(!hasParse(WrongArgument));
    try testing.expect(!hasParse(WrongReturn));
    try testing.expect(!hasParse(NotAFunction));
    try testing.expect(!hasParse(u8));
    try testing.expect(hasParse(Plain));
    try testing.expect(hasParse(scalar.Duration));
}

test envBindings {
    const Root = struct {
        db: ?struct {
            url: []const u8 = "",
            pass: []const u8 = "",
            pub const meta = .{ .pass = .{ .env = "DB_PASSWORD", .key = "password" } };
        } = null,
        port: u16 = 0,
        pub const meta = .{ .port = .{ .env = "PORT", .help = "for cli too" } };
    };
    const bindings = comptime envBindings(Root);
    try std.testing.expectEqual(2, bindings.len);
    try std.testing.expectEqualStrings("db.password", bindings[0].key);
    try std.testing.expectEqualStrings("DB_PASSWORD", bindings[0].env);
    try std.testing.expectEqualStrings("port", bindings[1].key);
    try std.testing.expectEqualStrings("PORT", bindings[1].env);
}

test "secretKeys follows optionals and renames, and stops at leaves" {
    const T = struct {
        db: ?struct {
            pass: []const u8,
            pub const meta = .{ .pass = .{ .secret = true, .key = "password" } };
        } = null,
        timeout: scalar.Duration = .zero,
        raw: Value = .null,
        whole: struct { x: u8 } = .{ .x = 0 },
        pub const meta = .{ .whole = .{ .secret = true } };
    };
    const keys = comptime secretKeys(T);
    try testing.expectEqual(2, keys.len);
    try testing.expectEqualStrings("db.password", keys[0]);
    try testing.expectEqualStrings("whole", keys[1]);
}

const Constrained = struct {
    port: u16 = 8080,
    ports: []const u16 = &.{},
    ratio: ?f64 = null,
    level: []const u8 = "info",
    host: []const u8 = "a.example.com",
    low: u8 = 0,
    high: u8 = 10,

    pub const meta = .{
        .port = .{ .min = 1024, .max = 49151 },
        .ports = .{ .min = 1 },
        .ratio = .{ .max = 1 },
        .level = .{ .one_of = &[_][]const u8{ "debug", "info" } },
        .host = .{ .pattern = "*.example.com" },
    };

    pub fn validate(self: Constrained) ?[]const u8 {
        if (self.low > self.high) return "low must not exceed high";
        return null;
    }
};

fn decodeWith(
    comptime T: type,
    arena: Allocator,
    source: []const u8,
    options: Options,
    diag: *Diagnostic,
) Error!T {
    const tree = @import("json.zig").parse(arena, source, null) catch unreachable;
    return decode(T, arena, tree, options, diag);
}

test "meta constraints and validate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const good = "{\"port\": 2000, \"ports\": [1, 2], \"ratio\": 0.5}";
    const ok = try decodeWith(Constrained, a, good, .{}, &diag);
    try testing.expectEqual(2000, ok.port);

    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "{\"port\": 80}", "port", "must be at least 1024" },
        .{ "{\"port\": \"50000\"}", "port", "must be at most 49151" },
        .{ "{\"ports\": [3, 0]}", "ports.1", "must be at least 1" },
        .{ "{\"ratio\": 1.5}", "ratio", "must be at most 1" },
        .{ "{\"level\": \"loud\"}", "level", "must be one of debug, info" },
        .{ "{\"host\": \"example.org\"}", "host", "must match *.example.com" },
        .{ "{\"low\": 5, \"high\": 1}", "(root)", "low must not exceed high" },
    };
    for (cases) |case| {
        const result = decodeWith(Constrained, a, case[0], .{}, &diag);
        try testing.expectError(error.InvalidValue, result);
        try testing.expectEqualStrings(case[1], diag.key);
        try testing.expectEqualStrings(case[2], diag.message);
    }
}

test "every error, not the first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Settings = struct {
        port: u16,
        name: []const u8,
        debug: bool = false,
        tags: []const u8 = "",
        inner: struct { n: u8 = 0 } = .{},
    };
    var problems: std.ArrayList(Diagnostic) = .empty;
    var diag: Diagnostic = .{};
    const source = "{\"port\": \"x\", \"debug\": 3, \"inner\": {\"n\": 300}, \"extra\": 1}";
    try testing.expectError(error.InvalidValue, decodeWith(Settings, a, source, .{
        .errors = &problems,
        .strict = true,
    }, &diag));
    try testing.expectEqual(5, problems.items.len);
    try testing.expectEqualStrings("port", problems.items[0].key);
    try testing.expectEqualStrings("name", problems.items[1].key);
    try testing.expectEqualStrings("required key is missing", problems.items[1].message);
    try testing.expectEqualStrings("debug", problems.items[2].key);
    try testing.expectEqualStrings("inner.n", problems.items[3].key);
    try testing.expectEqualStrings("extra", problems.items[4].key);
    // `diag` holds the first.
    try testing.expectEqualStrings("port", diag.key);
}

test glob {
    try testing.expect(glob("*.example.com", "a.example.com"));
    try testing.expect(glob("*.example.com", ".example.com"));
    try testing.expect(!glob("*.example.com", "example.com"));
    try testing.expect(glob("a?c*", "abcdef"));
    try testing.expect(glob("*", ""));
    try testing.expect(!glob("a*b", "ac"));
    try testing.expect(glob("*a*b*", "xxaxxbxx"));
}

test "deprecated keys are read, with a warning when set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Settings = struct {
        legacy: u8 = 0,
        current: u8 = 0,
        pub const meta = .{ .legacy = .{ .deprecated = "set by the server now" } };
    };
    var warnings: std.ArrayList(Diagnostic) = .empty;
    var diag: Diagnostic = .{};
    const settings = try decodeWith(
        Settings,
        a,
        "{\"legacy\": 3}",
        .{ .warnings = &warnings },
        &diag,
    );
    try testing.expectEqual(3, settings.legacy);
    try testing.expectEqual(1, warnings.items.len);
    try testing.expectEqualStrings("legacy", warnings.items[0].key);
    try testing.expectEqualStrings("deprecated: set by the server now", warnings.items[0].message);
    // Unset, it says nothing.
    warnings.clearRetainingCapacity();
    _ = try decodeWith(Settings, a, "{\"current\": 1}", .{ .warnings = &warnings }, &diag);
    try testing.expectEqual(0, warnings.items.len);
}

test "renamed_from reads the old key with a warning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Settings = struct {
        timeout: u32 = 1,
        server: struct {
            host: []const u8 = "",
            pub const meta = .{ .host = .{ .renamed_from = "hostname" } };
        } = .{},
        pub const meta = .{ .timeout = .{ .renamed_from = "request.timeout" } };
    };
    var warnings: std.ArrayList(Diagnostic) = .empty;
    var diag: Diagnostic = .{};
    const old = "{\"request\": {\"timeout\": 5}, \"server\": {\"hostname\": \"h\"}}";
    const settings = try decodeWith(Settings, a, old, .{ .warnings = &warnings }, &diag);
    try testing.expectEqual(5, settings.timeout);
    try testing.expectEqualStrings("h", settings.server.host);
    try testing.expectEqual(2, warnings.items.len);
    try testing.expectEqualStrings("request.timeout", warnings.items[0].key);
    try testing.expectEqualStrings("renamed; use timeout", warnings.items[0].message);
    try testing.expectEqualStrings("server.hostname", warnings.items[1].key);
    // A bad value is reported under the key it is under.
    const bad = "{\"request\": {\"timeout\": \"soon\"}}";
    try testing.expectError(error.InvalidValue, decodeWith(Settings, a, bad, .{}, &diag));
    try testing.expectEqualStrings("request.timeout", diag.key);
    // The new key wins when both are there.
    const both = "{\"timeout\": 7, \"request\": {\"timeout\": 5}}";
    try testing.expectEqual(7, (try decodeWith(Settings, a, both, .{}, &diag)).timeout);
    // Strict decoding knows the old keys.
    const strict = try decodeWith(Settings, a, old, .{ .strict = true }, &diag);
    try testing.expectEqual(5, strict.timeout);
    try testing.expectError(
        error.UnknownField,
        decodeWith(Settings, a, "{\"requests\": 1}", .{ .strict = true }, &diag),
    );
}

test "a TOML date-time decodes into DateTime and writes back bare" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toml = @import("toml.zig");
    const DateTime = @import("scalar.zig").DateTime;
    const tree = try toml.parse(a, "at = 1979-05-27T07:32:00Z\nday = 1979-05-27\n", null);
    const Settings = struct { at: DateTime, day: DateTime };
    var diag: Diagnostic = .{};
    const settings = try decode(Settings, a, tree, .{}, &diag);
    try testing.expectEqual(296638320, settings.at.unixSeconds().?);
    try testing.expectEqual(27, settings.day.date.?.day);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try toml.write(&out.writer, tree, .{});
    try testing.expectEqualStrings("at = 1979-05-27T07:32:00Z\nday = 1979-05-27\n", out.written());
}
