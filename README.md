# snek

Five Zig libraries and a program built from them:

| | |
|---|---|
| **`term`** | The terminal underneath: color profiles, Unicode 17 widths and grapheme clusters, styles and layout, tables, lists and trees, a VT500 parser and a full terminal emulator, pseudo-terminals, syntax highlighting, Markdown, fonts, PNG and GIF, images in the terminal. The roles of Charm's lipgloss, ultraviolet, x/ansi, x/vt, colorprofile, glamour, and sequin. |
| **`cli`** | Command-line applications from typed declarations: command trees, flags decoded into structs, help, typo suggestions, shell completion, generated docs. The role [cobra] plays in Go. |
| **`cfg`** | Layered configuration: TOML, YAML, JSON, ZON, dotenv; defaults, files, profiles, environment, flags, overrides; decoding into structs; provenance. The role [viper] plays in Go. |
| **`tui`** | Terminal user interfaces: an Elm-architecture runner that redraws only the cells that changed, springs for animation, input decoding, a headless test driver with golden files, and programs served over SSH. Ready-made components are source you copy and own, as with [shadcn/ui]. The roles of Bubble Tea, Bubbles, huh, harmonica, and teatest. |
| **`platform`** | The operating system as a CLI needs it: standard directories, processes, signals, atomic and lock files, daemons, secure memory, logging, crash reports, tracing, opt-in telemetry, self-update, package manifests, SSH keys and an SSH server (wish), secrets as words (melt). |
| **`snek`** | A program built only from the libraries' public surfaces: configuration tooling, project and command generators, gum-style shell widgets, a Markdown reader (glow), terminal recordings as GIFs (vhs), images of code (freeze), and system information. |

Zig **0.17.0**, standard library only. `cli` and `tui` build on `term`; otherwise no library imports
another. What comes next is in [ROADMAP.md](ROADMAP.md), what changed in
[CHANGELOG.md](CHANGELOG.md), and what stays stable in [docs/stability.md](docs/stability.md); what
`snek` prints for scripts is specified in [docs/machine-output.md](docs/machine-output.md). New
here? Start with [Your first app in 10 minutes](docs/guide.md). To help, see
[CONTRIBUTING.md](CONTRIBUTING.md); to report a vulnerability, [SECURITY.md](SECURITY.md).

[cobra]: https://github.com/spf13/cobra
[viper]: https://github.com/spf13/viper
[shadcn/ui]: https://ui.shadcn.com

## Install

**snek**, the program: each [release](https://github.com/93ams/snek/releases) has an archive
per system (`snek-<os>-<cpu>.tar.gz`, `.zip` on Windows; `linux`, `macos`, `windows` on
`x86_64` and `aarch64`), each with an Ed25519 signature beside it and all in `SHA256SUMS`.

```sh
curl -fsSL https://github.com/93ams/snek/releases/latest/download/snek-linux-x86_64.tar.gz \
  | tar -xz -C ~/.local/bin snek
scoop install https://github.com/93ams/snek/releases/latest/download/snek.json  # Windows
snek platform update                                # later: checks the signature, then swaps
```

The release also carries Homebrew (`snek.rb`) and winget (`snek.yaml`; `winget install
--manifest snek.yaml`) manifests. To build it instead: `zig build -Doptimize=ReleaseSafe`
with Zig 0.17.0.

On Windows, `snek.exe` is not code-signed yet, so the first run of a downloaded copy may
stop at a SmartScreen warning ("Windows protected your PC"): check it against
`SHA256SUMS`, then choose **More info**, **Run anyway**.

**The libraries**, in a Zig project:

```sh
zig fetch --save git+https://github.com/93ams/snek#v0.1.0
```

then import the modules you use in `build.zig` (below), or let `snek cli init` set a project
up.

## A complete example

```zig
const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");

const Settings = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    timeout: cfg.Duration = .{ .ns = 30 * std.time.ns_per_s },
};

const ServeFlags = struct {
    config: ?[]const u8 = null,
    port: ?u16 = null,
    pub const meta = .{
        .config = .{ .short = 'c', .help = "Config file" },
        .port = .{ .short = 'p', .help = "Port to listen on" },
    };
};

fn serve(ctx: *cli.Context, flags: ServeFlags) !void {
    var config: cfg.Config = .init(ctx.gpa);
    defer config.deinit();
    try config.setDefaults(Settings{});
    if (flags.config) |file| try config.loadFile(ctx.io, .cwd(), file, null, null);
    config.useEnv(ctx.environ);
    try config.automaticEnv("APP"); // APP_PORT=9000
    try config.bindFlags(try ctx.changedFlags(), .{}); // --port 9001
    const settings = try config.decode(Settings, .{}, null);
    try ctx.out.print("listening on {s}:{d}\n", .{ settings.host, settings.port });
}

const root = cli.command(.{
    .name = "app",
    .summary = "An example",
    .subcommands = .{
        cli.command(.{ .name = "serve", .summary = "Serve", .flags = ServeFlags, .run = serve }),
    },
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root, .version = "0.1.0" };
    return app.run(init);
}
```

The fastest start is to let `snek` write the project:

```sh
snek cli init demo --module-path /path/to/snek   # or --fetch <url> to add it with zig fetch
cd demo
snek cli add serve --flag 'port:u16=8080,short=p' --summary "Start serving"
snek cli add config get --flag 'key:string,required'
zig build run -- serve -p 9000
```

`init` writes `build.zig`, `build.zig.zon`, `src/main.zig` (the entry point and the command tree),
an example `hello` command in `src/cmd/hello.zig`, and `src/settings.zig`, whose `Settings` struct
is what the configuration file holds: `zig build schema` writes its JSON Schema, from which `snek
cfg init demo.toml --schema zig-out/schema.json` writes a starter file. `add` writes one file per
command with a typed flags struct, a handler, and a test, and wires it into its parent. A path like
`config get` creates the `config` group (`src/cmd/config/main.zig`) when it is missing. The
generated project builds and its tests pass with no edits.

To add the libraries by hand, depend on this package and import the modules you use:

```zig
const snek = b.dependency("snek", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("cli", snek.module("cli"));
exe.root_module.addImport("cfg", snek.module("cfg"));
exe.root_module.addImport("tui", snek.module("tui"));
exe.root_module.addImport("platform", snek.module("platform"));
```

## `cli`

**Commands** are data: `cli.command(.{ ... })` runs at compile time and yields a plain
`cli.Command` that help, completion, and docs walk without running anything. Spec fields:
`name`, `summary`, `description`, `aliases`, `examples`, `group` (help heading), `hidden`,
`deprecated`, `topic` (a help page, not a command), `flags`, `persistent_flags` (inherited
by descendants), `args`, `exclusive` / `together` / `one_required` (flag groups),
`subcommands`, and the handlers below. Mistakes such as a duplicate flag or a constraint
naming an unknown flag are compile errors.

**Positionals** are either counted words, `.args = .{ .min, .max, .usage }` (with
`.interspersed = false` to stop flag parsing at the first one, and `.passthrough = true`
to hand everything after `--` to `ctx.passthrough` untouched), or typed:
`.args = struct { key: []const u8, value: ?[]const u8 = null }` decodes like flags, with
the usage line, counts, completion of enums, and docs derived from the struct.

**Handlers** are `fn (*cli.Context) !void`, `fn (*cli.Context, Flags) !void`, or with typed
positionals `fn (*cli.Context, Flags, Args) !void`. Hooks run as `persistent_pre_run` (root first) →
`pre_run` → `run` → `post_run` → `persistent_post_run` (leaf first), and `cleanup` runs after all of
them however the command ended. `Context` carries `io`, `gpa`, a per-invocation `arena`, `environ`,
`out`, `err`, `args`, the command `path`, typed app data (`ctx.data(*T)`), `ctx.flags(T)` for any
visible flags struct, `ctx.fail(fmt, args)` (exit 1), `ctx.usageError(fmt, args)` (exit 2, with a
pointer to the command's help), `ctx.exit(status)` for any other status, and `ctx.warn` (silenced by
`-q`).

**Flags** are struct fields; `pub const meta` refines them:

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
| `.complete = fn` | values for shell completion, beyond an enum's choices, or `.files("toml")` / `.directories` |
| `.prompt = "Port"`, `.secret` | ask for a missing required flag when the run is interactive |

Types: `bool`, integers (`0x`, `0o`, `0b` accepted), floats, `[]const u8`, enums, `?T`,
`[]const T` (repeatable), and any type with `pub fn parse([]const u8) !T`. A field without
a default and without `?` is required. Spellings: `--port 80`, `--port=80`, `-p80`,
`-vvp 80`, `--no-force`, `--`. Unknown commands, flags, and enum values get "Did you mean"
suggestions. A flags struct may declare `pub fn validate(flags: T, ctx: *cli.Context) !void`
for checks across fields.

**Built-ins**: `-h/--help` and `-q/--quiet` everywhere, `help [command...]` (and `help --search
<words>`, the commands that mention them), `-V/--version` when the app has a version, and
`completion <bash|zsh|fish|powershell>` (`cli.complete.command`, mountable anywhere; set
`App.completion_command = false` to move it), with `completion install [shell]` writing the script
where the shell loads it by itself. Completion scripts call back into the binary, so they never
drift from the tree. A completer, `fn (*cli.Context, prefix: []const u8) ![]const cli.Candidate` in
`.complete`, offers values computed at run time; it receives the flags and arguments typed so far,
so `snek cfg -c prod.toml get <TAB>` completes the keys of `prod.toml`. Help wraps to the terminal's
width, bolds headings on a color terminal, and lists help topics and plugins; `App.help_sections`
replaces its header, usage, or footer. `cli.docs.write` renders Markdown, a man page, HTML, or JSON
(the whole tree, shaped for tool schemas); `cli.docs.writeManTree` writes one man page per command,
with an ENVIRONMENT section for the variables its flags read and an EXIT STATUS section
(`App.exit_statuses` adds the app's own codes, and a command's `.exit_statuses` its own);
`cli.docs.command` mounts it as `docs`. `App.executeLine` runs a command line given as one string,
with shell-style quoting, for REPLs and WASM hosts. Exit statuses: 0 success, 1 failure, 2 usage
error, 141 when stdout closes early (`app | head`); `App.exit_status` can map errors to others.

**Opt-in runtime features** (`App` fields, all off by default): `response_files` (`@args.txt`
expands to its words), `prefix_matching` (`app conf` runs `config`), `plugins = "app-"` (`app
deploy` runs `app-deploy` from `PATH`, as git does), `cancel_on_interrupt` (Ctrl-C cancels the
command's `std.Io` work, runs `cleanup`, exits 130), `messages` (every sentence the library prints,
replaceable to translate), `prompter` (how missing flags are asked for), and `pager` (help taller
than the terminal goes through `$PAGER`, else `less -FRX`, as git does), `color_flag` (`--color
auto|always|never` over the environment's choice), and `defaults = .from(&config, .{})` (flag
defaults from a `cfg.Config` or anything with `flagText(key)`). Under CI nothing prompts, even at a
terminal. `cli.version.string(.{ .version, .commit, .date })` formats `--version` from `build.zig`
options. `cli.repl.run(app, env, .{})` runs the tree as an interactive shell; the `shell` component
(`snek tui add shell`) gives it history and tab completion.

**Per command** (spec fields, each adding only what it names): `.confirm = "Delete it?"` asks first
(`.confirm = true` adds only `-y`/`--yes`, and the handler asks with `ctx.confirm(fmt, args)`, for a
question made at run time) and adds `-y`/`--yes` (without a terminal it refuses rather than hangs),
`.dry_run = true` adds `--dry-run` and `ctx.dry_run`, `.output = true` adds `-o`/`--output
text|json|yaml|jsonl` and `ctx.render(value)` (a table for a list of structs, its columns picked and
named by the struct's `pub const text_columns`, JSON, YAML, or one JSON object per line for
programs; under `-o json` errors are JSON too, `{"error": ..., "hint": ...}` on standard error),
`.logging = true` adds `-v` (more each time) and `--log-level` to the command and every one under
it, for `ctx.log(.debug, ...)`, and `.feature = "APP_BETA"` hides a command until the feature is on
(also per flag). Flag `meta` adds `.requires = &.{"cert"}`, `.min_len`/`.max_len`, `.key =
"fetch.concurrency"` (the configuration key `App.defaults` reads and `bindFlags` sets), and
`.internal = true` (state, such as a flow's, that is not a flag). Under `App.run` each line a
handler writes to `ctx.err` shows at once, without a flush.

**More `App` fields**: `translations` (below), `aliases` (the user's own commands, as
git's `alias.*`: `.{ "co", "checkout -b" }`), `defaults` (flag values from a
configuration file after the command line and the environment; `examples/tasks` reads
them with `cfg`), `middleware` (code around every command: timing, logging, errors), and
`feature_enabled` (where `.feature` is decided: by default an environment variable;
point it at `cfg` for feature flags in a file).

**Flows** (`cli.Flow`): commands that are graphs, as installers, deploys, and setup wizards are.
Steps are an enum; each asks for one field of a state struct (a `bool` is yes/no, an enum a choice,
text typed in), or for several as one form (`.form`, a page of a wizard), and/or runs an action with
an optional undo, and goes to a fixed `.next` step or lets `.decide` choose from the state, so the
path follows the answers. A question whose flag was given is not asked, so scripts run the same
flow; `--dry-run` asks and reports the actions instead of running them; a failed action undoes the
ones before it, latest first; `-o json` reports each step as an object. The graph is checked when
compiled, and `cli.flow.writeMermaid` draws it. Questions are asked in plain lines, or with the
`prompts` component (`App.asker`) for menus, inputs, and forms; `cli.flow.Script` answers them in
tests; `runFrom` starts at a given step, to resume a flow whose state was saved.
`snek cli add <name> --flow` writes one.

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

**Translation** (`cli.i18n`): gettext-style, the English text is the key, so nothing needs
an identifier and anything untranslated stays English. A `Translation` holds the library's
sentences (`cli.i18n.messages.german`, `spanish`, `french`, `portuguese`), command help
(summaries, descriptions, groups, flag help, examples), and the app's own strings
(`ctx.tr("Hello, {0}", .{name})`, `ctx.plural(n, one, other, args)` with CLDR plural
rules). The locale comes from `App.locale` or `LC_ALL`/`LC_MESSAGES`/`LANG`, `pt_BR`
falling back to `pt`.

**Testing an app**: `cli.testing.run(app, args, .{ .env = &.{.{ "PORT", "9" }} })` runs it
in memory and returns the exit status and everything written to stdout and stderr;
`result.expect(status, out, err)` compares all three. `.stdin` makes the run interactive,
for testing prompts.

## `cfg`

**Value model**: one dynamic tree (`cfg.Value`: null, bool, int, float, string, array,
ordered table) addressed by dotted paths (`servers.0.host`, `a."dotted.key"`).

**Formats** (read and write, errors with line and column):

| | |
|---|---|
| JSON | full; also streamed from a reader (`json.parseReader`, `Config.loadReader`) |
| JSON with comments | `.jsonc`, `.json5`: `//` and `/* */` comments, trailing commas; written as JSON |
| TOML | 1.0; date-times keep their text, decode into `cfg.DateTime`, and are written back bare |
| YAML | the configuration subset: block and flow collections, quoted, plain, and block scalars over several lines, indentation indicators, comments; anchors and aliases with `parseWith(.{ .aliases = true })`, under a node budget; tags and multiple documents are rejected rather than misread; read from a reader a top-level entry at a time (`yaml.parseReader`, `Config.loadReader`) |
| ZON | everything `@import` of a `.zon` file accepts, parsed by the compiler's own front end; writes zig-fmt output |
| dotenv | `export`, quotes, escapes, `$VAR` / `${VAR}` / `${VAR:-default}`; `A__B` nests as `a.b` |
| INI | `.ini`, `.cfg`, `.conf`: `[section.sub]` headers, `key = value` or `key: value`, `;` and `#` comments; values are text |

Defaults can be compile-time checked: `const defaults: Settings = @import("defaults.zon");`
then `try config.setDefaults(defaults);`. A field the struct doesn't have, or a value of the
wrong type, is a compile error.

**Sources**: `loadFile`, `loadVariants` (a file, then each of its variants that exists over
it: `app.production.toml` and `app.local.toml`, or `.env.local`), `loadDir` (a `conf.d`
directory in name order), `loadSource`,
`loadReader`, and `loadFrom` with a `cfg.Config.Source` (a small vtable, so remote stores
live in their own modules). `reload` reads them again and returns what changed. Opt in to
`useIncludes("include")` (files include others, relative to themselves), `useReferences`
(`${other.key}` in values, with cycles reported), `usePassphrase` (encrypted `.enc` files,
from `cfg.encrypted`), and `ignoreKeyCase`. `${secret:env:NAME}` and `${secret:file:path}`
resolve at load and are marked secret; `addSecretProvider` adds more schemes.
`setMerge(key, .append)` (or `meta.merge = .append`) makes lists accumulate across sources.

**Layers**, highest first: override (`set`) → flag (`bindFlags`, which skips flags that are
not settings) → env (`automaticEnv`,
`bindEnv`) → profile (`useProfile`: the `profiles.<name>` table) → file (`loadFile`, merged
in order) → default (`setDefault`, `setDefaults`). Tables merge deeply; anything else
replaces. `explain(key)` names the layer and the file, variable, or flag behind a value.
`findFile` searches directories (with `$VAR` and `~`) for
`<name>.{toml,yaml,yml,json,zon,env}`; `loadAppFile(io, "app", .{ .path, .env }, &diag)` loads
the `--config` path, the file a variable names, or `config.toml` in the user's configuration
directory, and a missing file is not an error. `glob`, `edit.applyAll`, and
`Duration.toIo` round it out.

**Reading**: `get`, typed getters (`getInt`, `getDuration`, `getStringList`, ...), `keys`, and
`decode(T)` into a struct with coercion from text, range checks, required fields, and unknown keys
rejected (`.strict`) or reported as warnings at their file and line with a "did you mean"
(`.warn_unknown`). Struct `meta` adds `.secret`, `.help`, `.key`, `.min`/`.max`/`.one_of`/`.pattern`
constraints, `.renamed_from` (the old key still reads, with a warning), `.deprecated = "why"` (read,
with a warning when set; `deprecated` in the schema too), and `.merge`; a struct's `validate` checks
rules across fields; with `Options.errors`, every problem is reported at once. Problems point at the
file and line that set the key, `app.toml:4:8: server.port: must be at most 65535`, and
`Diagnostic.writeSnippet` shows that line with a caret under the value (`cfg.locate` finds any key
in any format's text). `changed(io)` says whether a loaded file (or one it includes) changed on
disk, with one `stat` each, for a watch loop that calls `reload`. `cfg.migrate.run` upgrades
documents through a list of versioned migrations. `view("db")` hands a component its own section
(`getString("host")` reads `db.host`, and `decode` decodes just that part). `addResolver("name",
...)` makes `${name:arg}` in a file call your function (`${env:HOME}`, `${git:branch}`), as
`addSecretProvider` does for secrets. `findFile(.{ .upward = true })` searches the working directory
and its parents, as git and cosmiconfig do. `platform.remote.get` fetches a file over HTTP with an
ETag cache that serves the last copy offline; `loadSource` it, as `snek cfg -c https://...` does.
`Duration` (`1h30m`) and `ByteSize` (`10MiB`) work as config fields and as flag types.

**Writing**: `write(writer, format, .{ .layer, .redact })` with secrets redacted by default.
`cfg.edit.apply(arena, format, source, change)` sets or removes one key by changing only the
bytes it must, so comments and layout survive (every format; YAML in block style), and
`cfg.edit.reformat` formats a file canonically while keeping its comments (TOML, ZON,
dotenv, YAML); it checks that the result
reads back as intended, and returns null rather than a wrong document. `cfg.diff(arena, old,
new)` lists the leaves that differ.
`cfg.schema.write(T, arena, writer)` emits JSON Schema (draft-07), and
`cfg.schema.validate` checks an untyped tree against one. To keep secrets out of
swap and core dumps, give the `Config` `platform.secure`'s allocator: memory is page-locked
and zeroed on free.

## `term`

What every terminal program needs, below any framework; `cli` uses it for colored help and
`tui` for everything it draws. Nothing in it runs an event loop.

| | |
|---|---|
| detection | `capability.detect`: the color profile (none, 16, 256, true color) from `NO_COLOR`, `CLICOLOR_FORCE`, `FORCE_COLOR`, `COLORTERM`, `TERM`, and the terminal's own variables (kitty, Ghostty, WezTerm, iTerm2, VS Code, Windows Terminal, ...); `ansi.Downsampler` lowers any styled output to it as it is written |
| text | `width`: display width, wrapping, truncation and cutting that keep styles and links open across lines, and grapheme clusters by UAX #29 with Unicode 17 tables, checked against the Unicode test suite |
| styling | `Style` (lipgloss): colors, attributes, padding, margins, borders (with titles, per-side colors, and gradients), alignment, sizes; `layout` joins and places blocks; `Canvas` stacks layers; `Table`, `List`, and `Tree`; `Color` blends in Oklab, makes gradients, and picks light or dark variants |
| sequences | `ansi` writes them; `Parser` reads any (VT500); `Pen` tracks SGR state; `explain` says what each does (sequin) |
| emulation | `vt.Screen`: a terminal emulator with scrollback, modes, queries, OSC titles, links, and clipboard, written out as text, ANSI, or SVG; `Pty` runs a program on a pseudo-terminal (ConPTY on Windows); `Buffer` and `Renderer` draw frames by cell |
| content | `highlight` (30 languages, themes), `markdown` (CommonMark and GFM, style sheets, as glamour), `Regex` |
| pixels | `TrueType` and `fonts` (the machine's fonts, with fallbacks), `raster` (a screen in a window with a bar, rounded corners, and a shadow), `image` (PNG read and written, JPEG read (baseline and progressive, any subsampling, CMYK, EXIF orientation), GIF animated and read, resizing, quantizing), `graphics` (images in the terminal: kitty, iTerm2, sixel, or half blocks; support found from the environment or by asking the terminal) |
| tests | `golden.expect`: output against files kept with the tests, escapes shown as text, rewritten with `SNEK_UPDATE_GOLDEN=1` |
| diff | `diff`: line diffs written as unified diffs, colored like git when asked |
| progress | `live`: spinners (frame sets, styles, final symbols, elapsed time), progress bars (eighth-cell fill, gradients, counts, bytes/s, ETA), live text, and step checklists, without `tui.Program`: redrawn in place at a terminal, a line per change in logs and CI |

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

## `tui`

A program is a model with `update` and `view`; `tui.Program` runs it on the terminal, and
`tui.testing.Driver` runs it in memory with a virtual clock and screen:

```zig
pub const Confirm = struct {
    question: []const u8,
    answer: bool = false,

    pub fn update(model: *Confirm, msg: tui.Msg) tui.Cmd {
        const key = switch (msg) {
            .key => |key| key,
            else => return .none,
        };
        if (key.matches("y")) model.answer = true;
        if (key.matches("enter") or key.matches("y") or key.matches("n")) return .quit;
        return .none;
    }

    pub fn view(model: *const Confirm, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const accent: tui.Style = .{ .fg = .hex(0xff8700), .bold = true };
        try accent.paint(w, "? ");
        try w.print("{s} [y/N]\n", .{model.question});
    }
};

var confirm: Confirm = .{ .question = "Deploy?" };
const status = try tui.run(gpa, io, &confirm, .{});
```

`tui.run` returns the exit status (130 when interrupted) and, without a terminal, prints the
first frame as text. `Program` borrows the model through a pointer, so components may hold
slices of it; `testing.Driver` owns its own. `tui.runSession` runs a model over an SSH or
browser session at the session's size.

Inline (redrawn in place) or full screen; the UI draws on the controlling terminal even when stdio
is redirected, so a program works inside `$(...)`. Only the lines that changed are rewritten. Colors
are written at full fidelity and lowered to what the terminal supports (`NO_COLOR`, `FORCE_COLOR`,
`TERM`, `COLORTERM`). Ctrl-C ends the program as interrupted (exit 130), Ctrl-Z is an ordinary key
(undo in text fields; a program that wants job control sets `suspend_on_ctrl_z` or returns
`Cmd.suspend_process`, and `fg` resumes it), and the terminal is always restored. `Cmd.handoff(id)`
lends the terminal to the model's `handoff`, to run an editor or a pager, and takes it back.
`Cmd.work(id, arg)` runs the model's `work` function in the background and delivers its result as a
message; a model's `above` prints lines that stay above an inline program (logs, finished steps).
`layout.split` divides rows or columns by lengths, percentages, and fills; `tui.focus` keeps tab
order (`Ring`) or moves in two dimensions (`Grid`); `ansi.notify` and `ansi.setProgress` reach the
desktop and the taskbar. `testing.Screen.writeSvg` draws what a test's terminal shows as an SVG
image. `Options.queries` asks the terminal for its colors (dark or light, `Rgb.isDark`), whether it
knows a mode, and the kitty keyboard protocol; replies arrive as `.report` messages. `tui.Keymap`
declares key bindings once, for matching keys and for the help line. `Style` has curly, dotted,
dashed, and double underlines, and underline colors. `tui.motion` has springs and projectiles
(harmonica) for animation. Frames are drawn by cell: only the cells that changed are written, at
most `Options.max_fps` times a second. A model can place the terminal's cursor, set the window
title, filter messages, and copy to the clipboard. `Program.runSession` runs a program over a remote
terminal: an SSH session from `platform.ssh.Server`, so one binary serves a TUI to everyone who
connects, as wish does, or a browser's socket from `platform.web.Server`, which has the same session
surface. `testing.Driver` compares screens and output with golden files and moves the clock until
something shows (`advanceUntil`), as teatest does.

Components are not part of the module. `snek tui add select` copies `select.zig` (and `list.zig`,
which it needs) into your project. From then on the file is yours to change, and `snek tui diff` and
`snek tui add` (which refuses to overwrite your edits) keep you in touch with upstream. Available:
`confirm`, `input` (with suggestions), `textarea` (with line numbers), `list`, `select`,
`multiselect`, `filter`, `spinner`, `progress` (gradients and spring animation), `multiprogress`,
`table`, `pager`, `paginator`, `stopwatch`, `timer`, `help`, `form` (huh: inputs, texts, selects
with filtering, multi-selects, confirms, files, notes, pages, conditions, and themes), `tabs`,
`viewport` (a scrolling area to embed, both ways), `tree`, `filepicker`, `chart` (sparklines and
bars), `markdown` (a scrolling reader), `prompts`
(questions for a `cli.Flow`, asked with the components), and `shell` (a line editor with history and
tab completion, for `cli.repl`). `snek tui demo <component>` runs one on sample data, and `--svg`
draws it. The list components take mouse clicks and the wheel. `Program.Options.kitty_keyboard` asks
the terminal for the kitty keyboard protocol, for unambiguous modifiers.

## `platform`

Grouped by concern, every file also reachable by a flat name (`platform.dirs`):

| | |
|---|---|
| system | `dirs` (XDG, macOS, Windows known folders), `exe`, `env` (CI detection, `DO_NOT_TRACK`, elevation), `process` (capture, stream, `which`, `$EDITOR`, open a URL), `signal` (Ctrl-C as a flag, exit 130), `files` (atomic writes, lock files, a 0600 state store), `daemon`, `proctitle` (hide secret arguments from `ps`, Task Manager included), `dynlib` (hot reload) |
| security | `secure` (page-locked, dump-excluded, zero-on-free `Allocator`; constant-time `eql`; `Secret`), `sandbox` (path policy against traversal and symlink escapes), `oauth` (PKCE, device flow), `webauthn` (request and assertion types, every relying-party check, ES256 and EdDSA signatures from COSE keys, sign counts), `ctap` (CTAP2 over CTAPHID to a security key, with its PIN; the Linux hidraw transport), `cbor` |
| observability | `log` (text, logfmt, or JSON lines; styled levels, fields, prefixes, callers; redaction by key and of known secret values; a `std.log` adapter), `crash` (panic banner, JSON report without argv or environment), `profiler`, `trace` (W3C `traceparent`), `telemetry` (off unless the user consents; honors `DO_NOT_TRACK` and CI) |
| ssh | `keys` (public keys, fingerprints, `authorized_keys`; Ed25519, ECDSA, and RSA signatures checked; Ed25519 keys made and kept in OpenSSH's format, under a passphrase or not; `ssh-keygen -Y` signatures made and checked), `Server` (logins by key or password, terminals, resizes, signals, exit statuses, opt-in `ssh -L` and `ssh -R` forwarding; ML-KEM hybrid post-quantum key exchange, ChaCha20-Poly1305 and AES-GCM, strict key exchange), `Client` (host keys checked against `known_hosts`, Ed25519 keys from files or the ssh-agent, or passwords, commands and terminals, `ssh -L`), `Agent` (ssh-agent at `$SSH_AUTH_SOCK`), `known_hosts`, `mnemonic` (BIP 39 words for a secret, as melt) |
| web | `web.Server`: a terminal over a browser's WebSocket, with the SSH session's surface, a token, an origin check, and an xterm.js page with a `title`; `handlerFor` makes a typed handler, `link` the address to print; `web.Client` for tests |
| distribution | `version` (semver), `update` (release lookup with or without pre-releases, SHA-256 and Ed25519 verification, bare, `.tar.gz`, or `.zip` assets, atomic swap with rollback), `manifests` (Homebrew, Scoop, PKGBUILD, Debian control) |

Nothing starts a thread or touches the network unless the function called says so.

## `snek`

```sh
snek cfg get server.port                       # from ./snek.toml (or .yaml, .json, .zon, .env)
snek cfg -c base.toml -c local.yaml show -o json
snek cfg --env-prefix APP explain              # where every value comes from
snek cfg --profile prod get server.host
snek cfg set server.port 9090 -c app.toml
snek cfg convert app.toml --to yaml
snek cfg diff base.toml prod.yaml              # exit 1 when they differ, as diff(1)
eval "$(snek cfg env --prefix APP)"            # export APP_SERVER_PORT=... and the rest
snek cfg validate *.toml
snek cfg keys -0 | xargs -0 -n1 echo           # NUL-separated for odd keys
snek cli docs --format man > snek.1
source <(snek cli completion bash)
color=$(snek tui choose red green blue)          # the menu draws on the terminal
snek tui confirm "Deploy?" && make deploy
git log --oneline | snek tui filter
snek tui spin --title "Building" -- zig build
snek tui md README.md                          # read Markdown in a reader (glow)
snek cli record demo.tape                      # a terminal session as a GIF (vhs)
snek cli freeze main.zig --window -o main.png  # an image of code (freeze)
snek tui serve -- snek tui demo                # a TUI for everyone who connects with ssh (wish)
snek platform dirs                             # where config, cache, and state live
```

| command | |
|---|---|
| `cfg get <key>` (`--default`, `--raw`, `--as int\|duration\|...`), `keys [prefix]`, `show`, `explain [prefix]` | query the effective configuration |
| `cfg profile list`, `profile use <name>` (`--clear`) | the `profiles.*` sections, and the one used by default |
| `cfg env` (`--prefix`, `--shell sh\|fish\|powershell`) | the configuration as variable exports, quoted to be safe to evaluate |
| `cfg set <key> <value>`, `unset <key>` | edit a file in place, atomically, keeping comments |
| `cfg edit [file]` | open it in `$EDITOR`; saved only when it parses, as visudo does |
| `cfg convert <file\|->`, `validate <file>...` (`--schema`, which without files checks the effective configuration; warns about plain-text secrets and deprecated keys), `fmt <file>...` (`--sort`, keeping comments), `diff <old> <new>`, `redact <file\|->` (secret-looking values replaced, layout kept, for bug reports) | work on files directly |
| `cfg encrypt <file>`, `decrypt <file.enc>` | keep secrets in a repository; `-c x.enc` reads them with `$SNEK_PASSPHRASE` |
| `cfg merge <file>...`, `init [file]` (`--schema`), `schema infer <file>`, `schema check <schema> <file>...` | combine, start, and describe files |
| `cli init <name>`, `cli add <path...>` (`--flow`) | generate a project, and commands (or flows) in it |
| `cli docs` (`--format markdown\|man\|html\|json`, `--dir`, `--stylesheet`), `cli completion <shell>` | documentation and shell completion |
| `cli repl` | snek's commands as an interactive shell, or a script on stdin |
| `cli record <tape>` (`-o`), `record new`, `validate`, `capture`, `themes` | terminal sessions from scripts, as [vhs](https://github.com/charmbracelet/vhs) tapes: GIF, PNG, frames, text for golden tests, animated SVG, MP4 and WebM (with ffmpeg); `capture` writes a tape from what you type |
| `cli freeze [file]` (`-x command`, `--window`, `--shadow`, `-n`, `--lines`) | images of code or of a command's output, PNG or SVG, as [freeze](https://github.com/charmbracelet/freeze) |
| `cli explain [file...] [-- command]` | what each escape sequence in some output does, as [sequin](https://github.com/charmbracelet/sequin) |
| `tui choose`, `confirm`, `input`, `write`, `filter`, `spin`, `table`, `pager`, `file`, `style`, `format`, `join`, `log` | shell-script widgets, in the spirit of [gum](https://github.com/charmbracelet/gum); `ACCESSIBLE=1` asks with plain lines |
| `tui md [source]` | Markdown from a file, a URL, or a repository's README, in a reader, as [glow](https://github.com/charmbracelet/glow) |
| `tui image <file>` | a PNG, JPEG, or GIF in the terminal (kitty, iTerm2, sixel, or half blocks) |
| `tui serve -- command` | a terminal program over SSH, as [wish](https://github.com/charmbracelet/wish), or with `--web` in the browser, as [ttyd](https://github.com/tsl0922/ttyd) (a token link swapped for a cookie, loopback by default, at most 32 sessions) |
| `tui init`, `add <component>...`, `list`, `diff <component>`, `demo [component]` | copy components into a project (any subdirectory of it; `init` wires the nearest `build.zig`), keep them current, and try them first |
| `platform dirs`, `info`, `update` | standard directories, system facts, self-update |
| `platform release keygen`, `sign`, `verify`, `manifest` | publish releases `platform.update` installs: Ed25519 signatures and package manifests |
| `platform ssh keygen`, `fingerprint`, `melt`, `restore`, `sign`, `verify`, `run` | SSH keys as `ssh-keygen` makes them, backed up as 24 words ([melt](https://github.com/charmbracelet/melt)), and files signed as `ssh-keygen -Y` signs them |
| `version`, `help [command...]`, `help --search <words>` | |

Unix conventions throughout:
- **Streams:** results go to stdout, diagnostics to stderr.
- **Quiet:** `-q` silences warnings, never errors.
- **NUL output:** `-0` gives NUL-separated output where items could contain newlines.
- **No prompts:** nothing prompts when stdin isn't a terminal. Such paths exit 2 and name the flag
  to pass instead.
- **Color:** `NO_COLOR` is honored everywhere.
- **Closed pipe:** a closed stdout exits 141 without an error message.

`cfg` flags: `-c/--config` (repeatable, `SNEK_CONFIG`), `--profile` (`SNEK_PROFILE`),
`--env-prefix`, `--set key=value`, `-o/--output text|json|yaml|toml|zon|env|ini|systemd`. Without
`--config`, the first `snek.*` in `.`, `$XDG_CONFIG_HOME/snek`, or `~/.config/snek` is
loaded. `set` and `unset` keep a file's comments and layout, changing only the edited
lines, and `fmt` keeps the comments of TOML, ZON, dotenv, and YAML; what cannot be done in
place (an array element in JSON, say) is rewritten whole, losing its comments, with a
warning. Keys and `--profile` names complete in the shell.

## Coming from Charm

Charm's open-source terminal libraries and tools, and where each one's work is done here:

| Charm | here |
|---|---|
| lipgloss | `term.Style`, `term.layout`, `term.Canvas`, `term.Table`, `term.List`, `term.Tree`, `term.Color` |
| ultraviolet, x/ansi, x/vt, x/term | `term.Buffer`, `term.Renderer`, `term.ansi`, `term.Parser`, `term.vt`, `term.Terminal` |
| colorprofile | `term.capability`, `term.ansi.Downsampler` |
| x/xpty, x/conpty | `term.Pty` |
| x/mosaic, sixel, kitty graphics | `term.graphics`, `snek tui image` |
| x/editor | `platform.process.editAt` |
| x/exp/golden, x/exp/teatest | `term.golden`, `tui.testing.Driver` |
| bubbletea | `tui.Program` |
| bubbles | the component registry (`snek tui add`) |
| huh | the `form` and `prompts` components, `cli.Flow` |
| harmonica | `tui.motion` |
| glamour | `term.markdown`, `term.highlight` |
| glow | `snek tui md` |
| gum | `snek tui choose`, `input`, `write`, `filter`, `confirm`, `file`, `pager`, `spin`, `table`, `style`, `format`, `join`, `log` |
| fang | `cli` with `cli.Theme` |
| log | `platform.log` |
| sequin | `term.explain`, `snek cli explain` |
| vhs | `snek cli record` (GIF without a browser or ffmpeg) |
| freeze | `snek cli freeze` |
| wish, ssh | `platform.ssh.Server` and `Client`, `tui.Program.runSession`, `snek tui serve` |
| ttyd, gotty (not Charm) | `platform.web.Server`, `snek tui serve --web` |
| keygen | `platform.ssh.keys`, `snek platform ssh keygen` |
| melt | `platform.mnemonic`, `snek platform ssh melt` and `restore` |

Charm's products (crush, mods, soft-serve, pop, and its cloud) are applications, not
libraries, and have no counterpart here.

## Examples

Each directory in `examples/` is a small app with its own tests; `zig build examples` builds
them, runs their tests, and runs each once against its expected output. The doc comment at
the top of each `main.zig` lists what it shows and how to try it.

| example | shows |
|---|---|
| `git-style` | nested command groups, persistent flags, typed positionals, aliases, bounds |
| `httpc` | the flag grammar: lists, split values, `Duration`/`ByteSize` flags, env secrets, `requires`, `exclusive`, renamed, deprecated, and hidden flags, `validate`, prompts for missing flags, help topics, `help --search`, response files, prefixes, middleware |
| `deploy` | a `cli.Flow` graph: a form, a probe, decisions, undo on failure, `--dry-run`, `-o json` step reports, `-v` logging, a Mermaid chart; asked through the `prompts` component at a terminal |
| `tasks` | translations with plurals, `--yes`, `--dry-run`, `-o json`, flag defaults from a file, user aliases |
| `kv` | an interactive shell with history and tab completion (`cli.repl` and the `shell` component), completion from data, plugins, generated docs, the pager, a private store in the data directory |
| `server-config` | layered configuration decoded into a struct, with each value's origin |
| `conf-d` | a `conf.d` directory merged across formats |
| `settings` | `cfg` tooling: variants, profiles, encrypted secrets, every problem located with a caret, JSON Schema, comment-preserving edits, diffs, migrations |
| `monitor` | a full-screen `tui` program from components (tabs, table, chart, spinner, progress), keymaps, timers, the mouse, and headless tests |
| `lobby` | a guestbook served over SSH: `platform.ssh.Server`, `Program.runSession`, state shared between sessions, border titles and gradients, golden-file and scripted-session tests |
| `repos` | a real tool end to end: a config file under `REPOS_*` overrides, a first-run `cli.Flow` that keeps the file's comments, `list -o text\|json\|jsonl`, concurrent `git fetch` under `ctx.live`, a filterable TUI from components copied with `snek tui add` (its `ui/` and `tui.zon`), served with `--web` |
| `first-app` | the code of [the guide](docs/guide.md), checked word for word against it |
| `doctor` | `platform`: per-OS directories, CI detection, versions, path sandboxing, redacted logs, trace context, phase profiling |

The examples import the component registry as a module; a project copies the components
in with `snek tui add <name>` instead, as `repos` did for its `ui/`.

## Building and testing

| command | |
|---|---|
| `zig build` | builds `zig-out/bin/snek` |
| `zig build test` | everything below except `check` |
| `zig build unit` | unit tests of every library and of `snek`, leak-checked |
| `zig build e2e` | runs the `snek` binary and compares its output, including live bash, zsh, fish, and PowerShell completion, `tui` widgets driven through a pseudo-terminal, and generated projects built with `zig build` |
| `zig build compile-errors` | checks that misuse of `cli.command` and bad `.zon` defaults are compile errors with the promised message |
| `zig build examples` | builds, tests, and runs the apps in `examples/` (part of `test`) |
| `zig build check` | compiles everything for Linux, macOS, and Windows, and `cli`/`cfg` for WASI |
| `zig build coverage` | line coverage of the unit tests with kcov, into `zig-out/coverage` |
| `zig build fuzz --fuzz` | coverage-guided fuzzing of every parser of untrusted input: `cfg`'s formats, SSH keys, signatures, and transport, CBOR, escape sequences and the input decoder, Markdown, PNG, GIF, and JPEG, TrueType, highlighting, regexes, and tapes (`--fuzz=200K` stops) |
| `zig build budget` | the smallest `cli`, `cfg`, and `tui` apps (ReleaseSmall, stripped) against size budgets, and `--help`'s startup time |
| `zig build docs` | the libraries' API reference and snek's command reference, into `zig-out/docs` |
| `zig build site` | the documentation site, into `zig-out/site`: the guide, a page per library, the component gallery, the command and API reference (`zig build site-gifs` also records each component's GIF from `docs/tapes`) |
| `zig build console` | `cli`'s Windows console code under a pseudo console (on Windows, or WSL) |
| `zig build bench` | times `cfg` parsing, writing, merging, and decoding |
| `zig build fmt` | formats the sources |

Parsers are fuzzed with seeded generators: random trees must round-trip through every
`cfg` format, and random or mutated input must parse or fail with a positioned error, never
crash (`src/cfg/fuzz.zig`); in-place edits of random documents must decline or read back
exactly as intended. The same holds for `tui`'s input decoder, `cli`'s shell-style
tokenizer, and everything in `src/term/fuzz.zig` and `src/platform/fuzz.zig`. Each parser is
also a target for Zig's coverage-guided fuzzer; its seed corpus, and every input that once
broke a parser, run with the unit tests.

On WSL with the repository on a Windows drive (`/mnt/c/...`), Zig cannot rename files in
its local cache there (`AccessDenied`). Keep the cache on the Linux filesystem:
`zig build test --cache-dir ~/.cache/zig-snek` (or set `ZIG_LOCAL_CACHE_DIR`).

```text
src/cli/  src/cfg/  src/tui/  src/platform/   the libraries (each a module with root.zig)
src/main.zig                                  snek: main and the top-level command tree
src/cmd/<group>/main.zig                      one directory per snek command group
src/cmd/tui/registry/                         the tui components snek copies into projects
test/                                         end-to-end and compile-error cases, fixtures
examples/                                     small runnable apps, run by zig build test
docs/machine-output.md                        the output contract for scripts
docs/stability.md, docs/upgrading-zig.md      the versioning policy; notes per Zig release
```

## Design notes

- **No hidden work.** No threads, watchers, or global state, and no network access except
  through functions that say so. Every allocation uses an allocator the caller passed; every
  I/O call uses the caller's `std.Io`.
- **The libraries meet through conventions, not imports.** A type with
  `pub fn parse([]const u8) !T` (signature checked, not just the name) is both a flag type
  and a config field; `ctx.changedFlags()` returns records `config.bindFlags` accepts.
- **Trees are arena-owned.** Codecs copy every string into the arena, so a tree never points
  into its source. `Config` keeps layers in a long-lived arena and rebuilds the effective
  tree in a second arena reset on every change, so `get` results live until the next change
  and `decode` results until `deinit`.
- **Testable without a process.** `App.execute` takes arguments, environment, and writers
  (`cli.testing.run` wraps it for tests); library tests run under `std.testing.allocator`,
  so leaks fail the suite. CI (`.github/workflows/ci.yml`) runs `zig build test` on Linux,
  macOS, and Windows, with coverage and a bounded fuzzing run; `release.yml` publishes
  signed archives and manifests for a version tag, and `site.yml` the documentation site
  (`zig build site-gifs`) to GitHub Pages.

`backup/` holds the earlier implementation, kept for reference only; nothing builds it.
