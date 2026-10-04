const std = @import("std");

pub const DeviceAuthResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: ?[]const u8 = null,
    expires_in: u32 = 900,
    interval: u32 = 5,
};

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    expires_in: ?u32 = null,
    refresh_token: ?[]const u8 = null,
};

pub const PollStatus = enum {
    pending,
    slow_down,
    access_denied,
    expired_token,
    success,
};

pub const PollResult = union(enum) {
    success: std.json.Parsed(TokenResponse),
    poll: PollStatus,
    err: []const u8,

    pub fn deinit(self: *PollResult) void {
        switch (self.*) {
            .success => |*p| p.deinit(),
            else => {},
        }
    }
};

pub const OAuthDeviceFlow = struct {
    pub fn renderPrompt(writer: anytype, auth: DeviceAuthResponse) !void {
        try writer.writeAll("\n\x1b[36;1m=== Device Authentication Required ===\x1b[0m\n\n");
        try writer.print("Please visit: \x1b[4;34m{s}\x1b[0m\n", .{auth.verification_uri});
        try writer.print("And enter the code: \x1b[1;32m{s}\x1b[0m\n\n", .{auth.user_code});
        if (auth.verification_uri_complete) |complete_url| {
            try writer.print("Or open this direct URL:\n  \x1b[4;34m{s}\x1b[0m\n\n", .{complete_url});
        }
        try writer.writeAll("Waiting for authentication...\n");
    }

    pub fn parseTokenPollResponse(status_code: u16, body: []const u8, allocator: std.mem.Allocator) !PollResult {
        if (status_code == 200) {
            const parsed = try std.json.parseFromSlice(TokenResponse, allocator, body, .{ .ignore_unknown_fields = true });
            return .{ .success = parsed };
        }

        const ErrorResponse = struct {
            @"error": []const u8,
        };
        if (std.json.parseFromSlice(ErrorResponse, allocator, body, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            const err_str = parsed.value.@"error";
            if (std.mem.eql(u8, err_str, "authorization_pending")) {
                return .{ .poll = .pending };
            } else if (std.mem.eql(u8, err_str, "slow_down")) {
                return .{ .poll = .slow_down };
            } else if (std.mem.eql(u8, err_str, "access_denied")) {
                return .{ .poll = .access_denied };
            } else if (std.mem.eql(u8, err_str, "expired_token")) {
                return .{ .poll = .expired_token };
            }
            return .{ .err = try allocator.dupe(u8, err_str) };
        } else |_| {
            return .{ .err = try allocator.dupe(u8, "unknown_error") };
        }
    }
};
