//! A to-do tool that shows the opt-in `cli` features working with `cfg`:
//!
//! - translations: help, the library's messages, and the tool's own, plurals included,
//!   chosen by `LANG` (try `LANG=de_DE.UTF-8`);
//! - `.confirm` (`--yes`), `.dry_run` (`--dry-run`), and `.output` (`-o json`);
//! - flag defaults from a configuration file, `App.defaults = .from(&config, .{})`;
//! - a user alias (`ls` for `list`), as git's `alias.*`.
//!
//!     zig build examples
//!     LANG=de_DE.UTF-8 zig-out/bin/tasks clear --dry-run --config examples/tasks/tasks.toml
//!     zig-out/bin/tasks ls -o json

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const cfg = @import("cfg");

const Task = struct { title: []const u8, age_days: u32 };

const tasks = [_]Task{
    .{ .title = "Write the docs", .age_days = 3 },
    .{ .title = "Fix the parser", .age_days = 10 },
    .{ .title = "Reply to Ada", .age_days = 40 },
};

const Global = struct {
    config: ?[]const u8 = null,
};
const global_flags = cli.flags(Global, field.Set(.{field.Spec(Global){ .fields = .{
    .config = .{ .help = "Configuration file" },
} }}), .{ .fields = .{
    .config = .{ .short = 'c' },
} });

fn list(ctx: *cli.Context) !void {
    try ctx.render(@as([]const Task, &tasks));
}

const ClearFlags = struct {
    older_than: u32 = 30,
};
const clear_flags = cli.flags(ClearFlags, field.Set(.{field.Spec(ClearFlags){ .fields = .{
    .older_than = .{ .help = "Clear tasks older than this many days" },
} }}), .{});

fn clear(ctx: *cli.Context, flags: ClearFlags) !void {
    var count: u32 = 0;
    for (tasks) |task| count += @intFromBool(task.age_days > flags.older_than);
    const line = if (ctx.dry_run)
        try ctx.plural(
            count,
            "Would clear {0} task older than {1} days",
            "Would clear {0} tasks older than {1} days",
            .{ count, flags.older_than },
        )
    else
        try ctx.plural(count, "Cleared {0} task", "Cleared {0} tasks", .{count});
    try ctx.out.print("{s}\n", .{line});
}

pub const root = cli.command(.{
    .name = "tasks",
    .summary = "Keep track of things to do",
    .persistent_flags = global_flags,
    .subcommands = &.{
        cli.command(.{ .name = "list", .summary = "List the tasks", .output = true, .run = list }),
        cli.command(.{
            .name = "clear",
            .summary = "Clear old tasks",
            .flags = clear_flags,
            .confirm = "Clear the old tasks?",
            .dry_run = true,
            .run = clear,
        }),
    },
});

const german: cli.i18n.Translation = .{
    .locale = "de",
    .messages = &cli.i18n.messages.german,
    .strings = &.{
        .{ "Keep track of things to do", "Behält im Blick, was zu tun ist" },
        .{ "List the tasks", "Die Aufgaben auflisten" },
        .{ "Clear old tasks", "Alte Aufgaben löschen" },
        .{ "Clear the old tasks?", "Die alten Aufgaben löschen?" },
        .{
            "Clear tasks older than this many days",
            "Aufgaben löschen, die älter als so viele Tage sind",
        },
        .{ "Configuration file", "Konfigurationsdatei" },
        .{
            "Would clear {0} tasks older than {1} days",
            "Würde {0} Aufgabe löschen, älter als {1} Tage|" ++
                "Würde {0} Aufgaben löschen, älter als {1} Tage",
        },
        .{ "Cleared {0} tasks", "{0} Aufgabe gelöscht|{0} Aufgaben gelöscht" },
    },
};

/// The value of `--config`/`-c`, read before the command line is parsed, because the
/// file supplies defaults for the parse.
fn configPath(args: []const []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if ((std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) and i + 1 < args.len) {
            return args[i + 1];
        }
        if (std.mem.startsWith(u8, arg, "--config=")) return arg["--config=".len..];
    }
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config: cfg.Config = .init(init.gpa);
    defer config.deinit();
    if (configPath(args[1..])) |file| {
        var diag: cfg.Diagnostic = .{};
        config.loadFile(init.io, .cwd(), file, null, &diag) catch |err| {
            std.debug.print("tasks: {s}: {t} {f}\n", .{ file, err, diag });
            return 1;
        };
    }
    const app: cli.App = .{
        .root = &root,
        .translations = &.{german},
        .aliases = &.{.{ "ls", "list" }},
        // A flag's default from the file: `[clear] older-than = 7` for `tasks clear`.
        .defaults = .from(&config, .{ .name = "the config file" }),
    };
    return app.run(init);
}

const testing = std.testing;

test "output, confirmation, aliases, and translations" {
    const app: cli.App = .{
        .root = &root,
        .translations = &.{german},
        .aliases = &.{.{ "ls", "list" }},
    };
    const json = try cli.testing.run(app, &.{ "ls", "-o", "json" }, .{});
    defer json.deinit();
    const first = "[\n  {\n    \"title\": \"Write the docs\"";
    try testing.expect(std.mem.startsWith(u8, json.out, first));
    const refused = try cli.testing.run(app, &.{"clear"}, .{});
    defer refused.deinit();
    try testing.expectEqual(1, refused.status);
    const english = try cli.testing.run(app, &.{ "clear", "-y" }, .{});
    defer english.deinit();
    try english.expect(0, "Cleared 1 task\n", "");
    const one = try cli.testing.run(app, &.{ "clear", "-y", "--older-than", "30" }, .{
        .env = &.{.{ "LANG", "de_DE.UTF-8" }},
    });
    defer one.deinit();
    try one.expect(0, "1 Aufgabe gelöscht\n", "");
    const asked = try cli.testing.run(app, &.{ "clear", "--older-than", "5" }, .{
        .env = &.{.{ "LANG", "de" }},
        .stdin = "j\n",
    });
    defer asked.deinit();
    try asked.expect(0, "2 Aufgaben gelöscht\n", "Die alten Aufgaben löschen? [j/N] ");
}

test "flag defaults from the configuration file" {
    var config: cfg.Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("tasks.toml", "[clear]\nolder-than = 7\n", .toml, null);
    const app: cli.App = .{ .root = &root, .defaults = .from(&config, .{}) };
    const r = try cli.testing.run(app, &.{ "clear", "--dry-run", "-y" }, .{});
    defer r.deinit();
    try r.expect(0, "Would clear 2 tasks older than 7 days\n", "");
}
