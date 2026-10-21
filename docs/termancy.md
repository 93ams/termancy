# The `termancy` program

A program built only from the libraries' public surfaces: configuration tooling, project and
command generators, gum-style shell widgets, a Markdown reader (glow), terminal recordings as
GIFs (vhs), images of code (freeze), and system information. What it prints for scripts is a
contract: [machine-output.md](machine-output.md). To install it, see the
[README](../README.md#install).

## A tour

```sh
termancy cfg get server.port                   # from ./termancy.toml (or .yaml, .json, .zon, .env)
termancy cfg -c base.toml -c local.yaml show -o json
termancy cfg --env-prefix APP explain          # where every value comes from
termancy cfg --profile prod get server.host
termancy cfg set server.port 9090 -c app.toml
termancy cfg convert app.toml --to yaml
termancy cfg diff base.toml prod.yaml          # exit 1 when they differ, as diff(1)
eval "$(termancy cfg env --prefix APP)"        # export APP_SERVER_PORT=... and the rest
termancy cfg validate *.toml
termancy cfg keys -0 | xargs -0 -n1 echo       # NUL-separated for odd keys
termancy cli docs --format man > termancy.1
source <(termancy cli completion bash)
color=$(termancy ui choose red green blue)     # the menu draws on the terminal
termancy ui confirm "Deploy?" && make deploy
git log --oneline | termancy ui filter
termancy ui spin --title "Building" -- zig build
termancy md README.md                          # read Markdown in a reader (glow)
termancy record demo.tape                      # a terminal session as a GIF (vhs)
termancy freeze main.zig --window -o main.png  # an image of code (freeze)
termancy serve -- termancy ui demo             # a TUI for everyone who connects with ssh (wish)
termancy dirs                                  # where config, cache, and state live
```

## Conventions

- **Streams:** results go to stdout, diagnostics to stderr.
- **Quiet:** `-q` silences warnings, never errors.
- **NUL output:** `-0` gives NUL-separated output where items could contain newlines.
- **No prompts:** nothing prompts when stdin isn't a terminal. Such paths exit 2 and name the
  flag to pass instead.
- **Color:** `NO_COLOR` is honored everywhere.
- **Closed pipe:** a closed stdout exits 141 without an error message.

## `cfg`: configuration files

| command | |
|---|---|
| `get <key>` (`--default`, `--raw`, `--as int\|duration\|...`), `keys [prefix]`, `show`, `explain [prefix]` | query the effective configuration |
| `profile list`, `profile use <name>` (`--clear`) | the `profiles.*` sections, and the one used by default |
| `env` (`--prefix`, `--shell sh\|fish\|powershell`) | the configuration as variable exports, quoted to be safe to evaluate |
| `set <key> <value>`, `unset <key>` | edit a file in place, atomically, keeping comments |
| `edit [file]` | open it in `$EDITOR`; saved only when it parses, as visudo does |
| `convert <file\|->` | change format |
| `validate <file>...` (`--schema`) | check files, or without files the effective configuration; warns about plain-text secrets and deprecated keys |
| `fmt <file>...` (`--sort`) | format, keeping comments |
| `diff <old> <new>` | the keys that differ |
| `redact <file\|->` | secret-looking values replaced, layout kept, for bug reports |
| `encrypt <file>`, `decrypt <file.enc>` | keep secrets in a repository; `-c x.enc` reads them with `$TERMANCY_PASSPHRASE` |
| `merge <file>...`, `init [file]` (`--schema`), `schema infer <file>`, `schema check <schema> <file>...` | combine, start, and describe files |

Flags:

| | |
|---|---|
| `-c/--config` | the files to load; repeatable, `TERMANCY_CONFIG` |
| `--profile` | `TERMANCY_PROFILE` |
| `--env-prefix` | read variables with this prefix |
| `--set key=value` | an override |
| `-o/--output` | `text\|json\|yaml\|toml\|zon\|env\|ini\|systemd` |

Without `--config`, the first `termancy.*` in `.`, `$XDG_CONFIG_HOME/termancy`, or
`~/.config/termancy` is loaded. Keys and `--profile` names complete in the shell.

`set` and `unset` keep a file's comments and layout, changing only the edited lines, and `fmt`
keeps the comments of TOML, ZON, dotenv, and YAML. What cannot be done in place (an array
element in JSON, say) is rewritten whole, losing its comments, with a warning.

## `cli` and `tui`: building apps

| command | |
|---|---|
| `cli init <name>`, `cli add <path...>` (`--flow`) | generate a project, and commands (or flows) in it |
| `cli docs` (`--format markdown\|man\|html\|json`, `--dir`, `--stylesheet`), `cli completion <shell>` | documentation and shell completion |
| `cli repl` | termancy's commands as an interactive shell, or a script on stdin |
| `tui init`, `add <component>...`, `list`, `diff <component>`, `demo [component]` | copy components into a project (any subdirectory of it; `init` wires the nearest `build.zig`), keep them current, and try them first |

## `ui`: shell-script widgets

`ui choose`, `confirm`, `input`, `write`, `filter`, `spin`, `table`, `pager`, `file`, `style`,
`format`, `join`, `log`: in the spirit of [gum](https://github.com/charmbracelet/gum).
`ACCESSIBLE=1` asks with plain lines.

The commands share gum's conventions, each where it applies:

- **Variables:** every flag can come from `TERMANCY_<COMMAND>_<FLAG>`, its name in
  SCREAMING_SNAKE: `TERMANCY_CHOOSE_HEIGHT=5`, `TERMANCY_CHOOSE_CURSOR_FOREGROUND=212`. The
  command line wins.
- **`--timeout <duration>`** (`500ms`, `5s`, `1m30s`; `0`, the default, waits forever): ends
  with status 124 and `timed out` on stderr, unless the command's help says what a timeout
  answers instead.
- **Style groups:** `--<part>.<style>` styles one part of a component, such as
  `--cursor.foreground 212`, `--header.bold`, `--header.border rounded`. The styles are
  `ui style`'s flags: `foreground`, `background`, `border`, `border-foreground`,
  `border-background`, `align`, `width`, `height`, `margin`, `padding`, `bold`, `faint`,
  `italic`, `strikethrough`, `underline`. Colors are 0-255, `#rrggbb`, or a name. Help lists
  each part's colors; the rest work without being listed, as in gum. Unset, a part keeps the
  theme's look: the accent for the cursor and chosen items, the heading style for headers.
- **`--show-help`** (on; `--no-show-help` turns it off): the keys, under the component.
- **`--padding`:** space around the whole component: `1`, `1 2`, or `1 2 1 2`.
- **Standard input:** `--strip-ansi` (on) removes escape sequences, `--input-delimiter`
  splits it into items, and `--output-delimiter` separates the items printed (both `\n` by
  default, typed with escapes: `\n`, `\t`, `\0`, `\\`).

`ui input` and `ui write` start from `--value`, or else from standard input when it is
piped; their cursor is the terminal's own (`--cursor.mode blink`, `static`, or `hide`).
`write` submits with enter, starts a line with ctrl+j or alt+enter, and opens the text in
`$VISUAL` or `$EDITOR` with ctrl+e. `ui confirm` answers with its status (0 yes, 1 no);
`--show-output` prints the question and the answer, `--default` takes `yes`/`no` or gum's
`--default=false`, and `--timeout` takes the highlighted answer instead of failing.

## Terminal output and media

| command | |
|---|---|
| `md [source]` | Markdown from a file, a URL, or a repository's README, in a reader, as [glow](https://github.com/charmbracelet/glow) |
| `record <tape>` (`-o`), `record new`, `validate`, `capture`, `themes` | terminal sessions from scripts, as [vhs](https://github.com/charmbracelet/vhs) tapes: GIF, PNG, frames, text for golden tests, animated SVG, MP4 and WebM (with ffmpeg); `capture` writes a tape from what you type |
| `freeze [file]` (`-x command`, `--window`, `--shadow`, `-n`, `--lines`) | images of code or of a command's output, PNG or SVG, as [freeze](https://github.com/charmbracelet/freeze) |
| `image <file>` | a PNG, JPEG, or GIF in the terminal (kitty, iTerm2, sixel, or half blocks) |
| `explain [file...] [-- command]` | what each escape sequence in some output does, as [sequin](https://github.com/charmbracelet/sequin) |

## Serving, SSH, and releases

| command | |
|---|---|
| `serve -- command` | a terminal program over SSH, as [wish](https://github.com/charmbracelet/wish), or with `--web` in the browser, as [ttyd](https://github.com/tsl0922/ttyd) (a token link swapped for a cookie, loopback by default, at most 32 sessions) |
| `ssh keygen`, `fingerprint`, `melt`, `restore`, `sign`, `verify`, `run` | SSH keys as `ssh-keygen` makes them, backed up as 24 words ([melt](https://github.com/charmbracelet/melt)), and files signed as `ssh-keygen -Y` signs them |
| `release keygen`, `sign`, `verify`, `manifest` | publish releases `sys.update` installs: Ed25519 signatures and package manifests |

## System

| command | |
|---|---|
| `dirs`, `info`, `update` | standard directories, system facts, self-update |
| `version`, `help [command...]`, `help --search <words>` | |
