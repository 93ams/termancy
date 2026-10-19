//! How a settings struct is spelled in configuration, per place: each field's key, an old
//! key still read, its environment variable, how lists merge across layers. What the values
//! mean (help, secrecy, deprecation, checks) comes from `field` specs, by type.
//!
//! ```zig
//! const app_settings = cfg.settings(Settings, Specs, .{ .fields = .{
//!     .public = .{ .fields = .{ .port = .{ .env = "PORT" } } }, // $PORT is public.port only
//!     .plugins = .{ .merge = .append },                        // later files add plugins
//!     .timeout = .{ .renamed_from = "request_timeout" },       // the old key still works
//!     .tls_cert = .{ .key = "certificate" },                   // stored under another key
//! } });
//! const s = try config.decode(app_settings, .{}, &diag);
//! ```
//!
//! Every function that takes a settings type also takes a plain struct, read with no specs
//! and every field under its own name.

const std = @import("std");
const field = @import("field");
const Value = @import("value.zig").Value;

/// How layers combine a list: the later one replaces it, or adds to it.
pub const Merge = @import("Config.zig").Merge;

/// The spellings of a settings type `T`: `.fields` names each field's place.
pub fn Keys(comptime T: type) type {
    if (comptime isTable(T)) return struct { fields: PlaceFields(T) = .{} };
    return struct {};
}

/// The options of one place a value of type `V` is at.
pub fn Place(comptime V: type) type {
    const C = field.Unwrap(V);
    if (C == void) return struct {};
    if (comptime isTable(C)) return struct {
        /// The key, instead of the field name.
        key: ?[]const u8 = null,
        /// An old key (a path below the parent table) still read, with a warning.
        renamed_from: ?[]const u8 = null,
        fields: PlaceFields(C) = .{},
    };
    if (comptime isChoice(C)) return struct {
        key: ?[]const u8 = null,
        renamed_from: ?[]const u8 = null,
        /// Names the variant: `STORAGE=s3`.
        env: ?[]const u8 = null,
        /// Each variant's key (instead of its name) and its own fields' places.
        variants: PlaceFields(C) = .{},
    };
    if (field.isList(C) and isTable(@typeInfo(C).pointer.child)) return struct {
        key: ?[]const u8 = null,
        renamed_from: ?[]const u8 = null,
        merge: Merge = .replace,
        /// The places of each element's fields.
        fields: PlaceFields(@typeInfo(C).pointer.child) = .{},
    };
    return struct {
        key: ?[]const u8 = null,
        renamed_from: ?[]const u8 = null,
        /// Read from this environment variable (`Config` binds it).
        env: ?[]const u8 = null,
        /// For a list: whether later layers replace it or add to it.
        merge: Merge = .replace,
    };
}

/// One `Place` per field of the struct `T`, or per variant of the choice `T`.
pub fn PlaceFields(comptime T: type) type {
    const names = field.fieldNames(T);
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (field.fieldTypes(T), &types, &attrs) |F, *t, *a| {
        t.* = Place(F);
        a.* = .{ .default_value_ptr = &@as(Place(F), .{}) };
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

/// A settings type: `T`, what its fields mean (`S`, a `field.Set`), and how they are
/// spelled (`keys`). Pass it wherever `cfg` takes a type to decode, encode, or describe.
pub fn settings(comptime T: type, comptime S: type, comptime keys: Keys(T)) type {
    if (comptime !field.isSet(S)) @compileError("cfg.settings: " ++ @typeName(S) ++ " is not a field.Set");
    return struct {
        pub const is_cfg_settings = true;
        pub const Type = T;
        pub const Specs = S;
        /// The place of the root.
        pub const root: Place(T) = if (isTable(T)) .{ .fields = keys.fields } else .{};
    };
}

/// `X` as a settings type: itself, or a plain type with no specs and every field under
/// its own name.
pub fn Of(comptime X: type) type {
    if (@typeInfo(X) == .@"struct" and @hasDecl(X, "is_cfg_settings")) return X;
    return settings(X, field.none, .{});
}

/// A struct read as a table of settings: not a `Value`, not a type with `parse`.
pub fn isTable(comptime T: type) bool {
    return T != Value and field.isGroup(T);
}

/// A tagged union read as a choice between variants; `Value` is a value, not a choice.
pub fn isChoice(comptime T: type) bool {
    return T != Value and field.isChoice(T);
}

/// The key a field (or variant) is under at `place`.
pub fn keyOf(comptime place: anytype, comptime name: []const u8) []const u8 {
    const P = @TypeOf(place);
    return if (@hasField(P, "key")) place.key orelse name else name;
}

fn join(comptime prefix: []const u8, comptime key: []const u8) []const u8 {
    return if (prefix.len == 0) key else prefix ++ "." ++ key;
}

/// The dotted key of every value of `X` its specs mark secret.
pub fn secretKeys(comptime X: type) []const []const u8 {
    const Set = Of(X);
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: []const []const u8 = &.{};
        var unused: []const EnvBinding = &.{};
        collect(Set.Type, Set.Specs, Set.root, "", .secret, &out, &unused);
        break :blk out;
    };
}

/// A key and the environment variable its place names with `.env`.
pub const EnvBinding = struct { key: []const u8, env: []const u8 };

/// The dotted key of every value of `X` whose place names an environment variable.
pub fn envBindings(comptime X: type) []const EnvBinding {
    const Set = Of(X);
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var keys: []const []const u8 = &.{};
        var bindings: []const EnvBinding = &.{};
        collect(Set.Type, Set.Specs, Set.root, "", .env, &keys, &bindings);
        break :blk bindings;
    };
}

/// The keys of lists whose place sets `.merge = .append`.
pub fn appendKeys(comptime X: type) []const []const u8 {
    const Set = Of(X);
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: []const []const u8 = &.{};
        var unused: []const EnvBinding = &.{};
        collect(Set.Type, Set.Specs, Set.root, "", .append, &out, &unused);
        break :blk out;
    };
}

/// Every key `X` reads: each leaf, each choice (it names the variant), and each list of
/// tables, as a whole.
pub fn structKeys(comptime X: type) []const []const u8 {
    const Set = Of(X);
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: []const []const u8 = &.{};
        if (!isTable(field.Unwrap(Set.Type))) break :blk &.{""};
        var unused: []const EnvBinding = &.{};
        collect(Set.Type, Set.Specs, Set.root, "", .leaf, &out, &unused);
        break :blk out;
    };
}

const What = enum { secret, env, append, leaf };

fn collect(
    comptime T: type,
    comptime S: type,
    comptime place: anytype,
    comptime prefix: []const u8,
    comptime what: What,
    comptime keys: *[]const []const u8,
    comptime bindings: *[]const EnvBinding,
) void {
    const C = field.Unwrap(T);
    if (isTable(C)) {
        const spec = S.of(C);
        for (field.fieldNames(C), field.fieldTypes(C)) |name, F| {
            const p = @field(place.fields, name);
            const key = join(prefix, keyOf(p, name));
            const F_ = field.Unwrap(F);
            const secret = @field(spec.fields, name).secret;
            if (what == .secret and secret) {
                keys.* = keys.* ++ .{key};
                continue;
            }
            if (@hasField(@TypeOf(p), "env")) if (p.env) |variable| if (what == .env) {
                bindings.* = bindings.* ++ .{EnvBinding{ .key = key, .env = variable }};
            };
            if (@hasField(@TypeOf(p), "merge")) {
                if (p.merge == .append and !field.isList(F_)) {
                    @compileError(key ++ ": .merge is for lists, found " ++ @typeName(F));
                }
                if (what == .append and p.merge == .append) keys.* = keys.* ++ .{key};
            }
            if (isTable(F_) or isChoice(F_)) {
                if (what == .leaf and isChoice(F_)) keys.* = keys.* ++ .{key};
                collect(F_, S, p, key, what, keys, bindings);
            } else if (what == .leaf) {
                keys.* = keys.* ++ .{key};
            }
        }
    } else if (isChoice(C)) {
        const spec = S.of(C);
        for (field.fieldNames(C), field.fieldTypes(C)) |name, P| {
            if (P == void) continue;
            const p = @field(place.variants, name);
            const key = join(prefix, keyOf(p, name));
            if (what == .secret and @field(spec.fields, name).secret) {
                keys.* = keys.* ++ .{key};
                continue;
            }
            collect(P, S, p, key, what, keys, bindings);
        }
    }
}

const testing = std.testing;

const Tls = struct { cert: []const u8 = "", key: []const u8 = "" };
const Listener = struct { host: []const u8 = "", port: u16 = 80, tls: ?Tls = null };
const Example = struct {
    public: Listener = .{},
    storage: union(enum) { disk: struct { path: []const u8 = "" }, memory } = .memory,
    plugins: []const []const u8 = &.{},
    token: ?[]const u8 = null,
    mirrors: []const Listener = &.{},
};

const tls_spec: field.Spec(Tls) = .{ .fields = .{ .key = .{ .secret = true } } };
const example_spec: field.Spec(Example) = .{ .fields = .{ .token = .{ .secret = true } } };

const example = settings(Example, field.Set(.{ tls_spec, example_spec }), .{ .fields = .{
    .public = .{ .fields = .{ .port = .{ .env = "PORT" }, .host = .{ .key = "address" } } },
    .plugins = .{ .merge = .append },
    .token = .{ .env = "TOKEN" },
} });

test "keys, secrets, variables, and appends follow places and specs" {
    const keys = comptime structKeys(example);
    const expected = [_][]const u8{
        "public.address",
        "public.port",
        "public.tls.cert",
        "public.tls.key",
        "storage",
        "storage.disk.path",
        "plugins",
        "token",
        "mirrors",
    };
    try testing.expectEqual(expected.len, keys.len);
    for (expected, keys) |e, k| try testing.expectEqualStrings(e, k);

    const secrets = comptime secretKeys(example);
    try testing.expectEqual(2, secrets.len);
    try testing.expectEqualStrings("public.tls.key", secrets[0]);
    try testing.expectEqualStrings("token", secrets[1]);

    const env = comptime envBindings(example);
    try testing.expectEqual(2, env.len);
    try testing.expectEqualStrings("public.port", env[0].key);
    try testing.expectEqualStrings("PORT", env[0].env);

    const appends = comptime appendKeys(example);
    try testing.expectEqual(1, appends.len);
    try testing.expectEqualStrings("plugins", appends[0]);
}

test "a plain struct is its own settings" {
    try testing.expectEqualStrings("public.host", (comptime structKeys(Example))[0]);
    try testing.expectEqual(0, (comptime secretKeys(Example)).len);
    try testing.expectEqualStrings("", (comptime structKeys(u16))[0]);
}
