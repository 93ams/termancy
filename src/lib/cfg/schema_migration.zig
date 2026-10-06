const std = @import("std");

pub const MigrationFn = *const fn (allocator: std.mem.Allocator, input_toml: []const u8) anyerror![]const u8;

pub const Migration = struct {
    from_version: u32,
    to_version: u32,
    migrate_fn: MigrationFn,
};

pub const SchemaMigrator = struct {
    pub fn extractVersion(toml_content: []const u8) u32 {
        var it = std.mem.splitScalar(u8, toml_content, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (std.mem.startsWith(u8, line, "version")) {
                const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const val_str = std.mem.trim(u8, line[eq_idx + 1 ..], " \r\t\"");
                return std.fmt.parseInt(u32, val_str, 10) catch 1;
            }
        }
        return 1; // Default version 1 if absent
    }

    pub fn migrate(
        allocator: std.mem.Allocator,
        target_version: u32,
        migrations: []const Migration,
        initial_toml: []const u8,
    ) ![]const u8 {
        var current_v = extractVersion(initial_toml);
        if (current_v >= target_version) {
            return try allocator.dupe(u8, initial_toml);
        }

        var current_content: []const u8 = try allocator.dupe(u8, initial_toml);
        errdefer allocator.free(current_content);

        while (current_v < target_version) {
            var found = false;
            for (migrations) |m| {
                if (m.from_version == current_v and m.to_version <= target_version) {
                    const next_content = try m.migrate_fn(allocator, current_content);
                    allocator.free(current_content);
                    current_content = next_content;
                    current_v = m.to_version;
                    found = true;
                    break;
                }
            }

            if (!found) {
                return error.NoMigrationPath;
            }
        }

        return current_content;
    }
};
