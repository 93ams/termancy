# API stability

snek follows [Semantic Versioning](https://semver.org). The version is the one `snek
--version` reports; the libraries and the program are released together under it.

## What is covered

**`cli` and `cfg` are stable from 1.0.** Within a major version, a minor release only adds,
and a patch release only fixes. These are the stable declarations:

| `cli` | |
|---|---|
| Building a tree | `command`, `Command`, `Flag`, `Candidate`, `flagsOf`, `Defaults`, and the spec fields and `meta` options the README and `spec.zig` document (`.key` and `.internal` among them) |
| Running it | `App` (its fields and `run`, `execute`, `executeLine`, `exit_*` statuses), `Context` (its fields and methods, `FlagRecord`) |
| Output | `Context.render` and `text_columns`, `help`, `docs` (formats, `write`, `writeManTree`, `Options`), `complete` (scripts and the `__complete2` protocol), `json`, `Messages`, `Theme`, `version` |
| Interaction | `flow` and `Flow` (steps, `Ask`, `Asker`, `Question`, `Script`), `prompt`, `repl`, `plugins`, `interrupt`, `terminal`, `pager`, `i18n`, `defaults` |
| Tests | `testing.run`, `Run`, and `Options` |

| `cfg` | |
|---|---|
| The tree | `Value`, `Table`, `Array`, `value`, `path` |
| Formats | `Format`, `json`, `toml`, `yaml`, `dotenv`, `zon`, `ini`: `parse`, `write`, and their options |
| Layers | `Config` (its public methods and the option, result, and error types beside them, `loadAppFile` and `AppFileOptions` among them), `Diagnostic` |
| Typed access | `decode`, `encode`, `DecodeOptions`, `DecodeError`, `Duration`, `ByteSize`, `DateTime`, `infer`, `glob` |
| Tools | `diff`, `Change`, `edit` (`apply`, `applyAll`, `reformat`, `sort`), `schema`, `encrypted`, `migrate`, `locate` |

**Machine output is stable too:** what `snek` prints with `-o json` and the other formats
in [machine-output.md](machine-output.md), its exit statuses, and the completion protocol
(`__complete2`). A change to any of them is a breaking change.

## What is not covered

- **`tui` and `platform`** stay at 0.x after `cli` and `cfg` reach 1.0: they still change
  shape as the components and the operating-system support grow. Their breaking changes
  are listed in the CHANGELOG under **Breaking**.
- `cli.internal` (`spec`, `parse`, `values`, `text`, `shell`, `output`) and `cfg.internal`
  (`format`, `scalar`): the libraries' own parts, public so their files can share them.
  What they hold that is stable is re-exported above (`cli.command`, `cfg.Format`,
  `cfg.Duration`, ...); reach for it there.
- `Config`'s fields: they are its state, read and changed through its methods.
- Anything else whose doc comment says it is internal.
- Error sets may gain members in a minor release. Switch on them with an `else` arm.
- The Zig version: each release names the one it builds with (now 0.17.0), and a new Zig
  can need a new snek. See [upgrading-zig.md](upgrading-zig.md).
- Output meant for people (help text, error messages, `-o text`).
- Components copied by `snek tui add`, which are the project's own source once copied.

## Deprecation

A stable declaration is not removed in a minor release. It is first marked in its doc
comment ("Deprecated: use X") and listed in the CHANGELOG under **Deprecated**, and it is
removed at the next major version. Renamed flags and keys follow the same rule, and keep
working in the meantime through `meta.aliases` (flags) and `meta.renamed_from` (keys).
