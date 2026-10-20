//! `termancy ui input` and `termancy ui write`: read a line, or several, from the user.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");
const term = @import("term.zig");
const plain = @import("plain.zig");
const Input = @import("../tui/registry/input.zig");
const Textarea = @import("../tui/registry/textarea.zig");

pub const InputFlags = struct {
    placeholder: []const u8 = "Type something...",
    value: []const u8 = "",
    password: bool = false,
    header: []const u8 = "",
    prompt: []const u8 = "> ",
    char_limit: usize = 400,
};
const input_flags = cli.flags(InputFlags, field.Set(.{field.Spec(InputFlags){ .fields = .{
    .placeholder = .{ .help = "Shown while the input is empty" },
    .value = .{ .help = "The text to start with" },
    .password = .{ .help = "Mask the characters typed" },
    .header = .{ .help = "Text above the input" },
    .prompt = .{ .help = "Written before the input" },
    .char_limit = .{ .help = "The most characters; 0 for no limit" },
} }}), .{});

pub const input = cli.command(.{
    .name = "input",
    .summary = "Read a line of text",
    .description =
    \\Read one line and print it. Keys: the usual line editing (left/right, home/end,
    \\backspace, ctrl+w, ctrl+u, ctrl+k), enter submits, esc cancels (status 1), Ctrl-C
    \\interrupts (status 130).
    ,
    .flags = input_flags,
    .examples =
    \\name=$(termancy ui input --placeholder "Your name")
    \\token=$(termancy ui input --password --header "API token")
    ,
    .run = runInput,
});

const HeadedInput = term.Headed(Input);

fn runInput(ctx: *cli.Context, flags: InputFlags) !void {
    if (plain.wanted(ctx)) {
        var session: plain.Session = undefined;
        try session.open(ctx);
        defer session.close();
        const label = if (flags.header.len > 0)
            flags.header
        else
            std.mem.trimEnd(u8, flags.prompt, " >");
        const text = try session.input(
            if (label.len > 0) label else "Text",
            flags.value,
            flags.password,
        ) orelse return error.CommandFailed;
        try ctx.out.print("{s}\n", .{text});
        return;
    }
    var model = try buildInput(ctx.gpa, flags);
    defer model.inner.deinit();
    const interrupted = try term.run(ctx, HeadedInput, &model, term.inline_options);
    if (interrupted) return term.exitInterrupted(ctx);
    if (model.inner.status != .submitted) return error.CommandFailed;
    try ctx.out.print("{s}\n", .{model.inner.value()});
}

/// The `input` model from its flags.
pub fn buildInput(
    gpa: std.mem.Allocator,
    flags: InputFlags,
) std.mem.Allocator.Error!HeadedInput {
    var model: HeadedInput = .{
        .header = flags.header,
        .inner = .{
            .gpa = gpa,
            .prompt = flags.prompt,
            .placeholder = flags.placeholder,
            .password = flags.password,
            .char_limit = if (flags.char_limit == 0) null else flags.char_limit,
        },
    };
    errdefer model.inner.deinit();
    try model.inner.setValue(flags.value);
    return model;
}

pub const WriteFlags = struct {
    placeholder: []const u8 = "Write something...",
    value: []const u8 = "",
    header: []const u8 = "",
    prompt: []const u8 = "┃ ",
    char_limit: usize = 0,
    height: usize = 5,
};
const write_flags = cli.flags(WriteFlags, field.Set(.{field.Spec(WriteFlags){ .fields = .{
    .placeholder = .{ .help = "Shown while the text is empty" },
    .value = .{ .help = "The text to start with" },
    .header = .{ .help = "Text above the editor" },
    .prompt = .{ .help = "Written before each line" },
    .char_limit = .{ .help = "The most characters; 0 for no limit" },
    .height = .{ .help = "Lines shown at once; 0 for all" },
} }}), .{});

pub const write = cli.command(.{
    .name = "write",
    .summary = "Read several lines of text",
    .description =
    \\Read text of any number of lines and print it. Enter starts a new line; Ctrl-D
    \\submits; esc cancels (status 1); Ctrl-C interrupts (status 130).
    ,
    .flags = write_flags,
    .examples =
    \\git commit -m "$(termancy ui write --header "Commit message")"
    ,
    .run = runWrite,
});

const HeadedTextarea = term.Headed(Textarea);

fn runWrite(ctx: *cli.Context, flags: WriteFlags) !void {
    var model = try buildWrite(ctx.gpa, flags);
    defer model.inner.deinit();
    const interrupted = try term.run(ctx, HeadedTextarea, &model, term.inline_options);
    if (interrupted) return term.exitInterrupted(ctx);
    if (model.inner.status != .submitted) return error.CommandFailed;
    try ctx.out.print("{s}\n", .{model.inner.value()});
}

/// The `write` model from its flags.
pub fn buildWrite(
    gpa: std.mem.Allocator,
    flags: WriteFlags,
) std.mem.Allocator.Error!HeadedTextarea {
    var model: HeadedTextarea = .{
        .header = flags.header,
        .inner = .{
            .gpa = gpa,
            .prompt = flags.prompt,
            .placeholder = flags.placeholder,
            .char_limit = if (flags.char_limit == 0) null else flags.char_limit,
            .height = if (flags.height == 0) null else flags.height,
        },
    };
    errdefer model.inner.deinit();
    try model.inner.setValue(flags.value);
    return model;
}

const testing = std.testing;

test "input: header, starting value, and the limit" {
    var d: tui.testing.Driver(HeadedInput) = undefined;
    const model = try buildInput(testing.allocator, .{
        .header = "Name",
        .value = "Ad",
        .char_limit = 3,
    });
    d = try .init(testing.allocator, model, .{});
    defer d.deinit();
    defer d.model().inner.deinit();
    try d.expectFrame("Name\n> Ad ");
    try d.typeText("aXYZ");
    try d.press("enter");
    try testing.expectEqualStrings("Ada", d.model().inner.value());
    try testing.expectEqual(.submitted, d.model().inner.status);
}

test "input: password and no limit" {
    var model = try buildInput(testing.allocator, .{ .password = true, .char_limit = 0 });
    defer model.inner.deinit();
    try testing.expect(model.inner.password);
    try testing.expectEqual(null, model.inner.char_limit);
    try testing.expectEqualStrings("Type something...", model.inner.placeholder);
}

test "write: lines until ctrl+d" {
    var d: tui.testing.Driver(HeadedTextarea) = try .init(
        testing.allocator,
        try buildWrite(testing.allocator, .{ .prompt = "" }),
        .{},
    );
    defer d.deinit();
    defer d.model().inner.deinit();
    try d.expectFrame("Write something...");
    try d.typeText("a");
    try d.press("enter");
    try d.typeText("b");
    try d.press("ctrl+d");
    try testing.expectEqualStrings("a\nb", d.model().inner.value());
    try testing.expectEqual(.submitted, d.model().inner.status);
}
