const std = @import("std");

const Self = @This();
/// Securely zeroes out memory containing secrets to prevent exposure in core dumps or RAM inspection.
pub fn wipe(secret: []u8) void {
    @memset(secret, 0);
    // Ensure compiler barrier
    std.mem.doNotOptimizeAway(secret.ptr);
}

/// Redacts a secret string, leaving at most the first character visible if length allows.
pub fn redact(writer: anytype, secret: []const u8) !void {
    if (secret.len == 0) return;
    if (secret.len <= 4) {
        for (0..secret.len) |_| try writer.writeAll("*");
    } else {
        try writer.writeByte(secret[0]);
        for (1..secret.len - 1) |_| try writer.writeAll("*");
        try writer.writeByte(secret[secret.len - 1]);
    }
}
