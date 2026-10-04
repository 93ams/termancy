# snek

A Zig toolkit for building command-line applications: a command framework, a
configuration framework, and the pieces an operator-facing binary needs.

`snek` was extracted from the [tigershark](https://github.com/93ams/tigershark)
monorepo, where these two subsystems lived as `src/zig/app/cli` and
`src/zig/app/cfg`. They are mutually dependent — `app/cli` imports `app_cfg` and
`app/cfg` imports `cli` — which is why they move together and why they are worth
owning in one repository rather than two.

## Layout

```text
build.zig            One build root for the whole repository
build/targets.zig    Target policy and the test-root plumbing
lib/cli/             The command framework (module `cli`)
lib/cfg/             The configuration framework (module `cfg`)
lib/cfg_ops/         Configuration operations, no CLI dependency (`app_cfg_ops`)
lib/util/            Vendored primitives, so this repo depends on nothing else
app/cli/             The `tigershark` binary and its command set
app/cfg/             The `cfg` binary and the `config` command group
```

Two design points worth knowing before reading the code:

* **`cfg_ops` is framework-free on purpose.** It imports `cfg` and `util` and
  never `cli`, so a server binary that has no `App` can still use configuration
  management. This is enforced by the module's import table, not by convention.
* **`lib/util` is a deliberate copy.** The monorepo that `snek` came from still
  consumes `snek`'s `cfg` and `cli` modules, so a back-dependency would be a
  package cycle. `lib/util/root.zig` records what was copied and why it is the
  closure actually used rather than the whole library.

## Building

```sh
zig build                          # installs `tigershark` and `cfg` into zig-out/bin
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
