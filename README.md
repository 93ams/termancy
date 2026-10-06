# snek

A Zig toolkit for building command-line applications: a command framework, a
configuration framework, and the pieces an operator-facing binary needs.

This repository was extracted from the **upstream `snek` monorepo**, where these
two subsystems lived as `src/zig/app/cli` and `src/zig/app/cfg`. They are mutually
dependent — `app/cli` imports `app_cfg` and `app/cfg` imports `cli` — which is why
they move together and why they are worth owning in one repository rather than two.
The two share a name, so where the distinction matters this README says "the upstream
monorepo" and "this repository": the dependency direction is the point, and the name
cannot carry it.

## Layout

```text
build.zig            One build root for the whole repository
build/targets.zig    Target policy and the test-root plumbing
lib/cli/             The command framework (module `cli`)
lib/cfg/             The configuration framework (module `cfg`)
lib/util/            Vendored primitives, so this repo depends on nothing else
app/cli/             The `snek` binary and its command set
app/cfg/             The `cfg` binary and the `config` command group
app/cfg/lib/ops/     Configuration operations, no CLI dependency (module `app_cfg`)
```

Two design points worth knowing before reading the code:

* **The operations in `app/cfg/lib/ops` are framework-free on purpose.** They import
  `cfg` and `util` and never `cli`, so a server binary that has no `App` can still
  use configuration management. They are files of the `app_cfg` module, reached
  through its `ops` surface; a module of their own bought nothing but a second test
  root. That makes "no `cli` here" a review rule rather than a build error - while
  `ops` was its own module, the module's import table enforced it.
* **`lib/util` is a deliberate copy.** The upstream monorepo still consumes this
  repository's `cfg` and `cli` modules, so a back-dependency would be a package
  cycle. `lib/util/root.zig` records what was copied and why it is the closure
  actually used rather than the whole library.

## Building

```sh
zig build                          # installs `snek` and `cfg` into zig-out/bin
zig build test                     # every unit test
zig build test-direct              # the same tests, as direct child processes
```

## Status

The code is a relocation, not a rewrite: module names, binary names and
behaviour are unchanged from the monorepo, so the two can be compared directly
while the extraction is verified. `lib/cli/ROADMAP.md`, `lib/cli/RECONSTRUCTION.md`
and `app/cfg/PLAN.md` are the in-tree status documents and were carried over
with the code.

Those documents link to paths in the monorepo (`../../../../ROADMAP.md`,
`app/bus/ROADMAP.md`) which no longer resolve from here; their relative links are
stale, their content is not.
