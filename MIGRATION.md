# Migration plan — one app, `src/`, split modules

Implements `SPEC.md` (REQ-LAYOUT-001…010). Phased so `zig build test` is green at the end of
every phase; the test count is the instrument (baseline **598/599**, 1 skipped).

## STATUS — mid-migration, the tree does not build yet

**Landed (file moves only, staged):** every source file is now under `src/`, with no
root-level `app/` or `lib/` (REQ-LAYOUT-001). Seven library modules exist with roots, and
`src/lib/util` + `src/lib/cfg` **already build and test independently** (32 and 125 passing).

**Still to do, in order** — the tree cannot compile until step 1 and 2 are complete:

1. **`build.zig` module graph.** The file still names the old paths
   (`lib/util/root.zig`, `lib/cfg/root.zig`, `lib/cli/root.zig`, `app/cfg/root.zig`,
   `app/cli/root.zig`, `app/cfg/main.zig`, `app/cli/main.zig`) and the `app_cfg` module.
   Replace with the seven library modules plus one app module, per REQ-LAYOUT-008 layering:
   `framework` imports all six; `interact` imports `render`, `platform`, `secrets`;
   `secrets` imports `cfg`, `util`; `platform`/`render` import `util`; `cfg` imports `util`.
   Drop the `cfg` executable and `app_cfg` (REQ-LAYOUT-004/006). The app module's root is
   **`src/root.zig`** and its source file is `src/app/main.zig`.
2. **App imports.** `src/app/**: `@import("cli")` → `@import("framework")`;
   `@import("app_cfg")` → the relative paths now in `src/app/cmd/config/` and
   `src/app/lib/ops/`; and in the config command files `@import("fields.zig")` →
   `@import("../lib/ops/fields.zig")`.
3. **`src/root.zig`.** It delegates `pub fn main` to `app/main.zig`, but `app/main.zig`
   still contains `pub fn main` itself — one of the two must go, and the module root cannot
   export a second `main`. Keep `pub fn main` in `src/root.zig` and rename the app's body.
4. **`src/test/root.zig`** (RISK-LAYOUT-2) — the migrated `cli_test.zig` still imports
   `../cli.zig` and needs the new module names. Its 151 tests are the safety net.
5. **Documentation** — `src/lib/framework/ROADMAP.md` and `RECONSTRUCTION.md`, `README.md`,
   `build.zig`'s header and `AGENTS.md` still describe the old paths (74 references under
   `src/`).

**Verified so far:** `zig test src/lib/util/root.zig` → 32 pass;
`zig test src/lib/cfg/root.zig` → 125 pass. Those two have no in-tree module dependencies, so
they test without the build file — which is why they were the ones to check first.

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
