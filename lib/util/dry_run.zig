const std = @import("std");

pub const MutationType = enum {
    create_file,
    delete_file,
    write_file,
    network_request,
};

pub const MutationRecord = struct {
    action: MutationType,
    target: []const u8,
    details: []const u8 = "",
};

pub const DryRunLedger = struct {
    mutations: std.ArrayList(MutationRecord),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DryRunLedger {
        return .{
            .mutations = std.ArrayList(MutationRecord).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DryRunLedger) void {
        for (self.mutations.items) |m| {
            self.allocator.free(m.target);
            if (m.details.len > 0) self.allocator.free(m.details);
        }
        self.mutations.deinit(self.allocator);
    }

    pub fn record(self: *DryRunLedger, action: MutationType, target: []const u8, details: []const u8) !void {
        const t = try self.allocator.dupe(u8, target);
        const d = if (details.len > 0) try self.allocator.dupe(u8, details) else "";
        try self.mutations.append(self.allocator, .{
            .action = action,
            .target = t,
            .details = d,
        });
    }

    pub fn renderDiff(self: DryRunLedger, writer: anytype) !void {
        try writer.writeAll("\n\x1b[33;1m=== DRY RUN: Proposed Mutations ===\x1b[0m\n");
        for (self.mutations.items) |m| {
            const tag = switch (m.action) {
                .create_file => "\x1b[32m[+CREATE]\x1b[0m",
                .delete_file => "\x1b[31m[-DELETE]\x1b[0m",
                .write_file => "\x1b[36m[~MODIFY]\x1b[0m",
                .network_request => "\x1b[35m[NET_REQ]\x1b[0m",
            };
            try writer.print("{s} {s}", .{ tag, m.target });
            if (m.details.len > 0) {
                try writer.print(" ({s})", .{m.details});
            }
            try writer.writeAll("\n");
        }
    }
};
