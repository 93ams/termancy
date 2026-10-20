//! `termancy cfg profile list|use`: the `profiles.<name>` sections, and the one used by
//! default.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const cfg = @import("cfg");
const load = @import("load.zig");
const Document = @import("edit.zig").Document;

pub const command = cli.command(.{
    .name = "profile",
    .summary = "List profiles, or choose the one used by default",
    .description =
    \\A profile is a profiles.<name> section, applied over the rest of the file. --profile
    \\(or $TERMANCY_PROFILE) chooses one for a run; "profile use" records one in the config
    \\file, as current_profile, for every run that does not choose.
    ,
    .group = "Query Commands",
    .subcommands = .{ list, use },
});

const list = cli.command(.{
    .name = "list",
    .summary = "List the profiles; * marks the one in use",
    .run = runList,
});

fn runList(ctx: *cli.Context) !void {
    const global = try ctx.flags(load.Global);
    var config = try load.load(ctx, global);
    defer config.deinit();
    const active = global.profile orelse try load.currentProfile(&config);
    if (global.output != .text) {
        var names: cfg.Array = .empty;
        for (config.profileNames()) |name| try names.append(ctx.arena, .{ .string = name });
        return load.writeValue(ctx, .{ .array = names }, global.output);
    }
    for (config.profileNames()) |name| {
        const is_active = active != null and std.mem.eql(u8, active.?, name);
        const mark: []const u8 = if (is_active) "* " else "  ";
        try ctx.out.print("{s}{s}\n", .{ mark, name });
    }
}

const UseFlags = struct {
    clear: bool = false,
};
const use_flags = cli.flags(UseFlags, field.Set(.{field.Spec(UseFlags){ .fields = .{
    .clear = .{ .help = "Use no profile by default" },
} }}), .{});

const use = cli.command(.{
    .name = "use",
    .summary = "Use a profile by default",
    .flags = use_flags,
    .args = .{ .max = 1, .usage = "<name>", .complete = load.completeProfiles },
    .examples =
    \\termancy cfg profile use staging
    \\termancy cfg profile use --clear
    ,
    .run = runUse,
});

fn runUse(ctx: *cli.Context, flags: UseFlags) !void {
    const global = try ctx.flags(load.Global);
    const file = try load.targetFile(ctx, global);
    var document = try Document.read(ctx, file, .must_exist);
    if (flags.clear) {
        if (ctx.args.len > 0) return ctx.usageError("give a name or --clear, not both", .{});
        if (!document.tree.remove(load.current_profile_key)) return;
        return document.save(ctx, .{ .unset = load.current_profile_key });
    }
    if (ctx.args.len == 0) return ctx.usageError("name a profile, or give --clear", .{});
    const name = ctx.args[0];
    var config = try load.load(ctx, global);
    defer config.deinit();
    if (!load.hasProfile(&config, name)) {
        return ctx.fail("no profile \"{s}\" in the loaded files", .{name});
    }
    const value: cfg.Value = .{ .string = name };
    document.tree.put(ctx.arena, load.current_profile_key, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // A top-level key in a table.
    };
    try document.save(ctx, .{ .set = .{ .key = load.current_profile_key, .value = value } });
}
