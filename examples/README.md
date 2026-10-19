# Examples

Each directory here is a small app with its own tests; `zig build examples` builds them, runs
their tests, and runs each once against its expected output. The doc comment at the top of
each `main.zig` lists what it shows and how to try it.

| example | shows |
|---|---|
| `first-app` | the code of [the guide](../docs/guide.md), checked word for word against it |
| `git-style` | nested command groups, persistent flags, typed positionals, aliases, bounds |
| `httpc` | the flag grammar: lists, split values, `Duration`/`ByteSize` flags, env secrets, `requires`, `exclusive`, renamed, deprecated, and hidden flags, `validate`, prompts for missing flags, help topics, `help --search`, response files, prefixes, middleware |
| `deploy` | a `cli.Flow` graph: a form, a probe, decisions, undo on failure, `--dry-run`, `-o json` step reports, `-v` logging, a Mermaid chart; asked through the `prompts` component at a terminal |
| `tasks` | translations with plurals, `--yes`, `--dry-run`, `-o json`, flag defaults from a file, user aliases |
| `kv` | an interactive shell with history and tab completion (`cli.repl` and the `shell` component), completion from data, plugins, generated docs, the pager, a private store in the data directory |
| `server-config` | layered configuration decoded into a struct, with each value's origin |
| `conf-d` | a `conf.d` directory merged across formats |
| `settings` | `cfg` tooling: variants, profiles, encrypted secrets, every problem located with a caret, JSON Schema, comment-preserving edits, diffs, migrations |
| `monitor` | a full-screen `tui` program from components (tabs, table, chart, spinner, progress), keymaps, timers, the mouse, and headless tests |
| `lobby` | a guestbook served over SSH: `sys.ssh.Server`, `Program.runSession`, state shared between sessions, border titles and gradients, golden-file and scripted-session tests |
| `repos` | a real tool end to end: a config file under `REPOS_*` overrides, a first-run `cli.Flow` that keeps the file's comments, `list -o text\|json\|jsonl`, concurrent `git fetch` under `ctx.live`, a filterable TUI from components copied with `termancy tui add` (its `ui/` and `tui.zon`), served with `--web` |
| `doctor` | `sys`: per-OS directories, CI detection, versions, path sandboxing, redacted logs, trace context, phase profiling |

The examples import the component registry as a module; a project copies the components in
with `termancy tui add <name>` instead, as `repos` did for its `ui/`.
