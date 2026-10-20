//! Kinds of setting types, and typed dotted paths into a value: `public.port`,
//! `storage.s3.bucket`.

const std = @import("std");

/// `?X` is described and checked as `X`, when set.
pub fn Unwrap(comptime V: type) type {
    return if (@typeInfo(V) == .optional) @typeInfo(V).optional.child else V;
}

/// A list: a slice other than a string.
pub fn isList(comptime V: type) bool {
    const info = @typeInfo(V);
    return info == .pointer and info.pointer.size == .slice and V != []const u8;
}

/// Whether `V` follows the `parse` convention, `pub fn parse(text: []const u8) !V`: a value
/// read from text, such as a duration, rather than a group of settings. The signature is
/// checked, not just the name, so an unrelated method called `parse` does not count.
pub fn hasParse(comptime V: type) bool {
    switch (@typeInfo(V)) {
        .@"struct", .@"enum", .@"union" => {},
        else => return false,
    }
    if (!@hasDecl(V, "parse")) return false;
    const info = switch (@typeInfo(@TypeOf(V.parse))) {
        .@"fn" => |f| f,
        else => return false,
    };
    if (info.param_types.len != 1 or info.param_types[0] != []const u8) return false;
    const Return = info.return_type orelse return false;
    return Return == V or
        (@typeInfo(Return) == .error_union and @typeInfo(Return).error_union.payload == V);
}

/// A struct whose fields are settings of their own.
pub fn isGroup(comptime V: type) bool {
    return @typeInfo(V) == .@"struct" and !hasParse(V);
}

/// A tagged union whose variants are alternatives:
/// `storage: union(enum) { disk: Disk, s3: S3, memory }`.
pub fn isChoice(comptime V: type) bool {
    return @typeInfo(V) == .@"union" and @typeInfo(V).@"union".tag_type != null and
        !hasParse(V);
}

/// The names of a struct's fields or a union's variants.
pub fn fieldNames(comptime T: type) []const [:0]const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_names,
        .@"union" => |u| u.field_names,
        else => @compileError(@typeName(T) ++ " has no fields"),
    };
}

/// The types of a struct's fields or a union's variants.
pub fn fieldTypes(comptime T: type) []const type {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_types,
        .@"union" => |u| u.field_types,
        else => @compileError(@typeName(T) ++ " has no fields"),
    };
}

/// A value of `T` with every default set, groups without defaults filled with theirs.
/// Fields that must be set and have no default are zero (`null`, `false`, `0`, empty), or
/// left undefined for a type with no zero: read them only once something set them.
pub fn initDefaults(comptime T: type) T {
    var value: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        if (attrs.default_value_ptr) |d| {
            @field(value, name) = @as(*const F, @ptrCast(@alignCast(d))).*;
        } else if (comptime isGroup(F)) {
            @field(value, name) = initDefaults(F);
        } else if (comptime zero(F)) |z| {
            @field(value, name) = z;
        }
    }
    return value;
}

/// The value a field without a default holds until it is set, when its type has one.
fn zero(comptime F: type) ?F {
    return switch (@typeInfo(F)) {
        // Some null of `F`, not "no zero".
        .optional => @as(F, null),
        .bool => false,
        .int, .float => 0,
        .pointer => |p| if (p.size == .slice) &.{} else null,
        else => null,
    };
}

/// The variant `name` of the choice `U`, its fields at their defaults.
pub fn initVariant(comptime U: type, comptime name: []const u8) U {
    const P = @FieldType(U, name);
    if (P == void) return @unionInit(U, name, {});
    if (comptime !isGroup(P)) {
        @compileError(@typeName(U) ++ "." ++ name ++ ": a variant must be a struct or void");
    }
    return @unionInit(U, name, initDefaults(P));
}

/// Whether the field at `path` of `T` must be set: no default, not optional, and not a
/// group (whose own fields say what they need).
pub fn isRequired(comptime T: type, comptime path: []const u8) bool {
    return comptime blk: {
        if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
            const Parent = Unwrap(PathType(T, path[0..dot]));
            if (@typeInfo(Parent) != .@"struct") break :blk false;
            break :blk isRequired(Parent, path[dot + 1 ..]);
        }
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
            if (std.mem.eql(u8, name, path)) {
                break :blk attrs.default_value_ptr == null and @typeInfo(F) != .optional and
                    !isGroup(F);
            }
        }
        @compileError(@typeName(T) ++ " has no field " ++ path);
    };
}

/// The type at a dotted field path of `T`; optionals are unwrapped on the way and a
/// choice's variants are named like fields.
pub fn PathType(comptime T: type, comptime path: []const u8) type {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.') orelse return @FieldType(T, path);
    return PathType(Unwrap(@FieldType(T, path[0..dot])), path[dot + 1 ..]);
}

/// A pointer to the field at `path`, creating optional groups (with their defaults) and
/// switching choices to the variant named on the way.
pub fn ptrAt(comptime T: type, comptime path: []const u8, root: *T) *PathType(T, path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const head = comptime path[0..dot];
        if (comptime isChoice(T)) {
            if (!std.mem.eql(u8, @tagName(std.meta.activeTag(root.*)), head)) {
                root.* = initVariant(T, head);
            }
            return ptrAt(@FieldType(T, head), path[dot + 1 ..], &@field(root.*, head));
        }
        const slot = &@field(root, head);
        if (@typeInfo(@TypeOf(slot.*)) == .optional) {
            if (slot.* == null) slot.* = initDefaults(Unwrap(@TypeOf(slot.*)));
            return ptrAt(Unwrap(@TypeOf(slot.*)), path[dot + 1 ..], &slot.*.?);
        }
        return ptrAt(@TypeOf(slot.*), path[dot + 1 ..], slot);
    } else return &@field(root, path);
}

/// The field at `path`, or null when an unset optional group or another variant is in the
/// way.
pub fn getAt(
    comptime T: type,
    comptime path: []const u8,
    root: *const T,
) ?*const PathType(T, path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const head = comptime path[0..dot];
        if (comptime isChoice(T)) {
            if (!std.mem.eql(u8, @tagName(std.meta.activeTag(root.*)), head)) return null;
            return getAt(@FieldType(T, head), path[dot + 1 ..], &@field(root.*, head));
        }
        const slot = &@field(root, head);
        if (@typeInfo(@TypeOf(slot.*)) == .optional) {
            const set = &(slot.* orelse return null);
            return getAt(Unwrap(@TypeOf(slot.*)), path[dot + 1 ..], set);
        }
        return getAt(@TypeOf(slot.*), path[dot + 1 ..], slot);
    } else return &@field(root, path);
}

const testing = std.testing;

const Tls = struct { cert: []const u8 = "", key: []const u8 };
const Listener = struct { port: u16 = 8080, tls: ?Tls = null };
const Storage = union(enum) { disk: struct { path: []const u8 = "/var" }, memory };
const Settings = struct {
    public: Listener = .{},
    admin: ?Listener = null,
    storage: Storage = .memory,
    token: []const u8,
    name: ?[]const u8 = null,
};

test "kinds" {
    try testing.expect(isGroup(Listener));
    try testing.expect(isChoice(Storage));
    try testing.expect(isList([]const u16));
    try testing.expect(!isList([]const u8));
    try testing.expectEqual(Tls, Unwrap(?Tls));
}

test "paths through groups, optionals, and choices" {
    try testing.expectEqual(u16, PathType(Settings, "admin.port"));
    try testing.expectEqual([]const u8, PathType(Settings, "storage.disk.path"));
    var s = initDefaults(Settings);
    try testing.expectEqual(null, getAt(Settings, "admin.port", &s));
    ptrAt(Settings, "admin.port", &s).* = 9000;
    try testing.expectEqual(9000, s.admin.?.port);
    try testing.expectEqual(null, getAt(Settings, "storage.disk.path", &s));
    try testing.expectEqualStrings("/var", ptrAt(Settings, "storage.disk.path", &s).*);
    try testing.expect(s.storage == .disk);
    try testing.expectEqual(8080, getAt(Settings, "public.port", &s).?.*);
}

test isRequired {
    try testing.expect(isRequired(Settings, "token"));
    try testing.expect(!isRequired(Settings, "name"));
    try testing.expect(!isRequired(Settings, "public"));
    try testing.expect(isRequired(Settings, "public.tls.key"));
    try testing.expect(!isRequired(Settings, "storage.disk.path"));
}
