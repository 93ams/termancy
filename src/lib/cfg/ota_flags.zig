const std = @import("std");

pub const OtaError = error{
    FeatureDisabled,
};

pub const OtaFlagRegistry = struct {
    flags: std.StringHashMap(bool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OtaFlagRegistry {
        return .{
            .flags = std.StringHashMap(bool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OtaFlagRegistry) void {
        var it = self.flags.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.flags.deinit();
    }

    pub fn setFlag(self: *OtaFlagRegistry, name: []const u8, enabled: bool) !void {
        const key = try self.allocator.dupe(u8, name);
        if (self.flags.fetchPut(key, enabled)) |old| {
            if (old) |kv| {
                self.allocator.free(kv.key);
            }
        } else |_| {}
    }

    pub fn isEnabled(self: OtaFlagRegistry, name: []const u8) bool {
        return self.flags.get(name) orelse true; // Default to true if not specified
    }

    /// Validates if a command tagged with .feature_flag is permitted to execute
    pub fn assertAllowed(self: OtaFlagRegistry, feature_flag: ?[]const u8) OtaError!void {
        if (feature_flag) |flag| {
            if (!self.isEnabled(flag)) {
                return OtaError.FeatureDisabled;
            }
        }
    }

    /// Load flags from JSON string: e.g. {"beta_deploy": false, "telemetry_v2": true}
    pub fn loadFromJson(self: *OtaFlagRegistry, json_str: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const val_bool = switch (entry.value_ptr.*) {
                .bool => |b| b,
                else => true,
            };
            try self.setFlag(entry.key_ptr.*, val_bool);
        }
    }
};
