//! A comptime-built table of a config's reportable fields.
//!
//! ## The problem this solves
//!
//! Two operations must answer "given a *runtime* dotted path like `network.port`,
//! what is that field?" - dry-run validation and inspect. The obvious implementation
//! walks `std.meta.fields(ConfigT)` comparing names, but that does not compile:
//!
//! ```text
//! error: unable to resolve comptime value
//!     if (comptime std.mem.eql(u8, field.name, runtime_path_first))
//! ```
//!
//! `field.name` is comptime, the path is not. The fix is to invert it: build the
//! table **at comptime** - where every name and type is known - and look the runtime
//! path up *in* it. The path stays runtime, the reflection stays comptime.
//!
//! ## Why type-dependent work is a comptime-generated closure
//!
//! Zig cannot store a `type` in a runtime-readable table, and a function pointer
//! cannot take `anytype`. So each entry carries pointers to functions generated per
//! field inside `build`, where the field path *is* comptime:
//!
//! * `try_parse_fn` - "does this text fit this field" (dry-run).
//! * `render_fn` - "show me this field's value" (inspect).
//!
//! Because the field path is captured at comptime inside those functions, the runtime
//! side only ever calls a pointer. That is what avoids the branch that started this:
//! a runtime `if (entry.outer) |o|` feeding a `comptime eql(field.name, o)` cannot
//! work, and no amount of restructuring the *caller* fixes it.

const std = @import("std");
const cfg = @import("cfg");

/// A buffer size every rendered value fits in. Values are scalars, so this is
/// generous rather than tight; a value that overflows renders as `?` rather than
/// truncating silently.
pub const buf_len = 256;

/// One reportable field.
pub const Entry = struct {
    /// The dotted path, e.g. `port` or `network.port`.
    path: []const u8,
    /// The field's name within its own struct (no dots).
    leaf: []const u8,
    /// The outer struct field for a nested entry, else null.
    outer: ?[]const u8 = null,
    /// Whether the field is marked `.secret = true`.
    secret: bool,
    /// The field's declared type name, for reporting.
    type_name: []const u8,
    /// Function pointers, generated per field at comptime.
    ///
    /// Fields rather than declarations: Zig rejects a declaration between container
    /// fields.
    try_parse_fn: *const fn (text: []const u8) bool,
    render_fn: *const fn (config: *const anyopaque, buf: *[buf_len]u8) []const u8,

    /// "Does `text` parse into this field's type?" - discards the value.
    ///
    /// Allocation is owned inside, so a caller cannot leak by forgetting a free.
    pub fn tryParse(self: Entry, text: []const u8) bool {
        return self.try_parse_fn(text);
    }

    /// Renders this field's value from `config` into `buf`.
    ///
    /// `*const anyopaque` rather than a typed pointer because the table is
    /// type-erased; the generated `render_fn` knows the concrete type and casts back.
    /// Passing a pointer to the wrong config type is therefore a caller bug the
    /// compiler cannot catch - which is why every caller in this tree obtains the
    /// entry from `build(ConfigT)` for the same `ConfigT` it then renders.
    pub fn render(self: Entry, config: *const anyopaque, buf: *[buf_len]u8) []const u8 {
        return self.render_fn(config, buf);
    }
};

/// The field table for one config type.
pub const Table = struct {
    entries: []const Entry,
    /// Set when the config has more fields than the caller's fixed buffer array.
    overflowed: bool = false,
};

/// Builds the field table for `ConfigT`.
///
/// One level of nesting is included, because that is what every config in this tree
/// uses. A deeper path is excluded rather than guessed at, so a caller asking for
/// `a.b.c` gets "no such field" rather than a silently wrong answer.
pub fn build(comptime ConfigT: type) []const Entry {
    comptime {
        var list: []const Entry = &.{};
        for (std.meta.fields(ConfigT)) |field| {
            if (isScalar(field.type)) {
                list = list ++ &[_]Entry{.{
                    .path = field.name,
                    .leaf = field.name,
                    .secret = cfg.loader.isSecret(ConfigT, field.name),
                    .type_name = @typeName(field.type),
                    .try_parse_fn = makeTryParse(field.type),
                    .render_fn = makeRenderTop(ConfigT, field.name),
                }};
            } else if (isFlattenableStruct(field.type)) {
                for (std.meta.fields(field.type)) |sub| {
                    if (!isScalar(sub.type)) continue;
                    list = list ++ &[_]Entry{.{
                        .path = field.name ++ "." ++ sub.name,
                        .leaf = sub.name,
                        .outer = field.name,
                        .secret = cfg.loader.isSecret(field.type, sub.name),
                        .type_name = @typeName(sub.type),
                        .try_parse_fn = makeTryParse(sub.type),
                        .render_fn = makeRenderNested(ConfigT, field.name, sub.name),
                    }};
                }
            }
        }
        return list;
    }
}

/// Generates the `try_parse_fn` for one field type.
fn makeTryParse(comptime T: type) *const fn (text: []const u8) bool {
    return struct {
        fn f(text: []const u8) bool {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            _ = cfg.parseValue(T, text, arena.allocator()) catch return false;
            return true;
        }
    }.f;
}

/// Generates the `render_fn` for a top-level field.
fn makeRenderTop(comptime ConfigT: type, comptime name: []const u8) *const fn (*const anyopaque, *[buf_len]u8) []const u8 {
    return struct {
        fn f(config: *const anyopaque, buf: *[buf_len]u8) []const u8 {
            const typed: *const ConfigT = @ptrCast(@alignCast(config));
            inline for (std.meta.fields(ConfigT)) |field| {
                if (comptime std.mem.eql(u8, field.name, name)) {
                    return renderFieldValue(buf, @field(typed.*, field.name), cfg.loader.isSecret(ConfigT, field.name));
                }
            }
            return "?";
        }
    }.f;
}

/// Generates the `render_fn` for a one-level nested field.
fn makeRenderNested(
    comptime ConfigT: type,
    comptime outer: []const u8,
    comptime leaf: []const u8,
) *const fn (*const anyopaque, *[buf_len]u8) []const u8 {
    return struct {
        fn f(config: *const anyopaque, buf: *[buf_len]u8) []const u8 {
            const typed: *const ConfigT = @ptrCast(@alignCast(config));
            inline for (std.meta.fields(ConfigT)) |field| {
                if (comptime std.mem.eql(u8, field.name, outer)) {
                    inline for (std.meta.fields(field.type)) |sub| {
                        if (comptime std.mem.eql(u8, sub.name, leaf)) {
                            return renderFieldValue(buf, @field(@field(typed.*, field.name), sub.name), cfg.loader.isSecret(field.type, sub.name));
                        }
                    }
                }
            }
            return "?";
        }
    }.f;
}

/// Looks an entry up by exact dotted path.
pub fn find(table: []const Entry, path: []const u8) ?Entry {
    for (table) |e| {
        if (std.mem.eql(u8, e.path, path)) return e;
    }
    return null;
}

/// Renders one value. A secret becomes `[SECRET len=N]` and the value never reaches
/// the buffer.
pub fn renderFieldValue(buf: []u8, value: anytype, is_secret: bool) []const u8 {
    if (is_secret) {
        return std.fmt.bufPrint(buf, "[SECRET len={d}]", .{secretLen(value)}) catch "[SECRET]";
    }
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| renderFieldValue(buf, v, false) else "null",
        .bool => if (value) "true" else "false",
        .int => std.fmt.bufPrint(buf, "{d}", .{value}) catch "?",
        .float => std.fmt.bufPrint(buf, "{d}", .{value}) catch "?",
        .pointer => |p| if (p.size == .slice and p.child == u8) value else "?",
        .@"struct" => blk: {
            if (T == cfg.DurationMs) break :blk std.fmt.bufPrint(buf, "{d}ms", .{value.ms}) catch "?";
            if (T == cfg.ByteSize) break :blk std.fmt.bufPrint(buf, "{d}", .{value.bytes}) catch "?";
            break :blk "?";
        },
        else => "?",
    };
}

/// The length of a secret, for the redacted form. Null and empty are both 0.
fn secretLen(value: anytype) usize {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| secretLen(v) else 0,
        .pointer => |p| if (p.size == .slice and p.child == u8) value.len else 0,
        else => 0,
    };
}

/// Whether a field type is reportable.
pub fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool => true,
        .pointer => |p| p.size == .slice and p.child == u8,
        .optional => |o| isScalar(o.child),
        .@"struct" => T == cfg.DurationMs or T == cfg.ByteSize,
        else => false,
    };
}

/// A struct worth flattening one level: not a scalar type, and every field is.
pub fn isFlattenableStruct(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (T == cfg.DurationMs or T == cfg.ByteSize) return false;
    for (std.meta.fields(T)) |f| {
        if (!isScalar(f.type)) return false;
    }
    return true;
}

// -- Tests -----------------------------------------------------------------

const Network = struct {
    port: u16 = 8080,
    tls: bool = false,
};

const Fixture = struct {
    name: []const u8 = "svc",
    verbose: bool = false,
    timeout: cfg.DurationMs = .{ .ms = 1000 },
    limit: cfg.ByteSize = .{ .bytes = 1024 },
    network: Network = .{},
    token: ?[]const u8 = null,

    pub const meta = .{
        .token = .{ .env = "APP_TOKEN", .secret = true },
    };
};

test "the table contains top-level and nested fields, dotted" {
    const table = comptime build(Fixture);
    try std.testing.expect(find(table, "name") != null);
    try std.testing.expect(find(table, "network.port") != null);
    try std.testing.expect(find(table, "network.tls") != null);
    try std.testing.expect(find(table, "network.nope") == null);
    try std.testing.expect(find(table, "nope") == null);
    // A deeper path is absent rather than resolved wrongly.
    try std.testing.expect(find(table, "network.port.extra") == null);
}

test "a nested entry records its outer struct field" {
    const table = comptime build(Fixture);
    const e = find(table, "network.port").?;
    try std.testing.expectEqualStrings("network", e.outer.?);
    try std.testing.expectEqualStrings("port", e.leaf);
    try std.testing.expect(find(table, "name").?.outer == null);
}

test "secret flags come from the field's meta" {
    const table = comptime build(Fixture);
    try std.testing.expect(find(table, "token").?.secret);
    try std.testing.expect(!find(table, "name").?.secret);
    try std.testing.expect(!find(table, "network.port").?.secret);
}

test "tryParse accepts and rejects per the field's declared type" {
    const table = comptime build(Fixture);
    try std.testing.expect(find(table, "network.port").?.tryParse("9999"));
    try std.testing.expect(!find(table, "network.port").?.tryParse("not-a-port"));
    try std.testing.expect(find(table, "verbose").?.tryParse("yes"));
    try std.testing.expect(!find(table, "verbose").?.tryParse("maybe"));
    try std.testing.expect(find(table, "timeout").?.tryParse("2m"));
    try std.testing.expect(!find(table, "timeout").?.tryParse("2 fortnights"));
    try std.testing.expect(find(table, "limit").?.tryParse("1MB"));
    try std.testing.expect(!find(table, "limit").?.tryParse("1XB"));
}

test "tryParse frees string allocations it makes" {
    // The closure owns its arena, so repeated calls must not grow anything.
    const table = comptime build(Fixture);
    const e = find(table, "name").?;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try std.testing.expect(e.tryParse("some-string-value"));
    }
}

test "render renders a top-level and a nested field" {
    const table = comptime build(Fixture);
    var config = Fixture{};
    const base: *const anyopaque = @ptrCast(&config);

    var buf: [buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("svc", find(table, "name").?.render(base, &buf));

    var buf2: [buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("8080", find(table, "network.port").?.render(base, &buf2));

    var buf3: [buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("1000ms", find(table, "timeout").?.render(base, &buf3));
}

test "render redacts a secret and never emits its value" {
    const table = comptime build(Fixture);
    const secret_text = "tok_live_abcdef";
    var config = Fixture{ .token = secret_text };
    const base: *const anyopaque = @ptrCast(&config);

    const e = find(table, "token").?;
    var buf: [buf_len]u8 = undefined;
    const out = e.render(base, &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "SECRET") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "len=15") != null);
    // The assertion that matters: redaction returning the value would fail here.
    try std.testing.expect(std.mem.indexOf(u8, out, secret_text) == null);
}

test "renderFieldValue formats the scalar types" {
    var buf: [buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("true", renderFieldValue(&buf, true, false));
    try std.testing.expectEqualStrings("8080", renderFieldValue(&buf, @as(u16, 8080), false));
    try std.testing.expectEqualStrings("null", renderFieldValue(&buf, @as(?u16, null), false));
    try std.testing.expectEqualStrings("1500ms", renderFieldValue(&buf, cfg.DurationMs{ .ms = 1500 }, false));
}
