//! Coverage-guided fuzz test of the tape parser (`snek cli record`'s input). Its own test
//! root, as `tape.zig` needs nothing but `std`: `zig build fuzz --fuzz` explores it from the
//! seeds below, and `zig build unit` and a plain `zig build fuzz` replay them and
//! `regressions`.

const std = @import("std");
const testing = std.testing;
const tape = @import("tape.zig");

/// A parsed tape keeps its lines in order, numbered within the source; a failure names a
/// line of it and says why. Every key's bytes fit their buffer.
fn fuzzTape(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [8192]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const line_count = std.mem.countScalar(u8, source, '\n') + 1;
    var diag: tape.Diagnostic = .{};
    const lines = tape.parse(arena_state.allocator(), source, &diag) catch |err| switch (err) {
        error.ParseFailed => {
            try testing.expect(diag.line >= 1 and diag.line <= line_count);
            try testing.expect(diag.message.len > 0);
            return;
        },
        error.OutOfMemory => return err,
    };
    var previous: u32 = 0;
    for (lines) |line| {
        try testing.expect(line.number > previous and line.number <= line_count);
        previous = line.number;
        switch (line.command) {
            .key => |k| {
                var key_buffer: [8]u8 = undefined;
                try testing.expect(k.key.bytes(&key_buffer).len > 0);
            },
            else => {},
        }
    }
}

test "fuzz: tape" {
    try testing.fuzz({}, fuzzTape, .{ .corpus = comptime inputs(&(.{
        \\# a demo
        \\Output demo.gif
        \\Require git
        \\Set FontSize 22
        \\Set Theme "Catppuccin Mocha"
        \\Set TypingSpeed 75ms
        \\Set Width 1200
        \\Set Padding 20
        \\Type@20ms "echo \"hi\"" " there"
        \\Enter
        \\Backspace 3
        \\Ctrl+C
        \\Alt+x
        \\Up@100ms 2
        \\Sleep 1.5s
        \\Wait+Screen@3s /ready \d+/
        \\Wait+Line
        \\Env GREETING "hello"
        \\Copy "text"
        \\Paste
        \\Hide
        \\Show
        \\Screenshot shot.png
        \\Source other.tape
        ,
        "Sleep 1m\r\nSleep 500ms\nSleep 2\nType `back` 'single'\n\tTab@1s 4\n",
    } ++ regressions)) });
}

/// Inputs that once broke the parser.
const regressions = [_][]const u8{
    // Times too long for a duration, or not numbers, were converted anyway.
    "Enter@1e30s",          "Sleep nan",          "Sleep -inf", "Set TypingSpeed 1e300m",
    // An empty quoted time was taken for one that is there.
    "Set TypingSpeed \"\"", "Set WaitTimeout ''",
};

/// `docs` as fuzzer inputs: each a 4-byte little-endian length, then the bytes, which is
/// how `std.testing.Smith.slice` reads them.
fn inputs(docs: []const []const u8) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (docs) |doc| {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, doc.len));
        const input = len ++ doc[0..doc.len].*;
        out = out ++ .{&input};
    }
    return out;
}
