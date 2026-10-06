const std = @import("std");
const style = @import("render").style;

// --- 1. Unified Focus Manager ---
pub const FocusManager = struct {
    total: usize,
    focused: usize = 0,

    pub fn init(total: usize) FocusManager {
        return .{ .total = total, .focused = 0 };
    }

    pub fn next(self: *FocusManager) void {
        if (self.total == 0) return;
        self.focused = (self.focused + 1) % self.total;
    }

    pub fn prev(self: *FocusManager) void {
        if (self.total == 0) return;
        if (self.focused == 0) {
            self.focused = self.total - 1;
        } else {
            self.focused -= 1;
        }
    }

    pub fn isFocused(self: FocusManager, index: usize) bool {
        return self.total > 0 and self.focused == index;
    }
};

// --- 2. System Clipboard Integration via OSC 52 ---
pub fn copyToClipboard(writer: anytype, text: []const u8, allocator: std.mem.Allocator) !void {
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(text.len);
    const b64_buf = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_buf);

    _ = encoder.encode(b64_buf, text);
    try writer.print("\x1b]52;c;{s}\x07", .{b64_buf});
}

// --- 3. Fuzzy Finder (fzf-style) ---
pub const FuzzyMatch = struct {
    score: isize,
    matched_indices: [32]usize = undefined,
    matched_count: usize = 0,
};

pub fn fuzzyScore(pattern: []const u8, target: []const u8) ?FuzzyMatch {
    if (pattern.len == 0) return .{ .score = 0 };
    if (pattern.len > target.len) return null;

    var match = FuzzyMatch{ .score = 0 };
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var prev_matched = false;

    while (p_idx < pattern.len and t_idx < target.len) {
        const p_char = std.ascii.toLower(pattern[p_idx]);
        const t_char = std.ascii.toLower(target[t_idx]);

        if (p_char == t_char) {
            if (match.matched_count < 32) {
                match.matched_indices[match.matched_count] = t_idx;
                match.matched_count += 1;
            }

            match.score += 10;
            if (prev_matched) match.score += 5; // Sequential bonus
            if (t_idx == 0 or target[t_idx - 1] == '/' or target[t_idx - 1] == '_' or target[t_idx - 1] == '-') {
                match.score += 10; // Word boundary bonus
            }

            p_idx += 1;
            prev_matched = true;
        } else {
            prev_matched = false;
        }
        t_idx += 1;
    }

    if (p_idx == pattern.len) {
        return match;
    }
    return null;
}

pub const FuzzyFinder = struct {
    items: []const []const u8,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    selected_idx: usize = 0,

    pub fn init(items: []const []const u8) FuzzyFinder {
        return .{
            .items = items,
        };
    }

    pub fn setQuery(self: *FuzzyFinder, q: []const u8) void {
        const len = @min(q.len, 64);
        @memcpy(self.query[0..len], q[0..len]);
        self.query_len = len;
        self.selected_idx = 0;
    }

    pub fn getQuery(self: *const FuzzyFinder) []const u8 {
        return self.query[0..self.query_len];
    }

    pub fn render(self: *const FuzzyFinder, writer: anytype, max_results: usize) !void {
        const q = self.getQuery();
        try writer.print("> {s}_\n", .{q});

        var count: usize = 0;
        for (self.items, 0..) |item, i| {
            if (count >= max_results) break;
            const maybe_score = fuzzyScore(q, item);
            if (maybe_score != null or q.len == 0) {
                const is_sel = (i == self.selected_idx);
                if (is_sel) {
                    try writer.print("\x1b[36;1m> {s}\x1b[0m\n", .{item});
                } else {
                    try writer.print("  {s}\n", .{item});
                }
                count += 1;
            }
        }
    }
};

// --- 4. Interactive Hotkey Overlay (? Modal) ---
pub const Keybinding = struct {
    key: []const u8,
    desc: []const u8,
};

pub fn renderHotkeyOverlay(writer: anytype, title: []const u8, bindings: []const Keybinding) !void {
    try writer.writeAll("\n\x1b[1m╭──────────────────────────────────────────────────╮\x1b[0m\n");
    try writer.print("\x1b[1m│  ⌨  {s:43.43} │\x1b[0m\n", .{title});
    try writer.writeAll("\x1b[1m├──────────────────────────┬───────────────────────┤\x1b[0m\n");
    for (bindings) |b| {
        try writer.print("│ \x1b[33m{s:24.24}\x1b[0m │ {s:21.21} │\n", .{ b.key, b.desc });
    }
    try writer.writeAll("\x1b[1m╰──────────────────────────┴───────────────────────╯\x1b[0m\n");
}

// --- 5. Live Form Engine with Input Masking ---
pub const FormFieldType = enum { text, password, number };

pub const FormField = struct {
    label: []const u8,
    field_type: FormFieldType = .text,
    value: [128]u8 = undefined,
    value_len: usize = 0,
    error_msg: ?[]const u8 = null,

    pub fn setValue(self: *FormField, text: []const u8) void {
        const len = @min(text.len, 128);
        @memcpy(self.value[0..len], text[0..len]);
        self.value_len = len;
    }

    pub fn getValue(self: *const FormField) []const u8 {
        return self.value[0..self.value_len];
    }
};

pub const Form = struct {
    fields: []FormField,
    focus: FocusManager,

    pub fn init(fields: []FormField) Form {
        return .{
            .fields = fields,
            .focus = FocusManager.init(fields.len),
        };
    }

    pub fn render(self: *const Form, writer: anytype) !void {
        for (self.fields, 0..) |*f, idx| {
            const is_focused = self.focus.isFocused(idx);
            const prefix = if (is_focused) "\x1b[36m▶ \x1b[1m" else "  ";
            try writer.print("{s}{s}:\x1b[0m ", .{ prefix, f.label });

            if (f.field_type == .password) {
                for (0..f.value_len) |_| try writer.writeAll("*");
            } else {
                try writer.writeAll(f.getValue());
            }

            if (is_focused) {
                try writer.writeAll("▏");
            }

            if (f.error_msg) |err| {
                try writer.print(" \x1b[31m({s})\x1b[0m", .{err});
            }
            try writer.writeAll("\n");
        }
    }
};
