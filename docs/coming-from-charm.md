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

Charm's products (crush, mods, soft-serve, pop, and its cloud) are applications, not
libraries, and have no counterpart here.
