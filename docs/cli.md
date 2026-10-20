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
| `flags`, `persistent_flags` | the command's flags ([below](#flags)); persistent ones are inherited by descendants |
| `args` | positionals ([below](#positionals)) |
| `settings` | a field of the flags read from configuration too ([below](#settings)) |
| `subcommands` | child commands |
| `run` and the hooks | [handlers](#handlers-and-context) |

Mistakes such as a duplicate flag, a flag group naming a field the struct lacks, or an option
on a field it does not fit are compile errors.

## Positionals

Either counted words or a typed struct:

- **Counted:** `.args = .{ .min, .max, .usage }`. `.interspersed = false` stops flag parsing at
  the first one; `.passthrough = true` hands everything after `--` to `ctx.passthrough`
  untouched.
- **Typed:** `.args = struct { key: []const u8, value: ?[]const u8 = null }` decodes like flags.
  The usage line, counts, completion of enums, and docs are derived from the struct;
  `cli.args(Args, Specs, .{ .fields = .{ .key = .{ .name = "k", .prompt = "Key" } } })` adds
  help and checks from specs, and per field a `.name`, a `.complete`, and a `.prompt`.

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
| `ctx.flags(T)` | any visible flags struct, from the command line, the environment, and `App.defaults` |
| `ctx.fail(fmt, args)` | fail with exit 1 |
| `ctx.usageError(fmt, args)` | fail with exit 2 and a pointer to the command's help |
| `ctx.configError(fmt, args)` | fail with exit 78: the configuration cannot be used |
| `ctx.exit(status)` | any other status |
| `ctx.warn` | a warning, silenced by `-q` |

## Flags

Flags are struct fields. What each field means comes from `field` specs, shared with `cfg`;
how it is spelled on the command line comes from `cli.flags`' options:

```zig
const ServeFlags = struct {
    port: u16 = 8080,
    tags: []const []const u8 = &.{},
    verbose: u8 = 0,
};

const Specs = field.Set(.{field.Spec(ServeFlags){ .fields = .{
    .port = .{ .help = "Port to listen on", .checks = &.{ .min(1), .from(notReserved) } },
    .tags = .{ .help = "Labels", .each = &.{.minLen(1)} },
} }});

const serve_flags = cli.flags(ServeFlags, Specs, .{ .fields = .{
    .port = .{ .short = 'p', .env = "PORT" },
    .tags = .{ .name = "tag", .split = ',' },
    .verbose = .{ .short = 'v', .count = true },
} });

const serve = cli.command(.{ .name = "serve", .flags = serve_flags, .run = run });
fn run(ctx: *cli.Context, flags: ServeFlags) !void { ... }
```

A plain struct works too (`.flags = ServeFlags`): every field a flag under its own name.

**What a field means** (`field.Spec`; see the `field` library):

| spec | effect |
|---|---|
| `.help` | help text, also in docs and in `cfg`'s schema |
| `.checks = &.{ .min(1), .max(64) }` | checks on the value: `.min`, `.max` (numbers, or types with `order`), `.minLen`, `.maxLen`, `.oneOf` (strings), `.glob`, and `.from(fn)` for your own |
| `.each` | checks on each element of a list |
| `.secret` | never echoed: redacted in help, docs, messages, and `ctx.secretValues` |
| `.deprecated = "use --x"` | accepted, with this notice when used |
| `Spec(T).checks` | checks across the struct's fields |

A check is a plain function, `fn (V, *std.Io.Writer) !void`, that writes why a value is
wrong and returns `error.Invalid` (`field.fail` does both). Specs are keyed by type: one
`field.Spec(Listener)` applies wherever a `Listener` is, nested or listed.

**How a field is spelled** (`cli.flags` options, per field):

| option | effect |
|---|---|
| `.short = 'p'` | `-p` spelling |
| `.name` | long name (default: field name in kebab case) |
| `.value_name` | placeholder in help |
| `.env = "PORT"` | read the variable when the flag is absent |
| `.count = true` | integer field counts occurrences (`-vvv`) |
| `.split = ','` | list field also splits each value |
| `.hidden` | accepted, not shown |
| `.aliases = &.{"colour"}` | other names, for renames that keep scripts working |
| `.requires = &.{.cert}` | sibling fields that must be given with this one |
| `.complete = .from(fn)` | values for shell completion, beyond an enum's choices, or `.files("toml")` / `.directories` |
| `.prompt = "Port"` | ask for a missing required flag when the run is interactive |
| `.feature = "APP_BETA"` | hidden until the feature is on |
| `.internal = true` | state, such as a flow's, that is not a flag |

Beside `.fields`, `.exclusive`, `.together`, and `.one_required` take groups of fields:
`.exclusive = &.{&.{ .json, .yaml }}`.

**Types:** `bool`, integers (`0x`, `0o`, `0b` accepted), floats, `[]const u8`, enums, `?T`,
`[]const T` (repeatable), and any type with `pub fn parse([]const u8) !T`. A field without a
default and without `?` is required. A struct field is a group of flags named after it
(`--public-port`; `.name` renames the prefix, `.name = ""` drops it). A tagged union is a
choice: `--storage s3` names the variant, and its fields are a group under it
(`--storage-s3-bucket`, which also picks `s3`; naming another variant too is an error).

**Spellings:** `--port 80`, `--port=80`, `-p80`, `-vvp 80`, `--no-force`, `--`.

**Checks:** a value given is checked as it is parsed, against its type and its field's
checks; a failure is a usage error naming the flag. Checks that need the whole value (across
fields, or a list's own) run once every flag is parsed, before the command's hooks, and every
failure is reported. Unknown commands, flags, and enum values get "Did you mean" suggestions.

### Settings

A command whose flags are settings read from configuration too names their field and a
loader:

```zig
const Flags = struct {
    config: ?[]const u8 = null,
    settings: Settings = .{}, // --port, --workers, ...: every setting is a flag
};

const serve = cli.command(.{
    .name = "serve",
    .flags = cli.flags(Flags, Specs, .{ .fields = .{ .settings = .{ .name = "" } } }),
    .settings = .{
        .field = .settings,
        .load = load, // fn (*cli.Context) !Settings, usually with cfg
        .sources = cfg.sourcesOf(settings, .{ .file = "app.toml", .env_prefix = "APP" }),
    },
    .run = run,
});
```

The loader layers the flags over the file and the environment (`ctx.changedFlags()` gives
each its field's path as its configuration key), and the handler gets what it returns. Its
flags are never required on the command line, and their checks are the loader's to run;
`.sources` lets help say where else each can be set. In the loader,
`config.nameFlags(try ctx.flagKeys(), .{})` lets a missing key's message name its flag,
`config.askWith(ctx.settingsAsker())` asks for it at a terminal with the flag's `.prompt`,
and `ctx.configError` reports a configuration that cannot be used with exit status 78.
[examples/server-config](../examples/server-config/main.zig) does all of it.

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
- **Exit statuses:** 0 success, 1 failure, 2 usage error, 78 configuration error
  (`ctx.configError`), 141 when stdout closes early (`app | head`). `App.exit_status` can map
  errors to others.

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
  args)` with CLDR plural rules;
- what a check of its own says, looked up by the text it wrote: `field.fail(w, "is
  reserved", .{})` by `"is reserved"`, and `field.fail(w, "{d} is in use", .{port})` by a
  template, `.{ "{0} is in use", "{0} ist belegt" }`, whose `{0}`, `{1}`, ... stand for the
  arguments as written. The built-in checks' messages are the library's sentences.

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
