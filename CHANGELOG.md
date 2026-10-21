# Changelog

Notable changes, newest first. The format follows [Keep a Changelog](https://keepachangelog.com),
and versions follow [Semantic Versioning](https://semver.org) as
[docs/stability.md](docs/stability.md) describes. Work before the first entry is in the
git history.

## Unreleased

### Breaking

- **`termancy ui log` takes its arguments as gum's `log` does:** they are one message,
  joined by spaces, and key value pairs need `-s`/`--structured`. `-f`/`--format` is gum's
  printf switch (the first argument formats the rest), so the output format moved to
  `--formatter text|json|logfmt`. `--format json` is not kept: as a switch, `--format`
  would take `json` for the message, so `--format=json` is refused rather than misread.
  The default level is `none` (no level written), and `--min-level` reads
  `TERMANCY_LOG_LEVEL` instead of `GUM_LOG_LEVEL`. `sys.log.Level` has a `none` variant
  (charm's `Print`), so an exhaustive `switch` over it needs a `.none` arm.
- **`cfg.Value` has a date-time kind:** `.datetime` holds the text of a TOML offset
  date-time, local date-time, local date, or local time, and `toml.parse` gives one where it
  gave a `.string`. An exhaustive `switch` over a `cfg.Value` needs a `.datetime` arm. TOML
  writes a `.datetime` bare and a `.string` always quoted; JSON and ZON write a date-time as
  a string, and YAML, INI, and dotenv as plain text, which they read back as a string. A
  `[]const u8` setting and `cfg.DateTime` decode it, `encode` makes one from a `DateTime`, a
  schema's `string` type accepts it, and `cfg.infer` (so `cfg set`, `--set`, and flags)
  infers one from text such as `2024-01-01`.
- **`pub const meta` is gone; what a field means and how it is spelled are separate:** what
  a field means (help, `secret`, `deprecated`, and checks) is a `field.Spec`, in the new
  `field` library that `cli` and `cfg` both import, keyed by type so one spec covers every
  place a type occurs. How it is spelled comes per place from `cli.flags(T, Specs, options)`
  and `cli.args(T, Specs, options)` (short, name, env, count, split, prompt, completion with
  `.complete = .from(fn)`, requires, internal) and from `cfg.settings(T, Specs, keys)` (key,
  renamed_from, env, merge). `.min`, `.max`, `.min_len`, `.max_len`, `.one_of`, and
  `.pattern` are checks: `.checks = &.{ .min(1), .max(64) }`, `.oneOf(...)`, `.glob(...)`,
  `.each` for a list's elements, and `.from(fn)` for any rule of your own. A flags struct's
  `validate(flags, ctx)` and a settings struct's `validate(self)` become `Spec(T).checks`.
- **Flag groups move into the flag set:** a command's `.exclusive`, `.together`, and
  `.one_required` are `cli.flags` options naming fields (`.exclusive = &.{&.{ .json, .yaml }}`),
  checked at compile time.
- **A flag's configuration key is its field's path:** the `.key` option is gone. A flag in a
  group (`fetch: struct { concurrency: u8 }`, `--concurrency` with the group's prefix
  dropped) or below a command's `.settings` carries its path to `Config.bindFlags`, which
  follows keys a settings type renamed; `bindFlags` now leaves out every record whose key
  the configuration does not know (`setFlag` still sets any).
- `Config.setDefaults` takes the settings type first, and is only for defaults other than
  the struct's: `Config.initFor(X, gpa)` makes a configuration that knows a settings type
  and its defaults from the start (`decode` registers its type by itself, and
  `Config.register(X)` does so on a configuration made with `init`). `setDefaults(X, value)` replaces what the struct's
  defaults set at those keys rather than merging with them.
- A layer naming another variant of a choice replaces the lower layer's, instead of both
  being set ("set only one of disk and s3").
- **Each tui component's file is its type:** `const Select = @import("ui/select.zig");`
  in place of `@import("ui/select.zig").Select`, and its other declarations are the type's
  (`Select.Status`, `Form.Field`). The `components` module exports them by type
  (`components.Input`, not `components.input.Input`), and `Spinner.frames`, the frame sets,
  is `Spinner.frame_sets`. Likewise `sys.Version` replaces `sys.version.Version`, and
  `sys.version.parse` is `sys.Version.parse`.
- A command's checks across its flags' fields run before its hooks (`Command.check`), and
  report every failure; a single value's checks run as it is parsed. Checks only run on
  values given: a default that fails its own checks is no longer an error.
- A nested struct in a settings type without a default decodes from its fields' defaults
  when its table is missing, instead of being a missing key.

- **snek is now termancy, and the `platform` library is `sys`:** the program, the package
  (`.termancy` in `build.zig.zon`, with a new fingerprint), the repository URL, release
  archives (`termancy-<os>-<cpu>`), configuration files and directories (`termancy.toml`,
  `~/.config/termancy`), environment variables (`TERMANCY_*`), and plugins (`termancy-<name>`).
  `@import("platform")` is `@import("sys")`. Files encrypted by `cfg.encrypted` start with
  `termancy-encrypted`, which the encryption authenticates, so files sealed as
  `snek-encrypted` must be decrypted with snek and sealed again. Entries below keep the old
  names.
- **snek's commands are grouped by what they act on, not by library:** `platform` is gone;
  its `dirs`, `info`, `update`, `release`, and `ssh` move to the top level, and `platform
  webauthn` becomes `passkey`. `cli freeze`, `cli record`, `cli explain`, `tui md`, `tui
  image`, and `tui serve` move to the top level too. The gum-style widgets and `demo` move
  from `tui` to `ui` (`snek ui choose`); `tui` keeps `init`, `add`, `list`, and `diff`.
- **snek uses the library's built-ins:** `platform update` without a terminal (or under CI)
  and without `--yes` exits 1 naming `--yes` (was 2), and a declined update says "not
  confirmed; nothing was done". `platform update`, `tui add` (several components), `cli
  record`, and `cli freeze` report progress as `✓ <step>` lines on stderr (redrawn in place
  at a terminal; nothing with `-q`). `cli record` loses its own `-q` for the built-in one;
  `tui serve` shows connections only with `-v`; `platform ssh run`'s "added <host>" line is
  a warning.
- `cli.spec`, `parse`, `values`, `text`, `shell`, and `output` move to `cli.internal`, and
  `cfg.scalar` and `format` to `cfg.internal`; what was stable in them stays at the root
  (`cli.command`, `cli.flagsOf`, `cli.Defaults`, `cfg.Format`, `cfg.Duration`, `cfg.ByteSize`,
  `cfg.DateTime`, `cfg.infer`). `cli.json.schemaType`, `cli.plugins.isName`, and
  `App.max_response_file` are no longer public.
- Flag meta `.config = "a.b"` is `.key`, and `cli.Flag.config` is `Flag.key`.
- `cli.docs.writeWith` and `writeManTreeWith` fold into `write(writer, root, format, options)`
  and `writeManTree(io, dir, root, options)`; pass `.{}` for the defaults.
- `cfg.Config.bindFlags` leaves out flags whose key the configuration does not know (once it
  knows its keys, from `setDefaults`, `decode`, or `registerKeys`), so `--config` and
  `--verbose` no longer become settings; a flag with `.key` always binds. `setDefaults`
  registers the struct's keys.
- `cfg.edit` writes a new nested key into TOML as a `[table]` section, not a dotted key.
- `Config.loadFile`, `loadDir`, and `loadVariants` set `Diagnostic.file` on syntax errors:
  print `"{f}"`, not `"{s}:{f}", .{ path, diag }`.
- `tui.Program(M).init` takes `*M`: the model stays the caller's, is updated in place, and is
  never copied or freed, so components may borrow slices of it; `program.model` is `*M`.
  `tui.testing.Driver(M).init(gpa, model, opts)` returns the driver
  (`var d: Driver(M) = try .init(...)`), which owns its model and frees it in `deinit`
  (`pub fn deinit(*M)`); drop any `d.model().deinit()`, now a double free.
- `platform.web.Server.Config.handler` is a `web.Server.Handler`; `serveConnection` and
  `tui`'s `resize_poll` are no longer public.
- `tui.Options.suspend_on_ctrl_z` defaults to `false`: Ctrl+Z reaches the model as a key, so
  `input` and `textarea` undo works out of the box. To suspend, set
  `.suspend_on_ctrl_z = true` or return `Cmd.suspend_process` from `update`. `snek tui input`,
  `write`, `filter`, and `pager` undo on Ctrl+Z; `choose`, `confirm`, `file`, and `table`
  still suspend.
- A fifth module, `term`, holds what used to be `tui`'s terminal layer (`ansi`,
  `capability`, `width`, `input`, `Terminal`, `Style`, `layout`); `tui` re-exports all of
  it, so `tui.Style` and the rest still work, but a build that wires modules by hand must
  give `cli` and `tui` the `term` import.
- `cli.Environment.color` is a color level (`term.capability.Color`) instead of a bool,
  and `Environment` has `err_color`; help is colored only when standard output is a
  terminal (it used to be whenever a size was known).
- `tui.Program` draws by cell, so the bytes it writes are different (and fewer); tests
  that compared exact output need new expectations. `tui.testing.Screen` is
  `term.vt.Screen`.
- `term.width` splits grapheme clusters by UAX #29 (Unicode 17): CR LF is two clusters, as
  terminals draw it, and a lone regional indicator is one column wide.
- `Style` expands tabs to four spaces (`tab_width`; null keeps them).
- The `form` component was rewritten as huh's: `Field.kind` is one of `input`, `text`,
  `choice`, `select`, `multi_select`, `confirm`, `file`, `note`; the `markdown`
  component scrolls and needs `viewport`.

- `cli.complete.Builtins` is now `cli.complete.Options`. Completion scripts call
  `__complete2`, which adds directives (files, directories, no space); `__complete` still
  answers for scripts generated earlier.
- `snek platform update` installs from archives: releases publish
  `snek-<os>-<cpu>.tar.gz` (`.zip` on Windows) instead of bare executables.
- `snek platform update` requires an Ed25519 signature (`<archive>.sig`) made with the
  release key, and `release.yml` fails without the `SNEK_SIGNING_KEY` secret.
- Error sets gained members: `platform.update.ApplyError` (`ArchiveInvalid`,
  `ExecutableMissing`), `platform.webauthn.VerifyError` (`SignatureInvalid`,
  `SignCountRegressed`), and `platform.ctap.CommandError` (`PinInvalid`, `PinBlocked`,
  `PinNotSet`; the PIN statuses used to all be `PinRequired`).
- `platform.ctap.assert` takes an `AssertOptions` (`keepalive`, `pin`) in place of the
  keepalive, and `ctap.Channel` keeps the `io` it was opened with.
- The `__complete2` protocol has a `:prefix` directive; scripts from before it do not
  know it.
- `cfg.dotenv.write` returns `error.Unrepresentable` for a key whose variable name would
  read back as another path (a section key ending in `_`). It used to write a name that
  read back wrong or not at all.
- `tui.Msg` (and `Message(T)`) has a `report` variant and `tui.input.Event` a `report`
  variant, `tui.Cmd.Item` has `handoff` and `suspend_process`, and
  `tui.ansi.Color.Layer` has `underline`: exhaustive switches over them need a case.
- `tui.Program` handles Ctrl-Z itself on POSIX systems (`Options.suspend_on_ctrl_z`); it
  used to reach the model as a key.
- `cfg.Diagnostic` has a `file` field, and its `format` writes
  `file:line:column: key: message` with whatever of those is known.
- `Config.decode` fills in the file and position of its diagnostics (see Added).
- `tui.Cmd.Item` has `work`; `tui.testing.Screen.Cell` has a `pen`.
- `cli.parse.Source` has `config`; `cli.Command` and `cli.Flag` have new fields (all with
  defaults); `cli.Messages` has new sentences, so a translation written against the old
  table leaves them English.
- The `form` component's `Field` has a `kind` (`.input` or `.choice`) in place of
  `input`; `Field.deinit` frees it.
- `snek cfg` reads a top-level `current_profile` key as the profile to apply when none is
  given (`snek cfg profile use` writes it).
- Removing a key with `cfg.edit` (and `snek cfg unset`) also removes the comment lines
  directly above it and the blank line it would leave behind.
- dotenv rejects variable names that start with a digit.
- `CI=0` and `CI=false` no longer count as CI (for color as well as for interactivity).
- Deprecated commands are no longer listed in help, offered by completion, suggested, or
  reached by prefix; typed in full they still run, with their warning.
- `cfg.encrypted.Decrypted.plaintext` is `[]u8` (it is wiped), and diagnostics no longer
  quote lines of encrypted files.
- `webauthn.Registration.credential` takes `arena` and the relying party's `Expected`
  (`.credential(arena, .{ .challenge, .origin, .rp_id })`), which it checks the
  registration against.

### Added

- **`sys.timezone`: the local time zone,** its offset and abbreviation at any instant,
  from `TZ` (a POSIX rule such as `CET-1CEST,M3.5.0,M10.5.0/3`, or a zone name read from
  zoneinfo), else `/etc/localtime`, else on Windows the system's zone; TZif versions 1 to 3
  with their footer rule; UTC when nothing can be read. `sys.log.Logger.zone` writes times
  in it (`writeTimeAs` takes the offset), and `termancy ui log --time` uses the local zone,
  as gum's does.
- **`termancy ui style`, `format`, `join`, and `log` work as gum's:** a variable for every
  flag (`TERMANCY_STYLE_TRIM`, `TERMANCY_FORMAT_THEME`, `TERMANCY_JOIN_ALIGN`,
  `TERMANCY_LOG_FORMATTER`); `style --trim` and `--strip-ansi`; `--align top|middle|bottom`
  for every style group (where text sits in a taller block); `format --strip-ansi`, gum's
  `pink` style sheet by default (`notty` without color, where it was `dark` or `light`), and
  gum's template functions in all their spellings (`Color` with one color, `Foreground` and
  `Background` with none, `Overline`); `log --structured`, `--format` (printf),
  `--formatter`, the `none` level, gum's `--time` layout names (`kitchen`, `ansic`,
  `rfc822`, `stampmilli`, ...), `--min-level` from `TERMANCY_LOG_LEVEL`, a status of 1 after
  `fatal`, and a style group for each part (`--level.foreground`, `--key.faint`). `sys.log`
  grows what that takes: `Styles`, charm's look part by part; `TimeFormat`'s Go layouts
  (`goLayout`); `Level.charmColor`. `cli.flags`: `.env = ""` gives a flag no variable under
  an `env_prefix`.
- **`ui choose` and `ui filter` take the rest of gum's flags.** `choose`: `--ordered`,
  `--select-if-one` (prints a lone item with no terminal at all), `--label-delimiter`
  (labels shown, values printed), `--selected '*'`, `--cursor-prefix`, `--selected-prefix`,
  `--unselected-prefix`, and piped standard input naming the items selected when the items
  are arguments; `--header` is gum's `Choose:` unless given, and `a` chooses all only with
  `--no-limit`, as in gum. `filter`: `--strict`/`--no-strict` (the typed text as an answer),
  `--fuzzy`/`--no-fuzzy`, `--fuzzy-sort`/`--no-fuzzy-sort`, `--reverse`, `--width`,
  `--height` (0, now the default, fills the terminal on the alternate screen),
  `--indicator`, the prefixes, `--selected`, `--select-if-one`, `--timeout`, the shared
  flags, style groups for each part, and `TERMANCY_FILTER_*` variables; its rows have gum's
  look (`•` before the highlighted one, `◉`/`○` marks). With `ACCESSIBLE=1`, `filter` asks
  for a query, then numbers its matches. gum's keys: ctrl+q submits, left/right (h/l)
  page, up/down go round past either end, and ctrl+a (or a) chooses all.
- **Components:** `MultiSelect.order` keeps the order items were chosen in, `cursor_mark`
  marks the highlighted one, `toggle_all` turns off a/ctrl+a, and tab and ctrl+space toggle;
  a chosen item's text is in `styles.chosen` too. `Filter` has `strict`, `fuzzy`, `sort`,
  `reverse`, and `fill`, shift+tab, ctrl+space, and ctrl+a (`toggleAll`), and
  `styles.unchosen`; an empty query keeps the items' order, as documented. `List.wrap` goes
  round past either end, left/right (h/l) page, and ctrl+q submits `Select`, `MultiSelect`,
  and `Filter`. `List.styles`
  has `cursor_text`, styling the highlighted text apart from its prefix (`textStyle`). A
  `cli.flags` set with many groups no longer runs out of compile-time branches.
- **Flag group spelling and variables:** a group's place (`cli.GroupPlace`, the same type in
  any flags struct, so one can be shared) takes `.separator` (`"."` spells
  `--cursor.foreground`) and `.env_prefix`; `FlagOptions.env_prefix` gives every flag of a set
  a variable, the prefix and the flag's name in SCREAMING_SNAKE (`APP_` gives
  `--cursor.foreground` `APP_CURSOR_FOREGROUND`), unless it names its own `.env`.
  `tui.Options.timeout` ends a program after a while, as Ctrl-C does, with
  `Outcome.timed_out` set; `cli.Theme.accent` is what interactive prompts highlight.
- **`termancy ui` takes gum's shared flags** (`choose` first): `--timeout 500ms` (a
  `cfg.Duration`: status 124 and `timed out` on stderr), `--show-help`/`--no-show-help` (the
  keys under the component), `--padding` around it, `--strip-ansi`, `--input-delimiter`, and
  `--output-delimiter` (typed with escapes: `\n`, `\t`, `\0`); style groups for each part
  (`--cursor.foreground 212`, `--header.bold`, `--selected.background`) with the theme's
  colors as defaults; and every flag from a variable, `TERMANCY_CHOOSE_HEIGHT`,
  `TERMANCY_CHOOSE_CURSOR_FOREGROUND`.
- `Config.initFor(X, gpa)`: a configuration that knows its settings type, and its defaults,
  from the start. `field.Reason`, a writer that keeps the template and arguments a check gave
  `field.fail`. `input.Report.cursor` and `ansi.queryCursorPosition` (DECXCPR), and
  `Renderer.cursorColumn`.

- A check's own message is translated from the app's `translations` by the template it
  gave `field.fail` (`"{0} is in use"`, the `{0}` form `ctx.tr` takes), with its arguments
  filled into the translation.
- **`field`:** specs and checks (`min`, `max` on numbers or any type with `order`, `minLen`,
  `maxLen`, `oneOf`, `glob`, `from`) that describe themselves for help, docs, schemas, and
  completion; typed field paths; "did you mean" (the one edit distance `cli` and `cfg` share).
- **Nested flags and choices:** a struct field is a group of prefixed flags
  (`--public-port`); a tagged union is a choice (`--storage s3`, `--storage-s3-bucket`), with
  a variant's flag and another variant's name together an error. `cfg` decodes a choice from
  a string naming the variant or a one-key table holding it, and writes it back the same way.
- **`.settings` on a command:** a field of the flags read from configuration too, filled by a
  loader, never required on the command line, with help saying where else each value can be
  set (`cfg.sourcesOf`). `ctx.configError` exits 78 (`App.exit_config`), `ctx.settingsAsker`
  with `Config.askWith` asks for a missing required key at a terminal, and `ctx.flagKeys`
  with `Config.nameFlags` makes a missing key's message name its flag
  (`set it in a file, $APP_TOKEN, or --token`).
- `cfg` warns about a key set twice in one JSON, `.env`, or INI file; a failed check across
  a table's fields names the fields that took their defaults; an invalid enum or variant
  name gets "did you mean".
- `cli` messages for a failed check (`must match`, a check's own words, the check pass's)
  in every language.

- **`cfg`:** `DecodeOptions.warn_unknown` reports keys no field claims as warnings, at the
  file and line that set them, with "did you mean" for a close field; strict-mode and schema
  `additionalProperties: false` errors suggest the key too, and `snek cfg validate --schema`
  warns about an undeclared key close to a declared one.
- **`tui.testing.Driver`:** a model's `deinit(*M, std.mem.Allocator)` gets the driver's
  allocator.
- **DX:** `cli.command` compile errors name the command and suggest the closest name for
  unknown spec fields, `meta` names (listing the struct's fields), `.args` fields, and
  constraint flags: `cli.command("greet"): unknown spec field 'sumary'; did you mean
  'summary'?`. `snek cli add` generates its test with `cli.testing.run`, a few lines instead
  of twenty, and `snek cli init` also writes an example `hello` command with its test.
- **`platform`:** `windows_hello.register`, WebAuthn registration through Windows Hello,
  next to `assert`; `webauthn.CreationOptions`, `Registration` (with `credential()`, what a
  relying party keeps), and `attestedCredential`, which reads the credential out of a
  registration's authenticator data, with `CreationOptions.parseJson` and
  `Registration.writeJson` for their JSON forms. `distribution.manifests.writeWinget` writes
  a winget manifest, from a `Package` whose new `publisher` names the identifier's first
  part.
- **snek:** `platform webauthn get` and `create`, a WebAuthn client for scripts: the options
  a relying party sends, as JSON, in; the response's JSON out. Through Windows Hello on
  Windows; `get` through a USB security key on Linux. `platform release manifest -f winget`
  (with `--publisher`); the release publishes `snek.yaml` beside the Homebrew and Scoop
  manifests, and Authenticode-signs `snek.exe` when given a certificate.
- **`cli`:** `.confirm = true` with `ctx.confirm(fmt, args)`, a question made at run time
  under the same `--yes` and no-terminal rules; per-command `.exit_statuses`, in that
  command's man page and its section of the single page and Markdown.
- **snek:** `platform dirs`, `platform info`, and `tui list` take `-o yaml|jsonl` and report
  errors as JSON under `-o json`; `-v`/`--log-level` on `platform update` (URLs, archive,
  signature check), `cli record` (font, frames, sizes), `tui serve` (connections and exit
  statuses), and `cfg` (files found and loaded, the profile); spinners while `freeze`
  draws, `zig fetch` runs, and `tui md` fetches; `cfg validate`, `fmt`, `diff`, and
  `tui confirm` list their statuses in EXIT STATUS.
- **Fuzzing and budgets:** `zig build fuzz` covers SSH key blobs, `authorized_keys`, OpenSSH
  private keys, signatures, the SSH transport, CBOR, the escape-sequence parser and VT
  screen, the input decoder, Markdown, PNG, GIF, and JPEG, TrueType, highlighting, regexes,
  and tapes, as well as `cfg`. `zig build budget` checks the smallest `cli`, `cfg`, and `tui`
  apps against size budgets (347, 434, and 230 KB now; 416, 512, and 272 KiB allowed) and
  `--help` against 50 ms (1.5 ms now). `zig build check` also compiles the tests for aarch64
  Linux.
- **`cli` and `cfg` after dogfooding `examples/repos`:** under `App.run` standard error
  shows each line as it is written; `Config.loadAppFile` (the `--config` path, a variable's
  file, or `config.toml` in the configuration directory, a missing file not an error); flag
  meta `.key` and `.internal`; flow `Ask.label_fn`, list questions for `[]const T`, and an
  "invalid answer" line before asking again (`Messages.flow_rejected`, translated);
  `text_columns` for `ctx.render`'s tables; `cfg.glob`, `cfg.edit.applyAll`,
  `cfg.Duration.toIo`/`fromIo`; `cli.testing.Options.cwd`. Every public declaration in `cli`
  and `cfg` has a doc comment, and `docs/stability.md` lists what is stable.
- **`tui.run(gpa, io, &model, .{})`** runs a model on the terminal and returns the exit
  status (0, or `tui.interrupted_status`, 130); without a terminal it prints the first frame
  as trimmed text. `tui.runSession` runs one over an SSH or browser session at its size.
  `testing.Driver.screenTextTrimmed`, `testing.writeTrimmed`.
- **`platform.web`:** `Server.handlerFor(Context, fn (*Context, *Session) !void)` makes a
  handler without casts, `Server.link` formats the link to print, `Config.title` names the
  browser tab.
- **`term.live.Live.update(io, context, change)`** runs a change under the lock and redraws,
  for progress reported from several tasks.
- Registry `table`: `Table.handleKey(key) bool` moves the highlight and never quits, for
  embedding it.
- **Charm's libraries and tools, in Zig** (the README maps each one):
  - **`term`:** color profile detection for more terminals and a downsampling writer;
    UAX #29 grapheme clusters from Unicode 17 tables; styled wrapping and cutting that
    carry styles and links across lines; Oklab color math and gradients; `Style` borders
    with titles, per-side colors, and gradients, `max_width`, `max_height`, `transform`,
    hyperlinks; `Canvas` layers, `Table`, `List`, `Tree`; a VT500 `Parser`, `Pen`, and a
    terminal emulator (`vt.Screen`) with scrollback, modes, queries, and OSC; `explain`;
    `Pty` (Linux, macOS, BSDs, ConPTY); `Buffer` and `Renderer`; `highlight` (30
    languages) and `markdown` (CommonMark, GFM, style sheets); `TrueType`, `fonts`,
    `raster`, and `image` (PNG, animated GIF, resizing, quantizing); `graphics` (kitty,
    iTerm2, sixel, half-block images); `golden` files; `Regex`.
  - **`cli`:** `cli.Theme` (fang): styled help, errors, warnings, and hints; help measured
    in display columns, with wrapped summaries and a capped flag column.
  - **`tui`:** a cell-diff renderer, `max_fps`, cursor, title, filter, and clipboard
    hooks, `Cmd.every`, `bell`, `altScreen`, `mouse`; `tui.motion` springs (harmonica);
    `Program.runSession` for programs served over SSH; golden files and `advanceUntil`
    in `testing.Driver`; the `paginator`, `stopwatch`, `timer`, and `help` components;
    suggestions in `input`, line numbers in `textarea`, gradients and animation in
    `progress`, horizontal scrolling in `viewport`, and a huh-style `form` with themes.
  - **`platform`:** `ssh` (keys, fingerprints, `authorized_keys`, Ed25519, ECDSA, and RSA
    signatures, OpenSSH key files with passphrases, `ssh-keygen -Y` signatures, and a
    server with ML-KEM hybrid key exchange, ChaCha20-Poly1305 and AES-GCM, and strict key
    exchange, tested against OpenSSH 10); `mnemonic` (BIP 39); `log` in logfmt, styled,
    with fields, prefixes, and callers; `process.editAt` (an editor at a line).
  - **`snek`:** `cli record` (vhs tapes to GIF, PNG, frames, text, SVG, MP4, WebM; `new`,
    `validate`, `themes`, and `capture`, which writes a tape from what you type),
    `cli freeze`, `cli explain`, `tui md` (glow), `tui image`, `tui serve` (wish),
    `tui join` and `tui log`, `tui format --type markdown|code|emoji|template`, and
    `platform ssh keygen|fingerprint|melt|restore|sign|verify`.

- Six more examples: `deploy` (flows), `httpc` (the flag grammar), `kv` (an interactive
  shell, plugins, docs), `settings` (`cfg` tooling), `monitor` (a `tui` dashboard), and
  `doctor` (`platform`); the README lists all ten and what each shows.

- **`cli`:** typed positionals; flag aliases, `.min`/`.max`/`.one_of`, and `validate`;
  suggestions for mistyped values; response files, prefix matching, non-interspersed and
  pass-through arguments; run-time completers and shell directives; help that wraps to the
  terminal, in color, with topics and replaceable sections; file completion after
  `--flag=`; HTML docs and one man page per
  command; `cli.testing`; cancellation on Ctrl-C with `cleanup` hooks; prompts for missing
  flags, secret ones hidden; plugins (`app-<name>` on `PATH`); `cli.version`;
  `cli.Messages` for translation; `cli.repl`.
- **`cfg`:** in-place edits (every format) and `edit.reformat` that keeps comments (TOML, YAML, ZON,
  dotenv); `DateTime`; JSON with comments; streaming JSON, and YAML read a top-level entry at a
  time; INI; multi-line YAML scalars, indentation indicators, and opt-in anchors and aliases; `meta`
  constraints, `validate`, and every error at once; JSON Schema validation and inference; renames
  and migrations; `${key}` references; append merging; includes; `loadDir`; the `Source` interface;
  `reload`, which follows includes as they are now; secret references and providers; encrypted files
  (`cfg.encrypted`); case-insensitive keys; `cfg.diff`; incremental `set`, with references too.
- **`snek`:** `cfg diff`, `cfg env`, `cfg edit`, `cfg schema infer|check`, `cfg merge`,
  `cfg init`, `cfg encrypt|decrypt`, `-o systemd` and `-o ini`; completion of keys,
  profiles, and files; `cli repl`; `cli docs --format html` and `--dir`; `tui init
  --dependency`, `tui add --prune`, the `shell` component, and mouse support in the
  components; `platform release keygen|sign|verify|manifest`; `cli init` projects with a
  `Settings` struct and `zig build schema`, for `cfg init --schema`.
- **`tui`:**
  - the kitty keyboard protocol, on request;
  - frames rewrite only the lines that changed;
  - `Cmd.handoff` lends the terminal to the model (for an editor or a pager) and takes it
    back;
  - Ctrl-Z suspends (`Cmd.suspend_process`), and `fg` resumes and redraws;
  - `Options.queries` asks the terminal for its foreground and background colors, mode
    support (DECRQM), and kitty keyboard flags, answered as `.report` messages, and
    `ansi.Color.Rgb.isDark` tells a dark background from a light one;
  - `tui.Keymap`, key bindings that match keys and write the help line;
  - `Cmd.work`, background work whose result arrives as a message, and `Model.above`,
    lines printed above an inline program;
  - `layout.split` (lengths, percentages, fills, minimums, maximums), `tui.focus`
    (`Ring`, `Grid`), `ansi.notify`, and `ansi.setProgress`;
  - `testing.Screen` keeps colors and attributes, and `writeSvg` draws it;
  - curly, dotted, dashed, and double underlines, and underline colors, in `Style`;
  - the `viewport`, `tree`, `filepicker`, `multiprogress`, `chart`, `markdown`, and
    `prompts` components (`snek tui demo flow` shows the last asking a flow's questions);
  - `Terminal` keeps input typed ahead: keys a program read but did not use reach the next
    program on the same terminal, and switching modes no longer discards unread input.
- **`cfg` (since):** `Config.loadVariants` (`app.local.toml`, `.env.local` over the base),
  `Config.view` (a section with relative keys), `addResolver` (`${name:arg}`),
  `findFile(.{ .upward = true })`; decode problems point at the file and line that set the key
  (`Config.locateDiagnostic`, `Diagnostic.writeSnippet`, and `cfg.locate` for any format);
  `meta.deprecated`; `Config.changed`, to poll files for changes.
- **`cli` (since):**
  - `App.pager` shows help taller than the terminal through `$PAGER`;
  - translation (`cli.i18n`): locale detection, gettext-style tables for help and the
    app's strings, CLDR plural rules, `ctx.tr`, `ctx.plural`, and the library's sentences in
    German, Spanish, French, and Portuguese;
  - `.confirm` (with `--yes`), `.dry_run` (`--dry-run`, `ctx.dry_run`), `.output`
    (`-o text|json`, `ctx.render`, and JSON errors), `.logging` (`-v`, `--log-level`,
    `ctx.log`), and `.feature` gates on commands and flags;
  - flag `.requires`, `.min_len`, and `.max_len`;
  - `help --search <words>`, an ENVIRONMENT section in man pages, and
    `completion install [shell]`;
  - `App.aliases` (user aliases), `App.defaults` (flag values from a configuration file),
    and `App.middleware`;
  - `examples/tasks`, which uses them with `cfg`;
  - `cli.Flow`: commands as graphs of questions and actions, branching on the answers,
    with flags answering questions, forms (`.form`, several questions on one screen
    through `Asker.form`), dry runs, undo, JSON progress, and Mermaid output;
    `cli.flow.Script` for tests; `runFrom`; `snek cli add --flow` writes one.
- **`snek` (since):** `cfg validate` and `cfg schema check` show each problem's line with a
  caret, and `cfg validate` warns about plain-text secrets and deprecated keys; `snek tui
  file` chooses a file; `snek tui pager` opens the file in the editor with `v`; help goes
  through the pager; `cfg get --as`, `cfg profile list|use`, `cfg fmt --sort`, and
  `-c https://...` (cached, served offline); `tui demo` (with `--svg`); `ACCESSIBLE=1`
  plain prompts for `tui choose`, `confirm`, and `input`.
- **`platform` (since):** `remote.get`, a URL's body revalidated with its ETag and read
  from a cache when offline.
- **`platform`:**
  - `update` unpacks `.tar.gz` and `.zip` assets and finds pre-releases when asked;
  - `webauthn` verifies ES256 and EdDSA signatures from COSE keys, and sign counts;
  - `ctap` talks CTAP2 to security keys over CTAPHID (Linux hidraw), with ClientPIN
    (`getPinToken`, `getPinRetries`; PIN/UV auth protocols one and two), and `cbor`
    encodes and decodes the CBOR it needs;
  - `proctitle.scrub` works on Windows, through the process environment block.
- **Engineering:**
  - CI on Linux, macOS, and Windows;
  - `zig build coverage` (kcov);
  - `zig build fuzz` (coverage-guided, over the parsers, edits, reformatting, and
    decoding, with an in-tree corpus and regressions);
  - `zig build console`: `cli`'s Windows console code under a pseudo console;
  - `zig build examples`;
  - `zig build docs`;
  - a release workflow that builds, signs, and publishes archives and manifests;
  - [docs/upgrading-zig.md](docs/upgrading-zig.md).
- **`term.live`:** spinners, progress bars (eighth-cell fill, gradients, counts, bytes/s,
  ETA), live text, and step checklists, without `tui.Program`. At a terminal they redraw in
  place; in pipes, CI, or without color they print a line per change. `ctx.live(items)`
  draws them on standard error. The registry's `spinner`, `progress`, and `stopwatch` and
  `snek tui spin` share them.
- **`cli`:** `cli.docs.command`, a ready-made `docs` command; `App.color_flag` adds
  `--color auto|always|never` (snek has it); `-o jsonl`; docs end with an EXIT STATUS
  section, with the app's own codes from `App.exit_statuses`.
- **Components:** `input` and `textarea` undo (Ctrl+Z)
  and redo (Ctrl+Y, Ctrl+Shift+Z), grouped by word, with `undo_limit`.
- **`term.image`:** JPEG (baseline, extended, and progressive; grayscale, YCbCr, CMYK; any
  subsampling; restart markers; EXIF orientation); `image.decode` picks the format.
  `term.graphics.detectByQuery` asks the terminal about kitty graphics and sixels;
  `snek tui image -p auto` asks when the environment does not say.
- **SSH:** `platform.ssh.Client` (host keys checked against `known_hosts`, Ed25519 keys or
  passwords, commands and terminals, `forwardLocal` for `ssh -L`); `platform.ssh.known_hosts`;
  the server takes `ssh -L` and `ssh -R` when `Config.direct_tcpip` and `tcpip_forward`
  allow them; `snek platform ssh run [user@]host -- command`. The client logs in with the
  Ed25519 keys of the ssh-agent at `$SSH_AUTH_SOCK` (`platform.ssh.Agent`), after `-i` and
  before `~/.ssh/id_ed25519` as OpenSSH orders them; Windows' named-pipe agent is not supported.
- **The browser:** `platform.web.Server` serves a terminal over a WebSocket with the SSH
  session's surface, so `tui.Program.runSession` and `snek tui serve --web` (as ttyd) work
  in a browser: an xterm.js page pinned with integrity hashes, a token link, an origin
  check, loopback by default. `examples/lobby` takes `--web`. The token link is swapped for an
  HttpOnly, SameSite=Strict cookie (Secure behind `X-Forwarded-Proto: https`) and a redirect
  to the clean URL; at most `max_sessions` (32) at once, further upgrades get 503; the page
  sends a heartbeat and sessions silent for `idle_timeout` (120 s) are closed, since std's
  WebSocket hides pongs.
- **Docs site:** `zig build site` writes `zig-out/site`: a guide, a page per library from
  its module docs, a component gallery with each component's source, the command and API
  reference, on one light and dark style sheet that works offline. `zig build site-gifs`
  adds a GIF of each component recorded from `docs/tapes`; `.github/workflows/site.yml`
  publishes it to GitHub Pages and replaces `docs.yml`. `cli.docs.Options.stylesheet` and
  `snek cli docs --format html --stylesheet <url>` link a style sheet instead of inline
  styles.
- **Guide:** `docs/guide.md`, "Your first app in 10 minutes", every snippet checked against
  `examples/first-app`.
- **`examples/repos`:** a git repository dashboard built end to end: a config file under
  `REPOS_*` overrides, a first-run `cli.Flow` that keeps the file's comments, `list -o
  text|json|jsonl`, concurrent `git fetch` under `ctx.live`, and a filterable TUI from
  components copied with `snek tui add`, also served with `--web`.
- `snek tui add` works in any directory holding a `tui.zon`; it no longer requires
  `build.zig` there.
- **From the earlier implementation (`backup/`):**
  - **`cli`:**
    - `.secret` flags are never shown: their defaults in help and docs, and their values in
      parse errors, print `<redacted>`.
    - `Context.secretValues()` returns this run's secret values, for a log scrubber.
    - Typed positionals take `.help`, shown in an "Arguments" section of help and docs.
    - `App.defaults = .from(&config, .{ .prefix = "tool" })` reads flag defaults from any
      source with `flagText(key)`, such as `cfg.Config`; a flag's `.config` sets its key.
    - Runs under CI are never interactive, even at a terminal (`term.capability.ci`,
      `cli.terminal.interactive`).
    - A required positional with `.prompt` is asked for when missing.
    - `Command.repl`: a command without a handler, run bare at a terminal, starts a shell
      on its subcommands (`App.executeLineIn`, `repl.Options.path`).
    - `-o yaml` for commands with `.output`; `-V` for `--version`;
      `cli.text.aliasesFromIni` reads a git-style `[alias]` section into `App.aliases`.
  - **`cfg`:**
    - `snek cfg redact <file|->` prints a file with secret-looking values replaced,
      keeping its layout, for bug reports.
    - `snek cfg validate --schema` without files checks the effective configuration
      (files, profile, environment, `--set`) and says where each bad value came from.
    - `cfg.edit.sort` (and `snek cfg fmt --sort`) keeps TOML comments with their keys;
      edits keep CRLF line endings and single-quoted strings.
    - `meta.<field>.env = "NAME"` is honored (`Config.bindEnvs`); `Config.flagText`.
    - Decrypted plaintext is wiped after parsing.
  - **`term.diff`:** Myers line diff with a unified writer, optionally colored; golden
    mismatches print unified diffs; `snek tui diff` colors its output.
  - **`platform`:**
    - `Logger.secrets` replaces known secret values wherever they appear, without
      allocating; the `doctor` example feeds it `ctx.secretValues()`.
    - `capture` takes a `timeout`; `editText` edits a string in `$EDITOR`.
    - `signal.installWith` catches SIGHUP (`.hangup`, for reloads) and SIGQUIT.
    - `dirs.binDir` (`~/.local/bin` and the like) and `dirs.tempDir`.
    - `daemon.SystemdUnit` writes a complete unit, with systemd's escaping.
    - A lock file left empty or unreadable for over `Lock.stale_grace` is stale.
  - `snek tui add` with no names, at a terminal, offers a multi-select of components.

### Security

From a review before the repository went public:

- **ssh:** a packet longer than 64 KiB, sent before login, crashed the server (and a
  malicious server crashed the client); packets are read in full whatever their size.
- **ssh:** `Server.Config.max_connections` and `login_timeout` are enforced; connections were
  unlimited and could wait forever without logging in.
- **ssh:** a session's `env`, `signal`, and `pty-req` requests and forwarded host names no
  longer grow memory without bound: kept per channel, at most 64 variables, one terminal,
  known signal names only.
- **ssh:** strict key exchange requires the peer's KEXINIT first; a connection hangs up
  before a key's nonce (the sequence number) would repeat; received packets are wiped on
  disconnect.
- **`tui serve`:** `authorized_keys` entries with options (`from=`, `command=`, `restrict`)
  are left out with a warning, since the server cannot enforce them; client-chosen user
  names are escaped in the log.
- **`platform update`:** the new executable must report the release's version, so an older
  signed archive re-published under a newer tag is rolled back; `update.HttpTransport`
  fetches over https only and refuses a redirect to plain http.
- **`platform.web`:** with `--anyone` on the loopback, DNS-rebound hostnames get 421;
  connections that do not send their request within 10 s (`Config.head_timeout`) are hung
  up on; the page sends a Content-Security-Policy; `tui serve --web --anyone` off the
  loopback warns that any page a visitor opens can run the command.

### Fixed

- `passkey get` and `create` check the RP ID against `--origin` before anything else, on
  every system: `create` away from Windows said it needs Windows Hello instead.
- `ctap.getPinToken` wipes the PIN's hash, the secret shared with the key, its ephemeral
  key, and the key agreement's intermediates (the shared point, its `x`, the HKDF key) on
  every way out, errors included; they stayed on the stack.
- `ctap.Channel.open` waits past another program's INIT reply on the broadcast channel
  (its nonce is not ours) instead of failing with `InvalidResponse`.
- A security key that keeps sending keepalives, or a busy other channel, can no longer hold
  `ctap.Channel` (and `passkey get`) forever: each request ends with `error.Timeout` after
  the new `Channel.deadline_ms` (five minutes). `ctap.assert` takes it from the request's
  `timeout` as browsers do, as a hint: 0 or absent is WebAuthn's recommended default, and
  other values are held within its recommended range (`RequestOptions.ceremonyTimeoutMs`).
- `webauthn.verifyAssertion` (and so `verify` and `Registration.credential`) refuses
  authenticator data flagged backed up (BS) but not backup eligible (BE), as WebAuthn
  requires.
- `oauth.DevicePoll.next` no longer overflows when a server that sent an `interval` near
  2^32 then answers `slow_down`; the interval stops at its largest.
- `webauthn.Registration.credential` makes the registration checks `verifyAssertion` makes
  for a sign-in (client data of type `webauthn.create`, challenge, origin, RP ID hash, user
  presence, and verification when required): it read the key of a credential made for any
  RP, without the user's touch.
- `passkey get` and `create`, `ctap.assert`, and `windows_hello.assert` and `register` refuse
  an RP ID that is not the host of `--origin` or a domain it is under (WebAuthn's client
  check): options from `https://evil.example` naming `rpId` `bank.example` were signed for
  `bank.example`. The new `webauthn.rpIdFor` makes the check: hosts compare without case,
  an IP address (IPv6 in brackets, `https://[::1]:8443`) is only its own RP ID, and a
  single label such as `com` is no parent domain to claim.
- `webauthn.PublicKey.fromCose` refuses a COSE key that repeats a label (the last `x` won,
  where another parser may take the first) or has no `alg`, which WebAuthn requires.
- `ctap.Channel.transact` refuses a reply longer than CTAPHID's 7609 bytes whatever the size
  of `out`: with a larger buffer, a key announcing 65535 bytes overflowed the sequence
  number at its 256th continuation packet.
- `ctap.getAssertion` reads a credential or user map whose keys are not all text whole: a
  key that was not text was skipped without its value, so a key (`h'bb'` in
  `{1: "id", h'bb': 0}`) could be taken for the ID and the rest of the response misread.
- `webauthn.attestedCredential` no longer panics on a credential ID length of 65518 or more
  (the key's offset overflowed 16 bits); it refuses IDs over WebAuthn's 1023 bytes, and
  bytes after the key that the ED flag does not announce as an extensions map.
- `cbor.Reader.boolean` takes only `false` and `true` (`0xf4`, `0xf5`): a float whose bits
  matched them (`f9 00 15`), or a simple value in two bytes (`f8 14`), read as a boolean.
- `yaml.parseReader` (YAML through `Config.loadReader`) reads exactly what `yaml.parse`
  reads: it took each piece for a document, so it accepted keys after `...` and after a
  root that was a flow mapping or indented, and dropped a byte order mark starting a line.
- `termancy image` (`image.decode`) reads a GIF's first frame only; it read every frame to
  keep the first, so a long animation was slow and a bad later frame refused the file.
- A GIF cut short, or followed by junk, keeps the frames before the damage, as browsers
  show them; the whole file was refused. One with no whole frame still is.
- A GIF with an LZW minimum code size of 1 (below the spec's 2) is read as giflib and
  Chrome read it; its codes never grew wider, so most of it came out wrong.
- A baseline or extended JPEG scan with successive approximation (Ah or Al not 0) is
  refused, as the standard requires; it was decoded with its coefficients shifted.
- A JPEG quantization table whose precision is neither 8 nor 16 bits is refused; it was read
  as 16 bits.
- Interlaced GIFs are read with their rows in place; they came out scrambled.
- `image.readGif` clears or puts back a frame as its disposal method says, and a graphic
  control extension's transparent color applies to the frame after it only, not every one.
- A JPEG of more than 100 scans is refused, and blocks past the end of a scan's data are left
  blank (as libjpeg leaves them) instead of decoded from zeros: 8 KB of empty scans took 19 s.
- A JPEG of more than `image.max_pixels` (8192 by 8192) is refused, as a PNG or GIF is: a
  file of a few megabytes claiming 32768 by 32768 allocated gigabytes.
- A GIF's frames larger than its screen count toward `image.max_pixels`: a few kilobytes of
  8192 by 8192 frames on a 1 by 1 screen took most of a minute to read.
- `cfg fmt` on YAML took a `#` inside a key (`c#ounts:`) for the start of a comment and
  declined the file, even one it had just written from `c#ounts: [3, -4]`.
- **`cfg` encrypted files:** the Argon2 costs an envelope names are bounded (1 GiB, four
  passes over it, 16 lanes) and checked before they are paid; a file from elsewhere
  saying `m=4294967295` ran the machine out of memory, `t=4294967295` for hours.
  `encrypted.encrypt` refuses the same costs, so what it writes can be read.
- Argon2's working memory, from which an encrypted file's key could be derived again, is
  unmapped once the key is made instead of staying (64 MiB, unwiped) in the file's arena
  for as long as the `Config` lives.
- With a profile active, what is secret under `profiles.<name>` (an encrypted file's
  values, `${secret:...}`, `--secret profiles.prod.db`) is secret where the profile puts
  it too; `cfg show --profile prod` and `cfg explain` printed it. Those keys then stay
  secret whatever sets them.
- `encrypted.encrypt` and `cfg encrypt --passphrase ''` refuse an empty passphrase
  (`error.EmptyPassphrase`), which made a file anyone could open.
- Cancelling during an encrypted file's key derivation is `error.Canceled`, not
  `WeakParameters` (or `CorruptEncryption` from `Config.loadFile`).
- `cfg`: `Config.markSecret` after a `get` also redacts the references that had already
  expanded the secret (`url = "pg://u:${password}@h"`); `write` and `snapshot` showed them
  in plain text.
- `cfg`: converting to TOML (`termancy cfg convert`, `toml.write`) no longer turns a string
  that reads like a date (`{"d": "2024-01-01"}`) into a TOML date for every other reader; it
  stays a quoted string, and so does a new key set with `cfg set --string`.
- A failed check on one value of a list (`<file> (value 2): ...`) is worded from the new
  `Messages.nth_value`, translated in the bundled tables, instead of an English
  `(2nd value)`. `field.ordinal`, now unused, is gone.
- With `App.prefix_matching`, completion descends through a prefix of a subcommand's alias
  as the parser does (`app ru <Tab>` for `serve`, alias `run`); it took names only.
- fish completion runs the program once per Tab, not three times (each `complete`
  condition ran it again), so slow completers answer three times sooner.
- bash completion no longer expands candidates as file patterns: `photo[1].jpg` stayed
  `photo[1].jpg` only when no `photo1.jpg` existed, and under `shopt -s nullglob` a
  candidate holding `*`, `?`, or `[` (even in its description) disappeared.
- `field.checkOne` returns the failed check's `About` when its reason does not fit the
  writer, as `field.validate` does, instead of `error.WriteFailed`.
- `field`: `.min` and `.max` on a float reject NaN; `--ratio nan` (or `nan` in a TOML file)
  passed both.
- `cli`: a switch set to false (`--no-yaml`, or `yaml = false` in a configuration or its
  variable) no longer counts as given for `.exclusive`, `.together`, and `.requires`, so
  `serve --json` works with `yaml = false` in the configuration.
- `term.vt`: a cursor position query (`CSI 6n`) in origin mode with the cursor restored
  above the scroll region no longer crashes `freeze -x`, `explain`, and `record`.
- `term.markdown` and `termancy md`: control characters in a document are dropped, so a
  fetched README can no longer send its own escapes (OSC 52 clipboard writes, titles) to
  the terminal.
- `term.Buffer`: a grapheme cluster longer than a cell holds (a 25-byte family emoji) is
  cut between codepoints, not inside one, so the rest of the row is no longer drawn a
  column off.
- `term.input`: a bracketed paste arriving in many reads is searched for its end marker
  once, not again on every read (an 8 MB paste took seconds to decode). A paste past
  1 MiB arrives as several `paste` events in order, so memory stays bounded even when its
  end marker never comes.
- Windows: `Terminal.enterRaw` puts the console modes back when a later step fails,
  instead of leaving the console without echo.
- `term.Pty.deinit` sends `SIGKILL` to the program's process group when it ignores
  `SIGHUP` for a second, instead of waiting for it forever.
- `sys.update.removeLeftovers` also deletes `<exe>.zip`, the archive `termancy update`
  stages next to the executable while unpacking a `.zip` release, which stayed behind when
  the update was cut short.
- `sys.log`: strings inside a struct, list, or optional field value are written as text,
  with known secret values replaced by `[REDACTED]`, in every format. They were written as
  lists of byte values, which the secret scrubbing could not see, so a secret inside one
  (an argument list, a request struct) reached the log readable.
- `sys.dirs` on macOS: a relative `$TMPDIR` no longer makes the runtime directory relative
  to the working directory; `/tmp` is used instead, as `tempDir` already did.
- `sys.files.Store` refuses blob names Windows reads as something else: device names
  (`CON`, `NUL`, `nul.txt`, `COM1`, ...) and names ending in a dot or a space. Writing
  `nul` reported success and kept nothing; `con` wrote the blob to the console.
  `sys.sandbox` refuses device names in Windows paths too (`error.UnsupportedPath`). Both use
  the new `sys.dirs.isWindowsReserved`.
- `sys.update.install` (and so `termancy update`) syncs the new executable to disk before
  renaming it into place, so a crash or power loss right after an update cannot leave an
  empty executable with the rollback copy already removed.
- `sys.signal` on Windows: closing the console, logging off, or shutting down now waits
  for the program to clean up and call `uninstall` (up to Windows' own timeout, 5 seconds
  by default for a closed console). Windows ends the process as soon as the handler
  returns, so the program never saw the termination before and its cleanup did not run.
- `sys.signal`: a second `SIGHUP` before `reset` (a reload asked for twice) no longer ends
  the process; only interrupt, termination, and quit fall back to the default action on a
  second signal.
- `sys.ssh.Server.serve` and `sys.web.Server.serve` (and so `termancy serve`) keep serving
  when an accept fails for one connection (the peer hung up first) or for want of file
  descriptors (they wait 100 ms and accept again), instead of returning and ending every
  open session. A peer opening many idle connections could stop the server.
- termancy puts the terminal back (raw mode off, main screen, cursor shown) before printing
  a panic, instead of leaving it as a full-screen command had it.
- A tui program whose first frame fails, or that switched to the alternate screen or turned
  the mouse on with a command and then fails, turns those modes off again on the way out.
- A tui program ends on `SIGTERM` or `SIGHUP` as on Ctrl-C, restoring the terminal, instead
  of being killed with it in raw mode.
- Turning the mouse off also ends every-movement reporting (`?1003`), which
  `Cmd.mouse(.motion)` turns on.
- A tui program resized again before the terminal said where its cursor went no longer
  learns the wrong thing about whether it rewraps lines, and an answer that comes after the
  wait no longer reaches the model as a `.report`.
- The terminal's cursor (`Model.cursor`) sits on the right row below a line that starts
  with a tab and wraps.
- `focus.Grid.move` no longer panics when `count` shrank below the focused part.
- Messages posted from other threads are drawn in one frame per batch, not one each.
- After a message is posted from another thread, a tui program no longer wakes every 15 ms
  for the rest of its run: `post` wakes it once, through its signal pipe.
- `termancy cfg set`, `unset`, `fmt`, `init --force`, and `edit` keep the file's
  permissions: a `0600` file no longer becomes `0644` when rewritten, and `edit`'s working
  copy is as private as the file it stands for.
- `termancy freeze` no longer crashes on a line wider than 65535 columns (it wraps there),
  and writes its image only once drawn, atomically: a failure (a missing font) leaves the
  file already at `-o` as it was instead of empty.
- `termancy ssh verify --signers` enforces a signer's allowed_signers options as
  `ssh-keygen -Y verify` does: `namespaces=` must take the namespace, `valid-after=` and
  `valid-before=` must hold now, and `cert-authority` or any other option refuses (it used
  to accept the signature as good whatever they said). A matching line that allows the
  signature wins, and the signer is named by its principals.
- `termancy serve` ends a session's program and its output tasks when the client goes or
  the server is canceled, instead of leaving them running. A program run without a
  terminal is sent `SIGHUP` and, if still running a second later, `SIGKILL`; it used to
  get `SIGTERM` and block the session until it obeyed.
- `termancy record capture` refuses a tape that already exists, as `record new` does,
  before starting the shell.
- `termancy update` gives each download 30 minutes instead of 60 seconds, so a large
  archive over a slow link no longer times out; the release lookup keeps 60 seconds.
- `termancy release keygen` links the key into place only once written and synced, so a
  failure leaves no empty key file blocking the next try; `release sign` writes each
  `.sig` atomically.
- `cfg`: an integer setting given a number past 2^53 that was read as a float (JSON, YAML,
  or ZON past the `i64` range: `"id": 10000000000000000001`) is "integer out of range",
  instead of decoding as the nearest float, another number.
- `cfg`: reformatting, sorting, or setting a TOML value keeps a quoted string that reads
  like a date (`released = "2024-01-01"`) quoted, instead of turning it into a TOML date
  for every other reader of the file (`termancy cfg fmt`, `cfg set`).
- `cfg`: expansion adds at most `max_expanded_len` (16 MiB) of text, in a dotenv file
  (`dotenv.max_expanded_len`, a syntax error past it) and through `${key}` references
  (`Config.max_expanded_len`, reported by `checkReferences`). A few hundred bytes that
  double a value line by line used to ask for gigabytes.
- `cfg`: every format reads a file that starts with a UTF-8 byte order mark, as Windows
  editors write, and in-place edits keep it. INI used to read the mark into the first key's
  name, so that key was silently missing; TOML, JSON, JSONC, and dotenv rejected the file.
- `cfg`: an include cycle through another spelling of the same path (`include = "./a.toml"`
  or `"../conf/a.toml"`) is `error.IncludeCycle`, instead of reading the file again until
  the path is too long.
- `cfg`: with references on, a value that takes text from a secret through `${key}`
  (`url = "pg://u:${db.password}@h"`) is redacted by `write` and `snapshot` too, instead of
  printing the secret.
- `term.live`: after the terminal narrows, the next frame starts above the rows the old
  lines rewrapped into, instead of leaving copies of them on the screen. Both it and tui
  programs count one row a line on terminals that cut lines instead, rather than moving up
  over earlier output. A tui program learns which the terminal does from where its cursor
  went after the first narrowing (`CSI ? 6 n`); `Capability.reflows` is the guess before
  then, and for `term.live` and terminals that do not answer (false for xterm, st, and the
  Linux console).
- A tui program redraws as soon as the terminal is resized (on `SIGWINCH`), instead of at
  its next size check, up to 200 ms later.
- macOS: bash completion with more than one word before the cursor (bash 3.2 joined them
  into one), and a lone Esc in a program reading keys from `/dev/tty` (stdin piped), which
  waited for the next key.
- **Windows:** `snek platform update` replaces the running `snek.exe` (it failed renaming
  it aside), and snek deletes the `snek.exe.old` left behind on its next start. The web
  server's request timeout and the SSH server's login timeout fire (a `shutdown` did not
  wake the read they waited on). The Windows Hello dialog appears when asked from Windows
  Terminal or another pseudo console. `snek cli init`'s "next:" hint is two lines, since
  Windows PowerShell 5.1 has no `&&`; `snek tui init` and `add` print `C:\x\build.zig`, not
  `C:\x/build.zig`.
- `snek tui init` works in a subdirectory of a project: it writes `tui.zon` where asked,
  wires the nearest `build.zig` at or above it, and hints only when that applies.
- `tui.testing.Driver`: a model `deinit` of any other signature is a compile error, not
  silently skipped.
- Usage errors are JSON when the arguments ask for `-o json` or `-o jsonl`, as other errors
  were; `snek tui add -q --dry-run` prints only the files it would change, without the
  steps or the "dry run" note; `snek tui add` no longer crashes when the components resolve
  to exactly one.
- `build.zig.zon` said `0.0.0` while snek said `0.1.0`: the version is now written once, in
  `build.zig.zon`, and passed to snek by `build.zig`.
- `snek cli record` prints its failures once, after the progress; `tui serve --web`'s
  plain-HTTP warning, `cfg validate`'s warnings, and `tui demo`'s hint follow `-q` and the
  theme's colors.
- `platform.secure`'s page-range test assumed a 4 KiB page, which aarch64 need not have.
- `ctx.render` text tables line up by display width, not by codepoints.
- `Program.init` copied the model, so `deinit` on the caller's copy freed stale memory (kv,
  lobby, repos, gum, prompts).
- Flow step reports, `ctx.log`, and `ctx.warn` flush standard error, so they show when they
  happen instead of after the command's output.
- `term.live`: a SIGINT, SIGTERM, SIGHUP, or SIGQUIT that ends the process mid-animation no
  longer leaves the cursor hidden (POSIX); signals the program handles itself are left alone.
- The SSH server did not answer a channel close the client sent first.
- `files.Store.read` refused a file of exactly `limit` bytes.
- Crash reports written in the same second overwrote each other; names now carry
  nanoseconds and a suffix on collision.
- `Config.locateDiagnostic` pointed a key set by the environment or a flag at the file
  that set its table.
- `snek tui add --dry-run` printed "created" with no sign that nothing was written; it now
  says so on standard error.
- `snek cfg explain` printed secret values (from encrypted files, `${secret:...}`) in
  clear; it now redacts them as `show` does, with the same `--secret` and `--reveal`.
- A `cli.Flow` asked its questions through `App.asker` even without a terminal; it now
  asks only in an interactive run, as with the default asker, and otherwise keeps the
  values or names the flag to pass.
- The `prompts` component pre-filled a text question with its default, so typing added to
  it; the default now shows as a placeholder and is the answer when nothing is typed.
- A value read under a key `meta.renamed_from` names is reported under that key, so
  `locate` points at the line that holds it rather than at its table.
- JSON Schemas from `cfg.schema` write whole bounds as integers (`"minimum": 1`, not
  `1.0`).

- dotenv: backticks in values are escaped, so sourcing the output cannot run commands.
- Strict decoding (`DecodeOptions.strict`) rejected a key that `meta.renamed_from` still
  reads.
- PowerShell completion of a word typed so far no longer splits it into characters.
- TOML `fmt` no longer takes a `#` inside a quoted header key for a comment.
- TOML: setting a key at the top of a file and then removing it left a blank line where
  it was.
