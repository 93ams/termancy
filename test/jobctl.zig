//! `jobctl <command>...`: runs the command as a shell with job control runs a job, in a
//! process group of its own in the terminal's foreground; when the command stops (Ctrl-Z),
//! takes the terminal back and continues the command in the foreground, as `fg` does.
//! Exits as the command did. For testing suspend and resume without a shell's job
//! control, which bash under macOS's `script` does not do. Standard input is the terminal.

const std = @import("std");
const c = std.c;
const posix = std.posix;

extern "c" fn fork() c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn tcsetpgrp(fd: c_int, pgrp: c.pid_t) c_int;
extern "c" fn getpgrp() c.pid_t;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.Usage;
    const argv = try arena.allocSentinel(?[*:0]const u8, args.len - 1, null);
    for (args[1..], argv) |arg, *slot| slot.* = try arena.dupeSentinel(u8, arg, 0);

    // Giving the terminal away and back from the background would stop us otherwise.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TTOU, &ignore, null);

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        _ = tcsetpgrp(0, c.getpid());
        const default: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.TTOU, &default, null);
        _ = execvp(argv[0].?, argv);
        c._exit(127);
    }
    _ = c.setpgid(pid, pid);
    _ = tcsetpgrp(0, pid);
    while (true) {
        var status: c_int = 0;
        if (c.waitpid(pid, &status, c.W.UNTRACED) < 0) return error.WaitFailed;
        const s: u32 = @bitCast(status);
        if (c.W.IFSTOPPED(s)) {
            // As a shell does: the terminal back, then `fg`.
            _ = tcsetpgrp(0, getpgrp());
            _ = tcsetpgrp(0, pid);
            _ = c.kill(-pid, .CONT);
            continue;
        }
        _ = tcsetpgrp(0, getpgrp());
        if (c.W.IFEXITED(s)) return c.W.EXITSTATUS(s);
        return 128 + @as(u8, @intCast(@backingInt(c.W.TERMSIG(s))));
    }
}
