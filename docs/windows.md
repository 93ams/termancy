# Windows

The state of Windows, measured on 2026-10-16 by running the build natively on Windows 11
with Zig 0.17.0 (`zig.exe`, through anyzig), not cross-compiled:

| Step | Result |
|---|---|
| `zig build unit` | passes |
| `zig build examples e2e console` | passes (`console`: seven cases under ConPTY) |
| `zig build test check` (what CI runs) | passes, `check` cross-compiling from Windows, `aarch64-windows` included |

To rerun from WSL, with a cache on the Windows side:

```sh
cmd.exe /c "zig build test check console --summary all --cache-dir %LOCALAPPDATA%\zig-termancy-cache"
```

## Done

What the first native run found, and what changed:

- **Every TUI program on a Windows console crashed.** `Io.Batch.awaitConcurrent` cannot wait
  on a console handle (it is never asynchronous), says `ConcurrencyUnavailable`, and leaves
  the batch broken, so the `awaitAsync` fallback panicked (undefined behaviour in release).
  `tui.Program.run` and `term.graphics.detectByQuery` now wait on Windows with
  `Terminal.waitInput` (`WaitForSingleObject` on the console, with the queue's non-text
  events taken out; a pipe, as under mintty, is polled) and read directly, so timers fire
  without input too. Console case `ticks`.
- **SSH client trace on close.** `Client.close` shut the socket down under its own reader,
  which Windows reports as `error.Unexpected` (`PIPE_DISCONNECTED`) with a stack trace in
  Debug. The reader now stops first, and `Transport.take` maps that one `Unexpected` from
  a socket to `error.Disconnected` (a `shortcut:`).
- **Paths.** One rule, `sys.files.join` (and a copy in `cfg`): a path shows the way it
  was written, and new parts take the separator it already uses (`./termancy.toml`,
  `conf/shared/base.yaml`, `C:\x\termancy.toml`). Used by `cfg` sources and includes,
  `findFile`, `termancy md`, and `examples/repos`; tests of native paths use `sep_str`.
- **`term.Pty` reads never ended on Windows**: the pseudo console keeps its output open
  after the program exits. A thread now closes it when the program ends, so `termancy cli
  explain`, `record`, and `serve` see the end as on POSIX.
- **A web session whose browser never answered the close kept its task and its slot.**
  `sys.web.Server` stopped the socket's reader with `shutdown`, which on Windows does
  not wake a pending read (zig-issues.md, issue 4). The reader is a task of its own now,
  canceled when the session ends, the browser goes silent, or the reader stops. Test "a
  session ends though its browser never answers the close".
- **`PAGER` with a Windows path** lost its backslashes (split by POSIX shell rules); it is
  split by `CommandLineToArgvW`'s rules on Windows now.
- **`termancy record` with `Set Shell cmd`** ran the user's AutoRun commands (clink); `cmd`
  starts with `/d` now.
- **Text outside ASCII was garbled at a console on its default code page** (437, 850, ...:
  most installs, unless "Use Unicode UTF-8 for worldwide language support" is on): `✓`
  showed as `Γ£ô`, and typed answers came in that code page. `App.run` switches the console
  to UTF-8 for the run and puts it back (`cli.terminal.useUtf8`). Console case `utf8`,
  which starts at code page 437 and checks it is restored.
- **`EDITOR` and `VISUAL` with a quoted path** (`"C:\Program Files\...\code" --wait`) were
  split at the spaces inside the quotes; on Windows they are split as a command line now.
- **`aarch64-windows`**, which the release builds, is in `zig build check`. It caught a
  function pointer cast that compiled only on x86_64.
- **Checked and fine:** CRLF config files in every format (values normalized, `cfg set`
  keeps CRLF), paths outside ASCII, paths of 468 characters, editors that are `.cmd` shims.
- **Not implemented before, now done:** ssh-agent over `\\.\pipe\openssh-ssh-agent` (the
  default on Windows when `SSH_AUTH_SOCK` is unset); `term.live` shows the cursor again on
  Ctrl-C, Ctrl-Break, and console close (console case `spin`); WebAuthn registration and
  assertions through Windows Hello, `sys.windows_hello`, the way to a FIDO key on
  Windows (`windows_hello.register` returns a `webauthn.Registration`, whose `credential`
  is what a relying party keeps).
- **Distribution:** `termancy release manifest -f winget` writes a winget manifest
  (single-file form, a zip with a portable `termancy.exe`), and the release publishes it with
  the Homebrew and Scoop ones. The release Authenticode-signs `termancy.exe` with
  `osslsigncode` when the secrets `WINDOWS_CERTIFICATE` and `WINDOWS_CERTIFICATE_PASSWORD`
  are set.
- **Tests that skipped Windows now run there:** `process.which` (Windows rules), `capture`
  (output, status, cwd, environment, limits, timeout kill), `stream`, `editText`, plugins
  on `PATH` (`cli`, `examples/kv`), help through the pager, `ui spin`'s `runChild`, raw
  mode on a non-terminal, `Pty` on ConPTY, `explain` and `record`, and `sandbox`
  links where Windows allows them. Test-only fixes: a TOML literal string for a temp path,
  file timestamps set through the file (`Dir.setTimestamps` is a TODO panic in 0.17), the
  `pwsh` alias passed as a plain argument, `complete.ps1` ending lines with LF.
- **`termancy serve` with a Windows program**, tried by hand: over SSH on pipes (`termancy
  ssh run`) and on a pseudo console (OpenSSH's `ssh -tt`, the session ending when
  the program does), and `--web` in a browser, typing into `cmd.exe`.
- **`termancy image -p auto`**: Windows Terminal 1.24 answers the query with sixel (and
  `WT_SESSION` says the same); the classic console host answers without graphics, so it
  gets `mosaic`. Both in real windows, through the console case `query`.
- **`examples/repos` by hand**, against real git (2.55, Git for Windows): `setup` at a
  console, typing a root with backslashes (written to TOML escaped); `list` with a name
  holding a space and a nested `work/api`; `fetch` (ahead and behind a local remote); the
  TUI under ConPTY (filter, quit); and `ui --web` in a browser.
- **The release `.zip`**: built as `release.yml` does (`ReleaseSafe`, `x86_64-windows`),
  zipped, and extracted by `update.extractExecutable` to the same bytes. (Zipped here with
  Windows' `tar -a`; CI uses Info-ZIP.)
- **A Windows Hello passkey, end to end**: `windows_hello.register` made a platform
  credential (ES256) for a test RP, `assert` signed with it, and `webauthn.verify` checked
  the signature against the registered key (count 0, then 1); the passkey was deleted
  after. Then the same through `termancy passkey create` and `get`, their JSON
  checked as a relying party would. This found that the dialog never appeared from a
  terminal on a pseudo console (Windows Terminal, an IDE's): it was owned by the console
  window, which such a console never shows. It now belongs to the foreground window
  unless the console window is visible.
- **ssh-agent against OpenSSH's agent** (service running): `termancy ssh run` logged in
  to `termancy serve` with a key held only by the agent (its file deleted, and only it
  authorized; the server saw its fingerprint), and was refused once the key was removed
  from the agent.
- **`sandbox` with links**, in Developer Mode: the test runs instead of skipping, and a link
  out of the roots is refused (`SymlinkEscape`).
- **`termancy update` could not replace the running `termancy.exe`.** `move_aside` renames
  the running image first, and Zig's `Dir.rename` asks to write the file as well, which
  Windows refuses for a running image (`FileBusy` after 5 s of retries; zig-issues.md,
  issue 6). It renames with `MoveFileExW` on Windows now (test "renameImage moves a
  running executable aside, and back"), and termancy deletes the `termancy.exe.old` left behind
  when it next starts, as Windows cannot while the old one runs.
- **Request and login timeouts that could not fire.** The web server's request-head
  timeout and the SSH server's login timeout cut the connection off with `shutdown`, which
  on Windows does not wake the pending read (zig-issues.md, issue 4). Each read runs in a
  task of its own now, given up on with `cancel` at the deadline.
- **The DX and UX pass, on Windows:** `termancy cli init`, `cli add`, and the generated
  project's `zig build test` and `run`, in PowerShell and in cmd; "did you mean" compile
  errors; `tui init` looking upward across `\` paths, to a drive root, and on a UNC path
  (`\\localhost\C$\...`); an unknown key in a CRLF file reported with its Windows path,
  line, and column; `-o json` usage errors in PowerShell 7 and 5.1; `-q`. Two fixes came
  out of it: `cli init`'s "next:" hint was `cd demo && zig build ...`, which Windows
  PowerShell 5.1 cannot parse, and is two lines on Windows now; and `tui init`, `add`, and
  their errors printed `C:\x\demo/build.zig` and `..\../build.zig`, and now follow
  `sys.files.join`'s rule.

## Left

| What | State |
|---|---|
| The first CI run | `ci.yml` runs `zig build test` and `zig build console` on `windows-latest`; it has never run. Locally everything above passes |
| `termancy passkey` elsewhere | `get` uses a USB key under `/dev/hidraw` on Linux (not tried with a real key here); `create` needs Windows Hello, as `ctap` has no makeCredential; macOS has neither |
| Authenticode signing | the release step has not run: it needs a code-signing certificate in the secrets. Without one `termancy.exe` ships unsigned, and SmartScreen warns on first run |
| A winget submission | the manifest is generated; winget-pkgs takes the multi-file form (`wingetcreate update`), a pull request to that repository |
| Compile errors that flake | once in a few runs of `zig build test`, a `compile-errors` case fails because the compiler cannot read a file of its own library (`unable to load "test.zig": Unexpected`, a different file each time) during a full `zig build test`. Not the cases colliding: run one at a time, the cases still failed once in six runs, and 30 runs of one case alone, or of ten at once, never failed. Something else in the full run sets it off (the end-to-end tests start many processes; an antivirus scan is a guess). Zig's, not termancy's; rerunning passes |
| `sys.web.Server` test trace | once, a `CONNECTION_RESET` stack trace in Debug; the test passes. Not reproduced in eight runs, nor by probes of read, write, accept, and shutdown after a reset (below) |
| Ctrl+Z suspend | nothing to do: Windows consoles have no job control |
| A cached example that crashes with no output | once, `zig build examples` ran `first-app.exe` and `tasks.exe` from the cache, and they crashed silently (status 5, or an access violation) on every run, while byte-identical copies, even in the same folder, ran fine. Windows was mapping a stale image of those files; copying the same bytes over each fixed it. Not termancy's code. If it comes back, replace the file, or delete that `o/` folder |
| Installing with Scoop | the README's `scoop install .../termancy.json` waits for a release to exist; the manifest is generated and its fields tested |
| ARM64 Windows | compiled by `check`; `ci.yml` runs the tests and `console` on `windows-11-arm`, which has never run either |

## Upstream reports

The Zig problems met on the way, written up as issues with reproductions, are in
[zig-issues.md](zig-issues.md). None is filed yet.
