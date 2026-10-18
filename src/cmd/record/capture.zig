//! Capturing a tape from a real session, as vhs's `record`: a shell runs on a
//! pseudo-terminal inside this one, everything typed goes to it and is noted with when it
//! was typed, and when the shell exits the keystrokes are written as a tape: text as
//! `Type`, keys by name, and pauses as `Sleep`.

const std = @import("std");
const term = @import("term");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One read of input, and when.
pub const Keystroke = struct { bytes: []const u8, at_ns: i96 };

/// Runs `shell` until it exits; returns what was typed.
pub fn capture(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    shell: []const u8,
) ![]const Keystroke {
    var buffer: [4096]u8 = undefined;
    var terminal = try term.Terminal.open(io, &buffer);
    defer terminal.close();
    const size = terminal.size() catch term.Size{ .width = 80, .height = 24 };
    var env = try environ.clone(arena);
    try env.put("TERMANCY_RECORDING", "1");
    var pty = try term.Pty.spawn(io, gpa, .{ .argv = &.{shell}, .environ = &env, .size = size });
    defer pty.deinit();
    try terminal.enterRaw();
    defer terminal.restore();
    // Input is read on its own task: the shell ending (its output closing) is what ends
    // the capture, and the read blocked on the next key is then canceled.
    var keys: Keys = .{ .arena = arena, .start = Io.Timestamp.now(io, .awake) };
    var relay = try io.concurrent(relayInput, .{ io, &terminal, &pty, &keys });
    pumpOutput(&pty, &terminal);
    relay.cancel(io) catch {};
    _ = pty.wait() catch {};
    return keys.list.items;
}

const Keys = struct {
    arena: Allocator,
    start: Io.Timestamp,
    list: std.ArrayList(Keystroke) = .empty,
};

fn relayInput(io: Io, terminal: *term.Terminal, pty: *term.Pty, keys: *Keys) !void {
    var input: [1024]u8 = undefined;
    var data = [1][]u8{&input};
    while (true) {
        const n = try terminal.input.readStreaming(io, &data);
        if (n == 0) return;
        const at = Io.Timestamp.now(io, .awake).nanoseconds - keys.start.nanoseconds;
        const bytes = try keys.arena.dupe(u8, input[0..n]);
        try keys.list.append(keys.arena, .{ .bytes = bytes, .at_ns = at });
        try pty.write(input[0..n]);
    }
}

fn pumpOutput(pty: *term.Pty, terminal: *term.Terminal) void {
    var buffer: [8192]u8 = undefined;
    const w = terminal.writer();
    while (true) {
        const n = pty.read(&buffer) catch return;
        if (n == 0) return;
        w.writeAll(buffer[0..n]) catch return;
        w.flush() catch return;
    }
}

/// Writes keystrokes as tape commands: printable runs as `Type`, keys by name (repeats
/// counted), and pauses of 300ms or more as `Sleep`.
pub fn writeTape(w: *Io.Writer, keys: []const Keystroke) Io.Writer.Error!void {
    var text: std.ArrayList(u8) = .empty;
    var text_buffer: [4096]u8 = undefined;
    text = .initBuffer(&text_buffer);
    // The wait before the first key is the shell starting, not a pause.
    var last_at: i96 = if (keys.len > 0) keys[0].at_ns else 0;
    var pending_key: ?[]const u8 = null;
    var pending_count: u32 = 0;
    for (keys) |key| {
        const pause = key.at_ns - last_at;
        last_at = key.at_ns;
        if (pause >= 300 * std.time.ns_per_ms) {
            try flushKey(w, &pending_key, &pending_count);
            try flushText(w, &text);
            try w.print("Sleep {d}ms\n", .{@divTrunc(pause, std.time.ns_per_ms)});
        }
        var i: usize = 0;
        while (i < key.bytes.len) {
            const name, const len = keyName(key.bytes[i..]);
            if (name) |n| {
                try flushText(w, &text);
                if (pending_key) |p| {
                    if (std.mem.eql(u8, p, n)) {
                        pending_count += 1;
                        i += len;
                        continue;
                    }
                    try flushKey(w, &pending_key, &pending_count);
                }
                pending_key = n;
                pending_count = 1;
            } else {
                try flushKey(w, &pending_key, &pending_count);
                if (text.items.len + len > text.capacity) try flushText(w, &text);
                text.appendSliceAssumeCapacity(key.bytes[i..][0..len]);
            }
            i += len;
        }
    }
    try flushKey(w, &pending_key, &pending_count);
    try flushText(w, &text);
}

fn flushText(w: *Io.Writer, text: *std.ArrayList(u8)) Io.Writer.Error!void {
    if (text.items.len == 0) return;
    try w.writeAll("Type \"");
    for (text.items) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"\n");
    text.clearRetainingCapacity();
}

fn flushKey(w: *Io.Writer, key: *?[]const u8, count: *u32) Io.Writer.Error!void {
    const name = key.* orelse return;
    if (count.* > 1)
        try w.print("{s} {d}\n", .{ name, count.* })
    else
        try w.print("{s}\n", .{name});
    key.* = null;
    count.* = 0;
}

/// The tape name of the key at the start of `bytes` (and its length), or null for text.
fn keyName(bytes: []const u8) struct { ?[]const u8, usize } {
    const sequences = [_]struct { []const u8, []const u8 }{
        .{ "\x1b[A", "Up" },      .{ "\x1b[B", "Down" },      .{ "\x1b[C", "Right" },
        .{ "\x1b[D", "Left" },    .{ "\x1bOA", "Up" },        .{ "\x1bOB", "Down" },
        .{ "\x1bOC", "Right" },   .{ "\x1bOD", "Left" },      .{ "\x1b[H", "Home" },
        .{ "\x1b[F", "End" },     .{ "\x1b[3~", "Delete" },   .{ "\x1b[2~", "Insert" },
        .{ "\x1b[5~", "PageUp" }, .{ "\x1b[6~", "PageDown" },
    };
    for (sequences) |s| if (std.mem.startsWith(u8, bytes, s[0])) return .{ s[1], s[0].len };
    const c = bytes[0];
    switch (c) {
        '\r', '\n' => return .{ "Enter", 1 },
        0x7f, 0x08 => return .{ "Backspace", 1 },
        '\t' => return .{ "Tab", 1 },
        0x1b => {
            if (bytes.len > 1 and bytes[1] >= 0x20 and bytes[1] < 0x7f)
                return .{ altName(bytes[1]), 2 };
            return .{ "Escape", 1 };
        },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => return .{ ctrlName(c), 1 },
        else => {},
    }
    const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
    return .{ null, @min(len, bytes.len) };
}

fn ctrlName(c: u8) []const u8 {
    const names = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var list: [26][]const u8 = undefined;
        for (&list, 0..) |*n, i| n.* = std.fmt.comptimePrint("Ctrl+{c}", .{'A' + i});
        break :blk list;
    };
    return names[c - 1];
}

fn altName(c: u8) []const u8 {
    const names = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var list: [0x5f][]const u8 = undefined;
        for (&list, 0..) |*n, i| n.* = std.fmt.comptimePrint("Alt+{c}", .{0x20 + i});
        break :blk list;
    };
    return names[c - 0x20];
}

const testing = std.testing;

test writeTape {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const ms = std.time.ns_per_ms;
    try writeTape(&out.writer, &.{
        .{ .bytes = "l", .at_ns = 10 * ms },
        .{ .bytes = "s \"a\"", .at_ns = 50 * ms },
        .{ .bytes = "\r", .at_ns = 90 * ms },
        .{ .bytes = "\x1b[A", .at_ns = 900 * ms },
        .{ .bytes = "\x1b[A\x7f\x7f", .at_ns = 950 * ms },
        .{ .bytes = "\x03\x1bb", .at_ns = 1000 * ms },
    });
    try testing.expectEqualStrings(
        \\Type "ls \"a\""
        \\Enter
        \\Sleep 810ms
        \\Up 2
        \\Backspace 2
        \\Ctrl+C
        \\Alt+b
        \\
    , out.written());
}
