//! The smallest `tui` application, for `zig build budget`: a yes/no question.

const std = @import("std");
const tui = @import("tui");

const Confirm = struct {
    answer: bool = false,

    pub fn update(model: *Confirm, msg: tui.Msg) tui.Cmd {
        const key = switch (msg) {
            .key => |key| key,
            else => return .none,
        };
        if (key.matches("y")) model.answer = true;
        if (key.matches("enter") or key.matches("y") or key.matches("n")) return .quit;
        return .none;
    }

    pub fn view(_: *const Confirm, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const accent: tui.Style = .{ .fg = .hex(0xff8700), .bold = true };
        try accent.paint(w, "? ");
        try w.writeAll("Continue? [y/N]\n");
    }
};

pub fn main(init: std.process.Init) !u8 {
    var buffer: [4096]u8 = undefined;
    var terminal: tui.Terminal = try .open(init.io, &buffer);
    defer terminal.close();
    const options: tui.Options = .{ .capability = terminal.capabilityIn(init.environ_map) };
    var model: Confirm = .{};
    var program: tui.Program(Confirm) = .init(init.gpa, &model, terminal.writer(), options);
    defer program.deinit();
    const outcome = try program.run(&terminal);
    return if (outcome.interrupted) 130 else @intFromBool(!model.answer);
}
