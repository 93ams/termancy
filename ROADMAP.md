# Roadmap

What can make `cli`, `cfg`, `tui`, `platform`, and `snek` more capable and more mature,
ordered within each section by value for effort.

## The rule: no bloat

A feature belongs here only if it obeys all of these:

1. **Pay only for what you use.** If an app doesn't use it, nothing is compiled in, run, or
   shown in help. In practice: an optional `meta` key, an optional `App` or `Config` field
   with an inert default, or a separate module.
2. **No new dependencies.** Standard library only. OS services live in `platform`; network
   calls are thin, explicit functions there, never part of `cli`, `cfg`, or `tui`.
3. **No hidden work.** No threads, timers, or I/O the caller did not ask for. "Watch" and
   "refresh" are explicit calls.
4. **The simple case stays simple.** The README example must not get longer. New power
   arrives through defaults and conventions, not required boilerplate.
5. **The libraries stay independent.** `cli` and `tui` may build on `term`, the terminal
   layer they share; otherwise none imports another. They meet through conventions
   (`parse`, flag records, `std.mem.Allocator`, `*std.Io.Writer`, duck-typed sessions),
   and the program (`snek`) composes them.

Size: **S** is about a day, **M** a few days, **L** a week or more.

---

## 1. `cli`

Everything planned here has shipped: typed positionals, flag aliases, bounds and
`.one_of`, `validate`, value suggestions, response files, prefix matching, non-interspersed
and pass-through arguments, completers and shell directives, help that wraps to the
terminal with color, topics, and replaceable sections, a man page per command and HTML
docs, `cli.testing`, cancellation on Ctrl-C with `cleanup` hooks, prompts for missing
flags, plugins, `cli.version`, `cli.Messages`, and `cli.repl` with the `shell` component.
So have the gaps found while building them: file and directory completion after
`--flag=` (the `:prefix` directive, in all four shells), and the Windows console code
(terminal width, hidden prompt answers, Ctrl-C), checked under a real pseudo console by
`zig build console`. Then: long help through `$PAGER` (`App.pager`). Nothing is left.

---

## 2. `cfg`

Everything planned here has shipped: in-place edits for TOML, dotenv, YAML, and ZON;
`edit.reformat`, which keeps comments, for TOML, ZON, and dotenv; date-times
(`cfg.DateTime`, written back bare in TOML); kept inline tables; JSON with comments; YAML
over several lines, indentation indicators, and opt-in aliases; INI; `meta` constraints
and `validate`; every error at once; JSON Schema validation; renames and migrations;
references; append merging; includes; `loadDir`; the `Source` interface; `reload`; secret
references; encrypted files; case-insensitive keys; streaming JSON; benchmarks; and
patching instead of rebuilding on `set`. Since then: in-place edits for JSON, JSONC, and
INI (every format now has an editor); `reformat` for YAML, keeping comments, block
scalars and sequence items included; `reload` following includes as they are now;
incremental `set` with references on, which re-expands only the values that refer to the
key set; and YAML from a reader, parsed a top-level entry at a time (`yaml.parseReader`,
used by `loadReader`). Then: decode problems that point at the file and line that set
the key, with the line shown (`cfg.locate`, for every format, checked by a property over
the fuzz corpus); `meta.deprecated`; and `Config.changed`, a `stat` per file for watch
loops. Nothing is left.

---

## 3. `snek`

Shipped: `cfg diff` (of files or layers), `cfg env`, key and profile completion, `cfg edit`,
`cfg schema infer|check`, `cfg merge`, `cfg init`, `-o systemd`, `cfg encrypt|decrypt`, and
`cli repl`. Since then: projects from `cli init` have a `Settings` struct and a
`zig build schema` step, so `snek cfg init --schema zig-out/schema.json` writes a starter
file from the struct; and `cfg edit`'s edit-again loop is tested in a pseudo-terminal.
Nothing is left.

---

## 4. `tui` and `platform`

Shipped in `tui`: redrawing only the lines that changed (checked against whole redraws
by a property test), `Cmd.handoff` for editors and pagers, Ctrl-Z and `fg` (both run in
a real pseudo-terminal by the e2e tests), terminal queries (colors, modes, the kitty
keyboard), `tui.Keymap`, underline shapes and colors, and the `viewport`, `tree`, and
`filepicker` components (with `snek tui file`). Also: mouse in the components, the kitty
keyboard protocol, the macOS pty e2e cases,
`tui init --dependency`, retiring removed component files, release archives and
pre-releases in `platform.update`, WebAuthn signature and sign-count checks, CTAP2 over
CTAPHID with a Linux hidraw transport and ClientPIN (both PIN/UV auth protocols), and
`proctitle.scrub` on Windows (through the process environment block, checked against
`Get-CimInstance Win32_Process`), and signed self-update for snek (its release key is
compiled into `snek platform update`, which requires signatures). Since then: `tui.run` and
`tui.runSession`, the model borrowed by pointer, Ctrl-Z as an ordinary key (undo), the
cursor shown again when a live display is killed, and a browser terminal that caps
sessions, drops silent tabs, and moves its token into a cookie. Left:

| Item | Size | Notes |
|---|---|---|
| **CTAP2 on macOS and Windows** | M | `ctap.Device` has a Linux hidraw implementation only. macOS needs IOKit's HID manager; on Windows an unelevated process cannot open a FIDO device, so the way there is `webauthn.dll`, a different API from CTAP. Everything else left for Windows is in [docs/windows.md](docs/windows.md). |
| **Dogfooding leftovers** | S | From building `examples/repos`: `Keymap` modes were judged unnecessary (two keymaps chosen in `view` do it); `testing.Driver` frees a model only when its `deinit` is `pub fn (*M) void`, which is documented, not checked at compile time; `cfg` places its configuration directory by hand to match `platform.dirs`, since it imports only std, so the two must be kept in step; `help`, `paginator`, `stopwatch`, `timer`, and `shell` have no `snek tui demo`, so the site shows no GIF for them. |
| **CTAP2 on a real key** | S | The protocol layers, ClientPIN included, are tested against a simulated authenticator (and AES-CBC against NIST's vectors); no hardware key has been through `Hidraw` yet. |

---

## 5. Engineering maturity

Shipped: kcov coverage (`zig build coverage`, 93.75% of unit-test lines at last count),
coverage-guided fuzzing of the `cfg` parsers, in-place edits, reformatting, and decoding
(`zig build fuzz --fuzz`, with the corpus and regressions replayed by every test run; it
has found a dotenv bug and two in YAML reformatting, and the decode property found strict
decoding rejecting renamed keys), the release
pipeline (`.github/workflows/release.yml` with `snek platform release` for signatures and
manifests), the API stability policy ([docs/stability.md](docs/stability.md)) and
[CHANGELOG.md](CHANGELOG.md), `examples/` (run by `zig build test`), generated reference
docs (`zig build docs`, and the site, `zig build site`, published by
`.github/workflows/site.yml`), and the Zig upgrade
guide ([docs/upgrading-zig.md](docs/upgrading-zig.md)). Left:

| Item | Size | Notes |
|---|---|---|
| **CI on its first run** | S | `ci.yml` (tests on Linux, macOS, and Windows, the Windows console checks, cross-compiling, coverage, fuzzing), `release.yml`, and `site.yml` have not run on GitHub yet. Every step except publishing was run locally: the six release builds, the archives (bar the Windows `.zip`, as this machine has no `zip`), signing, the manifests, the docs, kcov, and the fuzzer. |
| **The release key in CI** | S | The key exists and `snek platform update` requires its signatures; its secret half must be stored as the `SNEK_SIGNING_KEY` repository secret, or `release.yml` fails at its Sign step. |

---

## 6. Parity and the rest of the field

The old implementation (`backup/`) and the leading libraries in other languages (cobra,
clap, click, typer, oclif, picocli, viper, koanf, figment, pydantic-settings, hydra,
cosmiconfig, bubbletea, ratatui, Textual, Ink, huh) were compared feature by feature
against these libraries. Shipped from that list:

- **Flows** (`cli.Flow`): multi-step commands as graphs whose path follows the answers,
  usable from scripts (flags answer questions) and at a terminal (plain or component
  prompts), with dry runs, undo, and JSON progress; `snek cli add --flow` scaffolds one.
- **`cli`:** translation with locale detection and plurals; confirmation (`--yes`),
  `--dry-run`, `--output` with `ctx.render`; feature gates; one-way `requires` and string
  lengths; user aliases; flag defaults from a configuration file; middleware.
- **`cfg`:** section views; custom `${name:arg}` resolvers; upward file discovery;
  remote files with an ETag cache (`platform.remote`); `snek cfg get --as`,
  `profile list|use`, and `fmt --sort`. Feature flags are a convention, not a feature:
  `App.feature_enabled` reading a `features` table.
- **`tui`:** background work (`Cmd.work`); lines above an inline program; constraint
  layout (`layout.split`); focus rings and grids; desktop notifications and taskbar
  progress; SVG screenshots; the `multiprogress`, `chart`, and `markdown` components;
  `snek tui demo`; plain prompts for screen readers (`ACCESSIBLE=1`).

Then Charm's open-source libraries and tools, which the README maps one by one: the `term`
module (lipgloss, ultraviolet, x/ansi, x/vt, colorprofile, glamour, sequin, mosaic and the
image protocols), the cell renderer, motion, and SSH serving in `tui` (Bubble Tea,
harmonica, wish), the huh-style `form` and more components (Bubbles), golden files
(x/exp/golden, teatest), and in `snek`: `cli record` (vhs, with GIF), `cli freeze`,
`cli explain`, `tui md` (glow), `tui image`, `tui serve`, and `platform ssh` (keygen,
melt). Left from that list:

| Item | Size | Notes |
|---|---|---|
| **More of SSH** | S | The server does sessions and opt-in port forwarding (`ssh -L`, `ssh -R`); the client checks `known_hosts`, logs in with Ed25519 keys or passwords, runs commands and terminals, and forwards `ssh -L`. The client also signs with the ssh-agent's Ed25519 keys (Unix sockets; Windows' named pipe is in [docs/windows.md](docs/windows.md)). Agent forwarding, SFTP, keyboard-interactive logins, certificates, and the client's side of `ssh -R` are not done. |
| **WebP, and rarer JPEGs** | M | `term.image` reads PNG, GIF, and JPEG (baseline and progressive); WebP, and arithmetic-coded, lossless, and 12-bit JPEGs, are not read. |
| **CFF fonts** | M | `TrueType` draws TrueType outlines; OpenType fonts with CFF outlines (`.otf`) are refused, so the recorder and freeze need a `.ttf` face. |

A second pass over `backup/` brought over what was still worth having: secrets never
shown by `cli` and scrubbed from logs by value, positional help, flag defaults from `cfg`,
CI as non-interactive, prompts for positionals, a shell on bare commands, `-o yaml`,
`cfg redact`, effective-configuration validation, comment-keeping sort and removal,
`meta.env` in `cfg`, capture timeouts, SIGHUP, `binDir`, `editText`, systemd units,
stale lock files, `term.diff`, and a component picker for `tui add`.

Left out, as not worth what they cost here: the backup's virtual file system, DAG
scheduler, B-tree store, and mmap helpers (general-purpose, not CLI concerns); OpenAPI
export (the JSON command tree serves tools); hydra's multirun sweeps; a command palette;
nushell and elvish completion; the backup's policy engine, OTA flag registry, and
stubs (FIDO2, headless, WASM bridge); Charm's products (crush, mods, soft-serve, pop), which are
applications rather than libraries.

## Not planned

These would make every user pay for what a few want:

- Network access inside `cfg` itself: remote sources plug in through the source interface
  (2.3), as separate modules.
- AI command routing (natural language to commands). The JSON command-tree export in
  `cli.docs` is the hook such a tool would use, from outside these libraries.
- A WASM plugin runtime. `cli.App.executeLine` covers embedding a CLI in a WASM host; running
  third-party WASM inside a CLI is a separate project.

`tui` and `platform` (terminal UIs, daemons, self-update, telemetry, crash reports) were on
this list for 0.1 and shipped in 0.2.
