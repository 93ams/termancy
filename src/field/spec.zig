//! What settings mean, by type: a `Spec(T)` gives each field of `T` its help, secrecy,
//! deprecation, and checks, and `T` checks across its fields. A `Set` of specs applies each
//! wherever its type occurs, nested in a group, an optional, a list, or a choice.

const std = @import("std");
const check = @import("check.zig");
const path = @import("path.zig");

const Check = check.Check;

/// What `.each` checks: a list's elements. Other types have it too, so that giving it to
/// one is a clear error from `Set` rather than a type mismatch.
fn EachOf(comptime C: type) type {
    return if (path.isList(C)) @typeInfo(C).pointer.child else C;
}

/// What one field (or variant) of type `V` means.
pub fn Field(comptime V: type) type {
    const C = path.Unwrap(V);
    return struct {
        help: []const u8 = "",
        /// Never shown: not echoed, and redacted in help, documentation, messages, and
        /// written configuration.
        secret: bool = false,
        /// Still accepted, with this notice when set.
        deprecated: ?[]const u8 = null,
        /// Checks on the value (when set, for an optional).
        checks: []const Check(C) = &.{},
        /// Checks on each element of a list.
        each: []const Check(EachOf(C)) = &.{},
    };
}

/// One `Field` per field of the struct `T`, or per variant of the choice `T`.
pub fn Fields(comptime T: type) type {
    const names = path.fieldNames(T);
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (path.fieldTypes(T), &types, &attrs) |F, *t, *a| {
        t.* = Field(F);
        a.* = .{ .default_value_ptr = &@as(Field(F), .{}) };
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

/// The rules of a struct, or of a choice's variants.
pub fn Spec(comptime T: type) type {
    return struct {
        pub const Target = T;
        fields: Fields(T) = .{},
        /// Checks on the whole value, across its fields.
        checks: []const Check(T) = &.{},
    };
}

/// A set of specs, at most one per type: `field.Set(.{ app, server } ++ net.specs)`.
pub fn Set(comptime specs: anytype) type {
    comptime {
        @setEvalBranchQuota(100_000);
        const types = @typeInfo(@TypeOf(specs)).@"struct".field_types;
        for (types, 0..) |A, i| for (types[i + 1 ..]) |B| {
            if (A.Target == B.Target) @compileError("two specs for " ++ @typeName(A.Target));
        };
        for (specs) |s| {
            const T = @TypeOf(s).Target;
            for (path.fieldNames(T), path.fieldTypes(T)) |name, F| {
                if (@field(s.fields, name).each.len > 0 and !path.isList(path.Unwrap(F))) {
                    @compileError(@typeName(T) ++ "." ++ name ++ ": .each is for lists; use .checks");
                }
            }
        }
    }
    return struct {
        pub const is_spec_set = true;

        /// The spec for `V`, or an empty one.
        pub fn of(comptime V: type) Spec(V) {
            inline for (specs) |s| if (@TypeOf(s).Target == V) return s;
            return .{};
        }
    };
}

/// No specs: every field means only what its type says.
pub const none = Set(.{});

/// The spec of the field at the dotted `path_` of `T`: its parent type's entry in `S`.
pub fn specAt(
    comptime T: type,
    comptime S: type,
    comptime path_: []const u8,
) Field(path.PathType(T, path_)) {
    const dot = comptime std.mem.lastIndexOfScalar(u8, path_, '.') orelse
        return @field(S.of(T).fields, path_);
    const Parent = path.Unwrap(path.PathType(T, path_[0..dot]));
    return @field(S.of(Parent).fields, path_[dot + 1 ..]);
}

/// One step of the path to a failed value: a field (or variant) name, or a list index.
pub const Segment = union(enum) { field: []const u8, index: usize };

/// Which checks `validate` runs.
pub const Scope = enum {
    /// Every check.
    every,
    /// Only checks that need a whole value: a struct's checks across its fields (and a
    /// choice's), a list's own `.checks`, and checks on a group or variant as a whole;
    /// not the checks of single values, nor `.each`. For values whose single parts were
    /// checked as they were given, such as flags on a command line.
    whole,
};

/// Runs every check in `S` on `value` and everything in it, calling
/// `report.fail(path: []const Segment, message: []const u8, about: ?About) !void` for each
/// failure; `path` is empty for a check on the whole of `value`. Returns how many failed.
pub fn validate(comptime T: type, comptime S: type, value: T, report: anytype) !usize {
    var at: [max_depth]Segment = undefined;
    return walk(T, S, .every, &.{}, &.{}, value, &at, 0, report);
}

/// `validate` with a `scope`, leaving out the fields of the struct `T` named in `skip`
/// (checked elsewhere, such as settings checked once merged with their other sources).
pub fn validateExcept(
    comptime T: type,
    comptime S: type,
    comptime scope: Scope,
    value: T,
    report: anytype,
    comptime skip: []const []const u8,
) !usize {
    var at: [max_depth]Segment = undefined;
    const spec = comptime S.of(T);
    var failures: usize = 0;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const skipped = comptime for (skip) |s| {
            if (std.mem.eql(u8, s, name)) break true;
        } else false;
        if (!skipped) {
            at[0] = .{ .field = name };
            const f = @field(spec.fields, name);
            failures += try walk(@FieldType(T, name), S, scope, f.checks, f.each, @field(value, name), &at, 1, report);
        }
    }
    return failures + try run(T, spec.checks, value, at[0..0], report);
}

/// How deep `validate` follows nested settings.
pub const max_depth = 32;

fn walk(
    comptime V: type,
    comptime S: type,
    comptime scope: Scope,
    comptime checks: []const Check(path.Unwrap(V)),
    comptime each: anytype,
    value: V,
    at: *[max_depth]Segment,
    depth: usize,
    report: anytype,
) !usize {
    if (@typeInfo(V) == .optional) {
        const set = value orelse return 0;
        return walk(path.Unwrap(V), S, scope, checks, each, set, at, depth, report);
    }
    // A single value's checks ran when it was given, under `.whole`.
    const whole = path.isList(V) or path.isGroup(V) or path.isChoice(V);
    var failures = if (scope == .every or whole) try run(V, checks, value, at[0..depth], report) else 0;
    if (comptime path.isGroup(V)) {
        const spec = comptime S.of(V);
        inline for (@typeInfo(V).@"struct".field_names) |name| {
            at[depth] = .{ .field = name };
            const f = @field(spec.fields, name);
            failures += try walk(@FieldType(V, name), S, scope, f.checks, f.each, @field(value, name), at, depth + 1, report);
        }
        failures += try run(V, spec.checks, value, at[0..depth], report);
    } else if (comptime path.isChoice(V)) {
        const spec = comptime S.of(V);
        switch (value) {
            inline else => |payload, tag| {
                const name = @tagName(tag);
                at[depth] = .{ .field = name };
                const f = @field(spec.fields, name);
                failures += try walk(@TypeOf(payload), S, scope, f.checks, f.each, payload, at, depth + 1, report);
            },
        }
        failures += try run(V, spec.checks, value, at[0..depth], report);
    } else if (comptime path.isList(V)) {
        const Elem = @typeInfo(V).pointer.child;
        for (value, 0..) |item, i| {
            at[depth] = .{ .index = i };
            failures += try walk(Elem, S, scope, each, &.{}, item, at, depth + 1, report);
        }
    }
    return failures;
}

fn run(
    comptime V: type,
    comptime checks: []const Check(V),
    value: V,
    at: []const Segment,
    report: anytype,
) !usize {
    var failures: usize = 0;
    inline for (checks) |c| {
        var buffer: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        c.run(value, &w) catch |err| switch (err) {
            error.Invalid => {
                failures += 1;
                try report.fail(at, w.buffered(), c.about);
            },
            // A message longer than the buffer is cut short rather than lost.
            error.WriteFailed => {
                failures += 1;
                try report.fail(at, w.buffered(), c.about);
            },
        };
    }
    return failures;
}

/// Runs the checks a field at `path_` of `T` has, on one value of it (one element, for a
/// list's `.each`), writing the first failure's reason: for checking a value as it is
/// given, such as a flag on the command line or an answer to a prompt. Checks across
/// fields wait for `validate`.
pub fn checkOne(
    comptime T: type,
    comptime S: type,
    comptime path_: []const u8,
    value: path.Unwrap(path.PathType(T, path_)),
    w: *std.Io.Writer,
) check.Error!?check.About {
    const spec = comptime specAt(T, S, path_);
    inline for (spec.checks) |c| {
        c.run(value, w) catch |err| switch (err) {
            error.Invalid => return c.about,
            else => |e| return e,
        };
    }
    return null;
}

const testing = std.testing;

const Listener = struct { port: u16 = 8080, host: []const u8 = "0.0.0.0" };
const App = struct {
    public: Listener = .{},
    admin: ?Listener = null,
    tags: []const []const u8 = &.{},
    storage: union(enum) { disk: Listener, memory } = .memory,
};

fn reserved(port: u16, w: *std.Io.Writer) !void {
    if (port == 6000) return check.fail(w, "is reserved", .{});
}

fn distinct(a: App, w: *std.Io.Writer) !void {
    const admin = a.admin orelse return;
    if (admin.port == a.public.port) return check.fail(w, "ports clash", .{});
}

const listener: Spec(Listener) = .{ .fields = .{
    .port = .{ .help = "Port", .checks = &.{ .min(1), .from(reserved) } },
} };

const app: Spec(App) = .{
    .fields = .{ .tags = .{ .each = &.{.minLen(1)} } },
    .checks = &.{.from(distinct)},
};

const Specs = Set(.{ app, listener });

const Collect = struct {
    out: *std.Io.Writer,

    pub fn fail(r: Collect, at: []const Segment, message: []const u8, _: ?check.About) !void {
        for (at) |s| switch (s) {
            .field => |f| try r.out.print("{s}.", .{f}),
            .index => |i| try r.out.print("{d}.", .{i}),
        };
        try r.out.print(" {s}\n", .{message});
    }
};

test "every failure, wherever the type occurs, then the checks across fields" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const value: App = .{
        .public = .{ .port = 6000 },
        .admin = .{ .port = 6000 },
        .tags = &.{ "a", "" },
        .storage = .{ .disk = .{ .port = 0 } },
    };
    const failures = try validate(App, Specs, value, Collect{ .out = &out });
    try testing.expectEqualStrings(
        \\public.port. is reserved
        \\admin.port. is reserved
        \\tags.1. must be at least 1 long
        \\storage.disk.port. must be at least 1
        \\ ports clash
        \\
    , out.buffered());
    try testing.expectEqual(5, failures);
}

test validateExcept {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const value: App = .{ .public = .{ .port = 0 }, .tags = &.{""} };
    _ = try validateExcept(App, Specs, .every, value, Collect{ .out = &out }, &.{"public"});
    try testing.expectEqualStrings("tags.0. must be at least 1 long\n", out.buffered());
    // Only what needs a whole value: here, the check across `App`'s fields.
    out = .fixed(&buffer);
    const clash: App = .{ .admin = .{ .port = 0 }, .public = .{ .port = 0 }, .tags = &.{""} };
    _ = try validateExcept(App, Specs, .whole, clash, Collect{ .out = &out }, &.{});
    try testing.expectEqualStrings(" ports clash\n", out.buffered());
}

test checkOne {
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try testing.expectEqual(null, try checkOne(App, Specs, "public.port", 80, &w));
    const about = try checkOne(App, Specs, "admin.port", 0, &w);
    try testing.expectEqual(1, about.?.min.number.?);
    try testing.expectEqualStrings("must be at least 1", w.buffered());
}

test specAt {
    try testing.expectEqualStrings("Port", specAt(App, Specs, "storage.disk.port").help);
    try testing.expectEqualStrings("", specAt(App, none, "public.port").help);
}
