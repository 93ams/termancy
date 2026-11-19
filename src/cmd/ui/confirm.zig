//! `termancy ui confirm`: ask a yes/no question; the answer is the exit status, as gum's
//! `confirm`.

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const plain = @import("plain.zig");
const styles = @import("styles.zig");
const Confirm = @import("../tui/registry/confirm.zig");

/// The answer `--default` gives: `yes` or `no`, also spelled as gum's `--default=false`
/// (any of cli's words for true and false), or `y` and `n`.
pub const Answer = enum {
    yes,
    no,

    pub fn parse(text: []const u8) error{InvalidAnswer}!Answer {
        if (cli.Flag.parseBool(text)) |yes| return if (yes) .yes else .no;
        if (std.ascii.eqlIgnoreCase(text, "y")) return .yes;
        if (std.ascii.eqlIgnoreCase(text, "n")) return .no;
        return error.InvalidAnswer;
    }
};

pub const Flags = struct {
    default: Answer = .yes,
    no_default: bool = false,
    show_output: bool = false,
    affirmative: []const u8 = "Yes",
    negative: []const u8 = "No",
    show_help: bool = true,
    timeout: cfg.Duration = .zero,
    padding: styles.Spacing = .{},
    prompt_style: styles.Styles = .{},
    selected_style: styles.Styles = .{},
    unselected_style: styles.Styles = .{},
};
const flags_flags = cli.flags(Flags, field.Set(.{ field.Spec(Flags){ .fields = .{
    .default = .{ .help = "The answer highlighted at the start, and taken on a timeout" },
    .no_default = .{ .help = "Highlight the negative answer at the start (--default no)" },
    .show_output = .{ .help = "Print the question and the answer chosen" },
    .affirmative = .{ .help = "The label of the yes button" },
    .negative = .{ .help = "The label of the no button; empty for none" },
    .show_help = .{ .help = term.help.show_help },
    .timeout = .{
        .help = "Answer with the button highlighted after this long (0 waits forever)",
    },
    .padding = .{ .help = term.help.padding },
} }, styles.spec }), .{ .env_prefix = "TERMANCY_CONFIRM_", .fields = .{
    .default = .{ .value_name = "yes|no" },
    .no_default = .{ .hidden = true },
    .prompt_style = styles.group("prompt"),
    .selected_style = styles.group("selected"),
    .unselected_style = styles.group("unselected"),
} });

pub const command = cli.command(.{
    .name = "confirm",
    .summary = "Ask a yes/no question",
    .description =
    \\Ask the question (default "Are you sure?") and exit with status 0 for yes and 1
    \\for no. Nothing is printed, unless --show-output asks for the question and the
    \\answer.
    \\
    \\--default says which answer is highlighted at the start: yes or no, or as gum
    \\spells it, --default=false (--no-default too). --timeout is not an error here: when
    \\it passes, the highlighted answer is taken, as gum takes it.
    \\
    \\Keys: left/right, tab, h/l, or ctrl+n/ctrl+p switch buttons, enter answers, y
    \\answers yes and n or q no, esc answers no (status 1), Ctrl-C interrupts (status 130).
    \\
    \\Style a part with --prompt.*, --selected.*, and --unselected.*. Every flag can also
    \\come from a variable: TERMANCY_CONFIRM_DEFAULT, TERMANCY_CONFIRM_TIMEOUT.
    ,
    .flags = flags_flags,
    .args = .{ .max = 1, .usage = "[prompt]" },
    .exit_statuses = &.{
        .{ .code = 0, .meaning = "Yes" },
        .{ .code = 1, .meaning = "No, or cancelled with esc" },
    },
    .examples =
    \\termancy ui confirm "Deploy to production?" && ./deploy
    \\termancy ui confirm --default no --affirmative Delete --negative Keep
    \\termancy ui confirm --timeout 10s --default=false "Restart now?"
    ,
    .run = run,
});

fn run(ctx: *cli.Context, flags: Flags) !void {
    const prompt = if (ctx.args.len > 0) ctx.args[0] else "Are you sure?";
    const default = flags.default == .yes and !flags.no_default;
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const yes = try session.confirm(prompt, default) orelse return error.CommandFailed;
        return answer(ctx, flags, prompt, yes);
    }
    const hints = [_]term.Hint{
        .{ .keys = &.{ "left", "right" }, .action = .hint, .help = "toggle" },
        .{ .keys = &.{"enter"}, .action = .hint, .help = "submit" },
        .{ .keys = &.{"y"}, .action = .hint, .help = flags.affirmative },
        .{ .keys = &.{"n"}, .action = .hint, .help = flags.negative },
    };
    var model: term.Framed(Confirm) = .{
        .inner = build(prompt, default, flags, ctx.theme),
        .gpa = ctx.gpa,
        .padding = flags.padding.sides,
        .hints = if (flags.show_help) &hints else &.{},
    };
    const options = term.timed(term.suspend_options, flags.timeout);
    const outcome = try term.runOutcome(ctx, @TypeOf(model), &model, options);
    if (outcome.interrupted) return term.exitInterrupted(ctx);
    return answer(ctx, flags, prompt, accepted(model.inner, outcome.timed_out));
}

/// Ends with the answer: status 0 for yes, 1 for no, and with `--show-output` the question
/// and the answer's label on standard output, as gum prints them.
fn answer(ctx: *cli.Context, flags: Flags, prompt: []const u8, yes: bool) !void {
    if (flags.show_output) {
        try ctx.out.print("{s} {s}\n", .{ prompt, if (yes) flags.affirmative else flags.negative });
    }
    if (!yes) return error.CommandFailed;
}

/// The model for `prompt`, `default` highlighted, in the flags' styles over the theme's.
pub fn build(prompt: []const u8, default: bool, flags: Flags, theme: *const cli.Theme) Confirm {
    // gum's layout: the prompt a column in, each button padded 3 and a column apart from
    // its neighbors.
    const button: tui.Style.Sides = .symmetric(0, 3);
    const margin: tui.Style.Sides = .symmetric(0, 1);
    var heading = theme.heading;
    heading.margin = .{ .left = 1 };
    return .{
        .prompt = prompt,
        .affirmative = flags.affirmative,
        .negative = flags.negative,
        .value = default,
        .gap = "",
        .styles = .{
            .prompt = flags.prompt_style.over(heading),
            // Bold and underlined as well, so it stands out under `NO_COLOR`.
            .selected = flags.selected_style.over(.{
                .fg = .{ .basic = 15 },
                .bg = theme.accent.fg,
                .bold = true,
                .underline = true,
                .padding = button,
                .margin = margin,
            }),
            .unselected = flags.unselected_style.over(.{
                .fg = theme.note.fg,
                .dim = theme.note.dim,
                .padding = button,
                .margin = margin,
            }),
        },
    };
}

/// Whether the question was answered yes: submitted so, or highlighted when the timeout
/// passed. Esc is no.
pub fn accepted(model: Confirm, timed_out: bool) bool {
    return model.value and (model.status == .submitted or timed_out);
}

const testing = std.testing;
const Driver = tui.testing.Driver(Confirm);

fn plainBuild(prompt: []const u8, default: bool, flags: Flags) Confirm {
    var model = build(prompt, default, flags, &cli.Theme.bold);
    // The layout without the colors.
    const s = model.styles;
    model.styles = .{
        .prompt = .{ .margin = s.prompt.margin },
        .selected = .{ .margin = s.selected.margin, .padding = s.selected.padding },
        .unselected = .{ .margin = s.unselected.margin, .padding = s.unselected.padding },
    };
    return model;
}

test "the default answer is highlighted; enter takes it" {
    var d: Driver = try .init(testing.allocator, plainBuild("Go?", false, .{}), .{});
    defer d.deinit();
    try testing.expect(!d.model().value);
    try d.press("enter");
    try testing.expect(!accepted(d.model().*, false));
}

test "yes, with custom labels" {
    var d: Driver = try .init(
        testing.allocator,
        plainBuild("Are you sure?", true, .{ .affirmative = "Ship", .negative = "Wait" }),
        .{},
    );
    defer d.deinit();
    // gum's margins: the prompt a column in, the buttons a column apart on each side.
    try d.expectFrame(" Are you sure?\n\n    Ship        Wait    ");
    try d.press("y");
    try testing.expect(accepted(d.model().*, false));
}

test "esc is no; a timeout takes the answer highlighted" {
    var d: Driver = try .init(testing.allocator, plainBuild("Sure?", true, .{}), .{});
    defer d.deinit();
    try d.press("esc");
    try testing.expect(!accepted(d.model().*, false));

    const yes = plainBuild("Sure?", true, .{});
    try testing.expect(accepted(yes, true));
    try testing.expect(!accepted(yes, false));
    try testing.expect(!accepted(plainBuild("Sure?", false, .{}), true));
}

test "--default as termancy and gum spell it" {
    try testing.expectEqual(Answer.no, try Answer.parse("no"));
    try testing.expectEqual(Answer.no, try Answer.parse("false"));
    try testing.expectEqual(Answer.no, try Answer.parse("N"));
    try testing.expectEqual(Answer.yes, try Answer.parse("TRUE"));
    try testing.expectEqual(Answer.yes, try Answer.parse("y"));
    try testing.expectError(error.InvalidAnswer, Answer.parse("maybe"));
}

test "framed: the padding, and the help line with the labels" {
    const hints = [_]term.Hint{
        .{ .keys = &.{ "left", "right" }, .action = .hint, .help = "toggle" },
        .{ .keys = &.{"y"}, .action = .hint, .help = "Ship" },
    };
    const model: term.Framed(Confirm) = .{
        .inner = plainBuild("Go?", true, .{ .affirmative = "Ship" }),
        .gpa = testing.allocator,
        .padding = .{ .left = 1 },
        .hints = &hints,
    };
    var d: tui.testing.Driver(term.Framed(Confirm)) = try .init(testing.allocator, model, .{});
    defer d.deinit();
    try d.expectFrame("  Go?                  \n" ++
        "                       \n" ++
        "     Ship        No    \n" ++
        "                       \n" ++
        " ←/→ toggle • y Ship   ");
}

test "the style flags reach the buttons, over the theme" {
    const theme = &cli.Theme.default;
    const model = build("Sure?", true, .{
        .selected_style = .{ .background = .{ .indexed = 212 } },
        .prompt_style = .{ .italic = true },
    }, theme);
    try testing.expectEqual(tui.Color{ .indexed = 212 }, model.styles.selected.bg);
    try testing.expect(model.styles.selected.bold);
    try testing.expect(model.styles.prompt.italic and model.styles.prompt.bold);
    try testing.expectEqual(theme.heading.fg, model.styles.prompt.fg);
    try testing.expectEqual(theme.accent.fg, build("?", true, .{}, theme).styles.selected.bg);
    try testing.expectEqual(tui.Style.Sides.symmetric(0, 3), model.styles.unselected.padding);
}
