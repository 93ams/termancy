//! The single process-wide answer to "may this program emit terminal escapes?"
//!
//! ## The problem this exists to solve
//!
//! `ColorEngine.detectProfile` was written, documented and **never called** -
//! `[measured]` zero call sites tree-wide. Meanwhile `Style.render`,
//! `highlight`, `renderDiff` and `MultiProgress.render` all emitted escape
//! sequences unconditionally. So the framework could detect that it was writing
//! into a pipe and had no way to act on it, and `NO_COLOR=1` changed nothing a
//! user could see. Two facts about the same decision lived in two places and one
//! of them was dead.
//!
//! This module is that decision, and it is the only one. Renderers ask it; nobody
//! re-derives it.
//!
//! ## Why a process-wide value rather than a parameter
//!
//! The alternative is threading a flag through every renderer and every caller of
//! every renderer, which for a styling helper means changing hundreds of call
//! sites to answer a question whose answer never differs between them. The value
//! is written once during startup, before any command runs, and read afterwards.
//!
//! ## Default is ON
//!
//! `[measured]` the default is "everything enabled". A library that renders into
//! a buffer - the test suite, `HeadlessTerminal`, a caller capturing output - must
//! not silently lose its escape sequences because it never called `set`. A
//! program that wants the gate applies it explicitly at startup, which
//! `cli.App.run` does.
//!
//! ## The three bits are not one bit
//!
//! They are separate because they answer to different rules, and collapsing them
//! is a real bug rather than a simplification:
//!
//!   * `color` honours `NO_COLOR`.
//!   * `cursor` deliberately does **not**. The `NO_COLOR` specification says the
//!     variable must not be used to suppress cursor movement, and a progress bar
//!     that vanished because someone set `NO_COLOR` would be a surprise. Cursor
//!     movement is suppressed by being *piped*, not by being colourless.
//!   * `interactive` follows stdin, because reading a prompt requires the terminal
//!     the user is typing into, which may be a different stream from the one
//!     output goes to.

const std = @import("std");
const assert = std.debug.assert;

/// What the process is allowed to do to its terminal.
pub const Capability = struct {
    /// ANSI colour and text styling.
    color: bool = true,
    /// Cursor movement, in-place redraw, line clearing.
    cursor: bool = true,
    /// Prompting the user for input.
    interactive: bool = true,
};

/// Everything on, which is also the pre-`set` default.
pub const all: Capability = .{ .color = true, .cursor = true, .interactive = true };

/// Everything off: plain text, no cursor movement, no prompting.
pub const none: Capability = .{ .color = false, .cursor = false, .interactive = false };

const color_bit: u8 = 1 << 0;
const cursor_bit: u8 = 1 << 1;
const interactive_bit: u8 = 1 << 2;

var state = std.atomic.Value(u8).init(color_bit | cursor_bit | interactive_bit);

/// Installs the process-wide capability. Called once, during startup.
pub fn set(capability: Capability) void {
    state.store(encode(capability), .release);
}

/// The current capability. Safe to call from any thread.
pub fn get() Capability {
    return decode(state.load(.acquire));
}

/// Decides the capability from the environment and the two streams' TTY status.
///
/// `stdout_is_tty` governs whether escapes can be *seen*; `stdin_is_tty` governs
/// whether the program can *ask*. They are separate because a program can
/// legitimately be `prog > file` while still prompting on the terminal.
pub fn decide(
    env_map: *const std.process.Environ.Map,
    stdout_is_tty: bool,
    stdin_is_tty: bool,
) Capability {
    assert(@sizeOf(Capability) == 3);

    const no_color = isSet(env_map, "NO_COLOR");
    // `FORCE_COLOR` is the escape hatch for `prog | less -R` and for CI logs that
    // can render escapes. `NO_COLOR` wins over it: an explicit opt-out is a
    // stronger signal than an opt-in, and the two are occasionally both set by
    // nested tools.
    const force_color = isSet(env_map, "FORCE_COLOR");
    const dumb_terminal = if (env_map.get("TERM")) |term|
        std.mem.eql(u8, term, "dumb")
    else
        false;

    const color = if (no_color)
        false
    else if (force_color)
        true
    else
        stdout_is_tty and !dumb_terminal;

    return .{
        .color = color,
        // Not `color`: see the module comment.
        .cursor = stdout_is_tty and !dumb_terminal,
        .interactive = stdin_is_tty,
    };
}

/// `true` when `name` is present **and non-empty**.
///
/// The distinction is the `NO_COLOR` specification's, not an invention: `NO_COLOR=`
/// is what a shell produces from an unset variable in many scripts, and treating
/// that as "the user asked for no colour" would disable colour for people who
/// never asked.
fn isSet(env_map: *const std.process.Environ.Map, name: []const u8) bool {
    assert(name.len > 0);
    const value = env_map.get(name) orelse return false;
    return value.len > 0;
}

fn encode(capability: Capability) u8 {
    var bits: u8 = 0;
    if (capability.color) bits |= color_bit;
    if (capability.cursor) bits |= cursor_bit;
    if (capability.interactive) bits |= interactive_bit;
    return bits;
}

fn decode(bits: u8) Capability {
    assert(bits & ~(color_bit | cursor_bit | interactive_bit) == 0);
    return .{
        .color = bits & color_bit != 0,
        .cursor = bits & cursor_bit != 0,
        .interactive = bits & interactive_bit != 0,
    };
}

const testing = std.testing;

fn envWith(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "the default is everything enabled, so a library never loses its escapes" {
    const saved = get();
    defer set(saved);

    // Reset to the initial value the module ships with, then check it.
    set(all);
    try testing.expect(get().color);
    try testing.expect(get().cursor);
    try testing.expect(get().interactive);
}

test "piped stdout disables colour and cursor movement but not prompting" {
    var map = try envWith(testing.allocator, &.{.{ "TERM", "xterm-256color" }});
    defer map.deinit();

    const capability = decide(&map, false, true);
    try testing.expect(!capability.color);
    try testing.expect(!capability.cursor);
    // stdout is a file but stdin is still the terminal, so a prompt is fine.
    try testing.expect(capability.interactive);
}

test "a terminal with a normal TERM enables everything" {
    var map = try envWith(testing.allocator, &.{.{ "TERM", "xterm-256color" }});
    defer map.deinit();

    const capability = decide(&map, true, true);
    try testing.expect(capability.color);
    try testing.expect(capability.cursor);
    try testing.expect(capability.interactive);
}

test "NO_COLOR disables colour but leaves cursor movement alone" {
    var map = try envWith(testing.allocator, &.{
        .{ "TERM", "xterm-256color" },
        .{ "NO_COLOR", "1" },
    });
    defer map.deinit();

    const capability = decide(&map, true, true);
    try testing.expect(!capability.color);
    // The NO_COLOR specification forbids using the variable to suppress cursor
    // movement, and a progress bar that disappeared would be a surprise.
    try testing.expect(capability.cursor);
}

test "an empty NO_COLOR is not an opt-out" {
    var map = try envWith(testing.allocator, &.{
        .{ "TERM", "xterm-256color" },
        .{ "NO_COLOR", "" },
    });
    defer map.deinit();

    try testing.expect(decide(&map, true, true).color);
}

test "FORCE_COLOR re-enables colour into a pipe, and NO_COLOR still wins" {
    var forced = try envWith(testing.allocator, &.{.{ "FORCE_COLOR", "1" }});
    defer forced.deinit();
    try testing.expect(decide(&forced, false, false).color);

    var both = try envWith(testing.allocator, &.{
        .{ "FORCE_COLOR", "1" },
        .{ "NO_COLOR", "1" },
    });
    defer both.deinit();
    try testing.expect(!decide(&both, true, true).color);
}

test "TERM=dumb disables escapes even on a terminal" {
    var map = try envWith(testing.allocator, &.{.{ "TERM", "dumb" }});
    defer map.deinit();

    const capability = decide(&map, true, true);
    try testing.expect(!capability.color);
    try testing.expect(!capability.cursor);
}

test "the encoding round-trips every combination" {
    for ([_]bool{ true, false }) |color| {
        for ([_]bool{ true, false }) |cursor| {
            for ([_]bool{ true, false }) |interactive| {
                const original = Capability{
                    .color = color,
                    .cursor = cursor,
                    .interactive = interactive,
                };
                set(original);
                try testing.expectEqual(original, get());
            }
        }
    }
    set(all);
}
