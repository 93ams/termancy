const std = @import("std");

pub const StructFootprint = struct {
    name: []const u8,
    size: usize,
    alignment: usize,
    field_count: usize,
};

pub const FootprintAnalyzer = struct {
    pub fn analyze(comptime T: type) StructFootprint {
        return .{
            .name = @typeName(T),
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .field_count = if (@typeInfo(T) == .@"struct") std.meta.fields(T).len else 0,
        };
    }
};
