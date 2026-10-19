//! Checks on a value: plain functions, plus built-in ones that also describe themselves for
//! help, documentation, schemas, and completion.

const std = @import("std");
const name = @import("name.zig");

/// What a check returns: `error.Invalid` after writing why to its writer.
pub const Error = error{Invalid} || std.Io.Writer.Error;

/// Writes why a value is invalid and returns `error.Invalid`:
/// `return field.fail(w, "{d} is in use", .{port});`.
pub fn fail(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) Error {
    try w.print(fmt, args);
    return error.Invalid;
}

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
                    if (less(v, n)) return fail(w, "must be at least {s}", .{comptime bound(n).text});
                }
            }.run };
        }

        /// At most `n`: a number, or a type with `order(a, b) std.math.Order`.
        pub fn max(comptime n: NumberOrOrdered(V)) Self {
            return .{ .about = .{ .max = bound(n) }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (less(n, v)) return fail(w, "must be at most {s}", .{comptime bound(n).text});
                }
            }.run };
        }

        /// At least `n` long: characters for a string, elements for a list.
        pub fn minLen(comptime n: usize) Self {
            comptime sized();
            return .{ .about = .{ .min_len = n }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (length(v) < n) return fail(w, "must be at least {d} long", .{n});
                }
            }.run };
        }

        /// At most `n` long: characters for a string, elements for a list.
        pub fn maxLen(comptime n: usize) Self {
            comptime sized();
            return .{ .about = .{ .max_len = n }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (length(v) > n) return fail(w, "must be at most {d} long", .{n});
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
                        return fail(w, "must be one of {s} (did you mean {s}?)", .{ all, close });
                    }
                    return fail(w, "must be one of {s}", .{all});
                }
            }.run };
        }

        /// Matching `pattern`, for a string: `*` matches any run of bytes, `?` one byte.
        pub fn glob(comptime pattern: []const u8) Self {
            if (V != []const u8) @compileError(".glob needs a string, found " ++ @typeName(V));
            return .{ .about = .{ .glob = pattern }, .run = struct {
                fn run(v: V, w: *std.Io.Writer) Error!void {
                    if (!matches(pattern, v)) return fail(w, "must match {s}", .{pattern});
                }
            }.run };
        }

        fn sized() void {
            const list = @typeInfo(V) == .pointer and @typeInfo(V).pointer.size == .slice;
            if (!list) @compileError(".minLen and .maxLen need a string or a list, found " ++
                @typeName(V));
        }

        fn less(a: V, b: V) bool {
            if (@typeInfo(V) == .int or @typeInfo(V) == .float) return a < b;
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
    try testing.expectEqualStrings("must be at least 3 long", try runs([]const u8, .minLen(3), "né"));
    try testing.expectEqualStrings("must be at most 1 long", try runs([]const u32, .maxLen(1), &.{ 1, 2 }));
    try testing.expectEqualStrings(
        "must be one of eu-west-1, us-east-1 (did you mean eu-west-1?)",
        try runs([]const u8, .oneOf(&.{ "eu-west-1", "us-east-1" }), "eu-wset-1"),
    );
    try testing.expectEqualStrings("must match *.pem", try runs([]const u8, .glob("*.pem"), "k.txt"));
    const check: Check(u16) = .max(10);
    try testing.expectEqual(10, check.about.?.max.number.?);
    try testing.expectEqualStrings("10", check.about.?.max.text);
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
    try testing.expectEqualStrings("must be at least 10ms", try runs(Millis, .min(.{ .n = 10 }), .{ .n = 9 }));
    try testing.expectEqualStrings("", try runs(Millis, .max(.{ .n = 10 }), .{ .n = 10 }));
}

fn even(n: u16, w: *std.Io.Writer) !void {
    if (n % 2 != 0) return fail(w, "{d} is odd", .{n});
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
