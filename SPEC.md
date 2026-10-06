# snek — repository layout and module boundaries

**Status:** the target architecture, agreed 2026-10-06. This document is the authority for
where code lives and how imports are spelled. The migration that implements it is tracked
in `ROADMAP.md`; this file describes the destination, not the journey.

## Problem

`snek` grew out of a monorepo that held several applications, and it kept the monorepo's
shape after the extraction: two application folders (`app/cli`, `app/cfg`), three shared
libraries (`lib/cli`, `lib/cfg`, `lib/util`), and four Zig *modules* wired by hand in
`build.zig` (`cli`, `cfg`, `util`, `app_cfg`).

Three costs followed from that.

1. **Two apps where there is one product.** `app/cfg` is not a separate application; it is
   `cfg`'s command group. Because it was modelled as an app it needed its own module
   (`app_cfg`) and its own test root, and the two apps ended up importing each other —
   `app/cli` imports `app_cfg` for the `config` command and `app/cfg` imports `cli`. That
   mutual dependency is why this repository holds both, but it is not a reason for two
   binaries.
2. **`lib/cli` is not one thing.** It carries the command framework, the rendering layer,
   the platform layer, the interactive prompts and the secret handling in a single module.
   A consumer that wants a spinner compiles and links all of it, and the module name says
   nothing about what is inside.
3. **Module boundaries were load-bearing for tests, not for reuse.** `refAllDecls` is
   shallow, so each module needed a hand-maintained root that reached its own tests. Adding
   a test rarely means editing `build.zig`, but adding a *module* does, and the boundaries
   did not correspond to anything a consumer wanted.

## Solution

One application, one command tree, and a `src/lib` of independently usable modules.

```text
build.zig              One build root
build/targets.zig      Target policy and test-root plumbing
src/
  app/
    main.zig           The only executable entry point: `pub fn main` and nothing else
    root.zig           The app's module root: the `App` alias, the command set, its tests
    cmd/               One file per subcommand
    lib/               App-private modules, imported directly by the files that need them
      ops/             Configuration operations, framework-free
  lib/                 Independently usable modules, each with a root.zig and its own tests
    framework/         The command framework: routing, flags, help, execution
    render/            Style, color, tables, layout, TUI, capability detection
    platform/          OS services: files, paths, processes, signals, crash, update
    interact/          Interactive prompts and terminal input
    secrets/           Secret values and locked memory
    cfg/               Configuration model, formats, merging, encryption
    util/              Domain-agnostic primitives
  test/
    root.zig           Cross-module behavioural suite (one test root for the whole surface)
```

## One Zig constraint that shapes the layout, measured

A Zig module root may only import files **inside the module's path**, and the app is built as
a module. Three probes, not reasoning:

| Arrangement | Result |
|---|---|
| `framework/root.zig` importing `../cfg/root.zig` | **rejected** — `import of file outside module path` |
| the same importing `@import("cfg")`, declared with `-M` | works |
| `src/app/main.zig` importing `../lib/...` | **rejected** |

Two consequences decide the layout, and both were chosen by the owner rather than inferred:

1. **Library modules import each other by name** (`@import("cfg")`, `@import("render")`),
   through the import tables in `build.zig`. This is the only mechanism Zig offers across a
   module boundary, it is what the code already did, and it is what keeps each module
   independently testable (REQ-LAYOUT-003). "The app imports its own lib files directly"
   therefore applies to `src/app/lib/ops`, which is app-private and has no boundary of its
   own (REQ-LAYOUT-007).
2. **The app module's root is `src/root.zig`**, not `src/app/main.zig`. Only a root above both
   `app/` and `lib/` can reach the library at all. `pub fn main` consequently lives in the
   root file and delegates to `src/app/main.zig`, which holds the boot sequence.

A third finding, recorded because it is a silent failure rather than an error: a bare
`zig test` on a file whose root names an undeclared module reports **`All 0 tests passed`**.
An under-collected suite looks like a small suite.

## Import spelling

Library-to-library and app-to-library imports are **by module name**; everything else is a
relative path, because it stays inside one module.

```zig
// in src/lib/interact/prompt.zig - another module, so by name
const render = @import("render");
const tea = render.tea;

// in src/app/cmd/config/root.zig - app-private, so by relative path
const ops = @import("../../lib/ops/root.zig");

// in src/root.zig - the app's own command tree, relative
const app = @import("app/main.zig");
```

`@import("cli")` and `@import("app_cfg")` no longer exist. `@import("cfg")`,
`@import("util")`, `@import("render")`, `@import("platform")`, `@import("secrets")`,
`@import("interact")` and `@import("framework")` are the module names, and `build.zig` is
where the graph that makes them resolvable is declared.

## Requirements

**REQ-LAYOUT-001** — All source lives under `src/`. There is no `app/` or `lib/` at the
repository root.

**REQ-LAYOUT-002** — `src/lib/<module>/root.zig` exists for every module in `src/lib`, is
the module's public surface, and collects that module's tests.

**REQ-LAYOUT-003** — Each `src/lib/<module>` is independently usable: it may be compiled
and tested on its own (`zig test src/lib/<module>/root.zig`, or through its own build test
root), and it imports only `std`, its own files, or modules declared as its dependencies.

**REQ-LAYOUT-004** — The application is one binary, `snek`, built from `src/app/main.zig`.
There is no second executable.

**REQ-LAYOUT-005** — The application's command tree includes every command that previously
belonged to `cfg`: configuration inspection, export, dry-run, schema, profiles, secrets,
cast, keys, get, mutate. They are subcommands of `snek`, not a separate program.

**REQ-LAYOUT-006** — `app_cfg` is not a module. The configuration command group and its
operations are files inside `src/app`, imported by the files that use them through relative
paths.

**REQ-LAYOUT-007** — `app/lib` does not require a root re-exporting everything in it. Files
in `src/app` import another app-private file by its own path.

**REQ-LAYOUT-008** — The dependency graph is acyclic and points one way: `app` → any
`lib` module; `framework` → `render`, `platform`, `interact`, `secrets`, `cfg`, `util`;
`interact` → `render`, `platform`; `secrets` → `cfg`; `render`, `platform`, `cfg`, `util`
→ `std` only (plus `util`, which has no siblings).

**REQ-LAYOUT-009** — Every existing test still runs. `zig build test` reports no fewer tests
than before the migration, and the *skipped* count is unchanged.

**REQ-LAYOUT-010** — Each `src/lib/<module>/root.zig` ends in an aggregate
`test { refAllDecls(@This()); }` (or `refAllDeclsRecursive`) so that adding a test never
means editing `build.zig`.

## Import spelling

Because the app is a module whose root is `src/app/root.zig`, and each lib module has its
own root, imports are spelled by *file*, not by module name:

```zig
// in src/app/cmd/init.zig - the app-private lib, imported directly (REQ-LAYOUT-007)
const ops = @import("../lib/ops/root.zig");

// in src/app/root.zig - a shared module, reached by relative path from the app root
const cli = @import("../lib/framework/root.zig");
const render = @import("../lib/render/root.zig");

// in src/lib/interact/prompt.zig - a sibling module, reached through its own root
const render = @import("../render/root.zig");
```

`@import("cli")`, `@import("cfg")`, `@import("util")` and `@import("app_cfg")` no longer
exist anywhere.

**Why not `.imports` on the app module?** A module's import table is for *packages* that
cannot be reached by path. Everything here is in one package, so a relative path is the
direct spelling a reader can follow to the file; a table adds a name that has to be looked
up. The library modules keep their own `root.zig` because REQ-LAYOUT-003 needs them
independently testable, not because the app needs a name for them.

## Invariants

* The dependency graph is acyclic. `util` depends on nothing in the tree; `cfg` depends on
  `util`; `render` and `platform` on `util` (`platform` also on `render`, for escape-sequence
  capability detection); `secrets` on `cfg` and `util`; `interact` on `render`, `platform`
  and `util`; `framework` on all of them; `app` on all of them. This is the inversion of
  today's `lib/cli` blob, which is why the split is worth the churn.
* No file imports another module's internals: a cross-module import names the module
  (`@import("render")`), never a file inside it.
* `src/root.zig` holds the only `pub fn main`; `src/app/main.zig` holds the boot sequence it
  calls, and no second entry point exists.

## Non-goals

* **Not a rewrite.** Every behaviour, error message and test assertion moved unchanged. Where
  a move changed a count, the count is recorded rather than smoothed over.
* **Not a re-split of `lib/cfg`.** It became `src/lib/cfg` as-is; its internal shape was
  already organized.
* **No new module boundaries inside a module.** Splitting `framework`'s 11k-line `cli.zig`
  is `ROADMAP.md` S-1/S-3 and stays open; this spec only decides where the file lives.
* **Not a rename of the framework.** `cli.zig` keeps its name inside `framework/`.
* **No behavioural change to the module split.** The split is justified by REQ-LAYOUT-003
  and REQ-LAYOUT-008; it does not add features, and a module that turns out to be empty
  should be deleted rather than kept for symmetry.

## Acceptance criteria

- [ ] `src/` holds all source; no root-level `app/` or `lib/`
- [ ] `src/lib/{framework,render,platform,interact,secrets,cfg,util}/root.zig` each exist and
      collect their own tests
- [ ] `zig test src/lib/<module>/root.zig` passes for every module, with no `-M` dependency
      flags for in-tree modules
- [ ] `zig build` produces exactly one executable, `zig-out/bin/snek`
- [ ] `snek --help` lists `config`, `add`, `init`, `repl`, `update`
- [ ] No occurrence of `@import("cli")`, `@import("cfg")`, `@import("util")` or
      `@import("app_cfg")` remains
- [ ] `zig build test` total is ≥ the pre-migration total, with the same skipped count
- [ ] `zig build test-direct`, `zig build test-linux-compile`, `zig fmt --check` all pass
- [ ] The Linux suite, run under WSL, passes

## Risks

**RISK-LAYOUT-1 (high) — the app's `App` alias and command set cross every lib boundary.**
`src/app/cmd/*` constructs `App.Command`s, and `framework` must not depend on `app`. The
alias lives in `src/app/root.zig` and is passed *down* into `lib/framework` generically,
which is already how `App(StateT, config)` works. The migration must not introduce a
backwards edge here.

**RISK-LAYOUT-2 (high) — the aggregate test root.** `lib/cli/test/cli_test.zig` reaches into
every part of today's `lib/cli` and asserts cross-module behaviour. After the split it spans
six modules, so it cannot live inside any one of them. It moves to `src/test/root.zig`,
which imports the modules it exercises. Its 151 tests are the safety net for the whole
migration; if they stop being collected, the migration has no evidence.

**RISK-LAYOUT-3 (medium) — `refAllDecls` reachability.** Test collection depends on each root
naming what it re-exports. A module whose root forgets a subdirectory silently loses tests
without failing the build. Mitigation: compare the test count before and after each phase.

## Open questions

* Should `snek` install a `cfg` alias or symlink for muscle memory from the two-binary era?
  Decided **no** for now: REQ-LAYOUT-004 says one binary, and an alias is a compatibility
  surface with no user yet at v0.1.0.
