# snek

One command-line application, built on seven independently usable Zig modules.

This repository was extracted from the **upstream `snek` monorepo**, where these subsystems
lived under `src/zig`. It is now a single app with a single binary and a `src/lib` of modules
that can each be used and tested on their own. The two share a name, so where the distinction
matters this README says "the upstream monorepo" and "this repository": the dependency
direction is the point, and the name cannot carry it.

## Layout

```text
build.zig            One build root for the whole repository
build/targets.zig    Target policy and the test-root plumbing
build/import_lint.zig  The `zig build lint` scanner
src/
  root.zig           The module root, and the only `pub fn main`
  app/               The application: main.zig, cmd/, and its own lib/
    cmd/             One file per subcommand; config/ holds the config group
    lib/ops/         App-private operations, imported directly by the files that need them
  lib/               Independently usable modules, one per concern:
    framework          routing, flags, help, execution, the REPL
    render             style, colour, tables, layout, TUI
    platform           files, paths, processes, signals, crash, update
    interact           prompts and terminal input
    secrets            secret values and locked memory
    cfg                configuration model, formats, merging, encryption
    util               domain-agnostic primitives
  test/              The cross-module behavioural suite
```

Three things worth knowing before reading the code:

* **`src/root.zig` is the module root, not `src/app/main.zig`.** A Zig module root may only
  import files **inside its own directory**, and the app has to reach `lib/` as well as
  `app/`. Rooting the module at `src/` is what makes that possible; `SPEC.md` records the
  compile probe. `pub fn main` therefore lives there, delegating to `app/main.zig`.
* **Modules import each other by name** (`@import("render")`) because that is the only
  mechanism Zig offers across a module boundary — the relative form is rejected as an
  `import of file outside module path`. Inside one module, file imports are relative paths.
  `build.zig` is the single place the graph is declared.
* **Import paths always use `/`, never `\`.** Zig reads `\c` as an invalid escape, so a
  Windows separator is a compile error pointing at the wrong place. `zig build lint` checks
  it, and `AGENTS.md` §1.2 records why.

## Building

```sh
zig build                          # installs `snek` into zig-out/bin
zig build test                     # source lint, then every unit test
zig build test-direct              # the same tests, as direct child processes
zig build lint                     # only the source lint
zig build test-linux-compile       # compile every root for the shipping target
```

One executable, `snek`, with `config`, `add`, `init`, `repl` and `update` as subcommands.

## Status

`SPEC.md` is the authority for the layout and the module boundaries. `MIGRATION.md` records the
migration to it — including the one coverage gap it caused, and how that was found. Open work
on the framework itself is in `src/lib/framework/ROADMAP.md`.

Those documents link to paths in the upstream monorepo (`app/bus`, `app/kvs`, `app/scp`)
which do not exist here; `ROADMAP.md` section 0.4 lists them. Their relative links are stale,
their content is the design history, and it is kept because it explains why the libraries are
shaped as they are.
