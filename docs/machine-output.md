# termancy machine-output contract

**Contract version: 1.** This document lists everything `termancy` prints that scripts may
parse, and the rules for changing it. Every shape below is pinned by tests: the
end-to-end tests run `termancy` and compare its output (`test/e2e*.zig`), and the libraries'
unit tests compare the generators' output byte for byte. An accidental change fails the
build.

## Stability rules

Within a contract version:

- **Keys are never removed or renamed**, and a key's type never changes. A value that can
  be absent is `null`, never a missing key.
- **New keys may be added** to objects. Parse objects by key, not by position.
- **Key order is stable** as documented, so line-oriented tools such as `jq -c` and `diff`
  give stable results. It is still not part of the contract.
- **Enumerated values may gain members** (a new CI provider, a new layer). Handle unknown
  values.
- **Text output is for people**, except where marked *script-stable* below.

A change that breaks any of these bumps the contract version. The bump is recorded here
and in the release notes.

JSON is UTF-8, indented with two spaces, and ends with one newline.

## Exit statuses

| status | meaning |
|---|---|
| 0 | success |
| 1 | the command failed (message on stderr). `cfg validate`, `cfg fmt --check`, `cfg diff`, and `ui confirm` also use 1 for "no" |
| 2 | usage error: unknown command or flag, invalid value, missing argument, a flag a non-interactive run must pass (message and `Run '... --help'` on stderr) |
| 124 | `ui`: `--timeout` passed (`timed out` on stderr), as gum and timeout(1) |
| 126, 127 | `ui spin`: the command could not be run (126) or was not found (127), as in sh(1) |
| 130 | interrupted (Ctrl-C) |
| 141 | standard output was closed early (`termancy ... \| head`); nothing more is printed |

## Global behavior

- `-q`/`--quiet` (any command, any position) suppresses warnings. Errors are always
  printed.
- Nothing ever prompts when standard input is not a terminal (or under CI): a missing
  value exits 2 and names the flag to pass instead; a confirmation (`update`)
  exits 1 and names `--yes`.
- Progress (`update`, and `tui add` with several components) goes to stderr: a
  line per finished step when stderr is not a terminal (`✓ <step>`, `✗ <step>` for the
  one that failed), nothing with `-q`. It is for people, not part of this contract.
- `dirs`, `info`, and `tui list` take `-o text|json|yaml|jsonl`: the
  objects below as JSON, the same as YAML, or on one line (`jsonl`). Under `-o json` and
  `-o jsonl` their errors are one JSON object on stderr, `{"error": string, "hint":
  string}`, with `hint` only for usage errors. That holds for usage errors found while
  parsing too, before `-o` is reached (`dirs --bogus -o json`): any `-o json`,
  `-o jsonl`, or `--output=json` among the arguments (the last wins, none after `--`)
  makes them JSON, still with exit status 2.
- `NO_COLOR` (any value) disables color everywhere. Color is also off when the output is
  not a terminal.

## `termancy cfg`

| command | output |
|---|---|
| `cfg get <key> -o json` | the value as JSON: a string, number, boolean, null, array, or object |
| `cfg get <key> --raw` | *script-stable*: a scalar printed bare (no quotes) with a newline; arrays and tables keep the `-o` format |
| `cfg get <key> --default <v>` | `<v>` typed like `--set` values (`8080` is a number) when the key is unset; exit 0 |
| `cfg keys` | *script-stable*: one key per line, sorted; with `-0`/`--null`, NUL-terminated |
| `cfg keys -o json` | `["key", ...]`, sorted |
| `cfg show -o json` | the effective configuration as one JSON object; secrets are `"<redacted>"` unless `--reveal` |
| `cfg explain -o json` | `[{"key": string, "value": any, "layer": string, "source": string}, ...]`, sorted by key. `layer` is one of `default`, `file`, `profile`, `env`, `flag`, `override`. `source` is the file path, variable name, or flag, and `""` when the layer has none |
| `cfg validate` | *script-stable*: `<file>: ok` per valid file on stdout; errors as `termancy: <file>:<line>:<column>: <message>` on stderr, and with `--schema` each place a file does not conform as `termancy: <file>: <key>: <message>` |
| `cfg fmt --check` | *script-stable*: one unformatted file per line (or NUL-terminated with `-0`); exit 1 if any |
| `cfg diff <old> <new>` | *script-stable*: `- key = value` for a key only in `<old>`, `+ key = value` for one only in `<new>`, both lines for a changed value; sorted by key. Exit 0 when the same, 1 when different, as diff(1) |
| `cfg diff -o json` | `[{"key": string, "change": "added" \| "removed" \| "changed", "old": any, "new": any}, ...]`, sorted by key. `old` is `null` for an added key, `new` for a removed one |
| `cfg show -o systemd` | *script-stable*: `[Service]`, then `Environment="NAME=value"` per key, named as `-o env` names them (`SERVER__PORT`); `"`, `\` and `%` escaped as unit files require |
| `cfg diff --layer A --layer B` | as `cfg diff`, comparing two layers of the loaded configuration |
| `cfg schema infer` | a JSON Schema (draft-07) document |
| `cfg env` | *script-stable*: one assignment per key, sorted by key: `export NAME='value'` (`--shell sh`), `set -gx NAME 'value'` (`fish`), or `$env:NAME = 'value'` (`powershell`). Names as `--env-prefix` reads them; arrays of scalars joined with `,`; nulls left out. Values are quoted so that evaluating the output runs nothing |

Keys use dotted paths. A segment that holds a `.` or `"` is double-quoted, as in
`hosts."a.example".port`.

## `termancy dirs` and `termancy info`

`dirs -o json`:

```json
{
  "app": "termancy",
  "os": "linux",
  "config": "/home/u/.config/termancy",
  "cache": "/home/u/.cache/termancy",
  "data": "/home/u/.local/share/termancy",
  "state": "/home/u/.local/state/termancy",
  "runtime": "/run/u/termancy"
}
```

`runtime` is `null` when the system defines none. `os` is Zig's OS tag name.

`dirs --search -o json`: `{"app": string, "os": string, "search": [string, ...]}`.
In text mode it prints one directory per line (*script-stable*), NUL-terminated with `-0`.

`info -o json`:

```json
{
  "os": "linux",
  "arch": "x86_64",
  "zig": "0.17.0",
  "termancy": "0.1.0",
  "ci": null,
  "stdin_tty": false,
  "stdout_tty": false,
  "elevated": false,
  "hostname": "build-01"
}
```

`ci` is a provider name (`github_actions`, `gitlab_ci`, ...) or `null`. `hostname` is
`null` when it can't be read.

## `termancy tui`

`tui list -o json`:

```json
{
  "version": 1,
  "manifest": true,
  "components": [
    {
      "name": "select",
      "summary": "...",
      "requires": ["list"],
      "files": ["select.zig"],
      "installed": true,
      "modified": false,
      "outdated": false
    }
  ]
}
```

`manifest` says whether the project has a `tui.zon`. When it doesn't, `installed`,
`modified`, and `outdated` are all `false`. Components are sorted by name.

## `termancy ui`

The interactive widgets (`ui choose`, `filter`, `input`, `write`, ...) print exactly the
user's answer on stdout, one item per line (or per `--output-delimiter`), and nothing else.
Their interface goes to the terminal, never to stdout. Cancelling (Esc) exits 1 with no
output; Ctrl-C exits 130; `--timeout` exits 124 with `timed out` on stderr. `ui confirm`
answers with its status: Esc is no, and a timeout takes the highlighted answer; with
`--show-output` it prints the question and the answer (`Deploy? No`), Esc included, as gum.
`ui pager` has nothing to cancel: q and Esc both exit 0, as gum's.

`ui spin -- <cmd>` exits with the command's own status. Where stdout is not a terminal, the
command's stdout goes straight to it and its stderr to stderr once the spinner is gone; where
stdout is a terminal, the output is printed only as `--show-output`, `--show-stdout`,
`--show-stderr`, and `--show-error` ask, as gum does.

`tui diff` follows diff(1): exit 0 when identical, 1 when different, unified diff on stdout.

`style`, `format`, and `table --print` are non-interactive. They write escapes only when
stdout is a terminal that can show color, so piped or `NO_COLOR` output is plain text.

## `termancy cli docs --format json`

The command tree. One object per command, recursively under `subcommands`:

```json
{
  "name": "get",
  "path": "termancy cfg get",
  "summary": "...",
  "description": "...",
  "examples": "...",
  "aliases": [],
  "deprecated": null,
  "runnable": true,
  "topic": false,
  "args": {"min": 1, "max": 1, "usage": "<key>", "positionals": []},
  "flags": [
    {
      "name": "default",
      "short": null,
      "help": "...",
      "kind": "value",
      "type": "string",
      "label": "value",
      "choices": [],
      "default": null,
      "env": null,
      "required": false,
      "repeatable": false,
      "persistent": false,
      "inherited": false,
      "deprecated": null,
      "aliases": [],
      "minimum": null,
      "maximum": null
    }
  ],
  "constraints": {"exclusive": [], "together": [], "one_required": []},
  "subcommands": []
}
```

- `kind` is `bool`, `count`, or `value`. `type` is a JSON Schema type (`boolean`,
  `integer`, `number`, `string`).
- `aliases` are other names the flag accepts; `minimum` and `maximum` are inclusive bounds
  on a numeric value, `null` when unbounded.
- `args.max` is `null` when unlimited. `args.positionals` describes typed positionals, in
  order: `{"name": string, "type": string, "choices": [string], "required": bool,
  "repeatable": bool}`; it is empty for commands that take untyped words.
- `topic` is true for a help topic: a page of text (`description`) rather than a command.
- Inherited persistent flags are listed on every command they apply to, with
  `"inherited": true`.
- Hidden commands and flags are omitted.

## Shell completion protocol

`termancy __complete2 <words...> <current>` prints one candidate per line, as
`candidate<TAB>description` (the description may be empty), then any directives:
`:file <ext>` (complete files ending in `.<ext>`; one line per extension), `:files` (any
file), `:dirs` (directories). It prints nothing when the shell should fall back to file
names. This is what the generated scripts (`termancy cli completion <shell>`) call.

`termancy __complete` is the same without directives: the protocol the scripts of earlier
versions call. Both are versioned with this contract, because scripts installed from an
older termancy keep calling a newer one.
