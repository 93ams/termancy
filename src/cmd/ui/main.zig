//! `termancy ui`: the gum-style commands, small interactive pieces for shell scripts built on
//! the registry components compiled into termancy, and `demo`, which shows those components.
//!
//! | command   | does                                              | prints              |
//! |-----------|---------------------------------------------------|---------------------|
//! | `choose`  | pick from arguments or stdin lines                | the chosen items    |
//! | `confirm` | ask yes/no                                        | nothing (status)    |
//! | `input`   | read a line (`--password`)                        | the line            |
//! | `write`   | read several lines (Ctrl-D submits)               | the text            |
//! | `filter`  | fuzzy-find among stdin lines                      | the chosen lines    |
//! | `spin`    | run a command behind a spinner                    | the command's output|
//! | `table`   | show CSV/TSV, pick a row (`--print` to render)    | the chosen row      |
//! | `pager`   | scroll through a file or stdin                    | nothing             |
//! | `file`    | browse directories, choose a file                 | its absolute path   |
//! | `style`   | style text: colors, border, padding, alignment    | the styled text     |
//! | `format`  | Markdown, code, emoji, or a template              | the rendered text   |
//! | `join`    | blocks side by side or stacked                    | the joined text     |
//! | `log`     | a log record: level, message, fields              | it, on stderr       |
//!
//! Interactive commands draw on the terminal (`/dev/tty` when stdio is redirected) and
//! print results to standard output, so they compose in `$(...)` and pipes. Without any
//! terminal they fail at once with status 2. Esc ends with status 1 and Ctrl-C with 130,
//! printing nothing. With `ACCESSIBLE=1`, `choose`, `confirm`, and `input` ask with plain
//! lines instead, numbered choices and typed answers, for screen readers (plain.zig).
//! `style`, `format`, and `table --print` write escapes only where
//! standard output shows them, honoring `NO_COLOR` and `FORCE_COLOR`. See term.zig.
//!
//! gum's shared flags, each where it applies (term.zig and styles.zig hold them):
//! `TERMANCY_<COMMAND>_<FLAG>` variables for every flag (`.env_prefix` on the flag set);
//! `--timeout <duration>`, which ends with status 124 and `timed out` on stderr unless the
//! command takes it as an answer; style groups per part (`--cursor.foreground`,
//! `--header.bold`; help lists only the colors), defaulting to `cli.Theme`'s look;
//! `--show-help` and `--padding` around the component (`term.Framed`); and `--strip-ansi`,
//! `--input-delimiter`, and `--output-delimiter` (`term.items`, `term.writeJoined`).

const std = @import("std");

const demo = @import("demo.zig");
const choose_zig = @import("choose.zig");
const confirm_zig = @import("confirm.zig");
const input_zig = @import("input.zig");
const filter_zig = @import("filter.zig");
const spin_zig = @import("spin.zig");
const table_zig = @import("table.zig");
const pager_zig = @import("pager.zig");
const file_zig = @import("file.zig");
const style_zig = @import("style.zig");
const format_zig = @import("format.zig");
const join_zig = @import("join.zig");
const log_zig = @import("log.zig");

pub const choose = choose_zig.command;
pub const confirm = confirm_zig.command;
pub const input = input_zig.input;
pub const write = input_zig.write;
pub const filter = filter_zig.command;
pub const spin = spin_zig.command;
pub const table = table_zig.command;
pub const pager = pager_zig.command;
pub const file = file_zig.command;
pub const style = style_zig.command;
pub const format = format_zig.command;
pub const join = join_zig.command;
pub const log = log_zig.command;

/// Every gum-style command.
pub const commands = .{
    choose, confirm, input, write, filter, spin, table, pager, file, style, format, join, log,
};

pub const command = cli.command(.{
    .name = "ui",
    .summary = "Terminal widgets for shell scripts, and demos of the components",
    .subcommands = commands ++ .{demo.command},
});

test {
    std.testing.refAllDecls(demo);
    std.testing.refAllDecls(@import("term.zig"));
    std.testing.refAllDecls(@import("styles.zig"));
    std.testing.refAllDecls(@import("plain.zig"));
    std.testing.refAllDecls(choose_zig);
    std.testing.refAllDecls(confirm_zig);
    std.testing.refAllDecls(join_zig);
    std.testing.refAllDecls(log_zig);
    std.testing.refAllDecls(input_zig);
    std.testing.refAllDecls(filter_zig);
    std.testing.refAllDecls(spin_zig);
    std.testing.refAllDecls(table_zig);
    std.testing.refAllDecls(pager_zig);
    std.testing.refAllDecls(file_zig);
    std.testing.refAllDecls(style_zig);
    std.testing.refAllDecls(format_zig);
    std.testing.refAllDecls(@import("../tui/registry/root.zig"));
}

const testing = std.testing;
const cli = @import("cli");

const test_root = cli.command(.{ .name = "termancy", .subcommands = commands });

/// Runs `termancy <args>` in memory with `env` as the whole environment. Only for commands
/// that end before reading standard input or opening the terminal.
fn testRun(args: []const []const u8, env: []const [2][]const u8) !cli.testing.Run {
    const app: cli.App = .{ .root = &test_root };
    return cli.testing.run(app, args, .{ .env = env });
}

fn expectRun(
    args: []const []const u8,
    env: []const [2][]const u8,
    status: u8,
    out: []const u8,
    err: []const u8,
) !void {
    const result = try testRun(args, env);
    defer result.deinit();
    try result.expect(status, out, err);
}

test "style: plain without color, escapes when forced" {
    const args: []const []const u8 = &.{
        "style", "--border", "ascii", "--padding", "0 1", "--bold", "--foreground", "1", "hi",
    };
    const plain = "+----+\n| hi |\n+----+\n";
    try expectRun(args, &.{.{ "NO_COLOR", "1" }}, 0, plain, "");
    try expectRun(args, &.{ .{ "NO_COLOR", "1" }, .{ "FORCE_COLOR", "3" } }, 0, plain, "");
    const colored = "+----+\n|\x1b[1;31m hi \x1b[0m|\n+----+\n";
    try expectRun(args, &.{.{ "FORCE_COLOR", "3" }}, 0, colored, "");
}

test "format: Markdown marks become styles, or go" {
    const args: []const []const u8 = &.{ "format", "# Hi", "a **b**" };
    try expectRun(args, &.{.{ "NO_COLOR", "1" }}, 0, "\n  # Hi\n\n  a b\n", "");
    const colored = "\n  \x1b[1;38;5;228;48;5;63m \x1b[0m\x1b[1;38;5;228;48;5;63mHi\x1b[0m" ++
        "\x1b[1;38;5;228;48;5;63m \x1b[0m\n\n  \x1b[38;5;252ma \x1b[0m\x1b[1;38;5;252mb\x1b[0m\n";
    try expectRun(args, &.{.{ "FORCE_COLOR", "3" }}, 0, colored, "");
}

test "format: code, emoji, and templates" {
    try expectRun(&.{ "format", "-t", "emoji", ":rocket: go" }, &.{}, 0, "🚀 go\n", "");
    try expectRun(&.{ "format", "-t", "template", "{{ Bold \"x\" }}!" }, &.{}, 0, "x!\n", "");
    const code = "\x1b[38;2;0;170;255mconst\x1b[0m";
    const run_code = try testRun(&.{ "format", "-t", "code", "-l", "zig", "const x = 1;" }, &.{
        .{ "FORCE_COLOR", "3" },
    });
    defer run_code.deinit();
    try testing.expect(std.mem.startsWith(u8, run_code.out, code));
    try expectRun(&.{ "format", "-t", "code", "-l", "cobol", "x" }, &.{}, 2, "", "termancy: no " ++
        "language named cobol\nRun 'termancy format --help' for usage.\n");
}

test "join and log" {
    try expectRun(&.{ "join", "a\nbb", "c" }, &.{}, 0, "a c\nbb \n", "");
    try expectRun(
        &.{ "join", "--vertical", "--align", "right", "a", "bbb" },
        &.{},
        0,
        "  a\nbbb\n",
        "",
    );
    try expectRun(
        &.{ "log", "-f", "logfmt", "-l", "warn", "full", "used", "93%" },
        &.{},
        0,
        "",
        "level=warn msg=full used=93%\n",
    );
    try expectRun(&.{ "log", "x", "odd" }, &.{}, 2, "", "termancy: fields come in key value pairs\n" ++
        "Run 'termancy log --help' for usage.\n");
}

test "usage errors come before any input or terminal" {
    const limit = "termancy: --limit must be at least 1\n";
    try expectRun(&.{ "choose", "--limit", "0", "a" }, &.{}, 2, "", limit ++
        "Run 'termancy choose --help' for usage.\n");
    try expectRun(&.{ "filter", "--limit", "0" }, &.{}, 2, "", limit ++
        "Run 'termancy filter --help' for usage.\n");
    try expectRun(&.{ "table", "--separator", ";;" }, &.{}, 2, "", "termancy: invalid --separator " ++
        "\";;\" (use one character, or \\t)\nRun 'termancy table --help' for usage.\n");
    // A name that is no file is the text to show, but a directory cannot be shown.
    try expectRun(&.{ "pager", "." }, &.{}, 1, "", "termancy: .: IsDir\n");
    try expectRun(&.{ "file", "termancy-no-such-dir" }, &.{}, 1, "", "termancy: termancy-no-such-dir: " ++
        "no such directory\n");
}
