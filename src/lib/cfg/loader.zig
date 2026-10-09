const std = @import("std");

/// The core config engine implements a Viper-style hierarchical merge:
/// Struct Defaults -> JSON Config File -> Environment Variables -> CLI Overrides
///
/// This provides a type-safe `ConfigT` struct loaded securely.
pub fn load(allocator: std.mem.Allocator, comptime ConfigT: type, env_map: *std.process.Environ.Map) !*ConfigT {
    const config = try allocator.create(ConfigT);
    errdefer allocator.destroy(config);

    // 1. Initialize with Struct Defaults
    //
    // A string default is **duped, not borrowed**. That is what makes `deinit` sound:
    // every string reachable from a loaded config is owned by the config's allocator,
    // so `deinit` can free them unconditionally without having to remember which ones
    // came from the environment.
    //
    // Without the dupe the two are indistinguishable at teardown, and the shortcut
    // (free nothing) is a leak while the naive version (free everything) is invalid -
    // it hands a `[]const u8` pointing at a static literal to the allocator. Measured
    // before this: `config export` leaked one allocation per environment-sourced string
    // field.
    //
    // On failure, release every string that has already been duped. `load` owns all
    // string fields it returns, so a partial construction owns a prefix of them.
    var strings_duped: usize = 0;
    errdefer {
        var i: usize = 0;
        const fnames0 = @typeInfo(ConfigT).@"struct".field_names;
        inline for (fnames0, 0..) |_, fnames0_i| {
            const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fnames0_i)));
            if (comptime isStringLike(field.type)) {
                if (i < strings_duped) {
                    if (comptime @typeInfo(field.type) == .optional) {
                        if (@field(config.*, field.name)) |s| allocator.free(s);
                    } else {
                        allocator.free(@field(config.*, field.name));
                    }
                }
                i += 1;
            }
        }
    }

    // Pass 1: struct defaults. A string **default** is skipped when the environment
    // will supply that field, because allocating it only to overwrite it in pass 2
    // leaks the default. Measured: a required `[]const u8` with both a literal default
    // and an `.env` mapping leaked one allocation per load at the dupe below.
    const fnames1 = @typeInfo(ConfigT).@"struct".field_names;
    inline for (fnames1, 0..) |_, fidx1| {
        const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fidx1)));
        const env_overrides = comptime fieldHasEnv(ConfigT, field.name);
        const overridden = env_overrides and env_map.get(comptime envName(ConfigT, field.name)) != null;

        if (field.attrs.default_value_ptr) |def| {
            const default: *align(1) const field.type = @ptrCast(def);
            if (comptime isStringLike(field.type)) {
                if (overridden) {
                    // Left unset; pass 2 fills it. `null` for an optional, and for a
                    // required slice an empty slice, which pass 2 always replaces.
                    if (comptime @typeInfo(field.type) == .optional) {
                        @field(config.*, field.name) = null;
                    } else {
                        @field(config.*, field.name) = "";
                    }
                } else if (comptime @typeInfo(field.type) == .optional) {
                    if (default.*) |s| {
                        @field(config.*, field.name) = try allocator.dupe(u8, s);
                        strings_duped += 1;
                    } else {
                        @field(config.*, field.name) = null;
                    }
                } else {
                    @field(config.*, field.name) = try allocator.dupe(u8, default.*);
                    strings_duped += 1;
                }
            } else {
                @field(config.*, field.name) = default.*;
            }
        } else {
            const ti = @typeInfo(field.type);
            if (ti == .optional) {
                @field(config.*, field.name) = null;
            } else if (field.type == bool) {
                @field(config.*, field.name) = false;
            }
            // Other types without defaults will be left undefined (assumes user provides them)
        }
    }

    // Pass 2: environment overrides.
    const fnames2 = @typeInfo(ConfigT).@"struct".field_names;
    inline for (fnames2, 0..) |_, fidx2| {
        const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fidx2)));
        if (comptime fieldHasEnv(ConfigT, field.name)) {
            const env_key = comptime envName(ConfigT, field.name);
            if (env_map.get(env_key)) |val| {
                if (comptime isStringLike(field.type)) {
                    // Both `[]const u8` and `?[]const u8`, via `isStringLike`. The
                    // optional case used to be missing, and the omission was invisible
                    // rather than loud: `field.type == []const u8` is false for
                    // `?[]const u8`, so every optional string silently kept its default
                    // no matter what the environment said. Measured: with
                    // `API_KEY=a-secret` set, `api_key` stayed null - while the
                    // provenance ledger, which reads the env map directly, still
                    // reported `Source: ENV (API_KEY)`. `config export` then printed
                    // `API_KEY=""`, hiding the disagreement, because an absent string
                    // and a redacted secret render identically.
                    //
                    // Pass 1 guarantees no owned default is overwritten here, so this
                    // assignment needs no free.
                    @field(config.*, field.name) = try allocator.dupe(u8, val);
                    strings_duped += 1;
                } else if (field.type == bool) {
                    @field(config.*, field.name) = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
                } else if (@typeInfo(field.type) == .int) {
                    @field(config.*, field.name) = std.fmt.parseInt(field.type, val, 10) catch @field(config.*, field.name);
                }
            }
        }
    }

    return config;
}

/// Whether `ConfigT`'s meta maps `field_name` to an environment variable.
fn fieldHasEnv(comptime ConfigT: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(ConfigT, "meta")) return false;
    if (!@hasField(@TypeOf(ConfigT.meta), field_name)) return false;
    return @hasField(@TypeOf(@field(ConfigT.meta, field_name)), "env");
}

/// The environment variable name mapped to `field_name`. Callers must have checked
/// `fieldHasEnv` first.
fn envName(comptime ConfigT: type, comptime field_name: []const u8) []const u8 {
    return @field(ConfigT.meta, field_name).env;
}

/// True for `?[]const u8`.
fn isOptionalString(comptime T: type) bool {
    if (@typeInfo(T) != .optional) return false;
    const Child = @typeInfo(T).optional.child;
    return @typeInfo(Child) == .pointer and
        @typeInfo(Child).pointer.size == .slice and
        @typeInfo(Child).pointer.child == u8;
}

/// Releases a config returned by `load`, including every string it owns.
///
/// `load` dupes **all** string fields - both the struct's own defaults and anything
/// read from the environment - so this can free them unconditionally. That is the
/// point of the dupe: at teardown, environment-sourced and default strings are
/// indistinguishable, so the alternative is a leak (free nothing) or an invalid free
/// (handing a static literal to the allocator).
///
/// Measured before `load` duped its defaults: `config export` leaked one allocation
/// per environment-sourced string field, because its call site did
/// `defer allocator.destroy(resolved)` only.
pub fn deinit(allocator: std.mem.Allocator, comptime ConfigT: type, config: *ConfigT) void {
    const fnames3 = @typeInfo(ConfigT).@"struct".field_names;
    inline for (fnames3, 0..) |_, fidx3| {
        const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fidx3)));
        if (comptime isStringLike(field.type)) {
            if (comptime @typeInfo(field.type) == .optional) {
                if (@field(config.*, field.name)) |s| allocator.free(s);
            } else {
                const s = @field(config.*, field.name);
                if (s.len > 0) allocator.free(s);
            }
        }
    }
    allocator.destroy(config);
}

/// True for `[]const u8` and `?[]const u8`.
///
/// Excludes `[][]const u8` and other multi-level slices: its child is itself a slice,
/// not a byte, so it is not a string this module owns.
fn isStringLike(comptime T: type) bool {
    const Base = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    if (@typeInfo(Base) != .pointer) return false;
    const p = @typeInfo(Base).pointer;
    return p.size == .slice and p.child == u8;
}

// 3. Merge from JSON Content (if provided)
pub fn mergeJson(config: anytype, json_content: []const u8, allocator: std.mem.Allocator) !void {
    const ConfigT = @TypeOf(config.*);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    const fnames4 = @typeInfo(ConfigT).@"struct".field_names;
    inline for (fnames4, 0..) |_, fidx4| {
        const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fidx4)));
        if (parsed.value.object.get(field.name)) |val| {
            if (field.type == []const u8 and val == .string) {
                @field(config.*, field.name) = try allocator.dupe(u8, val.string);
            } else if (field.type == bool and val == .bool) {
                @field(config.*, field.name) = val.bool;
            } else if (@typeInfo(field.type) == .int and val == .integer) {
                @field(config.*, field.name) = @intCast(val.integer);
            }
        }
    }
}

/// JSON Schema Generator
/// Dynamically traverses ConfigT to emit a draft-07 JSON Schema for editor tooling
pub fn generateSchema(writer: anytype, comptime ConfigT: type) !void {
    try writer.writeAll("{\n  \"$schema\": \"http://json-schema.org/draft-07/schema#\",\n");
    try writer.writeAll("  \"type\": \"object\",\n");
    try writer.writeAll("  \"properties\": {\n");

    const fields = @typeInfo(ConfigT).@"struct".field_names;
    inline for (fields, 0..) |_, i| {
        const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(i)));
        try writer.print("    \"{s}\": {{\n", .{field.name});

        const ti = @typeInfo(field.type);
        if (field.type == []const u8) {
            try writer.writeAll("      \"type\": \"string\"");
        } else if (field.type == bool) {
            try writer.writeAll("      \"type\": \"boolean\"");
        } else if (ti == .int) {
            try writer.writeAll("      \"type\": \"integer\"");
        } else if (ti == .optional) {
            try writer.writeAll("      \"type\": \"string\"");
        } else {
            try writer.writeAll("      \"type\": \"string\"");
        }

        if (comptime @hasDecl(ConfigT, "meta")) {
            if (comptime @hasField(@TypeOf(ConfigT.meta), field.name)) {
                const fmeta = @field(ConfigT.meta, field.name);
                if (comptime @hasField(@TypeOf(fmeta), "help")) {
                    try writer.print(",\n      \"description\": \"{s}\"", .{fmeta.help});
                }
                // A field marked `.secret = true` is declared `writeOnly`.
                //
                // This is deliberately *not* omission. A schema that silently
                // dropped secret fields would be a lie about the config surface:
                // an editor would not know the key exists, and a user would not
                // know they may set it. `writeOnly` is the draft-07 spelling for
                // "may be supplied, must never be echoed", which is exactly the
                // contract - and it is what makes `config sync` able to publish a
                // schema without publishing the values.
                //
                // Before this, `generateSchema` honoured `.help` and ignored
                // `.secret` entirely, so a secret field was documented like any
                // other. See `src/lib/framework/ROADMAP.md` section 5.3.
                if (comptime isSecret(ConfigT, field.name)) {
                    try writer.writeAll(",\n      \"writeOnly\": true");
                }
            }
        }

        try writer.writeAll("\n    }");
        if (i < fields.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("  }\n}\n");
}

/// Whether `field_name` on `ConfigT` is marked `.secret = true` in its meta.
///
/// Comptime, and false for any type without a `meta` declaration or any field
/// without an entry - so it is safe to call on every field unconditionally.
///
/// Exported because a caller that is about to *publish* configuration (`config
/// sync`, `config eject`, a diagnostic dump) needs the same answer the schema
/// generator uses, and re-deriving it per caller is how one of them ends up
/// disagreeing.
pub fn isSecret(comptime ConfigT: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(ConfigT, "meta")) return false;
    const Meta = @TypeOf(ConfigT.meta);
    if (!@hasField(Meta, field_name)) return false;
    const fmeta = @field(ConfigT.meta, field_name);
    if (!@hasField(@TypeOf(fmeta), "secret")) return false;
    return @field(fmeta, "secret");
}

/// Multi-profile configuration manager
pub const ProfileManager = struct {
    active_profile: []const u8,
    config_dir: []const u8,

    pub fn init(config_dir: []const u8, explicit_profile: ?[]const u8, env_map: *const std.process.Environ.Map) ProfileManager {
        const resolved = explicit_profile orelse (env_map.get("SNEK_PROFILE") orelse "default");
        return .{
            .active_profile = resolved,
            .config_dir = config_dir,
        };
    }

    pub fn getProfilePath(self: ProfileManager, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/profiles/{s}.json", .{ self.config_dir, self.active_profile });
    }
};

/// Lightweight file-based config change detector
pub const ConfigWatcher = struct {
    path: []const u8,
    last_size: u64 = 0,

    pub fn init(path: []const u8) ConfigWatcher {
        return .{ .path = path };
    }

    pub fn checkForChanges(self: *ConfigWatcher, io: std.Io) bool {
        const stat = std.Io.Dir.cwd().statFile(io, self.path) catch return false;
        if (self.last_size == 0) {
            self.last_size = stat.size;
            return false;
        }
        if (stat.size != self.last_size) {
            self.last_size = stat.size;
            return true;
        }
        return false;
    }
};

// -- Tests -----------------------------------------------------------------

/// A config with one secret field, one plain field, and one field with no meta
/// entry at all - the three cases `isSecret` and the schema generator must
/// distinguish.
const SecretFixture = struct {
    host: []const u8 = "127.0.0.1",
    api_key: ?[]const u8 = null,
    no_meta: u16 = 1,

    pub const meta = .{
        .host = .{ .help = "Bind address" },
        .api_key = .{ .env = "API_KEY", .secret = true, .help = "Secret API key" },
    };
};

test "isSecret finds the marked field and nothing else" {
    try std.testing.expect(isSecret(SecretFixture, "api_key"));
    try std.testing.expect(!isSecret(SecretFixture, "host"));
    // A field absent from `meta` must not be reported as secret, and must not
    // trip a compile error for the missing entry.
    try std.testing.expect(!isSecret(SecretFixture, "no_meta"));
}

test "isSecret is false for a config with no meta at all" {
    const Bare = struct { a: u16 = 0 };
    try std.testing.expect(!isSecret(Bare, "a"));
}

test "generateSchema marks a secret writeOnly and never emits its value" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try generateSchema(&w, SecretFixture);
    const out = w.buffered();

    // The secret is *declared*...
    try std.testing.expect(std.mem.indexOf(u8, out, "\"api_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"writeOnly\": true") != null);
    // ...with its help text...
    try std.testing.expect(std.mem.indexOf(u8, out, "Secret API key") != null);

    // ...and it is the only field marked writeOnly. Counted rather than
    // spot-checked, because a bug that marked *every* field writeOnly would
    // pass a "contains writeOnly" assertion.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"writeOnly\"")) |at| {
        count += 1;
        idx = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);

    // The non-secret field is described but not writeOnly.
    try std.testing.expect(std.mem.indexOf(u8, out, "Bind address") != null);
}

test "load reads an optional string from the environment" {
    // Regression guard. `field.type == []const u8` is false for `?[]const u8`, so the
    // optional case silently kept its default no matter what the environment said.
    // Measured before the fix: with `API_KEY=secret` set, `api_key` stayed null, while
    // the provenance ledger - which reads the env map itself - still reported
    // `Source: ENV (API_KEY)`.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("LOADER_TEST_KEY", "from-env");

    const Fixture = struct {
        api_key: ?[]const u8 = null,
        pub const meta = .{ .api_key = .{ .env = "LOADER_TEST_KEY" } };
    };

    const loaded = try load(std.testing.allocator, Fixture, &env);
    defer deinit(std.testing.allocator, Fixture, loaded);

    try std.testing.expect(loaded.api_key != null);
    try std.testing.expectEqualStrings("from-env", loaded.api_key.?);
}

test "load leaves an optional string null when the variable is unset" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const Fixture = struct {
        api_key: ?[]const u8 = "a-default",
        pub const meta = .{ .api_key = .{ .env = "LOADER_TEST_UNSET_KEY" } };
    };

    const loaded = try load(std.testing.allocator, Fixture, &env);
    defer deinit(std.testing.allocator, Fixture, loaded);
    try std.testing.expectEqualStrings("a-default", loaded.api_key.?);
}

test "deinit frees every string load owns, and the test allocator proves it" {
    // `std.testing.allocator` reports leaks, so reaching the end of this test without
    // a leak report is the assertion. It covers both string shapes and both sources:
    // an env-sourced optional and a defaulted required string.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("LOADER_TEST_BOTH_KEY", "env-value");

    const Fixture = struct {
        required: []const u8 = "a-literal-default",
        optional: ?[]const u8 = null,
        port: u16 = 1,
        pub const meta = .{
            .required = .{ .env = "LOADER_TEST_NOPE" },
            .optional = .{ .env = "LOADER_TEST_BOTH_KEY" },
        };
    };

    const loaded = try load(std.testing.allocator, Fixture, &env);
    // The required field came from its literal default, the optional from the
    // environment - the two cases that must be indistinguishable at teardown.
    try std.testing.expectEqualStrings("a-literal-default", loaded.required);
    try std.testing.expectEqualStrings("env-value", loaded.optional.?);
    try std.testing.expectEqual(@as(u16, 1), loaded.port);

    deinit(std.testing.allocator, Fixture, loaded);
}

test "deinit frees the environment copy of a required string too" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("LOADER_TEST_REQUIRED", "required-from-env");

    const Fixture = struct {
        name: []const u8 = "default-name",
        pub const meta = .{ .name = .{ .env = "LOADER_TEST_REQUIRED" } };
    };

    const loaded = try load(std.testing.allocator, Fixture, &env);
    try std.testing.expectEqualStrings("required-from-env", loaded.name);
    deinit(std.testing.allocator, Fixture, loaded);
}

test "isStringLike distinguishes strings from arrays of them" {
    try std.testing.expect(isStringLike([]const u8));
    try std.testing.expect(isStringLike(?[]const u8));
    try std.testing.expect(!isStringLike(u16));
    try std.testing.expect(!isStringLike(bool));
    // A slice of slices is not a string this module owns.
    try std.testing.expect(!isStringLike([]const []const u8));
}
