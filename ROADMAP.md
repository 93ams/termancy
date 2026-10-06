# snek ROADMAP

This roadmap outlines technical improvements and refactoring needed to align the `snek` repository with the Snek Engineering Standard (as defined in `AGENTS.md`).

## 1. Project Structure & Residency

**Goal**: Conform to a consolidated canonical layout by moving the scattered application and framework logic under unified domain roots.

*   **Move to `src/`**: The repository currently separates `app/` and `lib/` at the root. The new target structure is to consolidate these by domain into `src/{cli,cfg}`.
*   **The `src/{cli,cfg}/{cmd/lib}` Layout**:
    *   Merge `app/cli/` (the executables) into `src/cli/cmd/`.
    *   Merge `lib/cli/` (the framework code) into `src/cli/lib/`.
    *   Similarly, `app/cfg/` goes into `src/cfg/cmd/` and `lib/cfg/` into `src/cfg/lib/`.
*   **Domain-Agnostic Utilities**: `lib/util/` should be placed into `src/util/` or remain shared as part of the new hierarchy.

## 2. File-Level Structs

**Goal**: Eliminate redundant wrapper structs across the codebase in favor of file-level structs.

*   **Issue**: Many files currently wrap their entire contents in a `pub const X = struct { ... };`. The standard mandates that if a file's sole subject is a single type, the file *is* the type, using `const Self = @This();` at the file scope.
*   **Targets**:
    *   `lib/util/vfs.zig` (`pub const Vfs`)
    *   `lib/util/trace.zig` (`pub const TraceContext`)
    *   `lib/cli/render/style.zig` (`pub const Color`, `pub const Table`, etc.)
    *   `lib/cli/render/color.zig` (`pub const RGB`, `pub const ColorEngine`)
    *   `lib/cli/render/tea.zig` (`pub const KeyMsg`, `pub const MouseMsg`, etc.)
    *   *...and many others discovered during an audit.*

## 3. Naked `unreachable` Audit

**Goal**: Adhere to the error handling rule requiring justification for all `unreachable` states.

*   **Issue**: There are several instances of `catch unreachable` or `unreachable` that lack a preceding comment explaining *why* the state is mathematically or logically impossible.
*   **Targets**:
    *   `lib/cli/render/tea.zig`: missing comments for `mutex.lock` unreachables.
    *   `app/cfg/cmd/cast.zig`: missing comments on `w.writeAll(...) catch unreachable;`.
    *   `lib/cli/platform/update.zig` & `trace_parent.zig`: missing `std.fmt.bufPrint` unreachable comments.
    *   `lib/cli/interact/prompt.zig`.

## 4. Testing (Recursive Collection)

**Goal**: Modernize test collection to prevent silently skipped tests.

*   **Issue**: The current testing methodology heavily relies on manual, shallow `std.testing.refAllDecls(module)` chaining.
*   **Action**: Replace all manual namespace chaining in `root.zig` test blocks with the modern Zig feature: `test { std.testing.refAllDeclsRecursive(@This()); }`. This will automatically collect all tests recursively and prevent them from silently failing to run if a manual reference is forgotten.

## 5. Artifact Declarations

**Goal**: Explicitly document the artifact set for every app.

*   **Issue**: The root headers for `app/cli/root.zig` and `app/cfg/root.zig` do not document their standard set of artifacts.
*   **Action**: Update the module headers to explicitly declare the standard artifact set (Server Binary, SDK Client, In-Memory SDK, CLI, Test Classes). If an artifact is missing (e.g., In-Memory SDK for the CLI framework), it must be explicitly noted *why* it is missing.

## 6. Config-Management (`cfg`) Feature Plan

**Goal**: Complete the `config` command group features, adhering to strict owner constraints, and wire existing library operations into CLI commands.

### Hard Constraints
1. **No compilation at runtime**: Removes feature 3.2 (Comptime user configs) outright. Replaced by a comptime Zig config module compiled at build time.
2. **No background threads**: Polling is strictly forbidden. Features like 1.2 (OTA feature toggles) must be implemented via explicit, synchronous developer calls (e.g., `refreshFromUrl(io, ...)`).

### Feature Implementation Order
1. **[DONE]** `config export`, `config dry-run`, `config inspect` (Operations wired).
2. **`config set` (5.1)**: Requires comptime field-path validation and a `--dry-run` flag.
3. **`config diff` (2.3)**: Wire the config-typed field-by-field compare (`config_diff.renderDiff`) through the text line diff renderer (`style.renderDiff`). Do not confuse with dry run ledger.
4. **Fix Security Defects (4.1 & 4.2)**: 
   - *Prerequisite*: Fix the AEAD KDF (currently uses raw SHA-256, needs Argon2id or PBKDF2).
   - *Prerequisite*: Fix `Secret(T).expose()`, where two live exposed values cause a double-free on `destroy()`.
5. **Multi-tenant profiles (2.2)**: Requires real TOML block parsing.
6. **Schema migrations (3.1)**: Requires a TOML DOM for rewriting files (blocked by TOML block parsing).
7. **Remote KV (1.1) & OTA toggles (1.2)**: Requires an explicit network client (not a thread). Define "offline" caching behavior for 1.2 to avoid stale flags silently disabling features.

### Testing Deficits
*   **Issue**: Seven `lib/cfg` modules have zero tests (`toml_mutator`, `schema_migration`, `config_diff`, `profiles`, `remote_config`, `ota_flags`, `comptime_config`). Three of these rewrite files on disk or cache to disk.
*   **Action**: Coverage is a strict prerequisite before these modules can be wired into commands.
