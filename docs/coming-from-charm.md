# Coming from Charm

Charm's open-source terminal libraries and tools, and where each one's work is done here:

| Charm | here |
|---|---|
| lipgloss | `term.Style`, `term.layout`, `term.Canvas`, `term.Table`, `term.List`, `term.Tree`, `term.Color` |
| ultraviolet, x/ansi, x/vt, x/term | `term.Buffer`, `term.Renderer`, `term.ansi`, `term.Parser`, `term.vt`, `term.Terminal` |
| colorprofile | `term.capability`, `term.ansi.Downsampler` |
| x/xpty, x/conpty | `term.Pty` |
| x/mosaic, sixel, kitty graphics | `term.graphics`, `termancy image` |
| x/editor | `sys.process.editAt` |
| x/exp/golden, x/exp/teatest | `term.golden`, `tui.testing.Driver` |
| bubbletea | `tui.Program` |
| bubbles | the component registry (`termancy tui add`) |
| huh | the `form` and `prompts` components, `cli.Flow` |
| harmonica | `tui.motion` |
| glamour | `term.markdown`, `term.highlight` |
| glow | `termancy md` |
| gum | `termancy ui choose`, `input`, `write`, `filter`, `confirm`, `file`, `pager`, `spin`, `table`, `style`, `format`, `join`, `log` |
| fang | `cli` with `cli.Theme` |
| log | `sys.log` |
| sequin | `term.explain`, `termancy explain` |
| vhs | `termancy record` (GIF without a browser or ffmpeg) |
| freeze | `termancy freeze` |
| wish, ssh | `sys.ssh.Server` and `Client`, `tui.Program.runSession`, `termancy serve` |
| ttyd, gotty (not Charm) | `sys.web.Server`, `termancy serve --web` |
| keygen | `sys.ssh.keys`, `termancy ssh keygen` |
| melt | `sys.mnemonic`, `termancy ssh melt` and `restore` |

`termancy ui` takes gum's commands with gum's flags, defaults, and exit statuses, so most
gum scripts work after `gum` → `termancy ui`:

- every flag can be set by a `TERMANCY_<COMMAND>_<FLAG>` variable (`TERMANCY_CHOOSE_HEIGHT`)
  where gum reads `GUM_<COMMAND>_<FLAG>`;
- style groups are spelled as gum's (`--cursor.foreground 212`, `--header.bold`) and
  default to `cli.Theme`'s colors rather than gum's pink and purple;
- `--timeout` ends with status 124 and `timed out` (confirm takes the highlighted answer),
  Ctrl-C with 130, and Esc with 1, printing nothing.

Where termancy deliberately differs, it is to stay predictable in scripts: several choices
print in a stable order, a strict `filter` waits instead of exiting 0 with nothing on an
unmatched enter, Esc cancels at once, `spin` signals the command's whole process group and
reports 126/127 for commands that cannot run, and `log --format` is gum's printf switch, so
the output format is `--formatter`. Templates in `ui format` are termancy's small template
language, not Go's `text/template` (no `if` or `range`).

Charm's products (crush, mods, soft-serve, pop, and its cloud) are applications, not
libraries, and have no counterpart here.
