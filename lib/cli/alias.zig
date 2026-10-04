const std = @import("std");

pub const AliasMap = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AliasMap {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AliasMap) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn set(self: *AliasMap, name: []const u8, command: []const u8) !void {
        const key = try self.allocator.dupe(u8, name);
        const val = try self.allocator.dupe(u8, command);
        if (self.map.fetchPut(key, val)) |old| {
            if (old) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        } else |_| {}
    }

    pub fn get(self: AliasMap, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    /// Parse git-style alias definitions from string content.
    /// Lines can be "key = value" or inside "[alias]" INI blocks.
    pub fn parseFromContent(self: *AliasMap, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var in_alias_section = true; // default to true if no sections

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

            if (line[0] == '[' and line[line.len - 1] == ']') {
                const section = line[1 .. line.len - 1];
                in_alias_section = std.mem.eql(u8, section, "alias");
                continue;
            }

            if (!in_alias_section) continue;

            if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                const key = std.mem.trim(u8, line[0..eq_pos], " \t");
                const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\"'");
                if (key.len > 0 and val.len > 0) {
                    try self.set(key, val);
                }
            }
        }
    }

    /// Resolve an argument slice through aliases.
    /// If args[0] is an alias, it expands the alias into tokens and appends the remaining args.
    /// Returns the expanded args slice allocated in `arena`.
    pub fn resolve(self: AliasMap, arena: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
        if (args.len == 0) return args;

        const alias_val = self.get(args[0]) orelse return args;

        var tokens = std.ArrayList([]const u8).empty;
        defer tokens.deinit(arena);

        var it = std.mem.tokenizeScalar(u8, alias_val, ' ');
        while (it.next()) |token| {
            try tokens.append(arena, try arena.dupe(u8, token));
        }

        for (args[1..]) |arg| {
            try tokens.append(arena, try arena.dupe(u8, arg));
        }

        return try arena.dupe([]const u8, tokens.items);
    }
};
