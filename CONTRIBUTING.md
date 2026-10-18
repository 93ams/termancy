# Contributing

Issues and pull requests are welcome. For anything larger than a fix, open an issue first,
so the shape is agreed before you write it: [ROADMAP.md](ROADMAP.md) says what is planned,
and its first section what is left out on purpose, and why.

## Building

Zig **0.17.0**, nothing else. `zig build` builds `zig-out/bin/termancy`; the README's "Building
and testing" table lists the other steps. Before a pull request, run what CI runs:

```sh
zig build test check
```

`test` checks formatting and runs the unit, end-to-end, example, and compile-error tests;
`check` compiles everything for Linux, macOS, and Windows. On WSL with the repository on a
Windows drive (`/mnt/c/...`), give Zig a cache on the Linux side:
`--cache-dir ~/.cache/zig-termancy`. What is still to do on Windows is in
[docs/windows.md](docs/windows.md).

## Style

- Lines are at most 100 columns (Markdown tables excepted); `zig build fmt` formats.
- Match the code around you: its naming, its comment density, its tests.
- Every public declaration has a `///` comment; a module starts with a `//!` one.
- New behaviour comes with a test; a bug fix with the test that failed before it.
- Libraries import only `std` (`cli` and `tui` also import `term`); `termancy` uses only their
  public surfaces. What is public and stable is in [docs/stability.md](docs/stability.md),
  and what `termancy` prints for scripts is a contract:
  [docs/machine-output.md](docs/machine-output.md).
- The version is written once, in `build.zig.zon`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org): `fix(cfg): ...`,
`feat(tui): ...`, `feat!: ...` for a breaking change. Anything a user would notice also
gets a line in the Unreleased section of [CHANGELOG.md](CHANGELOG.md).

## Security

Report vulnerabilities privately, as [SECURITY.md](SECURITY.md) says, never in an issue.
