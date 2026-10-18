//! A line editor for interactive shells (REPLs): an `Input` with history and tab
//! completion. Up and down (ctrl+p, ctrl+n) walk the history, keeping the line being
//! typed; tab completes the last word from `completer`: one match is filled in, several
//! fill in what they share and are listed under the line. Enter submits; ctrl+d on an empty
//! line ends the input; esc cancels.
//!
//! ```zig
//! var line: Shell = .{
//!     .input = .{ .gpa = gpa, .prompt = "app> " },
//!     .history = history,
//!     .completer = .{ .context = &repl, .function = completeLine },
//! };
//! defer line.deinit();
//! // ... run it as a program ...
//! switch (line.status) {
//!     .submitted => run(line.value()),
//!     .ended, .canceled => break,
//!     .active => unreachable,
//! }
//! ```
//!
//! With `cli`, `completeLine` can call `cli.repl.Repl.complete`, which answers from the
//! same command tree the shell completion scripts use.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Input = @import("input.zig").Input;

pub const Status = enum { active, submitted, ended, canceled };

/// Computes the completions of the last word of `line` (empty after a space), each the
/// whole word, in `arena`.
pub const Completer = struct {
    context: *anyopaque,
    function: *const fn (
        context: *anyopaque,
        arena: Allocator,
        line: []const u8,
    ) anyerror![]const []const u8,
};

pub const Shell = struct {
    input: Input,
    /// Earlier lines, oldest first.
    history: []const []const u8 = &.{},
    completer: ?Completer = null,
    status: Status = .active,
    /// The history entry shown, while walking the history.
    browsing: ?usize = null,
    /// The line being typed when the walk began, shown again after the newest entry.
    draft: std.ArrayList(u8) = .empty,
    /// The matches of the last tab that found several, listed under the line.
    choices: []const []const u8 = &.{},
    /// Holds `choices` and completion results until the next tab.
    scratch: ?std.heap.ArenaAllocator = null,
    styles: Styles = .{},

    pub const Styles = struct {
        choices: tui.Style = .{ .fg = .{ .indexed = 244 } },
    };

    pub fn deinit(shell: *Shell) void {
        const allocator = shell.gpa();
        shell.input.deinit();
        shell.draft.deinit(allocator);
        if (shell.scratch) |*arena| arena.deinit();
        shell.* = undefined;
    }

    /// The line as typed.
    pub fn value(shell: *const Shell) []const u8 {
        return shell.input.value();
    }

    fn gpa(shell: *const Shell) Allocator {
        return shell.input.gpa;
    }

    pub fn update(shell: *Shell, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .key => |key| {
                if (key.matches("enter")) return shell.finish(.submitted);
                if (key.matches("esc")) return shell.finish(.canceled);
                if (key.matches("ctrl+d") and shell.value().len == 0) return shell.finish(.ended);
                if (key.matches("up") or key.matches("ctrl+p")) {
                    shell.older();
                } else if (key.matches("down") or key.matches("ctrl+n")) {
                    shell.newer();
                } else if (key.matches("tab")) {
                    shell.complete();
                } else if (shell.input.handleKey(key)) {
                    shell.choices = &.{};
                }
            },
            .paste => |text| shell.input.insert(text) catch {},
            else => {},
        }
        return .none;
    }

    fn finish(shell: *Shell, status: Status) tui.Cmd {
        shell.status = status;
        shell.choices = &.{};
        return .quit;
    }

    /// Shows the entry before the one shown, saving the typed line on the first step.
    fn older(shell: *Shell) void {
        if (shell.history.len == 0) return;
        const index = if (shell.browsing) |i| i -| 1 else blk: {
            shell.draft.clearRetainingCapacity();
            shell.draft.appendSlice(shell.gpa(), shell.value()) catch return;
            break :blk shell.history.len - 1;
        };
        shell.browsing = index;
        shell.input.setValue(shell.history[index]) catch {};
    }

    /// Shows the entry after the one shown, or the saved line after the newest.
    fn newer(shell: *Shell) void {
        const index = shell.browsing orelse return;
        if (index + 1 < shell.history.len) {
            shell.browsing = index + 1;
            shell.input.setValue(shell.history[index + 1]) catch {};
        } else {
            shell.browsing = null;
            shell.input.setValue(shell.draft.items) catch {};
        }
    }

    /// Completes the last word of the line.
    fn complete(shell: *Shell) void {
        const completer = shell.completer orelse return;
        if (shell.scratch) |*arena| {
            _ = arena.reset(.retain_capacity);
        } else {
            shell.scratch = .init(shell.gpa());
        }
        const arena = shell.scratch.?.allocator();
        shell.choices = &.{};
        const line = arena.dupe(u8, shell.value()) catch return;
        const found = completer.function(completer.context, arena, line) catch return;
        if (found.len == 0) return;
        const word_start = if (std.mem.lastIndexOfScalar(u8, line, ' ')) |space| space + 1 else 0;
        const shared = commonPrefix(found);
        const replacement = if (found.len == 1)
            std.mem.concat(arena, u8, &.{ found[0], " " }) catch return
        else
            shared;
        if (replacement.len >= line.len - word_start) {
            const text = std.mem.concat(arena, u8, &.{ line[0..word_start], replacement }) catch
                return;
            shell.input.setValue(text) catch return;
        }
        if (found.len > 1) shell.choices = found;
    }

    pub fn view(shell: *const Shell, w: *Writer) Writer.Error!void {
        try shell.input.view(w);
        if (shell.choices.len == 0) return;
        try w.writeByte('\n');
        for (shell.choices, 0..) |choice, i| {
            if (i > 0) try w.writeAll("  ");
            try shell.styles.choices.paint(w, choice);
        }
    }
};

/// The longest prefix all of `words` share.
fn commonPrefix(words: []const []const u8) []const u8 {
    var prefix = words[0];
    for (words[1..]) |word| {
        const shared = std.mem.indexOfDiff(u8, prefix, word) orelse @min(prefix.len, word.len);
        prefix = prefix[0..shared];
    }
    return prefix;
}

const testing = std.testing;
const Driver = tui.testing.Driver(Shell);

const commands = [_][]const u8{ "get", "keys", "set", "show" };

/// Completes the first word from `commands`, nothing after it.
fn completeCommand(_: *anyopaque, arena: Allocator, line: []const u8) ![]const []const u8 {
    if (std.mem.indexOfScalar(u8, line, ' ') != null) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (commands) |command| {
        if (std.mem.startsWith(u8, command, line)) try out.append(arena, command);
    }
    return out.items;
}

var unused: u8 = 0;

fn start(d: *Driver, history: []const []const u8) !void {
    d.* = try .init(testing.allocator, .{
        .input = .{ .gpa = testing.allocator, .prompt = "$ " },
        .history = history,
        .completer = .{ .context = &unused, .function = completeCommand },
    }, .{});
}

fn finish(d: *Driver) void {
    d.deinit();
}

test "tab fills in one match, the shared part of several, and lists them" {
    var d: Driver = undefined;
    try start(&d, &.{});
    defer finish(&d);
    try d.typeText("k");
    try d.press("tab");
    try testing.expectEqualStrings("keys ", d.model().value());
    try d.press("ctrl+u");
    try d.typeText("s");
    try d.press("tab");
    try testing.expectEqualStrings("s", d.model().value());
    try d.expectFrame("$ s \nset  show");
    try d.typeText("h");
    try d.press("tab");
    try testing.expectEqualStrings("show ", d.model().value());
    try d.expectFrame("$ show  ");
}

test "up and down walk the history and come back to the typed line" {
    var d: Driver = undefined;
    try start(&d, &.{ "get a", "keys" });
    defer finish(&d);
    try d.typeText("dra");
    try d.press("up");
    try testing.expectEqualStrings("keys", d.model().value());
    try d.press("up");
    try d.press("up");
    try testing.expectEqualStrings("get a", d.model().value());
    try d.press("down");
    try d.press("down");
    try testing.expectEqualStrings("dra", d.model().value());
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
}

test "ctrl+d on an empty line ends the input; esc cancels" {
    var d: Driver = undefined;
    try start(&d, &.{});
    defer finish(&d);
    try d.typeText("x");
    try d.press("ctrl+d"); // Deletes forward, as in `Input`, when the line has text.
    try testing.expect(!d.done());
    try d.press("backspace");
    try d.press("ctrl+d");
    try testing.expect(d.done());
    try testing.expectEqual(Status.ended, d.model().status);

    var e: Driver = undefined;
    try start(&e, &.{});
    defer finish(&e);
    try e.press("esc");
    try testing.expectEqual(Status.canceled, e.model().status);
}

test commonPrefix {
    try testing.expectEqualStrings("s", commonPrefix(&.{ "set", "show" }));
    try testing.expectEqualStrings("sho", commonPrefix(&.{ "show", "shown", "sho" }));
}
