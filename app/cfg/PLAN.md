# Config-management commands: status and plan

## Two hard constraints (owner decisions)

These are **design constraints, not preferences**, and they change several rows below.

**1. No compilation at runtime.** The config system must never invoke a compiler,
and must never execute a produced artifact. This removes feature **3.2** outright -
it is defined by calling the Zig compiler at runtime and running what it emits.

**2. No background threads.** The config system must never own a thread that does
work on its own schedule. Anything that would have been a poller becomes **a
function the developer calls when they choose.** This removes the *poller* from
feature **1.2** while leaving its registry intact - `OtaFlagRegistry` is already
100% synchronous (`setFlag`, `isEnabled`, `assertAllowed`, `loadFromJson`), so the
thread was only ever going to be a caller of it.

The second constraint has a consequence worth stating plainly, because it is the
project's actual security posture: **a config load performs no work the developer
did not ask for.** No implicit network call, no timer, no cache refresh behind the
caller's back. A refresh happens when a line of code says so.

## The question this answers

*"Do we have the config management commands in `src/zig/app/cfg`?"* — **No.**

There is exactly **one** command there, and it is a demonstration: `config`,
which resolves a fictional `ServerConfig { port, host, enable_cors, api_key }` to
show the merge engine working. **None** of the requested features is reachable from
a command line today.

What *does* exist is the library layer: nine modules in `lib/cfg` (plus four in
`lib/cli` / `lib/util`) that already implement most of the operations. So the work
is not "build 14 features" — it is **wire existing operations to commands, and
finish the handful that genuinely do not exist yet.**

## The structural blocker, and how this folder is laid out to fix it

`app/cfg` used to expose only:

```zig
pub fn Commands(comptime AppT: type) type   // AppT must be a cli.App(...)
```

`app/kvs` and `app/scp` have **no `App`** and do not import `lib/cli`, so they
**cannot reach any of this**. The shared config-command home is unreachable without
adopting the whole CLI framework first — which is why the "make the apps use the
shared libraries" half of the roadmap had stalled.

So this folder is split by **audience**, not by feature:

| Folder | Module | Contains | Callable from |
|---|---|---|---|
| `ops/` | `app_cfg_ops` | Framework-agnostic operations. Plain functions using `std` + `lib/cfg` + `lib/util` only, no `cli.Ctx`. | A command, a server binary, a test |
| `cmd/` | `app_cfg` | Thin `cli.App.Command` wrappers: parse flags, call `ops`, render. One file per command. | The CLI framework |

`Commands(AppT, ConfigT)` is the assembly point that returns the command group.
`ConfigT` is a second parameter because an operation is defined over a
*configuration type*, not over an app.

### This is done, and it is enforced rather than asserted

The split is not a plan any more. Measured:

```text
app/kvs, app/scp files importing "cli"          0
app/cfg/ops files importing "cli"               0
zig build test-kvs-config                       4/4 tests passed
```

`app/kvs/config_link_root.zig` calls all three operations against a `kvs`-shaped
config type, in a module whose import table holds **only** `app_cfg_ops` and `cfg`.
A `cli` import reappearing anywhere under `ops/` fails that build. That guard exists
because the stall this work removed was invisible: nothing failed, the commands were
simply unreachable.

Two things had to change to make it real:

* **`systemd_exporter.zig` moved from `app/cli/lib/platform/` to `lib/util/`.** It takes
  a `std.Io.Writer` and a slice of key/value pairs and mentions no terminal, no flag
  and no command — which is `lib/util`'s stated criterion. `lib/cli` re-exports it
  under its historical name, so no caller changed.
* **`app/cfg/lib/scalar.zig` gained `parseValue`**, the "does this text belong in this
  field" counterpart to the duration and byte-size grammars. Dry-run needed it, and
  `app/bus/config` had grown its own copy.

## Status of every requested feature

**op ready** = the operation exists and is usable, and only a command is missing.
**partial** = exists but is missing the part the feature is actually about.
**none** = does not exist.

### 1. Remote & Distributed Configuration

| # | Feature | Library | Verdict |
|---|---|---|---|
| 1.1 | Remote KV subscriptions (etcd / Consul) | `cfg.remote_config` (86L) | **partial, allowed** — cache read/write with ETag exists (`readCache`, `writeCache`, `freeState`); **the HTTP fetch does not**. Permitted because the spec's fetch is a *one-shot synchronous call at a point the caller chooses*, not a poller. Must stay that way: a `refresh()` function, never a thread. |
| 1.2 | OTA feature toggles | `cfg.ota_flags` (64L) | **registry ready; poller REMOVED by constraint 2.** `setFlag` / `isEnabled` / `loadFromJson` / `assertAllowed` all exist and are synchronous. What is dropped is the background poll. What replaces it is a function - `refreshFromJson(json)` and a `refreshFromUrl(io, ...)` the developer calls explicitly. Note `assertAllowed` has **no caller anywhere** (roadmap §5.3). |

### 2. State Management & Lineage

| # | Feature | Library | Verdict |
|---|---|---|---|
| 2.1 | Lineage & blame (`config inspect`) | `cfg.config_lineage` (141L) | **op ready** — `record` / `getProvenance` / `inspect` are all real, and `inspect` already renders the `Value: ... / Type: ... / Source: ...` line the spec asks for. **Not wired to a command.** |
| 2.2 | Multi-tenant profiles | `cfg.profiles` (52L) | **partial** — `getCurrentContext` and `switchContextContent` exist; **no `--profile` / `ZCLI_PROFILE` jump, and no TOML block parsing**. |
| 2.3 | Visual config diff | `cfg.config_diff` (43L) | **partial** — a field-by-field differ exists; **no colour and no `style` use**. Wiring it means picking between *three* existing `renderDiff`s (see below). |

### 3. Versioning & Programmability

| # | Feature | Library | Verdict |
|---|---|---|---|
| 3.1 | Schema migrations | `cfg.schema_migration` (59L) | **partial** — `extractVersion` and `migrate` exist; **rewriting the upgraded TOML back to disk needs a DOM**, which does not exist yet. Allowed: it runs when the developer calls it, on a file the developer named. |
| 3.2 | Comptime user configs | `cfg.comptime_config` (40L) | **REMOVED by constraint 1.** The feature *is* "invoke the Zig compiler at runtime and execute the artifact"; with runtime compilation prohibited there is no version of it left. `comptime_config.zig` stays in the tree but is not a command. See "What replaces 3.2" below. |

### 4. Security & Cryptography

| # | Feature | Library | Verdict |
|---|---|---|---|
| 4.1 | Encrypted config at rest | `cli.encrypted_config` (76L) | **partial + defect** — the AEAD usage is correct, but the KDF is **raw SHA-256** and the **salt is the nonce** (attacker-chosen). The spec asks for Argon2id; `lib/sec/pkcs/pkcs5.zig` already has correct PBKDF2. |
| 4.2 | `Secret(T)` ephemeral secrets | `cli.secret_val` (75L) | **partial + defect** — mmap + `mlock` exist; **`expose()` is a copyable capability that owns destruction**, so two live `Exposed` values make the first `destroy()` free what the second still points at. |

### 5. DX & Ecosystem Tooling

| # | Feature | Library | Verdict |
|---|---|---|---|
| 5.1 | TOML DOM mutator (`config set`) | `cfg.toml_mutator` (56L) | **op ready** — `setValue` is comment-preserving. **Not wired**, and the comptime field-path validation the spec describes is not implemented. |
| 5.2 | Dry-run testing | `cfg.config_dryrun` (79L) | **op ready** — `parseOverride` + `renderMatrix`. **Not wired.** |
| 5.3 | Dotfiles / systemd export | `cli.systemd_exporter` (98L) | **op ready** — `exportDotEnv` + `exportSystemdService`. **Not wired.** |

### Counting it up

- **5 features are operations waiting for a command** (2.1, 5.1, 5.2, 5.3).
- **6 need real work, and are allowed** (1.1, 1.2, 2.2, 2.3, 3.1).
- **1 is REMOVED by owner constraint** (3.2, runtime compilation).
- **2 carry a security defect** that must be fixed *before* the command is allowed
  to exist: 4.1's KDF and 4.2's `expose`.

Nothing here is blocked on the spec's fictional `zcli` / `mycli` naming.
Everything maps onto `lib/cfg` + `lib/cli`.

## What replaces 3.2, given no runtime compilation

The *goal* of 3.2 was "let users express configuration with logic instead of static
TOML". Dropping runtime compilation does not drop the goal — it moves the logic to
where this language already puts it, **comptime**:

| Option | How it works | Trade |
|---|---|---|
| **A. Comptime Zig config module** *(recommended)* | The user writes a `config.zig` that is **imported and compiled as part of the build**, exactly like `app/*/cmd/root.zig` already are. The file evaluates at comptime and produces a `ConfigT` value. | Turing-complete at build time, zero runtime cost, no compiler invocation at run time, and a compile error instead of a runtime one. The user recompiles to change config - which is the honest cost, stated up front. |
| **B. Generated JSON, user-edited** | A build step emits the resolved JSON; the user may hand-edit it; the CLI reads JSON. | No logic, but no compiler either. |
| **C. Nothing** | Keep TOML + env + flags only. | Least capable, least risk. |

**A is the recommendation.** It satisfies the constraint and the stated impact
("*Turing-complete configuration logic with zero performance penalty on subsequent
runs*") more completely than the runtime version did, because there is no
compilation step at all on subsequent runs.

## Order of work, by value per unit of risk

1. **[DONE] 5.3 export**, **5.2 dry-run**, **2.1 inspect** — the operations already
   existed. No new dependency, no network, no thread, no compiler. This is also
   where the `ops/` split got proven, because these three need no framework at all.

   Shipped: `config export` (`--format dotenv|systemd`), `config dry-run`
   (`--overrides`), `config inspect` (`[path]`), and bare `config`. All four work
   from the `tigershark` binary. 33 tests in `test-app-cfg-ops`, 18 in
   `test-app-cfg`, plus 4 in `test-kvs-config` proving reachability from `kvs`.

   Verified end-to-end from the command line:

   ```text
   $ tigershark config --help
     export    Write the resolved configuration as environment variables
     dry-run   Validate configuration overrides without applying them
     inspect   Explain where a configuration value came from

   $ tigershark config inspect
     Value: 8080 | Type: u16 | Source: DEFAULT (built-in default)
     Value: [SECRET len=0] | Type: ?[]const u8 | Source: DEFAULT (built-in default)

   $ PORT=7777 tigershark config inspect port
     Value: 8080 | Type: u16 | Source: ENV (PORT)
   ```

   A secret is reported by length and never by value on every path — that is
   asserted, not assumed, and the assertion is specifically one that a redaction
   returning the value would fail.

   **Two limitations found while building this, recorded rather than hidden:**

   * **A string field accepts any value in dry-run.** `host=nope` passes, because
     "nope" is a valid `[]const u8`. The check is structural by design and
     `lib/cfg` has no `.validate` hook (P-2), so "is this a valid host" cannot be
     answered. `port=not-a-port` and `nosuchfield=1` both fail correctly.
   * **Repeatable flags are not expressible.** `cli.zig:1290` is an explicit
     `@compileError("Unsupported pointer type for flag")` for a slice-of-slices, so
     `--overrides` takes one space-separated argument and a value containing a space
     cannot be given. Fixing that is a framework change in A-1's area.

2. **5.1 `config set`** — `toml_mutator.setValue` exists; needs the comptime
   field-path validation and a `--dry-run`. The field table in `ops/fields.zig` now
   does the path resolution this needs, so it is smaller than it was.
3. **2.3 `config diff`** — wire `config_diff` through `style.renderDiff`, which
   already exists.
4. **4.1 / 4.2** — **fix the two defects first.** An Argon2id-shaped hole filled
   with raw SHA-256 is a false assurance, and a `Secret` whose first `destroy()`
   invalidates the second is worse than no wrapper.
5. **2.2 profiles** — needs real TOML block parsing.
6. **3.1 migrations** — needs a TOML DOM. Same blocker as 2.2.
7. **1.1 and 1.2** — allowed, but **each still needs an explicit decision**, and
   the constraints here narrow it rather than settling it:
   - Both add an **outbound HTTP client** to a config path that currently performs
     no network I/O. That is a dependency and a trust-surface question.
   - Per constraint 2, the fetch must be a **function the developer calls**, never
     wired into `App.run` and never on a thread. Concretely: `remote_config.refresh(io, ...)`
     and `ota_flags.refreshFromUrl(io, ...)`, each returning the new state.
   - 1.2 additionally needs a decision on **what "offline" means**: the spec wants a
     last-known-good cache, which is a file on disk the developer's call reads -
     acceptable, but it means a stale flag can disable a feature long after the
     fact, and that should be a deliberate choice rather than a side effect.

## 3.2 is removed, not deferred

Recorded explicitly so it is not quietly re-added: **`app/cfg` will not compile
anything at runtime and will not execute a compiled artifact.** `comptime_config.zig`
stays as a library file, but there will be no `config compile` command.


## Three `renderDiff`s, and which to use

Feature 2.3 needs the red/green unified format. There are **three** functions with
that name, and they are not interchangeable:

| Location | Signature | What it does |
|---|---|---|
| `app/cfg/lib/config_diff.zig:4` | `(writer, default_cfg, active_cfg, show_unchanged) !usize` | **Config-typed** field-by-field compare. This is the one 2.3 is *about*. No colour. |
| `app/cli/lib/render/style.zig:205` | `(writer, old_content, new_content) !void` | **Text** line diff with `-`/`+` in red/green. This is the renderer to reuse. |
| `lib/util/dry_run.zig:45` | `(self: DryRunLedger, writer) !void` | Renders a *mutation* ledger, a different problem. |

So 2.3 is `config_diff.renderDiff` (what changed) piped through
`style.renderDiff`'s colouring (how to show it) — not a choice between them. The
third is unrelated and should not be merged.

## A gap that outranks several features

**Seven `lib/cfg` modules have zero tests.** Corrected: this said "all nine", which an
independent audit refuted by running the suite. The measured split is 20 tests across
`config_lineage`, `scalar`, `loader`, `cfg` and `config_dryrun`; the seven with **no**
tests are `toml_mutator`, `schema_migration`, `config_diff`, `profiles`,
`remote_config`, `ota_flags` and `comptime_config`. Those seven are the ones that
matter, because three of them rewrite files.

They compile, which is not the same
as working — this repository has already found five never-compiled functions that
way (`app/cli/lib/ROADMAP.md` N-2).

Three of them **rewrite files on disk** (`toml_mutator`, `schema_migration`,
`profiles`), and one caches to `~/.cache` (`remote_config`). Coverage is a
prerequisite for those becoming commands, not a follow-up.

## What this plan does not change

The defects already recorded in `app/cli/lib/ROADMAP.md` §5.3 stay open and are
**prerequisites, not follow-ups**:

- `config.zig` has no `deinit` — the secret is duped to the heap and only the
  struct is destroyed.
- `config_diff.zig` prints every changed field in cleartext.
- Two flag gates fail open (`ota_flags`'s unknown-flag `orelse true`,
  `policy.zig`'s nested `required_flag` check).
