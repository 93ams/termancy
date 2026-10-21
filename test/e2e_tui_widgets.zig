//! End-to-end tests for the gum-style `termancy ui` commands, run as processes in
//! `test/fixtures` with an empty environment plus what each case sets.
//!
//! Three kinds of case:
//!
//! - Output commands (`style`, `format`, `table --print`) and early failures, byte for
//!   byte. Standard output is a pipe, so color appears only when `FORCE_COLOR` asks.
//! - Interactive commands with no terminal at all, run under `setsid` so they have no
//!   controlling terminal even when the build does: they must fail at once (status 2),
//!   never wait. Without `setsid`, these are skipped: a terminal could be inherited.
//! - Interactive commands driven through a pseudo-terminal by util-linux `script`: a shell
//!   types the keys once the first frame is drawn (raw mode is on by then, so no key is
//!   lost), and the command's standard output, redirected to a file, is the result. This
//!   is the `x=$(termancy ui choose ...)` situation: the interface on the terminal, the answer
//!   in the pipe. Skipped without `script` and `sh`.

const std = @import("std");
const builtin = @import("builtin");

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    env: []const [2][]const u8 = &.{},
    /// Standard input; /dev/null when null.
    stdin: ?[]const u8 = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    status: u8 = 0,
};

const no_color = [_][2][]const u8{.{ "NO_COLOR", "1" }};
const force_color = [_][2][]const u8{.{ "FORCE_COLOR", "3" }};
const both = [_][2][]const u8{ .{ "NO_COLOR", "1" }, .{ "FORCE_COLOR", "3" } };

const style_args = [_][]const u8{
    "ui",     "style",        "--border", "rounded", "--padding", "0 1",
    "--bold", "--foreground", "212",      "hello",   "world",
};
const style_plain =
    \\╭───────╮
    \\│ hello │
    \\│ world │
    \\╰───────╯
    \\
;
const style_color = "╭───────╮\n" ++
    "│\x1b[1;38;5;212m hello \x1b[0m│\n" ++
    "│\x1b[1;38;5;212m world \x1b[0m│\n" ++
    "╰───────╯\n";

const markdown =
    \\# Notes
    \\
    \\Some **bold**, *italic*, and `code`.
    \\
    \\- one
    \\- two
    \\1. first
    \\> quote
    \\---
    \\```
    \\x = 1
    \\```
    \\See [docs](https://example.com).
    \\
;
/// `text` `n` times.
fn repeat(comptime text: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ text;
    return out;
}

/// Rendered for a pipe: 80 columns, two of margin on each side, no colors (glamour's
/// "notty" style).
const markdown_plain = "\n" ++
    \\  # Notes
    \\
    \\  Some bold, italic, and `code`.
    \\
    \\  • one
    \\  • two
    \\
    \\  1. first
    \\
    \\  │ quote
    \\
    \\
++ "  " ++ repeat("─", 76) ++ "\n" ++
    \\
    \\    x = 1
    \\
    \\  See docs https://example.com.
    \\
;

const people_csv =
    \\name,age,city
    \\Ada,36,London
    \\"Hopper, Grace",85,
    \\
;
const people_table =
    \\╭───────────────┬─────┬────────╮
    \\│ name          │ age │ city   │
    \\├───────────────┼─────┼────────┤
    \\│ Ada           │ 36  │ London │
    \\│ Hopper, Grace │ 85  │        │
    \\╰───────────────┴─────┴────────╯
    \\
;

const no_terminal = "termancy: no terminal to draw on: standard input and output are not " ++
    "terminals and /dev/tty cannot be opened\n";

fn usage(comptime command: []const u8) []const u8 {
    return "Run 'termancy ui " ++ command ++ " --help' for usage.\n";
}

/// Cases that never need a terminal.
const cases = [_]Case{
    // style
    .{ .name = "style, piped", .args = &style_args, .stdout = style_plain },
    .{ .name = "style, NO_COLOR", .args = &style_args, .env = &no_color, .stdout = style_plain },
    .{
        .name = "style, NO_COLOR beats FORCE_COLOR",
        .args = &style_args,
        .env = &both,
        .stdout = style_plain,
    },
    .{
        .name = "style, FORCE_COLOR into a pipe",
        .args = &style_args,
        .env = &force_color,
        .stdout = style_color,
    },
    .{
        .name = "style, 16 colors",
        .args = &.{ "ui", "style", "--foreground", "#ff0000", "--underline", "x" },
        .env = &.{.{ "FORCE_COLOR", "1" }},
        .stdout = "\x1b[4;91mx\x1b[0m\n",
    },
    .{
        .name = "style from standard input, aligned in a width",
        .args = &.{ "ui", "style", "--align", "right", "--width", "8", "--border", "normal" },
        .stdin = "right\n",
        .stdout = "┌────────┐\n│   right│\n└────────┘\n",
    },
    .{
        .name = "style with margin and padding",
        .args = &.{ "ui", "style", "--margin", "1 2", "--padding", "0 1 0 3", "x" },
        .stdout = "         \n     x   \n         \n",
    },
    .{
        .name = "style with a bad color",
        .args = &.{ "ui", "style", "--foreground", "nope", "x" },
        .stderr = "termancy: invalid value \"nope\" for flag --foreground: expected color\n" ++
            usage("style"),
        .status = 2,
    },
    .{
        .name = "style with bad padding",
        .args = &.{ "ui", "style", "--padding", "1 2 3", "x" },
        .stderr = "termancy: invalid value \"1 2 3\" for flag --padding: expected spacing\n" ++
            usage("style"),
        .status = 2,
    },
    // format
    .{
        .name = "format, piped",
        .args = &.{ "ui", "format" },
        .stdin = markdown,
        .stdout = markdown_plain,
    },
    .{
        .name = "format, NO_COLOR",
        .args = &.{ "ui", "format" },
        .env = &no_color,
        .stdin = markdown,
        .stdout = markdown_plain,
    },
    .{
        .name = "format, FORCE_COLOR",
        .args = &.{ "ui", "format", "# T", "*i* `c`" },
        .env = &force_color,
        .stdout = "\n  \x1b[1;38;5;228;48;5;63m \x1b[0m\x1b[1;38;5;228;48;5;63mT\x1b[0m" ++
            "\x1b[1;38;5;228;48;5;63m \x1b[0m\n\n  \x1b[3;38;5;252mi\x1b[0m\x1b[38;5;252m " ++
            "\x1b[0m\x1b[38;5;203;48;5;236m c \x1b[0m\n",
    },
    // table --print
    .{
        .name = "table --print, piped",
        .args = &.{ "ui", "table", "--print" },
        .stdin = people_csv,
        .stdout = people_table,
    },
    .{
        .name = "table --print, NO_COLOR",
        .args = &.{ "ui", "table", "--print" },
        .env = &no_color,
        .stdin = people_csv,
        .stdout = people_table,
    },
    .{
        .name = "table --print, FORCE_COLOR",
        .args = &.{ "ui", "table", "-p", "--border", "ascii" },
        .env = &force_color,
        .stdin = "a,b\n1,2\n",
        .stdout = "\x1b[38;5;238m+---+---+\x1b[0m\n" ++
            "\x1b[38;5;238m|\x1b[0m\x1b[1;38;5;99m a \x1b[0m\x1b[38;5;238m|\x1b[0m" ++
            "\x1b[1;38;5;99m b \x1b[0m\x1b[38;5;238m|\x1b[0m\n" ++
            "\x1b[38;5;238m+---+---+\x1b[0m\n" ++
            "\x1b[38;5;238m|\x1b[0m 1 \x1b[38;5;238m|\x1b[0m 2 \x1b[38;5;238m|\x1b[0m\n" ++
            "\x1b[38;5;238m+---+---+\x1b[0m\n",
    },
    .{
        .name = "table --print: TSV, titles, widths, no border",
        .args = &.{
            "ui", "table", "-p",       "-s",   "tab", "-c", "x,y",
            "-w", "6,0",   "--border", "none",
        },
        .stdin = "a\tb\nlonger cell\t2\n",
        .stdout = "x       y\na       b\nlonge…  2\n",
    },
    .{
        .name = "table with no input",
        .args = &.{ "ui", "table", "--print" },
        .stdin = "",
        .stderr = "termancy: standard input holds no table\n",
        .status = 1,
    },
    .{
        .name = "table with an unterminated quote",
        .args = &.{ "ui", "table", "--print" },
        .stdin = "a\n\"b\n",
        .stderr = "termancy: standard input: a quoted field never ends\n",
        .status = 1,
    },
    .{
        .name = "table with a bad separator",
        .args = &.{ "ui", "table", "--separator", "ab" },
        .stderr = "termancy: invalid --separator \"ab\" (use one character, or \\t)\n" ++
            usage("table"),
        .status = 2,
    },
    // failures that come before any terminal
    .{
        .name = "choose with no items",
        .args = &.{ "ui", "choose" },
        .stdin = "",
        .stderr = "termancy: no items to choose from\n",
        .status = 1,
    },
    .{
        .name = "filter with no items",
        .args = &.{ "ui", "filter" },
        .stdin = "",
        .stderr = "termancy: no items to choose from\n",
        .status = 1,
    },
    .{
        .name = "choose --limit 0",
        .args = &.{ "ui", "choose", "--limit", "0", "a" },
        .stderr = "termancy: --limit must be at least 1\n" ++ usage("choose"),
        .status = 2,
    },
    .{
        // The variable is read as the flag would be, before any terminal.
        .name = "choose: TERMANCY_CHOOSE_LIMIT=0",
        .args = &.{ "ui", "choose", "a" },
        .env = &.{.{ "TERMANCY_CHOOSE_LIMIT", "0" }},
        .stderr = "termancy: --limit must be at least 1\n" ++ usage("choose"),
        .status = 2,
    },
    .{
        .name = "choose --timeout that is not a duration",
        .args = &.{ "ui", "choose", "--timeout", "soon", "a" },
        .stderr = "termancy: invalid value \"soon\" for flag --timeout: expected duration\n" ++
            usage("choose"),
        .status = 2,
    },
    .{
        .name = "pager with a missing file",
        .args = &.{ "ui", "pager", "missing.txt" },
        .stderr = "termancy: missing.txt: no such file\n",
        .status = 1,
    },
    .{
        .name = "spin without a command",
        .args = &.{ "ui", "spin" },
        .stderr = "termancy: \"termancy ui spin\" requires at least 1 argument, received 0\n" ++
            usage("spin"),
        .status = 2,
    },
    // input/write/confirm (gum parity)
    .{
        .name = "confirm --default that is not an answer",
        .args = &.{ "ui", "confirm", "--default", "maybe" },
        .stderr = "termancy: invalid value \"maybe\" for flag --default: expected yes|no\n" ++
            usage("confirm"),
        .status = 2,
    },
};

/// Cases run with no controlling terminal (under `setsid`).
const detached_cases = [_]Case{
    .{
        .name = "choose without a terminal",
        .args = &.{ "ui", "choose", "a", "b" },
        .stderr = no_terminal ++ usage("choose"),
        .status = 2,
    },
    .{
        .name = "choose without a terminal, items piped",
        .args = &.{ "ui", "choose" },
        .stdin = "a\nb\n",
        .stderr = no_terminal ++ usage("choose"),
        .status = 2,
    },
    .{
        .name = "choose --limit without a terminal",
        .args = &.{ "ui", "choose", "--limit", "2", "a", "b" },
        .stderr = no_terminal ++ usage("choose"),
        .status = 2,
    },
    .{
        .name = "confirm without a terminal",
        .args = &.{ "ui", "confirm" },
        .stderr = no_terminal ++ usage("confirm"),
        .status = 2,
    },
    .{
        .name = "input without a terminal",
        .args = &.{ "ui", "input" },
        .stderr = no_terminal ++ usage("input"),
        .status = 2,
    },
    .{
        .name = "write without a terminal",
        .args = &.{ "ui", "write" },
        .stderr = no_terminal ++ usage("write"),
        .status = 2,
    },
    .{
        .name = "filter without a terminal",
        .args = &.{ "ui", "filter" },
        .stdin = "a\nb\n",
        .stderr = no_terminal ++ usage("filter"),
        .status = 2,
    },
    .{
        .name = "table without a terminal",
        .args = &.{ "ui", "table" },
        .stdin = "a,b\n1,2\n",
        .stderr = no_terminal ++ usage("table"),
        .status = 2,
    },
    .{
        .name = "pager without a terminal",
        .args = &.{ "ui", "pager", "notes.txt" },
        .stderr = no_terminal ++ usage("pager"),
        .status = 2,
    },
    // spin needs no terminal: without one, the command just runs.
    .{
        .name = "spin passes output and status through",
        .args = &.{ "ui", "spin", "--", "sh", "-c", "echo out; echo err >&2; exit 3" },
        .stdout = "out\n",
        .stderr = "err\n",
        .status = 3,
    },
    .{
        .name = "spin with a successful command",
        .args = &.{ "ui", "spin", "--title", "Working", "--", "sh", "-c", "echo ok" },
        .stdout = "ok\n",
    },
    .{
        .name = "spin with a command that does not exist",
        .args = &.{ "ui", "spin", "--", "termancy-e2e-no-such-command" },
        .stderr = "termancy: termancy-e2e-no-such-command: command not found\n",
        .status = 127,
    },
};

/// A command run in a pseudo-terminal, with keys typed into it.
const PtyCase = struct {
    name: []const u8,
    /// A shell command; `"$TERMANCY"` is the termancy binary. Its standard output is the result.
    command: []const u8,
    /// Typed once the first frame is drawn, as `printf` reads them (`\r` is enter,
    /// `\033` esc, `\003` Ctrl-C, `\004` Ctrl-D).
    keys: []const u8,
    env: []const [2][]const u8 = &.{},
    stdout: []const u8 = "",
    status: u8 = 0,
    /// What the terminal shows before the keys are typed: by default, the end of a frame.
    wait_for: []const u8 = "2026l",
    /// A second round: once the terminal has shown `then_wait_for` `then_count` times in
    /// all, `then_keys` are typed.
    then_wait_for: []const u8 = "",
    then_count: u8 = 1,
    then_keys: []const u8 = "",
    /// Run under `test/jobctl.zig` (`$JOBCTL`), which stops and continues the command as a
    /// shell's job control does.
    jobctl: bool = false,
};

/// `cfg edit` of a fresh `app.toml` holding `a = 1`, with `reedit.sh` as the editor (a
/// broken file first, then `a = 2`); prints the file afterwards, and exits as termancy did.
const cfg_edit =
    "(d=$(mktemp -d); printf 'a = 1\\n' > \"$d/app.toml\"; " ++
    "EDITOR=\"sh $PWD/reedit.sh\" \"$TERMANCY\" cfg edit \"$d/app.toml\"; s=$?; " ++
    "cat \"$d/app.toml\"; rm -rf \"$d\"; exit $s)";

const choose_abc = "\"$TERMANCY\" ui choose a b c";

const accessible = [_][2][]const u8{.{ "ACCESSIBLE", "1" }};

const pty_cases = [_]PtyCase{
    .{ .name = "choose: down, enter", .command = choose_abc, .keys = "j\\r", .stdout = "b\n" },
    .{ .name = "choose: esc", .command = choose_abc, .keys = "\\033", .status = 1 },
    .{ .name = "choose: Ctrl-C", .command = choose_abc, .keys = "\\003", .status = 130 },
    .{
        .name = "choose: items piped in, NO_COLOR",
        .command = "printf 'x\\ny\\n' | \"$TERMANCY\" ui choose --selected y",
        .keys = "\\r",
        .env = &no_color,
        .stdout = "y\n",
    },
    .{
        .name = "choose --limit 2: space chooses",
        .command = "\"$TERMANCY\" ui choose --limit 2 a b c",
        .keys = " jj \\r",
        .stdout = "a\nc\n",
    },
    .{
        // gum's timeout: nothing chosen, `timed out` on stderr, status 124. (The inner
        // shell puts stderr where the driver puts stdout.)
        .name = "choose --timeout",
        .command = "sh -c '\"$TERMANCY\" ui choose --timeout 100ms a b c 2>&1'",
        .keys = "",
        .stdout = "timed out\n",
        .status = 124,
    },
    .{
        .name = "choose: flags from TERMANCY_CHOOSE_* variables",
        .command = choose_abc,
        .keys = "\\r",
        .env = &.{
            .{ "TERMANCY_CHOOSE_HEADER", "Pick one" },
            .{ "TERMANCY_CHOOSE_SELECTED", "c" },
        },
        .wait_for = "Pick one",
        .stdout = "c\n",
    },
    .{
        // Escapes go from standard input, and the delimiters are typed with escapes.
        .name = "choose: --input-delimiter, --output-delimiter, --strip-ansi",
        .command = "printf 'x,\\033[31my\\033[0m\\n' | " ++
            "\"$TERMANCY\" ui choose --input-delimiter , --output-delimiter '\\t' --no-limit",
        .keys = "a\\r",
        .stdout = "x\ty\n",
    },
    .{ .name = "confirm: y", .command = "\"$TERMANCY\" ui confirm Sure?", .keys = "y" },
    .{ .name = "confirm: n", .command = "\"$TERMANCY\" ui confirm", .keys = "n", .status = 1 },
    .{
        .name = "confirm: enter takes --default no",
        .command = "\"$TERMANCY\" ui confirm --default no",
        .keys = "\\r",
        .status = 1,
    },
    .{
        .name = "input: typed text",
        .command = "\"$TERMANCY\" ui input --value 'hi '",
        .keys = "there\\r",
        .stdout = "hi there\n",
    },
    .{
        .name = "input --password",
        .command = "\"$TERMANCY\" ui input --password",
        .keys = "s3cret\\r",
        .stdout = "s3cret\n",
    },
    .{ .name = "input: esc", .command = "\"$TERMANCY\" ui input", .keys = "abc\\033", .status = 1 },
    .{
        // alt+enter starts a line (enter would submit, as gum's); Ctrl-D submits too.
        .name = "write: alt+enter, then Ctrl-D",
        .command = "\"$TERMANCY\" ui write",
        .keys = "one\\033\\rtwo\\004",
        .stdout = "one\ntwo\n",
    },
    .{
        .name = "filter: fuzzy query",
        .command = "printf 'apple\\nbanana\\ncherry\\n' | \"$TERMANCY\" ui filter",
        .keys = "bna\\r",
        .stdout = "banana\n",
    },
    .{
        .name = "filter --no-limit: tab chooses",
        .command = "printf 'apple\\nbanana\\ncherry\\n' | \"$TERMANCY\" ui filter --no-limit",
        .keys = "\\t\\t\\r",
        .stdout = "apple\nbanana\n",
    },
    .{
        .name = "table: choose a row",
        .command = "printf 'n,v\\nx,1\\n\"y,z\",2\\n' | \"$TERMANCY\" ui table",
        .keys = "j\\r",
        .stdout = "\"y,z\",2\n",
    },
    .{ .name = "pager: q", .command = "\"$TERMANCY\" ui pager notes.txt", .keys = "jG/a\\rq" },
    .{
        .name = "pager from standard input: esc",
        .command = "printf 'text\\n' | \"$TERMANCY\" ui pager",
        .keys = "\\033",
        .status = 1,
    },
    .{
        // No standard stream a terminal: the keys come through the controlling terminal
        // (on macOS, its own device, which a lone Esc must not wait on).
        .name = "pager with every stream redirected: esc",
        .command = "printf 'text\\n' | \"$TERMANCY\" ui pager 2>/dev/null",
        .keys = "\\033",
        .status = 1,
    },
    .{
        .name = "spin on a terminal",
        .command = "\"$TERMANCY\" ui spin --title wait -- sh -c 'sleep 0.3; echo done'",
        .keys = "",
        .stdout = "done\n",
    },
    .{
        .name = "spin: Ctrl-C stops the command",
        .command = "\"$TERMANCY\" ui spin -- sh -c 'sleep 20; echo late'",
        .keys = "\\003",
        .status = 130,
    },
    .{
        // Directories first, then notes.txt, the one .txt file; G goes to it.
        .name = "file: choose with --ext",
        .command = "\"$TERMANCY\" ui file --ext .txt | sed \"s|^$PWD/||\"",
        .keys = "G\\r",
        .stdout = "notes.txt\n",
    },
    .{
        .name = "file: into a directory and back up, esc",
        .command = "\"$TERMANCY\" ui file",
        .keys = "l\\177\\033",
        .status = 1,
    },
    .{
        // A form, then a question only an app is asked: keys typed ahead reach the next
        // program.
        .name = "flow: a form, then a question that depends on it, asked with components",
        .command = "\"$TERMANCY\" ui demo flow",
        .keys = "ada\\r\\033[C\\ry",
        .stdout = "created ada (app, with tests)\n",
    },
    .{
        .name = "flow: a library skips the tests question",
        .command = "\"$TERMANCY\" ui demo flow",
        .keys = "lib\\r\\r",
        .stdout = "created lib (library)\n",
    },
    .{
        .name = "ACCESSIBLE: choose by number",
        .command = "\"$TERMANCY\" ui choose a b c",
        .keys = "9\\r2\\r",
        .env = &accessible,
        .wait_for = "Number (1-3)",
        .stdout = "b\n",
    },
    .{
        .name = "ACCESSIBLE: choose several",
        .command = "\"$TERMANCY\" ui choose --no-limit a b c",
        .keys = "1, 3\\r",
        .env = &accessible,
        .wait_for = "Numbers (1-3",
        .stdout = "a\nc\n",
    },
    .{
        .name = "ACCESSIBLE: confirm, default no",
        .command = "\"$TERMANCY\" ui confirm --default no Sure?",
        .keys = "\\r",
        .env = &accessible,
        .wait_for = "Sure? (y/N)",
        .status = 1,
    },
    .{
        .name = "ACCESSIBLE: input",
        .command = "\"$TERMANCY\" ui input --header Name",
        .keys = "Ada\\r",
        .env = &accessible,
        .wait_for = "Name: ",
        .stdout = "Ada\n",
    },
    .{
        .name = "pager: v edits the file, and the pager shows it again",
        .command = "(d=$(mktemp -d); printf 'one\\n' > \"$d/n.txt\"; " ++
            "EDITOR=\"sh $PWD/append.sh\" \"$TERMANCY\" ui pager \"$d/n.txt\"; s=$?; " ++
            "cat \"$d/n.txt\"; rm -rf \"$d\"; exit $s)",
        .keys = "v",
        .then_wait_for = "appended-line",
        .then_keys = "q",
        .stdout = "one\nappended-line\n",
    },
    .{
        // Ctrl-Z stops the process group; jobctl continues it in the foreground, as `fg`
        // does, and it redraws (the third frame) before enter chooses.
        .name = "choose: Ctrl-Z suspends, fg resumes",
        .command = "\"$JOBCTL\" \"$TERMANCY\" ui choose a b c",
        .keys = "j\\032",
        .then_wait_for = "2026l",
        .then_count = 3,
        .then_keys = "\\r",
        .stdout = "b\n",
        .jobctl = true,
    },
    .{
        .name = "help taller than the terminal goes through $PAGER",
        .command = "(stty rows 10 cols 80; echo ready > /dev/tty; " ++
            "PAGER=\"sh -c 'head -n 1 >&3'\" \"$TERMANCY\" cfg --help 3>&1 > /dev/tty)",
        .keys = "",
        .wait_for = "ready",
        .stdout = "Read configuration from TOML, YAML, JSON (with or without comments), ZON, " ++
            "dotenv,\n",
    },
    .{
        .name = "cfg edit: a broken file, edited again",
        .command = cfg_edit,
        .keys = "e\\r",
        .wait_for = "What now?",
        .stdout = "a = 2\n",
    },
    .{
        .name = "cfg edit: a broken file, given up",
        .command = cfg_edit,
        .keys = "x\\r",
        .wait_for = "What now?",
        .stdout = "a = 1\n",
        .status = 1,
    },
    // input/write/confirm (gum parity)
    .{
        .name = "input: the value from standard input",
        .command = "printf '  piped value\\n' | \"$TERMANCY\" ui input",
        .keys = "!\\r",
        .stdout = "piped value!\n",
    },
    .{
        // The dots are drawn before enter is typed.
        .name = "input --password shows dots",
        .command = "\"$TERMANCY\" ui input --password --no-show-help",
        .keys = "s3cret",
        .then_wait_for = "••••••",
        .then_keys = "\\r",
        .stdout = "s3cret\n",
    },
    .{
        // The interface goes to the terminal; only the answer is captured.
        .name = "input in $(...): only the result",
        .command = "x=$(\"$TERMANCY\" ui input --header Name); printf '[%s]\\n' \"$x\"",
        .keys = "Ada\\r",
        .stdout = "[Ada]\n",
    },
    .{
        .name = "input: flags from TERMANCY_INPUT_* variables",
        .command = "\"$TERMANCY\" ui input",
        .keys = " there\\r",
        .env = &.{.{ "TERMANCY_INPUT_VALUE", "hi" }},
        .stdout = "hi there\n",
    },
    .{
        // Enter submits, as gum's.
        .name = "write: the value from standard input, enter submits",
        .command = "printf 'line one\\r\\nline two\\n' | \"$TERMANCY\" ui write",
        .keys = "\\r",
        .stdout = "line one\nline two\n",
    },
    .{
        .name = "write: ctrl+e edits the text in $EDITOR",
        .command = "EDITOR=\"sh $PWD/append.sh\" \"$TERMANCY\" ui write --value one",
        .keys = "\\005",
        .then_wait_for = "appended-line",
        .then_keys = "\\r",
        .stdout = "one\nappended-line\n",
    },
    .{
        // ctrl+j (LF) starts a line, as gum's.
        .name = "write --show-line-numbers --max-lines 2",
        .command = "\"$TERMANCY\" ui write --show-line-numbers --max-lines 2",
        .keys = "a\\nb\\nc\\r",
        .stdout = "a\nbc\n",
    },
    .{
        .name = "ACCESSIBLE: write, ended by an empty line twice",
        .command = "\"$TERMANCY\" ui write --header Notes",
        .keys = "one\\r\\rtwo\\r\\r\\r",
        .env = &accessible,
        .wait_for = "ends it.",
        .stdout = "one\n\ntwo\n",
    },
    .{
        // gum's timeout: no error, the answer highlighted (the default) is taken.
        .name = "confirm --timeout takes the default, yes",
        .command = "sh -c '\"$TERMANCY\" ui confirm --timeout 100ms 2>&1'",
        .keys = "",
    },
    .{
        .name = "confirm --timeout takes the default, no",
        .command = "sh -c '\"$TERMANCY\" ui confirm --default=false --timeout 100ms 2>&1'",
        .keys = "",
        .status = 1,
    },
    .{
        .name = "confirm --show-output",
        .command = "\"$TERMANCY\" ui confirm --show-output --affirmative Ship 'Deploy?'",
        .keys = "y",
        .stdout = "Deploy? Ship\n",
    },
    .{
        .name = "confirm: flags from TERMANCY_CONFIRM_* variables",
        .command = "\"$TERMANCY\" ui confirm",
        .keys = "\\r",
        .env = &.{
            .{ "TERMANCY_CONFIRM_DEFAULT", "false" },
            .{ "TERMANCY_CONFIRM_SHOW_OUTPUT", "1" },
        },
        .stdout = "Are you sure? No\n",
        .status = 1,
    },
};

/// Runs `$3` (a shell command) in a pseudo-terminal with `TERMANCY=$1`, types `$2` once the
/// terminal shows `$4` (for a `tui` command, the end of its first frame: synchronized
/// output ends with `2026l`), then `$6` once it has shown `$5` `$7` times (when `$5` is
/// set), and prints what the command wrote to standard output. Exits with the command's
/// status (124 on a timeout, or 142 where perl's alarm stands in for `timeout`).
/// Works with util-linux `script` (`-qfc command log`) and BSD `script`, as macOS has it
/// (`-qF log command...`); the status goes through a file, since only util-linux has `-e`.
const pty_driver =
    \\termancy=$1 keys=$2 command=$3 wait=$4 then_wait=$5 then_keys=$6 then_count=$7 jobctl=$8
    \\dir=$(mktemp -d) || exit 99
    \\trap 'rm -f "$dir/log" "$dir/out" "$dir/status"; rmdir "$dir"' EXIT
    \\# A minute at most: with `timeout`, else perl's alarm (macOS has no `timeout`).
    \\limit() { "$@"; }
    \\if command -v timeout > /dev/null 2>&1; then
    \\  limit() { timeout 60 "$@"; }
    \\elif command -v perl > /dev/null 2>&1; then
    \\  limit() { perl -e 'alarm shift; exec @ARGV' 60 "$@"; }
    \\fi
    \\shown() {
    \\  i=0
    \\  until [ "$(grep -aoF "$1" "$dir/log" 2> /dev/null | wc -l)" -ge "$2" ]; do
    \\    i=$((i + 1))
    \\    [ "$i" -gt 200 ] && break
    \\    sleep 0.05
    \\  done
    \\}
    \\feed() {
    \\  shown "$wait" 1
    \\  printf "$keys"
    \\  sleep 0.5
    \\  [ -n "$then_wait" ] || return 0
    \\  shown "$then_wait" "$then_count"
    \\  printf "$then_keys"
    \\  sleep 0.5
    \\}
    \\# A handler (not `trap '' INT`, which children would inherit) keeps this shell alive
    \\# to record the status when Ctrl-C interrupts the command.
    \\inner="trap : INT; $command > \"$dir/out\"; echo \$? > \"$dir/status\""
    \\export TERMANCY="$termancy" JOBCTL="$jobctl"
    \\if script --version > /dev/null 2>&1; then
    \\  feed | limit script -qfc "$inner" "$dir/log" > /dev/null
    \\else
    \\  feed | limit script -qF "$dir/log" sh -c "$inner" > /dev/null
    \\fi
    \\status=$?
    \\# A timeout: what the terminal last showed, to see where the command stuck.
    \\if [ "$status" = 124 ] || [ "$status" = 142 ]; then
    \\  echo "timed out; the terminal's last output:" >&2
    \\  tail -c 600 "$dir/log" | cat -v >&2
    \\  echo >&2
    \\fi
    \\[ -f "$dir/status" ] && status=$(cat "$dir/status")
    \\cat "$dir/out" 2> /dev/null
    \\exit $status
;

pub fn addCases(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    for (cases) |case| addCase(b, step, runTermancy(b, exe, null), case);
    // setsid as util-linux has it; script(1) from util-linux or the BSDs (macOS).
    const os = builtin.os.tag;
    if (os != .linux and !os.isDarwin()) return;
    if (os == .linux) if (b.findProgram(.{ .names = &.{"setsid"} })) |setsid| {
        for (detached_cases) |case| addCase(b, step, runTermancy(b, exe, setsid), case);
    };
    const sh = b.findProgram(.{ .names = &.{"sh"} }) orelse return;
    _ = b.findProgram(.{ .names = &.{"script"} }) orelse return;
    const jobctl = b.addExecutable(.{ .name = "jobctl", .root_module = b.createModule(.{
        .root_source_file = b.path("test/jobctl.zig"),
        .target = b.graph.host,
        .link_libc = true,
    }) });
    for (pty_cases) |case| addPtyCase(b, exe, step, sh, case, if (case.jobctl) jobctl else null);
}

/// A run of termancy, under `setsid` when given.
fn runTermancy(b: *std.Build, exe: *std.Build.Step.Compile, setsid: ?[]const u8) *std.Build.Step.Run {
    const path = setsid orelse return b.addRunArtifact(exe);
    const run = std.Build.Step.Run.create(b, "setsid termancy");
    run.addArgs(&.{ path, "--wait" });
    run.addArtifactArg(exe);
    return run;
}

fn addCase(b: *std.Build, step: *std.Build.Step, run: *std.Build.Step.Run, case: Case) void {
    run.setName(b.fmt("e2e: tui {s}", .{case.name}));
    run.setCwd(b.path("test/fixtures"));
    run.clearEnvironment();
    // The environment is exactly what the case says: no NO_COLOR from the build runner.
    run.color = .manual;
    // spin finds its command on PATH.
    if (b.graph.environ_map.get("PATH")) |path| run.setEnvironmentVariable("PATH", path);
    for (case.env) |pair| run.setEnvironmentVariable(pair[0], pair[1]);
    if (case.stdin) |bytes| run.setStdIn(.{ .bytes = bytes });
    run.addArgs(case.args);
    run.expectStdOutEqual(case.stdout);
    run.expectStdErrEqual(case.stderr);
    run.expectExitCode(case.status);
    step.dependOn(&run.step);
}

fn addPtyCase(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step: *std.Build.Step,
    sh: []const u8,
    case: PtyCase,
    jobctl: ?*std.Build.Step.Compile,
) void {
    const run = std.Build.Step.Run.create(b, b.fmt("e2e: tui in a terminal: {s}", .{case.name}));
    run.addArgs(&.{ sh, "-c", pty_driver, "sh" });
    run.addArtifactArg(exe);
    run.addArgs(&.{ case.keys, case.command, case.wait_for });
    run.addArgs(&.{ case.then_wait_for, case.then_keys, b.fmt("{d}", .{case.then_count}) });
    if (jobctl) |j| run.addArtifactArg(j) else run.addArg("");
    run.setCwd(b.path("test/fixtures"));
    run.clearEnvironment();
    run.color = .manual;
    if (b.graph.environ_map.get("PATH")) |path| run.setEnvironmentVariable("PATH", path);
    run.setEnvironmentVariable("TERM", "xterm-256color");
    for (case.env) |pair| run.setEnvironmentVariable(pair[0], pair[1]);
    run.expectStdOutEqual(case.stdout);
    run.expectStdErrEqual("");
    run.expectExitCode(case.status);
    step.dependOn(&run.step);
}
