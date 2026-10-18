//! The files `snek cli init` and `snek cli add` write. Each template writes text that is
//! already formatted as `zig fmt` would leave it, so no formatter needs to run.
//!
//! A file with subcommands carries two marker lines that `add` inserts before:
//! `// snek:subcommands` inside `.subcommands = .{ ... }`, and `// snek:tests` inside a
//! `test { ... }` block, which references each child file so its tests run.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const flagspec = @import("flagspec.zig");
const Spec = flagspec.Spec;

pub const subcommands_marker = "// snek:subcommands";
pub const tests_marker = "// snek:tests";

/// Calls a template with an allocating writer and returns what it wrote.
pub fn render(
    arena: std.mem.Allocator,
    comptime template: anytype,
    args: anytype,
) std.mem.Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    // An allocating writer fails only when it cannot allocate.
    @call(.auto, template, .{&out.writer} ++ args) catch return error.OutOfMemory;
    return out.written();
}

pub const gitignore =
    \\.zig-cache/
    \\zig-out/
    \\zig-pkg/
    \\
;

/// `build.zig`: the executable `name` from `src/main.zig`, with `cli` and `cfg` imported from
/// the `snek` dependency; `run`, `test`, and `schema` steps.
pub fn buildZig(w: *Writer, name: []const u8) Writer.Error!void {
    try w.print(
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\    const snek = b.dependency("snek", .{{ .target = target, .optimize = optimize }});
        \\
        \\    const root_module = b.createModule(.{{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{{
        \\            .{{ .name = "cli", .module = snek.module("cli") }},
        \\            .{{ .name = "cfg", .module = snek.module("cfg") }},
        \\        }},
        \\    }});
        \\    const exe = b.addExecutable(.{{ .name = "{s}", .root_module = root_module }});
        \\    b.installArtifact(exe);
        \\
        \\    const run = b.addRunArtifact(exe);
        \\    run.step.dependOn(b.getInstallStep());
        \\    run.addPassthruArgs();
        \\    b.step("run", "Run {s}").dependOn(&run.step);
        \\
        \\    const tests = b.addTest(.{{ .root_module = root_module }});
        \\    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
        \\
        \\    // The settings' JSON Schema, built for this machine whatever the target.
        \\    const host_snek = b.dependency("snek", .{{ .target = b.graph.host }});
        \\    const schema = b.addExecutable(.{{
        \\        .name = "schema",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("src/settings.zig"),
        \\            .target = b.graph.host,
        \\            .imports = &.{{.{{ .name = "cfg", .module = host_snek.module("cfg") }}}},
        \\        }}),
        \\    }});
        \\    const schema_json = b.addRunArtifact(schema).captureStdOut(.{{}});
        \\    b.step("schema", "Write the settings' JSON Schema to zig-out/schema.json")
        \\        .dependOn(&b.addInstallFile(schema_json, "schema.json").step);
        \\}}
        \\
    , .{ name, name });
}

/// Where `build.zig.zon` gets `snek` from.
pub const Dependency = union(enum) {
    /// No entry yet; `zig fetch --save=snek <url>` adds one.
    none,
    /// A checkout, relative to the project.
    path: []const u8,
};

/// `build.zig.zon`. `package` must be a valid bare Zig identifier; `fingerprint` must belong
/// to it (see `fingerprint`).
pub fn buildZon(
    w: *Writer,
    package: []const u8,
    fingerprint_value: u64,
    dependency: Dependency,
) Writer.Error!void {
    assert(std.zig.isValidId(package));
    try w.print(
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x{x},
        \\    .minimum_zig_version = "0.17.0",
        \\
    , .{ package, fingerprint_value });
    switch (dependency) {
        .none => try w.writeAll("    .dependencies = .{},\n"),
        .path => |path| try w.print(
            \\    .dependencies = .{{
            \\        .snek = .{{ .path = "{f}" }},
            \\    }},
            \\
        , .{std.zig.fmtString(path)}),
    }
    try w.writeAll(
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
        \\
    );
}

/// A package fingerprint as `zig init` makes one: a random id in the low half (never 0 or
/// all ones) and the CRC-32 of the package name in the high half.
pub fn fingerprint(random: std.Random, package: []const u8) u64 {
    const id = random.intRangeLessThan(u32, 1, 0xffffffff);
    return @as(u64, std.hash.Crc32.hash(package)) << 32 | id;
}

/// `src/main.zig`: `main` and the root command, listing `hello` (`src/cmd/hello.zig`) at the
/// markers as `snek cli add` would.
pub fn mainZig(w: *Writer, name: []const u8) Writer.Error!void {
    try w.print(
        \\//! `{s}`: the entry point and the command tree.
        \\//!
        \\//! Each command lives in `src/cmd/`. `snek cli add <path...>` writes one and lists it
        \\//! at the `snek:subcommands` marker below.
        \\
        \\const std = @import("std");
        \\const cli = @import("cli");
        \\
        \\pub const version = "0.1.0";
        \\
        \\pub const root = cli.command(.{{
        \\    .name = "{s}",
        \\    .summary = "A command-line application built with snek",
        \\    .subcommands = .{{
        \\        @import("cmd/hello.zig").command,
        \\        {s}
        \\    }},
        \\}});
        \\
        \\pub fn main(init: std.process.Init) u8 {{
        \\    const app: cli.App = .{{ .root = &root, .version = version }};
        \\    return app.run(init);
        \\}}
        \\
        \\test {{
        \\    _ = @import("settings.zig");
        \\    _ = @import("cmd/hello.zig");
        \\    {s}
        \\}}
        \\
    , .{ name, name, subcommands_marker, tests_marker });
}

/// `src/settings.zig`: what the configuration file holds, and a `main` that prints its JSON
/// Schema for `zig build schema`.
pub fn settingsZig(w: *Writer, name: []const u8) Writer.Error!void {
    try w.print(
        \\//! What `{s}`'s configuration file holds. `zig build schema` writes the JSON Schema of
        \\//! `Settings` to `zig-out/schema.json`, from which
        \\//! `snek cfg init {s}.toml --schema zig-out/schema.json` writes a starter file and
        \\//! `snek cfg schema check` validates one.
        \\
        \\const std = @import("std");
        \\const cfg = @import("cfg");
        \\
        \\pub const Settings = struct {{
        \\    log_level: enum {{ debug, info, warn, err }} = .info,
        \\    server: struct {{
        \\        host: []const u8 = "localhost",
        \\        port: u16 = 8080,
        \\    }} = .{{}},
        \\
        \\    pub const meta = .{{ .log_level = .{{ .help = "How much to log" }} }};
        \\}};
        \\
        \\/// For `zig build schema`: prints the JSON Schema of `Settings`.
        \\pub fn main(init: std.process.Init) !void {{
        \\    var buffer: [4096]u8 = undefined;
        \\    var out = std.Io.File.stdout().writer(init.io, &buffer);
        \\    try cfg.schema.write(Settings, init.arena.allocator(), &out.interface);
        \\    try out.interface.flush();
        \\}}
        \\
        \\test "the defaults decode from an empty file" {{
        \\    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        \\    defer arena.deinit();
        \\
    ++ "    const settings = try cfg.decode(Settings, arena.allocator(), .empty_table, " ++
        ".{{}}, null);\n" ++
        \\    try std.testing.expectEqual(8080, settings.server.port);
        \\}}
        \\
    , .{ name, name });
}

pub fn readme(w: *Writer, name: []const u8) Writer.Error!void {
    try w.print(
        \\# {s}
        \\
        \\A command-line application built on the `cli` and `cfg` modules of snek.
        \\
        \\```sh
        \\zig build run -- --help
        \\zig build test
        \\snek cli add greet --flag name:string=world --summary "Greet someone"
        \\```
        \\
        \\The command tree starts in `src/main.zig`; each command is a file under `src/cmd/`.
        \\What the configuration file holds is `Settings` in `src/settings.zig`; for a starter
        \\file with every setting:
        \\
        \\```sh
        \\zig build schema
        \\snek cfg init {s}.toml --schema zig-out/schema.json
        \\```
        \\
    , .{ name, name });
}

/// A group: `src/cmd/<path>/main.zig`, a command with only subcommands.
pub fn group(w: *Writer, path: []const []const u8) Writer.Error!void {
    assert(path.len > 0);
    try w.writeAll("//! `");
    try writeWords(w, path);
    try w.print(
        \\`: the {s} commands.
        \\
        \\const cli = @import("cli");
        \\
        \\pub const command = cli.command(.{{
        \\    .name = "{s}",
        \\    .summary = "The {s} commands",
        \\    .subcommands = .{{
        \\        {s}
        \\    }},
        \\}});
        \\
        \\test {{
        \\    {s}
        \\}}
        \\
    , .{
        path[path.len - 1],
        path[path.len - 1],
        path[path.len - 1],
        subcommands_marker,
        tests_marker,
    });
}

/// What a leaf command is made from.
pub const Leaf = struct {
    /// The command path below the root: `config get`.
    path: []const []const u8,
    summary: []const u8 = "",
    flags: []const Spec = &.{},
    args_min: usize = 0,
    /// `null` for no limit.
    args_max: ?usize = 0,
};

/// The command `snek cli init` starts a project with, in `src/cmd/hello.zig`.
pub const hello: Leaf = .{
    .path = &.{"hello"},
    .summary = "Say hello",
    .flags = &.{.{
        .name = "name",
        .field = "name",
        .base = .string,
        .default = "\"world\"",
        .short = 'n',
        .help = "Who to greet",
    }},
};

/// A leaf: a `Flags` struct, the command, a handler that prints what it was given, and a
/// test that runs it.
pub fn leaf(w: *Writer, l: Leaf) Writer.Error!void {
    assert(l.path.len > 0);
    assert(l.args_max == null or l.args_max.? >= l.args_min);
    try w.writeAll("//! `");
    try writeWords(w, l.path);
    if (l.summary.len > 0) try w.print("`: {s}\n", .{l.summary}) else try w.writeAll("`.\n");
    try w.writeAll("\nconst std = @import(\"std\");\nconst cli = @import(\"cli\");\n\n");
    if (l.flags.len > 0) try flagsStruct(w, "Flags", l.flags);
    try commandSpec(w, l);
    try handler(w, l);
    try testBlock(w, l);
}

fn flagsStruct(w: *Writer, name: []const u8, flags: []const Spec) Writer.Error!void {
    try w.print("const {s} = struct {{\n", .{name});
    for (flags) |s| {
        try w.print("    {s}: ", .{s.field});
        try fieldType(w, s);
        if (s.default) |default| {
            try w.print(" = {s}", .{default});
        } else if (s.list) {
            try w.writeAll(" = &.{}");
        } else if (s.count) {
            try w.writeAll(" = 0");
        } else if (s.base == .bool) {
            try w.writeAll(" = false");
        } else if (!s.required) {
            try w.writeAll(" = null");
        }
        try w.writeAll(",\n");
    }
    var any = false;
    for (flags) |s| {
        if (s.short == null and s.help.len == 0 and !s.count) continue;
        if (!any) try w.writeAll("\n    pub const meta = .{\n");
        any = true;
        try w.print("        .{s} = .{{", .{s.field});
        var first = true;
        if (s.short) |short| try metaEntry(w, &first, "short", "'{c}'", short);
        if (s.count) try metaEntry(w, &first, "count", "{s}", "true");
        if (s.help.len > 0) {
            try metaEntry(w, &first, "help", "\"{f}\"", std.zig.fmtString(s.help));
        }
        try w.writeAll(" },\n");
    }
    if (any) try w.writeAll("    };\n");
    try w.writeAll("};\n\n");
}

fn metaEntry(
    w: *Writer,
    first: *bool,
    comptime name: []const u8,
    comptime fmt: []const u8,
    value: anytype,
) Writer.Error!void {
    try w.writeAll(if (first.*) " ." ++ name ++ " = " else ", ." ++ name ++ " = ");
    try w.print(fmt, .{value});
    first.* = false;
}

fn fieldType(w: *Writer, s: Spec) Writer.Error!void {
    if (s.isOptional()) try w.writeByte('?');
    if (s.list) try w.writeAll("[]const ");
    switch (s.base) {
        .bool => try w.writeAll("bool"),
        .int => |int| try w.print("{c}{d}", .{ @as(u8, if (int.signed) 'i' else 'u'), int.bits }),
        .float => |bits| try w.print("f{d}", .{bits}),
        .string => try w.writeAll("[]const u8"),
        .@"enum" => |choices| {
            try w.writeAll("enum { ");
            for (choices, 0..) |choice, i| {
                if (i > 0) try w.writeAll(", ");
                try writeField(w, choice);
            }
            try w.writeAll(" }");
        },
    }
}

/// `very-slow` as a Zig identifier: `very_slow`.
fn writeField(w: *Writer, word: []const u8) Writer.Error!void {
    for (word) |c| try w.writeByte(if (c == '-') '_' else c);
}

fn commandSpec(w: *Writer, l: Leaf) Writer.Error!void {
    try w.print("pub const command = cli.command(.{{\n    .name = \"{s}\",\n", .{
        l.path[l.path.len - 1],
    });
    if (l.summary.len > 0) {
        try w.print("    .summary = \"{f}\",\n", .{std.zig.fmtString(l.summary)});
    }
    if (l.flags.len > 0) try w.writeAll("    .flags = Flags,\n");
    if (l.args_max == null or l.args_max.? > 0) {
        try w.print("    .args = .{{ .min = {d}, .max = ", .{l.args_min});
        if (l.args_max) |max| try w.print("{d}", .{max}) else try w.writeAll("null");
        try w.writeAll(", .usage = \"");
        try argsUsage(w, l.args_min, l.args_max);
        try w.writeAll("\" },\n");
    }
    try w.writeAll("    .run = run,\n});\n\n");
}

/// `<arg> [arg]`, `<arg> [arg...]`.
fn argsUsage(w: *Writer, min: usize, max: ?usize) Writer.Error!void {
    for (0..min) |i| try w.writeAll(if (i == 0) "<arg>" else " <arg>");
    if (max) |m| {
        for (min..m) |i| try w.writeAll(if (i == 0) "[arg]" else " [arg]");
    } else {
        try w.writeAll(if (min == 0) "[arg...]" else " [arg...]");
    }
}

fn handler(w: *Writer, l: Leaf) Writer.Error!void {
    if (l.flags.len > 0) {
        try w.writeAll("fn run(ctx: *cli.Context, flags: Flags) !void {\n");
    } else {
        try w.writeAll("fn run(ctx: *cli.Context) !void {\n");
    }
    try printFields(w, l, "flags");
    if (l.args_max == null or l.args_max.? > 0) {
        try w.writeAll("    for (ctx.args) |arg| try ctx.out.print(\"arg={s}\\n\", .{arg});\n");
    }
    try w.writeAll("}\n\n");
}

/// The handler's body before the arguments: the path, then `name=value` per flag of
/// `owner` (`flags`, or a flow's `state`).
fn printFields(w: *Writer, l: Leaf, owner: []const u8) Writer.Error!void {
    try w.writeAll("    try ctx.out.writeAll(\"");
    try writeWords(w, l.path);
    try w.writeAll("\\n\");\n");
    for (l.flags) |s| {
        if (s.list) {
            try w.print("    try ctx.out.print(\"{s}={{d}} values\\n\", .{{{s}.{s}.len}});\n", .{
                s.name, owner, s.field,
            });
            continue;
        }
        try w.print("    try ctx.out.print(\"{s}={{{s}{s}}}\\n\", .{{{s}.{s}}});\n", .{
            s.name,
            if (s.isOptional()) "?" else "",
            specifier(s),
            owner,
            s.field,
        });
    }
}

/// The most flags `flowLeaf` takes.
pub const max_flow_flags = 32;

/// Whether a flow can ask for the flag: lists and counters are given on the command line.
fn askable(s: Spec) bool {
    return !s.list and !s.count;
}

/// A command that is a flow (`snek cli add --flow`): its flags are the flow's state, each
/// one it can ask for is a question (skipped when given as a flag), and a last step does
/// the work. The test answers the questions with a script.
pub fn flowLeaf(w: *Writer, l: Leaf) Writer.Error!void {
    assert(l.path.len > 0);
    var any_question = false;
    for (l.flags) |s| any_question = any_question or askable(s);
    // A flow with nothing to ask asks for a name, to show how.
    const sample = [_]Spec{.{
        .name = "name",
        .field = "name",
        .base = .string,
        .default = "\"\"",
    }};
    var flow = l;
    if (!any_question) flow.flags = &sample;
    // A required flag becomes a required question: the flag itself may then be left out,
    // and the question asks for it.
    var copies: [max_flow_flags]Spec = undefined;
    assert(flow.flags.len <= copies.len);
    for (copies[0..flow.flags.len], flow.flags) |*copy, s| {
        copy.* = s;
        copy.required = false;
    }
    const original = flow.flags;
    flow.flags = copies[0..original.len];
    try w.writeAll("//! `");
    try writeWords(w, l.path);
    if (l.summary.len > 0) try w.print("`: {s}\n", .{l.summary}) else try w.writeAll("`.\n");
    try w.writeAll(
        \\//!
        \\//! A flow (see `cli.flow`): each step asks a question or does something, and decides
        \\//! what comes next. Every question can be answered by its flag instead, so scripts
        \\//! run it too. `--dry-run` asks, and reports the actions without doing them.
        \\
        \\const std = @import("std");
        \\const cli = @import("cli");
        \\
        \\/// What the steps share. Every field is also a flag.
        \\
    );
    try flagsStruct(w, "State", flow.flags);
    try w.writeAll("const Step = enum { ");
    for (flow.flags) |s| if (askable(s)) try w.print("{s}, ", .{s.field});
    try w.writeAll("work };\n\n");
    try w.writeAll("const flow: cli.Flow(State, Step) = .{ .start = .");
    for (flow.flags) |s| if (askable(s)) {
        try w.print("{s}", .{s.field});
        break;
    };
    try w.writeAll(", .steps = .{\n");
    var questions: usize = 0;
    for (flow.flags, original) |s, given| {
        if (!askable(s)) continue;
        questions += 1;
        try w.print(
            "    .{s} = .{{\n        .ask = .{{ .field = \"{s}\", .label = \"",
            .{ s.field, s.field },
        );
        if (s.help.len > 0) try w.print("{f}", .{std.zig.fmtString(s.help)}) else {
            try w.writeByte(std.ascii.toUpper(s.name[0]));
            try w.print("{s}?", .{s.name[1..]});
        }
        try w.writeAll("\"");
        if (given.required) try w.writeAll(", .required = true");
        try w.writeAll(" },\n        .next = .");
        var next: []const u8 = "work";
        var seen: usize = 0;
        for (flow.flags) |t| {
            if (!askable(t)) continue;
            seen += 1;
            if (seen == questions + 1) {
                next = t.field;
                break;
            }
        }
        try w.print("{s},\n    }},\n", .{next});
    }
    try w.writeAll(
        \\    // A step can also skip itself (`.when`), undo what it did when a later step fails
        \\    // (`.undo`), or choose the next step from the state (`.decide`).
        \\    .work = .{ .title = "Work", .run = work },
        \\} };
        \\
        \\
    );
    try w.print(
        "pub const command = cli.command(.{{\n    .name = \"{s}\",\n",
        .{l.path[l.path.len - 1]},
    );
    if (l.summary.len > 0) {
        try w.print("    .summary = \"{f}\",\n", .{std.zig.fmtString(l.summary)});
    }
    try w.writeAll(
        \\    .flags = State,
        \\    .dry_run = true,
        \\    .run = run,
        \\});
        \\
        \\fn run(ctx: *cli.Context, flags: State) !void {
        \\    var state = flags;
        \\    _ = try flow.run(ctx, &state);
        \\}
        \\
        \\fn work(ctx: *cli.Context, state: *State) !void {
        \\
    );
    try printFields(w, flow, "state");
    try w.writeAll("}\n\ntest \"");
    try writeWords(w, l.path);
    try w.writeAll("\" {\n    var script: cli.flow.Script = .{ .answers = &.{");
    var first = true;
    for (flow.flags) |s| {
        if (!askable(s)) continue;
        try w.writeAll(if (first) " \"" else ", \"");
        first = false;
        switch (s.base) {
            .bool => try w.writeAll("y"),
            .int => try w.writeAll("1"),
            .float => try w.writeAll("1.5"),
            .string => try w.writeAll("x"),
            .@"enum" => |choices| try w.writeAll(choices[0]),
        }
        try w.writeByte('"');
    }
    try w.writeAll(
        \\ } };
        \\    const app: cli.App = .{
        \\        .root = &command,
        \\        .completion_command = false,
        \\        .asker = script.asker(),
        \\    };
        \\    // Standard input makes the run interactive, as at a terminal, so it is asked.
        \\    const result = try cli.testing.run(app, &.{}, .{ .stdin = "" });
        \\    defer result.deinit();
        \\    try std.testing.expectEqual(0, result.status);
        \\    try std.testing.expectEqualStrings(
        \\
    );
    try w.writeAll("        \\\\");
    try writeWords(w, l.path);
    try w.writeByte('\n');
    for (flow.flags) |s| {
        try w.print("        \\\\{s}=", .{s.name});
        if (askable(s)) switch (s.base) {
            .bool => try w.writeAll("true"),
            .int => try w.writeAll("1"),
            .float => try w.writeAll("1.5"),
            .string => try w.writeAll("x"),
            .@"enum" => |choices| try writeField(w, choices[0]),
        } else try expectedValue(w, s);
        try w.writeByte('\n');
    }
    try w.writeAll(
        \\        \\
        \\    , result.out);
        \\}
        \\
    );
}

fn specifier(s: Spec) []const u8 {
    return switch (s.base) {
        .bool => "",
        .int, .float => "d",
        .string => "s",
        .@"enum" => "t",
    };
}

fn testBlock(w: *Writer, l: Leaf) Writer.Error!void {
    try w.writeAll("test \"");
    try writeWords(w, l.path);
    try w.writeAll(
        \\" {
        \\    const app: cli.App = .{ .root = &command, .completion_command = false };
        \\    const result = try cli.testing.run(app, &.{
    );
    try testArgs(w, l);
    try w.writeAll(
        \\, .{});
        \\    defer result.deinit();
        \\    try result.expect(0,
        \\
    );
    try w.writeAll("        \\\\");
    try writeWords(w, l.path);
    try w.writeByte('\n');
    for (l.flags) |s| {
        try w.print("        \\\\{s}=", .{s.name});
        try expectedValue(w, s);
        try w.writeByte('\n');
    }
    for (0..l.args_min) |i| try w.print("        \\\\arg=arg{d}\n", .{i + 1});
    try w.writeAll(
        \\        \\
        \\    , "");
        \\}
        \\
    );
}

/// The arguments the generated test passes: a value for every required flag, then the
/// fewest positionals allowed.
fn testArgs(w: *Writer, l: Leaf) Writer.Error!void {
    var count: usize = 0;
    for (l.flags) |s| {
        if (!s.required) continue;
        try w.print("{s}\"--{s}\", \"", .{ if (count == 0) " " else ", ", s.name });
        try sampleValue(w, s);
        try w.writeByte('"');
        count += 1;
    }
    for (0..l.args_min) |i| {
        try w.print("{s}\"arg{d}\"", .{ if (count == 0) " " else ", ", i + 1 });
        count += 1;
    }
    try w.writeAll(if (count == 0) "}" else " }");
}

/// A value the generated test passes for a required flag, as typed.
fn sampleValue(w: *Writer, s: Spec) Writer.Error!void {
    assert(s.required);
    switch (s.base) {
        .bool => unreachable, // `flagspec` rejects required booleans.
        .int => try w.writeAll("1"),
        .float => try w.writeAll("1.5"),
        .string => try w.writeAll("x"),
        .@"enum" => |choices| try w.writeAll(choices[0]),
    }
}

/// What the handler prints for the flag in the generated test.
fn expectedValue(w: *Writer, s: Spec) Writer.Error!void {
    if (s.list) return w.writeAll("0 values");
    if (s.count) return w.writeAll(s.default orelse "0");
    if (s.required) return switch (s.base) {
        .@"enum" => |choices| writeField(w, choices[0]),
        else => sampleValue(w, s),
    };
    const default = s.default orelse return w.writeAll(if (s.base == .bool) "false" else "null");
    switch (s.base) {
        // The source literal, unquoted and unescaped: `"a\"b"` prints as `a"b`.
        .string => try writeUnescaped(w, default[1 .. default.len - 1]),
        // `.very_slow` prints as `very_slow`.
        .@"enum" => try w.writeAll(default[1..]),
        else => try w.writeAll(default),
    }
}

/// Undoes `std.zig.fmtString` for printable ASCII, the only text `flagspec` accepts as a
/// string default: only `\\` and `\"` are escaped.
fn writeUnescaped(w: *Writer, escaped: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < escaped.len) : (i += 1) {
        if (escaped[i] == '\\') i += 1;
        try w.writeByte(escaped[i]);
    }
}

fn writeWords(w: *Writer, words: []const []const u8) Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(word);
    }
}

const testing = std.testing;

test leaf {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var message: []const u8 = "";
    const specs = try flagspec.parseAll(arena, &.{
        "name:string=world,short=n,help=Who to \"greet\"",
        "times:u8=1",
        "loud:bool",
        "mode:enum(plain|fancy),required",
        "tag:list(string)",
        "limit:int",
    }, &message);
    const text = try render(arena, leaf, .{Leaf{
        .path = &.{"greet"},
        .summary = "Say hello",
        .flags = specs,
        .args_max = 1,
    }});
    try testing.expectEqualStrings(
        \\//! `greet`: Say hello
        \\
        \\const std = @import("std");
        \\const cli = @import("cli");
        \\
        \\const Flags = struct {
        \\    name: []const u8 = "world",
        \\    times: u8 = 1,
        \\    loud: bool = false,
        \\    mode: enum { plain, fancy },
        \\    tag: []const []const u8 = &.{},
        \\    limit: ?i64 = null,
        \\
        \\    pub const meta = .{
        \\        .name = .{ .short = 'n', .help = "Who to \"greet\"" },
        \\    };
        \\};
        \\
        \\pub const command = cli.command(.{
        \\    .name = "greet",
        \\    .summary = "Say hello",
        \\    .flags = Flags,
        \\    .args = .{ .min = 0, .max = 1, .usage = "[arg]" },
        \\    .run = run,
        \\});
        \\
        \\fn run(ctx: *cli.Context, flags: Flags) !void {
        \\    try ctx.out.writeAll("greet\n");
        \\    try ctx.out.print("name={s}\n", .{flags.name});
        \\    try ctx.out.print("times={d}\n", .{flags.times});
        \\    try ctx.out.print("loud={}\n", .{flags.loud});
        \\    try ctx.out.print("mode={t}\n", .{flags.mode});
        \\    try ctx.out.print("tag={d} values\n", .{flags.tag.len});
        \\    try ctx.out.print("limit={?d}\n", .{flags.limit});
        \\    for (ctx.args) |arg| try ctx.out.print("arg={s}\n", .{arg});
        \\}
        \\
        \\test "greet" {
        \\    const app: cli.App = .{ .root = &command, .completion_command = false };
        \\    const result = try cli.testing.run(app, &.{ "--mode", "plain" }, .{});
        \\    defer result.deinit();
        \\    try result.expect(0,
        \\        \\greet
        \\        \\name=world
        \\        \\times=1
        \\        \\loud=false
        \\        \\mode=plain
        \\        \\tag=0 values
        \\        \\limit=null
        \\        \\
        \\    , "");
        \\}
        \\
    , text);
}

test "leaf: no flags, unlimited arguments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const text = try render(arena_state.allocator(), leaf, .{Leaf{
        .path = &.{ "files", "copy" },
        .args_min = 2,
        .args_max = null,
    }});
    try testing.expect(std.mem.startsWith(u8, text,
        \\//! `files copy`.
        \\
        \\const std = @import("std");
        \\const cli = @import("cli");
        \\
        \\pub const command = cli.command(.{
        \\    .name = "copy",
        \\    .args = .{ .min = 2, .max = null, .usage = "<arg> <arg> [arg...]" },
        \\    .run = run,
        \\});
        \\
        \\fn run(ctx: *cli.Context) !void {
        \\    try ctx.out.writeAll("files copy\n");
        \\    for (ctx.args) |arg| try ctx.out.print("arg={s}\n", .{arg});
        \\}
        \\
    ));
    const call = "run(app, &.{ \"arg1\", \"arg2\" }, .{});\n";
    try testing.expect(std.mem.indexOf(u8, text, call) != null);
}

test group {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const path: []const []const u8 = &.{"config"};
    const text = try render(arena_state.allocator(), group, .{path});
    try testing.expectEqualStrings(
        \\//! `config`: the config commands.
        \\
        \\const cli = @import("cli");
        \\
        \\pub const command = cli.command(.{
        \\    .name = "config",
        \\    .summary = "The config commands",
        \\    .subcommands = .{
        \\        // snek:subcommands
        \\    },
        \\});
        \\
        \\test {
        \\    // snek:tests
        \\}
        \\
    , text);
}

test buildZon {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fingerprint_value: u64 = 0x1234_5678_9abc_def0;
    const local = try render(arena, buildZon, .{ "my_app", fingerprint_value, Dependency{
        .path = "../snek",
    } });
    try testing.expectEqualStrings(
        \\.{
        \\    .name = .my_app,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x123456789abcdef0,
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{
        \\        .snek = .{ .path = "../snek" },
        \\    },
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
        \\
    , local);
    const fetched = try render(arena, buildZon, .{ "my_app", fingerprint_value, Dependency.none });
    try testing.expect(std.mem.indexOf(u8, fetched, "    .dependencies = .{},\n") != null);
}

test fingerprint {
    var prng: std.Random.DefaultPrng = .init(1);
    const value = fingerprint(prng.random(), "demo");
    try testing.expectEqual(std.hash.Crc32.hash("demo"), @as(u32, @truncate(value >> 32)));
    const id: u32 = @truncate(value);
    try testing.expect(id != 0 and id != 0xffffffff);
}

test "init templates" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const main = try render(arena, mainZig, .{"demo"});
    try testing.expect(std.mem.indexOf(u8, main, "    .name = \"demo\",\n") != null);
    try testing.expect(std.mem.indexOf(u8, main,
        \\        @import("cmd/hello.zig").command,
        \\        // snek:subcommands
    ) != null);
    const tests =
        \\test {
        \\    _ = @import("settings.zig");
        \\    _ = @import("cmd/hello.zig");
        \\    // snek:tests
        \\}
    ;
    try testing.expect(std.mem.indexOf(u8, main, tests) != null);
    const build = try render(arena, buildZig, .{"demo"});
    try testing.expect(std.mem.indexOf(u8, build, ".name = \"demo\", .root_module") != null);
    try testing.expect(std.mem.indexOf(u8, build, "b.dependency(\"snek\"") != null);
    const readme_text = try render(arena, readme, .{"demo"});
    try testing.expect(std.mem.startsWith(u8, readme_text, "# demo\n"));
}
