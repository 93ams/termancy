//! Seeded property and robustness tests for the five codecs.
//!
//! Every case derives from a fixed seed, so a failure reproduces exactly: the failing seed
//! is printed with the input, and `case(seed)` regenerates it. Set `trace` to print every
//! input before it is parsed, which locates a case that panics.
//!
//! Properties:
//! - a random tree, valid for the format, reads back equal to what was written;
//! - random bytes and random mutations of valid documents parse to a value or to
//!   `error.SyntaxError` with a diagnostic, and a parsed value writes and reads back;
//! - allocation failure at any point is `error.OutOfMemory`;
//! - an in-place edit (`edit.apply`) of any document either declines or reads back as the
//!   change describes, and changing a scalar of a written TOML document always succeeds;
//! - nesting far past `max_depth` is an error, not a stack overflow;
//! - reformatting is idempotent;
//! - any parsed tree decodes into a struct or fails with a diagnostic, and what decodes
//!   encodes and decodes back the same.
//!
//! The parser, edit, reformat, and decode properties also run under Zig's coverage-guided
//! fuzzer: `zig build fuzz --fuzz` (or `--fuzz=100K` for a bounded run) explores them from
//! `corpus` and `regressions`. A plain test run replays those inputs, so a crash the fuzzer finds
//! becomes a regression test by adding its input to `regressions`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Table = value_mod.Table;
const Array = value_mod.Array;
const Format = @import("format.zig").Format;
const Diagnostic = @import("Diagnostic.zig");
const json = @import("json.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const dotenv = @import("dotenv.zig");
const zon = @import("zon.zig");
const ini = @import("ini.zig");
const edit = @import("edit.zig");
const locate = @import("locate.zig");
const path = @import("path.zig");
const decoding = @import("decode.zig");
const scalar = @import("scalar.zig");
const settings_ = @import("settings.zig");
const encrypted = @import("encrypted.zig");
const field = @import("field");

const testing = std.testing;

/// Print every input before parsing it.
const trace = false;

/// What a format can represent, so that generated trees are valid for it.
const Rules = struct {
    null: bool,
    /// `inf` and `-inf`. `nan` is never generated: it is not equal to itself.
    infinity: bool,
    /// Only a table may be the root.
    table_root: bool,
    /// Empty arrays: ZON spells one `.{}`, which reads back as an empty table.
    empty_array: bool = true,
    /// Keys that are empty or contain a zero byte, which ZON cannot spell.
    any_key: bool = true,
    max_depth: usize = 4,
    max_width: usize = 4,

    fn of(format: Format) Rules {
        return switch (format) {
            .json, .jsonc => .{ .null = true, .infinity = false, .table_root = false },
            .toml => .{ .null = false, .infinity = true, .table_root = true },
            .yaml => .{ .null = true, .infinity = true, .table_root = false },
            .zon => .{
                .null = true,
                .infinity = true,
                .table_root = false,
                .empty_array = false,
                .any_key = false,
            },
            .dotenv, .ini => unreachable, // Strings only: not round-tripped as typed trees.
        };
    }
};

/// Strings that each format must quote, escape, or otherwise treat with care.
const tricky_strings = [_][]const u8{
    "",          " ",        " lead",  "trail ", "\u{e9}",     "\u{1F40D}",
    "\u{feff}x", "\u{2028}", "\u{85}", "\u{a0}", "\"q\"",      "'s'",
    "#",         "a #b",     "a#b",    ":",      "a:b",        "a: b",
    "a:",        "k=v",      "=",      "$HOME",  "${X}",       "${X:-y}",
    "$",         "\n",       "a\nb",   "\r\n",   "\t",         "a\tb",
    "0",         "123",      "-1",     "+1",     "1.5",        "1e3",
    "-0",        "0x1F",     "0o7",    "0b1",    "1_000",      "true",
    "False",     "TRUE",     "null",   "Null",   "~",          "yes",
    "off",       ".inf",     "-.inf",  ".nan",   "inf",        "nan",
    "-",         "- a",      "--- x",  "---",    "...",        "<<",
    "[a]",       "{}",       "[",      "}",      ",",          "?",
    "? x",       "| x",      "> x",    "|",      "&a",         "*a",
    "!t",        "%x",       "@",      "`",      "\\",         "a\\nb",
    "\x00",      "\x01",     "\x1b",   "\x7f",   "1979-05-27", "07:32:00",
    "a.b",       "\"",       "'",      "''",     "a'b",        "a\"b",
    "  two  ",   "a,b",      "a, b",   "%YAML",  "#!",         "8080/tcp",
};

/// Pieces random strings are made of: syntax characters of every format, a few control
/// bytes, and multi-byte UTF-8.
const string_pieces = [_][]const u8{
    " ",      "\t", "\n",   "\r",   "\"",     "'",    "#",      ":",         "=",        "$",
    "\\",     "{",  "}",    "[",    "]",      ",",    "-",      ".",         "|",        ">",
    "&",      "*",  "!",    "%",    "@",      "`",    "~",      "?",         "0",        "1",
    "9",      "a",  "e",    "E",    "f",      "n",    "l",      "t",         "r",        "u",
    "x",      "_",  "\x00", "\x01", "\x1b",   "\x7f", "\u{e9}", "\u{1F40D}", "\u{feff}", "\u{2028}",
    "\u{a0}", "{{", "${",   "\\u",  "\"\"\"", "'''",  ": ",     " #",
};

const special_floats = [_]f64{
    0.0,                     -0.0,                    1.0,
    -1.5,                    0.1,                     1e21,
    1e-7,                    1e300,                   -1e-300,
    5e-324,                  2.2250738585072014e-308, std.math.floatMax(f64),
    -std.math.floatMax(f64), 9007199254740993.0,      123456789.125,
};

fn pick(random: std.Random, items: anytype) @TypeOf(items[0]) {
    return items[random.uintLessThan(usize, items.len)];
}

const Gen = struct {
    random: std.Random,
    arena: Allocator,
    rules: Rules,

    fn tree(g: *Gen) Allocator.Error!Value {
        if (g.rules.table_root or g.random.uintLessThan(u8, 4) != 0) return g.table(0);
        return g.value(0);
    }

    fn value(g: *Gen, depth: usize) Allocator.Error!Value {
        if (depth < g.rules.max_depth and g.random.uintLessThan(u8, 3) == 0) {
            return if (g.random.boolean()) g.table(depth + 1) else g.array(depth + 1);
        }
        return g.scalar();
    }

    fn table(g: *Gen, depth: usize) Allocator.Error!Value {
        var t: Table = .empty;
        const width = g.random.uintAtMost(usize, g.rules.max_width);
        for (0..width) |_| {
            const key = try g.tableKey();
            // A duplicate key keeps its first value; the tree stays valid either way.
            const gop = try t.getOrPut(g.arena, key);
            if (!gop.found_existing) gop.value_ptr.* = try g.value(depth);
        }
        return .{ .table = t };
    }

    fn array(g: *Gen, depth: usize) Allocator.Error!Value {
        var a: Array = .empty;
        const min_width: usize = if (g.rules.empty_array) 0 else 1;
        const width = g.random.intRangeAtMost(usize, min_width, g.rules.max_width);
        // Arrays of tables are their own TOML syntax; make them likely.
        const tables = g.random.uintLessThan(u8, 3) == 0;
        for (0..width) |_| {
            try a.append(g.arena, if (tables) try g.table(depth) else try g.value(depth));
        }
        return .{ .array = a };
    }

    fn scalar(g: *Gen) Allocator.Error!Value {
        return switch (g.random.uintLessThan(u8, 8)) {
            0 => if (g.rules.null) .null else .{ .bool = g.random.boolean() },
            1 => .{ .bool = g.random.boolean() },
            2 => .{ .int = g.int() },
            3 => .{ .float = g.float() },
            else => .{ .string = try g.string() },
        };
    }

    fn int(g: *Gen) i64 {
        return switch (g.random.uintLessThan(u8, 6)) {
            0 => std.math.minInt(i64),
            1 => std.math.maxInt(i64),
            2 => g.random.intRangeAtMost(i64, -3, 3),
            3 => g.random.intRangeAtMost(i64, -100_000, 100_000),
            else => g.random.int(i64),
        };
    }

    fn float(g: *Gen) f64 {
        switch (g.random.uintLessThan(u8, 5)) {
            0 => return pick(g.random, &special_floats),
            1 => if (g.rules.infinity) {
                return if (g.random.boolean()) std.math.inf(f64) else -std.math.inf(f64);
            } else return 0.5,
            2 => return @as(f64, @floatFromInt(g.random.intRangeAtMost(i32, -1000, 1000))) / 8,
            else => while (true) {
                const f: f64 = @bitCast(g.random.int(u64));
                if (std.math.isFinite(f)) return f;
            },
        }
    }

    fn tableKey(g: *Gen) Allocator.Error![]const u8 {
        const k = try g.string();
        if (g.rules.any_key) return k;
        if (k.len == 0) return "k";
        const copy = try g.arena.dupe(u8, k);
        std.mem.replaceScalar(u8, copy, 0, '0');
        return copy;
    }

    fn string(g: *Gen) Allocator.Error![]const u8 {
        if (g.random.boolean()) return pick(g.random, &tricky_strings);
        var out: std.ArrayList(u8) = .empty;
        const len = g.random.uintAtMost(usize, 8);
        for (0..len) |_| {
            try out.appendSlice(g.arena, pick(g.random, &string_pieces));
        }
        return out.items;
    }
};

fn writeAlloc(gpa: Allocator, format: Format, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try format.write(&out.writer, value);
    return out.toOwnedSlice();
}

/// Writes with one of the format's non-default option sets, chosen by `variant`.
fn writeVariant(gpa: Allocator, format: Format, value: Value, variant: u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    switch (format) {
        .json => try json.write(w, value, .{ .indent = if (variant % 2 == 0) 0 else 4 }),
        .toml => try toml.write(w, value, .{ .array_sections = false }),
        .yaml => try yaml.write(w, value, .{ .indent = @intCast(variant % 3 * 3) }), // 0, 3, 6
        .dotenv => try dotenv.write(w, value, .{ .@"export" = true }),
        .zon => try zon.write(w, value, .{ .indent = if (variant % 2 == 0) 0 else 2 }),
        .jsonc => try json.write(w, value, .{ .indent = 1 }),
        .ini => try ini.write(w, value),
    }
    return out.toOwnedSlice();
}

fn report(format: Format, seed: u64, what: []const u8, input: []const u8) void {
    std.debug.print("\n{t} {s} failed, seed {d}, input ({d} bytes):\n{f}\n", .{
        format,
        what,
        seed,
        input.len,
        std.ascii.hexEscape(input, .lower),
    });
}

/// `parse(write(v))` equals `v` for a random tree `v` that `format` can represent.
fn expectRoundTrip(format: Format, seed: u64) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    var gen: Gen = .{ .random = prng.random(), .arena = arena.allocator(), .rules = .of(format) };
    const tree = try gen.tree();
    const text = writeAlloc(testing.allocator, format, tree) catch |err| {
        std.debug.print("\n{t} write failed ({t}), seed {d}: {f}\n", .{ format, err, seed, tree });
        return err;
    };
    defer testing.allocator.free(text);
    if (trace) report(format, seed, "trace", text);
    var diag: Diagnostic = .{};
    const back = format.parse(arena.allocator(), text, &diag) catch |err| {
        report(format, seed, "round trip (parse)", text);
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    if (!tree.eql(back)) {
        report(format, seed, "round trip (equality)", text);
        std.debug.print("wrote: {f}\nread:  {f}\n", .{ tree, back });
        return error.TestExpectedEqual;
    }
    const variant = try writeVariant(testing.allocator, format, tree, @truncate(seed));
    defer testing.allocator.free(variant);
    const again = format.parse(arena.allocator(), variant, &diag) catch |err| {
        report(format, seed, "round trip with options (parse)", variant);
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    if (!tree.eql(again)) {
        report(format, seed, "round trip with options (equality)", variant);
        std.debug.print("wrote: {f}\nread:  {f}\n", .{ tree, again });
        return error.TestExpectedEqual;
    }
}

/// A random table that dotenv can write: lower-case keys made of letters, digits (not
/// first, as a variable name cannot start with one), and single inner `_`, so that no two
/// keys map to one variable name, and arrays of scalars.
fn dotenvTree(g: *Gen, depth: usize) Allocator.Error!Value {
    var t: Table = .empty;
    const width = g.random.uintAtMost(usize, g.rules.max_width);
    for (0..width) |_| {
        const key = try dotenvKey(g);
        const gop = try t.getOrPut(g.arena, key);
        if (gop.found_existing) continue;
        gop.value_ptr.* = switch (g.random.uintLessThan(u8, 5)) {
            0 => if (depth < g.rules.max_depth) try dotenvTree(g, depth + 1) else .null,
            1 => blk: {
                var a: Array = .empty;
                for (0..g.random.uintAtMost(usize, 3)) |_| try a.append(g.arena, try g.scalar());
                break :blk .{ .array = a };
            },
            else => try g.scalar(),
        };
    }
    return .{ .table = t };
}

fn dotenvKey(g: *Gen) Allocator.Error![]const u8 {
    const alphabet = "abcxyz019";
    const len = 1 + g.random.uintLessThan(usize, 6);
    const key = try g.arena.alloc(u8, len);
    for (key, 0..) |*c, i| {
        const underscore = i > 0 and i + 1 < len and key[i - 1] != '_' and
            g.random.uintLessThan(u8, 4) == 0;
        const letters: usize = if (i == 0) 6 else alphabet.len;
        c.* = if (underscore) '_' else alphabet[g.random.uintLessThan(usize, letters)];
    }
    return key;
}

/// The tree dotenv reads back: every leaf is its text, and empty tables vanish.
fn dotenvText(arena: Allocator, value: Value) Allocator.Error!?Value {
    switch (value) {
        .table => |t| {
            var out: Table = .empty;
            var it = t.iterator();
            while (it.next()) |entry| {
                const child = try dotenvText(arena, entry.value_ptr.*) orelse continue;
                try out.put(arena, entry.key_ptr.*, child);
            }
            return if (out.count() == 0) null else .{ .table = out };
        },
        // The writer leaves null leaves out.
        .null => return null,
        .string => return value,
        .array => |a| {
            var text: std.Io.Writer.Allocating = .init(arena);
            for (a.items, 0..) |item, i| {
                if (i > 0) text.writer.writeByte(',') catch return error.OutOfMemory;
                text.writer.print("{f}", .{item}) catch return error.OutOfMemory;
            }
            return .{ .string = text.written() };
        },
        else => return .{ .string = try std.fmt.allocPrint(arena, "{f}", .{value}) },
    }
}

/// dotenv reads back the text of every leaf, and writing what it read is byte-identical.
fn expectDotenvRoundTrip(seed: u64) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(seed);
    var gen: Gen = .{
        .random = prng.random(),
        .arena = a,
        .rules = .{ .null = true, .infinity = true, .table_root = true },
    };
    const tree = try dotenvTree(&gen, 0);
    const first = try writeAlloc(a, .dotenv, tree);
    if (trace) report(.dotenv, seed, "trace", first);
    const back = dotenv.parse(a, first, null) catch |err| {
        report(.dotenv, seed, "round trip (parse)", first);
        return err;
    };
    const expected = try dotenvText(a, tree) orelse Value.empty_table;
    if (!expected.eql(back)) {
        report(.dotenv, seed, "round trip (text)", first);
        std.debug.print("expected: {f}\nread:     {f}\n", .{ expected, back });
        return error.TestExpectedEqual;
    }
    const second = try writeAlloc(a, .dotenv, back);
    if (!std.mem.eql(u8, first, second)) {
        report(.dotenv, seed, "round trip (bytes)", first);
        std.debug.print("second write:\n{s}\n", .{second});
        return error.TestExpectedEqual;
    }
}

/// `eql`, except that `nan` equals `nan`.
fn sameValue(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .float => |x| return x == b.float or (std.math.isNan(x) and std.math.isNan(b.float)),
        .array => |x| {
            if (x.items.len != b.array.items.len) return false;
            for (x.items, b.array.items) |l, r| if (!sameValue(l, r)) return false;
            return true;
        },
        .table => |x| {
            if (x.count() != b.table.count()) return false;
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.table.get(entry.key_ptr.*) orelse return false;
                if (!sameValue(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
        else => return a.eql(b),
    }
}

/// Parsing `input` returns a value or `error.SyntaxError` with a diagnostic. A value then
/// writes, unless the format cannot spell it, and reads back the same.
fn expectRobust(format: Format, input: []const u8, seed: u64) !void {
    if (trace) report(format, seed, "trace", input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const parsed = format.parse(a, input, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SyntaxError => {
            if (diag.message.len == 0 or diag.line == 0 or diag.column == 0) {
                report(format, seed, "diagnostic", input);
                return error.TestUnexpectedResult;
            }
            return;
        },
    };
    const text = writeAlloc(a, format, parsed) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // JSON has no `inf` (`1e400` reads as one), TOML no `null`, and so on.
        error.Unrepresentable => return,
        error.WriteFailed => unreachable, // An allocating writer fails only on memory.
    };
    const back = format.parse(a, text, &diag) catch |err| {
        report(format, seed, "re-read of a written value", input);
        std.debug.print("wrote:\n{s}\n{f}\n", .{ text, diag });
        return err;
    };
    // dotenv maps keys to names lossily (`a-b` and `a_b` are one name), so only the
    // structured formats must read back equal.
    if (format != .dotenv and !sameValue(parsed, back)) {
        report(format, seed, "re-read equality", input);
        std.debug.print("wrote:\n{s}\nfirst:  {f}\nsecond: {f}\n", .{ text, parsed, back });
        return error.TestExpectedEqual;
    }
}

/// Bytes biased towards each format's syntax, with an occasional arbitrary byte.
const syntax_bytes = " \t\n\n\n\r\"'#:=$\\{}[],-.|>&*!%@`~?_+0123456789aeEtrufnlsxob";

fn randomBytes(random: std.Random, buffer: []u8) []u8 {
    const len = random.uintAtMost(usize, buffer.len);
    for (buffer[0..len]) |*c| c.* = randomByte(random);
    return buffer[0..len];
}

fn randomByte(random: std.Random) u8 {
    if (random.uintLessThan(u8, 16) == 0) return random.int(u8);
    return syntax_bytes[random.uintLessThan(usize, syntax_bytes.len)];
}

/// Applies one to four random edits to `doc`.
fn mutate(random: std.Random, gpa: Allocator, doc: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, doc);
    for (0..1 + random.uintLessThan(usize, 4)) |_| {
        const len = out.items.len;
        switch (random.uintLessThan(u8, 6)) {
            0 => try out.insert(gpa, random.uintAtMost(usize, len), randomByte(random)),
            1 => if (len > 0) {
                _ = out.orderedRemove(random.uintLessThan(usize, len));
            },
            2 => if (len > 0) {
                out.items[random.uintLessThan(usize, len)] = randomByte(random);
            },
            3 => if (len > 0) {
                out.items[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3);
            },
            4 => if (len > 0) {
                // Duplicate a slice in place, which repeats keys and nests structures.
                const start = random.uintLessThan(usize, len);
                const end = start + random.uintAtMost(usize, @min(len - start, 16));
                const copy = try gpa.dupe(u8, out.items[start..end]);
                defer gpa.free(copy);
                try out.insertSlice(gpa, end, copy);
            },
            else => out.shrinkRetainingCapacity(random.uintAtMost(usize, len)),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Hand-written documents that exercise each format's syntax, as seeds for mutation.
fn corpus(format: Format) []const []const u8 {
    return switch (format) {
        .json => &.{
            \\{"a": 1, "b": [true, null, 2.5e-3, "x\n\u00e9"], "c": {"d": -0, "e": {}}}
            ,
            "[1, [2, [3, []]], {\"k\": \"v\"}, -9223372036854775808, 1e400]",
            "\"top\"",
        },
        .toml => &.{
            \\# comment
            \\title = "t" # trailing
            \\"quoted key" = 'lit'
            \\a.b.c = 1_000
            \\hex = 0xDEAD_beef
            \\f = [1.5e3, -inf, nan, +0.0]
            \\d = 1979-05-27T07:32:00Z
            \\ml = """
            \\x \
            \\  y"""
            \\inline = { x = 1, y.z = [ { w = 'q' } ] }
            \\[server]
            \\host = "h\u00e9"
            \\[[server.items]]
            \\n = 1
            \\[[server.items]]
            \\n = 2
            \\
            ,
        },
        .yaml => &.{
            \\# comment
            \\server:
            \\  host: "h\u00e9"
            \\  port: 0x1F
            \\  tags: [a, 'b c', {k: v}]
            \\list:
            \\- one
            \\- - nested
            \\  - 1.5e3
            \\- key: value
            \\  other: ~
            \\text: |+
            \\  line
            \\
            \\folded: >-
            \\  a
            \\  b
            \\quoted: 'it''s
            \\  folded'
            \\...
            \\
            ,
            "--- [1, 2, {a: b}]\n",
        },
        .zon => &.{
            \\// comment
            \\.{
            \\    .name = "h\u{e9}\x41\n",
            \\    .@"quoted key" = 'c',
            \\    .ports = .{ 8000, 0x1F, 0o7, 0b1, 1_000, -9223372036854775808 },
            \\    .floats = .{ 1.5e3, -0.0, 0x1p-2, inf, -inf, nan },
            \\    .flags = .{ true, false, null, .enum_literal },
            \\    .multi =
            \\    \\line one
            \\    \\line "two"
            \\    ,
            \\    .nested = .{ .deeper = .{ .{}, .{ .x = 1 } } },
            \\    .big = 18446744073709551616,
            \\}
            \\
            ,
            ".{ 1, .{ 2, .{ 3, .{} } }, \"top\" }",
            "\"just a string\"",
        },
        .dotenv => &.{
            \\# comment
            \\export A=1
            \\B="two words $A\n"
            \\C='lit $A'
            \\D=${A:-x}${MISSING:-${A}}
            \\SERVER__PORT=8080 # trailing
            \\E=a#b
            \\
            ,
        },
        .jsonc => &.{
            \\// comment
            \\{"a": [1, 2,], /* x */ "b": {"c": "//", "d": "/*",},}
            ,
        },
        .ini => &.{
            \\; comment
            \\name = demo
            \\[server]
            \\port: 8080 ; inline
            \\motto = "a;b \"q\""
            \\[server.tls]
            \\cert = c.pem
            \\["a.b"]
            \\
            ,
        },
    };
}

const formats = std.enums.values(Format);

test "random trees round-trip through json, toml, yaml, and zon" {
    for (formats) |format| {
        if (format == .dotenv or format == .ini) continue;
        const base: u64 = 0x5eed_0000 + @as(u64, @backingInt(format)) * 0x1_0000;
        for (0..300) |i| try expectRoundTrip(format, base + i);
    }
}

test "random trees round-trip through dotenv as text" {
    for (0..300) |i| try expectDotenvRoundTrip(0xd07e_0000 + i);
}

test "random bytes parse or fail cleanly" {
    var buffer: [96]u8 = undefined;
    for (formats) |format| {
        const base: u64 = 0xb17e_0000 + @as(u64, @backingInt(format)) * 0x1_0000;
        for (0..1500) |i| {
            const seed = base + i;
            var prng: std.Random.DefaultPrng = .init(seed);
            try expectRobust(format, randomBytes(prng.random(), &buffer), seed);
        }
    }
}

test "mutated documents parse or fail cleanly" {
    for (formats) |format| {
        const base: u64 = 0x3075_0000 + @as(u64, @backingInt(format)) * 0x1_0000;
        for (0..1500) |i| {
            const seed = base + i;
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            // Half from the corpus, half from what the writer produces for a random tree.
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const docs = corpus(format);
            const doc = if (format == .dotenv or format == .ini or random.boolean())
                docs[random.uintLessThan(usize, docs.len)]
            else blk: {
                var gen: Gen = .{
                    .random = random,
                    .arena = arena.allocator(),
                    .rules = .of(format),
                };
                break :blk try writeAlloc(arena.allocator(), format, try gen.tree());
            };
            const input = try mutate(random, testing.allocator, doc);
            defer testing.allocator.free(input);
            try expectRobust(format, input, seed);
        }
    }
}

/// Applies a random change to `doc`: to an existing leaf or a new key, a set or an unset.
/// Returns whether the edit was made in place; checks the result when it was.
fn expectEdit(format: Format, doc: []const u8, random: std.Random, seed: u64) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tree = format.parse(arena, doc, null) catch return false;
    var leaves: std.ArrayList([]const u8) = .empty;
    try tree.leafPaths(arena, "", &leaves);
    const key = if (leaves.items.len > 0 and random.uintLessThan(u8, 4) != 0)
        leaves.items[random.uintLessThan(usize, leaves.items.len)]
    else
        pick(random, [_][]const u8{ "new", "a.b", "x.\"y z\"", "0", "n.0.k" });
    var gen: Gen = .{ .random = random, .arena = arena, .rules = .of(.toml) };
    const change: edit.Change = if (random.uintLessThan(u8, 3) == 0)
        .{ .unset = key }
    else
        .{ .set = .{ .key = key, .value = try gen.scalar() } };
    if (trace) std.debug.print("{t} {d}: {s}\n", .{ format, seed, key });
    const edited = try edit.apply(arena, format, doc, change) orelse return false;
    // `apply` checks this itself; the test holds it to the contract independently.
    switch (change) {
        .set => |set| try tree.put(arena, set.key, set.value),
        .unset => |k| try testing.expect(tree.remove(k)),
    }
    const expected_text = try writeAlloc(arena, format, tree);
    const expected = try format.parse(arena, expected_text, null);
    const actual = format.parse(arena, edited, null) catch |err| {
        report(format, seed, "the edited document does not parse", edited);
        return err;
    };
    if (!sameValue(actual, expected)) {
        report(format, seed, "the edited document reads back differently", edited);
        return error.TestUnexpectedResult;
    }
    return true;
}

test "in-place edits decline or are right" {
    for ([_]Format{ .toml, .dotenv, .yaml, .zon, .json, .jsonc, .ini }) |format| {
        const base: u64 = 0x3d17_0000 + @as(u64, @backingInt(format)) * 0x1_0000;
        var made: usize = 0;
        for (0..1500) |i| {
            const seed = base + i;
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const docs = corpus(format);
            const sample = docs[random.uintLessThan(usize, docs.len)];
            const doc = switch (random.uintLessThan(u8, 3)) {
                0 => sample,
                1 => try mutate(random, a, sample),
                else => blk: {
                    var gen: Gen = .{ .random = random, .arena = a, .rules = .of(.toml) };
                    const tree = if (format == .dotenv) try dotenvTree(&gen, 0) else try gen.tree();
                    break :blk writeAlloc(a, format, tree) catch continue;
                },
            };
            if (try expectEdit(format, doc, random, seed)) made += 1;
        }
        // Most edits are possible in place; a regression to "always decline" must fail.
        // Most edits are possible in place (some documents do not parse, or hold no table
        // to edit); a regression to "always decline" must fail.
        try testing.expect(made > 400);
    }
}

test "changing a scalar of a written TOML document is done in place" {
    for (0..500) |i| {
        const seed = 0x3d18_0000 + i;
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var gen: Gen = .{ .random = random, .arena = arena, .rules = .of(.toml) };
        const doc = try writeAlloc(arena, .toml, try gen.tree());
        const tree = try toml.parse(arena, doc, null);
        var leaves: std.ArrayList([]const u8) = .empty;
        try tree.leafPaths(arena, "", &leaves);
        for (leaves.items) |key| {
            // An empty table may be a `[header]`, and an array of tables is `[[header]]`
            // sections: neither is one value to replace.
            const old = tree.lookup(key).?;
            if (old == .table) continue;
            if (old == .array and old.array.items.len > 0 and old.array.items[0] == .table) {
                continue;
            }
            const change: edit.Change = .{ .set = .{ .key = key, .value = .{ .int = 7 } } };
            if (try edit.apply(arena, .toml, doc, change) == null) {
                report(.toml, seed, key, doc);
                return error.TestExpectedEdit;
            }
        }
    }
}

test "the corpus parses" {
    for (formats) |format| {
        for (corpus(format)) |doc| {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var diag: Diagnostic = .{};
            _ = format.parse(arena.allocator(), doc, &diag) catch |err| {
                std.debug.print("{t}: {f}\n", .{ format, diag });
                return err;
            };
            try expectRobust(format, doc, 0);
        }
    }
}

test "allocation failure is error.OutOfMemory at every point" {
    for (formats) |format| {
        for (corpus(format)) |doc| {
            var fail_index: usize = 0;
            while (true) : (fail_index += 1) {
                var arena: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena.deinit();
                var failing: std.testing.FailingAllocator = .init(arena.allocator(), .{
                    .fail_index = fail_index,
                });
                const result = format.parse(failing.allocator(), doc, null);
                if (result) |_| {
                    try testing.expect(!failing.has_induced_failure);
                    break;
                } else |err| try testing.expectEqual(error.OutOfMemory, err);
            }
        }
    }
}

/// `count` copies of `unit` between `prefix` and `suffix`, in `gpa`.
fn repeat(
    gpa: Allocator,
    prefix: []const u8,
    unit: []const u8,
    count: usize,
    suffix: []const u8,
) ![]u8 {
    const out = try gpa.alloc(u8, prefix.len + unit.len * count + suffix.len);
    @memcpy(out[0..prefix.len], prefix);
    for (0..count) |i| @memcpy(out[prefix.len + i * unit.len ..][0..unit.len], unit);
    @memcpy(out[out.len - suffix.len ..], suffix);
    return out;
}

fn expectTooDeep(format: Format, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, format.parse(arena.allocator(), input, &diag));
    try testing.expect(diag.message.len > 0);
}

test "deep nesting is an error, not a stack overflow" {
    const gpa = testing.allocator;
    const n = 10_000;
    const Case = struct { Format, []const u8, []const u8, []const u8 };
    const cases = [_]Case{
        .{ .json, "", "[", "" },
        .{ .json, "", "{\"a\":", "" },
        .{ .toml, "a = ", "[", "" },
        .{ .toml, "a = ", "{b = ", "" },
        .{ .toml, "", "a.", "b = 1\n" },
        .{ .toml, "[", "a.", "b]\n" },
        .{ .toml, "", "[[a]]\n", "" }, // Not deep: arrays of tables append, so this parses.
        .{ .yaml, "", "[", "" },
        .{ .yaml, "", "{a: ", "" },
        .{ .yaml, "", "- ", "x\n" },
        .{ .yaml, "a: ", "[", "" },
        .{ .dotenv, "A=", "${A:-", "" },
        .{ .zon, "", ".{", "" },
        .{ .zon, "", ".{ .a = ", "" },
        .{ .zon, "", "(", "1" },
        .{ .zon, "", "-", "1" },
        .{ .zon, "", "!", "true" },
        .{ .zon, "", "if (true) ", "1" },
        .{ .zon, "", "[", "" },
    };
    for (cases) |case| {
        const input = try repeat(gpa, case[1], case[2], n, case[3]);
        defer gpa.free(input);
        if (std.mem.eql(u8, case[2], "[[a]]\n")) {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const v = try toml.parse(arena.allocator(), input, null);
            try testing.expectEqual(n, v.table.get("a").?.array.items.len);
            continue;
        }
        try expectTooDeep(case[0], input);
    }

    // Block mappings, one more space of indentation per level.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    for (0..1000) |level| {
        @memset(try deep.addManyAsSlice(gpa, level), ' ');
        try deep.appendSlice(gpa, "k:\n");
    }
    try expectTooDeep(.yaml, deep.items);
}

test "nesting just inside the bound parses" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json_doc = try repeat(gpa, "", "[", json.max_depth, "");
    defer gpa.free(json_doc);
    const json_closed = try std.mem.concat(gpa, u8, &.{ json_doc, json_doc });
    defer gpa.free(json_closed);
    std.mem.replaceScalar(u8, json_closed[json_doc.len..], '[', ']');
    _ = try json.parse(a, json_closed, null);
    const yaml_doc = try repeat(gpa, "", "- ", yaml.max_depth - 1, "x\n");
    defer gpa.free(yaml_doc);
    _ = try yaml.parse(a, yaml_doc, null);
    const zon_open = try repeat(gpa, "", ".{ .a = ", zon.max_depth, "-1");
    defer gpa.free(zon_open);
    const zon_close = try repeat(gpa, zon_open, " }", zon.max_depth, "");
    defer gpa.free(zon_close);
    const zon_value = try zon.parse(a, zon_close, null);
    var zon_path: std.ArrayList(u8) = .empty;
    defer zon_path.deinit(gpa);
    for (0..zon.max_depth - 1) |_| try zon_path.appendSlice(gpa, "a.");
    try zon_path.append(gpa, 'a');
    try testing.expectEqual(-1, zon_value.lookup(zon_path.items).?.int);
}

test "YAML with aliases on: mutated documents parse or fail cleanly, within the budget" {
    const base =
        \\a: &a [1, {k: &k v}]
        \\b: *a
        \\c: [*k, &c x, *c]
        \\d: &d
        \\  e: *a
        \\f: *d
        \\
    ;
    for (0..1500) |i| {
        const seed = 0xa11a_0000 + i;
        var prng: std.Random.DefaultPrng = .init(seed);
        const input = try mutate(prng.random(), testing.allocator, base);
        defer testing.allocator.free(input);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var diag: Diagnostic = .{};
        _ = yaml.parseWith(arena.allocator(), input, &diag, .{ .aliases = true }) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (diag.message.len == 0 or diag.line == 0) {
                report(.yaml, seed, "diagnostic", input);
                return error.TestUnexpectedResult;
            }
        };
    }
}

/// Reformats `doc` twice and checks the second pass changes nothing. Returns whether `doc`
/// could be reformatted at all.
fn expectReformat(arena: Allocator, format: Format, doc: []const u8, seed: u64) !bool {
    const once = try edit.reformat(arena, format, doc) orelse return false;
    const twice = try edit.reformat(arena, format, once) orelse {
        report(format, seed, "formatted output does not format", once);
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, once, twice)) {
        report(format, seed, "formatting is not idempotent", doc);
        std.debug.print("once:\n{s}\ntwice:\n{s}\n", .{ once, twice });
        return error.TestUnexpectedResult;
    }
    return true;
}

test "reformatting is idempotent, and declines or reads back the same" {
    for ([_]Format{ .toml, .zon, .dotenv, .yaml }) |format| {
        const base: u64 = 0xf0f0_0000 + @as(u64, @backingInt(format)) * 0x1_0000;
        var made: usize = 0;
        for (0..600) |i| {
            const seed = base + i;
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            const docs = corpus(format);
            const sample = docs[random.uintLessThan(usize, docs.len)];
            const doc = switch (random.uintLessThan(u8, 3)) {
                0 => sample,
                1 => try mutate(random, a, sample),
                else => blk: {
                    var gen: Gen = .{ .random = random, .arena = a, .rules = .of(.toml) };
                    const tree = if (format == .dotenv) try dotenvTree(&gen, 0) else try gen.tree();
                    break :blk writeAlloc(a, format, tree) catch continue;
                },
            };
            if (try expectReformat(a, format, doc, seed)) made += 1;
        }
        // YAML's corpus holds block scalars and flow collections over several lines, which
        // reformatting declines.
        try testing.expect(made > @as(usize, if (format == .yaml) 100 else 150));
    }
}

/// `yaml.parseReader`, which parses a piece at a time through a small buffer, agrees with
/// `yaml.parse`: the same tree, or both fail.
fn expectYamlStream(arena: Allocator, doc: []const u8, seed: u64) !void {
    const whole = yaml.parse(arena, doc, null);
    var source: std.Io.Reader = .fixed(doc);
    var small: [7]u8 = undefined;
    var limited = source.limited(.unlimited, &small);
    const streamed = yaml.parseReader(arena, testing.allocator, &limited.interface, 1 << 20, null);
    if (whole) |tree| {
        const got = streamed catch |err| {
            report(.yaml, seed, "parseReader failed where parse did not", doc);
            return err;
        };
        if (!sameValue(tree, got)) {
            report(.yaml, seed, "parseReader read differently from parse", doc);
            return error.TestUnexpectedResult;
        }
    } else |_| {
        if (streamed) |_| {
            report(.yaml, seed, "parseReader accepted what parse rejects", doc);
            return error.TestUnexpectedResult;
        } else |err| if (err == error.OutOfMemory) return err;
    }
}

test "YAML read a piece at a time reads as YAML read whole" {
    for (0..1500) |i| {
        const seed = 0x57e0_0000 + i;
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const docs = corpus(.yaml);
        const sample = docs[random.uintLessThan(usize, docs.len)];
        const doc = switch (random.uintLessThan(u8, 3)) {
            0 => sample,
            1 => try mutate(random, a, sample),
            else => blk: {
                var gen: Gen = .{ .random = random, .arena = a, .rules = .of(.yaml) };
                break :blk writeAlloc(a, .yaml, try gen.tree()) catch continue;
            },
        };
        try expectYamlStream(a, doc, seed);
    }
}

fn fuzzYamlStream(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const doc = buffer[0..smith.slice(&buffer)];
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try expectYamlStream(arena_state.allocator(), doc, 0);
}

test "fuzz: yaml read a piece at a time" {
    try testing.fuzz({}, fuzzYamlStream, .{ .corpus = fuzzInputs(.yaml) });
}

/// Inputs the fuzzer once broke a parser with, replayed by every test run.
fn regressions(format: Format) []const []const u8 {
    return switch (format) {
        // A key ending in `_` holding a table was written as a name that read back as
        // another path, clashing with its neighbour.
        .dotenv => &.{"_=\n__.__=\n_=\n"},
        // Reformatting wrote `- -4`, then took the `-` of `-4` for an indicator; and it
        // could not find the end of a key quoted with escapes; and reading a piece at a
        // time cut before `\x9d:\x0c`, which is not a key; and it took a first piece that
        // was a block scalar for the whole document, then added keys to it; and
        // reformatting took the `#` in a key for a comment, so declined what it wrote; and
        // reading a piece at a time took a piece for a document, so a `...` ended only
        // that piece and a byte order mark starting it was dropped, and a first piece whose
        // root was a flow mapping or indented was followed by keys at the first column.
        .yaml => &.{
            "counts: [3, -4]\n",
            "\"\x19counts\":\n  - 3\n",
            "b:\x0c\n\x9d:\x0c",
            " |+\nxs: [a]\nlist:\n- 1\n",
            "c#\xcb\xf4ounts: [3, -4]\n",
            "a: 1\n...\nb: 2\n",
            "a: 1\n\xef\xbb\xbfb: 2\n",
            "{a: 1,\nb: 2}\nc: 3\n",
            "# c\n  a: 'x\nb: y'\nc: 1\n",
        },
        else => &.{},
    };
}

/// `corpus`, `regressions`, and `decodeCorpus` as fuzzer inputs: each a 4-byte little-endian
/// length, then the bytes, which is how `std.testing.Smith.slice` reads them.
fn fuzzInputs(comptime format: Format) []const []const u8 {
    return comptime blk: {
        var inputs: []const []const u8 = &.{};
        for (corpus(format) ++ regressions(format) ++ decodeCorpus(format)) |doc| {
            const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, doc.len));
            const input = len ++ doc[0..doc.len].*;
            inputs = inputs ++ .{&input};
        }
        break :blk inputs;
    };
}

fn fuzzParser(format: Format, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);
    try expectRobust(format, buffer[0..len], 0);
}

test "fuzz: json" {
    try testing.fuzz(Format.json, fuzzParser, .{ .corpus = fuzzInputs(.json) });
}

test "fuzz: toml" {
    try testing.fuzz(Format.toml, fuzzParser, .{ .corpus = fuzzInputs(.toml) });
}

test "fuzz: yaml" {
    try testing.fuzz(Format.yaml, fuzzParser, .{ .corpus = fuzzInputs(.yaml) });
}

test "fuzz: zon" {
    try testing.fuzz(Format.zon, fuzzParser, .{ .corpus = fuzzInputs(.zon) });
}

test "fuzz: dotenv" {
    try testing.fuzz(Format.dotenv, fuzzParser, .{ .corpus = fuzzInputs(.dotenv) });
}

test "fuzz: ini" {
    try testing.fuzz(Format.ini, fuzzParser, .{ .corpus = fuzzInputs(.ini) });
}

/// A struct with a field of every kind `decode` handles, for the decode property.
const Sample = struct {
    name: []const u8 = "",
    port: u16 = 8080,
    small: i8 = 0,
    ratio: f64 = 0,
    on: bool = false,
    level: enum { debug, info, warn } = .info,
    maybe: ?u32 = null,
    tags: []const []const u8 = &.{},
    counts: []const i64 = &.{},
    timeout: scalar.Duration = .zero,
    size: scalar.ByteSize = .{ .bytes = 0 },
    when: ?scalar.DateTime = null,
    inner: struct { a: u8 = 0, b: ?[]const u8 = null, any: ?Value = null } = .{},
    store: union(enum) { disk: struct { path: []const u8 = "" }, memory } = .memory,
};

/// `Sample` with checks, a renamed key, an old key, and a list that appends.
const sample_settings = settings_.settings(Sample, field.Set(.{field.Spec(Sample){ .fields = .{
    .port = .{ .checks = &.{.min(1)} },
    .counts = .{ .each = &.{.max(1000)} },
} }}), .{ .fields = .{
    .name = .{ .key = "service-name" },
    .level = .{ .renamed_from = "log_level" },
    .counts = .{ .merge = .append },
} });

/// Decodes `doc`, parsed as `format`, as a `Sample`: decoding succeeds or fails with a
/// diagnostic, and a decoded value encodes and decodes back to the same tree. Returns
/// whether `doc` decoded.
fn expectDecode(arena: Allocator, format: Format, doc: []const u8, strict: bool, seed: u64) !bool {
    const tree = format.parse(arena, doc, null) catch |err| switch (err) {
        error.SyntaxError => return false,
        else => return err,
    };
    var errors: std.ArrayList(Diagnostic) = .empty;
    var diag: Diagnostic = .{};
    const options: decoding.Options = .{
        .strict = strict,
        .errors = if (seed & 1 == 0) &errors else null,
    };
    const decoded = decoding.decode(
        sample_settings,
        arena,
        tree,
        options,
        &diag,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            if (diag.message.len == 0) {
                report(format, seed, "decoding failed without a diagnostic", doc);
                return error.TestUnexpectedResult;
            }
            return false;
        },
    };
    const encoded = decoding.encodeAs(sample_settings, arena, decoded) catch |err| switch (err) {
        // A float that is not finite has no representation in some formats' trees.
        error.Unrepresentable => return true,
        else => return err,
    };
    const again = decoding.decode(
        sample_settings,
        arena,
        encoded,
        .{ .strict = true },
        &diag,
    ) catch |err| {
        report(format, seed, "an encoded value does not decode", doc);
        std.debug.print("{s}\n", .{diag.message});
        return err;
    };
    const reencoded = try decoding.encodeAs(sample_settings, arena, again);
    if (!sameValue(encoded, reencoded)) {
        report(format, seed, "a decoded value does not encode back the same", doc);
        return error.TestUnexpectedResult;
    }
    return true;
}

test "parsed trees decode or fail with a diagnostic, and decoded values round-trip" {
    inline for (formats) |format| {
        const base: u64 = 0xdec0_0000 + @as(u64, @backingInt(format)) * 0x1_0000;
        var decoded: usize = 0;
        for (0..400) |i| {
            const seed = base + i;
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            const docs = comptime corpus(format) ++ decodeCorpus(format);
            const sample = docs[random.uintLessThan(usize, docs.len)];
            const doc = if (random.boolean()) sample else try mutate(random, a, sample);
            if (try expectDecode(a, format, doc, random.boolean(), seed)) decoded += 1;
        }
        try testing.expect(decoded > 40);
    }
}

test "the decode corpus decodes" {
    inline for (formats) |format| {
        for (decodeCorpus(format)) |doc| {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            var diag: Diagnostic = .{};
            const tree = try format.parse(a, doc, &diag);
            _ = decoding.decode(sample_settings, a, tree, .{ .strict = true }, &diag) catch |err| {
                std.debug.print("{t}: {s}: {s}\n", .{ format, diag.key, diag.message });
                return err;
            };
        }
    }
}

/// Documents shaped like `Sample`, so that mutations reach past the first field.
fn decodeCorpus(format: Format) []const []const u8 {
    return switch (format) {
        .json, .jsonc => &.{
            \\{"service-name": "api", "port": "8081", "small": -3, "ratio": 0.5,
            \\ "on": "yes", "log_level": "warn", "maybe": 7, "tags": "a,b",
            \\ "counts": [1, 2], "timeout": "1m30s", "size": "2kb",
            \\ "when": "2024-05-01T10:00:00Z", "inner": {"a": 3, "b": "x", "any": [1]}}
            ,
        },
        .toml => &.{
            \\service-name = "api"
            \\port = 8081
            \\ratio = 1e3
            \\level = "debug"
            \\tags = ["a", "b"]
            \\timeout = "250ms"
            \\when = 2024-05-01
            \\[inner]
            \\a = 255
            \\b = "y"
            ,
        },
        .yaml => &.{
            \\service-name: api
            \\port: 8081
            \\on: true
            \\counts: [3, -4]
            \\size: 1mb
            \\inner:
            \\  a: 1
            \\  any: {k: v}
            ,
        },
        .zon => &.{
            \\.{ .@"service-name" = "api", .port = 8081, .small = 127, .level = .info,
            \\   .tags = .{ "a" }, .inner = .{ .a = 2 } }
            ,
        },
        .dotenv => &.{
            \\SERVICE_NAME=api
            \\PORT=8081
            \\ON=1
            \\TAGS=a,b
            \\TIMEOUT=5s
            \\INNER__A=9
            ,
        },
        .ini => &.{
            \\service-name = api
            \\port = 8081
            \\[inner]
            \\a = 4
            ,
        },
    };
}

fn fuzzEdit(format: Format, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const doc = buffer[0..smith.slice(&buffer)];
    const seed = smith.value(u64);
    var prng: std.Random.DefaultPrng = .init(seed);
    _ = try expectEdit(format, doc, prng.random(), seed);
}

fn fuzzReformat(format: Format, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const doc = buffer[0..smith.slice(&buffer)];
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    _ = try expectReformat(arena_state.allocator(), format, doc, 0);
}

fn fuzzDecode(format: Format, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const doc = buffer[0..smith.slice(&buffer)];
    const seed = smith.value(u64);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    _ = try expectDecode(arena_state.allocator(), format, doc, seed & 2 != 0, seed);
}

test "fuzz: edit toml" {
    try testing.fuzz(Format.toml, fuzzEdit, .{ .corpus = fuzzInputs(.toml) });
}

test "fuzz: edit yaml" {
    try testing.fuzz(Format.yaml, fuzzEdit, .{ .corpus = fuzzInputs(.yaml) });
}

test "fuzz: edit zon" {
    try testing.fuzz(Format.zon, fuzzEdit, .{ .corpus = fuzzInputs(.zon) });
}

test "fuzz: edit dotenv" {
    try testing.fuzz(Format.dotenv, fuzzEdit, .{ .corpus = fuzzInputs(.dotenv) });
}

test "fuzz: reformat toml" {
    try testing.fuzz(Format.toml, fuzzReformat, .{ .corpus = fuzzInputs(.toml) });
}

test "fuzz: reformat zon" {
    try testing.fuzz(Format.zon, fuzzReformat, .{ .corpus = fuzzInputs(.zon) });
}

test "fuzz: reformat yaml" {
    try testing.fuzz(Format.yaml, fuzzReformat, .{ .corpus = fuzzInputs(.yaml) });
}

test "fuzz: reformat dotenv" {
    try testing.fuzz(Format.dotenv, fuzzReformat, .{ .corpus = fuzzInputs(.dotenv) });
}

test "fuzz: decode json" {
    try testing.fuzz(Format.json, fuzzDecode, .{ .corpus = fuzzInputs(.json) });
}

test "fuzz: decode yaml" {
    try testing.fuzz(Format.yaml, fuzzDecode, .{ .corpus = fuzzInputs(.yaml) });
}

test "fuzz: decode toml" {
    try testing.fuzz(Format.toml, fuzzDecode, .{ .corpus = fuzzInputs(.toml) });
}

/// Fails unless every leaf of `doc` (when it parses) is found by `locate`: exactly, unless
/// it is inside a list or an inline table (whose entries are not spans of their own in
/// every format), and then at the start of that list or table.
fn expectLocated(arena: Allocator, format: Format, doc: []const u8, seed: u64) !usize {
    const tree = format.parse(arena, doc, null) catch return 0;
    var leaves: std.ArrayList([]const u8) = .empty;
    try tree.leafPaths(arena, "", &leaves);
    for (leaves.items) |key| {
        const at = try locate.locate(arena, format, doc, key) orelse {
            report(format, seed, key, doc);
            return error.TestKeyNotLocated;
        };
        const segments = try path.split(arena, key);
        const in_list = for (segments) |segment| {
            if (segment.len > 0 and std.ascii.isDigit(segment[0])) {
                if (std.fmt.parseInt(usize, segment, 10)) |_| break true else |_| {}
            }
        } else false;
        if (at.exact) continue;
        const inline_start = at.offset < doc.len and
            std.mem.indexOfScalar(u8, ".{[", doc[at.offset]) != null;
        if (!in_list and !inline_start) {
            report(format, seed, key, doc);
            return error.TestKeyNotLocatedExactly;
        }
    }
    return leaves.items.len;
}

test "every key of a document is located" {
    for (formats) |format| {
        const base: u64 = 0x10c4_0000 + @as(u64, @backingInt(format)) * 0x1_0000;
        var located: usize = 0;
        for (0..600) |i| {
            const seed = base + i;
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const docs = corpus(format);
            const sample = docs[random.uintLessThan(usize, docs.len)];
            const doc = switch (random.uintLessThan(u8, 3)) {
                0 => sample,
                1 => try mutate(random, a, sample),
                else => blk: {
                    var gen: Gen = .{ .random = random, .arena = a, .rules = .of(.toml) };
                    const tree = if (format == .dotenv) try dotenvTree(&gen, 0) else try gen.tree();
                    break :blk writeAlloc(a, format, tree) catch continue;
                },
            };
            located += try expectLocated(a, format, doc, seed);
        }
        try testing.expect(located > 300);
    }
}

// Encrypted envelopes.

/// What the envelopes these tests start from seal, and under what passphrase.
const envelope_plaintext = "token = \"s3cret\"\n";
const envelope_passphrase = "correct horse";

fn sealedEnvelope(arena: Allocator) ![]const u8 {
    const cheap: encrypted.Params = .{ .t = 1, .m = 64, .p = 1 };
    const plaintext = envelope_plaintext;
    return encrypted.encrypt(arena, testing.io, plaintext, envelope_passphrase, .toml, cheap);
}

/// Fails unless `text` opens to what was sealed or fails with an error: a changed envelope
/// never opens to something else. Whether it opened. Argon2 costs what the header says, so
/// an envelope asking more than a test should spend is not opened.
fn expectEnvelope(text: []const u8) !bool {
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (encrypted.parseHeader(std.mem.trimEnd(u8, line, "\r"))) |header| {
        const costs = header.params;
        if (costs.t > 2 or costs.m > 256 or costs.p > 4) return false;
    } else |_| {}
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const opened = encrypted.decrypt(a, testing.io, text, envelope_passphrase) catch |err| {
        return if (err == error.OutOfMemory) err else false;
    };
    try testing.expectEqualStrings(envelope_plaintext, opened.plaintext);
    return true;
}

test "changed envelopes fail, and never open to something else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const sealed = try sealedEnvelope(arena_state.allocator());
    try testing.expect(try expectEnvelope(sealed));
    for (0..300) |i| {
        const seed = 0xe7c0_0000 + i;
        var prng: std.Random.DefaultPrng = .init(seed);
        const doc = try mutate(prng.random(), testing.allocator, sealed);
        defer testing.allocator.free(doc);
        _ = expectEnvelope(doc) catch |err| {
            report(.toml, seed, "envelope", doc);
            return err;
        };
    }
}

fn fuzzEnvelope(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    _ = try expectEnvelope(buffer[0..smith.slice(&buffer)]);
}

test "fuzz: encrypted envelopes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // As `fuzzInputs` lays them out, but made at run time: a salt and a nonce are random.
    const sealed = try sealedEnvelope(a);
    const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, @intCast(sealed.len)));
    const input = try std.mem.concat(a, u8, &.{ &len, sealed });
    try testing.fuzz({}, fuzzEnvelope, .{ .corpus = &.{input} });
}
