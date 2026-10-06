const std = @import("std");

const Self = @This();
cancelled: std.atomic.Value(bool) = .init(false),

pub fn init() Self {
    return .{};
}

pub fn cancel(self: *Self) void {
    self.cancelled.store(true, .seq_cst);
}

pub fn isCancelled(self: *const Self) bool {
    return self.cancelled.load(.seq_cst);
}

pub fn reset(self: *Self) void {
    self.cancelled.store(false, .seq_cst);
}
