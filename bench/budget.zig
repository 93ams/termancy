//! `zig build budget`: the size of the smallest `cli`, `cfg`, and `tui` applications
//! (`bench/budget/`, built ReleaseSmall and stripped), and how long the `cli` one takes to
//! print `--help`. Fails when a binary outgrows its budget or startup is slow, so that a
//! change that bloats every application built on the libraries is seen when it is made.
//!
//! Arguments: `name=path` for each binary; the one named `cli` is also timed.

const std = @import("std");

/// Bytes each binary may take on x86_64 Linux, about a fifth above its size when the budget
/// was set (cli 346176, cfg 433624, tui 230192 bytes). When a change grows a binary for a
/// good reason, raise its budget here, in the same change, to about 20% above the new size
/// `zig build budget` prints. Other systems' binaries differ; CI checks on Linux.
const budgets = [_]struct { []const u8, u64 }{
    .{ "cli", 416 * 1024 },
    .{ "cfg", 512 * 1024 },
    .{ "tui", 272 * 1024 },
};

/// How many times `--help` is run; the median counts.
const runs = 21;

/// The slowest median `--help` allowed. Generous: it catches startup work that grows with
/// the program (a table built at run time, a file read), not a slow machine.
const max_startup_ns = 50 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    var failed = false;
    var cli_path: ?[]const u8 = null;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.BadArgument;
        const name = arg[0..eq];
        const path = arg[eq + 1 ..];
        if (std.mem.eql(u8, name, "cli")) cli_path = path;
        const budget = for (budgets) |b| {
            if (std.mem.eql(u8, b[0], name)) break b[1];
        } else return error.NoBudget;
        const size = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
        const over = size > budget;
        failed = failed or over;
        try out.print("{s:<4} {d:>7} bytes  budget {d:>7}  {s}\n", .{
            name, size, budget, if (over) "OVER BUDGET" else "ok",
        });
    }

    if (cli_path) |path| {
        var times: [runs]u64 = undefined;
        for (&times) |*t| {
            const start: std.Io.Timestamp = .now(io, .awake);
            const result = try std.process.run(gpa, io, .{ .argv = &.{ path, "--help" } });
            t.* = @intCast(@max(start.untilNow(io, .awake).toNanoseconds(), 0));
            gpa.free(result.stdout);
            gpa.free(result.stderr);
            if (result.term != .exited or result.term.exited != 0) return error.HelpFailed;
        }
        std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
        const median = times[runs / 2];
        const slow = median > max_startup_ns;
        failed = failed or slow;
        try out.print("cli --help: median {d:.2}ms of {d} runs, limit {d}ms  {s}\n", .{
            @as(f64, @floatFromInt(median)) / std.time.ns_per_ms,
            runs,
            max_startup_ns / std.time.ns_per_ms,
            if (slow) "TOO SLOW" else "ok",
        });
    }
    try out.flush();
    return @intFromBool(failed);
}
