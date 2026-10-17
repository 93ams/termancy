//! The tape language: the commands `snek cli record` runs, the same as vhs's, so tapes
//! written for vhs run here.
//!
//! ```
//! Output demo.gif
//! Set FontSize 22
//! Set Theme "Catppuccin Mocha"
//! Type "snek --help"
//! Sleep 500ms
//! Enter
//! Wait /\$ $/
//! Sleep 2s
//! ```
//!
//! Commands: `Output <path>`, `Require <program>`, `Set <setting> <value>`, `Type[@time]
//! "text"`, the keys (`Enter`, `Backspace`, `Tab`, `Space`, `Escape`, `Up`, `Down`,
//! `Left`, `Right`, `PageUp`, `PageDown`, `Home`, `End`, `Delete`, `Insert`, `Ctrl+<key>`,
//! `Alt+<key>`, `Shift+<key>`, each with an optional `@time` and repeat count), `Sleep
//! <time>`, `Wait[+Screen|+Line][@timeout] [/regex/]`, `Hide`, `Show`, `Screenshot
//! <path>`, `Copy "text"`, `Paste`, `Env <name> "value"`, and `Source <tape>`. Times are
//! `500ms`, `2s`, `1m`, or a bare number of seconds. Lines starting with `#` are comments.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Duration = std.Io.Duration;

pub const Command = union(enum) {
    output: []const u8,
    require: []const u8,
    set: Setting,
    type: struct { text: []const u8, speed: ?Duration },
    key: struct { key: Key, speed: ?Duration, count: u32 },
    sleep: Duration,
    wait: struct { scope: WaitScope, timeout: ?Duration, pattern: ?[]const u8 },
    hide,
    show,
    screenshot: []const u8,
    copy: []const u8,
    paste,
    env: struct { name: []const u8, value: []const u8 },
    source: []const u8,
};

pub const WaitScope = enum { line, screen };

pub const Key = union(enum) {
    named: Named,
    ctrl: u8,
    alt: u8,
    shift: u8,

    pub const Named = enum {
        enter,
        backspace,
        tab,
        space,
        escape,
        up,
        down,
        left,
        right,
        page_up,
        page_down,
        home,
        end,
        delete,
        insert,
    };

    /// The bytes a terminal sends for the key.
    pub fn bytes(key: Key, buffer: *[8]u8) []const u8 {
        switch (key) {
            .named => |n| return switch (n) {
                .enter => "\r",
                .backspace => "\x7f",
                .tab => "\t",
                .space => " ",
                .escape => "\x1b",
                .up => "\x1b[A",
                .down => "\x1b[B",
                .right => "\x1b[C",
                .left => "\x1b[D",
                .page_up => "\x1b[5~",
                .page_down => "\x1b[6~",
                .home => "\x1b[H",
                .end => "\x1b[F",
                .delete => "\x1b[3~",
                .insert => "\x1b[2~",
            },
            .ctrl => |c| {
                buffer[0] = switch (c) {
                    'a'...'z' => c - 'a' + 1,
                    '@' => 0,
                    '[' => 0x1b,
                    '\\' => 0x1c,
                    ']' => 0x1d,
                    '^' => 0x1e,
                    '_' => 0x1f,
                    else => c & 0x1f,
                };
                return buffer[0..1];
            },
            .alt => |c| {
                buffer[0] = 0x1b;
                buffer[1] = c;
                return buffer[0..2];
            },
            .shift => |c| {
                buffer[0] = std.ascii.toUpper(c);
                return buffer[0..1];
            },
        }
    }
};

pub const Setting = union(enum) {
    shell: []const u8,
    font_family: []const u8,
    font_size: f32,
    letter_spacing: f32,
    line_height: f32,
    /// The picture's size in pixels (the terminal's columns and rows follow from it).
    width: u32,
    height: u32,
    /// The terminal's size in cells, instead of the picture's in pixels.
    columns: u16,
    rows: u16,
    padding: u32,
    margin: u32,
    margin_fill: []const u8,
    window_bar: []const u8,
    window_bar_size: u32,
    border_radius: u32,
    theme: []const u8,
    typing_speed: Duration,
    framerate: u32,
    playback_speed: f32,
    loop_offset: f32,
    cursor_blink: bool,
    wait_timeout: Duration,
    wait_pattern: []const u8,
    title: []const u8,
    shadow: bool,
};

/// A command and the line it came from.
pub const Line = struct { number: u32, command: Command };

pub const Error = error{ParseFailed} || Allocator.Error;

/// Where parsing failed, and why.
pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

/// Parses `source` into commands; strings point into `source` or `arena`.
pub fn parse(arena: Allocator, source: []const u8, diag: *Diagnostic) Error![]const Line {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (it.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        diag.line = number;
        const command = parseLine(arena, line, diag) catch |err| switch (err) {
            error.ParseFailed => return err,
            error.OutOfMemory => return err,
        };
        try lines.append(arena, .{ .number = number, .command = command });
    }
    return lines.items;
}

fn fail(diag: *Diagnostic, message: []const u8) error{ParseFailed} {
    diag.message = message;
    return error.ParseFailed;
}

fn parseLine(arena: Allocator, line: []const u8, diag: *Diagnostic) Error!Command {
    var words: Words = .{ .text = line };
    const head = words.word() orelse return fail(diag, "an empty command");
    // `Type@100ms`, `Ctrl+C`, `Wait+Screen@5s`.
    const at = std.mem.indexOfScalar(u8, head, '@');
    const name_and_mods = head[0 .. at orelse head.len];
    const speed = if (at) |a| try duration(head[a + 1 ..], diag) else null;
    var parts = std.mem.splitScalar(u8, name_and_mods, '+');
    const name = parts.next().?;

    if (eql(name, "Output")) return .{
        .output = try words.rest(arena, diag, "Output needs a path"),
    };
    if (eql(name, "Require")) return .{
        .require = try words.rest(arena, diag, "Require needs a program"),
    };
    if (eql(name, "Screenshot")) return .{
        .screenshot = try words.rest(arena, diag, "Screenshot needs a path"),
    };
    if (eql(name, "Source")) return .{
        .source = try words.rest(arena, diag, "Source needs a tape"),
    };
    if (eql(name, "Hide")) return .hide;
    if (eql(name, "Show")) return .show;
    if (eql(name, "Paste")) return .paste;
    if (eql(name, "Copy")) return .{
        .copy = try words.string(arena, diag) orelse return fail(diag, "Copy needs \"text\""),
    };
    if (eql(name, "Sleep")) {
        const value = words.word() orelse return fail(diag, "Sleep needs a time");
        return .{ .sleep = try requiredDuration(value, diag) };
    }
    if (eql(name, "Type")) {
        var text: std.ArrayList(u8) = .empty;
        // Type "a" "b" types both.
        while (try words.string(arena, diag)) |piece| try text.appendSlice(arena, piece);
        if (text.items.len == 0 and words.done()) return fail(diag, "Type needs \"text\"");
        if (!words.done()) return fail(diag, "Type takes quoted text");
        return .{ .type = .{ .text = text.items, .speed = speed } };
    }
    if (eql(name, "Env")) {
        const key = words.word() orelse return fail(diag, "Env needs a name and a value");
        const value = try words.string(arena, diag) orelse words.word() orelse return fail(
            diag,
            "Env needs a value",
        );
        return .{ .env = .{ .name = key, .value = value } };
    }
    if (eql(name, "Wait")) {
        var scope: WaitScope = .line;
        if (parts.next()) |which| {
            if (eql(which, "Screen"))
                scope = .screen
            else if (eql(which, "Line"))
                scope = .line
            else
                return fail(diag, "Wait+Line or Wait+Screen");
        }
        const rest = std.mem.trim(u8, words.text[words.at..], " \t");
        var pattern: ?[]const u8 = null;
        if (rest.len > 0) {
            if (rest.len < 2 or rest[0] != '/' or rest[rest.len - 1] != '/') return fail(
                diag,
                "Wait takes a /regular expression/",
            );
            pattern = rest[1 .. rest.len - 1];
        }
        return .{ .wait = .{ .scope = scope, .timeout = speed, .pattern = pattern } };
    }
    if (eql(name, "Set")) return .{ .set = try setting(arena, &words, diag) };
    // Keys, with modifiers and a repeat count.
    const key: Key = if (eql(name, "Ctrl") or eql(name, "Alt") or eql(name, "Shift")) blk: {
        const target = parts.next() orelse return fail(diag, "a modifier needs a key: Ctrl+C");
        const c: u8 = if (target.len == 1)
            std.ascii.toLower(target[0])
        else if (eql(target, "Space"))
            ' '
        else if (eql(target, "Enter"))
            '\r'
        else if (eql(target, "Backspace"))
            0x7f
        else
            return fail(diag, "a modifier takes one character: Ctrl+C");
        break :blk if (eql(name, "Ctrl"))
            .{ .ctrl = c }
        else if (eql(name, "Alt"))
            .{ .alt = c }
        else
            .{ .shift = c };
    } else .{ .named = namedKey(name) orelse return fail(diag, "an unknown command") };
    var count: u32 = 1;
    if (words.word()) |n| count = std.fmt.parseInt(u32, n, 10) catch return fail(
        diag,
        "a key takes a repeat count",
    );
    return .{ .key = .{ .key = key, .speed = speed, .count = count } };
}

fn namedKey(name: []const u8) ?Key.Named {
    const names = [_]struct { []const u8, Key.Named }{
        .{ "Enter", .enter },    .{ "Backspace", .backspace }, .{ "Tab", .tab },
        .{ "Space", .space },    .{ "Escape", .escape },       .{ "Up", .up },
        .{ "Down", .down },      .{ "Left", .left },           .{ "Right", .right },
        .{ "PageUp", .page_up }, .{ "PageDown", .page_down },  .{ "Home", .home },
        .{ "End", .end },        .{ "Delete", .delete },       .{ "Insert", .insert },
    };
    for (names) |n| if (eql(n[0], name)) return n[1];
    return null;
}

fn setting(arena: Allocator, words: *Words, diag: *Diagnostic) Error!Setting {
    const name = words.word() orelse return fail(diag, "Set needs a setting");
    const value = (try words.string(arena, diag)) orelse words.word() orelse return fail(
        diag,
        "Set needs a value",
    );
    const S = Setting;
    const float = struct {
        fn f(text: []const u8, d: *Diagnostic) error{ParseFailed}!f32 {
            return std.fmt.parseFloat(
                f32,
                std.mem.trimEnd(u8, text, "%"),
            ) catch fail(d, "a number");
        }
    }.f;
    const int = struct {
        fn f(text: []const u8, d: *Diagnostic) error{ParseFailed}!u32 {
            return std.fmt.parseInt(
                u32,
                std.mem.trimEnd(u8, text, "px"),
                10,
            ) catch fail(d, "a whole number");
        }
    }.f;
    if (eql(name, "Shell")) return S{ .shell = value };
    if (eql(name, "FontFamily")) return S{ .font_family = value };
    if (eql(name, "FontSize")) return S{ .font_size = try float(value, diag) };
    if (eql(name, "LetterSpacing")) return S{ .letter_spacing = try float(value, diag) };
    if (eql(name, "LineHeight")) return S{ .line_height = try float(value, diag) };
    if (eql(name, "Width")) return S{ .width = try int(value, diag) };
    if (eql(name, "Height")) return S{ .height = try int(value, diag) };
    if (eql(name, "Columns")) return S{ .columns = @intCast(@min(try int(value, diag), 1000)) };
    if (eql(name, "Rows")) return S{ .rows = @intCast(@min(try int(value, diag), 1000)) };
    if (eql(name, "Padding")) return S{ .padding = try int(value, diag) };
    if (eql(name, "Margin")) return S{ .margin = try int(value, diag) };
    if (eql(name, "MarginFill")) return S{ .margin_fill = value };
    if (eql(name, "WindowBar")) return S{ .window_bar = value };
    if (eql(name, "WindowBarSize")) return S{ .window_bar_size = try int(value, diag) };
    if (eql(name, "BorderRadius")) return S{ .border_radius = try int(value, diag) };
    if (eql(name, "Theme")) {
        // A JSON theme runs to the end of the line.
        if (value[0] == '{') return S{
            .theme = std.mem.trim(u8, words.text[words.at - value.len ..], " "),
        };
        return S{ .theme = value };
    }
    if (eql(name, "TypingSpeed")) return S{ .typing_speed = try requiredDuration(value, diag) };
    if (eql(name, "Framerate")) return S{ .framerate = @max(1, @min(try int(value, diag), 100)) };
    if (eql(name, "PlaybackSpeed")) return S{ .playback_speed = try float(value, diag) };
    if (eql(name, "LoopOffset")) return S{ .loop_offset = try float(value, diag) };
    if (eql(name, "CursorBlink")) return S{ .cursor_blink = try boolean(value, diag) };
    if (eql(name, "WaitTimeout")) return S{ .wait_timeout = try requiredDuration(value, diag) };
    if (eql(name, "WaitPattern")) {
        const pattern = if (value.len >= 2 and value[0] == '/' and value[value.len - 1] == '/')
            value[1 .. value.len - 1]
        else
            value;
        return S{ .wait_pattern = pattern };
    }
    if (eql(name, "Title")) return S{ .title = value };
    if (eql(name, "Shadow")) return S{ .shadow = try boolean(value, diag) };
    return fail(diag, "an unknown setting");
}

fn boolean(text: []const u8, diag: *Diagnostic) error{ParseFailed}!bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return fail(diag, "true or false");
}

/// `500ms`, `2s`, `1.5s`, `1m`, or a bare number of seconds.
pub fn duration(text: []const u8, diag: *Diagnostic) error{ParseFailed}!?Duration {
    if (text.len == 0) return null;
    const units = [_]struct { []const u8, f64 }{ .{ "ms", 1e6 }, .{ "s", 1e9 }, .{ "m", 60e9 } };
    for (units) |unit| {
        if (std.mem.endsWith(u8, text, unit[0])) {
            const number = std.fmt.parseFloat(
                f64,
                text[0 .. text.len - unit[0].len],
            ) catch return fail(diag, "a time: 500ms, 2s");
            return try nanoseconds(number * unit[1], diag);
        }
    }
    const seconds = std.fmt.parseFloat(f64, text) catch return fail(diag, "a time: 500ms, 2s");
    return try nanoseconds(seconds * 1e9, diag);
}

/// A time that must be there (an empty quoted string is not one).
fn requiredDuration(text: []const u8, diag: *Diagnostic) error{ParseFailed}!Duration {
    return (try duration(text, diag)) orelse fail(diag, "a time: 500ms, 2s");
}

/// `ns` as a duration; a time that is negative, not a number, or longer than a year is
/// refused rather than converted (which would overflow).
fn nanoseconds(ns: f64, diag: *Diagnostic) error{ParseFailed}!Duration {
    if (!(ns >= 0 and ns <= 365 * std.time.ns_per_day)) return fail(diag, "a time: 500ms, 2s");
    return .fromNanoseconds(@intFromFloat(ns));
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Splits a line into words and quoted strings (`"..."`, `'...'`, or `` `...` ``, with
/// `\"`-style escapes in double quotes).
const Words = struct {
    text: []const u8,
    at: usize = 0,

    fn skip(w: *Words) void {
        while (w.at < w.text.len and (w.text[w.at] == ' ' or w.text[w.at] == '\t')) w.at += 1;
    }

    fn done(w: *Words) bool {
        w.skip();
        return w.at >= w.text.len;
    }

    fn word(w: *Words) ?[]const u8 {
        w.skip();
        if (w.at >= w.text.len) return null;
        if (std.mem.indexOfScalar(u8, "\"'`", w.text[w.at]) != null) return null;
        const start = w.at;
        while (w.at < w.text.len and w.text[w.at] != ' ' and w.text[w.at] != '\t') w.at += 1;
        return w.text[start..w.at];
    }

    fn string(w: *Words, arena: Allocator, diag: *Diagnostic) Error!?[]const u8 {
        w.skip();
        if (w.at >= w.text.len) return null;
        const quote = w.text[w.at];
        if (std.mem.indexOfScalar(u8, "\"'`", quote) == null) return null;
        var out: std.ArrayList(u8) = .empty;
        var i = w.at + 1;
        while (i < w.text.len and w.text[i] != quote) : (i += 1) {
            if (w.text[i] == '\\' and quote == '"' and i + 1 < w.text.len) {
                i += 1;
                try out.append(arena, switch (w.text[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    'e' => 0x1b,
                    else => w.text[i],
                });
                continue;
            }
            try out.append(arena, w.text[i]);
        }
        if (i >= w.text.len) return fail(diag, "an unterminated string");
        w.at = i + 1;
        return out.items;
    }

    /// The rest of the line (a path, which may be quoted).
    fn rest(w: *Words, arena: Allocator, diag: *Diagnostic, message: []const u8) Error![]const u8 {
        if (try w.string(arena, diag)) |s| return s;
        w.skip();
        const text = std.mem.trim(u8, w.text[w.at..], " \t");
        if (text.len == 0) return fail(diag, message);
        w.at = w.text.len;
        return text;
    }
};

const testing = std.testing;

test parse {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const lines = try parse(arena.allocator(),
        \\# a demo
        \\Output demo.gif
        \\Set FontSize 22
        \\Set Theme "Catppuccin Mocha"
        \\Set TypingSpeed 75ms
        \\Type@20ms "echo \"hi\"" " there"
        \\Enter
        \\Backspace 3
        \\Ctrl+C
        \\Sleep 1.5s
        \\Wait+Screen@3s /ready \d+/
        \\Wait
        \\Env GREETING "hello"
        \\Hide
        \\Screenshot shot.png
    , &diag);
    try testing.expectEqual(14, lines.len);
    try testing.expectEqualStrings("demo.gif", lines[0].command.output);
    try testing.expectEqual(22, lines[1].command.set.font_size);
    try testing.expectEqualStrings("Catppuccin Mocha", lines[2].command.set.theme);
    try testing.expectEqual(75 * std.time.ns_per_ms, lines[3].command.set.typing_speed.nanoseconds);
    try testing.expectEqualStrings("echo \"hi\" there", lines[4].command.type.text);
    try testing.expectEqual(20 * std.time.ns_per_ms, lines[4].command.type.speed.?.nanoseconds);
    try testing.expectEqual(Key.Named.enter, lines[5].command.key.key.named);
    try testing.expectEqual(3, lines[6].command.key.count);
    try testing.expectEqual('c', lines[7].command.key.key.ctrl);
    try testing.expectEqual(1500 * std.time.ns_per_ms, lines[8].command.sleep.nanoseconds);
    try testing.expectEqual(WaitScope.screen, lines[9].command.wait.scope);
    try testing.expectEqualStrings("ready \\d+", lines[9].command.wait.pattern.?);
    try testing.expectEqual(null, lines[10].command.wait.pattern);
    try testing.expectEqualStrings("hello", lines[11].command.env.value);
    try testing.expectEqual(15, lines[13].number);
}

test "errors name the line and the problem" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.ParseFailed,
        parse(arena.allocator(), "Type \"ok\"\nTipe \"x\"", &diag),
    );
    try testing.expectEqual(2, diag.line);
    try testing.expectEqualStrings("an unknown command", diag.message);
    try testing.expectError(error.ParseFailed, parse(arena.allocator(), "Sleep soon", &diag));
    try testing.expectError(error.ParseFailed, parse(arena.allocator(), "Type \"open", &diag));
    try testing.expectError(error.ParseFailed, parse(arena.allocator(), "Set Bogus 1", &diag));
}

test "keys are what a terminal sends" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("\x03", (Key{ .ctrl = 'c' }).bytes(&buffer));
    try testing.expectEqualStrings("\x1bb", (Key{ .alt = 'b' }).bytes(&buffer));
    try testing.expectEqualStrings("\x1b[A", (Key{ .named = .up }).bytes(&buffer));
}
