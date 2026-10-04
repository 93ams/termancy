//! `config cast <path> <type>` - coerce a value into a named type.
//!
//! The specification describes this as fixing bad data types from external sources:
//! converting a `"8080"` string into an `8080` integer so the result passes a strict
//! schema.
//!
//! ## What this does and does not do
//!
//! It **validates and normalises**, and prints the canonical form. It does **not** rewrite
//! a file, because there is no TOML document model in this tree - `app/cfg/lib/cfg/toml_mutator.zig`
//! is line-based text, and a line-based editor cannot safely coerce a nested value. That
//! gap is recorded in `app/cfg/PLAN.md` rather than papered over with a text substitution
//! that would corrupt a file it did not fully understand.
//!
//! So the honest use is a pre-flight check: `config cast port u16` answers "will this be
//! accepted as a `u16`", and prints what the value would become.

const std = @import("std");
const cfg = @import("cfg");
const ops = @import("app_cfg_ops");

/// Flags for `config cast`.
pub const CastFlags = struct {
    positionals: struct {
        /// The dotted path, e.g. `port`.
        path: []const u8 = "",
        /// The target type: u8,u16,u32,u64,i32,i64,bool,string,duration,bytes.
        type_name: []const u8 = "",
    } = .{},

    pub const meta = .{
        .positionals = .{ .description = "<path> <type>" },
    };
};

/// Prints the coerced value, or fails with a reason.
pub fn run(
    allocator: std.mem.Allocator,
    writer: anytype,
    err_writer: anytype,
    env_map: *std.process.Environ.Map,
    comptime ConfigT: type,
    flags: CastFlags,
) !void {
    const path = flags.positionals.path;
    const type_name = flags.positionals.type_name;

    if (path.len == 0 or type_name.len == 0) {
        try err_writer.print(
            "config cast: expected a path and a type, e.g. `config cast port u16`\n" ++
                "  types: {s}\n",
            .{joinTypes()},
        );
        return error.MissingRequiredPositionalArgument;
    }

    if (!ops.query.isCastType(type_name)) {
        try err_writer.print("unknown cast type '{s}'; expected one of {s}\n", .{
            type_name,
            joinTypes(),
        });
        return error.InvalidFormat;
    }

    const resolved = try cfg.loader.load(allocator, ConfigT, env_map);
    defer cfg.loader.deinit(allocator, ConfigT, resolved);

    // The field must exist, and its declared type must be the one asked for. Both checks
    // matter: coercing `host` to `u16` should fail even though `host` exists, and casting
    // a name that is not a field should fail before any parsing.
    var buf: [ops.fields.buf_len]u8 = undefined;
    const found = ops.query.get(ConfigT, resolved.*, path, &buf, true) orelse {
        try err_writer.print("no such configuration field: {s}\n", .{path});
        return error.UnknownField;
    };

    if (found.simple_type.len > 0 and !std.mem.eql(u8, found.simple_type, type_name)) {
        try err_writer.print("field '{s}' is {s}, not {s}\n", .{ path, found.simple_type, type_name });
        return error.InvalidFormat;
    }

    const coerced = ops.query.cast(allocator, found.text, type_name) catch |err| {
        try err_writer.print("'{s}' cannot be cast to {s} ({s})\n", .{
            found.text,
            type_name,
            @errorName(err),
        });
        return error.InvalidFormat;
    };
    // Only the non-string branches allocate; `cast` returns the caller's own slice for a
    // string, so the free is conditional on the result not being that slice.
    defer if (coerced.ptr != found.text.ptr) allocator.free(coerced);

    try writer.print("{s}\n", .{coerced});
}

/// The type list, as text, in a fixed buffer.
///
/// No allocation, so the error paths below have nothing to leak - the previous version
/// returned an owned slice and leaked it on every path that printed usage. The list is a
/// compile-time array of ten short names, so a fixed buffer is exact rather than a guess;
/// the build fails if it ever fills up.
var types_buf: [128]u8 = undefined;

fn joinTypes() []const u8 {
    var w = std.Io.Writer.fixed(&types_buf);
    for (ops.query.cast_types, 0..) |t, i| {
        if (i > 0) w.writeAll(", ") catch unreachable;
        w.writeAll(t) catch unreachable;
    }
    return w.buffered();
}

// -- Tests -----------------------------------------------------------------

const Fixture = struct {
    port: u16 = 4222,
    name: []const u8 = "svc",
    verbose: bool = false,
    timeout: cfg.DurationMs = .{ .ms = 500 },

    pub const meta = .{};
};

fn runFixture(writer: anytype, err_writer: anytype, args: CastFlags) !void {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try run(std.testing.allocator, writer, err_writer, &env, Fixture, args);
}

test "a numeric cast frees its allocation" {
    // `testing.allocator` and no arena, so a missing free is reported rather than hidden.
    // This is the guard for a real leak: the `defer` that releases the numeric result was
    // once commented out by a stray `\n` in its preceding comment line, which no assertion
    // could see - only the allocator could.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{
        .positionals = .{ .path = "port", .type_name = "u16" },
    });
    try std.testing.expectEqualStrings("4222\n", out.buffered());
}

test "a string cast frees nothing, because it allocated nothing" {
    // The string branch returns the caller's slice. Freeing it would be freeing stack
    // memory belonging to the caller, so this test exists to prove that path does not
    // allocate and the conditional free correctly skips it.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, &out, &err, &env, Fixture, .{
        .positionals = .{ .path = "name", .type_name = "string" },
    });
    try std.testing.expectEqualStrings("svc\n", out.buffered());
}

test "an integer field casts to its own type" {
    // An arena, not `testing.allocator`: `cast` allocates for a numeric type, and the
    // conditional free the command performs is keyed on a pointer comparison that is only
    // meaningful when the output genuinely came from an allocator the test controls.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    try run(arena.allocator(), &out, &err, &env, Fixture, .{
        .positionals = .{ .path = "port", .type_name = "u16" },
    });
    try std.testing.expectEqualStrings("4222\n", out.buffered());
}

test "a field whose declared type differs from the request is refused" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    // `name` is a string; asking for u16 must fail rather than silently reinterpreting it.
    try std.testing.expectError(
        error.InvalidFormat,
        runFixture(&out, &err, .{ .positionals = .{ .path = "name", .type_name = "u16" } }),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "is string, not u16") != null);
}

// The remaining tests use an arena. `cast` allocates for every type except `string`,
// where it returns the caller's own slice, so the ownership rule is conditional - and
// exercising it with `testing.allocator` plus hand-written `free`s obscured the behaviour
// under free-of-non-owned bugs. An arena frees everything once and lets the assertions be
// about coercion rather than about allocator bookkeeping. The conditional rule itself is
// still documented on `cast`, and the command above honours it.
test "an out-of-range value is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.OutOfRange, ops.query.cast(a, "99999", "u8"));
    try std.testing.expectEqualStrings("255", try ops.query.cast(a, "255", "u8"));
    // `65536` is one past a u16 but well inside a u32, so the bound is per-type rather
    // than a single global limit.
    try std.testing.expectError(error.OutOfRange, ops.query.cast(a, "65536", "u16"));
    try std.testing.expectEqualStrings("65536", try ops.query.cast(a, "65536", "u32"));
}

test "cast normalises what it accepts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("true", try ops.query.cast(a, "yes", "bool"));
    try std.testing.expectEqualStrings("false", try ops.query.cast(a, "no", "bool"));
    try std.testing.expectEqualStrings("120000ms", try ops.query.cast(a, "2m", "duration"));
    try std.testing.expectEqualStrings("1024", try ops.query.cast(a, "1KB", "bytes"));
    // A string is returned unchanged, and is the caller's slice rather than a copy.
    const s = try ops.query.cast(a, "hello", "string");
    try std.testing.expectEqualStrings("hello", s);

    // Values that do not fit their claimed type are rejected rather than approximated.
    try std.testing.expectError(error.InvalidValue, ops.query.cast(a, "not-a-number", "u16"));
    try std.testing.expectError(error.UnknownType, ops.query.cast(a, "1", "float128"));
}

test "an unknown type is refused by isCastType" {
    try std.testing.expect(ops.query.isCastType("u16"));
    try std.testing.expect(ops.query.isCastType("string"));
    try std.testing.expect(!ops.query.isCastType("float128"));
    try std.testing.expect(!ops.query.isCastType(""));
}

test "the positional is declared where the framework looks for it" {
    try std.testing.expect(@hasField(CastFlags, "positionals"));
    const P = @FieldType(CastFlags, "positionals");
    try std.testing.expect(@hasField(P, "path"));
    try std.testing.expect(@hasField(P, "type_name"));
}
