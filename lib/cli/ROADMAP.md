# `lib/cli` — Improvement Roadmap (organization, reusability, maintainability)

Scope: **`src/zig/app/cli/lib/` only.** The repo-wide backlog is
[`ROADMAP.md`](../../../../ROADMAP.md); feature status for the message bus is
[`app/bus/ROADMAP.md`](../../app/bus/ROADMAP.md). This file exists because
`lib/cli` is the one library in the tree that has grown past the point where a
reader can hold it in their head, and it is the only one with **no test run and
no committed history**. Nothing here replaces the other documents.

**Hard constraint, same as the repo-wide roadmap: no capability may be lost.**
Every item is either (a) a pure edit with no behaviour change, (b) a
move/rename proven by the test suite, or (c) explicitly marked as needing a
decision. This document was written because `lib/cli` had **91 tests that passed
but never ran**; item C-1 wired them into the build first, so every item below is
now provable rather than argued — and that act alone is what exposed the
compile-time and memory bugs in §1b and §5.

---

## 0. Baseline — measured on this working tree

Everything below was observed, not recalled. Commands were run from
`src/zig/` with Zig **0.16.0** on Windows.

The "before" column is the state this document was written against; the "now"
column is the state after the four items marked done in §1 landed. Keeping both
is deliberate: the gap between them is the argument for every remaining item.

| Fact | Before | Now |
|---|---|---|
| `lib/cli` size | 64 files, flat, ~11,400 lines | **44 files** in 4 topical groups; config and 11 primitives moved out (U-0) |
| **Tests that actually run** | **0 of 91** — no `cli` step existed in `test-lib` | **250 run**, `test-lib-cli 250 pass (250 total)` |
| `zig build test-lib` | `13/13 steps, 80/80 tests` | **`17/17 steps, 180/180 tests`** |
| `lib/cfg` | 1 file, **does not compile**, imported by nothing | **12 files**, `root.zig`, own test root, tests pass |
| **`zig fmt --check build.zig build lib app`** | **red on 39 files**, 14 under `lib/cli` | **clean, exit 0** |
| `zig build --summary all` | `48/48 steps succeeded` | `48/48 steps succeeded` |
| Files tracked in git | 2 of 64 (`cli.zig`, `config.zig`) | 2 of 65 — **C-3 is still open** |
| `lib/cli` dependency direction | only `std` + siblings; no `anyerror` | unchanged |
| Only consumer | `app/cli/` (the `tigershark` binary) | unchanged |

Evidence for the "before" column, so it can be re-checked: the 91 tests were
confirmed real with `zig test app/cli/lib/cli_test.zig` → `All 91 tests passed`,
while a dependency walk from `cli.zig` reached **63 of 64** files with
`cli_test.zig` the single orphan. The `zig fmt` figure came from
`zig fmt --check build.zig build lib app`.

### 0.1 The five structural problems, in one place

| # | Problem | Cost | Status |
|---|---|---|---|
| 1 | **No test step** | 91 passing tests, ~2,250 lines, provided zero protection. Repo-wide roadmap item **O-13** in its purest form. | **fixed** (C-1) |
| 2 | **No library surface** | `AGENTS.md` requires a library's surface to be `root.zig` or `<module>.zig`. `lib/cli` was neither. | **fixed** (C-1) |
| 3 | **The root was a 63-way god-import** | Every consumer compiled all 11,400 lines to use a few hundred; no way to import one widget. | open (S-4) |
| 4 | **`cli.zig` is two files wearing one name** | Lines 1–64 were a re-export list; 66–171 core types; **173–1936 a single `App` closure** holding `execute`, `parseFlags`, help, output and the REPL. | open (S-1) |
| 5 | **Nothing was in git** | 63 untracked files: no `git blame`, no revert, no review surface. | open (C-3) |

### 0.2 What is already good — do not regress

- **The implementation is real and the tests are good.** All 91 tests pass, and
  they are behavioural rather than smoke tests: onion-middleware ordering,
  `--` end-of-options, `--no-*` negation, `-vvv` cumulative flags, env-var
  binding, `conflicts_with` / `requires`, Levenshtein "did you mean", `OSC 52`
  clipboard, `OSC 8` hyperlinks, `XChaCha20-Poly1305` config encryption,
  `DECSTBM` regions. This is not scaffolding — it is an untested library.
- **`lib/cli` is honestly app-agnostic.** It imports nothing outside `std` and
  itself, which is exactly the property that makes it promotable and reusable.
  `lib/util/root.zig` names it as the model: a documented header comment, one
  flat re-export list, and an aggregate `test` block.
- **`cli.zig`'s comptime design is coherent.** One `App(StateT, config)` closure
  producing a typed command tree; `Flags(T)` merging user flags with
  `GlobalFlags`; `MergeFlags` built on `@Struct`; middleware as an onion. This
  is the reason the library is worth organising rather than rewriting.
- **The repo-wide conventions it should follow already exist**, written down in
  [`src/zig/README.md`](../../README.md) and the build itself: a module root is
  a file with an aggregate `test { refAllDecls(@This()); }` block, so **adding a
  test never means editing a build file.** The mechanism is subtler than the
  convention says, and this session measured the difference — see §5.0.

---

### 0.3 How to read this document's status markers

The markers are part of the document's contract, so they are defined here rather than left
to inference:

| Marker | Means |
|---|---|
| `**[done]**` | A gate, shape or hygiene item that landed. Its body should name the measurement. |
| `**[FIXED, verified]**` | A defect that was fixed **and** whose fix was re-checked independently (a test run in isolation, or a control experiment that fails without the fix). |
| `**[FIXED]**` | Fixed, with less evidence than the above. Treat as weaker. |
| `**[resolved by deletion]**`, `**[superseded by …]**` | The item was answered by removing or replacing its subject, not by doing the work as written. |
| `**[decision recorded]**`, `**[planned — owner action]**` | Not a work item: either a decision already made, or something only the owner can do. |
| *(no marker)* | **Open** — unless the body says otherwise. Several bodies do (B-1 is `done, via N-1`, P-1 and A-1 are largely landed, U-0's tiers 1 and 2 are complete), and that gap between heading and body is exactly what makes a heading-only scan unreliable. |

Two rules follow, and both were learned by getting them wrong in this document:

1. **Prefer the body's measured evidence to the heading's marker.** A heading says what its
   author believed when they wrote it; the body says what was measured. Where they
   disagree, the body wins and the heading is owed an edit.
2. **A "done" without a measurement is not done.** Every fixed item in this session ends
   with a command and its output (a test count, a cross-compile result, or a control
   experiment that fails without the change), because "fixed" on its own is the same class
   of claim as the dead test suite this document opens with — see §5.0.

### 0.4 Applicability — which items can be executed in *this* tree

Measured by path existence, not by reading: several items below name files that **do not
exist here**, and the document is long enough that this wastes a reader's time otherwise.

**Absent, so the item cannot be started in this tree:**

| Path | Item(s) that depend on it |
|---|---|
| `lib/resp` | C-5 (the 9 tests that never run) |
| `app/kvs`, `app/scp`, `app/bus` | A-0's adoption measurements, A-1's remaining migrations, A-1b's reverted bus migration, A-2's bus-vs-`cfg.Manager` decision, and the justification quoted in `app/cfg/lib/ops/root.zig` |
| `src/zig` | every path written in that form (this tree has `lib/` and `app/` at the root) |
| `lib/util/slab.zig` | N-2's "deliberately not done" note |

They are kept rather than deleted because they record *why* the library is shaped as it is
— the ops layer exists, for instance, because a non-CLI consumer needed config management —
but the consumers named are not in this repository. Treat them as design history, not as a
backlog.

**Stale paths inside items that do apply** (corrected here):

* B-4's `app/cli/commands/add.zig` is **`app/cli/cmd/add.zig`**.
* B-4's `prompt.zig` is **`lib/cli/interact/prompt.zig`**.
* B-4's line numbers were from before the file was touched; at the time of writing the
  reader thread is spawned at **`tea.zig:185`** and the line counts are at `:191` and `:228`
  (defect 1 of that item is fixed — see the item itself).
* **B-4 defect 2 is four call sites, not one.** The pattern "create a channel, `defer` its
  `deinit`, hand it to `Program.run` while a reader thread holds it" repeats at
  `lib/cli/interact/prompt.zig:77`, `:155`, `:255` and `:364`. Fixing one fixes a quarter of
  it.

**The rule this subsection exists for:** before starting any item below, confirm its paths
exist (`Test-Path`, or the repository's grep tool over the whole tree). An item whose
subject is absent is either history or written against the other layout — and an audit's
line numbers are a claim like any other, to be re-measured rather than trusted. Both
corrections above were found by exactly that check, and §8.5 records the same lesson
learned the hard way.

---

## 1. C-0 — Correctness and gates (do these first, they are cheap)

The point of this section is that **every later item becomes provable**. Until
C-1 landed, any claim about `lib/cli` was a claim about code that had never
executed under test in this repository — and, as §5.0 shows, mostly code that had
never been compiled either.

### C-1 · `high` · Wire the 91 dead tests into the build · **[done]**

The single highest-value change in this file. `cli_test.zig` passes but is
unreachable, and per the build convention the fix is a module root that reaches
it — **not** a new build.zig entry.

*What landed:*

1. `app/cli/lib/root.zig` added. It is the documented public surface (the framework's
   own declarations plus the 63 sibling modules), and it owns the aggregate test
   block that makes the suite reachable. `cli.zig` keeps its path, so
   `@import("cli.zig")` in the test suite is unchanged.
2. `build.zig`'s `cli_mod` root moved from `app/cli/lib/cli.zig` to
   `app/cli/lib/root.zig`, and a `test-lib-cli` entry joined the `test-lib` step.
3. `root.zig` also carries a **completeness guard**: a comptime test that fails
   the build if `cli.zig` gains a `pub` declaration `root.zig` does not
   re-export. Verified by removing one re-export and observing
   `error: app/cli/lib/root.zig is missing re-exports for: AppError`.

*Measured:* `zig build test-lib` went from `13/13 steps, 80/80 tests` to
**`15/15 steps, 173/173 tests`** (and to `17/17 steps, 180/180` once U-0's
`lib/cfg` root landed), of which `test-lib-cli` is **93** (the 91
original tests, `cli_test`'s own suite, plus the guard).

*Guard:* the regression is silent — deleting the `refAllDecls(suite)` line drops
91 tests and still exits 0. C-4 pins the count so that cannot happen quietly.

*Discovered while doing this, and it matters more than the count:* `cli.zig`'s
`pub const X = @import("<sibling>.zig")` is a **lazy** namespace, so a sibling's
function bodies were analysed only when something instantiated them. Nothing
outside `app/cli` did. Wiring the suite is therefore also what first compiled
most of these 63 files — see §5.0 and §5.1 for what that surfaced.

### C-2 · `high` · Make `zig fmt --check` pass · **[done]**

CI's first step is `zig fmt --check build.zig build lib app`, and it failed on
**39 files**, 14 of them in `lib/cli`. The gate had therefore never been green,
which means every other CI result in this repository was reported by a workflow
whose first step fails.

Two honest options, and the one taken here: **fix all 39**, because a gate that
is disabled "just for now" is the failure mode this repo's roadmap already
documents twice (B-2 path drift, R-10 behind `-Djetstream=true`). Formatting
only — `zig fmt` rewrites whitespace and nothing else.

*What landed:* `zig fmt` over the tree, and `zig fmt --check build.zig build lib app`
now exits 0. Verified after each step with the full suite: `zig build` 48/48,
`test-lib` 173/173, `test-bus-direct` 14/14, `test-scp` 21/21.

*Residual risk to state plainly:* this produces a large whitespace-only diff
across `app/kvs/lib/resp/commands/*`, `app/kvs/*`, `app/cli/*` and `build.zig` that is
unrelated to `lib/cli`. It is mechanical and revertible as one commit; leaving it
broken was worse.

*Note:* `app/cfg/lib/cfg.zig` was among the 39 and was reformatted, but it **still
does not compile** — formatting it does not fix `.Slice`. See §5.1.

### C-3 · `high` · Commit the 63 untracked files · **[done]**

*Landed as one commit, `d5c1d8f`, not the two this item asked for.* The item's
reasoning for splitting - a reviewable "as-found" baseline - assumed the 63 files
were an unreviewed dump. By the time the tree was green, the change was a reviewed
session of features, fixes and a module move, and the formatting fix (C-2) had long
since been folded into the files it touched, so no whitespace-only commit was
recoverable. One commit with a body that names every feature, defect and measurement
is more useful to `git blame` here than an artificial split. The renames
(`lib/cfg_ops/*` to `app/cfg/lib/ops/*`) are `R100`, so they survive as renames.

### C-6 · `medium` · The "one dead test in `lib/`" was an accounting artifact · **[resolved, no defect]**

This item records an investigation rather than a fix, because the finding is that
there was nothing to fix and the number that motivated the search cannot be
reproduced. It exists so the next session does not run the same hour again.

*The claim.* The handover asserted `lib/` declares **479** tests but runs **478**
(util 31 + cfg 124 + cli 323), with `app/` reconciling exactly at 110, and
nominated `render/tea.zig:313` as the place to look.

*What was measured.* Every named declaration in `lib/` executes. The three module
roots were run directly - the only way to see per-test names, since
`zig build test --summary all` does not reprint cached steps - and each declaration
was paired with the executed name that served it, allowing for the
instantiation-qualified prefix a test inside a generic container runs under
(`render.tea.Program(...).test....`). Result: **471 named declarations, 471 executed,
0 missing**, in every module. `tea.zig:313` runs (`323/323`, `...OK`), as does its
`i18n`-style sibling under an instantiation prefix.

*The arithmetic.* 479 does reproduce, exactly: **471 named** declarations (cli 318,
cfg 123, util 30) **+ 8 bare `test { ... }` blocks**. The runner executes **478**:
471 named plus **7** of those 8 blocks. The eight blocks are `lib/cli/root.zig`,
`lib/cli/test/root.zig`, and one in each of `render/`, `interact/`, `secrets/` and
`platform/`, plus one each in the `cfg` and `util` roots. Every one of them is a
collector whose body is nothing but `refAllDecls` calls - there is no test body
anywhere in the eight - so the off-by-one is *which collector the runner names*,
not a test with a body that never runs.

*The one that does not run*, isolated by control experiment: the block in
`lib/cli/test/root.zig`. Adding `_ = 1;` to it leaves the runner at `323/323`, and
so does the same edit to `lib/cli/root.zig`'s. `lib/cli/root.zig` imports
`test/cli_test.zig` directly, so `test/root.zig` is a second entry point nothing
reaches - its own header comment says as much. It is the entire "dead test" in
`lib/`, and it has no body to lose, so nothing is untested.

*And no file is unreachable.* A static check over all 100 `lib/` sources found 60
files declaring tests, none a `root.zig`, and **zero** that no other file imports by
name - so there is no orphaned suite of the kind C-1 found. The reachability risk
that made this worth checking is real; the instance was not. Verdict: **the "one
dead test" is the counting of a body-less aggregator, not a lost test.** If C-4's
pinned numbers are ever updated, count named declarations and executable blocks -
never bare `test {` blocks.

*Numbers are as of the audit.* Later work added tests (B-6's port added one to
`lib/util/trace.zig`, and `render/tea.zig` gained a headless `run` test), so the tree now
reports **592** where this item says 588, and `util`/`cli` declare 32/319 named tests
where it says 30/318. The **479** figure and the aggregator that accounts for the
off-by-one are unchanged - that count is historical and was never a defect.

### C-4 · `medium` · Pin the test count so a lost suite fails loudly · **[done]**

The failure mode C-1 introduces is subtle: if a future edit removes the
`refAllDecls(suite)` line from `root.zig`, or renames a file so it falls out of
the graph, `zig build test-lib` still exits 0 and simply reports fewer tests.
The measured number is the assertion.

*What landed:* `root.zig`'s comment records the measured figures, and the
per-step counts now appear in the `--summary all` output that `scripts/check.ps1`
and CI both print. **`test-lib-cli` = 250, `test-lib` = 502** are the numbers to
watch; any drop is a lost suite, not a passing build.

### C-5 · `low` · `lib/resp` has 9 tests that never run — same bug, different module

Found while measuring C-1, and recorded here rather than fixed here because it is
outside `lib/cli`: `lib/resp` declares 9 test blocks across 4 files
(`resp.zig`, `resp_writer.zig`, `wire.zig`, `commands/*`), and `zig build
test-lib` reports `test-lib-resp success` with **no test count at all** —
`app/kvs/lib/resp/root.zig` is a 6-line re-export with no `test` block, so nothing
references the suite and it is dead in exactly the way `lib/net/tls` was before
repo-wide roadmap item O-10.

*The fix is not quite the one-line `refAllDecls(@This())` this item originally
proposed.* Measured here: `refAllDecls(X)` reaches the declarations of `X` and a
test block only when a declaration in that namespace references it, so the
helper must be applied to a namespace that **directly contains or imports** the
tests. `app/kvs/lib/resp/root.zig` re-exports `resp.zig`, `resp_writer.zig`, `wire.zig`
and `commands/root.zig`, so it needs `refAllDecls` applied to each of those
namespaces (and `commands/root.zig` in turn needs its own) — not one call on
`@This()`. Verify with the control in M-2 rather than by reasoning about the
graph.

---

## 1b. B-0 — Bugs the audits found once C-1 made them visible

These were not discoverable before the test root existed. They outrank every
structural item because three of them are "does not compile" or "crashes", and
one is on the only production path through the library. Full evidence is in §5;
this section is the work order.

### B-1 · `high` · `panic.zig:65` — a crash reporter that cannot compile · **[done, via N-1]**

**Fixed.** The field is now `u64`, matching `getMonotonicMs()`. It was found by
wiring `platform/root.zig` into the module graph, which is the first time
`refAllDecls` reached `writeCrashReport` — see N-3 for why that is the general
lesson and not a coincidence.

`CrashJson.timestamp` is `i64` (`panic.zig:56`) and `getMonotonicMs()` returns
`u64` (`telemetry.zig:4`), so `writeCrashReport` fails with
`expected type 'i64', found 'u64'` the moment anything instantiates it — on every
OS. One cast, and the file starts working.

*Test to add at the same time:* none exists for `writeCrashReport`, which is why
nobody noticed. Write the crash-report path's test **before** the fix and watch
it fail, so the fix is proven rather than assumed.

### B-1b · `medium` · A red build from in-flight work, and how to tell it apart · **[resolved by the parallel worker]**

**This item is kept as a worked example of diagnosis, not as an open bug.** It
records a two-hour window in which `zig build` was red for reasons that had nothing
to do with this roadmap, and the checks that established that.

**What was seen.** After converting `style.zig` and `slab.zig`, `zig build` went
from 48/48 to 45/48:

```
app\kvs\lib\resp\registry.gen.zig:1:1: error: unable to load 'registry.gen.zig': FileNotFound
app\kvs\lib\resp\root.zig:43: note: file imported here
```

**Why it was not mine.** Three checks, in increasing order of directness:

1. `app/kvs/lib/resp/` and `src/zig/tools/` are both **untracked** (`git ls-files` returns
   nothing for either) - mid-flight work that had never been committed.
2. `git stash push -u` - every change from this session set aside, including
   untracked files - and a clean tree failed **identically**:
   `error: process exited with error code 255`, `16/19 steps`.
3. The generator at `tools/resp_codegen/` did not compile either
   (`layout.commandFile` vs `layout.Layout.commandFile` was mid-refactor), and once
   that was unblocked the code it emitted had its own errors
   (`duplicate struct member name 'unsupported'`,
   `local constant 'arg_count' shadows local constant from outer scope`).

**Why the build had been green anyway.** `kvs` was reusing a cached artifact that
still referenced the generated files. They had been missing for a while; only the
conversion of `style.zig`/`slab.zig` invalidated enough of the graph to force `kvs`
to recompile, at which point the absence surfaced. **A green `zig build` is not
evidence that every source file exists** — it is evidence that nothing invalidated
the cached compilation of the targets that do not.

**How it resolved.** `app/kvs` is being built in parallel by another worker, who
completed the codegen. The tree is green again: `zig build` 48/48, `test-lib`
**263/263**.

**The reusable lesson.** When `zig build` goes red immediately after an unrelated
change, `git stash push -u` plus a rebuild is the cheapest way to attribute it. It
takes one command and it distinguishes "I broke it" from "it was already broken and
I stopped hiding it". Two edits made during the misdiagnosis - re-exporting
`Layout`'s members at file scope, and a `Count-Seq` guard in
`scripts/check-encoding.ps1` - were later reverted/kept respectively by the other
worker; neither is load-bearing here.

### B-2 · `high` · `btree_store.zig:32-36` — use-after-free on update · **[FIXED, verified]**

In Zig 0.16 `fetchPutContext` returns the **existing** key pointer and does not
replace it (`std/hash_map.zig:904-914`). `WorkspaceStore.put` frees that pointer
and leaves it in the map, so `get()` hashes freed memory and `deinit` double-frees
it; the freshly duped key also leaks. `cli_test.zig` covers `WorkspaceStore`, but
evidently not its update path — which is the path that breaks.

**Fixed.** The update path now has its own coverage, including
`WorkspaceStore.put and delete leak nothing when each allocation fails`, which fails every
allocation in turn — the test that catches the double-free on `deinit` and the leaked
fresh key. Verified independently: `zig test lib/util/btree_store.zig` → **All 4 tests
passed.**

### B-3 · `high` · `spatial_focus.zig:48` — underflow panic · **[FIXED, verified]**

`SpatialFocusGrid.init(2, 0, true)` followed by `moveLeft()` panics with
`integer overflow` at `self.cur_col = self.cols - 1`. `:44` and `:47` are
unguarded the same way. Either guard the three sites or reject a zero dimension
in `init` — and if you reject it, that is a documented contract, so say so.

**Fixed, and the audit undercounted the sites.** There were **four** unguarded `- 1`
expressions, not three: `:44`, `:47` and `:48` as listed, plus **`:70`** in `moveUp`,
which this item did not name. Each was reproduced as a real `panic: integer overflow`
before the fix (`:47` and `:70` via `init(0, 2, true)`, `:48`/`:44` via `init(2, 0, true)`).
The contract chosen is "a zero dimension is a legal *inert* grid": movement is a no-op
returning `false`, the cursor stays at `(0,0)`, `getIndex` is 0 — documented on `init` and
in the module header, with an `assertCursorInBounds` precondition and a `defer`
postcondition on every movement function. Verified independently:
`zig test lib/cli/render/spatial_focus.zig` → **All 8 tests passed.** The lesson is the
one §8.5 records: an audit is a claim, and the compiler is the arbiter.

### B-4 · `high` · The shipped prompt path mis-renders and can use freed memory · **[FIXED, verified]**

`tea.zig` is the only code in this group a user actually runs, via
`prompt.zig` → `app/cli/commands/add.zig` → the `tigershark` binary. Two defects:

1. `tea.zig:152`/`:189` compute `prev_lines = std.mem.count(u8, view_bytes, "\n")`,
   which is one short for any view ending in a newline — the normal case — so the
   erase loop at `:181-183` emits one too few `\x1b[A\x1b[2K\r` and every
   re-render leaves the previous frame on screen. Demonstrated by running
   `Program.run`.
2. `tea.zig:142` spawns a thread holding `&stdin_ctx`, a `run` local, and never
   joins or stops it; `prompt.zig:78` then deinits the channel queue that thread
   may still push into.

The second is a latent use-after-free on the quit path and needs a shutdown flag
the reader thread observes, not a fix to the deinit order. Both need regression
tests, and both are in a file with *no* tests today — `cli_test.zig` covers
neither `Program.run` nor `prompt`'s cancellation path.

**Status: both defects FIXED, verified.**

*Defect 1 (stale frames) is fixed.* The counting rule now lives in one documented
function, `renderedLineCount`, with the rule written down: one line per newline, plus one
for a final line the view did not terminate, and zero for an empty view (erasing there
would move the cursor over a line this program never wrote). A test pins all four cases,
including the two-line view that the old `std.mem.count` reported as one. This is the
user-visible half: it is what left the previous frame on screen on every re-render.

*Defect 2 (thread lifetime) is fixed, but not the way this item proposed — and the reason
is worth more than the fix.* This item said "a shutdown flag the reader thread observes,
not a fix to the deinit order". The flag is **not implementable in this std**, established
by searching rather than assuming:

* `std.Io.Future.cancel` (`Io.zig:1191`) only places a cancel *request* and then **waits**
  for the operation to finish; the task observes it at its next cancellation point, which
  for a blocked read never arrives.
* `Io.Threaded.waitForCancelWithSignaling` (`Threaded.zig:772`) signals a blocked thread
  only to interrupt a *cancelable syscall*, and that machinery is entered solely through
  `Io.operate`/`async` (`Thread.Status.blocked_canceling`, `Threaded.zig:856`).
* `std.Io.Reader.readVec`/`stream` are not `Io` operations at all — `Reader.zig:23`'s
  VTable has no cancellation hook.
* The one cancelable read path, `Io.File.readStreaming` (`Io/File.zig:474`), is executed
  synchronously by the Threaded backend, and the cancel flag is only observed *after* the
  syscall returns.
* There is no `poll`/`select` over a file descriptor in 0.16 (`Io.Operation` has no poll
  variant), and no timeout applies to a blocking read.

So a stop flag is only observable *between* reads, and joining blocks until a byte arrives
— on the quit path no byte ever does. That is exactly what hung the first attempt at this
item, whose tests drove the real `Program.run`.

The rule actually adopted is the opposite one, documented on `StdinContext`: **the reader
thread owns nothing its spawner can free.** `Program.run` allocates the reader context
*and* the channel from `std.heap.page_allocator` in a new `startReader(allocator, io, in)`,
and never frees or joins them; `Program.init` no longer *takes* a channel, so a caller
cannot own or free one. Nothing is freed while the reader could run, so neither UAF is
reachable. The residual cost is a **deliberate, bounded, documented leak** — one context
plus one channel per prompt, in a process that exits as soon as the prompt's command
returns. That is a real cost, recorded here rather than hidden: if a future std gains a
pollable stdin, "stop it" becomes available and the leak can go.

All four call sites are updated uniformly (`prompt.zig`'s `confirm`, `select`,
`multiSelect`, `multiSelectDynamic` — the stack channel and its `defer channel.deinit()`
are gone), and the change is **170 insertions / 32 deletions across two files**, of which
37/2 is defect 1. The test injects a finite source (`std.Io.Reader.fixed` over a one-byte
slice), joins after deterministic EOF, and asserts zero leaks under
`std.testing.allocator` — it caught a real missing `deinit` while being written. It never
calls `Program.run` and never reads a real stdin; the first attempt's hanging test is the
reason.

**Update: `run` itself is now covered, and the method is the generalisable part.** The note
above said the real `run` path "has no regression test (it cannot have one without a
thread-capable stdin)". That was wrong in the same way as B-6's "we cannot execute a Linux
binary": the requirement is not a thread-capable stdin, it is a **finite** one. `run` now
has a test that drives the quit path headlessly with `std.Io.Reader.fixed` over a single
`q`, which reaches end of stream, so the reader thread ends on its own and `run` returns.
It asserts the whole path rather than the shape: the byte travels from the source through
the reader thread and the channel into `update`, the `.quit` command is honoured, the final
view is drawn, and the cursor is hidden on entry and restored on exit **in that order**.
Nothing blocks, so nothing can hang `zig build test` — the constraint the first attempt
paid for.

*Measuring the leak is done, and it took the allocator seam rather than a pollable stdin.*
The note above said the leak was "reasoned and structural, not observed", and that measuring
it needed `Program.init` to take an allocator. That is what happened:

* `Program` gained an `allocator` field. `init` keeps the process-lifetime
  `std.heap.page_allocator` (named `default_allocator`), and a new `initWithAllocator` takes
  one explicitly - so production is unchanged and a test can pass `std.testing.allocator`.
  `run` no longer hardcodes the allocator; it records the `Reader` on the program so the
  caller can reach it later.
* `Program.deinit` is the new half of the ownership rule: **join the reader, then free**.
  It is a no-op when `run` never started a reader, and idempotent, because a caller `defer`s
  it unconditionally. Production still does not call it - the thread is normally blocked in
  a stdin read that no byte will end, so joining would hang - but a caller with a finite
  source can, and that is what makes the two allocations recoverable.

**Measured by control experiment, not inferred.** With the `defer prog.deinit()` removed from
the `run` test, `std.testing.allocator` fails the suite with
`2 tests leaked memory`, naming each address and the three allocation sites -
`startReader`'s context, `startReader`'s channel, and the queue storage that
`Channel.push` grows. With the `defer` restored, all 594 pass. So the leak is now a
number with a failing control behind it rather than a paragraph: one context, one channel and
one queue-buffer per prompt that is never joined.

*What this does not change:* the shipped prompt path still leaks, deliberately, for the
reason in `StdinContext` - `prompt.zig` uses the default allocator and never joins. What
changed is that the claim is now testable, and a future `Program` that forgets to release
will be caught by the same `testing.allocator` the day someone drives it with a finite
source.

*Two traps found while adding these tests, both cost time and neither is obvious.*

1. **A test inside a generic is collected once per instantiation, and the body sees the
   *ambient* generic's parameters, not the ones it names.** The `run` test initially drove
   `Program(QuitModel, void)` while being *collected* under
   `Program(prompt.confirm's Model, void)`, whose model does not quit on `q` - so `run` never
   returned and the suite **hung** rather than failing. A hang is the wrong failure mode for
   a guard: it takes the whole suite with it. The rule that follows is to make such a body
   work for whichever model it is collected under, or to construct the inner `Program`
   explicitly so its model is not in question. The second test does the latter.
2. **The prompt's model has required fields**, so a generic test cannot construct a value of
   `ModelT` to drive a quit - which is why the two tests here assert against `QuitModel`
   (constructed explicitly) or against properties that hold for any model, and never against
   `ModelT{}`.

*A compiler bug found on the way, worth one line for the next person:* declaring the test's
model as a `struct` with methods **inside a test that is itself inside a generic** made the
compiler exit `error: OutOfMemory` — reproducibly, and with 5 GB of free RAM. Moving the
same type to file scope fixed it. That is why `QuitModel` is a `pub` file-scope type even
though only that one test uses it.

*And one cost worth knowing:* tests inside a generic container are collected **per
instantiation**. `Program(QuitModel, void)` runs the reader-thread test *and* the new `run`
test, because both are declared inside `Program`. Adding a second model type therefore adds
more than one test, and `test-lib-cli` moved 323 → 326 rather than 324.

### B-5 · `medium` · `version.zig:51,59` are stale `std` APIs · **[resolved by deletion]**

The file is gone, and the finding is recorded here because deleting it was the fix.

`version.zig` was a background thread that fetched a version string and cached it in
`/tmp/<app>_version_cache.txt`, printing an ANSI notice on exit. Every line used an API
Zig 0.16 removed (`std.Thread.spawn(.{}, …)`, `std.http.Client{ .allocator }` without an
`Io`, `client.open`/`send`/`finish`/`wait`/`reader`, `readAllArrayList`,
`file.readStreaming`, `std.time.milliTimestamp`), and nothing called it: the only surviving
mention was a comment in `app/cli/main.zig` explaining why the call was disabled.
`std.debug.assert`-style "fix the two call sites and re-enable the call" was the plan; the
better answer turned out to be that both halves were replaced outright:

* **the notice** by `App.updateCommand` (§8.4) — a real release registry, tag comparison,
  checksum, optional Ed25519 signature, confirmation before replacing a running binary,
  and an atomic swap, instead of comparing two strings and printing yellow text;
* **the cache** by `platform/state.zig` — XDG-resolved instead of `/tmp`, atomic replace
  instead of a truncating write, and permissions that can be restricted for secrets.

Verified by removal: the flat re-export in `cli.zig` and the surface re-export in
`root.zig` were dropped, `zig build test` stayed green at the same test count, and no
declaration anywhere referenced the module. A non-compiling module whose documented home
is `/tmp` is a trap rather than a feature waiting to be finished — the note left in
`cli.zig` where it used to be says so, so it does not get re-added.

### B-6 · `medium` · The five POSIX/Linux files cannot compile for the shipped target

`build/targets.zig:35-39` makes Linux mean musl, so this is the shipping
configuration. Verified by forcing instantiation:
`sys.zig:32` (`std.posix.geteuid` gone), `sys.zig:77` (`Child.init` gone),
`daemon.zig:57` (`getpid` gone), `daemon.zig:76` (`kill` takes a `SIG` enum, not
`0`), `mmap.zig:85,122` (`std.posix.open`/`close` gone; 0.16 has `openat`),
`telemetry.zig:12` (`clock_gettime` gone).

Fix as one unit — these are the four files with per-OS branches, and they hide
inside generic functions that the Windows host build never instantiates. The
auditor could not execute cross-target binaries, so these are **compile-time**
findings; verify by compiling, not by running.

*Note:* `zig build -Dtarget=x86_64-linux-musl` is already red for unrelated
reasons (`cli.zig:386` references `error.NotATerminal`/`error.ProcessOrphaned`
which are not in `AppError`; `app/scp/crypto/cpace_oquake.zig:24,32`;
`app/bus/client/srv.zig:238`). Getting those green is a prerequisite for making
this item *verifiable*, and is its own task.

**Update, measured later (the session behind §7.5):** the `cli.zig` half of that note
is gone, and the cross-build is **green**: `zig build -Dtarget=x86_64-linux-musl`
with a *fresh* cache directory (so nothing was reused) → **5/5 steps succeeded**,
both `cfg` and `tigershark` compiled for `x86_64-linux-musl`.
`error.NotATerminal`/`error.ProcessOrphaned` no longer appear anywhere in `cli.zig`.
This does **not** clear B-6: the other two paths in the note (`app/scp`, `app/bus`)
are not part of this build's target set, and the per-OS branches in `sys.zig`,
`daemon.zig`, `mmap.zig` and `telemetry.zig` still need the compile-time
verification described above.

**Update, measured later (the session behind §8.5):** two of the four files are fixed, and
the *method* is now proven rather than proposed.

`sys.zig` was fixed by exactly the "force instantiation" technique this item describes:
a throwaway probe that called `System.isElevated()` and took `&System.openEditor` reported
`error: incompatible types: 'os.windows.Bool(c_int)' and 'comptime_int'` at `:21` — a
`win.BOOL` compared against an integer — which had never been compiled because nothing
called it. Both are ported now (`std.os.linux.geteuid`; `std.process.spawn` with
`.expand_arg0`/`.inherit`; `file.readFileAlloc`; `io.random` for the temporary file's name,
which also removed a `platform → util` dependency and a clock read from a platform helper)
and both are **instantiated by tests in `sys.zig`**, so the bodies are analysed on every
`zig build test`. That is the regression gate this item implies but never had.

Still open, and the same treatment applies: `daemon.zig:57,76`, `mmap.zig:85,122`, and
`telemetry.zig:12` (the last may already be gone — that module was rewritten in the same
session, and the line number is from before the rewrite; re-probe before trusting it).
The lesson from `version.zig` (B-5), `crash.zig`'s panic handler and `sys.zig` alike: in
this tree **an uninstantiated body is not a compiling body**, so the fix for each of these
is a test that calls it, not a reading of it.

**Update, measured after re-probing each site (three of them are already gone):**

| Site | Verdict |
|---|---|
| `daemon.zig:57` (`getpid`) | **already fixed** — `std.posix.system.getpid()` |
| `daemon.zig:76` (`kill`) | **already fixed** — `std.posix.kill(@intCast(pid), @enumFromInt(0))` |
| `telemetry.zig:12` (`clock_gettime`) | **already fixed** — the module was rewritten and no longer reads a clock at all |
| `mmap.zig:85` (`std.posix.open`) | **CONFIRMED BROKEN**: `error: root source file struct 'posix' has no member named 'open'` |
| `mmap.zig:122` (`std.posix.close`) | **CONFIRMED BROKEN**: `... has no member named 'close'` |

`mmap.zig` is the whole of B-6's residue, and it needs: `std.posix.open(path, flags, mode)`
→ `std.posix.openat(std.posix.AT.FDCWD, path, flags, mode)` (verified present at
`std/posix.zig:441`), and a replacement for `std.posix.close` — which does **not** exist
under that name in 0.16, so the `close` spelling has to be found before editing (candidates
are the syscall layer `std.posix.system.close` or moving the file onto `std.Io.File`).
`fstat` should be checked at the same time; it is not in the `posix` surface either.

**Update: the port was attempted and deliberately reverted — it is a three-API change, not
a two-API one.** `open` → `openat(AT.FDCWD, …)` and `close` →
`std.posix.system.close(fd)` (the syscall layer, `linux.close` on this target, `std.c.close`
under libc; its result is an error *code* rather than an error union, so the call sites
discard it) both compile — the cross-compile then failed one line later on
`std.posix.fstat`, which **is also gone** and was hidden behind the first two errors. So the
file needs a third spelling that is not in the `posix` surface at all:

* `std.posix.fstatat` does **not** exist either (searched; `posix.zig` has `AT` and `openat`
  but no `fstat`/`fstatat`), so either the syscall layer is used directly
  (`linux.fstat`/`std.c.fstat` with a `Stat` out-parameter and a manual error check), or
* the file moves onto the `Io` API — but `MmapFile.open(path)` takes **no `io`**, so that
  variant changes the signature and every caller, which is a different size of change.

Reverted rather than half-ported: a file that still cannot cross-compile is not an
improvement, and I cannot *run* a Linux binary here to validate the logic afterwards. The
next attempt should start from the three spellings above and finish with the cross-compile,
not the native test.

**The methodological finding is the valuable part, and it generalises to every item in this
section.** I probed `mmap.zig` twice:

* **native (`zig test` on the Windows host) → `All 1 tests passed.`** A false negative: the
  file branches on `builtin.os.tag`, so the Windows branch was analysed and the POSIX one
  never was. A test that *runs* on this host cannot vouch for the other OS's branch.
* **cross-compiled (`zig test -target x86_64-linux-musl`) → both errors, immediately.**

So the rule for this whole section is: **verify a per-OS branch by cross-compiling, never by
running.** That is what this item's original note meant by "verify by compiling, not by
running", and it is why the probe has to target the *shipping* OS. Note also that neither
probe could *execute* a Linux binary, so `mmap.zig` will still need a review of its logic
once it compiles — a cross-compile proves the branch is well-formed, not that it is correct.

### B-6 · **[FIXED, verified — and it was 7 broken sites, not 3]** · with a gate that makes the class non-recurring

The port landed, and the first thing it did was disprove the table above. `mmap.zig` was not
the whole residue, and two of the sites below were found by the compile gate within a minute
of that gate existing.

| Site | Verdict |
|---|---|
| `mmap.zig` `open` | `std.posix.open` → `std.posix.openat(AT.FDCWD, …)` |
| `mmap.zig` `fstat` | **gone**, no `posix` replacement → `statx` with `AT.EMPTY_PATH` |
| `mmap.zig` `close` | **gone** → `std.os.linux.close` (returns an error *code*) |
| `mmap.zig` `PROT.READ` | **not in the B-6 table at all** → `PROT` is a packed struct: `PROT{ .READ = true }` |
| `telemetry.zig` `.block = .global` | **not in the table** → `Environ.Block` is `GlobalBlock` on Windows but `PosixBlock` elsewhere, so the field does not exist on Linux |
| `trace.zig` `clock_gettime` | **the table said "may already be gone"; it was not** → `std.c.clock_gettime` |
| `trace.zig` `.tv_sec`/`.tv_nsec` | **not in the table** → the Linux `timespec` names them `sec`/`nsec`, so the *replacement* line could not have compiled either |

That is **7 broken sites where the audits named 3**, across three files. The
count is the point: the audits read the source, and a file that branches on `builtin.os.tag`
hides its other half from both a Windows test *and* a careful reader. The lesson this
section already stated — an uninstantiated body is not a compiling body — had a corollary
nobody had acted on: **an unread branch is not an audited branch either.**

**The gate.** `build.zig` gained `zig build test-linux-compile`, which compiles every test
root for `x86_64-linux-musl` (linking libc, as the release builds do) and stops: the step
depends on the `Compile` steps, never on a `Run`, so it asserts "this compiles for the
shipping OS" and needs no cross-toolchain to execute. It is deliberately **not** part of
`test`, so a developer without the target is not blocked. It found the `telemetry.zig` and
`trace.zig` sites on its first run.

**Verified by running it, not only compiling it.** The Linux half was believed to be
unrunnable here, and that was wrong for the second time in this item: the repository has WSL
available, and a static musl binary runs there. The suite was built for `x86_64-linux-musl`
with `--test-no-exec` and executed under WSL Ubuntu, and the milestone is now:

| Run | Result |
|---|---|
| No `zig` on WSL's `PATH` | 326 tests — 321 passed, 1 skipped, **4 failed** |
| With zvm's Linux `zig` on `PATH` | 328 tests — **327 passed, 1 skipped, 0 failed** |

*The four failures were the environment, proved by removing the environmental difference.*
`process.zig` and `detach.zig` spawn the string `"zig"` (their own comment says it is
guaranteed present "because the build running this test ships with it"), and WSL Ubuntu had
no `zig` on `PATH` - its `PATH` reaches Windows' `/mnt/c/Users/amsti/.zvm/bin/zig`, which is
a **Windows PE** binary that cannot exec under Linux. Installing zvm inside WSL turned all
four green with no source change, which is the cleanest possible proof that they were never
defects.

*Installing a Linux Zig (`zvm`), for the next person.* `curl https://www.zvm.app/install.sh
| bash` installs zvm itself, but the extracted binary arrives **without the executable bit**
- `chmod +x "$HOME/.zvm/self/zvm"` before the first run. zvm 0.9.1 has no `--skip-use` (the
README documents one the binary rejects); the flag set is `--force`, `--skip-shasum`,
`--zls`, `--full`, `--nomirror`. `zvm install 0.16.0` verifies the shasum and the minisign
signature, which is why it is worth preferring over an unverified tarball.
`~/.zvm/bin` is then on `PATH` via the `# ZVM` block in `~/.bashrc` - but only for
**interactive** shells, and `bash -lc` does not read `.bashrc` on Ubuntu, so a script that
needs `zig` must export the `PATH` itself.

**Confirmed green on Linux:** `OS Primitives: MmapFile zero-copy reading` (the
`openat`/`statx`/`PROT`/`mmap`/`munmap`/`close` path, verified by execution, so the old
logic is not "well-formed but unvalidated" any more), `render.tea.Program(…,void).test.run
reaches its quit path…` (the B-4 addition), and the POSIX branches of `state.zig`, `xdg.zig`,
`signal.zig` and `update.zig`.

*One failure is easy to miss when reading the output*, and did get missed once here, so it is
named: `process.zig`'s "an exceeding output budget…" fails as `expected
error.StreamTooLong, found error.FileNotFound` and prints `FAIL (TestUnexpectedError)` on its
own line, so grepping `...FAIL` finds **3** of the 4. Count failures from the summary line.

To reproduce: `zig test -target x86_64-linux-musl -lc --test-no-exec --dep cfg --dep util
"-Mroot=lib/cli/root.zig" "-Mcfg=lib/cfg/root.zig" "-Mutil=lib/util/root.zig" -femit-bin=<out>`,
then run `<out>` inside WSL with `PATH="$HOME/.zvm/bin:$PATH"`. Note `-target` must precede
the `-M` flags; placed after them it is silently ignored and the host target is built
instead. Two consecutive runs gave identical counts.

**Still open in this item:** the cross-build of the *executables* (`zig build -Dtarget=…`) is
green, but nothing runs `cfg`/`tigershark` on Linux, so a per-OS branch reachable only from
`main.zig` would still be caught by the compile gate alone.


---

## 1c. N-0 — Naming and shape conventions

Two conventions the tree should follow uniformly, plus the measurement of how far
it does.

### N-0 · `cmd/` is the command-folder name · **[done]**

`app/cli` was the odd one out. `app/bus/cmd`, `app/kvs/cmd` and `app/scp/cmd` all
existed; `app/cli` had `commands/` **and** a separate `app.zig` holding the shared
`App` alias, so the two things every command needs - the alias and the sibling
command list - were in different folders.

*What landed*, as one move:

```
app/cli/app.zig          ->  app/cli/cmd/root.zig      (the App alias becomes the folder root)
app/cli/commands/add.zig ->  app/cli/cmd/add.zig
app/cli/commands/config.zig -> app/cli/cmd/config.zig
app/cli/commands/init.zig   -> app/cli/cmd/init.zig
app/cli/commands/root.zig   -> deleted (superseded; its re-exports moved into cmd/root.zig)
app/cli/commands/           -> deleted
```

`cmd/root.zig` is now both the folder root and the `App` home, so a command file
reads `const App = @import("root.zig").App;` and `main.zig` names the command set
once, from that root. The convention is recorded in `.agents/AGENTS.md`.

*Also removed:* an empty, untracked `app/kvs/cmd/` that had been sitting there with
zero files. There is now no `commands/` folder anywhere under `app/`, so the two
spellings cannot drift apart again.

*Verified:* `zig build` 48/48; `tigershark --version` and `--help` unchanged, with
all four subcommands (`repl`, `config`, `add`, `init`) still listed; no remaining
reference to `app.zig` or `commands/` anywhere in the tree; `zig fmt --check` 0;
`test-lib` 199/199; `test-scp` 26/26; `test-bus-direct` 14/14.

### N-0b · `app/cfg` is the home for config-management commands · **[done]**

Config commands were tangled up with the CLI framework **and** owned by one
binary. Two separate problems, fixed together:

1. The only config command in the tree was `app/cli/cmd/config.zig`, and it was a
   **demonstration**: it hardcoded a fictional `ServerConfig{port, host,
   enable_cors, api_key}` to show the merge engine working. Nothing about it was
   specific to `tigershark`, and nothing else could use it.
2. All four binaries have configuration, and all four deserve the same commands.
   The specified suite (`setup`, `doctor`, `backup`, `restore`, `sync`, `eject`)
   would have been written into `app/cli` and then extracted.

*What landed:* **`app/cfg/root.zig`**, an app module with no binary of its own,
exporting

```zig
pub fn Commands(comptime AppT: type) type
```

**Why a function and not a `const`.** A command in this framework is a *type* -
`App.Command(Flags, .{}){...}` is specialised to the app's `State` and framework
`Config`. A fixed set of constants would therefore compile for exactly one binary
and silently fail for the rest. `Commands(App, ConfigT)` lets each binary
instantiate the group with its own `App` and its own configuration type:

```zig
const app_cfg = @import("app_cfg");
const cfg_cmds = app_cfg.Commands(App, app_cfg.DemoConfig);
```

`ConfigT` became a second parameter once the operations were needed by binaries with
no `App` at all: an export or a dry run is defined over a *configuration type*, not
over an app. See section 3c for the `ops` / `cmd` split that made those operations
reachable from `app/kvs` and `app/scp`, which import no file mentioning `cli`.

`app/cli` is the first consumer. This is the first **app module that other apps
import** - everything until now was `lib/` - which is why `app_cfg` is declared in
`build.zig` with its own test root, `test-app-cfg`. Nothing else compiles it, so
without that root its tests would never run, and a `refAllDecls` from elsewhere does
not help - it cannot cross a module boundary.

*Superseded:* `app_cfg` was declared as **two** modules (`app_cfg` and `app_cfg_ops`)
with two test roots (`test-app-cfg`, `test-app-cfg-ops`). The operations are a folder
of `app_cfg` now (`app/cfg/lib/ops`), reached by relative import through its `ops`
surface, so the second module and its root are gone and the same tests run in
`test-app-cfg`.

*Deliberately kept:* the demonstration config, now `Commands(App, DemoConfig)` with
`DemoConfig` exported from `cmd/root.zig` and documented as a placeholder rather than
this repository's config. It is what makes the merge path exercisable before a real
per-app schema is passed in. Replacing it with each app's own
type is the point at which this module stops being a demonstration, and the
generic shape is already in place for that.

*Improved while moving:* the description now reads "Inspect, validate and export the
configuration" rather than "Test the Viper-style Configuration engine", and the group
carries three real subcommands instead of one, so the description is accurate rather
than aspirational. The `--schema` flag was on the old single command; the schema
generator (`cfg.loader.generateSchema`, which emits `writeOnly` for `.secret` fields)
is still reachable as a library call and is a candidate for its own subcommand. A
secret is never printed on any path, only its length.

*Superseded verification:* the counts in the paragraph below are from the earlier
move. The current state is in section 3c - `test-app-cfg` 51 (the operations' and the
command group's tests share one root), `test-kvs-config` 4, `test-lib` 327/327.

*Verified:* `zig build` 48/48; `tigershark --help` still lists `repl`, `config`,
`add`, `init`; `tigershark config` resolves and prints; `config --schema` emits
draft-07; `config --help` shows both flags; `test-lib` **200/200** with
`test-app-cfg 1 pass`; `test-scp` 26/26; `test-bus-direct` 14/14; `zig fmt --check`
0; all 54 folders still have a `root.zig`.

### N-1 · `root.zig` in every folder · **[done: 53 folders, 0 missing]**

A folder that contains Zig sources has a `root.zig` naming them. Measured before
starting: **29 folders had one, 24 did not** — and 5 of the 24 were folders this
document's own S-0 item had just created (`app/cli/lib/{render,interact,secrets,platform,test}`),
so the reorganization had introduced the inconsistency itself.

*What landed:*

- **`lib/` is complete** — every folder with Zig sources now has a `root.zig`
  (from 0 missing). `lib/net/` correctly has none: it holds only `dns/`, `s3/`
  and `tls/`, each with its own root, so a file there would be a root with
  nothing of its own to name.
- Five new group roots under `app/cli/lib/`, each documenting the folder, re-exporting
  its files, and applying `refAllDecls` per namespace (M-2's rule).
- `app/cli/lib/cli.zig` imports those roots (`pub const render = @import("render/root.zig")`)
  so they are **in the module graph and compiled**, and `app/cli/lib/root.zig`
  re-exports them, which the completeness guard enforces.
- `app/cli/root.zig` and `app/cli/commands/root.zig`, with `main.zig` changed to
  consume them — a root nothing imports cannot be verified and will rot.

*Still open:* **none — every folder with sources now has one.** All 17 `app/`
folders were done in the same pass.

**How the 17 were done, and the three different shapes they turned out to need.**
Assuming "add a root that `refAllDecls`es everything" would have been wrong three
times:

1. **Rename, when the folder holds exactly one file named after it.**
   `app/kvs/persistence/persistence.zig` became `persistence/root.zig` and its 7
   importers were repointed at the folder. This is the only remaining
   folder/file name collision in the tree (the other, `bus/client/jetstream/JetStream.zig`,
   is capitalised so it does not collide).
2. **A real root with `refAllDecls`, when the folder holds ordinary modules.**
   `scp/{common,crypto,net,storage,cmd}`, `kvs/{storage,replication}`,
   `bus/{testing,server/feature/jetstream,server/os/linux}`.
3. **A name plate with NO `refAllDecls`, when the folder holds program entry
   points.** `bus/cmd` holds three `pub fn main`s, `bus/testing` holds two more
   (`fuzz`, `integration`), and `bus/server/feature` is 7,000+ lines most of which
   a given build compiles out. Referencing every declaration there would force
   semantic analysis of `main` functions and of feature code the build
   deliberately excludes - the same mechanism that surfaced the `panic.zig` break
   in N-3, but pointed at code with nothing to gain.

`app/scp/test` was a near-miss worth recording: I first measured its three files
as orphans, and they are not - `app/scp/root.zig` imports each inside its `test`
block, and `_ = @import(...)` there is what puts their `test` blocks in the
compilation. That import is load-bearing and silent if removed, which is exactly
M-2's hazard.

**Reachability, stated honestly.** Adding a root does not by itself put it in a
compilation. Where the folder already had a consumer the root is now in the graph
and verified: the five `lib/cli` group roots (via `cli.zig`), `app/cli/root.zig`
and `app/cli/commands/root.zig` (via `main.zig`), and the five `scp` folder roots
(via `app/scp/root.zig`). Where the folder is reached by path from a build file
instead - `bus/cmd`, `bus/testing`, `bus/server/feature` - the root is a name
plate and is not compiled, which is stated in each file rather than papered over.

*What the work found:* `app/scp/root.zig` grouped its folders with `pub const cli = struct { ... }`
literals, so a folder root is a drop-in for each group. Before swapping them I
compared the names each group exposed against each root's exports, and the check
caught a real trap: the `cli` group also exposed six historical aliases
(`send_mod`, `receive_mod`, `relay_mod`, `ui_mod`, `pitch`, `field`) that
`cmd/root.zig` did not export. Swapping without that comparison would have
silently removed them. The aliases were added to `cmd/root.zig` and the swap then
kept every name.

*Verified:* `test-scp` went 21 -> 26 tests, because rewiring `app/scp/root.zig`
through the five folder roots puts five new `refAllDecls` blocks in the
compilation. A count that moves for a reason you can name is the check working.

*One flake observed, and it is not from this work.* The first
`zig build test-bus-integration` of the session reported
**`1 INTEGRATION TEST(S) FAILED`**; two subsequent runs reported
**`ALL INTEGRATION TESTS PASSED`**, and the second of those was run immediately
after the first with no intervening change. The failure surfaced inside the `tls`
suite as a `readNext` error, which is the same locus repo-wide `ROADMAP.md` item
R-11 documents ("one run failing with a stack through the client's
`fillMoreWindows`/`readNext`, the next identical run passing"). **None of this
item's changes can reach that suite** - every file it added is either a
`root.zig` that nothing imports on that path or a `Self` alias inside a struct
body, and the two `app/` roots that *are* in the graph (`cmd/`, `scp/*`) are not
in the bus's graph at all.

Recording it because "it went away" is not a diagnosis, and because a suite that
fails one run in three is worse than one that always fails.


### N-2 · `const Self = @This();` at file scope — the file IS the type · **[COMPLETE in this tree: 0 wrapped, 0 candidates]

**The rule is in `.agents/AGENTS.md`.** A file whose subject is a single type does
not wrap it in a named struct; the file's own scope is the struct, so the import
yields the type directly:

```zig
const RawTerminal = @import("raw_terminal.zig");   // the file IS the type
var rt = try RawTerminal.enable();
```

not `@import("raw_terminal.zig").RawTerminal`.

**Scope, measured:** 23 files were written in the wrapped form, 27 already used
file-scope `Self`, and 11 more declare several types in one file (a primary type
plus argument records or enums) where the rule needs judgement rather than a
mechanical rewrite.

#### Current state, measured

| Scope | file-as-type | still wrapped |
|---|---|---|
| `lib/` | **30** | **0** - complete |
| `app/` in *this* tree (`cfg`, `cli`) | **0 candidates** | **0** - complete; see below |
| `app/` in the monorepo (`bus`, `scp`, `kvs`) | n/a | 13 - the paths are absent here (§0.4) |

#### Complete, and re-verified after the header above went stale

**`lib/` is done: 30 files, 0 wrapped.** The last two were the aggregates
(`style.zig` with seven types, `slab.zig` with four), and they turned out **not** to need
the split this section previously recommended — see "the multi-type problem" below.

The header this section carried for a long time said `app/ 25 done, 9 left`, and the
`app/` pass header says `5 converted, 7 left`. **Both counts are about `bus`, `scp`
and `kvs`, and none of those three apps exists in this repository** — `app/` contains
only `cfg/` and `cli/`, 24 Zig files in total. So the "9 left" was a backlog for a tree
that is not this one, and it read as open work here. Re-measured:

* Every `pub const <Name> = struct` under `app/` was enumerated (30 matches, 24 files)
  and each is a **declaration inside a file whose subject is the command**, not the
  file's own wrapper: `<Cmd>Flags` or `<Cmd>Args` next to a `run`, a `Fixture`, and
  tests (`cast.zig` has `CastFlags` + `run` + `Fixture` + 9 tests), or a helper record
  in a multi-type file (`ops/exporter.zig` declares `Variable`, `Options`, `Collector`).
  N-2's rule does not reach any of them.
* `lib/` needs no re-check: it was completed and is still 0 wrapped.

**The generalisable point, and why this note exists:** §0.4 already says the `bus`
/`scp`/`kvs` paths are absent, but a *per-item progress header* that counts those files
contradicts it in the one place a reader looks first — the heading. When a document
carries counts, the counts need the same applicability check as the prose. Nothing was
converted here; the work was confirming there is none, and saying so where the stale
number was.

#### The multi-type problem, resolved: keep the helpers as declarations

The previous recommendation here was to split `style.zig` into `color.zig`,
`border.zig`, `table.zig` and so on, on the theory that making the file the primary
type would re-spell every helper access - `style.Color`, `style.Table` - across 178
call sites.

**That theory was wrong, and the conversion cost 6 reference edits, not 178.**

The key is that a helper declared **inside** the file's scope is still reached
through the file either way. `style.Table` keeps working when `Table` is declared
in `style.zig`, whether the file's own scope is a struct or not:

```zig
// the file's own scope IS Style
const Self = @This();
pub const Color = struct { ... };   // still style.Color
pub const Table = struct { ... };   // still style.Table
```

Only the spelling that named the *file's own* type changed - `style.Style` became
`style` - and **that had zero external references.** So the split was unnecessary
machinery: it would have moved four types into three new files to avoid a problem
that does not exist.

Two measured facts made this safe:

| file | reference edits needed |
|---|---|
| `style.zig` | 6 (`style.Color` x4, `style.Column`, `style.Table` - all unchanged) |
| `slab.zig` | 0 (`TieredSlab` and `SlabAllocator` both had zero external uses) |

**A second consequence, and it is the good kind:** a file-scope type is now
reachable by `refAllDecls` from the folder root, so methods that were previously
unreachable get compiled. `style.zig` had **no tests at all** before this; it has
five now, and `slab.zig` gained one.

**The naming collision is the real recurring cost.** At file scope, locals collide
with declarations where they previously did not:

- `slab.zig`: `const alloc = sa.allocator()` shadows the `alloc` method ->
  renamed to `iface`, with a comment saying why.
- `spin_lock.zig`: `var lock` shadows the `lock` method -> renamed to `sl`.

Both are recorded rather than worked around, because the next conversion will hit
the same thing.

#### `app/` pass · **[not applicable in this tree — the files it counts are in `bus`, `scp`, `kvs`, none of which exist here (§0.4)]**

*The counts in this subsection are records of the monorepo, kept because the reasoning is
generalisable — the `union(enum)` exception and the filename-keyed-detector flaw below are
the two things a future conversion needs. They are **not** a backlog for this repository.*

Converted there: `bus/client/header_map.zig`, `bus/client/memory/sidmap.zig`,
`bus/client/respmux.zig`, `scp/storage/crawler.zig`.

**`scp/net/transport.zig` is an EXCEPTION, not a shortfall.** It was converted,
failed, and correctly reverted: it declares `Transport` as a **`union(enum)`**, and
a file's own scope is *always* a struct. A bare union body at file scope parses but
`switch` on it fails with `switch on struct with auto layout`; `pub const Self =
union(enum)` compiles but is the same wrapper renamed. So a union file keeps its
wrapper. The rule in `.agents/AGENTS.md` now states this, and `transport.zig`
carries a test asserting `@typeInfo(Transport) == .@"union"` so the reason is not
lost. `ConnectionState` stays a declaration inside, as the rule requires.

`ws_fallback.zig` was also converted and reverted. It is **resolved by deletion**,
not by conversion - see the note further down.

**A needed correction to this roadmap's own list.** `bus/server/metrics.zig` was
listed here as needing conversion, but it is **already file-as-type** - under a
different name:

```zig
pub const Exporter = @This();   // line 397
allocator: std.mem.Allocator,   // fields at file scope
io: std.Io,
metrics: *Metrics,
```

The file is the `Exporter`; `Metrics` is a declaration inside it. The scan that
produced this list keyed on "the PascalCase of the filename", so `metrics.zig` was
matched against `Metrics` - a real type in the file, just not the file's own.
Six other `app/` files alias `@This()` the same way and were never flagged because
their alias happens to be spelled `Self` (`shared/cmd.zig`,
`server/feature/protocol/raft.zig`, `kvs/pubsub.zig`, `kvs/storage/store.zig`,
`kvs/storage/zset.zig`, `scp/storage/metadata.zig`). **A filename-keyed detector
cannot tell "wrapped" from "already flat under another name";** each remaining file
needs its structure read, not just its wrapper counted.

**Blocked: `scp/net/ws_fallback.zig` · `high`.** Converted, and the conversion
immediately failed `test-scp`:

```
app\scp\net\ws_fallback.zig:6:13: error: root source file struct 'std'
  has no member named 'net'
```

The file uses `std.net.Stream` (`writeAll`, `read`, `reader()`), which does not
exist in 0.16 - networking moved to `std.Io.net` and the calls take an `io`. The
unwrap reached it through `scp/net/root.zig`'s `refAllDecls` for the first time,
so **this file has never been compiled.** It was reverted to wrapped to keep the
tree green.

**Resolved: deleted.** The blocker was the diagnosis, not the obstacle. The file
was reachable from nothing (one reference site, `scp/lib/net/root.zig`, plus its
own `refAllDecls`), it had never compiled, and it was a fifth copy of the RFC 6455
codec - with the fixed mask below. It is gone rather than converted:
`app/scp/ROADMAP.md` section 1 now records WebSocket signalling as a capability
that does not exist, and the generic codec is `src/zig/lib/net/websocket/root.zig`
(see `PROMOTION_INVENTORY.md` section 4.2). The two things this note said had to
happen - migrate to `std.Io.net`, and replace the hardcoded mask - are what a real
fallback transport must do; they are no longer a conversion task.

Still to convert: `bus/client/server_pool.zig`, `bus/client/micro/service.zig`,
`bus/server/permissions.zig`, `bus/server/feature/jetstream/consumer.zig`,
`bus/shared/nkey.zig`, and `kvs/storage/stream.zig`.

**Why these five `bus` files are not merely "not yet done" - they are not
*shaped* for the mechanical conversion.** In every one of them the primary type is
declared **after** at least one other type:

| file | primary type | byte offset |
|---|---|---|
| `client/server_pool.zig` | `ServerPool` | 1650 |
| `server/permissions.zig` | `Permissions` | 3861 |
| `feature/jetstream/consumer.zig` | `Consumer` | 2809 |
| `client/micro/service.zig` | `Service` | 13460 |
| `shared/nkey.zig` | **no `Nkey` type exists** | - |

`nkey.zig` declares `KeyPair` and `NKey`; there is no `Nkey`, so the
filename-to-PascalCase derivation that drives the pattern has nothing to match.

For the other four, a "first `pub const X = struct`" script would unwrap the
*wrong* type - which is exactly the bug that flattened `Cell`, `EnvVar`,
`FieldProvenance`, `ValidationResult` and `SandboxPolicy` earlier in this
document, producing `error: ambiguous reference` and nesting the primary type
inside its own helper. **Reordering a file's declarations so the primary type comes
first is a safe prerequisite, and it is the next step for these four** - not
another pass of the same script.

**`kvs/storage/stream.zig` is deliberately out of scope**: `app/kvs` is being
built in parallel, so touching it would collide.

#### The multi-type problem — historical note

`style.zig` declares **seven** types and `slab.zig` **four**. The rule as written
("the file's own scope is the struct") says what to do with a file that has *one*
subject; it does not say what to do with an aggregate.

The resolution above shows that no extra clause is needed: an aggregate's helpers
simply stay declarations inside, and the file's own type is the primary one. The
reference counts that motivated the abandoned split were never the issue.

| type in `style.zig` | external references |
|---|---|
| `Table` | 66 |
| `Style` | 55 |
| `Alignment` | 44 |
| `RGB` | 30 |
| `Color` | 21 |
| `Column` | 11 |
| `Border` | 6 |

`Table` is referenced *more* than `Style`, which is why the split looked
unavoidable. It was not: the counts measure how often helpers are *used*, not how
hard they are to keep, and keeping them as declarations costs nothing. `style.zig`
is 466 lines of colour handling **and** table layout - still two concerns sharing a
file, still arguably worth splitting *on its own merits*, but that is a design
opinion about cohesion, not a prerequisite for this convention, and it should not
be smuggled in under a naming refactor.

#### What is converted

**`lib/` 30 files, `app/` 22 files** — verified with `zig build` 48/48,
`test-lib` **223/223**, `test-scp` 26/26, `test-bus-direct` 14/14 and
`zig fmt --check` 0.

Converted across this pass, all via `scripts/unwrap-type.ps1` plus
`scripts/flatten-typerefs.ps1` for the call sites (both encoding-safe):

- `raw_terminal`, `tty_stream`, `byte_ring`, `dynlib_reloader`, `decstbm`, `vte`
- `security`, `encrypted_config`, `wasm_bridge`, `object_pipe`
- `cancellation`, `toml_mutator`, `spin_lock`, `pager`
- `config_lineage`, `config_dryrun`, `virtual_terminal`, `systemd_exporter`, `sandbox`
- `i18n`, `layout`

`telemetry.zig` is the one file that was **split rather than unwrapped**, because
it held three unrelated subjects and one of them (`Telemetry`) was a struct
wrapping a single free function:

```
platform/telemetry.zig  ->  platform/telemetry.zig   (isOptedOut, free function - not a type)
                            platform/trace_parent.zig (TraceParent)
                            platform/profiler.zig     (Profiler)
```

Its `getMonotonicMs` re-export is gone; `panic.zig` and `sys.zig` now import
`@import("util").trace` directly, which is where that function actually lives.

**A bug in the conversion script, found and fixed:** `unwrap-type.ps1` originally
matched the *first* `pub const X = struct {` in a file rather than the file's
**primary** type. On `config_lineage`, `config_dryrun`, `virtual_terminal`,
`systemd_exporter` and `sandbox` that flattened the helper (`FieldProvenance`,
`ValidationResult`, `Cell`, `EnvVar`, `SandboxPolicy`) instead, producing
`error: ambiguous reference` and nesting the primary type inside the helper. It now
matches the PascalCase of the filename and refuses to guess. Those five files were
rewritten by hand, which is also how their four tests came to exist.

#### Testing note

The conversions added **27 tests** (196 -> 223 across the pass), because a folder
root applying `refAllDecls` reaches a file's tests only once the file's own scope
is the struct. Two of the new tests were **wrong when first written** and are worth
recording as a pattern:

- `renderMatrix`'s PASS/FAIL markers are wrapped in ANSI colour, so
  `indexOf(out, "[PASS] a = 1")` never matches. Assert on the text around the
  marker, not through it.
- `exportSystemdService` renders `Description={s} ({s})` with
  `.{ service_name, description }` - the name comes first, not the description.

Both were found by dumping the produced bytes rather than re-reading the source.

#### The conversion is a compile-time gate, and it found five latent faults

This is the important finding, and it is the same mechanism as N-3. Wrapping a
type in a named struct means **nothing outside the file can reference its
methods**, so `refAllDecls` on the enclosing folder cannot reach them and their
bodies are never analysed. Unwrapping makes the file the struct, the folder root's
`refAllDecls` reaches every method, and the bodies get compiled for the first
time. Four files had never had a single line of their implementation compiled:

| File | Fault found | Resolution |
|---|---|---|
| `dynlib_reloader.zig` | `std.DynLib` has **no Windows backend** (`@compileError("unsupported platform")`), so the whole file was unbuildable on the shipping host. Also called `l.close()` on an optional payload, which would not have compiled on Linux either. | Fixed: `Supported` is computed from `builtin.os.tag`, the backing handle is `void` where unsupported, `loadOrReload` returns `error.UnsupportedPlatform`. |
| `pager.zig` | `std.process.Child.init(argv, alloc)` — that constructor is **gone in 0.16**; the API is now `std.process.spawn(io, .{...})`. | **Reverted to the wrapped form**, pending a real migration. |
| `version.zig` | `std.ArrayList(u8).init(alloc)` (gone in 0.16) and `std.http.Client` without `.io`. | **Left wrapped.** `version.check` is disabled anyway (roadmap B-5). |

#### Two conversions that are *not* purely mechanical

Both are reasons the rule needs a stated exception, and both are recorded rather
than forced:

- **`spin_lock.zig` cannot be converted as written.** At file scope its `lock()`
  method collides with the local `var lock: Self` its own tests declare
  (`error: local variable shadows declaration of 'lock'`). Wrapped, the local was
  inside a different scope. Converting means renaming either the method or the
  test locals, and renaming a shipped method (`lock.lock()`) is a worse trade than
  renaming a test variable — so the test locals should change, deliberately.
- **`pager.zig` and `version.zig`** are blocked on stale `std` APIs that need a
  migration, not a rewrite. Doing that migration blind, inside a naming refactor,
  is how a "mechanical" change becomes an unreviewable one.

#### Still wrapped, and why

11 multi-type files (`style`, `slab`, `telemetry`, `vte`-style aggregates, `i18n`,
`layout`, `sandbox`, `config_lineage`, `config_dryrun`, `virtual_terminal`,
`systemd_exporter`) plus `pager` and `version`. The multi-type ones need a
decision the rule does not currently make: when a file declares a primary type
*and* helper types, making the file the primary type leaves the helpers as
file-scope siblings, which changes how they are reached
(`@import("x.zig").Helper` becomes `@import("x.zig").Helper` only if the helper
stays a declaration inside the file — it does — but the primary type is now the
file itself). That is a coherent design; it is simply not the design of the files
as they stand, so each needs a look rather than a script.

#### What this item taught, for the next conversion

**A naming refactor in this codebase will repeatedly uncover never-compiled code.**
Four of ten files had broken implementations. That is not bad luck: the wrapped
form is *specifically* what hides a method body from `refAllDecls`, so the files
most likely to be broken are exactly the files that need converting. Budget for
it, convert one file at a time, and treat a compile error as a finding rather than
an obstacle.


The convention is that a type uses `Self` rather than repeating its own name.
Measured before starting: of the **236 files declaring a top-level type, only 45
declared `Self`**.

**The scope had to be defined, because applying it blindly would be wrong.** Most
of those 236 files declare several types, and in `app/kvs/lib/resp/commands/*.zig` the
declarations are all argument records (`SetArgs`, `GetbitArgs`, ...) in files of
free functions — a `Self` there means nothing. The rule applied, and the one to
keep applying, is:

> Add `Self` to the file's **primary** type: the type whose name is the
> PascalCase form of the filename. A file of free functions, or a file whose
> types are all argument records, has no primary type and is left alone.

*What landed:* **28 files** (`20` in `lib/`, `8` in `app/`), with zero encoding
problems — the script verifies the non-ASCII byte count per file before and
after, because of S-0a. `76` files already had it.

*Deliberately not done:* the remaining declarations. `lib/util/slab.zig` declares
`Config`, `Slab`, `TieredSlab` and `SlabAllocator`; `app/cli/lib/render/style.zig`
declares seven types. Giving every one of them a `Self` would be noise, not
consistency.

### N-3 · What N-1 found: a compile bug that had never been compiled

Worth recording because it is the *reason* this convention has value beyond
tidiness. Wiring `platform/root.zig` into the module graph made `refAllDecls`
reach `panic.writeCrashReport` for the first time, and it **did not compile**:

```
app/cli/lib/platform/panic.zig:65: expected type 'i64', found 'u64'
```

`CrashJson.timestamp` was `i64` while `telemetry.getMonotonicMs()` returns
`u64`. This is roadmap item **B-1**, predicted by the audit and now fixed: the
field is `u64`, matching its source.

The general point: **a folder root that applies `refAllDecls` is a compile-time
gate.** Files that nothing calls are never analysed, so a crash reporter can sit
broken indefinitely. Each root added under N-1 makes the tree a little more
thoroughly type-checked, which is a better argument for the convention than
uniformity.

---

## 2. S-0 — Shape: one surface, one file per concern

### S-0 · `medium` · The directory layout · **[done]**

The 64 files were flat in one directory, so nothing about the design was visible
from a listing. They are now grouped by concern, and this was a **pure move**
proved content-preserving (see the verification note below):

```
app/cli/lib/
  root.zig          the public surface (C-1) + the completeness guard
  cli.zig           the framework: App/Command/Flags/Ctx/ExecutionChain/execute
  alias.zig i18n.zig version.zig repl.zig policy.zig
  render/   11  tea style color graphics layout progress pager
                virtual_terminal vte decstbm spatial_focus
  interact/  6  prompt widgets rope raw_terminal tty_stream supervisor
  settings/ 10  config comptime_config config_diff config_dryrun
                config_lineage profiles remote_config ota_flags
                schema_migration toml_mutator
  secrets/   4  security secret_val secure_heap encrypted_config
  platform/ 26  sys daemon tasks dag cancellation sandbox proctitle vfs
                object_pipe cas btree_store dry_run mmap dynlib_reloader
                telemetry panic headless footprint linter dist_specs
                systemd_exporter openapi wasm_bridge updater fido2 oauth
  test/      1  cli_test.zig
```

**Why these five groups and not more.** The grouping was driven by the measured
import graph, not by taste: **58 of the 60 leaf files had zero intra-directory
imports**, and the only edges were `prompt→{style,tea}`, `widgets→style`,
`panic→telemetry`, `sys→telemetry`. So files could be grouped topically without
breaking anything, and each group's internal edges were kept inside it by
construction (`prompt` and `widgets` both live in `interact/` with the `render/`
files they need).

**Why 7 files stayed flat.** `root.zig` and `cli.zig` are the surface and the
framework — the two files that define the module. `alias.zig`, `i18n.zig`,
`version.zig` and `policy.zig` are small single-purpose leaves that fit no group
without inventing one. `repl.zig` stays deliberately: the live REPL lives inside
`cli.zig` today, and moving the stub into a subdirectory would create a second
thing called "repl" in a new place — S-5 merges them first.

**Not done, and deliberately:** `cli.zig` was *not* split. S-1 below still
describes that work, and doing it at the same time as a 58-file move would make
both unreviewable.

*Verification.* A script compared the tree against a pre-move snapshot:
65 files before and after, identical file set, **identical line count in every
file**, and byte deltas exactly accounted for by the longer import paths
(`cli.zig` +476 bytes for 57 rewritten imports, `prompt` +14, `widgets` +10,
`test` +3). `zig fmt --check` 0, `zig build` 48/48, `test-lib` 173/173 with
`test-lib-cli` at 93, `test-scp` 21/21, and `tigershark --help` unchanged.

*This item also produced the two findings below, both of which cost real time
and are worth not rediscovering.*

### S-0a · `high` · Two encoders in this environment corrupt any non-ASCII text

`lib/cli` is not pure ASCII — `cli.zig` has 117 non-ASCII bytes (the box-drawing
characters `formatOutput` prints) and `widgets.zig` has 492. Two separate
mechanisms in this session silently mangled them, and **both are still live
hazards for any future edit**:

1. **Windows PowerShell 5.1 text IO.** `$PSVersionTable.PSVersion` reports
   `5.1.26100.9444` in this environment. `Get-Content -Raw` on a **BOM-less**
   UTF-8 file mis-decodes it as Windows-1252, and `Set-Content -Encoding utf8`
   re-encodes the mis-decoded text. A single read/write round-trip therefore
   doubles the encoding: the correct em dash `e2 80 94` becomes the 8-byte
   `c3 a2 e2 82 ac e2 80 9d`. It broke two tests (`Advanced Table Engine`,
   `Interactive Hotkey Overlay`) because the test file's expected glyphs no
   longer matched what `style.zig` emits.
2. **Non-ASCII written through the editing tool.** The same corruption appeared
   in a file created from scratch, so it is not PowerShell alone.

*The rule this yields, which belongs in `src/zig/README.md`:* edit these files
with byte-exact IO — `[System.IO.File]::ReadAllText` / `WriteAllText` with
`New-Object System.Text.UTF8Encoding($false)` — or keep the text ASCII-only, and
**fingerprint non-ASCII byte counts before and after** any scripted rewrite. The
reorganization above does exactly that, and `root.zig` was rewritten ASCII-only
so it cannot be a victim again.

### S-0b · `medium` · Pre-existing mojibake across 10 files, including `HEAD`

Found while building the detector above. Measured by matching the full
double-decoded byte sequence (not the `C3 A2` prefix, which matches legitimate
text and over-counts by an order of magnitude):

| File | Corrupted character | Count |
|---|---|---|
| `src/zig/build/bus.zig` | inverted `!` (`0xC3 0x82 0xC2 0xA1`) | **179** |
| `app/bus/server/feature/jetstream/store.zig` | em dash | 25 |
| `app/bus/server/feature/raft_node.zig` | em dash | 22 |
| `lib/net/tls/tests.zig` | em dash | 8 |
| `lib/net/tls/server.zig` | em dash | 5 |
| `app/bus/testing/temp_dir.zig` | em dash | 3 |
| `lib/net/tls/client.zig` | em dash | 3 |
| `app/bus/server/feature/jetstream.zig` | em dash | 3 |
| `app/bus/server/config.zig` | em dash | 1 |
| `lib/net/tls/record.zig` | em dash | 1 |

`build/bus.zig` is the striking one: 179 occurrences of an inverted exclamation
mark in a build file. The repo-wide roadmap's item **M-5** claims this class of
damage was repaired ("34 double-encoded em dashes across 11 files"), so either
that fix was partial or this is a separate wave. It is cosmetic — a comment
character, not a syntax error — which is exactly why it has survived.

*Action:* repair with byte-exact IO and add the detector as a check, so a new
occurrence fails rather than accumulating. Do **not** batch this with S-0: it
touches `lib/net/tls`, `app/bus` and `build/`, and mixing it into the `lib/cli`
move would make both diffs unreviewable.

### S-1 · `medium` · `cli.zig` is the module root *and* the implementation

`AGENTS.md`: *"The entry point or surface for a library must be `root.zig` or
named after the module."* C-1 gave the library a `root.zig`; `cli.zig` is still
1,921 lines that mix the facade with the implementation. S-1 finishes the job by
deciding what each file is for:

| File | Responsibility | Approx. size |
|---|---|---|
| `root.zig` | Public surface: re-exports + aggregate test block | ~40 lines |
| `cli.zig` | The `App` facade: `App`, `Command`, `Flags`, `Ctx`, `ExecutionChain` | ~200 lines |
| `flags.zig` | `parseFlags`, `assignFlag`, `parseValue`, `determinesIfFlagTakesValue`, `getGlobalParserIndex` | ~450 lines |
| `help.zig` | `printHelp`, `generateDocsMarkdown`, `generateDocsMan`, `writeMarkdownDocs` | ~160 lines |
| `completions.zig` | `executeAutocomplete`, the four shell-script templates | ~80 lines |
| `output.zig` | `formatOutput`, `OutputFormat` | ~110 lines |
| `repl.zig` | `runShell`, `executeReplCommand`, `tokenizeReplInput`, `handleReplAutocomplete` (merging today's `repl.zig` stub) | ~150 lines |
| `testing.zig` | `TestHarness` + the shared test fixture from S-6 | ~80 lines |

Keep `cli.zig` as the facade so `@import("cli")` and `App.Command(...)` keep
working; the split is internal. The `App(StateT, config)` closure stays exactly
as it is — do **not** convert it to a `pub fn`-per-declaration module, because
`Ctx`, `AppError` and `Command` are generic over `StateT`/`config` and the
closure is what threads them.

### S-2 · `medium` · `cli.zig`'s indentation hides which scope a declaration is in

This is the worst readability defect in the library and it is worth stating
precisely, because it is not obvious and it cost real time to establish.

`App(...)` returns an anonymous struct opened at line 174. **`zig fmt` does not
re-indent the body**, so declarations *inside* that closure keep writing at the
same column as declarations at file scope:

```
 431  indent=0   fn levenshtein(...)      <-- FILE scope
 450  indent=4   pub fn execute(...)      <-- inside the App closure
 417  indent=0   pub fn executeAndExit(...)  <-- inside the App closure
 728  indent=0   fn parseFlags(...)          <-- inside the App closure
```

Measured, not inferred: `cli.executeAndExit` fails with *"root source file struct
'cli' has no member named 'executeAndExit'"*, while `App.executeAndExit` and
`App.levenshtein` resolve — and the latter errors with *"'levenshtein' is not
marked 'pub'"*, naming `cli.zig:431` as a **file-scope** declaration. So two
adjacent `indent=0` functions live in different scopes, and the only cue is the
column of the `fn` keyword.

*Action:* make the scope visible. Either (a) move every genuinely file-scope
helper out of the way of the closure — there is exactly one candidate,
`levenshtein` — and then indent the closure body properly, or (b) at minimum add
a `// ── inside App(StateT, config) ──` banner and stop mixing the two. Prefer (a);
it is a whitespace-only change once `levenshtein` is relocated, and `zig fmt`
enforces whatever indent the closing braces imply.

### S-3 · `medium` · The `App` closure outgrew its welcome: `parseFlags` is 430 lines

`parseFlags` (lines 728–1118) mixes seven jobs in one function:

1. default-value initialisation via `field.default_value_ptr` casts,
2. positional-struct defaulting,
3. the tokenizer (`--`, `--k=v`, `-abc` grouping, `--no-*`),
4. `assignFlag` dispatch and value coercion,
5. **direct environment-variable binding** with `ctx.env_map.get`,
6. **validation**: `conflicts_with`, `requires`, `validate` callbacks,
7. **interactive prompting** for missing required flags when `is_tty`.

Jobs 5–7 are policy, not parsing, and 7 is untestable without a TTY. Extract at
least 7 (`promptForMissingFlags`) and 6 (`validateFlags`) into their own
functions taking the parsed struct plus `provided`, so each is unit-testable on
its own and `parseFlags` becomes a readable tokenizer loop. This is
behaviour-preserving; the 91-test suite is the guard, and if it does not cover a
branch being moved, **add the test before moving it**.

### S-4 · `medium` · Every consumer compiles all 11,400 lines

`cli.zig`'s 62 `pub const X = @import` lines mean the `tigershark` binary
analyses `mmap.zig`, `fido2.zig`, `wasm_bridge.zig`, `systemd_exporter.zig` and
58 others whether or not it calls them. Comptime work that is never used is not
free, and more importantly it means a change to any one file is a change to
every consumer's compile.

*Action:* keep `root.zig` as a *documented* list but make the expensive groups
opt-in where the language allows it — named modules or explicit
`@import("cli").widgets` sub-namespaces — so `App`-only consumers stop pulling in
the terminal stack. Measure before and after with `zig build --summary all` plus
a clean-cache `zig build -Doptimize=ReleaseFast` wall time, and **record both
numbers**; do not claim a speedup you did not measure.

*Not proposed:* deleting the re-exports. They are the library's advertised
surface and the 91 tests exercise most of them. This item is about cost, not
existence.

### S-5 · `low` · `repl.zig` is a 53-line stub while `cli.zig` has the real REPL

`repl.zig` exists, is re-exported as `cli.repl`, and is not what `--interactive`
uses. The live implementation is inside `cli.zig`
(`runShell` 1615, `executeReplCommand` 1581, `tokenizeReplInput` 1551,
`handleReplAutocomplete` 1599). Two things called "repl" is precisely the
same-named-pair trap the repo-wide roadmap documents as item O-4.

*Action:* merge them — move the four functions into `repl.zig`, decide which of
the two surfaces survives, and write the header comment O-4 established as the
convention for this situation. `cli.repl` then means one thing.

### S-6 · `low` · 25 copies of the same 15-line test fixture

`cli_test.zig` re-declares the context setup inline in almost every test:
`var out_buf: [N]u8 = undefined` **×25**, `Environ.Map.init` **×17**,
`App.Ctx{ … }` **×14**, `ExecutionChain.init` **×13**, and `std.Io.Writer.fixed`
throughout. `TestHarness` already exists in `cli.zig` and is the natural home for
a single `Fixture` that owns the buffers, the env map, the reader and the chain,
with a `deinit`. That removes ~200 lines of near-identical code and, more
usefully, removes 14 places where a test can forget to `defer`.

`app/cli/lib/cli_test.zig` also has `5` empty function bodies and 133 occurrences of
`undefined`; a `Fixture` shrinks that surface too.

#### Re-measured, and the correctness half of this item does not hold

**Every one of the 19 `ExecutionChain.init` sites in `cli_test.zig` is matched by a
`defer <chain>.deinit(allocator)`** - verified by pairing each `var <name> = try …ExecutionChain.init(...)`
with the following two lines. `ExecutionChain.init` does allocate (two slices,
`cli.zig:556-559`), so a missed `deinit` would fail under `testing.allocator`; none is
missed and the suite is green. The "14 places a test can forget to `defer`" is therefore a
*hazard*, not a live defect, and the item's own evidence does not support the stronger
reading.

**And the file already has the better pattern - it is now the dominant one.** `Rig`
(`cli_test.zig:2603`) owns the two buffers and the env map as fields, with
`init`/`deinit`/`reset`/`stdout`/`stderr`, and the `runCmd` helper owns the chain. **Measured:
118 `runCmd` call sites against 13 `testExecute` ones**, out of 151 test declarations. So
the migration is largely *done* and this item's "25 copies" describes a minority of the
file. Tests on `Rig` are strictly cleaner than the ones S-6 describes: no fixed buffer size
chosen per test, no `defer` to forget, and `reset()` lets one test drive several
invocations.

So the work here is **finishing the migration onto the pattern the file already invented**,
not adding a new `Fixture` alongside it. The remaining sites are the `testExecute` helpers
and the hand-built `App.Ctx` blocks that predate `Rig`.

**Counts are stale, as the file has grown.** Latest measurement: `out_buf` ×26,
`Environ.Map.init` ×21, `App.Ctx{` ×15 (13 by hand + `Rig`/`runCmd`), `ExecutionChain.init`
×19, `Writer.fixed` ×108, and the file is 5,003 lines over 328 tests.

**Recommendation: defer, and do not do it blind.** It is a `low`-priority item whose only
remaining value is line count, the majority of the file already uses the good pattern, and
— as `S-2` and the `tea.zig` work showed twice — a volume refactor of tests is exactly where
a semantic drift hides, because the tests still pass either way. If it is done, finish the
`Rig` migration in slices of a few tests with the suite green between each, and re-measure
the saving rather than believing "~200 lines".

### S-8 · `medium` · Sequential prompts race each other for stdin

Found by reading `prompt.zig` while measuring B-4, and recorded rather than fixed: it is a
design question, not an edit.

**Every prompt starts its own reader thread over the same `ctx.in`.** `confirm`
(`prompt.zig:82`), `select` (`:157`), `multiSelect` (`:253`) and `multiSelectDynamic`
(`:360`) each call `tea.Program.run`, and `run` calls `startReader` (`tea.zig:318`) — one
`stdinReaderThread` per prompt. Those threads are **never joined**: that is precisely the
deliberate leak B-4 documents, and it is correct *as a leak* (nothing is freed while the
thread may run).

The consequence nobody has looked at is the one the leak hides. A command that prompts
twice leaves the first prompt's thread alive and still blocked in `readVec` on the same
`std.Io.Reader`. When the second prompt starts, **two threads are reading one stream**, and
which one gets a given byte is a race. The second prompt then sees a partial answer, or the
first thread consumes the bytes meant for it.

**Why it stays open here rather than being demonstrated:** the orphan's lifetime is
unbounded by design, so the repro is inherently non-deterministic, and this session already
paid twice for tests that hang instead of fail. A convincing demonstration needs a
deterministic seam (a shared, single reader owner), which is the fix, not a probe.

**The shape of the fix**, for whoever takes it: promote the reader to one owner per `App`
(or per `Ctx`) rather than per `Program`, so `run` attaches to an existing reader instead of
starting one. That removes the race, and it is also what finally makes the B-4 leak
unnecessary — with one long-lived reader a stop flag has somewhere to live. It is a real
API change to `tea.Program`, so it needs a plan and the spec treatment, not a patch.

### S-7 · `low` · `.io = undefined` in 14 tests is a live tripwire · **[FIXED, 15 sites]

`App.Ctx.io` is assigned `undefined` in every test that builds a `Ctx` by hand.
Every module in this library that talks to the filesystem takes `ctx.io` — `add`
in `app/cli/commands/add.zig` calls `std.Io.Dir.cwd().openFile(ctx.io, …)`. A
test that exercises any such path today gets undefined behaviour rather than a
compile error.

*Action:* fold this into S-6: the `Fixture` should set `io` from a real
`std.Io` (the test runner's) rather than `undefined`, or the tests should use
`TestHarness`, which has the same problem at `cli.zig:1923`. Whichever way, the
field stops being a landmine.

**Fixed, and the count was 15, not 14.** Every `.io = undefined` in
`lib/cli/test/cli_test.zig` is now `.io = std.testing.io` - 15 sites, of which 13
build an `App.Ctx` by hand and 2 are the in-memory rig. Two things worth recording:

* **S-6 is *not* a prerequisite for this**, which is why it landed alone. The item
  proposed folding the fix into a shared `Fixture`, but the landmine is one field's
  *value*; a `Fixture` is one way to set it correctly and a mechanical value change is
  another, with a fraction of the blast radius. `TestHarness` already did it right
  (`cli.zig:4460`) with a comment explaining why, and the hand-built contexts simply
  never followed - so the fix was to make the file consistent with its own best site.
* **This is a reasoning fix, not a demonstrated one, and the difference is stated on
  purpose.** The plant-and-run control was attempted and abandoned: a body that touches
  `ctx.io` has to satisfy the framework's signature checks, which reject an `anytype`
  parameter and then require the flags parameter to be the command's merged `Flags` type;
  getting that right is a compile-time exercise in the framework's own generics, not a
  two-line probe. What *is* established: `undefined` is not a valid `std.Io`, Zig rejects
  `drive(undefined)` as a comptime-known argument, and the fix makes the file consistent
  with `TestHarness`'s already-correct site. The trap is real; it is simply not worth
  three more compile cycles to watch it fire.

---

## 3. U-0 — Reuse: the library is bigger than its consumer

`lib/cli` advertises 63 modules; `app/cli` uses a handful. The honest question is
not "are the others dead" — the 91 tests say no — but **"who is the second
consumer, and is this the right library for it?"** Each item below is a decision,
not a cleanup, and each names the evidence a decision needs.

### U-0 · `high` · Half of `lib/cli` is not CLI code, and the layout hides it

Asked directly ("should all these files be under `lib/cli`?"), the measured
answer is **no**. A module boundary is a claim about reuse, and a large part of
this directory is not reusable *as CLI* — it is a general-purpose stdlib that
happens to live in the only library the `tigershark` executable links, which is
also the only library with a test root. That made `lib/cli` the path of least
resistance for anything that needed to compile and be tested.

**The test to apply**, and the one this section applies throughout:

> Would a program that is *not* a CLI reasonably want this? A NATS daemon, a
> file-transfer client and a Redis server all live in this repo. If the answer is
> yes, the file does not belong in `lib/cli`.

`lib/cli` is genuinely app-agnostic already (it imports only `std` and siblings,
with no `anyerror`), so the problem is not coupling — it is **labelling**. The
subdirectory grouping added by S-0 made the categories visible, which is what
makes the boundary question answerable at all.

#### Evidence, measured across the tree

| Finding | Measurement |
|---|---|
| The bus runs its own configuration system | `app/bus/config/{root,conf,env,flags}.zig`, 843 lines, **154 env-access sites** |
| The CLI has its own config loader | `app/cli/lib/settings/config.zig`, live in the shipped binary |
| A third, generic config manager exists | `app/cfg/lib/cfg.zig` — **imported by nothing, in no module, and it does not compile** |
| Two independent W3C `traceparent` implementations | `app/bus/shared/telemetry.zig` (serializes it) and `app/cli/lib/platform/telemetry.zig` (`TraceParent.generate`/`formatHeader`) |
| Three apps hand-roll ANSI output | bus 13 escape-sequence sites, scp 4, kvs 1, while `lib/cli` owns the render layer and `app/cli` has **0** |
| Only 4 modules of the library are reachable from the shipped binary | `app/cli` uses `App`, `Command`, `prompt`, `zconfig`, `version` — see §0 |

#### Tier 1 — genuine duplicates of something that already exists · **[done]**

These were not judgement calls; there were two implementations and only one could
be right.

| Item | What landed |
|---|---|
| `app/cfg/lib/cfg.zig` vs `app/cli/lib/settings/config.zig` | **Resolved.** `cfg.zig` now compiles (four stale Zig-0.16 enum tags: `.Slice`→`.slice` at :90/:120/:146 and `.Int`/`.Float`/`.Enum` in `parseValue`), gained `app/cfg/lib/root.zig`, and **its two tests run for the first time** as a new `test-lib-cfg` step. `app/cli/lib/settings/*` was folded into `app/cfg/lib/` (10 files; `config.zig` renamed `loader.zig` to sit beside `cfg.zig`). `lib/cli` now imports the `cfg` **module** and re-exports it, so `cli.zconfig` and `cli.profiles` still resolve. |
| `app/bus/shared/telemetry.zig` vs `app/cli/lib/platform/telemetry.zig` | **Resolved.** Both `traceparent` implementations are gone, replaced by `lib/util/trace.zig` with the canonical `TraceContext`/`TraceId`/`SpanId`/`toW3C`. The bus's version turned out to be **referenced by nothing outside its own file** — a generic, tested type sitting in a NATS file — so it is now a re-export and the bus's test moved with it. The CLI's `TraceParent` is a thin adapter, unchanged in behaviour. |

*The lesson worth keeping:* the duplication looked like a deep refactor across 11
bus files. Measuring the actual references showed the generic half was dead code,
which turned it into a 20-line change. **Count references before estimating.**

#### Tier 2 — pure primitives with zero application knowledge · **[done]**

Verified by scanning each file for any CLI concept (`ctx`, `Ctx`, `flag`,
`command`, `terminal`, `writer`): the only hit in `mmap.zig` was the Win32
parameter `dwFlagsAndAttributes`, i.e. no coupling at all. All eleven were also
`std`-only with **zero tests of their own**, so the move was mechanically clean —
and they are all still exercised, because `cli_test.zig` reaches them through the
`cli.X` re-exports.

| Moved out of `app/cli/lib/platform/` | To |
|---|---|
| `mmap.zig`, `cas.zig`, `btree_store.zig`, `dag.zig`, `tasks.zig`, `dry_run.zig`, `object_pipe.zig`, `vfs.zig`, `cancellation.zig`, `linter.zig`, `footprint.zig` | `lib/util/` |

`lib/util/root.zig` gained the re-exports and a note explaining why this class of
thing lives there. `lib/cli` now imports the `util` module and re-exports each
under its historical `cli.X` name, so `cli.tasks.Task`, `cli.mmap.MmapFile`,
`cli.cas.CasStore` and the rest resolve exactly as before.

**What this cost.** A cross-module move is not a rename: `lib/util` is a named
module, so `cli` had to declare it as an import in `build.zig`, and
`app/cli/lib/platform/telemetry.zig` reaches `util.trace` through that same import
table. That is the whole expense for eleven files, because none of them had
dependents.

#### Tier 3 — library-shaped; half landed, half needs a decision

| Item | Status |
|---|---|
| `settings/*` | **Landed.** All ten files moved to `app/cfg/lib/`. Note what this did *not* solve: `app/bus/config` (843 lines, NATS-specific) is untouched, so there are still two config systems — one generic, one protocol-specific. Merging those is a product decision, not a cleanup. |
| `secrets/*` — `security`, `secret_val`, `secure_heap`, `encrypted_config` | **Open, and no longer blocked.** Wiping, redaction, locked pages and XChaCha20-Poly1305 config encryption. Genuinely app-agnostic; a daemon wants exactly this. The blocking question was `lib/crypto/sec`: it owns PEM/PKCS/X.509 and the PKCS and X.509 halves **did not compile** (repo-wide item R-4). R-4 has landed - the DER codec is `lib/crypto/sec/der/`, all 11 files are ported and tested, and `zig build test-lib` / `zig build check-core` are green - so the move is a decision now rather than a wait. `encrypted_config`'s own KDF defect (raw SHA-256, nonce as salt) is the thing to fix before or with the move. |
| `interact/prompt.zig`, `render/*` | Genuinely CLI. `prompt` and `tea` drive an interactive TTY; this is the framework's user-facing half. **Keep.** |
| `platform/{sys,daemon}` | The per-OS files, and B-6 says they need fixing as one unit. Move them *after* B-6, not before, so the diff is not entangled with a POSIX repair. `platform/telemetry.zig` is now a thin adapter over `lib/util/trace.zig`, so the tracing half of this row is done. |

#### What must stay in `lib/cli`

The framework and its user-facing surface: `root.zig`, `cli.zig`, `App`/`Command`/
`Flags`/`Ctx`/`ExecutionChain`/`execute`, `render/*`, `interact/*`, `secrets/*`,
`i18n`, `alias`, `version`, `repl`, and the flag-parsing internals S-1 splits out.
Those are the ones a non-CLI program would never want, which is exactly the
criterion. `lib/cli` is **44 files** after tiers 1 and 2, down from 65.

#### Cost, stated honestly

A file cannot simply move: `lib/` modules are declared in `build.zig` with
`b.addModule` plus a `test-lib-*` root, so each destination needs wiring. The
eleven tier-2 files cost **one** new import edge from `cli` to `util` — the whole
expense, because none of them had dependents. Compare R-2 (the S3 signer), where
a module with real consumers made the same move genuinely fiddly.

**And do not do this as one sweep.** The 58-file S-0 move was purely mechanical
and still produced two real bugs; a move that also changes module boundaries
changes what compiles, so it must go one unit at a time with `zig build test-lib`
green after each.

#### What tiers 1 and 2 did not fix

Stated so the section is not mistaken for finished:

- `app/bus/config` (843 lines, NATS-specific) is untouched, so the repo still has
  two configuration systems: one generic (`lib/cfg`) and one protocol-specific.
- `cfg.Manager` and `cfg.loader` are still two resolvers inside `lib/cfg`.
- `platform/` still holds 15 files. Several are arguably app plumbing rather than
  CLI plumbing (`systemd_exporter`, `dist_specs`, `updater`, `dynlib_reloader`,
  `oauth`, `fido2`, `daemon`), but none is a *duplicate* and none has a second
  consumer, so moving them would be churn for tidiness. Leave them, pending a
  real second user.
- `lib/cfg` is a **new module**, so it is new surface. It exports only what the
  ten moved files already exported; nothing was invented.


### U-1 · `medium` · Reserve the library surface, and say what it promises

`app/cli/lib/root.zig` (C-1/S-1) should be the **complete** advertised surface, with
a one-line promise per group: what is stable, what is internal, and what is
experimental. Today the boundary is implicit — anything `pub` in any of 65 files
is reachable, and removing one is technically a breaking change nobody agreed to.

*Action:* mark the experimental groups explicitly in `root.zig`'s header. The
candidates from the audit are the ones with a single consumer and no second use
case in sight — but **the list must come from the audit, not from taste**, and
this item is not done until the audit's merge/dead-weight findings are folded in
(see §5).

### U-2 · `medium` · `lib/cfg` is now the config home · **[done, one half left]**

There are now two configuration modules in `lib/`, and the newer one
(`app/cfg/lib/cfg.zig`, 8,529 bytes, committed as *"advanced configuration merge
engine, EnvVars binding, and JSON schema generator"*) did not exist when
`app/cli/lib/config.zig` (6,350 bytes) was written. They overlap on merge semantics,
env-var binding and schema generation — the same three things.

Two configuration systems in one `lib/` is a correctness risk, not just
duplication: only one of them can be right about precedence, and nothing in the
tree makes the two agree. This is the same shape the repo-wide roadmap resolved
for the S3 signer as item R-2, where *"two implementations of a signature
algorithm is a correctness risk, not just duplication"*.

*Resolved — option (a), taken further than proposed.* `lib/cfg` was promoted into
the real generic configuration home and `app/cli/lib/settings/*` was folded into it,
which is option (a) with the shim replaced by a module re-export. What landed:

1. **`cfg.zig` compiles.** Four stale Zig-0.16 enum tags: `ptr.size == .Slice` in
   two places and `info.pointer.size == .Slice` in a third, all now `.slice`; and
   `parseValue`'s `.Int`/`.Float`/`.Enum` switched to `.int`/`.float`/`.@"enum"`.
2. **`app/cfg/lib/root.zig` added** — the surface, with `refAllDecls` per namespace
   (M-2's rule) so every file's tests are reachable.
3. **`lib/cfg` is wired as a module** with its own `test-lib-cfg` root. Its two
   tests, written in the "advanced configuration merge engine" commit and never
   compiled since, now run.
4. **`app/cli/lib/settings/*` folded in** — ten files moved; `config.zig` became
   `loader.zig` so it does not collide with `cfg.zig` inside the same directory.
   `lib/cli` imports the `cfg` **module** (a relative path would leave the module
   root, which Zig rejects) and re-exports it, so every `cli.zconfig` and
   `cli.profiles` reference is unchanged.

*Still open, and deliberately not folded into a move:* `cfg.Manager` and
`loader.load` are two resolvers that overlap on defaults, environment binding and
JSON overlay. Both are correct, both are tested, and `loader` is live in the
shipped binary — so unifying them is a behaviour change that needs its own tests,
not a side effect of relocation. That is the remaining half of this item.

### U-3 · `low` · The eleven `os` / process primitives do not need to be CLI-specific · **[superseded by U-0]**

Kept for the record, because its triage list is the seed U-0 turned into tiers and
because two of its guesses were corrected by measurement:

`mmap.zig`, `proctitle.zig`, `sandbox.zig`, `sys.zig`, `cancellation.zig`,
`daemon.zig`, `object_pipe.zig`, `tty_stream.zig`, `secure_heap.zig`,
`cas.zig`, `btree_store.zig` were flagged as general OS/utility primitives living
under `cli/`. `lib/util` already owns that class of thing (`ring`, `spsc`,
`slab`, `dash_map`, `spin_lock`, checksums, `base32`).

**What U-0 adds:** the full list is larger than these eleven (it also covers the
`settings/`, `secrets/`, `dag`/`tasks`/`dry_run`/`vfs`/`linter`/`footprint`
files), it is organised into tiers by how defensible each move is, and it carries
the cross-app evidence this item lacked. **What this item got wrong:** the closing
note guessed that `tty_stream`, `cancellation` and `object_pipe` were "arguably"
framework files. Only `tty_stream` is — it resolves a terminal handle.
`cancellation` is an atomic flag and `object_pipe` is structured record piping;
both are tier 2 in U-0.

*Superseded, not deleted:* the guidance below still holds for whichever files U-0
selects. Do it one file at a time with `zig build test-lib` green after each, and
**check who imports it before moving** — the naive "who imports X" count is
misleading; the repo-wide roadmap's O-4 note says to match on the full relative
path, because a basename match makes a file look like it imports itself. Remember
too that a `lib/` file needs `b.addModule` plus a `test-lib-*` root in
`build.zig`, so a cross-module move is not a rename.

### U-4 · `low` · `app/cli` proves the framework's ergonomics, so keep them honest

The only consumer is `app/cli/` and it is a good canary:

- `app/cli/main.zig` hand-rolls `stdin`/`stdout`/`stderr` buffering, builds `Ctx`
  by hand, and calls `App.execute` — while `cli.run(state, root, init)` and
  `App.TestHarness` already exist for exactly this. Either the helper is wrong
  or the consumer should use it; find out which.
- `main.zig:63` hard-codes `.is_tty = true, // Simplified for this prototype`
  and `main.zig:45` prints `"Debug print works!\n"` on every invocation, while
  `main.zig:16` declares `version` and `main.zig:35` hard-codes `"0.1.0"`.
- `add.zig` reads `registry.json`, fetches over HTTP and shells out to
  `zig fetch` — real behaviour with no test, in the one place the framework's
  ergonomics are exercised end to end.

*Action:* a small integration test that drives the real `tigershark` binary
(`--version`, `--help`, a bad subcommand → exit 127) is cheap and would catch the
errors the framework's own unit tests cannot see, because they use `TestHarness`
with `.io = undefined` (S-7).

---

## 3b. A-0 — Adoption: make the apps use what was built

The libraries exist, are tested, and serve exactly one 380-line consumer. This
section is the inverse of §3: not "what should leave `lib/cli`" but "what do the
apps need, and is the library actually the right shape for it?"

### The measured starting position

| App | Size | Uses `lib/cfg`? | Uses `lib/cli`? | How it takes input today |
|---|---|---|---|---|
| `app/bus` | 119 files, 60,965 lines | no | no | its own `config/` module: a runtime `StringHashMap` store, hydrated reflectively |
| `app/kvs` | 41 files, 19,104 lines | no | no | `persistence.Config.parse(&args)`, a hand-rolled `if/else if` chain |
| `app/scp` | 32 files, 4,826 lines | no | no | per-command `Args.parse(...)`, manual subcommand dispatch in `main.zig` |
| `app/cli` | 5 files, 380 lines | via re-export | yes | the framework itself |

**Three different argument models**, and none of them is the one `lib/cli`
implements:

1. **The bus** keeps a `std.StringHashMap([]const u8)` populated from three
   prefixes (env `NATS_*`, conf keys, flags), then `get(T, meta)` walks `T` with
   `inline for` and, per field, looks up **four** candidate keys in precedence
   order: short flag, long flag, env, conf. It has per-field overrides
   (`conf`/`env`/`long`/`short`), `skip`, `flatten`, and nested-struct
   namespacing. It also has two config-only types, `DurationMs` and `ByteSize`,
   dispatched specially.
2. **`kvs`** reads *only* argv — **zero environment reads** — with `--key value`
   for every option and one stringly boolean (`--appendonly yes`).
3. **`scp`** dispatches on `args[1]` by hand and hands the rest to a per-command
   `Args.parse()`; its `Args` is a flat struct of 8 optionals/bools.

### What that means for the library

The honest conclusion is that a single comptime `App`/`Command` framework is
**not** what these apps need, and adopting one wholesale would be a rewrite of
83k lines for no behavioural gain. What they need is separable:

| Capability | bus | kvs | scp | Who provides it today |
|---|---|---|---|---|
| argv → typed struct | (as flags) | yes | yes | nobody shared |
| env → typed struct | yes | **no** | no | nobody shared |
| file → typed struct | yes | no | no | `lib/cfg.loader` |
| defaults | yes | yes | yes | everybody, inline |
| per-field source override | yes | n/a | n/a | bus only |
| config-only scalar types (duration, byte size) | yes | no | no | bus only |
| validation with named errors | yes | no | partial | bus only |
| subcommand dispatch | yes | no | yes | ad hoc in each |
| help text / `--help` | yes | no | no | ad hoc |
| output rendering, progress, prompts | some | no | some | `lib/cli` |

So the work splits cleanly:

* **A-1 `argv` parsing as a library function.** The one thing all four apps need
  and all four hand-roll. Must accept `[]const []const u8` *and*
  `[]const [:0]const u8` (the `spawn`-style arrays `scp` carries), support
  `--key value`, `--key=value`, short flags, booleans, optional positionals, and
  report a named error rather than silently ignoring an unknown option.
* **A-2 the bus's store model, generalised.** `Manager`'s `PREFIX_FIELDNAME`
  convention cannot express what the bus needs (four candidate keys per field,
  per-field names, `skip`, `flatten`, nested namespacing). Either extend
  `lib/cfg` with the store+meta hydration the bus already has — moving that code
  rather than rewriting it — or accept that the bus keeps its own layer and only
  shares the pieces above.
* **A-3 config-only scalar types.** `DurationMs` and `ByteSize` with their string
  grammars are generic, tested behaviour sitting in an app file. **[done - see A-3 below]**
* **A-4 `--help` and usage generation** from the same declaration the parser uses,
  so an app cannot document one flag set and parse another.

### A-3 · `medium` · Config scalar types belong in `lib/cfg` · **[done]**

`DurationMs`, `ByteSize`, `parseDurationMs` and `parseByteSize` lived in
`app/bus/config/root.zig` and were the only copy. A duration grammar and a size
grammar are not NATS behaviour - `kvs`, `scp` and the CLI all take durations and
sizes in the same two shapes - so an app file was the wrong home.

**`app/cfg/lib/scalar.zig`** now holds them, and `app/cfg/lib/root.zig` re-exports them
both flat (`cfg.parseDurationMs`) and as a namespace (`cfg.scalar`).

**The file follows the file-as-type rule, which shaped the re-exports.** The file's
own scope *is* `DurationMs`, so `scalar.DurationMs` does not exist - writing it is
a compile error, and this was hit while wiring it up:

```
app\cfg\lib\root.zig:89:30: error: root source file struct 'scalar'
  has no member named 'DurationMs'
```

The correct spellings are `cfg.DurationMs = scalar` and
`cfg.ByteSize = scalar.ByteSize`. `ByteSize` is a declaration *inside* the file, so
it keeps the dotted form - the same asymmetry that `style.zig` has, and the reason
the helpers-stay-inside rule exists.

**The re-export is what keeps the blast radius at zero.** `app/bus/config/root.zig`
re-exports the types, so the 12 `Config.DurationMs` / `Config.ByteSize` field
declarations in `app/bus/server/config.zig` and all 32 internal uses are untouched.

*Two build-graph edges this needed, both previously absent:*

1. The bus `config` module was declared with **no imports at all**
   (`b.createModule(.{ .root_source_file = ... })`), so `@import("cfg")` could not
   resolve. It now has the `cfg` edge.
2. `build/bus.zig`'s `depsOf`/`moduleOf`/`Imports` closure needed a `cfg` entry,
   and `build.zig` needed to pass `cfg_mod` through - the closure table panics on
   an unknown name, which is that guard working.

*A collision this surfaced:* `app/bus/config/root.zig`'s test had a local
`const cfg = try mgr.get(...)`, which at file scope shadowed the new module import
(`error: local constant shadows declaration of 'cfg'`). Renamed to `got`. Same
class as `spin_lock`'s `lock` and `slab`'s `alloc`.

*Verified:* the three grammar tests moved with the code and now run under
`test-lib-cfg`, which went **3 -> 10 tests**. Total `test-lib` **264 -> 267**.
`zig build` 48/48, `test-scp` 33/33, `test-bus-direct` 16/16.

### A-1 · `high` · One argv parser for the whole repository · **[library done + aliases/required added; kvs, scp relay/receive/send, bus nsc migrated; bus server layer stays (A-1b)]**

Measured first, because the three apps turned out to need three different things
— and none of them needed the comptime command tree:

| App | Argument handling today | Size |
|---|---|---|
| `app/kvs` | an `if/else if` chain of `std.mem.eql` | **26 lines** |
| `app/scp` | argv[0]-basename dispatch + three near-identical `Args.parse` loops | **140 lines** |
| `app/bus` | flags folded into a string-keyed store, hydrated later | 48 lines, plus a 395-line store |
| `app/cli` | the `lib/cli` comptime framework | n/a |

*What landed:* **`lib/util/argv.zig`** — a parser, not a framework, deliberately
placed in `lib/util` rather than `lib/cli` so a server binary can use it without
pulling in the whole CLI stack. It handles `--key value`, `--key=value`, short
options (`-p 8080` and `-p8080`), clustered shorts (`-va`), `--`, `--no-<flag>`,
optional and repeated options, and declared positionals. Three behaviours are
**new relative to every app that adopts it**, and each is a bug fix:

1. an unknown option is a **named error**, not silently ignored (all three apps
   silently ignored unknown options);
2. a repeated option is an **error** unless declared `.multiple`, not silent
   last-wins;
3. `--key=value` works — none of the three apps supported the attached form.

`argv.Failure.message(writer)` lets each app report in its own voice rather than
the library printing for it.

*First app migrated:* **`app/kvs`**. Its `persistence.Config.parse` is now a
9-entry spec table plus a `@hasField`-driven binder, with the `Config` struct and
every downstream call site untouched. Verified against the real binary:

```
$ kvs --nonsense            kvs: unknown option '--nonsense'         (exit 1)
$ kvs --port abc            kvs: invalid value 'abc' for option '--port'  (exit 1)
$ kvs --port 1 --port 2     kvs: option '--port' given more than once (exit 1)
$ kvs --port=7799           starts and serves
```

Note the exit path: a mistyped option now prints one line and exits 1 rather than
returning an error, because a returned error makes Zig dump an error trace and
stack trace for a typo, which reads like a crash.

*Two bugs found and fixed while doing this, both worth not repeating:*

- **`Args.toSlice` must not be freed.** It allocates one combined buffer and
  returns a *sub-slice* of it, so `allocator.free(args)` panics with
  `Invalid free`. This bit immediately: every error path crashed. The fix is the
  documented `std.process.Args.Iterator` and its `deinit`. Four existing call
  sites in this repo use `toSlice` with an arena and never free, which is why the
  trap had not been hit before.
- The first cut of `kvs`'s binder compared field names with `comptime
  std.mem.eql`, which is comptime control flow inside a runtime block and does
  not compile. `@hasField` is the right tool.

#### `app/scp` migration · **[relay + receive done, send left]**

`scp` had **three** near-identical parsers. The first two are migrated:

| Command | Was | Now |
|---|---|---|
| `relay` | 21-line `if/else if` chain | 3-spec table |
| `receive` | 39-line chain | 8-spec table |
| `send` | 140-line chain | **not yet** |

All three had the same latent bugs, and both migrated commands fix them:

1. **Unknown options were silently ignored.** `scp relay --nonsense` used to
   start a relay and ignore the typo; it now exits 1 with
   `scp relay: unknown option '--nonsense'`.
2. **A bad port value silently became a default.** `--port abc` read
   `std.fmt.parseInt(u16, ...) catch 3478` in `relay` and `catch 9000` in
   `receive`, so a typo bound the wrong port instead of saying so. Now:
   `invalid value 'abc' for option '--port'`.
3. **`--key=value` was unsupported.** Now works, verified against the binary.
4. **A repeated option was silent last-wins.** Now
   `option '--port' given more than once`.
5. **`receive`'s `--out-dir` was declared on `Args` and never parsed** - the flag
   the struct advertised had no effect. It now parses.

Two behaviours were **deliberately preserved** rather than "fixed", because
changing them is a product decision, not a refactor: `receive`'s `transfer_code`
is declared an *optional* positional so a missing code still reports
`error.MissingTransferCode` instead of a generic parse failure; and `send` is not
touched yet.

#### A new library capability this needed: `Spec.field`

`argv` matched options on `name` (the CLI spelling) and a name-driven binder then
looked for a struct field of the same name. That breaks the moment the two
legitimately differ: `--public-ip` binds to `public_ip`, `--headless` to
`is_headless`. `Spec` gained

```zig
field: []const u8 = "",          // empty means "same as name"
pub fn fieldName(self: Spec) []const u8
```

so the CLI keeps its natural kebab-case spelling **and** the struct keeps its
natural snake_case field, with neither lowered to suit the other. Covered by a
new `argv` test asserting that `field` is a *binding target, not an alias* - the
snake_case form is still an unknown option.

#### A wart found, not fixed

`argv` reports a **missing required positional** as
`Failure.missing_value`, whose message renders as
`option 'transfer-code' requires a value`. The wording is written for options;
for a positional it reads wrong. It is why `receive` declares its positional
optional and does its own check. Worth a dedicated
`Failure.missing_positional` variant.

#### Still to do

`scp cmd/send.zig` (the largest parser, 140 lines) and the bus's flag layer.
`app/cli` is already on the framework, which parses independently - unifying the
two parsers is its own item.

#### `app/bus/cmd/nsc.zig` migration · **[done]**

`nsc` had **two** hand-written option loops (`generate nkey`'s `--type`, and
`generate operator|account|user`'s `--name`/`-o`/`--output-dir`/`--operator`/
`--account`). Both are now one spec table each, and `-o` is a declared short
rather than a second string comparison.

*Verified against the binary:*

```
$ bus-nsc generate nkey --type operator     seed + public key
$ bus-nsc generate nkey --type=account      works (attached form was unsupported)
$ bus-nsc generate nkey --bogus             nsc: unknown option '--bogus'
$ bus-nsc generate nkey --type a --type b   nsc: option '--type' given more than once
$ bus-nsc generate nkey                     generate nkey requires --type <operator|account|user>
$ bus-nsc generate operator --name acme -o <dir>    writes acme.nk + acme.jwt
$ bus-nsc generate account --name acct --operator <acme.nk> --output-dir <dir>   writes acct.nk + acct.jwt
```

The command-specific "requires --type" / "requires --name" messages are
**preserved**: a *required* option is still checked by the caller via `orelse`,
because `argv.Failure` has no "required option absent" variant. Adding one would
let `nsc` drop that duplicated check.

*Two build-graph defects this exposed:*

1. `bus_nsc_exe` imported only `nsc`, so `@import("util")` did not resolve. Fixed
   by adding `util` to that executable's import list **and** threading `util`
   through `build/bus.zig`'s `depsOf`/`moduleOf`/`Imports` tables - the closure
   table panics on an unknown name, which is exactly that guard working.
2. **`cmd/nsc.zig`'s tests were never collected.** `test-bus-nsc` points at
   `lib/nsc` (`nsc_mod`), not at the command source, and a binary source file is
   only compiled by a test root. Added `test-bus-nsc-cmd` (`test_roots` grew
   6 -> 7), which is why `test-bus-direct` went 14 -> 16 steps. The newly-collected
   test immediately found a real leak in the helper (a `StringHashMap` never
   freed); fixed by handing ownership to the caller with a documented `deinit`.

#### The bus's remaining flag layers, and why they should stay · **[decision recorded]**

Measured after the `nsc` migration. The bus has **three** flag-handling sites and
none is a candidate for `argv.parse`:

| Site | What it is | Verdict |
|---|---|---|
| `config/flags.zig` (48 lines) | A **type-erased sink**: `-x v`, `--long v`, `--long=v`, and bare `-D`/`-DV`/`-h`/`-V` stored as `"true"` into the string `Manager`. It cannot enumerate its options because the bus's config *schema* defines them. | **Keep.** A fixed spec table is the wrong shape - A-2's decision restated at the flag layer. |
| `main.zig:503-520` | `--config`/`-c`, `--config=`, and `-t`. | **Keep for now** - two library gaps block it, below. |
| `main.zig:1014-1022` | `--cores N`. | Migratable, but a one-option spec table for a value with a silent-parse fallback is not worth the churn alone. |

**Two concrete gaps block `main.zig`'s config block:**

1. **No multi-name alias.** `Spec` has one `name` and one optional `short`. The bus
   accepts `--config` *and* `-c` for the same value. `Spec` needs
   `aliases: []const []const u8` so two spellings do not become two specs racing
   to write one field.
2. **`-t` is not a config alias.** It is the **config-check mode selector**:
   `-t <file>` parses the file and exits without starting the server, and
   `app/bus/testing/integration/phase78.zig` asserts that behaviour. It merely
   reuses the config-path slot to carry its file. Modelling it as an alias of
   `--config` would be wrong; it wants a flag spec plus its own mode handling.

**The honest position on A-1: the library is done, and four parsers across `kvs`,
`scp` and `bus` are on it.** The bus's remaining sites are either type-erased by
design or blocked on the two gaps above. Recording that is worth more than a fifth
migration that would misrepresent `-t`.

### A-1b · `Spec.aliases` and `Spec.required` · **[library done; the bus migration was REVERTED - see below]**

Two capabilities were added to `lib/util/argv.zig`, and both stand on their own
merit with 3 new tests (`test-lib` 224 -> **227**).

**1. `Spec.aliases`** - several long names for one spec:

```zig
.{ .name = "config", .aliases = &.{"c"}, .kind = .option }
```

Without it, `--config` and `-c` become two specs racing to write one field, which
silently makes the second spelling last-wins *across specs*.

**A single-character alias is NOT reachable as `-x`.** `findShort` matches
`short`; an alias is only ever matched after `--`. Reaching for
`aliases = &.{"t"}` to mean `-t` fails with `unknown option '-t'`, which is exactly
how this was found. Use `short` for `-x`, `aliases` for extra `--long` spellings.

**2. `Spec.required`** plus `Failure.missing_required`, so a caller stops
hand-rolling the same `orelse` check per option. `Failure.missing_positional` was
added in the same pass, because a missing positional previously reported
`missing_value` and rendered as `option 'transfer-code' requires a value` -
wording written for options, applied to an argument.

#### `app/bus/main.zig`: migrated, then **reverted** - and that is the finding

The migration was written, built, and looked correct in spot checks. It was then
**reverted**, because the integration suite proved the premise wrong.

**What broke.** `test-bus-integration` went from passing to a consistent
`[FAIL] p0: server keepalive: error.ServerStartTimeout`, reproducibly across runs.
The cause:

```zig
// app/bus/testing/integration/phase0.zig:77
.extra_args = &.{ "--ping-interval-ms", "200", "--max-pings-out", "2" },
```

Those are **valid** server flags. They are not in any fixed table, because they are
config *schema* field names:

```zig
// app/bus/server/config.zig
ping_interval_ms: Config.DurationMs = .{ .ms = 120_000 },
max_pings_out: u32 = 2,
max_payload: Config.ByteSize = .{ .bytes = 1_048_576 },
```

The old path accepts them because `Config.flags.parse` hands *any* flag to the
type-erased string store, and `Manager.set` keeps the key verbatim for typed
hydration to resolve later. A declared spec table rejects them at parse time.

**So the conclusion recorded in the previous round was wrong, and this round
corrected it by measurement.** A fixed spec table is *structurally* the wrong shape
for the bus, for the same reason A-2 gives about `cfg.Manager`: the bus's flag
surface is defined by its config schema, not by a list anyone can enumerate. My
"complete set" was complete for the flags I found, and the flags I did not find
were the ones that mattered.

**What this cost, stated plainly.** The migration was reverted wholesale rather
than patched, because every patch widens the table toward "accept anything", which
is what the old code already did - with less machinery. `git checkout --
app/bus/main.zig` restored it; `test-bus-integration` returned to passing.

**Two things worth keeping from the attempt:**

- `testing/server_manager.zig` passes `-p <port>` and `--auth <token>` to every
  spawned server. A table-based migration has to include them or *every*
  integration server fails to start, which is a fast, loud failure - better than a
  silent one.
- The `util` import edges added to `bus_exe` and `bus-server-js` are **kept**:
  `cmd/nsc.zig`, `shared/nkey.zig` and `shared/telemetry.zig` all import `util` by
  name, so the edges are real regardless of this revert.

**Where the bus actually stands on A-1:** `kvs`, `scp` (all three parsers) and the
bus's `nsc` command are migrated, and those are the parsers with a **fixed** flag
surface. The bus server's own two layers stay as they are, now with a measured
reason rather than an assumption. Both are A-2's decision seen from a different
angle, which makes A-2 the more load-bearing item of the two.

### A-2 · `high` · The bus must NOT be forced onto `cfg.Manager` · **[decision recorded]**

The audit settled this with numbers, and the answer is uncomfortable but clear.
The bus's config layer (843 lines) and `lib/cfg.Manager` are **two different
designs, not two implementations of one**:

- `Manager` is a single-typed resolver: struct defaults → one prefixed env
  convention (`PREFIX_FIELDNAME`) → JSON → typed overrides.
- The bus needs a **type-erased string store** with **four key spaces per field**
  (short flag, long flag, env, conf) looked up in a fixed precedence, per-field
  key overrides, `skip`, `flatten`, nested-namespace prefix accumulation,
  cross-key aliases, dynamic key spaces (`accounts.<NAME>.*`,
  `resolver_preload.<KEY>`, `tls.sni_certs`), and typed hydration of **94 fields
  across 13 structs** at a `@setEvalBranchQuota(20_000)`.

Reaching parity would mean adding all thirteen missing capabilities into
`lib/cfg`, at which point the library *is* the bus's config module and 843 lines
have been re-typed rather than deleted — while 99 `self.cfg.*` reads and the
by-value threading model stay put.

**So the bus keeps its own layer, and shares only the genuinely generic pieces.**
The strongest argument for ever revisiting this is not tidiness: the bus's
`ServerConfig` is copied per worker thread and its SIGHUP reload allocates ~30
strings it never frees. That leak is real and should be fixed **in the bus**,
where the lifetime constraint actually lives.

*Do not* add the bus's store as a third resolver shape next to `cfg.Manager` and
`cfg.loader`. If a shared store+meta layer is ever built, it should replace
`Manager`, not sit beside it.

### A-3 · `medium` · Known library gaps the app audits named, ranked by value per line

Each is a concrete, named requirement from a real app — which is the only
justification this file accepts for extending the library.

| # | Gap | Evidence | Why it matters |
|---|---|---|---|
| 1 | `cli.ExitMap` carries only `{name, code}`, printed as `"Error: {s}"` with the error name | `app/scp/main.zig:67-98` maps six errors to codes **and prose**; there is nowhere for the prose to live | The one framework-shaped thing `scp` already has cannot be expressed. Highest value per line. |
| 2 | `cli.run` builds a `Ctx` that omits the required `env_map` and `io`, and returns exit 0 on every failure | `cli.zig` `run`; `app/cli/main.zig:56-65` hand-builds its own `Ctx` as a workaround | This is *why* the framework's own consumer bypasses it, and it makes `lib/cfg` and colour unreachable through `lib/cli`. |
| 3 | `cli.Ctx.color_enabled` is never set true anywhere, and `is_tty` is one bit taken from **stdin** | grep finds only the declaration and a forced `false` in the REPL ctx; `scp` writes progress to **stderr** | Per-stream TTY facts are needed before any renderer can be shared. |
| 4 | `cli.progress` has **no TTY/headless gate** and is inherently multi-bar | it always emits cursor-up and colour | Migrating `scp`'s `cmd/ui.zig` to it would silently break `scp --headless`. |
| 5 | `lib/cfg.Manager.get()` returns `ConfigT` **by value** | `kvs` `CONFIG SET` genuinely mutates five config fields at runtime | Without a mutable accessor, `lib/cfg` can only *produce* a config, never own one. Blocks `kvs` adoption. |
| 6 | `argv` has no typed values or `--help`/usage generation | `Failure.invalid_value` is declared but never produced; `value_hint`/`default_text` are help-only and unused | Each app currently reparses strings by hand, as `kvs` does. |
| 7 | `argv` positionals are all-or-nothing required | `scp field <code>` is zero-or-one | Needed before `scp`'s `receive` can migrate. |

### A-4 · `medium` · Two real app bugs the audits found

Neither is a library problem; both are recorded because leaving them would mean
the next migration "fixes" or preserves them by accident.

- **`scp --out-dir` is dead.** `receive.Args.out_dir` is declared and consumed but
  **no branch of `parse` assigns it**, so it falls through to the drop-everything
  `else` and extracted files always land in the CWD. Whoever migrates `scp` must
  decide the contract deliberately and test it.
- **`scp --port <bad>` silently becomes 9000**, in both `send` and `receive`
  (`catch 9000`). `argv` rejects a bad value. That is the correct behaviour, but
  it is an observable change on a networking path, so it needs a deliberate call
  rather than arriving as a side effect.

---

## 3b-3. `cfg` as a standalone binary · **[done]**

The specification describes two tools - `cli` for workspace work and `cfg` for
configuration - and both existed only as subcommands of `tigershark`, so a machine that
needed `cfg get` installed the component registry, the scaffolder and the REPL with it.

`build.zig` now produces a second executable, `zig-out/bin/cfg`, whose root mounts the
configuration commands **directly** (`cfg get port`, not `cfg config get port`).

`app/cfg/main.zig` sits at `app/cfg/main.zig` rather than `app/cfg/main.zig`, and that
location is load-bearing: `app/cfg/root.zig` **is** the module root, and a second file in
that directory claiming the same module name fails with
`error: file exists in modules 'root' and 'app_cfg'`.

Two further traps, both measured:

* The executable's own module needs the **same import table** as `app_cfg`, not a subset.
  Naming a nested declaration from `cmd/` compiles those files against the *executable's*
  table, and a missing entry is reported against the deep file
  (`app/cfg/cmd/exporter.zig:14: no module named 'cfg'`), which points away from the cause.
* `Commands(...)` returns a **type**, and its per-command declarations resolve through
  `Group.export_cmd` (type access), not `group.export_cmd` (instance access). The instance
  form fails with `no field named 'export_cmd'`.

The workspace tools are absent by construction and a test asserts it: `cfg add`,
`cfg init` and `cfg repl` all exit 127.
## 3b-4. `app/cfg/lib/toml_doc.zig` - the mutation blocker, resolved · **[done]**

Four commands needed to *mutate* a config file without destroying it, and none could be
built on what existed. `toml_mutator.zig` matches lines by text, so it cannot tell `port`
under `[database]` from a root `port`, cannot keep a multi-line value, and re-emitted keys
with no indentation while preserving only a trailing comment.

`app/cfg/lib/toml_doc.zig` is a comment-preserving document model. **A file that is not
modified round-trips byte for byte** - asserted, not assumed - because it stores every
original line and replaces only the lines a mutation changes.

Three bugs found and fixed while building it, each measured:

* **A new root key landed inside the last table.** Appending at the end put
  `current_context` under `[contexts.prod]`, where it was unreadable as a root key. Root
  keys now insert before the first header.
* **A new root key ran into the following header.** The insert landed at the header's
  index, which *is* the author's blank line, so the key went above the gap. It now inserts
  after the last content line before the header, reusing the file's own separation.
* **The gap before a trailing comment was lost.** `port = 8080  # note` came back with one
  space instead of two, so the model did not round-trip a line it had edited. The gap is
  now part of the line record.

That unblocks `config set`, `config del`, and the same model is what `config format` and
`config profile switch` need. `set` infers a value's type (numbers and booleans bare, text
quoted) with `--string` to override the inference, and `del` reports a miss rather than
treating it as success.

`config set` and `config del` take a **file** (`--file`, required), not a path into a
resolved config, and that is deliberate: defaulting the target would mean a mistyped
command silently rewriting whichever file happened to be conventional.
## 3b-5. Secret commands, and a module that was in the wrong library · **[done]**

`config encrypt`, `config decrypt` and `config redact` now exist. The cryptography was
already correct after the KDF fix; what was missing was a way to *reach* it, because
`encrypted_config.zig` lived in `app/cli/lib/secrets/` and the config operations in
`app/cfg/lib/ops` may not import `lib/cli`.

That was the same miscategorisation already fixed for `systemd_exporter`: the file imports
**only `std`** and is configuration functionality, so it belongs in `lib/cfg`. Moved, with
`lib/cli` re-exporting it so `cli.encrypted_config` keeps resolving. One consequence worth
noting: its 7 tests moved from `test-lib-cli` to `test-lib-cfg`, and the test count is
unchanged - the relocation was verified by comparing per-root counts, which is the check
`app/cli/lib/ROADMAP.md` M-2 prescribes and the one that caught the earlier silent loss.

Three decisions in the commands:

* **The passphrase never comes from a flag.** It is read from `CONFIG_PASSPHRASE` (renameable
  via `--passphrase-env`, which names the variable rather than carrying the value). A
  passphrase on a command line is visible in the process list and written to shell history,
  and this is the tool whose purpose is protecting secrets.
* **`redact` prints and never writes.** Its purpose is producing something safe to paste
  into a bug report, so the destination is a clipboard or a pipe. Writing it back would
  destroy the file it was asked to sanitise.
* **Decryption fails closed with a message.** `AuthenticationFailed` cannot distinguish a
  wrong passphrase from a corrupted blob, so the message says both rather than guessing.

**One claim of mine was wrong and is corrected here.** A test asserted that redaction is
idempotent. It is not: the placeholder `[REDACTED len=6]` itself contains `len=`, so a
second pass redacts the placeholder's own text length (`len=16`). That is harmless - no
secret is involved in either string - and the property worth keeping, now asserted instead,
is that no number of passes makes the original value or its exact length recoverable.
## 3b-2. Security defects · **[all three FIXED]**

Detailed in `app/cli/lib/secrets/encrypted_config.zig`, `app/cli/lib/secrets/secret_val.zig` and
`app/cfg/lib/config_lineage.zig`, each with the measurement inline. Summary, because two of
the three were described wrongly here for several revisions:

**(1) Configuration encryption KDF.** Was a **single unsalted, uniterated SHA-256** over
`"tigershark-cfg-salt::" || nonce || "::" || passphrase`, with the **nonce used as the
salt** - a value the payload stores in the clear. Work factor 1: a GPU tests billions of
passphrases per second. Now PBKDF2-HMAC-SHA256 with a **random 16-byte salt** drawn from
`std.Io.random`. Format is `[0x01][salt][nonce][tag][ciphertext]`; the **legacy format is
still decryptable** so existing blobs are not orphaned, though nothing writes it.

*Iterations are 100,000, not OWASP's 600,000, and that gap is a measured compromise:*
at 600,000 the module's own tests exceeded the test runner's watchdog in a Debug build,
which would have made the correct value unshippable. Recorded in the constant's doc
comment rather than left as a silent shortfall.

**(2) `secret_val.expose()`.** Was an `Exposed{value, parent}` guard that was **copyable
while owning destruction**, so a copy became a dangling view. Refined against this
file's earlier claim: the second `destroy()` was a **safe no-op** (`deinit` guards on
`buffer.len`), so the hazard was **read-after-free through the copy**, not a double free.

Fixed by removing the guard rather than hardening it: `bytes()` and `value()` now
**borrow**, and `wipe()` zeroes contents without ending the lifetime. There is no handle
left to duplicate. The guard's only benefit was automatic wiping at a point the caller
chose anyway, which `deinit` already provided.

**(3) `config_lineage.record`.** `fetchPut` returns the map's **own** key, and the code
freed it, leaving the map holding a dangling key. The old description here ("it can free
the `""` literal") was wrong in both directions - nothing frees the literal, and the real
problem is the stored key. Measured before the fix: `getProvenance("a.b")` returned
**null** after a second `record`, then `deinit` reported a double free plus a leaked key.
Fixed by taking the update path explicitly so the stored key is reused and never freed.
## 3b-1. Unknown subcommands exited 0 · **[FIXED]**

**Resolution.** Fixed by separating the two things the earlier attempts conflated.

`execute` now delegates to `executeFrom(cmd, ctx, args, chain, arg_start)`, which keeps
`args` **whole** and moves only the position routing starts at. A parent recurses with
the same `args` and `cursor + 1`, recording the matched token's position in
`chain.subcmd_indices` so the leaf's `parseFlags` skips it - the invariant the earlier
attempts broke by slicing.

One further step was required and is easy to miss: a command invoked **directly** carries
its own name at `args[0]` (`execute(CustomCmd, {"custom", "--ip", ...})`,
`app/cli/lib/test/cli_test.zig:300`), so that position must be skipped **and recorded**, not
merely stepped over. Without recording it the leaf parses the command's own name as a
positional - measured as `error.TooManyPositionalArguments` for
`{"proot", "child", "hello"}`, where `hello` was the only real positional.

With routing correct, an unmatched token can finally be judged on its own terms: it is
rejected when the command declares no positionals, or when its flags are an anonymous
struct (the historical typo path). `is_repl` is exempt because a REPL command has no
`run` by design.

Measured after:

```text
config lint        -> 127   config inspect port -> 0
config foo export  -> 127   config export       -> 0
update / bench     -> 127   config get port     -> 0
config exportt     -> 127 (Did you mean 'export'?)   repl / --help -> 0
```

Four regression tests at the end of `app/cli/lib/test/cli_test.zig` pin it: rejection of an
unmatched token on a command *with* a body, an unmatched token not being satisfied by a
later valid one, a valid subcommand keeping its positional, and the suggestion text.
They call `execute` directly rather than `TestHarness`, because the harness reconstructs
its `Allocating` writers per `run` and its buffers are not readable afterwards.
**Symptom.** Every unimplemented command is a silent success.

```text
$ tigershark config get port   -> prints the whole config,  exit 0
$ tigershark update            -> prints the root banner,   exit 0
```

This is why the 26 missing features in the spec all "passed" a smoke test. A script
cannot distinguish a working command from a missing one.

**Root cause, measured.** `execute` recurses with the **full** `args`
(`cli.zig`, the `execute(subcmd, ctx, args, chain)` calls), not the tail after the
matched token. So `config` receives `["config", ...]` and its routing loop tests its own
name against its own children, matching nothing. The old code absorbed that by ignoring
unmatched tokens whenever the command had a `run` - and `config` has one - so routing
moved on and executed the next recognised subcommand anywhere in the tail. That is why
`config foo export` ran `export`.

**Why the obvious fix does not work.** Passing `args[cursor + 1 ..]` fixes the
re-testing but breaks two invariants at once, both measured:

1. `chain.subcmd_indices` stores indices **absolute into `args`**, and `parseFlags`
   uses them to skip subcommand tokens (`for (chain.subcmd_indices[...]) if (i == subcmd_idx) continue :args_loop;`).
   With a sliced `args`, those indices no longer line up and positionals are lost -
   `config inspect port` printed every field instead of `port`.
2. Leaf commands rely on the full `args` so the filter can skip the parent tokens.

So the widening must be paired with making the index bookkeeping relative, which is a
change to the routing core rather than a guard.

**What is in place now.** The typo path is intact and pinned by
`app/cli/lib/test/cli_test.zig:762` (`logni` -> "Did you mean 'login'?" +
`expectError(error.UnknownCommand)`), and it deliberately keeps the **original**
condition `!@hasField(CmdType, "run") or @TypeOf(cmd.run) == @TypeOf(null)`.
`@TypeOf(cmd.run)` is the type `?*const fn`, which never equals `@TypeOf(null)`, so any
command built through `App.Command` skips this branch. Narrowing it to `!hasRunBody`
measured as safe (root typos and `repl` both behaved identically), but it was reverted:
changing a pre-existing branch with no functional gain is not worth the risk, and it
does not fix the defect either - the guard is about the *typ* path, not the fall-through.

**Four attempts measured, all reverted.** Recorded so the next attempt does not
repeat them; each is a dead end for a specific reason.

| Attempt | Result |
|---|---|
| Widen the rejection guard to `!hasRunBody and !declaresPositionals` | `config` rejected (the block fired at the root for the literal token `config`), then `repl` rejected (no `run` by design), then the typo test failed. Root cause of the first: `routed` was a flag the loop set, but reaching the block *already* means nothing matched, so the guard was dead code and the block fired on the match path too. |
| Recurse on `args[cursor + 1 ..]` | `config inspect port` lost `port`. The tail drops the command name that callers put first - `app/cli/lib/test/cli_test.zig:300` passes `{"custom", "--ip", ...}` - and `parseFlags` relies on `subcmd_indices` to skip routed tokens, so a leaf started parsing at the wrong element. |
| Tail + record index 0 | Leaf skipped its first real argument. Same cause. |
| Add `arg_base` to make indices absolute | Six tests failed (`Deeply nested subcommand routing`, `Short Flags: Grouping`, `Validation Failure: Missing required flags`, `Help Text`, `Custom Parser and Validator`, `In-Memory Testing Harness`). The offset is not the whole story; `subcmd_indices` is consumed against the array each leaf parses, and those two disagree once `args` is sliced. |

**Do not start from a guard.** Start from the data flow: decide whether `args` is
absolute (current) or per-level (attempts 2-4), then make **both**
`chain.subcmd_indices` and every `parseFlags` site agree with that choice before
touching the rejection. The rejection is the last step, not the first.
**Fix sketch for whoever takes it.** Make the recursion pass the tail, and store
`subcmd_indices` relative to the `args` slice each `execute` receives - or drop the index
array and have `execute` receive args already stripped of parent tokens. Then an
unmatched token at a command that has subcommands can be rejected unconditionally
regardless of whether it has a `run`.
## 3c. Proposed-feature intake: daemon mode, undo ledger, locks, auto-TUI, SHM, LLM router, config suite

### `app/cfg` split into `ops` + `cmd` · **[done]**

The config commands were unreachable from `app/kvs` and `app/scp`, which import zero
files mentioning `cli` (measured). `app/cfg` therefore ships both halves:

| Module | Source | Imports | Callers |
|---|---|---|---|
| `app_cfg` | `app/cfg/root.zig` | `cli`, `cfg`, `util` | binaries with a `cli.App`, and - through its `ops` surface - any binary |

`ops` is a folder of that module (`app/cfg/lib/ops`), not a module of its own. It was
one (`app_cfg_ops`, source `app/cfg/ops/root.zig`, imports `std`/`cfg`/`util`) until
the two were merged; that merge is what removed the second test root, and it costs the
import table that made a `cli` import under `ops/` a build error.

Shipped commands: `config export` (`--format dotenv|systemd`), `config dry-run`
(`--overrides`), `config inspect` (`[path]`), `config schema` (`[output]`), and bare
`config`. Per-root test counts: `test-app-cfg` 51 (33 operations + 18 command group,
in one root), `test-kvs-config` 4 (the reachability guard, in a module that names
`cfg` and no `cli`).

**Two file moves were forced by this, and both are the pattern U-0 describes:**

* `systemd_exporter.zig`: `app/cli/lib/platform/` -> `lib/util/`. It takes a
  `std.Io.Writer` and a slice of key/value pairs and mentions no terminal, no flag
  and no command, which is `lib/util`'s stated criterion. `lib/cli` re-exports it
  under its historical name, so no caller changed.
* `parseValue` was added to `app/cfg/lib/scalar.zig`, next to the duration and byte-size
  grammars it complements. `app/bus/config` had grown its own copy; `ops/dry_run`
  needed the same answer.

**Three traps worth recording, each measured:**

1. `App.Command(...)` returns a **type whose field is named `command`**, so a
   per-command file cannot also export a function named `command` returning that
   type: `error: expected type 'type', found '...CommandWithReturn(...)'`. The
   command declarations therefore live in `cmd/root.zig`, and each child file owns
   only its flags and its `run` body.
2. `App.Flags(X)` is `X` **merged with the global flags**, so it is a different type
   from `X` and cannot be passed as one. Runners rebuild the plain struct.
3. `refAllDecls` **cannot cross a module boundary**. When `ops` became its own
   module, `test-app-cfg` fell from 34 to 15 tests while `zig build` stayed green;
   the tests were recovered with a second root, `test-app-cfg-ops`. (Merging that
   module back is what removes the root again: the operations are files of
   `app_cfg`, so `refAllDecls(ops)` in `app/cfg/root.zig` collects their 47 tests
   into `test-app-cfg`.) Compare **per-root** counts after any module split, not the
   total.

A further trap cost real time and is recorded because the fix was structural:
`error: unable to resolve comptime value` appears when a **runtime** path is compared
against a **comptime** `field.name` inside an `inline for`. No amount of restructuring
the caller fixes it; the reflection must be inverted into a comptime-built table that
the runtime path is looked up *in*. That table is `app/cfg/lib/ops/fields.zig`, and it
carries per-field function pointers for the type-dependent work, because Zig cannot
store a `type` in a runtime-readable table and a function pointer cannot take
`anytype`.

### Owner constraints on the config suite · **[binding, decided]**

Two constraints were set for the config-management work, and they are **decisions,
not open questions** - recorded here because a later reader will otherwise
re-propose both:

**1. No compilation at runtime.** The config system must never invoke a compiler and
never execute a produced artifact. This **removes feature 3.2** ("comptime user
configs"), whose definition is invoking the Zig compiler at run time and consuming
its output. The *goal* survives as a comptime-imported config module compiled with
the build - `app/cfg/PLAN.md` records the replacement options and recommends that
one.

**2. No background threads.** The config system must never own a thread that does
work on its own schedule. Anything specified as a poller becomes **a function the
developer calls when they choose.** This removes the *poller* from feature 1.2
(OTA flags) while leaving its registry intact: `app/cfg/lib/ota_flags.zig` is already
100% synchronous - `setFlag`, `isEnabled`, `assertAllowed`, `loadFromJson` - so the
thread was only ever going to be a caller of it.

**The posture this produces, stated plainly:** a config load performs no work the
developer did not ask for. No implicit network call, no timer, no cache refresh
behind the caller's back. A refresh happens when a line of code says so. That is a
security property, not just a style preference - it is what makes "the config
system started a thread" and "the config system made a request" impossible to write
by accident.

**Still open after both constraints:** features 1.1 and 1.2 remain *allowed* but each
still needs an explicit decision, because both add an outbound HTTP client to a
config path that currently performs no network I/O. When they land, the fetch is
`remote_config.refresh(io, ...)` / `ota_flags.refreshFromUrl(io, ...)` - a call, not
a wire-up into `App.run`.

### The original spec assessment

A specification was supplied for seven large feature areas (a sub-millisecond
daemon RPC mode, an undo/redo ledger, inter-process mutex locks, an auto-TUI
`--ui` mode, shared-memory pipes, an LLM natural-language router, and a
`config` subcommand suite: setup/doctor/backup/restore/sync/eject). It reads as a
generic template — it names a binary `mycli` and a framework `zcli` that appear
nowhere in this tree (`zcli` occurs 0 times).

Rather than start implementing, this section records what a check against the
actual code found, because **the specification's prerequisites do not exist here
and one of them was a show-stopper**.

### P-1 · `high` · `App.run` could not compile — five independent faults · **[done]**

Every one of the seven proposed features has to hook `App.run`: a daemon check, a
lock, an `--ui` interception, a ledger write, an exit code. So the first thing to
verify was that the function exists and works. It did not compile, **in five
separate ways**, none of which anyone had noticed because **no caller existed**:
`app/cli/main.zig` hand-built its own `Ctx`, its own buffered writers and its own
`ExecutionChain`, so the framework's own entry point bypassed the framework's own
entry point.

The five faults, in the order the compiler revealed them once the function was
actually instantiated:

| # | Fault | Correct form |
|---|---|---|
| 1 | `Ctx{...}` omitted `env_map` and `io`, both required fields with no default | set both from `init` |
| 2 | `init.minimal.args()` — `minimal.args` is a `std.process.Args` **value**, not a function | `init.minimal.args.toSlice(...)` |
| 3 | `std.ArrayList(T).init(alloc)` — that constructor does not exist in 0.16 | `std.ArrayListUnmanaged(T).empty` + allocator-passed `deinit` |
| 4 | `Ctx(.{}){...}` and `ExecutionChain(.{}).init(...)` — these are types inside the closure, not functions | `Ctx{...}`, `ExecutionChain.init(...)` |
| 5 | `init.io.stdin.reader()` — `stdin`/`stdout`/`stderr` are on `std.Io.File`, not `std.Io`, and `isTty` is a `File` method returning `Cancelable!bool` | `std.Io.File.stdin().reader(init.io, buf)`, `.isTty(init.io) catch false` |

*What landed:* all five fixed, plus three things the old body got wrong or lost:

- **Buffered writers sized from the framework `Config`.** `Config` already
  declared `in_buffer_size`/`out_buffer_size`/`err_buffer_size` and nothing used
  them. Using them matters: the naive `init.io.stdout.writer().any()` is
  unbuffered, so a command printing a table would issue one write per line.
- **A real exit status.** The old body caught every error, printed
  `"Command failed: {s}"` and returned, so a failed command exited 0. It now
  flushes and calls `std.process.exit(getExitCode(err))`, which is what the
  `exit_map` in `Config` was always for.
- **`app/cli/main.zig` now calls `App.run`** instead of duplicating it, which is
  what actually verifies the path. This is the fix for the *class* of bug, not
  just the instance: while the only consumer hand-rolled the bootstrap, `run`
  could rot indefinitely and nothing would say so.

*Measured, and the reason this mattered:* `zig build` was green at 48/48
throughout, because a function that is never called is never analysed. Two naive
probes passed and proved nothing — `_ = @TypeOf(App.run)` and even `_ = &App.run`
do **not** analyse the body. Only *calling* it did. That is M-2's rule again, and
it is the second time in this document that a "verify the function exists" check
gave false confidence.

*Verified:* `zig build` 48/48; `tigershark --version` / `--help` / no-args all
exit 0 with correct output; the `Debug print works!` that ran on **every**
invocation is gone; `zig fmt --check` clean; `test-lib` 196/196; `test-scp` 26/26;
`test-bus-direct` 14/14.

*One trap worth repeating:* writing this fix, I used
`defer init.gpa.free(all_args)` after `toSlice` and hit `panic: Invalid free` at
runtime — the same trap recorded two turns earlier, because `toSlice` allocates
one combined buffer and returns a sub-slice. Fixed with an arena. **The lesson is
that this hazard is easy to re-introduce even when it is documented**, so it
belongs in a lint or a test rather than in prose.

### P-2 · `high` · The specification's prerequisites do not match the library

Checked each assumption against the code:

| The spec assumes | What `lib/cli` / `lib/cfg` actually have |
|---|---|
| commands declare `.exclusive = true` in `.meta` | **no such key.** The real `.meta` surface is `short, count, env, conflicts_with, requires, validate, deprecated, hidden, help, secret` |
| a `.validate` hook **on config fields** | `lib/cfg` reads only `default_value_ptr` and one `.env` key per field. Validation exists only on `lib/cli` **flags** (`cli.zig` ~`:917`), a different layer |
| `zcli.style` spinner and checklist | `style.zig` has `Style`, `Table`, `hyperlink`, `renderDiff`, `highlight` — **no spinner, no checklist**. `render/progress.zig` has `MultiProgress`, and per A-3.4 it has **no TTY/headless gate** |
| `zcli.tea` for multi-step forms and fuzzy finders | real: `tea.Program` exists, and `widgets.zig` already has `FuzzyFinder` and `Form` (`interact/widgets.zig`) |
| `run(...) !?UndoAction` | `run` is `*const fn (ctx, flags) AppError!void` / `!ReturnT`. No undo channel |
| `App.run` is the daemon entry point | it now compiles, but it had never run before P-1 |

Also, the spec's file references are stale: `dry_run` and `cas` are in
`lib/util/` after the U-0 reorganization, not `app/cli/lib/platform/`.

### P-3 · `high` · Dependency and security implications that need a decision

**Dependencies.** This repo's entire `lib/` layer imports **`std` only**, with no
external packages (`zio` was removed in the repo-wide roadmap's M-6). The spec
introduces: MsgPack (1.1), sqlite *or* jsonl (1.2), tar.gz (3.3), an HTTP client
for `config doctor` and Gist sync (3.2/3.4), file locking (1.3), POSIX shared
memory + named pipes (1.1/2.1), and an LLM API client (2.2). Every one is a
dependency decision, not an implementation detail, and none exists in the tree
today (`MsgPack 0`, `sqlite 0`, `flock 0`, `shm_open 0`).

**Security — three of these create a new local attack surface and must be
designed before they are coded:**

1. **Daemon RPC (1.1).** A UDS or named pipe that executes CLI commands on behalf
   of whoever connects. On a shared host that is an arbitrary-command channel as
   the user. Needs: socket permissions (0600), a token or peer-credential check,
   a decision about environment inheritance, and an answer for "what happens when
   the daemon holds stale config".
2. **`config sync export --gist` (3.4).** Uploads configuration to a third party.
   The spec says "strips `.secret = true` fields". **The schema half of this is now
   done** (§5.3): `generateSchema` marks a secret field `"writeOnly": true` instead
   of ignoring the flag, and `isSecret` is exported so a publisher can ask the same
   question the schema generator asks. What remains unproved is the *payload*:
   stripping must be demonstrated by a test that a secret value never appears in
   what gets uploaded. Note also that `config_diff` still prints changed fields in
   cleartext, so the export path must not simply reuse it.
3. **LLM router (2.2).** Untrusted text becomes a command line. The spec's
   confirm-before-execute is right and necessary; it also needs the parsed argv to
   be re-validated against the real command tree rather than executed verbatim.

### P-4 · `medium` · Several spec items already exist in part

Worth knowing before building, because the spec reads as greenfield:

| Spec item | Already in the tree |
|---|---|
| 1.2 undo ledger | `lib/util/dry_run.zig` — a `DryRunLedger` recording typed mutations with a diff renderer (61 lines) |
| 2.1 structured piping | `lib/util/object_pipe.zig` — JSON/NDJSON record piping (29 lines) |
| 1.4 / 3.3 TUI forms and pickers | `interact/widgets.zig` — `FuzzyFinder` and `Form` with focus management |
| 3.4 sharing config between machines | `app/cfg/lib/ota_flags.zig` and `remote_config.zig` (ETag-cached remote config) |
| 3.5 `config eject` | the resolved-config path already exists: `app/cfg/lib/loader.load` plus `config_diff` and `config_lineage` for provenance |

So 1.2, 2.1, 1.4, 3.3 and 3.4 are **extensions of existing modules**, not new
subsystems, and should be scoped as such.

### P-5 · Recommended order, and what not to start with

Do **not** begin with the daemon, the LLM router, or `config sync`. Each depends
on a foundation that P-1 has only just made work, and each adds a dependency or an
attack surface that needs a decision first.

Suggested order, by value per unit of risk:

1. **`config eject` (3.5)** — pure output from resolved config. No new dependency,
   no daemon, no network. It also forces the resolved-config path to be honest,
   which several later items need.
2. **`config doctor` (3.2)** — the validation and health-check matrix, minus the
   network probes. Needs the per-field `.validate` gap closed in `lib/cfg` (P-2),
   which is a library improvement worth having on its own.
3. **Locks (1.3)** — small, testable, no network. Needs one `std` file-lock path
   per OS and a `.meta` key; the spinner half should use a `progress` that has
   the headless gate from A-3.4.
4. **Undo ledger (1.2)** — extend `lib/util/dry_run.zig` rather than inventing a
   second ledger, and prefer `.jsonl` over sqlite to avoid the dependency.
5. **`config setup` / `backup` / `restore` (3.1, 3.3)** — needs the TUI path to
   be non-interactive-safe (A-3.6) so `--headless` and CI do not hang on a prompt.
6. **Auto-TUI `--ui` (1.4)** — depends on 3.1's form generation being solid.
7. **Daemon (1.1), SHM (2.1), LLM router (2.2), `config sync` (3.4)** — last, each
   gated on an explicit decision about its dependency and its attack surface.

---

## 4. M-0 — Maintainability: keep it from drifting back


### M-1 · `medium` · One README, and a doc that cannot lie

`lib/cli` has no README while `lib/util` has a documented root comment and the
repo has READMEs for every other non-obvious tree. Write
`app/cli/lib/README.md` with: the surface (what `root.zig` promises), the
`App(StateT, config)` model in ten lines, the file map from S-1, the test
command, and the measured test count.

*Guard, and the reason this is not just prose:* the count and the commands in
that README must be the ones `scripts/check.ps1` runs, which is the rule the
repo-wide roadmap set for itself in item O-1 — *"the commands the docs name are
the ones `scripts/check.ps1` runs."*

### M-2 · `medium` · The test-reachability convention, stated correctly

This has now bitten **three** times: `lib/net/tls` (repo-wide item O-10 — a
26-test suite that had never run), `lib/resp` (item C-5) and `lib/cli` (C-1).
The repo-wide roadmap records the hazard as O-13. What this session adds is a
measurement of *why*, which the existing convention statement gets subtly wrong.

**Measured here, with controls, in Zig 0.16.0:**

| Setup | Tests that ran |
|---|---|
| root imports `mid`, no test block in root | 0 |
| root imports `mid`, test block with only plain references | 1 — root's own only |
| root imports `mid` + `refAllDecls(@This())` | 2 — root + `mid`, **not** `mid`'s own import |
| root imports `mid` **and** `leaf`, `refAllDecls(@This())` | 3 — all of them |

So `refAllDecls(X)` reaches the declarations of `X`, and a `test` block is
collected only when a declaration **in that namespace** references it. It is
**not** transitive, and an import alone collects nothing. The convention
"a module root's own `refAllDecls(@This())` reaches its whole graph" is therefore
true only for a *flat* module, which is why `lib/util` works (one root, all
siblings re-exported) and `lib/resp` does not (its root re-exports four
namespaces, each of which needs its own call).

*Action:* state the corrected rule in `src/zig/README.md` — *every module root
applies `refAllDecls` to each namespace it re-exports, and `zig build test-lib`
must report a non-zero count for every step* — and add the control the repo-wide
roadmap says is the only trustworthy check: **add a deliberately failing test to
a file and confirm the suite notices.** A static import walk is not sufficient
and was already wrong once (it produced the `metrics.zig` false positive).

### M-3 · `low` · `AppError`'s definition reaches into other functions' types

```zig
pub const AppError = error{ … } || std.mem.Allocator.Error
  || std.Io.Writer.Error || std.Io.Reader.Error
  || std.Io.File.StatError || std.Io.File.OpenError
  || @typeInfo(@typeInfo(@TypeOf(std.process.run)).@"fn".return_type.?).error_union.error_set
  || @typeInfo(@typeInfo(@TypeOf(std.http.Client.fetch)).@"fn".return_type.?).error_union.error_set
  || std.json.ParseError(std.json.Scanner);
```

Two entries are reflected out of `std` function signatures at comptime. It works
today, but it makes `AppError` change shape when an unrelated `std` signature
changes, and it makes the error set unreadable at the point of use — which
defeats the point of an explicit error set (the convention this repo follows).

*Action:* name the two sets explicitly, or wrap them in a named type alias with a
comment saying which `std` API it tracks and why it is versioned that way. Low
priority, but it is a load-bearing type in every signature and it should be
legible.

### M-4 · `low` · `--help` scans for `--help` after routing

`execute` routes subcommands first (line 550) and only then scans all args for
`--help`/`-h` (line 613). So `tigershark add --help` prints help for `add`, which
is right, but the scan is over the *full* arg list including values, so a
positional or flag value equal to `--help` triggers help instead of being passed
through. The 91 tests cover `--help` for a command; they do not cover a *value*
of `--help`.

*Action:* parse `--help` where the `--` end-of-options handling already lives, so
a value after `--` is never treated as help. Add the regression test first.

### M-5 · `low` · An opt-in `ziglint` pass, run deliberately

The `zig-best-practices` tooling notes `ziglint` with a `.ziglint.zon` config.
Adding one repo-wide is out of scope here; adding it as a **documented, opt-in
command for `lib/cli`** is cheap and would surface the classes of issue the
manual audit caught by hand (unchecked reads, `catch {}` that swallows a real
error, `undefined` reaches). Record the findings as items rather than fixing
them blind, and do not wire it into CI until its false-positive rate is known —
the repo-wide roadmap's R-7 lesson is that a guard nobody trusts gets ignored.

---

## 5. Audit findings

Three read-only audits split the 60 modules that are neither `cli.zig` nor
`cli_test.zig` into terminal/rendering (16), config/security (16) and
platform/OS-primitives (26). Each was asked, per file: what it really provides,
implemented or scaffolding, the worst concrete bug with a `file:line`, what it
duplicates, and whether anything other than `cli.zig` imports it.

Two claims in these findings were **retracted by the auditors themselves after
re-measurement** and are marked as such below. Everything else is reported with
the evidence the auditor gave, and the three items this session independently
re-verified are marked **[verified here]**.

### 5.0 The finding that reframes the rest

**`zig build` passing did not mean these modules compiled.** `cli.zig`'s
`pub const X = @import("<sibling>.zig")` is a *lazy* namespace: a file's
declarations are analysed only when something uses them, and a function body only
when that function is instantiated. Nothing outside `app/cli` used 60 of the 63
siblings, so most of their bodies had never been type-checked by any build in
this repository.

Two auditors disagreed about whether `std.testing.refAllDecls` forces that
analysis. One claimed it does not ("it only binds declaration names"), the other
proved experimentally that it does — by injecting an unused local constant into
`openapi.zig` and getting `error: unused local constant`. **The second is
correct, and it is the reason C-1 is worth more than it looks**: wiring the suite
does not merely add assertions, it turns ~60 files that had never been compiled
into files that are, and it is what surfaced every compile error in §5.1.

**[verified here]** The residual gap is real and worth stating precisely:
`refAllDecls` forces analysis of the declarations it reaches, but a *function
that no test calls is still only analysed when instantiated*. C-1 therefore
covers exactly what the 93 tests exercise. That is a large improvement over
nothing and is not full coverage — see M-2.

### 5.1 Compile errors and memory bugs — highest severity

These are new information: they were invisible before C-1 and are the reason the
linter (`linter.zig`) and the test root matter more than any individual fix.

| Item | Evidence | Action |
|---|---|---|
| **`app/cfg/lib/cfg.zig` does not compile at all** **[verified here]** | `zig test app/cfg/lib/cfg.zig` → `cfg.zig:90: no field named 'Slice' in enum 'builtin.Type.Pointer.Size'`, and `:120`, `:146` the same. Its `parseValue` also uses pre-0.16 `.Int`/`.Float` tags. Imported by nothing; no `cfg` module in `build.zig`. Its commit message claims a "JSON schema generator" that exists *only* in `app/cli/lib/config.zig`. | **U-2, and it is now the top of that item.** A non-compiling second config engine that advertises a capability it does not have, sitting next to the live one, is a trap. Fix or delete; do not leave it. |
| **`panic.zig:65` fails to compile on every OS** | `CrashJson.timestamp` is `i64` (`panic.zig:56`), `getMonotonicMs()` returns `u64` (`telemetry.zig:4`) → `expected type 'i64', found 'u64'` as soon as `writeCrashReport` is instantiated. | One-line cast. Cheap, and it is a *crash reporter* that cannot compile. |
| **`version.zig:51,59` are stale `std` APIs** | `statFile(io, cache_path)` now takes 3 args; `std.http.Client{ .allocator = allocator }` now requires `.io`. Invisible because `app/cli/main.zig:69` has `// cli.version.check disabled for now`. | Fix both, then re-enable the call — the disabled call is the only reason the build is green. |
| **Live use-after-free in `btree_store.zig:32-36`** | In 0.16 `fetchPutContext` returns the **existing** key and does not replace it (`std/hash_map.zig:904-914`), so freeing `kv.key` frees the pointer the map still stores. `get()` then hashes freed memory and `deinit` double-frees. The freshly duped key also leaks on the update path. | Real bug on a shipped path. Fix with `getOrPut` semantics, and add the test — `cli_test.zig` covers `WorkspaceStore` but clearly not the update path. |
| **Confirmed panic in `spatial_focus.zig:48`** | `SpatialFocusGrid.init(2, 0, true)` then `moveLeft()` → `panic: integer overflow` at `self.cur_col = self.cols - 1`. `:44` and `:47` are equally unguarded. | One-line guard, or reject `rows == 0 or cols == 0` in `init`. Reproduced by the auditor. |
| **Five files cannot compile for Linux — the shipped target** | `build/targets.zig:35-39` makes Linux mean musl. Forcing instantiation gives `sys.zig:32` (`std.posix.geteuid` gone), `sys.zig:77` (`Child.init` gone), `daemon.zig:57` (`getpid` gone), `daemon.zig:76` (`kill` wants a `SIG` enum, not `0`), `mmap.zig:85,122` (`std.posix.open`/`close` gone; 0.16 has `openat`), `telemetry.zig:12` (`clock_gettime` gone). | A Linux build is already red for unrelated reasons, which masks this. Fix as one unit: these are the four files with per-OS branches. |

### 5.2 The live path is the broken one

The audit's most important *ranking* conclusion: `prompt.zig` →
`app/cli/commands/add.zig` → the shipped `tigershark` binary is the **only**
production path through the terminal group, and it is exactly what is broken.

| Item | Evidence | Action |
|---|---|---|
| **Interactive re-render leaves stale lines** | `tea.zig:152`/`:189` set `prev_lines = std.mem.count(u8, view_bytes, "\n")`, which is one short for any view ending in `\n` (the normal case); the erase loop at `tea.zig:181-183` then emits one too few `\x1b[A\x1b[2K\r`. Demonstrated by running `Program.run`: `n=0` then `n=1` without clearing `n=0`. | Fix the count (use `visualWidth`-style line accounting, not `count`), and add the regression test. This is user-visible on every prompt. |
| **Detached thread + freed queue on the quit path** | `tea.zig:142` spawns a thread holding `&stdin_ctx`, a `run` local; it is never joined or detached and loops forever in a blocking read (`:107-119`). `prompt.zig:78` then `channel.deinit()`s the queue that thread may still push into (`tea.zig:117`). | Latent use-after-free. Needs a shutdown signal the reader thread observes, not a detached thread. |
| **`Command.exec` is a documented no-op** | `tea.zig:44-46` defines `Command.exec`, user code can return it, and `run`'s `.exec` branch (`:174-178`) is empty; `execThread`/`ExecContext` are referenced nowhere. | Either implement or delete the tag; today it advertises a capability that silently does nothing. |

### 5.3 Security and correctness findings in the config group

| Item | Evidence | Action |
|---|---|---|
| **The live `config` command leaks a secret and publishes it** | `config.zig:46` dups `API_KEY` into the heap; `config.zig` has **no `deinit` at all**; the caller does `defer ctx.allocator.destroy(cfg)` (`app/cli/commands/config.zig:44`), which frees the struct only. `generateSchema` (`config.zig:100-113`) ignores the `.secret` flag that the caller already declares, and `config_diff.zig:26-27` prints every changed field in cleartext. | **Half fixed.** The `.secret` half of `generateSchema` is done - see below. The `deinit`/arena leak and `config_diff`'s cleartext printing are still open. |
| **`encrypted_config.zig` uses raw SHA-256 as the password KDF** | `:10-19` hashes with plain `Sha256` — no iterations, no memory hardness — and `:28` passes the **nonce** as the salt, so the salt is attacker-chosen. The repo already has correct PBKDF2 at `lib/sec/pkcs/pkcs5.zig:47`. | Replace with PBKDF2 and a real random per-file salt. The AEAD usage itself is correct, so fix in place — do not fold this file into another. |
| **Two flag gates, both fail open** | `ota_flags.zig:36` returns `orelse true` for an unknown flag (and `assertAllowed` has **no caller anywhere**); `policy.zig:18` nests the entire `required_flag` check inside `if (rule.forbidden_env)`, so a flag-only rule is silently inert. | A policy rule that looks enforced and is not is worse than no rule. Fix both before either is trusted. |
| **`security.redact` shows the first *and* last character** | `:11` promises "at most the first character"; `:18-19` writes `secret[0]` and `secret[secret.len - 1]`. | One-line fix; the doc is the contract. |
| **`config_lineage.zig:41-43` frees by length, not provenance** | `record` stores the literal `""` when `origin.len == 0` (`:50`); `deinit` frees when `origin.len > 0`. Re-recording a key with a non-empty origin can free the literal. | Track ownership explicitly instead of inferring it from `len`. |
| **`secret_val.zig:43-55` — `expose()` is a copyable capability that owns destruction** | Every `Exposed.destroy()` calls `parent.deinit()`, so two live `Exposed` values make the first destroy zero and free the buffer the second still points at. | Make `Exposed` non-copyable by shape, or make `deinit` idempotent through an owned-flag rather than an empty slice. |

#### `generateSchema` now honours `.secret` · **[done]**

The `.secret` half of the first finding is fixed. `app/cfg/lib/loader.zig` read `.help`
from a field's meta and ignored `.secret` entirely, so a field the caller had
explicitly marked secret was documented like any other:

```zig
.api_key = .{ .env = "API_KEY", .secret = true, .help = "Secret API key" },
```

A secret field is now emitted with **`"writeOnly": true`** (draft-07). That is
deliberately *not* omission: a schema that silently dropped secret fields would
misdescribe the config surface - an editor could not offer the key and a user could
not discover they may set it. `writeOnly` is precisely the contract "may be
supplied, must never be echoed", and it is what lets `config sync` publish a schema
without publishing values.

`isSecret(ConfigT, field_name)` is exported for the same reason: a caller about to
*publish* configuration needs the identical answer, and re-deriving it per caller is
how one of them ends up disagreeing.

*Verified end-to-end, not just unit-tested.* **This claim was false for a period, and
that is worth recording.** When `app/cfg` was split into `ops/` + `cmd/` and the group
grew real subcommands, the `--schema` flag was dropped and `generateSchema` was left
with no caller but its own test - so the feature compiled, stayed covered, and was
unreachable. An independent audit caught it (`config --schema` exits 2 with
`Unknown flag 'schema'`). It is now `config schema`, a subcommand rather than a flag,
and it takes an optional output path. Against the demo config (which declares `api_key`
secret) it emits:

```
"api_key": {
  "writeOnly": true,
  ...
```

and the output still parses as JSON with all four properties present. Three tests
in `loader.zig` cover it - it had **none** before - including a **count** of the
`writeOnly` occurrences rather than a spot check, because a bug that marked every
field writeOnly would pass a "contains writeOnly" assertion.

*Still open from the same row:* `config.zig`'s missing `deinit` (the secret is
duped onto the heap and only the struct is destroyed), and `config_diff.zig`'s
cleartext printing of changed fields. Both are real; neither is closed by this.

### 5.4 Scaffolding that advertises a capability it does not have

Ranked by how misleading the name is. These are *decision* items, not cleanups:
each must become real or stop claiming to be real.

| File | What the name promises vs what is there |
|---|---|
| `fido2.zig` | The entire "FIDO2" flow is one `print` (`:15`); `challenge` is stored and never used; no CBOR/WebAuthn anywhere. |
| `sandbox.zig` | `isPathAllowed` (`:21`) is a **prefix** match, so `/data` allows `/database`; `:18` fails open; `allow_network` (`:6`) is never read by anything. |
| `cas.zig` | No `get`/`put`/read/write at all — only `computeKey`/`formatKeyHex`. `cache_dir` and `init` are dead fields. |
| `config_dryrun.zig` | Contains **no validation whatsoever**; the caller must hand it a pre-computed `[]ValidationResult`. 29 lines. |
| `comptime_config.zig` | Doc says "evaluates or extracts JSON from a programmable Zig config file"; it greps for the sentinel strings `JSON_START`/`JSON_END` in a **single 4096-byte read** (`:25-27`), so a larger file silently truncates to the fallback. |
| `updater.zig` | Recreates the binary with default mode (losing `+x` on POSIX), no signature check, and renames the running image on Windows (`:11-14`). |
| `graphics.zig` | `detectProtocol` is real, but the sixel branch (`:57`) is a hardcoded literal that never reads `image_data`, and the kitty branch sends one unchunked payload with `m=0` (no chunking loop), truncating any real image. |
| `openapi.zig` | Walks one level of subcommands and emits flat paths with no parameters — it describes an API the binary does not implement. |
| `rope.zig` | Not a rope: an `ArrayList` of lines with O(n) `insertLine` (`:26-30`) and no character-level editing. Misnamed, and misleads anyone choosing it for an editor. |
| `virtual_terminal.zig` | `Cell.char` is `u8` (`:4`), so non-ASCII is stored as mojibake; `exportSvg` ignores `fg`/`bg` entirely and does not escape `"` or control bytes. |

### 5.5 Duplication — merge candidates with no capability loss

Named pairs/triples the audits agree on. Each is a *possible* merge; do them one
at a time with `zig build test-lib` green after each.

| Capability | Duplicated by | Note |
|---|---|---|
| Visual width of a string | `tea.visualWidth` (`tea.zig:197-212`) and `style.visualWidth` (`style.zig:111-131`) | Byte-identical logic. Delete `tea`'s; `style` is the file widgets/prompt actually import. |
| RGB type | `style.RGB` (`style.zig:9`) and `color.RGB` (`color.zig:10-13`) | Same layout, incompatible types. Worse: `Style.render` hardcodes truecolor (`style.zig:89-90`) and never calls `ColorEngine.formatFg`, so the whole profile-detection layer is dead. |
| Terminal size | `tea.getTerminalSize` (`tea.zig:322-348`) and `pager.getTerminalHeight` (`pager.zig:5-31`) | Three separate declarations of `CONSOLE_SCREEN_BUFFER_INFO`, with different field types. Pager's null/`INVALID_HANDLE_VALUE` check is the better one. |
| Side-by-side text | `style.joinHorizontal` (`style.zig:144-173`), `style.Table` (`:218-338`), `layout.Layout.split` (`layout.zig:43-49`) | Three compositors with three width rules; only `layout` measures bytes, which is its bug. |
| Focus model | `widgets.FocusManager` (`widgets.zig:5-30`, 1-D) and `spatial_focus.SpatialFocusGrid` (`spatial_focus.zig`) | One is used by `widgets.Form`, the other by nothing. |
| Wipe a secret | `security.wipe` (`:5`), `secret_val.deinit` (`:57`), `secure_heap.deinit` (`:27`), `proctitle.scrubSecretArg` (`:6-9`) | Four copies, one of them verbatim. The `extern "kernel32" VirtualLock` block is character-identical in `secret_val.zig:31-34` and `secure_heap.zig:14-17`. |
| Task graph | `tasks.zig` (`Task{name,deps,run}` + cycle detection) and `dag.zig` (`DagNode{name,deps}` + layering) | The same node model; neither alone is complete. |
| Terminal handle | `raw_terminal.zig` (hardcodes fd 0), `pager.zig` (hardcodes `STD_OUTPUT_HANDLE`), `tty_stream.zig` | Three idioms for one job. |
| Escape-sequence emitters | `supervisor.zig` (10L), `decstbm.zig` (13L), the emitter half of `vte.zig` | No state, no allocation — nothing to lose by merging into one `ansi.zig`. |

### 5.6 Claims retracted by the auditors

Recorded because this file's whole value is that its claims can be trusted.

- **"Two base64 bugs send uninitialized bytes to the terminal."** Retracted after
  measurement: `std.base64.standard.Encoder.encode` writes the padding bytes, so
  the returned slice and the written length coincide for every input length
  (`uninit_in_slice = 0` for all of them). What remains is a **fragility** note:
  `widgets.zig:39-40` and `graphics.zig:42/:51` discard the returned length and
  print the whole buffer, which would become wrong under a no-pad encoder. Not a
  memory-disclosure bug.
- **"`std.testing.refAllDecls` does not force function-body analysis."** Retracted
  in the other direction by the third auditor's control experiment. See §5.0.

---

## 6. Order of work

Sequenced so that each step is verified by the step before it.

| Step | Item | Status |
|---|---|---|
| 1 | **C-1** wire the tests — nothing else is provable until this exists | done |
| 2 | **C-2** `zig fmt` — the gate must be real before it is trusted | done |
| 3 | **C-4** pin the test count | done |
| 4 | **S-0** group the 58 leaf files into `render/interact/settings/secrets/platform` | done |
| 5 | **N-1** `root.zig` in every folder with sources — 53 files, lib and app | **done** |
| 6 | **N-2** `const Self = @This();` on every file's primary type — 89 files | **done** |
| 7 | **N-3** the compile bug N-1 surfaced (`panic.zig`) — roadmap **B-1** | **done, via N-1** |
| 8 | **C-3** two commits — makes the rest reviewable | **owner action** |
| 9 | **B-2** `btree_store.zig:32-36` use-after-free | open |
| 8 | **B-3** `spatial_focus.zig:48` underflow panic | open |
| 9 | **B-4** `tea.Program.run` line accounting + reader-thread lifetime (the shipped prompt path) | open |
| 10 | **B-5** `version.zig:51,59` stale `std` APIs, then re-enable `version.check` | open |
| 11 | **B-6** the five POSIX/Linux files, as one unit | open |
| 12 | **S-0a** document the encoding rule; add a byte-integrity check to the workflow | open |
| 13 | **S-0b** repair the pre-existing mojibake in 10 files (incl. `build/bus.zig`) | open |
| 14 | **U-0 tier 1** — `lib/cfg` fixed and promoted; the `traceparent` pair collapsed | **done** |
| 15 | **U-0 tier 2** — 11 pure primitives moved to `lib/util` | **done** |
| 16 | **U-0 tier 3** — decide `secrets/`, and whether to merge `cfg.Manager` with `cfg.loader` | open (owner call) |
| 17 | **S-2** fix the scope-visibility defect — cheapest structural win | open |
| 18 | **S-1** split `cli.zig` along the boundaries S-1 names | open |
| 19 | **S-3** extract `parseFlags`'s policy jobs (needs S-1's `flags.zig`) | open |
| 20 | **S-5, S-6, S-7** the `repl` merge and the test fixture | open |
| 15 | **U-2** the `lib/cfg` decision — **now urgent**, it does not compile | owner call |
| 16 | **C-5** the same dead-suite bug in `lib/resp` | open |
| 17 | **M-1, M-2** the README and the convention in `src/zig/README.md` | open |
| 18 | **U-1, U-3** triage with §5 in hand | open |
| 19 | **S-4** the compile-cost work, with before/after numbers | open |
| 20 | **M-3, M-4, M-5** opportunistic | open |

**Steps 5–9 were not on this list until the audits in §5.** They are all
concrete, all verified by an auditor, and three of them are compile-or-crash
failures rather than design questions — which is why they now outrank the
structural work. Step 8 is the one a user will actually hit.

The three items marked done are the three that landed in this session, in this
order, each verified by the command in "the guard for every step" below. Note
that C-3 is deliberately **not** done here: committing is the owner's call, and
the two-commit shape matters more than the speed.

### The guard for every step

- `zig build --summary all` → `48/48 steps succeeded` (plus the new `test-lib-cli`).
- `zig build test-lib --summary all` → **non-zero, and the recorded total must not drop**.
- `zig fmt --check build.zig build lib app` → clean, on every step.
- `zig build` and `zig build test` for the whole repo, because `app/cli` is a consumer.

**Report the number, not the adjective.** Every count in this document is a
measurement with a command behind it, and any item that cannot produce one is
not finished.

---

## 7. A-0 — The ergonomic registration API, and the gaps it exposed · **[done]**

`App.Command(Flags, subcmds){ .name = ..., .run = ... }` put four things in one
struct literal: a command's identity, its flags type, its behaviour, and - because
positional arguments were a field *inside* the flags struct - its arguments. The new
spelling separates them:

```zig
const meta = .{
    .name = "add",
    .description = "Add a UI component to your project",
    .flags = AddFlags,
    .args = AddArgs,
};

pub const cmd = App.command(meta, addRun);

// Any of these; the framework reads the signature at comptime.
fn addRun(ctx: App.Ctx, flags: App.Flags(AddFlags), args: AddArgs) !void { ... }
fn addRun(ctx: App.Ctx, args: AddArgs, flags: App.Flags(AddFlags)) !void { ... }
```

`App.command(meta, null)` registers a command with no body (a routing node, or
`is_repl`), and a flags type that already declares `positionals` keeps working, so a
command can move to `.args` without rewriting a flags struct a library function
shares. `App.Command`/`LeafCommand`/`CommandWithReturn` are unchanged and still
tested; both `app/cli` and `app/cfg` (14 commands) are migrated to the new spelling.

### 7.1 What "ensure the feature exists" actually found

Auditing the checklist against the code found nine features that were *declared* and
not implemented. Each is now implemented and has a test that fails without it:

| Feature | State found | Evidence |
|---|---|---|
| Repeated/array flags | **absent** - `parseValue` rejected every non-`[]const u8` slice at compile time, and `assignFlag` overwrote | a `[]const []const u8` flag was a `@compileError`, so `-H a -H b` could not be expressed |
| Custom `parse` declaration | **dead** - looked up on the type `MergeFlags` synthesizes, which copies fields and no declarations | `@hasDecl(FlagsType, "parse")` was permanently false |
| `validation` rules block | **dead**, same cause | `@hasDecl(FlagsType, "validation")` permanently false |
| `--dry-run` for field `dry_run` | **unknown flag** at runtime, and a test asserted against its own local copy of the normalisation | `config format --dry-run` → `Unknown flag 'dry-run'` |
| Attached short values (`-tvalue`) | **unimplemented**, and the dead `next_val` branch made `-ttok` mis-route | value could only come from the next argv token |
| Hidden commands | **unimplemented** for framework commands: `hidden` was not a field, so `@hasField` was comptime-false everywhere except a hand-written type | `--help`, `writeMarkdownDocs` and completions listed them |
| `pre_run` hook | **never called** - collected and ignored | no call site anywhere in the file |
| `--version` / `-V` | absent at framework level | each app hardcoded its own flag and string |
| Config-file defaults | absent | `parseFlags` read defaults, argv and the environment only |
| Flag typo suggestions | absent (subcommands had them) | `Unknown flag 'verbos'` with no hint |
| Overridable help | absent; `printHelp` was private | `app/cfg` hand-wrote usage rather than delegating |
| zsh completions | **unreachable** - shadowed by a hardcoded duplicate earlier in the dispatcher | `emitZshCompletions` had no reachable caller |

Three defects were also found by reading the *resolution order*, not the feature list:
1. **The environment could not satisfy a required flag.** The "missing required"
   error was raised before the environment was consulted, so a field with no default
   could never be filled from `meta.<field>.env`. The check now runs after the
   environment and the file, in the order the documentation always claimed.
2. **`subcmd_indices[32]` and `pre_runs[count]` were written unchecked.** A deep
   enough tree or argv wrote past the end of the array. Both are bounds-checked now,
   with `error.CommandNestingTooDeep`.
3. **`@import("cli").AppError` did not compile.** `root.zig` re-exported nine names
   that `cli.zig` does not declare at file scope (`AppError`, `Error`, `GlobalFlags`,
   `Command`, `CommandWithReturn`, `LeafCommand`, `Flags`, `MergeFlags`,
   `ExecutionChain`, `TestHarness`), and nothing referenced them, so the surface was
   broken silently. `AppError` and `GlobalFlags` are now real file-scope
   declarations, the rest are documented as `App.*`, and the completeness guard
   checks **both** directions.

### 7.2 Measured

- `zig build test --summary all` → **15/15 steps, 502/502 tests**, of which
  `test-lib-cli` is **250** (was 216).
- `zig fmt --check build.zig build lib app` → clean.
- `zig build` → 15/15 steps; `tigershark --help`, `tigershark add --help`,
  `cfg --help`, `generate-completions zsh`, `generate-docs markdown` and
  `--version`/`-V` were all checked by running the binaries.

### 7.3 What the new tests pin, and why

The 34 new tests are grouped by the checklist rather than by function: registration
shapes, parsing, typing, routing/help, environment/config, execution. Two rules they
follow deliberately, because the audits found tests that broke both:

1. **Never assert against a copy of the implementation.** The kebab-case test used to
   re-implement the normalisation locally and pass while the parser had none; it now
   drives the parser. The exit-code test enumerates the framework's *declared* set
   (`@typeInfo(cli.AppError)`), not a hand-written copy of it.
2. **A test that needs a different framework configuration declares its own `App`.**
   `Ctx` is a member of the `App` closure, so a command is only guaranteed to run
   under the instance it was built from.

### 7.4 Follow-up hardening · **[done]**

Three more gaps, all of them "the capability exists but nothing uses it":

1. **`ComptimeLinter` was never called by the framework.** `lib/util/linter.zig` checked
   duplicate short flags and had exactly one caller: a test. `App.command` and
   `App.Command` now run it when the command **type** is built, so a bad declaration
   fails the build whether or not anything executes it. The checker also grew three
   rules that were previously silent or badly reported:
   * a long name the framework owns (`help`, `output`, `interactive`, `yes`) - `--help`
     is intercepted and the other three are merged in from `GlobalFlags`, so declaring
     one is either shadowed behaviour or a duplicate-field error with no explanation;
   * `-h`, which the router consumes;
   * `.count = true` on a non-integer field, which used to fail inside `parseFlags`
     with a message about `+=`.
2. **The man page had no OPTIONS or ARGUMENTS section and did not recurse**, so
   `generate-docs man` documented a synopsis and (at most) one level of children. It
   now emits COMMANDS/ARGUMENTS/OPTIONS for the root, a `.SS` entry per subcommand at
   any depth, and labels a subcommand's own sections as paragraphs - a `.SH` inside a
   `.SS` silently returns to the top level, which is why the level is a parameter
   rather than a literal.
3. **`cfg` and `tigershark` had no root description**, so their help printed a usage
   line with nothing under it and their man pages read `cfg - `. Both roots now carry
   one; two existing tests asserted the old man macros and were updated with the new
   structure.

*Measured after this pass:* `zig build test --summary all` → **15/15 steps, 505/505
tests** (`test-lib-cli` 250, `test-lib-util` 23); `zig fmt --check` clean; `zig build`
15/15. The linter's own failure mode was verified by declaring a `help` field and
observing `error: CLI Flag Collision: 'help' is reserved by the framework; rename the
field` at compile time.

### 7.5 The exit status the binaries actually return · **[done]**

Running the shipped binaries and reading `$LASTEXITCODE` - which no test had ever
done, because `App.run` terminates the process - found that the documented status
table was not the one in use:

| Command | Before | Now |
|---|---|---|
| `tigershark nope` (unknown command) | 1 | **127** |
| `tigershark --versoin` (unknown flag) | 1 | **2** |
| `tigershark --output zz` (bad value) | **0**, after printing an error | **2** |
| `tigershark repl` piped | 1 (printed help) | 1, with a message |

Two causes, both in the one function no test could reach:

* `failWith` consulted `config.exit_map` and then **hardcoded `1`**; `getExitCode` -
  with its POSIX table, and with the test that asserts it - was never called on the
  real path.
* `App.run` excluded `HandledError` from the failure path. `assignFlag` raises it
  *after* printing "Invalid value …", so a rejected flag value was treated as the
  command having succeeded: an error message and exit 0.

`failWith` now uses `getExitCode`, the decision is extracted into
`App.failureDisposition(err)` (`{ code, report }`) so the previously untestable part is
a pure function with tests, `HandledError` is mapped to 2 (a usage failure) with the
diagnostic already printed, and a cancelled prompt exits 130 rather than 0.

Also fixed while adding the first test of the **interactive prompt path**: answering the
prompt for a required positional incremented `pos_count` without storing a value, so the
pass that fills positionals read `pos_buf[0]` when `pos_buf` had been sized by argv
alone - a panic with a bare `mycmd <TAB>`-free invocation and no arguments at all. The
prompt's value is already assigned where it is parsed, so the counter now counts only
argv positionals, which is what the fill pass reads.

*Measured after this pass:* **15/15 steps, 564/564 tests** (`test-lib-cli` 308); the exit
codes in the table above were re-measured from `zig-out/bin/tigershark.exe`.

---

## 8. What "ensure we have all of" found in the second checklist

A longer feature list was audited the same way as §7: for each item, find the code, find the
test, and where either is missing say so precisely. The method that keeps paying is
**running the thing** and **searching for the caller** - `rg 'fn feature'` then `rg
'feature\('` - because this tree's failure mode is not a missing implementation, it is an
implementation wired to nothing.

### 8.1 Landed in this pass, with tests

| Item | What was there | What is there now |
|---|---|---|
| Deprecation lifecycle (commands) | flags had `.deprecated`; commands had nothing | `meta.deprecated` / `.deprecated`: warned on use, omitted from `--help`, completions and suggestions |
| Feature flags | nothing | `meta.feature` / `.feature` on commands *and* flags, gated by an environment variable: unroutable, unadvertised, and not settable from the environment or a config file while closed |
| OnError hook | `pre_run`/`post_run` only | command-level `on_error = fn (ctx, err) void`, wrapped around the body *and* the middleware onion, notification-only by design |
| Dry run in the context | a per-command `dry_run` flag in `app/cfg`, `cli.dry_run` unused | `Ctx.dry_run`, set from a `dry_run` field or from `meta.dry_run = true` (which adds `--dry-run`), so deep business logic can honour it from the context alone |
| REPL on a bare invocation | `--interactive` and a `repl` subcommand | a command with `is_repl` and no arguments enters its shell **on a terminal**; piped or in CI it prints usage instead |
| TTY / CI awareness | `decide` read `NO_COLOR`, `FORCE_COLOR`, `TERM` and two `isatty`s | CI is an input: colour, cursor movement and prompts are all off under CI, `FORCE_COLOR` still wins for colour, and `Ctx.is_tty` is `caps.interactive` so the policy has one source |
| Secret redaction | `meta.<field>.secret` redacted in `formatFlags` only | the chain is closed: `--help`, the man page and the HTML page never print a secret's default; a failed parse masks the value instead of echoing it; and every secret string flag is registered with `cli.log`'s scrubber, so a log line cannot carry it (text and JSON) |
| Structured output | text tables and JSON | `--output yaml`, a block-style emitter in the same `formatOutput` |
| Generated documentation | `markdown` and `man` | `generate-docs html`, one self-contained page with escaped descriptions, and deprecated/gated commands marked in all three |
| Plugin discovery | nothing | `Config.plugins = .{ .enabled, .prefix }`: an unregistered command runs `<prefix>-<name>` from `PATH` with the remaining arguments, inheriting the streams, its exit status passed through `chain.external_status` to `App.run`. Off by default, and a token containing a separator, a dot, a colon or a leading dash is refused before any lookup |
| Mutually exclusive groups | declared, checked at parse time | plus a compile-time check that every name in a group names a real flag - a group that matches nothing is a safeguard that enforces nothing |

### 8.2 The tests that pin it

Nine new tests, in the same style as §7.3 - grouped by capability, never asserting against
a copy of the implementation, and each declaring its own `App` when it needs different
framework configuration. The CI test drives `capability.decide` directly with a synthetic
environment map, because the alternative (a real CI runner) is not a unit test.

### 8.3 Also landed: three modules that were library-only

Each was a real implementation with no caller and no test, found by the same
"search for the caller" method. All three now have one:

* **`platform/state.zig`** (new): reading and writing state, caches and tokens in the
  standard per-OS directories, through `xdg`, with atomic replace, parent-directory
  creation and owner-only permissions for secret material. This is also what retires the
  `/tmp/<app>_version_cache.txt` hardcode in `version.zig` that `xdg`'s own module comment
  claims was already removed.
* **`platform/update.zig`**: GitHub Releases parsing, the checksum-asset convention, a
  `sha256sum`-format parser, and detached Ed25519 signature verification, so the existing
  check → download → verify → replace pipeline can be driven from an ordinary release
  registry and can enforce a signature rather than only a checksum.
* **`platform/telemetry.zig`**: an *opt-in* reporter (the module previously had only an
  opt-out predicate and sent nothing), with an injected transport, so the framework never
  performs network I/O and a payload cannot contain the environment, argv or a hostname.

### 8.4 `App.updateCommand`: the pipeline, now reachable from a command line

The self-updating item was the one place where every part existed and nothing was joined
up. `App.updateCommand(.{ … })` registers a command that:

1. reads `<owner>/<repo>`'s latest release and compares tags (`--check` stops here);
2. prints the available version **before** changing anything;
3. requires `--yes` - or an interactive yes - to replace a running binary;
4. fetches `<asset>.sha256`, parses it, and fetches `<asset>.sig` when a public key is
   configured, so `install` verifies the checksum and then the signature;
5. reports `Already up to date` or `Updated <path> to <version>; restart to use it`.

Two decisions are worth recording, because both are seams rather than assumptions:

* **The transport is a factory** (`fetcher_factory`), not a value. The metadata is
  comptime, and a `Fetcher` holds a context pointer - so runtime state (a test stub, a
  proxy from the environment, an authenticated session) can only be reached through a
  function called at run time. The command's own test needed exactly this.
* **The binary to replace is the caller's business** (`target_path`, or `resolve_target`).
  `std.process.Init` in Zig 0.16 carries the environment, the arguments, an arena, an
  allocator, an `Io` and the preopened directories - and no executable path, and there is
  no `std.process.selfExePath` to fall back on. Rather than guess, the command refuses
  with `NoUpdateTarget` and names the field to set. `platform/self_exe.zig` is the
  implementation an app passes: Windows reads `ImagePathName` from the process
  environment block (the loader's own record, the same field `std` uses), Linux reads the
  `/proc/self/exe` symlink (so a `PATH`-resolved or linked invocation still names the real
  file), and any other platform returns `error.Unsupported` rather than a plausible-looking
  wrong path. `app/cli` registers the command with `.resolve_target = cli.self_exe.resolveTarget`,
  so `tigershark update --check` runs the whole pipeline against the real registry.

Its test drives all five paths through a stub transport and a temporary file: up to date
(no prompt, no `--yes`), `--check` (one request, nothing written), refusal without `--yes`
(`ConfirmationRequired`), install (`--yes`, target replaced, three requests), and a bad
checksum (`ChecksumMismatch`, target untouched).

### 8.5 The pass that followed: instantiate it, or it is not compiling

*Measured at the time of writing:* **13/13 steps, 573/574 tests passed (1 skipped)**.
(`test-lib-cli` 312+1 skip, `test-lib-cfg` 124, `test-lib-util` 27, `test-app-cfg` 107,
`test-app-cli` 3.) The step count fell from 15 to 13 because `app/cfg/lib/ops` stopped
being a module of its own; each test root carries a compile *and* a run step, so removing
one root removes two.

This pass cost almost nothing in new features and found five defects, all of the same
shape: **code nothing calls is code the compiler never analyses, and it rots silently.**

| Declaration | How it had rotted | Fix |
|---|---|---|
| `crash.zig` panic handler | `dumpCurrentStackTrace(first_trace_addr)` — 0.16 takes `StackUnwindOptions` | passing `.{ .first_address = … }`; found the instant the hook was installed in the binaries |
| `sys.isElevated` | `win.BOOL` compared against integer `0` | compare against `.FALSE`; POSIX branch moved to `std.os.linux.geteuid` |
| `sys.openEditor` | `Child.init`, `readStreaming`, `std.crypto.random`, and a `platform → util` import for a timestamp | `std.process.spawn` + `readFileAlloc` + `io.random`, no cross-module dependency |
| `dry_run.record` | no `errdefer`: a failed details copy leaked the target, a failed append leaked both | `errdefer` on both copies, proven by `checkAllAllocationFailures` |
| `dry_run.renderDiff` | unconditional ANSI, so a redirected ledger carried escape codes | colour is a caller parameter, since `lib/util` cannot read `lib/cli`'s capability |

Two habits came out of it, and they are now the rule for this tree:

1. **A fix ends with a test that calls the thing.** Referencing a function is what forces
   its body to be analysed, so `sys.zig`'s two functions and `dry_run`'s ledger now have
   tests whose *purpose* is instantiation plus behaviour. The `isElevated` test asserts a
   `bool` and deliberately not a value: whether the host is elevated is a property of the
   host.
2. **A guard that has never failed is not a guard.** Both new guards were run against a
   planted defect: the ops-folder scan (`fields.zig imports the CLI; this folder must stay
   framework-free` → `FAIL (OpsDependsOnCli)`) and the allocation-failure test
   (`fail_index: 1/4` with the `errdefer`s removed).

Also in this pass: `version.zig` deleted (B-5), `app/cfg/lib/ops` moved out of `lib/` so
the residency rule holds for every module (each of `util`, `cfg`, `cli` now has ≥2
consumers), and the ops folder's "framework-free" invariant - which the merge into
`app_cfg` could no longer enforce through the build graph - re-established as a source
scanning test that skips comments, because the rule is also *documented* as
`` **No `@import("cli")`.** `` in the very file being scanned.

**A method warning, for whoever reads this next.** Absence claims in this document were
made with shell glob searches, and that method produced a false negative in exactly this
pass: `lib/util/dry_run.zig` was written up as having "no callers and no tests" when
`cli_test.zig:1977` had covered it all along, which the compiler then pointed out by
failing the build. Before recording that something is unused, search with the repository's
grep tool over the whole tree, and prefer a compiler error to a search result.

