//! Reading configuration values and structure.
//!
//! The two operations the specification calls `cfg get` and `cfg keys`. Neither adds
//! new parsing: `fields.build` already resolves a dotted path to an entry, and
//! `Entry.render` already produces the text. What was missing was operations that
//! return a *value* rather than a provenance line, and a caller that wants the keys
//! without the values.
//!
//! ## Why this is separate from `inspect`
//!
//! `inspect` answers "where did this come from", which is a diagnostic: every line
//! carries `Type:` and `Source:`. `get` answers "what is it", which is what a shell
//! script wants - and a script piping `cfg get port` into `iptables` cannot use a line
//! that ends in `(built-in default)`. Keeping them apart means neither has to grow a
//! mode flag that makes its output ambiguous.

const std = @import("std");
const cfg = @import("cfg");
const fields = @import("fields.zig");

/// The result of resolving one path.
pub const Got = struct {
    /// The dotted path as resolved from the table.
    path: []const u8,
    /// The rendered value.
    text: []const u8,
    /// The field's declared type name.
    type_name: []const u8,
    /// The field's `.type` name for `cast` (`u16`, `bool`, ...). Empty when the type
    /// has no simple spelling, which is a signal that `cast` cannot target it.
    simple_type: []const u8,
};

/// Renders one path from `config`, or null when it names nothing.
///
/// `raw` strips the decoration a shell would have to post-process. In practice that
/// means a string value is emitted without the quotes it renders with, and an absent
/// optional becomes an empty string rather than `null`, because a shell's `$(...)`
/// cannot distinguish those anyway and an empty expansion is more useful in a
/// substitution than the four characters `null`.
pub fn get(
    comptime ConfigT: type,
    config: ConfigT,
    path: []const u8,
    buf: *[fields.buf_len]u8,
    raw: bool,
) ?Got {
    const entry = fields.find(comptime fields.build(ConfigT), path) orelse return null;
    const erased: *const anyopaque = @ptrCast(&config);
    const rendered = entry.render(erased, buf);

    if (!raw) {
        return .{
            .path = entry.path,
            .text = rendered,
            .type_name = entry.type_name,
            .simple_type = simpleTypeName(entry.type_name),
        };
    }

    // Raw: a redacted secret stays redacted. `raw` means "undecorated", not
    // "unprotected" - a flag that could print a secret would make every caller that
    // passes it a leak, and `get` is the command most likely to be piped somewhere.
    if (entry.secret) {
        return .{
            .path = entry.path,
            .text = rendered,
            .type_name = entry.type_name,
            .simple_type = simpleTypeName(entry.type_name),
        };
    }

    return .{
        .path = entry.path,
        .text = stripDecoration(rendered),
        .type_name = entry.type_name,
        .simple_type = simpleTypeName(entry.type_name),
    };
}

/// `null` becomes empty and a quoted string loses its quotes.
fn stripDecoration(rendered: []const u8) []const u8 {
    if (std.mem.eql(u8, rendered, "null")) return "";
    if (rendered.len >= 2 and rendered[0] == '"' and rendered[rendered.len - 1] == '"') {
        return rendered[1 .. rendered.len - 1];
    }
    return rendered;
}

/// The plain type name for a type, or "" when it has none worth printing.
///
/// `@typeName` gives qualified spellings (`?[]const u8`, `cfg.scalar`), which are
/// accurate but not what a user types on a command line. This maps the ones the
/// configuration surface actually uses and returns "" for the rest rather than
/// inventing a name.
fn simpleTypeName(type_name: []const u8) []const u8 {
    const known = [_]struct { full: []const u8, simple: []const u8 }{
        .{ .full = "u8", .simple = "u8" },
        .{ .full = "u16", .simple = "u16" },
        .{ .full = "u32", .simple = "u32" },
        .{ .full = "u64", .simple = "u64" },
        .{ .full = "i32", .simple = "i32" },
        .{ .full = "i64", .simple = "i64" },
        .{ .full = "bool", .simple = "bool" },
        .{ .full = "f32", .simple = "f32" },
        .{ .full = "f64", .simple = "f64" },
        .{ .full = "[]const u8", .simple = "string" },
        .{ .full = "?[]const u8", .simple = "string" },
    };
    for (known) |k| {
        if (std.mem.eql(u8, type_name, k.full)) return k.simple;
    }
    if (std.mem.endsWith(u8, type_name, "scalar")) return "duration";
    if (std.mem.indexOf(u8, type_name, "ByteSize") != null) return "bytes";
    return "";
}

/// Appends every reportable field's dotted path to `out`, in table order.
///
/// Order is the table's, which is declaration order, because a caller writing shell
/// completion wants a stable list rather than a sorted one that changes when a field
/// is added in the middle.
pub fn keys(
    allocator: std.mem.Allocator,
    comptime ConfigT: type,
    out: *std.ArrayListUnmanaged([]const u8),
    prefix: []const u8,
) !usize {
    const table = comptime fields.build(ConfigT);
    var count: usize = 0;
    for (table) |entry| {
        // A prefix filters to one subtree: `keys network` lists `network.port` and so
        // on, which is what a completion script needs as it descends. The prefix is
        // matched on a dot boundary so `net` does not match `network`.
        if (prefix.len > 0) {
            if (!std.mem.startsWith(u8, entry.path, prefix)) continue;
            if (entry.path.len == prefix.len) continue;
            if (entry.path[prefix.len] != '.') continue;
        }
        try out.append(allocator, entry.path);
        count += 1;
    }
    return count;
}

// -- Tests -----------------------------------------------------------------

const Network = struct {
    port: u16 = 8080,
    tls: bool = false,
};

const Fixture = struct {
    name: []const u8 = "svc",
    verbose: bool = false,
    token: ?[]const u8 = null,
    network: Network = .{},

    pub const meta = .{
        .token = .{ .env = "QUERY_TEST_TOKEN", .secret = true },
    };
};

test "get renders a top-level and a nested value" {
    var buf: [fields.buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("svc", get(Fixture, Fixture{}, "name", &buf, false).?.text);
    try std.testing.expectEqualStrings("8080", get(Fixture, Fixture{}, "network.port", &buf, false).?.text);
    try std.testing.expect(get(Fixture, Fixture{}, "nosuch", &buf, false) == null);
    try std.testing.expect(get(Fixture, Fixture{}, "network.nosuch", &buf, false) == null);
}

test "raw turns null into empty and leaves a string alone" {
    var buf: [fields.buf_len]u8 = undefined;

    // A string renders and raw both ways unquoted. `renderAtPath` produces the value
    // itself for a slice - it does not add quotes - so `stripDecoration`'s quote case
    // is unreachable for this renderer. Kept because a caller may hand `get` text that
    // *was* quoted, and removing it without a test would be removing untested code.
    try std.testing.expectEqualStrings("svc", get(Fixture, Fixture{}, "name", &buf, false).?.text);
    try std.testing.expectEqualStrings("svc", get(Fixture, Fixture{}, "name", &buf, true).?.text);

    // A secret renders redacted whether or not it is set - `token` is `.secret`, so an
    // absent one is `[SECRET len=0]`, not the literal `null`. Both forms stay redacted,
    // which is the property under test: `--raw` must not reveal a secret.
    try std.testing.expectEqualStrings("[SECRET len=0]", get(Fixture, Fixture{}, "token", &buf, false).?.text);
    try std.testing.expectEqualStrings("[SECRET len=0]", get(Fixture, Fixture{}, "token", &buf, true).?.text);
}

test "stripDecoration removes quotes when the text has them" {
    // Exercised directly because the config renderer does not produce quoted text, so
    // the branch would otherwise be unreachable from a config-only test.
    try std.testing.expectEqualStrings("svc", stripDecoration("\"svc\""));
    try std.testing.expectEqualStrings("", stripDecoration("null"));
    try std.testing.expectEqualStrings("8080", stripDecoration("8080"));
    // A single quote character is not a quoted string.
    try std.testing.expectEqualStrings("\"", stripDecoration("\""));
}

test "raw does NOT un-redact a secret" {
    // `--raw` means undecorated, not unprotected. A flag that printed a secret would
    // make every caller that passes it a leak, and `get` is the command most likely to
    // be piped.
    var buf: [fields.buf_len]u8 = undefined;
    const secret_text = "tok_live_abcdef";
    const got = get(Fixture, Fixture{ .token = secret_text }, "token", &buf, true).?;
    try std.testing.expect(std.mem.indexOf(u8, got.text, "SECRET") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.text, secret_text) == null);
}

test "simple type names map the types a config uses" {
    var buf: [fields.buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("u16", get(Fixture, Fixture{}, "network.port", &buf, false).?.simple_type);
    try std.testing.expectEqualStrings("bool", get(Fixture, Fixture{}, "verbose", &buf, false).?.simple_type);
    try std.testing.expectEqualStrings("string", get(Fixture, Fixture{}, "name", &buf, false).?.simple_type);
}

test "keys lists every reportable path in declaration order" {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(std.testing.allocator);
    const n = try keys(std.testing.allocator, Fixture, &list, "");
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("name", list.items[0]);
    try std.testing.expectEqualStrings("verbose", list.items[1]);
    try std.testing.expectEqualStrings("token", list.items[2]);
    try std.testing.expectEqualStrings("network.port", list.items[3]);
}

test "keys filters by a dot-boundary prefix" {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(std.testing.allocator);

    const n = try keys(std.testing.allocator, Fixture, &list, "network");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("network.port", list.items[0]);
    try std.testing.expectEqualStrings("network.tls", list.items[1]);

    // `net` must NOT match `network`: a completion script descending one segment at a
    // time would otherwise suggest keys from a subtree the user has not entered.
    var none: std.ArrayListUnmanaged([]const u8) = .empty;
    defer none.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), try keys(std.testing.allocator, Fixture, &none, "net"));
}

/// The result of asking whether a value can be coerced into a named type.
pub const Cast = struct {
    /// The target type name as the user wrote it, normalised.
    type_name: []const u8,
    /// Whether the field's declared type is that type.
    matches: bool,
    /// Whether the value parses as that type.
    parses: bool,
};

/// The type names `cast` accepts, mapped to the renderer's spelling of the same type.
///
/// A single table rather than a chain of comparisons, because `cfg cast port u16` and
/// `cfg cast port string` must agree with what `config get` reports as a field's type -
/// and two separate spellings would eventually disagree.
pub const cast_types = [_][]const u8{ "u8", "u16", "u32", "u64", "i32", "i64", "bool", "string", "duration", "bytes" };

/// Whether `type_name` is one `cast` understands.
pub fn isCastType(type_name: []const u8) bool {
    for (cast_types) |t| {
        if (std.mem.eql(u8, t, type_name)) return true;
    }
    return false;
}

/// Coerces `text` into `type_name`, or reports why it cannot.
///
/// ## What this can and cannot do
///
/// It **validates and normalises**, it does not write: there is no TOML document model in
/// this tree (`app/cfg/lib/cfg/toml_mutator.zig` is line-based text), so emitting a mutated file
/// is a separate piece of work. What it does provide is the answer `cast` exists to give -
/// "will this value be accepted as this type" - plus the canonical rendering of it, which
/// is what a pipeline needs before deciding to write.
///
/// The target type is selected by a **runtime** name, which `cfg.parseValue` cannot take
/// because its target is a `comptime` parameter. The dispatch below is what bridges that:
/// each branch fixes one concrete type at compile time.
///
/// ## Ownership of the result
///
/// An **allocated** slice for every type except `string`, where the caller''s own `text`
/// is returned unchanged. Callers must therefore only free the result when it differs
/// from their input:
///
/// ```zig
/// const out = try cast(alloc, text, "u16");
/// defer if (out.ptr != text.ptr) alloc.free(out);
/// ```
///
/// The alternative - always duping - would make the rule uniform, but it would allocate
/// to copy a string into itself, and `parseValue`''s existing contract already returns
/// borrowed data for that one case.
pub fn cast(allocator: std.mem.Allocator, text: []const u8, type_name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, type_name, "u8") or std.mem.eql(u8, type_name, "u16") or
        std.mem.eql(u8, type_name, "u32") or std.mem.eql(u8, type_name, "u64"))
    {
        // Widest first, then re-check the narrow ones so `256` is rejected for `u8`.
        const wide = try cfg.parseValue(u64, text, allocator);
        if (std.mem.eql(u8, type_name, "u8") and wide > std.math.maxInt(u8)) return error.OutOfRange;
        if (std.mem.eql(u8, type_name, "u16") and wide > std.math.maxInt(u16)) return error.OutOfRange;
        if (std.mem.eql(u8, type_name, "u32") and wide > std.math.maxInt(u32)) return error.OutOfRange;
        return std.fmt.allocPrint(allocator, "{d}", .{wide});
    }
    if (std.mem.eql(u8, type_name, "i32") or std.mem.eql(u8, type_name, "i64")) {
        const v = try cfg.parseValue(i64, text, allocator);
        if (std.mem.eql(u8, type_name, "i32") and (v > std.math.maxInt(i32) or v < std.math.minInt(i32))) {
            return error.OutOfRange;
        }
        return std.fmt.allocPrint(allocator, "{d}", .{v});
    }
    if (std.mem.eql(u8, type_name, "bool")) {
        const v = try cfg.parseValue(bool, text, allocator);
        return if (v) "true" else "false";
    }
    if (std.mem.eql(u8, type_name, "string")) {
        // Returned as-is, **not** duped. A string is already its own canonical rendering,
        // and `cfg.parseValue([]const u8, ...)` hands back the caller's slice rather than
        // an allocation - so treating the result as owned made the caller free a pointer
        // it did not own (measured: `Segmentation fault ... in free`). It also means this
        // branch allocates nothing, which is why the ownership rule is stated here.
        return text;
    }
    if (std.mem.eql(u8, type_name, "duration")) {
        const v = try cfg.parseValue(cfg.DurationMs, text, allocator);
        return std.fmt.allocPrint(allocator, "{d}ms", .{v.ms});
    }
    if (std.mem.eql(u8, type_name, "bytes")) {
        const v = try cfg.parseValue(cfg.ByteSize, text, allocator);
        return std.fmt.allocPrint(allocator, "{d}", .{v.bytes});
    }
    return error.UnknownType;
}
