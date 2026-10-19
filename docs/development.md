# Development

How the repository is laid out, built, and tested, and the principles behind the libraries.
How to send a change is in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Layout

```text
src/cli/  src/cfg/  src/term/  src/tui/  src/sys/   the libraries (each a module with root.zig)
src/main.zig                                  termancy: main and the top-level command tree
src/cmd/<group>/main.zig                      one directory per termancy command group
src/cmd/tui/registry/                         the tui components termancy copies into projects
test/                                         end-to-end and compile-error cases, fixtures
examples/                                     small runnable apps, run by zig build test
tools/                                        the documentation site generator, Unicode tables
docs/                                         these pages
```

`backup/` holds the earlier implementation, kept for reference only; nothing builds it.

## Build steps

| command | |
|---|---|
| `zig build` | builds `zig-out/bin/termancy` |
| `zig build test` | everything below except `check` |
| `zig build unit` | unit tests of every library and of `termancy`, leak-checked |
| `zig build e2e` | runs the `termancy` binary and compares its output, including live bash, zsh, fish, and PowerShell completion, `tui` widgets driven through a pseudo-terminal, and generated projects built with `zig build` |
| `zig build compile-errors` | checks that misuse of `cli.command` and bad `.zon` defaults are compile errors with the promised message |
| `zig build examples` | builds, tests, and runs the apps in `examples/` (part of `test`) |
| `zig build check` | compiles everything for Linux, macOS, and Windows, and `cli`/`cfg` for WASI |
| `zig build coverage` | line coverage of the unit tests with kcov, into `zig-out/coverage` |
| `zig build fuzz --fuzz` | coverage-guided fuzzing of every parser of untrusted input: `cfg`'s formats, SSH keys, signatures, and transport, CBOR, escape sequences and the input decoder, Markdown, PNG, GIF, and JPEG, TrueType, highlighting, regexes, and tapes (`--fuzz=200K` stops) |
| `zig build budget` | the smallest `cli`, `cfg`, and `tui` apps (ReleaseSmall, stripped) against size budgets, and `--help`'s startup time |
| `zig build docs` | the libraries' API reference and termancy's command reference, into `zig-out/docs` |
| `zig build site` | the documentation site, into `zig-out/site`: the guide, a page per library, the component gallery, the command and API reference (`zig build site-gifs` also records each component's GIF from `docs/tapes`) |
| `zig build console` | `cli`'s Windows console code under a pseudo console (on Windows, or WSL) |
| `zig build bench` | times `cfg` parsing, writing, merging, and decoding |
| `zig build fmt` | formats the sources |

On WSL with the repository on a Windows drive (`/mnt/c/...`), Zig cannot rename files in its
local cache there (`AccessDenied`). Keep the cache on the Linux filesystem:
`zig build test --cache-dir ~/.cache/zig-termancy` (or set `ZIG_LOCAL_CACHE_DIR`).

## Fuzzing

Parsers are fuzzed with seeded generators: random trees must round-trip through every `cfg`
format, and random or mutated input must parse or fail with a positioned error, never crash
(`src/cfg/fuzz.zig`); in-place edits of random documents must decline or read back exactly as
intended. The same holds for `tui`'s input decoder, `cli`'s shell-style tokenizer, and
everything in `src/term/fuzz.zig` and `src/sys/fuzz.zig`.

Each parser is also a target for Zig's coverage-guided fuzzer; its seed corpus, and every
input that once broke a parser, run with the unit tests.

## Continuous integration

`.github/workflows/ci.yml` runs `zig build test` on Linux, macOS, and Windows (x86_64 and
ARM64), with coverage and a bounded fuzzing run. `release.yml` publishes signed archives and
manifests for a version tag, and `site.yml` the documentation site (`zig build site-gifs`) to
GitHub Pages.

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
  so leaks fail the suite.
