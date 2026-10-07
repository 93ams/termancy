//! Compile-time checks for a command's flag metadata.
//!
//! These are mistakes that are otherwise *silent*: a duplicated short flag means one
//! of two flags can never be reached, a flag named `help` is shadowed by the
//! framework's own interception, and `.count = true` on a string field fails deep
//! inside `parseFlags` with a message about `+=` rather than about the declaration
//! that caused it. A compile error naming the field is the cheapest possible place to
//! catch all three.
//!
//! `src/lib/framework`'s `App.command` and `App.Command` run this when the command *type* is
//! built, so a bad declaration fails the build even if the command is never executed
//! by a test.

const std = @import("std");

pub const ComptimeLinter = struct {
    /// Long flag names the framework consumes before a command's flags are parsed.
    ///
    /// `help` is intercepted by the router, and `output`, `interactive` and `yes` are
    /// merged into every command's flags from `GlobalFlags` - so a command that
    /// declares one either shadows the framework's behaviour or collides with a field
    /// that already exists.
    pub const reserved_long_names = [_][]const u8{ "help", "output", "interactive", "yes" };

    /// Short flag names the framework consumes. `-h` is help.
    pub const reserved_short_names = [_]u8{'h'};

    /// Checks one flags type's metadata, failing the build on a collision.
    pub fn lintFlags(comptime FlagsType: type) void {
        if (FlagsType == void) return;
        if (!@hasDecl(FlagsType, "meta")) {
            lintReservedNames(FlagsType, null);
            return;
        }

        const Meta = @TypeOf(FlagsType.meta);
        const meta = FlagsType.meta;
        const fields = std.meta.fields(FlagsType);

        // Check for duplicate short flags
        inline for (fields, 0..) |f1, i| {
            if (@hasField(Meta, f1.name)) {
                const m1 = @field(meta, f1.name);
                if (@hasField(@TypeOf(m1), "short")) {
                    const s1 = m1.short;
                    inline for (fields[i + 1 ..]) |f2| {
                        if (@hasField(Meta, f2.name)) {
                            const m2 = @field(meta, f2.name);
                            if (@hasField(@TypeOf(m2), "short")) {
                                const s2 = m2.short;
                                if (s1 == s2) {
                                    @compileError("CLI Flag Collision: Flags '" ++ f1.name ++ "' and '" ++ f2.name ++ "' share duplicate shorthand '-" ++ [_]u8{s1} ++ "'");
                                }
                            }
                        }
                    }
                }
            }
        }

        lintCountFlags(FlagsType, Meta);
        lintReservedNames(FlagsType, Meta);
    }

    /// `.count = true` accumulates with `+= 1`, so it only means anything on a number.
    fn lintCountFlags(comptime FlagsType: type, comptime Meta: type) void {
        const meta = FlagsType.meta;
        inline for (std.meta.fields(FlagsType)) |field| {
            if (@hasField(Meta, field.name)) {
                const field_meta = @field(meta, field.name);
                if (@hasField(@TypeOf(field_meta), "count")) {
                    if (field_meta.count) {
                        switch (@typeInfo(field.type)) {
                            .int => {},
                            else => @compileError("CLI Flag Collision: '" ++ field.name ++
                                "' declares `.count = true`, which needs an integer field (found " ++
                                @typeName(field.type) ++ ")"),
                        }
                    }
                }
            }
        }
    }

    /// A name the framework already owns cannot also be a command's flag.
    fn lintReservedNames(comptime FlagsType: type, comptime Meta: ?type) void {
        inline for (std.meta.fields(FlagsType)) |field| {
            inline for (reserved_long_names) |reserved| {
                if (comptime std.mem.eql(u8, field.name, reserved)) {
                    @compileError("CLI Flag Collision: '" ++ field.name ++
                        "' is reserved by the framework; rename the field");
                }
            }

            if (comptime Meta) |MetaT| {
                if (@hasField(MetaT, field.name)) {
                    const field_meta = @field(FlagsType.meta, field.name);
                    if (@hasField(@TypeOf(field_meta), "short")) {
                        inline for (reserved_short_names) |reserved_short| {
                            if (field_meta.short == reserved_short) {
                                @compileError("CLI Flag Collision: '-" ++ [_]u8{reserved_short} ++
                                    "' (field '" ++ field.name ++ "') is reserved by the framework");
                            }
                        }
                    }
                }
            }
        }
    }

    /// Checks that every name in a command's mutually exclusive groups names a real flag.
    ///
    /// A group whose name matches nothing is a safeguard that enforces nothing: the
    /// declaration reads as a rule, the command line is never checked against it, and the
    /// mistake is a typo no test will catch. Members are compared in either spelling, so
    /// `use_tcp` and `use-tcp` both resolve.
    pub fn lintMutexGroups(comptime FlagsType: type, comptime groups: anytype) void {
        inline for (groups) |group| {
            if (comptime group.len < 2) {
                @compileError("CLI Group Collision: a mutually exclusive group needs at least two flags");
            }
            inline for (group) |name| {
                if (comptime !hasFlagNamed(FlagsType, name)) {
                    @compileError("CLI Group Collision: '" ++ name ++
                        "' is in a mutually exclusive group but names no flag of this command");
                }
            }
        }
    }

    /// Whether the flags type has a field with this name, in either spelling.
    fn hasFlagNamed(comptime FlagsType: type, comptime name: []const u8) bool {
        inline for (std.meta.fields(FlagsType)) |field| {
            if (comptime namesEqual(field.name, name)) return true;
        }
        return false;
    }

    /// `dry_run` and `dry-run` name the same flag; the same equivalence `src/lib/framework` matches on.
    fn namesEqual(comptime a: []const u8, comptime b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const na = if (ca == '_') '-' else ca;
            const nb = if (cb == '_') '-' else cb;
            if (na != nb) return false;
        }
        return true;
    }
};

const testing = std.testing;

// A struct with no metadata at all: nothing to collide, and the reserved-name pass
// still has to accept it.
test "a flags type with no metadata lints clean" {
    ComptimeLinter.lintFlags(struct { port: u16 = 8080 });
}

test "a well-formed metadata block lints clean" {
    ComptimeLinter.lintFlags(struct {
        port: u16 = 8080,
        verbose: u8 = 0,

        pub const meta = .{
            .port = .{ .short = 'p' },
            .verbose = .{ .short = 'v', .count = true },
        };
    });
}

// The failures this catches are compile errors, so they cannot be asserted with
// `expectError`. Each was verified by writing it and observing the message:
//
//   * duplicate short:   `.verbose = .{ .short = 'v' }` and `.version = .{ .short = 'v' }`
//   * reserved long:     a field named `help`
//   * reserved short:    `.hidden = .{ .short = 'h' }`
//   * count on a string: `.tag = .{ .count = true }`
//
// The checks are wired into `App.command` and `App.Command`, so a bad declaration
// fails the build when the command type is built - before any test runs.
test "the reserved lists are not empty" {
    try testing.expect(ComptimeLinter.reserved_long_names.len > 0);
    try testing.expect(ComptimeLinter.reserved_short_names.len > 0);
}
