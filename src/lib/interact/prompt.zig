const std = @import("std");
const tea = @import("render").tea;
const style = @import("render").style;

// --- CONFIRM PROMPT ---
pub const ConfirmOptions = struct {
    default: bool = false,
};

pub fn confirm(ctx: anytype, question: []const u8, options: ConfirmOptions) !bool {
    const Model = struct {
        q: []const u8,
        val: bool,
        done: bool = false,

        pub fn init(q: []const u8, def: bool) @This() {
            return .{ .q = q, .val = def };
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .left, .right => {
                        self.val = !self.val;
                    },
                    .char => {
                        const c = k.char orelse return .none;
                        if (c == 'y' or c == 'Y') {
                            self.val = true;
                            self.done = true;
                            return .quit;
                        } else if (c == 'n' or c == 'N') {
                            self.val = false;
                            self.done = true;
                            return .quit;
                        }
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new().faint(true);

            try writer.print("? {s} ", .{self.q});

            if (self.done) {
                const text = if (self.val) "Yes" else "No";
                try active_style.render(writer, text);
            } else {
                if (self.val) {
                    try active_style.render(writer, "[Y]");
                    try writer.writeAll(" ");
                    try inactive_style.render(writer, "n");
                } else {
                    try inactive_style.render(writer, "y");
                    try writer.writeAll(" ");
                    try active_style.render(writer, "[N]");
                }
            }
            try writer.writeAll("\n");
        }
    };

    const m = Model.init(question, options.default);

    // No channel here: `Program` allocates its own and transfers the lifetime to the
    // reader thread, which cannot be joined. A caller-owned channel on this frame is
    // exactly the use-after-free this prompt used to have. See `tea.StdinContext`.
    var prog = tea.Program(Model, void).init(m, ctx.io);
    try prog.run(ctx);

    return prog.model.val;
}

// --- SELECT PROMPT ---
pub fn select(ctx: anytype, comptime EnumType: type, question: []const u8) !EnumType {
    const type_info = @typeInfo(EnumType);
    if (type_info != .@"enum") @compileError("select prompt requires an enum type");

    const fields = type_info.@"enum".fields;

    const Model = struct {
        q: []const u8,
        cursor: usize = 0,
        done: bool = false,

        pub fn init(q: []const u8) @This() {
            return .{ .q = q };
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .up => {
                        if (self.cursor > 0) self.cursor -= 1;
                    },
                    .down => {
                        if (self.cursor < fields.len - 1) self.cursor += 1;
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new();

            try writer.print("? {s}\n", .{self.q});

            if (self.done) {
                inline for (fields, 0..) |field, i| {
                    if (self.cursor == i) {
                        try writer.writeAll("  ");
                        try active_style.render(writer, field.name);
                        try writer.writeAll("\n");
                    }
                }
            } else {
                inline for (fields, 0..) |field, i| {
                    if (self.cursor == i) {
                        try active_style.render(writer, "> ");
                        try active_style.render(writer, field.name);
                    } else {
                        try inactive_style.render(writer, "  ");
                        try inactive_style.render(writer, field.name);
                    }
                    try writer.writeAll("\n");
                }
            }
        }
    };

    const m = Model.init(question);
    var prog = tea.Program(Model, void).init(m, ctx.io);
    try prog.run(ctx);

    inline for (fields, 0..) |field, i| {
        if (prog.model.cursor == i) {
            return @field(EnumType, field.name);
        }
    }
    unreachable;
}

// --- MULTI-SELECT PROMPT ---
pub fn multiSelect(ctx: anytype, comptime EnumType: type, question: []const u8) ![]EnumType {
    const type_info = @typeInfo(EnumType);
    if (type_info != .Enum) @compileError("multiSelect prompt requires an enum type");

    const fields = type_info.Enum.fields;

    const Model = struct {
        q: []const u8,
        cursor: usize = 0,
        selected: [fields.len]bool = [_]bool{false} ** fields.len,
        done: bool = false,

        pub fn init(q: []const u8) @This() {
            return .{ .q = q };
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .up => {
                        if (self.cursor > 0) self.cursor -= 1;
                    },
                    .down => {
                        if (self.cursor < fields.len - 1) self.cursor += 1;
                    },
                    .char => {
                        const c = k.char orelse return .none;
                        if (c == ' ') {
                            self.selected[self.cursor] = !self.selected[self.cursor];
                        }
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new();

            try writer.print("? {s} (Press Space to select, Enter to confirm)\n", .{self.q});

            if (self.done) {
                inline for (fields, 0..) |field, i| {
                    if (self.selected[i]) {
                        try writer.writeAll("  ");
                        try active_style.render(writer, field.name);
                        try writer.writeAll("\n");
                    }
                }
            } else {
                inline for (fields, 0..) |field, i| {
                    if (self.cursor == i) {
                        try active_style.render(writer, "> ");
                    } else {
                        try inactive_style.render(writer, "  ");
                    }

                    if (self.selected[i]) {
                        try active_style.render(writer, "[x] ");
                    } else {
                        try inactive_style.render(writer, "[ ] ");
                    }

                    if (self.cursor == i) {
                        try active_style.render(writer, field.name);
                    } else {
                        try inactive_style.render(writer, field.name);
                    }
                    try writer.writeAll("\n");
                }
            }
        }
    };

    const m = Model.init(question);
    var prog = tea.Program(Model, void).init(m, ctx.io);
    try prog.run(ctx);

    var selected_list = std.ArrayListUnmanaged(EnumType).empty;
    errdefer selected_list.deinit(ctx.allocator);

    inline for (fields, 0..) |field, i| {
        if (prog.model.selected[i]) {
            try selected_list.append(ctx.allocator, @field(EnumType, field.name));
        }
    }

    return selected_list.toOwnedSlice(ctx.allocator);
}

// --- DYNAMIC MULTI-SELECT PROMPT ---
pub fn multiSelectDynamic(ctx: anytype, options: []const []const u8, question: []const u8) ![][]const u8 {
    const Model = struct {
        q: []const u8,
        opts: []const []const u8,
        cursor: usize = 0,
        selected: []bool,
        done: bool = false,
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, q: []const u8, opts: []const []const u8) !@This() {
            const selected = try alloc.alloc(bool, opts.len);
            @memset(selected, false);
            return .{ .allocator = alloc, .q = q, .opts = opts, .selected = selected };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.selected);
        }

        pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
            switch (msg) {
                .key => |k| switch (k.key) {
                    .up => {
                        if (self.cursor > 0) self.cursor -= 1;
                    },
                    .down => {
                        if (self.cursor < self.opts.len - 1) self.cursor += 1;
                    },
                    .char => {
                        const c = k.char orelse return .none;
                        if (c == ' ') {
                            self.selected[self.cursor] = !self.selected[self.cursor];
                        }
                    },
                    .enter => {
                        self.done = true;
                        return .quit;
                    },
                    .ctrl_c, .escape => {
                        return error.PromptCancelled;
                    },
                    else => {},
                },
                else => {},
            }
            return .none;
        }

        pub fn view(self: *const @This(), writer: anytype) !void {
            const active_style = style.new().foreground(style.Color.rgb(100, 255, 100)).bold(true);
            const inactive_style = style.new();

            try writer.print("? {s} (Press Space to select, Enter to confirm)\n", .{self.q});

            if (self.done) {
                for (self.opts, 0..) |opt, i| {
                    if (self.selected[i]) {
                        try writer.writeAll("  ");
                        try active_style.render(writer, opt);
                        try writer.writeAll("\n");
                    }
                }
            } else {
                for (self.opts, 0..) |opt, i| {
                    if (self.cursor == i) {
                        try active_style.render(writer, "> ");
                    } else {
                        try inactive_style.render(writer, "  ");
                    }

                    if (self.selected[i]) {
                        try active_style.render(writer, "[x] ");
                    } else {
                        try inactive_style.render(writer, "[ ] ");
                    }

                    if (self.cursor == i) {
                        try active_style.render(writer, opt);
                    } else {
                        try inactive_style.render(writer, opt);
                    }
                    try writer.writeAll("\n");
                }
            }
        }
    };

    var m = try Model.init(ctx.allocator, question, options);
    defer m.deinit();

    var prog = tea.Program(Model, void).init(m, ctx.io);
    try prog.run(ctx);

    var selected_list = std.ArrayListUnmanaged([]const u8).empty;
    errdefer selected_list.deinit(ctx.allocator);

    for (options, 0..) |opt, i| {
        if (prog.model.selected[i]) {
            try selected_list.append(ctx.allocator, opt);
        }
    }

    return selected_list.toOwnedSlice(ctx.allocator);
}
