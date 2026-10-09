const std = @import("std");

pub const TaskbarState = enum(u8) {
    clear = 0,
    normal = 1,
    error_state = 2,
    indeterminate = 3,
    warning = 4,
};

pub const PaletteTheme = enum {
    dark,
    light,
};

const Self = @This();
// 1.1 Synchronized Output Protocol (Mode 2026 / 2025)
pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";

pub fn beginSync(writer: anytype) !void {
    try writer.writeAll(sync_begin);
}

pub fn endSync(writer: anytype) !void {
    try writer.writeAll(sync_end);
}

// 1.2 Native OS Taskbar / Dock Progress Reporting (OSC 9;4)
pub fn writeTaskbarProgress(writer: anytype, state: TaskbarState, progress_pct: u8) !void {
    const pct = @min(progress_pct, 100);
    try writer.print("\x1b]9;4;{d};{d}\x1b\\", .{ @backingInt(state), pct });
}

// 1.3 Adaptive Dynamic Palette Querying (OSC 11)
pub const query_bg = "\x1b]11;?\x1b\\";

/// Parse terminal RGB response for OSC 11: e.g. "rgb:rrrr/gggg/bbbb" or "rgb:rr/gg/bb"
pub fn parseRgbResponse(response: []const u8) ?struct { r: u8, g: u8, b: u8, theme: PaletteTheme } {
    const prefix = "rgb:";
    const idx = std.mem.indexOf(u8, response, prefix) orelse return null;
    const color_part = response[idx + prefix.len ..];

    var it = std.mem.splitScalar(u8, color_part, '/');
    const r_hex = it.next() orelse return null;
    const g_hex = it.next() orelse return null;
    const b_raw = it.next() orelse return null;

    // Strip any trailing escape characters
    var b_len: usize = 0;
    while (b_len < b_raw.len and ((b_raw[b_len] >= '0' and b_raw[b_len] <= '9') or (b_raw[b_len] >= 'a' and b_raw[b_len] <= 'f') or (b_raw[b_len] >= 'A' and b_raw[b_len] <= 'F'))) : (b_len += 1) {}
    const b_hex = b_raw[0..b_len];

    if (r_hex.len == 0 or g_hex.len == 0 or b_hex.len == 0) return null;

    // Take the top 2 hex characters if 4 are returned (e.g. "ffff" -> "ff")
    const r_slice = if (r_hex.len >= 2) r_hex[0..2] else r_hex;
    const g_slice = if (g_hex.len >= 2) g_hex[0..2] else g_hex;
    const b_slice = if (b_hex.len >= 2) b_hex[0..2] else b_hex;

    const r = std.fmt.parseInt(u8, r_slice, 16) catch return null;
    const g = std.fmt.parseInt(u8, g_slice, 16) catch return null;
    const b = std.fmt.parseInt(u8, b_slice, 16) catch return null;

    // ITU-R BT.601 luminance formula
    const lum = (299 * @as(u32, r) + 587 * @as(u32, g) + 114 * @as(u32, b)) / 1000;
    const theme: PaletteTheme = if (lum >= 128) .light else .dark;

    return .{ .r = r, .g = g, .b = b, .theme = theme };
}

// 1.4 Bracketed Paste Guard (Mode 2004)
pub const paste_enable = "\x1b[?2004h";
pub const paste_disable = "\x1b[?2004l";
pub const paste_start = "\x1b[200~";
pub const paste_end = "\x1b[201~";

pub fn isPastedInput(buf: []const u8) bool {
    return std.mem.startsWith(u8, buf, paste_start) and std.mem.endsWith(u8, buf, paste_end);
}

pub fn extractPastedContent(buf: []const u8) ?[]const u8 {
    if (!isPastedInput(buf)) return null;
    if (buf.len < paste_start.len + paste_end.len) return null;
    return buf[paste_start.len .. buf.len - paste_end.len];
}

// 1.5 Sub-Cell / Pixel-Level SGR Mouse Reporting (Mode 1016)
pub const mouse_pixel_enable = "\x1b[?1016h";
pub const mouse_pixel_disable = "\x1b[?1016l";
