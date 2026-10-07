//! Turning a resolved `ConfigT` into environment-variable form.
//!
//! Two output shapes are supported because two consumers want different ones:
//!
//! * **`.env`** - `KEY="value"` lines, for docker-compose, direnv, a shell.
//! * **systemd** - a `[Service]` unit with `Environment=` lines, the "wire the
//!   current working config into a daemon" case.
//!
//! Both renderers are `src/lib/util/systemd_exporter.zig`; what this file adds
//! is the part that was missing - reflecting a config *type* into a list of
//! variables.
//!
//! ## How a field becomes a variable name
//!
//! 1. If the field's meta declares `.env = "NAME"`, that name wins. It is the
//!    author's explicit statement and is not second-guessed or prefixed.
//! 2. Otherwise the name is derived: the field name uppercased, with `prefix`
//!    prepended when given. Nested structs flatten one level as `OUTER_INNER`.
//!
//! ## What is deliberately not exported
//!
//! **A field marked `.secret = true` contributes its key with an empty value.** It
//! is right for a `.env` file to contain `NATS_API_KEY=""` as a placeholder -
//! omitting the key would misdescribe the config surface and an operator would not
//! learn they may set it. Writing the *value* would put a secret in a plaintext file
//! whose entire purpose is to be read by something else.
//!
//! This mirrors `generateSchema`'s `writeOnly`, and it calls
//! `src/lib/cfg/loader.isSecret` rather than re-deriving the answer, so the schema and
//! the export cannot disagree about which fields are secret.

const std = @import("std");
const cfg = @import("cfg");
const exporter = @import("util").systemd_exporter;

/// One environment variable to export.
pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    /// True when the source field was `.secret = true`. The value is already
    /// empty; this is kept so a caller can report how many secrets were withheld.
    redacted: bool = false,
};

/// Where to write, and what to call the result.
pub const Options = struct {
    /// Prepended to derived names, e.g. `"MYAPP_"`. Ignored for fields that
    /// declare `.env`, because such a name is already absolute.
    prefix: []const u8 = "",
    /// Whether to emit variables whose value is an empty string.
    include_empty: bool = true,
};

/// Collects a config's variables. Owns the arena used for derived names, so the
/// caller's allocator is used for exactly one thing and cannot leak per-value.
pub const Collector = struct {
    arena: std.heap.ArenaAllocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    vars: std.ArrayListUnmanaged(Variable) = .empty,

    pub fn init(gpa: std.mem.Allocator) Collector {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Collector) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn variables(self: Collector) []const Variable {
        return self.vars.items;
    }

    /// How many values were withheld because the field is secret.
    pub fn redactedCount(self: Collector) usize {
        var n: usize = 0;
        for (self.vars.items) |v| {
            if (v.redacted) n += 1;
        }
        return n;
    }

    /// Reflects `config` into variables.
    pub fn collect(self: *Collector, config: anytype, options: Options) !void {
        const T = @TypeOf(config);
        const a = self.arena.allocator();

        inline for (std.meta.fields(T)) |field| {
            const value = @field(config, field.name);

            if (comptime isScalar(field.type)) {
                const name = if (comptime declaredEnv(T, field.name)) |explicit|
                    // Declared names are already absolute: not prefixed.
                    try a.dupe(u8, explicit)
                else
                    try self.deriveName(a, options.prefix, comptime screamSnake(field.name));
                try self.push(name, value, cfg.loader.isSecret(T, field.name), options);
            } else if (comptime isFlattenableStruct(field.type)) {
                const Nested = field.type;
                inline for (std.meta.fields(Nested)) |sub| {
                    const joined = try std.fmt.allocPrint(a, "{s}_{s}", .{
                        comptime screamSnake(field.name),
                        comptime screamSnake(sub.name),
                    });
                    const name = try self.deriveName(a, options.prefix, joined);
                    try self.push(name, @field(value, sub.name), cfg.loader.isSecret(Nested, sub.name), options);
                }
            }
            // Anything else - a pointer, an array, a struct too deep to name well -
            // is skipped rather than guessed at. A wrong variable name is worse
            // than a missing one, because it looks correct.
        }
    }

    fn deriveName(self: *Collector, a: std.mem.Allocator, prefix: []const u8, body: []const u8) ![]const u8 {
        _ = self;
        if (prefix.len == 0) return body;
        return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, body });
    }

    fn push(self: *Collector, name: []const u8, value: anytype, is_secret: bool, options: Options) !void {
        const text = try renderValue(self.arena.allocator(), value, is_secret);
        if (!options.include_empty and text.len == 0) return;
        try self.vars.append(self.arena.allocator(), .{
            .name = name,
            .value = text,
            .redacted = is_secret,
        });
    }
};

/// Renders `vars` as a `.env` file.
pub fn writeDotEnv(allocator: std.mem.Allocator, writer: anytype, vars: []const Variable) !void {
    const mapped = try toEnvVars(allocator, vars);
    defer allocator.free(mapped);
    try exporter.exportDotEnv(writer, mapped);
}

/// Renders `vars` as a systemd unit.
pub fn writeSystemdService(
    allocator: std.mem.Allocator,
    writer: anytype,
    vars: []const Variable,
    service_name: []const u8,
    description: []const u8,
    exec_path: []const u8,
) !void {
    const mapped = try toEnvVars(allocator, vars);
    defer allocator.free(mapped);
    try exporter.exportSystemdService(writer, service_name, description, exec_path, mapped);
}

/// Bridges this module's `Variable` to the exporter's `EnvVar`.
///
/// The exporter's type has no `redacted` field; this is where the two shapes meet
/// rather than duplicating either exporter.
fn toEnvVars(allocator: std.mem.Allocator, vars: []const Variable) ![]exporter.EnvVar {
    const list = try allocator.alloc(exporter.EnvVar, vars.len);
    for (vars, 0..) |v, i| {
        list[i] = .{ .key = v.name, .value = v.value };
    }
    return list;
}

/// Renders `vars` as a shell script of `export` statements.
///
/// The specification calls this the `bash` format. Three things make it usable as
/// something to `source` rather than merely something that looks right:
///
/// * **Values are single-quoted, not double-quoted.** A double-quoted `$`, backtick or
///   `\` would be *expanded* when the script is sourced, so a config value containing
///   `$(rm -rf /)` would execute. Single quotes suppress every expansion, which is the
///   only safe default for data that came from a file.
/// * **A value containing a single quote is escaped**, because that is the one
///   character single quotes cannot hold. `bash` spells it `'\''`.
/// * **Names are validated.** A variable name that is not `[A-Za-z_][A-Za-z0-9_]*`
///   would produce a syntax error, or worse, arbitrary shell. A config field name
///   comes from Zig source so it should always be safe, but a declared `.env` name is
///   author-supplied text and this is the boundary where it becomes executable. Bad
///   names are refused rather than emitted, as `error.InvalidFormat` - the same error
///   the command already returns for a format it does not know, because both mean "what
///   you asked for cannot be rendered", and the framework's error set is closed.
pub fn writeBash(_: std.mem.Allocator, writer: anytype, vars: []const Variable) !void {
    for (vars) |v| {
        if (!isShellIdentifier(v.name)) return error.InvalidFormat;
        try writer.writeAll("export ");
        try writer.writeAll(v.name);
        try writer.writeAll("='");
        try writeSingleQuoted(writer, v.value);
        try writer.writeAll("'\n");
    }
}

/// Writes `text` so it is safe *inside* an existing pair of single quotes.
fn writeSingleQuoted(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        if (c == '\'') {
            // Close the quote, emit an escaped quote, reopen.
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(c);
        }
    }
}

/// Whether `name` is a portable shell variable name.
pub fn isShellIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Renders `vars` as a flat JSON object.
///
/// Flat rather than nested: the variables are already flattened by `Collector`, and
/// reconstructing the nesting from `TLS_ENABLED` would be guesswork. What this is for
/// is a pipeline that wants the resolved values as data rather than as shell text.
///
/// **Values are JSON strings, including numbers and booleans.** `port` renders as
/// `"8080"` rather than `8080`, because the collector has already discarded the type
/// and re-guessing it would turn a string field holding `"8080"` into a number. A
/// consumer that wants types should use `config schema`, which still has them.
pub fn writeJson(_: std.mem.Allocator, writer: anytype, vars: []const Variable) !void {
    try writer.writeAll("{\n");
    for (vars, 0..) |v, i| {
        try writer.writeAll("  ");
        try writeJsonString(writer, v.name);
        try writer.writeAll(": ");
        try writeJsonString(writer, v.value);
        if (i + 1 < vars.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("}\n");
}

/// Writes `text` as a quoted JSON string, escaping what RFC 8259 requires.
fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                // Everything below 0x20 must be escaped; anything else is valid UTF-8
                // and is passed through, so a non-ASCII value stays readable.
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// Renders one value into `a`.
///
/// The text is allocated in the collector's arena rather than a shared buffer.
/// An earlier version wrote into a module-level `[512]u8` and returned a slice of it,
/// which meant **every** variable aliased the last one rendered - six tests caught
/// it (`declared env names are used verbatim`, `dotenv output carries every
/// variable`, and four more). Arena allocation is what makes each value independent.
///
/// A secret returns empty without the value ever being formatted.
fn renderValue(a: std.mem.Allocator, value: anytype, is_secret: bool) ![]const u8 {
    if (is_secret) return "";

    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| renderValue(a, v, false) else "",
        .bool => if (value) "true" else "false",
        .int => std.fmt.allocPrint(a, "{d}", .{value}),
        .float => std.fmt.allocPrint(a, "{d}", .{value}),
        .pointer => |p| if (p.size == .slice and p.child == u8) value else error.UnsupportedValue,
        .@"struct" => blk: {
            // The config scalar types have meaningful text forms.
            if (T == cfg.DurationMs) break :blk std.fmt.allocPrint(a, "{d}ms", .{value.ms});
            if (T == cfg.ByteSize) break :blk std.fmt.allocPrint(a, "{d}", .{value.bytes});
            break :blk error.UnsupportedValue;
        },
        else => error.UnsupportedValue,
    };
}
/// Types that map to a single variable.
fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool => true,
        .pointer => |p| p.size == .slice and p.child == u8,
        .optional => |o| isScalar(o.child),
        .@"struct" => T == cfg.DurationMs or T == cfg.ByteSize,
        else => false,
    };
}

/// A struct worth flattening one level: not a scalar type, and every field is.
///
/// Deeper shapes are refused because a three-segment name stops looking like an
/// environment variable; such a config should declare `.env`.
fn isFlattenableStruct(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (T == cfg.DurationMs or T == cfg.ByteSize) return false;
    for (std.meta.fields(T)) |f| {
        if (!isScalar(f.type)) return false;
    }
    return true;
}

/// The `.env` name a field declares, or null.
fn declaredEnv(comptime T: type, comptime field_name: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "meta")) return null;
    const Meta = @TypeOf(T.meta);
    if (!@hasField(Meta, field_name)) return null;
    const fmeta = @field(T.meta, field_name);
    if (!@hasField(@TypeOf(fmeta), "env")) return null;
    return @field(fmeta, "env");
}

/// Uppercases a field name at comptime.
///
/// Deliberately does not insert underscores at case boundaries: `maxPayload` would
/// become `MAXPAYLOAD`. A field named that way should declare `.env` rather than
/// have the framework guess where the word breaks are.
fn screamSnake(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        const frozen = out;
        return &frozen;
    }
}

// -- Tests -----------------------------------------------------------------

const Cluster = struct {
    port: u16 = 6222,
    name: []const u8 = "n1",
};

const Fixture = struct {
    port: u16 = 4222,
    enable_websocket: bool = true,
    server_name: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    max_payload: cfg.ByteSize = .{ .bytes = 1048576 },
    ping: cfg.DurationMs = .{ .ms = 2000 },
    cluster: Cluster = .{},

    pub const meta = .{
        .api_key = .{ .env = "NATS_API_KEY", .secret = true },
        .server_name = .{ .env = "SERVER_NAME" },
    };
};

fn findVar(vars: []const Variable, name: []const u8) ?Variable {
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, name)) return v;
    }
    return null;
}

test "declared env names are used verbatim and derived names are uppercased" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{ .api_key = "s", .server_name = "srv" }, .{});

    try std.testing.expectEqualStrings("srv", findVar(c.variables(), "SERVER_NAME").?.value);
    try std.testing.expectEqualStrings("4222", findVar(c.variables(), "PORT").?.value);
    try std.testing.expectEqualStrings("true", findVar(c.variables(), "ENABLE_WEBSOCKET").?.value);
    try std.testing.expectEqualStrings("1048576", findVar(c.variables(), "MAX_PAYLOAD").?.value);
    try std.testing.expectEqualStrings("2000ms", findVar(c.variables(), "PING").?.value);
}

test "nested structs flatten one level with the outer name" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{}, .{});
    try std.testing.expectEqualStrings("6222", findVar(c.variables(), "CLUSTER_PORT").?.value);
    try std.testing.expectEqualStrings("n1", findVar(c.variables(), "CLUSTER_NAME").?.value);
}

test "an absent optional renders empty rather than failing" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{}, .{});
    try std.testing.expectEqualStrings("", findVar(c.variables(), "SERVER_NAME").?.value);
}

test "include_empty = false drops empty values" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{}, .{ .include_empty = false });
    try std.testing.expect(findVar(c.variables(), "SERVER_NAME") == null);
    try std.testing.expect(findVar(c.variables(), "PORT") != null);
}

test "a prefix applies to derived names and NOT to declared ones" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{}, .{ .prefix = "APP_" });

    // Declared names are absolute: `NATS_API_KEY` must not become `APP_NATS_API_KEY`.
    try std.testing.expect(findVar(c.variables(), "NATS_API_KEY") != null);
    try std.testing.expect(findVar(c.variables(), "APP_PORT") != null);
    try std.testing.expect(findVar(c.variables(), "APP_CLUSTER_PORT") != null);
    try std.testing.expect(findVar(c.variables(), "APP_SERVER_NAME") == null);
}

test "a secret contributes its key but never its value" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const secret_text = "super-secret-value";
    try c.collect(Fixture{ .api_key = secret_text }, .{});

    const v = findVar(c.variables(), "NATS_API_KEY").?;
    try std.testing.expect(v.redacted);
    try std.testing.expectEqualStrings("", v.value);
    try std.testing.expectEqual(@as(usize, 1), c.redactedCount());

    // And the rendered file contains the key but not the value. This is the
    // assertion that matters: it catches a redaction that returned the value.
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDotEnv(std.testing.allocator, &w, c.variables());
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "NATS_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, secret_text) == null);
}

test "dotenv output carries every variable" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{ .server_name = "srv" }, .{});

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDotEnv(std.testing.allocator, &w, c.variables());
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "PORT=\"4222\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SERVER_NAME=\"srv\"") != null);
}

test "systemd output has the unit sections and the variables" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{}, .{});

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeSystemdService(std.testing.allocator, &w, c.variables(), "svc", "a service", "/usr/bin/svc");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[Service]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ExecStart=/usr/bin/svc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Environment=\"PORT=4222\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Install]") != null);
}

test "collector deinit does not leak" {
    // std.testing.allocator reports leaks; simply running a collect and freeing
    // is the assertion. Derived names live in the collector's arena, so a missing
    // deinit would be reported here.
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try c.collect(Fixture{}, .{ .prefix = "X_" });
}

test "bash output single-quotes values and refuses a bad name" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const vars = [_]Variable{
        .{ .name = "PORT", .value = "8080" },
        .{ .name = "GREETING", .value = "hi there" },
    };
    try writeBash(std.testing.allocator, &w, &vars);
    try std.testing.expectEqualStrings(
        "export PORT='8080'\nexport GREETING='hi there'\n",
        w.buffered(),
    );

    // A name that is not a shell identifier must be refused rather than emitted: a
    // declared `.env` name is author-supplied text and this is where it becomes code.
    var buf2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    const bad = [_]Variable{.{ .name = "FOO; rm -rf /", .value = "x" }};
    try std.testing.expectError(error.InvalidFormat, writeBash(std.testing.allocator, &w2, &bad));
    try std.testing.expectEqual(@as(usize, 0), w2.buffered().len);
}

test "bash does not expand a value that would execute when sourced" {
    // Single quotes suppress expansion, so `$(...)` and backticks stay literal. With
    // double quotes this value would run when the script is sourced - which is the
    // whole reason the format uses single quotes.
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const vars = [_]Variable{
        .{ .name = "EVIL", .value = "$(touch /tmp/pwned)" },
        .{ .name = "TICKS", .value = "`id`" },
        .{ .name = "VAR", .value = "$HOME" },
    };
    try writeBash(std.testing.allocator, &w, &vars);
    const out = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "export EVIL='$(touch /tmp/pwned)'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "export TICKS='`id`'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "export VAR='$HOME'") != null);
    // No double-quoted form anywhere.
    try std.testing.expect(std.mem.indexOf(u8, out, "=\"") == null);
}

test "bash escapes a single quote inside a value" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const vars = [_]Variable{.{ .name = "MSG", .value = "it's fine" }};
    try writeBash(std.testing.allocator, &w, &vars);
    // `'\''` is how a single quote is spelled inside a single-quoted shell string.
    try std.testing.expectEqualStrings("export MSG='it'\\''s fine'\n", w.buffered());
}

test "json output is a flat object with quoted values" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const vars = [_]Variable{
        .{ .name = "PORT", .value = "8080" },
        .{ .name = "NAME", .value = "svc" },
    };
    try writeJson(std.testing.allocator, &w, &vars);
    try std.testing.expectEqualStrings(
        "{\n  \"PORT\": \"8080\",\n  \"NAME\": \"svc\"\n}\n",
        w.buffered(),
    );
}

test "json escapes quotes, backslashes and control characters" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const vars = [_]Variable{.{ .name = "Q", .value = "a\"b\\c\nd\te" }};
    try writeJson(std.testing.allocator, &w, &vars);
    const out = w.buffered();

    // The output must be parseable as a JSON object; escaping is what makes it so.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\\c\nd\te", parsed.value.object.get("Q").?.string);
}

test "json with no variables is still a valid empty object" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJson(std.testing.allocator, &w, &.{});
    try std.testing.expectEqualStrings("{\n}\n", w.buffered());

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.count());
}

test "isShellIdentifier accepts the portable form only" {
    try std.testing.expect(isShellIdentifier("PORT"));
    try std.testing.expect(isShellIdentifier("_x1"));
    try std.testing.expect(!isShellIdentifier(""));
    try std.testing.expect(!isShellIdentifier("1PORT"));
    try std.testing.expect(!isShellIdentifier("WITH-DASH"));
    try std.testing.expect(!isShellIdentifier("A B"));
    try std.testing.expect(!isShellIdentifier("A;B"));
}
