const std = @import("std");
const builtin = @import("builtin");

const Self = @This();
pub fn getTtyInPath() []const u8 {
    if (builtin.os.tag == .windows) {
        return "CONIN$";
    } else {
        return "/dev/tty";
    }
}

pub fn getTtyOutPath() []const u8 {
    if (builtin.os.tag == .windows) {
        return "CONOUT$";
    } else {
        return "/dev/tty";
    }
}

pub fn openTtyIn(io: std.Io) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, getTtyInPath(), .{ .mode = .read_only });
}

pub fn openTtyOut(io: std.Io) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, getTtyOutPath(), .{ .mode = .write_only });
}
