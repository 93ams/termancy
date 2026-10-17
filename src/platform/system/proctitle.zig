//! Hiding secrets passed on the command line from other users' `ps`.
//!
//! A flag like `--token=abc` is readable by every user of the machine for as long as the
//! process runs. `scrub` overwrites the secret bytes in the process's own argument memory
//! with `*`, which is where `ps` reads them on some systems:
//!
//! - Linux: `/proc/<pid>/cmdline` is read from the live argument area, so the change is
//!   visible at once.
//! - macOS: `ps` reads the argument area through `sysctl(KERN_PROCARGS2)`, which copies
//!   it from the process's memory, so the change is visible too.
//! - FreeBSD, NetBSD, OpenBSD: the kernel keeps its own copy from `exec`; overwriting
//!   memory changes nothing visible (`setproctitle(3)` is the tool there).
//! - Windows: other processes (Task Manager, `Get-CimInstance Win32_Process`) read the
//!   command line, one UTF-16 string, from the process environment block in the process's
//!   memory, and `std.process.Args` is that string. `scrub` masks the values in it
//!   (`scrubCommandLine`), so the change is visible at once.
//!
//! The secret was visible between `exec` and the call, so scrub first thing in `main`, and
//! prefer passing secrets through files or the environment. Scrubbing destroys the bytes:
//! copy any value the program needs before calling it, including slices a parser handed
//! out that point into the arguments.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const native = builtin.os.tag;

/// Whether `scrub` changes what other processes see on this OS.
pub const effective = native == .linux or native.isDarwin() or native == .windows;

/// The byte that replaces each secret byte.
pub const mask = '*';

/// Bytes of the argument list that hold a secret: `argv[arg][start..]`.
pub const Span = struct {
    arg: usize,
    start: usize,
};

/// Finds the values of the given flags in an argument list. For a flag `--token` it
/// yields the value of `--token=abc` (after the `=`) and the whole argument after a bare
/// `--token`; for a short flag `-p` the rest of `-pabc` and the argument after `-p`.
/// Scanning stops at `--`. `argv[0]` is never a flag.
pub const Iterator = struct {
    argv: []const []const u8,
    flags: []const []const u8,
    index: usize = 1,

    /// The next secret, or `null` at the end.
    pub fn next(it: *Iterator) ?Span {
        while (it.index < it.argv.len) {
            const i = it.index;
            it.index += 1;
            switch (match(it.argv[i], it.flags)) {
                .none => {},
                .end => it.index = it.argv.len,
                .attached => |start| return .{ .arg = i, .start = start },
                .next => if (i + 1 < it.argv.len) {
                    it.index += 1;
                    return .{ .arg = i + 1, .start = 0 };
                },
            }
        }
        return null;
    }
};

const Match = union(enum) {
    none,
    /// `--`: no flags follow.
    end,
    /// The value starts at this offset of the same argument.
    attached: usize,
    /// The value is the next argument.
    next,
};

fn match(arg: []const u8, flags: []const []const u8) Match {
    if (std.mem.eql(u8, arg, "--")) return .end;
    for (flags) |flag| {
        assert(flag.len >= 2 and flag[0] == '-');
        if (!std.mem.startsWith(u8, arg, flag)) continue;
        if (arg.len == flag.len) return .next;
        const long = flag[1] == '-';
        if (long and arg[flag.len] != '=') continue;
        return .{ .attached = flag.len + @intFromBool(long) };
    }
    return .none;
}

/// Iterates the secrets in `argv` for `flags` such as `&.{ "--token", "-p" }`.
pub fn iterate(argv: []const []const u8, flags: []const []const u8) Iterator {
    return .{ .argv = argv, .flags = flags };
}

/// Overwrites the values of `flags` in the process's arguments with `mask`, in place, and
/// returns how many values were scrubbed. Returns 0 on WASI. See the file comment for
/// where this hides the values and where it does not.
pub fn scrub(args: std.process.Args, flags: []const []const u8) usize {
    // The command line is writable process memory; `Args` merely types it as const.
    if (native == .windows) return scrubCommandLine(@constCast(args.vector), flags);
    if (comptime std.process.Args.Vector == void) return 0;
    const vector = args.vector;
    var count: usize = 0;
    var i: usize = 1;
    while (i < vector.len) : (i += 1) {
        const target, const start = switch (match(std.mem.span(vector[i]), flags)) {
            .none => continue,
            .end => break,
            .attached => |start| .{ i, start },
            .next => if (i + 1 < vector.len) .{ i + 1, 0 } else break,
        };
        if (target != i) i += 1;
        maskFrom(vector[target], start);
        count += 1;
    }
    return count;
}

fn maskFrom(arg: [*:0]const u8, start: usize) void {
    // The argument area is writable process memory; `Args` merely types it as const.
    const bytes: [*]u8 = @constCast(arg);
    @memset(bytes[start..std.mem.len(arg)], mask);
}

/// Masks the values of `flags` in a Windows command line, in place, and returns how many
/// were masked. The line is split as the Microsoft C runtime splits it: the program name
/// ends at the first space or tab outside quotes, and in the arguments `2n` backslashes
/// before a quote are `n` backslashes and the quote toggles quoting, `2n + 1` are `n` and a
/// literal quote, and `""` inside quotes is a literal quote. Every unit that makes up a
/// value is masked, escapes included; quotes that only toggle quoting are kept.
pub fn scrubCommandLine(line: []u16, flags: []const []const u8) usize {
    var pos = skipProgramName(line);
    var count: usize = 0;
    var mask_next = false;
    while (true) {
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
        if (pos >= line.len) break;
        var arg: Unquote = .{ .line = line, .pos = pos };
        if (mask_next) {
            mask_next = false;
            maskUnits(line, &arg, 0);
            count += 1;
            pos = arg.pos;
            continue;
        }
        // The flag names are short ASCII; a longer prefix of the argument is enough.
        var prefix: [max_flag_len + 1]u8 = undefined;
        var len: usize = 0;
        var probe = arg;
        while (probe.next()) |unit| : (len += 1) {
            if (len == prefix.len) break;
            prefix[len] = if (unit.value < 0x80) @intCast(unit.value) else 0xff;
        }
        switch (match(prefix[0..len], flags)) {
            .none => {
                while (arg.next()) |_| {}
            },
            .end => break,
            .attached => |start| {
                maskUnits(line, &arg, start);
                count += 1;
            },
            .next => {
                while (arg.next()) |_| {}
                mask_next = true;
            },
        }
        pos = arg.pos;
    }
    return count;
}

/// The longest flag name `scrubCommandLine` matches.
const max_flag_len = 64;

fn skipProgramName(line: []const u16) usize {
    var pos: usize = 0;
    var quoted = false;
    while (pos < line.len) : (pos += 1) {
        const c = line[pos];
        if (c == '"') {
            quoted = !quoted;
        } else if (!quoted and (c == ' ' or c == '\t')) break;
    }
    return pos;
}

/// Masks the units of the rest of `arg` from its `start`th decoded unit on.
fn maskUnits(line: []u16, arg: *Unquote, start: usize) void {
    var index: usize = 0;
    while (arg.next()) |unit| : (index += 1) {
        if (index >= start) @memset(line[unit.from..unit.to], mask);
    }
}

/// Decodes one argument of a Windows command line, yielding each unit with the units it
/// came from.
const Unquote = struct {
    line: []const u16,
    pos: usize,
    quoted: bool = false,
    /// Backslashes decoded but not yet yielded, where the first of them comes from, and
    /// from how many units each (two when they escape each other before a quote).
    backslashes: usize = 0,
    backslash_at: usize = 0,
    backslash_width: usize = 1,
    /// A literal quote to yield after the backslashes, escaped by the backslash before it.
    quote_at: ?usize = null,

    /// A decoded unit and the units `line[from..to]` it came from.
    const Unit = struct { value: u16, from: usize, to: usize };

    fn next(u: *Unquote) ?Unit {
        while (true) {
            if (u.backslashes > 0) {
                u.backslashes -= 1;
                const from = u.backslash_at;
                u.backslash_at += u.backslash_width;
                return .{ .value = '\\', .from = from, .to = u.backslash_at };
            }
            if (u.quote_at) |at| {
                u.quote_at = null;
                return .{ .value = '"', .from = at - 1, .to = at + 1 };
            }
            if (u.pos >= u.line.len) return null;
            const c = u.line[u.pos];
            if (!u.quoted and (c == ' ' or c == '\t')) return null;
            switch (c) {
                '\\' => {
                    const start = u.pos;
                    while (u.pos < u.line.len and u.line[u.pos] == '\\') u.pos += 1;
                    const run = u.pos - start;
                    u.backslash_at = start;
                    if (u.pos < u.line.len and u.line[u.pos] == '"') {
                        u.backslashes = run / 2;
                        u.backslash_width = 2;
                        if (run % 2 == 1) {
                            u.quote_at = u.pos;
                            u.pos += 1;
                        }
                    } else {
                        u.backslashes = run;
                        u.backslash_width = 1;
                    }
                },
                '"' => {
                    if (u.quoted and u.pos + 1 < u.line.len and u.line[u.pos + 1] == '"') {
                        u.pos += 2;
                        return .{ .value = '"', .from = u.pos - 2, .to = u.pos };
                    }
                    u.quoted = !u.quoted;
                    u.pos += 1;
                },
                else => {
                    u.pos += 1;
                    return .{ .value = c, .from = u.pos - 1, .to = u.pos };
                },
            }
        }
    }
};

const testing = std.testing;

fn expectSpans(argv: []const []const u8, flags: []const []const u8, expected: []const Span) !void {
    var it = iterate(argv, flags);
    for (expected) |span| try testing.expectEqual(span, it.next().?);
    try testing.expectEqual(null, it.next());
}

test "long flags with = and with a separate value" {
    try expectSpans(
        &.{ "app", "--token=abc", "--verbose", "--token", "def", "--tokenizer=x" },
        &.{"--token"},
        &.{ .{ .arg = 1, .start = 8 }, .{ .arg = 4, .start = 0 } },
    );
}

test "short flags attached and separate" {
    try expectSpans(
        &.{ "app", "-psecret", "-p", "two", "-v" },
        &.{"-p"},
        &.{ .{ .arg = 1, .start = 2 }, .{ .arg = 3, .start = 0 } },
    );
}

test "stops at -- and at a trailing flag; argv[0] is not a flag" {
    try expectSpans(&.{ "--token", "--token" }, &.{"--token"}, &.{});
    try expectSpans(&.{ "app", "--", "--token=x" }, &.{"--token"}, &.{});
    try expectSpans(&.{ "app", "--password=" }, &.{"--password"}, &.{.{ .arg = 1, .start = 11 }});
}

test "scrub overwrites the values in place" {
    if (native == .windows) {
        var line = std.unicode.utf8ToUtf16LeStringLiteral("app --token=abc -p hunter2 keep").*;
        const args: std.process.Args = .{ .vector = &line };
        try testing.expectEqual(2, scrub(args, &.{ "--token", "-p" }));
        const want = std.unicode.utf8ToUtf16LeStringLiteral("app --token=*** -p ******* keep");
        try testing.expectEqualSlices(u16, want, &line);
        return;
    }
    if (comptime std.process.Args.Vector == void) return error.SkipZigTest;
    var a0 = "app".*;
    var a1 = "--token=abc".*;
    var a2 = "-p".*;
    var a3 = "hunter2".*;
    var a4 = "keep".*;
    const vector = [_][*:0]const u8{ &a0, &a1, &a2, &a3, &a4 };
    const args: std.process.Args = .{ .vector = &vector };
    try testing.expectEqual(2, scrub(args, &.{ "--token", "-p" }));
    try testing.expectEqualStrings("--token=***", &a1);
    try testing.expectEqualStrings("*******", &a3);
    try testing.expectEqualStrings("keep", &a4);
    try testing.expectEqual(0, scrub(args, &.{"--other"}));
}

/// Scrubs `line` as a Windows command line and compares the result.
fn expectScrubbed(
    line: []const u8,
    flags: []const []const u8,
    count: usize,
    want: []const u8,
) !void {
    var buffer: [128]u16 = undefined;
    for (line, 0..) |c, i| buffer[i] = c;
    try testing.expectEqual(count, scrubCommandLine(buffer[0..line.len], flags));
    var got: [128]u8 = undefined;
    for (buffer[0..line.len], 0..) |c, i| got[i] = @intCast(c);
    try testing.expectEqualStrings(want, got[0..line.len]);
}

test "scrubCommandLine: the Windows splitting rules" {
    const flags: []const []const u8 = &.{ "--token", "-p" };
    try expectScrubbed(
        "app --token=abc -p  two keep",
        flags,
        2,
        "app --token=*** -p  *** keep",
    );
    // The program name ends at a space outside quotes, and is never a flag.
    try expectScrubbed(
        "\"C:\\Program Files\\--token\" --token \"a b\"",
        flags,
        1,
        "\"C:\\Program Files\\--token\" --token \"***\"",
    );
    // Quoted flag names match; escapes in values are masked, toggling quotes are kept.
    try expectScrubbed(
        "app \"--token=x\\\"y\" \"-p\"\"q\" -- --token=z",
        flags,
        2,
        "app \"--token=****\" \"-p***\" -- --token=z",
    );
    // Backslashes not before a quote are literal; pairs before one are each one backslash.
    try expectScrubbed("a --token=c:\\d e", flags, 1, "a --token=**** e");
    try expectScrubbed("a -p\\\\\"x\" e", flags, 1, "a -p**\"*\" e");
    // A trailing flag with no value, and nothing to do.
    try expectScrubbed("a --token", flags, 0, "a --token");
    try expectScrubbed("a b", flags, 0, "a b");
    try expectScrubbed("", flags, 0, "");
}
