//! A single-line loading spinner for a step whose duration is unknown.
//!
//! A progress bar needs a total; a spinner is for the case where there is not one
//! yet - resolving a lockfile, waiting on a socket, hashing a large file. The two
//! are complements, not variants of one widget, which is why this is its own file
//! rather than another field on `MultiProgress`.
//!
//! ## The frames are ASCII on purpose
//!
//! The familiar Braille spinner is prettier and this tree cannot currently be
//! trusted with it: `src/lib/framework/ROADMAP.md` S-0a/S-0b record that **two encoders in
//! this environment corrupt non-ASCII text**, and that the corruption is already
//! present in ten committed files. A widget whose default output depends on the
//! writer's encoding is a widget that renders mojibake on someone else's machine.
//! Callers that know their encoding is intact can pass their own frames to
//! `withFrames`.
//!
//! ## Redrawing
//!
//! Every frame is written as `\r` + text, so the spinner overwrites itself instead
//! of scrolling. `stop` clears the line first, so a caller can print the result on
//! the same row the spinner occupied. `drawn` tracks whether a frame is currently
//! on the line, because clearing a line that was never drawn emits a `\r` and
//! erases whatever the shell had there.

const std = @import("std");
const assert = std.debug.assert;

/// The frames this spinner cycles through by default.
pub const ascii_frames = [_][]const u8{ "|", "/", "-", "\\" };

label: []const u8,
frames: []const []const u8 = &ascii_frames,
frame_index: usize = 0,
/// When false, `tick` and `stop` write nothing. This is the single bit a caller
/// sets from its TTY/`NO_COLOR` gate, so the widget itself never reads the
/// environment and stays testable.
enabled: bool = true,
/// Whether a frame is currently on the current line.
drawn: bool = false,

const Self = @This();

/// A spinner labelled `label`. `label` is borrowed, not copied, so it must outlive
/// the spinner - the usual case is a string literal.
pub fn init(label: []const u8) Self {
    assert(label.len > 0);
    return .{ .label = label };
}

/// A spinner that cycles its own frames.
pub fn withFrames(label: []const u8, frames: []const []const u8) Self {
    assert(label.len > 0);
    assert(frames.len > 0);
    return .{ .label = label, .frames = frames };
}

/// Suppresses all output. Idempotent.
pub fn disable(self: *Self) void {
    assert(self.frames.len > 0);
    self.enabled = false;
}

/// Restores output. Does not redraw a frame that was suppressed while disabled.
pub fn enable(self: *Self) void {
    assert(self.frames.len > 0);
    self.enabled = true;
}

/// Advances one frame and redraws in place.
pub fn tick(self: *Self, writer: anytype) !void {
    assert(self.frames.len > 0);
    if (!self.enabled) return;

    const frame = self.frames[self.frame_index];
    self.frame_index = (self.frame_index + 1) % self.frames.len;
    assert(self.frame_index < self.frames.len);

    try writer.print("\r{s} {s}", .{ frame, self.label });
    self.drawn = true;
}

/// Erases the current line if a frame is on it, leaving the cursor at column 0.
pub fn clear(self: *Self, writer: anytype) !void {
    assert(self.frames.len > 0);
    if (!self.drawn) return;

    try writer.writeAll("\r\x1b[2K");
    self.drawn = false;
}

/// Erases the spinner and, when enabled, prints `final_label` in its place.
///
/// `final_label` is what the caller wants the user to be left looking at - the
/// completion line - so the spinner never invents one.
pub fn stop(self: *Self, writer: anytype, final_label: []const u8) !void {
    assert(self.frames.len > 0);
    try self.clear(writer);
    if (!self.enabled) return;
    if (final_label.len == 0) return;

    try writer.print("{s}\n", .{final_label});
}

const testing = std.testing;

test "tick cycles the frames and prefixes each with a carriage return" {
    var spinner = Self.init("working");
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try spinner.tick(&writer);
    try testing.expectEqualStrings("\r| working", writer.buffered());

    var second: [64]u8 = undefined;
    var writer2 = std.Io.Writer.fixed(&second);
    try spinner.tick(&writer2);
    try testing.expectEqualStrings("\r/ working", writer2.buffered());
}

test "the frame index wraps rather than running off the end" {
    var spinner = Self.init("working");
    // Four frames of eleven bytes each, so the buffer holds the whole sequence.
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Five ticks, so the last one must be the first frame again and the index must
    // be back inside the array rather than one past the end.
    for (0..5) |_| try spinner.tick(&writer);
    try testing.expect(spinner.frame_index < spinner.frames.len);
    try testing.expectEqual(@as(usize, 1), spinner.frame_index);
}

test "stop erases the line before printing the final label" {
    var spinner = Self.init("working");
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try spinner.tick(&writer);
    try spinner.stop(&writer, "done");
    try testing.expectEqualStrings("\r| working\r\x1b[2Kdone\n", writer.buffered());
    try testing.expect(!spinner.drawn);
}

test "stop on a spinner that never drew emits nothing" {
    // Clearing a line that was never drawn would erase whatever the shell had
    // there, so this is a behaviour, not an optimisation.
    var spinner = Self.init("working");
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try spinner.stop(&writer, "done");
    try testing.expectEqualStrings("done\n", writer.buffered());
}

test "disable suppresses every write and enable restores them" {
    var spinner = Self.init("working");
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    spinner.disable();
    try spinner.tick(&writer);
    try spinner.stop(&writer, "done");
    try testing.expectEqualStrings("", writer.buffered());
    try testing.expect(!spinner.drawn);

    spinner.enable();
    try spinner.tick(&writer);
    try testing.expectEqualStrings("\r| working", writer.buffered());
}

test "custom frames are used verbatim" {
    var spinner = Self.withFrames("loading", &.{ "a", "b" });
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try spinner.tick(&writer);
    try spinner.tick(&writer);
    try testing.expectEqualStrings("\ra loading\rb loading", writer.buffered());
}
