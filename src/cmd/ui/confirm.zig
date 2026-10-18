//! `termancy ui confirm`: ask a yes/no question; the answer is the exit status.

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const term = @import("term.zig");
const plain = @import("plain.zig");
const Confirm = @import("../tui/registry/confirm.zig").Confirm;

pub const Answer = enum { yes, no };

pub const Flags = struct {
    default: Answer = .yes,
    affirmative: []const u8 = "Yes",
    negative: []const u8 = "No",

    pub const meta = .{
        .default = .{ .help = "The button highlighted at the start" },
        .affirmative = .{ .help = "The label of the yes button" },
        .negative = .{ .help = "The label of the no button" },
    };
};

pub const command = cli.command(.{
    .name = "confirm",
    .summary = "Ask a yes/no question",
    .description =
    \\Ask the question (default "Are you sure?") and exit with status 0 for yes and 1
    \\for no. Nothing is printed.
    \\
    \\Keys: left/right or tab switch buttons, enter answers, y and n answer directly,
    \\esc cancels (status 1), Ctrl-C interrupts (status 130).
    ,
    .flags = Flags,
    .args = .{ .max = 1, .usage = "[prompt]" },
    .exit_statuses = &.{
        .{ .code = 0, .meaning = "Yes" },
        .{ .code = 1, .meaning = "No, or cancelled with esc" },
    },
    .examples =
    \\termancy ui confirm "Deploy to production?" && ./deploy
    \\termancy ui confirm --default no --affirmative Delete --negative Keep
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const question = if (ctx.args.len > 0) ctx.args[0] else "Are you sure?";
        const yes = try session.confirm(question, flags.default == .yes) orelse
            return error.CommandFailed;
        if (!yes) return error.CommandFailed;
        return;
    }
    var model = build(if (ctx.args.len > 0) ctx.args[0] else null, flags);
    if (try term.run(ctx, Confirm, &model, term.suspend_options)) return term.exitInterrupted(ctx);
    if (!accepted(model)) return error.CommandFailed;
}

/// The model for `prompt` (the default question when null) and the flags.
pub fn build(prompt: ?[]const u8, flags: Flags) Confirm {
    var model: Confirm = .{
        .affirmative = flags.affirmative,
        .negative = flags.negative,
        .value = flags.default == .yes,
    };
    if (prompt) |text| model.prompt = text;
    return model;
}

/// Whether the question was answered yes (not no, and not canceled).
pub fn accepted(model: Confirm) bool {
    return model.status == .submitted and model.value;
}

const testing = std.testing;
const Driver = tui.testing.Driver(Confirm);

test "the default answer is highlighted; enter takes it" {
    var d: Driver = try .init(testing.allocator, build("Go?", .{ .default = .no }), .{});
    defer d.deinit();
    try testing.expect(!d.model().value);
    try d.press("enter");
    try testing.expect(!accepted(d.model().*));
}

test "yes, with custom labels" {
    var d: Driver = try .init(
        testing.allocator,
        build(null, .{ .affirmative = "Ship", .negative = "Wait" }),
        .{},
    );
    defer d.deinit();
    try d.expectFrame("Are you sure?\n\n   Ship        Wait   ");
    try d.press("y");
    try testing.expect(accepted(d.model().*));
}

test "esc is not yes" {
    var d: Driver = try .init(testing.allocator, build(null, .{}), .{});
    defer d.deinit();
    try d.press("esc");
    try testing.expect(!accepted(d.model().*));
}
