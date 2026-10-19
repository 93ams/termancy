# `cfg`

Layered configuration: TOML, YAML, JSON, ZON, dotenv; defaults, files, profiles, environment,
flags, overrides; decoding into structs; provenance. The role [viper] plays in Go.

[viper]: https://github.com/spf13/viper

- [Value model](#value-model)
- [Formats](#formats)
- [Layers](#layers)
- [Sources](#sources)
- [Reading](#reading)
- [Validation and errors](#validation-and-errors)
- [Writing and editing](#writing-and-editing)
- [Secrets](#secrets)

## Value model

One dynamic tree (`cfg.Value`: null, bool, int, float, string, array, ordered table) addressed
by dotted paths: `servers.0.host`, `a."dotted.key"`.

## Formats

All read and written, with errors at line and column:

| | |
|---|---|
| JSON | full; also streamed from a reader (`json.parseReader`, `Config.loadReader`) |
| JSON with comments | `.jsonc`, `.json5`: `//` and `/* */` comments, trailing commas; written as JSON |
| TOML | 1.0; date-times keep their text, decode into `cfg.DateTime`, and are written back bare |
| YAML | the configuration subset: block and flow collections, quoted, plain, and block scalars over several lines, indentation indicators, comments; anchors and aliases with `parseWith(.{ .aliases = true })`, under a node budget; tags and multiple documents are rejected rather than misread; read from a reader a top-level entry at a time (`yaml.parseReader`, `Config.loadReader`) |
| ZON | everything `@import` of a `.zon` file accepts, parsed by the compiler's own front end; writes zig-fmt output |
| dotenv | `export`, quotes, escapes, `$VAR` / `${VAR}` / `${VAR:-default}`; `A__B` nests as `a.b` |
| INI | `.ini`, `.cfg`, `.conf`: `[section.sub]` headers, `key = value` or `key: value`, `;` and `#` comments; values are text |

## Layers

Highest first:

| layer | set by |
|---|---|
| override | `set` |
| flag | `bindFlags` (skips flags that are not settings) |
| env | `automaticEnv`, `bindEnv` |
| profile | `useProfile`: the `profiles.<name>` table |
| file | `loadFile` and the other [sources](#sources), merged in order |
| default | `setDefault`, `setDefaults` |

Tables merge deeply; anything else replaces. `setMerge(key, .append)` (or `meta.merge =
.append`) makes lists accumulate across sources instead. `explain(key)` names the layer and the
file, variable, or flag behind a value.

Defaults can be checked at compile time: a field the struct doesn't have, or a value of the
wrong type, is a compile error.

```zig
const defaults: Settings = @import("defaults.zon");
try config.setDefaults(defaults);
```

## Sources

| | |
|---|---|
| `loadFile` | one file |
| `loadVariants` | a file, then each of its variants that exists over it: `app.production.toml` and `app.local.toml`, or `.env.local` |
| `loadDir` | a `conf.d` directory in name order |
| `loadSource`, `loadReader` | text already in hand, or a reader |
| `loadFrom` | a `cfg.Config.Source` (a small vtable, so remote stores live in their own modules) |
| `loadAppFile(io, "app", .{ .path, .env }, &diag)` | the `--config` path, the file a variable names, or `config.toml` in the user's configuration directory; a missing file is not an error |

Finding files:

- `findFile` searches directories (with `$VAR` and `~`) for
  `<name>.{toml,yaml,yml,json,zon,env}`; `findFile(.{ .upward = true })` searches the working
  directory and its parents, as git and cosmiconfig do.
- `sys.remote.get` fetches a file over HTTP with an ETag cache that serves the last copy
  offline; `loadSource` it, as `termancy cfg -c https://...` does.

Opt-ins:

- `useIncludes("include")`: files include others, relative to themselves.
- `useReferences`: `${other.key}` in values, with cycles reported.
- `addResolver("name", ...)`: `${name:arg}` in a file calls your function (`${env:HOME}`,
  `${git:branch}`).
- `usePassphrase`: encrypted `.enc` files, from `cfg.encrypted`.
- `ignoreKeyCase`.

Reloading:

- `reload` reads every source again and returns what changed.
- `changed(io)` says whether a loaded file (or one it includes) changed on disk, with one
  `stat` each, for a watch loop that calls `reload`.

## Reading

- `get`, typed getters (`getInt`, `getDuration`, `getStringList`, ...), and `keys`.
- `decode(T)` into a struct, with coercion from text, range checks, and required fields.
  Unknown keys are rejected (`.strict`) or reported as warnings at their file and line with a
  "did you mean" (`.warn_unknown`).
- `view("db")` hands a component its own section: `getString("host")` reads `db.host`, and
  `decode` decodes just that part.
- `Duration` (`1h30m`) and `ByteSize` (`10MiB`) work as config fields and as flag types;
  `Duration.toIo` converts for `std.Io`.
- `cfg.migrate.run` upgrades documents through a list of versioned migrations.
- `glob` matches keys.

Struct `meta` refines decoding:

| meta option | |
|---|---|
| `.secret` | redacted when written |
| `.help` | description, also in the schema |
| `.key` | the key to read, when not the field name |
| `.min`, `.max`, `.one_of`, `.pattern` | constraints |
| `.renamed_from` | the old key still reads, with a warning |
| `.deprecated = "why"` | read, with a warning when set; `deprecated` in the schema too |
| `.merge` | how lists combine across sources |

A struct's `validate` checks rules across fields.

## Validation and errors

Problems point at the file and line that set the key:

```text
app.toml:4:8: server.port: must be at most 65535
```

`Diagnostic.writeSnippet` shows that line with a caret under the value, and `cfg.locate` finds
any key in any format's text. With `Options.errors`, every problem is reported at once.

`cfg.schema.write(T, arena, writer)` emits JSON Schema (draft-07), and `cfg.schema.validate`
checks an untyped tree against one.

## Writing and editing

- `write(writer, format, .{ .layer, .redact })` writes any layer, with secrets redacted by
  default.
- `cfg.edit.apply(arena, format, source, change)` sets or removes one key by changing only the
  bytes it must, so comments and layout survive (every format; YAML in block style).
  `edit.applyAll` applies several.
- `cfg.edit.reformat` formats a file canonically while keeping its comments (TOML, ZON,
  dotenv, YAML).
- Both check that the result reads back as intended, and return null rather than a wrong
  document.
- `cfg.diff(arena, old, new)` lists the leaves that differ.

## Secrets

- `${secret:env:NAME}` and `${secret:file:path}` resolve at load and are marked secret;
  `addSecretProvider` adds more schemes.
- To keep secrets out of swap and core dumps, give the `Config` `sys.secure`'s allocator: memory
  is page-locked and zeroed on free.
