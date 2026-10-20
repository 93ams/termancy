//! One answer to "may I emit escapes, and how many colors": a pure function of the
//! environment and of whether the output is a terminal, so every rule is testable.
//!
//! Rules, first match wins for color:
//!
//! 1. `NO_COLOR` set and non-empty: no color.
//! 2. `FORCE_COLOR`: `0` or `false` means no color; `1`, `true`, or empty means at least 16
//!    colors; `2` means 256; `3` means truecolor. Applies even when not a terminal.
//! 3. `CLICOLOR_FORCE` set and not `0`: color even when not a terminal, at the level the
//!    terminal variables suggest (at least 16).
//! 4. Not a terminal: no color, except under `CI` (16 colors; truecolor on GitHub and Gitea
//!    Actions), whose logs render escapes.
//! 5. `TERM=dumb`, or `CLICOLOR=0`: no color.
//! 6. Otherwise the level comes from `COLORTERM` (`truecolor`, `24bit`), `WT_SESSION`,
//!    `KONSOLE_VERSION`, `VTE_VERSION` (0.36 and later), `TERM_PROGRAM` (iTerm2, WezTerm,
//!    Ghostty, VS Code, ...), and `TERM` (`*-direct`, `*truecolor*`, kitty, Ghostty,
//!    Alacritty, WezTerm, foot, `*256color*`); a terminal with no `TERM` is a Windows
//!    console (truecolor) on Windows and 16 colors elsewhere.
//!
//! Escapes (cursor movement, redraws) are allowed only on a terminal whose `TERM` is not
//! `dumb`. Color and escapes are independent: `NO_COLOR` still allows an interactive
//! program, and `FORCE_COLOR` into a pipe yields color without cursor control.

const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;

/// How many colors the output can show. Ordered: a higher level can show everything a lower
/// one can.
pub const Color = enum(u2) {
    none,
    /// The 16 ANSI colors (8 plus their bright variants).
    basic,
    /// The xterm 256-color palette.
    ansi256,
    /// 24-bit RGB.
    truecolor,

    /// The lower of two levels.
    pub fn min(a: Color, b: Color) Color {
        return @fromBackingInt(@intCast(@min(@backingInt(a), @backingInt(b))));
    }

    /// The higher of two levels.
    pub fn max(a: Color, b: Color) Color {
        return @fromBackingInt(@intCast(@max(@backingInt(a), @backingInt(b))));
    }
};

/// What the output may receive.
pub const Capability = struct {
    color: Color,
    /// Cursor movement, erasing, modes: everything an interactive program needs.
    escapes: bool,
    /// Whether the terminal rewraps lines when it narrows, as most do; xterm, st, and the
    /// Linux console cut them instead. Redrawing in place after a resize counts rows by it.
    reflows: bool = true,

    /// Everything allowed; the default for in-memory rendering.
    pub const full: Capability = .{ .color = .truecolor, .escapes = true };
    /// Plain text only.
    pub const plain: Capability = .{ .color = .none, .escapes = false };
};

/// The facts `detect` decides from.
pub const Facts = struct {
    /// Whether the output stream is a terminal.
    is_tty: bool,
    /// The operating system, which decides what a terminal without `TERM` is.
    os: std.Target.Os.Tag = builtin.os.tag,
};

/// The capability of an output stream, from the environment and `facts`.
pub fn detect(environ: *const Environ.Map, facts: Facts) Capability {
    const term = environ.get("TERM");
    const dumb = if (term) |t| std.mem.eql(u8, t, "dumb") else false;
    return .{
        .color = colorLevel(environ, facts, dumb),
        .escapes = facts.is_tty and !dumb,
        .reflows = reflows(environ, term orelse ""),
    };
}

/// Whether the terminal rewraps lines when it narrows: not xterm (which sets
/// `XTERM_VERSION`, unless tmux or screen, which do rewrap, runs inside it), st, or the
/// Linux console.
fn reflows(environ: *const Environ.Map, term: []const u8) bool {
    const multiplexed = environ.get("TMUX") != null or environ.get("STY") != null;
    if (environ.get("XTERM_VERSION") != null and !multiplexed) return false;
    if (std.mem.eql(u8, term, "linux")) return false;
    if (std.mem.eql(u8, term, "st") or std.mem.startsWith(u8, term, "st-")) return false;
    return true;
}

fn colorLevel(environ: *const Environ.Map, facts: Facts, dumb: bool) Color {
    if (nonEmpty(environ, "NO_COLOR")) return .none;
    if (environ.get("FORCE_COLOR")) |value| {
        if (forcedLevel(value)) |forced| {
            if (forced == .none) return .none;
            return forced.max(if (facts.is_tty and !dumb) terminalLevel(environ, facts) else .none);
        }
    }
    if (environ.get("CLICOLOR_FORCE")) |value| {
        if (value.len > 0 and !std.mem.eql(u8, value, "0")) {
            return terminalLevel(environ, facts).max(.basic);
        }
    }
    if (!facts.is_tty) return ciLevel(environ);
    if (dumb) return .none;
    if (environ.get("CLICOLOR")) |value| {
        if (std.mem.eql(u8, value, "0")) return .none;
    }
    return terminalLevel(environ, facts);
}

/// The level `FORCE_COLOR` asks for, or null when its value means nothing.
fn forcedLevel(value: []const u8) ?Color {
    if (value.len == 0 or eqlIgnoreCase(value, "true")) return .basic;
    if (eqlIgnoreCase(value, "false")) return .none;
    const level = std.fmt.parseInt(u8, value, 10) catch return null;
    return switch (level) {
        0 => .none,
        1 => .basic,
        2 => .ansi256,
        else => .truecolor,
    };
}

/// Whether the process runs under continuous integration: `CI` is set, and not to `0` or
/// `false`. Its logs render color, but nobody is there to answer a question.
pub fn ci(environ: *const Environ.Map) bool {
    const value = environ.get("CI") orelse return false;
    if (value.len == 0 or std.mem.eql(u8, value, "0")) return false;
    return !eqlIgnoreCase(value, "false");
}

fn ciLevel(environ: *const Environ.Map) Color {
    if (!ci(environ)) return .none;
    if (environ.get("GITHUB_ACTIONS") != null or environ.get("GITEA_ACTIONS") != null) {
        return .truecolor;
    }
    return .basic;
}

/// The level a terminal supports, judged from the variables terminals set.
fn terminalLevel(environ: *const Environ.Map, facts: Facts) Color {
    if (environ.get("COLORTERM")) |value| {
        if (eqlIgnoreCase(value, "truecolor") or eqlIgnoreCase(value, "24bit")) return .truecolor;
    }
    if (environ.get("WT_SESSION") != null) return .truecolor;
    if (environ.get("KONSOLE_VERSION") != null) return .truecolor;
    // VTE-based terminals (GNOME Terminal, Tilix, ...) have 24-bit color since 0.36.
    if (environ.get("VTE_VERSION")) |version| {
        if ((std.fmt.parseInt(u32, version, 10) catch 0) >= 3600) return .truecolor;
    }
    if (environ.get("TERM_PROGRAM")) |program| {
        const truecolor_programs = [_][]const u8{
            "iTerm.app", "WezTerm", "ghostty", "vscode", "Hyper", "WarpTerminal", "rio", "Tabby",
        };
        for (truecolor_programs) |name| if (std.mem.eql(u8, program, name)) return .truecolor;
        if (std.mem.eql(u8, program, "Apple_Terminal")) return .ansi256;
    }
    const term = environ.get("TERM") orelse
        return if (facts.os == .windows) .truecolor else .basic;
    if (std.mem.endsWith(u8, term, "-direct") or contains(term, "truecolor")) return .truecolor;
    const truecolor_terms = [_][]const u8{ "kitty", "ghostty", "alacritty", "wezterm", "foot" };
    for (truecolor_terms) |name| if (contains(term, name)) return .truecolor;
    if (contains(term, "256color")) return .ansi256;
    if (term.len == 0) return if (facts.os == .windows) .truecolor else .basic;
    return .basic;
}

fn nonEmpty(environ: *const Environ.Map, name: []const u8) bool {
    const value = environ.get(name) orelse return false;
    return value.len > 0;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const testing = std.testing;

const Case = struct {
    env: []const [2][]const u8,
    tty: bool = true,
    os: std.Target.Os.Tag = .linux,
    color: Color,
    escapes: bool = true,
    reflows: bool = true,
};

fn expectCase(case: Case) !void {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    for (case.env) |pair| try environ.put(pair[0], pair[1]);
    const got = detect(&environ, .{ .is_tty = case.tty, .os = case.os });
    testing.expectEqual(case.color, got.color) catch |err| {
        std.debug.print("env {any} tty={} os={t}\n", .{ case.env, case.tty, case.os });
        return err;
    };
    try testing.expectEqual(case.escapes, got.escapes);
    try testing.expectEqual(case.reflows, got.reflows);
}

test "detect: the terminal variables set the level" {
    try expectCase(.{ .env = &.{.{ "TERM", "xterm" }}, .color = .basic });
    try expectCase(.{ .env = &.{.{ "TERM", "xterm-256color" }}, .color = .ansi256 });
    try expectCase(.{ .env = &.{.{ "TERM", "xterm-direct" }}, .color = .truecolor });
    try expectCase(.{ .env = &.{.{ "TERM", "foot-truecolor" }}, .color = .truecolor });
    try expectCase(.{
        .env = &.{ .{ "TERM", "xterm-256color" }, .{ "COLORTERM", "truecolor" } },
        .color = .truecolor,
    });
    try expectCase(.{
        .env = &.{ .{ "TERM", "xterm" }, .{ "COLORTERM", "24BIT" } },
        .color = .truecolor,
    });
    try expectCase(.{ .env = &.{.{ "TERM_PROGRAM", "Apple_Terminal" }}, .color = .ansi256 });
    try expectCase(.{ .env = &.{.{ "TERM_PROGRAM", "iTerm.app" }}, .color = .truecolor });
    try expectCase(.{ .env = &.{.{ "WT_SESSION", "x" }}, .color = .truecolor });
    try expectCase(.{ .env = &.{}, .color = .basic });
    try expectCase(.{ .env = &.{}, .os = .windows, .color = .truecolor });
    try expectCase(.{ .env = &.{.{ "TERM", "" }}, .os = .windows, .color = .truecolor });
    try expectCase(.{ .env = &.{.{ "TERM", "xterm-kitty" }}, .color = .truecolor });
    try expectCase(.{ .env = &.{.{ "TERM", "xterm-ghostty" }}, .color = .truecolor });
    try expectCase(.{ .env = &.{.{ "TERM", "alacritty" }}, .color = .truecolor });
    try expectCase(.{
        .env = &.{ .{ "TERM", "xterm-256color" }, .{ "TERM_PROGRAM", "vscode" } },
        .color = .truecolor,
    });
    try expectCase(.{
        .env = &.{ .{ "TERM", "xterm-256color" }, .{ "VTE_VERSION", "7600" } },
        .color = .truecolor,
    });
    try expectCase(.{
        .env = &.{ .{ "TERM", "xterm-256color" }, .{ "VTE_VERSION", "3405" } },
        .color = .ansi256,
    });
    try expectCase(.{ .env = &.{.{ "TERM", "screen-256color" }}, .color = .ansi256 });
    try expectCase(.{ .env = &.{.{ "TERM", "linux" }}, .color = .basic, .reflows = false });
}

test "detect: dumb terminals get neither color nor escapes" {
    try expectCase(.{ .env = &.{.{ "TERM", "dumb" }}, .color = .none, .escapes = false });
    try expectCase(.{
        .env = &.{ .{ "TERM", "dumb" }, .{ "FORCE_COLOR", "1" } },
        .color = .basic,
        .escapes = false,
    });
}

test "detect: xterm, st, and the Linux console cut lines; tmux in xterm rewraps" {
    const xterm = .{ "XTERM_VERSION", "XTerm(390)" };
    try expectCase(.{ .env = &.{ .{ "TERM", "xterm-256color" }, xterm }, .color = .ansi256, .reflows = false });
    try expectCase(.{
        .env = &.{ .{ "TERM", "tmux-256color" }, xterm, .{ "TMUX", "/tmp/tmux-1000/default,1,0" } },
        .color = .ansi256,
    });
    try expectCase(.{ .env = &.{.{ "TERM", "st-256color" }}, .color = .ansi256, .reflows = false });
    try expectCase(.{ .env = &.{.{ "TERM", "linux" }}, .color = .basic, .reflows = false });
    try expectCase(.{ .env = &.{.{ "TERM", "xterm-256color" }}, .color = .ansi256 });
}

test "detect: NO_COLOR wins, but keeps escapes" {
    try expectCase(.{
        .env = &.{ .{ "TERM", "xterm-256color" }, .{ "NO_COLOR", "1" } },
        .color = .none,
    });
    try expectCase(.{
        .env = &.{ .{ "NO_COLOR", "1" }, .{ "FORCE_COLOR", "3" } },
        .color = .none,
    });
    // An empty NO_COLOR is not set, per no-color.org.
    try expectCase(.{ .env = &.{ .{ "TERM", "xterm" }, .{ "NO_COLOR", "" } }, .color = .basic });
}

test "detect: FORCE_COLOR levels, on and off a terminal" {
    try expectCase(.{ .env = &.{.{ "FORCE_COLOR", "0" }}, .color = .none });
    try expectCase(.{ .env = &.{.{ "FORCE_COLOR", "false" }}, .color = .none });
    try expectCase(.{
        .env = &.{.{ "FORCE_COLOR", "" }},
        .tty = false,
        .color = .basic,
        .escapes = false,
    });
    try expectCase(.{
        .env = &.{.{ "FORCE_COLOR", "true" }},
        .tty = false,
        .color = .basic,
        .escapes = false,
    });
    try expectCase(.{
        .env = &.{.{ "FORCE_COLOR", "2" }},
        .tty = false,
        .color = .ansi256,
        .escapes = false,
    });
    try expectCase(.{
        .env = &.{.{ "FORCE_COLOR", "3" }},
        .tty = false,
        .color = .truecolor,
        .escapes = false,
    });
    // Forcing never lowers what the terminal can do.
    try expectCase(.{
        .env = &.{ .{ "FORCE_COLOR", "1" }, .{ "COLORTERM", "truecolor" } },
        .color = .truecolor,
    });
    // A value that means nothing is ignored.
    try expectCase(.{
        .env = &.{.{ "FORCE_COLOR", "maybe" }},
        .tty = false,
        .color = .none,
        .escapes = false,
    });
}

test "detect: CLICOLOR and CLICOLOR_FORCE" {
    try expectCase(.{ .env = &.{ .{ "TERM", "xterm" }, .{ "CLICOLOR", "0" } }, .color = .none });
    try expectCase(.{ .env = &.{ .{ "TERM", "xterm" }, .{ "CLICOLOR", "1" } }, .color = .basic });
    try expectCase(.{
        .env = &.{.{ "CLICOLOR_FORCE", "1" }},
        .tty = false,
        .color = .basic,
        .escapes = false,
    });
    try expectCase(.{
        .env = &.{ .{ "CLICOLOR_FORCE", "1" }, .{ "TERM", "xterm-256color" } },
        .tty = false,
        .color = .ansi256,
        .escapes = false,
    });
    try expectCase(.{
        .env = &.{.{ "CLICOLOR_FORCE", "0" }},
        .tty = false,
        .color = .none,
        .escapes = false,
    });
    // CLICOLOR_FORCE outranks CLICOLOR=0.
    try expectCase(.{
        .env = &.{ .{ "CLICOLOR", "0" }, .{ "CLICOLOR_FORCE", "1" } },
        .color = .basic,
    });
}

test "detect: pipes are plain, except in CI" {
    try expectCase(.{
        .env = &.{.{ "TERM", "xterm-256color" }},
        .tty = false,
        .color = .none,
        .escapes = false,
    });
    try expectCase(.{
        .env = &.{.{ "CI", "true" }},
        .tty = false,
        .color = .basic,
        .escapes = false,
    });
    try expectCase(.{ .env = &.{.{ "CI", "" }}, .tty = false, .color = .none, .escapes = false });
    try expectCase(.{
        .env = &.{ .{ "CI", "true" }, .{ "GITHUB_ACTIONS", "true" } },
        .tty = false,
        .color = .truecolor,
        .escapes = false,
    });
}

test ci {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expect(!ci(&environ));
    for ([_][]const u8{ "", "0", "false", "FALSE" }) |value| {
        try environ.put("CI", value);
        try testing.expect(!ci(&environ));
    }
    for ([_][]const u8{ "true", "1", "woodpecker" }) |value| {
        try environ.put("CI", value);
        try testing.expect(ci(&environ));
    }
}

test "Color: min and max" {
    try testing.expectEqual(Color.basic, Color.ansi256.min(.basic));
    try testing.expectEqual(Color.truecolor, Color.none.max(.truecolor));
}
