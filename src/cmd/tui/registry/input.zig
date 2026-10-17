//! A single-line text input: a prompt, the text with a cursor, an optional placeholder,
//! password masking, a length limit, and a validation hook.
//!
//! ```zig
//! var input: Input = .{ .gpa = gpa, .placeholder = "your name" };
//! defer input.deinit();
//! // ... run it as a program, or forward messages to it from a larger model ...
//! if (input.status == .submitted) use(input.value());
//! ```
//!
//! Keys: printable characters insert; left/right (ctrl+b/ctrl+f) move by character,
//! alt+left/alt+right (alt+b/alt+f) by word; home/end (ctrl+a/ctrl+e) jump; backspace and
//! delete (ctrl+d) erase; ctrl+w erases the word before the cursor, ctrl+u everything before
//! it, ctrl+k everything after it. Enter submits when `validate` accepts the text (its
//! message is shown otherwise); esc cancels. A paste inserts its text with line breaks and
//! tabs turned into spaces.
//!
//! Ctrl+z undoes the last edit and ctrl+y (or ctrl+shift+z) redoes it, cursor included.
//! Typing joins one undo step per word, and so does a run of backspaces or deletes; a
//! paste, a ctrl+w/ctrl+u/ctrl+k, `setValue` (an accepted suggestion too), and any edit
//! after the cursor moved are steps of their own. A new edit forgets what was undone.
//! `undo_limit` steps are kept, as copies of the text; 0 turns undo off. A `tui.Program`
//! with `suspend_on_ctrl_z` on stops the process on ctrl+z instead; ctrl+y still redoes.
//!
//! With `suggestions`, the rest of the first one that starts with what was typed shows
//! after the cursor, dimmed: tab (or right at the end) takes it, ctrl+n and ctrl+p go
//! through the others that match. `hidden` shows nothing as you type (for a secret whose
//! length should not show either); `password` shows `mask` for each character.
//! `cursorColumn` is where a real terminal cursor goes (`tui.Cursor`).
//!
//! The cursor moves by grapheme cluster (see `tui.width`), so it never splits a character.
//! The text grows with `gpa`; a keystroke that needs memory that is not there is dropped.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Status = enum { active, submitted, canceled };

/// Checks the text on submit: null to accept it, or a message saying what is wrong.
pub const Validator = *const fn (text: []const u8) ?[]const u8;

pub const Input = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Byte offset of the cursor in `text`, always at a cluster boundary.
    cursor: usize = 0,
    prompt: []const u8 = "> ",
    /// Shown, dimmed, while the text is empty.
    placeholder: []const u8 = "",
    /// Show `mask` for each character instead of the text.
    password: bool = false,
    mask: []const u8 = "•",
    /// The most characters (grapheme clusters) the text may hold.
    char_limit: ?usize = null,
    validate: ?Validator = null,
    /// Whether the cursor is drawn; a model holding several inputs focuses one.
    focused: bool = true,
    status: Status = .active,
    /// What `validate` said about the last submitted text, until the next edit.
    message: ?[]const u8 = null,
    /// Completions offered as you type: the first that starts with the text (ignoring
    /// ASCII case) shows after it.
    suggestions: []const []const u8 = &.{},
    /// Which of the matching suggestions is offered.
    suggestion: usize = 0,
    /// Show nothing of the text, not even its length.
    hidden: bool = false,
    /// The most edits ctrl+z can take back; 0 turns undo off.
    undo_limit: usize = 100,
    /// The text and cursor before each edit that can be undone, the oldest first.
    undo_steps: std.ArrayList(Snapshot) = .empty,
    /// The states undone, the latest undone last.
    redo_steps: std.ArrayList(Snapshot) = .empty,
    /// The last edit and where it left the cursor: another like it there joins its step.
    last_edit: Edit = .none,
    edit_end: usize = 0,
    styles: Styles = .{},

    pub const Snapshot = struct { text: std.ArrayList(u8), cursor: usize };

    /// What an edit was, for joining edits into one undo step.
    pub const Edit = enum { none, typing, erasing, other };

    pub const Styles = struct {
        prompt: tui.Style = .{ .fg = .{ .indexed = 212 } },
        text: tui.Style = .{},
        placeholder: tui.Style = .{ .fg = .{ .indexed = 240 } },
        cursor: tui.Style = .{ .reverse = true },
        message: tui.Style = .{ .fg = .{ .indexed = 203 } },
        suggestion: tui.Style = .{ .fg = .{ .indexed = 240 } },
    };

    /// The suggestion on offer, whole, or null when none matches what was typed.
    pub fn offered(input: *const Input) ?[]const u8 {
        var index: usize = 0;
        var first: ?[]const u8 = null;
        for (input.suggestions) |candidate| {
            if (!matchesPrefix(candidate, input.value())) continue;
            if (first == null) first = candidate;
            if (index == input.suggestion) return candidate;
            index += 1;
        }
        return first;
    }

    fn matchCount(input: *const Input) usize {
        var n: usize = 0;
        for (input.suggestions) |candidate| {
            n += @intFromBool(matchesPrefix(candidate, input.value()));
        }
        return n;
    }

    fn matchesPrefix(candidate: []const u8, typed: []const u8) bool {
        return typed.len > 0 and candidate.len > typed.len and
            std.ascii.startsWithIgnoreCase(candidate, typed);
    }

    /// Takes the suggestion on offer as the text; returns whether there was one.
    pub fn acceptSuggestion(input: *Input) bool {
        const choice = input.offered() orelse return false;
        input.setValue(choice) catch return false;
        input.suggestion = 0;
        return true;
    }

    /// The column of the cursor in the view: after the prompt and the text before it.
    pub fn cursorColumn(input: *const Input) usize {
        const before = input.value()[0..input.cursor];
        const typed = if (input.hidden)
            0
        else if (input.password)
            clusterCount(before) * tui.width.of(input.mask)
        else
            tui.width.of(before);
        return tui.width.of(input.prompt) + typed;
    }

    /// Frees the text and the undo history.
    pub fn deinit(input: *Input) void {
        input.text.deinit(input.gpa);
        for (input.undo_steps.items) |*step| step.text.deinit(input.gpa);
        for (input.redo_steps.items) |*step| step.text.deinit(input.gpa);
        input.undo_steps.deinit(input.gpa);
        input.redo_steps.deinit(input.gpa);
        input.* = undefined;
    }

    /// The text typed so far.
    pub fn value(input: *const Input) []const u8 {
        return input.text.items;
    }

    /// Replaces the text (cut to `char_limit`) and puts the cursor at its end, as one
    /// step ctrl+z takes back.
    pub fn setValue(input: *Input, text: []const u8) Allocator.Error!void {
        input.remember(.other);
        input.text.clearRetainingCapacity();
        input.cursor = 0;
        try input.insertAs(text, .none);
    }

    /// Inserts `text` at the cursor, as much of it as `char_limit` allows. Line breaks and
    /// tabs become spaces; other control characters and escapes are dropped.
    pub fn insert(input: *Input, text: []const u8) Allocator.Error!void {
        return input.insertAs(text, .other);
    }

    /// `insert`, recorded for undo as `kind` (`.none`: not recorded).
    fn insertAs(input: *Input, text: []const u8, kind: Edit) Allocator.Error!void {
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(input.gpa);
        var room = if (input.char_limit) |limit| limit -| clusterCount(input.value()) else null;
        var it: tui.width.Iterator = .init(text);
        while (it.next()) |cluster| {
            if (room) |left| {
                if (left == 0) break;
            }
            const bytes = sanitize(cluster) orelse continue;
            try clean.appendSlice(input.gpa, bytes);
            if (room) |*left| left.* -= 1;
        }
        input.message = null;
        if (clean.items.len == 0) return;
        input.remember(kind);
        try input.text.insertSlice(input.gpa, input.cursor, clean.items);
        input.cursor += clean.items.len;
        input.edit_end = input.cursor;
    }

    /// Records the text before an edit of `kind`, unless it continues the last edit (the
    /// same kind of typing or erasing, where that one left the cursor). A new step
    /// forgets what was undone. Without memory for it, the edit goes unrecorded.
    fn remember(input: *Input, kind: Edit) void {
        if (kind == .none or input.undo_limit == 0) return;
        const joins = kind != .other and kind == input.last_edit and
            input.cursor == input.edit_end;
        input.last_edit = kind;
        if (joins) return;
        for (input.redo_steps.items) |*step| step.text.deinit(input.gpa);
        input.redo_steps.clearRetainingCapacity();
        input.undo_steps.ensureUnusedCapacity(input.gpa, 1) catch return;
        const copy = input.gpa.dupe(u8, input.value()) catch return;
        if (input.undo_steps.items.len >= input.undo_limit) {
            var oldest = input.undo_steps.orderedRemove(0);
            oldest.text.deinit(input.gpa);
        }
        const step: Snapshot = .{ .text = .fromOwnedSlice(copy), .cursor = input.cursor };
        input.undo_steps.appendAssumeCapacity(step);
    }

    /// Takes back the last edit step; returns whether there was one.
    pub fn undo(input: *Input) bool {
        return input.swapStep(&input.undo_steps, &input.redo_steps);
    }

    /// Makes again the last step undone; returns whether there was one.
    pub fn redo(input: *Input) bool {
        return input.swapStep(&input.redo_steps, &input.undo_steps);
    }

    /// Restores the last state in `from`, keeping the current one in `to`.
    fn swapStep(input: *Input, from: *std.ArrayList(Snapshot), to: *std.ArrayList(Snapshot)) bool {
        if (from.items.len == 0) return false;
        to.ensureUnusedCapacity(input.gpa, 1) catch return false;
        const step = from.pop().?;
        to.appendAssumeCapacity(.{ .text = input.text, .cursor = input.cursor });
        input.text = step.text;
        input.cursor = step.cursor;
        input.last_edit = .none;
        input.message = null;
        return true;
    }

    fn sanitize(cluster: tui.width.Cluster) ?[]const u8 {
        if (cluster.escape) return null;
        return switch (cluster.bytes[0]) {
            '\n', '\r', '\t' => " ",
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => null,
            else => cluster.bytes,
        };
    }

    pub fn update(input: *Input, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .key => |key| {
                if (key.matches("enter")) return input.submit();
                if (key.matches("esc")) {
                    input.status = .canceled;
                    return .quit;
                }
                _ = input.handleKey(key);
            },
            .paste => |text| input.insert(text) catch {},
            else => {},
        }
        return .none;
    }

    /// Checks the text with `validate`: submits and quits when it passes, shows the
    /// message otherwise.
    pub fn submit(input: *Input) tui.Cmd {
        if (!input.check()) return .none;
        input.status = .submitted;
        return .quit;
    }

    /// Runs `validate`, recording its message; returns whether the text passes.
    pub fn check(input: *Input) bool {
        const validate = input.validate orelse return true;
        input.message = validate(input.value());
        return input.message == null;
    }

    /// Applies an editing or movement key; returns whether the key was one. Enter and esc
    /// are not: the caller decides what they mean.
    pub fn handleKey(input: *Input, key: tui.input.Key) bool {
        if (input.suggestions.len > 0) {
            const at_end = input.cursor == input.text.items.len;
            if (key.matches("tab") or (at_end and key.matches("right"))) {
                if (input.acceptSuggestion()) return true;
            }
            if (key.matches("ctrl+n") or key.matches("ctrl+p")) {
                const count = input.matchCount();
                if (count > 0) {
                    input.suggestion = if (key.matches("ctrl+n"))
                        (input.suggestion + 1) % count
                    else
                        (input.suggestion + count - 1) % count;
                }
                return true;
            }
        }
        defer if (input.suggestion >= @max(input.matchCount(), 1)) {
            input.suggestion = 0;
        };
        if (key.printable()) |c| {
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buffer) catch return true;
            // A word typed after a space is a new undo step.
            const text = input.value();
            if (c != ' ' and input.cursor > 0 and text[input.cursor - 1] == ' ') {
                input.last_edit = .none;
            }
            input.insertAs(buffer[0..len], .typing) catch {};
        } else if (key.matches("ctrl+z")) {
            _ = input.undo();
        } else if (key.matches("ctrl+y") or key.matches("ctrl+Z")) {
            // The decoder reports ctrl+shift+z as ctrl+Z.
            _ = input.redo();
        } else if (key.matches("left") or key.matches("ctrl+b")) {
            input.cursor = previousBoundary(input.value(), input.cursor);
        } else if (key.matches("right") or key.matches("ctrl+f")) {
            input.cursor = nextBoundary(input.value(), input.cursor);
        } else if (key.matches("alt+left") or key.matches("alt+b")) {
            input.cursor = wordStart(input.value(), input.cursor);
        } else if (key.matches("alt+right") or key.matches("alt+f")) {
            input.cursor = wordEnd(input.value(), input.cursor);
        } else if (key.matches("home") or key.matches("ctrl+a")) {
            input.cursor = 0;
        } else if (key.matches("end") or key.matches("ctrl+e")) {
            input.cursor = input.text.items.len;
        } else if (key.matches("backspace")) {
            input.erase(previousBoundary(input.value(), input.cursor), input.cursor, .erasing);
        } else if (key.matches("delete") or key.matches("ctrl+d")) {
            input.erase(input.cursor, nextBoundary(input.value(), input.cursor), .erasing);
        } else if (key.matches("ctrl+w") or key.matches("alt+backspace")) {
            input.erase(wordStart(input.value(), input.cursor), input.cursor, .other);
        } else if (key.matches("ctrl+u")) {
            input.erase(0, input.cursor, .other);
        } else if (key.matches("ctrl+k")) {
            input.erase(input.cursor, input.text.items.len, .other);
        } else return false;
        return true;
    }

    /// Removes `text[from..to]` and leaves the cursor at `from`.
    fn erase(input: *Input, from: usize, to: usize, kind: Edit) void {
        input.message = null;
        if (from == to) return;
        input.remember(kind);
        input.text.replaceRangeAssumeCapacity(from, to - from, &.{});
        input.cursor = from;
        input.edit_end = from;
    }

    pub fn view(input: *const Input, w: *Writer) Writer.Error!void {
        try input.styles.prompt.paint(w, input.prompt);
        if (input.text.items.len == 0) {
            try input.writePlaceholder(w);
        } else {
            try input.writeText(w);
        }
        if (input.message) |message| {
            try w.writeByte('\n');
            try input.styles.message.paint(w, message);
        }
    }

    fn writePlaceholder(input: *const Input, w: *Writer) Writer.Error!void {
        if (!input.focused) return input.styles.placeholder.paint(w, input.placeholder);
        const first = nextBoundary(input.placeholder, 0);
        try input.styles.cursor.paint(w, if (first == 0) " " else input.placeholder[0..first]);
        try input.styles.placeholder.paint(w, input.placeholder[first..]);
    }

    fn writeText(input: *const Input, w: *Writer) Writer.Error!void {
        const text = input.value();
        if (input.hidden) {
            if (input.focused) try input.styles.cursor.paint(w, " ");
            return;
        }
        var it: tui.width.Iterator = .init(text);
        var start: usize = 0;
        while (it.next()) |cluster| : (start = it.index) {
            const shown = if (input.password) input.mask else cluster.bytes;
            const style = if (input.focused and start == input.cursor)
                input.styles.cursor
            else
                input.styles.text;
            try style.paint(w, shown);
        }
        // The rest of the suggestion on offer, its first character under the cursor.
        const rest = if (input.offered()) |choice| choice[text.len..] else "";
        if (input.focused and input.cursor == text.len) {
            const first = nextBoundary(rest, 0);
            try input.styles.cursor.paint(w, if (first == 0) " " else rest[0..first]);
            try input.styles.suggestion.paint(w, rest[first..]);
        } else {
            try input.styles.suggestion.paint(w, rest);
        }
    }
};

/// The number of grapheme clusters in `text`.
pub fn clusterCount(text: []const u8) usize {
    var count: usize = 0;
    var it: tui.width.Iterator = .init(text);
    while (it.next()) |_| count += 1;
    return count;
}

/// The cluster boundary before `index`, or 0.
pub fn previousBoundary(text: []const u8, index: usize) usize {
    var it: tui.width.Iterator = .init(text);
    var last: usize = 0;
    while (it.index < index) {
        last = it.index;
        _ = it.next() orelse break;
    }
    return last;
}

/// The cluster boundary after `index`, or the end of `text`.
pub fn nextBoundary(text: []const u8, index: usize) usize {
    var it: tui.width.Iterator = .{ .bytes = text, .index = index };
    _ = it.next();
    return it.index;
}

/// The start of the word before `index`: back over spaces, then over the word.
pub fn wordStart(text: []const u8, index: usize) usize {
    var i = index;
    while (i > 0 and text[i - 1] == ' ') i -= 1;
    while (i > 0 and text[i - 1] != ' ') i -= 1;
    return i;
}

/// The end of the word after `index`: forward over spaces, then over the word.
pub fn wordEnd(text: []const u8, index: usize) usize {
    var i = index;
    while (i < text.len and text[i] == ' ') i += 1;
    while (i < text.len and text[i] != ' ') i += 1;
    return i;
}

const testing = std.testing;
const Driver = tui.testing.Driver(Input);

test "suggestions show, cycle, and are taken with tab" {
    var d: Driver = try .init(testing.allocator, .{
        .gpa = testing.allocator,
        .prompt = "",
        .suggestions = &.{ "apple", "apricot", "banana" },
        .styles = .{ .cursor = .{}, .suggestion = .{} },
    }, .{});
    defer d.deinit();
    try d.typeText("ap");
    try d.expectFrame("apple");
    try d.press("ctrl+n");
    try d.expectFrame("apricot");
    try d.press("tab");
    try testing.expectEqualStrings("apricot", d.model().value());
    try testing.expectEqual(7, d.model().cursorColumn());
}

test "hidden input shows nothing" {
    var d: Driver = try .init(testing.allocator, .{
        .gpa = testing.allocator,
        .hidden = true,
        .styles = .{ .cursor = .{}, .prompt = .{} },
    }, .{});
    defer d.deinit();
    try d.typeText("secret");
    try d.expectFrame(">  ");
    try testing.expectEqual(2, d.model().cursorColumn());
}

fn startInput(d: *Driver, input: Input) !void {
    d.* = try .init(testing.allocator, input, .{});
}

fn finish(d: *Driver) void {
    d.deinit();
}

test "typing, moving, and erasing" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.expectFrame(">  ");
    try d.typeText("helo");
    try d.expectFrame("> helo ");
    try d.press("left");
    try d.typeText("l");
    try testing.expectEqualStrings("hello", d.model().value());
    try testing.expectEqual(4, d.model().cursor);
    try d.press("home");
    try d.press("delete");
    try d.press("end");
    try d.press("backspace");
    try testing.expectEqualStrings("ell", d.model().value());
    try d.press("ctrl+a");
    try d.press("right");
    try d.press("ctrl+k");
    try testing.expectEqualStrings("e", d.model().value());
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
}

test "word movement and erasing" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.typeText("one two  three");
    try d.press("alt+left");
    try testing.expectEqual(9, d.model().cursor);
    try d.press("alt+b");
    try testing.expectEqual(4, d.model().cursor);
    try d.press("alt+right");
    try testing.expectEqual(7, d.model().cursor);
    try d.press("ctrl+w");
    try testing.expectEqualStrings("one   three", d.model().value());
    try d.press("end");
    try d.press("ctrl+u");
    try testing.expectEqualStrings("", d.model().value());
}

test "the cursor moves by whole characters" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.typeText("a中é");
    try d.press("left");
    try testing.expectEqual(4, d.model().cursor);
    try d.press("left");
    try testing.expectEqual(1, d.model().cursor);
    try d.press("delete");
    try testing.expectEqualStrings("aé", d.model().value());
    try d.expectFrame("> aé");
}

test "the cursor is drawn in reverse video" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    var input: Input = .{ .gpa = testing.allocator, .styles = .{ .prompt = .{} } };
    defer input.deinit();
    try input.setValue("ab");
    input.cursor = 1;
    try input.view(&w);
    try testing.expectEqualStrings("> a\x1b[7mb\x1b[0m", w.buffered());
}

test "placeholder and password" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator, .placeholder = "secret", .password = true });
    defer finish(&d);
    try d.expectFrame("> secret");
    try d.typeText("hunter2");
    try d.expectFrame("> ••••••• ");
    try testing.expectEqualStrings("hunter2", d.model().value());
}

test "char_limit stops typing and cuts pastes" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator, .char_limit = 3 });
    defer finish(&d);
    try d.typeText("abcd");
    try testing.expectEqualStrings("abc", d.model().value());
    try d.press("home");
    try d.press("delete");
    try d.paste("xyz");
    try testing.expectEqualStrings("xbc", d.model().value());
}

test "a paste keeps to one line" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.paste("one\ntwo\tthree\x07");
    try testing.expectEqualStrings("one two three", d.model().value());
}

fn notEmpty(text: []const u8) ?[]const u8 {
    return if (text.len == 0) "required" else null;
}

test "validation blocks submit and shows its message until the next edit" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator, .validate = notEmpty });
    defer finish(&d);
    try d.press("enter");
    try testing.expect(!d.done());
    try d.expectFrame(">  \nrequired");
    try d.typeText("x");
    try d.expectFrame("> x ");
    try d.press("enter");
    try testing.expect(d.done());
}

test "esc cancels" {
    var d: Driver = undefined;
    try startInput(&d, .{ .gpa = testing.allocator });
    defer finish(&d);
    try d.typeText("abc");
    try d.press("esc");
    try testing.expect(d.done());
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "setValue and an unfocused input" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    var input: Input = .{ .gpa = testing.allocator, .focused = false, .prompt = "" };
    defer input.deinit();
    try input.setValue("ready");
    try testing.expectEqual(5, input.cursor);
    try input.view(&w);
    try testing.expectEqualStrings("ready", w.buffered());
}

test "boundaries and words" {
    try testing.expectEqual(0, previousBoundary("abc", 0));
    try testing.expectEqual(1, previousBoundary("a中", 4));
    try testing.expectEqual(4, nextBoundary("a中", 1));
    try testing.expectEqual(4, nextBoundary("a中", 4));
    try testing.expectEqual(3, clusterCount("a中é"));
    try testing.expectEqual(4, wordStart("ab  cd", 6));
    try testing.expectEqual(0, wordStart("ab  cd", 4));
    try testing.expectEqual(6, wordEnd("ab  cd", 2));
}

test "typing undoes a word at a time, and redo puts it back, cursor included" {
    var d: Driver = try .init(testing.allocator, .{ .gpa = testing.allocator }, .{});
    defer finish(&d);
    try d.typeText("hello big world");
    try d.press("ctrl+z");
    try testing.expectEqualStrings("hello big ", d.model().value());
    try testing.expectEqual(10, d.model().cursor);
    try d.press("ctrl+z");
    try d.press("ctrl+z");
    try testing.expectEqualStrings("", d.model().value());
    try testing.expect(!d.model().undo());
    try d.press("ctrl+y");
    try testing.expectEqualStrings("hello ", d.model().value());
    try testing.expectEqual(6, d.model().cursor);
    try d.press("ctrl+Z"); // ctrl+shift+z
    try testing.expectEqualStrings("hello big ", d.model().value());
}

test "undo returns the cursor to where the edit was, and a move starts a new step" {
    var d: Driver = try .init(testing.allocator, .{ .gpa = testing.allocator }, .{});
    defer finish(&d);
    try d.typeText("abcd");
    try d.press("home");
    try d.typeText("xy");
    try d.press("end");
    try d.press("backspace");
    try d.press("backspace");
    try testing.expectEqualStrings("xyab", d.model().value());
    try d.press("ctrl+z"); // both backspaces
    try testing.expectEqualStrings("xyabcd", d.model().value());
    try testing.expectEqual(6, d.model().cursor);
    try d.press("ctrl+z");
    try testing.expectEqualStrings("abcd", d.model().value());
    try testing.expectEqual(0, d.model().cursor);
}

test "a new edit forgets what was undone" {
    var d: Driver = try .init(testing.allocator, .{ .gpa = testing.allocator }, .{});
    defer finish(&d);
    try d.typeText("one two");
    try d.press("ctrl+z");
    try d.typeText("x");
    try testing.expect(!d.model().redo());
    try testing.expectEqualStrings("one x", d.model().value());
}

test "a paste and a ctrl+w are one step each" {
    var d: Driver = try .init(testing.allocator, .{ .gpa = testing.allocator }, .{});
    defer finish(&d);
    try d.typeText("a");
    try d.paste("bc de");
    try d.typeText("f");
    try d.press("ctrl+w");
    try testing.expectEqualStrings("abc ", d.model().value());
    try d.press("ctrl+z");
    try testing.expectEqualStrings("abc def", d.model().value());
    try d.press("ctrl+z");
    try testing.expectEqualStrings("abc de", d.model().value());
    try d.press("ctrl+z");
    try testing.expectEqualStrings("a", d.model().value());
}

test "undo_limit keeps the latest steps, and 0 turns undo off" {
    var input: Input = .{ .gpa = testing.allocator, .undo_limit = 2 };
    defer input.deinit();
    try input.setValue("a");
    try input.setValue("b");
    try input.setValue("c");
    try testing.expect(input.undo());
    try testing.expect(input.undo());
    try testing.expect(!input.undo());
    try testing.expectEqualStrings("a", input.value());

    var off: Input = .{ .gpa = testing.allocator, .undo_limit = 0 };
    defer off.deinit();
    try off.setValue("a");
    try testing.expect(!off.undo());
    try testing.expectEqualStrings("a", off.value());
}
