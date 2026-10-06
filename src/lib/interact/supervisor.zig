const std = @import("std");

pub const TerminalSupervisor = struct {
    // Sane terminal reset sequence: reset attributes, show cursor, soft terminal reset (DECSTR)
    pub const stty_sane_seq = "\x1b[0m\x1b[?25h\x1b[!p";

    pub fn restoreTerminalSanity(writer: anytype) !void {
        try writer.writeAll(stty_sane_seq);
    }
};
