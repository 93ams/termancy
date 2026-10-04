const std = @import("std");

pub const ColorProfile = enum {
    ascii,
    ansi16,
    ansi256,
    truecolor,
};

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn distanceSq(self: RGB, other: RGB) u32 {
        const dr: i32 = @as(i32, self.r) - @as(i32, other.r);
        const dg: i32 = @as(i32, self.g) - @as(i32, other.g);
        const db: i32 = @as(i32, self.b) - @as(i32, other.b);
        return @intCast(dr * dr + dg * dg + db * db);
    }

    /// Downsamples 24-bit RGB to closest standard 16-color ANSI code (0..15)
    pub fn toAnsi16(self: RGB) u8 {
        const standard_colors = [16]RGB{
            .{ .r = 0, .g = 0, .b = 0 }, // 0: Black
            .{ .r = 128, .g = 0, .b = 0 }, // 1: Red
            .{ .r = 0, .g = 128, .b = 0 }, // 2: Green
            .{ .r = 128, .g = 128, .b = 0 }, // 3: Yellow
            .{ .r = 0, .g = 0, .b = 128 }, // 4: Blue
            .{ .r = 128, .g = 0, .b = 128 }, // 5: Magenta
            .{ .r = 0, .g = 128, .b = 128 }, // 6: Cyan
            .{ .r = 192, .g = 192, .b = 192 }, // 7: White
            .{ .r = 128, .g = 128, .b = 128 }, // 8: Bright Black
            .{ .r = 255, .g = 0, .b = 0 }, // 9: Bright Red
            .{ .r = 0, .g = 255, .b = 0 }, // 10: Bright Green
            .{ .r = 255, .g = 255, .b = 0 }, // 11: Bright Yellow
            .{ .r = 0, .g = 0, .b = 255 }, // 12: Bright Blue
            .{ .r = 255, .g = 0, .b = 255 }, // 13: Bright Magenta
            .{ .r = 0, .g = 255, .b = 255 }, // 14: Bright Cyan
            .{ .r = 255, .g = 255, .b = 255 }, // 15: Bright White
        };

        var best_idx: u8 = 0;
        var min_dist: u32 = std.math.maxInt(u32);
        for (standard_colors, 0..) |col, idx| {
            const dist = self.distanceSq(col);
            if (dist < min_dist) {
                min_dist = dist;
                best_idx = @intCast(idx);
            }
        }
        return best_idx;
    }

    /// Downsamples 24-bit RGB to closest 256-color palette index (16..231 cube or 232..255 gray)
    pub fn toAnsi256(self: RGB) u8 {
        // Check 6x6x6 color cube
        const r_idx: u8 = @intCast((@as(u16, self.r) * 5 + 127) / 255);
        const g_idx: u8 = @intCast((@as(u16, self.g) * 5 + 127) / 255);
        const b_idx: u8 = @intCast((@as(u16, self.b) * 5 + 127) / 255);
        return 16 + 36 * r_idx + 6 * g_idx + b_idx;
    }
};

pub const ColorEngine = struct {
    pub fn detectProfile(env_map: *const std.process.Environ.Map) ColorProfile {
        if (env_map.get("NO_COLOR") != null) return .ascii;
        if (env_map.get("COLORTERM")) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
                return .truecolor;
            }
        }
        if (env_map.get("TERM")) |term| {
            if (std.mem.indexOf(u8, term, "256color") != null) return .ansi256;
            if (std.mem.eql(u8, term, "dumb")) return .ascii;
        }
        return .ansi16;
    }

    pub fn formatFg(writer: anytype, rgb: RGB, profile: ColorProfile) !void {
        switch (profile) {
            .ascii => {},
            .truecolor => {
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
            },
            .ansi256 => {
                const code = rgb.toAnsi256();
                try writer.print("\x1b[38;5;{d}m", .{code});
            },
            .ansi16 => {
                const code = rgb.toAnsi16();
                if (code < 8) {
                    try writer.print("\x1b[{d}m", .{30 + code});
                } else {
                    try writer.print("\x1b[{d}m", .{90 + (code - 8)});
                }
            },
        }
    }
};
