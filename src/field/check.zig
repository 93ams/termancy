//! Checks on a value: plain functions, plus built-in ones that also describe themselves for
//! help, documentation, schemas, and completion.

const std = @import("std");
const name = @import("name.zig");

/// What a check returns: `error.Invalid` after writing why to its writer.
pub const Error = error{Invalid} || std.Io.Writer.Error;

/// Writes why a value is invalid and returns `error.Invalid`: `template` with `{0}`, `{1}`,
/// ... replaced by `args` (strings, numbers, or anything with a `format` method), as
/// `ctx.tr` takes them: `return field.fail(w, "{0} is in use", .{port});`. To a `Reason`'s
/// writer it also gives the template and the arguments, so a surface can translate the
/// template and fill the arguments in.
pub fn fail(w: *std.Io.Writer, comptime template: []const u8, args: anytype) Error {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_names;
    comptime checkTemplate(template, fields.len);
    var bytes: [arg_bytes]u8 = undefined;
    var texts: std.Io.Writer = .fixed(&bytes);
    var ends: [fields.len]usize = undefined;
    inline for (fields, 0..) |field_name, i| {
        writeArg(&texts, @field(args, field_name));
        ends[i] = texts.end;
    }
    var slices: [fields.len][]const u8 = undefined;
    for (&slices, ends, 0..) |*slice, end, i| slice.* = bytes[if (i == 0) 0 else ends[i - 1]..end];
    if (Reason.of(w)) |reason| reason.keep(template, &slices);
    try render(w, template, &slices);
    return error.Invalid;
}

/// The most arguments `fail` takes.
pub const max_args = 8;
/// Room for `fail`'s arguments as text; past it they are cut short.
const arg_bytes = 256;

fn checkTemplate(comptime template: []const u8, comptime count: usize) void {
    if (count > max_args) @compileError("field.fail takes at most 8 arguments");
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] != '{') continue;
        if (i + 1 < template.len and template[i + 1] == '{') {
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse
            @compileError("field.fail: an unclosed { in \"" ++ template ++ "\"");
        const index = std.fmt.parseUnsigned(usize, template[i + 1 .. close], 10) catch
            @compileError("field.fail: arguments are {0}, {1}, ...; found \"" ++
                template[i .. close + 1] ++ "\" in \"" ++ template ++ "\"");
        if (index >= count) @compileError("field.fail: \"" ++ template ++ "\" names {" ++
            template[i + 1 .. close] ++ "}, past its arguments");
        i = close;
    }
}

/// Writes one argument as text: a string as it is, a number in decimal, anything else with
/// its `format` method. One that does not fit is cut short.
fn writeArg(w: *std.Io.Writer, arg: anytype) void {
    const T = @TypeOf(arg);
    (if (comptime isString(T))
        w.writeAll(arg)
    else switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => w.print("{d}", .{arg}),
        else => w.print("{f}", .{arg}),
    }) catch {};
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Writes `template` with `{n}` replaced by `args[n]`, and `{{` as `{`; a reference past
/// the end of `args` is written as it is.
pub fn render(w: *std.Io.Writer, template: []const u8, args: []const []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{' and i + 1 < template.len and template[i + 1] == '{') {
            try w.writeByte('{');
            i += 2;
            continue;
        }
        if (c == '{') {
            const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse {
                try w.writeAll(template[i..]);
                return;
            };
            const index = std.fmt.parseUnsigned(usize, template[i + 1 .. close], 10) catch null;
            if (index != null and index.? < args.len) {
                try w.writeAll(args[index.?]);
            } else {
                try w.writeAll(template[i .. close + 1]);
            }
            i = close + 1;
            continue;
        }
        try w.writeByte(c);
        i += 1;
    }
}

/// Where a surface has a check write its reason: a fixed buffer, as `std.Io.Writer.fixed`,
/// that also keeps what `fail` was given, the template and its arguments, for translating
/// the template rather than the text. Pass `&reason.writer` to the check, and do not move
/// the `Reason` while it is in use.
pub const Reason = struct {
    writer: std.Io.Writer,
    /// `fail`'s template; null when the check wrote its reason another way.
    template: ?[]const u8 = null,
    arg_count: usize = 0,
    arg_ends: [max_args]usize = undefined,
    arg_text: [arg_bytes]u8 = undefined,

    pub fn init(buffer: []u8) Reason {
        return .{ .writer = .{ .vtable = &vtable, .buffer = buffer } };
    }

    /// The reason in English, as the check wrote it.
    pub fn text(r: *const Reason) []const u8 {
        return r.writer.buffered();
    }

    /// `fail`'s arguments as text, for the template's `{0}`, `{1}`, ...: in `out`.
    pub fn args(r: *const Reason, out: *[max_args][]const u8) []const []const u8 {
        for (out[0..r.arg_count], 0..) |*slice, i| {
            slice.* = r.arg_text[if (i == 0) 0 else r.arg_ends[i - 1]..r.arg_ends[i]];
        }
        return out[0..r.arg_count];
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = std.Io.Writer.fixedDrain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn of(w: *std.Io.Writer) ?*Reason {
        if (w.vtable != &vtable) return null;
        return @fieldParentPtr("writer", w);
    }

    fn keep(r: *Reason, template: []const u8, texts: []const []const u8) void {
        r.template = template;
        var end: usize = 0;
        for (texts, 0..) |t, i| {
            const n = @min(t.len, r.arg_text.len - end);
            @memcpy(r.arg_text[end..][0..n], t[0..n]);
            end += n;
            r.arg_ends[i] = end;
        }
        r.arg_count = texts.len;
    }
};

/// A bound as help shows it, and as a number for schemas when it is one.
pub const Bound = struct {
    number: ?f64 = null,
    text: []const u8,
};

/// What a built-in check is, for help, documentation, schemas, completion, and for a
/// surface to word the failure itself (in the user's language, say).
pub const About = union(enum) {
    min: Bound,
    max: Bound,
    min_len: usize,
    max_len: usize,
    one_of: []const []const u8,
    glob: []const u8,
};

/// A check on a value of type `V`. Built with the declarations below, usually as decl
/// literals: `.checks = &.{ .min(1), .from(notReserved) }`.
pub fn Check(comptime V: type) type {
    return struct {
        run: *const fn (V, *std.Io.Writer) Error!void,
        /// Set for the built-in checks; null for a function given to `from`.
        about: ?About = null,

        const Self = @This();

        /// A check of your own: `fn (V, *std.Io.Writer) !void` that writes why the value
        /// is invalid and returns `error.Invalid` (or `field.fail`).
        pub fn from(comptime f: anytype) Self {
            const F = @TypeOf(f);
            const info = @typeInfo(F);
            if (info != .@"fn") @compileError(".from needs a function, found " ++ @typeName(F));
            const params = info.@"fn".param_types;
            if (params.len != 2 or params[1] != *std.Io.Writer) {
                @compileError(".from needs fn (" ++ @typeName(V) ++
                    ", *std.Io.Writer) !void, found a function with other parameters");
            }
            if (params[0] != V) {
                @compileError(".from on a " ++ @typeName(V) ++ " needs a function taking " ++
                    @typeName(V) ++ ", not " ++ @typeName(params[0].?));
            }
            return .{ .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    return f(v, w);
                }
            }.run };
        }

        /// At least `n`: a number, or a type with `order(a, b) std.math.Order`.
        pub fn min(comptime n: NumberOrOrdered(V)) Self {
            return .{ .about = .{ .min = bound(n) }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (less(v, n)) return fail(w, "must be at least {0}", .{comptime bound(n).text});
                }
            }.run };
        }

        /// At most `n`: a number, or a type with `order(a, b) std.math.Order`.
        pub fn max(comptime n: NumberOrOrdered(V)) Self {
            return .{ .about = .{ .max = bound(n) }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (less(n, v)) return fail(w, "must be at most {0}", .{comptime bound(n).text});
                }
            }.run };
        }

        /// At least `n` long: characters for a string, elements for a list.
        pub fn minLen(comptime n: usize) Self {
            comptime sized();
            return .{ .about = .{ .min_len = n }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (length(v) < n) return fail(w, "must be at least {0} long", .{n});
                }
            }.run };
        }

        /// At most `n` long: characters for a string, elements for a list.
        pub fn maxLen(comptime n: usize) Self {
            comptime sized();
            return .{ .about = .{ .max_len = n }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (length(v) > n) return fail(w, "must be at most {0} long", .{n});
                }
            }.run };
        }

        /// One of `choices`, for a string; an enum gives its choices by itself.
        pub fn oneOf(comptime choices: []const []const u8) Self {
            if (V != []const u8) @compileError(".oneOf needs a string, found " ++ @typeName(V) ++
                "; an enum gives choices by itself");
            return .{ .about = .{ .one_of = choices }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    for (choices) |c| if (std.mem.eql(u8, c, v)) return;
                    const all = comptime name.join(choices, ", ");
                    if (name.suggest(v, choices)) |close| {
                        return fail(w, "must be one of {0} (did you mean {1}?)", .{ all, close });
                    }
                    return fail(w, "must be one of {0}", .{all});
                }
            }.run };
        }

        /// Matching `pattern`, for a string: `*` matches any run of bytes, `?` one byte.
        pub fn glob(comptime pattern: []const u8) Self {
            if (V != []const u8) @compileError(".glob needs a string, found " ++ @typeName(V));
            return .{ .about = .{ .glob = pattern }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (!matches(pattern, v)) return fail(w, "must match {0}", .{pattern});
                }
            }.run };
        }

        fn sized() void {
            const list = @typeInfo(V) == .pointer and @typeInfo(V).pointer.size == .slice;
            if (!list) @compileError(".minLen and .maxLen need a string or a list, found " ++
                @typeName(V));
        }

        fn less(a: V, b: V) bool {
            if (@typeInfo(V) == .int) return a < b;
            // Not `a < b`: NaN must fail both `.min` and `.max`.
            if (@typeInfo(V) == .float) return !(a >= b);
            return V.order(a, b) == .lt;
        }

        fn length(v: V) usize {
            if (V == []const u8) return std.unicode.utf8CountCodepoints(v) catch v.len;
            return v.len;
        }
    };
}

/// `V` when `.min` and `.max` can bound it: a number, or a type with
/// `order(a, b) std.math.Order`. Otherwise a type no bound converts to, whose name says
/// why at the bound itself: `expected type 'MinMaxNeedANumberOrOrder([]const u8)'`.
fn NumberOrOrdered(comptime V: type) type {
    const numeric = @typeInfo(V) == .int or @typeInfo(V) == .float;
    if (numeric or (@typeInfo(V) == .@"struct" and @hasDecl(V, "order"))) return V;
    return MinMaxNeedANumberOrOrder(V);
}

fn MinMaxNeedANumberOrOrder(comptime V: type) type {
    return struct {
        comptime {
            _ = V;
        }
    };
}

fn bound(comptime n: anytype) Bound {
    return switch (@typeInfo(@TypeOf(n))) {
        .int, .comptime_int => .{
            .number = @floatFromInt(n),
            .text = std.fmt.comptimePrint("{d}", .{n}),
        },
        .float, .comptime_float => .{
            .number = @floatCast(n),
            .text = std.fmt.comptimePrint("{d}", .{n}),
        },
        else => .{ .text = std.fmt.comptimePrint("{f}", .{n}) },
    };
}

/// Whether `text` matches `pattern`, where `*` matches any run of bytes and `?` one byte.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    // Where to resume after a mismatch: the last `*` and the text position it covers to.
    var star: ?usize = null;
    var star_text: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_text = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_text += 1;
            t = star_text;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const testing = std.testing;

fn runs(comptime V: type, check: Check(V), value: V) ![]const u8 {
    const State = struct {
        var buffer: [128]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&State.buffer);
    check.run(value, &w) catch |err| switch (err) {
        error.Invalid => return w.buffered(),
        else => return err,
    };
    return "";
}

test "built-in checks pass, fail with a reason, and describe themselves" {
    try testing.expectEqualStrings("", try runs(u16, .min(1), 1));
    try testing.expectEqualStrings("must be at least 1", try runs(u16, .min(1), 0));
    try testing.expectEqualStrings("must be at most 64", try runs(u8, .max(64), 65));
    try testing.expectEqualStrings(
        "must be at least 3 long",
        try runs([]const u8, .minLen(3), "né"),
    );
    try testing.expectEqualStrings(
        "must be at most 1 long",
        try runs([]const u32, .maxLen(1), &.{ 1, 2 }),
    );
    try testing.expectEqualStrings(
        "must be one of eu-west-1, us-east-1 (did you mean eu-west-1?)",
        try runs([]const u8, .oneOf(&.{ "eu-west-1", "us-east-1" }), "eu-wset-1"),
    );
    try testing.expectEqualStrings(
        "must match *.pem",
        try runs([]const u8, .glob("*.pem"), "k.txt"),
    );
    const check: Check(u16) = .max(10);
    try testing.expectEqual(10, check.about.?.max.number.?);
    try testing.expectEqualStrings("10", check.about.?.max.text);
}

test "NaN is out of every bound" {
    try testing.expectEqualStrings("must be at least 0", try runs(f64, .min(0), std.math.nan(f64)));
    try testing.expectEqualStrings("must be at most 1", try runs(f64, .max(1), std.math.nan(f64)));
    try testing.expectEqualStrings("", try runs(f64, .max(1), 1));
}

const Millis = struct {
    n: u64,
    pub fn order(a: Millis, b: Millis) std.math.Order {
        return std.math.order(a.n, b.n);
    }
    pub fn format(m: Millis, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}ms", .{m.n});
    }
};

test "min and max on an ordered type, shown with its format" {
    try testing.expectEqualStrings(
        "must be at least 10ms",
        try runs(Millis, .min(.{ .n = 10 }), .{ .n = 9 }),
    );
    try testing.expectEqualStrings("", try runs(Millis, .max(.{ .n = 10 }), .{ .n = 10 }));
}

fn even(n: u16, w: *std.Io.Writer) !void {
    if (n % 2 != 0) return fail(w, "{0} is odd", .{n});
}

test "a Reason keeps fail's template and arguments; a plain writer gets the text" {
    var buffer: [64]u8 = undefined;
    var reason: Reason = .init(&buffer);
    try testing.expectEqual(error.Invalid, fail(&reason.writer, "{1} took {0}", .{ 8080, "ada" }));
    try testing.expectEqualStrings("ada took 8080", reason.text());
    try testing.expectEqualStrings("{1} took {0}", reason.template.?);
    var out: [max_args][]const u8 = undefined;
    const args = reason.args(&out);
    try testing.expectEqual(2, args.len);
    try testing.expectEqualStrings("8080", args[0]);
    try testing.expectEqualStrings("ada", args[1]);
    var plain: std.Io.Writer = .fixed(&buffer);
    try testing.expectEqual(error.Invalid, fail(&plain, "{{literal}} {0}", .{1.5}));
    try testing.expectEqualStrings("{literal}} 1.5", plain.buffered());
    // Written some other way: text only.
    var other: Reason = .init(&buffer);
    try other.writer.writeAll("is wrong");
    try testing.expectEqual(null, other.template);
}

test "a check of your own" {
    try testing.expectEqualStrings("3 is odd", try runs(u16, .from(even), 3));
    try testing.expectEqual(null, (Check(u16).from(even)).about);
}

test matches {
    try testing.expect(matches("*.example.com", "a.example.com"));
    try testing.expect(matches("a?c", "abc"));
    try testing.expect(!matches("*.pem", "key.txt"));
    try testing.expect(matches("*", ""));
}
