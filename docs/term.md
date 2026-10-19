# `term`

What every terminal program needs, below any framework; `cli` uses it for colored help and
`tui` for everything it draws. Nothing in it runs an event loop. It does the work of Charm's
lipgloss, ultraviolet, x/ansi, x/vt, colorprofile, glamour, and sequin.

| | |
|---|---|
| detection | `capability.detect`: the color profile (none, 16, 256, true color) from `NO_COLOR`, `CLICOLOR_FORCE`, `FORCE_COLOR`, `COLORTERM`, `TERM`, and the terminal's own variables (kitty, Ghostty, WezTerm, iTerm2, VS Code, Windows Terminal, ...); `ansi.Downsampler` lowers any styled output to it as it is written |
| text | `width`: display width, wrapping, truncation and cutting that keep styles and links open across lines, and grapheme clusters by UAX #29 with Unicode 17 tables, checked against the Unicode test suite |
| styling | `Style` (lipgloss): colors, attributes, padding, margins, borders (with titles, per-side colors, and gradients), alignment, sizes; `layout` joins and places blocks; `Canvas` stacks layers; `Table`, `List`, and `Tree`; `Color` blends in Oklab, makes gradients, and picks light or dark variants |
| sequences | `ansi` writes them; `Parser` reads any (VT500); `Pen` tracks SGR state; `explain` says what each does (sequin) |
| emulation | `vt.Screen`: a terminal emulator with scrollback, modes, queries, OSC titles, links, and clipboard, written out as text, ANSI, or SVG; `Pty` runs a program on a pseudo-terminal (ConPTY on Windows); `Buffer` and `Renderer` draw frames by cell |
| content | `highlight` (30 languages, themes), `markdown` (CommonMark and GFM, style sheets, as glamour), `Regex` |
| pixels | `TrueType` and `fonts` (the machine's fonts, with fallbacks), `raster` (a screen in a window with a bar, rounded corners, and a shadow), `image` (PNG read and written, JPEG read (baseline and progressive, any subsampling, CMYK, EXIF orientation), GIF animated and read, resizing, quantizing), `graphics` (images in the terminal: kitty, iTerm2, sixel, or half blocks; support found from the environment or by asking the terminal) |
| tests | `golden.expect`: output against files kept with the tests, escapes shown as text, rewritten with `TERMANCY_UPDATE_GOLDEN=1` |
| diff | `diff`: line diffs written as unified diffs, colored like git when asked |
| progress | `live`: spinners (frame sets, styles, final symbols, elapsed time), progress bars (eighth-cell fill, gradients, counts, bytes/s, ETA), live text, and step checklists, without `tui.Program`: redrawn in place at a terminal, a line per change in logs and CI |

## Progress in a command

A long command shows progress through `ctx.live`, which draws on standard error in the
context's colors and stays quiet under `-q`:

```zig
var bar: term.live.Bar = .{ .label = "push", .total = size, .units = .bytes };
const items = [_]term.live.Item{.{ .bar = &bar }};
var display = ctx.live(&items);
while (try chunk()) |n| {
    bar.add(n);
    try display.tick(.now(ctx.io, .awake));
}
bar.finish(.success);
try display.finish(.now(ctx.io, .awake));
```

Tasks that report progress at the same time go through `display.update(io, context, change)`,
which runs the change under the display's lock and redraws.
