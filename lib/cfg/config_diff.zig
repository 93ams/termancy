const std = @import("std");

pub const ConfigDiffer = struct {
    pub fn renderDiff(writer: anytype, default_cfg: anytype, active_cfg: anytype, show_unchanged: bool) !usize {
        const T = @TypeOf(default_cfg);
        if (@typeInfo(T) != .@"struct") return 0;

        var diff_count: usize = 0;
        try writer.writeAll("\n\x1b[1m=== Configuration Diff (Default vs Active) ===\x1b[0m\n");

        inline for (std.meta.fields(T)) |field| {
            const def_val = @field(default_cfg, field.name);
            const act_val = @field(active_cfg, field.name);

            const is_diff = switch (field.type) {
                []const u8, []u8 => !std.mem.eql(u8, def_val, act_val),
                else => def_val != act_val,
            };

            if (is_diff) {
                diff_count += 1;
                if (field.type == []const u8 or field.type == []u8) {
                    try writer.print("\x1b[31m- {s} = \"{s}\"\x1b[0m\n", .{ field.name, def_val });
                    try writer.print("\x1b[32m+ {s} = \"{s}\"\x1b[0m\n", .{ field.name, act_val });
                } else {
                    try writer.print("\x1b[31m- {s} = {any}\x1b[0m\n", .{ field.name, def_val });
                    try writer.print("\x1b[32m+ {s} = {any}\x1b[0m\n", .{ field.name, act_val });
                }
            } else if (show_unchanged) {
                if (field.type == []const u8 or field.type == []u8) {
                    try writer.print("  {s} = \"{s}\"\n", .{ field.name, def_val });
                } else {
                    try writer.print("  {s} = {any}\n", .{ field.name, def_val });
                }
            }
        }

        if (diff_count == 0) {
            try writer.writeAll("  (no differences from defaults)\n");
        }
        return diff_count;
    }
};
