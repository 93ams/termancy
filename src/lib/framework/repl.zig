const std = @import("std");

pub const AutocompleteFn = *const fn (prefix: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8;

pub const ReplState = struct {
    prompt: []const u8 = "snek> ",
    running: bool = true,
    history: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ReplState {
        return .{
            .history = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReplState) void {
        for (self.history.items) |h| {
            self.allocator.free(h);
        }
        self.history.deinit(self.allocator);
    }

    pub fn addHistory(self: *ReplState, line: []const u8) !void {
        if (line.len == 0) return;
        const duped = try self.allocator.dupe(u8, line);
        try self.history.append(self.allocator, duped);
    }

    pub fn stop(self: *ReplState) void {
        self.running = false;
    }

    /// Autocomplete output hijacking: intercepts TAB query and returns candidate completions
    pub fn getCompletions(
        self: ReplState,
        prefix: []const u8,
        candidates: []const []const u8,
        arena: std.mem.Allocator,
    ) ![]const []const u8 {
        _ = self;
        var matches = std.ArrayList([]const u8).empty;
        defer matches.deinit(arena);

        for (candidates) |cand| {
            if (std.mem.startsWith(u8, cand, prefix)) {
                try matches.append(arena, try arena.dupe(u8, cand));
            }
        }
        return try arena.dupe([]const u8, matches.items);
    }
};
