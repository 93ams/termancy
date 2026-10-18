//! Must not compile: a model whose `deinit` the test driver cannot call.

const std = @import("std");
const tui = @import("tui");

const Model = struct {
    pub fn update(_: *Model, _: tui.Msg) tui.Cmd {
        return .none;
    }
    pub fn view(_: *const Model, _: *std.Io.Writer) std.Io.Writer.Error!void {}
    pub fn deinit(model: *Model, extra: u8) void {
        _ = model;
        _ = extra;
    }
};

comptime {
    _ = &tui.testing.Driver(Model).deinit;
}
