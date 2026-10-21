//! `termancy ui demo [component]`: each registry component running live on sample data, to
//! see what it does before `termancy tui add` copies it in, or (with `--svg`) its first frame
//! as an SVG image, for documentation.

const std = @import("std");
const cli = @import("cli");
const field_ = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const group = @import("../tui/init.zig").group;

const registry = struct {
    const Confirm = @import("../tui/registry/confirm.zig");
    const Input = @import("../tui/registry/input.zig");
    const Textarea = @import("../tui/registry/textarea.zig");
    const List = @import("../tui/registry/list.zig");
    const Select = @import("../tui/registry/select.zig");
    const MultiSelect = @import("../tui/registry/multiselect.zig");
    const Filter = @import("../tui/registry/filter.zig");
    const Spinner = @import("../tui/registry/spinner.zig");
    const Progress = @import("../tui/registry/progress.zig");
    const MultiProgress = @import("../tui/registry/multiprogress.zig");
    const Table = @import("../tui/registry/table.zig");
    const Pager = @import("../tui/registry/pager.zig");
    const Form = @import("../tui/registry/form.zig");
    const Tabs = @import("../tui/registry/tabs.zig");
    const Viewport = @import("../tui/registry/viewport.zig");
    const Tree = @import("../tui/registry/tree.zig");
    const FilePicker = @import("../tui/registry/filepicker.zig");
    const chart = @import("../tui/registry/chart.zig");
    const Markdown = @import("../tui/registry/markdown.zig");
    const Prompts = @import("../tui/registry/prompts.zig");
};

const Flags = struct {
    svg: bool = false,
    width: u16 = 64,
    height: u16 = 16,
};
const flags_flags = cli.flags(Flags, field_.Set(.{field_.Spec(Flags){ .fields = .{
    .svg = .{ .help = "Print the first frame as an SVG image instead of running it" },
    .width = .{ .help = "Columns of the --svg image", .checks = &.{ .min(20), .max(300) } },
    .height = .{ .help = "Rows of the --svg image", .checks = &.{ .min(4), .max(200) } },
} }}), .{});

pub const command = cli.command(.{
    .name = "demo",
    .summary = "Try a component on sample data",
    .description =
    \\Run a component of the registry on sample data, as it would run in your project after
    \\termancy tui add. Without a name, list the components that have a demo. q or esc ends a
    \\demo of a component that does not end by itself.
    ,
    .group = group,
    .flags = flags_flags,
    .args = .{ .max = 1, .usage = "[component]", .complete = completeDemos },
    .examples =
    \\termancy ui demo
    \\termancy ui demo tree
    \\termancy ui demo chart --svg > chart.svg
    ,
    .run = run,
});

const Demo = struct {
    name: []const u8,
    run: *const fn (r: *Runner) anyerror!void,
};

const demos = [_]Demo{
    .{ .name = "chart", .run = chart },
    .{ .name = "confirm", .run = confirm },
    .{ .name = "filepicker", .run = filepicker },
    .{ .name = "filter", .run = filter },
    .{ .name = "flow", .run = flowDemo },
    .{ .name = "form", .run = formDemo },
    .{ .name = "input", .run = input },
    .{ .name = "list", .run = list },
    .{ .name = "markdown", .run = markdownDemo },
    .{ .name = "multiprogress", .run = multiprogress },
    .{ .name = "multiselect", .run = multiselect },
    .{ .name = "pager", .run = pager },
    .{ .name = "progress", .run = progress },
    .{ .name = "select", .run = select },
    .{ .name = "spinner", .run = spinner },
    .{ .name = "table", .run = table },
    .{ .name = "tabs", .run = tabs },
    .{ .name = "textarea", .run = textarea },
    .{ .name = "tree", .run = tree },
    .{ .name = "viewport", .run = viewport },
};

fn run(ctx: *cli.Context, flags: Flags) !void {
    if (ctx.args.len == 0) {
        for (demos) |demo| try ctx.out.print("{s}\n", .{demo.name});
        return;
    }
    const name = ctx.args[0];
    const demo = for (demos) |demo| {
        if (std.mem.eql(u8, demo.name, name)) break demo;
    } else return ctx.usageError("no demo of \"{s}\"; termancy ui demo lists them", .{name});
    var runner: Runner = .{ .ctx = ctx, .flags = flags };
    try demo.run(&runner);
    if (!flags.svg and !runner.interrupted and !ctx.quiet) {
        // The flow demo shows `prompts` asking for a `cli.Flow`.
        const component = if (std.mem.eql(u8, name, "flow")) "prompts" else name;
        try ctx.err.print("Copy it into your project: termancy tui add {s}\n", .{component});
    }
    if (runner.interrupted) return term.exitInterrupted(ctx);
}

fn completeDemos(ctx: *cli.Context, _: []const u8) ![]const cli.Candidate {
    const out = try ctx.arena.alloc(cli.Candidate, demos.len);
    for (out, demos) |*candidate, demo| candidate.* = .{ .value = demo.name };
    return out;
}

/// Runs a demo's model live, or draws its first frame as SVG.
const Runner = struct {
    ctx: *cli.Context,
    flags: Flags,
    interrupted: bool = false,

    fn show(r: *Runner, comptime Model: type, model: *Model, options: tui.Options) !void {
        if (!r.flags.svg) {
            r.interrupted = try term.run(r.ctx, Model, model, options);
            return;
        }
        var sized = options;
        sized.size = .{ .width = r.flags.width, .height = r.flags.height };
        var output: std.Io.Writer.Allocating = .init(r.ctx.gpa);
        defer output.deinit();
        var program: tui.Program(Model) = .init(r.ctx.gpa, model, &output.writer, sized);
        defer program.deinit();
        try program.start();
        var screen: tui.testing.Screen = try .init(r.ctx.gpa, sized.size);
        defer screen.deinit();
        screen.write(output.written());
        try screen.writeSvg(r.ctx.out, .{});
    }
};

/// `Inner` plus q and esc to quit and a line saying so, for components that never end.
fn Quittable(comptime Inner: type) type {
    return struct {
        inner: Inner,

        const Self = @This();
        pub const Message = if (@hasDecl(Inner, "Message")) Inner.Message else void;

        pub fn start(q: *Self) tui.Cmd {
            return if (@hasDecl(Inner, "start")) q.inner.start() else .none;
        }

        pub fn update(q: *Self, msg: tui.Message(Message)) tui.Cmd {
            if (msg == .key and (msg.key.matches("q") or msg.key.matches("esc"))) return .quit;
            return q.inner.update(msg);
        }

        pub fn view(q: *const Self, w: *std.Io.Writer) anyerror!void {
            try q.inner.view(w);
            try w.writeAll("\n\n");
            try hint.paint(w, "q to quit");
        }
    };
}

const hint: tui.Style = .{ .fg = .{ .indexed = 240 } };

/// A view drawn by a function, for the components that are functions.
const Static = struct {
    draw: *const fn (w: *std.Io.Writer) std.Io.Writer.Error!void,

    pub fn update(_: *Static, _: tui.Msg) tui.Cmd {
        return .none;
    }

    pub fn view(s: *const Static, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try s.draw(w);
    }
};

const fruits: []const []const u8 = &.{
    "apple", "banana",      "cherry", "damson", "elderberry", "fig",
    "grape", "huckleberry", "kiwi",   "lemon",  "mango",      "nectarine",
};

const story =
    \\The tui library draws a model's view on the terminal and sends it every key, mouse
    \\event, and resize as a message; the model answers with commands: quit, set a timer,
    \\run some work in the background, or lend the terminal to an editor.
    \\
    \\Components are not part of the library. termancy tui add copies their source into your
    \\project, where they are yours to change; termancy tui diff shows what upstream changed
    \\since.
    \\
    \\Every frame rewrites only the lines that changed, inside a synchronized update.
;

fn chart(r: *Runner) !void {
    var model: Quittable(Static) = .{ .inner = .{ .draw = struct {
        fn draw(w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("requests  ");
            try registry.chart.sparkline(w, &.{ 3, 5, 4, 8, 12, 9, 14, 11, 7, 10, 15, 13 }, .{});
            try w.writeAll("\n\n");
            try registry.chart.bars(w, &.{
                .{ .label = "zig", .value = 42 },
                .{ .label = "rust", .value = 35.5 },
                .{ .label = "go", .value = 27 },
                .{ .label = "c", .value = 12.25 },
            }, .{ .width = 30 });
        }
    }.draw } };
    try r.show(@TypeOf(model), &model, .{});
}

fn confirm(r: *Runner) !void {
    var model: registry.Confirm = .{ .prompt = "Deploy to production?" };
    try r.show(registry.Confirm, &model, term.inline_options);
}

fn filepicker(r: *Runner) !void {
    var model: registry.FilePicker = try .init(r.ctx.gpa, r.ctx.io, ".", .{});
    defer model.deinit();
    model.height = 8;
    try r.show(registry.FilePicker, &model, term.inline_options);
}

fn filter(r: *Runner) !void {
    var model: registry.Filter = try .init(r.ctx.gpa, fruits);
    defer model.deinit();
    try r.show(registry.Filter, &model, term.inline_options);
}

/// A `cli.Flow` asking with the `prompts` component: the first page is one form, and what
/// it asks next depends on the answers.
const NewProject = struct {
    name: []const u8 = "",
    kind: enum { library, app } = .library,
    tests: bool = true,
};

const NewStep = enum { project, tests, create };

fn afterProject(state: *const NewProject) ?NewStep {
    return if (state.kind == .app) .tests else .create;
}

fn create(ctx: *cli.Context, state: *NewProject) !void {
    try ctx.out.print("created {s} ({t}{s})\n", .{
        state.name,
        state.kind,
        if (state.kind == .app and state.tests) ", with tests" else "",
    });
}

const new_project: cli.Flow(NewProject, NewStep) = .{ .start = .project, .steps = .{
    .project = .{
        .title = "New project",
        .form = &.{
            .{ .field = "name", .label = "Project name?", .required = true },
            .{ .field = "kind", .label = "What kind?" },
        },
        .decide = .{ .to = &.{ .tests, .create }, .by = afterProject },
    },
    .tests = .{ .ask = .{ .field = "tests", .label = "Add tests?" }, .next = .create },
    .create = .{ .title = "Create", .run = create },
} };

fn flowDemo(r: *Runner) !void {
    if (r.flags.svg) {
        // The flow's first page, as `prompts` draws it.
        var fields = [_]registry.Form.Field{
            .{
                .label = "Project name?",
                .kind = .{ .input = .{ .gpa = r.ctx.gpa, .prompt = "" } },
            },
            .{
                .label = "What kind?",
                .kind = .{ .choice = .{ .options = &.{ "library", "app" } } },
            },
        };
        defer for (&fields) |*field| field.deinit();
        var model: registry.Form = .{ .fields = &fields, .title = "New project" };
        return r.show(registry.Form, &model, term.inline_options);
    }
    var prompts: registry.Prompts = .{ .gpa = r.ctx.gpa, .io = r.ctx.io, .environ = r.ctx.environ };
    defer prompts.deinit();
    r.ctx.asker = prompts.asker(cli.flow.Asker);
    r.ctx.interactive = true;
    var state: NewProject = .{};
    _ = try new_project.run(r.ctx, &state);
}

fn formDemo(r: *Runner) !void {
    const gpa = r.ctx.gpa;
    var fields = [_]registry.Form.Field{
        .{
            .label = "Name",
            .kind = .{ .input = .{ .gpa = gpa, .placeholder = "Ada" } },
            .required = true,
        },
        .{
            .label = "Email",
            .description = "We never share it.",
            .kind = .{ .input = .{ .gpa = gpa } },
        },
        .{ .label = "Plan", .kind = .{ .choice = .{ .options = &.{ "free", "pro", "team" } } } },
        .{ .label = "Password", .kind = .{ .input = .{ .gpa = gpa, .password = true } } },
    };
    defer for (&fields) |*field| field.deinit();
    var model: registry.Form = .{ .fields = &fields };
    try r.show(registry.Form, &model, term.inline_options);
}

fn input(r: *Runner) !void {
    var model: registry.Input = .{
        .gpa = r.ctx.gpa,
        .prompt = "Name: ",
        .placeholder = "Ada Lovelace",
    };
    defer model.deinit();
    try r.show(registry.Input, &model, term.inline_options);
}

fn list(r: *Runner) !void {
    var model: Quittable(registry.List) = .{ .inner = .{ .items = fruits, .height = 6 } };
    try r.show(@TypeOf(model), &model, term.inline_options);
}

fn markdownDemo(r: *Runner) !void {
    var model: registry.Markdown = .{ .gpa = r.ctx.gpa, .source =
        \\# Release notes
        \\
        \\Everything **passed**, and `zig build` is *fast*.
        \\
        \\- one
        \\- [x] two
        \\
        \\> Quoted, with a [link](https://ziglang.org).
        \\
        \\```zig
        \\const std = @import("std");
        \\```
    };
    defer model.deinit();
    try r.show(@TypeOf(model), &model, .{ .alt_screen = true });
}

fn multiprogress(r: *Runner) !void {
    const zero: std.Io.Timestamp = .zero;
    var tasks = [_]registry.MultiProgress.Task{
        .{ .label = "download", .bar = .{ .total = 100, .width = 30 } },
        .{ .label = "verify", .bar = .{ .total = 100, .width = 30 } },
        .{ .label = "install", .bar = .{ .total = 100, .width = 30 } },
    };
    tasks[0].bar.set(100, zero);
    tasks[1].bar.set(64, zero);
    tasks[2].bar.set(12, zero);
    var model: Quittable(registry.MultiProgress) = .{ .inner = .{ .tasks = &tasks } };
    try r.show(@TypeOf(model), &model, term.inline_options);
}

fn multiselect(r: *Runner) !void {
    var model: registry.MultiSelect = try .init(r.ctx.gpa, .{ .items = fruits, .height = 6 });
    defer model.deinit();
    try r.show(registry.MultiSelect, &model, term.inline_options);
}

fn pager(r: *Runner) !void {
    var model: registry.Pager = try .init(r.ctx.gpa, story);
    defer model.deinit();
    try r.show(registry.Pager, &model, .{ .alt_screen = true });
}

fn progress(r: *Runner) !void {
    var model: Quittable(registry.Progress) = .{ .inner = .{ .total = 100, .show_eta = false } };
    model.inner.set(42, .zero);
    try r.show(@TypeOf(model), &model, term.inline_options);
}

fn select(r: *Runner) !void {
    var model: registry.Select = .{
        .header = "Pick a fruit",
        .list = .{ .items = fruits, .height = 6 },
    };
    try r.show(registry.Select, &model, term.inline_options);
}

fn spinner(r: *Runner) !void {
    var model: Quittable(registry.Spinner) = .{ .inner = .{ .title = "Fetching the index..." } };
    try r.show(@TypeOf(model), &model, term.inline_options);
}

fn table(r: *Runner) !void {
    var model: registry.Table = .{
        .columns = &.{ .{ .title = "Language" }, .{ .title = "Year", .@"align" = .end } },
        .rows = &.{
            &.{ "Zig", "2016" }, &.{ "Rust", "2010" },
            &.{ "Go", "2009" },  &.{ "C", "1972" },
        },
    };
    try r.show(registry.Table, &model, term.inline_options);
}

fn tabs(r: *Runner) !void {
    var model: Quittable(registry.Tabs) = .{ .inner = .{
        .titles = &.{ "Overview", "Details", "Help" },
        .contents = &.{
            "Everything is fine.",
            "Left and right switch tabs.",
            "q quits.",
        },
    } };
    try r.show(@TypeOf(model), &model, term.inline_options);
}

fn textarea(r: *Runner) !void {
    var model: registry.Textarea = .{
        .gpa = r.ctx.gpa,
        .placeholder = "Tell us more",
        .height = 5,
    };
    defer model.deinit();
    try r.show(registry.Textarea, &model, term.inline_options);
}

fn tree(r: *Runner) !void {
    var lib = [_]registry.Tree.Node{ .{ .label = "Program.zig" }, .{ .label = "Style.zig" } };
    var src = [_]registry.Tree.Node{
        .{ .label = "tui", .children = &lib, .expanded = true },
        .{ .label = "main.zig" },
    };
    var roots = [_]registry.Tree.Node{
        .{ .label = "src", .children = &src, .expanded = true },
        .{ .label = "build.zig" },
        .{ .label = "README.md" },
    };
    var model: Quittable(registry.Tree) = .{ .inner = .{ .roots = &roots } };
    try r.show(@TypeOf(model), &model, term.inline_options);
}

fn viewport(r: *Runner) !void {
    var model: Quittable(registry.Viewport) = .{ .inner = .{ .content = story, .height = 6 } };
    try r.show(@TypeOf(model), &model, term.inline_options);
}

const testing = std.testing;

const test_root = cli.command(.{ .name = "termancy", .subcommands = .{command} });

test "every demo draws a first frame" {
    const app: cli.App = .{ .root = &test_root };
    for (demos) |demo| {
        const result = try cli.testing.run(app, &.{ "demo", demo.name, "--svg" }, .{});
        defer result.deinit();
        testing.expectEqual(0, result.status) catch |err| {
            std.debug.print("{s}: {s}\n", .{ demo.name, result.err });
            return err;
        };
        try testing.expect(std.mem.startsWith(u8, result.out, "<svg "));
        try testing.expect(std.mem.indexOf(u8, result.out, "<text") != null);
    }
    const listed = try cli.testing.run(app, &.{"demo"}, .{});
    defer listed.deinit();
    try testing.expect(std.mem.startsWith(u8, listed.out, "chart\nconfirm\n"));
    const unknown = try cli.testing.run(app, &.{ "demo", "nope" }, .{});
    defer unknown.deinit();
    try testing.expectEqual(2, unknown.status);
}
