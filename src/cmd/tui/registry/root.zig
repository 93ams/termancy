//! The component registry: source files that `termancy tui add` copies into a project and that
//! termancy itself compiles, for the gum-style commands and for their tests.
//!
//! Each component is one file importing only `std`, `tui`, and the sibling files it
//! requires, so a copy builds wherever `tui` is a dependency. `registry.zon` lists the
//! components with a summary, their files, and the components they require:
//!
//! ```zig
//! .{ .components = .{
//!     .select = .{ .summary = "...", .files = .{"select.zig"}, .requires = .{"list"} },
//! } }
//! ```
//!
//! Every file a component lists is in `files`, so the copy is byte for byte what termancy was
//! built and tested with.

const std = @import("std");

/// The components' declarations, for the apps in `examples/`, which import the registry as
/// a module where a project would have copied the files in.
pub const Prompts = @import("prompts.zig");
pub const Form = @import("form.zig");
pub const Tabs = @import("tabs.zig");
pub const Table = @import("table.zig");
pub const Spinner = @import("spinner.zig");
pub const Progress = @import("progress.zig");
pub const List = @import("list.zig");
pub const chart = @import("chart.zig");
pub const Shell = @import("shell.zig");
pub const Paginator = @import("paginator.zig");
pub const Stopwatch = @import("stopwatch.zig");
pub const Input = @import("input.zig");
pub const Timer = @import("timer.zig");
pub const help = @import("help.zig");
pub const Filter = @import("filter.zig");
pub const Markdown = @import("markdown.zig");

/// `registry.zon`, verbatim.
pub const manifest: []const u8 = @embedFile("registry.zon");

/// A component source file.
pub const File = struct {
    name: []const u8,
    source: []const u8,
};

/// Every component source file, by name.
pub const files = [_]File{
    .{ .name = "chart.zig", .source = @embedFile("chart.zig") },
    .{ .name = "confirm.zig", .source = @embedFile("confirm.zig") },
    .{ .name = "filepicker.zig", .source = @embedFile("filepicker.zig") },
    .{ .name = "filter.zig", .source = @embedFile("filter.zig") },
    .{ .name = "form.zig", .source = @embedFile("form.zig") },
    .{ .name = "help.zig", .source = @embedFile("help.zig") },
    .{ .name = "input.zig", .source = @embedFile("input.zig") },
    .{ .name = "list.zig", .source = @embedFile("list.zig") },
    .{ .name = "markdown.zig", .source = @embedFile("markdown.zig") },
    .{ .name = "multiprogress.zig", .source = @embedFile("multiprogress.zig") },
    .{ .name = "multiselect.zig", .source = @embedFile("multiselect.zig") },
    .{ .name = "pager.zig", .source = @embedFile("pager.zig") },
    .{ .name = "paginator.zig", .source = @embedFile("paginator.zig") },
    .{ .name = "progress.zig", .source = @embedFile("progress.zig") },
    .{ .name = "prompts.zig", .source = @embedFile("prompts.zig") },
    .{ .name = "select.zig", .source = @embedFile("select.zig") },
    .{ .name = "shell.zig", .source = @embedFile("shell.zig") },
    .{ .name = "spinner.zig", .source = @embedFile("spinner.zig") },
    .{ .name = "stopwatch.zig", .source = @embedFile("stopwatch.zig") },
    .{ .name = "table.zig", .source = @embedFile("table.zig") },
    .{ .name = "tabs.zig", .source = @embedFile("tabs.zig") },
    .{ .name = "textarea.zig", .source = @embedFile("textarea.zig") },
    .{ .name = "timer.zig", .source = @embedFile("timer.zig") },
    .{ .name = "tree.zig", .source = @embedFile("tree.zig") },
    .{ .name = "viewport.zig", .source = @embedFile("viewport.zig") },
};

test {
    // `refAllDecls` is shallow, so every component is named here.
    std.testing.refAllDecls(@import("chart.zig"));
    std.testing.refAllDecls(@import("confirm.zig"));
    std.testing.refAllDecls(@import("filepicker.zig"));
    std.testing.refAllDecls(@import("filter.zig"));
    std.testing.refAllDecls(@import("form.zig"));
    std.testing.refAllDecls(@import("help.zig"));
    std.testing.refAllDecls(@import("input.zig"));
    std.testing.refAllDecls(@import("list.zig"));
    std.testing.refAllDecls(@import("markdown.zig"));
    std.testing.refAllDecls(@import("multiprogress.zig"));
    std.testing.refAllDecls(@import("multiselect.zig"));
    std.testing.refAllDecls(@import("pager.zig"));
    std.testing.refAllDecls(@import("paginator.zig"));
    std.testing.refAllDecls(@import("progress.zig"));
    std.testing.refAllDecls(@import("prompts.zig"));
    std.testing.refAllDecls(@import("select.zig"));
    std.testing.refAllDecls(@import("shell.zig"));
    std.testing.refAllDecls(@import("spinner.zig"));
    std.testing.refAllDecls(@import("stopwatch.zig"));
    std.testing.refAllDecls(@import("table.zig"));
    std.testing.refAllDecls(@import("tabs.zig"));
    std.testing.refAllDecls(@import("textarea.zig"));
    std.testing.refAllDecls(@import("timer.zig"));
    std.testing.refAllDecls(@import("tree.zig"));
    std.testing.refAllDecls(@import("viewport.zig"));
}

const testing = std.testing;
const Zoir = std.zig.Zoir;

test "registry.zon names every file once, and each imports only what it requires" {
    const gpa = testing.allocator;
    const source = try gpa.dupeSentinel(u8, manifest, 0);
    defer gpa.free(source);
    var ast: std.zig.Ast = try .parse(gpa, source, .{ .mode = .zon });
    defer ast.deinit(gpa);
    const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);
    try testing.expect(!zoir.hasCompileErrors());

    const top = Zoir.Node.Index.root.get(&zoir).struct_literal;
    try testing.expectEqualStrings("components", top.names[0].get(&zoir));
    const components = top.vals.at(0).get(&zoir).struct_literal;
    var named: usize = 0;
    for (components.names, 0..) |name, i| {
        const component = components.vals.at(@intCast(i)).get(&zoir).struct_literal;
        var requires: std.ArrayList([]const u8) = .empty;
        defer requires.deinit(gpa);
        for (component.names, 0..) |field, j| {
            const value = component.vals.at(@intCast(j));
            if (std.mem.eql(u8, field.get(&zoir), "requires")) {
                try appendStrings(gpa, &zoir, value, &requires);
            }
        }
        for (component.names, 0..) |field, j| {
            if (!std.mem.eql(u8, field.get(&zoir), "files")) continue;
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(gpa);
            try appendStrings(gpa, &zoir, component.vals.at(@intCast(j)), &names);
            for (names.items) |file_name| {
                named += 1;
                const file = find(file_name) orelse {
                    std.debug.print("{s}: {s} is not in files\n", .{ name.get(&zoir), file_name });
                    return error.TestUnexpectedResult;
                };
                try expectImportsOnly(file, requires.items);
            }
        }
    }
    try testing.expectEqual(files.len, named);
}

fn appendStrings(
    gpa: std.mem.Allocator,
    zoir: *const Zoir,
    node: Zoir.Node.Index,
    out: *std.ArrayList([]const u8),
) !void {
    switch (node.get(zoir)) {
        .empty_literal => {},
        .array_literal => |range| for (0..range.len) |k| {
            try out.append(gpa, range.at(@intCast(k)).get(zoir).string_literal);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn find(name: []const u8) ?File {
    for (files) |file| {
        if (std.mem.eql(u8, file.name, name)) return file;
    }
    return null;
}

/// Fails unless every `@import` in `file` is `std`, `tui`, or a required component's file.
fn expectImportsOnly(file: File, requires: []const []const u8) !void {
    const marker = "@import(\"";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, file.source, at, marker)) |start| {
        const name_start = start + marker.len;
        const end = std.mem.indexOfScalarPos(u8, file.source, name_start, '"').?;
        const name = file.source[name_start..end];
        at = end;
        if (std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "tui")) continue;
        for (requires) |required| {
            if (std.mem.startsWith(u8, name, required) and
                std.mem.eql(u8, name[required.len..], ".zig")) break;
        } else {
            std.debug.print("{s} imports {s}, which it does not require\n", .{ file.name, name });
            return error.TestUnexpectedResult;
        }
    }
}
