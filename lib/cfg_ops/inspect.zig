//! Explain where a configuration field's value came from.
//!
//! The question this answers is the one users actually ask: *"I set it in the
//! environment, so why is it 8080?"* With a merge order of defaults -> file ->
//! remote -> env -> flags, a value alone does not say which layer won.
//!
//! `app/cfg/lib/cfg/config_lineage.zig` implements the ledger - `record` during the merge,
//! `getProvenance` to ask, `inspect` to render the
//! `Value: 8080 | Type: u16 | Source: ENV (APP_PORT)` line. What was missing is
//! anything that reports on a *whole config* rather than one field at a time.
//!
//! ## How paths are resolved
//!
//! Through `fields.build`, which does the reflection at comptime and hands back a
//! table a runtime path can be looked up in. Comparing a runtime path against
//! `field.name` directly does not compile - `error: unable to resolve comptime value`
//! - so the reflection is inverted, and the type-dependent work is captured as
//! comptime-generated closures inside the table.
//!
//! ## Redaction
//!
//! A field marked `.secret = true` is reported with its **length**, never its value,
//! for the same reason `exporter` withholds it: a provenance report is exactly where
//! a secret leaks into a terminal, a scrollback buffer or a pasted bug report. "Where
//! did this come from" does not require the value.

const std = @import("std");
const cfg = @import("cfg");
const lineage = cfg.config_lineage;
const fields = @import("fields.zig");

/// Builds a lineage ledger for `ConfigT` by recording where each field's value would
/// come from, reading `env_map`.
///
/// This is what makes the report meaningful without a real merge: it inspects the
/// same environment the loader would, so `Source: ENV (APP_PORT)` is true rather than
/// decorative. Fields the environment does not set are recorded as `.default`, which
/// is what they are.
pub fn buildEnvLineage(
    allocator: std.mem.Allocator,
    comptime ConfigT: type,
    env_map: *std.process.Environ.Map,
) !lineage {
    var led = lineage.init(allocator);
    // Errors from `record` propagate, and the partially built ledger is freed on the
    // way out rather than leaked.
    errdefer led.deinit();

    inline for (std.meta.fields(ConfigT)) |field| {
        if (comptime fields.isScalar(field.type)) {
            if (comptime declaredEnv(ConfigT, field.name)) |env_name| {
                if (env_map.get(env_name)) |_| {
                    try led.record(field.name, .env, env_name);
                } else {
                    try led.record(field.name, .default, "built-in default");
                }
            } else {
                try led.record(field.name, .default, "built-in default");
            }
        }
    }
    return led;
}

/// Renders one field's provenance line through the ledger.
///
/// A thin pass-through, kept because a caller that already has a value's text (the
/// single-field path) should not have to build a `Rendered` to report it.
pub fn reportField(
    led: lineage,
    writer: anytype,
    path: []const u8,
    value_repr: []const u8,
    type_name: []const u8,
) !void {
    try led.inspect(writer, path, value_repr, type_name);
}
/// A field's rendered text, plus the name and type that describe it.
///
/// `text` borrows a buffer the caller owns, so nothing here is heap-allocated and a
/// caller cannot leak by forgetting a free.
pub const Rendered = struct {
    path: []const u8,
    text: []const u8,
    type_name: []const u8,
};

/// Renders every reportable field of `config` into `out`, borrowing `bufs`.
///
/// `bufs` is `anytype` so its length is visible at comptime: an array-to-slice
/// coercion reports `len == 0` at comptime, which made an earlier version of this
/// reject every caller. The check below therefore tests the *type*, not `.len`.
pub fn collect(
    comptime ConfigT: type,
    config: ConfigT,
    out: *std.ArrayListUnmanaged(Rendered),
    bufs: anytype,
) !usize {
    const table = comptime fields.build(ConfigT);
    const count = table.len;

    if (comptime @TypeOf(bufs) != *[count][fields.buf_len]u8) {
        @compileError("collect needs exactly one [fields.buf_len]u8 buffer per reportable field");
    }
    // Capacity is a runtime property, so it is checked at runtime rather than
    // asserted at comptime. A caller that skipped `ensureTotalCapacity` gets a clear
    // error instead of memory corruption.
    if (out.capacity < count) return error.InsufficientCapacity;

    // The entry's `render` closure knows the concrete config type and casts the
    // erased pointer back, so the config must be the same type the table was built
    // from - which is why `ConfigT` is taken here rather than inferred.
    const erased: *const anyopaque = @ptrCast(&config);
    for (table, 0..) |entry, i| {
        out.appendAssumeCapacity(.{
            .path = entry.path,
            .text = entry.render(erased, &bufs[i]),
            .type_name = entry.type_name,
        });
    }
    return count;
}

/// Writes `collect`'s output through the lineage ledger, redaction included.
pub fn reportAll(
    led: lineage,
    writer: anytype,
    rendered: []const Rendered,
) !usize {
    for (rendered) |r| {
        try led.inspect(writer, r.path, r.text, r.type_name);
    }
    return rendered.len;
}

/// Renders the single field `path` names, or null when it is not reportable.
pub fn renderAtPath(
    comptime ConfigT: type,
    config: ConfigT,
    path: []const u8,
    buf: *[fields.buf_len]u8,
) ?struct { text: []const u8, type_name: []const u8, secret: bool } {
    const entry = fields.find(comptime fields.build(ConfigT), path) orelse return null;
    const erased: *const anyopaque = @ptrCast(&config);
    return .{
        .text = entry.render(erased, buf),
        .type_name = entry.type_name,
        .secret = entry.secret,
    };
}

/// The number of reportable fields, at comptime.
pub fn fieldCount(comptime ConfigT: type) usize {
    return comptime fields.build(ConfigT).len;
}

fn declaredEnv(comptime T: type, comptime field_name: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "meta")) return null;
    const Meta = @TypeOf(T.meta);
    if (!@hasField(Meta, field_name)) return null;
    const fmeta = @field(T.meta, field_name);
    if (!@hasField(@TypeOf(fmeta), "env")) return null;
    return @field(fmeta, "env");
}

// -- Tests -----------------------------------------------------------------

const Network = struct {
    port: u16 = 8080,
};

const Fixture = struct {
    name: []const u8 = "svc",
    verbose: bool = false,
    timeout: cfg.DurationMs = .{ .ms = 1500 },
    token: ?[]const u8 = null,
    network: Network = .{},

    pub const meta = .{
        .name = .{ .env = "APP_NAME" },
        .token = .{ .env = "APP_TOKEN", .secret = true },
    };
};

/// A buffer array sized exactly to `Fixture`'s reportable field count.
const FixtureBufs = [fieldCount(Fixture)][fields.buf_len]u8;

test "collect names every reportable field, dotted for nested ones" {
    var bufs: FixtureBufs = undefined;
    var list: std.ArrayListUnmanaged(Rendered) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacity(std.testing.allocator, fieldCount(Fixture));

    const n = try collect(Fixture, Fixture{}, &list, &bufs);
    try std.testing.expectEqual(@as(usize, 5), n);

    var joined: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&joined);
    for (list.items) |r| try w.print("{s}={s} ", .{ r.path, r.text });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "network.port=8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "timeout=1500ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "verbose=false") != null);
}

test "collect reports insufficient capacity rather than corrupting memory" {
    var bufs: FixtureBufs = undefined;
    var list: std.ArrayListUnmanaged(Rendered) = .empty;
    defer list.deinit(std.testing.allocator);
    // Deliberately no ensureTotalCapacity.
    try std.testing.expectError(error.InsufficientCapacity, collect(Fixture, Fixture{}, &list, &bufs));
}

test "renderAtPath resolves a top-level and a nested path" {
    var buf: [fields.buf_len]u8 = undefined;
    const top = renderAtPath(Fixture, Fixture{}, "name", &buf).?;
    try std.testing.expectEqualStrings("svc", top.text);

    var buf2: [fields.buf_len]u8 = undefined;
    const nested = renderAtPath(Fixture, Fixture{}, "network.port", &buf2).?;
    try std.testing.expectEqualStrings("8080", nested.text);

    var buf3: [fields.buf_len]u8 = undefined;
    try std.testing.expect(renderAtPath(Fixture, Fixture{}, "nope", &buf3) == null);
    try std.testing.expect(renderAtPath(Fixture, Fixture{}, "network.nope", &buf3) == null);
}

test "a secret reports by length and never by value" {
    var buf: [fields.buf_len]u8 = undefined;
    const secret_text = "tok_live_abcdef";
    const r = renderAtPath(Fixture, Fixture{ .token = secret_text }, "token", &buf).?;
    try std.testing.expect(r.secret);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "SECRET") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "len=15") != null);
    // The assertion that matters: redaction returning the value would fail here.
    try std.testing.expect(std.mem.indexOf(u8, r.text, secret_text) == null);
}

test "buildEnvLineage records ENV for a set variable and DEFAULT otherwise" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("APP_NAME", "from-env");

    var led = try buildEnvLineage(std.testing.allocator, Fixture, &env);
    defer led.deinit();

    const name_prov = led.getProvenance("name").?;
    try std.testing.expectEqual(lineage.ConfigSource.env, name_prov.source);
    try std.testing.expectEqualStrings("APP_NAME", name_prov.origin);

    const verbose_prov = led.getProvenance("verbose").?;
    try std.testing.expectEqual(lineage.ConfigSource.default, verbose_prov.source);
}

test "reportAll writes every collected field through the ledger" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var led = try buildEnvLineage(std.testing.allocator, Fixture, &env);
    defer led.deinit();

    var bufs: FixtureBufs = undefined;
    var list: std.ArrayListUnmanaged(Rendered) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacity(std.testing.allocator, fieldCount(Fixture));
    _ = try collect(Fixture, Fixture{}, &list, &bufs);

    var out_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    const n = try reportAll(led, &w, list.items);
    // The lineage line is `Value: ... | Type: ... | Source: ...` - it names the
    // *value*, not the path, because the library's `inspect` prints a path only when
    // one was asked for. So assert on the value and the source, not on the key.
    try std.testing.expectEqual(@as(usize, 5), n);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Source:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1500ms") != null);
}
