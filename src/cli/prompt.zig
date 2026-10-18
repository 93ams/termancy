//! Asking for a required flag that was not given, in an interactive run: a flag with
//! `.prompt = "Port"` in `meta` is asked for instead of being a usage error, and so is a
//! required typed positional with one (when every missing one has). `App.prompter` does the
//! asking; the default, `line`, reads one line. An app can draw the question with its own
//! `tui` components instead, so `cli` itself needs nothing beyond `std`.
//!
//! Prompting happens only when standard input and standard error are both terminals and the
//! run is not under CI (`terminal.interactive`). A piped or scripted run gets the usual
//! usage error (exit 2), which names the flag to pass.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Flag = @import("Flag.zig");
const Command = @import("Command.zig");

/// One question.
pub const Request = struct {
    io: Io,
    /// For the answer and anything else the prompter allocates.
    arena: Allocator,
    /// Where the answer comes from: the terminal.
    in: *Io.Reader,
    /// Where the question goes: standard error, so standard output stays the command's.
    out: *Io.Writer,
    /// The terminal itself, for a prompter that changes its modes (echo, raw input); null
    /// when there is none to change.
    terminal: ?Io.File = null,
    /// The flag's `.prompt`.
    label: []const u8,
    /// For a positional, a stand-in named after it, with its choices.
    flag: *const Flag,
    /// The positional asked for, or null for a flag.
    positional: ?*const Command.Positional = null,
    /// Why the previous answer was refused, when asking again.
    problem: ?[]const u8 = null,
};

/// Returns the answer, as it would be typed after the flag. An error abandons the run with
/// the usual missing-flag usage error.
pub const Prompter = *const fn (request: Request) anyerror![]const u8;

/// The default prompter: writes `label [a/b/c]: ` and reads one line. A secret flag's
/// answer is not echoed when `terminal` is set.
pub fn line(request: Request) anyerror![]const u8 {
    const out = request.out;
    if (request.problem) |problem| try out.print("{s}\n", .{problem});
    try out.writeAll(request.label);
    if (request.flag.choices.len > 0) {
        try out.writeAll(" [");
        for (request.flag.choices, 0..) |choice, i| {
            if (i > 0) try out.writeByte('/');
            try out.writeAll(choice);
        }
        try out.writeByte(']');
    }
    try out.writeAll(": ");
    try out.flush();
    const hide = request.flag.secret and request.terminal != null;
    const saved = if (hide) echoOff(request.io, request.terminal.?) else null;
    defer if (saved) |mode| {
        echoRestore(request.io, request.terminal.?, mode);
        out.writeByte('\n') catch {};
        out.flush() catch {};
    };
    // Null at the end of input (Ctrl-D): no answer.
    const text = try request.in.takeDelimiter('\n') orelse return error.EndOfStream;
    return request.arena.dupe(u8, std.mem.trim(u8, text, " \t\r"));
}

/// What `echoOff` changed, for `echoRestore`.
const Saved = switch (builtin.os.tag) {
    .windows => u32,
    .wasi, .freestanding => void,
    else => std.posix.termios,
};

fn echoOff(io: Io, file: Io.File) ?Saved {
    switch (builtin.os.tag) {
        .windows => {
            const user_io = std.os.windows.CONSOLE.USER_IO;
            var get = user_io.GET_MODE;
            const status = get.operate(io, file) catch return null;
            if (status != .SUCCESS) return null;
            const enable_echo_input: u32 = 0x0004;
            var set = user_io.SET_MODE(get.Data & ~enable_echo_input);
            _ = set.operate(io, file) catch return null;
            return get.Data;
        },
        .wasi, .freestanding => return null,
        else => {
            const saved = std.posix.tcgetattr(file.handle) catch return null;
            var quiet = saved;
            quiet.lflag.ECHO = false;
            std.posix.tcsetattr(file.handle, .FLUSH, quiet) catch return null;
            return saved;
        },
    }
}

fn echoRestore(io: Io, file: Io.File, saved: Saved) void {
    switch (builtin.os.tag) {
        .windows => {
            var set = std.os.windows.CONSOLE.USER_IO.SET_MODE(saved);
            _ = set.operate(io, file) catch {};
        },
        .wasi, .freestanding => {},
        else => std.posix.tcsetattr(file.handle, .FLUSH, saved) catch {},
    }
}
