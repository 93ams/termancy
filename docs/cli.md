# `cli`

Command-line applications from typed declarations: command trees, flags decoded into structs,
help, typo suggestions, shell completion, generated docs. The role [cobra] plays in Go.

[cobra]: https://github.com/spf13/cobra

- [Commands](#commands)
- [Positionals](#positionals)
- [Handlers and `Context`](#handlers-and-context)
- [Flags](#flags)
- [Built-in commands and flags](#built-in-commands-and-flags)
- [Per-command options](#per-command-options)
- [`App` options](#app-options)
- [Flows](#flows)
- [Translation](#translation)
- [Testing an app](#testing-an-app)

## Commands

Commands are data: `cli.command(.{ ... })` runs at compile time and yields a plain
`cli.Command` that help, completion, and docs walk without running anything.

| spec field | |
|---|---|
| `name`, `summary`, `description`, `aliases`, `examples` | what help shows |
| `group` | the help heading the command is listed under |
| `hidden`, `deprecated` | not listed / a notice when used |
| `topic` | a help page, not a command |
| `flags`, `persistent_flags` | the command's flags; persistent ones are inherited by descendants |
| `args` | positionals ([below](#positionals)) |
| `exclusive`, `together`, `one_required` | flag groups |
| `subcommands` | child commands |
| `run` and the hooks | [handlers](#handlers-and-context) |

Mistakes such as a duplicate flag or a constraint naming an unknown flag are compile errors.

## Positionals

Either counted words or a typed struct:

- **Counted:** `.args = .{ .min, .max, .usage }`. `.interspersed = false` stops flag parsing at
  the first one; `.passthrough = true` hands everything after `--` to `ctx.passthrough`
  untouched.
- **Typed:** `.args = struct { key: []const u8, value: ?[]const u8 = null }` decodes like flags.
  The usage line, counts, completion of enums, and docs are derived from the struct.

## Handlers and `Context`

A handler is one of:

```zig
fn (*cli.Context) !void
fn (*cli.Context, Flags) !void
fn (*cli.Context, Flags, Args) !void // with typed positionals
```

Hooks run in this order, and `cleanup` runs after all of them however the command ended:

```text
persistent_pre_run (root first) → pre_run → run → post_run → persistent_post_run (leaf first)
```

`Context` carries:

| | |
|---|---|
| `io`, `gpa`, `arena`, `environ` | the run's I/O, allocators (the arena is per invocation), environment |
| `out`, `err` | standard output and error |
| `args`, `path` | the arguments and the command path |
| `ctx.data(*T)` | typed app data |
| `ctx.flags(T)` | any visible flags struct |
| `ctx.fail(fmt, args)` | fail with exit 1 |
| `ctx.usageError(fmt, args)` | fail with exit 2 and a pointer to the command's help |
| `ctx.exit(status)` | any other status |
| `ctx.warn` | a warning, silenced by `-q` |

## Flags

Flags are struct fields; `pub const meta` refines them:

```zig
const ServeFlags = struct {
    port: u16 = 8080,
    pub const meta = .{ .port = .{ .short = 'p', .help = "Port to listen on" } };
};
```

| meta option | effect |
|---|---|
| `.short = 'p'` | `-p` spelling |
| `.help`, `.value_name` | help text and placeholder |
| `.name` | long name (default: field name in kebab case) |
| `.env = "PORT"` | read the variable when the flag is absent |
| `.count = true` | integer field counts occurrences (`-vvv`) |
| `.split = ','` | list field also splits each value |
| `.hidden`, `.deprecated = "use --x"` | not shown / notice when used |
| `.aliases = &.{"colour"}` | other names, for renames that keep scripts working |
| `.min`, `.max`, `.one_of` | bounds on numbers, a fixed set for strings (checked, completed, shown in help) |
| `.min_len`, `.max_len` | bounds on a value's length |
| `.requires = &.{"cert"}` | other flags this one needs |
| `.complete = fn` | values for shell completion, beyond an enum's choices, or `.files("toml")` / `.directories` |
| `.prompt = "Port"`, `.secret` | ask for a missing required flag when the run is interactive |
| `.key = "fetch.concurrency"` | the configuration key `App.defaults` reads and `bindFlags` sets |
| `.feature = "APP_BETA"` | hidden until the feature is on |
| `.internal = true` | state, such as a flow's, that is not a flag |

**Types:** `bool`, integers (`0x`, `0o`, `0b` accepted), floats, `[]const u8`, enums, `?T`,
`[]const T` (repeatable), and any type with `pub fn parse([]const u8) !T`. A field without a
default and without `?` is required.

**Spellings:** `--port 80`, `--port=80`, `-p80`, `-vvp 80`, `--no-force`, `--`.

Unknown commands, flags, and enum values get "Did you mean" suggestions. A flags struct may
declare `pub fn validate(flags: T, ctx: *cli.Context) !void` for checks across fields.

## Built-in commands and flags

- **Help:** `-h/--help` everywhere, `help [command...]`, and `help --search <words>` (the
  commands that mention them). Help wraps to the terminal's width, bolds headings on a color
  terminal, and lists help topics and plugins; `App.help_sections` replaces its header, usage,
  or footer.
- **Quiet:** `-q/--quiet` everywhere.
- **Version:** `-V/--version` when the app has a version. `cli.version.string(.{ .version,
  .commit, .date })` formats it from `build.zig` options.
- **Completion:** `completion <bash|zsh|fish|powershell>` (`cli.complete.command`, mountable
  anywhere; set `App.completion_command = false` to move it), and `completion install [shell]`
  writes the script where the shell loads it by itself. Scripts call back into the binary, so
  they never drift from the tree. A completer, `fn (*cli.Context, prefix: []const u8)
  ![]const cli.Candidate` in `.complete`, offers values computed at run time; it receives the
  flags and arguments typed so far, so `termancy cfg -c prod.toml get <TAB>` completes the keys
  of `prod.toml`.
- **Docs:** `cli.docs.write` renders Markdown, a man page, HTML, or JSON (the whole tree, shaped
  for tool schemas). `cli.docs.writeManTree` writes one man page per command, with an
  ENVIRONMENT section for the variables its flags read and an EXIT STATUS section
  (`App.exit_statuses` adds the app's own codes, a command's `.exit_statuses` its own).
  `cli.docs.command` mounts it as `docs`.
- **Exit statuses:** 0 success, 1 failure, 2 usage error, 141 when stdout closes early
  (`app | head`). `App.exit_status` can map errors to others.

## Per-command options

Spec fields, each adding only what it names:

| spec field | adds |
|---|---|
| `.confirm = "Delete it?"` | asks first, and `-y`/`--yes`; without a terminal it refuses rather than hangs. `.confirm = true` adds only `-y`/`--yes`, and the handler asks with `ctx.confirm(fmt, args)` |
| `.dry_run = true` | `--dry-run` and `ctx.dry_run` |
| `.output = true` | `-o`/`--output text\|json\|yaml\|jsonl` and `ctx.render(value)`: a table for a list of structs (columns picked and named by the struct's `pub const text_columns`), JSON, YAML, or one JSON object per line. Under `-o json` errors are JSON too, `{"error": ..., "hint": ...}` on standard error |
| `.logging = true` | `-v` (more each time) and `--log-level`, on the command and every one under it, for `ctx.log(.debug, ...)` |
| `.feature = "APP_BETA"` | hides the command until the feature is on |

Under `App.run` each line a handler writes to `ctx.err` shows at once, without a flush.

## `App` options

All off by default.

| field | |
|---|---|
| `response_files` | `@args.txt` expands to its words |
| `prefix_matching` | `app conf` runs `config` |
| `plugins = "app-"` | `app deploy` runs `app-deploy` from `PATH`, as git does |
| `cancel_on_interrupt` | Ctrl-C cancels the command's `std.Io` work, runs `cleanup`, exits 130 |
| `messages` | every sentence the library prints, replaceable to translate |
| `translations` | [translation](#translation) |
| `prompter` | how missing flags are asked for |
| `pager` | help taller than the terminal goes through `$PAGER`, else `less -FRX`, as git does |
| `color_flag` | `--color auto\|always\|never` over the environment's choice |
| `defaults = .from(&config, .{})` | flag defaults from a `cfg.Config` (or anything with `flagText(key)`), after the command line and the environment; `examples/tasks` reads them with `cfg` |
| `aliases` | the user's own commands, as git's `alias.*`: `.{ "co", "checkout -b" }` |
| `middleware` | code around every command: timing, logging, errors |
| `feature_enabled` | where `.feature` is decided: by default an environment variable; point it at `cfg` for feature flags in a file |

Under CI nothing prompts, even at a terminal.

Two more ways to run a tree:

- `App.executeLine` runs a command line given as one string, with shell-style quoting, for
  REPLs and WASM hosts.
- `cli.repl.run(app, env, .{})` runs the tree as an interactive shell; the `shell` component
  (`termancy tui add shell`) gives it history and tab completion.

## Flows

`cli.Flow`: commands that are graphs, as installers, deploys, and setup wizards are.

```zig
const deploy: cli.Flow(Deploy, Step) = .{ .start = .where, .steps = .{
    .where = .{ .ask = .{ .field = "env", .label = "Deploy where?" }, .next = .build },
    .build = .{ .title = "Build", .run = build, .next = .ask_migrate },
    .ask_migrate = .{
        .ask = .{ .field = "migrate", .label = "Run the migrations?" },
        .decide = .{ .to = &.{ .migrate, .release }, .by = afterAsk },
    },
    .migrate = .{ .title = "Migrate", .run = migrate, .undo = rollback, .next = .release },
    .release = .{ .title = "Release", .run = release, .when = isProduction },
} };
```

- **Steps** are an enum. Each asks for one field of a state struct (a `bool` is yes/no, an enum
  a choice, text typed in), or for several as one form (`.form`, a page of a wizard), and/or
  runs an action with an optional undo.
- **Paths** follow the answers: a step goes to a fixed `.next` or lets `.decide` choose from the
  state.
- **Scripts run the same flow:** a question whose flag was given is not asked.
- `--dry-run` asks and reports the actions instead of running them.
- A failed action undoes the ones before it, latest first.
- `-o json` reports each step as an object.
- The graph is checked when compiled, and `cli.flow.writeMermaid` draws it.
- Questions are asked in plain lines, or with the `prompts` component (`App.asker`) for menus,
  inputs, and forms. `cli.flow.Script` answers them in tests.
- `runFrom` starts at a given step, to resume a flow whose state was saved.

`termancy cli add <name> --flow` writes one.

## Translation

`cli.i18n` is gettext-style: the English text is the key, so nothing needs an identifier and
anything untranslated stays English. A `Translation` holds:

- the library's sentences (`cli.i18n.messages.german`, `spanish`, `french`, `portuguese`);
- command help (summaries, descriptions, groups, flag help, examples);
- the app's own strings: `ctx.tr("Hello, {0}", .{name})`, and `ctx.plural(n, one, other,
  args)` with CLDR plural rules.

The locale comes from `App.locale` or `LC_ALL`/`LC_MESSAGES`/`LANG`, `pt_BR` falling back to
`pt`.

## Testing an app

```zig
const result = try cli.testing.run(app, args, .{ .env = &.{.{ "PORT", "9" }} });
try result.expect(status, out, err);
```

`cli.testing.run` runs the app in memory and returns the exit status and everything written
to stdout and stderr; `expect` compares all three. `.stdin` makes the run interactive, for
testing prompts.
