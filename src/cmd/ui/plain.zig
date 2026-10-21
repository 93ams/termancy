//! Plain prompts for the interactive commands, for screen readers and terminals that
//! cannot redraw: with `ACCESSIBLE` set to a true value (as huh's accessible mode), a
//! question is a line of text, choices are numbered, and the answer is a typed line.
//! Nothing is redrawn, erased, or colored, so every line can be read aloud as it comes.

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const term = @import("term.zig");
const Io = std.Io;

/// Whether `ACCESSIBLE` asks for plain prompts.
pub fn wanted(ctx: *const cli.Context) bool {
    const value = ctx.environ.get("ACCESSIBLE") orelse return false;
    return cli.Flag.parseBool(value) orelse (value.len > 0);
}

/// The terminal's lines: questions out, answers in.
pub const Session = struct {
    ctx: *cli.Context,
    terminal: tui.Terminal,
    out_buffer: [1024]u8 = undefined,
    in_buffer: [1024]u8 = undefined,
    reader: Io.File.Reader = undefined,

    /// Opens the terminal (as the drawing commands do); fails with a usage error without
    /// one. `session` must not move afterwards.
    pub fn open(session: *Session, ctx: *cli.Context) !void {
        session.ctx = ctx;
        session.terminal = tui.Terminal.open(ctx.io, &session.out_buffer) catch |err| switch (err) {
            error.NotATerminal => return term.noTerminal(ctx),
            error.Canceled => return error.Canceled,
        };
        session.reader = session.terminal.input.readerStreaming(ctx.io, &session.in_buffer);
    }

    pub fn close(session: *Session) void {
        session.terminal.close();
    }

    fn out(session: *Session) *Io.Writer {
        return session.terminal.writer();
    }

    /// One answer to `label`, hidden when `secret`; null at the end of input.
    fn ask(session: *Session, label: []const u8, problem: ?[]const u8, secret: bool) !?[]const u8 {
        const flag: cli.Flag = .{
            .name = "answer",
            .field = "answer",
            .kind = .value,
            .secret = secret,
            .check = struct {
                fn any(_: []const u8) bool {
                    return true;
                }
            }.any,
        };
        return cli.prompt.line(.{
            .io = session.ctx.io,
            .arena = session.ctx.arena,
            .in = &session.reader.interface,
            .out = session.out(),
            .terminal = session.terminal.input,
            .label = label,
            .flag = &flag,
            .problem = problem,
        }) catch |err| switch (err) {
            error.EndOfStream => null,
            else => |e| e,
        };
    }

    /// The indexes of the items chosen: one, or (with `limit` above 1) up to `limit`,
    /// typed as numbers separated by spaces or commas. Null when the input ends.
    pub fn choose(
        session: *Session,
        header: []const u8,
        items: []const []const u8,
        limit: usize,
    ) !?[]const usize {
        const w = session.out();
        if (header.len > 0) try w.print("{s}\n", .{header});
        for (items, 1..) |item, n| try w.print("{d}) {s}\n", .{ n, item });
        const label = if (limit == 1)
            try std.fmt.allocPrint(session.ctx.arena, "Number (1-{d})", .{items.len})
        else
            try std.fmt.allocPrint(
                session.ctx.arena,
                "Numbers (1-{d}, up to {d})",
                .{ items.len, limit },
            );
        var problem: ?[]const u8 = null;
        while (true) {
            const answer = try session.ask(label, problem, false) orelse return null;
            problem = "Type the numbers of items in the list.";
            var chosen: std.ArrayList(usize) = .empty;
            var words = std.mem.tokenizeAny(u8, answer, " ,");
            const valid = while (words.next()) |word| {
                const n = std.fmt.parseInt(usize, word, 10) catch break false;
                if (n < 1 or n > items.len) break false;
                try chosen.append(session.ctx.arena, n - 1);
            } else chosen.items.len > 0 and chosen.items.len <= limit;
            if (valid) return chosen.items;
        }
    }

    /// Yes or no; an empty answer is `default`. Null when the input ends.
    pub fn confirm(session: *Session, question: []const u8, default: bool) !?bool {
        const label = try std.fmt.allocPrint(session.ctx.arena, "{s} ({s})", .{
            question,
            if (default) "Y/n" else "y/N",
        });
        var problem: ?[]const u8 = null;
        while (true) {
            const answer = try session.ask(label, problem, false) orelse return null;
            if (answer.len == 0) return default;
            if (cli.Flag.parseBool(answer)) |yes| return yes;
            if (std.ascii.eqlIgnoreCase(answer, "y")) return true;
            if (std.ascii.eqlIgnoreCase(answer, "n")) return false;
            problem = "Answer yes or no.";
        }
    }

    /// Lines of text, until an empty line twice in a row or the end of input (Ctrl-D at
    /// the start of a line): easy to type and to hear, with no key but enter and Ctrl-D.
    /// With nothing typed, `value`.
    pub fn text(
        session: *Session,
        header: []const u8,
        placeholder: []const u8,
        value: []const u8,
    ) ![]const u8 {
        const w = session.out();
        if (header.len > 0) try w.print("{s}\n", .{header});
        if (placeholder.len > 0) try w.print("({s})\n", .{placeholder});
        try w.writeAll("Type the text; an empty line twice, or Ctrl-D, ends it.\n");
        if (value.len > 0) try w.print("With nothing typed, it is:\n{s}\n", .{value});
        try w.flush();
        var lines: std.ArrayList(u8) = .empty;
        var empty_before = false;
        while (try session.reader.interface.takeDelimiter('\n')) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 and empty_before) break;
            empty_before = line.len == 0;
            try lines.appendSlice(session.ctx.arena, line);
            try lines.append(session.ctx.arena, '\n');
        }
        const typed = std.mem.trimEnd(u8, lines.items, "\n");
        return if (typed.len == 0) value else typed;
    }

    /// A line of text, hidden when `secret`; an empty answer is `value`. Null when the
    /// input ends.
    pub fn input(
        session: *Session,
        label: []const u8,
        value: []const u8,
        secret: bool,
    ) !?[]const u8 {
        const answer = try session.ask(label, null, secret) orelse return null;
        return if (answer.len == 0) value else answer;
    }
};
