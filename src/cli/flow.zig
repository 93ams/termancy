//! Commands that are graphs: steps that ask questions and do things, where what comes next
//! depends on the answers and on what was found along the way, as installers, deploys, and
//! setup wizards are.
//!
//! ```zig
//! const Deploy = struct {                  // the flow's state; usually the flags struct too
//!     env: enum { staging, production } = .staging,
//!     migrate: bool = false,
//!     pub const meta = .{ .migrate = .{ .help = "Run the migrations" } };
//! };
//! const Step = enum { where, build, ask_migrate, migrate, release };
//!
//! const deploy: cli.Flow(Deploy, Step) = .{ .start = .where, .steps = .{
//!     .where = .{ .ask = .{ .field = "env", .label = "Deploy where?" }, .next = .build },
//!     .build = .{ .title = "Build", .run = build, .next = .ask_migrate },
//!     .ask_migrate = .{
//!         .ask = .{ .field = "migrate", .label = "Run the migrations?" },
//!         .decide = .{ .to = &.{ .migrate, .release }, .by = afterAsk },
//!     },
//!     .migrate = .{ .title = "Migrate", .run = migrate, .undo = rollback, .next = .release },
//!     .release = .{ .title = "Release", .run = release, .when = isProduction },
//! } };
//!
//! fn run(ctx: *cli.Context, flags: Deploy) !void {
//!     var state = flags;
//!     _ = try deploy.run(ctx, &state);
//! }
//! ```
//!
//! A step can:
//!
//! - **ask** for one field of the state. The question follows the field's type: a `bool`
//!   is yes or no, an enum is a choice of its values, text (or a number, or a type with
//!   `parse`) is typed in, and a list of those is typed in separated by commas. An answer
//!   that does not parse is refused, saying why, and asked again. The label may be worked
//!   out when asked (`.label_fn`). A question whose field was given as a flag is not
//!   asked, so the same flow runs from a script; without a terminal, an unasked question
//!   keeps the field's value, or (`.required`) fails, naming the flag to pass.
//! - ask for several fields as one **form** (`.form`, a page of a wizard), on one screen
//!   when the asker has `Asker.form`, else one question after another.
//! - **run** an action, `fn (*Context, *State) !void`, with an optional `undo`. When an
//!   action fails, the actions done so far are undone, latest first, and the error is
//!   returned. Under `--dry-run` actions are reported, not run, except `.probe` ones,
//!   which only look (and may decide the path).
//! - be skipped, `.when` a predicate says so.
//! - go on to a fixed `.next` step, or let `.decide` choose among the steps it lists (or
//!   `null`, to end). With neither, the flow ends.
//!
//! Fields of the state that are not settings (what the steps found, say) are marked
//! `.internal = true` in its `meta`, so a state that is also the command's flags struct
//! does not offer them as flags.
//!
//! The graph is checked when it is compiled: steps are an enum, so every target exists,
//! and a question names a field the state has, of a type that can be asked. A loop is
//! allowed (retry, ask again) and bounded by `max_steps`.
//!
//! Each action reports one line on standard error when it ends (`✓ Build (1.2s)`; with
//! `-q`, only failures and undos), or, with `-o json`, one JSON object on standard
//! output. Questions are asked by `Context.asker`: plain lines by default (`App.asker`
//! replaces it; the `prompts` component of `termancy tui add` asks with the terminal
//! interface instead).
//! `writeMermaid` draws the graph for documentation.

const std = @import("std");
const sets = @import("sets.zig");
const field_ = @import("field");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("Context.zig");
const Flag = @import("Flag.zig");
const Messages = @import("Messages.zig");
const prompt = @import("prompt.zig");
const text = @import("text.zig");
const values = @import("values.zig");

/// How a flow asks its questions. Each function returns null when the user gave no answer
/// (the input ended, or they canceled), which ends the flow.
pub const Asker = struct {
    context: ?*anyopaque = null,
    /// Yes or no.
    confirm: *const fn (context: ?*anyopaque, label: []const u8, default: bool) anyerror!?bool,
    /// The index of one of `choices`.
    select: *const fn (
        context: ?*anyopaque,
        label: []const u8,
        choices: []const []const u8,
        default: usize,
    ) anyerror!?usize,
    /// A line of text, in `arena`; `default` when nothing is typed. Not echoed when `secret`.
    text: *const fn (
        context: ?*anyopaque,
        arena: Allocator,
        label: []const u8,
        default: []const u8,
        secret: bool,
    ) anyerror!?[]const u8,
    /// Several questions at once, on one screen, each answer written into its question;
    /// false when canceled. Without it, they are asked one at a time.
    form: ?*const fn (
        context: ?*anyopaque,
        arena: Allocator,
        title: []const u8,
        questions: []Question,
    ) anyerror!bool = null,
    /// Says that a typed answer was refused, before it is asked for again: `answer` is what
    /// was typed, `expected` what the question takes (`Question.expected`). Without it,
    /// the question is asked again without a word.
    reject: ?*const fn (
        context: ?*anyopaque,
        answer: []const u8,
        expected: []const u8,
    ) anyerror!void = null,
};

/// One question of a form, as an asker sees it.
pub const Question = struct {
    label: []const u8,
    /// What a `.select` chooses from.
    choices: []const []const u8 = &.{},
    /// Text typed in is not echoed.
    secret: bool = false,
    /// Whether typed text can be taken (a number parses, say); any text can when null.
    accepts: ?*const fn (text: []const u8) bool = null,
    /// What typed text must be, for the message when it is refused: `int`, `list of int`.
    expected: []const u8 = "",
    /// The default going in, the answer coming out.
    answer: Answer,

    /// Yes or no, the index of a choice, or typed text.
    pub const Answer = union(enum) { confirm: bool, select: usize, text: []const u8 };
};

/// The most steps one run may take, loops included, before it is taken for a bug.
pub const max_steps = 10_000;

/// A flow over the state `State`, its steps named by the enum `Step`. Declare it as a
/// `const`: `run` checks it when compiled.
pub fn Flow(comptime State: type, comptime Step: type) type {
    if (@typeInfo(Step) != .@"enum") @compileError("cli.Flow: the steps must be an enum");
    return struct {
        start: Step,
        steps: std.enums.EnumFieldStruct(Step, Spec, null),

        const Self = @This();

        /// An action or an undo.
        pub const Action = *const fn (ctx: *Context, state: *State) anyerror!void;

        /// One step.
        pub const Spec = struct {
            /// What reports name the step; its name in the enum when empty.
            title: []const u8 = "",
            ask: ?Ask = null,
            /// Several questions asked together, as one form when the asker has
            /// `Asker.form` (the step's title heads it), else one after another.
            form: []const Ask = &.{},
            run: ?Action = null,
            /// Reverses `run`, when a later step fails.
            undo: ?Action = null,
            /// `run` only looks: it runs under `--dry-run` too, so decisions can use it.
            probe: bool = false,
            /// The step is skipped (and the flow goes on to `next` or `decide`) when this
            /// returns false.
            when: ?*const fn (state: *const State) bool = null,
            next: ?Step = null,
            decide: ?Decide = null,
        };

        /// A question setting `field` of the state.
        pub const Ask = struct {
            field: []const u8,
            /// The question, and the step's name in reports and `writeMermaid`.
            label: []const u8,
            /// The question as asked, worked out from the state at that moment ("Also
            /// search ~/src and ~/code?"); `label` when null. Not translated: `ctx.tr` it.
            label_fn: ?*const fn (ctx: *Context, state: *const State) anyerror![]const u8 = null,
            /// Without a terminal and without the flag, fail instead of keeping the field's
            /// value.
            required: bool = false,
            /// Text typed in is not echoed.
            secret: bool = false,
        };

        /// Where to go: `by` returns one of `to`, or null to end.
        pub const Decide = struct {
            to: []const Step,
            by: *const fn (state: *const State) ?Step,
        };

        /// What a run did.
        pub const Result = struct {
            /// The steps visited, in order, skipped ones included.
            path: []const Step,
        };

        /// Runs the flow from `start` on `state`, which questions and actions update. The
        /// error of a failed action is returned after the undos; an unanswered question
        /// ends the run with status 1.
        pub fn run(comptime flow: Self, ctx: *Context, state: *State) anyerror!Result {
            return flow.runFrom(ctx, state, flow.start);
        }

        /// Runs the flow from `step` instead of `start`: to resume one whose state was
        /// saved, or to let a flag skip ahead.
        pub fn runFrom(
            comptime flow: Self,
            ctx: *Context,
            state: *State,
            step: Step,
        ) anyerror!Result {
            comptime flow.check();
            var path: std.ArrayList(Step) = .empty;
            var done: std.ArrayList(Step) = .empty;
            var current: ?Step = step;
            while (current) |at| {
                if (path.items.len == max_steps) return error.FlowLoop;
                try path.append(ctx.arena, at);
                current = switch (at) {
                    inline else => |s| next: {
                        const spec = comptime @field(flow.steps, @tagName(s));
                        const title = ctx.translate(comptime titleOf(s, spec));
                        if (spec.when) |when| if (!when(state)) {
                            try report(ctx, s, .skipped, title, null);
                            break :next spec.next orelse
                                if (spec.decide) |d| decided(d, state) else null;
                        };
                        if (spec.ask) |ask| try askFields(ctx, state, "", &.{ask});
                        if (spec.form.len > 0) {
                            const heading = if (spec.title.len > 0) title else "";
                            try askFields(ctx, state, heading, spec.form);
                        }
                        if (spec.run) |action| {
                            if (ctx.dry_run and !spec.probe) {
                                try report(ctx, s, .dry_run, title, null);
                            } else {
                                const started = Io.Timestamp.now(ctx.io, .awake);
                                action(ctx, state) catch |err| {
                                    try report(ctx, s, .failed, title, .{ .err = err });
                                    try flow.undoAll(ctx, state, done.items);
                                    return err;
                                };
                                const finished = Io.Timestamp.now(ctx.io, .awake);
                                const elapsed = started.durationTo(finished);
                                try report(ctx, s, .done, title, .{ .elapsed = elapsed });
                                if (spec.undo != null) try done.append(ctx.arena, s);
                            }
                        }
                        break :next if (spec.decide) |d| decided(d, state) else spec.next;
                    },
                };
            }
            return .{ .path = path.items };
        }

        fn decided(comptime d: Decide, state: *const State) ?Step {
            const target = d.by(state) orelse return null;
            for (d.to) |allowed| if (allowed == target) return target;
            std.debug.panic("cli.Flow: decide chose {t}, which its `to` does not list", .{target});
        }

        fn undoAll(comptime flow: Self, ctx: *Context, state: *State, done: []const Step) !void {
            var i = done.len;
            while (i > 0) {
                i -= 1;
                switch (done[i]) {
                    inline else => |s| {
                        const spec = comptime @field(flow.steps, @tagName(s));
                        const title = ctx.translate(comptime titleOf(s, spec));
                        if (spec.undo) |undo| {
                            if (undo(ctx, state)) {
                                try report(ctx, s, .undone, title, null);
                            } else |err| {
                                try report(ctx, s, .undo_failed, title, .{ .err = err });
                            }
                        }
                    },
                }
            }
        }

        fn titleOf(comptime s: Step, comptime spec: Spec) []const u8 {
            if (spec.title.len > 0) return spec.title;
            if (spec.ask) |ask| return ask.label;
            if (spec.form.len > 0) return spec.form[0].label;
            return @tagName(s);
        }

        /// Compile-time checks of the graph and its questions.
        fn check(comptime flow: Self) void {
            for (@typeInfo(Step).@"enum".field_names) |name| {
                const spec = @field(flow.steps, name);
                if (spec.next != null and spec.decide != null) {
                    @compileError("cli.Flow step ." ++ name ++ ": give .next or .decide, not both");
                }
                if (spec.undo != null and spec.run == null) {
                    @compileError("cli.Flow step ." ++ name ++ ": .undo needs .run");
                }
                if (spec.ask != null and spec.form.len > 0) {
                    @compileError("cli.Flow step ." ++ name ++ ": give .ask or .form, not both");
                }
                const asks: []const Ask = if (spec.ask) |ask| &.{ask} else spec.form;
                for (asks) |ask| {
                    if (!@hasField(State, ask.field)) {
                        @compileError("cli.Flow step ." ++ name ++ ": " ++ @typeName(State) ++
                            " has no field " ++ ask.field);
                    }
                    _ = Asked(@FieldType(State, ask.field));
                }
            }
        }

        /// Asks the questions whose fields no flag gave: as one form when there are several
        /// and the asker can, else one at a time.
        fn askFields(
            ctx: *Context,
            state: *State,
            title: []const u8,
            comptime asks: []const Ask,
        ) anyerror!void {
            var open: [asks.len]bool = undefined;
            inline for (asks, &open) |ask, *o| o.* = !givenAsFlag(ctx, ask.field);
            if (std.mem.indexOfScalar(bool, &open, true) == null) return;
            // Only a run at a terminal is asked, whoever asks.
            const custom = if (ctx.interactive) ctx.asker else null;
            const asker = custom orelse if (ctx.interactive and ctx.in != null)
                lineAsker(ctx)
            else {
                // Nobody to ask: keep the values, unless a question must be answered.
                inline for (asks, open) |ask, o| if (o and ask.required) {
                    try ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error");
                    try Messages.render(ctx.err, ctx.messages.flow_unanswered, &.{
                        ctx.translate(ask.label),
                        comptime text.kebab(ask.field),
                    });
                    try ctx.err.writeByte('\n');
                    return ctx.exit(2);
                };
                return;
            };
            var asked: [asks.len]Question = undefined;
            var n: usize = 0;
            inline for (asks, open) |ask, o| if (o) {
                const label = if (ask.label_fn) |f|
                    try f(ctx, state)
                else
                    ctx.translate(ask.label);
                const current = @field(state, ask.field);
                asked[n] = try questionFor(@FieldType(State, ask.field), ctx.arena, label, current);
                asked[n].secret = ask.secret;
                n += 1;
            };
            var as_form = false;
            if (asker.form) |form| if (n > 1) {
                if (!try form(asker.context, ctx.arena, title, asked[0..n])) return canceled(ctx);
                as_form = true;
            };
            n = 0;
            inline for (asks, open) |ask, o| if (o) {
                const q = &asked[n];
                n += 1;
                const T = @FieldType(State, ask.field);
                const field = &@field(state, ask.field);
                // A form's typed answer that does not parse is asked for again on its own.
                if (!as_form or !try setAnswer(T, ctx.arena, field, q.answer)) {
                    if (!try askOne(asker, ctx.arena, q)) return canceled(ctx);
                    if (!try setAnswer(T, ctx.arena, field, q.answer)) return canceled(ctx);
                }
            };
        }

        fn canceled(ctx: *Context) anyerror!void {
            try ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error");
            try ctx.err.print("{s}\n", .{ctx.messages.flow_canceled});
            return ctx.exit(1);
        }
    };
}

fn givenAsFlag(ctx: *const Context, field: []const u8) bool {
    for (ctx.occurrences) |occurrence| {
        if (std.mem.eql(u8, occurrence.flag.field, field)) return true;
    }
    return false;
}

/// The type asked for a field of type `T` (the child of an optional); a compile error for
/// a type that cannot be asked for.
fn Asked(comptime T: type) type {
    const Base = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    const ok = Base == bool or @typeInfo(Base) == .@"enum" or typed(Base) or
        (isList(Base) and typed(@typeInfo(Base).pointer.child));
    if (!ok) @compileError("cli.Flow: cannot ask for a " ++ @typeName(T));
    return Base;
}

/// Asked by typing it in: text, a number, or a type with `parse`.
fn typed(comptime T: type) bool {
    return T == []const u8 or @typeInfo(T) == .int or @typeInfo(T) == .float or
        (@typeInfo(T) == .@"struct" and @hasDecl(T, "parse"));
}

/// A list of things typed in, separated by commas.
fn isList(comptime T: type) bool {
    return T != []const u8 and @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice;
}

/// Each element of a list answer: `a, b,c` is `a`, `b`, `c`; empty pieces are dropped.
fn listItems(answer: []const u8) ListItems {
    return .{ .parts = std.mem.splitScalar(u8, answer, ',') };
}

const ListItems = struct {
    parts: std.mem.SplitIterator(u8, .scalar),

    fn next(it: *ListItems) ?[]const u8 {
        while (it.parts.next()) |part| {
            const item = std.mem.trim(u8, part, " \t");
            if (item.len > 0) return item;
        }
        return null;
    }
};

/// The question for a field of type `T` whose value is `current`.
fn questionFor(comptime T: type, arena: Allocator, label: []const u8, current: T) !Question {
    const Base = Asked(T);
    const value: ?Base = current;
    if (Base == bool) return .{ .label = label, .answer = .{ .confirm = value orelse false } };
    if (@typeInfo(Base) == .@"enum") {
        const names = comptime enumNames(Base);
        var default: usize = 0;
        if (value) |c| for (names, 0..) |name, i| {
            if (std.mem.eql(u8, name, @tagName(c))) default = i;
        };
        return .{ .label = label, .choices = &names, .answer = .{ .select = default } };
    }
    var shown: []const u8 = "";
    if (value) |c| shown = if (comptime isList(Base)) list: {
        var out: std.ArrayList(u8) = .empty;
        for (c, 0..) |item, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            try out.appendSlice(arena, try showText(arena, item));
        }
        break :list out.items;
    } else try showText(arena, c);
    const Item = if (comptime isList(Base)) @typeInfo(Base).pointer.child else Base;
    const accepts = struct {
        fn accepts(text_in: []const u8) bool {
            if (@typeInfo(T) == .optional and text_in.len == 0) return true;
            if (comptime !isList(Base)) return parseText(Base, text_in) != null;
            var items = listItems(text_in);
            while (items.next()) |item| if (parseText(Item, item) == null) return false;
            return true;
        }
    }.accepts;
    const label_of_item = comptime values.label(Item);
    return .{
        .label = label,
        .accepts = if (Item == []const u8) null else accepts,
        .expected = if (comptime isList(Base)) "list of " ++ label_of_item else label_of_item,
        .answer = .{ .text = shown },
    };
}

fn showText(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
    if (@TypeOf(value) == []const u8) return value;
    return std.fmt.allocPrint(arena, "{any}", .{value});
}

fn parseText(comptime Base: type, text_in: []const u8) ?Base {
    return switch (@typeInfo(Base)) {
        .int => std.fmt.parseInt(Base, text_in, 0) catch null,
        .float => std.fmt.parseFloat(Base, text_in) catch null,
        else => if (Base == []const u8) text_in else Base.parse(text_in) catch null,
    };
}

/// Sets `field` from `answer`, a list in `arena`; false when typed text does not parse.
fn setAnswer(
    comptime T: type,
    arena: Allocator,
    field: *T,
    answer: Question.Answer,
) Allocator.Error!bool {
    const Base = Asked(T);
    switch (answer) {
        .confirm => |yes| if (Base == bool) {
            field.* = yes;
        },
        .select => |index| if (@typeInfo(Base) == .@"enum") {
            const names = comptime enumNames(Base);
            field.* = std.meta.stringToEnum(Base, names[index]).?;
        },
        .text => |text_in| {
            if (Base == bool or @typeInfo(Base) == .@"enum") unreachable;
            if (@typeInfo(T) == .optional and text_in.len == 0) {
                field.* = null;
            } else if (comptime isList(Base)) {
                const Item = @typeInfo(Base).pointer.child;
                var list: std.ArrayList(Item) = .empty;
                var items = listItems(text_in);
                while (items.next()) |item| {
                    try list.append(arena, parseText(Item, item) orelse return false);
                }
                field.* = list.items;
            } else {
                field.* = parseText(Base, text_in) orelse return false;
            }
        },
    }
    return true;
}

/// Asks `q` on its own, writing the answer into it; false when there was none. Typed text
/// that `q` does not accept is asked for again, three times at most.
pub fn askOne(asker: Asker, arena: Allocator, q: *Question) anyerror!bool {
    switch (q.answer) {
        .confirm => |default| {
            q.answer.confirm = try asker.confirm(asker.context, q.label, default) orelse
                return false;
        },
        .select => |default| {
            q.answer.select = try asker.select(asker.context, q.label, q.choices, default) orelse
                return false;
        },
        .text => |default| for (0..3) |_| {
            const answer = try asker.text(asker.context, arena, q.label, default, q.secret) orelse
                return false;
            if (q.accepts == null or q.accepts.?(answer)) {
                q.answer.text = answer;
                return true;
            }
            if (asker.reject) |reject| try reject(asker.context, answer, q.expected);
        } else return false,
    }
    return true;
}

fn enumNames(comptime E: type) [@typeInfo(E).@"enum".field_names.len][]const u8 {
    var names: [@typeInfo(E).@"enum".field_names.len][]const u8 = undefined;
    for (&names, @typeInfo(E).@"enum".field_names) |*out, name| out.* = name;
    return names;
}

const Outcome = enum { done, failed, skipped, dry_run, undone, undo_failed };

const Detail = union(enum) { elapsed: Io.Duration, err: anyerror };

/// One line on standard error, or one JSON object on standard output under `-o json`.
fn report(
    ctx: *Context,
    step: anytype,
    outcome: Outcome,
    title: []const u8,
    detail: ?Detail,
) !void {
    if (ctx.output == .json or ctx.output == .jsonl) {
        var json: std.json.Stringify = .{ .writer = ctx.out };
        try json.beginObject();
        try json.objectField("step");
        try json.write(@tagName(step));
        try json.objectField("title");
        try json.write(title);
        try json.objectField("outcome");
        try json.write(@tagName(outcome));
        if (detail) |d| switch (d) {
            .elapsed => |e| {
                try json.objectField("ms");
                try json.write(@divTrunc(e.toNanoseconds(), std.time.ns_per_ms));
            },
            .err => |err| {
                try json.objectField("error");
                try json.write(@errorName(err));
            },
        };
        try json.endObject();
        try ctx.out.writeByte('\n');
        return;
    }
    // `-q` keeps the lines about what went wrong, and drops the rest.
    if (ctx.quiet and (outcome == .done or outcome == .skipped or outcome == .dry_run)) return;
    const m = ctx.messages;
    const w = ctx.err;
    switch (outcome) {
        .done => {
            try w.print("✓ {s}", .{title});
            if (detail) |d| try writeElapsed(w, d.elapsed);
        },
        .failed => try Messages.render(w, m.flow_failed, &.{ title, @errorName(detail.?.err) }),
        .skipped => try Messages.render(w, m.flow_skipped, &.{title}),
        .dry_run => try Messages.render(w, m.flow_dry_run, &.{title}),
        .undone => try Messages.render(w, m.flow_undone, &.{title}),
        .undo_failed => try Messages.render(
            w,
            m.flow_undo_failed,
            &.{ title, @errorName(detail.?.err) },
        ),
    }
    try w.writeByte('\n');
    // A progress line, so it shows now, even on an `Environment.err` that buffers.
    try w.flush();
}

fn writeElapsed(w: *Io.Writer, elapsed: Io.Duration) !void {
    const ms = @divTrunc(elapsed.toNanoseconds(), std.time.ns_per_ms);
    if (ms < 1000) return w.print(" ({d}ms)", .{ms});
    try w.print(" ({d}.{d}s)", .{ @divTrunc(ms, 1000), @divTrunc(@rem(ms, 1000), 100) });
}

/// Writes the flow as a Mermaid flowchart: a box per step (a diamond where `.decide`
/// chooses), an arrow per possible next step, and `done` where the flow can end.
pub fn writeMermaid(comptime flow: anytype, w: *Io.Writer) Io.Writer.Error!void {
    const Self = @TypeOf(flow);
    const Step = @TypeOf(flow.start);
    try w.writeAll("flowchart TD\n");
    var ends = false;
    inline for (@typeInfo(Step).@"enum".field_names) |name| {
        const spec = @field(flow.steps, name);
        const title = comptime Self.titleOf(@field(Step, name), spec);
        if (spec.decide != null) {
            try w.print("  {s}{{\"{s}\"}}\n", .{ name, title });
        } else {
            try w.print("  {s}[\"{s}\"]\n", .{ name, title });
        }
        if (spec.next) |next| try w.print("  {s} --> {t}\n", .{ name, next });
        if (spec.decide) |d| {
            for (d.to) |target| try w.print("  {s} --> {t}\n", .{ name, target });
            try w.print("  {s} -.-> done\n", .{name});
            ends = true;
        }
        if (spec.next == null and spec.decide == null) {
            try w.print("  {s} --> done\n", .{name});
            ends = true;
        }
    }
    if (ends) try w.writeAll("  done((done))\n");
}

/// The default asker: one line of text per question, on standard error, answers read from
/// standard input. Needs `ctx` to outlive the asker.
pub fn lineAsker(ctx: *Context) Asker {
    return .{
        .context = ctx,
        .confirm = lineConfirm,
        .select = lineSelect,
        .text = lineText,
        .reject = lineReject,
    };
}

fn lineReject(context: ?*anyopaque, answer: []const u8, expected: []const u8) anyerror!void {
    const ctx: *Context = @ptrCast(@alignCast(context.?));
    try ctx.theme.writePrefix(ctx.err, ctx.err_color, ctx.app_name, .@"error");
    try Messages.render(ctx.err, ctx.messages.flow_rejected, &.{ answer, expected });
    try ctx.err.writeByte('\n');
}

fn readLine(ctx: *Context, label: []const u8, secret: bool) !?[]const u8 {
    const flag: Flag = .{
        .name = "answer",
        .field = "answer",
        .kind = .value,
        .secret = secret,
        .check = anyText,
    };
    return prompt.line(.{
        .io = ctx.io,
        .arena = ctx.arena,
        .in = ctx.in.?,
        .out = ctx.err,
        .terminal = ctx.terminal,
        .label = label,
        .flag = &flag,
    }) catch |err| switch (err) {
        error.EndOfStream => null,
        else => |e| e,
    };
}

fn anyText(_: []const u8) bool {
    return true;
}

fn lineConfirm(context: ?*anyopaque, label: []const u8, default: bool) anyerror!?bool {
    const ctx: *Context = @ptrCast(@alignCast(context.?));
    const hint: []const u8 = if (default) "Y/n" else "y/N";
    const question = try std.fmt.allocPrint(ctx.arena, "{s} [{s}]", .{ label, hint });
    for (0..3) |_| {
        const answer = try readLine(ctx, question, false) orelse return null;
        if (answer.len == 0) return default;
        if (Flag.parseBool(answer)) |yes| return yes;
        if (std.ascii.eqlIgnoreCase(answer, "y")) return true;
        if (std.ascii.eqlIgnoreCase(answer, "n")) return false;
    }
    return null;
}

fn lineSelect(
    context: ?*anyopaque,
    label: []const u8,
    choices: []const []const u8,
    default: usize,
) anyerror!?usize {
    const ctx: *Context = @ptrCast(@alignCast(context.?));
    try ctx.err.print("{s}\n", .{label});
    for (choices, 1..) |choice, n| {
        const mark: []const u8 = if (n - 1 == default) "*" else " ";
        try ctx.err.print("{s} {d}) {s}\n", .{ mark, n, choice });
    }
    const question = try std.fmt.allocPrint(
        ctx.arena,
        "[1-{d}, default {d}]",
        .{ choices.len, default + 1 },
    );
    for (0..3) |_| {
        const answer = try readLine(ctx, question, false) orelse return null;
        if (answer.len == 0) return default;
        if (std.fmt.parseInt(usize, answer, 10)) |n| {
            if (n >= 1 and n <= choices.len) return n - 1;
        } else |_| for (choices, 0..) |choice, i| {
            if (std.ascii.eqlIgnoreCase(choice, answer)) return i;
        }
    }
    return null;
}

fn lineText(
    context: ?*anyopaque,
    arena: Allocator,
    label: []const u8,
    default: []const u8,
    secret: bool,
) anyerror!?[]const u8 {
    const ctx: *Context = @ptrCast(@alignCast(context.?));
    const question = if (default.len > 0 and !secret)
        try std.fmt.allocPrint(arena, "{s} [{s}]", .{ label, default })
    else
        label;
    const answer = try readLine(ctx, question, secret) orelse return null;
    return if (answer.len == 0) default else answer;
}

/// Answers given in advance, for tests: `confirm` reads `y`/`n` (or any boolean word),
/// `select` a choice's name or number, `text` the answer as it is. Running out of
/// answers is an unanswered question. A form takes one answer per question, in order,
/// and is counted in `forms`.
pub const Script = struct {
    answers: []const []const u8,
    next: usize = 0,
    /// The forms asked so far.
    forms: usize = 0,

    /// The script as an `Asker`; `script` must outlive it.
    pub fn asker(script: *Script) Asker {
        return .{
            .context = script,
            .confirm = confirm,
            .select = select,
            .text = textAnswer,
            .form = form,
        };
    }

    fn form(
        context: ?*anyopaque,
        arena: Allocator,
        _: []const u8,
        questions: []Question,
    ) anyerror!bool {
        const script: *Script = @ptrCast(@alignCast(context.?));
        script.forms += 1;
        for (questions) |*q| if (!try askOne(script.asker(), arena, q)) return false;
        return true;
    }

    fn take(context: ?*anyopaque) ?[]const u8 {
        const script: *Script = @ptrCast(@alignCast(context.?));
        if (script.next == script.answers.len) return null;
        defer script.next += 1;
        return script.answers[script.next];
    }

    fn confirm(context: ?*anyopaque, _: []const u8, default: bool) anyerror!?bool {
        const answer = take(context) orelse return null;
        if (answer.len == 0) return default;
        if (std.ascii.eqlIgnoreCase(answer, "y")) return true;
        if (std.ascii.eqlIgnoreCase(answer, "n")) return false;
        return Flag.parseBool(answer) orelse error.BadScriptedAnswer;
    }

    fn select(
        context: ?*anyopaque,
        _: []const u8,
        choices: []const []const u8,
        default: usize,
    ) anyerror!?usize {
        const answer = take(context) orelse return null;
        if (answer.len == 0) return default;
        for (choices, 0..) |choice, i| if (std.mem.eql(u8, choice, answer)) return i;
        const n = std.fmt.parseInt(usize, answer, 10) catch return error.BadScriptedAnswer;
        if (n < 1 or n > choices.len) return error.BadScriptedAnswer;
        return n - 1;
    }

    fn textAnswer(
        context: ?*anyopaque,
        _: Allocator,
        _: []const u8,
        default: []const u8,
        _: bool,
    ) anyerror!?[]const u8 {
        const answer = take(context) orelse return null;
        return if (answer.len == 0) default else answer;
    }
};

const testing = std.testing;
const spec_zig = @import("spec.zig");
const App = @import("App.zig");
const cli_testing = @import("testing.zig");

const Deploy = struct {
    env: enum { staging, production } = .staging,
    migrate: bool = false,
    version: []const u8 = "",
    attempts: u8 = 0,
    fail_at: ?[]const u8 = null,
};
const deploy_flags = sets.flags(Deploy, field_.Set(.{field_.Spec(Deploy){ .fields = .{
    .env = .{ .help = "Where to deploy" },
    .migrate = .{ .help = "Run the migrations" },
    .fail_at = .{ .help = "Fail this step (for the tests)" },
} }}), .{});

const DeployStep = enum { version, where, build, ask_migrate, migrate, release, check, retry };

fn failIf(ctx: *Context, state: *Deploy, name: []const u8) !void {
    _ = ctx;
    if (state.fail_at) |at| if (std.mem.eql(u8, at, name)) return error.Broken;
}

fn build(ctx: *Context, state: *Deploy) !void {
    try failIf(ctx, state, "build");
    try ctx.out.print("built {s}\n", .{state.version});
}
fn migrate(ctx: *Context, state: *Deploy) !void {
    try failIf(ctx, state, "migrate");
    try ctx.out.writeAll("migrated\n");
}
fn rollback(ctx: *Context, _: *Deploy) !void {
    try ctx.out.writeAll("rolled back\n");
}
fn release(ctx: *Context, state: *Deploy) !void {
    try failIf(ctx, state, "release");
    try ctx.out.print("released to {t}\n", .{state.env});
}
fn unrelease(ctx: *Context, _: *Deploy) !void {
    try ctx.out.writeAll("unreleased\n");
}
fn afterMigrateQuestion(state: *const Deploy) ?DeployStep {
    return if (state.migrate) .migrate else .release;
}
fn checkHealth(_: *Context, state: *Deploy) !void {
    state.attempts += 1;
}
fn afterCheck(state: *const Deploy) ?DeployStep {
    return if (state.attempts < 3) .retry else null;
}
fn isProduction(state: *const Deploy) bool {
    return state.env == .production;
}

const deploy_flow: Flow(Deploy, DeployStep) = .{ .start = .version, .steps = .{
    .version = .{
        .ask = .{ .field = "version", .label = "Version", .required = true },
        .next = .where,
    },
    .where = .{ .ask = .{ .field = "env", .label = "Deploy where?" }, .next = .build },
    .build = .{ .title = "Build", .run = build, .next = .ask_migrate },
    .ask_migrate = .{
        .ask = .{ .field = "migrate", .label = "Run the migrations?" },
        .decide = .{ .to = &.{ .migrate, .release }, .by = afterMigrateQuestion },
    },
    .migrate = .{ .title = "Migrate", .run = migrate, .undo = rollback, .next = .release },
    .release = .{
        .title = "Release",
        .run = release,
        .undo = unrelease,
        .when = isProduction,
        .next = .check,
    },
    .check = .{
        .title = "Check",
        .run = checkHealth,
        .probe = true,
        .decide = .{ .to = &.{.retry}, .by = afterCheck },
    },
    .retry = .{ .next = .check },
} };

fn runDeploy(ctx: *Context, flags: Deploy) !void {
    var state = flags;
    const result = try deploy_flow.run(ctx, &state);
    try ctx.out.print("path:", .{});
    for (result.path) |step| try ctx.out.print(" {t}", .{step});
    try ctx.out.writeByte('\n');
}

const deploy_root = spec_zig.command(.{
    .name = "app",
    .subcommands = &.{spec_zig.command(.{
        .name = "deploy",
        .flags = deploy_flags,
        .dry_run = true,
        .output = true,
        .run = runDeploy,
    })},
});

/// Durations vary; the tests compare the lines without them.
fn withoutTimes(gpa: Allocator, text_in: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text_in.len) {
        if (std.mem.startsWith(u8, text_in[i..], " (") and
            std.mem.indexOfScalarPos(u8, text_in, i, ')') != null)
        {
            const close = std.mem.indexOfScalarPos(u8, text_in, i, ')').?;
            const inside = text_in[i + 2 .. close];
            if (std.mem.endsWith(u8, inside, "ms") or std.mem.endsWith(u8, inside, "s")) {
                i = close + 1;
                continue;
            }
        }
        try out.append(gpa, text_in[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Options for a run as at a terminal, where questions are asked.
const at_terminal: cli_testing.Options = .{ .stdin = "" };

fn expectRun(
    app: App,
    args: []const []const u8,
    options: cli_testing.Options,
    status: u8,
    out: []const u8,
    err: []const u8,
) !void {
    const r = try cli_testing.run(app, args, options);
    defer r.deinit();
    const plain_err = try withoutTimes(testing.allocator, r.err);
    defer testing.allocator.free(plain_err);
    testing.expectEqualStrings(err, plain_err) catch |e| {
        std.debug.print("stdout:\n{s}\n", .{r.out});
        return e;
    };
    try testing.expectEqualStrings(out, r.out);
    try testing.expectEqual(status, r.status);
}

test "flags answer the questions, and the path follows the decisions" {
    const app: App = .{ .root = &deploy_root };
    try expectRun(
        app,
        &.{ "deploy", "--version", "1.2", "--env", "production", "--migrate" },
        .{},
        0,
        "built 1.2\nmigrated\nreleased to production\npath: version where build ask_migrate " ++
            "migrate release check retry check retry check\n",
        "✓ Build\n✓ Migrate\n✓ Release\n✓ Check\n✓ Check\n✓ Check\n",
    );
    // Staging, no migrations: the release is skipped.
    try expectRun(
        app,
        &.{ "deploy", "--version", "1.3" },
        .{},
        0,
        "built 1.3\npath: version where build ask_migrate " ++
            "release check retry check retry check\n",
        "✓ Build\n- Release: skipped\n✓ Check\n✓ Check\n✓ Check\n",
    );
}

test "a required question without a terminal or a flag fails, naming the flag" {
    const app: App = .{ .root = &deploy_root };
    try expectRun(app, &.{"deploy"}, .{}, 2, "", "app: Version: no answer; pass --version\n");
}

test "questions are asked at a terminal, and a failure undoes what was done, latest first" {
    const app: App = .{ .root = &deploy_root };
    try expectRun(
        app,
        &.{ "deploy", "--fail-at", "check" },
        .{ .stdin = "2.0\n2\ny\n" },
        0,
        "built 2.0\nmigrated\nreleased to production\npath: version where build ask_migrate " ++
            "migrate release check retry check retry check\n",
        "Version: Deploy where?\n* 1) staging\n  2) production\n[1-2, default 1]: ✓ Build\n" ++
            "Run the migrations? [y/N]: ✓ Migrate\n✓ Release\n✓ Check\n✓ Check\n✓ Check\n",
    );
    try expectRun(
        app,
        &.{
            "deploy",    "--version", "3", "--env", "production", "--migrate",
            "--fail-at", "release",
        },
        .{},
        1,
        "built 3\nmigrated\nrolled back\n",
        "✓ Build\n✓ Migrate\n✗ Release: Broken\n↩ Migrate: undone\napp: Broken\n",
    );
}

test "a dry run asks and probes, and runs nothing else" {
    const app: App = .{ .root = &deploy_root };
    try expectRun(
        app,
        &.{ "deploy", "--version", "4", "--env", "production", "--dry-run" },
        .{},
        0,
        "path: version where build ask_migrate release check retry check retry check\n",
        "~ Build: not run (dry run)\n~ Release: not run (dry run)\n" ++
            "✓ Check\n✓ Check\n✓ Check\n",
    );
}

test "-o json reports each step as a JSON object" {
    const app: App = .{ .root = &deploy_root };
    const r = try cli_testing.run(app, &.{ "deploy", "--version", "5", "-o", "json" }, .{});
    defer r.deinit();
    try testing.expectEqual(0, r.status);
    const built = "{\"step\":\"build\",\"title\":\"Build\",\"outcome\":\"done\",\"ms\":";
    try testing.expect(std.mem.indexOf(u8, r.out, built) != null);
    const skipped = "{\"step\":\"release\",\"title\":\"Release\",\"outcome\":\"skipped\"}";
    try testing.expect(std.mem.indexOf(u8, r.out, skipped) != null);
}

test "a scripted asker answers, and running out of answers cancels" {
    var script: Script = .{ .answers = &.{ "9.9", "production", "n" } };
    const app: App = .{ .root = &deploy_root, .asker = script.asker() };
    // A scripted asker is asked only in an interactive run, as any asker is.
    try expectRun(
        app,
        &.{"deploy"},
        at_terminal,
        0,
        "built 9.9\nreleased to production\npath: version where build ask_migrate release " ++
            "check retry check retry check\n",
        "✓ Build\n✓ Release\n✓ Check\n✓ Check\n✓ Check\n",
    );
    var short: Script = .{ .answers = &.{"1.0"} };
    const canceled: App = .{ .root = &deploy_root, .asker = short.asker() };
    const said = "app: canceled; nothing more was done\n";
    try expectRun(canceled, &.{"deploy"}, at_terminal, 1, "", said);
}

test writeMermaid {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeMermaid(deploy_flow, &out.writer);
    try testing.expectEqualStrings(
        \\flowchart TD
        \\  version["Version"]
        \\  version --> where
        \\  where["Deploy where?"]
        \\  where --> build
        \\  build["Build"]
        \\  build --> ask_migrate
        \\  ask_migrate{"Run the migrations?"}
        \\  ask_migrate --> migrate
        \\  ask_migrate --> release
        \\  ask_migrate -.-> done
        \\  migrate["Migrate"]
        \\  migrate --> release
        \\  release["Release"]
        \\  release --> check
        \\  check{"Check"}
        \\  check --> retry
        \\  check -.-> done
        \\  retry["retry"]
        \\  retry --> check
        \\  done((done))
        \\
    , out.written());
}

const Signup = struct {
    name: []const u8 = "",
    plan: enum { free, pro } = .free,
    newsletter: bool = false,
    seats: u16 = 1,
};

const SignupStep = enum { details, seats, create };

fn afterDetails(state: *const Signup) ?SignupStep {
    return if (state.plan == .pro) .seats else .create;
}

fn createAccount(ctx: *Context, state: *Signup) !void {
    try ctx.out.print("{s}: {t}, {d} seats, newsletter {}\n", .{
        state.name, state.plan, state.seats, state.newsletter,
    });
}

const signup_flow: Flow(Signup, SignupStep) = .{ .start = .details, .steps = .{
    .details = .{
        .title = "Your account",
        .form = &.{
            .{ .field = "name", .label = "Name", .required = true },
            .{ .field = "plan", .label = "Plan" },
            .{ .field = "newsletter", .label = "Newsletter?" },
        },
        .decide = .{ .to = &.{ .seats, .create }, .by = afterDetails },
    },
    .seats = .{ .form = &.{.{ .field = "seats", .label = "Seats" }}, .next = .create },
    .create = .{ .title = "Create", .run = createAccount },
} };

fn runSignup(ctx: *Context, flags: Signup) !void {
    var state = flags;
    _ = try signup_flow.run(ctx, &state);
}

const signup_root = spec_zig.command(.{
    .name = "app",
    .subcommands = &.{spec_zig.command(.{ .name = "signup", .flags = Signup, .run = runSignup })},
});

test "a form asks its questions together, and a decision follows it" {
    var script: Script = .{ .answers = &.{ "ada", "pro", "y", "5" } };
    const app: App = .{ .root = &signup_root, .asker = script.asker() };
    const out = "ada: pro, 5 seats, newsletter true\n";
    try expectRun(app, &.{"signup"}, at_terminal, 0, out, "✓ Create\n");
    try testing.expectEqual(1, script.forms); // the one-question form is asked on its own
}

test "flags leave a form fewer questions, and one left is asked on its own" {
    var two: Script = .{ .answers = &.{ "free", "" } };
    const app: App = .{ .root = &signup_root, .asker = two.asker() };
    try expectRun(app, &.{ "signup", "--name", "bo" }, at_terminal, 0, "bo: free, 1 seats, " ++
        "newsletter false\n", "✓ Create\n");
    try testing.expectEqual(1, two.forms);
    var one: Script = .{ .answers = &.{"n"} };
    const app_one: App = .{ .root = &signup_root, .asker = one.asker() };
    const given: []const []const u8 = &.{ "signup", "--name", "cy", "--plan", "free" };
    try expectRun(app_one, given, at_terminal, 0, "cy: free, " ++
        "1 seats, newsletter false\n", "✓ Create\n");
    try testing.expectEqual(0, one.forms);
}

test "without a form, an asker asks a form's questions one at a time" {
    const app: App = .{ .root = &signup_root };
    try expectRun(app, &.{"signup"}, .{ .stdin = "di\n2\nn\n7\n" }, 0, "di: pro, 7 seats, " ++
        "newsletter false\n", "Name: Plan\n* 1) free\n  2) pro\n[1-2, default 1]: " ++
        "Newsletter? [y/N]: Seats [1]: ✓ Create\n");
    try expectRun(app, &.{"signup"}, .{}, 2, "", "app: Name: no answer; pass --name\n");
}

fn sloppyForm(context: ?*anyopaque, _: Allocator, title: []const u8, qs: []Question) !bool {
    const script: *Script = @ptrCast(@alignCast(context.?));
    try testing.expectEqualStrings("Your account", title);
    script.forms += 1;
    for (qs) |*q| switch (q.answer) {
        .text => q.answer = .{ .text = "" },
        .select => q.answer = .{ .select = 1 },
        .confirm => {},
    };
    return true;
}

fn canceledForm(_: ?*anyopaque, _: Allocator, _: []const u8, _: []Question) !bool {
    return false;
}

const Seats = struct {
    plan: enum { free, pro } = .free,
    seats: u16 = 1,
};

const seats_flow: Flow(Seats, enum { only }) = .{ .start = .only, .steps = .{ .only = .{
    .title = "Your account",
    .form = &.{
        .{ .field = "plan", .label = "Plan" },
        .{ .field = "seats", .label = "Seats" },
    },
} } };

fn runSeats(ctx: *Context, flags: Seats) !void {
    var state = flags;
    _ = try seats_flow.run(ctx, &state);
    try ctx.out.print("{t} {d}\n", .{ state.plan, state.seats });
}

const seats_root = spec_zig.command(.{
    .name = "app",
    .subcommands = &.{spec_zig.command(.{ .name = "seats", .flags = Seats, .run = runSeats })},
});

test "a form's answer that does not parse is asked for again; a canceled form cancels" {
    var script: Script = .{ .answers = &.{ "many", "3" } };
    var asker = script.asker();
    asker.form = sloppyForm;
    // "" did not parse, so Seats is asked on its own: "many" is refused, then 3.
    const seats: App = .{ .root = &seats_root, .asker = asker };
    try expectRun(seats, &.{"seats"}, at_terminal, 0, "pro 3\n", "");
    try testing.expectEqual(1, script.forms);
    asker.form = canceledForm;
    const canceling: App = .{ .root = &seats_root, .asker = asker };
    try expectRun(canceling, &.{"seats"}, at_terminal, 1, "", "app: " ++
        "canceled; nothing more was done\n");
}

test "runFrom starts at a given step" {
    var t: Io.Writer.Allocating = .init(testing.allocator);
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    var ctx: Context = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = arena.allocator(),
        .environ = &environ,
        .out = &t.writer,
        .err = &err.writer,
        .args = &.{},
        .path = &.{&signup_root},
        .occurrences = &.{},
        .app_name = "app",
        .quiet = true,
    };
    var state: Signup = .{ .name = "ed", .plan = .pro, .seats = 4 };
    const result = try signup_flow.runFrom(&ctx, &state, .create);
    try testing.expectEqualSlices(SignupStep, &.{.create}, result.path);
    try testing.expectEqualStrings("ed: pro, 4 seats, newsletter false\n", t.written());
}

/// Standard error as `App.run` gives it: buffered, so what is written shows only once
/// flushed.
const BufferedSink = struct {
    shown: std.ArrayList(u8) = .empty,
    buffer: [256]u8 = undefined,
    writer: Io.Writer,

    fn init(sink: *BufferedSink) void {
        sink.writer = .{ .buffer = &sink.buffer, .vtable = &.{ .drain = drain } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const sink: *BufferedSink = @fieldParentPtr("writer", w);
        const a = testing.allocator;
        sink.shown.appendSlice(a, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            sink.shown.appendSlice(a, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| {
            sink.shown.appendSlice(a, data[data.len - 1]) catch return error.WriteFailed;
        }
        return n + data[data.len - 1].len * splat;
    }
};

const Shown = struct {};
const ShownStep = enum { first, second };
var shown_sink: ?*BufferedSink = null;

fn firstStep(ctx: *Context, _: *Shown) !void {
    ctx.warn("careful", .{});
    try testing.expect(std.mem.endsWith(u8, shown_sink.?.shown.items, "warning: careful\n"));
}
fn secondStep(_: *Context, _: *Shown) !void {
    try testing.expect(std.mem.indexOf(u8, shown_sink.?.shown.items, "✓ First") != null);
}

const shown_flow: Flow(Shown, ShownStep) = .{ .start = .first, .steps = .{
    .first = .{ .title = "First", .run = firstStep, .next = .second },
    .second = .{ .title = "Second", .run = secondStep },
} };

const shown_root = spec_zig.command(.{ .name = "app", .run = runShown });

fn runShown(ctx: *Context) !void {
    var state: Shown = .{};
    _ = try shown_flow.run(ctx, &state);
}

test "step reports and warnings show on a buffered standard error as they happen" {
    var sink: BufferedSink = .{ .writer = undefined };
    sink.init();
    defer sink.shown.deinit(testing.allocator);
    shown_sink = &sink;
    defer shown_sink = null;
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const app: App = .{ .root = &shown_root };
    try testing.expectEqual(0, app.execute(.{
        .io = testing.io,
        .gpa = testing.allocator,
        .environ = &environ,
        .out = &out.writer,
        .err = &sink.writer,
    }, &.{}));
}

const Hosts = struct {
    hosts: []const []const u8 = &.{"a"},
    retries: u8 = 1,
};
const hosts_flags = sets.flags(Hosts, field_.none, .{ .fields = .{
    .hosts = .{ .split = ',' },
} });

const hosts_flow: Flow(Hosts, enum { hosts, retries, show }) = .{ .start = .hosts, .steps = .{
    .hosts = .{ .ask = .{ .field = "hosts", .label = "Hosts" }, .next = .retries },
    .retries = .{
        .ask = .{ .field = "retries", .label = "Retries", .label_fn = retriesLabel },
        .next = .show,
    },
    .show = .{ .title = "Show", .run = showHosts },
} };

fn retriesLabel(ctx: *Context, state: *const Hosts) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "Retries for {d} hosts", .{state.hosts.len});
}

fn showHosts(ctx: *Context, state: *Hosts) !void {
    const joined = try std.mem.join(ctx.arena, "|", state.hosts);
    try ctx.out.print("{s} {d}\n", .{ joined, state.retries });
}

fn runHosts(ctx: *Context, flags: Hosts) !void {
    var state = flags;
    _ = try hosts_flow.run(ctx, &state);
}

const hosts_root = spec_zig.command(.{ .name = "app", .flags = hosts_flags, .run = runHosts });

test "a list question, a label worked out when asked, and a refused answer said so" {
    const app: App = .{ .root = &hosts_root };
    try expectRun(app, &.{}, .{ .stdin = "x, y,,z\nn\n3\n" }, 0, "x|y|z 3\n", "Hosts [a]: " ++
        "Retries for 3 hosts [1]: app: invalid answer \"n\": expected int\n" ++
        "Retries for 3 hosts [1]: ✓ Show\n");
    // As flags, the list splits on commas and nothing is asked.
    const given: []const []const u8 = &.{ "--hosts", "p,q", "--retries", "2" };
    try expectRun(app, given, at_terminal, 0, "p|q 2\n", "✓ Show\n");
}
