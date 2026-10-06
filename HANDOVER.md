# HANDOVER — start here

**For:** the next session or agent picking up this work.
**State:** every gate is green, and the tree is **committed** as `d5c1d8f`. Read §0,
then §1, then pick from §3.

Last verified numbers (run them yourself before trusting anything here):

| Gate | Expected |
|---|---|
| `zig build test --summary all` | `13/13 steps succeeded; 593/594 tests passed (1 skipped)` |
| `zig build test-direct --summary all` | `13/13 steps succeeded` |
| `zig build test-linux-compile --summary all` | `6/6 steps succeeded` — compiles every root for the shipping OS |
| `zig fmt --check build.zig build lib app` | exit 0, no output |
| `zig build` | exit 0; `.\zig-out\bin\snek.exe --version` → `v0.1.0` |
| `git status --porcelain` | empty |

**Two traps in this environment, both paid for:**

1. `zig build … 2>&1` in PowerShell sets `$LASTEXITCODE` to **1** even when the
   build succeeds, because Zig writes its summary to stderr and PowerShell turns
   that into a `NativeCommandError`. Redirect with `*> $file` instead, or check the
   `N/N steps succeeded` line rather than the exit code.
2. `zig build test --summary all` does **not** reprint individual test names for a
   cached step. To see the `N/M test.<module>.test.<Name>...OK` lines you must run a
   root directly, e.g.
   `zig test --dep cfg --dep util "-Mroot=lib/cli/root.zig" "-Mcfg=lib/cfg/root.zig" "-Mutil=lib/util/root.zig"`.
   Redirecting *that* with `>` writes **UTF-16LE**, and PowerShell wraps the first
   line in an error record; parse with `[System.IO.File]::ReadAllLines` and a regex
   that tolerates a `zig : ` prefix, or you will silently analyse 322 of 323 tests.

If you see `OutOfMemory` from the compiler, or test binaries exiting `255` with no test
failure, **check free disk space first**: `.zig-cache` had grown to **11 GB** here, and
deleting it dropped a full rebuild's cache to **0.15 GB**. The 11 GB was accumulated
legacy garbage, not the cost of this tree. A nearly-full volume produces both symptoms
and neither is a code failure.

---

## 0. What the previous session's open item turned out to be

§3's first task — "find the one dead test in `lib/`" — is **resolved, and there is no
dead test**. The measured claim (479 declarations, 478 runs) was real, but the cause
was an accounting artifact, not a lost test. Read `lib/cli/ROADMAP.md` item **C-6**
for the full method and the two control experiments; the short version:

* All **471 named** declarations in `lib/` execute (cli 318 + cfg 123 + util 30), as
  measured when the audit ran. The tree has grown since — `util` added a direct test for
  the monotonic clock and `cli` gained headless `Program.run`/`deinit` tests, so it
  currently reports **594** tests, 593 passing (cli 328, util 32). The audit's arithmetic
  is unaffected; only the totals moved.
  Verified by running each module root directly and pairing every declaration with
  the executed name that served it, allowing for the instantiation-qualified prefix
  a test inside a generic container runs under.
* Those 471 are 471 of the 479; the remaining 8 are **bare `test { ... }` blocks**,
  every one of them a `refAllDecls` collector with **no test body**. The runner
  names 7 of them; the one it never names is `lib/cli/test/root.zig`, a second entry
  point to the same suite that `lib/cli/root.zig` does not import.
* No file is unreachable: of 100 `lib/` sources, **60 declare tests and zero are
  imported by nothing**.
* The handover's nominated suspect, `render/tea.zig:313`, runs — it was observed
  passing at `323/323`.

**Do not re-run this investigation.** If you update C-4's pinned numbers, count named
declarations and executable blocks, never bare `test {` blocks.

---

## 1. The commit that landed

`d5c1d8f` — `feat(cli): command lifecycles, feature gates and real platform modules`.
53 paths: 43 modified, 4 added (`HANDOVER.md`, `ROADMAP.md`,
`lib/cli/platform/{state,self_exe}.zig`), 6 renames (`lib/cfg_ops/*` →
`app/cfg/lib/ops/*`, content-identical `R100`), 1 deleted (`lib/cli/version.zig`).

It went out as **one** commit, not the two ROADMAP C-3 asked for: by the time the
tree was green the change was a reviewed session rather than an "as-found" dump, and
C-2's formatting fix was already folded into the files it touched. C-3 records that
deviation and why. Read the commit body — it is the detailed record of every feature,
defect and measurement from this session.


## 2. What already landed in this session — do not redo it

**Features** (all in `lib/cli`, with tests in `lib/cli/test/cli_test.zig`): command
deprecation lifecycles; feature gates on commands *and* flags; `on_error` hooks;
`Ctx.dry_run` plus `meta.dry_run`; REPL-on-empty-invocation; CI-aware capability (colour,
cursor, prompts); end-to-end secret redaction (help/man/HTML defaults, error messages, a
`lib/cli/platform/log.zig` scrubber registry); `--output yaml`; `generate-docs html`;
`PATH` plugin delegation (`Config.plugins`); a mutually-exclusive-group lint.

**New modules wired to real callers:** `platform/state.zig` (atomic writes, XDG paths,
owner-only permissions), `platform/self_exe.zig` (the running binary's path — `std.process.Init`
in 0.16 carries no executable path), `platform/update.zig` gained GitHub Releases parsing,
checksum-file parsing and Ed25519 verification, `platform/telemetry.zig` gained an opt-in
reporter with an injected transport.

**`App.updateCommand`** (in `lib/cli/cli.zig`) + **`snek update`** registered in
`app/cli/cmd/root.zig` with `.resolve_target = cli.self_exe.resolveTarget`.

**Crash reporting installed**: `pub const panic = cli.crash.Panic(…)` plus
`cli.crash.install(init.io)` in both `app/cli/main.zig` and `app/cfg/main.zig`.

**Defects fixed, each with a test or a control experiment:** `platform/crash.zig`'s
`dumpCurrentStackTrace` call; `sys.zig`'s `isElevated` (`win.BOOL` vs integer) and
`openEditor` (four dead APIs); `lib/util/dry_run.zig`'s leak-on-failure and unconditional
ANSI; `lib/util/btree_store.zig`'s update-path use-after-free (**B-2**);
`lib/cli/render/spatial_focus.zig`'s underflow panic at **four** sites (**B-3**);
`lib/cli/render/tea.zig`'s stale-frame off-by-one and its reader-thread use-after-free
(**B-4**, both defects).

**Structure:** `lib/cfg_ops` moved to `app/cfg/lib/ops` and merged into the `app_cfg`
module (6 modules → 5, 15 test steps → 13), so `lib/` now holds only `util`, `cfg` and
`cli`, each with ≥2 consumers. The ops folder's "framework-free" invariant, which the merge
could no longer enforce through the build graph, is enforced by a source-scanning test in
`app/cfg/lib/ops/root.zig`.

**Documentation:** `lib/cli/ROADMAP.md` — §0.3 defines the status markers, §0.4 lists items
whose paths do not exist in this tree (see §5 below), §8.5 is the retrospective,
B-2/B-3/B-4/B-5/B-6 carry their measured resolutions.

## 3. Open work, in the order I would take it

1. ~~**Find the one dead test in `lib/`.**~~ **Resolved — see §0. There is no dead
   test; the 479-vs-478 gap was a body-less `refAllDecls` aggregator in
   `lib/cli/test/root.zig`, which is not a lost test.** Do not repeat the search.
2. ~~**`lib/util/mmap.zig`'s POSIX port.**~~ **Done, and it was the tip of a larger
   item — see ROADMAP B-6. The audits named 3 dead sites; compiling for Linux found
   **7**, across `mmap.zig`, `platform/telemetry.zig` and `util/trace.zig`.
   `zig build test-linux-compile` now gates this class, and the Linux suite was
   **executed under WSL**, where the `MmapFile` test passes.**
3. ~~**B-4's deliberate leak.**~~ **Closed, and now measured rather than argued.**
   `Program` takes an allocator (`initWithAllocator`; `init` still defaults to
   `page_allocator`), and `Program.deinit` joins the reader thread **before** freeing
   it — so any caller with a finite source can release both allocations. The `run` test
   does, under `std.testing.allocator`. Control experiment: removing that `defer` makes
   the suite fail with `2 tests leaked memory`, naming the context, the channel and the
   queue buffer. Production still leaks deliberately (`prompt.zig` never joins, because
   its thread is blocked in a real stdin read), but the claim is testable now. See the
   B-4 entry, which also records two traps that cost time — a generic test body sees the
   *ambient* instantiation's model and **hangs** rather than fails when it does not quit.
4. ~~**Run the Linux suite properly.**~~ **Done — the second platform is fully green.**
   WSL has a Linux `zig` (zvm, 0.16.0), and the whole suite passes there: **327 passed,
   1 skipped, 0 failed**. The four failures previously blamed on the environment were
   exactly that — they spawn the bare string `"zig"`, and WSL's `PATH` only reached the
   **Windows** `zig` at `/mnt/c/…/.zvm/bin`, which cannot exec under Linux. See §4 for the
   zvm setup, the `chmod +x` it needs, and the `bash -lc` gotcha.
5. **S-1–S-7** (`cli.zig` is the module root *and* an 11k-line implementation; its
   indentation hides scope; `parseFlags` is ~430 lines). Large, structural, review-heavy.
6. **N-2** — nine `app/` files still wrap a single type instead of `const Self = @This();`.
   Mechanical, wide.
7. **M-1–M-5**, **U-0 tier 3**, **U-1**, **U-2**'s remaining half.

## 4. How to verify anything here (the exact commands)

Dependencies are declared **before** the module that owns them:

```
zig test --dep cfg --dep util "-Mroot=lib/cli/root.zig" "-Mcfg=lib/cfg/root.zig" "-Mutil=lib/util/root.zig"
zig test --dep cfg --dep util "-Mroot=lib/cli/root.zig" --dep cfg --dep util "-Mcli=lib/cli/root.zig" "-Mcfg=lib/cfg/root.zig" "-Mutil=lib/util/root.zig"   # app-level
zig test lib/util/btree_store.zig            # a single module with no deps
zig test --test-filter "part of the name" …  # note: filter matches the full test name
zig build test-linux-compile                 # compile every root for the shipping OS
zig build -Dtarget=x86_64-linux-musl --cache-dir "$env:TEMP\lx" --prefix "$env:TEMP\lx-out"
```

**`-target` must come before the `-M` flags.** Placed after them it is silently ignored,
the host target is built, and the tests *run on Windows* — which looks like success and is
the opposite of the check you meant to perform.

**You can execute the Linux build here.** WSL Ubuntu is installed, so a static musl binary
runs:

```
zig test -target x86_64-linux-musl -lc --test-no-exec --dep cfg --dep util `
  "-Mroot=lib/cli/root.zig" "-Mcfg=lib/cfg/root.zig" "-Mutil=lib/util/root.zig" -femit-bin=x
wsl -d Ubuntu -- bash -lc "cp /mnt/c/<path>/x /tmp/x && chmod +x /tmp/x && cd /tmp && /tmp/x"
```

Expect **328 tests: 327 passed, 1 skipped, 0 failed**. `zig` must be on the `PATH` you
launch it with, or the four tests that spawn it fail; WSL's default `PATH` reaches
Windows' `/mnt/c/…/.zvm/bin/zig`, which is a **PE binary** and cannot exec, so use the
Linux one:

```
export PATH="$HOME/.zvm/bin:$HOME/.zvm/self:$PATH"   # zvm's Linux zig, v0.16.0
```

`bash -lc` does **not** read `~/.bashrc` on Ubuntu, so the `# ZVM` block there is not
enough for a script — export the `PATH` in the script itself. Count failures from the
summary line rather than a `...FAIL` grep, which finds only 3 of 4 when they occur.

Use `--prefix` for cross-builds: without it the Linux binaries overwrite `zig-out/bin`, and
then you must re-run a plain `zig build` before the Windows binaries work again.

## 5. Traps this session paid for — read before changing anything

* **An absence claim is only as good as the search.** A shell glob (`lib\cli\*\*.zig`) missed
  `lib/cli/test/cli_test.zig`, which led to writing "no callers and no tests" about a module
  that had a test, and the compiler then proved it by failing the build. Use the repository's
  grep tool over the whole tree, and prefer a compiler error to a search result.
* **An uninstantiated body is not a compiling body.** `version.zig`,
  `crash.zig`'s panic handler and `sys.isElevated` had all rotted onto removed APIs while
  nothing called them. Every fix ends with a test that **calls** the thing.
* **Verify a per-OS branch by cross-compiling, never by running.** `mmap.zig` passed a native
  `zig test` and failed the Linux cross-compile immediately, because the Windows branch was
  analysed and the POSIX one never was.
* **No test may read a real stdin or block.** A previous attempt at B-4 rewrote
  `tea.zig` (568 lines) with tests that drove `Program.run` against the terminal; they hung,
  which would have hung `zig build test`. It was reverted. Inject a finite source
  (`std.Io.Reader.fixed`) instead.
* **A guard that has never failed is not a guard.** Both new guards were run against a
  planted defect first (the ops-folder scan against a real `@import("cli")`, and the
  allocation-failure test against removed `errdefer`s).
* **Report the number, not the adjective.** Every item above ends with a command and its
  output. `ROADMAP.md` §0.3 defines the status markers; §0.4 lists items that name paths this
  repository does not contain (`lib/resp`, `app/kvs`, `app/scp`, `app/bus`, `src/zig`,
  `lib/util/slab.zig`) — those are design history, not a backlog.
* **A test count is a count of two different things.** Zig's compiler and Zig's test
  runner disagree by one on this tree, and both are right. A bare `test { refAllDecls(…) }`
  block has no body, so the runner never names it — but it still counts as a declaration.
  Counting bare `test {` blocks as tests manufactured the "479 declared, 478 run" gap that
  cost the previous session an audit. When a count drives a search, *prove* the missing
  item exists (a failing test, a compiler error, a control experiment) before hunting it.
  See ROADMAP C-6.
* **This session's own measurement bug is the cautionary tale for the above.** The first
  extraction of executed test names reported 322 of 323 tests and only four of the five
  anonymous blocks, because PowerShell had wrapped the *first* line (`zig : 1/323
  root.test_0...OK`) in an error record, and the `>` redirect had written UTF-16. A
  scope-blind comparison then "found" 259 unexecuted declarations that were simply in
  other modules. Two wrong analyses, both confident, both from *how the data was
  captured* rather than what it said. Check the capture before trusting the conclusion.
* **A green native test says nothing about the other OS's branch — and neither does
  reading the file.** `zig build test` analyses only the branch `builtin.os.tag` selects.
  B-6 was audited by reading and reported **3** dead sites; compiling for Linux found
  **7**, including `PROT.READ` (a packed struct in 0.16) and a `.block = .global` field
  that does not exist off Windows. Every one of them was in code that had shipped for
  months behind a green build. `zig build test-linux-compile` exists so this cannot recur,
  and it is cheap: it compiles every root for the shipping target and never runs them.
* **"We cannot execute a Linux binary here" was false, and it had been repeated in
  three documents.** WSL Ubuntu was already installed. Static musl binaries run under it
  unchanged, which upgraded the mmap fix from "compiles" to "passes". Before writing a
  limitation into a document, test the limitation — the cost of being wrong is a class of
  verification nobody attempts.
* **A `struct` with methods declared *inside a test that is inside a generic* makes the
  compiler exit `error: OutOfMemory`** — reproducibly, with 5 GB free. It is not a disk
  problem and not a real OOM: the same code compiles the moment the type moves to file
  scope. If the compiler reports `OutOfMemory` on a change that only added a test, suspect
  this before suspecting the machine.
* **Tests inside a generic container are collected per instantiation.** `Program(Model, T)`
  declares tests; each distinct `Program(A, T)` and `Program(B, T)` runs them again. Adding
  one model type can therefore add several tests, and a test-count assertion pinned to an
  exact number will need updating for a reason that has nothing to do with the change.
* **A test inside a generic that hangs takes the whole suite with it — and hangs are the
  likely failure, not asserts.** `Program`'s `run` test drove `QuitModel` while being
  *collected* under the prompt's model, which does not quit on `q`, so `run` waited for a key
  that never came. It had to be killed twice. If a test you are adding touches a generic,
  check which instantiation will collect it, and make the body independent of that choice —
  or drive it with a timeout while you work.
* **A green suite can hide a schedule-dependent assert.** `stdinReaderThread` asserted its
  channel's mutex was `.unlocked` at thread start. It is not an invariant — `Channel.pop`
  holds that lock the whole time it waits — so the assert was a latent flake that only fired
  once the new tests shifted the timing, as `1 crash` in `--summary all` while the same
  suite passed on the next run. Two lessons: **a flaky crash is a bug, not noise** (the
  assertion was simply wrong and is now gone), and when a run reports a count you did not
  expect, re-run it — `593/594` and `592/594 (1 crashed)` were the same tree.

## 6. Zig 0.16 spellings this session had to discover

`std.mem.trimLeft` → `std.mem.trim` · `std.process.Child.init` → `std.process.spawn(io, .{ .argv, .expand_arg0 = .expand, .stdin/.stdout/.stderr = .inherit })` + `child.wait(io)` · `std.crypto.random` → `io.random(buf)` · `std.posix.open` → `openat(AT.FDCWD, …)` · `std.posix.close`/`fstat` → gone (use `std.posix.system.*` or `Io`) · `std.posix.geteuid` → `std.os.linux.geteuid` · `std.debug.dumpCurrentStackTrace(addr)` → takes `.{ .first_address = addr }` · `win.BOOL` compares to `.FALSE`, not `0` · `std.Io.Dir.readFileAlloc(io, path, alloc, .limited(n))` replaces `readStreaming` · a name for an anonymous struct type is a *different* type at every mention (use a named type) · `Type` returned where a value was expected is caught by `@hasField` on a `type` · functions in a file must be **called** to be analysed, and `@embedFile` is the way to read a sibling file's source at compile time.

## 7. Briefing a worker (the pattern that worked)

The tasks that landed cleanly — `state.zig`, the GitHub/Ed25519 work, the telemetry
reporter, the `cfg_ops` relocation, B-2, B-3, B-4 — each went out with:

1. the finding **quoted verbatim** from `ROADMAP.md`, plus "verify it yourself; the document
   is a claim, not proof";
2. **"prove the bug before fixing it"** — a failing test or a demonstration, and explicit
   permission to report *"this claim is false as written"* (B-3's audit undercounted its
   sites, and that was reported rather than smoothed over);
3. a hard **file allow-list**, and "never edit a file outside your scope to make the build
   pass" (three workers ran concurrently on disjoint files);
4. the **baseline numbers and the exact gate commands**, with the instruction to report the
   before/after counts and `git status` for their files only;
5. for anything with a guard or a fix: run a **control experiment** that fails without it.

The one failure — B-4's first attempt — was the brief that lacked (5) and the "do not write
a test that can block" constraint. It cost a revert, not a bad commit.
