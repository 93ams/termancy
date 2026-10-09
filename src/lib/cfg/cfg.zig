const std = @import("std");

/// Viper-style Configuration Manager backed by an ArenaAllocator to guarantee zero memory leaks.
pub fn Manager(comptime ConfigT: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        config: ConfigT,

        /// Initialize the config manager with default values.
        pub fn init(child_allocator: std.mem.Allocator, defaults: ConfigT) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(child_allocator),
                .config = defaults,
            };
        }

        /// Frees all strings allocated during environment or CLI parsing.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Zig 0.16: Accepts the injected environ_map directly to avoid allocations.
        pub fn loadEnv(self: *Self, prefix: []const u8, env_map: anytype) !void {
            const allocator = self.arena.allocator();

            const fnames0 = @typeInfo(ConfigT).@"struct".field_names;
            inline for (fnames0, 0..) |_, fnames0_i| {
                const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fnames0_i)));
                const upper_name = comptime blk: {
                    var buf: [field.name.len]u8 = undefined;
                    for (field.name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
                    break :blk buf;
                };

                const env_key = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, upper_name });

                if (env_map.get(env_key)) |val| {
                    if (self.parseValue(field.type, val)) |parsed| {
                        @field(self.config, field.name) = parsed;
                    } else |err| {
                        std.log.err("Failed to parse env var {s}='{s}': {any}", .{ env_key, val, err });
                    }
                }
            }
        }

        /// Safely merges overrides. Duplicates strings to prevent dangling pointers.
        pub fn loadJsonConfig(self: *Self, json_str: []const u8) !void {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.allocator(), json_str, .{});
            defer parsed.deinit();

            if (parsed.value != .object) return error.ExpectedObject;

            const fnames1 = @typeInfo(ConfigT).@"struct".field_names;
            inline for (fnames1, 0..) |_, fidx1| {
                const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fidx1)));
                if (parsed.value.object.get(field.name)) |json_val| {
                    if (self.parseJsonValue(field.type, json_val)) |parsed_val| {
                        @field(self.config, field.name) = parsed_val;
                    } else |err| {
                        std.log.err("Failed to parse config '{s}': {any}", .{ field.name, err });
                    }
                }
            }
        }

        fn parseJsonValue(self: *Self, comptime T: type, val: std.json.Value) !T {
            const info = @typeInfo(T);
            switch (info) {
                .int => {
                    if (val != .integer) return error.InvalidType;
                    return std.math.cast(T, val.integer) orelse error.Overflow;
                },
                .float => {
                    if (val == .float) return @as(T, @floatCast(val.float));
                    if (val == .integer) return @as(T, @floatFromInt(val.integer));
                    return error.InvalidType;
                },
                .bool => {
                    if (val != .bool) return error.InvalidType;
                    return val.bool;
                },
                .@"enum" => {
                    if (val != .string) return error.InvalidType;
                    return std.meta.stringToEnum(T, val.string) orelse error.InvalidEnum;
                },
                .optional => |opt| {
                    if (val == .null) return null;
                    return try self.parseJsonValue(opt.child, val);
                },
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) {
                        if (val != .string) return error.InvalidType;
                        return try self.arena.allocator().dupe(u8, val.string);
                    }
                    return error.UnsupportedType;
                },
                else => return error.UnsupportedType,
            }
        }

        pub fn merge(self: *Self, overrides: anytype) !void {
            const OverrideT = @TypeOf(overrides);
            const fnames2 = @typeInfo(ConfigT).@"struct".field_names;
            inline for (fnames2, 0..) |_, fidx2| {
                const field = std.meta.fieldInfo(ConfigT, @fromBackingInt(@intCast(fidx2)));
                if (@hasField(OverrideT, field.name)) {
                    const override_val = @field(overrides, field.name);

                    if (@typeInfo(@TypeOf(override_val)) == .optional) {
                        if (override_val) |v| {
                            try self.assignSafe(field.name, field.type, v);
                        }
                    } else {
                        try self.assignSafe(field.name, field.type, override_val);
                    }
                }
            }
        }

        /// Helper to guarantee strings are duplicated into the Arena during merges.
        fn assignSafe(self: *Self, comptime field_name: []const u8, comptime T: type, val: anytype) !void {
            const info = @typeInfo(T);
            if (info == .pointer and info.pointer.size == .slice and info.pointer.child == u8) {
                @field(self.config, field_name) = try self.arena.allocator().dupe(u8, val);
            } else {
                @field(self.config, field_name) = val;
            }
        }

        pub fn get(self: *const Self) ConfigT {
            return self.config;
        }

        fn parseValue(self: *Self, comptime T: type, val: []const u8) !T {
            const info = @typeInfo(T);
            switch (info) {
                .int => return std.fmt.parseInt(T, val, 10),
                .float => return std.fmt.parseFloat(T, val),
                .bool => {
                    if (std.ascii.eqlIgnoreCase(val, "true") or std.mem.eql(u8, val, "1")) return true;
                    if (std.ascii.eqlIgnoreCase(val, "false") or std.mem.eql(u8, val, "0")) return false;
                    return error.InvalidBool;
                },
                .@"enum" => return std.meta.stringToEnum(T, val) orelse error.InvalidEnum,
                .optional => |opt| {
                    return self.parseValue(opt.child, val);
                },
                .pointer => |ptr| {
                    if (ptr.size == .Slice and ptr.child == u8) {
                        return try self.arena.allocator().dupe(u8, val);
                    }
                    return error.UnsupportedType;
                },
                else => return error.UnsupportedType,
            }
        }
    };
}

test "Manager loads defaults and merges correctly" {
    const TestConfig = struct {
        port: u16 = 8080,
        host: []const u8 = "localhost",
        debug: bool = false,
    };

    var mgr = Manager(TestConfig).init(std.testing.allocator, .{});
    defer mgr.deinit();

    const cfg1 = mgr.get();
    try std.testing.expectEqual(@as(u16, 8080), cfg1.port);
    try std.testing.expectEqualStrings("localhost", cfg1.host);

    // Simulate merge
    const overrides = struct { port: u16 = 9090, host: []const u8 = "0.0.0.0" }{};
    try mgr.merge(overrides);

    const cfg2 = mgr.get();
    try std.testing.expectEqual(@as(u16, 9090), cfg2.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg2.host);
}

test "JSON configuration parsing" {
    const TestConfig = struct {
        port: u16 = 8080,
        host: []const u8 = "localhost",
        debug: bool = false,
        level: enum { info, warn, err } = .info,
    };

    var mgr = Manager(TestConfig).init(std.testing.allocator, .{});
    defer mgr.deinit();

    // Create a temporary JSON file
    const json_data =
        \\{
        \\    "port": 9090,
        \\    "host": "0.0.0.0",
        \\    "debug": true,
        \\    "level": "warn"
        \\}
    ;

    try mgr.loadJsonConfig(json_data);

    const cfg = mgr.get();
    try std.testing.expectEqual(@as(u16, 9090), cfg.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
    try std.testing.expectEqual(true, cfg.debug);
    try std.testing.expectEqual(.warn, cfg.level);
}
