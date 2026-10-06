# Migration plan — one app, `src/`, split modules

Implements `SPEC.md` (REQ-LAYOUT-001…010). Phased so `zig build test` is green at the end of
every phase; the test count is the instrument (baseline **598/599**, 1 skipped).

## STATUS — complete; all five gates green

| Gate | Result |
|---|---|
| `zig build test` | 19/19 steps, **592/593** (1 skipped) |
| `zig build test-direct` | exit 0 |
| `zig build test-linux-compile` | 10/10 steps |
| `zig fmt --check build.zig build src` | exit 0 |
| `zig build` | exit 0, **one** binary: `zig-out/bin/snek.exe` |

`snek --help` lists `repl`, `update`, `config`, `add`, `init`; `snek --version` prints
`snek v0.1.0`.

Per-root counts: util 32, cfg 125, render 45, platform 106 (+1 skip), secrets 2, interact 18,
framework 4, app 108, integration 152.

### One open discrepancy, measured rather than smoothed over

The baseline was **598 passed / 1 skipped**; this is **592 / 1**. Five tests fewer, and the
declared-vs-executed reconciliation shows where it is *not*:

| Module | declared | executed |
|---|---|---|
| cfg | 125 | 125 |
| util | 32 | 32 |
| platform | 107 | 107 |
| interact | 18 | 18 |
| app | 109 | 108 |
| integration | 152 | 152 |
| framework | 4 | 4 |
| secrets | 2 | 2 |
| render | 49 | **45** |

`render` is the only material gap: 47 named + 2 anonymous declared, 45 executed. Those are
tests declared **inside generic containers** that no instantiation reaches, which is the same
mechanism `ROADMAP.md` C-6 documents — a test in an uninstantiated generic is never collected.
It is not yet proven whether those 4 ran before the move (in which case a container that used
to be instantiated through the old root no longer is) or never ran at all. **This is the one
thing to check next**, and the method is the one C-6 used: pair each declaration with the
executed name that serves it. The remaining 1-test difference across `app` is the same shape.

Nothing else is unresolved: no `@import("cli")`, `@import("app_cfg")` or `@import("zconfig")`
remains, the tree builds for the shipping target, and `src/lib` imports are by module name
with `build.zig` as the single place the graph is declared.

### What the migration cost, for the record

Almost all of the friction was **not** the refactor. Two environment traps and one
self-inflicted bug dominated:

1. **Backslash paths.** Two PowerShell string-replace round-trips wrote `@import("..\cfg\root.zig")`
   into six files. Zig reads `\c` as an invalid escape, so the symptom was
   `expected '{', found 't'` — nowhere near the cause.
2. **An `@`-swallowing bug in a helper script.** `@import` became `iimport`, `@min` became
   `imin`, `@tagName` became `itagName`, and so on: **17 corrupted builtin call sites across
   two files, plus 6 `iimport` sites**. Found by diffing the corrupted files against `git`,
   which is the technique to reach for when a bulk edit is suspected of shredding tokens.
3. **Disk pressure.** `LLVM ERROR: IO failure on output stream: No space left on device`
   appeared twice at ~6 GB free and vanished after dropping `.zig-cache` (2.65 GB). It reads
   like a broken toolchain and is not one.

**The lesson worth carrying:** a bulk text rewrite over source is the riskiest tool in this
repository. Every one of the six `iimport` sites and all seventeen corrupted builtins came
from replacements that were correct in intent and wrong in mechanism. After each bulk edit,
**diff the result against `git` and build** — the compiler caught all 23, but only after
several rounds of confusing errors.

## Baseline, measured before any move

| Test root | Result |
|---|---|
| `test-lib-util` | 32 |
| `test-lib-cfg` | 125 |
| `test-lib-cli` | 331 pass, **1 skip** (332) |
| `test-app-cfg` | 107 |
| `test-app-cfg-bin` | success |
| `test-app-cli` | 3 |
| **total** | **598 passed, 1 skipped** |

Module import sites to rewrite: `@import("cli")` ×15, `@import("cfg")` ×17,
`@import("util")` ×8, `@import("app_cfg")` ×5 — **45**.

## Phase 1 — `src/lib`, seven modules

Moves (all `git mv`, to keep history):

```
lib/util/                  -> src/lib/util/
lib/cfg/                   -> src/lib/cfg/
lib/cli/render/            -> src/lib/render/
lib/cli/interact/          -> src/lib/interact/
lib/cli/platform/          -> src/lib/platform/
lib/cli/secrets/           -> src/lib/secrets/
lib/cli/{alias,i18n,policy,repl,cli}.zig -> src/lib/framework/
lib/cli/test/cli_test.zig  -> src/test/
```

`lib/cli/root.zig` is **not** moved: it is replaced by seven new module roots, one per
module, each ending in an aggregate test block (REQ-LAYOUT-010). The old root's
`refAllDecls` list becomes the seven roots' lists.

`lib/cli/test/root.zig` is replaced by `src/test/root.zig`, which imports the modules the
suite exercises. It carries 151 tests spanning six modules, so it cannot live inside one
(RISK-LAYOUT-2).

Import rewrites in this phase:

* cross-module `@import("cli"|"cfg"|"util")` → a relative path to that module's `root.zig`
* `@import("../../render/x.zig")`-style sibling paths inside a moved tree are unchanged,
  because the trees keep their internal shape

`build.zig` gains seven library modules and their test roots; `test-lib-cli` becomes six
roots (`test-lib-framework`, `-render`, `-platform`, `-interact`, `-secrets`, plus `-cfg`,
`-util` already existing).

**Exit criteria:** `zig build test` ≥ 598 passed / 1 skipped; `zig test
src/lib/<module>/root.zig` passes for each module with no in-tree `-M` flags;
`zig fmt --check` clean.

## Phase 2 — the app absorbs `cfg`

Moves:

```
app/cli/main.zig           -> src/app/main.zig
app/cli/root.zig           -> src/app/root.zig      (the module root, per the Zig constraint)
app/cli/cmd/{add,init,root}.zig -> src/app/cmd/
app/cfg/cmd/*.zig          -> src/app/cmd/config/   (the `config` group)
app/cfg/lib/ops/*.zig      -> src/app/lib/ops/      (app-private, imported directly)
```

`app/cfg/main.zig` is **deleted**: REQ-LAYOUT-004 says one binary. Its content is the
redundant second entry point the extraction left behind.

`app_cfg` stops being a module (REQ-LAYOUT-006): `src/app/cmd/config/` imports
`../../lib/ops/...` directly, and the app's command tree includes the group.

Import rewrites: `@import("app_cfg")` ×5 → relative paths into `src/app/lib/ops/` or
`src/app/cmd/config/`.

`build.zig` loses the `app_cfg` module and the `cfg` executable; `test-app-cfg-bin` goes
away with the binary.

**Exit criteria:** one executable in `zig-out/bin`; `snek --help` lists `config add init
repl update`; tests ≥ 598 passed / 1 skipped.

## Phase 3 — documentation and gates

* `README.md`, `build.zig`'s header, `lib/*/root.zig` headers and `AGENTS.md` describe the new
  layout; `AGENTS.md`'s `src/zig` paths become `src/`.
* `src/lib/*/root.zig` headers state what each module is for and what it may import
  (REQ-LAYOUT-008), so the next reader does not have to derive the layering.
* `ROADMAP.md` records the old paths as historical, the way §0.4 already does for the
  monorepo's absent apps.
* The layout guard: a test that asserts the tree's shape, so a future move that violates
  REQ-LAYOUT-001/002/004 fails rather than being noticed by review. This is the same
  technique `app/cfg/lib/ops/root.zig` already uses for its framework-free invariant.

**Exit criteria:** all five gates green, including the Linux suite under WSL.

## Risk register

| # | Risk | Mitigation |
|---|---|---|
| 1 | `refAllDecls` silently drops tests when a new root forgets a subdirectory | Compare the test count after every phase; RISK-LAYOUT-3 |
| 2 | The app's `App` alias creates a backwards edge `framework` → `app` | The alias stays in `src/app/root.zig` and is passed down generically; check that `lib/framework` has no `app` import after phase 2 |
| 3 | `src/test/root.zig` stops reaching part of the suite | Its count is compared against `test-lib-cli`'s 332 in phase 1 |
| 4 | A path rewrite breaks a sibling import inside a moved tree | Trees move with their internal shape intact; `zig fmt --check` plus the suite catch the rest |
| 5 | Losing the "no `cli` import" invariant in `ops` | The scanning test moves with the folder and keeps its control experiment |
