//! Terminal color themes for recordings and screenshots: the 16 ANSI colors, the
//! foreground and background, and the cursor. A set of well-known ones by name, or a theme
//! in vhs's JSON form: `{"black": "#000000", ..., "brightWhite": "#ffffff",
//! "background": "#1e1e2e", "foreground": "#cdd6f4", "cursor": "#f5e0dc"}`.

const std = @import("std");
const term = @import("term");
const Rgb = term.Color.Rgb;

pub const Theme = struct {
    name: []const u8,
    background: Rgb,
    foreground: Rgb,
    cursor: Rgb,
    /// black, red, green, yellow, blue, magenta, cyan, white, then the bright ones.
    palette: [16]Rgb,

    /// Applies the theme to a screen: its default colors and its palette.
    pub fn apply(t: *const Theme, screen: *term.vt.Screen) void {
        screen.background = t.background;
        screen.foreground = t.foreground;
        for (t.palette, 0..) |c, i| screen.palette[i] = c;
    }
};

fn hex(comptime text: []const u8) Rgb {
    const v = std.fmt.parseInt(u24, text[1..], 16) catch unreachable;
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

fn theme(
    comptime name: []const u8,
    comptime bg: []const u8,
    comptime fg: []const u8,
    comptime cursor: []const u8,
    comptime colors: [16][]const u8,
) Theme {
    @setEvalBranchQuota(100_000);
    var palette: [16]Rgb = undefined;
    for (colors, 0..) |c, i| palette[i] = hex(c);
    return .{
        .name = name,
        .background = hex(bg),
        .foreground = hex(fg),
        .cursor = hex(cursor),
        .palette = palette,
    };
}

/// The themes known by name. The first is the default.
pub const themes = [_]Theme{
    theme("Charm", "#171717", "#dddddd", "#ff5f87", .{
        "#000000", "#ff5f87", "#5fd787", "#ffd75f", "#5f87ff", "#af5fff", "#5fd7ff", "#dddddd",
        "#4d4d4d", "#ff87af", "#87ffaf", "#ffff87", "#87afff", "#d787ff", "#87ffff", "#ffffff",
    }),
    theme("Catppuccin Mocha", "#1e1e2e", "#cdd6f4", "#f5e0dc", .{
        "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
        "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
    }),
    theme("Catppuccin Latte", "#eff1f5", "#4c4f69", "#dc8a78", .{
        "#5c5f77", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#acb0be",
        "#6c6f85", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#bcc0cc",
    }),
    theme("Dracula", "#282a36", "#f8f8f2", "#f8f8f2", .{
        "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
    }),
    theme("Nord", "#2e3440", "#d8dee9", "#eceff4", .{
        "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
        "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
    }),
    theme("Tokyo Night", "#1a1b26", "#c0caf5", "#c0caf5", .{
        "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
        "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
    }),
    theme("Gruvbox Dark", "#282828", "#ebdbb2", "#ebdbb2", .{
        "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
        "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
    }),
    theme("Gruvbox Light", "#fbf1c7", "#3c3836", "#3c3836", .{
        "#fbf1c7", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#7c6f64",
        "#928374", "#9d0006", "#79740e", "#b57614", "#076678", "#8f3f71", "#427b58", "#3c3836",
    }),
    theme("One Dark", "#282c34", "#abb2bf", "#528bff", .{
        "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
        "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff",
    }),
    theme("Solarized Dark", "#002b36", "#839496", "#93a1a1", .{
        "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
        "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
    }),
    theme("Solarized Light", "#fdf6e3", "#657b83", "#586e75", .{
        "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
        "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
    }),
    theme("Monokai", "#272822", "#f8f8f2", "#f8f8f0", .{
        "#272822", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
        "#75715e", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5",
    }),
    theme("GitHub Dark", "#0d1117", "#c9d1d9", "#c9d1d9", .{
        "#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
        "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc",
    }),
    theme("GitHub Light", "#ffffff", "#24292f", "#24292f", .{
        "#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
        "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f",
    }),
    theme("Rose Pine", "#191724", "#e0def4", "#524f67", .{
        "#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
        "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
    }),
    theme("Kanagawa", "#1f1f28", "#dcd7ba", "#c8c093", .{
        "#16161d", "#c34043", "#76946a", "#c0a36e", "#7e9cd8", "#957fb8", "#6a9589", "#c8c093",
        "#727169", "#e82424", "#98bb6c", "#e6c384", "#7fb4ca", "#938aa9", "#7aa89f", "#dcd7ba",
    }),
    theme("Everforest Dark", "#2d353b", "#d3c6aa", "#d3c6aa", .{
        "#475258", "#e67e80", "#a7c080", "#dbbc7f", "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa",
        "#475258", "#e67e80", "#a7c080", "#dbbc7f", "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa",
    }),
    theme("Ayu Dark", "#0b0e14", "#bfbdb6", "#e6b450", .{
        "#11151c", "#ea6c73", "#7fd962", "#f9af4f", "#53bdfa", "#cda1fa", "#90e1c6", "#c7c7c7",
        "#686868", "#f07178", "#aad94c", "#ffb454", "#59c2ff", "#d2a6ff", "#95e6cb", "#ffffff",
    }),
    theme("Material", "#263238", "#eeffff", "#ffcc00", .{
        "#546e7a", "#ff5370", "#c3e88d", "#ffcb6b", "#82aaff", "#c792ea", "#89ddff", "#ffffff",
        "#546e7a", "#ff5370", "#c3e88d", "#ffcb6b", "#82aaff", "#c792ea", "#89ddff", "#ffffff",
    }),
    theme("Xterm", "#000000", "#e5e5e5", "#e5e5e5", .{
        "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
        "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
    }),
};

/// The theme with this name, ignoring case and spaces.
pub fn named(name: []const u8) ?*const Theme {
    for (&themes) |*t| if (term.fonts.sameName(t.name, name)) return t;
    return null;
}

/// A theme in vhs's JSON form; colors missing from it come from `base`.
pub fn parseJson(arena: std.mem.Allocator, json: []const u8, base: Theme) !Theme {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    if (value != .object) return error.InvalidTheme;
    var t = base;
    t.name = "custom";
    const keys = [16][]const u8{
        "black",      "red",           "green",       "yellow",      "blue",        "magenta",
        "cyan",       "white",         "brightBlack", "brightRed",   "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan",  "brightWhite",
    };
    for (keys, 0..) |key, i| if (color(value, key)) |c| {
        t.palette[i] = c;
    };
    if (color(value, "background")) |c| t.background = c;
    if (color(value, "foreground")) |c| t.foreground = c;
    if (color(value, "cursor")) |c| t.cursor = c;
    if (value.object.get("name")) |n| if (n == .string) {
        t.name = n.string;
    };
    return t;
}

fn color(value: std.json.Value, key: []const u8) ?Rgb {
    const v = value.object.get(key) orelse return null;
    if (v != .string) return null;
    const c = term.Color.parse(v.string) catch return null;
    return switch (c) {
        .rgb => |rgb| rgb,
        else => null,
    };
}

const testing = std.testing;

test "themes by name, and from JSON" {
    try testing.expectEqualStrings("Catppuccin Mocha", named("catppuccinmocha").?.name);
    try testing.expectEqual(null, named("nope"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try parseJson(
        arena.allocator(),
        "{\"name\":\"mine\",\"red\":\"#ff0000\",\"background\":\"#101010\"}",
        themes[0],
    );
    try testing.expectEqualStrings("mine", t.name);
    try testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, t.palette[1]);
    try testing.expectEqual(Rgb{ .r = 16, .g = 16, .b = 16 }, t.background);
    try testing.expectEqual(themes[0].palette[2], t.palette[2]);
}
