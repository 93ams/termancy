const std = @import("std");

pub const HeadlessTerminal = struct {
    aw: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) HeadlessTerminal {
        return .{
            .aw = std.Io.Writer.Allocating.init(allocator),
        };
    }

    pub fn deinit(self: *HeadlessTerminal) void {
        self.aw.deinit();
    }

    pub fn writer(self: *HeadlessTerminal) *std.Io.Writer {
        return &self.aw.writer;
    }

    pub fn getOutput(self: HeadlessTerminal) []const u8 {
        return self.aw.writer.buffer[0..self.aw.writer.end];
    }

    pub fn clear(self: *HeadlessTerminal) void {
        self.aw.writer.end = 0;
    }

    pub fn assertGolden(self: HeadlessTerminal, golden_text: []const u8) !void {
        const actual = std.mem.trim(u8, self.getOutput(), " \r\n");
        const expected = std.mem.trim(u8, golden_text, " \r\n");
        try std.testing.expectEqualStrings(expected, actual);
    }
};
