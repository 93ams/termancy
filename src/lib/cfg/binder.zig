//! The comptime data binder: one struct in, every source resolved out.
//!
//! ## The problem this solves
//!
//! `[measured]` the tree had **three** overlapping resolvers and none of them was
//! the whole chain:
//!
//!   * `cfg.Manager` applied defaults -> env -> JSON, but had no notion of a flag;
//!   * `loader.load` applied defaults -> env only, and its own header claimed a
//!     chain it did not implement;
//!   * `cli.parseFlags` applied flag > env, over a flags struct that is
//!     **hand-written separately** from the config struct.
//!
//! So the precedence a user experiences was assembled from three partial answers,
//! and the two structs could - and did - drift, because nothing tied the flag
//! `--api-key` to the config field `api_key` except a human remembering.
//!
//! Here there is one struct. Its fields are the keys, its defaults are the
//! defaults, its `meta` declares the environment name and the flag spelling, and
//! `flagSpecs` derives the flag table from it. Adding a field adds a flag, an env
//! mapping and a config key, or the build fails.
//!
//! ## Precedence, stated once
//!
//! ```text
//! flag  >  env  >  file  >  default
//! ```
//!
//! That order is not a convention this module follows, it is the **order of the
//! layer list the caller passes**, and that is the design. A caller that wants a
//! different chain writes a different list; the module has no opinion to get wrong.
//! `bind` sorts nothing and reorders nothing - it walks the layers as given and the
//! first layer that answers wins. So "which wins" is answerable by reading one
//! line of the caller, not by reading this file.
//!
//! ## Ownership
//!
//! A resolved value owns every string reachable from it. Rather than counting the
//! string fields and freeing a prefix on failure - which is what `loader.load` does
//! and what makes its teardown hard to follow - this records each allocation in a
//! list as it is made and frees the list. A partial construction is therefore
//! sound by construction rather than by an index that has to stay in step.

const std = @import("std");
const assert = std.debug.assert;
const scalar = @import("scalar.zig");

/// Where a value came from.
///
/// Ordered, so `>` compares precedence and a caller can ask "was this overridden"
/// without a second table.
pub const Source = enum(u8) {
    /// The struct's own field default. Always the lowest.
    default = 0,
    /// A config file.
    file = 1,
    /// The process environment.
    env = 2,
    /// A command-line flag.
    flag = 3,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .default => "DEFAULT",
            .file => "FILE",
            .env => "ENV",
            .flag => "FLAG",
        };
    }
};

pub const Error = error{
    /// A field with no default, not optional, that no layer supplied.
    MissingValue,
    /// A layer supplied text that does not fit the field's type.
    InvalidValue,
    /// A nested struct field had no way to be expressed as a single string, and
    /// no layer supplied its leaves.
    UnrepresentableField,
    OutOfMemory,
};

/// One source of values.
///
/// A function pointer plus a context rather than a tagged union, because the
/// sources a caller has are already heterogeneous - a `StringHashMap`, an
/// `Environ.Map`, a table built from parsed argv - and wrapping each in a variant
/// would mean this module knowing about all of them.
pub const Layer = struct {
    source: Source,
    ctx: ?*const anyopaque = null,
    /// Returns the raw text for `key`, or null when this layer has no opinion.
    ///
    /// The key is the **field name**, except for an `env` layer where it is the
    /// environment variable name declared in `meta` - see `KeySpace`.
    lookup: *const fn (ctx: ?*const anyopaque, key: []const u8) ?[]const u8,

    pub fn get(self: Layer, key: []const u8) ?[]const u8 {
        return self.lookup(self.ctx, key);
    }

    /// A layer backed by an environment map, keyed by the `meta`-declared variable
    /// name.
    pub fn environment(env_map: *const std.process.Environ.Map) Layer {
        return .{
            .source = .env,
            .ctx = env_map,
            .lookup = struct {
                fn look(ctx: ?*const anyopaque, key: []const u8) ?[]const u8 {
                    const table: *const std.process.Environ.Map = @ptrCast(@alignCast(ctx.?));
                    return table.get(key);
                }
            }.look,
        };
    }

    /// A layer backed by a string map, keyed by field name. This is the shape a
    /// config file parse or a parsed argv both reduce to.
    pub fn map(source: Source, values: *const std.StringHashMapUnmanaged([]const u8)) Layer {
        assert(source != .default);
        return .{
            .source = source,
            .ctx = values,
            .lookup = struct {
                fn look(ctx: ?*const anyopaque, key: []const u8) ?[]const u8 {
                    const table: *const std.StringHashMapUnmanaged([]const u8) =
                        @ptrCast(@alignCast(ctx.?));
                    return table.get(key);
                }
            }.look,
        };
    }
};

// The one asymmetry in the design, stated rather than hidden: an environment layer
// is asked for the variable name declared in `meta` (`API_KEY`), while a file or
// flag layer is asked for the field name (`api_key`). That is because the
// environment's namespace belongs to the *user's shell*, not to this struct, so
// its name is the user's to choose and has to be declared; a config key and a flag
// are the struct's own vocabulary. See `resolveLeaf`.

/// A resolved configuration, its provenance, and everything it owns.
pub fn Binding(comptime ConfigT: type) type {
    const field_count = @typeInfo(ConfigT).@"struct".field_names.len;

    return struct {
        const Self = @This();

        value: ConfigT,
        /// Where each top-level field's value came from, parallel to
        /// `@typeInfo(ConfigT).@"struct".field_names`.
        sources: [field_count]Source,
        /// Every allocation this binding owns. Freeing the list frees the value.
        owned: std.ArrayListUnmanaged([]u8),
        allocator: std.mem.Allocator,

        /// Allocates nothing. Names is deliberately `Binding(ConfigT)` and takes no
        /// allocator, because a partially built binding must not be freeable.
        pub fn initPlaceholder(allocator: std.mem.Allocator) Self {
            return .{
                .value = undefined,
                .sources = @splat(.default),
                .owned = .empty,
                .allocator = allocator,
            };
        }

        /// Frees every string this binding owns.
        pub fn deinit(self: *Self) void {
            for (self.owned.items) |slice| self.allocator.free(slice);
            self.owned.deinit(self.allocator);
            self.* = undefined;
        }

        /// Where `field_name`'s value came from.
        pub fn sourceOf(self: Self, comptime field_name: []const u8) Source {
            const fnames0 = @typeInfo(ConfigT).@"struct".field_names;
            inline for (fnames0, 0..) |_, i| {
                const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(i)));
                if (comptime std.mem.eql(u8, field.name, field_name)) return self.sources[i];
            }
            @compileError("no field named '" ++ field_name ++ "' in " ++ @typeName(ConfigT));
        }

        /// Whether `field_name`'s value came from anywhere other than the struct
        /// default. The question a `config inspect` command actually asks.
        pub fn wasOverridden(self: Self, comptime field_name: []const u8) bool {
            return self.sourceOf(field_name) != .default;
        }
    };
}

/// Resolves `ConfigT` from `layers`, highest precedence first, falling back to the
/// struct's own field defaults.
pub fn bind(
    comptime ConfigT: type,
    allocator: std.mem.Allocator,
    layers: []const Layer,
) Error!Binding(ConfigT) {
    assert(layers.len <= 8);

    var result = Binding(ConfigT).initPlaceholder(allocator);
    errdefer {
        for (result.owned.items) |slice| allocator.free(slice);
        result.owned.deinit(allocator);
    }

    const fnames1 = @typeInfo(ConfigT).@"struct".field_names;
    inline for (fnames1, 0..) |_, index| {
        const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(index)));
        // A nested struct is resolved leaf by leaf, with a dotted key prefix, so a
        // `tls` group does not have to be one opaque string.
        if (comptime isNestedStruct(field.type)) {
            // The group's own name is the key prefix, so a leaf is addressed as
            // `tls.enabled`. Passing an empty prefix here was a real bug: the
            // group's fields became reachable as `enabled` and `cert`, and a file
            // that set `tls.enabled` silently did nothing.
            const nested = try bindNested(
                field.type,
                allocator,
                layers,
                field.name ++ ".",
                &result.owned,
            );
            @field(result.value, field.name) = nested.value;
            // A group's provenance is the highest-precedence layer that supplied
            // any of its leaves: that is the answer to "did anything override this
            // group", which is the question a report asks.
            result.sources[index] = nested.highest;
            continue;
        }

        const leaf = try resolveLeaf(
            ConfigT,
            field.type,
            "",
            field.name,
            field.attrs.default_value_ptr,
            allocator,
            layers,
            &result.owned,
        );
        @field(result.value, field.name) = leaf.value;
        result.sources[index] = leaf.source;
    }

    return result;
}

/// A resolved leaf: its value, and which layer supplied it.
fn Leaf(comptime T: type) type {
    return struct { value: T, source: Source };
}

/// The outcome of resolving a nested group.
fn Nested(comptime T: type) type {
    return struct { value: T, highest: Source };
}

/// Resolves one group's fields.
///
/// `MetaOwner` is the type whose `meta` table declares this group's environment
/// names, and it is threaded explicitly rather than looked up through a global.
/// The first draft of this file used a comptime module-level variable for it,
/// which is a data race waiting for the day two bindings run on two threads - and
/// a `var` of type `type` that no test would ever have exercised.
fn bindNested(
    comptime T: type,
    allocator: std.mem.Allocator,
    layers: []const Layer,
    comptime prefix: []const u8,
    owned: *std.ArrayListUnmanaged([]u8),
) Error!Nested(T) {
    var out: T = undefined;
    var highest: Source = .default;

    const fnames2 = @typeInfo(T).@"struct".field_names;
    inline for (fnames2, 0..) |_, fidx2| {
        const field = std.meta.fieldInfo(T, @fromBackingInt(@intCast(fidx2)));
        if (comptime isNestedStruct(field.type)) {
            const nested = try bindNested(
                field.type,
                allocator,
                layers,
                prefix ++ field.name ++ ".",
                owned,
            );
            @field(out, field.name) = nested.value;
            if (@backingInt(nested.highest) > @backingInt(highest)) highest = nested.highest;
            continue;
        }

        const leaf = try resolveLeaf(
            T,
            field.type,
            prefix,
            field.name,
            field.attrs.default_value_ptr,
            allocator,
            layers,
            owned,
        );
        @field(out, field.name) = leaf.value;
        if (@backingInt(leaf.source) > @backingInt(highest)) highest = leaf.source;
    }

    return .{ .value = out, .highest = highest };
}

/// Resolves one leaf field.
///
/// `key_prefix` is empty at the top level and `"tls."` inside a group, so a file or
/// flag layer is asked for `tls.enabled` while the environment layer is asked for
/// the *leaf*'s declared variable - a group has no environment variable of its own,
/// because `TLS_ENABLED` is a leaf and `TLS` is not something a shell can express.
fn resolveLeaf(
    comptime MetaOwner: type,
    comptime FieldT: type,
    comptime key_prefix: []const u8,
    comptime leaf_name: []const u8,
    default_ptr: ?*const anyopaque,
    allocator: std.mem.Allocator,
    layers: []const Layer,
    owned: *std.ArrayListUnmanaged([]u8),
) Error!Leaf(FieldT) {
    const key = comptime key_prefix ++ leaf_name;

    // The layers are walked in the order given, so the caller's list *is* the
    // precedence rule. No sorting, and no comparison of `Source` values anywhere.
    for (layers) |layer| {
        const lookup_key: []const u8 = switch (layer.source) {
            .env => environmentName(MetaOwner, leaf_name) orelse continue,
            .file, .flag => key,
            .default => continue,
        };

        const raw = layer.get(lookup_key) orelse continue;
        const parsed = try scalar.parseValue(FieldT, raw, allocator);
        // `parseValue` dupes a string; record it so teardown is a list walk rather
        // than an index that has to stay in step with the field order.
        if (comptime isStringLike(FieldT)) try recordOwned(owned, parsed, allocator);
        return .{ .value = parsed, .source = layer.source };
    }

    // No layer had an opinion: fall back to the struct's own default.
    if (default_ptr) |ptr| {
        const default: *align(1) const FieldT = @ptrCast(ptr);
        if (comptime isStringLike(FieldT)) {
            // A slice default points at a comptime literal, so it must be copied
            // for `deinit` to be able to free it. Skipping this is the leak the
            // loader documented at length.
            const copied = try dupeStringLike(FieldT, default.*, allocator);
            try recordOwned(owned, copied, allocator);
            return .{ .value = copied, .source = .default };
        }
        return .{ .value = default.*, .source = .default };
    }

    // No default and no layer. An optional can represent "absent", and a bool can
    // honestly be false; anything else is a declaration bug the caller has to hear
    // about rather than a value to invent.
    if (comptime @typeInfo(FieldT) == .optional) {
        return .{ .value = null, .source = .default };
    }
    if (comptime FieldT == bool) {
        return .{ .value = false, .source = .default };
    }
    return error.MissingValue;
}

/// Adds an allocation to the binding's owned list.
fn recordOwned(
    owned: *std.ArrayListUnmanaged([]u8),
    value: anytype,
    allocator: std.mem.Allocator,
) Error!void {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .optional) {
        if (value) |slice| try owned.append(allocator, @constCast(slice));
        return;
    }
    if (comptime isStringLike(T)) try owned.append(allocator, @constCast(value));
}

fn dupeStringLike(comptime T: type, value: T, allocator: std.mem.Allocator) Error!T {
    if (comptime @typeInfo(T) == .optional) {
        const inner = value orelse return null;
        return try allocator.dupe(u8, inner);
    }
    return try allocator.dupe(u8, value);
}

/// True for `[]const u8` and `?[]const u8`.
fn isStringLike(comptime T: type) bool {
    const RealType = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    if (@typeInfo(RealType) != .pointer) return false;
    const p = @typeInfo(RealType).pointer;
    return p.size == .slice and p.child == u8;
}

/// True for a struct that is a group of fields rather than a value.
fn isNestedStruct(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    // `DurationMs` and `ByteSize` are structs, but they are *values*: they parse
    // from one string and are handled by `scalar.parseValue`.
    if (T == scalar) return false;
    if (T == scalar.ByteSize) return false;
    return true;
}

/// The `meta`-declared environment variable for `leaf_name` on `MetaOwner`, or null.
///
/// `MetaOwner` is the type that declares the `meta` table for this field: the
/// config type itself at the top level, or the group's own type inside a group. A
/// group declares its own table, so `Tls` names `TLS_ENABLED` for its `enabled`
/// field - `TLS` alone is not something a shell can express.
fn environmentName(comptime MetaOwner: type, comptime leaf_name: []const u8) ?[]const u8 {
    if (!@hasDecl(MetaOwner, "meta")) return null;
    const MetaT = @TypeOf(MetaOwner.meta);
    if (!@hasField(MetaT, leaf_name)) return null;
    const entry = @field(MetaOwner.meta, leaf_name);
    if (!@hasField(@TypeOf(entry), "env")) return null;
    return entry.env;
}

/// One flag derived from the struct.
pub const FlagSpec = struct {
    /// The struct field this flag sets.
    field_name: []const u8,
    /// `--field-name`.
    long: []const u8,
    /// `-f`, from `meta.<field>.short`, when declared.
    short: ?[]const u8,
    help: []const u8,
    env: ?[]const u8,
    type_name: []const u8,
    /// True when the field has no default and is not optional, so a caller must
    /// supply it from somewhere.
    required: bool,
};

/// Derives the flag table for `ConfigT`.
///
/// This is the half of "auto-generate flags" that can be stated without a
/// particular parser: the names, the help text, the environment mapping and which
/// flags are required all come from the struct, so a flag cannot exist without a
/// field and a field cannot exist without a flag.
pub fn flagSpecs(comptime ConfigT: type) [@typeInfo(ConfigT).@"struct".field_names.len]FlagSpec {
    const fields = @typeInfo(ConfigT).@"struct".field_names;
    var specs: [fields.len]FlagSpec = undefined;

    inline for (fields, 0..) |_, i| {
        const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(i)));
        specs[i] = .{
            .field_name = field.name,
            .long = "--" ++ field.name,
            .short = comptime metaField(ConfigT, field.name, "short"),
            .help = comptime metaField(ConfigT, field.name, "help") orelse "",
            .env = comptime metaField(ConfigT, field.name, "env"),
            .type_name = @typeName(field.type),
            .required = comptime field.attrs.default_value_ptr == null and
                @typeInfo(field.type) != .optional,
        };
    }
    return specs;
}

/// Reads `meta.<field_name>.<attribute>` when both exist.
fn metaField(
    comptime ConfigT: type,
    comptime field_name: []const u8,
    comptime attribute: []const u8,
) ?[]const u8 {
    if (!@hasDecl(ConfigT, "meta")) return null;
    const MetaT = @TypeOf(ConfigT.meta);
    if (!@hasField(MetaT, field_name)) return null;
    const entry = @field(ConfigT.meta, field_name);
    if (!@hasField(@TypeOf(entry), attribute)) return null;
    const value = @field(entry, attribute);
    if (@TypeOf(value) == ?[]const u8) return value;
    return value;
}

const testing = std.testing;

/// The struct every test below binds. One declaration, and the flags, the
/// environment names and the config keys all come from it.
const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    workers: u8 = 4,
    debug: bool = false,
    rate: f64 = 1.5,
    mode: Mode = .strict,
    api_key: ?[]const u8 = null,
    tls: Tls = .{},

    pub const Mode = enum { strict, relaxed };

    pub const Tls = struct {
        enabled: bool = false,
        cert: ?[]const u8 = null,
    };

    pub const meta = .{
        .host = .{ .env = "SNEK_HOST", .short = "H", .help = "Interface to bind" },
        .port = .{ .env = "SNEK_PORT", .short = "p", .help = "Port to listen on" },
        .api_key = .{ .env = "SNEK_API_KEY", .secret = true },
        .debug = .{ .env = "SNEK_DEBUG" },
        .mode = .{ .env = "SNEK_MODE" },
        .workers = .{ .env = "SNEK_WORKERS" },
        .rate = .{ .env = "SNEK_RATE" },
    };
};

fn envFrom(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

fn stringMap(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8){};
    for (pairs) |pair| try map.put(allocator, pair[0], pair[1]);
    return map;
}

test "with no layers, every field takes its struct default" {
    var binding = try bind(ServerConfig, testing.allocator, &.{});
    defer binding.deinit();

    try testing.expectEqualStrings("127.0.0.1", binding.value.host);
    try testing.expectEqual(@as(u16, 8080), binding.value.port);
    try testing.expectEqual(@as(u8, 4), binding.value.workers);
    try testing.expect(!binding.value.debug);
    try testing.expectEqual(@as(f64, 1.5), binding.value.rate);
    try testing.expectEqual(ServerConfig.Mode.strict, binding.value.mode);
    try testing.expectEqual(@as(?[]const u8, null), binding.value.api_key);
    try testing.expect(!binding.value.tls.enabled);

    try testing.expectEqual(Source.default, binding.sourceOf("port"));
    try testing.expect(!binding.wasOverridden("port"));
}

test "the environment supplies a value and the provenance records it" {
    var env = try envFrom(&.{.{ "SNEK_PORT", "9000" }});
    defer env.deinit();

    var binding = try bind(ServerConfig, testing.allocator, &.{Layer.environment(&env)});
    defer binding.deinit();

    try testing.expectEqual(@as(u16, 9000), binding.value.port);
    try testing.expectEqual(Source.env, binding.sourceOf("port"));
    try testing.expect(binding.wasOverridden("port"));
    // Untouched fields stay at their default and say so.
    try testing.expectEqual(Source.default, binding.sourceOf("host"));
}

test "a field with no meta.env is unreachable from the environment" {
    // `tls` declares no variable, so a variable that happens to share its name is
    // not consulted. Without this the environment could set a field nobody asked
    // it to, which is how a config surface grows by accident.
    var env = try envFrom(&.{.{ "tls", "true" }});
    defer env.deinit();

    var binding = try bind(ServerConfig, testing.allocator, &.{Layer.environment(&env)});
    defer binding.deinit();

    try testing.expect(!binding.value.tls.enabled);
    try testing.expectEqual(Source.default, binding.sourceOf("tls"));
}

test "the caller's layer order is the precedence rule" {
    // flag > env > file, stated as a list rather than as logic inside the binder.
    var env = try envFrom(&.{.{ "SNEK_HOST", "from-env" }});
    defer env.deinit();
    var file = try stringMap(testing.allocator, &.{.{ "host", "from-file" }});
    defer file.deinit(testing.allocator);
    var flags = try stringMap(testing.allocator, &.{.{ "host", "from-flag" }});
    defer flags.deinit(testing.allocator);

    var binding = try bind(ServerConfig, testing.allocator, &.{
        Layer.map(.flag, &flags),
        Layer.environment(&env),
        Layer.map(.file, &file),
    });
    defer binding.deinit();

    try testing.expectEqualStrings("from-flag", binding.value.host);
    try testing.expectEqual(Source.flag, binding.sourceOf("host"));
}

test "and reversing the same layers reverses the answer" {
    // The same three layers, ordered differently, produce the other winner. If
    // this test and the one above both pass, precedence really is the list order
    // and not something encoded in the binder.
    var env = try envFrom(&.{.{ "SNEK_HOST", "from-env" }});
    defer env.deinit();
    var file = try stringMap(testing.allocator, &.{.{ "host", "from-file" }});
    defer file.deinit(testing.allocator);
    var flags = try stringMap(testing.allocator, &.{.{ "host", "from-flag" }});
    defer flags.deinit(testing.allocator);

    var binding = try bind(ServerConfig, testing.allocator, &.{
        Layer.map(.file, &file),
        Layer.environment(&env),
        Layer.map(.flag, &flags),
    });
    defer binding.deinit();

    // `file` is first, so it wins: nothing about `flag` outranks `file` except the
    // position the caller gave it.
    try testing.expectEqualStrings("from-file", binding.value.host);
    try testing.expectEqual(Source.file, binding.sourceOf("host"));
}

test "a lower layer fills what a higher one does not mention" {
    var env = try envFrom(&.{.{ "SNEK_PORT", "7000" }});
    defer env.deinit();
    var file = try stringMap(testing.allocator, &.{.{ "host", "file-host" }});
    defer file.deinit(testing.allocator);

    var binding = try bind(ServerConfig, testing.allocator, &.{
        Layer.environment(&env),
        Layer.map(.file, &file),
    });
    defer binding.deinit();

    try testing.expectEqual(@as(u16, 7000), binding.value.port);
    try testing.expectEqualStrings("file-host", binding.value.host);
    try testing.expectEqual(@as(u8, 4), binding.value.workers);
}

test "every scalar shape coerces from text" {
    var env = try envFrom(&.{
        .{ "SNEK_HOST", "0.0.0.0" },
        .{ "SNEK_PORT", "443" },
        .{ "SNEK_WORKERS", "32" },
        .{ "SNEK_DEBUG", "1" },
        .{ "SNEK_RATE", "2.25" },
        .{ "SNEK_MODE", "relaxed" },
        .{ "SNEK_API_KEY", "hunter2" },
    });
    defer env.deinit();

    var binding = try bind(ServerConfig, testing.allocator, &.{Layer.environment(&env)});
    defer binding.deinit();

    try testing.expectEqualStrings("0.0.0.0", binding.value.host);
    try testing.expectEqual(@as(u16, 443), binding.value.port);
    try testing.expectEqual(@as(u8, 32), binding.value.workers);
    try testing.expect(binding.value.debug);
    try testing.expectEqual(@as(f64, 2.25), binding.value.rate);
    try testing.expectEqual(ServerConfig.Mode.relaxed, binding.value.mode);
    // The optional string is the case `loader.load` got wrong for a long time: an
    // optional field silently kept its default no matter what the environment said.
    try testing.expectEqualStrings("hunter2", binding.value.api_key.?);
}

test "nested groups are addressed by dotted key and resolved field by field" {
    var file = try stringMap(testing.allocator, &.{
        .{ "tls.enabled", "true" },
        .{ "tls.cert", "/etc/cert.pem" },
    });
    defer file.deinit(testing.allocator);

    var binding = try bind(ServerConfig, testing.allocator, &.{Layer.map(.file, &file)});
    defer binding.deinit();

    try testing.expect(binding.value.tls.enabled);
    try testing.expectEqualStrings("/etc/cert.pem", binding.value.tls.cert.?);
    // The group's provenance is the highest layer that touched any leaf.
    try testing.expectEqual(Source.file, binding.sourceOf("tls"));
}

test "text that does not fit the field is an error, not a silent default" {
    var env = try envFrom(&.{.{ "SNEK_PORT", "not-a-number" }});
    defer env.deinit();

    try testing.expectError(error.InvalidValue, bind(
        ServerConfig,
        testing.allocator,
        &.{Layer.environment(&env)},
    ));
}

test "an enum value outside the declaration is rejected" {
    var env = try envFrom(&.{.{ "SNEK_MODE", "turbo" }});
    defer env.deinit();

    try testing.expectError(error.InvalidValue, bind(
        ServerConfig,
        testing.allocator,
        &.{Layer.environment(&env)},
    ));
}

test "a required field nothing supplies is reported rather than invented" {
    const Required = struct {
        token: []const u8,
    };

    try testing.expectError(error.MissingValue, bind(Required, testing.allocator, &.{}));

    var env = try envFrom(&.{.{ "token", "unused" }});
    defer env.deinit();
    // `token` declares no `meta.env`, so the environment cannot reach it either.
    try testing.expectError(error.MissingValue, bind(
        Required,
        testing.allocator,
        &.{Layer.environment(&env)},
    ));

    var flags = try stringMap(testing.allocator, &.{.{ "token", "from-a-flag" }});
    defer flags.deinit(testing.allocator);
    var binding = try bind(Required, testing.allocator, &.{Layer.map(.flag, &flags)});
    defer binding.deinit();
    try testing.expectEqualStrings("from-a-flag", binding.value.token);
    try testing.expectEqual(Source.flag, binding.sourceOf("token"));
}

test "a resolved value owns its strings, so one deinit releases everything" {
    // Run under the testing allocator, which fails the test on a leak. Every string
    // here comes from somewhere different - a literal default, the environment, a
    // file - and all three must be freed by the single `deinit`.
    var env = try envFrom(&.{.{ "SNEK_HOST", "from-env" }});
    defer env.deinit();
    var file = try stringMap(testing.allocator, &.{
        .{ "tls.cert", "/etc/cert.pem" },
    });
    defer file.deinit(testing.allocator);

    var binding = try bind(ServerConfig, testing.allocator, &.{
        Layer.environment(&env),
        Layer.map(.file, &file),
    });
    defer binding.deinit();

    try testing.expectEqualStrings("from-env", binding.value.host);
    try testing.expectEqualStrings("/etc/cert.pem", binding.value.tls.cert.?);
}

test "a partial failure frees what it had already allocated" {
    // `port` fails, and `host` was already duped from the environment before it.
    // The testing allocator reports the leak if the error path does not undo it.
    var env = try envFrom(&.{
        .{ "SNEK_HOST", "already-duped" },
        .{ "SNEK_PORT", "not-a-number" },
    });
    defer env.deinit();

    try testing.expectError(error.InvalidValue, bind(
        ServerConfig,
        testing.allocator,
        &.{Layer.environment(&env)},
    ));
}

test "flagSpecs derives the flag table from the same struct" {
    const specs = comptime flagSpecs(ServerConfig);

    try testing.expectEqual(@typeInfo(ServerConfig).@"struct".field_names.len, specs.len);

    // Field order is declaration order, so a help page lists flags in the order the
    // struct declares them rather than in whatever order a map iterates.
    try testing.expectEqualStrings("host", specs[0].field_name);
    try testing.expectEqualStrings("--host", specs[0].long);
    try testing.expectEqualStrings("H", specs[0].short.?);
    try testing.expectEqualStrings("Interface to bind", specs[0].help);
    try testing.expectEqualStrings("SNEK_HOST", specs[0].env.?);

    try testing.expectEqualStrings("--port", specs[1].long);
    try testing.expectEqualStrings("p", specs[1].short.?);

    // A field with no declared short has none, rather than a fabricated one.
    try testing.expectEqual(@as(?[]const u8, null), specs[2].short);
    // And one with no help text says so with an empty string.
    try testing.expectEqualStrings("", specs[4].help);
}

test "flagSpecs marks exactly the fields that cannot be omitted" {
    const specs = comptime flagSpecs(ServerConfig);
    for (specs) |spec| {
        // Every field here has a default or is optional.
        try testing.expect(!spec.required);
    }

    const Required = struct { token: []const u8, optional_one: ?u8 = null };
    const required_specs = comptime flagSpecs(Required);
    try testing.expect(required_specs[0].required);
    // An optional field is satisfiable by absence, so it is not required.
    try testing.expect(!required_specs[1].required);
}
