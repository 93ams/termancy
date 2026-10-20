//! Questions asked with the components, one small inline program each: yes or no with
//! `confirm`, a choice with `select`, text with `input`, and several at once with `form`.
//! Each answered question stays on the terminal as one line (`? Deploy where? production`),
//! so the scrollback shows the decisions made.
//!
//! The functions have the shape of `cli.flow.Asker`'s, so a `cli.Flow` asks with them:
//!
//! ```zig
//! var prompts: Prompts = .{ .gpa = gpa, .io = io, .environ = environ };
//! defer prompts.deinit();
//! const app: cli.App = .{ .root = &root, .asker = prompts.asker(cli.flow.Asker) };
//! ```
//!
//! One terminal serves every question, so keys typed ahead (answering the next question
//! before it is drawn) are kept for it. `prompts` must not move once it has asked.
//! Without a terminal each question is unanswered (null), so a caller falls back as it
//! would at the end of input. Ctrl-C and esc are unanswered too.

const std = @import("std");
const tui = @import("tui");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Confirm = @import("confirm.zig");
const Select = @import("select.zig");
const Input = @import("input.zig");
const Form = @import("form.zig");

const Prompts = @This();

gpa: Allocator,
io: Io,
/// For the terminal's color support (`NO_COLOR`, `TERM`, ...).
environ: *const std.process.Environ.Map,
/// Choices shown at once before the list scrolls.
height: usize = 8,
styles: Styles = .{},
/// What a typed answer that `accepts` refuses says, in a form.
invalid_message: []const u8 = "Not a valid answer",
/// Opened by the first question, closed by `deinit`.
terminal: ?tui.Terminal = null,
buffer: [4096]u8 = undefined,

pub const Styles = struct {
    mark: tui.Style = .{ .fg = .{ .indexed = 212 }, .bold = true },
    answer: tui.Style = .{ .fg = .{ .indexed = 245 } },
};

/// Closes the terminal, if a question opened it.
pub fn deinit(prompts: *Prompts) void {
    if (prompts.terminal) |*terminal| terminal.close();
    prompts.terminal = null;
}

fn open(prompts: *Prompts) !?*tui.Terminal {
    if (prompts.terminal == null) {
        prompts.terminal = tui.Terminal.open(
            prompts.io,
            &prompts.buffer,
        ) catch |err| switch (err) {
            error.NotATerminal => return null,
            error.Canceled => return error.Canceled,
        };
    }
    return &prompts.terminal.?;
}

/// The functions as a value of `Asker`, a struct with the fields `context`, `confirm`,
/// `select`, `text`, and `form` (`cli.flow.Asker`).
pub fn asker(prompts: *Prompts, comptime Asker: type) Asker {
    return .{
        .context = prompts,
        .confirm = confirm,
        .select = select,
        .text = text,
        .form = form(@typeInfo(@FieldType(Asker, "form")).optional.child),
    };
}

/// Asks every question of a `cli.flow.Question` slice on one screen: a confirm or a
/// select becomes a choice, text an input. `Fn` is the function type of the asker's
/// `form` field, whose last parameter is the questions.
pub fn form(comptime Fn: type) Fn {
    const params = @typeInfo(@typeInfo(Fn).pointer.child).@"fn".param_types;
    const Question = @typeInfo(params[params.len - 1].?).pointer.child;
    return &struct {
        fn ask(
            context: ?*anyopaque,
            arena: Allocator,
            title: []const u8,
            questions: []Question,
        ) anyerror!bool {
            const prompts: *Prompts = @ptrCast(@alignCast(context.?));
            return prompts.askForm(Question, arena, title, questions);
        }
    }.ask;
}

fn askForm(
    prompts: *Prompts,
    comptime Question: type,
    arena: Allocator,
    title: []const u8,
    questions: []Question,
) !bool {
    const fields = try arena.alloc(Form.Field, questions.len);
    var made: usize = 0;
    defer for (fields[0..made]) |*field| field.deinit();
    for (questions, fields) |q, *field| {
        field.* = .{
            .label = q.label,
            .kind = switch (q.answer) {
                .confirm => |yes| .{ .choice = .{
                    .options = &.{ "yes", "no" },
                    .index = @intFromBool(!yes),
                } },
                .select => |index| .{ .choice = .{ .options = q.choices, .index = index } },
                // The default shows until something is typed, and is the answer if nothing is.
                .text => |default| .{ .input = .{
                    .gpa = prompts.gpa,
                    .prompt = "",
                    .placeholder = if (q.secret) "" else default,
                    .password = q.secret,
                } },
            },
        };
        made += 1;
    }
    var model: Form = .{ .fields = fields, .title = title };
    while (true) {
        if (!try prompts.run(Form, &model)) return false;
        if (model.status != .submitted) return false;
        // Typed answers the caller would refuse keep the form open, saying so.
        const refused = for (questions, fields, 0..) |q, *field, i| {
            const accepts = q.accepts orelse continue;
            if (field.kind != .input) continue;
            if (accepts(typed(&field.kind.input, q.answer.text))) continue;
            field.kind.input.message = prompts.invalid_message;
            break i;
        } else null;
        const index = refused orelse break;
        model.status = .active;
        model.focus = index;
    }
    for (questions, fields) |*q, *field| {
        const shown = switch (field.kind) {
            .choice => |choice| choice.selected(),
            .input => |*input| try arena.dupe(u8, typed(input, q.answer.text)),
            // The questions only make choices and inputs.
            else => unreachable,
        };
        q.answer = switch (q.answer) {
            .confirm => .{ .confirm = field.kind.choice.index == 0 },
            .select => .{ .select = field.kind.choice.index },
            .text => .{ .text = shown },
        };
        try prompts.answered(q.label, shown, q.secret);
    }
    return true;
}

pub fn confirm(context: ?*anyopaque, label: []const u8, default: bool) anyerror!?bool {
    const prompts: *Prompts = @ptrCast(@alignCast(context.?));
    var model: Confirm = .{ .prompt = label, .value = default };
    if (!try prompts.run(Confirm, &model)) return null;
    if (model.status != .submitted) return null;
    try prompts.answered(label, if (model.value) "yes" else "no", false);
    return model.value;
}

pub fn select(
    context: ?*anyopaque,
    label: []const u8,
    choices: []const []const u8,
    default: usize,
) anyerror!?usize {
    const prompts: *Prompts = @ptrCast(@alignCast(context.?));
    var model: Select = .{
        .header = label,
        .list = .{ .items = choices, .height = prompts.height },
    };
    model.list.moveTo(default);
    if (!try prompts.run(Select, &model)) return null;
    if (model.status != .submitted) return null;
    try prompts.answered(label, choices[model.list.cursor], false);
    return model.list.cursor;
}

pub fn text(
    context: ?*anyopaque,
    arena: Allocator,
    label: []const u8,
    default: []const u8,
    secret: bool,
) anyerror!?[]const u8 {
    const prompts: *Prompts = @ptrCast(@alignCast(context.?));
    const prompt = try std.fmt.allocPrint(arena, "{s} ", .{label});
    var model: Input = .{
        .gpa = prompts.gpa,
        .prompt = prompt,
        .placeholder = if (secret) "" else default,
        .password = secret,
    };
    defer model.deinit();
    if (!try prompts.run(Input, &model)) return null;
    if (model.status != .submitted) return null;
    const value = try arena.dupe(u8, typed(&model, default));
    try prompts.answered(label, value, secret);
    return value;
}

/// What `input` answers: the text typed, or `default` when none was.
fn typed(input: *const Input, default: []const u8) []const u8 {
    const value = input.value();
    return if (value.len == 0) default else value;
}

/// Runs `model` inline, erased when done; false without a terminal or after Ctrl-C.
fn run(prompts: *Prompts, comptime Model: type, model: *Model) !bool {
    const terminal = try prompts.open() orelse return false;
    const options: tui.Options = .{
        .clear_on_quit = true,
        .capability = terminal.capabilityIn(prompts.environ),
    };
    var program: tui.Program(Model) = .init(prompts.gpa, model, terminal.writer(), options);
    defer program.deinit();
    const outcome = try program.run(terminal);
    return !outcome.interrupted;
}

/// Leaves `? label answer` on the terminal.
fn answered(prompts: *Prompts, label: []const u8, answer: []const u8, secret: bool) !void {
    const terminal = try prompts.open() orelse return;
    const w = terminal.writer();
    const level = terminal.capabilityIn(prompts.environ).color;
    var line: Io.Writer.Allocating = .init(prompts.gpa);
    defer line.deinit();
    try prompts.styles.mark.paint(&line.writer, "?");
    try line.writer.print(" {s} ", .{label});
    try prompts.styles.answer.paint(&line.writer, if (secret) "••••" else answer);
    try tui.ansi.downsample(w, line.written(), level);
    try w.writeAll("\n");
    try w.flush();
}

const testing = std.testing;

const TestQuestion = struct {
    label: []const u8,
    choices: []const []const u8 = &.{},
    secret: bool = false,
    accepts: ?*const fn ([]const u8) bool = null,
    answer: union(enum) { confirm: bool, select: usize, text: []const u8 },
};

test "the functions fit an asker's shape" {
    const Asker = struct {
        context: ?*anyopaque = null,
        confirm: *const fn (?*anyopaque, []const u8, bool) anyerror!?bool,
        select: *const fn (?*anyopaque, []const u8, []const []const u8, usize) anyerror!?usize,
        text: *const fn (?*anyopaque, Allocator, []const u8, []const u8, bool) anyerror!?[]const u8,
        form: ?*const fn (?*anyopaque, Allocator, []const u8, []TestQuestion) anyerror!bool = null,
    };
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var prompts: Prompts = .{ .gpa = testing.allocator, .io = testing.io, .environ = &environ };
    const bound = prompts.asker(Asker);
    try testing.expect(bound.context == @as(?*anyopaque, &prompts));
    // Without a terminal, a form is unanswered. A test run from a console (Windows) or
    // with a controlling terminal has one, and the form would wait for keys.
    var buffer: [16]u8 = undefined;
    if (tui.Terminal.open(testing.io, &buffer)) |opened| {
        var terminal = opened;
        terminal.close();
        return;
    } else |_| {}
    var questions = [_]TestQuestion{
        .{ .label = "Plan", .choices = &.{ "free", "pro" }, .answer = .{ .select = 0 } },
        .{ .label = "Name", .answer = .{ .text = "ada" } },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(!try bound.form.?(&prompts, arena.allocator(), "", &questions));
}
