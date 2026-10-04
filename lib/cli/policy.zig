const std = @import("std");

pub const PolicyRule = struct {
    name: []const u8,
    required_flag: ?[]const u8 = null,
    forbidden_env: ?[]const u8 = null,
    message: []const u8,
};

pub const PolicyEngine = struct {
    pub fn evaluate(
        rules: []const PolicyRule,
        env_map: *const std.process.Environ.Map,
        flags_provided: []const []const u8,
        writer: anytype,
    ) !void {
        for (rules) |rule| {
            if (rule.forbidden_env) |env_var| {
                if (env_map.get(env_var) != null) {
                    if (rule.required_flag) |req| {
                        var found = false;
                        for (flags_provided) |fp| {
                            if (std.mem.eql(u8, fp, req)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            try writer.print("Policy Violation: {s}\n", .{rule.message});
                            return error.PolicyViolation;
                        }
                    }
                }
            }
        }
    }
};
