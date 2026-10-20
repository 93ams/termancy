//! Typed access to a `Value` tree: `decode` fills a Zig type from a tree, `encode` turns a
//! Zig value into a tree.
//!
//! Decoding coerces, because environment variables and flags are always text: `"8080"`
//! decodes into a `u16`, `"a,b"` into a `[]const []const u8`, `"yes"` into a `bool`.
//!
//! What a type decodes from is a settings type (`settings.zig`): the struct, the `field`
//! specs saying what its fields mean, and the keys they are spelled with. A plain struct
//! decodes too, with no specs, each field under its own name. Specs give:
//!
//! - checks on each value (`.checks`, and `.each` for a list's elements), and on a whole
//!   struct across its fields, run once every field of it decoded;
//! - `.deprecated`: the key is read, with a warning when it is set;
//! - `.secret`: `Config` redacts the key when writing.
//!
//! The keys give `.key` (stored under another name), `.renamed_from` (an old key still
//! read, with a warning), `.env`, and `.merge` (see `settings.zig`).
//!
//! A tagged union is a choice between its variants (`storage: union(enum) { disk: Disk,
//! s3: S3, memory }`): a string names the variant, which takes its defaults
//! (`storage = "s3"`), or a table with one key names it and holds its fields
//! (`[storage.s3]`, `bucket = "b"`).
//!
//! With `Options.errors`, decoding does not stop at the first problem: every one is
//! collected, so a configuration can be fixed in one pass.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const field = @import("field");
const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const Diagnostic = @import("Diagnostic.zig");
const path = @import("path.zig");
const settings_ = @import("settings.zig");

/// The message of a required key that nothing set; `Config.decode` adds how to set it.
pub const missing_message = "required key is missing";

/// What decoding can fail with; the diagnostic names the key.
pub const Error = error{ InvalidValue, MissingField, UnknownField } || Allocator.Error;

/// How `decode` treats unknown keys, bounds, and warnings.
pub const Options = struct {
    /// Reject table keys that no struct field claims: "unknown key", with "did you mean"
    /// for a close field.
    strict: bool = false,
    /// Without `strict`, note each such key in `warnings` instead (when given). Off by
    /// default: a tree may hold keys meant for others, such as `Config`'s `profiles`.
    warn_unknown: bool = false,
    /// Collect every problem here, in the decode arena, instead of stopping at the first.
    /// Decoding still fails, with the first problem's error and in `diag`.
    errors: ?*std.ArrayList(Diagnostic) = null,
    /// Notes on keys read under a name their place marks `.renamed_from`, in the decode
    /// arena: `key` is the old name, `message` says which to use instead. Also keys a spec
    /// marks `.deprecated` that are set: `message` is "deprecated: " and the reason. Also
    /// keys no field claims, with `warn_unknown`.
    warnings: ?*std.ArrayList(Diagnostic) = null,
};

/// Decodes `value` as `X`: a settings type (`cfg.settings`) or a plain type. Slices and
/// strings in the result are allocated in `arena` or borrowed from the tree, so the result
/// lives as long as both. On failure, `diag` names the key and the problem.
pub fn decode(
    comptime X: type,
    arena: Allocator,
    value: Value,
    options: Options,
    diag: ?*Diagnostic,
) Error!settings_.Of(X).Type {
    const Set = settings_.Of(X);
    var decoder: Decoder = .{ .arena = arena, .options = options, .diag = diag };
    const result = try decoder.any(Set.Type, Set.Specs, Set.root, value, "");
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

    fn any(
        d: *Decoder,
        comptime T: type,
        comptime S: type,
        comptime place: anytype,
        value: Value,
        key: []const u8,
    ) Error!T {
        if (T == Value) return value;
        if (comptime hasParse(T)) return d.parsed(T, value, key);
        if (comptime settings_.isChoice(T)) return d.choice(T, S, place, value, key);
        return switch (@typeInfo(T)) {
            .optional => |o| if (value == .null) null else try d.any(o.child, S, place, value, key),
            .bool => d.boolean(value, key),
            .int => d.int(T, value, key),
            .float => d.float(T, value, key),
            .@"enum" => d.enumeration(T, value, key),
            .pointer => |p| {
                if (p.size != .slice) @compileError("cfg cannot decode " ++ @typeName(T));
                if (p.child == u8) return d.string(value, key);
                return d.slice(p.child, S, place, value, key);
            },
            .@"struct" => d.structure(T, S, place, value, key),
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
        const names = @typeInfo(T).@"enum".field_names;
        if (value == .string) {
            inline for (names, 0..) |name, i| {
                if (field.sameName(name, value.string)) {
                    return @fromBackingInt(@intCast(@typeInfo(T).@"enum".field_values[i]));
                }
            }
        }
        return d.fail(key, error.InvalidValue, try d.oneOf(names, value));
    }

    /// "expected one of: a, b", with "did you mean" when `value` is text close to one.
    fn oneOf(d: *Decoder, comptime names: []const [:0]const u8, value: Value) Error![]const u8 {
        const message = "expected one of: " ++ comptime nameList(names);
        if (value != .string) return message;
        const near = path.suggest(value.string, &comptime nameSlices(names)) orelse return message;
        return std.fmt.allocPrint(d.arena, "{s}; did you mean '{s}'?", .{ message, near });
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

    fn slice(
        d: *Decoder,
        comptime Child: type,
        comptime S: type,
        comptime place: anytype,
        value: Value,
        key: []const u8,
    ) Error![]const Child {
        // The elements of a list of tables have their fields' places; others, none.
        const item_place = comptime elementPlace(Child, place);
        switch (value) {
            .array => |a| {
                const out = try d.arena.alloc(Child, a.items.len);
                for (a.items, out, 0..) |item, *slot, i| {
                    const item_key = if (key.len == 0)
                        try std.fmt.allocPrint(d.arena, "{d}", .{i})
                    else
                        try std.fmt.allocPrint(d.arena, "{s}.{d}", .{ key, i });
                    slot.* = d.any(Child, S, item_place, item, item_key) catch |err| {
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
                    slot.* = try d.any(Child, S, item_place, .{ .string = part }, key);
                }
                return out;
            },
            else => return d.fail(key, error.InvalidValue, "expected an array"),
        }
    }

    fn structure(
        d: *Decoder,
        comptime T: type,
        comptime S: type,
        comptime place: anytype,
        value: Value,
        key: []const u8,
    ) Error!T {
        if (value != .table) return d.fail(key, error.InvalidValue, "expected a table");
        const info = @typeInfo(T).@"struct";
        const spec = comptime S.of(T);
        var result: T = undefined;
        var failed = false;
        // Which fields took their defaults: named when a check across fields fails.
        var defaulted: [info.field_names.len]bool = @splat(false);
        inline for (
            info.field_names,
            info.field_types,
            info.field_attrs,
            0..,
        ) |name, Field, attrs, i| {
            const field_place = @field(place.fields, name);
            const field_spec = @field(spec.fields, name);
            const child_key = try path.join(
                d.arena,
                key,
                comptime settings_.keyOf(field_place, name),
            );
            if (try d.findOrRenamed(field_place, name, value.table, key, child_key)) |found| {
                const child = found.value;
                // Problems name the key the value is under, the old one when it was renamed.
                const at = found.key;
                if (field_spec.deprecated) |reason| {
                    if (d.options.warnings) |list| try list.append(d.arena, .{
                        .key = at,
                        .message = try std.fmt.allocPrint(d.arena, "deprecated: {s}", .{reason}),
                    });
                }
                if (d.any(Field, S, field_place, child, at)) |decoded| {
                    @field(result, name) = decoded;
                    if (!try d.checkField(Field, field_spec, decoded, at)) failed = true;
                } else |err| {
                    if (!d.recover(err)) return err;
                    failed = true;
                    @field(result, name) = undefined; // The decode fails; nothing reads it.
                }
            } else if (comptime defaultOf(Field, attrs)) |default| {
                @field(result, name) = default;
                defaulted[i] = true;
            } else if (@typeInfo(Field) == .optional) {
                @field(result, name) = null;
            } else if (comptime settings_.isTable(Field)) {
                // A table whose own fields all have defaults may be left out.
                @field(result, name) = d.any(
                    Field,
                    S,
                    field_place,
                    .empty_table,
                    child_key,
                ) catch |err| blk: {
                    if (!d.recover(err)) return err;
                    failed = true;
                    break :blk undefined;
                };
            } else {
                const err = d.fail(child_key, error.MissingField, missing_message);
                if (!d.recover(err)) return err;
                failed = true;
                @field(result, name) = undefined;
            }
        }
        const warn = d.options.warn_unknown and d.options.warnings != null;
        if (d.options.strict or warn) d.unknownKeys(T, place, value.table, key) catch |err| {
            if (!d.recover(err)) return err;
        };
        // Checks across fields need every field decoded.
        if (!failed) inline for (spec.checks) |c| {
            d.runCheck(
                T,
                c,
                result,
                key,
                defaultsNote(T, &defaulted, value.table.count() > 0),
            ) catch |err| {
                if (!d.recover(err)) return err;
            };
        };
        return result;
    }

    /// A choice: a string naming the variant, or a table with one key naming it.
    fn choice(
        d: *Decoder,
        comptime U: type,
        comptime S: type,
        comptime place: anytype,
        value: Value,
        key: []const u8,
    ) Error!U {
        const names = comptime field.fieldNames(U);
        const keys = comptime blk: {
            var out: [names.len][]const u8 = undefined;
            for (names, &out) |name, *k| k.* = settings_.keyOf(@field(place.variants, name), name);
            break :blk out;
        };
        const spec = comptime S.of(U);
        var chosen: ?U = null;
        var failed = false;
        switch (value) {
            .string => |text| inline for (names, keys) |name, variant_key| {
                if (field.sameName(variant_key, text)) {
                    const at = try path.join(d.arena, key, variant_key);
                    chosen = try d.variant(U, S, place, name, .empty_table, at, &failed);
                }
            },
            .table => |t| {
                var found: ?[]const u8 = null;
                inline for (names, keys) |name, variant_key| {
                    if (findKey(t, variant_key)) |payload| {
                        if (found) |other| {
                            const message = try std.fmt.allocPrint(
                                d.arena,
                                "set only one of {s} and {s}",
                                .{ other, variant_key },
                            );
                            return d.fail(key, error.InvalidValue, message);
                        }
                        found = variant_key;
                        const at = try path.join(d.arena, key, variant_key);
                        chosen = try d.variant(U, S, place, name, payload, at, &failed);
                    }
                }
            },
            else => {},
        }
        const result = chosen orelse {
            const message = "expected one of: " ++ comptime nameList(&keys);
            const near = if (value == .string) path.suggest(value.string, &keys) else null;
            return d.fail(key, error.InvalidValue, if (near) |n|
                try std.fmt.allocPrint(d.arena, "{s}; did you mean '{s}'?", .{ message, n })
            else
                message);
        };
        if (!failed) inline for (spec.checks) |c| {
            d.runCheck(U, c, result, key, no_note) catch |err| {
                if (!d.recover(err)) return err;
            };
        };
        return result;
    }

    fn variant(
        d: *Decoder,
        comptime U: type,
        comptime S: type,
        comptime place: anytype,
        comptime name: []const u8,
        payload: Value,
        at: []const u8,
        failed: *bool,
    ) Error!U {
        const P = @FieldType(U, name);
        if (P == void) return @unionInit(U, name, {});
        const decoded = d.any(P, S, @field(place.variants, name), payload, at) catch |err| {
            if (!d.recover(err)) return err;
            failed.* = true;
            return @unionInit(U, name, undefined); // The decode fails; nothing reads it.
        };
        const variant_spec = @field((comptime S.of(U)).fields, name);
        if (!try d.checkField(P, variant_spec, decoded, at)) failed.* = true;
        return @unionInit(U, name, decoded);
    }

    /// Runs a field's checks on its decoded value, and `.each` on a list's elements.
    /// Whether they all passed.
    fn checkField(
        d: *Decoder,
        comptime Field: type,
        comptime spec: anytype,
        decoded: Field,
        key: []const u8,
    ) Error!bool {
        const C = field.Unwrap(Field);
        const value: C = if (@typeInfo(Field) == .optional) decoded orelse return true else decoded;
        var ok = true;
        inline for (spec.checks) |c| {
            d.runCheck(C, c, value, key, no_note) catch |err| {
                if (!d.recover(err)) return err;
                ok = false;
            };
        }
        if (comptime field.isList(C)) {
            if (spec.each.len > 0) for (value, 0..) |item, i| {
                const item_key = try std.fmt.allocPrint(d.arena, "{s}.{d}", .{ key, i });
                inline for (spec.each) |c| {
                    d.runCheck(@TypeOf(item), c, item, item_key, no_note) catch |err| {
                        if (!d.recover(err)) return err;
                        ok = false;
                    };
                }
            };
        }
        return ok;
    }

    fn runCheck(
        d: *Decoder,
        comptime V: type,
        comptime c: field.Check(V),
        value: V,
        key: []const u8,
        note: anytype,
    ) Error!void {
        var message: std.Io.Writer.Allocating = .init(d.arena);
        c.run(value, &message.writer) catch |err| switch (err) {
            // An allocating writer fails only for want of memory.
            error.WriteFailed => return error.OutOfMemory,
            error.Invalid => {
                note.write(&message.writer) catch return error.OutOfMemory;
                return d.fail(key, error.InvalidValue, message.written());
            },
        };
    }

    /// The field's value and the key it is under: its own, or the key its place says it
    /// was renamed from, with a warning.
    fn findOrRenamed(
        d: *Decoder,
        comptime place: anytype,
        comptime name: []const u8,
        table: Table,
        key: []const u8,
        child_key: []const u8,
    ) Error!?struct { value: Value, key: []const u8 } {
        if (findKey(table, comptime settings_.keyOf(place, name))) |child| {
            return .{ .value = child, .key = child_key };
        }
        const renamed = comptime renamedFrom(place);
        if (renamed == null) return null;
        const old: []const u8 = renamed.?;
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

    /// Fails on the first table key no field of `T` claims, when strict; else adds a
    /// warning for each (`warn_unknown`).
    fn unknownKeys(
        d: *Decoder,
        comptime T: type,
        comptime place: anytype,
        table: Table,
        key: []const u8,
    ) Error!void {
        const names = @typeInfo(T).@"struct".field_names;
        const keys = comptime blk: {
            var out: [names.len][]const u8 = undefined;
            for (names, &out) |name, *k| k.* = settings_.keyOf(@field(place.fields, name), name);
            break :blk out;
        };
        var it = table.iterator();
        outer: while (it.next()) |entry| {
            inline for (names, keys) |name, field_key| {
                if (field.sameName(field_key, entry.key_ptr.*)) continue :outer;
                // A key the field was renamed from is known too, while it is still read.
                if (comptime renamedFrom(@field(place.fields, name))) |old| {
                    var segments = path.iterate(old);
                    const first = segments.next() catch null;
                    if (first != null and field.sameName(first.?.text, entry.key_ptr.*)) {
                        continue :outer;
                    }
                }
            }
            const unknown_key = try path.join(d.arena, key, entry.key_ptr.*);
            const message = if (path.suggest(entry.key_ptr.*, &keys)) |near|
                try std.fmt.allocPrint(d.arena, "unknown key; did you mean '{s}'?", .{near})
            else
                "unknown key";
            if (!d.options.strict) {
                const warning: Diagnostic = .{ .key = unknown_key, .message = message };
                try d.options.warnings.?.append(d.arena, warning);
                continue;
            }
            return d.fail(unknown_key, error.UnknownField, message);
        }
    }
};

/// The place of each element of a list at `place`: a list of tables gives its elements'
/// fields; anything else, none.
fn elementPlace(comptime Child: type, comptime place: anytype) settings_.Place(Child) {
    if (comptime settings_.isTable(field.Unwrap(Child)) and @hasField(@TypeOf(place), "fields")) {
        return .{ .fields = place.fields };
    }
    return .{};
}

fn renamedFrom(comptime place: anytype) ?[]const u8 {
    return if (@hasField(@TypeOf(place), "renamed_from")) place.renamed_from else null;
}

/// After a failed check across a struct's fields: the fields that took their defaults
/// though the table was there, which the check may have read without the user seeing them.
fn defaultsNote(comptime T: type, defaulted: []const bool, present: bool) DefaultsNote(T) {
    return .{ .defaulted = defaulted, .present = present };
}

fn DefaultsNote(comptime T: type) type {
    return struct {
        defaulted: []const bool,
        present: bool,

        fn write(note: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (!note.present) return;
            const info = @typeInfo(T).@"struct";
            var first = true;
            inline for (
                info.field_names,
                info.field_types,
                info.field_attrs,
                0..,
            ) |name, F, attrs, i| {
                if (note.defaulted[i] and comptime isScalar(F)) {
                    const default = comptime defaultOf(F, attrs).?;
                    try w.writeAll(if (first) " (defaults: " else ", ");
                    first = false;
                    try writeScalar(F, default, name, w);
                }
            }
            if (!first) try w.writeAll(")");
        }
    };
}

fn isScalar(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .bool, .int, .float, .@"enum" => true,
        .pointer => F == []const u8,
        else => false,
    };
}

fn writeScalar(
    comptime F: type,
    value: F,
    name: []const u8,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    switch (@typeInfo(F)) {
        .@"enum" => try w.print("{s} = {s}", .{ name, @tagName(value) }),
        .pointer => try w.print("{s} = \"{s}\"", .{ name, value }),
        else => try w.print("{s} = {}", .{ name, value }),
    }
}

/// No note: what `runCheck` takes for checks on one value.
const no_note = struct {
    fn write(_: @This(), _: *std.Io.Writer) std.Io.Writer.Error!void {}
}{};

/// What encoding can fail with: a value no tree can hold.
pub const EncodeError = error{Unrepresentable} || Allocator.Error;

/// Encodes a Zig value as a tree in `arena`, each field under its own name. Optional
/// fields that are `null` are left out of tables, since most formats cannot spell null.
/// Types with a `format` method and a `parse` function encode as their text.
pub fn encode(arena: Allocator, value: anytype) EncodeError!Value {
    return encodeAt(settings_.Of(@TypeOf(value)).root, arena, value);
}

/// Encodes `value`, a `settings_.Of(X).Type`, under the keys `X` gives its fields.
pub fn encodeAs(comptime X: type, arena: Allocator, value: settings_.Of(X).Type) EncodeError!Value {
    return encodeAt(settings_.Of(X).root, arena, value);
}

/// The struct's own defaults as the settings type `X` spells them. A field without one is
/// left out, but for a table, which holds its fields' defaults; so is a default the tree
/// cannot hold (an integer beyond `i64`), which `decode` still falls back to.
pub fn encodeDefaults(comptime X: type, arena: Allocator) Allocator.Error!Value {
    const S = settings_.Of(X);
    if (comptime !settings_.isTable(S.Type)) return .empty_table;
    return encodeDefaultsAt(S.Type, S.root, arena);
}

fn encodeDefaultsAt(comptime T: type, comptime place: anytype, arena: Allocator) Allocator.Error!Value {
    var table: Table = .empty;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const field_place = comptime @field(place.fields, name);
        const key = comptime settings_.keyOf(field_place, name);
        if (attrs.default_value_ptr) |d| {
            const default = @as(*const F, @ptrCast(@alignCast(d))).*;
            const skip = @typeInfo(F) == .optional and default == null;
            if (!skip) if (encodeAt(field_place, arena, default)) |encoded| {
                var kept = encoded;
                if (comptime settings_.isTable(F)) dropRequired(F, field_place, &kept);
                try table.put(arena, key, kept);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unrepresentable => {},
            };
        } else if (comptime settings_.isTable(F)) {
            try table.put(arena, key, try encodeDefaultsAt(F, field_place, arena));
        }
    }
    return .{ .table = table };
}

/// Leaves out of `value` the fields of `T` that have no default of their own (a table that
/// is given must give them, so its default does not stand in for them).
fn dropRequired(comptime T: type, comptime place: anytype, value: *Value) void {
    if (value.* != .table) return;
    inline for (comptime field.fieldNames(T), comptime field.fieldTypes(T)) |name, F| {
        const field_place = comptime @field(place.fields, name);
        const key = comptime settings_.keyOf(field_place, name);
        if (comptime settings_.isTable(F)) {
            if (value.table.getPtr(key)) |child| dropRequired(F, field_place, child);
        } else if (comptime field.isRequired(T, name)) {
            _ = value.table.orderedRemove(key);
        }
    }
}

fn encodeAt(comptime place: anytype, arena: Allocator, value: anytype) EncodeError!Value {
    const T = @TypeOf(value);
    if (T == Value) return value.clone(arena);
    if (comptime hasParse(T) and std.meta.hasMethod(T, "format")) {
        return .{ .string = try std.fmt.allocPrint(arena, "{f}", .{value}) };
    }
    if (comptime settings_.isChoice(T)) return encodeChoice(place, arena, value);
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| encodeAt(place, arena, v) else .null,
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
                encodeSlice(place, arena, value),
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8)
                    .{ .string = try arena.dupe(u8, value) }
                else
                    encodeSlice(place, arena, @as([]const a.child, value)),
                else => encodeAt(place, arena, value.*),
            },
            else => @compileError("cfg cannot encode " ++ @typeName(T)),
        },
        .@"struct" => encodeStruct(place, arena, value),
        else => @compileError("cfg cannot encode " ++ @typeName(T)),
    };
}

fn encodeSlice(comptime place: anytype, arena: Allocator, items: anytype) EncodeError!Value {
    const item_place = comptime elementPlace(@typeInfo(@TypeOf(items)).pointer.child, place);
    var array: Array = try .initCapacity(arena, items.len);
    for (items) |item| array.appendAssumeCapacity(try encodeAt(item_place, arena, item));
    return .{ .array = array };
}

fn encodeStruct(comptime place: anytype, arena: Allocator, value: anytype) EncodeError!Value {
    const T = @TypeOf(value);
    const has_fields = @hasField(@TypeOf(place), "fields");
    var table: Table = .empty;
    inline for (
        @typeInfo(T).@"struct".field_names,
        @typeInfo(T).@"struct".field_types,
    ) |name, Field| {
        const f = @field(value, name);
        const skip = @typeInfo(Field) == .optional and f == null;
        const field_place = comptime if (has_fields and @hasField(@TypeOf(place.fields), name))
            @field(place.fields, name)
        else
            settings_.Place(Field){};
        if (!skip) try table.put(
            arena,
            comptime settings_.keyOf(field_place, name),
            try encodeAt(field_place, arena, f),
        );
    }
    return .{ .table = table };
}

/// A void variant as its name; any other as a one-key table naming it.
fn encodeChoice(comptime place: anytype, arena: Allocator, value: anytype) EncodeError!Value {
    switch (value) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            const variant_place = comptime if (@hasField(@TypeOf(place), "variants"))
                @field(place.variants, name)
            else
                settings_.Place(@TypeOf(payload)){};
            const variant_key = comptime settings_.keyOf(variant_place, name);
            if (@TypeOf(payload) == void) return .{ .string = variant_key };
            var table: Table = .empty;
            try table.put(arena, variant_key, try encodeAt(variant_place, arena, payload));
            return .{ .table = table };
        },
    }
}

/// Whether `text` matches `pattern`, where `*` matches any run of bytes and `?` one byte.
pub const glob = field.matches;

/// Whether `T` follows the `parse` convention; see `field.hasParse`.
pub const hasParse = field.hasParse;

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
        if (field.sameName(name, entry.key_ptr.*)) return entry.value_ptr.*;
    }
    return null;
}

fn nameList(comptime names: anytype) []const u8 {
    var out: []const u8 = "";
    for (names, 0..) |name, i| out = out ++ (if (i == 0) "" else ", ") ++ name;
    return out;
}

fn nameSlices(comptime names: []const [:0]const u8) [names.len][]const u8 {
    var out: [names.len][]const u8 = undefined;
    for (names, &out) |name, *slot| slot.* = name;
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
};

fn decodeJson(
    comptime T: type,
    arena: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
) !settings_.Of(T).Type {
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
    try testing.expectEqualStrings("unknown key; did you mean 'port'?", diag.message);
    _ = try decode(Server, a, tree, .{}, null);
    // With warn_unknown: a warning per unknown key, and none for a `Value` field's contents.
    const T = struct { server: Server, extra: Value = .null };
    const nested = try json.parse(a,
        \\{"server": {"port": 1, "prot": 2, "zzz": 3}, "extra": {"anything": 1}, "srever": 0}
    , null);
    var warnings: std.ArrayList(Diagnostic) = .empty;
    _ = try decode(T, a, nested, .{ .warnings = &warnings }, null);
    try testing.expectEqual(0, warnings.items.len);
    _ = try decode(T, a, nested, .{ .warnings = &warnings, .warn_unknown = true }, null);
    try testing.expectEqual(3, warnings.items.len);
    try testing.expectEqualStrings("server.prot", warnings.items[0].key);
    try testing.expectEqualStrings("unknown key; did you mean 'port'?", warnings.items[0].message);
    try testing.expectEqualStrings("server.zzz", warnings.items[1].key);
    try testing.expectEqualStrings("unknown key", warnings.items[1].message);
    try testing.expectEqualStrings("srever", warnings.items[2].key);
    try testing.expectEqualStrings(
        "unknown key; did you mean 'server'?",
        warnings.items[2].message,
    );
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

test "keys rename fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const T = struct { cert: []const u8 };
    const keyed = settings_.settings(
        T,
        field.none,
        .{ .fields = .{ .cert = .{ .key = "certificate" } } },
    );
    const t = try decodeJson(keyed, arena.allocator(), "{\"certificate\": \"x\"}", null);
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

test "secret keys follow specs by type" {
    const Db = struct { url: []const u8 };
    const Root = struct { server: Server, db: Db };
    const specs = field.Set(.{
        field.Spec(Server){ .fields = .{ .password = .{ .secret = true } } },
        field.Spec(Db){ .fields = .{ .url = .{ .secret = true } } },
    });
    const keys = comptime settings_.secretKeys(settings_.settings(Root, specs, .{}));
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
    };
    const outer = settings_.settings(
        Outer,
        field.none,
        .{ .fields = .{ .renamed = .{ .key = "is-renamed" } } },
    );
    const empty = try decode(outer, a, .empty_table, .{ .strict = true }, null);
    try testing.expectEqual(1, empty.inner.x);
    try testing.expectEqual(null, empty.maybe);
    try testing.expectEqual(0, empty.list.len);
    const full = try decode(outer, a, try json.parse(a,
        \\{"inner": {"y": 3}, "maybe": {"x": 9}, "list": [{}, {"x": 2}], "IS_RENAMED": "on"}
    , null), .{ .strict = true }, null);
    try testing.expectEqual(3, full.inner.y.?);
    try testing.expectEqual(9, full.maybe.?.x);
    try testing.expectEqual(2, full.list[1].x);
    try testing.expect(full.renamed);
    const null_tree = try json.parse(a, "{\"maybe\": null}", null);
    const explicit_null = try decode(outer, a, null_tree, .{}, null);
    try testing.expectEqual(null, explicit_null.maybe);

    var diag: Diagnostic = .{};
    const unknown = try json.parse(a, "{\"inner\": {\"z\": 1}}", null);
    try testing.expectError(
        error.UnknownField,
        decode(outer, a, unknown, .{ .strict = true }, &diag),
    );
    try testing.expectEqualStrings("inner.z", diag.key);
    // The field's own name is unknown once its key renames it.
    const old_name = try json.parse(a, "{\"renamed\": true}", null);
    try testing.expectError(
        error.UnknownField,
        decode(outer, a, old_name, .{ .strict = true }, &diag),
    );
    try testing.expectError(error.InvalidValue, decode(outer, a, .{ .string = "x" }, .{}, &diag));
    try testing.expectEqualStrings("(root)", diag.key);
    const in_list = try json.parse(a, "{\"list\": [{\"x\": \"big\"}]}", null);
    try testing.expectError(error.InvalidValue, decode(outer, a, in_list, .{}, &diag));
    try testing.expectEqualStrings("list.0.x", diag.key);
}

test "a key that needs quoting is quoted in diagnostics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = settings_.settings(struct { port: u16 }, field.none, .{ .fields = .{
        .port = .{ .key = "http.port" },
    } });
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
    };
    const keyed = settings_.settings(T, field.none, .{ .fields = .{ .c = .{ .key = "kind" } } });
    const tree = try encodeAs(keyed, a, .{});
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

test "environment variables follow keys through optionals" {
    const Root = struct {
        db: ?struct { url: []const u8 = "", pass: []const u8 = "" } = null,
        port: u16 = 0,
    };
    const keyed = settings_.settings(Root, field.none, .{ .fields = .{
        .db = .{ .fields = .{ .pass = .{ .env = "DB_PASSWORD", .key = "password" } } },
        .port = .{ .env = "PORT" },
    } });
    const bindings = comptime settings_.envBindings(keyed);
    try std.testing.expectEqual(2, bindings.len);
    try std.testing.expectEqualStrings("db.password", bindings[0].key);
    try std.testing.expectEqualStrings("DB_PASSWORD", bindings[0].env);
    try std.testing.expectEqualStrings("port", bindings[1].key);
    try std.testing.expectEqualStrings("PORT", bindings[1].env);
}

test "secret keys follow optionals and renames, and stop at leaves" {
    const Db = struct { pass: []const u8 };
    const Whole = struct { x: u8 };
    const T = struct {
        db: ?Db = null,
        timeout: scalar.Duration = .zero,
        raw: Value = .null,
        whole: Whole = .{ .x = 0 },
    };
    const specs = field.Set(.{
        field.Spec(Db){ .fields = .{ .pass = .{ .secret = true } } },
        field.Spec(T){ .fields = .{ .whole = .{ .secret = true } } },
    });
    const keyed = settings_.settings(T, specs, .{ .fields = .{
        .db = .{ .fields = .{ .pass = .{ .key = "password" } } },
    } });
    const keys = comptime settings_.secretKeys(keyed);
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
};

fn ordered(c: Constrained, w: *std.Io.Writer) !void {
    if (c.low > c.high) return field.fail(w, "low must not exceed high", .{});
}

const constrained = settings_.settings(Constrained, field.Set(.{field.Spec(Constrained){
    .fields = .{
        .port = .{ .checks = &.{ .min(1024), .max(49151) } },
        .ports = .{ .each = &.{.min(1)} },
        .ratio = .{ .checks = &.{.max(1)} },
        .level = .{ .checks = &.{.oneOf(&.{ "debug", "info" })} },
        .host = .{ .checks = &.{.glob("*.example.com")} },
    },
    .checks = &.{.from(ordered)},
}}), .{});

fn decodeWith(
    comptime T: type,
    arena: Allocator,
    source: []const u8,
    options: Options,
    diag: *Diagnostic,
) Error!settings_.Of(T).Type {
    const tree = @import("json.zig").parse(arena, source, null) catch unreachable;
    return decode(T, arena, tree, options, diag);
}

test "checks on values and across fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const good = "{\"port\": 2000, \"ports\": [1, 2], \"ratio\": 0.5}";
    const ok = try decodeWith(constrained, a, good, .{}, &diag);
    try testing.expectEqual(2000, ok.port);

    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "{\"port\": 80}", "port", "must be at least 1024" },
        .{ "{\"port\": \"50000\"}", "port", "must be at most 49151" },
        .{ "{\"ports\": [3, 0]}", "ports.1", "must be at least 1" },
        .{ "{\"ratio\": 1.5}", "ratio", "must be at most 1" },
        .{ "{\"level\": \"loud\"}", "level", "must be one of debug, info" },
        .{ "{\"host\": \"example.org\"}", "host", "must match *.example.com" },
        .{
            "{\"low\": 5, \"high\": 1}",
            "(root)",
            "low must not exceed high (defaults: port = 8080, level = \"info\", " ++
                "host = \"a.example.com\")",
        },
    };
    for (cases) |case| {
        const result = decodeWith(constrained, a, case[0], .{}, &diag);
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
    const Plain = struct { legacy: u8 = 0, current: u8 = 0 };
    const Settings = settings_.settings(Plain, field.Set(.{field.Spec(Plain){ .fields = .{
        .legacy = .{ .deprecated = "set by the server now" },
    } }}), .{});
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
    const Plain = struct {
        timeout: u32 = 1,
        server: struct { host: []const u8 = "" } = .{},
    };
    const Settings = settings_.settings(Plain, field.none, .{ .fields = .{
        .timeout = .{ .renamed_from = "request.timeout" },
        .server = .{ .fields = .{ .host = .{ .renamed_from = "hostname" } } },
    } });
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

const Storage = union(enum) {
    disk: struct { path: []const u8 = "/var/lib/app" },
    s3: struct { bucket: []const u8, prefix: []const u8 = "" },
    memory,
};

test "a choice from its name or from a table naming it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct { storage: Storage = .memory };
    const named = try decodeJson(T, a, "{\"storage\": \"disk\"}", null);
    try testing.expectEqualStrings("/var/lib/app", named.storage.disk.path);
    const table = try decodeJson(T, a, "{\"storage\": {\"s3\": {\"bucket\": \"b\"}}}", null);
    try testing.expectEqualStrings("b", table.storage.s3.bucket);
    try testing.expect((try decodeJson(T, a, "{}", null)).storage == .memory);
    try testing.expect(
        (try decodeJson(T, a, "{\"storage\": \"MEMORY\"}", null)).storage == .memory,
    );

    var diag: Diagnostic = .{};
    const cases = [_]struct { []const u8, anyerror, []const u8, []const u8 }{
        .{
            "{\"storage\": \"s4\"}",
            error.InvalidValue,
            "storage",
            "expected one of: disk, s3, memory; did you mean 's3'?",
        },
        .{
            "{\"storage\": \"s3\"}",
            error.MissingField,
            "storage.s3.bucket",
            "required key is missing",
        },
        .{
            "{\"storage\": {\"disk\": {}, \"s3\": {}}}",
            error.InvalidValue,
            "storage",
            "set only one of disk and s3",
        },
        .{ "{\"storage\": 1}", error.InvalidValue, "storage", "expected one of: disk, s3, memory" },
    };
    for (cases) |case| {
        try testing.expectError(case[1], decodeJson(T, a, case[0], &diag));
        try testing.expectEqualStrings(case[2], diag.key);
        try testing.expectEqualStrings(case[3], diag.message);
    }
}

test "a choice encodes as its name, or a table naming it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct { storage: Storage };
    try testing.expectEqualStrings(
        "memory",
        (try encode(a, T{ .storage = .memory })).lookup("storage").?.string,
    );
    const s3 = try encode(a, T{ .storage = .{ .s3 = .{ .bucket = "b" } } });
    try testing.expectEqualStrings("b", s3.lookup("storage.s3.bucket").?.string);
    const back = try decode(T, a, s3, .{ .strict = true }, null);
    try testing.expectEqualStrings("b", back.storage.s3.bucket);
}

test "checks on a choice's variants, by type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct { storage: Storage = .memory };
    const S3 = @FieldType(Storage, "s3");
    const specs = field.Set(
        .{field.Spec(S3){ .fields = .{ .bucket = .{ .checks = &.{.minLen(3)} } } }},
    );
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, decodeJson(
        settings_.settings(T, specs, .{}),
        a,
        "{\"storage\": {\"s3\": {\"bucket\": \"b\"}}}",
        &diag,
    ));
    try testing.expectEqualStrings("storage.s3.bucket", diag.key);
    try testing.expectEqualStrings("must be at least 3 long", diag.message);
}

test "an enum name close to a choice is suggested" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const Level = enum { debug, info, warn };
    try testing.expectError(
        error.InvalidValue,
        decode(Level, arena.allocator(), .{ .string = "wran" }, .{}, &diag),
    );
    try testing.expectEqualStrings(
        "expected one of: debug, info, warn; did you mean 'warn'?",
        diag.message,
    );
}
