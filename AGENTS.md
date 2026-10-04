# Tigershark Engineering Standard

**The Zig Tree (`src/zig`) Style and Architecture Guide**

This document defines *how* Zig code must be written, *where* it must live, and *what* every Tigershark application must ship. Our design goals, in order of priority, are **Safety, Performance, and Developer Experience** (derived from [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/raw/main/docs/TIGER_STYLE.md)). 

When making technical tradeoffs, resolve conflicts using this hierarchy:
1. **Performance** (on a measured hot path) overrides all below.
2. **Clarity** overrides Maintainability and Consistency.
3. **Maintainability** overrides Consistency.
4. **Consistency** is the baseline.

---

## Table of Contents
1. [Tooling & Environment](#1-tooling--environment)
2. [Canonical App Architecture](#2-canonical-app-architecture)
3. [File & Module Organization](#3-file--module-organization)
4. [The Artifact Set](#4-the-artifact-set)
5. [Zig Language & Idioms](#5-zig-language--idioms)
6. [Build & Testing Rules](#6-build--testing-rules)

---

## 1. Tooling & Environment

### 1.1 PowerShell 7+ Mandate (UTF-8)
We strictly mandate **PowerShell 7+ (`pwsh`)** for all development scripts. PowerShell 7 universally defaults to BOM-less UTF-8, which eliminates the double-decoded character corruption that historically plagued Windows PowerShell 5.1 environments. 
*   **Do not** use legacy `powershell.exe`. 
*   **Do not** introduce non-ASCII characters outside of deliberate typography (e.g., em dashes, box-drawing characters).

### 1.2 Formatting
*   `zig fmt` is law. `zig fmt --check` is a required CI gate.
*   **100 columns maximum**, without exception.
*   4 spaces, no tabs.

---

## 2. Canonical App Architecture

Every application under `src/zig/app/` adheres to a strict layout to ensure any developer can immediately locate entry points, libraries, and tests.

```text
app/<app>/
  build.zig            # The app's own build entry point
  build.zig.zon        # The app's own package manifest
  root.zig             # The app's importable surface and test collector
  main.zig             # The primary server/daemon entry point
  cmd/                 # One directory per additional binary (CLI, tools)
    <artifact>/
      main.zig         # Entry point for the specific artifact
  lib/                 # App-private modules
    <module>/
      root.zig         # The module's public surface
  test/                # Integration and e2e suites
```

### 2.1 The `main.zig` Rule
A file compiled as a native executable (`b.addExecutable`) is **always** named `main.zig`. 

This provides immediate visual clarity. A file named `main.zig` contains the `pub fn main` function and **nothing else** (no command definitions, no flags structs, no heavy logic). It is purely an entry point that wires dependencies and dispatches.

**✅ Good: Clear entry points**
```text
app/cfg/main.zig           # The cfg daemon
app/bus/cmd/cli/main.zig   # The bus CLI
```

**❌ Bad: Suffixes and wrappers hide the entry point**
```text
app/cfg/cfg_bin.zig        # Ambiguous, looks like a helper file
app/cli/cmd/cli_main.zig   # Redundant naming
```

### 2.2 The `cmd/` Directory
The `cmd/` directory holds secondary artifacts (like CLIs or test tools) and subcommand implementations. 

If an app has multiple binaries, they live in `cmd/<artifact>/main.zig`. The artifact directory drops redundant prefixes. 

**✅ Good: Dropping redundant names**
```text
app/bus/cmd/bench/main.zig   # Compiles to `bus-bench`
```

**❌ Bad: Repeating the app name**
```text
app/bus/cmd/bus-bench/main.zig 
```

---

## 3. File & Module Organization

### 3.1 Folder Surfaces (`root.zig`)
Any directory exporting a module or shared interface **must** have a `root.zig`. This file acts as the module's API surface, documenting its purpose (`//!`) and re-exporting necessary internals. Consumers should never need to reach deep into a module's internals (e.g., avoid `@import("lib/net/internal/socket.zig")`).

### 3.2 The Residency Rule (App vs. Shared Libraries)
Code lives with its domain. 
*   **`app/<app>/lib/`**: For modules that know about a specific app's domain (even if other apps import it). E.g., The RESP protocol codec belongs in `app/kvs/lib/resp`, not a global folder.
*   **`src/zig/lib/`**: Strictly for domain-agnostic code with **at least two** consumers (e.g., bytes, buffers, TLS, generic data structures).

### 3.3 File-Level Structs (Avoid Redundant Wrappers)
If a file's sole subject is a single type, the file *is* the type. Use `const Self = @This();` at the file scope. Do not wrap it in a redundant struct.

**✅ Good: The file is the struct**
```zig
// raw_terminal.zig
const Self = @This();
enabled: bool = false,

pub fn enable() !Self { ... }
```
```zig
// Usage:
const RawTerminal = @import("raw_terminal.zig");
var rt = try RawTerminal.enable();
```

**❌ Bad: Redundant wrapper struct**
```zig
// raw_terminal.zig
pub const RawTerminal = struct { ... };
```
*(Exception: `union(enum)` cannot be declared at file scope and must keep its wrapper).*

### 3.4 Dependency Management
*   **Minimal Dependencies:** Avoid third-party dependencies for functionality that can be trivially implemented using the Zig standard library or our shared `src/zig/lib/`.
*   **Explicit Pinning:** All external dependencies in `build.zig.zon` must be explicitly pinned with hashes to ensure reproducible builds.

---

## 4. The Artifact Set

A Tigershark app is a domain with a standard set of artifacts. Every app must explicitly declare its artifacts in its `root.zig` header. If one is missing, note *why*.

1. **Server Binary:** The daemon or process (`main.zig`).
2. **SDK Client:** An in-tree API surface speaking the wire protocol.
3. **In-Memory SDK:** A local, in-memory implementation of the SDK interface. **This is not a mock.** It is a real backend verified against the exact same compile-time assertions as the wire client, used for offline operation and fast testing.
4. **CLI:** A command-line interface driven by the SDK (`cmd/`).
5. **Test Classes:** End-to-End (`test/`), Fuzzers (`cmd/fuzz/`), and Benchmarks (`cmd/bench/`).

---

## 5. Zig Language & Idioms

### 5.1 Memory & Allocations
*   **Servers:** No allocations on the connection hot path. Pre-allocate at startup.
*   **CLIs/Tools:** May allocate, provided ownership is explicit.
*   **Allocate before you mutate:** Check limits, perform allocations, and register `errdefer` before mutating existing state to avoid partial updates on failure.
*   **The `Value` Ownership Rule:** If a struct returns dynamically allocated data, it must own **all** its bytes (no mixing literal pointers with allocated pointers), allowing a simple `.deinit()` call.

### 5.2 Control Flow & Function Shape
*   **70-line limit:** Functions should fit on a single screen. Extract complex branching or deep logic into descriptive helpers.
*   **Bound every loop and queue:** Unbounded queues cause latency spikes and memory leaks. Document the upper bound.
*   **Early Returns / Positive Invariants:** Push `if`s up, `for`s down. State conditions positively (`if (index < count)`) to reduce cognitive load. 

### 5.3 Safety & Assertions
*   **Assert generously:** Aim for at least two assertions per function. Validate boundaries, preconditions, and invariants.
*   **Pair Assertions:** Assert state before a write and after a read across the boundary.
*   **Split Compound Assertions:** 
    *   ✅ `assert(a); assert(b);`
    *   ❌ `assert(a and b);` (Hides which condition failed).

### 5.4 Error Handling
*   **No naked `unreachable`:** Never use `catch unreachable` or `unreachable` without a preceding comment explaining exactly *why* the state is mathematically or logically impossible.
*   **Error Sets:** Keep error sets narrow and specific to the domain. Avoid massive global error sets.
*   **Contextualize Errors:** When bubbling up errors across domain boundaries, consider transforming them to add domain-specific context instead of leaking generic internal errors.

### 5.5 Naming & Documentation
*   **Standard Zig Conventions:** Adhere to standard Zig casing: `PascalCase` for types, `camelCase` for functions and variables.
*   **Doc Comments:** Use `///` for public declarations (functions, types) and `//!` for module-level documentation.
*   **Self-Documenting Code:** Optimize for readability. Prefer descriptive variable names (`clientConnection`) over terse ones (`c`) unless the scope is extremely small (e.g., within a 3-line loop).

---

## 6. Build & Testing Rules

### 6.1 Build File Constraints
*   **One graph per app:** An app's standalone `build.zig` and the root repository's `build.zig` must import the same `build/install.zig` wiring.
*   **Relative Paths:** `b.path()` is relative to the *build root* (the directory holding the `build.zig.zon`), not the file calling it.

### 6.2 Testing
*   **Recursive Collection:** Take advantage of modern Zig testing by using recursive declaration collection in `root.zig` files. This replaces manual namespace chaining and prevents tests from silently failing to run.
    ```zig
    test {
        std.testing.refAllDeclsRecursive(@This());
    }
    ```
*   **Memory Leak Detection:** Always use `std.testing.allocator` in tests. This guarantees that memory leaks within the tested unit are caught automatically during the test run.
*   **E2E vs. Benchmarks:** 
    *   *End-to-End (`test/`)* suites cross process/socket boundaries. If a test can be a unit test, it should be a unit test.
    *   *Benchmarks (`cmd/bench/`)* are for measuring host-dependent performance and are **deliberately excluded** from `zig build test` to avoid spurious CI failures.
*   **Fuzzing:** Fuzzing uses deterministic seeded PRNGs with the malformed targets committed directly to source for immediate reproducibility. Do not pull in heavy external fuzzing dependencies.