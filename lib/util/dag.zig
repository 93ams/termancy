const std = @import("std");

pub const DagError = error{
    CircularDependency,
    NodeNotFound,
};

pub const DagNode = struct {
    name: []const u8,
    deps: []const []const u8 = &.{},
};

pub const DagPipeline = struct {
    nodes: []const DagNode,

    pub fn init(nodes: []const DagNode) DagPipeline {
        return .{ .nodes = nodes };
    }

    /// Resolves nodes into execution stages where all nodes within a stage can execute concurrently
    pub fn computeStages(self: DagPipeline, allocator: std.mem.Allocator) ![]const []const []const u8 {
        var resolved = std.StringHashMap(usize).init(allocator);
        defer resolved.deinit();

        var stages_list = std.ArrayList([]const []const u8).empty;
        defer stages_list.deinit(allocator);
        errdefer {
            for (stages_list.items) |stage| allocator.free(stage);
        }

        var remaining: usize = self.nodes.len;
        var loop_guard: usize = 0;

        while (remaining > 0) {
            loop_guard += 1;
            if (loop_guard > self.nodes.len + 1) {
                return DagError.CircularDependency;
            }

            var current_stage = std.ArrayList([]const u8).empty;
            defer current_stage.deinit(allocator);

            for (self.nodes) |node| {
                if (resolved.contains(node.name)) continue;

                var deps_satisfied = true;
                for (node.deps) |dep| {
                    if (!resolved.contains(dep)) {
                        deps_satisfied = false;
                        break;
                    }
                }

                if (deps_satisfied) {
                    try current_stage.append(allocator, node.name);
                }
            }

            if (current_stage.items.len == 0) {
                return DagError.CircularDependency;
            }

            for (current_stage.items) |name| {
                try resolved.put(name, stages_list.items.len);
                remaining -= 1;
            }

            try stages_list.append(allocator, try allocator.dupe([]const u8, current_stage.items));
        }

        return try allocator.dupe([]const []const u8, stages_list.items);
    }

    pub fn freeStages(stages: []const []const []const u8, allocator: std.mem.Allocator) void {
        for (stages) |stage| {
            allocator.free(stage);
        }
        allocator.free(stages);
    }
};
