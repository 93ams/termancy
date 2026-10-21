# `tui`

Terminal user interfaces: an Elm-architecture runner that redraws only the cells that changed,
springs for animation, input decoding, a headless test driver with golden files, and programs
served over SSH. Ready-made components are source you copy and own, as with [shadcn/ui]. The
roles of Bubble Tea, Bubbles, huh, harmonica, and teatest.

[shadcn/ui]: https://ui.shadcn.com

- [A program](#a-program)
- [Running](#running)
- [Commands](#commands)
- [Drawing](#drawing)
- [Input and the terminal](#input-and-the-terminal)
- [Serving over SSH or the browser](#serving-over-ssh-or-the-browser)
- [Testing](#testing)
- [Components](#components)

## A program

A program is a model with `update` and `view`:

```zig
pub const Confirm = struct {
    question: []const u8,
    answer: bool = false,

    pub fn update(model: *Confirm, msg: tui.Msg) tui.Cmd {
        const key = switch (msg) {
            .key => |key| key,
            else => return .none,
        };
        if (key.matches("y")) model.answer = true;
        if (key.matches("enter") or key.matches("y") or key.matches("n")) return .quit;
        return .none;
    }

    pub fn view(model: *const Confirm, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const accent: tui.Style = .{ .fg = .hex(0xff8700), .bold = true };
        try accent.paint(w, "? ");
        try w.print("{s} [y/N]\n", .{model.question});
    }
};

var confirm: Confirm = .{ .question = "Deploy?" };
const status = try tui.run(gpa, io, &confirm, .{});
```

A model may also have:

- `above`: lines that stay above an inline program (logs, finished steps);
- `work`: run in the background by `Cmd.work`;
- `handoff`: given the terminal by `Cmd.handoff`;
- a message filter, and calls to place the terminal's cursor, set the window title, and copy
  to the clipboard.

## Running

`tui.Program` runs a model on the terminal; `tui.run` is the short form.

- `tui.run` returns the exit status (130 when interrupted) and, without a terminal, prints the
  first frame as text.
- `Program` borrows the model through a pointer, so components may hold slices of it.
- Inline (redrawn in place) or full screen. The UI draws on the controlling terminal even when
  stdio is redirected, so a program works inside `$(...)`.
- Ctrl-C ends the program as interrupted (exit 130), and the terminal is always restored.
- Ctrl-Z is an ordinary key (undo in text fields). A program that wants job control sets
  `suspend_on_ctrl_z` or returns `Cmd.suspend_process`, and `fg` resumes it.

## Commands

| | |
|---|---|
| `Cmd.work(id, arg)` | runs the model's `work` function in the background and delivers its result as a message |
| `Cmd.handoff(id)` | lends the terminal to the model's `handoff`, to run an editor or a pager, and takes it back |
| `Cmd.suspend_process` | job control, as Ctrl-Z in a shell |
| `Cmd.quit` | ends the program |

## Drawing

- Frames are drawn by cell: only the cells that changed are written, at most
  `Options.max_fps` times a second.
- Colors are written at full fidelity and lowered to what the terminal supports (`NO_COLOR`,
  `FORCE_COLOR`, `TERM`, `COLORTERM`).
- `Style` has curly, dotted, dashed, and double underlines, and underline colors.
- `layout.split` divides rows or columns by lengths, percentages, and fills.
- `tui.motion` has springs and projectiles (harmonica) for animation.
- `ansi.notify` and `ansi.setProgress` reach the desktop and the taskbar.

## Input and the terminal

- `tui.Keymap` declares key bindings once, for matching keys and for the help line.
- `tui.focus` keeps tab order (`Ring`) or moves in two dimensions (`Grid`).
- `Options.queries` asks the terminal for its colors (dark or light, `Rgb.isDark`), whether it
  knows a mode, and the kitty keyboard protocol; replies arrive as `.report` messages.
- `Program.Options.kitty_keyboard` asks the terminal for the kitty keyboard protocol, for
  unambiguous modifiers.

## Serving over SSH or the browser

`Program.runSession` (or `tui.runSession`) runs a program over a remote terminal, at the
session's size:

- an SSH session from `sys.ssh.Server`, so one binary serves a TUI to everyone who connects,
  as wish does;
- a browser's socket from `sys.web.Server`, which has the same session surface.

## Testing

`tui.testing.Driver` runs a model in memory with a virtual clock and screen. Unlike `Program`,
it owns its model.

- It compares screens and output with golden files, and moves the clock until something
  shows (`advanceUntil`), as teatest does.
- `testing.Screen.writeSvg` draws what a test's terminal shows as an SVG image.

## Components

Components are not part of the module. `termancy tui add select` copies `select.zig` (and
`list.zig`, which it needs) into your project. From then on the file is yours to change;
`termancy tui diff` and `termancy tui add` (which refuses to overwrite your edits) keep you in
touch with upstream. `termancy ui demo <component>` runs one on sample data, and `--svg` draws
it.

| component | |
|---|---|
| `confirm` | yes or no |
| `input` | a line of text, with suggestions |
| `textarea` | several lines, with line numbers |
| `list`, `select`, `multiselect`, `filter` | choosing from items; mouse clicks and the wheel |
| `spinner` | |
| `progress`, `multiprogress` | gradients and spring animation |
| `table`, `tree`, `chart` | data: sparklines and bars in `chart` |
| `pager`, `viewport`, `markdown` | scrolling areas; `viewport` embeds, both ways; `pager` searches, with line numbers; `markdown` is a reader |
| `paginator`, `tabs`, `help` | |
| `stopwatch`, `timer` | |
| `filepicker` | permissions and sizes; files, directories, or both to choose |
| `form` | huh: inputs, texts, selects with filtering, multi-selects, confirms, files, notes, pages, conditions, and themes |
| `prompts` | questions for a `cli.Flow`, asked with the components |
| `shell` | a line editor with history and tab completion, for `cli.repl` |
