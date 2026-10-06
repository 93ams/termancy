const std = @import("std");

pub const TaskError = error{
    TaskNotFound,
    CircularDependency,
    TaskFailed,
};

pub const TaskRunError = TaskError || std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.Dir.OpenError || std.Io.File.OpenError;

pub const Task = struct {
    name: []const u8,
    description: []const u8 = "",
    deps: []const []const u8 = &[_][]const u8{},
    run: *const fn (allocator: std.mem.Allocator) TaskRunError!void,
};

pub const TaskRunner = struct {
    tasks: []const Task,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tasks: []const Task) TaskRunner {
        return .{
            .allocator = allocator,
            .tasks = tasks,
        };
    }

    pub fn findTask(self: TaskRunner, name: []const u8) ?Task {
        for (self.tasks) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn run(self: TaskRunner, target: []const u8, writer: anytype) !void {
        var executed = std.StringHashMap(void).init(self.allocator);
        defer executed.deinit();

        var visiting = std.StringHashMap(void).init(self.allocator);
        defer visiting.deinit();

        try self.executeWithDeps(target, &executed, &visiting, writer);
    }

    fn executeWithDeps(
        self: TaskRunner,
        task_name: []const u8,
        executed: *std.StringHashMap(void),
        visiting: *std.StringHashMap(void),
        writer: anytype,
    ) !void {
        if (executed.contains(task_name)) return;

        if (visiting.contains(task_name)) {
            try writer.print("Error: Circular dependency detected at task '{s}'\n", .{task_name});
            return TaskError.CircularDependency;
        }

        const task = self.findTask(task_name) orelse {
            try writer.print("Error: Task '{s}' not found\n", .{task_name});
            return TaskError.TaskNotFound;
        };

        try visiting.put(task_name, {});

        // Run dependencies first
        for (task.deps) |dep| {
            try self.executeWithDeps(dep, executed, visiting, writer);
        }

        _ = visiting.remove(task_name);

        try writer.print("\x1b[36m==>\x1b[0m Running task \x1b[1m'{s}'\x1b[0m...\n", .{task.name});
        task.run(self.allocator) catch |err| {
            try writer.print("\x1b[31m✖\x1b[0m Task '{s}' failed: {s}\n", .{ task.name, @errorName(err) });
            return TaskError.TaskFailed;
        };

        try executed.put(task_name, {});
        try writer.print("\x1b[32m✔\x1b[0m Task '{s}' completed successfully.\n", .{task.name});
    }
};
