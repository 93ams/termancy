# HANDOVER — start here

**For:** the next session or agent picking up this work.
**State:** every gate is green, **nothing is committed**. Read §1, then §2, then pick from §3.

Last verified numbers (run them yourself before trusting anything here):

| Gate | Expected |
|---|---|
| `zig build test --summary all` | `13/13 steps succeeded; 587/588 tests passed (1 skipped)` |
| `zig build test-direct --summary all` | `13/13 steps succeeded` |
| `zig fmt --check build.zig build lib app` | exit 0, no output |
| `zig build` | exit 0; `.\zig-out\bin\tigershark.exe --version` → `v0.1.0` |
| `git status --porcelain` | ~62 changed paths, all uncommitted |

If you see `OutOfMemory` from the compiler, or test binaries exiting `255` with no test
failure, **check free disk space first**: `.zig-cache` grew to 7.6 GB during this work and a
nearly-full volume produced both symptoms, neither of which was a code failure. Deleting
`.zig-cache` restores ~8 GB and the next build recreates it.

---

## 1. Do this first: commit the green tree

The roadmap's own item **C-3** asks for it, and every remaining task lands more easily from
a known-good base. ~62 paths are uncommitted, including two new files
(`lib/cli/platform/state.zig`, `lib/cli/platform/self_exe.zig`), six renames
(`lib/cfg_ops/*` → `app/cfg/lib/ops/*`, shown by git as `R100`, i.e. content-identical), and
one deletion (`lib/cli/version.zig`, superseded — see the note left in `lib/cli/cli.zig`).

Inspect before committing: `git status --porcelain`, `git diff --stat`, and
`git diff --cached -M --name-status` (the renames are staged).

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

**`App.updateCommand`** (in `lib/cli/cli.zig`) + **`tigershark update`** registered in
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

1. **Find the one dead test in `lib/`.** Measured: `lib/` has 479 test declarations
   (471 named + 8 anonymous `test {` blocks) but only **478 run** (util 31 + cfg 124 +
   cli 323). `app/` reconciles exactly (110 = 110), so this is a `lib/` problem. Method:
   capture the suite's emitted names (`N/588 test.<module>.test.<Name>…OK`), extract the
   declared names with `^\s*test "([^"]+)"`, and diff the sets. A test inside a **generic
   container** that is never instantiated does not run — `lib/cli/render/tea.zig:313` is
   such a test and only runs because its instantiation is reached — so check for that as
   well as for a file no aggregator reaches. This is the same failure mode as the roadmap's
   opening item (C-1: 91 dead tests), so it is worth the hour.
2. **`lib/util/mmap.zig`'s POSIX port** (the whole residue of B-6). Three dead APIs:
   `std.posix.open` → `std.posix.openat(std.posix.AT.FDCWD, …)` (works),
   `std.posix.close` → `std.posix.system.close(fd)` (works; its result is an error *code*,
   so discard it), and `std.posix.fstat` — **gone, with no `posix` replacement**. Either
   use the syscall layer directly (`linux.fstat`/`std.c.fstat` with a `Stat` out-parameter
   and a manual error check) or move the file onto `Io` (which changes `MmapFile.open`'s
   signature to take an `io`). An attempt was made and **reverted**: a file that still
   cannot cross-compile is not an improvement.
3. **B-4's deliberate leak.** One reader context plus one channel per prompt is allocated
   from `page_allocator` and never freed, because 0.16 cannot cancel a blocked stdin read
   (the full analysis is in the B-4 entry). If a pollable-stdin mechanism ever appears, the
   leak can go.
4. **S-1–S-7** (`cli.zig` is the module root *and* an 11k-line implementation; its
   indentation hides scope; `parseFlags` is ~430 lines). Large, structural, review-heavy.
5. **N-2** — nine `app/` files still wrap a single type instead of `const Self = @This();`.
   Mechanical, wide.
6. **M-1–M-5**, **U-0 tier 3**, **U-1**, **U-2**'s remaining half.

## 4. How to verify anything here (the exact commands)

Dependencies are declared **before** the module that owns them:

```
zig test --dep cfg --dep util "-Mroot=lib/cli/root.zig" "-Mcfg=lib/cfg/root.zig" "-Mutil=lib/util/root.zig"
zig test --dep cfg --dep util "-Mroot=lib/cli/root.zig" --dep cfg --dep util "-Mcli=lib/cli/root.zig" "-Mcfg=lib/cfg/root.zig" "-Mutil=lib/util/root.zig"   # app-level
zig test lib/util/btree_store.zig            # a single module with no deps
zig test --test-filter "part of the name" …  # note: filter matches the full test name
zig build -Dtarget=x86_64-linux-musl --cache-dir "$env:TEMP\lx" --prefix "$env:TEMP\lx-out"
```

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
