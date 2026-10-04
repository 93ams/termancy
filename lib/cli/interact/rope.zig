const std = @import("std");

pub const RopeBuffer = struct {
    lines: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RopeBuffer {
        return .{
            .lines = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RopeBuffer) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn appendLine(self: *RopeBuffer, text: []const u8) !void {
        const duped = try self.allocator.dupe(u8, text);
        try self.lines.append(self.allocator, duped);
    }

    pub fn insertLine(self: *RopeBuffer, index: usize, text: []const u8) !void {
        const idx = @min(index, self.lines.items.len);
        const duped = try self.allocator.dupe(u8, text);
        try self.lines.insert(self.allocator, idx, duped);
    }

    pub fn deleteLine(self: *RopeBuffer, index: usize) void {
        if (index < self.lines.items.len) {
            const old = self.lines.orderedRemove(index);
            self.allocator.free(old);
        }
    }

    pub fn getLine(self: RopeBuffer, index: usize) ?[]const u8 {
        if (index >= self.lines.items.len) return null;
        return self.lines.items[index];
    }

    pub fn lineCount(self: RopeBuffer) usize {
        return self.lines.items.len;
    }
};
