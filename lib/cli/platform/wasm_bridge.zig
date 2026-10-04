const std = @import("std");

const Self = @This();
output_buffer: [65536]u8 = undefined,
output_len: usize = 0,

pub fn executeString(
    self: *Self,
    raw_cmd_line: []const u8,
    exec_fn: *const fn (argv: []const []const u8, writer: *std.Io.Writer) (std.mem.Allocator.Error || std.Io.Writer.Error)!void,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, raw_cmd_line, ' ');
    while (it.next()) |token| {
        try argv.append(allocator, token);
    }

    var writer = std.Io.Writer.fixed(&self.output_buffer);
    exec_fn(argv.items, &writer) catch |err| {
        try writer.print("Execution error: {s}\n", .{@errorName(err)});
    };
    self.output_len = self.output_buffer.len - writer.unusedCapacityLen();
    return self.output_buffer[0..self.output_len];
}
